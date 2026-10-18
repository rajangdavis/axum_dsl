# expect: `use_layer :csrf` takes no keywords, so it does not take `except:`
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :csrf, except: ["/assets"]
