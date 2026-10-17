#!/bin/sh
# L5 end to end for the view-rendering service the DSL generates from examples/views.axum.rb: start the
# built binary, speak HTTP to it, and check the whole view surface -- a page rendered inside the layout, a
# partial (views/form_field.html) inlined for the form's two fields with different arguments, the `{% raw %}`
# region copied byte for byte from views/layout.html, an escaped marker, an unescaped (`|raw`) one, the two
# `render` options the example uses (`layout: nil` and `layout: :other`), a `{% if %}`/`{% else %}` true in
# one request and false in the other, a sanitised Action Text body whose markup is kept and whose script and
# `javascript:` URL are not, and the rule that separates a view from `static`: no `.html` file is copied into
# the crate, the view's text is compiled into src/main.rs.
# Exit zero only when every check passed. Needs curl (or ruby).
#
# The service is started from this directory rather than the crate's, because nothing is read at run time:
# unlike examples/assets.axum.rb there is no copied file behind it, which is the last check below.
#
# usage: sh test/e2e_views.sh [CRATE_DIR]      (default /tmp/axum_dsl_views-out)
# Build the crate first:  ruby exe/axum_dsl build examples/views.axum.rb -o /tmp/axum_dsl_views-out
set -eu

dir=${1:-/tmp/axum_dsl_views-out}
host=127.0.0.1
port=8091     # examples/views.axum.rb: `set :port, 8091`
name=views    # examples/views.axum.rb: `server "views"` names the crate, so names this binary
base="http://$host:$port"
repo=$(dirname "$0")/..
layout="$repo/examples/views/layout.html"

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
	fail "e2e_views.sh speaks HTTP with curl or ruby, and neither is on PATH"
fi
if has curl; then
	# GET "$1" into $body, the response headers into $headers; $status is the code.
	get() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' "$base$1" 2>"$err") || status=000
	}
	# POST the urlencoded body $2 to "$1".
	post_form() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' \
			-H 'Content-Type: application/x-www-form-urlencoded' --data "$2" "$base$1" 2>"$err") || status=000
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
	post_form() {
		status=$(ruby -rnet/http -ruri -e '
			u = URI(ARGV[0])
			req = Net::HTTP::Post.new(u.request_uri)
			req["Content-Type"] = "application/x-www-form-urlencoded"
			req["Accept-Encoding"] = "identity"
			req.body = ARGV[2]
			res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
			File.binwrite(ARGV[1], res.body.to_s)
			File.open(ARGV[3], "w") { |f| res.each_header { |k, v| f.puts "#{k}: #{v}" } }
			print res.code
		' "$base$1" "$body" "$2" "$headers" 2>"$err") || status=000
	}
	listening() {
		ruby -rsocket -e 'begin; TCPSocket.new(ARGV[0], ARGV[1].to_i).close; rescue SystemCallError, IOError; exit 1; end' "$host" "$port" 2>/dev/null
	}
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_views.XXXXXX") || exit 1
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
	echo "      examples/views.axum.rb fixes the port with \`set :port, 8091\`, and this test has no other."
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
# want_get LABEL PATH STATUS: a GET with that status; the body stays in $body for has/hasnt.
want_get() {
	get "$2"
	if [ "$status" = "$3" ]; then ok "$1"; else no "$2 -> $status, wanted $3"; fi
}
# want_post LABEL PATH DATA STATUS: a form POST with that status.
want_post() {
	post_form "$2" "$3"
	if [ "$status" = "$4" ]; then ok "$1"; else no "POST $2 with [$3] -> $status, wanted $4"; fi
}
# holds LABEL TEXT / hasnt LABEL TEXT
holds() { if has "$2"; then ok "$1"; else no "$1: the body holds no [$2]"; fi; }
hasnt() { if has "$2"; then no "$1: the body holds [$2], which it must not"; else ok "$1"; fi; }
# want_ctype LABEL PATH TYPE: the Content-Type header is TYPE, or TYPE with a parameter such as a charset.
want_ctype() {
	get "$2"
	ct=$(grep -i '^content-type:' "$headers" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
	base_ct=$(printf '%s' "$ct" | sed 's/;.*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')
	want=$(printf '%s' "$3" | tr 'A-Z' 'a-z')
	if [ "$base_ct" = "$want" ]; then ok "$1"; else no "$2 -> content-type [$ct], wanted [$3]"; fi
}

# --- GET /signup: the form, rendered inside the layout ------------------------------------------
# The form's two fields are views/form_field.html, inlined by `{{ partial :form_field, ... }}` twice with different
# arguments. `id="name" name="name"` is the partial's own `{{ field }}` (the string the call passed) while
# `value=""` is the caller's `name` local: both scopes are exercised in one render, and the partial's
# markers plainly do not read the caller's locals, or the ids would be empty too.
want_get "the signup form is answered" "/signup" 200
holds "the page is the layout (it opens with a doctype)" "<!doctype html>"
holds "the layout's {{ title }} local is rendered" "<title>Sign up</title>"
holds "the form posts to its own route" 'action="/signup"'
holds "the name field is the partial's markup" '<label for="name">Name</label>'
holds "the email field is the same partial with different arguments" '<label for="email">Email</label>'
holds "the partial's {{ field }} is the call's argument, not the caller's local" 'id="name" name="name"'
holds "and the second call passes a different name" 'id="email" name="email"'
holds "the caller's name local reaches the partial as its value" 'value=""'
holds "the partial renders its own error slot" '<p class="error"></p>'
holds "an omitted partial argument takes its {% args %} default" '<small class="hint">Required</small>'
holds "a passed partial argument overrides the default" '<small class="hint">Never shared</small>'
want_ctype "a rendered page is text/html" "/signup" "text/html"

# --- the `{% raw %}` region: the view file's own bytes, minus its markers ------------------------
# The region between `{% raw %}` and `{% endraw %}` is copied byte for byte, so the response holds it
# contiguously: the comparison strips the newlines from both so a multi-line region can be one `case` match
# (a line-oriented grep cannot ask for a block). The delimiters themselves must not be served, and the
# literal `{{ client_side }}` in the region is the proof that nothing evaluated it -- it would have been a
# marker, and an unknown local at that.
region=$(sed -n '/{% raw %}/,/{% endraw %}/p' "$layout" | sed '1d;$d')
[ -n "$region" ] || fail "no {% raw %} region in $layout; this test reads one out of it"
region_flat=$(printf '%s' "$region" | tr '\n' '\001')
body_flat=$(tr '\n' '\001' <"$body")
case "$body_flat" in
*"$region_flat"*) ok "the {% raw %} region arrives byte for byte" ;;
*) no "the body does not hold the {% raw %} region of $layout contiguously" ;;
esac
holds "the raw region's script fragment" '<script id="client-template" type="text/x-template">'
holds "a marker inside the raw region is served as text" '{{ client_side }}'
hasnt "the raw region's delimiters are not served" '{% raw %}'
hasnt "and neither is its end" '{% endraw %}'

