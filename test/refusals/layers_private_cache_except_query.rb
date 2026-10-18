# expect: `use_layer :private_cache` `except:` entry "/assets?x" must be one literal path prefix without ? # * { or }
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :private_cache, except: ["/assets?x"]
