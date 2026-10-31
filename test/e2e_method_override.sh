#!/bin/sh
# L5 end to end for the service the DSL generates from examples/method_override.axum.rb: a POST whose `_method`
# form field (or X-HTTP-Method-Override header) names PATCH or DELETE reaches the `patch` or `delete` route,
# an unknown override stays a POST, a GET is never rewritten, the route still reads the form body, and a route's
# `request_method` is the rewritten method.
# Exit zero only when every check passed. Needs curl.
# usage: sh test/e2e_method_override.sh [CRATE_DIR]      (default /tmp/axum_dsl_method_override-out)
# Build the crate first:  ruby exe/axum_dsl build examples/method_override.axum.rb -o /tmp/axum_dsl_method_override-out
set -eu

dir=${1:-/tmp/axum_dsl_method_override-out}
host=127.0.0.1
port=8101        # examples/method_override.axum.rb: `set :port, 8101`
name=method_override
base="http://$host:$port"

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_method_override.sh speaks HTTP with curl, which is not on PATH"

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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_method_override.XXXXXX") || exit 1
body="$work/body"
err="$work/err"
log="$work/server.log"
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

listening() { curl -s -o /dev/null --max-time 2 "$base/notes/1" 2>/dev/null; }

# req METHOD PATH [curl args]
req() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	exit 1
fi

: >"$log"
if has setsid; then
	setsid "$bin" >>"$log" 2>&1 &
else
	"$bin" >>"$log" 2>&1 &
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

# want LABEL STATUS BODY: the last request answered that status with exactly that body.
want() {
	got=$(cat "$body")
	if [ "$status" = "$2" ] && [ "$got" = "$3" ]; then
		ok "$1 -> $status [$got]"
	else
		bad "$1"
		echo "      HTTP $status, wanted $2 with [$3]"
		echo "      body: [$got]"
	fi
}

req POST /notes/7 --data-urlencode "body=plain"
want "a POST without _method stays a POST" 200 "post 7: plain"

req POST /notes/7 --data-urlencode "_method=delete"
want "_method=delete reaches the delete route" 200 "delete 7"

req POST /notes/7 --data-urlencode "_method=patch" --data-urlencode "body=hello world"
want "_method=patch reaches the patch route, and the route still reads the form body" 200 "patch 7: hello world"

req POST /notes/7 --data-urlencode "_method=Patch" --data-urlencode "body=mixed case"
want "the method is upcased" 200 "patch 7: mixed case"

req POST /method --data-urlencode "_method=patch"
want "a route's request_method is the rewritten method" 200 "PATCH"

req POST /notes/7 --data-urlencode "_method=bogus" --data-urlencode "body=kept"
want "an unknown _method leaves the request a POST" 200 "post 7: kept"

req POST /notes/7 --data-urlencode "_method=" -H "X-HTTP-Method-Override: DELETE" --data-urlencode "body=empty"
want "an empty _method is still the field, so the header is not read" 200 "post 7: empty"

req GET "/notes/7?_method=delete"
want "a GET with _method is not rewritten" 200 "get 7"

req POST /notes/7 -H "X-HTTP-Method-Override: DELETE" --data-urlencode "body=x"
want "the X-HTTP-Method-Override header works" 200 "delete 7"

req POST /notes/7 -H "X-HTTP-Method-Override: patch" --data-urlencode "body=via header"
want "the header is upcased and the form body still arrives" 200 "patch 7: via header"

req POST /notes/7 -H "X-HTTP-Method-Override: DELETE" --data-urlencode "_method=patch" --data-urlencode "body=field wins"
want "the form field wins over the header" 200 "patch 7: field wins"

req DELETE /notes/7 --data-urlencode "_method=patch"
want "only a POST is considered: a real DELETE is not rewritten" 200 "delete 7"

req POST /notes/7 -H "Content-Type: application/json" -H "X-HTTP-Method-Override: DELETE" --data '{"_method":"patch"}'
want "a JSON body is not read for _method; the header applies" 200 "delete 7"

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: a POST's _method field or X-HTTP-Method-Override header is routed as PATCH or DELETE, an unknown one stays a POST, a GET and a real DELETE are not rewritten, and the route still reads its form"
