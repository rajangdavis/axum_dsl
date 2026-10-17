//! A TLS listener for the generated service: `set :listener, "tls::TlsListener"` in the DSL file makes
//! the emitted `main` call `tls::TlsListener::bind((host, port)).await?` and serve with the result.
//! The contract is that `bind` takes `(&str, u16)` and returns `std::io::Result<Self>`, and that the
//! type implements `axum::serve::Listener` with `type Addr = std::net::SocketAddr`.
//!
//! The certificate chain and the private key are PEM files named by `TLS_CERT` and `TLS_KEY`. A missing
//! variable or an unreadable file is an error from `bind`, so the service exits before it listens.
//! Only TLS is spoken on the port: a plain `http://` request fails the handshake and is dropped.

use std::fs::File;
use std::io::{self, BufReader};
use std::net::SocketAddr;
use std::sync::Arc;

use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinSet;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::server::TlsStream;
use tokio_rustls::TlsAcceptor;

/// A connection whose handshake finished, with the peer's address; `None` when the handshake failed.
type Handshake = Option<(TlsStream<TcpStream>, SocketAddr)>;

pub struct TlsListener {
    tcp: TcpListener,
    acceptor: TlsAcceptor,
    /// Handshakes in flight. Each runs in its own task, so a client that stalls its handshake holds
    /// only its own task and never blocks `accept` for the others.
    pending: JoinSet<Handshake>,
}

fn env_path(name: &str) -> io::Result<String> {
    std::env::var(name)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, format!("{name} must name a PEM file")))
}

fn load_config() -> io::Result<ServerConfig> {
    let cert_path = env_path("TLS_CERT")?;
    let key_path = env_path("TLS_KEY")?;
    let certs = rustls_pemfile::certs(&mut BufReader::new(File::open(&cert_path)?))
        .collect::<Result<Vec<_>, _>>()?;
    let key = rustls_pemfile::private_key(&mut BufReader::new(File::open(&key_path)?))?
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, format!("no private key in {key_path}")))?;
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    // the generated service serves HTTP/1.1 only
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(config)
}

impl TlsListener {
    pub async fn bind(addr: (&str, u16)) -> io::Result<Self> {
        let config = load_config()?;
        Ok(Self {
            tcp: TcpListener::bind(addr).await?,
            acceptor: TlsAcceptor::from(Arc::new(config)),
            pending: JoinSet::new(),
        })
    }
}

impl axum::serve::Listener for TlsListener {
    type Io = TlsStream<TcpStream>;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            tokio::select! {
                (tcp, addr) = axum::serve::Listener::accept(&mut self.tcp) => {
                    let acceptor = self.acceptor.clone();
                    self.pending.spawn(async move {
                        match acceptor.accept(tcp).await {
                            Ok(tls) => Some((tls, addr)),
                            Err(error) => {
                                eprintln!("TLS handshake with {addr} failed: {error}");
                                None
                            }
                        }
                    });
                }
                Some(done) = self.pending.join_next(), if !self.pending.is_empty() => {
                    if let Ok(Some(ready)) = done {
                        return ready;
                    }
                }
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.tcp.local_addr()
    }
}
