# expect: `set :port` must be 0 to 65535, got :x
server "refuse", version: "0.1.0"
set :port, :x
