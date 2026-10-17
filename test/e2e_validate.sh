#!/bin/sh
# L5 end to end for the axum service the DSL generates from examples/validate.axum.rb: start it, speak
# HTTP to it, and check the one thing that example exists for -- that the compiler's own field
# constraints run. Every field of its params block carries a constraint, so the generated check() (see
# lib/axum_dsl/emit.rb: checked?, check_impl, field_checks) runs before the body and answers 400 with a
# message of its own. axum's extractors reject a malformed query too, but none of their messages says
# "error: invalid value for ...", so the equalities below cannot pass on a build whose check() was never
# called. The query route is answered 400 before its body runs; the form routes that read errors[:name]
# instead (emit.rb: route_fn, check_impl), so a rejected POST runs the body with the check()'s message and
# keeps the 400 unless the body sets status(...). It also drives the form routes (whose answers are HTML
# built with h(params[:name]), so a name that looks like a tag comes back escaped) and the named layers
# the example declares: compression, cors, timeout and trace. Exit zero only when every check passed.
# Needs curl.
# usage: sh test/e2e_validate.sh [CRATE_DIR]      (default /tmp/axum_dsl_validate-out)
# Build the crate first:  ruby exe/axum_dsl build examples/validate.axum.rb -o /tmp/axum_dsl_validate-out
set -eu

