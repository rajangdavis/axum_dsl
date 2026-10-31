#!/bin/sh
# L5 end to end for the service the DSL generates from examples/upload.axum.rb: a multipart form with a file
# (curl -F) reaches its params group, the file arrives with its name, type, size and Active Storage's MD5 checksum,
# an empty file input is nil, a urlencoded body still works, `_method=patch` in a multipart body reaches the patch
# route, `store` writes the file at <root>/<key[0,2]>/<key[2,2]>/<key> with a blob and an attachment row behind
# it, and a repeated `user_ids[]` key is a list in both encodings. Exit zero only when every check passed.
# Needs curl; the checksum check needs openssl and base64.
# usage: sh test/e2e_upload.sh [CRATE_DIR]      (default /tmp/axum_dsl_upload-out)
# Build the crate first:  ruby exe/axum_dsl build examples/upload.axum.rb -o /tmp/axum_dsl_upload-out
set -eu

dir=${1:-/tmp/axum_dsl_upload-out}
host=127.0.0.1
port=8111        # examples/upload.axum.rb: `set :port, 8111`
name=upload
base="http://$host:$port"

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_upload.sh speaks HTTP with curl, which is not on PATH"

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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_upload.XXXXXX") || exit 1
body="$work/body"
err="$work/err"
log="$work/server.log"
pid=
cleanup() {
	if [ -n "${pid:-}" ]; then
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

listening() { curl -s -o /dev/null --max-time 2 "$base/blobs/0" 2>/dev/null; }

# req METHOD PATH [curl args]
req() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	exit 1
fi

export DATABASE_PATH="$work/upload.sqlite3"
export STORAGE_PATH="$work/storage"
: >"$log"
if has setsid; then
	setsid "$bin" >>"$log" 2>&1 &
else
	"$bin" >>"$log" 2>&1 &
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

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "ok: $1"; }
bad() { failed=$((failed + 1)); echo "FAIL: $1"; }

# want LABEL STATUS BODY: the last request answered that status with exactly that body.
want() {
	got=$(cat "$body")
	if [ "$status" = "$2" ] && [ "$got" = "$3" ]; then
		ok "$1 -> $status [$got]"
	else
		bad "$1"
		echo "      HTTP $status, wanted $2 with [$3]"
		echo "      body: [$got]"
	fi
}

# status_is LABEL STATUS
status_is() {
	if [ "$status" = "$2" ]; then ok "$1 -> $status"; else bad "$1 (HTTP $status, wanted $2: $(cat "$body"))"; fi
}

printf 'moon-bytes-0123' >"$work/moon.png"   # 15 bytes
md5=
if has openssl && has base64; then
	md5=$(openssl dgst -md5 -binary "$work/moon.png" | base64)
fi

# --- /join: text fields and an optional avatar
req POST /join -F 'user[name]=Nora' -F "user[avatar]=@$work/moon.png;type=image/png"
if [ -n "$md5" ]; then
	want "a multipart form: the text field and the file (name, type, size, md5)" 200 "joined Nora with moon.png (image/png, 15 bytes, md5 $md5)"
else
	got=$(cat "$body")
	case "$got" in "joined Nora with moon.png (image/png, 15 bytes, md5 "*) ok "a multipart form: the text field and the file ($got)" ;; *) bad "a multipart form: [$got]" ;; esac
fi

# A browser sends an empty part (filename="") for a file input nobody chose a file in; Rack drops it.
boundary=----e2eboundary
printf -- '--%s\r\nContent-Disposition: form-data; name="user[name]"\r\n\r\nNora\r\n--%s\r\nContent-Disposition: form-data; name="user[avatar]"; filename=""\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--%s--\r\n' "$boundary" "$boundary" "$boundary" >"$work/empty.body"
req POST /join -H "Content-Type: multipart/form-data; boundary=$boundary" --data-binary "@$work/empty.body"
want "an empty file input is nil, the text field still arrives" 200 "joined Nora without an avatar"

req POST /join -F 'user[name]=Only Text'
want "a multipart form with no file part at all" 200 "joined Only Text without an avatar"

req POST /join --data-urlencode 'user[name]=Urlenc Ode'
want "a urlencoded body still reads" 200 "joined Urlenc Ode without an avatar"

req POST /join -F 'user[name]=a' -F 'user[name]=last wins'
want "a repeated plain key keeps its last value (Rack)" 200 "joined last wins without an avatar"

req POST /join -F 'user[avatar]=@'"$work/moon.png"
status_is "a missing required text field is axum's Form 422" 422

req POST /join -H 'Content-Type: application/json' --data '{"user[name]":"x"}'
status_is "a body that is no form is 415, as axum's Form answers" 415

