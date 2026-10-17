# typed: true
server "calculator", version: "0.1.0"
set :port, 8080

params :CalcParams do
  field :a, :i32, in: :query
  field :b, :i32, in: :query
end

get "/add", params: :CalcParams, description: "Add two integers" do
  text((params[:a] + params[:b]).to_s)
end

params :UserId do
  field :id, :i64, in: :path
end

get "/users/:id", params: :UserId, description: "One user's id, as JSON" do
  json(params[:id])
end

# A route that takes about 2 s (sleep, run as a subprocess; the subprocess timeout is 10 s), so
# test/e2e_add.sh can send SIGTERM while a request is in flight and see graceful shutdown drain it.
cmd_fn :nap, program: "sleep", argv: ["2"], args: [], returns: :string

get "/slow", description: "Answers after about 2 seconds, to show graceful shutdown draining a request" do
  text("slept#{rust(:nap)}")
end
