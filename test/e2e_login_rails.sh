#!/bin/sh
# L5 end to end for the Rails-format signed cookie the DSL generates from examples/login_rails.axum.rb: a
# running service must accept the cookie Rails itself would write, and the cookie the service writes must
# verify in Ruby. A unit test can pin the emitted Rust; only this shows the two implementations agree on the
# wire. Every value here is computed by Ruby from the documented algorithm, not from the compiler's Rust:
#   key    = OpenSSL::PKCS5.pbkdf2_hmac(secret, "signed cookie", 1000, 64, SHA1)
#   data   = Base64.strict_encode64(Marshal.dump(value))
#   signed = data + "--" + OpenSSL::HMAC.hexdigest(SHA1, key, data)   (lower-case hex)
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
# The vector test/test_login.rb pins for key/tok: checking it here keeps the Ruby helper below honest even
# before the service runs, so a passing wire check cannot come from two implementations sharing a mistake.
vector='BAhJIgh0b2sGOgZFVA==--87e78c745a7a62ef517be4571bdf0b22eb074ace'

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
echo "OK: $passed checks passed: a Ruby-written Rails cookie verifies, tampered and foreign-keyed ones do not, the cookie /set writes verifies in Ruby, and the unsigned plain cookie round-trips"
