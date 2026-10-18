# expect: `use_layer :private_cache` `except: ["/"]` is refused: the layer would not apply anywhere
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :private_cache, except: ["/"]
