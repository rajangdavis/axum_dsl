# expect: page_locals takes `name = value` or `@name = value` lines
server "refuse", version: "0.1.0"
set :port, 8080

controller "C" do
  page_locals do
    "not a pair"
  end

  get "/" do
    render :unknown_local
  end
end
