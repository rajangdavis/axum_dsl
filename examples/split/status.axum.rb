# typed: true
# Included by split/routes.axum.rb, so it is two files deep.
fragment do
  get "/status", description: "A route two fragments deep" do
    text("split ok")
  end
end
