# expect: duplicate page local `title`
server "refuse", version: "0.1.0"
set :port, 8080

controller "C" do
  page_locals do
    title = "a"
    title = "b"
  end

  get "/" do
    render :unknown_local
  end
end
