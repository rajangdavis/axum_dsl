#!/bin/sh
# L5 end to end for the Rails-format signed cookies the DSL generates from examples/login_rails.axum.rb: a
# running service must accept the cookie Rails itself would write, and the cookie the service writes must
# verify in Ruby. A unit test can pin the emitted Rust; only this shows the two implementations agree on the
# wire. Every value here is computed by Ruby from the documented algorithm, not from the compiler's Rust:
#   key    = OpenSSL::PKCS5.pbkdf2_hmac(secret, "signed cookie", 1000, 64, SHA1)
#   data   = Base64.strict_encode64(Marshal.dump(value))
#   signed = data + "--" + OpenSSL::HMAC.hexdigest(SHA1, key, data)   (lower-case hex)
# The Rails 7/8 form (format: :rails7) uses the :json serializer, the _rails metadata envelope and the
# load_defaults "7.0" key derivation:
#   key7     = OpenSSL::PKCS5.pbkdf2_hmac(secret, "signed cookie", 1000, 64, SHA256)
#   message  = Base64.strict_encode64(JSON.generate(value))
#   envelope = {"_rails":{"message":message,"exp":<null or an ISO8601 string>,"pur":"cookie.NAME"}}
#   signed7  = Base64.strict_encode64(envelope) + "--" + HMAC-SHA1 hex
# A permanent (`cookies.signed.permanent`) or max_age cookie writes the expiry Rails'
# Messages::Metadata.pick_expiry writes: expires_at.utc.iso8601(3), e.g. "3018-07-11T16:11:26.753Z";
# null is the non-expiring form. Rails' own max_age alone writes null (`cookie_metadata` passes only
# `:expires`), so this service's max_age exp is the intentional difference. The service writes the string
# and refuses an expired one, an integer, or a malformed one, as Messages::Metadata#verify does.
# Strict Base64 is [].pack("m0"): Ruby 4 dropped the base64 library, so nothing here requires it. A Rails
# value also travels percent-encoded as Rack encodes it, so the service's unquote() runs before verify.
# Exit zero only when every check passed. Needs curl and ruby.
#
# usage: sh test/e2e_login_rails.sh [CRATE_DIR]      (default /tmp/axum_dsl_login_rails-out)
# Build the crate first:  ruby exe/axum_dsl build examples/login_rails.axum.rb -o /tmp/axum_dsl_login_rails-out
set -eu

dir=${1:-/tmp/axum_dsl_login_rails-out}
host=127.0.0.1
port=8096         # examples/login_rails.axum.rb: `set :port, 8096`
name=login_rails  # examples/login_rails.axum.rb: `server "login_rails"` names the crate, so names this binary
base="http://$host:$port"
key=0123456789abcdef0123456789abcdef0123456789
other_key=abcdef0123456789abcdef0123456789abcdef01
# The vector test/test_login.rb pins for key/tok: both this script's helper and the vector come from the
# documented Rails algorithm, so the pin catches a later drift, not a mistake shared by both.
vector='BAhJIgh0b2sGOgZFVA==--87e78c745a7a62ef517be4571bdf0b22eb074ace'
# The rails7 vector test/test_login.rb pins for rails7_token/tok under the Rails 7/8 defaults.
vector7='eyJfcmFpbHMiOnsibWVzc2FnZSI6IkluUnZheUk9IiwiZXhwIjpudWxsLCJwdXIiOiJjb29raWUucmFpbHM3X3Rva2VuIn19--927d95959802b52062338321816e15e36c2c9e09'
# The permanent vector test/test_login.rb pins for exp "2100-01-01T00:00:00.000Z".
vector7_permanent='eyJfcmFpbHMiOnsibWVzc2FnZSI6IkluUnZheUk9IiwiZXhwIjoiMjEwMC0wMS0wMVQwMDowMDowMC4wMDBaIiwicHVyIjoiY29va2llLnJhaWxzN190b2tlbiJ9fQ==--599afd628ed52407c633e1ae6e92d73296848b9c'

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_login_rails.sh speaks HTTP with curl, which is not on PATH"
has ruby || fail "e2e_login_rails.sh computes Rails' cookie with ruby, which is not on PATH"

# rails_cookie KEY VALUE: the signed value Rails' MessageVerifier#generate writes, before Rack escaping.
rails_cookie() {
	ruby -ropenssl -e '
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA1.new)
		data = [Marshal.dump(ARGV[1])].pack("m0")
		print "#{data}--#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)}"
	' "$1" "$2"
}

