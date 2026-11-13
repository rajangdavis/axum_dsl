# typed: false
# Locales (docs/views.md, "Locales"): Rails' i18n, opt-in. The texts live in locales/config/locales/en.yml and es.yml,
# one top-level key per locale and nested keys below it, and are read when the compiler runs: each `t` below becomes
# a generated Rust function with a `match` over the request's locale, so the crate has no YAML parser and no new
# dependency. A request is answered in the locale its `locale` query parameter names when a file holds it (?locale=es),
# else the default. A key the default locale (en) lacks is a compile error naming the `t` call; a key Spanish lacks
# (bots.index.only_in_english) answers with the English text. A file that never calls `t` needs none of this.
# `typed: false` as the other service examples that declare names Sorbet cannot see.
# test/test_locales.rb compiles it; it takes port 8088 (the other examples hold 8080-8087 and 8091-8111).
server "locales", version: "0.1.0"
set :port, 8088

# Where the views and the locale files are, beside this file (the defaults are views/ and config/locales/).
set :views, "locales/views"
set :locales, "locales/config/locales"

# Optional: without it the default is :en when a file holds it, else the only locale there is.
default_locale :en

params :Visitor do
  field :name, :string, in: :query, optional: true
end

# `{{ t ".title" }}` in locales/views/bots/index.html is Rails' lazy lookup: the view's path under the views folder,
# bots/index.html, is the scope `bots.index`, so the key is bots.index.title. `{{ t ".welcome", name: user_name }}` fills
# `%{name}` in the text with the local `user_name`, escaped as any string a view writes is.
get "/bots", params: :Visitor, description: "The bots page, in the request's locale" do
  render "bots/index", layout: nil, locals: { user_name: params[:name] || "friend" }
end

# In a route body the whole key is written, and the value is a String like any other: not escaped, so HTML would write
# h(t(...)). The locale is the same one the view above reads: the `locale` query parameter, bound once per request.
get "/health", description: "A translated plain-text answer" do
  text(t("health.ok"))
end
