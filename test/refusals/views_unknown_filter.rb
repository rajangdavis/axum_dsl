# expect: is not a filter; `|raw`, `|sanitize` and `|editable` are the only ones
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :filter, locals: { name: "x" }
end
