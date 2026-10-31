# typed: true
# Rack::MethodOverride (docs/dsl.md): a browser form can only send GET and POST, so a Rails form that edits or
# deletes submits a POST with a hidden `_method=patch|delete` field (or a client sends X-HTTP-Method-Override).
# `use_layer :method_override` routes that POST as the named method, so the `patch` and `delete` below are
# reachable from a form, and the route still reads the form's other fields. `/method` reads `request_method`,
# which is the method the router sees: the rewritten one.
# `make e2e-method-override` builds this file and test/e2e_method_override.sh drives it over HTTP.
server "method_override", version: "0.1.0"
set :port, 8101

use_layer :method_override

params :Note do
  field :id, :i64, in: :path
  field :body, :string, in: :form
end

params :NoteId do
  field :id, :i64, in: :path
end

get "/notes/:id", params: :NoteId, description: "A GET is never rewritten" do
  text("get #{params[:id]}")
end

post "/notes/:id", params: :Note, description: "What a POST with no usable override still is" do
  text("post #{params[:id]}: #{params[:body]}")
end

patch "/notes/:id", params: :Note, description: "Reached by a POST with _method=patch" do
  text("patch #{params[:id]}: #{params[:body]}")
end

delete "/notes/:id", params: :NoteId, description: "Reached by a POST with _method=delete" do
  text("delete #{params[:id]}")
end

# The route-side `request_method`: the method after the override, in upper case. This is also the compile
# guard for the `Method` extractor a route needs (a before filter reads the method from the request itself).
patch "/method", description: "request_method is the method the override produced" do
  text(request_method)
end
