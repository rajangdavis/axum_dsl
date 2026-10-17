#!/bin/sh
# L5 end to end for the file-serving service the DSL generates from examples/assets.axum.rb: start the
# built binary WITH THE CRATE DIRECTORY AS ITS WORKING DIRECTORY, then assert over HTTP that a `static`
# mount serves each file type with the right content type, that a missing file and a path-traversal
# attempt answer an empty 404, that `serve_file` answers its route, that a route's `headers(...)` reach
# the response, and that `static ... digest: true` serves the fingerprinted name and not the undigested one.
# Exit zero only when every check passed. Needs curl, and ruby for the digest the fingerprint is derived from.
#
# The working directory is the point of the run: a declared asset (the `static` directory, the
# `serve_file` file) is copied into the emitted crate at its own relative path, and the emitted
# ServeDir::new("public") / ServeFile::new("public/report.txt") resolve against the process's working
# directory. Started from anywhere else, every file below would be a 404.
#
# usage: sh test/e2e_assets.sh [CRATE_DIR]      (default /tmp/axum_dsl_assets-out)
# Build the crate first:  ruby exe/axum_dsl build examples/assets.axum.rb -o /tmp/axum_dsl_assets-out
set -eu

dir=${1:-/tmp/axum_dsl_assets-out}
host=127.0.0.1
port=8097      # examples/assets.axum.rb: `set :port, 8097`
name=assets    # examples/assets.axum.rb: `server "assets"` names the crate, so names this binary
base="http://$host:$port"
# The fixture the crate copy is compared with, read from the tree this script lives in.
repo=$(dirname "$0")/..
fixture="$repo/examples/public/index.html"
fixture2="$repo/examples/public/report.txt"

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# make shares one cargo target dir (CARGO_TARGET_DIR), so the binary is there, or else inside the crate.
bin=
for candidate in "${CARGO_TARGET_DIR:-$dir/target}/debug/$name" "$dir/target/debug/$name"; do
	if [ -x "$candidate" ]; then
		bin=$candidate
		break
	fi
done
[ -n "$bin" ] || fail "no $name binary under ${CARGO_TARGET_DIR:-$dir/target}/debug or $dir/target/debug"

# The copy rule, before any HTTP: a declared asset is in the crate at its own relative path.
[ -f "$dir/public/index.html" ] || fail "$dir/public/index.html is missing: the static directory was not copied into the crate"
[ -f "$dir/public/report.txt" ] || fail "$dir/public/report.txt is missing: the serve_file file was not copied into the crate"

