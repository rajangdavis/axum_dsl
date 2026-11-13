# expect: this file is a layout
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :no_markers, layout: :c_args_in_view
end