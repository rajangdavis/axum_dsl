# expect: `{{ yield }}` is a layout's child output, and this render has no layout
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :yield_plain
end
