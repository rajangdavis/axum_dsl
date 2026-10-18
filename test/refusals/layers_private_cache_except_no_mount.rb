# expect: `use_layer :private_cache` `except:` entry "/media" is not served by a `static` mount
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :private_cache, except: ["/media"]
