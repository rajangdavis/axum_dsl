#!/bin/sh
# L5 end to end for the locales service the DSL generates from examples/locales.axum.rb: start the built binary,
# speak HTTP to it, and check Rails-style i18n over the wire -- the default locale (English) with no parameter, the
# interpolated `%{name}`, `?locale=es` for the Spanish texts, the English fallback for a key only `en` holds, an
# unknown or empty `locale` answered in the default, `t("health.ok")` in a route body in both locales, and an
# interpolated value with HTML characters escaped by the view.
# Exit zero only when every check passed. Needs curl (or ruby).
#
# usage: sh test/e2e_locales.sh [CRATE_DIR]      (default /tmp/axum_dsl_locales-out)
# Build the crate first:  ruby exe/axum_dsl build examples/locales.axum.rb -o /tmp/axum_dsl_locales-out
set -eu

dir=${1:-/tmp/axum_dsl_locales-out}
host=127.0.0.1
port=8088       # examples/locales.axum.rb: `set :port, 8088`
name=locales    # examples/locales.axum.rb: `server "locales"` names the crate, so names this binary
base="http://$host:$port"

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

# --- how this script speaks HTTP and probes the port ------------------------------------------
if ! has curl && ! has ruby; then
	fail "e2e_locales.sh speaks HTTP with curl or ruby, and neither is on PATH"
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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_locales.XXXXXX") || exit 1
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
	echo "      examples/locales.axum.rb fixes the port with \`set :port, 8088\`, and this test has no other."
	echo "      Nothing was started by this test. Stop what holds $host:$port and run it again."
	exit 1
fi

: >"$log"
if has setsid; then
	exec setsid "$bin" >"$log" 2>&1 &
else
	exec "$bin" >"$log" 2>&1 &
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

# show: the response, which a failing check is nearly always about.
show() {
	echo "      status [$status]"
	echo "      body: [$(cat "$body" 2>/dev/null)]"
	sed 's/^/      /' "$headers" 2>/dev/null || true
}
ok() { passed=$((passed + 1)); echo "ok: $1"; }
no() { failed=$((failed + 1)); echo "FAIL: $1"; show; }
# has TEXT: is TEXT in the response body, byte for byte (-F: no pattern metacharacters)?
has() { grep -F -q -- "$1" "$body"; }
# want_get LABEL PATH STATUS: a GET with that status; the body stays in $body for holds/hasnt.
want_get() {
	get "$2"
	if [ "$status" = "$3" ]; then ok "$1"; else no "$2 -> $status, wanted $3"; fi
}
holds() { if has "$2"; then ok "$1"; else no "$1: the body holds no [$2]"; fi; }
hasnt() { if has "$2"; then no "$1: the body holds [$2], which it must not"; else ok "$1"; fi; }

# --- GET /bots: no locale parameter is the default locale, English -------------------------------
want_get "the bots page is answered" "/bots" 200
holds "the lazy key .title is bots.index.title, in English" "<h1>Chat bots</h1>"
holds "%{name} is filled with the route's local (its default here)" "<p>Welcome, friend!</p>"
holds "the key only en holds is served" "Bots can post to any room."

want_get "the bots page answers a visitor's name" "/bots?name=Ada" 200
holds "the interpolated name is in the English text" "<p>Welcome, Ada!</p>"

# --- ?locale=es: the Spanish texts, and the English fallback for a key es lacks -------------------
want_get "the Spanish bots page is answered" "/bots?locale=es" 200
holds "the title is Spanish" "<h1>Bots de chat</h1>"
holds "the interpolated text is Spanish" "<p>Bienvenido, friend!</p>"
holds "a key only en holds falls back to the English text" "Bots can post to any room."
hasnt "and the English title is not served" "Chat bots"

want_get "the locale and another parameter together" "/bots?name=Ada&locale=es" 200
holds "the Spanish text takes the name too" "<p>Bienvenido, Ada!</p>"

# --- a locale no file holds, and an empty one, are the default ------------------------------------
want_get "an unknown locale is answered" "/bots?locale=xx" 200
holds "an unknown locale is served in English" "<h1>Chat bots</h1>"
want_get "an empty locale is answered" "/bots?locale=" 200
holds "an empty locale is served in English" "<h1>Chat bots</h1>"

# --- t(...) in a route body: the same locale, bound once per request ------------------------------
want_get "the route-body t in English" "/health" 200
holds "the English text" "All good"
want_get "the route-body t in Spanish" "/health?locale=es" 200
holds "the Spanish text" "Todo bien"
want_get "the route-body t with an unknown locale" "/health?locale=xx" 200
holds "serves the default" "All good"

# --- an interpolated value is escaped by the view -------------------------------------------------
want_get "a tag-shaped name is answered" "/bots?name=%3Cb%3Ex%3C%2Fb%3E" 200
holds "the view escaped the interpolated value" "<p>Welcome, &lt;b&gt;x&lt;/b&gt;!</p>"
hasnt "and no raw tag came back" "<b>x</b>"

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: the default locale and ?locale=es pick the English and Spanish texts, %{name} is interpolated and escaped, a key only en holds falls back to English under es, an unknown or empty locale is the default, and a route body's t reads the same locale"
