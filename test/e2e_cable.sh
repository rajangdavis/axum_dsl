#!/bin/sh
# L5 end to end for the Action Cable broadcasts of the service the DSL generates from examples/cable.axum.rb: start it,
# then test/cable_broadcast_check.mjs opens two real WebSocket clients (alice and bob, each with the signed `who`
# cookie the service hands out) and checks, frame by frame, that a broadcast from a route, from a channel's
# `perform` and from its lifecycle callbacks reaches exactly the subscribers on that broadcasting name as Rails'
# frame (`{"identifier":"...","message":...}`, JSON object keys in the order written, a Turbo tag as an escaped JSON
# string), that an unsubscribe and a closed socket leave the streams, and that a connection without the cookie is
# told `unauthorized`. Exit zero only when every check passed. Needs node (the check is JavaScript) and curl.
# usage: sh test/e2e_cable.sh [CRATE_DIR]      (default /tmp/axum_dsl_cable-out)
# Build the crate first:  ruby exe/axum_dsl build examples/cable.axum.rb -o /tmp/axum_dsl_cable-out
set -eu

dir=${1:-/tmp/axum_dsl_cable-out}
here=$(cd "$(dirname "$0")" && pwd)
host=127.0.0.1
port=8105        # examples/cable.axum.rb: `set :port, 8105`
name=cable       # examples/cable.axum.rb: `server "cable"` names the crate, so names this binary
base="http://$host:$port"
key=0123456789abcdef0123456789abcdef0123456789

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_cable.sh waits for the service with curl, which is not on PATH"
if ! has node; then
	echo "SKIP: node is not on PATH, and the WebSocket clients of test/cable_broadcast_check.mjs are JavaScript"
	exit 0
fi

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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_cable.XXXXXX") || exit 1
log="$work/server.log"
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
listening() { curl -s -o /dev/null --max-time 2 "$base/stream_name" 2>/dev/null; }

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/cable.axum.rb fixes the port with \`set :port, 8105\`, and this test has no other."
	exit 1
fi

SECRET_KEY_BASE="$key" setsid "$bin" >>"$log" 2>&1 &
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

if node "$here/cable_broadcast_check.mjs" "$base"; then
	echo "OK: Action Cable frames reach exactly the subscribers of the broadcasting name, byte for byte, and leave with an unsubscribe or a closed socket"
else
	echo "      server log:"
	sed 's/^/      /' "$log" 2>/dev/null || true
	fail "the Action Cable broadcast checks failed"
fi
