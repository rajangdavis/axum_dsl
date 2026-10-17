# expect: is a cycle: views/p_cycle.html -> views/p_cycle.html
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_partial_cycle
end
