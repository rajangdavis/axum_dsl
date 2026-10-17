#!/bin/sh
# L5 end to end for the axum service the DSL generates from examples/hatches.axum.rb, the example that
# carries every escape hatch: injected Rust (rust_crate, rust_item, rust_fn), a hand-written module
# (rust_file), subprocesses (cmd_fn, script_fn) and a file read on each call (file). Start it, speak HTTP
# to it, and assert the value each hatch computes. The subprocess routes also get values built to break a
# shell ($HOME, a `;`), because the generated service passes them as argv or stdin and never as shell
# text. Exit zero only when every check passed. Needs curl or ruby; the `ruby` script_fn is checked only
# where a ruby runs under the service's reduced environment (PATH alone).
# usage: sh test/e2e_hatches.sh [CRATE_DIR]      (default /tmp/axum_dsl_hatches-out)
# Build the crate first:  ruby exe/axum_dsl build examples/hatches.axum.rb -o /tmp/axum_dsl_hatches-out
set -eu

dir=${1:-/tmp/axum_dsl_hatches-out}
host=127.0.0.1
port=8083        # examples/hatches.axum.rb: `set :port, 8083`
name=hatches  # examples/hatches.axum.rb: `server "hatches"` names the crate, so names this binary
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

fixture="$repo/examples/hatches/motd.txt"
[ -f "$fixture" ] || fail "$fixture is missing"

# The copy rules, before any HTTP: rust_crate reaches the manifest, and rust_file lands in the crate as
# src/shout.rs byte for byte.
grep -q '^heck = "0.5"' "$dir/Cargo.toml" || fail "$dir/Cargo.toml has no heck = \"0.5\" line: rust_crate did not reach the manifest"
[ -f "$dir/src/shout.rs" ] || fail "$dir/src/shout.rs is missing: rust_file did not copy the module into the crate"
cmp -s "$dir/src/shout.rs" "$repo/examples/rust/shout.rs" || fail "$dir/src/shout.rs differs from examples/rust/shout.rs"
# `file` is copied into the crate at its declared path; the service reads it from its working directory.
[ -f "$dir/hatches/motd.txt" ] || fail "$dir/hatches/motd.txt is missing: file did not copy the source into the crate"
cmp -s "$dir/hatches/motd.txt" "$fixture" || fail "$dir/hatches/motd.txt differs from examples/hatches/motd.txt"

# --- how this script speaks HTTP and probes the port ------------------------------------------
# curl is the house tool; ruby is the fallback, and the one HTTP client make has certainly just
# installed, since it has run `ruby exe/axum_dsl build`.
if ! has curl && ! has ruby; then
	fail "e2e_hatches.sh speaks HTTP with curl or ruby, and neither is on PATH"
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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_hatches.XXXXXX") || exit 1
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
	echo "      examples/hatches.axum.rb fixes the port with \`set :port, 8083\`, and this test has no other."
	echo "      Nothing was started by this test. Stop what holds $host:$port and run it again."
	exit 1
fi

: >"$log"
if has setsid; then
	( cd "$dir" && exec setsid "$bin" ) >"$log" 2>&1 &
else
	( cd "$dir" && exec "$bin" ) >"$log" 2>&1 &
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

# rust_crate "heck" + rust_item (fn to_snake, fn twice) + rust_fn
want_body "rust_item: to_snake" "/snake?value=HelloWorld%20fooBar" 200 "hello_world_foo_bar"
want_body "rust_item: twice (i32)" "/twice?n=21" 200 "42"
want_body "rust_item: twice of a negative" "/twice?n=-4" 200 "-8"
want_error "rust_item: n is not an integer" "/twice?n=x" 400

# rust_file "rust/shout.rs", as: :shout, and rust_fn ... from: :shout
want_body "rust_file: loud" "/loud?value=hey" 200 "HEY!"
want_body "rust_file: first_word is Some" "/first?value=%20%20alpha%20beta" 200 "alpha"
want_body "rust_file: first_word is None, so the body's fallback" "/first?value=%20%20%20" 200 "none"

# cmd_fn :bracket_argv (printf "[%s]" with the value as one argv entry)
want_body "cmd_fn argv: plain" "/bracket?value=hey" 200 "[hey]"
want_body "cmd_fn argv: a % in the value is data, not a printf format" "/bracket?value=100%25%20sure" 200 "[100% sure]"
want_body "cmd_fn argv: no shell sees the value" "/bracket?value=%3Becho%20pwned" 200 "[;echo pwned]"
want_body "cmd_fn argv: \$HOME stays literal" "/bracket?value=%24HOME" 200 '[$HOME]'

# cmd_fn :upcase_stdin (tr a-z A-Z, the value on stdin)
want_body "cmd_fn stdin: tr" "/upcase?value=hello%20world" 200 "HELLO WORLD"
want_body "cmd_fn stdin: a leading dash is data" "/upcase?value=-n%20abc" 200 "-N ABC"

# script_fn :wc_words (sh -c CODE _ VALUE: the value is $1)
want_body "script_fn sh: three words" "/words?value=one%20two%20%20three" 200 "3"
want_body "script_fn sh: \$HOME is one word and is not expanded" "/words?value=%24HOME" 200 "1"
want_body "script_fn sh: no words" "/words?value=" 200 "0"

# script_fn :reverse_ruby (ruby -e CODE VALUE), where a ruby starts under a PATH-only environment
if has ruby && env -i PATH="$PATH" ruby -e 'print 1' >/dev/null 2>&1; then
	want_body "script_fn ruby: reverse" "/reverse?value=abc" 200 "cba"
else
	echo "skip: GET /reverse (no ruby starts with PATH alone, which is all the service passes on)"
fi

# file "hatches/motd.txt", as: :motd, read with file_text on each call. The fixture ends in a newline;
# the comparison ignores trailing newlines, so an editor that drops it does not fail the check.
get "/motd"
if [ "$status" = "200" ] && [ "$(cat "$body")" = "$(cat "$fixture")" ] && [ -n "$(cat "$body")" ]; then
	passed=$((passed + 1))
	echo "ok: GET /motd -> 200 [$(cat "$body")]"
else
	echo "FAIL: GET /motd -> HTTP $status, wanted the text of examples/hatches/motd.txt"
	echo "      wanted: [$(cat "$fixture")]"
	echo "      got:    [$(cat "$body")]"
	failed=$((failed + 1))
fi

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
echo "OK: $passed checks passed: rust_item and rust_file functions answer (including an Option and an i32), cmd_fn and script_fn pass values as argv or stdin without a shell, file_text reads the file, and the manifest and src/shout.rs carry rust_crate and rust_file"
