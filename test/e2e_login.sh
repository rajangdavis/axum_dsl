#!/bin/sh
# L5 end to end for the session service the DSL generates from examples/login.axum.rb: sign up, refuse a wrong
# password, log in and receive a signed `session_token` cookie (HttpOnly, SameSite=Lax, Path=/), read /me with it,
# be redirected without it and with a tampered or foreign-keyed one, log out and find the old cookie dead (its
# session row is gone), see the Fetch Metadata guard refuse a cross-site write and pass a same-origin one, and see a
# SECRET_KEY_BASE shorter than 32 bytes stop the server at startup with exit status 2. Exit zero only when every
# check passed. Needs curl.
# usage: sh test/e2e_login.sh [CRATE_DIR]      (default /tmp/axum_dsl_login-out)
# Build the crate first:  ruby exe/axum_dsl build examples/login.axum.rb -o /tmp/axum_dsl_login-out
set -eu

dir=${1:-/tmp/axum_dsl_login-out}
host=127.0.0.1
port=8086        # examples/login.axum.rb: `set :port, 8086`
name=login       # examples/login.axum.rb: `server "login"` names the crate, so names this binary
base="http://$host:$port"
key=0123456789abcdef0123456789abcdef0123456789
other_key=abcdef0123456789abcdef0123456789abcdef01

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_login.sh speaks HTTP with curl, which is not on PATH"

