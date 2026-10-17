#!/bin/sh
# L5 end to end for the axum service the DSL generates from examples/proxy.axum.rb: start it, send
# requests with and without an X-Forwarded-For header, and check which address the trace layer's log
# line names. `use_layer :trace, forwarded: true` installs a subscriber, so the log is the server's own
# output ($log below). Exit zero only when every check passed. Needs curl or ruby.
# usage: sh test/e2e_proxy.sh [CRATE_DIR]      (default /tmp/axum_dsl_proxy-out)
# Build the crate first:  ruby exe/axum_dsl build examples/proxy.axum.rb -o /tmp/axum_dsl_proxy-out
set -eu

dir=${1:-/tmp/axum_dsl_proxy-out}
host=127.0.0.1
port=8095       # examples/proxy.axum.rb: `set :port, 8095` (add 8080, views 8091, validate 8093, assets 8097)
name=proxy      # examples/proxy.axum.rb: `server "proxy"` names the crate, so names this binary
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
	fail "e2e_proxy.sh speaks HTTP with curl or ruby, and neither is on PATH"
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
	# GET "$1" with an X-Forwarded-For header, into $body and $headers.
	get_forwarded() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' -H "X-Forwarded-For: $2" "$base$1" 2>"$err") || status=000
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
	get_forwarded() {
		status=$(ruby -rnet/http -ruri -e '
			u = URI(ARGV[0])
			req = Net::HTTP::Get.new(u.request_uri)
			req["Accept-Encoding"] = "identity"
			req["X-Forwarded-For"] = ARGV[2]
			res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
			File.binwrite(ARGV[1], res.body.to_s)
			File.open(ARGV[3], "w") { |f| res.each_header { |k, v| f.puts "#{k}: #{v}" } }
			print res.code
		' "$base$1" "$body" "$2" "$headers" 2>"$err") || status=000
	}
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_proxy.XXXXXX") || exit 1
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
	echo "      examples/proxy.axum.rb fixes the port with \`set :port, 8095\`, and this test has no other."
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
# with its own output, which is where a failed bind says what it was.
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

# Does the server's log carry $1 within 3 s? The line is written as the request starts, but not
# necessarily before the response has been read.
log_has() {
	n=0
	while [ "$n" -lt 30 ]; do
		if grep -q "$1" "$log"; then
			return 0
		fi
		n=$((n + 1))
		sleep 0.1
	done
	return 1
}

# check LABEL PATTERN: the log names PATTERN.
check_log() {
	if log_has "$2"; then
		passed=$((passed + 1))
		echo "ok: $1"
	else
		echo "FAIL: $1 (the log has no [$2]); the server printed:"
		sed 's/^/      /' "$log" 2>/dev/null || true
		failed=$((failed + 1))
	fi
}

# The first entry of the header is the visitor; the later ones are proxies the request passed through.
get_forwarded "/ping?via=chain" "203.0.113.9, 10.0.0.1"
[ "$status" = 200 ] || fail "GET /ping with X-Forwarded-For answered $status, wanted 200"
check_log "X-Forwarded-For: 203.0.113.9, 10.0.0.1 -> the log names client=203.0.113.9" 'uri=/ping?via=chain client=203\.0\.113\.9'

# A single entry is taken as it is.
get_forwarded "/ping?via=single" "198.51.100.7"
check_log "X-Forwarded-For: 198.51.100.7 -> the log names client=198.51.100.7" 'uri=/ping?via=single client=198\.51\.100\.7'

# With no header the client is the peer that connected, which here is this script on the loopback.
get "/ping?via=none"
[ "$status" = 200 ] || fail "GET /ping answered $status, wanted 200"
check_log "no X-Forwarded-For -> the log names the peer, client=127.0.0.1" 'uri=/ping?via=none client=127\.0\.0\.1'

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: the trace log names the first X-Forwarded-For entry, and the peer when the header is absent"
