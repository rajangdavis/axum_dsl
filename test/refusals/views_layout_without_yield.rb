# expect: has no `{{ yield }}`, so the layout would drop the view it wraps
server "refuse", version: "0.1.0"
set :port, 8080
set :layout, :layout_no_yield
