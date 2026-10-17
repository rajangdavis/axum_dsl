# typed: true
# The fourth example: pages the server renders. A view is a `.html` file beside this file, read at compile
# time and compiled into the emitted Rust, so the crate carries no template and no template engine -- which
# is what separates a view from `static`, whose file is copied for the running service to serve. The form
# shows a partial (`views/form_field.html`, inlined into `views/signup.html` once per field) and a layout
# (`views/layout.html`, which wraps every page and writes the page's own markup where its `{{ yield }}` is).
# test/e2e_views.sh drives it; examples/assets.axum.rb holds port 8097, so this takes another.
server "views", version: "0.1.0"
set :port, 8091

# The folder a `render` reads (the default is already "views", written out because the example shows the
# setting), and the layout every render gets unless it names one itself with `layout:`.
set :views, "views"
set :layout, :layout

# An HTML form POSTs application/x-www-form-urlencoded, which axum reads with its Form extractor. The two
# constraints are what make the POST below fail: a name shorter than 3 characters (or longer than 8) is a
# violation, and errors[:name] then carries the generated check()'s own message.
params :SignupForm do
  field :name, :string, in: :form, min_length: 3, max_length: 8
  field :email, :string, in: :form, min_length: 3, max_length: 40
end

# The query parameter /greeting reads. `optional: true` makes it nil-able, so `.to_s` turns a missing
# parameter into "" and the route has a bool to pass as the condition.
params :Greeting do
  field :show, :string, in: :query, optional: true
end

# GET /signup shows the form. A fresh form has no values and no error, so those locals are empty strings:
# a render's locals are exactly the names its view's, its layout's and its partial calls' markers read, so
# `title` is here because views/layout.html writes `{{ title }}`, and `name`/`email`/`error` because the two
# partial calls pass them on. The partial's own markers read only its arguments -- the `{{ field }}` inside
# views/form_field.html is the string "name" the call passed, not the visitor's `name` local -- so one partial
# renders both fields, each with its own arguments.
#
# A render that left one out -- `locals: { name: "", email: "", error: "" }` with no `title` -- is refused,
# and the refusal names the local and the view line that reads it. So is passing one nothing reads.
get "/signup", description: "The signup form" do
  render :signup, locals: { title: "Sign up", name: "", email: "", error: "" }
end

# POST /signup answers one of two pages. errors[:name] is the generated check()'s message for that field, and
# an empty string when the request passed it, so the body branches on the value rather than on a status: a
# good signup gets the thanks page inside the layout, a bad one gets the form again with the message in
# `error` and the values the visitor typed echoed back -- escaped, because a marker value is escaped.
#
# The receipt is the one `|raw` use here: the route escapes the address with h(...) as it builds the
# fragment, and the page writes that fragment as markup, which is what `|raw` is for. A route that put user
# data into a `|raw` value without escaping it first would hand the browser a tag of the visitor's choosing.
post "/signup", params: :SignupForm, description: "One signup, answered as a page" do
  name_error = errors[:name]
  if name_error == ""
    render :thanks, locals: { title: "Thanks", name: params[:name],
                              receipt: "<p>Confirmation sent to <code>#{h(params[:email])}</code>.</p>" }
  else
    render :signup, locals: { title: "Sign up", name: params[:name], email: params[:email], error: name_error }
  end
end

# `layout: nil` opts a render out of the layout it would otherwise inherit: this page is a fragment the
# browser swaps into a document it already has, so it carries no `<html>` of its own.
get "/signup/fragment", description: "One page with no layout" do
  render :fragment, layout: nil, locals: { name: "" }
end

# `layout:` names another layout for one render. views/plain.html writes only `{{ yield }}`, so this render
# passes no `title`: the locals are the names the markers read, and that layout reads none of its own.
get "/signup/plain", description: "One page in a second layout" do
  render :signup, layout: :plain, locals: { name: "", email: "", error: "" }
end

# `{% if %}` writes one of two branches, chosen by Ruby truthiness. The condition here is a bool the route
# computes from the query string, so the same page answers both ways and test/e2e_views.sh can ask for each:
# ?show=1 is true and no parameter is false. The view echoes the local as data-show, so the response carries
# the precondition it was rendered with as well as the branch's markup.
get "/greeting", params: :Greeting, description: "One page whose markup depends on a condition" do
  show = params[:show].to_s == "1"
  render :greeting, layout: nil, locals: { show: show }
end

# `{{ content|sanitize }}` is for HTML the route did not write: an Action Text body. Escaping would show the
# tags as text and `|raw` would trust a <script>, so the view cleans the string with ammonia's default
# allowlist (its tags, attributes and URL schemes, plus `class`), which keeps <strong> and drops both the
# script tag and the javascript: URL. test/e2e_views.sh asserts exactly that.
get "/sanitize", description: "One page whose Action Text body is sanitised" do
  content = "<p>Hi <strong>there</strong><script>alert(1)</script><a href=\"javascript:alert(2)\">link</a></p>"
  render :sanitized, layout: nil, locals: { content: content }
end
