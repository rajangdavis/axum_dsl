#!/bin/sh
# L5 end to end for the SQLite service the DSL generates from examples/notes.axum.rb: start it on a fresh
# database (DATABASE_PATH), add two notes, list them (as JSON and, through a `{% for %}` view, as a page), fetch one, ask for a missing one, delete one; then stop
# it, start it again on the same file and check that the notes are still there (the migration is not applied
# a second time, or its CREATE TABLE would stop the server). Last, a second tiny service whose record has a
# field its query does not select must refuse to start and name the DSL line. Exit zero only when every
# check passed. Needs curl and ruby.
# usage: sh test/e2e_notes.sh [CRATE_DIR]      (default /tmp/axum_dsl_notes-out)
# Build the crate first:  ruby exe/axum_dsl build examples/notes.axum.rb -o /tmp/axum_dsl_notes-out
set -eu

dir=${1:-/tmp/axum_dsl_notes-out}
here=$(cd "$(dirname "$0")" && pwd)
exe="$here/../exe/axum_dsl"
host=127.0.0.1
port=8084        # examples/notes.axum.rb: `set :port, 8084`
name=notes       # examples/notes.axum.rb: `server "notes"` names the crate, so names this binary
base="http://$host:$port"

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_notes.sh speaks HTTP with curl, which is not on PATH"
has ruby || fail "e2e_notes.sh builds a second service with ruby exe/axum_dsl, and ruby is not on PATH"

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

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_notes.XXXXXX") || exit 1
body="$work/body"
err="$work/err"
log="$work/server.log"
db="$work/notes.sqlite3"
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

