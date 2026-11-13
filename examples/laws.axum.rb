server "lawtry", version: "0.1.0"

params :Pair do
  field :a, :i64, min: -1000, max: 1000
  field :b, :i64, exclusive_min: 0, max: 50
end

params :Name do
  field :name, :string, min_length: 1, max_length: 20
end

helper :add, args: [:i64, :i64], returns: :i64 do |a, b|
  a + b
end

helper :shout, args: [:string], returns: :string do |s|
  s.upcase
end

helper :twice, args: [:string], returns: :string do |s|
  shout(s) + shout(s)
end

get "/sum", params: :Pair do
  text(add(params[:a], params[:b]).to_s)
end

law :add_commutes, forall: :Pair do |a, b|
  add(a, b) == add(b, a)
end

law :b_is_positive, forall: :Pair, cases: 64 do |b|
  b >= 1
end

law :shout_is_idempotent, forall: :Name do |name|
  shout(shout(name)) == shout(name)
end

law :example_add do
  add(2, 3) == 5
end

law :twice_doubles, forall: :Name do |name|
  twice(name).length == 2 * shout(name).length
end

# Route laws: respond(...) sends the service a request in-process and reads the answer.
law :sum_route_adds, forall: :Pair, cases: 64 do |a, b|
  r = respond(:get, "/sum?a=#{a}&b=#{b}")
  r.status == 200 && r.body == (a + b).to_s
end

law :sum_route_checks_its_params do
  respond(:get, "/sum?a=1&b=0").status == 400
end
