# expect: static dir must be a relative path inside the DSL file's folder, without ..
server "refuse", version: "0.1.0"
set :port, 8080

static "/assets", dir: "../lib"