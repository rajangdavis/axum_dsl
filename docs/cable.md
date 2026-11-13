# Action Cable

_See also: [README](../README.md), [The DSL](dsl.md), [Sessions](sessions.md), [Coverage](coverage.md)._

A service can answer an Action Cable endpoint without a line of Rust of the app's own: the compiler writes the
WebSocket upgrade, the session loop and the subscription check into the emitted crate, only when the file declares
`cable`. The wire format is the one Rails' `@rails/actioncable` client speaks, `actioncable-v1-json`: `welcome`,
a `ping` every 3 seconds, `confirm_subscription` or `reject_subscription` for each `subscribe`, and a `disconnect`
message before the socket closes (`unauthorized`, `server_restart`, or `remote` when a route calls `close_remote_connections`).

A subscription is authorized (or not) and confirmed (or rejected). A channel then says what it listens to
(`stream_from`, `stream_for`, or the verified name of a Turbo signed stream), and a route or a channel callback sends to
those names with `broadcast`, `broadcast_to` and `broadcast_turbo` (see [Channel callbacks](#channel-callbacks) and
[Broadcasting](#broadcasting)). A client's `message` and `unsubscribe` commands reach the channel's `perform` and
`on_unsubscribe` callbacks.

## The declaration

```ruby
current :user, returns: :User? do
  token = cookie(:session_token)
  token.nil? ? nil : user_for_session(token: token)
end

cable "/cable", authenticate_with: :user do
  channel "PresenceChannel", room_param: :room_id, member_of: :room_for_user
  channel "TypingNotificationsChannel", room_param: :room_id, member_of: :room_for_user
  channel "RoomMessagesChannel", signed_stream: :secret_key, member_of: :room_for_user
  channel "ReadRoomsChannel"
  channel "HeartbeatChannel"
  channel "UnreadRoomsChannel"
end
```

`cable path, authenticate_with: current` declares one endpoint per service. The path is written like a
`serve_file` path and must not also be answered by a GET route, another served file, the OpenAPI document or a
`static` mount. `authenticate_with:` names a nil-able `current`: `returns: :Record?` for a record, or a scalar type
with `?` such as `:i64?`. Nil is the connection that is not signed in.

A named `before` filter does not run for the endpoint: it authenticates itself, so the same session cookie a route
reads is read here, and a filter's redirect-to-login is not what an unauthorised WebSocket gets. Unnamed filters
still run.

`channel "Name"` declares one name a client may subscribe to. The name is the class name the client sends in its
identifier (`PresenceChannel`, `TypingNotificationsChannel`, and so on), not a Ruby constant. Subscribing to any
name the block does not declare is rejected. A name may be declared once.

## Authentication

The current named by `authenticate_with:` is computed from the upgrade request's own headers, exactly as a route
computes it: a signed session cookie is verified by the same code, and a database-backed current runs the same
query. The peer address is available to the current too, so `request_ip` sees the WebSocket client.

A request with a nil current is upgraded and then told

```json
{"type":"disconnect","reason":"unauthorized","reconnect":false}
```

and the socket is closed. A current that fails (for example, a database error) closes the socket without a
`disconnect` frame. A request that carries a valid user but subscribes to a room the user is not in gets
`reject_subscription` for that subscription, not a connection-level disconnect.

## The wire protocol

The client asks for the `actioncable-v1-json` subprotocol. The server selects it and then:

1. authenticates the connection, as above;
2. sends `{"type":"welcome"}`;
3. sends `{"type":"ping","message":<unix seconds>}` every 3 seconds;
4. reads one JSON command per text frame.

A `subscribe` command carries its identifier as a JSON **string**:

```json
{"command":"subscribe","identifier":"{\"channel\":\"PresenceChannel\",\"room_id\":1}"}
```

The server parses that string and answers with the same identifier text, so the client can match the reply:

```json
{"identifier":"{\"channel\":\"PresenceChannel\",\"room_id\":1}","type":"confirm_subscription"}
```

or

```json
{"identifier":"{\"channel\":\"NotAChannel\"}","type":"reject_subscription"}
```

An identifier already subscribed is not confirmed twice. `unsubscribe` leaves the subscription's streams, runs the
channel's `on_unsubscribe` and answers nothing; `message` calls the channel's `perform` (see
[Channel callbacks](#channel-callbacks)) and answers nothing itself; every command the endpoint does not know answers
nothing. A closed socket ends the session and drops every subscription it held, running `on_unsubscribe` for each, as
Rails' `unsubscribe_from_all` does.

When the server is asked to stop, every open socket is told

```json
{"type":"disconnect","reason":"server_restart","reconnect":true}
```

and closed, so the graceful shutdown can drain instead of waiting for long-lived connections.

## Channel options

A channel is confirmed when its identifier satisfies every option it declares. The options combine:

- **`room_param:`** names the identifier key that holds a room id, such as `:room_id`. The value may be a JSON
  number or a numeric string. Without it, the subscription is rejected.
- **`signed_stream:`** names the required string setting that holds `SECRET_KEY_BASE` (the same setting another
  signing call names, such as `:secret_key`). The identifier must carry a `signed_stream_name` that Turbo's
  verifier accepts; a bad signature, bad base64 or a value that is not a JSON string rejects the subscription.
  This is the option a `<turbo-cable-stream-source>` sends: the view writes the name with
  `turbo_signed_stream_name(global_id_param("Rooms::Open", room.id, app: "campfire"), :messages, secret:
  :secret_key)`.
- **`member_of:`** names a `query` with the arguments `id:` and `user_id:` (both `:i64`) that returns `:Record?`.
  The subscription is confirmed only when the query finds a row: the user's membership in the room. It needs
  `room_param:` or `signed_stream:` to say which room to ask about.
- **`on_subscribe:`** names an `execute` (a `query` also works) with the arguments `room_id:` and `user_id:` (both
  `:i64`). It runs once for each subscription that was just confirmed, never for a rejected one or a repeated
  subscribe, and its result and any error are ignored. It needs `member_of:`, which supplies the user. The
  statement runs on the confirming path, before the subscription's streams are joined and before the
  `confirm_subscription` frame is written. Rails' `PresenceChannel` uses this to mark the membership connected and
  read (`Membership.connect`). What runs afterwards, and what runs when the subscription ends, is a block
  (`after_subscribe`, `on_unsubscribe`, below).

With `signed_stream:`, the room is derived, not taken from the identifier: the verified stream name is split at
the first `:`, its first part is decoded as a Global ID param (`gid://<app>/<Model>/<id>`, url-safe base64), and
the last segment is the room id. The room the client names in some other field is never used for the membership
check. With `room_param:`, the id comes from that key.

A channel with none of the three options and no block is confirmed for any authenticated connection and listens to
nothing:

```ruby
channel "HeartbeatChannel"
```

## Channel callbacks

A channel may take a block. Its calls say what the subscription listens to and what happens as it starts and ends:

```ruby
cable "/cable", authenticate_with: :user do
  channel "ReadRoomsChannel" do
    stream_from { |user| "user_#{user.id}_reads" }
  end

  channel "TypingNotificationsChannel", room_param: :room_id, member_of: :room_for_user do
    stream_for { |room| global_id_param(room.kind, room.id, app: "campfire") }
    perform :start do |user|
      broadcast_to "action" => "start", "user" => json_object("id" => user.id, "name" => user.name)
    end
    perform :stop do |user|
      broadcast_to "action" => "stop", "user" => json_object("id" => user.id, "name" => user.name)
    end
  end

  channel "PresenceChannel", room_param: :room_id, member_of: :room_for_user, on_subscribe: :connect_membership do
    after_subscribe { |user, room_id| broadcast "user_#{user.id}_reads", "room_id" => room_id }
    on_unsubscribe { |user, room_id| disconnect_membership(room_id: room_id, user_id: user.id) }
    perform(:refresh) { |user, room_id| refresh_membership(room_id: room_id, user_id: user.id) }
  end
end
```

Each block is a body, like a route's, and names the values it wants as block parameters, in any order and only the
ones it reads (an unread parameter is refused, as an unread local is):

| Parameter | What it is | Offered to |
|-----------|------------|------------|
| the `current`'s name (`user`) | the signed-in user, a record or a scalar, never nil | every callback |
| `room_id` | the room id, as an `:i64`, from `room_param:` or, with `member_of:`, from the signed stream name | every callback, on a channel that has one |
| `room` | the row `member_of:` found | `stream_from`, `stream_for` and `after_subscribe` |

- `stream_from { ... }` ends in a string: the broadcasting name the subscription listens to, Rails' `stream_from`.
- `stream_for { ... }` ends in a string too (a Global ID param, for a record): the broadcasting name is the channel's
  name underscored (`ActionCable::Channel::Naming#channel_name`: the class name without `Channel`, `::` as `:`) and
  a colon in front of it, Rails' `broadcasting_for`. `TypingNotificationsChannel` with a room's Global ID param
  `Z2lkOi8vY2FtcGZpcmUvUm9vbXM6Ok9wZW4vMQ` listens on
  `typing_notifications:Z2lkOi8vY2FtcGZpcmUvUm9vbXM6Ok9wZW4vMQ`, `Turbo::StreamsChannel` is `turbo:streams`.
- A channel with `signed_stream:` also listens to the verified stream name by itself (Turbo's
  `stream_from verified_stream_name_from_params`), so `RoomMessagesChannel` and `Turbo::StreamsChannel` declare no block.
  A channel may have several streams: the signed one, a `stream_from` and a `stream_for`.
- `after_subscribe { ... }` runs once each time a subscription has joined its streams. It runs before the
  `confirm_subscription` frame is written, but a frame it broadcasts goes through the connection's queue, so the client
  always sees the confirmation first. Its value and any error are ignored.
- `on_unsubscribe { ... }` runs when the client unsubscribes and, for each subscription still held, when the socket
  closes; its error is ignored.
- `perform :start do ... end` answers a `message` command whose `data` is the string `{"action":"start", ...}`, as
  the public method `start` of the Rails channel does. An action the channel does not declare is dropped, with no
  frame. The rest of `data` is not readable yet.
- A callback other than `stream_from` and `stream_for` ends in anything; it may leave early with a bare `return` in a
  guard clause (`return if cond`).
- A callback may call a `query` or `execute` (the statement runs on the pool, as a route's does), `broadcast`,
  `broadcast_to`, `broadcast_turbo`, `close_remote_connections`, `render_string` and the signing calls; it has no request, so it cannot read a cookie
  or `request_ip`.

## Broadcasting

The hub is part of the endpoint, so a file that broadcasts must declare a `cable`. Three calls send, in a route, a `before`
filter or a channel callback:

```ruby
# ActionCable.server.broadcast "user_#{id}_reads", { room_id: id }
broadcast "user_#{user.id}_reads", "room_id" => room.id

# broadcast_to @room, action: :start, user: {...} -- the name the channel's own stream_for made
broadcast_to "action" => "start", "user" => json_object("id" => user.id, "name" => user.name)

# Turbo::StreamsChannel.broadcast_append_to([room, :messages], target: ..., partial: ...)
broadcast_turbo global_id_param("Rooms::Open", room.id, app: "campfire"), :messages,
                action: :append, target: "messages_rooms_open_#{room.id}",
                html: render_string(:message, locals: { message: message }), maintain_scroll: true
```

- `broadcast(name, "key" => value, ...)` sends a JSON object. A value is a string, a number or a bool; `json_object("key" =>
  value)` nests an object. Keys keep the order they are written in (a Ruby hash's order, not alphabetical).
- `broadcast_to("key" => value, ...)` is `broadcast` to the name `stream_for` made for this subscription. It is only
  in a channel callback that runs once the stream is known (`after_subscribe`, `on_unsubscribe`, `perform`) and the channel
  declares a `stream_for`.
- `broadcast_turbo(*parts, action:, target:, html:, maintain_scroll:)` sends a `<turbo-stream>` tag. The positional parts are the
  stream name, strings or symbols joined with `:` as turbo-rails' `stream_name_from` does (a record is spelled with
  `global_id_param`); a blank part is dropped, and nothing is sent when none is left. `action:` is `:append`, `:prepend`,
  `:replace`, `:update`, `:before`, `:after` or `:remove`. `target:` is the element's id. `html:` is the template's
  markup and is required for every action but `:remove`, which writes no template. `maintain_scroll: true` writes
  `maintain_scroll="true"` (the one extra attribute Campfire uses). The attributes come in turbo-rails' order: `maintain_scroll`,
  then `action`, then `target`; the target is HTML-escaped. When `html:` is written directly as
  `render_string(...)`, the render is skipped when no subscription is listening on the stream, so a POST with no open
  socket does not build markup nobody will receive.
- `broadcast_append_to`, `broadcast_prepend_to`, `broadcast_replace_to`, `broadcast_update_to` and `broadcast_remove_to`
  `(streamable, *parts, target:, html:, maintain_scroll:, app:)` are turbo-rails' own spellings of the five common actions, and
  pure sugar: each lowers to exactly the Rust of the `broadcast_turbo` call with that `action:` (`broadcast_remove_to` takes
  no `html:`, as `action: :remove` takes none). The first argument is the streamable: a record (a `record` or a params
  struct) with `class_name` and `id` fields, whose stream part is `global_id_param(rec.class_name, rec.id, app: app)`, or
  anything `broadcast_turbo` takes as a part, unchanged. The other positionals are the rest of the stream name. No
  declaration names the GlobalID app, so a record needs `app: "campfire"` on the call; `app:` is refused when the first
  argument is not a record. `action:` is refused: the name says it.

  ```ruby
  # broadcast_remove_to room, :messages, target: "message_#{id}"   (turbo-rails)
  broadcast_remove_to room, :messages, target: "message_#{id}", app: "campfire"
  # the same call, spelled out
  broadcast_turbo global_id_param(room.class_name, room.id, app: "campfire"), :messages, action: :remove, target: "message_#{id}"
  ```
- `render_string(:message, locals: {...})` is the markup: a view rendered to a string, with no layout and no response. It is
  compiled into the crate and follows `render`'s rule for locals, partials and `{% for %}` (see [Views](views.md)); it is
  allowed in a route, a filter and a channel callback.

### The frame a subscriber receives

A broadcast becomes, for each subscription listening on the name, one text frame:

```json
{"identifier":"{\"channel\":\"TypingNotificationsChannel\",\"room_id\":1}","message":{"action":"start","user":{"id":2,"name":"Jason"}}}
{"identifier":"{\"channel\":\"RoomMessagesChannel\",\"signed_stream_name\":\"IloybGtP...\"}","message":"<turbo-stream action=\"remove\" target=\"message_1\"></turbo-stream>"}
```

`identifier` is the identifier string exactly as that client sent it when it subscribed (so two clients may hold the same
channel under identifiers that differ in key order or spacing, and each gets its own); `message` is a JSON object for
`broadcast`/`broadcast_to` and a JSON string for `broadcast_turbo`. The whole frame is written with ActiveSupport's JSON escaping:
`<`, `>` and `&` come out as `<`, `>` and `&`, and U+2028/U+2029 are not escaped (Rails 8.1's default). This was
checked against the frames Rails sends (the parity harness's cable logs and `once-campfire-rust`'s golden channel test).

### Delivery

- One process: the hub is a map from a broadcasting name to its subscriptions, in the crate. There is no Redis and no
  other process to share a broadcast with.
- A broadcast takes the hub's lock, `try_send`s the frame into each subscriber's queue and returns; it never waits for a socket.
  Each connection has a bounded queue of 256 frames that the session's loop drains onto the socket.
- Backpressure: a client too slow to drain 256 frames loses the frames that arrive while its queue is full; the route that
  broadcast does not notice. The connection stays up.
- Order: the frames of one broadcasting name reach a connection in the order the `broadcast` calls were made (the
  lock serialises them). Frames of different names are in the order they were queued.
- Cleanup: an `unsubscribe` removes the subscription's entries from the hub, and so does the close of the socket, for
  every subscription it held, before `on_unsubscribe` runs. A hub entry never outlives its connection.
- A broadcast to a name no one listens on is dropped.

### Watching broadcasts from a test

With `AXUM_DSL_CABLE_LOG=<file>` in the environment, every broadcast is also appended to the file as one JSON line,
`{"stream": "<name>", "message": "<the JSON text sent>"}`, and every stream counts as listened to (so a Turbo
broadcast renders even with no subscriber). A test in another process reads what Action Cable's test adapter would
hold: Campfire's `test/rails_tests` replays the lines into Rails' pubsub for `assert_broadcasts` and
`assert_turbo_stream_broadcasts`.

## Closing a user's connections

```ruby
# user.reset_remote_connections  (User#close_remote_connections reconnect: true)
close_remote_connections(user.id)
close_remote_connections(user.id, reconnect: false)   # User#deactivate and a ban: the client must not come back
```

`close_remote_connections(user_id, reconnect: true)` is `ActionCable.server.remote_connections.where(current_user: user).disconnect(reconnect:)`.
It is a statement for a route, a `before` filter or a channel callback, and needs a `cable`. Every open connection whose
authenticated user is that one (the `id` of a record current, the value of an `:i64` current, or a string current's own string) is sent `{"type":"disconnect","reason":"remote","reconnect":true}` (`false` when written `reconnect: false`; the
keys in that order, as Rails' `ActionCable::Connection::Base#close` transmits them) and the socket is closed. Closing unsubscribes
every channel the connection held, so `on_unsubscribe` runs as for a socket the client closed. Other users' connections are left
open, and a connection that opens afterwards is not affected: a client told `reconnect: true` comes back, authenticates again
and has its subscriptions checked again (a `member_of:` channel now rejects the room the user lost).

The call flips a switch on each matching connection and returns; the session sends the frame and closes from its own loop, so a
route never waits for a slow socket. The argument is an `:i64` expression (`user.id`) for a record or `:i64` current and a string for a string current; the compiler refuses the other. `reconnect:` is a literal `true` (the
default) or `false`.

## Limits

- One process, no Redis; a broadcast does not reach another instance.
- `perform` cannot read the `data` the client sent besides the action's name.
- The authorization is the connection's current plus, optionally, room membership. There are no roles, and the
  channel's own checks (`reject` in a callback) are not expressible beyond `member_of:`.
- A message is built from strings, numbers and bools (and `json_object` nesting); a list or a nil value is refused.
- `render_string` is for markup that does not read the request: there is no request in a channel callback.

## In Campfire

`campfire.axum.rb` declares `/cable` with `current :user` and the six channels the once-campfire client
subscribes to: `PresenceChannel`, `TypingNotificationsChannel` and `RoomMessagesChannel` (room membership
required, the third through Turbo's signed stream name), plus `ReadRoomsChannel`, `HeartbeatChannel` and
`UnreadRoomsChannel`. `test/cable_check.mjs` drives it against the e2e seed: it expects `welcome`, a ping, a
confirmation for each channel, a rejection for an undeclared channel, and the unauthorized disconnect without a
session cookie.
