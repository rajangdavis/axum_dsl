# expect: is never closed; a conditional ends with `{% endif %}`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :if_unclosed, locals: { show: true }
end