dir=${1:-/tmp/axum_dsl_validate-out}
host=127.0.0.1
port=8093       # examples/validate.axum.rb: `set :port, 8093` (add.axum.rb holds 8080, so the two differ)
name=validator  # examples/validate.axum.rb: `server "validator"` names the crate, so names this binary
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
	fail "e2e_validate.sh speaks HTTP with curl or ruby, and neither is on PATH"
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
	# POST the urlencoded body $2 to "$1"; raw bytes into $body, headers into $headers.
	post_form() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' \
			-H 'Content-Type: application/x-www-form-urlencoded' --data "$2" "$base$1" 2>"$err") || status=000
	}
	# The same POST offering gzip; the response bytes in $body stay compressed.
	post_form_gzip() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' \
			-H 'Content-Type: application/x-www-form-urlencoded' -H 'Accept-Encoding: gzip' \
			--data "$2" "$base$1" 2>"$err") || status=000
	}
	# The same POST offering gzip and letting curl decode it, so $body is the plain text.
	post_form_compressed() {
		status=$(curl -sS --compressed --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' \
			-H 'Content-Type: application/x-www-form-urlencoded' --data "$2" "$base$1" 2>"$err") || status=000
	}
	# GET "$1" with an Origin header, into $body and $headers.
	get_origin() {
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' -H "Origin: $2" "$base$1" 2>"$err") || status=000
	}
	# GET "$1" with one more request header, "$2: $3", into $body and $headers.
	get_h() {
		: >"$body" # a 304 has no body, and curl would otherwise leave the last one in place
		status=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' -H "$2: $3" "$base$1" 2>"$err") || status=000
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
	# POST a form body. Mode identity keeps the response as sent; gzip offers gzip and keeps the compressed
	# bytes; decode offers gzip and gunzips them into $body.
	_post_form() {
		status=$(ruby -rnet/http -ruri -rzlib -rstringio -e '
			mode = ARGV[3]
			u = URI(ARGV[0])
			req = Net::HTTP::Post.new(u.request_uri)
			req["Content-Type"] = "application/x-www-form-urlencoded"
			req["Accept-Encoding"] = "gzip" unless mode == "identity"
			req.body = ARGV[2]
			res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
			out = res.body.to_s
			out = Zlib::GzipReader.new(StringIO.new(out)).read if mode == "decode" && res["content-encoding"] == "gzip"
			File.binwrite(ARGV[1], out)
			File.open(ARGV[4], "w") { |f| res.each_header { |k, v| f.puts "#{k}: #{v}" } }
			print res.code
		' "$base$1" "$body" "$2" "$3" "$headers" 2>"$err") || status=000
	}
	post_form() { _post_form "$1" "$2" identity; }
	post_form_gzip() { _post_form "$1" "$2" gzip; }
	post_form_compressed() { _post_form "$1" "$2" decode; }
	get_origin() {
		status=$(ruby -rnet/http -ruri -e '
			u = URI(ARGV[0])
			req = Net::HTTP::Get.new(u.request_uri)
			req["Accept-Encoding"] = "identity"
			req["Origin"] = ARGV[2]
			res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
			File.binwrite(ARGV[1], res.body.to_s)
			File.open(ARGV[3], "w") { |f| res.each_header { |k, v| f.puts "#{k}: #{v}" } }
			print res.code
		' "$base$1" "$body" "$2" "$headers" 2>"$err") || status=000
	}
	get_h() {
		status=$(ruby -rnet/http -ruri -e '
			u = URI(ARGV[0])
			req = Net::HTTP::Get.new(u.request_uri)
			req["Accept-Encoding"] = "identity"
			req[ARGV[2]] = ARGV[3]
			res = Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
			File.binwrite(ARGV[1], res.body.to_s)
			File.open(ARGV[4], "w") { |f| res.each_header { |k, v| f.puts "#{k}: #{v}" } }
			print res.code
		' "$base$1" "$body" "$2" "$3" "$headers" 2>"$err") || status=000
	}
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_validate.XXXXXX") || exit 1
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
	echo "      examples/validate.axum.rb fixes the port with \`set :port, 8093\`, and this test has no other."
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

# want_error LABEL PATH BODY: a 400 whose body is exactly the message the generated check() builds.
# The equality is what makes this test worth running -- axum's own extractor rejection reads
# "Failed to deserialize query string: ...", so a build without the check() call cannot pass -- and
# the case below names which of the two answered when the equality fails.
want_error() {
	get "$2"
	if [ "$status" != "400" ]; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, wanted 400"
		echo "      body: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	if ! body_is "$body" "$3"; then
		echo "FAIL: $1"
		echo "      GET $2 -> HTTP $status, but the body was not the compiler's check() message"
		echo "      wanted: [$3]"
		echo "      got:    [$(cat "$body")]"
		case "$(cat "$body")" in
		*"Failed to deserialize"*) echo "      (that is axum's own extractor rejection, so the generated check() did not run)" ;;
		esac
		failed=$((failed + 1))
		return 0
	fi
	case "$(cat "$body")" in
	"error: invalid value for "*) ;;
	*)
		echo "FAIL: $1"
		echo "      the 400 body does not begin with the compiler's message prefix: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
		;;
	esac
	passed=$((passed + 1))
	echo "ok: GET $2 -> 400 [$3]"
}

# get "/signup", params: :Signup do text("ok: #{params[:name]} #{params[:handle]} #{params[:colour]} #{params[:age]}") end
#   every field is `in: :query` and every field carries a constraint, so this is the request that
#   arrives with all four and passes every check() the compiler generated.
want_body "signup: all four constraints satisfied" \
	"/signup?name=ada&age=36&colour=green&handle=ada_l" 200 "ok: ada ada_l green 36"
if grep -qi '^content-type:.*text/plain' "$headers"; then
	passed=$((passed + 1))
	echo "ok: GET /signup -> content-type is text/plain"
else
	echo "FAIL: GET /signup did not answer text/plain; its headers were:"
	sed 's/^/      /' "$headers" 2>/dev/null || true
	failed=$((failed + 1))
fi

# One request per constraint, each violating exactly one field and leaving the other three valid, so
# the body can only be the message that field's check produces. The formats are emit.rb's field_checks:
#   min_length  "error: invalid value for {}: it has {} characters, fewer than the minimum of {}"
#   max_length  "error: invalid value for {}: it has {} characters, more than the maximum of {}"
#   min         "error: invalid value for {}: {} is below the minimum of {}"
#   max         "error: invalid value for {}: {} is above the maximum of {}"
#   enum        "error: invalid value for {}: {:?} is not one of {}"
#   pattern     "error: invalid value for {}: {:?} does not match the pattern {}"
# ({:?} Debug-prints its argument, so a string arrives quoted.)
want_error "name: 2 characters, under min_length 3" \
	"/signup?name=ab&age=36&colour=green&handle=ada_l" \
	"error: invalid value for name: it has 2 characters, fewer than the minimum of 3"
want_error "name: 11 characters, over max_length 8" \
	"/signup?name=toolongname&age=36&colour=green&handle=ada_l" \
	"error: invalid value for name: it has 11 characters, more than the maximum of 8"
want_error "age: 7, under min 18" \
	"/signup?name=ada&age=7&colour=green&handle=ada_l" \
	"error: invalid value for age: 7 is below the minimum of 18"
want_error "age: 200, over max 120" \
	"/signup?name=ada&age=200&colour=green&handle=ada_l" \
	"error: invalid value for age: 200 is above the maximum of 120"
want_error "colour: purple, not in the enum" \
	"/signup?name=ada&age=36&colour=purple&handle=ada_l" \
	"error: invalid value for colour: \"purple\" is not one of red, green, blue"
want_error "handle: Ada1, which the pattern rejects" \
	"/signup?name=ada&age=36&colour=green&handle=Ada1" \
	"error: invalid value for handle: \"Ada1\" does not match the pattern ^[a-z][a-z0-9_]{2,7}$"

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

# --- in: :form and the named layers --------------------------------------------------------------
# The form route reads application/x-www-form-urlencoded through axum Form, and the generated check()
# then runs on the parsed struct exactly as it does for the query route. The two are told apart by
# their messages: an extractor rejection reads "Failed to deserialize form body", the check() one reads
# "error: invalid value for ...".

# want_form LABEL PATH DATA STATUS BODY: a form POST whose urlencoded body is DATA, asserting the
# status and the exact response body.
want_form() {
	post_form "$2" "$3"
	if [ "$status" != "$4" ]; then
		echo "FAIL: $1"
		echo "      POST $2 body=[$3] -> HTTP $status, wanted $4"
		echo "      response: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	if ! body_is "$body" "$5"; then
		echo "FAIL: $1"
		echo "      POST $2 body=[$3] -> HTTP $status, but the body was not the one expected"
		echo "      wanted: [$5]"
		echo "      got:    [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	passed=$((passed + 1))
	echo "ok: POST $2 body=[$3] -> $status [$5]"
}

# want_form_reject LABEL PATH DATA EXPECTED [STATUS=400]: a form POST that must answer STATUS with EXPECTED in
# the body. The match is a substring, so the message says which of axum and the check() answered.
want_form_reject() {
	post_form "$2" "$3"
	if [ "$status" != "${5:-400}" ]; then
		echo "FAIL: $1"
		echo "      POST $2 body=[$3] -> HTTP $status, wanted ${5:-400}"
		echo "      response: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
	fi
	case "$(cat "$body")" in
	*"$4"*) ;;
	*)
		echo "FAIL: $1"
		echo "      the body does not contain [$4]"
		echo "      got: [$(cat "$body")]"
		failed=$((failed + 1))
		return 0
		;;
	esac
	passed=$((passed + 1))
	echo "ok: POST $2 body=[$3] -> ${5:-400} [$(cat "$body")]"
}