# req METHOD PATH [curl args]: the answer's code goes to $status and its body to $body.
req() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      examples/notes.axum.rb fixes the port with \`set :port, 8084\`, and this test has no other."
	exit 1
fi

# Starts the service on the database file and waits for its port; a server that died on the way up is
# reported with its own output.
start_server() {
	DATABASE_PATH="$db" setsid "$bin" >>"$log" 2>&1 &
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

stop_server() {
	kill -TERM "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	pid=
	i=0
	while listening && [ "$i" -lt 50 ]; do
		i=$((i + 1))
		sleep 0.1
	done
}

passed=0
failed=0

# want LABEL STATUS BODY-PREFIX: the last req answered that status, with a body that starts with that text.
want() {
	got=$(cat "$body")
	case "$got" in
	"$3"*)
		if [ "$status" = "$2" ]; then
			passed=$((passed + 1))
			echo "ok: $1 -> $status [$got]"
			return 0
		fi
		;;
	esac
	echo "FAIL: $1"
	echo "      HTTP $status, wanted $2 with a body starting [$3]"
	echo "      body: [$got]"
	failed=$((failed + 1))
}

# --- the first run, on a fresh database ----------------------------------------------------------
start_server

# post "/notes": the form field body goes to add_note, which returns the new id
req POST /notes --data-urlencode "body=first note"
want "POST /notes (first)" 200 "1"
req POST /notes --data-urlencode "body=second note"
want "POST /notes (second)" 200 "2"

# get "/notes": recent_notes as JSON, newest first, the NULL tag as null
req GET /notes
want "GET /notes lists both, newest first" 200 '[{"id":2,"body":"second note","created_at":"'
if grep -q '"id":1,"body":"first note"' "$body" && grep -q '"tag":null' "$body"; then
	passed=$((passed + 1))
	echo "ok: GET /notes holds the first note and a null tag"
else
	echo "FAIL: GET /notes does not hold the first note and a null tag: [$(cat "$body")]"
	failed=$((failed + 1))
fi

# get "/notes/:id": find_note, or a 404 from the route
req GET /notes/1
want "GET /notes/1" 200 '{"id":1,"body":"first note","created_at":"'
req GET /notes/999
want "GET /notes/999 is a 404" 404 "no such note"

# delete "/notes/:id": delete_note answers how many rows went
req DELETE /notes/1
want "DELETE /notes/1" 200 "1"
req DELETE /notes/1
want "DELETE /notes/1 again" 200 "0"
req GET /notes/1
want "GET /notes/1 after the delete" 404 "no such note"

# --- the second run, on the same file --------------------------------------------------------------
# axum_dsl_migrations remembers 001_create_notes.sql, so it is not applied again: its CREATE TABLE has no
# IF NOT EXISTS, and a second run of it would stop the server.
stop_server
start_server
req GET /notes/2
want "restart: GET /notes/2 is still there" 200 '{"id":2,"body":"second note","created_at":"'
req GET /notes/1
want "restart: GET /notes/1 is still deleted" 404 "no such note"
req POST /notes --data-urlencode "body=third note"
want "restart: POST /notes carries on from the old ids" 200 "3"

# get "/notes.html": the `{% for %}` view lists the notes newest first, and a tag-shaped body comes back escaped
req POST /notes --data-urlencode "body=<b>x</b>"
want "POST /notes (a tag-shaped body)" 200 "4"
req GET /notes.html
want "GET /notes.html is a page" 200 "<!doctype html>"
if ruby -e 'b = File.read(ARGV[0]); at = ["&lt;b&gt;x&lt;/b&gt;", "third note", "second note"].map { |s| b.index(s) }; exit(at.all? && at == at.sort ? 0 : 1)' "$body" &&
	! grep -q "<b>x</b>" "$body" && ! grep -q "first note" "$body"; then
	passed=$((passed + 1))
	echo "ok: GET /notes.html holds each live note body, newest first, the tag-shaped one escaped, the deleted one gone"
else
	echo "FAIL: GET /notes.html is not the three live notes newest first with the tag escaped: [$(cat "$body")]"
	failed=$((failed + 1))
fi
stop_server

# --- a record the query does not match --------------------------------------------------------------
# The record has a field (body) the query does not select. The server checks every query against the
# database as it starts, so it exits non-zero and names the DSL line of the query.
mkdir -p "$work/bad/db"
cat >"$work/bad/db/001_create_notes.sql" <<'SQL'
CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
SQL
cat >"$work/bad/bad.axum.rb" <<'RB'
server "notes-bad", version: "0.1.0"
set :port, 8085
database :sqlite, path: "bad.sqlite3", env: "DATABASE_PATH"
migrations "db"
record :Note do
  field :id, :i64
  field :body, :string
end
query :list_notes, args: {}, returns: list(:Note), sql: "SELECT id FROM notes"
get "/notes" do
  json(list_notes())
end
RB
line=$(grep -n '^query :list_notes' "$work/bad/bad.axum.rb" | cut -d: -f1)
ruby "$exe" build "$work/bad/bad.axum.rb" -o "$work/bad/out" >"$work/bad/build.log" 2>&1 || {
	echo "FAIL: the second service did not build:"
	sed 's/^/      /' "$work/bad/build.log"
	exit 1
}
badbin=$(find_bin "$work/bad/out" notes-bad) || fail "no notes-bad binary after building the second service"
rc=0
DATABASE_PATH="$work/bad/bad.sqlite3" "$badbin" >"$work/bad/run.log" 2>&1 || rc=$?
if [ "$rc" != 0 ] && grep -q "bad.axum.rb:$line" "$work/bad/run.log" && grep -q 'list_notes' "$work/bad/run.log" && grep -q '"body"' "$work/bad/run.log"; then
	passed=$((passed + 1))
	echo "ok: a query that misses a record field stops the server (exit $rc) and names bad.axum.rb:$line"
else
	echo "FAIL: the mismatched query did not stop the server with a message naming bad.axum.rb:$line and the missing column; exit $rc, output:"
	sed 's/^/      /' "$work/bad/run.log" 2>/dev/null || true
	failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: notes are added, listed, fetched, deleted and kept across a restart (the migration runs once), a missing note is a 404, a query that misses a record field stops the server at startup"