# rails_verify KEY COOKIE: MessageVerifier#verified, written out again -- undo Rack's escaping, check the
# hex digest over the Base64 text, then Marshal.load it. Prints the value, or exits non-zero with a reason.
rails_verify() {
	ruby -ropenssl -ruri -e '
		raw = URI.decode_www_form_component(ARGV[1])
		data, digest = raw.split("--", 2)
		abort "no separator" unless digest && digest.length == 40
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA1.new)
		want = OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)
		abort "digest mismatch" unless want == digest
		print Marshal.load(data.unpack1("m0"))
	' "$1" "$2"
}

# rails7_cookie KEY NAME VALUE [EXP]: the signed value a default Rails 7/8 app's cookies.signed[NAME] =
# VALUE writes, before Rack escaping (JSON serializer, _rails envelope, PBKDF2-HMAC-SHA256 key, HMAC-SHA1
# hex). EXP is the UTC ISO8601 string a permanent/max_age cookie carries; without it the exp is null.
rails7_cookie() {
	ruby -ropenssl -rjson -e '
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA256.new)
		message = [JSON.generate(ARGV[2])].pack("m0")
		expiry = ARGV[3].nil? || ARGV[3] == "null" ? nil : ARGV[3]
		envelope = JSON.generate("_rails" => { "message" => message, "exp" => expiry, "pur" => "cookie.#{ARGV[1]}" })
		data = [envelope].pack("m0")
		print "#{data}--#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)}"
	' "$1" "$2" "$3" "${4:-null}"
}

# rails7_verify KEY NAME COOKIE: MessageVerifier#verified with the jar's purpose -- undo Rack escaping, check
# the HMAC-SHA1 hex, unwrap _rails (purpose, then a null exp or an ISO8601 string strictly later than
# now), decode the inner message and parse its JSON String. Prints the value, or exits non-zero with a reason.
rails7_verify() {
	ruby -ropenssl -rjson -ruri -rtime -e '
		raw = URI.decode_www_form_component(ARGV[2])
		data, separator, digest = raw.rpartition("--")
		abort "no separator" if separator.empty? || digest.length != 40
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA256.new)
		want = OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)
		abort "digest mismatch" unless want == digest
		text = data.unpack1("m0")
		envelope = JSON.parse(text)
		if (rails = envelope["_rails"])
			abort "purpose mismatch" unless rails["pur"] == "cookie.#{ARGV[1]}"
			exp = rails["exp"]
			abort "expiry metadata is not an ISO8601 string or null" unless exp.nil? || exp.is_a?(String)
			abort "cookie has expired" if exp && Time.iso8601(exp) <= Time.now
			text = rails["message"].unpack1("m0")
		end
		print JSON.parse(text)
	' "$1" "$2" "$3"
}

# rails7_custom KEY NAME EXP: a signed rails7 envelope whose exp is "null" or the given UTC ISO8601
# string; it proves a wrong purpose, an expired exp and the accepted unexpired form.
rails7_custom() {
	ruby -ropenssl -rjson -e '
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA256.new)
		message = [JSON.generate("tok")].pack("m0")
		expiry = ARGV[2] == "null" ? nil : ARGV[2]
		envelope = JSON.generate("_rails" => { "message" => message, "exp" => expiry, "pur" => "cookie.#{ARGV[1]}" })
		data = [envelope].pack("m0")
		print "#{data}--#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)}"
	' "$1" "$2" "$3"
}

# rails7_exp KEY NAME COOKIE: the envelope's exp ("null" or the ISO8601 string), after the signature and
# purpose check, so a check on a cookie the service wrote is not fooled by an edited one.
rails7_exp() {
	ruby -ropenssl -rjson -ruri -rtime -e '
		raw = URI.decode_www_form_component(ARGV[2])
		data, separator, digest = raw.rpartition("--")
		abort "no separator" if separator.empty? || digest.length != 40
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA256.new)
		want = OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)
		abort "digest mismatch" unless want == digest
		envelope = JSON.parse(data.unpack1("m0"))
		rails = envelope["_rails"] or abort "no _rails envelope"
		abort "purpose mismatch" unless rails["pur"] == "cookie.#{ARGV[1]}"
		exp = rails["exp"]
		Time.iso8601(exp) if exp
		print exp.nil? ? "null" : exp
	' "$1" "$2" "$3"
}

# rails7_at SECONDS: the UTC ISO8601 string Rails' pick_expiry writes for that epoch second.
rails7_at() {
	ruby -rtime -e 'print Time.at(Integer(ARGV[0])).utc.iso8601(3)' "$1"
}

