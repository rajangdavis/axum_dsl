# frozen_string_literal: true

# `channel "Name", room_param:, member_of:, on_subscribe: :statement` (docs/cable.md), asserted on the emitted Rust
# and on the refusals. No cargo and no socket; campfire_axum_dsl/test/e2e_campfire.sh drives the running service.
#
#   ruby -Ilib test/test_cable_on_subscribe.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestCableOnSubscribe < Minitest::Test
  HEAD = <<~RB
    server "presence", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    cookies secret: :secret_key
    database :sqlite, path: "presence.sqlite3"
    record :User do
      field :id, :i64
    end
    record :Room do
      field :id, :i64
    end
    query :user_for_token, args: { token: :string }, returns: :User?, sql: "SELECT id FROM users WHERE token = :token"
    current :user, returns: :User? do
      token = cookie(:token)
      token.nil? ? nil : user_for_token(token: token)
    end
    query :room_for_user, args: { id: :i64, user_id: :i64 }, returns: :Room?, sql: "SELECT room_id AS id FROM memberships WHERE room_id = :id AND user_id = :user_id"
    execute :connect, args: { room_id: :i64, user_id: :i64 }, sql: "UPDATE memberships SET unread_at = NULL WHERE room_id = :room_id AND user_id = :user_id"
  RB

  def compile(cable, head: HEAD)
    Dir.mktmpdir("presence") do |dir|
      file = File.join(dir, "presence.axum.rb")
      File.write(file, head + cable)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(cable, head: HEAD)
    assert_raises(AxumDsl::CompileError) { compile(cable, head: head) }.message
  end

  def cable(options)
    <<~RB
      cable "/cable", authenticate_with: :user do
        channel "PresenceChannel", room_param: :room_id, member_of: :room_for_user#{options}
        channel "HeartbeatChannel"
      end
    RB
  end

  def test_the_statement_runs_only_after_membership_is_proven
    rust = compile(cable(", on_subscribe: :connect"))
    assert_includes rust, "let room = match query_room_for_user(room_id, user_id).await {"
    assert_includes rust, "let _ = query_connect(room_id, user_id).await;"
    assert_operator rust.index("let room = match query_room_for_user"), :<, rust.index("query_connect(room_id, user_id)")
    # a rejected subscription returns before the statement runs
    assert_operator rust.index("_ => return None,"), :<, rust.index("query_connect(room_id, user_id)")
  end

  def test_a_channel_without_the_option_runs_nothing
    # Without the option nothing calls `connect`, and an unused declaration is refused, so the head leaves it out.
    rust = compile(cable(""), head: HEAD.sub(/^execute :connect.*\n/, ""))
    refute_includes rust, "query_connect("
  end

  def test_the_name_must_be_declared
    assert_match(/`on_subscribe:` names statement `nope`, which is not declared/, refusal(cable(", on_subscribe: :nope")))
  end

  def test_the_arguments_must_be_room_id_and_user_id
    head = HEAD + "execute :touch, args: { id: :i64 }, sql: \"UPDATE memberships SET unread_at = NULL WHERE room_id = :id\"\n"
    assert_match(/needs an `execute` with the arguments `room_id:` and `user_id:`/, refusal(cable(", on_subscribe: :touch"), head: head))
  end

  def test_it_needs_member_of
    message = refusal(<<~RB)
      cable "/cable", authenticate_with: :user do
        channel "PresenceChannel", room_param: :room_id, on_subscribe: :connect
      end
    RB
    assert_match(/`on_subscribe:` needs `member_of:`/, message)
  end
end
