# expect: is not valid UTF-8 text
server "refuse", version: "0.1.0"
set :port, 8080

# The view this renders, test/refusals/views/invalid_utf8.html, holds a byte sequence that is not valid
# UTF-8. The editor writes text, so it cannot create that file: it is made with `printf '<p>caf\351</p>\n'`
# from the command line. The refusal is raised while the view is read, before any parsing of markers.
get "/", description: "renders a view whose bytes are not valid UTF-8" do
  render :invalid_utf8
end
