#!/bin/sh
# L5 end to end for the CSRF service the DSL generates from examples/csrf.axum.rb: the form carries the token
# from `{{ csrf_token }}`, the token is also a signed HttpOnly cookie, and a write must submit it as the
# `authenticity_token` form field or as `X-CSRF-Token`; a missing, wrong, forged or cookie-less one is a 403,\n# and an urlencoded body over 2 MiB is a 413.
# A cross-site write is refused by `use_layer :fetch_metadata` before the token is looked at. Exit zero only
# when every check passed. Needs curl, sed, dd and tr (the token is read out of the form, and an oversized body is generated).
# usage: sh test/e2e_csrf.sh [CRATE_DIR]      (default /tmp/axum_dsl_csrf-out)
# Build the crate first:  ruby exe/axum_dsl build examples/csrf.axum.rb -o /tmp/axum_dsl_csrf-out
set -eu

dir=${1:-/tmp/axum_dsl_csrf-out}
host=127.0.0.1
port=8087        # examples/csrf.axum.rb: `set :port, 8087`
name=csrf        # examples/csrf.axum.rb: `server "csrf"` names the crate, so names this binary
base="http://$host:$port"
key=0123456789abcdef0123456789abcdef0123456789

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_csrf.sh speaks HTTP with curl, which is not on PATH"

find_bin() {
	for candidate in "${CARGO_TARGET_DIR:-$1/target}/debug/$2" "$1/target/debug/$2"; do
		if [ -x "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}
bin=$(find_bin "$dir" "$name") || fail "no $name binary under ${CARGO_TARGET_DIR:-$dir/target}/debug or $dir/target/debug"

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_csrf.XXXXXX") || exit 1
body="$work/body"
hdr="$work/headers"
err="$work/err"
log="$work/server.log"
jar="$work/cookies"
pid=
cleanup() {
	if [ -n "${pid:-}" ]; then
		kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		pid=
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

listening() { curl -s -o /dev/null --max-time 2 "$base/form" 2>/dev/null; }

# req METHOD PATH [curl args]: with the browser's cookie jar.
req() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -b "$jar" -c "$jar" -D "$hdr" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

# anon METHOD PATH [curl args]: no cookie jar, so no cookie is sent or kept.
anon() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -D "$hdr" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/csrf.axum.rb fixes the port with \`set :port, 8087\`, and this test has no other."
	exit 1
fi

: >"$log"
if has setsid; then
	SECRET_KEY_BASE="$key" setsid "$bin" >>"$log" 2>&1 &
else
	SECRET_KEY_BASE="$key" "$bin" >>"$log" 2>&1 &
fi
pid=$!
i=0
until listening; do
	i=$((i + 1))
	if [ "$i" -gt 100 ]; then
		echo "FAIL: $host:$port did not accept a connection within 10 s"
		sed 's/^/      /' "$log" 2>/dev/null || true
		exit 1
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "FAIL: $bin exited before it accepted a connection on $host:$port"
		sed 's/^/      /' "$log" 2>/dev/null || true
		exit 1
	fi
	sleep 0.1
done

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "ok: $1"; }
bad() { failed=$((failed + 1)); echo "FAIL: $1"; }

# want LABEL STATUS PREFIX: the last request answered that status with a body starting with PREFIX.
want() {
	got=$(cat "$body")
	case "$got" in
	"$3"*)
		if [ "$status" = "$2" ]; then
			ok "$1 -> $status [$got]"
			return 0
		fi
		;;
	esac
	bad "$1"
	echo "      HTTP $status, wanted $2 with a body starting [$3]"
	echo "      body: [$got]"
}

# set_cookie_has LABEL PATTERN: the last response has a Set-Cookie line matching PATTERN (case-blind ERE).
set_cookie_has() {
	if grep -i '^set-cookie:' "$hdr" | tr -d '\r' | grep -Eiq "$2"; then
		ok "$1"
	else
		bad "$1: no Set-Cookie line matching [$2]"
		sed 's/^/      /' "$hdr"
	fi
}

# --- the form and its token ----------------------------------------------------------------------
req GET /form
want "GET /form answers the form" 200 "<!doctype html>"
set_cookie_has "GET /form sets the signed CSRF cookie" '_axum_dsl_csrf=[A-Za-z0-9_.-]+; Path=/; SameSite=Lax; HttpOnly'
token=$(sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p' "$body" | head -n 1)
if [ -n "$token" ]; then
	ok "the form carries an authenticity_token ($token)"
else
	bad "the form carries no authenticity_token"
fi

# A second GET with the jar reuses the cookie: the layer mints a token only for a request without one.
req GET /form
if grep -qi '^set-cookie:.*_axum_dsl_csrf=' "$hdr" 2>/dev/null; then
	bad "a second GET with the cookie set it again; the token should be reused"
else
	ok "a request that already has the cookie is not given a new one"
fi

# --- the token check -----------------------------------------------------------------------------
req POST /notes --data-urlencode "authenticity_token=$token" --data-urlencode "body=hello world"
want "POST with the form's token passes" 200 "note: hello world"

req POST /notes --data-urlencode "body=no token"
want "POST with no token is refused" 403 "CSRF token missing or invalid"

req POST /notes --data-urlencode "authenticity_token=wrong" --data-urlencode "body=wrong"
want "POST with a wrong token is refused" 403 "CSRF token missing or invalid"

# The middleware reads an urlencoded body once to find the field; a body over its 2 MiB limit is a 413
# before axum's Form extractor sees it. The token is deliberately valid so only the size triggers this.
big="$work/big"
{ printf 'authenticity_token=%s&body=' "$token"; dd if=/dev/zero bs=1024 count=2049 2>/dev/null | tr '\0' 'a'; } >"$big"
req POST /notes -H "Content-Type: application/x-www-form-urlencoded" --data-binary @"$big"
want "a urlencoded write over 2 MiB is refused" 413 "request body is too large"

req POST /notes -H "X-CSRF-Token: $token" --data-urlencode "body=header token"

want "POST with the X-CSRF-Token header passes" 200 "note: header token"

# The token alone is not enough: the request needs the cookie it must match.
anon POST /notes --data-urlencode "authenticity_token=$token" --data-urlencode "body=no cookie"
want "POST with a token but no cookie is refused" 403 "CSRF token missing or invalid"

anon POST /notes -b "_axum_dsl_csrf=forged.token" --data-urlencode "authenticity_token=$token" --data-urlencode "body=forged"
want "POST with a forged cookie and a valid token is refused" 403 "CSRF token missing or invalid"

# Fetch Metadata runs first: even a valid token does not let another site through.
req POST /notes -H "Sec-Fetch-Site: cross-site" --data-urlencode "authenticity_token=$token" --data-urlencode "body=cross"
want "a cross-site write is refused before the token" 403 "cross-site request refused"

# A GET is not checked and needs no token (the form itself is a GET).
anon GET /form
want "GET /form needs no cookie or token" 200 "<!doctype html>"

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: the form carries a token in a signed cookie, a matching form field or X-CSRF-Token passes, a missing, wrong, forged or cookie-less one is a 403 behind the Fetch Metadata guard, and a body over 2 MiB is a 413"
