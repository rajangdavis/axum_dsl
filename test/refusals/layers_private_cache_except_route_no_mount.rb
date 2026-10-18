# expect: `use_layer :private_cache` `except:` entry "/api" is not served by a `static` mount
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :private_cache, except: ["/api"]

get "/api/ping" do
  text("pong")
end