# --- POST /signup: a good signup is the thanks page inside the layout ---------------------------
want_post "a good signup is answered" "/signup" "name=Ada&email=ada%40example.com" 200
holds "the thanks page reads the name" "<h1>Thanks, Ada</h1>"
holds "and writes the route's receipt fragment unescaped (|raw)" "<p>Confirmation sent to <code>ada@example.com</code>.</p>"
holds "the thanks page is inside the layout" "<!doctype html>"
hasnt "the thanks page is not the form" 'name="name"'

# --- POST /signup: a marker escapes, and `|raw` does not ----------------------------------------
# `<script>` is 8 characters, so it passes max_length: 8 and the body runs. The name is a marker value, so
# it comes back escaped; the address is escaped by h(...) in the route as the receipt is built, and the
# page writes that fragment with `|raw`, so the fragment's own tags are served as markup while the value
# inside them is text. Both halves are asserted: the escaped one and the unescaped one.
want_post "a tag-shaped signup is answered" "/signup" "name=%3Cscript%3E&email=%3Ci%3Ex%3C%2Fi%3E" 200
holds "the name marker escaped the tag" "&lt;script&gt;"
hasnt "and no raw <script> came back" "<script>"
holds "h(...) escaped the address inside the receipt" "&lt;i&gt;x&lt;/i&gt;"
holds "the |raw fragment's own tags are markup" "<p>Confirmation sent to <code>"
hasnt "the |raw fragment was not escaped" "&lt;p&gt;Confirmation"

