# typed: true
# A second example, and the one that makes the compiler's own validation run: every field below carries
# a constraint the generated check() enforces (lib/axum_dsl/emit.rb: field_checks), so a request that
# violates one is refused with the compiler's own 400 message before the body runs -- unless the route's
# body reads `errors`, which hands that message to the body instead (the form routes below). It also
# carries
# the two declarative surfaces a service adds on top of its routes: a form body (`in: :form`, axum's
# Form extractor) and named middleware (`use_layer`).
# test/e2e_validate.sh drives it; examples/add.axum.rb holds port 8080, so this service takes another.
server "validator", version: "0.1.0"
set :port, 8093

# The compiler writes an OpenAPI 3.1 document of the routes below, with every description and constraint,
# and the service serves it at this path (docs/openapi.md). test/e2e_validate.sh reads it back.
openapi "/openapi.json"

# A layer answers every route, so where these sit in the file does not change the service; the emitter
# puts them on the router in its own fixed order (lib/axum_dsl/emit.rb: LAYER_ORDER) and adds each
# tower-http feature to the one Cargo.toml line. :private_cache is the compiler's own header layer: it
# appends Cache-Control: private, no-cache and Vary: Cookie to every response, so a shared cache does
# not store a page behind a cookie.
use_layer :compression                         # gzip/deflate response compression
use_layer :cors, origins: ["https://example.com"]
use_layer :timeout, secs: 5
use_layer :trace
use_layer :private_cache

params :Signup do
  field :name, :string, in: :query, min_length: 3, max_length: 8
  field :age, :i32, in: :query, min: 18, max: 120
  field :colour, :string, in: :query, enum: ["red", "green", "blue"]
  field :handle, :string, in: :query, pattern: "^[a-z][a-z0-9_]{2,7}$"
end

# An HTML form POSTs application/x-www-form-urlencoded, which axum reads with its Form extractor. A
# urlencoded body is flat key/value pairs, so a form field is a scalar here; a list or a nested object
# has no flat encoding (use a JSON body for those). The generated check() still runs on the parsed
# struct, after the extractor has accepted it.
params :SignupForm do
  field :name, :string, in: :form, min_length: 3, max_length: 8
  field :age, :i32, in: :form, min: 18, max: 120
end

# A Rails form posts bracketed wire names (`message[body]`). `name:` renames the wire key on the generated
# struct (serde rename) while the field and everything the body reads keep the DSL name, so params[:body]
# still reads it and the check()/errors messages stay keyed by `body`. A flat `body=...` is not accepted:
# the Form extractor answers 422, as it does for any field the wire does not carry.
params :MessageForm do
  field :body, :string, in: :form, name: "message[body]", min_length: 1
  field :client_message_id, :string, in: :form, name: "message[client_message_id]", optional: true
end

get "/signup", params: :Signup, description: "One signup, echoing the values it accepted" do
  # :private_cache appends its own Cache-Control, so this route's value must still be on the response:
  # test/e2e_validate.sh asserts both halves, which is what "append, not replace" means.
  headers "Cache-Control" => "max-age=60"
  text("ok: #{params[:name]} #{params[:handle]} #{params[:colour]} #{params[:age]}")
end

post "/signup/form", params: :SignupForm, description: "One signup sent as an HTML form" do
  # The visible text is unchanged, but the name is escaped before it lands in the markup: a value that
  # looks like a tag is served as text. test/e2e_validate.sh posts `<script>` through this route.
  #
  # errors[:name] is the generated check()'s own message for that field, and an empty string when the
  # request passed it, so the page interpolates it with no conditional; a POST that breaks a constraint
  # is re-rendered here instead of being answered 400 before the body runs. That 400 is still the
  # answer when a constraint was broken (a body that reads errors keeps it), because this body sets no
  # status(...). The success text above is unchanged, since the message is empty then.
  html("<p>form signup accepted: name=#{h(params[:name])} age=#{params[:age]}, sent as a form</p>#{h(errors[:name])}")
end

post "/messages", params: :MessageForm, description: "A message form with Rails' bracketed wire names" do
  html("<p>message accepted: body=#{h(params[:body])}</p>")
end

# `etag(value)` is a route-level statement: the response carries that ETag, and a request whose
# If-None-Match lists it is answered 304 with no body. The value is computed at run time (a helper or an
# interpolation); a constant here keeps test/e2e_validate.sh's two GETs exact.
get "/etag", description: "A conditional GET: 304 when If-None-Match matches the ETag" do
  etag("\"validator-v1\"")
  text("fresh")
end

post "/signup/soft", params: :SignupForm, description: "One signup answered with a status of its own" do
  # The same re-render, but with status(:accepted): a body that reads errors and sets a status gets the
  # status it sets, so a rejected POST is answered 202 with the message rather than the 400 the check()
  # would otherwise answer with.
  status(:accepted)
  html("<p>soft signup: name=#{h(params[:name])} age=#{params[:age]}</p>#{h(errors[:name])}")
end
