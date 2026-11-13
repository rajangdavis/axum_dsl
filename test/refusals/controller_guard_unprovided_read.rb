# expect: `before :ensure_thing` reads `thing`, which `before :set_thing` provides, but not to the action `show`
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :id, :i64, min: 1, in: :path
end

controller "Things" do
  before :set_thing, only: [:index], provides: :thing
  before :ensure_thing, only: [:show]

  get "/a/:id", params: :P, action: :index do
    text(thing)
  end

  get "/b/:id", params: :P, action: :show do
    "x"
  end

  def set_thing
    params[:id]
  end

  def ensure_thing
    return head(403) unless thing == 1
  end
end
