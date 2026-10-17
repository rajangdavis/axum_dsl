#!/bin/sh
# L5 end to end for the axum service the DSL generates from examples/tls.axum.rb: its `set :listener` is
# a TLS listener written in Rust (examples/rust/tls_listener.rs, tokio-rustls), so start it with a
# throwaway self-signed certificate and check that HTTPS answers, that plain HTTP on the same port does
# not, and that the request log (plain `use_layer :trace`) names the request. Exit zero only when every
# check passed. Needs curl and openssl; without openssl it prints a skip note and exits zero.
# usage: sh test/e2e_tls.sh [CRATE_DIR]      (default /tmp/axum_dsl_tls-out)
# Build the crate first:  ruby exe/axum_dsl build examples/tls.axum.rb -o /tmp/axum_dsl_tls-out
set -eu

dir=${1:-/tmp/axum_dsl_tls-out}
host=127.0.0.1
port=8098       # examples/tls.axum.rb: `set :port, 8098` (add 8080, views 8091, validate 8093, proxy 8095, assets 8097)
name=tls        # examples/tls.axum.rb: `server "tls"` names the crate, so names this binary
secure="https://$host:$port"
plain="http://$host:$port"

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

if ! has openssl; then
	echo "SKIP: e2e_tls.sh needs openssl to make a self-signed certificate, and it is not on PATH; nothing was run."
	exit 0
fi
has curl || fail "e2e_tls.sh speaks HTTPS with curl, and it is not on PATH"

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

# --- how this script speaks HTTP(S) and probes the port ----------------------------------------
# -k: the certificate is self-signed, so it is not verified; the point is that TLS is spoken.
# GET "$1" over TLS into $body; $status is the code.
get() {
	status=$(curl -sSk --max-time 10 -o "$body" -w '%{http_code}' "$secure$1" 2>"$err") || status=000
}
# GET "$1" over plain HTTP; $status is the code, 000 when the server never answered in HTTP.
get_plain() {
	status=$(curl -s --max-time 5 -o "$body" -w '%{http_code}' "$plain$1" 2>"$err") || status=000
}
# Is a server accepting TLS on $host:$port? A refused connection or a failed handshake exits non-zero.
listening() {
	curl -sk -o /dev/null --max-time 2 "$secure/" 2>/dev/null
}
# Is anything accepting TCP connections on $host:$port, TLS or not? curl exits 52 (empty reply) or 35
# (handshake) for a server that is there but not speaking plain HTTP, and 7 for a refused connection.
occupied() {
	curl -s -o /dev/null --max-time 2 "$plain/" 2>/dev/null
	[ "$?" -ne 7 ]
}

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_tls.XXXXXX") || exit 1
body="$work/body"
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
if occupied; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/tls.axum.rb fixes the port with \`set :port, 8098\`, and this test has no other."
	echo "      Nothing was started by this test. Stop what holds $host:$port and run it again."
	exit 1
fi

# --- a throwaway certificate: the listener reads TLS_CERT and TLS_KEY ---------------------------
cert="$work/cert.pem"
key="$work/key.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
	-addext "subjectAltName=DNS:localhost,IP:$host" -keyout "$key" -out "$cert" >"$work/openssl.log" 2>&1 ||
	fail "openssl could not make a self-signed certificate: $(cat "$work/openssl.log")"

: >"$log"
if has setsid; then
	TLS_CERT=$cert TLS_KEY=$key setsid "$bin" >"$log" 2>&1 &
else
	TLS_CERT=$cert TLS_KEY=$key "$bin" >"$log" 2>&1 &
fi
pid=$!

# Wait for the port instead of sleeping and hoping. A server that died on the way up is reported
# with its own output, which is where a missing certificate or a failed bind says what it was.
i=0
until listening; do
	i=$((i + 1))
	if [ "$i" -gt 100 ]; then
		echo "FAIL: $host:$port did not answer TLS within 10 s"
		sed 's/^/      /' "$log" 2>/dev/null || true
		exit 1
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "FAIL: $bin exited before it answered TLS on $host:$port"
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

get "/ping"
if [ "$status" = 200 ] && [ "$(cat "$body")" = "pong" ]; then
	passed=$((passed + 1))
	echo "ok: GET https://$host:$port/ping -> 200 [pong]"
else
	echo "FAIL: GET https://$host:$port/ping -> HTTP $status, wanted 200 [pong]; body: [$(cat "$body")]; curl said: [$(cat "$err")]"
	failed=$((failed + 1))
fi

# The listener serves TLS only, so a plain HTTP request to the same port never gets an HTTP answer.
get_plain "/ping"
if [ "$status" = 000 ]; then
	passed=$((passed + 1))
	echo "ok: GET http://$host:$port/ping -> no HTTP answer (the port speaks TLS only)"
else
	echo "FAIL: GET http://$host:$port/ping -> HTTP $status; the port should answer TLS only"
	failed=$((failed + 1))
fi

# Plain `use_layer :trace` installs a subscriber, so the request is in the server's own output.
if log_has 'uri=/ping'; then
	passed=$((passed + 1))
	echo "ok: the log names the request (uri=/ping)"
else
	echo "FAIL: the log has no [uri=/ping]; the server printed:"
	sed 's/^/      /' "$log" 2>/dev/null || true
	failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: the service answers HTTPS through the Rust TLS listener, plain HTTP gets no answer, and the request is logged"
