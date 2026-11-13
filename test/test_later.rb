# frozen_string_literal: true

# `later do ... end` (work after the response, a spawned task) and `web_push(...)` (one Web Push delivery), asserted on
# the emitted crate. Campfire's differential runs check the push behaviour against Rails (invalid subscriptions go).
#
#   ruby -Ilib test/test_later.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestLater < Minitest::Test
  def files(src)
    Dir.mktmpdir("later") do |dir|
      file = File.join(dir, "later.axum.rb")
      File.write(file, "server \"later\", version: \"0.1.0\"\ndatabase :sqlite, path: \"x.db\"\n#{src}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  NOTE = <<~RB
    execute :touch_note, args: { id: :i64, body: :string }, sql: "UPDATE notes SET body = :body WHERE id = :id"
    params :NoteIn do
      field :body, :string, in: :form
    end
  RB

  def test_the_block_runs_in_a_task_that_owns_what_it_reads
    main = files(NOTE + <<~RB)["src/main.rs"]
      post "/note", params: :NoteIn do
        note_id = 1
        later do
          touch_note(id: note_id, body: params[:body])
          touch_note(id: 2, body: request_base_url)
        end
        text("queued")
      end
    RB
    assert_includes main, "let note_id = note_id.clone(); let body = body.clone(); let __headers = __headers.clone(); ::tokio::spawn(async move {"
    assert_includes main, "query_touch_note(note_id, body.clone()).await?;"
    assert_includes main, 'eprintln!("later (line 9): {__e}");'
  end

  def test_a_later_block_has_no_response
    err = assert_raises(AxumDsl::CompileError) { files(NOTE + <<~RB) }
      post "/note", params: :NoteIn do
        later do
          text("no")
        end
        text("queued")
      end
    RB
    assert_includes err.message, "a `later` block has no response"
  end

  def test_web_push_comes_with_its_runtime_and_crates
    out = files(NOTE + <<~RB)
      post "/push", params: :NoteIn do
        later do
          refused = web_push("https://fcm.googleapis.com/x", params[:body], "auth", "{}", "pub", "priv", "mailto:a@b.c")
          touch_note(id: refused, body: "")
        end
        text("queued")
      end
    RB
    assert_includes out["src/main.rs"], "async fn axum_dsl_web_push(endpoint: &str, p256dh: &str"
    assert_includes out["src/main.rs"], "axum_dsl_web_push(\"https://fcm.googleapis.com/x\", body.as_str(), \"auth\""
    assert_includes out["Cargo.toml"], 'p256 = { version = "0.14", features = ["ecdh", "ecdsa", "getrandom"] }'
    assert_includes out["Cargo.toml"], 'aes-gcm = "0.11"'
    assert_includes out["Cargo.toml"], 'sha2_wp = { package = "sha2", version = "0.11" }'
  end

  def test_webhook_post_comes_with_its_runtime
    out = files(NOTE + <<~RB)
      post "/hook", params: :NoteIn do
        later do
          reply = webhook_post("http://127.0.0.1:9/hook", params[:body])
          touch_note(id: 1, body: reply || "")
        end
        text("queued")
      end
    RB
    assert_includes out["src/main.rs"], "async fn axum_dsl_webhook_post(url: &str, payload: &str) -> Option<String>"
    assert_includes out["Cargo.toml"], "reqwest = "
  end

  # Ruby's to_json writes nil as null and keeps a hash's keys in written order.
  def test_json_object_keeps_its_key_order_and_writes_nil_as_null
    out = files(NOTE + <<~RB)
      post "/json", params: :NoteIn do
        name = params[:body] == "" ? nil : params[:body]
        touch_note(id: 1, body: "")
        text(json_object("user" => json_object("name" => name), "room" => json_object("id" => 1)))
      end
    RB
    assert_includes out["src/main.rs"], '::serde_json::json!({ "user": ::serde_json::json!({ "name": name }), "room": ::serde_json::json!({ "id": 1 }) })'
    assert_includes out["Cargo.toml"], 'serde_json = { version = "1", features = ["preserve_order"] }'
  end

  # A conditional may hold a transaction, an each loop and a broadcast-free call list; its locals stay inside it.
  def test_a_conditional_may_hold_a_transaction_and_a_loop
    main = files(NOTE + <<~RB)["src/main.rs"]
      post "/cond", params: :NoteIn do
        go = params[:body] == "yes"
        if go
          saved = transaction do
            touch_note(id: 1, body: "a")
          end
          [1, 2].each { |i| touch_note(id: i + saved, body: "b") }
        end
        text("ok")
      end
    RB
    assert_includes main, "if go { let saved = { let __out = db_tx("
  end
end