# A valid form body answers its route, and the values the body read are right.
want_form "form: both fields parse and the body reads them" \
	"/signup/form" "name=ada&age=36" 200 \
	"<p>form signup accepted: name=ada age=36, sent as a form</p>"

# h(params[:name]) escapes the name before it lands in the markup, so a tag-shaped value comes back as
# text: the response contains `&lt;script&gt;` and no raw `<script>`. The name field takes at most 8
# characters, so the payload is `<script>` (percent-encoded); a longer one never reaches the body,
# because the generated check() answers 400 for it first.
post_form "/signup/form" "name=%3Cscript%3E&age=36"
if [ "$status" = "200" ] && grep -q '&lt;script&gt;' "$body" && ! grep -q '<script>' "$body"; then
	passed=$((passed + 1))
	echo "ok: POST /signup/form name=<script> -> the HTML body escapes it to &lt;script&gt;"
else
	echo "FAIL: POST /signup/form did not escape the name into the HTML body"
	echo "      status [$status]  body: [$(cat "$body")]"
	failed=$((failed + 1))
fi

# A missing required field is refused by axum Form itself, before the generated check() runs: axum answers 422.
want_form_reject "form: a missing name is the Form extractor rejection" \
	"/signup/form" "age=36" "Failed to deserialize form body" 422

