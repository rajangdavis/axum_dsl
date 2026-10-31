# frozen_string_literal: true

# Action Cable broadcasts (docs/cable.md), asserted on the emitted Rust and on the refusals: a channel's callbacks
# (`stream_from`, `stream_for`, `after_subscribe`, `on_unsubscribe`, `perform`), the three broadcast calls and
# `render_string`. No cargo and no socket; test/e2e_cable.sh drives the running service and checks the frames.
#
#   ruby -Ilib test/test_cable_broadcast.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestCableBroadcast < Minitest::Test
  HEAD = <<~RB
    server "chat", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    cookies secret: :secret_key
    current :user, returns: :string? do
      cookie(:who)
    end
  RB

  MEMBER_HEAD = <<~RB
    server "chat", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    cookies secret: :secret_key
    database :sqlite, path: "chat.sqlite3"
    record :User do
      field :id, :i64
    end
    record :Room do
      field :id, :i64
      field :kind, :string
    end
    query :user_for_token, args: { token: :string }, returns: :User?, sql: "SELECT id FROM users WHERE token = :token"
    current :user, returns: :User? do
      token = cookie(:token)
      token.nil? ? nil : user_for_token(token: token)
    end
    query :room_for_user, args: { id: :i64, user_id: :i64 }, returns: :Room?, sql: "SELECT id, kind FROM rooms WHERE id = :id AND owner_id = :user_id"
  RB

  def compile(body, head: HEAD, views: {})
    Dir.mktmpdir("chat") do |dir|
      views.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "chat.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(body, head: HEAD, views: {})
    assert_raises(AxumDsl::CompileError) { compile(body, head: head, views: views) }.message
  end

  def cable(channels)
    "cable \"/cable\", authenticate_with: :user do\n#{channels}\nend\n"
  end

  NOTE = { "views/note.html" => "<p>{{ text }}</p>" }.freeze

  def test_channel_names_are_rails
    assert_equal "presence", AxumDsl::Cable.channel_name("PresenceChannel")
    assert_equal "typing_notifications", AxumDsl::Cable.channel_name("TypingNotificationsChannel")
    assert_equal "turbo:streams", AxumDsl::Cable.channel_name("Turbo::StreamsChannel")
    assert_equal "room", AxumDsl::Cable.channel_name("RoomChannel")
  end

  def test_a_channel_without_a_block_still_works
    rust = compile(cable('channel "HeartbeatChannel"'))
    assert_includes rust, "static AXUM_DSL_CABLE_HUB"
    assert_includes rust, '"HeartbeatChannel" => {'
    refute_includes rust, "axum_dsl_cable_0_"
  end

  def test_stream_from_names_the_broadcasting_the_user_listens_on
    rust = compile(cable(<<~RB))
      channel "NoticesChannel" do
        stream_from { |user| "notices_for_\#{user}" }
      end
    RB
    assert_includes rust, "async fn axum_dsl_cable_0_stream_from(user: String) -> Result<String, String> {"
    assert_includes rust, "streams.push(axum_dsl_cable_0_stream_from(__user.clone()).await.ok()?);"
  end

  def test_stream_for_prefixes_the_underscored_channel_name
    rust = compile(cable(<<~RB))
      channel "TypingNotificationsChannel", room_param: :room_id do
        stream_for { |room_id| "room-\#{room_id}" }
      end
    RB
    assert_includes rust, "async fn axum_dsl_cable_0_stream_for(room_id: i64) -> Result<String, String> {"
    assert_includes rust, 'let broadcasting = format!("{}:{}", "typing_notifications", axum_dsl_cable_0_stream_for(room_id).await.ok()?);'
    assert_includes rust, "streams.push(broadcasting.clone());"
  end

  def test_a_signed_stream_listens_on_its_verified_name
    rust = compile(cable('channel "BoardChannel", signed_stream: :secret_key'))
    assert_includes rust, "streams.push(stream.clone());"
  end

  def test_perform_after_subscribe_and_on_unsubscribe_are_dispatched_by_channel
    rust = compile(cable(<<~RB))
      channel "ChatChannel", room_param: :room_id do
        stream_for { |room_id| "room-\#{room_id}" }
        after_subscribe { |user| broadcast("log", "joined" => user) }
        on_unsubscribe { |user| broadcast("log", "left" => user) }
        perform :speak do |user|
          broadcast_to("who" => user)
        end
      end
    RB
    assert_includes rust, "async fn axum_dsl_cable_0_perform_speak(user: String, __stream_for: &str) -> Result<(), String> {"
    assert_includes rust, "let _ = axum_dsl_cable_0_perform_speak(__user.clone(), &broadcasting).await;"
    assert_includes rust, '("ChatChannel", "speak") => {'
    assert_includes rust, "let _ = axum_dsl_cable_0_after_subscribe(__user.clone()).await;"
    assert_includes rust, "let _ = axum_dsl_cable_0_on_unsubscribe(__user.clone()).await;"
    assert_includes rust, "axum_dsl_cable_broadcast(__stream_for, "
  end

  def test_the_subscription_is_registered_before_after_subscribe_runs
    rust = compile(cable(<<~RB))
      channel "ChatChannel", room_param: :room_id do
        after_subscribe { |user| broadcast("log", "joined" => user) }
      end
    RB
    assert_operator rust.index("axum_dsl_cable_register(conn, identifier, &sub)?;"), :<, rust.index("let _ = axum_dsl_cable_0_after_subscribe(")
  end

  def test_a_member_channel_gives_a_stream_callback_the_room_row
    rust = compile(cable(<<~RB), head: MEMBER_HEAD)
      channel "RoomChannel", room_param: :room_id, member_of: :room_for_user do
        stream_for { |room| global_id_param(room.kind, room.id, app: "campfire") }
        on_unsubscribe { |user, room_id| broadcast("gone", "user" => user.id, "room" => room_id) }
      end
    RB
    assert_includes rust, "async fn axum_dsl_cable_0_stream_for(room: Room) -> Result<String, String> {"
    assert_includes rust, "async fn axum_dsl_cable_0_on_unsubscribe(user: User, room_id: i64) -> Result<(), String> {"
    assert_includes rust, "let room = match query_room_for_user(room_id, user_id).await {"
    assert_includes rust, 'format!("{}:{}", "room", axum_dsl_cable_0_stream_for(room.clone()).await.ok()?)'
    assert_includes rust, "let _ = axum_dsl_cable_0_on_unsubscribe(__user.clone(), room_id).await;"
  end

  def test_room_is_not_offered_once_the_subscription_exists
    message = refusal(cable(<<~RB), head: MEMBER_HEAD)
      channel "RoomChannel", room_param: :room_id, member_of: :room_for_user do
        on_unsubscribe { |room| broadcast("gone", "room" => room.id) }
      end
    RB
    assert_match(/`room` is not available to this callback \(it can take: user, room_id\)/, message)
  end

  def test_a_route_broadcasts_a_json_object_in_the_order_written
    rust = compile(<<~RB + cable('channel "HeartbeatChannel"'))
      get "/n" do
        broadcast "reads", "b" => 1, "a" => "x"
        "sent"
      end
    RB
    assert_includes rust, 'axum_dsl_cable_broadcast("reads", format!("{{{}}}", ['
    assert_operator rust.index('"\"b\""'), :<, rust.index('"\"a\""')
    assert_includes rust, "::serde_json::Value::from(1 as i64).to_string()"
  end

  def test_a_nested_json_object_stays_an_object
    rust = compile(<<~RB + cable('channel "HeartbeatChannel"'))
      get "/n" do
        broadcast "typing", "action" => "start", "user" => json_object("id" => 1, "name" => "Jason")
        "sent"
      end
    RB
    assert_includes rust, '"\"user\"", format!("{{{}}}", ['
    assert_includes rust, '"\"name\"", ::serde_json::Value::from("Jason").to_string()'
  end

  def test_broadcast_turbo_builds_the_tag_with_an_escaped_target_and_a_template
    rust = compile(<<~RB + cable('channel "BoardChannel", signed_stream: :secret_key'), views: NOTE)
      get "/n" do
        broadcast_turbo("board", :messages, action: :append, target: "notes", html: render_string(:note, locals: { text: "hi" }), maintain_scroll: true)
        "sent"
      end
    RB
    assert_includes rust, 'if axum_dsl_cable_listening(&["board", "messages"]) {'
    assert_includes rust, 'axum_dsl_cable_broadcast_turbo(&["board", "messages"], "append", "notes", Some('
    assert_includes rust, '.as_str()), true);'
    assert_includes rust, 'tag.push_str(" maintain_scroll=\"true\"");'
    assert_includes rust, 'tag.push_str(&format!(" action=\"{}\" target=\"{}\">", action, axum_dsl_cable_attr(target)));'
  end

  def test_remove_has_no_template
    rust = compile(<<~RB + cable('channel "BoardChannel", signed_stream: :secret_key'))
      get "/n" do
        broadcast_turbo("board", action: :remove, target: "note_1")
        "sent"
      end
    RB
    assert_includes rust, 'axum_dsl_cable_broadcast_turbo(&["board"], "remove", "note_1", None, false);'
  end

  def test_render_string_follows_the_locals_rule_of_render
    message = refusal(<<~RB + cable('channel "HeartbeatChannel"'), views: NOTE)
      get "/n" do
        broadcast_turbo("board", action: :append, target: "notes", html: render_string(:note))
        "sent"
      end
    RB
    assert_match(/reads a local, so the render must pass it/, message)
  end

  # ---- refusals -------------------------------------------------------------------------------------

  def test_a_broadcast_needs_a_cable
    message = refusal(<<~RB, head: "server \"chat\", version: \"0.1.0\"\n")
      get "/n" do
        broadcast "reads", "room_id" => 1
        "sent"
      end
    RB
    assert_match(/this broadcasts to Action Cable subscribers, and the file declares no `cable`/, message)
  end

  def test_a_helper_cannot_broadcast
    message = refusal(<<~RB + cable('channel "HeartbeatChannel"'))
      helper :shout, args: [:string], returns: :string do |text|
        broadcast "reads", "text" => text
        text
      end
      get "/n" do
        shout("x")
      end
    RB
    assert_match(/`broadcast` sends to the Action Cable subscribers: write it in a route, a filter or a channel's block/, message)
  end

  def test_broadcast_to_needs_a_stream_for
    message = refusal(cable(<<~RB))
      channel "ChatChannel", room_param: :room_id do
        perform :speak do |user|
          broadcast_to("who" => user)
        end
      end
    RB
    assert_match(/`broadcast_to` sends to the channel's `stream_for` stream, and this channel declares none/, message)
  end

  def test_a_stream_callback_cannot_broadcast_to_a_stream_not_yet_made
    message = refusal(cable(<<~RB))
      channel "ChatChannel", room_param: :room_id do
        stream_for { |room_id| "room-\#{room_id}" }
        stream_from do |user|
          broadcast_to("who" => user)
          "x"
        end
      end
    RB
    assert_match(/`broadcast_to` sends to the channel's `stream_for` stream, and this channel declares none \(or this callback runs before it is known\)/, message)
  end

  def test_a_remove_takes_no_html
    message = refusal(<<~RB + cable('channel "HeartbeatChannel"'), views: NOTE)
      get "/n" do
        broadcast_turbo("board", action: :remove, target: "n", html: render_string(:note))
        "sent"
      end
    RB
    assert_match(/a `remove` action carries no template, so it takes no `html:`/, message)
  end

  def test_an_append_needs_html
    message = refusal(<<~RB + cable('channel "HeartbeatChannel"'))
      get "/n" do
        broadcast_turbo("board", action: :append, target: "n")
        "sent"
      end
    RB
    assert_match(/`action: :append` needs `html:`/, message)
  end

  def test_the_action_is_one_turbo_knows
    message = refusal(<<~RB + cable('channel "HeartbeatChannel"'))
      get "/n" do
        broadcast_turbo("board", action: :explode, target: "n")
        "sent"
      end
    RB
    assert_match(/`action:` is one of :append, :prepend, :replace, :update, :remove, :before, :after/, message)
  end

  def test_a_callback_takes_only_what_it_is_offered
    message = refusal(cable(<<~RB))
      channel "NoticesChannel" do
        stream_from { |user, room_id| "n_\#{user}\#{room_id}" }
      end
    RB
    assert_match(/`room_id` is not available to this callback \(it can take: user\)/, message)
  end

  def test_an_unread_parameter_is_refused
    message = refusal(cable(<<~RB))
      channel "NoticesChannel" do
        stream_from { |user| "n" }
      end
    RB
    assert_match(/parameter `user` is never read; remove it from the \|\.\.\.\| list/, message)
  end

  def test_a_stream_callback_ends_in_a_string
    message = refusal(cable(<<~RB))
      channel "NoticesChannel" do
        stream_from { 1 }
      end
    RB
    assert_match(/this callback names a stream, so it ends in a string/, message)
  end

  def test_a_callback_is_declared_once
    message = refusal(cable(<<~RB))
      channel "NoticesChannel" do
        stream_from { "a" }
        stream_from { "b" }
      end
    RB
    assert_match(/declares `stream_from` twice/, message)
  end

  def test_an_action_is_performed_once
    message = refusal(cable(<<~RB))
      channel "ChatChannel" do
        perform(:speak) { broadcast("log", "x" => 1) }
        perform(:speak) { broadcast("log", "x" => 2) }
      end
    RB
    assert_match(/performs `speak` twice/, message)
  end

  def test_a_message_value_is_a_scalar
    message = refusal(<<~RB + cable('channel "HeartbeatChannel"'))
      get "/n" do
        broadcast "reads", "ids" => [1, 2]
        "sent"
      end
    RB
    assert_match(/a message value is a string, number or bool/, message)
  end
end
