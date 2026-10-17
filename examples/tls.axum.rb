# typed: true
# A sixth small example, for one declaration: `set :listener`, the hook that lets a Rust type of your own
# take the place of the TCP listener. Here the type is a TLS listener built on tokio-rustls
# (rust/tls_listener.rs), so the service speaks HTTPS and nothing else; the compiler has no TLS in it.
# The certificate and key are PEM files named by the TLS_CERT and TLS_KEY environment variables, which the
# Rust code reads. `use_layer :trace` is here to show the request log (RUST_LOG overrides its level).
# test/e2e_tls.sh drives it; add holds port 8080, views 8091, validate 8093, proxy 8095 and assets 8097,
# so this takes 8098.
server "tls", version: "0.1.0"
set :port, 8098

# tokio-rustls defaults to the aws_lc_rs provider, whose aws-lc-sys build also pulls the cmake crate; "ring" picks
# the ring provider instead (ring still compiles C through cc, so a C compiler is needed either way), and
# "logging" and "tls12" keep the other two defaults. Its own rustls dependency turns the defaults off, so no
# rustls line is needed; ServerConfig::builder() uses the one provider the features name.
rust_crate "tokio-rustls", "0.26", default_features: false, features: ["ring", "logging", "tls12"]
rust_crate "rustls-pemfile", "2"
rust_file "rust/tls_listener.rs", as: :tls
set :listener, "tls::TlsListener"

use_layer :trace

get "/ping", description: "Answer pong over TLS" do
  text("pong")
end