# rails7_custom_int KEY NAME SECONDS: deliberately wrong -- an integer exp, the shape the old signer wrote
# and Messages::Metadata#verify would raise on. It proves the service refuses a non-string exp.
rails7_custom_int() {
	ruby -ropenssl -rjson -e '
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA256.new)
		message = [JSON.generate("tok")].pack("m0")
		envelope = JSON.generate("_rails" => { "message" => message, "exp" => Integer(ARGV[2]), "pur" => "cookie.#{ARGV[1]}" })
		data = [envelope].pack("m0")
		print "#{data}--#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)}"
	' "$1" "$2" "$3"
}

# rails7_no_metadata KEY VALUE: use_cookies_with_metadata = false -- the JSON text signed directly.
rails7_no_metadata() {
	ruby -ropenssl -rjson -e '
		key = OpenSSL::PKCS5.pbkdf2_hmac(ARGV[0], "signed cookie", 1000, 64, OpenSSL::Digest::SHA256.new)
		data = [JSON.generate(ARGV[1])].pack("m0")
		print "#{data}--#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)}"
	' "$1" "$2"
}

# Rack's percent-encoding, which is how a Rails-signed value travels in a Cookie header (and what the
# service's unquote() undoes). Without it the Base64 "+" would read as a space.
encode_cookie() {
	ruby -ruri -e 'print URI.encode_www_form_component(ARGV[0])' "$1"
}

# make shares one cargo target dir (CARGO_TARGET_DIR), so the binary is there, or else inside the crate.
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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_login_rails.XXXXXX") || exit 1
body="$work/body"
hdr="$work/headers"
err="$work/err"
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
listening() { curl -s -o /dev/null --max-time 2 "$base/" 2>/dev/null; }

# req METHOD PATH [curl args]: the answer's code goes to $status, its headers to $hdr and its body to $body.
req() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -D "$hdr" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

