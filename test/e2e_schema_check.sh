#!/bin/sh
# The build-time query check: `axum_dsl schema-check` builds a service and runs it with --schema-check, which applies
# the migrations to a fresh in-memory database and prepares every query, with no server and no database file.
# A correct example (examples/notes.axum.rb) must pass; three small services must fail with the startup messages:
# a query that selects a column its record lacks, a record field its query does not select, and SQL that names a
# column the table does not have (SQLite's own message). Exit zero only when every check passed. Needs ruby and cargo.
# usage: sh test/e2e_schema_check.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
exe="$here/../exe/axum_dsl"
examples="$here/../examples"

fail() { echo "FAIL: $1"; exit 1; }
command -v ruby >/dev/null 2>&1 || fail "e2e_schema_check.sh builds with ruby exe/axum_dsl, and ruby is not on PATH"

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_schema_check.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

passed=0
failed=0

# --- a correct example ------------------------------------------------------------------------------
rc=0
ruby "$exe" schema-check "$examples/notes.axum.rb" -o "$work/notes-out" >"$work/notes.log" 2>&1 || rc=$?
if [ "$rc" = 0 ] && grep -q '^schema-check: ok' "$work/notes.log"; then
	passed=$((passed + 1))
	echo "ok: examples/notes.axum.rb passes the schema check"
else
	echo "FAIL: examples/notes.axum.rb did not pass the schema check (exit $rc):"
	sed 's/^/      /' "$work/notes.log"
	failed=$((failed + 1))
fi

# bad NAME QUERY-LINE RECORD-FIELDS MESSAGE: a service over notes(id, body) whose one query is QUERY-LINE; it must
# fail with exit status 2, the message naming the DSL line of the query, and MESSAGE.
bad() {
	name=$1
	query=$2
	fields=$3
	message=$4
	dir="$work/$name"
	mkdir -p "$dir/db"
	cat >"$dir/db/001_create_notes.sql" <<'SQL'
CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
SQL
	{
		echo "server \"$name\", version: \"0.1.0\""
		echo "set :port, 8085"
		echo 'database :sqlite, path: "bad.sqlite3", env: "DATABASE_PATH"'
		echo 'migrations "db"'
		echo 'record :Note do'
		echo "$fields"
		echo 'end'
		echo "$query"
		echo 'get "/notes" do'
		echo '  json(list_notes())'
		echo 'end'
	} >"$dir/$name.axum.rb"
	line=$(grep -n '^query :list_notes' "$dir/$name.axum.rb" | cut -d: -f1)
	rc=0
	ruby "$exe" schema-check "$dir/$name.axum.rb" -o "$dir/out" >"$dir/run.log" 2>&1 || rc=$?
	if [ "$rc" = 2 ] && grep -q "$name.axum.rb:$line" "$dir/run.log" && grep -q "$message" "$dir/run.log"; then
		passed=$((passed + 1))
		echo "ok: $name fails the schema check (exit $rc) at $name.axum.rb:$line with [$message]"
	else
		echo "FAIL: $name should exit 2 naming $name.axum.rb:$line and [$message]; exit $rc, output:"
		sed 's/^/      /' "$dir/run.log"
		failed=$((failed + 1))
	fi
}

# the query selects a column (body) the record does not have
bad extra_column 'query :list_notes, args: {}, returns: list(:Note), sql: "SELECT id, body FROM notes"' \
	'  field :id, :i64' 'does not select the columns of its record: missing \[\], not a field \["body"\]'
# the record has a field (body) the query does not select
bad missing_column 'query :list_notes, args: {}, returns: list(:Note), sql: "SELECT id FROM notes"' \
	'  field :id, :i64
  field :body, :string' 'does not select the columns of its record: missing \["body"\], not a field \[\]'
# SQL the database rejects: a column the table does not have
bad unknown_column 'query :list_notes, args: {}, returns: list(:Note), sql: "SELECT id FROM notes WHERE title = 1"' \
	'  field :id, :i64' 'no such column: title'

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: a correct service passes the schema check, a column the record lacks, a record field the query does not select and a column the table does not have are each found without a server"
