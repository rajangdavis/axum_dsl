# typed: true
# A service split across files with `use_dsl`: the fragments live in examples/split/, a sub-folder, so
# the `examples/*.axum.rb` glob that `make dsl-check` and test/test_refusals.rb walk finds this root and
# never a fragment (a fragment is not a server, and building one directly is refused). Each use_dsl
# names a path relative to the file that says it, stays inside this file's folder, and splices the
# fragment's declarations in at that line, so declaration order runs across the files.
# test/e2e_split.sh drives it; the other examples hold 8080, 8081, 8091, 8093, 8095 and 8097, so this takes 8082.
server "splitter", version: "0.1.0"
set :port, 8082

use_dsl "split/params.axum.rb"  # the params blocks
use_dsl "split/routes.axum.rb"  # two routes, and a fragment that itself uses split/status.axum.rb

get "/ping", description: "A route written in the root file" do
  text("pong")
end
