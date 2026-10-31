# frozen_string_literal: true

# `close_remote_connections` (docs/cable.md), asserted on the emitted Rust and on the refusals: Rails' remote disconnect
# of one user's connections. No cargo and no socket; test/e2e_cable.sh drives the running service and checks the frames.
#
#   ruby -Ilib test/test_cable_close_remote.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestCableCloseRemote < Minitest::Test
  STRING_HEAD = <<~RB
    server "chat", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    cookies secret: :secret_key
    current :user, returns: :string? do
      cookie(:who)
    end
  RB

  RECORD_HEAD = <<~RB
    server "chat", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    cookies secret: :secret_key
    database :sqlite, path: "chat.sqlite3"
    record :User do
      field :id, :i64
    end
    query :user_for_token, args: { token: :string }, returns: :User?, sql: "SELECT id FROM users WHERE token = :token"
    current :user, returns: :User? do
      token = cookie(:token)
      token.nil? ? nil : user_for_token(token: token)
    end
  RB

  CABLE = "cable \"/cable\", authenticate_with: :user do\n  channel \"HeartbeatChannel\"\nend\n"

  def compile(body, head: STRING_HEAD)
    Dir.mktmpdir("chat") do |dir|
      file = File.join(dir, "chat.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(body, head: STRING_HEAD)
    assert_raises(AxumDsl::CompileError) { compile(body, head: head) }.message
  end

  def test_a_record_current_is_matched_by_its_id
    rust = compile(<<~RB + CABLE, head: RECORD_HEAD)
      post "/out" do
        user = current(:user)
        return halt(401, "") if user.nil?
        close_remote_connections(user.id)
        "closed"
      end
    RB
    assert_includes rust, "let user_key: String = { let user = user.clone(); user.id.to_string() };"
    assert_match(/axum_dsl_cable_close_remote\(&format!\("\{\}", [^)]*id[^)]*\), true\);/, rust)
  end

  def test_a_string_current_is_matched_by_the_string
    rust = compile(<<~RB + CABLE)
      post "/out" do
        close_remote_connections("alice")
        "closed"
      end
    RB
    assert_includes rust, "let user_key: String = { let user = user.clone(); user.clone() };"
    assert_includes rust, 'axum_dsl_cable_close_remote(&format!("{}", "alice"), true);'
  end

  def test_reconnect_false_is_written_into_the_call
    rust = compile(<<~RB + CABLE)
      post "/out" do
        close_remote_connections("alice", reconnect: false)
        "closed"
      end
    RB
    assert_includes rust, 'axum_dsl_cable_close_remote(&format!("{}", "alice"), false);'
  end

  def test_the_runtime_sends_the_remote_frame_and_closes_from_the_session_loop
    rust = compile(<<~RB + CABLE)
      post "/out" do
        close_remote_connections("alice")
        "closed"
      end
    RB
    assert_includes rust, "static AXUM_DSL_CABLE_REMOTE"
    assert_includes rust, 'format!(r#"{{"type":"disconnect","reason":"remote","reconnect":{reconnect}}}"#'
    assert_includes rust, "switch.send_replace(Some(reconnect));"
    # the switch is dropped from the registry after the loop, then the subscriptions are dropped (on_unsubscribe)
    assert_operator rust.index("AXUM_DSL_CABLE_REMOTE.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&id);"), :<,
                    rust.index("axum_dsl_cable_close(&mut conn).await;\n}")
  end

  def test_a_file_without_the_call_registers_no_key
    rust = compile("get \"/n\" do\n  \"x\"\nend\n" + CABLE)
    assert_includes rust, "let user_key: String = String::new();"
  end

  def test_the_call_needs_a_cable
    message = refusal(<<~RB)
      post "/out" do
        close_remote_connections("alice")
        "closed"
      end
    RB
    assert_match(/this broadcasts to Action Cable subscribers, and the file declares no `cable`/, message)
  end

  def test_a_helper_cannot_close_connections
    message = refusal(<<~RB + CABLE)
      helper :out, args: [:string], returns: :string do |name|
        close_remote_connections(name)
        name
      end
      get "/n" do
        out("x")
      end
    RB
    assert_match(/`close_remote_connections` sends to the Action Cable subscribers: write it in a route/, message)
  end

  def test_a_string_for_a_record_current_is_refused
    message = refusal(<<~RB + CABLE, head: RECORD_HEAD)
      post "/out" do
        close_remote_connections("alice")
        "closed"
      end
    RB
    assert_match(/takes the user's id \(an :i64\), as the current `user` is a record or an :i64/, message)
  end

  def test_an_id_for_a_string_current_is_refused
    message = refusal(<<~RB + CABLE)
      post "/out" do
        close_remote_connections(7)
        "closed"
      end
    RB
    assert_match(/takes the user's name \(a string\), as the current `user` is a string/, message)
  end

  def test_the_call_takes_one_argument_and_a_literal_reconnect
    assert_match(/close_remote_connections takes the user's id and, optionally, `reconnect:`/, refusal("post \"/out\" do\n  close_remote_connections\n  \"x\"\nend\n" + CABLE))
    assert_match(/`reconnect:` is true or false/, refusal("post \"/out\" do\n  close_remote_connections(\"a\", reconnect: params[:x])\n  \"x\"\nend\n" + CABLE))
    assert_match(/unknown keyword `again:` for close_remote_connections/, refusal("post \"/out\" do\n  close_remote_connections(\"a\", again: true)\n  \"x\"\nend\n" + CABLE))
  end
end