# A field that does not parse at its type is the Form extractor rejection too, and also 422.
want_form_reject "form: age=x is the Form extractor rejection" \
	"/signup/form" "name=ada&age=x" "Failed to deserialize form body" 422

# Fields that parse but violate a constraint are the generated check()'s own message. /signup/form reads
# errors[:name], so the message reaches the body (the page is re-rendered with it) while the status stays
# 400, because that body sets no status(...). The message is the one the query route gives, so the check()
# really runs on the form struct after the extractor accepts it.
want_form_reject "form: name too short keeps the 400 and carries the check()'s message" \
	"/signup/form" "name=ab&age=36" \
	"error: invalid value for name: it has 2 characters, fewer than the minimum of 3"

# The re-render itself: the success page with the check()'s message for that field appended. The exact
# success body above is unchanged by the routes reading errors, because errors[:name] is "" when the
# request passed -- which is what makes the two routes' 200s and the gzip check below still exact.
post_form "/signup/form" "name=ab&age=36"
if [ "$status" = "400" ] &&
	grep -qF '<p>form signup accepted: name=ab age=36, sent as a form</p>error: invalid value for name: it has 2 characters, fewer than the minimum of 3' "$body"; then
	passed=$((passed + 1))
	echo "ok: POST /signup/form name=ab -> 400, the page re-rendered with the check()'s message for name"
else
	echo "FAIL: POST /signup/form did not re-render the page with the check()'s message for name"
	echo "      status [$status]  body: [$(cat "$body")]"
	failed=$((failed + 1))
fi

# /signup/soft reads errors and sets status(:accepted): a body that sets a status decides for itself, so a
# rejected POST is answered 202 with the message instead of the 400 the check() would otherwise give.
post_form "/signup/soft" "name=ab&age=36"
if [ "$status" = "202" ] &&
	grep -qF 'error: invalid value for name: it has 2 characters, fewer than the minimum of 3' "$body"; then
	passed=$((passed + 1))
	echo "ok: POST /signup/soft name=ab -> 202 (the body's own status) with the check()'s message"
else
	echo "FAIL: POST /signup/soft with a too-short name did not answer the status its body sets"
	echo "      status [$status]  body: [$(cat "$body")]"
	failed=$((failed + 1))
fi

# The same route on a request that passes: the body's status again, and the message is empty.
want_form "soft: a valid body answers the body's own status" \
	"/signup/soft" "name=ada&age=36" 202 \
	"<p>soft signup: name=ada age=36</p>"

# --- a Rails form's bracketed wire names --------------------------------------------------------
# `name: "message[body]"` is a serde rename on the generated struct: the URL-encoded key is the bracketed
# one, while the body reads params[:body] and the check() is still keyed by `body`. A flat `body=` does
# not satisfy the renamed field, so axum's Form extractor answers 422, which is the gap this closes.
want_form "form: a Rails bracketed wire name reaches params[:body]" \
	"/messages" "message%5Bbody%5D=hello" 200 \
	"<p>message accepted: body=hello</p>"
want_form "form: the optional bracketed wire name is accepted too" \
	"/messages" "message%5Bbody%5D=hello&message%5Bclient_message_id%5D=c1" 200 \
	"<p>message accepted: body=hello</p>"
want_form_reject "form: a flat body does not satisfy the bracketed wire name" \
	"/messages" "body=hello" "Failed to deserialize form body" 422
want_form_reject "form: the bracketed name still runs the check() for the DSL name" \
	"/messages" "message%5Bbody%5D=" \
	"error: invalid value for body: it has 0 characters, fewer than the minimum of 1"

# compression: tower-http skips a response under 32 bytes, so the form route (whose body is longer) is
# the one to ask. The raw request is asserted for the header, and curl --compressed for the body.
post_form_compressed "/signup/form" "name=ada&age=36"
if [ "$status" = "200" ] && body_is "$body" "<p>form signup accepted: name=ada age=36, sent as a form</p>"; then
	passed=$((passed + 1))
	echo "ok: POST /signup/form with Accept-Encoding: gzip decodes to the plain body"
