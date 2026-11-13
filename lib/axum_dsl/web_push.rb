# frozen_string_literal: true

module AxumDsl
  # `web_push(endpoint, p256dh, auth, payload, vapid_public, vapid_private, subject)`: one Web Push delivery as Campfire
  # sends it (lib/web_push/notification.rb through the web-push gem, from WebPush::Pool's threads), answering whether the
  # subscription is to be invalidated -- 1 where the pool's `rescue WebPush::ExpiredSubscription, OpenSSL::OpenSSLError`
  # calls the invalid-subscription handler, 0 otherwise:
  # - the endpoint's host must resolve to a public address (Push::Subscription#resolved_endpoint_ip, surfguard's ranges);
  #   when it does not, the notification is not sent at all (0), and the request is pinned to that address, no proxy;
  # - the payload is encrypted as RFC 8291's aes128gcm: an ephemeral P-256 key, ECDH with the subscription's p256dh key,
  #   HKDF with its auth secret, one record (rs 4096) ending in the 0x02 delimiter; a key that is not a P-256 point is
  #   OpenSSL's error there (1), while one that is not Base64 is the gem's ArgumentError, logged and not invalidated (0);
  # - the request carries the gem's headers: `Content-Encoding: aes128gcm`, `TTL: 2419200` (four weeks), `Urgency:
  #   high` and VAPID's `Authorization: vapid t=<ES256 JWT over aud, exp (12 hours) and sub>, k=<public key>`;
  # - 404 and 410 are ExpiredSubscription (1); any other answer, or a failure to connect, is logged by the pool (0).
  module WebPush
    module_function

    CALL = "web_push"

    def used?(ir) = ir["builtins"].to_a.include?(CALL)

    def items(ir) = used?(ir) ? RUNTIME.lines.map(&:chomp) + [""] : []

    def deps(ir)
      return "" unless used?(ir)

      "\nreqwest = { version = \"0.12\", default-features = false, features = [\"rustls-tls-native-roots\"] }" \
        "\np256 = { version = \"0.14\", features = [\"ecdh\", \"ecdsa\", \"getrandom\"] }\nhkdf = \"0.13\"\naes-gcm = \"0.11\"" \
        "\nsha2_wp = { package = \"sha2\", version = \"0.11\" }" \
        "\nbase64 = \"0.22\""
    end

    RUNTIME = <<~'RS'
      fn axum_dsl_wp_blocked(ip: ::std::net::IpAddr) -> bool {
          match ip {
              ::std::net::IpAddr::V4(v4) => {
                  let [a, b, c, _] = v4.octets();
                  a == 0 || a == 10 || a == 127 || (a == 100 && (64..=127).contains(&b)) || (a == 169 && b == 254)
                      || (a == 172 && (16..=31).contains(&b)) || (a == 192 && b == 0 && (c == 0 || c == 2))
                      || (a == 192 && b == 88 && c == 99) || (a == 192 && b == 168) || (a == 198 && (b == 18 || b == 19))
                      || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113) || a >= 224
              }
              ::std::net::IpAddr::V6(v6) => {
                  if let Some(v4) = v6.to_ipv4_mapped() {
                      return axum_dsl_wp_blocked(::std::net::IpAddr::V4(v4));
                  }
                  let s = v6.segments();
                  v6.is_unspecified() || v6.is_loopback() || (s[0] & 0xfe00) == 0xfc00 || (s[0] & 0xffc0) == 0xfe80
                      || (s[0] & 0xff00) == 0xff00 || (s[0] == 0x2001 && s[1] == 0x0db8) || (s[0] == 0x0064 && s[1] == 0xff9b)
                      || s[0] == 0x2002 || (s[0] == 0 && s[1] == 0 && s[2] == 0 && s[3] == 0 && s[4] == 0 && s[5] == 0)
              }
          }
      }

      /// Base64, URL-safe or standard, padded or not: the gem's `Base64.urlsafe_decode64` takes both alphabets' padding.
      fn axum_dsl_wp_b64(s: &str) -> Option<Vec<u8>> {
          use ::base64::Engine;
          let t: String = s.trim().trim_end_matches('=').chars().map(|c| match c { '+' => '-', '/' => '_', c => c }).collect();
          ::base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(t.as_bytes()).ok()
      }

      fn axum_dsl_wp_b64url(bytes: &[u8]) -> String {
          use ::base64::Engine;
          ::base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
      }

      enum AxumDslWpBody {
          Sealed(Vec<u8>),
          BadKey,      // not a P-256 point: OpenSSL's error, an invalid subscription
          Unreadable,  // not Base64: the gem's ArgumentError, logged
      }

      /// RFC 8291 (aes128gcm) for one record.
      fn axum_dsl_wp_encrypt(p256dh: &str, auth: &str, payload: &[u8]) -> AxumDslWpBody {
          use ::aes_gcm::aead::Aead;
          use ::aes_gcm::KeyInit;
          use ::p256::elliptic_curve::{sec1::ToSec1Point, Generate};
          let (Some(ua_bytes), Some(auth_secret)) = (axum_dsl_wp_b64(p256dh), axum_dsl_wp_b64(auth)) else { return AxumDslWpBody::Unreadable };
          let Ok(ua_public) = ::p256::PublicKey::from_sec1_bytes(&ua_bytes) else { return AxumDslWpBody::BadKey };
          let as_secret = ::p256::ecdh::EphemeralSecret::generate();
          let as_public = as_secret.public_key().to_sec1_point(false);
          let shared = as_secret.diffie_hellman(&ua_public);
          let ua_point = ua_public.to_sec1_point(false);
          let mut key_info = b"WebPush: info\0".to_vec();
          key_info.extend_from_slice(ua_point.as_bytes());
          key_info.extend_from_slice(as_public.as_bytes());
          let mut ikm = [0u8; 32];
          if ::hkdf::Hkdf::<::sha2_wp::Sha256>::new(Some(&auth_secret), shared.raw_secret_bytes().as_slice()).expand(&key_info, &mut ikm).is_err() {
              return AxumDslWpBody::BadKey;
          }
          let salt = <[u8; 16]>::generate();
          let prk = ::hkdf::Hkdf::<::sha2_wp::Sha256>::new(Some(&salt), &ikm);
          let (mut cek, mut nonce) = ([0u8; 16], [0u8; 12]);
          if prk.expand(b"Content-Encoding: aes128gcm\0", &mut cek).is_err() || prk.expand(b"Content-Encoding: nonce\0", &mut nonce).is_err() {
              return AxumDslWpBody::BadKey;
          }
          let mut plain = payload.to_vec();
          plain.push(0x02);
          let cipher = ::aes_gcm::Aes128Gcm::new(&cek.into());
          let Ok(sealed) = cipher.encrypt(&nonce.into(), plain.as_slice()) else { return AxumDslWpBody::BadKey };
          let mut body = salt.to_vec();
          body.extend_from_slice(&4096u32.to_be_bytes());
          body.push(as_public.as_bytes().len() as u8);
          body.extend_from_slice(as_public.as_bytes());
          body.extend_from_slice(&sealed);
          AxumDslWpBody::Sealed(body)
      }

      /// VAPID (RFC 8292): an ES256 JWT for the endpoint's origin, valid twelve hours, signed with the private key.
      fn axum_dsl_wp_vapid(audience: &str, subject: &str, private_key: &str) -> Option<String> {
          use ::p256::ecdsa::signature::Signer;
          let secret = ::p256::SecretKey::from_slice(&axum_dsl_wp_b64(private_key)?).ok()?;
          let exp = ::std::time::SystemTime::now().duration_since(::std::time::UNIX_EPOCH).ok()?.as_secs() + 12 * 3600;
          let header = axum_dsl_wp_b64url(br#"{"typ":"JWT","alg":"ES256"}"#);
          let claims = axum_dsl_wp_b64url(::serde_json::json!({ "aud": audience, "exp": exp, "sub": subject }).to_string().as_bytes());
          let signing = format!("{header}.{claims}");
          let signature: ::p256::ecdsa::Signature = ::p256::ecdsa::SigningKey::from(secret).sign(signing.as_bytes());
          Some(format!("{signing}.{}", axum_dsl_wp_b64url(signature.to_bytes().as_slice())))
      }

      async fn axum_dsl_web_push(endpoint: &str, p256dh: &str, auth: &str, payload: &str, vapid_public: &str, vapid_private: &str, subject: &str) -> i64 {
          let Ok(url) = ::reqwest::Url::parse(endpoint) else { return 0 };
          let Some(host) = url.host_str().map(|h| h.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase()) else { return 0 };
          let port = url.port_or_known_default().unwrap_or(443);
          let addr = match host.parse::<::std::net::IpAddr>() {
              Ok(ip) if !axum_dsl_wp_blocked(ip) => Some(::std::net::SocketAddr::new(ip, port)),
              Ok(_) => None,
              Err(_) => match ::tokio::time::timeout(::std::time::Duration::from_secs(10), ::tokio::net::lookup_host((host.as_str(), port))).await {
                  Ok(Ok(found)) => found.into_iter().find(|a| !axum_dsl_wp_blocked(a.ip())),
                  _ => None,
              },
          };
          let Some(addr) = addr else { return 0 }; // resolved_endpoint_ip is nil: nothing is sent
          let body = match axum_dsl_wp_encrypt(p256dh, auth, payload.as_bytes()) {
              AxumDslWpBody::Sealed(body) => body,
              AxumDslWpBody::BadKey => return 1,
              AxumDslWpBody::Unreadable => {
                  eprintln!("Error in WebPush::Pool.deliver: the subscription's keys are not Base64");
                  return 0;
              }
          };
          let audience = format!("{}://{}", url.scheme(), url.host_str().unwrap_or(""));
          let audience = match url.port() { Some(p) => format!("{audience}:{p}"), None => audience };
          let Some(jwt) = axum_dsl_wp_vapid(&audience, subject, vapid_private) else {
              eprintln!("Error in WebPush::Pool.deliver: the VAPID private key is not a P-256 key");
              return 0;
          };
          let Ok(client) = ::reqwest::Client::builder().no_proxy().resolve(&host, addr).timeout(::std::time::Duration::from_secs(60)).build() else { return 0 };
          let sent = client
              .post(url)
              .header("Content-Encoding", "aes128gcm")
              .header("Content-Type", "application/octet-stream")
              .header("TTL", "2419200")
              .header("Urgency", "high")
              .header("Authorization", format!("vapid t={jwt}, k={}", vapid_public.trim_end_matches('=')))
              .body(body)
              .send()
              .await;
          match sent {
              Ok(res) if res.status() == ::reqwest::StatusCode::NOT_FOUND || res.status() == ::reqwest::StatusCode::GONE => 1,
              Ok(res) if res.status().is_success() => 0,
              Ok(res) => {
                  eprintln!("Error in WebPush::Pool.deliver: WebPush::ResponseError {}", res.status());
                  0
              }
              Err(e) => {
                  eprintln!("Error in WebPush::Pool.deliver: {e}");
                  0
              }
          }
      }
    RS
  end
end