# The Ruby helper and the pinned vector must agree before the service is involved at all.
[ "$(rails_cookie "$key" tok)" = "$vector" ] ||
	fail "the Ruby helper no longer produces test_login.rb's Rails vector: [$(rails_cookie "$key" tok)]"

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/login_rails.axum.rb fixes the port with \`set :port, 8096\`, and this test has no other."
	exit 1
fi

# Starts the service with the key $1 and waits for its port; a server that died on the way up is reported
# with its own output.
start_server() {
	if has setsid; then
		SECRET_KEY_BASE="$1" setsid "$bin" >>"$log" 2>&1 &
	else
		SECRET_KEY_BASE="$1" "$bin" >>"$log" 2>&1 &
	fi
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
}

passed=0
failed=0

ok() {
	passed=$((passed + 1))
	echo "ok: $1"
}

bad() {
	failed=$((failed + 1))
	echo "FAIL: $1"
}

# want LABEL STATUS BODY-PREFIX: the last req answered that status, with a body that starts with that text.
want() {
	got=$(cat "$body")
	case "$got" in
	"$3"*)
		if [ "$status" = "$2" ]; then
			ok "$1 -> $status [$got]"
			return 0
		fi
		;;
	esac
	bad "$1"
	echo "      HTTP $status, wanted $2 with a body starting [$3]"
	echo "      body: [$got]"
}

# set_cookie_has LABEL PATTERN: the last req's Set-Cookie line matches the pattern (an extended regex, case-blind).
set_cookie_has() {
	if grep -i '^set-cookie:' "$hdr" | tr -d '\r' | grep -Eiq "$2"; then
		ok "$1"
	else
		bad "$1: no Set-Cookie line matching [$2]; headers:"
		sed 's/^/      /' "$hdr"
	fi
}

# cookie_value NAME: the value of the last req's Set-Cookie line for that cookie, or empty.
cookie_value() {
	sed -n "s/^[Ss]et-[Cc]ookie: *$1=\([^;]*\).*/\1/p" "$hdr" | tr -d '\r' | head -n 1
}

start_server "$key"

# --- a cookie Ruby writes, Rails' way, is what the service accepts ---------------------------------
hand=$(encode_cookie "$(rails_cookie "$key" tok)")
req GET /me -H "Cookie: rails_token=$hand"
want "GET /me accepts a hand-made Rails signed cookie" 200 "tok"

# The same value with its Base64 padding left raw: unquote() passes an unescaped "=" straight through, so a
# client that escapes only "+" and "/" still verifies. Rails itself would send %3D.
req GET /me -H "Cookie: rails_token=$(rails_cookie "$key" tok)"
want "GET /me accepts the unescaped Base64 form too" 200 "tok"

tampered=$(rails_cookie "$key" tok)
case "$tampered" in
*0) tampered="${tampered%?}1" ;;
*) tampered="${tampered%?}0" ;;
esac
req GET /me -H "Cookie: rails_token=$tampered"
want "GET /me refuses a tampered Rails cookie" 200 "none"

foreign=$(encode_cookie "$(rails_cookie "$other_key" tok)")
req GET /me -H "Cookie: rails_token=$foreign"
want "GET /me refuses a cookie signed with another key" 200 "none"

req GET /me
want "GET /me without a cookie answers none" 200 "none"

# --- the cookie /set writes verifies in Ruby, and is the MessageVerifier value ----------------------
req GET /set
want "GET /set answers the value it set" 200 "tok"
set_cookie_has "the cookie is a signed value (Base64--40 lower-case hex)" '^set-cookie: rails_token=[^;]*--[0-9a-f]{40};'
set_cookie_has "the cookie is HttpOnly" '; HttpOnly'
set_cookie_has "the cookie is SameSite=Lax" '; SameSite=Lax'
set_cookie_has "the cookie is Path=/" '; Path=/(;|$)'
set_cookie=$(cookie_value rails_token)
[ -n "$set_cookie" ] || fail "no rails_token cookie to carry on with"

# The writer's escaping and its Base64/Marshal/HMAC must be exactly Rails' value for key/tok.
if [ "$set_cookie" = "$(encode_cookie "$vector")" ]; then
	ok "the Set-Cookie value is Rails' MessageVerifier value, Rack-encoded"
else
	bad "the Set-Cookie value is not the pinned Rails value"
	echo "      got:  [$set_cookie]"
	echo "      want: [$(encode_cookie "$vector")]"
fi

# The reverse steps, in Ruby, must recover the fixed value from what the service wrote.
if decoded=$(rails_verify "$key" "$set_cookie"); then
	if [ "$decoded" = "tok" ]; then
		ok "Ruby verifies the cookie the service wrote and reads tok back"
	else
		bad "Ruby verified the service's cookie but read [$decoded], not [tok]"
	fi
else
	bad "Ruby could not verify the cookie the service wrote"
fi

req GET /me -H "Cookie: rails_token=$set_cookie"
want "GET /me accepts the cookie it wrote" 200 "tok"

tampered="$set_cookie"
case "$tampered" in
*0) tampered="${tampered%?}1" ;;
*) tampered="${tampered%?}0" ;;
esac
req GET /me -H "Cookie: rails_token=$tampered"
want "GET /me refuses a tampered copy of the written cookie" 200 "none"

# --- format: :rails7, the default Rails 7/8 signed cookie -------------------------------------------
# The Ruby helper and the pinned vector must agree before the service is involved at all.
[ "$(rails7_cookie "$key" rails7_token tok)" = "$vector7" ] ||
	fail "the Ruby rails7 helper no longer produces test_login.rb's vector: [$(rails7_cookie "$key" rails7_token tok)]"

[ "$(rails7_cookie "$key" rails7_token tok "2100-01-01T00:00:00.000Z")" = "$vector7_permanent" ] ||
	fail "the Ruby rails7 helper no longer produces test_login.rb's permanent vector: [$(rails7_cookie "$key" rails7_token tok "2100-01-01T00:00:00.000Z")]"

hand7=$(encode_cookie "$(rails7_cookie "$key" rails7_token tok)")
req GET /me7 -H "Cookie: rails7_token=$hand7"
want "GET /me7 accepts a hand-made Rails 7/8 signed cookie" 200 "tok"

req GET /me7 -H "Cookie: rails7_token=$(rails7_cookie "$key" rails7_token tok)"
want "GET /me7 accepts the unescaped Base64 form too" 200 "tok"

tampered=$(rails7_cookie "$key" rails7_token tok)
case "$tampered" in
*0) tampered="${tampered%?}1" ;;
*) tampered="${tampered%?}0" ;;
esac
req GET /me7 -H "Cookie: rails7_token=$tampered"
want "GET /me7 refuses a tampered rails7 cookie" 200 "none"

foreign=$(encode_cookie "$(rails7_cookie "$other_key" rails7_token tok)")
req GET /me7 -H "Cookie: rails7_token=$foreign"
want "GET /me7 refuses a rails7 cookie signed with another key" 200 "none"

wrong=$(encode_cookie "$(rails7_custom "$key" other_token null)")
req GET /me7 -H "Cookie: rails7_token=$wrong"
want "GET /me7 refuses a rails7 envelope written for another cookie name" 200 "none"

now=$(ruby -e 'print Time.now.to_i')
fresh=$(encode_cookie "$(rails7_custom "$key" rails7_token "$(rails7_at "$((now + 3600))")")")
req GET /me7 -H "Cookie: rails7_token=$fresh"
want "GET /me7 accepts a hand-made unexpired ISO8601 exp" 200 "tok"

expired=$(encode_cookie "$(rails7_custom "$key" rails7_token "$(rails7_at "$((now - 60))")")")
req GET /me7 -H "Cookie: rails7_token=$expired"
want "GET /me7 refuses an expired rails7 cookie" 200 "none"

integer_exp=$(encode_cookie "$(rails7_custom_int "$key" rails7_token "$((now + 3600))")")
req GET /me7 -H "Cookie: rails7_token=$integer_exp"
want "GET /me7 refuses a hand-made integer exp" 200 "none"

bad_date=$(encode_cookie "$(rails7_custom "$key" rails7_token "2100-02-30T00:00:00.000Z")")
req GET /me7 -H "Cookie: rails7_token=$bad_date"
want "GET /me7 refuses an impossible calendar date" 200 "none"

nom=$(encode_cookie "$(rails7_no_metadata "$key" tok)")
req GET /me7 -H "Cookie: rails7_token=$nom"
want "GET /me7 accepts the no-metadata form" 200 "tok"

req GET /me7
want "GET /me7 without a cookie answers none" 200 "none"

req GET /set7
want "GET /set7 answers the value it set" 200 "tok"
set_cookie_has "the rails7 cookie is a signed value (Base64--40 lower-case hex)" '^set-cookie: rails7_token=[^;]*--[0-9a-f]{40};'
set_cookie_has "the rails7 cookie is HttpOnly" '; HttpOnly'
set_cookie7=$(cookie_value rails7_token)
[ -n "$set_cookie7" ] || fail "no rails7_token cookie to carry on with"
if [ "$set_cookie7" = "$(encode_cookie "$vector7")" ]; then
	ok "the rails7 Set-Cookie value is Rails' JSON/metadata value, Rack-encoded"
else
	bad "the rails7 Set-Cookie value is not the pinned Rails 7/8 value"
	echo "      got:  [$set_cookie7]"
	echo "      want: [$(encode_cookie "$vector7")]"
fi
if decoded=$(rails7_verify "$key" rails7_token "$set_cookie7"); then
	if [ "$decoded" = "tok" ]; then
		ok "Ruby verifies the rails7 cookie the service wrote and reads tok back"
	else
		bad "Ruby verified the rails7 cookie but read [$decoded], not [tok]"
	fi
else
	bad "Ruby could not verify the rails7 cookie the service wrote"
fi
req GET /me7 -H "Cookie: rails7_token=$set_cookie7"
want "GET /me7 accepts the rails7 cookie it wrote" 200 "tok"

tampered="$set_cookie7"
case "$tampered" in
*0) tampered="${tampered%?}1" ;;
*) tampered="${tampered%?}0" ;;
esac
req GET /me7 -H "Cookie: rails7_token=$tampered"
want "GET /me7 refuses a tampered copy of the written rails7 cookie" 200 "none"

# --- the signed metadata expiry: permanent and max_age write it, expired is refused ------------------
# Rails' CookieJar#write gives a permanent cookie `expires = 20.years.from_now`, and cookie_metadata
# puts only `:expires` into the metadata, so Messages::Metadata.pick_expiry writes it as
# `expires_at.utc.iso8601(3)` -- a string, separate from the HTTP Max-Age the browser honours. Both are
# written; the cookie verifies in Ruby and still reads.
permanent_now=$(ruby -e 'print Time.now.to_i')
req GET /set7permanent
want "GET /set7permanent answers the value it set" 200 "tok"
set_cookie_has "the permanent rails7 cookie is HttpOnly" '; HttpOnly'
set_cookie_has "the permanent rails7 cookie carries Max-Age=631139040" '; Max-Age=631139040(;|$)'
permanent=$(cookie_value rails7_token)
[ -n "$permanent" ] || fail "no permanent rails7_token cookie to carry on with"
permanent_exp=$(rails7_exp "$key" rails7_token "$permanent") || permanent_exp=
permanent_exp_at=$(ruby -rtime -e 'print Time.iso8601(ARGV[0]).to_i' "$permanent_exp" 2>/dev/null) || permanent_exp_at=
if [ -n "$permanent_exp_at" ] && [ "$permanent_exp_at" -ge $((permanent_now + 631139040)) ] &&
	[ "$permanent_exp_at" -le $((permanent_now + 631139040 + 10)) ]; then
	ok "the permanent rails7 metadata exp is now + 631139040 ($permanent_exp)"
else
	bad "the permanent rails7 metadata exp is [$permanent_exp], not now + 631139040 (request at $permanent_now)"
fi
if [ -n "$permanent_exp" ] && [ "$permanent" = "$(encode_cookie "$(rails7_cookie "$key" rails7_token tok "$permanent_exp")")" ]; then
	ok "the permanent rails7 Set-Cookie value is Rails' JSON/metadata value for that exp"
else
	bad "the permanent rails7 Set-Cookie value is not Rails' value for exp [$permanent_exp]"
	echo "      got:  [$permanent]"
	echo "      want: [$(encode_cookie "$(rails7_cookie "$key" rails7_token tok "${permanent_exp:-null}")")]"
fi
if decoded=$(rails7_verify "$key" rails7_token "$permanent"); then
	if [ "$decoded" = "tok" ]; then
		ok "Ruby verifies the permanent rails7 cookie and reads tok back"
	else
		bad "Ruby verified the permanent rails7 cookie but read [$decoded], not [tok]"
	fi
else
	bad "Ruby could not verify the permanent rails7 cookie"
fi
req GET /me7 -H "Cookie: rails7_token=$permanent"
want "GET /me7 accepts the permanent rails7 cookie" 200 "tok"

max_age_now=$(ruby -e 'print Time.now.to_i')
req GET /set7maxage
want "GET /set7maxage answers the value it set" 200 "tok"
set_cookie_has "the max_age rails7 cookie carries Max-Age=60" '; Max-Age=60(;|$)'
max_age_cookie=$(cookie_value rails7_token)
[ -n "$max_age_cookie" ] || fail "no max_age rails7_token cookie to carry on with"
max_age_exp=$(rails7_exp "$key" rails7_token "$max_age_cookie") || max_age_exp=
max_age_exp_at=$(ruby -rtime -e 'print Time.iso8601(ARGV[0]).to_i' "$max_age_exp" 2>/dev/null) || max_age_exp_at=
if [ -n "$max_age_exp_at" ] && [ "$max_age_exp_at" -ge $((max_age_now + 60)) ] &&
	[ "$max_age_exp_at" -le $((max_age_now + 60 + 10)) ]; then
	ok "the max_age rails7 metadata exp is now + 60 ($max_age_exp)"
else
	bad "the max_age rails7 metadata exp is [$max_age_exp], not now + 60 (request at $max_age_now)"
fi
if [ -n "$max_age_exp" ] && [ "$max_age_cookie" = "$(encode_cookie "$(rails7_cookie "$key" rails7_token tok "$max_age_exp")")" ]; then
	ok "the max_age rails7 Set-Cookie value is Rails' JSON/metadata value for that exp"
else
	bad "the max_age rails7 Set-Cookie value is not Rails' value for exp [$max_age_exp]"
	echo "      got:  [$max_age_cookie]"
	echo "      want: [$(encode_cookie "$(rails7_cookie "$key" rails7_token tok "${max_age_exp:-null}")")]"
fi
req GET /me7 -H "Cookie: rails7_token=$max_age_cookie"
want "GET /me7 accepts the max_age rails7 cookie" 200 "tok"

# --- the unsigned plain cookie travels beside the signed one ----------------------------------------
req GET /unsigned
want "GET /unsigned answers the plain value it set" 200 "lobby"
set_cookie_has "the plain cookie carries no signature" '^set-cookie: plain_token=lobby;'
plain=$(cookie_value plain_token)
[ -n "$plain" ] || fail "no plain_token cookie to carry on with"
req GET /plain -H "Cookie: plain_token=$plain"
want "GET /plain round-trips the plain cookie" 200 "lobby"
req GET /plain
want "GET /plain without a cookie answers none" 200 "none"

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: Ruby-written Rails and Rails 7/8 cookies verify, tampered, foreign-keyed, wrong-purpose and expired ones do not, the cookies /set, /set7, /set7permanent and /set7maxage write verify in Ruby (with the signed permanent/max_age ISO8601 exp), and the unsigned plain cookie round-trips"
