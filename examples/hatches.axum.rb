# typed: true
# Every escape hatch in one service, each reached by a route, so a build proves the compiler emits them:
#   rust_crate + rust_item + rust_fn   injected Rust, here a function from the `heck` crate
#   rust_file + rust_fn from:          a hand-written file (examples/rust/shout.rs) copied in as a module
#   cmd_fn                             a subprocess with a fixed argv (printf) and one fed on stdin (tr)
#   script_fn                          inline code run by an interpreter (sh, and ruby)
#   file + file_text                   a text file read from disk on each call
# Each prints a notice (N-RUST-INJECTED, N-EXEC-INJECTED); see docs/bindings.md. A service that can be written
# with a binding should be (examples/case.axum.rb), and these are for what a binding cannot say.
# test/e2e_hatches.sh drives it; the other examples hold 8080, 8081, 8082, 8091, 8093, 8095 and 8097, so this takes 8083.
server "hatches", version: "0.1.0"
set :port, 8083

# --- injected Rust: a crate, an item that uses it, and the item's signature ------------------------------
rust_crate "heck", "0.5"
rust_item <<~'RS'
  fn to_snake(s: &str) -> String {
      use heck::ToSnakeCase;
      s.to_snake_case()
  }

  fn twice(n: i32) -> i32 {
      n * 2
  }
RS
rust_fn :to_snake, args: [:string], returns: :string
rust_fn :twice, args: [:i32], returns: :i32

# --- a hand-written file, copied in as module `shout` ----------------------------------------------------
rust_file "rust/shout.rs", as: :shout
rust_fn :loud, args: [:string], returns: :string, from: :shout
rust_fn :first_word, args: [:string], returns: :string?, from: :shout # an Option<String>, handled with `||`

# --- subprocesses: no shell, arguments are argv entries or stdin -----------------------------------------
cmd_fn :bracket_argv, program: "printf", argv: ["[%s]"], args: [:string], returns: :string
cmd_fn :upcase_stdin, program: "tr", argv: ["a-z", "A-Z"], args: [:string], returns: :string, pass: :stdin
script_fn :wc_words, interpreter: "sh", args: [:string], returns: :string, code: <<~'SH'
  printf '%s' "$1" | wc -w | tr -d ' '
SH
script_fn :reverse_ruby, interpreter: "ruby", args: [:string], returns: :string, code: "print ARGV[0].reverse"

# --- a file beside this one, read on every call ----------------------------------------------------------
file "hatches/motd.txt", as: :motd

params :Value do
  field :value, :string, in: :query
end

params :Number do
  field :n, :i32, in: :query
end

get "/snake", params: :Value, description: "rust_item: heck's snake_case" do
  text(rust(:to_snake, params[:value]))
end

get "/twice", params: :Number, description: "rust_item: an i32 argument and result" do
  text(rust(:twice, params[:n]).to_s)
end

get "/loud", params: :Value, description: "rust_file: upper-case and an exclamation mark" do
  text(rust(:loud, params[:value]))
end

get "/first", params: :Value, description: "rust_file: the first word, or none" do
  text(rust(:first_word, params[:value]) || "none")
end

get "/bracket", params: :Value, description: "cmd_fn: printf with the value as an argv entry" do
  text(rust(:bracket_argv, params[:value]))
end

get "/upcase", params: :Value, description: "cmd_fn: tr with the value on stdin" do
  text(rust(:upcase_stdin, params[:value]))
end

get "/words", params: :Value, description: "script_fn: how many words, counted by sh" do
  text(rust(:wc_words, params[:value]))
end

get "/reverse", params: :Value, description: "script_fn: the value reversed by ruby" do
  text(rust(:reverse_ruby, params[:value]))
end

get "/motd", description: "file: the text of hatches/motd.txt" do
  text(file_text(:motd))
end