# make shares one cargo target dir (CARGO_TARGET_DIR), so the binary is there, or else inside the
# crate directory.
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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_login.XXXXXX") || exit 1
body="$work/body"
hdr="$work/headers"
err="$work/err"
log="$work/server.log"
db="$work/login.sqlite3"
pid=
cleanup() {
	if [ -n "${pid:-}" ]; then
		# the server is started with setsid where that exists, so it leads its own process group
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

# Is a server answering on $host:$port? A refused connection exits non-zero.
listening() { curl -s -o /dev/null --max-time 2 "$base/" 2>/dev/null; }

# req METHOD PATH [curl args]: the answer's code goes to $status, its headers to $hdr and its body to $body.
req() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -D "$hdr" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/login.axum.rb fixes the port with \`set :port, 8086\`, and this test has no other."
	exit 1
fi

# Starts the service with the key $1 and waits for its port; a server that died on the way up is reported with
# its own output.
start_server() {
	DATABASE_PATH="$db" SECRET_KEY_BASE="$1" setsid "$bin" >>"$log" 2>&1 &
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
}

stop_server() {
	kill -TERM "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	pid=
	i=0
	while listening && [ "$i" -lt 50 ]; do
		i=$((i + 1))
		sleep 0.1
	done
}

passed=0
failed=0

ok() {
	passed=$((passed + 1))
	echo "ok: $1"
}

bad() {
	failed=$((failed + 1))
	echo "FAIL: $1"
}

# want LABEL STATUS BODY-PREFIX: the last req answered that status, with a body that starts with that text.
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

# redirects LABEL LOCATION: the last req answered a redirect to that Location.
redirects() {
	location=$(sed -n 's/^[Ll]ocation: *//p' "$hdr" | tr -d '\r' | head -n 1)
	case "$status" in
	301 | 302 | 303 | 307 | 308)
		if [ "$location" = "$2" ]; then
			ok "$1 -> $status, Location $location"
			return 0
		fi
		;;
	esac
	bad "$1"
	echo "      HTTP $status with Location [$location], wanted a redirect to [$2]"
}

# set_cookie_has LABEL PATTERN: the last req's Set-Cookie line matches the pattern (an extended regex, case-blind).
set_cookie_has() {
	if grep -i '^set-cookie:' "$hdr" | tr -d '\r' | grep -Eiq "$2"; then
		ok "$1"
	else
		bad "$1: no Set-Cookie line matching [$2]; headers:"
		sed 's/^/      /' "$hdr"
	fi
}

# --- the first run -------------------------------------------------------------------------------
start_server "$key"

req POST /signup --data-urlencode "name=Ada" --data-urlencode "email=ada@example.com" --data-urlencode "password=correct horse"
redirects "POST /signup creates the user" /session/new
req POST /signup --data-urlencode "name=Ada" --data-urlencode "email=ada@example.com" --data-urlencode "password=other"
want "POST /signup with the same email is refused" 409 "that email address is taken"

req POST /session --data-urlencode "email=ada@example.com" --data-urlencode "password=wrong"
want "POST /session with a wrong password" 401 "bad login"
req POST /session --data-urlencode "email=nobody@example.com" --data-urlencode "password=correct horse"
want "POST /session with an unknown email" 401 "bad login"
if grep -qi '^set-cookie:' "$hdr"; then
	bad "a refused login set a cookie"
else
	ok "a refused login sets no cookie"
fi

req POST /session --data-urlencode "email=ada@example.com" --data-urlencode "password=correct horse"
redirects "POST /session logs in" /me
set_cookie_has "the login sets session_token" '^set-cookie: session_token=[^;]+\.[^;]+;'
set_cookie_has "the cookie is HttpOnly" '; HttpOnly'
set_cookie_has "the cookie is SameSite=Lax" '; SameSite=Lax'
set_cookie_has "the cookie is Path=/" '; Path=/(;|$)'
set_cookie_has "the cookie lasts (permanent: true)" '; Max-Age=631139040'
cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: *\(session_token=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1)
[ -n "$cookie" ] || fail "no session_token cookie to carry on with"

req GET /me -H "Cookie: $cookie"
want "GET /me with the cookie" 200 "Hello, Ada"
req GET /me
redirects "GET /me without a cookie" /session/new
req GET /me -H "Cookie: ${cookie}x"
redirects "GET /me with a tampered cookie (a character added)" /session/new
req GET /me -H "Cookie: ${cookie%?}"
redirects "GET /me with a tampered cookie (a character dropped)" /session/new
req GET /me -H "Cookie: session_token=abc"
redirects "GET /me with an unsigned cookie" /session/new
req GET /me -H "Cookie: other=1; $cookie; more=2"
want "GET /me finds the cookie among others" 200 "Hello, Ada"

# --- the Fetch Metadata guard ----------------------------------------------------------------------
req POST /session -H "Sec-Fetch-Site: cross-site" --data-urlencode "email=ada@example.com" --data-urlencode "password=correct horse"
want "POST /session from another site" 403 "cross-site request refused"
req POST /session -H "Sec-Fetch-Site: same-site" --data-urlencode "email=ada@example.com" --data-urlencode "password=correct horse"
want "POST /session from a sibling site (same-site)" 403 "cross-site request refused"
req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email=ada@example.com" --data-urlencode "password=correct horse"
redirects "POST /session from the same origin" /me
req POST /session -H "Sec-Fetch-Site: none" --data-urlencode "email=ada@example.com" --data-urlencode "password=wrong"
want "POST /session typed into the address bar (none) passes the guard" 401 "bad login"
req GET /session/new -H "Sec-Fetch-Site: cross-site"
want "GET /session/new from another site is a read, so it passes" 200 "<form"

# --- log out ---------------------------------------------------------------------------------------
req DELETE /session -H "Sec-Fetch-Site: cross-site" -H "Cookie: $cookie"
want "DELETE /session from another site" 403 "cross-site request refused"
req GET /me -H "Cookie: $cookie"
want "the refused logout left the session alone" 200 "Hello, Ada"
req DELETE /session -H "Cookie: $cookie"
redirects "DELETE /session logs out" "/session/new?ended=1"
set_cookie_has "the logout clears the cookie" '^set-cookie: session_token=;'
set_cookie_has "the clearing cookie expires at once" '; Max-Age=0'
req GET /me -H "Cookie: $cookie"
redirects "the old cookie no longer works (its session row is gone)" /session/new
req DELETE /session -H "Cookie: $cookie"
redirects "DELETE /session again finds no session" "/session/new?ended=0"

# --- a different key -------------------------------------------------------------------------------
req POST /session --data-urlencode "email=ada@example.com" --data-urlencode "password=correct horse"
cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: *\(session_token=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1)
req GET /me -H "Cookie: $cookie"
want "a fresh login works" 200 "Hello, Ada"

# --- rate limiting: POST /session is capped per client, per 60 s window -----------------------------
# use_layer :rate_limit, per: 60, burst: 25, path: "/session". The requests above have used about a dozen
# of the 25 (POSTs and the DELETEs, since the limit is per path); a burst of 51 more (more than twice the
# burst) must see 429 whichever side of a 60 s window boundary it falls on, and a GET on another path must
# stay unlimited.
# This is the end of the first run, so the count cannot disturb the assertions above; the next server start
# is a fresh process and starts from zero.
limited=0
i=0
while [ "$i" -lt 51 ]; do
	i=$((i + 1))
	req POST /session --data-urlencode "email=nobody@example.com" --data-urlencode "password=wrong"
	if [ "$status" = "429" ]; then limited=$((limited + 1)); fi
done
if [ "$limited" -gt 0 ]; then
	ok "a burst of 51 POSTs to /session is rate limited ($limited answered 429)"
else
	bad "a burst of 51 POSTs to /session answered no 429"
fi
req GET /session/new
want "GET /session/new is outside the rate limit path" 200 "<form"
stop_server
start_server "$other_key"
req GET /me -H "Cookie: $cookie"
redirects "a cookie signed with another key is not accepted" /session/new
stop_server

# --- a key that is too short ------------------------------------------------------------------------
rc=0
# a bug would leave the server listening, so the run is bounded where timeout exists
limit=
if has timeout; then limit="timeout 20"; fi
DATABASE_PATH="$db" SECRET_KEY_BASE=tooshort $limit "$bin" >"$work/short.log" 2>&1 || rc=$?
if [ "$rc" = 2 ] && grep -q 'SECRET_KEY_BASE' "$work/short.log" && grep -q '32 bytes' "$work/short.log"; then
	ok "a SECRET_KEY_BASE of 8 bytes stops the server at startup (exit 2) and says why"
else
	bad "a short SECRET_KEY_BASE did not stop the server with exit 2 and a message; exit $rc, output:"
	sed 's/^/      /' "$work/short.log" 2>/dev/null || true
fi

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: signup, login with a signed HttpOnly SameSite=Lax cookie, /me with it, a redirect without it or with a tampered or foreign-keyed one, logout that kills the cookie and its session, the Fetch Metadata guard, a short key stops the server"
