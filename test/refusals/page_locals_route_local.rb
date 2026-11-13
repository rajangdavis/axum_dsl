# expect: undefined local `leaked`
server "refuse", version: "0.1.0"
set :port, 8080

controller "C" do
  page_locals do
    leaked = "L"
    title = leaked
  end

  get "/" do
    render :unknown_local
  end
end