# --- how this script speaks HTTP and probes the port ------------------------------------------
if has curl; then
	# GET "$1" into $body, the response headers into $headers; $status is the code.
	get() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' "$base$1" 2>"$err") || status=000
	}
	# get_raw sends the path unchanged. Without --path-as-is curl squashes `..` in the URL itself, so the
	# traversal check below would probe a different path and pass while proving nothing.
	get_raw() {
		status=$(curl -sS --path-as-is --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' "$base$1" 2>"$err") || status=000
	}
	# Is a server answering on $host:$port? A refused connection exits non-zero.
	listening() {
		curl -s -o /dev/null --max-time 2 "$base/" 2>/dev/null
	}
else
	if ! has ruby; then
		fail "e2e_assets.sh speaks HTTP with curl or ruby, and neither is on PATH"
	fi
	# Net::HTTP sends the request target as given, `..` included, so get and get_raw are the same here.
	get() {
		status=$(ruby -rnet/http -ruri -e '
			u = URI(ARGV[0])
			req = Net::HTTP::Get.new(ARGV[1])
			req["Accept-Encoding"] = "identity"
			res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
			File.binwrite(ARGV[2], res.body.to_s)
			File.open(ARGV[3], "w") { |f| res.each_header { |k, v| f.puts "#{k}: #{v}" } }
			print res.code
		' "$base" "$1" "$body" "$headers" 2>"$err") || status=000
	}
	get_raw() {
		get "$1"
	}
	listening() {
		ruby -rsocket -e 'begin; TCPSocket.new(ARGV[0], ARGV[1].to_i).close; rescue SystemCallError, IOError; exit 1; end' "$host" "$port" 2>/dev/null
	}
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_assets.XXXXXX") || exit 1
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
# Every way out -- a failed check, a signal -- kills the server, so it never holds the port for the next run.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The port belongs to the example, so a server already on it is a fault of the environment and not a
# reason to test somebody else's service.
if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/assets.axum.rb fixes the port with \`set :port, 8097\`, and this test has no other."
	echo "      Nothing was started by this test. Stop what holds $host:$port and run it again."
	exit 1
fi

: >"$log"
# The crate directory is the working directory: that is where the copied assets are, and what a relative
# path in a ServeDir or ServeFile is resolved against. The subshell execs, so $pid is the server's own pid.
if has setsid; then
	( cd "$dir" && exec setsid "$bin" ) >"$log" 2>&1 &
else
	( cd "$dir" && exec "$bin" ) >"$log" 2>&1 &
fi
pid=$!

# Wait for the port instead of sleeping and hoping. A server that died on the way up is reported with its
# own output, which is where a failed bind says what it was.
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

# The body is exactly $2, byte for byte, so a plausible body that differs by one byte fails too.
body_is() {
	printf '%s' "$2" >"$work/want"
	[ "$(cat "$1")" = "$(cat "$work/want")" ] && [ "$(wc -c <"$1")" = "$(wc -c <"$work/want")" ]
}
# The body is exactly the line $2 with a newline after it (every fixture file ends in one).
body_is_line() {
	printf '%s\n' "$2" >"$work/want"
	[ "$(cat "$1")" = "$(cat "$work/want")" ] && [ "$(wc -c <"$1")" = "$(wc -c <"$work/want")" ]
}
# show_headers: the response headers, which a failing check is nearly always about.
show_headers() { sed 's/^/      /' "$headers" 2>/dev/null || true; }

# want_body LABEL PATH STATUS TEXT: that status and exactly that body (no trailing newline).
want_body() {
	get "$2"
	if [ "$status" != "$3" ] || ! body_is "$body" "$4"; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, wanted $3 with body [$4]"
		echo "      got: [$(cat "$body")]"
		show_headers
		failed=$((failed + 1))
		return 0
	fi
	passed=$((passed + 1))
	echo "ok: GET $2 -> $status [$4]"
}

# want_line LABEL PATH STATUS LINE: that status and exactly that line, newline included.
want_line() {
	get "$2"
	if [ "$status" != "$3" ] || ! body_is_line "$body" "$4"; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, wanted $3 with body [$4]"
		echo "      got: [$(cat "$body")]"
		show_headers
		failed=$((failed + 1))
		return 0
	fi
	passed=$((passed + 1))
	echo "ok: GET $2 -> $status [$4]"
}

# want_ctype LABEL PATH TYPE: the Content-Type header is TYPE, or TYPE with a parameter such as a charset.
want_ctype() {
	get "$2"
	ct=$(grep -i '^content-type:' "$headers" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
	# the type before the first parameter: tower-http may answer "text/html; charset=utf-8"
	base_ct=$(printf '%s' "$ct" | sed 's/;.*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')
	want=$(printf '%s' "$3" | tr 'A-Z' 'a-z')
	if [ "$base_ct" = "$want" ]; then
		passed=$((passed + 1))
		echo "ok: GET $2 -> content-type $ct"
	else
		echo "FAIL: $1"
		echo "      GET $2 -> content-type [$ct], wanted [$3]"
		show_headers
		failed=$((failed + 1))
	fi

}

# want_status LABEL PATH STATUS: that status, with an empty body.
want_status() {
	get "$2"
	if [ "$status" != "$3" ] || [ -s "$body" ]; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status with body [$(cat "$body")], wanted $3 with no body"
		show_headers
		failed=$((failed + 1))
		return 0
	fi
	passed=$((passed + 1))
	echo "ok: GET $2 -> $status with no body"
}

# want_header LABEL PATH PATTERN: a header line matches PATTERN (case-insensitive).
want_header() {
	get "$2"
	if grep -qi -- "$3" "$headers" 2>/dev/null; then
		passed=$((passed + 1))
		echo "ok: GET $2 carries $3"
	else
		echo "FAIL: $1"
		echo "      GET $2 did not answer a header matching [$3]"
		show_headers
		failed=$((failed + 1))
	fi
}

# want_no_header LABEL PATH PATTERN: no header line matches PATTERN, so a header a route sets is scoped to
# that route.
want_no_header() {
	get "$2"
	if grep -qi -- "$3" "$headers" 2>/dev/null; then
		echo "FAIL: $1"
		echo "      GET $2 answered a header matching [$3], which belongs to another route"
		show_headers
		failed=$((failed + 1))
	else
		passed=$((passed + 1))
		echo "ok: GET $2 carries no $3"
	fi
}

# --- static "/files", dir: "public" -------------------------------------------------------------
# The body is the fixture's own bytes, so a changed fixture, a truncated copy or a changed path fails here.
# want_file LABEL PATH STATUS FIXTURE: that status and exactly the fixture's own bytes. want_line compares
# one line plus its newline, which cannot describe a multi-line fixture; this compares the file itself.
want_file() {
	get "$2"
	if [ "$status" != "$3" ] || ! { [ "$(cat "$body")" = "$(cat "$4")" ] && [ "$(wc -c <"$body")" = "$(wc -c <"$4")" ]; }; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, wanted $3 with the bytes of $4"
		echo "      got: [$(cat "$body")]"
		show_headers
		failed=$((failed + 1))
		return 0
	fi
	passed=$((passed + 1))
	echo "ok: GET $2 -> $status [$(cat "$4")]"
}
want_file "assets: index.html's own bytes" "/files/index.html" 200 "$fixture"
want_ctype "assets: an html file is text/html" "/files/index.html" "text/html"
want_line "assets: a stylesheet" "/files/style.css" 200 'body { color: #333; }'
want_ctype "assets: a css file is text/css" "/files/style.css" "text/css"
want_line "assets: a json file" "/files/data.json" 200 '{"ok":true,"items":[1,2,3]}'
want_ctype "assets: a json file is application/json" "/files/data.json" "application/json"
want_line "assets: the file serve_file also serves" "/files/report.txt" 200 'served by serve_file from public/report.txt'
# append_index_html_on_directories: a request for the directory itself is its index.html, at the prefix
# its nest_service registered.
want_file "assets: the mount prefix with a trailing slash is index.html" "/files/" 200 "$fixture"
want_status "assets: a missing file is an empty 404" "/files/nope.txt" 404
want_status "a path-traversal attempt is refused" "/files/../Cargo.toml" 404
if grep -q 'package' "$body" 2>/dev/null; then
	echo "FAIL: the traversal request leaked a file outside the mount: [$(cat "$body")]"
	failed=$((failed + 1))
fi

# --- static "/assets", dir: "fingerprints", digest: true ---------------------------------------
# The name is re-derived here from the fixture's own bytes with Ruby's SHA-256 instead of being read from
# the compiler: the rule is `<stem>-<the first 12 hex digits><ext>`, and the bytes come back unchanged.
has ruby || fail "the fingerprint checks compute SHA-256 with ruby, which is not on PATH"
fixture_css="$repo/examples/fingerprints/campfire.css"
digest=$(ruby -rdigest -e 'print Digest::SHA256.hexdigest(File.binread(ARGV[0]))[0, 12]' "$fixture_css") || fail "could not digest $fixture_css"
[ -n "$digest" ] || fail "empty digest for $fixture_css"
want_file "fingerprint: the digested stylesheet" "/assets/campfire-$digest.css" 200 "$fixture_css"
want_ctype "fingerprint: a css file is text/css" "/assets/campfire-$digest.css" "text/css"
want_status "fingerprint: the undigested path is not served" "/assets/campfire.css" 404
# The view helper and the mount name one URL: the page's asset_path is the path fetched above.
get "/fingerprints"
if [ "$status" = 200 ] && grep -q "/assets/campfire-$digest.css" "$body"; then
	passed=$((passed + 1))
	echo "ok: /fingerprints names /assets/campfire-$digest.css"
else
	echo "FAIL: /fingerprints did not name /assets/campfire-$digest.css (HTTP $status)"
	show_headers
	failed=$((failed + 1))
fi

# --- serve_file "/report.txt", from: "public/report.txt" ----------------------------------------
want_line "serve_file: its own route" "/report.txt" 200 'served by serve_file from public/report.txt'
want_ctype "serve_file: a text file is text/plain" "/report.txt" "text/plain"

# --- get "/api/ping" with headers(...) ----------------------------------------------------------
want_body "ping: the route body" "/api/ping" 200 "pong"
want_header "ping: Cache-Control" "/api/ping" "cache-control:[[:space:]]*no-store"
want_header "ping: X-Content-Type-Options" "/api/ping" "x-content-type-options:[[:space:]]*nosniff"
# The headers belong to that route only: the file services answer without them.
want_no_header "the served file has no Cache-Control" "/files/index.html" "cache-control:"

# --- the mount is a mount, not the whole service -------------------------------------------------
want_status "an unrouted path is a 404" "/nope" 404

# --- the copy rule, after the fact ---------------------------------------------------------------
# The crate copy is the bytes the service was serving; the fixture in the tree is what it must be a copy
# of, so a compiler that copied the wrong file (or nothing) fails here as well as above.
if [ -f "$fixture" ] && [ -f "$fixture_css" ]; then
	if [ "$(cat "$dir/public/index.html")" = "$(cat "$fixture")" ] &&
		[ "$(wc -c <"$dir/public/index.html")" = "$(wc -c <"$fixture")" ] &&
		[ "$(cat "$dir/public/report.txt")" = "$(cat "$fixture2")" ] &&
		[ "$(wc -c <"$dir/public/report.txt")" = "$(wc -c <"$fixture2")" ] &&
		[ "$(cat "$dir/fingerprints/campfire-$digest.css")" = "$(cat "$fixture_css")" ] &&
		[ "$(wc -c <"$dir/fingerprints/campfire-$digest.css")" = "$(wc -c <"$fixture_css")" ]; then
		passed=$((passed + 1))
		echo "ok: the assets copied into the crate are the fixture files, byte for byte"
	else
		echo "FAIL: the assets in $dir/public or $dir/fingerprints are not the fixture files"
		failed=$((failed + 1))
	fi
	if [ -e "$dir/fingerprints/campfire.css" ]; then
		echo "FAIL: the digest mount copied the undigested path $dir/fingerprints/campfire.css"
		failed=$((failed + 1))
	else
		passed=$((passed + 1))
		echo "ok: the digest mount copied only the fingerprinted name"
	fi
else
	echo "note: $fixture or $fixture_css is not there, so the copy rule was checked by the responses above only"
fi

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: the /files mount serves html, css, json and txt with the right content type, a missing file and a traversal attempt are an empty 404, serve_file answers /report.txt, /api/ping carries its own headers, and /assets serves the fingerprinted file whose name /fingerprints writes"