# --- POST /signup: a broken constraint re-renders the form with the check()'s message -------------
# name=x breaks min_length: 3, so the generated check() reports it and the body reads the message with
# errors[:name]; the route sets no status, so the response keeps the 400 the check() always answered with
# (emit.rb: response_expr), and the form comes back with the value the visitor typed.
want_post "a bad signup is refused" "/signup" "name=x&email=ada%40example.com" 400
holds "the form is re-rendered" 'action="/signup"'
holds "with the value that was sent" 'value="x"'
holds "the partial still passes its own argument as the id, not the caller's local" 'id="name" name="name"'
holds "and the check()'s own message" "error: invalid value for name: it has 1 characters, fewer than the minimum of 3"
holds "inside the layout" "<!doctype html>"

# --- the partial escapes its value: a name longer than max_length: 8 fails the check, so the form is
# re-rendered with the value inside the partial's value attribute, escaped by the partial's own marker, while
# the id stays the literal string the call passed. One input, both rules of the partial at once.
want_post "a long tag-shaped name re-renders the form" "/signup" "name=%3Cscript%3Ex%3C%2Fscript%3E&email=ada%40example.com" 400
holds "the caller's value is escaped inside the partial" 'value="&lt;script&gt;x&lt;/script&gt;"'
holds "while the partial's id is its literal argument, in one input" 'id="name" name="name" value="&lt;script&gt;x&lt;/script&gt;"'

# --- layout: nil and layout: :other -------------------------------------------------------------
want_get "the fragment route is answered" "/signup/fragment" 200
holds "it renders its own view" '<p class="fragment">Hello .</p>'
hasnt "and no layout wrapped it" "<!doctype html>"
hasnt "so it has no title either" "<title>"
want_get "the second layout's route is answered" "/signup/plain" 200
holds "the second layout wrapped the page" '<div class="plain">'
holds "and the page itself is the form" 'action="/signup"'
hasnt "the default layout did not wrap it" "<!doctype html>"

# --- `{% if %}`: one branch's markup is served, the other is not ---------------------------------
# The route computes `show` from ?show=1 and passes it as a bool local; data-show echoes that local in the
# same response, so the two requests differ only in the condition's value, which is asserted first.
want_get "the greeting with a true condition is answered" "/greeting?show=1" 200
holds "the condition's value is the one the route computed" 'data-show="true"'
holds "the taken branch's markup is served" '<p class="shown">The condition held.</p>'
hasnt "the branch not taken is not served" 'The condition did not hold.'
want_get "the greeting with a false condition is answered" "/greeting" 200
holds "the condition's value is the other" 'data-show="false"'
holds "the other branch's markup is served" '<p class="hidden">The condition did not hold.</p>'
hasnt "the true branch is not served" 'The condition held.'

# --- `{{ content|sanitize }}`: HTML text is cleaned, not escaped ---------------------------------
# The route passes an Action Text body as a string; the view sanitises it. Ammonia's default allowlist keeps
# the strong element's markup and drops the script element and the javascript: URL. That the strong tag is
# markup (not &lt;strong&gt;) also shows |sanitize is not the escaper.
want_get "the sanitised body page is answered" "/sanitize" 200
holds "the sanitised body keeps the strong markup" '<strong>there</strong>'
hasnt "the script element is gone" '<script'
hasnt "the javascript: href is gone" 'javascript:'
hasnt "the body was sanitised, not escaped" '&lt;strong&gt;'

# --- the rule that separates a view from static --------------------------------------------------
# A view is read at compile time, so nothing is copied into the crate and the running service reads no
# file: the crate has no views/ directory, and the view's text (with its braces doubled, because format!
# reads them) is in the emitted Rust.
if [ -d "$dir/views" ]; then
	no "$dir/views exists: a view is compiled into the Rust, not copied beside the crate"
else
	ok "the crate carries no views/ directory"
fi
if grep -F -q '{{{{ client_side }}}}' "$dir/src/main.rs"; then
	ok "the view's text is in the emitted Rust, with format!'s braces doubled"
else
	no "src/main.rs holds no doubled-brace copy of the raw region, so a view was not compiled in"
fi

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: the form and the thanks page render inside views/layout.html, the form's two fields come from views/form_field.html with their own arguments (and only those), a bad POST re-renders the form with the check()'s message, a marker escapes a tag-shaped name while |raw writes the route's fragment as markup, the {% raw %} region is served byte for byte, layout: nil and layout: :other both work, a {% if %}/{% else %} serves one branch and not the other, {{ content|sanitize }} keeps an Action Text body's markup and drops its script and javascript: URL, and no .html file was copied into the crate"