req POST /join -H 'Content-Type: multipart/form-data; boundary=zzz' --data-binary 'not a multipart body'
status_is "a malformed multipart body is 400" 400

req POST /join -H 'Content-Type: multipart/form-data' --data-binary 'x'
status_is "a multipart body with no boundary is 400" 400

# --- PATCH through a multipart POST, store, blob and attachment rows
req POST /users/7/profile -F '_method=patch' -F 'user[bio]=hello there' -F "user[avatar]=@$work/moon.png;type=image/png"
got=$(cat "$body")
case "$got" in
"blob 1 key "*" bio hello there") ok "_method=patch in a multipart body reaches the patch route [$got]" ;;
*) bad "_method=patch in a multipart body (HTTP $status): [$got]" ;;
esac
key=$(echo "$got" | sed -n 's/^blob 1 key \([a-z0-9]*\) bio.*/\1/p')
if [ "${#key}" -eq 28 ]; then ok "the key is 28 lowercase base36 characters ($key)"; else bad "the key [$key] is not 28 lowercase base36 characters"; fi
first=$(echo "$key" | cut -c1-2)
second=$(echo "$key" | cut -c3-4)
stored="$STORAGE_PATH/$first/$second/$key"
if [ -f "$stored" ] && [ "$(cat "$stored")" = "moon-bytes-0123" ]; then ok "the file is at <root>/<key[0,2]>/<key[2,2]>/<key>"; else bad "no file with the upload's bytes at $stored"; fi

req GET /blobs/1
got=$(cat "$body")
case "$got" in
*'"filename":"moon.png"'*'"content_type":"image/png"'*'"byte_size":15'*'"service_name":"local"'*) ok "the blob row records filename, type, size and service [$got]" ;;
*) bad "the blob row: HTTP $status [$got]" ;;
esac
if [ -n "$md5" ]; then
	case "$got" in *"\"checksum\":\"$md5\""*) ok "the blob checksum is the base64 MD5" ;; *) bad "the blob checksum is not $md5: [$got]" ;; esac
fi

req POST /users/7/profile -F '_method=patch' -F "user[avatar]=@$work/moon.png"
case "$(cat "$body")" in "blob 2 key "*" bio ") ok "a second upload is a second blob (keys are fresh)" ;; *) bad "second upload: [$(cat "$body")]" ;; esac

req POST /users/7/profile -H "Content-Type: multipart/form-data; boundary=$boundary" --data-binary "@$work/empty.body"
status_is "no file chosen on a POST (no _method): the route is a POST and not found" 405

printf -- '--%s\r\nContent-Disposition: form-data; name="_method"\r\n\r\npatch\r\n--%s\r\nContent-Disposition: form-data; name="user[avatar]"; filename=""\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--%s--\r\n' "$boundary" "$boundary" "$boundary" >"$work/empty_patch.body"
req POST /users/7/profile -H "Content-Type: multipart/form-data; boundary=$boundary" --data-binary "@$work/empty_patch.body"
want "_method=patch with an empty file input reaches the route, whose avatar is nil" 422 "no file chosen"

req POST /users/7/profile -H 'X-HTTP-Method-Override: PATCH' -F "user[avatar]=@$work/moon.png"
case "$(cat "$body")" in "blob 3 key "*) ok "the X-HTTP-Method-Override header still works with a multipart body" ;; *) bad "header override: HTTP $status [$(cat "$body")]" ;; esac

# --- repeated keys: user_ids[] is a list
req POST /rooms/3 -d 'room[name]=Closed&user_ids[]=1&user_ids[]=2&_method=patch'
want "a urlencoded user_ids[] repeated is a list" 200 "room 3 Closed members 2: 1,2"

req POST /rooms/3 -F '_method=patch' -F 'room[name]=Closed' -F 'user_ids[]=4' -F 'user_ids[]=5' -F 'user_ids[]=6'
want "a multipart user_ids[] repeated is a list, in order" 200 "room 3 Closed members 3: 4,5,6"

req POST /rooms/3 -d 'room[name]=Closed&user_ids%5B%5D=9&_method=patch'
want "a percent-encoded key name[] is the same key" 200 "room 3 Closed members 1: 9"

req POST /rooms/3 -d 'room[name]=Closed&_method=patch'
want "no user_ids[] at all is the default, an empty list" 200 "room 3 Closed members 0: "

req POST /rooms/3 -d 'room[name]=Closed&user_ids[]=x&_method=patch'
status_is "an element that is not an integer is 422" 422

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: multipart forms reach their params group with the file's name, type, size and checksum, an empty file input is nil, urlencoded bodies still read, a multipart _method routes the request, store writes the Disk service's path under a fresh key, and repeated name[] keys are lists"
