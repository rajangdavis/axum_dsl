# A controller with a before filter (except: an action), a def returning a value, a top-level def, and laws over
# its routes: `axum_dsl test examples/controllers.axum.rb`.
server "ctl", version: "0.1.0"

params :ThingPath do
  field :id, :i64, min: 1, in: :path
end

helper :known, args: [:i64], returns: :bool do |id|
  id < 10
end

def not_found_page
  head(404)
end

controller "Things" do
  before :ensure_admin, except: [:index]

  get "/things", action: :index do
    "all"
  end

  get "/things/:id", params: :ThingPath, action: :show do
    id = set_thing
    "thing #{id}"
  end

  private

  def ensure_admin
    return head(403) unless params[:id] != 7
  end

  def set_thing
    return not_found_page unless known(params[:id])
    params[:id] * 2
  end
end

law :index_is_open do
  respond(:get, "/things").status == 200
end

law :show_rules, forall: :ThingPath, cases: 200 do |id|
  r = respond(:get, "/things/#{id}")
  if id == 7
    r.status == 403
  elsif id < 10
    r.status == 200 && r.body == "thing #{id * 2}"
  else
    r.status == 404
  end
end
