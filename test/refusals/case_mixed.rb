# expect: this `case` compares strings, but `when` has an integer
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :s, :string, in: :query
end

get "/x", params: :P do
  case params[:s]
  when 1 then "a"
  else "b"
  end
end
