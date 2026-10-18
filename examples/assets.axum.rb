# typed: true
# The third example: serving files, and shaping a response with headers. A `static` mount answers a whole
# directory, `serve_file` answers one route with one file, and `headers` adds header lines to a route's
# response. `make e2e-assets` builds this file and test/e2e_assets.sh talks HTTP to it.
#
# Every declared asset is copied into the emitted crate at the same relative path, so the service finds a
# bare ServeDir::new("public") beside the crate's own Cargo.toml: the emitted binary must run with the
# crate directory as its working directory, which is what the e2e script establishes and what the docs say.
server "assets", version: "0.1.0"
set :port, 8097
set :views, "asset_views"

# GET /files/index.html, /files/style.css and /files/data.json are answered from public/, with the
# content type guessed from each extension; a missing file is an empty 404.
static "/files", dir: "public"

# A fingerprinted mount: every file under fingerprints/ is copied under <stem>-<sha256 prefix><ext> and only
# that name is served, so GET /assets/campfire-<digest>.css is the one URL for those bytes and a far-future
# Cache-Control on it is safe. `{{ asset_path "campfire.css" }}` writes that URL into a page.
static "/assets", dir: "fingerprints", digest: true

# The fingerprinted files are public: they carry no session or CSRF token, so a shared cache may store them.
# `except:` leaves the private headers off that mount only; every other response (the /files mount,
# /api/ping and a 404) keeps `Cache-Control: private, no-cache` and `Vary: Cookie`, which is the default.
# Only a path a `static` mount serves may be named: a route or a page must never be exempted by accident.
use_layer :private_cache, except: ["/assets"]

# One route answered by one file: GET /report.txt is public/report.txt, served by ServeFile.
serve_file "/report.txt", from: "public/report.txt"

get "/api/ping", description: "A route that sets its own response headers" do
  headers "Cache-Control" => "no-store", "X-Content-Type-Options" => "nosniff"
  text("pong")
end

get "/fingerprints", description: "A page naming the fingerprinted stylesheet" do
  render :fingerprints
end