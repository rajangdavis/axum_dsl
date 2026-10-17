# expect: `set :views` takes the folder as a string
server "refuse", version: "0.1.0"
set :views, :app
