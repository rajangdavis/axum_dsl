# expect: is never closed; a loop ends with `{% endfor %}`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :loop_unclosed
end
