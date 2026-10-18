# frozen_string_literal: true

require "yaml"

module AxumDsl
  # The agent skill that `axum_dsl skill` writes: a folder named for the skill, with a SKILL.md
  # (name and description in the frontmatter, plain markdown body, relative links) and reference
  # pages. It uses no harness-specific features, so any agent that reads SKILL.md can use it.
  # The reference pages are generated from the compiler's own tables (SIG, TYPES, FIELD_LISTS,
  # Body::ALLOWED_METHODS, Notify::CODES and the shim catalog) so they cannot drift. rmcp_dsl's
  # test/test_skill.rb (which also compiles every example embedded here) is not ported yet.
  module Skill
    NAME = "axum-dsl"
    CATALOG = File.expand_path("../../spec/shims/string.yml", __dir__)
    DESCRIPTION = "Write an HTTP service as a small, strict Ruby DSL and compile it to Rust with the " \
                  "axum_dsl command line tool. Use when asked to create, edit, check, build or debug an " \
                  "axum service from a Ruby file that starts with `server \"name\", version:` and declares " \
                  "`get`/`post`/... routes, or to add a route to one. Covers the DSL, the Ruby subset a route " \
                  "body may use, the escape hatches (bindings, subprocesses, injected Rust) and the check, " \
                  "build and run workflow."

    BASIC = <<~'RB'
      # typed: true
      server "calculator", version: "0.1.0"
      set :port, 8080

      params :AddParams do
        field :a, :i32, in: :query
        field :b, :i32, in: :query
      end

      get "/add", params: :AddParams, description: "Add two integers" do
        text((params[:a] + params[:b]).to_s)
      end
    RB

    TEXT = <<~'RB'
      server "labeler", version: "0.1.0"

      params :TextParams do
        field :text, :string, in: :query, description: "The text to classify"
      end

      get "/label", params: :TextParams, description: "Say what kind of URL a string looks like" do
        if params[:text].start_with?("https://")
          "secure"
        elsif params[:text].match?(/\Ahttp:/)
          "plain"
        else
          "other"
        end
      end
    RB

    CMD = <<~'RB'
      server "shouter", version: "0.1.0"

      cmd_fn :run_upper, program: "tr", argv: ["a-z", "A-Z"], args: [:string], returns: :string, pass: :stdin

      params :TextParams do
        field :text, :string, in: :query
      end

      get "/upper", params: :TextParams, description: "Uppercase text with tr" do
        rust(:run_upper, params[:text])
      end
    RB

    EXAMPLES = { "basic" => BASIC, "text" => TEXT, "cmd" => CMD }.freeze

    SKILL_TEXT = <<~'MD'
      # axum-dsl

      `axum_dsl` turns a Ruby file into a Rust axum HTTP service crate. The file is never run as Ruby: it
      is parsed, type-checked and translated, so only the constructs in the references are accepted.
      Anything else is refused with `FILE:LINE:COL: reason`. A service is a few declarations plus a body
      per route:

      ```ruby
      %EXAMPLE%```

      ## Workflow

      1. Write or edit the DSL file. [references/dsl.md](references/dsl.md) lists every declaration;
         [references/body-language.md](references/body-language.md) lists what a route body may contain;
         [references/bindings.md](references/bindings.md) lists how a Rust-backed function is declared.
      2. Check it: `axum_dsl check FILE.rb --format json`. On failure the JSON has
         `error.file`, `error.line`, `error.col` and `error.message`; fix that spot and check again until
         `"ok": true`. Warnings and notices come back in `notes`.
      3. Build it: `axum_dsl build FILE.rb` writes `build/NAME` and runs `cargo build`. A rustc error
         inside generated code is reported at the DSL line that produced it.
      4. Run it: `axum_dsl run FILE.rb` starts the service over HTTP.

      The commands and their flags are in [references/cli.md](references/cli.md).

      ## Rules that matter

      - A route body is a block of restricted Ruby; its last expression is the response, as text unless a
        helper says otherwise. The compiler refuses what it cannot translate faithfully, and its message
        says what to use instead. Do not work around a refusal by guessing at other Ruby; check the lists
        in the references.
      - A route reads its inputs with `params[:field]`; a body takes no block parameters.
      - Every local must be read, or the compiler refuses the body.
      - Logic that more than one route needs goes in a `helper`, not in a copy.
      - To fail a request use `raise "message"`: the `error` filter answers it, or the generated service
        answers a plain 500 when no `error` filter is declared.
      - Describe each `field` with `description:` and constrain it (`enum:`, `min:`, `max:`, `pattern:`,
        length limits; the generated service enforces them). Say which part of the request a field comes
        from with `in:` when the verb's default is not what you want.
      - Prefer Ruby in the body. When the body language cannot express something, use an escape hatch, in
        this order: a binding (`use_bindings`), a subprocess (`cmd_fn`, `script_fn`), a hand-written Rust
        file (`rust_file`), then inline Rust (`rust_item`). Each prints a notice, because the compiler
        cannot check that code.
    MD

    DSL_INTRO = <<~'MD'
      # DSL reference

      A file names one crate with a top-level `server` call (or `set :name`/`set :version`), then holds
      the declarations: `set` settings, `params` groups, routes, the request filters `before`, `not_found`
      and `error`, typed `helper`s, `use_layer` middleware, and the `use_bindings`/`rust_*`/`file` escape
      hatches. `use_layer :compression` (or `:trace`, `:cors` with `origins:`, `:timeout` with `secs:`)
      wraps the whole router in a tower-http layer; `:rate_limit` (`per:`, `burst:`, optional `path:`) and
      `:private_cache` (which appends `Cache-Control: private, no-cache` and `Vary: Cookie` to every
      response) are the compiler's own. `except: ["/assets"]` on `:private_cache` leaves its headers off
      the public files under a declared `static` mount (only a mount may be named); a route still adds
      `private, no-store` when it wants it. A layer answers every route, so where the declaration sits
      does not matter. The shape is
      Sinatra's: there is no enclosing block, so `server` carries only the crate's name and version and the
      routes sit at the top level. Paths use Sinatra's `:name` capture syntax, translated to axum 0.8's
      `{name}`.

      A `params` group is a struct of `field`s. A route names it with `params:` and reads it in the body
      with `params[:field]`. Each `field` takes `description:`, `optional: true` (the value is nil-able in
      the body), `default:` (the field is then always present) and JSON schema constraints the generated
      service also enforces: `min:` and `max:` on numbers, `exclusive_min:` and `exclusive_max:` (which the
      value must be above and below), `multiple_of:`, `min_length:`, `max_length:`, `pattern:` (Ruby regex source, translated
      to the Rust `regex` crate), `enum:` on strings, and `min_items:`/`max_items:` on lists. `in:` says which part of the
      request the field arrives in: `:path`, `:query`, `:body` or `:form` (an HTML form body, read by axum's
      Form extractor). It is optional except for `:form`, which is always written out; the verb decides the
      default (`:body` for post/put/patch, `:query` otherwise), and a group whose fields arrive in more than
      one part needs `in:` on each. A field's type is a scalar (`:i32`, `:i64`, `:f64`, `:bool`, `:string`), a
      list (`:string_list`, `:i64_list`, `:f64_list`, also `list(:string)`), a typed map with string keys and
      one value type (`map(:i64)`, `map(list(:string))`, `map(map(:i64))`), or the CamelCase name of another
      `params` declared above it (a nested object, read as `address.city`, or `address&.city` when the field
      is `optional: true`). `format:` (`:email`, `:uri`, ...) is advice to the client and is not checked.

      A route ends in a response. The last expression of the body is the body of the response as text
      (Sinatra's rule), and the response helpers say otherwise: `text(s)`, `html(s)`, `json(value)`,
      `redirect(path)` (a 302), `render(name, locals: {...})` (a view: a `.html` file beside the DSL file,
      read at compile time and compiled into the emitted Rust, wrapped in the `set :layout` layout unless
      `layout:` names another or `layout: nil` opts out; a view may write `{{ partial :name, key: value }}`
      to inline `views/name.html`, whose markers read only the call's arguments) and `halt(status, body)`
      (stop here with that
      status; `halt(status)` sends no
      body). `text`, `html`, `json` and `render` take `status:` and `content_type:` on the value they return. `status(...)`, `content_type(...)` and `headers(...)` are statements, not values; `content_type`
      is only meaningful in a `before` filter, where it is the default for the routes that follow, and
      `headers \"Cache-Control\" => \"no-store\"` adds header lines to the response. A `before` filter
      runs before every route that follows it; `not_found` answers a request that matched no route; `error`
      answers a route body that raised, with the raised value as the message.

      With a `database`, a body may wrap statement calls in `transaction do ... end`: `name = query_x(...)` locals
      and bare `execute`/`query` calls run on one connection, the block's final expression is its value, and a
      database error rolls the whole block back. Inside it only those calls and that final value are allowed; a
      `return`, `raise`, guard clause or other statement is refused, because a `return` would bypass the rollback
      and non-SQL work does not belong in a retried/rolled-back unit. The block is a `move` closure in Rust, so a
      value it uses is moved into it; clone it or compute it outside if the body needs it afterwards.

      A `helper` declares a typed function that route bodies and later helpers call by name: `helper :name,
      args: [:string], returns: :string do |text| ... end`. A helper may only call helpers declared above
      it, so recursion cannot happen, and a helper that nothing calls is refused. `setting :name, env:
      "VAR"` declares a value read from the environment when the service starts (`default:`, `optional:`,
      `secret:`, `type:`); a body reads it with `setting(:name)`.

      Sessions are the compiler's, with no Rust of the app's own: `cookies secret: :secret_key` signs cookies with a
      `setting`; `format: :rails` writes the classic Marshal MessageVerifier value and `format: :rails7` the
      JSON/`_rails` value a default Rails 7/8 app reads, instead of the default `:hmac` (a cookie call may pick
      either; `signed: false` is a plain cookie with no MAC). A body reads one with
      `cookie(:name)` (nil when absent or not signed by this key) and a route writes one with
      `set_cookie :name, value, http_only: true, same_site: :lax, permanent: true` and
      `delete_cookie :name`. `random_token`, `request_ip` and `user_agent` are values, `Bcrypt.verify(plain,
      digest)` and `Bcrypt.hash(plain)` are built in, and `current :user, returns: :User? do ... end` declares a
      per-request value that a route or filter reads with `current(:user)`; `required: :authenticate` makes it
      non-nil in routes that do not skip that named filter. `use_layer :fetch_metadata` refuses
      a cross-site write, `use_layer :csrf` (with `cookies secret:`) checks a signed token on every write and
      `{{ csrf_token }}` writes that token into a form, and `set :rust, :none` refuses every declaration that
      injects Rust.

      A large service splits into files: `use_dsl "dsl/routes.axum.rb"` splices in a fragment, a file whose
      one top-level call is `fragment do ... end` holding the same declarations. An error names the
      fragment's own file and line.

      Logic the body language cannot express comes in three ways: a binding (`use_bindings :name`, a typed
      function backed by a Rust crate or compiled from Ruby), injected Rust (`rust_crate`, `rust_item`,
      `rust_fn`, `rust_file`), or a subprocess (`cmd_fn`, `script_fn`). A file beside the DSL file can be
      read on each call (`file "path", as: :name`, read with `file_text(:name)`).

      The declarations are generated from the compiler's signature table, so this page matches the
      installed version.
    MD

    BODY_INTRO = <<~'MD'
      # Route bodies

      A route body is `do ... end`. It takes no block parameters: it reads its inputs with
      `params[:field]`, at the type the route's params declared. Before the last expression only
      `name = expression` locals, guard clauses (`return "x" if cond`, `raise "msg" unless cond`),
      `status(...)`/`headers(...)` statements, `content_type(...)` in a `before` filter, and `.each { ... }` loops are allowed. The last
      expression is the response; a plain string is the text, and `text(...)`, `html(...)`, `json(...)`,
      `redirect(...)` and `halt(...)` say otherwise. `return` ends the request with that string, even from
      inside a block. `raise "message"` ends it as an error: the `error` filter answers, or the generated
      service answers a plain 500 when there is none.

      A `current(:user)` whose declaration says `required: :authenticate` reads at its non-nil type in a route
      that does not skip that named filter: no `nil?`/`||` is needed, and a route that skips it is refused.

      A value placed in a page goes through `h(value)`, which escapes `&`, `<`, `>`, `"` and `'` and is
      what a page interpolates, or `raw(value)`, which leaves the value alone: `raw` is the XSS door, named
      so a review can grep for it. Neither is context-aware (a `javascript:` URL survives `h`) and nothing
      is sanitised.

      A route that names `params:` may also read `errors[:field]`: the message the generated `check()` has
      for that field, and an empty string when the request passed it (or that field had no violation), so
      a page interpolates it with no conditional. It carries only the `check()`'s own violations -- a
      request axum's extractor rejects is axum's own 422 and never reaches the body -- and reading it
      makes the route run its body on a violation and keep the 400, unless the body sets `status(...)`.
      `errors` is refused in a route with no `params:`, or one whose group has no constraint to report.

      Syntax available: `if`/`elsif`/`else` and `unless` (as a value they need an `else`),
      `case x when "a", /re/ then ... else ... end`, the ternary `c ? a : b`, `&&`, `||`, `!`,
      parentheses, string interpolation, and `rust(:name, args)` to call a declared function
      (`rust_fn`, `cmd_fn`, `script_fn`). Bindings are called as `Module.method(args)` after
      `use_bindings :name`.

      Integers: `:i32` and `:i64` arithmetic is overflow-checked, and `/` and `%` round down like Ruby.
      `Rust::Int32(x)` and `Rust::Int64(x)` opt into Rust's truncating semantics for one operation.

      Strings: Ruby's methods keep Ruby's rules (`strip` is not Rust's `trim`). `Rust::Str(s)` opts into
      Rust's `str` behaviour: `trim`, `strip` (the same as `trim`), `to_lowercase`, `to_uppercase`, `len`
      (bytes), `lines`, `split(pat)`, `contains(pat)`, `starts_with?(pat)` and `replace(from, to)`; `to_s`
      leaves it for a plain string. A body cannot return a Rust::Str without `to_s`.

      Values that may be nil: `xs[i]`, `xs.first`, `xs.last`, `s.index(x)` and `s =~ /re/` return nil in Ruby
      when nothing matches, so a body may only use them through `|| default` (the default runs only when
      the value is nil, and `|| raise("message")` is allowed), `.nil?` or `.to_s`. A field declared
      `optional: true` is nil-able the same way; an optional nested object is read with `&.`
      (`address&.city`). The `=~` operator takes a regex literal and gives the character index of the first
      match (not a boolean).

      Lists: `split`, `chars`, `lines`, `n.times`, `a.upto(b)`/`a.downto(b)`, ranges `(a..b)`, array
      literals, and `map join length size uniq reverse first last [] empty? include? count sort partition
      select reject find any? all? each`; `sum`, `min` and `max` are for integer and float lists. Blocks
      take one plain parameter and may use integer arithmetic, `to_i`, `raise` and `return`. A
      `list(:Address)` (a list of nested objects) supports
      `length size empty? first last [] each map select reject find any? all? count reverse`; ordering,
      equality and stringification are refused, because an object has none.

      Maps: a typed map is read-only. `m["k"]` is nil-able, and `fetch key? has_key? member? keys values
      size length empty? merge` read it; `map`, `select`, `reject` and `each` take a `|k, v|` block (the
      String key and the value). Nothing changes a map in place.

      Helpers: `helper :name, args: [:string, :i64], returns: :string do |text, n| ... end` declares a
      function that route bodies and later helpers call by name: `name(text, 3)`. Argument and result types
      are always written out: `:string`, `:i32`, `:i64`, `:f64`, `:bool`, `:string_list`, `:i64_list`,
      `:f64_list`, and a trailing ? makes a parameter or result nil-able (`:string?`, `:i64?`, ...). A helper
      may also take keyword parameters: `kw: { sep: [:string, false] }` with `do |text, sep: "-"| ... end`,
      called as `name(text, sep: ",")`. A helper may only call helpers declared above it. It may use
      `return`, `raise` and checked arithmetic; a failure becomes the request's error. A helper that nothing
      calls is refused. Sorbet cannot know names declared in the DSL, so run `axum_dsl rbi FILE...` to write
      their signatures to `sorbet/rbi/axum_dsl/dsl_helpers.rbi` and keep the file `# typed: true`; the
      compiler checks every call regardless.

      Settings and files: `setting(:name)` reads a value the service declared with `setting :name, env:
      "..."`, as its declared type (text when none). `file_text(:name)` is the text of a file declared with
      `file "path", as: :name`, read from disk on each call; `file_path(:name)` is the path it is read from.
      `entry(:name, :fn)` is a declared entry's name and `entry_args(:name, :fn, key: value, ...)` builds its
      arguments as JSON, checked against the file.

      Errors: `raise "message"` (or `raise some_string`) ends the request with that message, which the
      `error` filter or the default 500 answers. It has no value, so use it where any type fits, for example
      `cond ? raise("bad") : value`. Integer overflow and division by zero also end the request as an error.

      The DSL is strict on purpose so the file says exactly what the service does and the generated Rust
      stays warning-free. Unused locals, declarations, helpers and params are refused.
    MD

    NOTIFY_TEXT = <<~'MD'
      Notifications never change the generated code or fail a build; the environment only decides what
      is printed. Set `AXUM_DSL_WARN` or `AXUM_DSL_NOTICE` to `all`, `none` or a comma-separated list
      of codes, or pass `--warn SPEC` and `--notice SPEC`. An unknown code is an error.
    MD

    BODY_LIMITS = <<~'MD'
      ## Not supported yet

      These are refused today; the compiler's message is the authority if this list is out of date.

      - `def` inside a body, and `while`/`for` loops.
      - Regex literals are only accepted by `gsub`, `sub`, `match?`, `=~` and `when`.
      - `status(...)` is parsed but has no effect on the generated response yet.
      - `entry_args(...)` and a typed map's `to_json` are refused by rustc: they are still emitted against
        `rmcp::serde_json` (the compiler this one was ported from), so the generated crate does not build
        when a body uses them.
      - The content-block builders (`image`, `audio`, `resource_link`, `embedded_text`, `embedded_blob`)
        are the same: they name `rmcp::model` types, which an axum crate does not have.
      - A typed map's value may be a scalar, a list, another params object or one nested map; collections
        nested more deeply than that are refused.

      Predicates and extraction are often expressible anyway: `s.sub(/\Ahttp/, "") != s` tests a prefix,
      and two `sub` calls with lazy, dot-all patterns (`/\A.*?<title[^>]*>/mi`) cut text out between tags.
    MD

    CLI_TEXT = <<~'MD'
      # Command line

      ```
      axum_dsl check FILE.rb [--format json]
      axum_dsl build FILE.rb [-o DIR] [--release] [--emit-only]
      axum_dsl run   FILE.rb [-o DIR] [--release]
      axum_dsl init  NAME [-o DIR] [--force] [--no-bindings]
      axum_dsl check FILE.rb --format json --types
      axum_dsl rbi   FILE.rb... [-o DIR]
      axum_dsl lsp
      axum_dsl skill [-o DIR]
      axum_dsl FILE.rb -o DIR | --dump-ir | --check      (the original form)
      ```

      - `check` validates only and writes nothing. With `--format json` it prints one document:
        `{"ok":true,"file":...,"notes":[{code,level,line,col,message,file}],"hidden":N}`, or on failure
        `{"ok":false,"file":...,"error":{file,line,col,message,suggestions}}`. Exit status 1 on failure. An
        error names the valid choices and, for a likely typo, suggests the nearest name (`suggestions`). With
        `--types` the success document also has `"types"`: `[{line,col,end_line,end_col,kind,type,name?}]`, the
        type the compiler inferred for every parameter, local and expression (1-based lines and columns,
        `end_col` exclusive).
      - `rbi` writes Sorbet signatures for the helpers the files declare to `sorbet/rbi/axum_dsl/dsl_helpers.rbi`.
      - `lsp` runs a language server on stdio: diagnostics from the compiler over the buffer being edited,
        plus hover and completion from the declaration table; see [Editor support](editor-support.md).
        Name DSL files `*.axum.rb` so an editor can attach it.
      - `build` writes the crate to `-o DIR` (default `build/NAME`) and runs `cargo build`; `--emit-only`
        stops after writing and `--release` is passed to cargo. The crate is a standalone cargo workspace.
        Rust errors in generated code are printed as `FILE:LINE: error: ... (in `what`)`.
      - `run` builds, then starts the service. Nothing else may write to stdout while it runs.
      - `init` writes `NAME.axum.rb` (a minimal service) and a `bindings/` folder (with a
        `.gitkeep`) into `-o DIR` (default `.`). It refuses to overwrite an existing file
        without `--force`, and `--no-bindings` skips the folder.
      - `skill` writes this skill into `-o DIR` (default the current directory) as `axum-dsl/`.
      - `--warn SPEC` and `--notice SPEC` choose which notifications are printed (`all`, `none`, codes).
      - `--dump-ir` prints the intermediate representation as JSON.

      `build` and `run` need `cargo` on the PATH; `check` needs only Ruby.
    MD

    BINDINGS_INTRO = <<~'MD'
      # Bindings

      A binding is a typed function backed by a Rust crate (or compiled from Ruby). The compiler ships none:
      they are yours, kept in a `bindings/` folder in the SAME directory as the DSL file that uses them
      (nothing is searched beyond that). `use_bindings :words` at the top of the file loads
      `bindings/words.rb` from there (parsed, never run), and a body calls it as `Module.method(args)`. A
      missing file is an error that names the path it looked for. A binding file looks like this:

      ```ruby
      BINDING_EXAMPLE_HERE
      ```

      - `sig` gives the types: `String`, `Float`, `I32`, `I64`, `T::Boolean`, `T::Array[String]`,
        `T::Array[I64]`, `T::Array[Float]`, and `T.nilable(...)` of those, for a return or a parameter.
      - Without a `rust` line the Ruby body is compiled to Rust and is the implementation. With
        `rust "heck::ToSnakeCase::to_snake_case(s)"` above the method, that Rust expression does the work and
        the Ruby body is only the reference the tests compare it against. `no_reference "why"` marks a
        function with no Ruby stand-in (an HTML parser, DNS).
      - `crate "heck", "0.5"` adds a Cargo dependency. `example :method, args..., expect: value` documents a
        function; the test generators in the compiler's repository run examples, the compiler itself only
        reads the types.
      - A binding may own a type with `class Value < AxumDsl::Opaque; type_rust "serde_json::Value", wire: true; end`,
        the DSL holds values of it, passes them to that binding's functions and, with `wire: true`, takes them
        as a `field`. A **record** also lists its fields after `type_rust` (`field :text, String`), which a body
        reads (`row.text`); the generated service checks each field against the Rust struct.

      The repository ships no example bindings yet, so the format above is the reference.

      A nil-able return type means "does not exist" or "does not parse", and a binding never fails by
      itself: the body decides what that means. Use `|| default` to carry on, `|| raise("message")` to
      fail the request, `|| []` for a nil-able list, or `.nil?` to test.
    MD

    TYPE_NAMES = { string: "String", f64: "Float", i32: "I32", i64: "I64", bool: "T::Boolean",
                   strs: "T::Array[String]", i64s: "T::Array[I64]", f64s: "T::Array[Float]", ostr: "T.nilable(String)",
                   oi32: "T.nilable(I32)", oi64: "T.nilable(I64)", of64: "T.nilable(Float)",
                   obool: "T.nilable(T::Boolean)", ostrs: "T.nilable(T::Array[String])",
                   oi64s: "T.nilable(T::Array[I64])", of64s: "T.nilable(T::Array[Float])" }.freeze

    # A binding the page shows: it is parsed by the real loader in the tests, so the page cannot drift from the format.
    BINDING_EXAMPLE = <<~'RB'
      # bindings/words.rb, in the same directory as the DSL file
      module Words
        extend T::Sig
        extend AxumDsl::BindingDsl

        sig { params(s: String).returns(String) }
        def self.shout(s) = s.upcase + "!"
        example :shout, "hello", expect: "HELLO!"
      end
    RB

    module_function

    # { path relative to the output directory => text }
    def files
      { "#{NAME}/SKILL.md" => skill_md,
        "#{NAME}/references/dsl.md" => dsl_md,
        "#{NAME}/references/body-language.md" => body_md,
        "#{NAME}/references/bindings.md" => bindings_md,
        "#{NAME}/references/cli.md" => CLI_TEXT }
    end

    def skill_md
      front = ["---", "name: #{NAME}", "description: #{DESCRIPTION.inspect}", "---", ""].join("\n")
      "#{front}\n#{SKILL_TEXT.sub('%EXAMPLE%', BASIC)}\n_Generated by axum_dsl #{VERSION}._\n"
    end

    def dsl_md
      types = TYPES.map { |k, v| "- `:#{k}` is Rust `#{v}`" }
      calls = SIG.flat_map { |name, sig| call_lines(name, sig) }
      [DSL_INTRO, "## Types", "", *types, "", "## Declarations", "", *calls,
       "## Examples", "", "A string route:", "", fence(TEXT), "",
       "A route backed by a subprocess, with no Rust:", "", fence(CMD), ""].join("\n")
    end

    def body_md
      methods = Body::ALLOWED_METHODS.map { |m| "`#{m}`" }.join(", ")
      helpers = Docs::BODY_HELPERS.map { |_name, text| "- #{text}" }
      shims = catalog.select { |e| e["receiver"] == "native_ruby" }.map { |e| shim_line(e) }
      codes = Notify::CODES.map { |code, level| "- `#{code}` (#{level})" }
      [BODY_INTRO, "## Methods", "", "Allowed: #{methods}, plus `rust(:name, args)` for a declared function.", "",
       "## Body helpers", "", *helpers, "",
       "String methods in detail:", "", *shims, "", "## Notifications", "", NOTIFY_TEXT, *codes, "", BODY_LIMITS].join("\n")
    end

    def bindings_md = BINDINGS_INTRO.sub("BINDING_EXAMPLE_HERE", BINDING_EXAMPLE.chomp)

    def catalog = YAML.safe_load_file(CATALOG)

    def fence(code) = "```ruby\n#{code.chomp}\n```"

    def shim_line(entry)
      bits = [entry["notes"], entry["notify"] && "Prints #{entry['notify']['code']} (#{entry['notify']['level']})."].compact
      "- `#{entry['name']}`#{bits.empty? ? '' : ": #{bits.join(' ')}"}"
    end

    def call_lines(name, sig)
      optional = sig[:optional_pos] || 0
      pos = sig[:names].each_with_index.map do |n, i|
        mark = i >= sig[:names].size - optional ? ", optional" : ""
        "`#{n}` (#{kind(sig[:pos][i])}#{mark})"
      end
      kws = sig[:kw].map { |n, (k, req)| "`#{n}:` (#{kind(k)}, #{req ? 'required' : 'optional'})" }
      block = { nil => "no block", decls: "a block of DSL declarations", body: "a block of restricted Ruby" }.fetch(sig[:block])
      about = Docs.call(name)
      kw_docs = sig[:kw].keys.filter_map { |kw| (text = Docs.keyword(name, kw)) && "  - `#{kw}:` #{text}" }
      ["### `#{name}`", "", *(about ? [about, ""] : []),
       "- Allowed inside: #{Array(sig[:in]).map { |c| c == :top ? 'the top level of the file' : "`#{c}`" }.join(' or ')}",
       "- Positional arguments: #{pos.empty? ? 'none' : pos.join(', ')}",
       "- Keyword arguments: #{kws.empty? ? 'none' : kws.join(', ')}", *kw_docs,
       "- Takes #{block}", ""]
    end

    # How a signature-table kind reads in prose.
    def kind(kind)
      case kind
      when :str then "string literal"
      when :bool then "true or false"
      when :lit then "a string, number or true/false literal"
      when :setting then "a string, number or true/false literal, or a symbol naming what the setting points at, such as the view `set :layout` names"
      when :default then "a string, number or true/false literal, or a list of them for a list field"
      when :fieldtype then "a type symbol (#{(TYPES.keys + FIELD_LISTS).map(&:inspect).join(', ')}, map(...), list(...), or the CamelCase name of another params to nest an object)"
      when :num then "number literal"
      when :uint then "non-negative integer literal"
      when :snake then "snake_case symbol"
      when :camel then "CamelCase symbol"
      when :htypes then "array of helper type symbols, such as [:string, :i64?]"
      when :types then "array of type symbols"
      when :helper_kw then "hash of `name: [type, required]` keyword parameters"
      when :strs then "array of string literals"
      when :snakes then "array of snake_case symbols, such as %i[place look]"
      when :file_checks then "array of check names: #{FILE_CHECKS.map(&:inspect).join(', ')}"
      when :sqlargs then "hash of the query's arguments, such as `{ limit: :i64 }`; each a scalar type"
      when :qreturns then "`list(:Record)`, `:Record?` or a scalar type (`?` for nil-able)"
      when Array then "one of #{kind.map(&:inspect).join(', ')}"
      else kind.to_s
      end
    end
  end
end
