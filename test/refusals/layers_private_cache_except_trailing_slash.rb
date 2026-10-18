# expect: `use_layer :private_cache` `except:` entry "/assets/" must not end with /
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :private_cache, except: ["/assets/"]
