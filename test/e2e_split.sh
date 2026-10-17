#!/bin/sh
# L5 end to end for the axum service the DSL generates from examples/split.axum.rb, the example that is
# split across files with `use_dsl`: start it, speak HTTP to it, and check one route from each file --
# the root, split/routes.axum.rb, and split/status.axum.rb (a fragment included by a fragment) -- plus the
# params block that split/params.axum.rb declares and the routes in split/routes.axum.rb use. Exit zero
# only when every check passed. Needs curl or ruby.
# usage: sh test/e2e_split.sh [CRATE_DIR]      (default /tmp/axum_dsl_split-out)
# Build the crate first:  ruby exe/axum_dsl build examples/split.axum.rb -o /tmp/axum_dsl_split-out
set -eu

dir=${1:-/tmp/axum_dsl_split-out}
host=127.0.0.1
port=8082        # examples/split.axum.rb: `set :port, 8082`
name=splitter  # examples/split.axum.rb: `server "splitter"` names the crate, so names this binary
base="http://$host:$port"
repo=$(dirname "$0")/..

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# make shares one cargo target dir (CARGO_TARGET_DIR), so the binary is there, or else inside the
# crate directory.
bin=
for candidate in "${CARGO_TARGET_DIR:-$dir/target}/debug/$name" "$dir/target/debug/$name"; do
	if [ -x "$candidate" ]; then
		bin=$candidate
		break
	fi
done
[ -n "$bin" ] || fail "no $name binary under ${CARGO_TARGET_DIR:-$dir/target}/debug or $dir/target/debug"


# --- how this script speaks HTTP and probes the port ------------------------------------------
# curl is the house tool; ruby is the fallback, and the one HTTP client make has certainly just
# installed, since it has run `ruby exe/axum_dsl build`.
if ! has curl && ! has ruby; then
	fail "e2e_split.sh speaks HTTP with curl or ruby, and neither is on PATH"
fi
if has curl; then
	# GET "$1" into $body, the response headers into $headers; $status is the code.
	get() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' "$base$1" 2>"$err") || status=000
	}
	# Is a server answering on $host:$port? A refused connection exits non-zero.
	listening() {
		curl -s -o /dev/null --max-time 2 "$base/" 2>/dev/null
	}
else
	get() {
		status=$(ruby -rnet/http -ruri -e '
			u = URI(ARGV[0])
			req = Net::HTTP::Get.new(u.request_uri)
			req["Accept-Encoding"] = "identity"
			res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
			File.binwrite(ARGV[1], res.body.to_s)
			File.open(ARGV[2], "w") { |f| res.each_header { |k, v| f.puts "#{k}: #{v}" } }
			print res.code
		' "$base$1" "$body" "$headers" 2>"$err") || status=000
	}
	listening() {
		ruby -rsocket -e 'begin; TCPSocket.new(ARGV[0], ARGV[1].to_i).close; rescue SystemCallError, IOError; exit 1; end' "$host" "$port" 2>/dev/null
	}
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_split.XXXXXX") || exit 1
body="$work/body"
headers="$work/headers"
err="$work/err"
log="$work/server.log"
pid=
cleanup() {
	if [ -n "${pid:-}" ]; then
		# the server is started with setsid where that exists, so it leads its own process group
		# and `-$pid` reaches the whole group; the bare pid is the fallback.
		kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		pid=
	fi
	rm -rf "$work"
}
# Every way out -- a failed check, a signal -- kills the server, so it never holds the port for the
# next run. The signal traps exit, which runs the EXIT trap, and stop a run someone interrupted.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The port belongs to the example, so a server already on it is a fault of the environment and not
# a reason to test somebody else's service.
if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/split.axum.rb fixes the port with \`set :port, 8082\`, and this test has no other."
	echo "      Nothing was started by this test. Stop what holds $host:$port and run it again."
	exit 1
fi

: >"$log"
if has setsid; then
	setsid "$bin" >"$log" 2>&1 &
else
	"$bin" >"$log" 2>&1 &
fi
pid=$!

# Wait for the port instead of sleeping and hoping. A server that died on the way up is reported
# with its own output, which is where a failed bind or a missing file check says what it was.
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

# --- the checks --------------------------------------------------------------------------------
passed=0
failed=0

# Is $1 exactly $2, byte for byte, so a plausible body that differs by one byte fails too?
body_is() {
	printf '%s' "$2" >"$work/want"
	[ "$(cat "$1")" = "$(cat "$work/want")" ] && [ "$(wc -c <"$1")" = "$(wc -c <"$work/want")" ]
}

# want_body LABEL PATH STATUS BODY
want_body() {
	get "$2"
	if [ "$status" != "$3" ]; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, wanted $3"
		echo "      body: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	if ! body_is "$body" "$4"; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, but the body was not the one expected"
		echo "      wanted: [$4]"
		echo "      got:    [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	passed=$((passed + 1))
	echo "ok: GET $2 -> $status [$4]"
}

# want_error LABEL PATH STATUS: that status, a body saying why, and no panic.
want_error() {
	get "$2"
	if [ "$status" != "$3" ]; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, wanted $3"
		echo "      body: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	if [ ! -s "$body" ]; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status with an empty body; a rejection should say what was wrong"
		failed=$((failed + 1))
		return 0
	fi
	if grep -qi panic "$body"; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status but the body looks like a panic: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	passed=$((passed + 1))
	echo "ok: GET $2 -> $status [$(cat "$body")]"
}

# split.axum.rb itself: get "/ping" do text("pong") end
want_body "root file: ping" "/ping" 200 "pong"

# split/routes.axum.rb, with its params blocks from split/params.axum.rb
want_body "routes fragment: 2 + 3" "/sum?a=2&b=3" 200 "5"
want_body "routes fragment: -7 + 7" "/sum?a=-7&b=7" 200 "0"
want_body "routes fragment: hello" "/hello?name=World" 200 "hello, World"
want_error "params fragment: b is not an integer" "/sum?a=2&b=x" 400
want_error "params fragment: name is missing" "/hello" 400

# split/status.axum.rb, which split/routes.axum.rb includes: a fragment two levels deep
want_body "nested fragment: status" "/status" 200 "split ok"

get "/nope"
if [ "$status" = "404" ]; then
	passed=$((passed + 1))
	echo "ok: GET /nope -> 404"
else
	echo "FAIL: GET /nope -> HTTP $status, wanted 404"
	echo "      body: [$(cat "$body")]"
	failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: a route from the root, from a fragment and from a fragment of a fragment all answer, the params fragment's types are enforced, an unrouted path is a 404"
