# expect: `use_layer :private_cache` `except:` needs at least one path prefix
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :private_cache, except: []
