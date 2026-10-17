#!/bin/sh
# End to end for `axum_dsl dev`: start it on a small service, then change the DSL file and check that the
# running service follows -- the new answer appears after an edit, a compile error is printed while the old
# server keeps answering, a fix restarts it, and stopping `dev` leaves no server behind. Needs curl and ruby.
# usage: sh test/e2e_dev.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
host=127.0.0.1
fail() { echo "FAIL: $1"; [ -f "${log:-}" ] && sed 's/^/      /' "$log"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: e2e_dev.sh speaks HTTP with curl, which is not on PATH"; exit 1; }

# A free port: ask the kernel for one and let it go.
port=$(ruby -rsocket -e 's = TCPServer.new("127.0.0.1", 0); print s.addr[1]; s.close')
base="http://$host:$port"

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_dev.XXXXXX") || exit 1
log="$work/dev.log"
src="$work/hello.axum.rb"
pid=
cleanup() {
	if [ -n "${pid:-}" ]; then
		kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		pid=
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

write_src() {
	cat >"$src" <<RUBY
server "devhello", version: "0.1.0"
set :port, 8080

get "/hello" do
  text("$1")
end
RUBY
}

answer() { curl -s --max-time 2 "$base/hello" 2>/dev/null || true; }

# wait_answer WANT SECONDS: poll until GET /hello is WANT.
wait_answer() {
	i=0
	while [ "$i" -lt $(($2 * 5)) ]; do
		[ "$(answer)" = "$1" ] && return 0
		i=$((i + 1))
		sleep 0.2
	done
	return 1
}

write_src one
: >"$log"
PORT=$port ruby "$root/exe/axum_dsl" dev "$src" -o "$work/out" >"$log" 2>&1 &
pid=$!

wait_answer one 600 || fail "the first build did not come up answering \"one\" on $base within 600 s"
echo "ok: dev built and started the service"

write_src two
wait_answer two 600 || fail "after an edit the service did not answer \"two\""
grep -q 'axum_dsl dev: restarted' "$log" || fail "no restart line was printed"
echo "ok: an edit rebuilt and restarted the service"

# A compile error: reported, and the old server keeps answering.
before=$(wc -l <"$log")
cat >"$src" <<RUBY
server "devhello", version: "0.1.0"
set :port, 8080

get "/hello" do
  text(bogus_call(1))
end
RUBY
i=0
while [ "$(wc -l <"$log")" -le "$before" ]; do
	i=$((i + 1))
	[ "$i" -le 100 ] || fail "a compile error was not printed within 20 s"
	sleep 0.2
done
sleep 1
[ "$(answer)" = two ] || fail "after a compile error the old server no longer answers \"two\""
kill -0 "$pid" 2>/dev/null || fail "dev exited on a compile error"
echo "ok: a compile error was printed and the old server kept answering"

write_src three
wait_answer three 600 || fail "after fixing the error the service did not answer \"three\""
echo "ok: the fix restarted the service"

# Stopping dev stops the server with it.
kill -TERM "$pid"
status=0
wait "$pid" || status=$?
pid=
[ "$status" = 0 ] || fail "dev exited with status $status on SIGTERM, wanted 0"
sleep 0.5
if curl -s -o /dev/null --max-time 2 "$base/hello" 2>/dev/null; then
	fail "a server still answers on $base after dev stopped"
fi
echo "OK: dev followed an edit, survived a compile error, restarted on the fix, and left no server behind"
