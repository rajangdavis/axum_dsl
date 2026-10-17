# expect: an argument is named by a bare word and a colon
# A trailing comma in a partial's arguments: after the `,` Views.partial_args expects another `key:`
# and finds nothing, so it refuses with the message a malformed key gets.
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_partial_trailing_comma
end
