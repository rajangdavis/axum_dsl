# expect: needs `cookies secret: :setting_name` at the top level of the file
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  cookie(:last_room, signed: false).to_s
end
