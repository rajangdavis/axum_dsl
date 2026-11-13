# frozen_string_literal: true

module AxumDsl
  # `cable "/cable", authenticate_with: :user do channel "HeartbeatChannel" ... end`: an Action Cable endpoint
  # (docs/cable.md). The runtime written here speaks the wire format Rails' actioncable JS client expects over
  # the `actioncable-v1-json` WebSocket subprotocol: `welcome`, `ping` every 3 seconds, `confirm_subscription` or
  # `reject_subscription` for each `subscribe`, and a `disconnect` message before the socket closes. It also holds
  # the broadcast hub: a subscription joins the broadcasting names its channel streams from, and `broadcast`,
  # `broadcast_to` and `broadcast_turbo` (in a route or a channel callback) hand one message to every subscription on a name.
  # `close_remote_connections(user.id)` (Rails' `User#close_remote_connections`) makes every open connection of one user send
  # `{"type":"disconnect","reason":"remote","reconnect":true}` and close.
  #
  # The connection is authenticated by the `current` the declaration names, the same value a route reads with
  # current(:user), computed from the upgrade request's own headers (so the session cookie is read exactly as a
  # route reads it). A request with no user is upgraded and then told
  # `{"type":"disconnect","reason":"unauthorized","reconnect":false}` and closed, as Rails does.
  #
  # The hub lives in this one process (no Redis). Each connection has a bounded queue of 256 frames; a broadcast
  # only ever `try_send`s into it, so a route never waits for a socket, and a client too slow to drain its queue
  # misses the frames that arrive while it is full. Frames of one broadcasting name reach a connection in the order
  # the broadcasts were made.
  #
  # The Rust is emitted only for a file that declares `cable`, and the axum `ws` feature with it.
  module Cable
    PROTOCOL = "actioncable-v1-json"

    module_function

    def used?(ir) = !ir["cable"].nil?

    # The tokio features the runtime needs beyond the crate's own: `time` for the 3 second ping.
    def tokio_features(ir) = used?(ir) ? ", \"time\"" : ""

    def axum_features(ir) = used?(ir) ? %w[ws] : []

    # Whether any channel asks the database whether the user may enter a room.
    def members?(ir) = ir["cable"]["channels"].any? { |c| c["member_of"] }

    # The statement the main function ends the graceful shutdown with, so open sockets are told to reconnect.
    def stop_call = "axum_dsl_cable_stop()"

    # `ActionCable::Channel::Naming#channel_name`: the class name without "Channel", `::` as `:`, underscored.
    # "TypingNotificationsChannel" is "typing_notifications" and "Turbo::StreamsChannel" is "turbo:streams".
    def channel_name(class_name)
      class_name.delete_suffix("Channel").gsub("::", ":")
                .gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').tr("-", "_").downcase
    end

    # The Rust of the endpoint: the stop switch, the hub, the upgrade handler, the session loop, the channel
    # callbacks, and the function that decides whether (and where) a subscription is allowed.
    def items(ir)
      cable = ir["cable"]
      member = members?(ir)
      out = []
      out.concat(lines(fill(RUNTIME, cable)))
      out << ""
      out.concat(lines(fill(COMMANDS, cable)))
      out << ""
      bodies(cable).each do |name, body|
        out.concat(body_fn(name, body))
        out << ""
      end
      out.concat(callbacks_fn(cable, "axum_dsl_cable_unsubscribed", "on_unsubscribe"))
      out << ""
      out.concat(perform_fn(cable))
      out << ""
      out.concat(admit_fn(cable, member))
      out
    end

    def lines(text) = text.lines.map(&:chomp)

    def fill(text, cable)
      text.gsub("@@PATH@@", AxumDsl.rstr(cable["path"]))
          .gsub("@@PROTOCOL@@", AxumDsl.rstr(PROTOCOL))
          .gsub("@@AUTH@@", cable["authenticate_with"])
          .gsub("@@USER_RUST@@", cable["user_rust"])
          .gsub("@@USER_KEY@@", cable["user_key"] ? "{ let user = user.clone(); #{cable["user_key"]} }" : "String::new()")
    end

    # Every callback body of the cable, as [function name, body]: stream_from, stream_for, after_subscribe,
    # on_unsubscribe and one per perform. The name is by channel position, so two channels never share one.
    def bodies(cable)
      cable["channels"].each_with_index.flat_map do |channel, i|
        out = %w[stream_from stream_for after_subscribe on_unsubscribe].filter_map do |kind|
          [body_name(i, kind), channel[kind]] if channel[kind]
        end
        out + channel.fetch("performs", []).map { |p| [body_name(i, "perform_#{p['action']}"), p["body"]] }
      end
    end

    def body_name(index, kind) = "axum_dsl_cable_#{index}_#{kind}"

    # One callback: an async fn taking exactly the values its block named, answering the stream name or nothing.
    def body_fn(name, body)
      params = body["params"].map { |n, t| "#{n}: #{t}" }
      params << "__stream_for: &str" if body["stream_for"]
      string = body["ret"] == "string"
      tail = string ? ["    Ok(#{body['expr']})"] : ["    #{body['expr']};", "    Ok(())"]
      ["async fn #{name}(#{params.join(', ')}) -> Result<#{string ? 'String' : '()'}, String> {",
       *body["locals"].map { |l| "    #{l}" },
       *tail,
       "}"]
    end

    # The arguments a callback is called with, from the Rust locals of the code that calls it: `__user`, `room_id`,
    # `room` and `broadcasting`.
    def call_args(body, cable)
      args = body["params"].map do |n, _|
        if n == cable["authenticate_with"] then "__user.clone()"
        elsif n == "room_id" then "room_id"
        else "room.clone()"
        end
      end
      args << "&broadcasting" if body["stream_for"]
      args.join(", ")
    end

    # The channels' on_unsubscribe callbacks, dispatched on the channel the subscription was made for.
    def callbacks_fn(cable, name, kind)
      arms = cable["channels"].each_with_index.filter_map do |channel, i|
        body = channel[kind] or next
        "        #{AxumDsl.rstr(channel['name'])} => {\n            let _ = #{body_name(i, kind)}(#{call_args(body, cable)}).await;\n        }"
      end
      ["#[allow(unused_variables)]",
       "async fn #{name}(__user: &#{cable['user_rust']}, sub: &AxumDslCableSub) {",
       "    let room_id = sub.room_id;",
       "    let broadcasting = sub.broadcasting.as_str();",
       "    match sub.channel {",
       *arms.flat_map { |a| a.lines.map(&:chomp) },
       "        _ => {}",
       "    }",
       "}"]
    end

    # A client's `message` command: `{"action": "start", ...}` in its `data` string calls the channel's `perform`
    # of that name. An action the channel does not declare is dropped, as Rails drops one it cannot call.
    def perform_fn(cable)
      arms = cable["channels"].each_with_index.flat_map do |channel, i|
        channel.fetch("performs", []).map do |p|
          body = p["body"]
          "        (#{AxumDsl.rstr(channel['name'])}, #{AxumDsl.rstr(p['action'])}) => {\n            let _ = #{body_name(i, "perform_#{p['action']}")}(#{call_args(body, cable)}).await;\n        }"
        end
      end
      ["#[allow(unused_variables)]",
       "async fn axum_dsl_cable_perform(conn: &AxumDslCableConn, identifier: &str, data: Option<&::serde_json::Value>) {",
       "    let Some(sub) = conn.subs.get(identifier) else {",
       "        return;",
       "    };",
       "    let action = data",
       "        .and_then(|data| data.as_str())",
       "        .and_then(|data| ::serde_json::from_str::<::serde_json::Value>(data).ok())",
       "        .and_then(|data| data.get(\"action\").and_then(|action| action.as_str()).map(str::to_string));",
       "    let Some(action) = action else {",
       "        return;",
       "    };",
       "    let __user = &conn.user;",
       "    let room_id = sub.room_id;",
       "    let broadcasting = sub.broadcasting.as_str();",
       "    match (sub.channel, action.as_str()) {",
       *arms.flat_map { |a| a.lines.map(&:chomp) },
       "        _ => {}",
       "    }",
       "}"]
    end

    # Whether the identifier of a `subscribe` names a declared channel with what it needs, and if so which
    # streams it joins: the signed stream name that verifies, the room the user belongs to, what the channel's
    # `stream_from` and `stream_for` say. The subscription is registered with the hub before `after_subscribe` runs.
    def admit_fn(cable, member)
      channels = cable["channels"]
      arms = channels.each_with_index.flat_map { |c, i| arm(c, i, cable) }
      helpers = []
      if channels.any? { |c| c["room_param"] }
        helpers.concat(lines(<<~'RS'))
          fn axum_dsl_cable_i64(value: Option<&::serde_json::Value>) -> Option<i64> {
              match value? {
                  ::serde_json::Value::Number(number) => number.as_i64(),
                  ::serde_json::Value::String(text) => text.parse().ok(),
                  _ => None,
              }
          }

        RS
      end
      if channels.any? { |c| c["signed_stream"] && c["member_of"] }
        helpers.concat(lines(<<~'RS'))
          // The room a signed stream name is about: its first part is a Global ID param, `gid://app/Model/ID` in url-safe base64.
          fn axum_dsl_cable_stream_room(name: &str) -> Option<i64> {
              use ::base64::Engine;
              let gid = name.split(':').next()?;
              let decoded = ::base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(gid.trim_end_matches('=')).ok()?;
              let text = String::from_utf8(decoded).ok()?;
              text.strip_prefix("gid://")?.rsplit('/').next()?.parse().ok()
          }

        RS
      end
      [*helpers,
       "#[allow(unused_variables, unused_mut)]",
       "async fn axum_dsl_cable_admit(conn: &AxumDslCableConn, identifier: &str) -> Option<AxumDslCableSub> {",
       "    let options = ::serde_json::from_str::<::serde_json::Value>(identifier).ok()?;",
       "    let __user = &conn.user;",
       "    let sub = match options.get(\"channel\").and_then(|channel| channel.as_str())? {",
       *arms.map { |l| "        #{l}" },
       "        _ => return None,",
       "    };",
       "    Some(sub)",
       "}"]
    end

    # The match arm of one channel: validate the identifier, find the room, join the streams, and run `after_subscribe`.
    def arm(channel, index, cable)
      name = AxumDsl.rstr(channel["name"])
      member = channel["member_of"]
      out = []
      if channel["signed_stream"]
        out << "let stream = options.get(\"signed_stream_name\").and_then(|signed| signed.as_str()).and_then(|signed| axum_dsl_turbo_verified_stream_name(settings().#{channel['signed_stream']}.as_bytes(), signed))?;"
      end
      if channel["room_param"]
        out << "let room_id = axum_dsl_cable_i64(options.get(#{AxumDsl.rstr(channel['room_param'])}))?;"
      elsif channel["signed_stream"] && member
        out << "let room_id = axum_dsl_cable_stream_room(&stream)?;"
      else
        out << "let room_id: i64 = 0;"
      end
      if member
        out << "let user_id: i64 = { let user = __user.clone(); #{cable['user_id']} };"
        out << "let room = match #{Db.fn_name(member)}(#{member['args'].map { |a| a == 'id' ? 'room_id' : 'user_id' }.join(', ')}).await {"
        out << "    Ok(Some(room)) => room,"
        out << "    _ => return None,"
        out << "};"
        if (hook = channel["on_subscribe"])
          out << "let _ = #{Db.fn_name(hook)}(#{hook['args'].join(', ')}).await;"
        end
      end
      out << "let mut streams: Vec<String> = Vec::new();"
      out << "streams.push(stream.clone());" if channel["signed_stream"]
      if (body = channel["stream_from"])
        out << "streams.push(#{body_name(index, 'stream_from')}(#{call_args(body, cable)}).await.ok()?);"
      end
      if (body = channel["stream_for"])
        out << "let broadcasting = format!(\"{}:{}\", #{AxumDsl.rstr(channel['broadcasting'])}, #{body_name(index, 'stream_for')}(#{call_args(body, cable)}).await.ok()?);"
        out << "streams.push(broadcasting.clone());"
      else
        out << "let broadcasting = String::new();"
      end
      out << "let sub = AxumDslCableSub { channel: #{name}, room_id, streams, broadcasting };"
      out << "axum_dsl_cable_register(conn, identifier, &sub)?;"
      if (body = channel["after_subscribe"])
        out << "let broadcasting = sub.broadcasting.clone();"
        out << "let _ = #{body_name(index, 'after_subscribe')}(#{call_args(body, cable)}).await;"
      end
      out << "sub"
      ["#{name} => {", *out.map { |l| "    #{l}" }, "}"]
    end

    RUNTIME = <<~'RS'
      // Action Cable (cable @@PATH@@): the actioncable-v1-json protocol and the in-process hub the broadcasts go through: written by the compiler
      const AXUM_DSL_CABLE_PROTOCOL: &str = @@PROTOCOL@@;
      // Frames a connection may have waiting; a broadcast never waits for a slow socket, it drops the frame that does not fit.
      const AXUM_DSL_CABLE_QUEUE: usize = 256;

      // Flipped when the server is asked to stop, so every open socket says goodbye and the server can drain.
      static AXUM_DSL_CABLE_STOP: ::std::sync::LazyLock<::tokio::sync::watch::Sender<bool>> =
          ::std::sync::LazyLock::new(|| ::tokio::sync::watch::channel(false).0);

      fn axum_dsl_cable_stop() {
          AXUM_DSL_CABLE_STOP.send_replace(true);
      }

      // One subscription listening on a broadcasting name: the connection's queue, and the start of the frame it is sent in
      // (`{"identifier":"...","message":`), already escaped, so a broadcast only adds its message and a closing brace.
      #[allow(dead_code)]
      struct AxumDslCableTarget {
          connection: u64,
          identifier: String,
          head: String,
          queue: ::tokio::sync::mpsc::Sender<String>,
      }

      static AXUM_DSL_CABLE_HUB: ::std::sync::LazyLock<::std::sync::Mutex<::std::collections::HashMap<String, Vec<AxumDslCableTarget>>>> =
          ::std::sync::LazyLock::new(|| ::std::sync::Mutex::new(::std::collections::HashMap::new()));
      static AXUM_DSL_CABLE_IDS: ::std::sync::atomic::AtomicU64 = ::std::sync::atomic::AtomicU64::new(1);

      // The subscription a connection holds for one identifier: what it was made for, and where it listens.
      #[allow(dead_code)]
      struct AxumDslCableSub {
          channel: &'static str,
          room_id: i64,
          streams: Vec<String>,
          broadcasting: String,
      }

      #[allow(dead_code)]
      struct AxumDslCableConn {
          id: u64,
          user: @@USER_RUST@@,
          queue: ::tokio::sync::mpsc::Sender<String>,
          subs: ::std::collections::HashMap<String, AxumDslCableSub>,
      }

      // The open connections by id: the signed-in user's identity (a record current's id, an :i64 or a string), and the switch `close_remote_connections` flips to ask that
      // connection's session to send the remote disconnect and close (Some(reconnect)). Flipping never waits for a socket.
      static AXUM_DSL_CABLE_REMOTE: ::std::sync::LazyLock<::std::sync::Mutex<::std::collections::HashMap<u64, (String, ::tokio::sync::watch::Sender<Option<bool>>)>>> =
          ::std::sync::LazyLock::new(|| ::std::sync::Mutex::new(::std::collections::HashMap::new()));

      // `ActionCable.server.remote_connections.where(current_user: user).disconnect(reconnect:)`: every open connection of this
      // user is told to send `{"type":"disconnect","reason":"remote","reconnect":...}` and close, which runs the same cleanup as
      // a closed socket (on_unsubscribe). The route goes on at once.
      #[allow(dead_code)]
      fn axum_dsl_cable_close_remote(user_key: &str, reconnect: bool) {
          let remote = AXUM_DSL_CABLE_REMOTE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
          for (owner, switch) in remote.values() {
              if owner == user_key {
                  switch.send_replace(Some(reconnect));
              }
          }
      }

      // ActiveSupport's JSON escaping of HTML characters, which Rails applies to every frame it writes.
      #[allow(dead_code)]
      fn axum_dsl_cable_escape(json: &str) -> String {
          json.replace('<', "\\u003c").replace('>', "\\u003e").replace('&', "\\u0026")
      }

      // ERB::Util.unwrapped_html_escape, for a turbo-stream tag's attribute.
      #[allow(dead_code)]
      fn axum_dsl_cable_attr(text: &str) -> String {
          text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
      }

      fn axum_dsl_cable_join(stream: &str, target: AxumDslCableTarget) {
          let mut hub = AXUM_DSL_CABLE_HUB.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
          hub.entry(stream.to_string()).or_default().push(target);
      }

      fn axum_dsl_cable_leave(connection: u64, streams: &[String], identifier: &str) {
          let mut hub = AXUM_DSL_CABLE_HUB.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
          for stream in streams {
              let empty = match hub.get_mut(stream) {
                  Some(targets) => {
                      targets.retain(|target| !(target.connection == connection && target.identifier == identifier));
                      targets.is_empty()
                  }
                  None => false,
              };
              if empty {
                  hub.remove(stream);
              }
          }
      }

      // Registers a subscription under each stream it listens to.
      fn axum_dsl_cable_register(conn: &AxumDslCableConn, identifier: &str, sub: &AxumDslCableSub) -> Option<()> {
          let quoted = ::serde_json::to_string(identifier).ok()?;
          let head = axum_dsl_cable_escape(&format!("{{\"identifier\":{},\"message\":", quoted));
          for stream in &sub.streams {
              let target = AxumDslCableTarget { connection: conn.id, identifier: identifier.to_string(), head: head.clone(), queue: conn.queue.clone() };
              axum_dsl_cable_join(stream, target);
          }
          Some(())
      }

      // Hands one message (JSON text) to every subscription listening on the name, in the order the calls are made.
      // `try_send` never waits: a connection whose queue is full loses the frame, and the route that broadcast goes on.
      // AXUM_DSL_CABLE_LOG=<file>: every broadcast is also appended to the file as one JSON line,
      // {"stream": name, "message": the JSON text sent}, and every stream counts as listened to, so a test outside the
      // process sees what Action Cable's test adapter would hold (campfire_axum_dsl's test/rails_tests replays it into
      // Rails' pubsub for assert_broadcasts and assert_turbo_stream_broadcasts).
      #[allow(dead_code)]
      fn axum_dsl_cable_log() -> Option<&'static ::std::sync::Mutex<::std::fs::File>> {
          static LOG: ::std::sync::OnceLock<Option<::std::sync::Mutex<::std::fs::File>>> = ::std::sync::OnceLock::new();
          LOG.get_or_init(|| {
              let path = ::std::env::var("AXUM_DSL_CABLE_LOG").ok().filter(|path| !path.is_empty())?;
              ::std::fs::OpenOptions::new().create(true).append(true).open(path).ok().map(::std::sync::Mutex::new)
          })
          .as_ref()
      }

      #[allow(dead_code)]
      fn axum_dsl_cable_broadcast(stream: &str, json: String) {
          if let Some(log) = axum_dsl_cable_log() {
              use ::std::io::Write;
              let line = ::serde_json::json!({ "stream": stream, "message": json }).to_string();
              let mut file = log.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
              let _ = writeln!(file, "{line}");
              let _ = file.flush();
          }
          let message = axum_dsl_cable_escape(&json);
          let hub = AXUM_DSL_CABLE_HUB.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
          if let Some(targets) = hub.get(stream) {
              for target in targets {
                  let _ = target.queue.try_send(format!("{}{}}}", target.head, message));
              }
          }
      }

      // Whether any subscription is listening on the stream these parts name. `broadcast_turbo` uses it to skip
      // rendering a template when there is nobody to send it to.
      #[allow(dead_code)]
      fn axum_dsl_cable_listening(parts: &[&str]) -> bool {
          let parts: Vec<&str> = parts.iter().copied().filter(|part| !part.trim().is_empty()).collect();
          if parts.is_empty() {
              return false;
          }
          if axum_dsl_cable_log().is_some() {
              return true;
          }
          let hub = AXUM_DSL_CABLE_HUB.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
          hub.get(&parts.join(":")).is_some_and(|targets| !targets.is_empty())
      }

      // Turbo::StreamsChannel.broadcast_<action>_to: the parts are the stream name (blank ones dropped, nothing sent when none is
      // left), the message is the `<turbo-stream>` tag as a JSON string. Extra attributes come first, then action and target.
      #[allow(dead_code)]
      fn axum_dsl_cable_broadcast_turbo(parts: &[&str], action: &str, target: &str, html: Option<&str>, maintain_scroll: bool) {
          let parts: Vec<&str> = parts.iter().copied().filter(|part| !part.trim().is_empty()).collect();
          if parts.is_empty() {
              return;
          }
          let mut tag = String::from("<turbo-stream");
          if maintain_scroll {
              tag.push_str(" maintain_scroll=\"true\"");
          }
          tag.push_str(&format!(" action=\"{}\" target=\"{}\">", action, axum_dsl_cable_attr(target)));
          if let Some(html) = html {
              tag.push_str("<template>");
              tag.push_str(html);
              tag.push_str("</template>");
          }
          tag.push_str("</turbo-stream>");
          axum_dsl_cable_broadcast(&parts.join(":"), ::serde_json::Value::String(tag).to_string());
      }

      async fn axum_dsl_cable(
          ws: ::axum::extract::ws::WebSocketUpgrade,
          ::axum::extract::ConnectInfo(peer): ::axum::extract::ConnectInfo<::std::net::SocketAddr>,
          headers: ::axum::http::HeaderMap,
      ) -> ::axum::response::Response {
          ws.protocols([AXUM_DSL_CABLE_PROTOCOL])
              .on_upgrade(move |socket| axum_dsl_cable_session(socket, headers, peer))
      }

      async fn axum_dsl_cable_session(mut socket: ::axum::extract::ws::WebSocket, headers: ::axum::http::HeaderMap, peer: ::std::net::SocketAddr) {
          use ::axum::extract::ws::Message;
          let currents = AxumDslCurrents::default();
          let user: @@USER_RUST@@ = match axum_dsl_current_@@AUTH@@(&headers, Some(peer), &currents).await {
              Ok(Some(user)) => user,
              Ok(None) => {
                  let _ = socket
                      .send(Message::Text(r#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#.into()))
                      .await;
                  let _ = socket.send(Message::Close(None)).await;
                  return;
              }
              Err(_) => {
                  let _ = socket.send(Message::Close(None)).await;
                  return;
              }
          };
          let mut stop = AXUM_DSL_CABLE_STOP.subscribe();
          let goodbye = r#"{"type":"disconnect","reason":"server_restart","reconnect":true}"#;
          if *stop.borrow() {
              let _ = socket.send(Message::Text(goodbye.into())).await;
              let _ = socket.send(Message::Close(None)).await;
              return;
          }
          if socket.send(Message::Text(r#"{"type":"welcome"}"#.into())).await.is_err() {
              return;
          }
          let period = ::std::time::Duration::from_secs(3);
          let mut beat = ::tokio::time::interval_at(::tokio::time::Instant::now() + period, period);
          let (queue, mut inbox) = ::tokio::sync::mpsc::channel::<String>(AXUM_DSL_CABLE_QUEUE);
          let id = AXUM_DSL_CABLE_IDS.fetch_add(1, ::std::sync::atomic::Ordering::Relaxed);
          let user_key: String = @@USER_KEY@@;
          let (switch, mut remote) = ::tokio::sync::watch::channel(None::<bool>);
          AXUM_DSL_CABLE_REMOTE.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert(id, (user_key, switch));
          let mut conn = AxumDslCableConn { id, user, queue, subs: ::std::collections::HashMap::new() };
          loop {
              ::tokio::select! {
                  Ok(()) = remote.changed() => {
                      let reconnect = remote.borrow_and_update().unwrap_or(true);
                      let _ = socket
                          .send(Message::Text(format!(r#"{{"type":"disconnect","reason":"remote","reconnect":{reconnect}}}"#).into()))
                          .await;
                      let _ = socket.send(Message::Close(None)).await;
                      break;
                  }
                  _ = stop.changed() => {
                      let _ = socket.send(Message::Text(goodbye.into())).await;
                      let _ = socket.send(Message::Close(None)).await;
                      break;
                  }
                  _ = beat.tick() => {
                      let seconds = ::std::time::SystemTime::now()
                          .duration_since(::std::time::UNIX_EPOCH)
                          .map(|elapsed| elapsed.as_secs())
                          .unwrap_or(0);
                      if socket.send(Message::Text(format!(r#"{{"type":"ping","message":{seconds}}}"#).into())).await.is_err() {
                          break;
                      }
                  }
                  frame = inbox.recv() => {
                      if let Some(frame) = frame {
                          if socket.send(Message::Text(frame.into())).await.is_err() {
                              break;
                          }
                      }
                  }
                  incoming = socket.recv() => match incoming {
                      Some(Ok(Message::Text(text))) => {
                          let mut gone = false;
                          for reply in axum_dsl_cable_command(&mut conn, text.as_str()).await {
                              if socket.send(Message::Text(reply.into())).await.is_err() {
                                  gone = true;
                                  break;
                              }
                          }
                          if gone {
                              break;
                          }
                      }
                      Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                      Some(Ok(_)) => {}
                  },
              }
          }
          AXUM_DSL_CABLE_REMOTE.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&id);
          axum_dsl_cable_close(&mut conn).await;
      }
    RS

    COMMANDS = <<~'RS'
      // One client command. `subscribe` answers with the confirmation or the rejection of its identifier; a repeated
      // subscribe to an identifier already held answers nothing. `unsubscribe` leaves the streams and runs on_unsubscribe,
      // `message` performs the channel's action of that name, and any other command answers nothing, as Rails does.
      async fn axum_dsl_cable_command(conn: &mut AxumDslCableConn, text: &str) -> Vec<String> {
          let Ok(command) = ::serde_json::from_str::<::serde_json::Value>(text) else {
              return Vec::new();
          };
          let Some(identifier) = command.get("identifier").and_then(|identifier| identifier.as_str()) else {
              return Vec::new();
          };
          let identifier = identifier.to_string();
          match command.get("command").and_then(|name| name.as_str()) {
              Some("subscribe") => {
                  if conn.subs.contains_key(&identifier) {
                      return Vec::new();
                  }
                  let admitted = axum_dsl_cable_admit(conn, &identifier).await;
                  let kind = if admitted.is_some() { "confirm_subscription" } else { "reject_subscription" };
                  if let Some(sub) = admitted {
                      conn.subs.insert(identifier.clone(), sub);
                  }
                  match ::serde_json::to_string(&identifier) {
                      Ok(quoted) => vec![format!(r#"{{"identifier":{},"type":"{}"}}"#, quoted, kind)],
                      Err(_) => Vec::new(),
                  }
              }
              Some("unsubscribe") => {
                  axum_dsl_cable_drop(conn, &identifier).await;
                  Vec::new()
              }
              Some("message") => {
                  axum_dsl_cable_perform(conn, &identifier, command.get("data")).await;
                  Vec::new()
              }
              _ => Vec::new(),
          }
      }

      // Leaves the streams of one subscription and runs its channel's on_unsubscribe.
      async fn axum_dsl_cable_drop(conn: &mut AxumDslCableConn, identifier: &str) {
          let Some(sub) = conn.subs.remove(identifier) else {
              return;
          };
          axum_dsl_cable_leave(conn.id, &sub.streams, identifier);
          axum_dsl_cable_unsubscribed(&conn.user, &sub).await;
      }

      // A closed socket drops every subscription it held, as Rails' `unsubscribe_from_all` does.
      async fn axum_dsl_cable_close(conn: &mut AxumDslCableConn) {
          let identifiers: Vec<String> = conn.subs.keys().cloned().collect();
          for identifier in identifiers {
              axum_dsl_cable_drop(conn, &identifier).await;
          }
      }
    RS
  end
end
