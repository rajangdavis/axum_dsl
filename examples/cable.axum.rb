# typed: false
# Action Cable broadcasts (docs/cable.md): channels that stream, answer a client's `perform`, and are told things by
# routes. The wire format is Rails'; test/e2e_cable.sh opens WebSocket clients and checks the frames byte for byte.
# `typed: false` because Sorbet knows the DSL's calls (rbi/dsl.rbi) but not the block parameters of a channel callback.
# The other examples hold 8080-8087, 8091-8098 and 8101, so this service takes 8105.
server "cable", version: "0.1.0"
set :port, 8105
# render_string(:note) reads cable/views/note.html.
set :views, "cable/views"

# The key cookies and Turbo's signed stream names are signed with: at least 32 bytes, or the server exits as it starts.
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key

# Who is connecting: the name in the signed `who` cookie, or nil (a connection with no cookie is told `unauthorized`).
current :user, returns: :string? do
  cookie(:who)
end

params :Name do
  field :name, :string, in: :path
end

params :Text do
  field :text, :string, in: :path
end

cable "/cable", authenticate_with: :user do
  # `stream_from` names what the subscription listens to; a block parameter asks for the signed-in user.
  channel "NoticesChannel" do
    stream_from { |user| "notices_for_#{user}" }
  end

  # `stream_for` is Rails' `stream_for @room`: the broadcasting is "chat:" and what the block ends in. `perform :speak`
  # answers {"action":"speak"} from a client, `broadcast_to` sends to the stream_for name, and the two lifecycle
  # callbacks tell whoever listens on "chat_log".
  channel "ChatChannel", room_param: :room_id do
    stream_for { |room_id| "room-#{room_id}" }
    after_subscribe { |user, room_id| broadcast("chat_log", "event" => "joined", "user" => user, "room_id" => room_id) }
    on_unsubscribe { |user, room_id| broadcast("chat_log", "event" => "left", "user" => user, "room_id" => room_id) }
    perform :speak do |user, room_id|
      broadcast_to("action" => "speak", "user" => json_object("name" => user, "room" => room_id))
    end
  end

  channel "LogChannel" do
    stream_from { "chat_log" }
  end

  # A Turbo signed stream: the verified stream name is the broadcasting, with no callback to write.
  channel "BoardChannel", signed_stream: :secret_key
end

post "/login/:name", params: :Name, description: "Sign in as a name: the signed who cookie" do
  set_cookie :who, params[:name], http_only: true, same_site: :lax
  "signed in as #{params[:name]}"
end

get "/stream_name", description: "The signed stream name a BoardChannel subscription carries" do
  turbo_signed_stream_name("board", secret: :secret_key)
end

post "/notify/:name", params: :Name, description: "ActionCable.server.broadcast to one user's notices" do
  broadcast "notices_for_#{params[:name]}", "message" => "hello", "to" => params[:name]
  "sent"
end

post "/kick/:name", params: :Name, description: "close_remote_connections: every socket of that user is sent the remote disconnect and closed" do
  close_remote_connections(params[:name])
  "kicked"
end

post "/kick/:name/final", params: :Name, description: "close_remote_connections with reconnect: false" do
  close_remote_connections(params[:name], reconnect: false)
  "kicked for good"
end

post "/board/:text", params: :Text, description: "Turbo append of the note view to every BoardChannel subscriber" do
  broadcast_turbo("board", action: :append, target: "notes", html: render_string(:note, locals: { text: params[:text] }), maintain_scroll: true)
  "posted"
end

delete "/board/:text", params: :Text, description: "Turbo remove of one note" do
  broadcast_turbo("board", action: :remove, target: "note_#{params[:text]}")
  "removed"
end