else
	echo "FAIL: the gzip response of POST /signup/form did not decode to the plain body"
	echo "      status: [$status]  body: [$(cat "$body")]"
	failed=$((failed + 1))
fi

post_form_gzip "/signup/form" "name=ada&age=36"
if [ "$status" = "200" ] && grep -qi '^content-encoding: *gzip' "$headers"; then
	passed=$((passed + 1))
	echo "ok: POST /signup/form with Accept-Encoding: gzip -> content-encoding: gzip"
else
	echo "FAIL: POST /signup/form did not answer content-encoding: gzip; status [$status], headers:"
	sed 's/^/      /' "$headers" 2>/dev/null || true
	failed=$((failed + 1))
fi

# cors: an origin in the allow-list is echoed back, and one that is not gets no header at all, so the
# layer is a real allow-list and not a permissive one.
get_origin "/signup?name=ada&age=36&colour=green&handle=ada_l" "https://example.com"
acao=$(grep -i '^access-control-allow-origin:' "$headers" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//')
if [ "$acao" = "https://example.com" ]; then
	passed=$((passed + 1))
	echo "ok: GET /signup with Origin: https://example.com -> access-control-allow-origin: https://example.com"
else
	echo "FAIL: the allowed origin was not echoed; access-control-allow-origin was [$acao]"
	sed 's/^/      /' "$headers" 2>/dev/null || true
	failed=$((failed + 1))
fi

get_origin "/signup?name=ada&age=36&colour=green&handle=ada_l" "https://evil.example"
acao=$(grep -i '^access-control-allow-origin:' "$headers" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//')
if [ -z "$acao" ]; then
	passed=$((passed + 1))
	echo "ok: GET /signup with Origin: https://evil.example -> no access-control-allow-origin"
else
	echo "FAIL: an origin outside the allow-list got access-control-allow-origin: [$acao]"
	failed=$((failed + 1))
fi

# openapi "/openapi.json": the compiler wrote an OpenAPI 3.1 document from the routes and fields above, and
# the service serves it as one static string. It is parsed as JSON and read back for the things the DSL
# declared: the paths, a parameter's schema (age: min 18, max 120), a field and a route description, the
# form request body and the 400 the check() answers with. Without ruby on PATH only the content type and a
# few substrings are asserted.
get "/openapi.json"
if [ "$status" = "200" ] && grep -qi '^content-type:.*application/json' "$headers"; then
	passed=$((passed + 1))
	echo "ok: GET /openapi.json -> 200 application/json"
else
	echo "FAIL: GET /openapi.json -> HTTP $status, wanted 200 application/json; headers:"
	sed 's/^/      /' "$headers" 2>/dev/null || true
	failed=$((failed + 1))
fi
if has ruby; then
	cat >"$work/openapi_check.rb" <<'RUBY'
require "json"
doc = JSON.parse(File.read(ARGV[0]))
fail_with = ->(msg) { puts msg; exit 1 }
fail_with.call("openapi is #{doc['openapi'].inspect}, wanted 3.1.0") unless doc["openapi"] == "3.1.0"
fail_with.call("info is #{doc['info'].inspect}") unless doc["info"] == { "title" => "validator", "version" => "0.1.0" }
paths = doc["paths"].keys.sort
fail_with.call("paths are #{paths.inspect}") unless paths == ["/etag", "/messages", "/signup", "/signup/form", "/signup/soft"]
op = doc.dig("paths", "/signup", "get")
fail_with.call("GET /signup has no operation") unless op
fail_with.call("summary is #{op['summary'].inspect}") unless op["summary"] == "One signup, echoing the values it accepted"
params = op["parameters"].to_h { |p| [p["name"], p] }
age = params.fetch("age")
fail_with.call("age is #{age.inspect}") unless age["in"] == "query" && age["required"] == true &&
                                               age["schema"] == { "type" => "integer", "format" => "int32", "minimum" => 18, "maximum" => 120 }
fail_with.call("name schema is #{params['name']['schema'].inspect}") unless params["name"]["schema"].values_at("minLength", "maxLength") == [3, 8]
fail_with.call("colour schema is #{params['colour']['schema'].inspect}") unless params["colour"]["schema"]["enum"] == %w[red green blue]
fail_with.call("handle has no pattern") unless params["handle"]["schema"]["pattern"] == "^[a-z][a-z0-9_]{2,7}$"
fail_with.call("GET /signup has no 400") unless op["responses"].key?("400")
form = doc.dig("paths", "/signup/form", "post", "requestBody", "content", "application/x-www-form-urlencoded", "schema")
fail_with.call("form body schema is #{form.inspect}") unless form && form.dig("properties", "age", "minimum") == 18 && form["required"] == %w[name age]
fail_with.call("POST /signup/form has no 422") unless doc.dig("paths", "/signup/form", "post", "responses").key?("422")
puts "ok"
RUBY
	if msg=$(ruby "$work/openapi_check.rb" "$body" 2>&1); then
		passed=$((passed + 1))
		echo "ok: GET /openapi.json parses as OpenAPI 3.1 with the declared paths, constraints, descriptions and responses"
	else
		echo "FAIL: the document served at /openapi.json is not what the DSL declares"
		echo "      $msg"
		failed=$((failed + 1))
	fi
elif grep -q '"minimum":18' "$body" && grep -q '"openapi":"3.1.0"' "$body"; then
	passed=$((passed + 1))
	echo "ok: GET /openapi.json names OpenAPI 3.1.0 and age's minimum 18 (no ruby to parse it)"
else
	echo "FAIL: GET /openapi.json lacks \"openapi\":\"3.1.0\" or age's \"minimum\":18"
	failed=$((failed + 1))
fi

# --- ETag and conditional GET ----------------------------------------------------------------------
# `etag(value)` is a route statement: the response carries ETag, and a request whose If-None-Match lists
# the value is answered 304 with no body (still carrying the ETag); a different tag still gets the body.
get "/etag"
etag=$(grep -i '^etag:' "$headers" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//')
if [ "$status" = "200" ] && body_is "$body" "fresh" && [ "$etag" = '"validator-v1"' ]; then
	passed=$((passed + 1))
	echo "ok: GET /etag -> 200 with ETag $etag"
else
	echo "FAIL: GET /etag did not answer 200 fresh with ETag \"validator-v1\""
	echo "      status [$status]  etag [$etag]  body: [$(cat "$body")]"
	failed=$((failed + 1))
fi
get_h "/etag" "If-None-Match" "$etag"
if [ "$status" = "304" ] && [ ! -s "$body" ] && grep -qi '^etag:' "$headers"; then
	passed=$((passed + 1))
	echo "ok: GET /etag with If-None-Match -> 304 with no body and the ETag"
else
	echo "FAIL: GET /etag with If-None-Match did not answer 304 with no body and the ETag"
	echo "      status [$status]  body: [$(cat "$body")]"
	failed=$((failed + 1))
fi
get_h "/etag" "If-None-Match" different
if [ "$status" = "200" ] && body_is "$body" "fresh"; then
	passed=$((passed + 1))
	echo "ok: GET /etag with a different If-None-Match -> 200 fresh"
else
	echo "FAIL: GET /etag with a different If-None-Match did not answer 200 fresh"
	echo "      status [$status]  body: [$(cat "$body")]"
	failed=$((failed + 1))
fi

# :timeout and :trace are declared, so they compile and wrap every route, but neither is asserted over
# HTTP here: a timeout needs a slow route, and the blocking escape hatches would starve the one tokio
# worker a single-core run has, making the check timing-flaky; plain :trace logs only with a tracing
# subscriber, which the generated crate does not install (test/e2e_proxy.sh asserts the one that does).
# Both are exercised by every route above still answering through them.
echo "note: :timeout and :trace are declared but not asserted over HTTP (see the comment in this script)"

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: /signup echoes the values it accepted, each violated constraint answers 400 with the message the generated check() builds, the form route parses, escapes the name with h(...) and, reading errors[:name], re-renders that message while keeping the 400, /signup/soft answers the status its body sets, the compression and cors layers answer, and /openapi.json serves an OpenAPI 3.1 document of the routes and their constraints"
