# expect: which has no fields; write `{{ n }}`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :loop_scalar_field, locals: { names: ["a", "b"] }
end
