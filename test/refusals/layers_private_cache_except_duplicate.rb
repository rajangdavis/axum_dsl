# expect: `use_layer :private_cache` `except:` lists "/assets" twice
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :private_cache, except: ["/assets", "/assets"]
