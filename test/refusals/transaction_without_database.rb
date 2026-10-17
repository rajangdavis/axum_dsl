# expect: `transaction` needs a database; add `database :sqlite
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  transaction do
    1
  end
end