# typed: true
# The routes use the params blocks of split/params.axum.rb, spliced in above them by the root file.
fragment do
  get "/sum", params: :Pair, description: "a + b, from a fragment" do
    text((params[:a] + params[:b]).to_s)
  end

  get "/hello", params: :Who, description: "A greeting, from a fragment" do
    text("hello, #{params[:name]}")
  end

  # A fragment may use another; the path is relative to THIS file's folder (examples/split/).
  use_dsl "status.axum.rb"
end
