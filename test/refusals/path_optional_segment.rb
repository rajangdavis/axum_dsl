# expect: uses an optional segment (`?`), which axum's router cannot express
server "refuse", version: "0.1.0"
set :port, 8080

get "/items/:id?" do
  text("ok")
end
