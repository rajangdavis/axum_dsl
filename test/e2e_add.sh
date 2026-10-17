#!/bin/sh
# L5 end to end for the axum service the DSL generates from examples/add.axum.rb: start it, speak
# HTTP to it, and check every route the example declares, plus the answers the generated extractors
# give a bad request. Exit zero only when every check passed. Needs curl.
# usage: sh test/e2e_add.sh [CRATE_DIR]      (default /tmp/add-out)
# Build the crate first:  ruby exe/axum_dsl build examples/add.axum.rb -o /tmp/add-out
set -eu

dir=${1:-/tmp/add-out}
host=127.0.0.1
port=8080        # examples/add.axum.rb: `set :port, 8080`
name=calculator  # examples/add.axum.rb: `server "calculator"` names the crate, so names this binary
base="http://$host:$port"

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
	fail "e2e_add.sh speaks HTTP with curl or ruby, and neither is on PATH"
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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_add.XXXXXX") || exit 1
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
# Every way out — a failed check, a signal — kills the server, so it never holds the port for the
# next run. The signal traps exit, which runs the EXIT trap, and stop a run someone interrupted.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The port belongs to the example, so a server already on it is a fault of the environment and not
# a reason to test somebody else's service.
if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/add.axum.rb fixes the port with \`set :port, 8080\`, and this test has no other."
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

# get "/add", params: :CalcParams do text((params[:a] + params[:b]).to_s) end
#   a and b are :i32 `in: :query`.
want_body "add: 2 + 3" "/add?a=2&b=3" 200 "5"
want_body "add: 2 + 40" "/add?a=2&b=40" 200 "42"
want_body "add: -7 + 7" "/add?a=-7&b=7" 200 "0"

# get "/users/:id", params: :UserId do json(params[:id]) end
#   id is :i64 `in: :path`, so the answer is that number as JSON.
want_body "users: 42" "/users/42" 200 "42"
want_body "users: 9000000001" "/users/9000000001" 200 "9000000001"
if grep -qi '^content-type:[ 	]*application/json' "$headers"; then
	passed=$((passed + 1))
	echo "ok: GET /users/9000000001 -> content-type is application/json"
else
	echo "FAIL: GET /users/9000000001 did not answer application/json; its headers were:"
	sed 's/^/      /' "$headers" 2>/dev/null || true
	failed=$((failed + 1))
fi

# The compiler's own failure paths: a field of the wrong shape is a 400 from the extractor, never a
# panic and never a 200. (CalcParams carries no constraint, so its struct needs no check() of its
# own; what the DSL generates around these routes is the Query and Path rejections.)
want_error "add: b is not an integer" "/add?a=2&b=x" 400
want_error "add: b is missing" "/add?a=2" 400
want_error "users: id is not an integer" "/users/abc" 400

# The example declares no not_found, so a path it does not route is axum's own 404: a service that
# answered 200 to everything would fail here.
get "/nope"
if [ "$status" = "404" ]; then
	passed=$((passed + 1))
	echo "ok: GET /nope -> 404"
else
	echo "FAIL: GET /nope -> HTTP $status, wanted 404"
	echo "      body: [$(cat "$body")]"
	failed=$((failed + 1))
fi

# The deployment contract: the environment chooses the listener, and SIGTERM stops the service.
# A second copy runs beside the first on another port (the first holds 8080, so this also shows PORT
# beats `set :port`). Graceful shutdown is checked with a request in flight: GET /slow takes about 2 s
# (examples/add.axum.rb runs `sleep 2`), SIGTERM arrives while it is running, and the request must still
# finish with 200 and its body, the listener must stop taking new connections, and the process must then
# exit 0 (the old bare `axum::serve` died of the signal). The drain has no deadline; nothing here tests one.
alt=$((20000 + $$ % 20000))
port=$alt # get and listening look at $port and $base; put 8080 back below
base="http://$host:$port"
log2="$work/server2.log"
PORT=$alt BIND=0.0.0.0 "$bin" >"$log2" 2>&1 & # 0.0.0.0 still answers on 127.0.0.1: this runs the BIND path, not a different interface
pid2=$!
i=0
until listening; do
	i=$((i + 1))
	if [ "$i" -gt 100 ] || ! kill -0 "$pid2" 2>/dev/null; then
		echo "FAIL: PORT=$alt: the service did not come up on $host:$alt"
		sed 's/^/      /' "$log2" 2>/dev/null || true
		kill -TERM "$pid2" 2>/dev/null || true
		exit 1
	fi
	sleep 0.1
done
want_body "PORT=$alt overrides set :port" "/add?a=2&b=3" 200 "5"

# GET /slow in the background: its status code goes to slow.status and its body to slow.body.
slow_bg() {
	if has curl; then
		curl -sS --max-time 15 -o "$work/slow.body" -w '%{http_code}' "$base/slow" >"$work/slow.status" 2>/dev/null &
	else
		ruby -rnet/http -ruri -e '
			begin
				u = URI(ARGV[0])
				res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 15) { |h| h.request(Net::HTTP::Get.new(u.request_uri)) }
				File.binwrite(ARGV[1], res.body.to_s)
				print res.code
			rescue StandardError
				print "000"
			end
		' "$base/slow" "$work/slow.body" >"$work/slow.status" 2>/dev/null &
	fi
}
slow_bg
slow_pid=$!
# There is nothing to poll for "the server has read the request and is running the handler", so this
# sleeps 0.5 s, a quarter of the handler's 2 s. A loaded machine that takes longer than 2 s to deliver the
# request would make SIGTERM arrive first, and the check below would then fail (a flake, never a false pass).
sleep 0.5
kill -TERM "$pid2"

# The listener closes as soon as the signal is handled, long before the handler's 2 s are up, so a new
# connection stops being answered while the process is still alive draining /slow. Poll briefly for it.
i=0
while listening && [ "$i" -lt 8 ]; do
	i=$((i + 1))
	sleep 0.1
done
if listening; then
	echo "FAIL: SIGTERM: a new connection to $host:$alt was still answered 0.8 s after the signal"
	failed=$((failed + 1))
elif ! kill -0 "$pid2" 2>/dev/null; then
	echo "FAIL: SIGTERM: the service was gone before /slow could finish, so nothing was drained"
	failed=$((failed + 1))
else
	passed=$((passed + 1))
	echo "ok: SIGTERM -> new connections are refused while the process is still draining"
fi

# The request that was in flight is answered in full.
wait "$slow_pid" || true
slow_status=$(cat "$work/slow.status" 2>/dev/null || echo missing)
if [ "$slow_status" = 200 ] && body_is "$work/slow.body" "slept"; then
	passed=$((passed + 1))
	echo "ok: SIGTERM -> the in-flight GET /slow finished with 200 [slept]"
else
	echo "FAIL: SIGTERM: the in-flight GET /slow was not drained: HTTP $slow_status, body [$(cat "$work/slow.body" 2>/dev/null)]"
	failed=$((failed + 1))
fi
port=8080
base="http://$host:$port"

i=0
while kill -0 "$pid2" 2>/dev/null && [ "$i" -le 50 ]; do
	i=$((i + 1))
	sleep 0.1
done
if kill -0 "$pid2" 2>/dev/null; then
	echo "FAIL: SIGTERM: the service was still running 5 s later"
	kill -KILL "$pid2" 2>/dev/null || true
	failed=$((failed + 1))
else
	rc=0
	wait "$pid2" || rc=$?
	if [ "$rc" = 0 ]; then
		passed=$((passed + 1))
		echo "ok: SIGTERM -> the service exited 0"
	else
		echo "FAIL: SIGTERM: the service exited $rc, wanted 0"
		failed=$((failed + 1))
	fi
fi

# A PORT that is not a port number stops the service before it listens: exit 2 and a message.
rc=0
PORT=http "$bin" >"$work/bad-port.log" 2>&1 || rc=$?
if [ "$rc" = 2 ] && grep -q '^PORT must be a port number' "$work/bad-port.log"; then
	passed=$((passed + 1))
	echo "ok: PORT=http -> exit 2 with a message"
else
	echo "FAIL: PORT=http: exit $rc, wanted 2 with a message; its output was:"
	sed 's/^/      /' "$work/bad-port.log" 2>/dev/null || true
	failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: /add returns a + b as text, /users/:id returns the id as JSON, a bad or missing input is a 400, an unrouted path is a 404, PORT chooses the port, SIGTERM drains an in-flight /slow and refuses new connections, then exits 0, a bad PORT exits 2"
