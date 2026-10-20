# frozen_string_literal: true

module AxumDsl
  # Transpiles one body block to Rust text: a route's `do ... end`, a `before do ... end` filter, a tool's.
  # The reader passes `kind:` for a body that answers an HTTP request (:route, :before, :not_found, :error);
  # the response helpers (json, text, html, halt, redirect) are only in scope there.
  # expr() returns [rust, type, atomic]; atomic means "safe as an operand or receiver
  # without parentheses". Types: :i32 :i64 :f64 :bool :string :str (&'static str) :int (literal).
  class Body
    include Diag

    ARITH = %i[+ - * / %].freeze
    ORDER = %i[< <= > >=].freeze
    EQ = %i[== !=].freeze
    INTS = %i[i32 i64].freeze
    NUM = %i[i32 i64 f64 int].freeze
    STRM = { upcase: "to_uppercase", downcase: "to_lowercase" }.freeze
    # Every method a body may call, for the refusal message and the generated skill. The shim
    # catalog (spec/shims/string.yml) documents the string ones; test/test_skill.rb checks the two agree.
    ALLOWED_METHODS = %w[+ - * / % == != < <= > >= ! -@ to_s upcase downcase strip gsub sub split length size
                         capitalize map join start_with? end_with? include? empty? match? reverse first last [] index tr delete
                         squeeze to_i each select reject find any? all? count sort uniq partition chars lines times upto downto
                         sum min max to_a fetch key? has_key? member? keys values merge tally =~
].freeze

    # The calls a body makes by name: the reader's own reads of the request (params, errors, setting, the file
    # helpers), the one escape hatch (rust), and the response surface (RESPONSE_HELPERS plus the status,
    # content_type and headers statements). bin/gen_rbi declares exactly these for Sorbet, and test/test_body_surface.rb
    # holds the two lists equal so the rbi cannot drift from what the compiler accepts. The methods a body
    # calls on a value (ALLOWED_METHODS, above) are the other half of the surface: Sorbet's own String, Array
    # and Hash rbis declare those, together with the Rust::Str section of the generated rbi.
    BODY_CALLS = %i[params errors text json html halt redirect status content_type headers etag setting rust
                    file_text file_path entry entry_args h raw render send_file rails_signed_id
                    cookie set_cookie delete_cookie random_token request_ip user_agent current transaction].freeze

    # The response helpers and the statuses and types they name (Sinatra's spelling, axum's semantics). A
    # route body, and the filters around it, is a body that answers an HTTP request: the reader passes
    # `kind:` for one of these, and the response helpers are only in scope there.
    RESPONSE_BODY_KINDS = %i[route before not_found error].freeze
    RESPONSE_HELPERS = %i[json text html halt redirect render send_file].freeze
    # `::axum::response::Response`, what an axum handler returns, and the trait method every helper goes
    # through so its concrete type is named exactly once.
    INTO = "::axum::response::IntoResponse::into_response"
    # The keywords `render` takes: the values the view's markers read, by name, the layout that wraps the
    # view (`layout: nil` opts out of the `set :layout` default), the status this response answers with,
    # and the MIME type its body carries (`content_type: "text/html"`).
    RENDER_KEYWORDS = %i[status content_type locals layout].freeze
    # The keywords `text`, `html` and `json` take: the same status and content type, and no view keywords.
    RESPONSE_KEYWORDS = %i[status content_type].freeze
    # The statuses `redirect(path, status: N)` accepts: the ones HTTP defines for a redirect.
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
    # What a redirect path may interpolate: `format!` writes an integer, a float or a bool as digits, a
    # sign or true/false, and no header value rejects those; a string could carry a control byte.
    HEADER_SCALARS = %i[i32 i64 f64 bool int].freeze
    # The Rust local the emitted handler binds the generated check()'s messages in, and what a body's
    # `errors[:field]` reads (emit.rb: check_impl, errors_binding). Dunder-named so no field of a params
    # group can shadow it in the destructuring that follows the extractors.
    ERRORS_MAP = "__errors"
    # Sinatra's status symbols, mapped to axum's StatusCode variants. An integer status is built from it.
    STATUS_CODES = {
      ok: "OK", created: "CREATED", accepted: "ACCEPTED", no_content: "NO_CONTENT",
      moved_permanently: "MOVED_PERMANENTLY", found: "FOUND", see_other: "SEE_OTHER", not_modified: "NOT_MODIFIED",
      temporary_redirect: "TEMPORARY_REDIRECT", bad_request: "BAD_REQUEST", unauthorized: "UNAUTHORIZED",
      payment_required: "PAYMENT_REQUIRED", forbidden: "FORBIDDEN", not_found: "NOT_FOUND",
      method_not_allowed: "METHOD_NOT_ALLOWED", not_acceptable: "NOT_ACCEPTABLE", conflict: "CONFLICT", gone: "GONE",
      length_required: "LENGTH_REQUIRED", payload_too_large: "PAYLOAD_TOO_LARGE", uri_too_long: "URI_TOO_LONG",
      unsupported_media_type: "UNSUPPORTED_MEDIA_TYPE", unprocessable_entity: "UNPROCESSABLE_ENTITY",
      too_many_requests: "TOO_MANY_REQUESTS", internal_server_error: "INTERNAL_SERVER_ERROR",
      not_implemented: "NOT_IMPLEMENTED", bad_gateway: "BAD_GATEWAY", service_unavailable: "SERVICE_UNAVAILABLE",
      gateway_timeout: "GATEWAY_TIMEOUT"
    }.freeze
    # What `content_type(:name)` sets, as the header value the generated response carries.
    CONTENT_TYPES = { json: "application/json", html: "text/html", text: "text/plain", xml: "application/xml",
                      csv: "text/csv", form: "application/x-www-form-urlencoded" }.freeze
    # A helper's `content_type:` value: a MIME type as the Content-Type header carries it -- a type and a
    # subtype, then optional `; name=value` parameters (a token or a quoted string). It is a string literal
    # in the source, so the emitted header is static text.
    MEDIA_TYPE = %r{\A[!\#$%&'*+\-.^_`|~0-9A-Za-z]+/[!\#$%&'*+\-.^_`|~0-9A-Za-z]+(?:[ \t]*;[ \t]*[!\#$%&'*+\-.^_`|~0-9A-Za-z]+[ \t]*=[ \t]*(?:[!\#$%&'*+\-.^_`|~0-9A-Za-z]+|"[^"\\\x00-\x1f\x7f]*"))*\z}

    # Values that may be nil in Ruby (list indexing, index): Option in Rust. Only `|| default`,
    # `.nil?` and `.to_s` may consume them, so a missing value is never silently used.
    OPT_FIXED = { ostr: :string, oi64: :i64, oi32: :i32, of64: :f64, obool: :bool, ostrs: :strs, oi64s: :i64s, of64s: :f64s, ojson: :json }.freeze
    OPT = CompositeTypes::OptTable.new(OPT_FIXED)
    OPT_OF = CompositeTypes::OptOfTable.new(OPT_FIXED.invert) # element type -> nil-able type, for optional fields
    # Typed maps (T::Hash[String, V]); see CompositeTypes. Like a list they are only ever borrowed.
    MAPS = CompositeTypes::MapTable.new
    MAP_ARITY = { :[] => 1, :fetch => 1..2, :key? => 1, :has_key? => 1, :member? => 1, :include? => 1, :keys => 0,
                  :values => 0, :size => 0, :length => 0, :empty? => 0, :merge => 1, :map => 0, :select => 0, :reject => 0, :each => 0, :to_json => 0 }.freeze
    LIST_BLOCK = %i[each select reject find any? all? count].freeze
    # List types and their element types. Code that differs between the kinds lives in list_call and its
    # helpers; everything else treats a list as opaque.
    LISTS = { strs: :string, i64s: :i64, f64s: :f64 }.freeze
    LIST_OF = LISTS.invert.freeze
    # The methods a list of another params struct supports. Ordering, equality and stringification (sort,
    # uniq, include?, join, sum, min, max) are refused: the elements have no order or equality of their own.
    STRUCT_LIST_METHODS = %i[length size empty? first last [] each map select reject find any? all? count reverse].freeze
    LIST_ARITY = { length: 0, size: 0, empty?: 0, first: 0, last: 0, sort: 0, uniq: 0, reverse: 0, to_a: 0,
                   sum: 0, min: 0, max: 0, join: 0..1, :[] => 1, include?: 1, map: 0, select: 0, reject: 0, each: 0,
                   find: 0, any?: 0, all?: 0, count: 0, tally: 0 }.freeze
    INT_LIST_METHODS = %i[sum min max].freeze
    FLOAT_LIST_METHODS = %i[sum min max].freeze
    LIST_METHODS = (%i[length size map join first last [] empty? include? sort uniq reverse to_a tally] + LIST_BLOCK).freeze
    # One-string-argument tests: Ruby method => Rust str method. Regex arguments are refused (use match?).
    STR_TESTS = { start_with?: "starts_with", end_with?: "ends_with", include?: "contains" }.freeze
    # Ruby split with no argument: ASCII whitespace separators only (no NBSP, no NUL).
    SPLIT_WS = %q(|c: char| matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'))
    # Ruby String#strip: NUL, tab, LF, VT, FF, CR and space. Rust trim() differs
    # (Unicode whitespace, no NUL), so the set is spelled out. See spec/shims/string.yml.
    STRIP_FN = %q(|c: char| matches!(c, '\u{0}' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' '))

    def initialize(path, params, regexes = [], externs = {}, flags = {}, tool = nil, bindings = {}, helpers = {}, structs = [], outputs = [], mime_type: nil, kind: nil, skip: [])
      @path = path
      @outputs = outputs # structured results a tool may build with Name.new(...)
      @structs = structs # every params struct, so a nested object's fields can be read
      # A query record derives Clone (db/sqlite.rb), so a record local is cloned where Rust would move it.
      @record_types = structs.filter_map { |s| :"struct:#{s['name']}" if s["kind"] == "record" }
      @helpers = helpers # helpers declared above this body: name -> record (see Reader#helper_decl)
      @ret = :string     # what `return` must return: a tool returns a string, a helper its declared type
      @helper = false
      @bindings = bindings
      @regexes = regexes
      @externs = externs
      @flags = flags
      @tool = tool
      @body_line = nil      # the line the enclosing body opened at, named when a top-level declaration lands inside it
      @fallible = false
      @uses_async = false   # a tool body (or a helper it calls) awaits, so its fn is async
      @async_reason = nil   # the first construct that made the body async, for diagnostics and hover
      @kind = kind          # the enclosing call, when the reader knows it (:route, :before, :not_found, :error)
      @skips = skip         # a route's `skip:` names: a required current read on one of them is refused
      @currents_read = []   # the `current`s this body read, so the filter a `required:` names can be checked
      @route = RESPONSE_BODY_KINDS.include?(kind) # a body that answers an HTTP request, not an MCP call
      @status = nil         # a `status(...)` statement's StatusCode, applied by `lower` to what the body ends in
      @status_site = nil    # that statement's node, named when a helper's `status:` is also in the body
      @helper_status = nil  # [node, helper] of a `render`/`html`/`text`/`json` `status:`, which rides on the value
      @content_type_site = nil    # that statement's node, named when a helper's `content_type:` is also in the body
      @helper_content_type = nil  # [node, helper] of a helper's `content_type:`, which rides on the value
      @content_type = nil   # a `content_type(...)` statement's type, the response default the emitter sets
      @headers = nil        # a `headers(...)` statement's response headers, as [name, value] pairs
      @etag = nil           # an `etag(value)` statement's value (a Rust String expression), applied by the emitter
      @needs = {}           # what the body reads of the request: :headers, :peer, :currents (the emitter binds exactly these)
      @cookies_written = false # a `set_cookie` / `delete_cookie` statement: the emitter keeps the Set-Cookie lines

      @read = {}       # names of locals / block parameters that are read somewhere
      @declared = []   # [name, node, what] for every local and block parameter declared
      @mime_type = mime_type # the resource mime_type, the default of a resource content keyword
      @used_read_uri = false # a resource content took the read uri as its default
      @in_transaction = false # lowering a transaction block: query/execute calls emit their sync `_on` core on `__tx`
      # errors[:field] is the generated check()'s message for one field, so it is only there in a route
      # that named a params group: the group's name is what makes the body value legal, and the reader
      # refuses one whose group has no constraint to report (see errors_read).
      @params_name = params["name"]
      @errors_used = false
      # An optional field is nil-able in the body: use `|| default`, `.nil?` or `.to_s`.
      @types = params["fields"].to_h { |f| [f["name"], field_type(f)] }
      @enums = params["fields"].to_h { |f| [f["name"], f["enum"]] }.compact # for entry_args into a Literal field
    end

    def lower(blk, output = nil)
      @body_line = blk.location.start_line
      names = block_params(blk.parameters)
      @ret = :"struct:#{output}" if output
      env = names.to_h { |n| [n.to_sym, @types.fetch(n)] }
      names.each_with_index do |n, i|
        @declared << [n.to_sym, blk.parameters.parameters.requireds[i], "parameter"]
        note_decl(blk.parameters.parameters.requireds[i].location, n.to_sym, "parameter", env[n.to_sym])
      end
      st = blk.body
      bad(blk, "empty body") unless st
      bad(st, "unsupported #{nodename(st)} as body") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env)
      e = unparen(e)
      bad(st, "a body cannot end in `raise` or `return`; end it in a string value") if t == :never
      if output
        bad(st, "this tool returns #{output}; end the body with result(:#{output}, ...), got #{t}") unless t == @ret
      elsif t == :secret
        bad(st, "a secret cannot be returned; pass it to a binding or rust_fn function and return what that gives back")
      elsif %i[block blocks].include?(t)
        e = "vec![#{e}]" if t == :block
      elsif %i[rcontent rcontents].include?(t)
        e = "vec![#{e}]" if t == :rcontent
      else
        built = resource_body? ? "text(...) or blob(...)" : "text(...) or image(...)"
        ok = %i[string str unit].include?(t) || (@route && t == :response)
        bad(st, "body must return a string, got #{TypeNames.display(t)}; use .to_s, or end it in a content block such as #{built}") unless ok
        e = "#{e}.to_string()" if t == :str
      end
      reject_unused
      type = if output then "struct:#{output}"
             elsif %i[block blocks].include?(t) then "blocks"
             elsif %i[rcontent rcontents].include?(t) then "rcontents"
             elsif t == :response then "response"
             elsif t == :unit then "unit"
             else "string"
             end
      body = { "args" => names, "locals" => lets, "expr" => e, "type" => type, "fallible" => @fallible,
               "uses_async" => @uses_async, "async_reason" => @async_reason, "uses_uri" => @used_read_uri,
               "content_type" => @content_type&.to_s, "status" => @status, "headers" => @headers, "etag" => @etag }
      # The emitter binds the check's own messages for a route whose body read errors (emit.rb: route_fn,
      # response_expr); a body that never reads them leaves this out, so every other route emits exactly
      # what it emitted before.
      body["errors"] = true if @errors_used
      # What the body reads of the request (cookie, request_ip, user_agent, current), and whether it writes cookies:
      # the emitter adds the extractors and the Set-Cookie list a route needs for them (emit.rb: route_fn).
      body["request"] = @needs.keys.map(&:to_s).sort unless @needs.empty?
      body["currents"] = @currents_read.uniq unless @currents_read.empty?
      body["cookies"] = true if @cookies_written
      body
    end

    private

    # Rust would warn about these, so the DSL refuses them: the compiled code stays warning-free
    # and the DSL file says exactly what the implementation does.
    def reject_unused
      name, node, what = @declared.find { |n, _, _| !@read[n] }
      return unless name

      hint = if what == "local" then "remove it, or use it"
             elsif @helper then "remove it from the helper's `args:` and its |...| list"
             else "remove it from the |...| list (callers still send that field)"
             end
      bad(node, "#{what} `#{name}` is never read; #{hint}")
    end

    def block_params(ps)
      return [] unless ps
      bad(ps, "a route body takes no block parameters; read an input with params[:name]") if @route
      bad(ps, "unsupported #{nodename(ps)} as body parameters") unless ps.is_a?(Prism::BlockParametersNode)
      bad(ps, "block-local variables are not allowed") unless ps.locals.empty?
      pn = ps.parameters
      return [] unless pn
      extra = [pn.optionals, pn.posts, pn.keywords].any? { |x| !x.empty? } || pn.rest || pn.keyword_rest || pn.block
      bad(pn, "only plain required parameters are allowed") if extra
      pn.requireds.each_with_object([]) do |r, acc|
        bad(r, "unsupported #{nodename(r)} as a body parameter") unless r.is_a?(Prism::RequiredParameterNode)
        unless @types.key?(r.name.to_s)
          bad(r, "`#{r.name}` is not a field of the tool's params (fields: #{@types.keys.join(', ')})", word: r.name, from: @types.keys)
        end
        bad(r, "duplicate parameter `#{r.name}`") if acc.include?(r.name.to_s)
        acc << r.name.to_s
      end
    end

    # [let-lines, final expr, type, atomic]; only `name = expr`, a guard clause, `status(...)`,
    # `content_type(...)`, `headers(...)` or `.each { ... }` may precede the last expression.
    def stmts(st, env)
      outer = @after.to_a # what follows the enclosing statement, which also follows every statement here
      init = st.body[0...-1]
      lets = init.each_with_index.flat_map do |n, i|
        @after = st.body[(i + 1)..] + outer # what follows, so a narrowing guard knows whether the local is read again
        statement(n, env)
      end
      @after = outer
      last = expr(st.body.last, env)
      @after = outer
      [lets, *last]
    end

    # One statement before a body's or an each block's last expression: a local, a guard clause, a
    # status/content_type/headers call, a bare execute/query call, or an each loop. Anything else is refused.
    def statement(n, env)
      return status_stmt(n, args_of(n)) if route_stmt?(n, :status)
      return content_type_stmt(n, args_of(n)) if route_stmt?(n, :content_type)
      return headers_stmt(n, args_of(n)) if route_stmt?(n, :headers)
      return etag_stmt(n, args_of(n), env) if route_stmt?(n, :etag)
      return set_cookie_stmt(n, args_of(n), env) if cookie_stmt?(n, :set_cookie)
      return delete_cookie_stmt(n, args_of(n)) if cookie_stmt?(n, :delete_cookie)
      return [guard(n, env)] if n.is_a?(Prism::IfNode) || n.is_a?(Prism::UnlessNode)
      return each_stmt(n, env) if each_call?(n)
      return query_stmt(n, env) if bare_query_call?(n)

      let_stmt(n, env)
    end

    # A bare `execute`/`query` call in statement position: run it for its effect and drop its value. It
    # declares no local, so nothing can be left unread; the call itself still refuses where it may not run.
    def bare_query_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && @flags.dig("queries", node.name.to_s)
    end

    def query_stmt(node, env)
      e, = expr(node, env)
      ["#{unparen(e)};"]
    end

    # `name = expr` as a statement. The local is declared once and may not be reassigned.
    def let_stmt(n, env)
      bad(n, "unsupported #{nodename(n)} as a statement (only `name = expr`, a guard clause, `status(...)`, `content_type(...)`, `headers(...)`, a bare `execute`/`query` call or `.each { ... }` before the last expression)#{top_level_hint(n)}") unless n.is_a?(Prism::LocalVariableWriteNode)
      bad(n, "`#{n.name}` is already defined (no reassignment)") if env.key?(n.name)
      bad(n, "local `#{n.name}` must be snake_case and not a Rust keyword") if !n.name.to_s.match?(SNAKE) || RUST_KW.include?(n.name.to_s)
      e, t, = kept(n.value, expr(n.value, env))
      env[n.name] = t
      @declared << [n.name, n, "local"]
      note_decl(n.name_loc, n.name, "local", t)
      # A value such as `xs.length` carries its own parens (`(xs.len() as i64)`); rustc warns on them here.
      ["let #{n.name} = #{unparen(e)};"]
    end

    # A statement that only belongs at the top level (`params`, `tool`, `field`, ...) usually means an
    # unbalanced `end` above: the enclosing body swallowed it. Name that body and where it opened.
    def top_level_hint(n)
      return nil unless n.is_a?(Prism::CallNode) && SIG.key?(n.name) && @tool

      "; `#{n.name}` is a top-level declaration, and the enclosing #{@tool} body, opened at line #{@body_line}, is still open: check for a missing `end` above"
    end

    # Is this node a bare `.each { ... }` call in statement position? It must have a receiver and a block.
    def each_call?(node)
      node.is_a?(Prism::CallNode) && node.name == :each && node.receiver && node.block
    end

    # `xs.each { |x| ... }` / `m.each { |k, v| ... }` as a statement: run the block for its effects
    # (raise, return, a helper call) and drop the receiver Ruby's each would return. The
    # block's value is ignored, unlike map, which must produce a string or an integer.
    def each_stmt(node, env)
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "`each` takes no arguments; write `xs.each { |x| ... }`") unless args.empty?
      recv = expr(node.receiver, env)
      bad(node, "a secret has no methods (not `each`): it can only be passed to a binding or rust_fn function") if recv[1] == :secret
      bad(node, "this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `each`)") if OPT.key?(recv[1])
      bad(node, "#{opaque_name(recv[1])} is an opaque value with no methods of its own (not `each`); pass it to a function of its binding") if opaque?(recv[1])
      bad(node, "`each` needs a list or a map, got #{TypeNames.display(recv[1])}") unless LISTS.key?(recv[1]) || struct_list?(recv[1]) || MAPS.key?(recv[1])

      [each_loop(node, recv, env, wrap(recv))]
    end

    # `each` as an expression: Ruby's each returns its receiver, so the loop runs and the receiver
    # is cloned out. A list is only ever borrowed, so the receiver is bound once for both uses.
    def each_expr(node, recv, env)
      ["{ let __v = &#{wrap(recv)}; #{each_loop(node, recv, env, '__v')} (*__v).clone() }", recv[1], false]
    end

    # The for loop of an each block (a list or a map), shared by the statement and expression
    # positions. The block's value is ignored, so it may end in a guard clause or a status/content_type/headers call;
    # a trailing value expression is emitted and dropped.
    def each_loop(node, recv, env, iterable)
      blk = node.block
      bad(node, "`each` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      st = blk.body
      bad(blk, "empty each block") unless st.is_a?(Prism::StatementsNode)
      if LISTS.key?(recv[1])
        elem = LISTS.fetch(recv[1])
        param = block_param(blk, env, "`each`", elem)
        body = each_block_stmts(st, env.merge(param => elem))
        "for __e in #{iterable}.iter() { let #{param} = #{elem == :i64 ? '*__e' : '__e.to_string()'}; #{body.join(' ')} }"
      elsif struct_list?(recv[1])
        elem = list_elem(recv[1])
        param = block_param(blk, env, "`each`", elem)
        body = each_block_stmts(st, env.merge(param => elem))
        "for __e in #{iterable}.iter() { let #{param} = (*__e).clone(); #{body.join(' ')} }"
      elsif CompositeTypes.map_list_sym?(recv[1])
        elem = CompositeTypes.map_list_value(recv[1])
        param = block_param(blk, env, "`each`", elem)
        body = each_block_stmts(st, env.merge(param => elem))
        "for __e in #{iterable}.iter() { let #{param} = (*__e).clone(); #{body.join(' ')} }"
      else
        value = MAPS.fetch(recv[1])
        kname, vname = map_block_params(blk, env, :each, value)
        body = each_block_stmts(st, env.merge(kname => :string, vname => value))
        "for (__k, __v) in #{iterable}.iter() { let #{kname} = __k.to_string(); let #{vname} = #{map_block_value(value)}; #{body.join(' ')} }"
      end
    end

    # The statements of an each block. Its value is discarded, so its last statement may be a guard
    # clause, a status/content_type/headers call or another each; any other trailing expression is emitted and dropped.
    def each_block_stmts(st, env)
      @in_each = (@in_each || 0) + 1
      st.body.flat_map do |n|
        if route_stmt?(n) || cookie_stmt?(n) || each_call?(n) || n.is_a?(Prism::LocalVariableWriteNode) || guard_clause?(n)
          statement(n, env)
        else
          e, = expr(n, env)
          ["#{unparen(e)};"]
        end
      end
    ensure
      @in_each -= 1
    end

    # A guard clause is an `if`/`unless` with no else; only those may stand as a statement.
    def guard_clause?(n)
      (n.is_a?(Prism::IfNode) && n.subsequent.nil?) || (n.is_a?(Prism::UnlessNode) && n.else_clause.nil?)
    end
    # The one place every expression is typed; with --types each typed node is also reported.
    def expr(n, env, header: false)
      r = expr_node(n, env, header)
      note_expr(n, r[1]) if @flags["types"]
      r
    end

    # The collector keeps the DSL files' positions and drops a binding file's (TypeNames::Collector#add).
    def note_type(loc, kind, sym, name = nil)
      c = @flags["types"]
      c&.add(loc, kind, TypeNames.display(sym), name: name)
    end

    # A stand-in for a Prism::Location when only a name's own span is wanted: a keyword parameter's
    # location includes its trailing colon, which the editor should not underline. It keeps the parse's
    # source, which is how the type collector tells which file a position is in (AxumDsl::SOURCE_FILES).
    NameSpan = Struct.new(:start_line, :start_column, :end_line, :end_column, :source)

    def name_span(node, name)
      loc = node.respond_to?(:name_loc) ? node.name_loc : node.location
      NameSpan.new(loc.start_line, loc.start_column, loc.start_line, loc.start_column + name.to_s.bytesize, loc.send(:source))
    end

    def note_decl(loc, name, kind, sym)
      (@var_kind ||= {})[name] = kind
      note_type(loc, kind, sym, name)
    end

    def note_expr(n, sym)
      if n.is_a?(Prism::LocalVariableReadNode)
        note_type(n.location, (@var_kind || {}).fetch(n.name, "local"), sym, n.name)
      elsif n.is_a?(Prism::CallNode) && n.name == :result && n.receiver.nil? && sym.to_s.start_with?("struct:")
        note_type(n.location, "output", sym, sym.to_s.delete_prefix("struct:"))
      else
        note_type(n.location, "expression", sym)
      end
    end

    def expr_node(n, env, header = false)
      case n
      when Prism::IntegerNode then [n.value.negative? ? "(#{n.value})" : n.value.to_s, :int, true]
      when Prism::FloatNode then [n.value.negative? ? "(#{n.value})" : n.value.to_s, :f64, true]
      when Prism::StringNode then [AxumDsl.rstr(n.unescaped), :str, true]
      when Prism::TrueNode then ["true", :bool, true]
      when Prism::FalseNode then ["false", :bool, true]
      when Prism::NilNode then ["None", :nil, true]
      when Prism::LocalVariableReadNode
        @read[n.name] = true
        [n.name.to_s, env.fetch(n.name) { bad(n, "undefined local `#{n.name}`") }, true]
      when Prism::ParenthesesNode then parens(n, env)
      when Prism::AndNode, Prism::OrNode then logic(n, env)
      when Prism::IfNode then cond(n, env)
      when Prism::UnlessNode then unless_expr(n, env)
      when Prism::CaseNode then case_expr(n, env)
      when Prism::ArrayNode then array_lit(n, env)
      when Prism::HashNode then map_lit(n, env)
      when Prism::RangeNode then range_lit(n, env)
      when Prism::ReturnNode then return_expr(n, env)
      when Prism::InterpolatedStringNode then interp(n, env, header)
      when Prism::RegularExpressionNode then [regex_id(n), :regex, true]
      when Prism::CallNode then send_expr(n, env)
      else bad(n, "unsupported #{nodename(n)} in body")
      end
    end

    def parens(n, env)
      st = n.body
      bad(n, "parentheses must hold exactly one expression") unless st.is_a?(Prism::StatementsNode) && st.body.size == 1
      e, t, atomic = expr(st.body[0], env)
      [atomic ? e : "(#{e})", t, true]
    end

    def wrap(r) = r[2] ? r[0] : "(#{r[0]})"

    # Types whose local is cloned where Rust would move it: a branch's value, `a = b`, and the left of `||`.
    # Ruby reads a local without consuming it, so it stays readable afterwards (gaps #17, #21, #31). Copy
    # types need no clone; a params object or opaque type may not implement Clone, so those still move. A query
    # record always derives Clone, so it is cloned like a string.
    CLONED_ON_MOVE = %i[string r_str strs i64s f64s json].freeze

    def clone_on_move?(t) = CLONED_ON_MOVE.include?(t) || MAPS.key?(t) || @record_types.to_a.include?(t) ||
                            (OPT.key?(t) && clone_on_move?(OPT.fetch(t)))

    # r, the compiled `node`, with a clone when node is a local that this position would move.
    def kept(node, r)
      return r unless node.is_a?(Prism::LocalVariableReadNode) && clone_on_move?(r[1])

      ["#{wrap(r)}.clone()", r[1], true]
    end

    # `(x)` around a whole branch or body is redundant in Rust, and rustc warns (unused_parens).
    # Strips one outer pair only when it encloses the entire expression, ignoring string literals.
    def unparen(code)
      return code unless code.start_with?("(") && code.end_with?(")")

      depth = 0
      in_str = false
      i = 0
      while i < code.length
        ch = code[i]
        if in_str
          i += 1 if ch == "\\"
          in_str = false if ch == "\""
        elsif ch == "\""
          in_str = true
        elsif ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
          return code if depth.zero? && i < code.length - 1
        end
        i += 1
      end
      code[1..-2]
    end

    def logic(n, env)
      if n.is_a?(Prism::OrNode) && (nar = or_narrowing(n.left, env))
        return narrowed_or(n, nar, env)
      end

      l = expr(n.left, env)
      l = kept(n.left, l) if n.is_a?(Prism::OrNode) && OPT.key?(l[1])
      # `maybe_list || []`: an empty list of the same kind as the left side.
      if n.is_a?(Prism::OrNode) && OPT.key?(l[1]) && empty_default?(OPT[l[1]], n.right)
        return ["#{wrap(l)}.unwrap_or_default()", OPT.fetch(l[1]), true]
      end

      if n.is_a?(Prism::OrNode) && !OPT.key?(l[1]) &&
         ((n.right.is_a?(Prism::ArrayNode) && n.right.elements.empty?) ||
          (n.right.is_a?(Prism::HashNode) && n.right.elements.empty?))
        empty = n.right.is_a?(Prism::HashNode) ? "{}" : "[]"
        bad(n.right, "`#{n.left.slice}` is not nilable, so `||` gives `#{empty}` no element type; drop the fallback")
      end

      r = expr(n.right, env)
      return opt_or(n, l, r) if n.is_a?(Prism::OrNode) && OPT.key?(l[1])

      bad(n, "`&&`/`||` need bool operands, got #{l[1]} and #{r[1]}") unless l[1] == :bool && r[1] == :bool
      ["#{wrap(l)} #{n.is_a?(Prism::AndNode) ? '&&' : '||'} #{wrap(r)}", :bool, false]
    end

    def cond(n, env)
      c = expr(n.predicate, env)
      bad(n.predicate, "condition must be bool, got #{c[1]}") unless c[1] == :bool
      sub = n.subsequent
      bad(n, "`if` used as a value needs an `else` branch") unless sub
      nar = narrowing(n.predicate, env)
      after = @after.to_a # captured before the branches, whose own statements move @after
      then_env, else_env = split_env(nar, env, true)
      tl, te, tt = branch(n.statements, then_env, n)
      fl = nil
      if sub.is_a?(Prism::IfNode)
        fb, ft, = cond(sub, else_env)
        fb = "{ #{fb} }" if fb.start_with?("match ")
      elsif sub.is_a?(Prism::ElseNode)
        fl, fe, ft = branch(sub.statements, else_env, sub)
      else
        bad(sub, "unsupported #{nodename(sub)} in `if`")
      end
      type = unify(n, tt, ft)
      tb = branch_block(tl, coerce(te, tt, type) || te)
      if fl
        fb = branch_block(fl, coerce(fe, ft, type) || fe)
      else
        coerced = coerce(fb, ft, type)
        fb = "{ #{coerced} }" if coerced && coerced != fb
      end
      if nar
        fb = "{ #{fb} }" unless fb.start_with?("{")
        return [narrowed_match(nar, env, true, { arm: tb, node: n.statements }, { arm: fb, node: sub }, after), type, false]
      end
      ["if #{c[0]} #{tb} else #{fb}", type, false]
    end

    # A :str branch becomes an owned String so both arms of an `if` have one Rust type.
    def branch(st, env, at)
      bad(at, "empty branch") unless st.is_a?(Prism::StatementsNode)
      lets, *r = stmts(st, env.dup)
      e, t, = kept(st.body.last, r)
      e = unparen(e)
      e, t = "#{e}.to_string()", :string if t == :str
      [lets, e, t]
    end

    # A branch's local statements and result as one Rust block, so `if`/`else`/`case` arms are blocks
    # (Rust requires a block after `if`/`else`, and coercing `Some(...)` must stay inside it).
    def branch_block(lets, code) = "{ #{(lets + [code]).join(' ')} }"

    # A nested object, required (:"struct:Name") or optional (:"opt<struct:Name>").
    def object_type?(sym)
      sym.to_s.start_with?("struct:") || (OPT.key?(sym) && OPT[sym].to_s.start_with?("struct:"))
    end

    # A list of another params struct (:"list<struct:Name>", element :struct:Name), or of a type a binding owns
    # (:"list<ext<Html::Row>>", element :"ext<Html::Row>"): the same list methods serve both.
    def struct_list?(sym) = CompositeTypes.object_list_sym?(sym) || !CompositeTypes::Opaque.list_element(sym).nil?

    def struct_list_name(sym) = CompositeTypes.object_list_element(sym) || CompositeTypes::Opaque.list_element(sym)

    def list_elem(sym)
      (name = CompositeTypes::Opaque.list_element(sym)) ? CompositeTypes::Opaque.symbol(name) : :"struct:#{struct_list_name(sym)}"
    end

    # A record: a binding type that lists its fields (docs/specs/typed_record.md), so a body may read them.
    def record?(sym) = opaque?(sym) && !CompositeTypes::Opaque.fields(opaque_name(sym)).nil?

    # The type of a record's field, refused with the declared fields when there is none.
    def record_field_type(node, rname, name)
      fields = CompositeTypes::Opaque.fields(rname)
      f = fields.find { |x| x[0] == name.to_s } or
        bad(node, "#{rname} has no field `#{name}` (its fields: #{fields.map(&:first).join(', ')})", word: name.to_s, from: fields.map(&:first))
      f[1].to_sym
    end

    # row.text: the field's value, owned (cloned unless Copy) so the record can be read again.
    def record_field(node, name, recv)
      t = record_field_type(node, opaque_name(recv[1]), name)
      copy = %i[i32 i64 f64 bool oi32 oi64 of64 obool].include?(t)
      ["#{wrap(recv)}.#{name}#{copy ? '' : '.clone()'}", t, true]
    end

    # `header:` is set for a redirect path: the path becomes the Location header, so every embedded
    # value has to lower to text a header value cannot reject (see HEADER_SCALARS).
    def interp(n, env, header = false)
      fmt = +""
      vals = []
      n.parts.each do |part|
        case part
        when Prism::StringNode then fmt << AxumDsl.esc(part.unescaped).gsub("{", "{{").gsub("}", "}}")
        when Prism::EmbeddedStatementsNode
          st = part.statements
          bad(part, "interpolation must hold exactly one expression") unless st && st.body.size == 1
          fmt << "{}"
          v = expr(st.body[0], env)
          bad(part, "this value may be nil; use `|| default` or `.to_s` inside the string") if OPT.key?(v[1]) && !object_type?(v[1])
          bad(part, "a list cannot go inside a string; use join") if LISTS.key?(v[1])
          bad(part, "a list of objects cannot go inside a string; map it to strings first") if struct_list?(v[1])
          bad(part, "a map cannot go inside a string; read one value with m[\"key\"] (or join its keys)") if MAPS.key?(v[1])
          bad(part, "#{opaque_name(v[1])} is an opaque value; pass it to a function of its binding to get a string out") if opaque?(v[1])
          bad(part, "an object cannot go inside a string; read one of its fields") if object_type?(v[1])
          bad(part, "a content block cannot go inside a string; return it from the body") if %i[block blocks].include?(v[1])
          bad(part, "a secret cannot go inside text, where it could be returned or logged; pass it to a binding or rust_fn function") if v[1] == :secret
          if header && !HEADER_SCALARS.include?(v[1])
            bad(st.body[0], "a redirect path can interpolate only a number (i32, i64 or f64) or a bool, because the path becomes the Location header and a string value could carry a byte the header rejects; write redirect(\"/rooms/\#{room_id}\") with an integer, or a literal path")
          end
          vals << (v[1] == :f64 ? f64_str(v[0]) : v[0])
        else bad(part, "unsupported #{nodename(part)} in string")
        end
      end
      ["format!(\"#{fmt}\"#{vals.map { |v| ", #{v}" }.join})", :string, true]
    end

    def send_expr(n, env)
      args = n.arguments ? n.arguments.arguments : []
      name = n.name
      return transaction_expr(n, args, env) if n.receiver.nil? && name == :transaction
      if n.block && name != :map && !LIST_BLOCK.include?(name) && !%i[gsub sub].include?(name)
        bad(n, "blocks are only supported on map, gsub, sub, #{LIST_BLOCK.join(', ')}", word: name, from: %i[map gsub sub] + LIST_BLOCK)
      end
      return safe_nav_call(n, env) if n.safe_navigation?
      # `params[:id]` / `params["id"]` in a route body: the value the route's params declared for that field.
      # A route body has no block parameters; this is how it reads its inputs.
      if n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :params && n.receiver.receiver.nil? &&
         n.receiver.arguments.nil? && n.receiver.block.nil?
        return params_read(n, args, env)
      end
      bad(n, "`params` holds the route's inputs; read one field with params[:name]") if n.receiver.nil? && name == :params
      # `errors[:name]` in a route body: the message the generated check() has for that field.
      if n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :errors && n.receiver.receiver.nil? &&
         n.receiver.arguments.nil? && n.receiver.block.nil?
        return errors_read(n, args, env)
      end
      bad(n, "`errors` holds the generated check()'s messages; read one field with errors[:name]") if n.receiver.nil? && name == :errors
      # The response helpers: what a route body may end in.
      if n.receiver.nil? && @route && RESPONSE_HELPERS.include?(name)
        return response_call(n, name, args, env)
      end
      bad(n, "`#{name}` is a statement, not a value; write it on its own line") if n.receiver.nil? && (@route ? %i[status content_type headers set_cookie delete_cookie] : %i[set_cookie delete_cookie]).include?(name)
      # `render` answers an HTTP request -- a view is compiled into the response -- so it is not there in a
      # helper or a binding body, where a value is being computed rather than a request answered.
      bad(n, "`render` answers an HTTP request: a view is rendered in a route or a filter body, not in a helper or a binding") if n.receiver.nil? && name == :render
      if n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Rust
        return n.name == :Str ? rust_str(n, args, env) : rust_int(n, args, env)
      end
      if n.receiver.is_a?(Prism::ConstantReadNode)
        return bcrypt_call(n, args, env) if n.receiver.name == :Bcrypt
        return binding_call(n, args, env) if @bindings.key?(n.receiver.name.to_s)

        bad(n.receiver, "unknown constant `#{n.receiver.name}`; bindings are loaded with use_bindings :name#{@bindings.empty? ? '' : " (loaded: #{@bindings.keys.join(', ')})"}",
            word: n.receiver.name, from: @bindings.keys + %w[Rust Bcrypt])
      end
      return rust_call(n, args, env) if name == :rust && n.receiver.nil?
      return raise_call(n, args, env) if name == :raise && n.receiver.nil?
      return output_new(n, args, env) if name == :result && n.receiver.nil?
      return setting_call(n, args) if name == :setting && n.receiver.nil?
      return rails_signed_id_call(n, args, env) if name == :rails_signed_id && n.receiver.nil?
      return cookie_call(n, args) if name == :cookie && n.receiver.nil?
      return current_call(n, args) if name == :current && n.receiver.nil?
      return request_value_call(n, args) if REQUEST_VALUES.include?(name) && n.receiver.nil?
      return html_escape_call(n, name, args, env) if %i[h raw].include?(name) && n.receiver.nil?
      return file_text_call(n, args) if name == :file_text && n.receiver.nil?
      return file_path_call(n, args) if name == :file_path && n.receiver.nil?
      return entry_call(n, args) if name == :entry && n.receiver.nil?
      return entry_args_call(n, args, env) if name == :entry_args && n.receiver.nil?

      return integer_call(n, args, env) if name == :Integer && n.receiver.nil?

      return query_call(n, args, env) if n.receiver.nil? && @flags.dig("queries", name.to_s)
      return helper_call(n, args, env) if n.receiver.nil? && @helpers.key?(name.to_s)
      if n.receiver.nil? && RESOURCE_CONTENT.key?(name)
        return resource_content_call(n, args, env) if resource_body?
        # `blob` is an MCP resource content; `text` here is also one, and the response helper `text(...)` is
        # matched earlier, in a route body or a filter.
        bad(n, "`blob` builds an MCP resource content, which an axum service has no equivalent for") if name == :blob
      end
      return content_call(n, args, env) if n.receiver.nil? && CONTENT_SHAPE.key?(name)

      unless n.receiver
        bad(n, "unsupported call `#{name}` (needs a receiver); a helper can only be called after it is declared, and only from a tool or a later helper" \
               "#{@helpers.empty? ? '' : " (declared helpers: #{@helpers.keys.join(', ')})"}", word: name, from: @helpers.keys)
      end

      recv = expr(n.receiver, env)
      bad(n, "a secret has no methods (not `#{name}`): it can only be passed to a binding or rust_fn function") if recv[1] == :secret
      return rust_str_call(n, name, args, recv, env) if recv[1] == :r_str
      return struct_field(n, name, recv) if recv[1].to_s.start_with?("struct:") && args.empty?
      if record?(recv[1])
        bad(n, "#{opaque_name(recv[1])} is read-only here; a binding function creates records") if name.to_s.end_with?("=")
        return record_field(n, name, recv) if args.empty?
      end


      if recv[1] == :regex && !%i[gsub sub].include?(name)
        bad(n, "a regex literal can only be the first argument of gsub/sub")
      end
      if OPT.key?(recv[1])
        inner = OPT[recv[1]]
        if (inner.to_s.start_with?("struct:") || record?(inner)) && name != :nil?
          bad(n, "`#{n.receiver.slice}` may be nil, so read its fields with `&.` (write `#{n.receiver.slice}&.#{name}`) or test `.nil?` first")
        end
        if MAPS.key?(inner) # m["a"] on a map of maps: index the inner map too; a missing outer key gives nil
          return opt_map_call(n, name, args, recv, env, inner)
        end
        soft = LISTS.key?(inner) || struct_list?(inner) || MAPS.key?(inner) || opaque?(inner) || inner.to_s.start_with?("struct:")
        allowed = soft ? %i[nil?] : %i[nil? to_s]
        bad(n, "this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `#{name}`)") unless allowed.include?(name)
      end
      bad(n, "#{opaque_name(recv[1])} is an opaque value with no methods of its own (not `#{name}`); pass it to a function of its binding") if opaque?(recv[1])
      return list_call(n, name, args, recv, env) if LISTS.key?(recv[1])
      return struct_list_call(n, name, args, recv, env) if struct_list?(recv[1])
      return map_list_call(n, name, args, recv, env) if CompositeTypes.map_list_sym?(recv[1])
      return map_call(n, name, args, recv, env) if MAPS.key?(recv[1])
      return match_op(n, args, recv) if name == :=~

      if (ARITH + ORDER + EQ).include?(name) && args.size == 1
        binop(n, name, recv, expr(args[0], env))
      elsif OPT.key?(recv[1]) && name == :to_s && args.empty?
        opt_to_s(recv)
      elsif OPT.key?(recv[1]) && name == :nil? && args.empty?
        ["#{wrap(recv)}.is_none()", :bool, true]
      elsif name == :to_s && args.empty? && recv[1] == :f64
        [f64_str(wrap(recv)), :string, false]
      elsif name == :to_s && args.empty?
        ["#{wrap(recv)}.to_string()", :string, true]
      elsif STRM.key?(name) && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.#{STRM[name]}()", :string, true]
      elsif name == :split && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.split(#{SPLIT_WS}).filter(|w| !w.is_empty()).collect::<Vec<&str>>()", :strs, true]
      elsif %i[length size].include?(name) && args.empty? && %i[str string].include?(recv[1])
        ["(#{wrap(recv)}.chars().count() as i64)", :i64, true]
      elsif name == :capitalize && args.empty? && %i[str string].include?(recv[1])
        note_capitalize(n)
        # A bare block expression: not atomic, so `wrap` parenthesizes it only when it is a receiver.
        ["{ let mut cs = #{wrap(recv)}.chars(); match cs.next() { Some(f) => f.to_uppercase().collect::<String>() + &cs.as_str().to_lowercase(), None => String::new() } }", :string, false]
      elsif name == :strip && args.empty? && %i[str string].include?(recv[1])
        note_strip(n)
        ["#{wrap(recv)}.trim_matches(#{STRIP_FN}).to_string()", :string, true]
      elsif STR_TESTS.key?(name) && args.size == 1 && %i[str string].include?(recv[1])
        str_test(name, recv, args[0], env)
      elsif name == :empty? && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.is_empty()", :bool, true]
      elsif name == :match? && args.size == 1 && %i[str string].include?(recv[1])
        match_test(recv, args[0])
      elsif name == :reverse && args.empty? && %i[str string].include?(recv[1])
        # Both Ruby and Rust reverse by code point, not by grapheme cluster.
        ["#{wrap(recv)}.chars().rev().collect::<String>()", :string, true]
      elsif name == :split && args.size == 1 && %i[str string].include?(recv[1])
        split_sep(recv, args[0])
      elsif name == :index && args.size == 1 && %i[str string].include?(recv[1])
        str_index(recv, args[0], env)
      elsif name == :tr && args.size == 2 && %i[str string].include?(recv[1])
        str_tr(n, recv, args)
      elsif name == :delete && args.size == 1 && %i[str string].include?(recv[1])
        str_delete(recv, args[0])
      elsif name == :squeeze && args.empty? && %i[str string].include?(recv[1])
        squeeze_code(recv)
      elsif name == :to_i && args.empty? && %i[str string].include?(recv[1])
        str_to_i(n, recv)
      elsif name == :split && args.size == 2 && %i[str string].include?(recv[1])
        split_limit(recv, args)
      elsif name == :partition && args.size == 1 && %i[str string].include?(recv[1])
        str_partition(recv, args[0])
      elsif name == :chars && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.chars().map(|__c| __c.to_string()).collect::<Vec<String>>()", :strs, true]
      elsif name == :lines && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.split_inclusive('\\n').map(|__l| __l.to_string()).collect::<Vec<String>>()", :strs, true]
      elsif name == :[] && args.size.between?(1, 2) && %i[str string].include?(recv[1])
        str_slice(recv, args, env)
      elsif name == :times && args.empty? && %i[int i32 i64].include?(recv[1])
        ["(0..#{wrap(recv)} as i64).collect::<Vec<i64>>()", :i64s, true]
      elsif %i[upto downto].include?(name) && args.size == 1 && %i[int i32 i64].include?(recv[1])
        int_run(name, recv, args[0], env)
      elsif %i[gsub sub].include?(name)
        subst(n, name, recv, args, env)
      elsif name == :! && args.empty? && recv[1] == :bool
        ["!#{wrap(recv)}", :bool, false]
      elsif name == :-@ && args.empty? && (INTS.include?(recv[1]) || RINT.key?(recv[1]))
        checked_neg(n, recv)
      elsif name == :-@ && args.empty? && NUM.include?(recv[1])
        ["-#{wrap(recv)}", recv[1], false]
      else
        bad(n, "unsupported method `#{name}` in body (allowed: #{ALLOWED_METHODS.join(' ')}, or rust(:fn, ...))", word: name, from: ALLOWED_METHODS)
      end
    end

    # `unless c ... else ... end` is `if c ... else ... end` with the branches swapped. As a value
    # it needs the else branch, like `if`.
    def unless_expr(n, env)
      c = expr(n.predicate, env)
      bad(n.predicate, "condition must be bool, got #{c[1]}") unless c[1] == :bool
      els = n.else_clause
      bad(n, "`unless` used as a value needs an `else` branch") unless els
      nar = narrowing(n.predicate, env)
      after = @after.to_a # captured before the branches, whose own statements move @after
      unless_env, else_env = split_env(nar, env, false)
      ul, ue, ut = branch(n.statements, unless_env, n)
      el, ee, et = branch(els.statements, else_env, els)
      type = unify(n, ut, et)
      ub = branch_block(ul, coerce(ue, ut, type) || ue)
      eb = branch_block(el, coerce(ee, et, type) || ee)
      return [narrowed_match(nar, env, false, { arm: ub, node: n.statements }, { arm: eb, node: els }, after), type, false] if nar

      ["if #{c[0]} #{eb} else #{ub}", type, false]
    end

    # `raise "message"` ends the tool call with an MCP error result (isError: true) that carries
    # the message. It has no value, so it fits wherever any type does: `cond ? raise("x") : v`.
    def raise_call(node, args, env)
      bad(node, "`raise` takes exactly one message argument; write `raise \"message\"`") unless args.size == 1
      msg = expr(args[0], env)
      bad(args[0], "`raise` needs a string message, got #{msg[1]}") unless %i[str string].include?(msg[1])
      @fallible = true
      ["return Err(#{msg[1] == :str ? "#{msg[0]}.to_string()" : msg[0]})", :never, false]
    end

    # start_with? / end_with? / include? with one string argument. Ruby takes a regex too for
    # start_with? and include? (a different method); that form is refused here, use match?.
    def str_test(name, recv, arg, env)
      bad(arg, "`#{name}` takes a string, not a regex (use match?)") if arg.is_a?(Prism::RegularExpressionNode)
      a = expr(arg, env)
      bad(arg, "`#{name}` takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      pat = a[1] == :str ? a[0] : "&#{wrap(a)}"
      ["#{wrap(recv)}.#{STR_TESTS.fetch(name)}(#{pat})", :bool, true]
    end

    # match? with a regex literal: an unanchored search, like Ruby; ^ and $ are line anchors.
    def match_test(recv, pat)
      bad(pat, "`match?` needs a regex literal, got #{nodename(pat)}") unless pat.is_a?(Prism::RegularExpressionNode)
      ["#{regex_id(pat)}.is_match(&#{wrap(recv)})", :bool, true]
    end

    # `s =~ /re/`: the character index of the first match, or nil (Ruby counts characters, not
    # bytes). v1 takes a regex literal only and a string receiver only; it is an index, never a
    # boolean, so anything else is refused rather than quietly turned into true or false.
    def match_op(node, args, recv)
      bad(node, "`=~` takes exactly one argument (a regex literal), got #{args.size}") unless args.size == 1
      bad(node, "`=~` needs a string receiver, got #{TypeNames.display(recv[1])}") unless %i[str string].include?(recv[1])
      pat = args[0]
      bad(pat, "`=~` needs a regex literal, got #{nodename(pat)}") unless pat.is_a?(Prism::RegularExpressionNode)
      ["{ let __s: &str = &#{wrap(recv)}; #{regex_id(pat)}.find(__s).map(|__m| __s[..__m.start()].chars().count() as i64) }",
       :oi64, false]
    end

    # `maybe || default` for a value that may be nil. The default is only evaluated when the left
    # side is nil, as in Ruby; `xs.first || raise("empty")` ends the call with an error result.
    def opt_or(node, l, r)
      return ["match #{l[0]} { Some(__v) => __v, None => #{r[0]} }", OPT.fetch(l[1]), false] if r[1] == :never

      # A literal default can be evaluated eagerly. Anything else is only evaluated when the left side is nil,
      # as in Ruby, and may contain `return`, `raise` or checked arithmetic, so it goes in a match arm (a
      # closure would swallow the early exit).
      pure = [Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode].any? { |k| node.right.is_a?(k) }
      lazy = ->(code, type) { ["match #{l[0]} { Some(__v) => __v, None => #{unparen(code)} }", type, false] }

      if LISTS.key?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able list must be a list of the same kind, got #{r[1]}") unless r[1] == OPT.fetch(l[1])
        return lazy.call(r[0], OPT.fetch(l[1]))
      end
      if struct_list?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able list of objects must be a list of the same kind, got #{r[1]}") unless r[1] == OPT.fetch(l[1])
        return lazy.call(r[0], OPT.fetch(l[1]))
      end
      if MAPS.key?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able map must be a map of the same kind, got #{TypeNames.display(r[1])}") unless [OPT.fetch(l[1]), :empty_map].include?(r[1])
        return lazy.call(r[0], OPT.fetch(l[1]))
      end
      if opaque?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able #{opaque_name(OPT.fetch(l[1]))} must be another #{opaque_name(OPT.fetch(l[1]))} (or `raise(\"...\")`), got #{TypeNames.display(r[1])}") unless r[1] == OPT.fetch(l[1])
        return lazy.call(r[0], OPT.fetch(l[1]))
      end

      if l[1] == :ostr
        bad(node.right, "the default for a nil-able string must be a string, got #{r[1]}") unless %i[str string].include?(r[1])
        d = r[1] == :str ? "#{r[0]}.to_string()" : r[0]
        pure ? ["#{wrap(l)}.unwrap_or_else(|| #{d})", :string, true] : lazy.call(d, :string)
      else
        want = OPT.fetch(l[1])
        ok = case want
             when :bool then r[1] == :bool
             when :f64 then %i[f64 int].include?(r[1])
             else r[1] == :int || r[1] == want
             end
        bad(node.right, "the default for a nil-able #{want} must be a #{want}, got #{r[1]}") unless ok
        d = want == :f64 && r[1] == :int ? "#{r[0]} as f64" : r[0]
        # Negative literals carry protective parens (for `a - -1`); a single `unwrap_or` argument does not
        # need them, and rustc warns (unused_parens), so strip them as elsewhere.
        pure ? ["#{wrap(l)}.unwrap_or(#{unparen(d)})", want, true] : lazy.call(d, want)
      end
    end

    # Ruby's Float#to_s writes a whole Float with a trailing ".0" (1.0); Rust's Display writes "1".
    # (For |x| >= 1e16 Ruby also switches to scientific notation, which this does not reproduce.)
    def f64_str(rust) = "{ let __s = (#{rust}).to_string(); if !__s.contains('.') && __s.chars().all(|c| c.is_ascii_digit() || c == '-') { __s + \".0\" } else { __s } }"

    # nil.to_s is "" in Ruby.
    def opt_to_s(recv)
      code = if recv[1] == :ostr
               "#{wrap(recv)}.unwrap_or_default()"
             elsif recv[1] == :of64
               "#{wrap(recv)}.map(|__n| #{f64_str('__n')}).unwrap_or_default()"
             else
               "#{wrap(recv)}.map(|__n| __n.to_string()).unwrap_or_default()"
             end
      [code, :string, true]
    end

    # split("sep"): Ruby keeps leading empty pieces and drops trailing ones. " " (awk mode, any
    # whitespace) and "" (every character) mean something else in Ruby, so they are refused.
    def split_sep(recv, sep)
      bad(sep, "`split` takes a plain string literal separator") unless sep.is_a?(Prism::StringNode)
      bad(sep, "split(\" \") means whitespace in Ruby; use split with no argument") if sep.unescaped == " "
      bad(sep, "split with an empty separator is not supported") if sep.unescaped.empty?
      ["{ let mut __v: Vec<String> = #{wrap(recv)}.split(#{AxumDsl.rstr(sep.unescaped)}).map(|__p| __p.to_string()).collect(); " \
       "while __v.last().is_some_and(|__l| __l.is_empty()) { __v.pop(); } __v }", :strs, false]
    end

    # index("x"): the character offset of the first match, or nil. Ruby counts characters.
    def str_index(recv, arg, env)
      bad(arg, "`index` takes a string, not a regex") if arg.is_a?(Prism::RegularExpressionNode)
      a = expr(arg, env)
      bad(arg, "`index` takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      pat = a[1] == :str ? a[0] : "&#{wrap(a)}"
      ["{ let __s = &#{wrap(recv)}; __s.find(#{pat}).map(|__b| __s[..__b].chars().count() as i64) }", :oi64, false]
    end

    # tr and delete take Ruby character sets; only plain characters are supported (no a-z ranges,
    # no ^ negation, no backslashes), so what the DSL says is exactly what the Rust does.
    def plain_chars(node, name)
      bad(node, "`#{name}` takes string literals") unless node.is_a?(Prism::StringNode)
      chars = node.unescaped.chars
      bad(node, "`#{name}` needs at least one character") if chars.empty?
      # A `-` at either end of the set is a literal dash in Ruby; in the middle it makes a range.
      range = chars.each_with_index.any? { |c, i| c == "-" && i.positive? && i < chars.size - 1 }
      if range || chars.any? { |c| ["^", "\\"].include?(c) }
        bad(node, "`#{name}` with ranges (a-z), `^` or backslashes is not supported; list the characters " \
                  "(a `-` at the start or end of the set is fine)")
      end
      chars
    end

    def str_tr(node, recv, args)
      from = plain_chars(args[0], :tr)
      to = plain_chars(args[1], :tr)
      bad(node, "`tr` needs the same number of characters on both sides") unless from.size == to.size
      bad(args[0], "`tr` source characters must be distinct") unless from.uniq.size == from.size
      arms = from.zip(to).map { |a, b| "#{AxumDsl.rchar(a)} => #{AxumDsl.rchar(b)}," }.join(" ")
      ["#{wrap(recv)}.chars().map(|__c| match __c { #{arms} _ => __c }).collect::<String>()", :string, true]
    end

    def str_delete(recv, arg)
      set = plain_chars(arg, :delete).map { |c| AxumDsl.rchar(c) }.join(" | ")
      ["#{wrap(recv)}.chars().filter(|__c| !matches!(*__c, #{set})).collect::<String>()", :string, true]
    end

    # squeeze with no argument collapses every run of the same character.
    def squeeze_code(recv)
      ["{ let mut __o = String::new(); let mut __l: Option<char> = None; for __c in #{wrap(recv)}.chars() { " \
       "if __l != Some(__c) { __o.push(__c); } __l = Some(__c); } __o }", :string, false]
    end

    # case x when "a", "b" then ... when /re/ then ... else ... end. The subject is evaluated once.
    def case_expr(node, env)
      bad(node, "`case` needs a subject: case x when ...") unless node.predicate
      bad(node, "`case` used as a value needs an `else` branch") unless node.else_clause
      subj = expr(node.predicate, env)
      kind = if %i[str string].include?(subj[1]) then :text
             elsif %i[int i32 i64].include?(subj[1]) then :int
             end
      bad(node.predicate, "`case` subject must be a string or an integer, got #{subj[1]}") unless kind
      arms = node.conditions.map do |w|
        bad(w, "unsupported #{nodename(w)} in `case`") unless w.is_a?(Prism::WhenNode)
        wl, we, wt = branch(w.statements, env, w)
        [w.conditions.map { |c| when_test(c, kind) }.join(" || "), wl, we, wt]
      end
      el, ee, et = branch(node.else_clause.statements, env, node.else_clause)
      type = arms.reduce(et) { |acc, (_, _, _, t)| unify(node, acc, t) }
      chain = arms.map { |test, wl, we, t| "if #{test} #{branch_block(wl, coerce(we, t, type) || we)}" }.join(" else ")
      ["{ let __k = &#{wrap(subj)}; #{chain} else #{branch_block(el, coerce(ee, et, type) || ee)} }", type, false]
    end

    def when_test(cond, kind)
      case cond
      when Prism::StringNode
        bad(cond, "this `case` compares integers, but `when` has a string") unless kind == :text
        "*__k == #{AxumDsl.rstr(cond.unescaped)}"
      when Prism::IntegerNode
        bad(cond, "this `case` compares strings, but `when` has an integer") unless kind == :int
        "*__k == #{cond.value.negative? ? "(#{cond.value})" : cond.value}"
      when Prism::RegularExpressionNode
        bad(cond, "a regex `when` needs a string subject") unless kind == :text
        "#{regex_id(cond)}.is_match(__k)"
      else bad(cond, "`when` takes string, integer or regex literals, got #{nodename(cond)}")
      end
    end

    # `return value` ends the tool call with that string. It has no value of its own, so like `raise` it
    # fits wherever any type does (`cond ? (return "x") : y`). It returns from the whole tool, even from
    # inside a list block. A body cannot end in `return`: end it in the value itself.
    def return_expr(node, env)
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "`return` needs exactly one string value") unless args.size == 1
      v = expr(args[0], env)
      # A route answers with a response: `return halt(404) if note.nil?` leaves with it.
      code = @route && v[1] == :response ? v[0] : coerce(v[0], v[1], @ret)
      code or bad(args[0], "`return` needs a #{@ret == :string ? "string" : @ret} value, got #{v[1]}")
      @fallible = true
      ["return Ok(#{code})", :never, false]
    end

    # A guard clause before the last expression: `return "x" if cond`, `raise "msg" unless cond`, or the
    # block form without an else. Anything else as a statement is refused.
    def guard(node, env)
      other = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
      bad(node, "only a guard clause is allowed as a statement: `return x if cond` or `raise \"msg\" if cond` (no else)") if other
      c = expr(node.predicate, env)
      bad(node.predicate, "condition must be bool, got #{c[1]}") unless c[1] == :bool
      st = node.statements
      bad(node, "a guard clause needs a body") unless st.is_a?(Prism::StatementsNode) && st.body.size == 1
      e, t, = expr(st.body[0], env)
      bad(st.body[0], "a guard clause must end with `return` or `raise`") unless t == :never
      plain = narrowing(node.predicate, env)
      # `return x if x.nil? || rest` narrows like the plain test: when the guard does not fire, x is not nil.
      nar = plain || (node.predicate.is_a?(Prism::OrNode) ? or_narrowing(node.predicate.left, env) : nil)
      # `return x if x.nil?` / `raise "m" if x.nil?`: past the guard the local is non-nil, so a later read shadows it.
      if nar && (node.is_a?(Prism::IfNode) == nar[1]) && (@in_each || 0).zero? && reads_local?(@after, nar[0])
        name = nar[0]
        env[name] = OPT.fetch(env.fetch(name))
        narrowed = "let #{name} = match #{name} { Some(__v) => __v, None => #{e} };"
        # the plain test is the match itself; with `|| rest` the guard still has to run `rest`, then the match unwraps
        return plain ? narrowed : "if #{c[0]} { #{e}; } #{narrowed}"
      end
      test = node.is_a?(Prism::UnlessNode) ? "!#{wrap(c)}" : c[0]
      "if #{test} { #{e}; }"
    end

    # `x.nil?` or `!x.nil?` on a nil-able local: [name, whether the condition being true means x is nil].
    # Anything else (a compound condition, a field, an expression) does not narrow.
    def narrowing(pred, env)
      truth = true
      if pred.is_a?(Prism::CallNode) && pred.name == :! && pred.arguments.nil? && pred.receiver
        truth = false
        pred = pred.receiver
      end
      return nil unless pred.is_a?(Prism::CallNode) && pred.name == :nil? && pred.arguments.nil? && pred.receiver.is_a?(Prism::LocalVariableReadNode)

      name = pred.receiver.name
      OPT.key?(env[name]) ? [name, truth] : nil
    end

    # `x.nil? || rest` on a nil-able local: the left operand of `||` is exactly `x.nil?` (not `!x.nil?`, not a
    # compound), so `rest` only runs when x is not nil. [name, true], or nil when the shape is anything else.
    def or_narrowing(left, env)
      nar = narrowing(left, env)
      nar && nar[1] ? nar : nil
    end

    # `x.nil? || rest` as a bool: a match whose Some arm binds x at its inner type and runs `rest` with it, so a
    # read of x in `rest` needs no unwrap and cannot panic. The scrutinee is cloned when the arm reads x and the
    # type is cloned on a move (as `kept` does), since Ruby lets x be read again after the expression.
    def narrowed_or(n, nar, env)
      name = nar[0]
      expr(n.left, env) # the test itself: marks x read
      right = expr(n.right, env.merge(name => OPT.fetch(env[name])))
      bad(n.right, "`&&`/`||` need bool operands, got bool and #{TypeNames.display(right[1])}") unless right[1] == :bool
      used = reads_local?(n.right, name)
      scrut = used && clone_on_move?(env[name]) ? "#{name}.clone()" : name.to_s
      ["match #{scrut} { None => true, Some(#{used ? name : '_'}) => #{right[0]} }", :bool, false]
    end

    # The envs of an `if`/`unless` pair of branches (first, second): the one that runs when x is not nil sees x
    # at its non-nil type. `first_when_true` is true for `if` (its first branch runs when the condition holds).
    def split_env(nar, env, first_when_true)
      return [env, env] unless nar

      name, truth = nar
      narrowed = env.merge(name => OPT.fetch(env[name]))
      truth == first_when_true ? [env, narrowed] : [narrowed, env]
    end

    # Does any node under `node` (or a list of nodes) read the local `name`?
    def reads_local?(node, name)
      return node.any? { |c| reads_local?(c, name) } if node.is_a?(Array)
      return false if node.nil?

      (node.is_a?(Prism::LocalVariableReadNode) && node.name == name) || node.compact_child_nodes.any? { |c| reads_local?(c, name) }
    end

    # `if x.nil? ... else ... end` on a nil-able local as a match: the non-nil arm binds x at its inner type
    # (`Some(_)` when that arm never reads it, which moves nothing). The scrutinee is cloned only when the arm binds
    # the local and `after` (what follows the `if`) reads it again, as `kept` does elsewhere.
    def narrowed_match(nar, env, first_when_true, first, second, after = [])
      name = nar[0]
      first_nil = nar[1] == first_when_true
      nil_arm, some_arm = first_nil ? [first[:arm], second[:arm]] : [second[:arm], first[:arm]]
      used = reads_local?(first_nil ? second[:node] : first[:node], name)
      scrut = used && reads_local?(after, name) && clone_on_move?(env[name]) ? "#{name}.clone()" : name.to_s
      "match #{scrut} { None => #{nil_arm}, Some(#{used ? name : "_"}) => #{some_arm} }"
    end

    # Code for a value of `type` where `want` is expected, or nil when it does not fit. A string literal
    # fits a string, an integer literal an integer type, and a plain value fits its nil-able type (as Some).
    def coerce(code, type, want)
      return code if type == want
      return "None" if type == :nil && OPT.key?(want)
      return "#{code}.to_string()" if type == :str && want == :string
      return code if type == :int && %i[i32 i64].include?(want)
      return code if type == :empty_map && MAPS.key?(want)

      if OPT.key?(want)
        inner = coerce(code, type, OPT.fetch(want))
        return "Some(#{inner})" if inner
      end
      nil
    end

    # result(:Name, field: value, ...) builds a tool's structured result. Every field is given exactly once and
    # each value has to fit its field's type, so a result can never be missing or mistyped.
    def output_new(n, args, env)
      bad(n, "result(:Name, field: value, ...) starts with the output's name") unless args[0].is_a?(Prism::SymbolNode)
      sname = args[0].unescaped
      st = @outputs.find { |o| o["name"] == sname } or
        bad(args[0], "unknown output `#{sname}`; declare it with `output :#{sname} do ... end`" \
                     "#{@outputs.empty? ? '' : " (declared outputs: #{@outputs.map { |o| o['name'] }.join(', ')})"}", word: sname, from: @outputs.map { |o| o["name"] })
      names = st["fields"].map { |f| f["name"] }
      kw = args.size == 2 && args[1].is_a?(Prism::KeywordHashNode) ? args[1].elements : nil
      bad(n, "result(:#{sname}, ...) takes one keyword argument for each field: #{names.join(', ')}") unless kw
      given = {}
      kw.each do |el|
        bad(el, "unsupported #{nodename(el)} in result(:#{sname}, ...) (use `field: value`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped
        bad(el, "#{sname} has no field `#{key}` (it has: #{names.join(', ')})", word: key, from: names) unless names.include?(key)
        bad(el, "duplicate `#{key}:`") if given.key?(key)
        given[key] = el.value
      end
      missing = names - given.keys
      bad(n, "result(:#{sname}) is missing #{missing.map { |x| "`#{x}:`" }.join(', ')}") unless missing.empty?
      parts = st["fields"].map do |f|
        node = given.fetch(f["name"])
        code, type, = expr(node, env)
        want = field_type(f)
        fits = coerce(code, type, want) or
          bad(node, "`#{f['name']}:` of #{sname} needs #{want == :string ? 'a string' : want}, got #{type}")
        # a local or parameter is read again later, so the struct takes a copy
        fits = "#{fits}.clone()" if node.is_a?(Prism::LocalVariableReadNode) && (%i[string strs i64s].include?(want) || MAPS.key?(want))
        "#{f['name']}: #{fits}"
      end
      ["#{sname} { #{parts.join(', ')} }", :"struct:#{sname}", true]
    end

    # obj&.field for a field of an optional nested object. Ruby safe navigation answers nil when the
    # object is nil, so the result is nil-able. The receiver is an owned params field, so as_ref()
    # borrows it and the object can be read again.
    def safe_nav_call(node, env)
      recv = expr(node.receiver, env)
      inner = OPT[recv[1]] or
        bad(node, "`&.` is only for a value that may be nil, but `#{node.receiver.slice}` is always present")
      unless inner.to_s.start_with?("struct:") || record?(inner)
        bad(node, "`&.` is only supported on an optional nested object or record so far, not on #{TypeNames.display(recv[1])}")
      end
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "`&.` on a nested object takes no arguments") unless args.empty?
      name = node.name
      return ["#{wrap(recv)}.is_none()", :bool, true] if name == :nil?

      t =
        if record?(inner)
          record_field_type(node, opaque_name(inner), name)
        else
          sname = inner.to_s.delete_prefix("struct:")
          st = (@structs + @outputs).find { |p| p["name"] == sname } or bad(node, "unknown params `#{sname}`")
          f = st["fields"].find { |x| x["name"] == name.to_s } or
            bad(node, "#{sname} has no field `#{name}` (it has: #{st["fields"].map { |x| x["name"] }.join(", ")})", word: name, from: st["fields"].map { |x| x["name"] })
          field_type(f)
        end
      copy = %i[i32 i64 f64 bool oi32 oi64 of64 obool].include?(t)
      suffix = copy ? "" : ".clone()"
      if OPT.key?(t)
        ["#{wrap(recv)}.as_ref().and_then(|__o| __o.#{name}.clone())", t, false]
      else
        ["#{wrap(recv)}.as_ref().map(|__o| __o.#{name}#{suffix})", OPT_OF.fetch(t), false]
      end
    end

    # The type a field has inside a body. Lists are lists of strings, integers or floats, a nested object is a
    # struct value (read with `obj.field`), and an optional field is nil-able. A field with a default is
    # always present, so it is not.
    def field_type(f)
      TypeNames.field_symbol(f)
    end

    # obj.name for a nested object field. Strings and lists are cloned so the object can be read again.
    def struct_field(node, name, recv)
      sname = recv[1].to_s.delete_prefix("struct:")
      st = (@structs + @outputs).find { |p| p["name"] == sname } or bad(node, "unknown params `#{sname}`")
      f = st["fields"].find { |x| x["name"] == name.to_s } or
        bad(node, "#{sname} has no field `#{name}` (it has: #{st['fields'].map { |x| x['name'] }.join(', ')})", word: name, from: st["fields"].map { |x| x["name"] })
      type = field_type(f)
      copy = %i[i32 i64 f64 bool oi32 oi64 of64 obool].include?(type)
      ["#{wrap(recv)}.#{name}#{copy ? '' : '.clone()'}", type, true]
    end

    # A helper body: its parameters have the declared types and its last expression must fit the declared
    # result. `return` and `raise` inside it leave the helper, and the caller sees an error result.
    def lower_helper(blk, names, types, ret, kw_params = nil)
      @body_line = blk.location.start_line
      @ret = ret
      @helper = true
      env = {}
      reqs = blk.parameters&.parameters&.requireds || []
      names.each_with_index do |n, i|
        env[n.to_sym] = types[i]
        @declared << [n.to_sym, reqs[i], "parameter"]
        note_decl(reqs[i].location, n.to_sym, "parameter", types[i])
      end
      (kw_params || []).each do |kname, ktype, knode|
        env[kname.to_sym] = ktype.to_sym
        @declared << [kname.to_sym, knode, "parameter"]
        note_decl(name_span(knode, kname), kname.to_sym, "parameter", ktype.to_sym)
      end
      st = blk.body
      bad(blk, "empty helper body") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env)
      bad(st, "a helper cannot end in `raise` or `return`; end it in a value") if t == :never
      code = coerce(unparen(e), t, ret) or bad(st, "the helper returns #{ret} but its body ends in #{t}")
      reject_unused
      { "locals" => lets, "expr" => code, "fallible" => @fallible, "uses_async" => @uses_async, "async_reason" => @async_reason }
    end
    public :lower_helper

    # name(args) for a declared helper. Arguments are passed owned (strings and lists are cloned, so the
    # caller can keep using them). A helper that can fail returns a Result: the call propagates it with `?`.
    def helper_call(node, args, env)
      h = @helpers.fetch(node.name.to_s)
      args = args.dup
      kwn = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      unless args.size == h["args"].size
        bad(node, "helper `#{h['name']}` takes #{h['args'].size} argument(s), got #{args.size}; expected `#{h['name']}(#{h['args'].join(', ')})`")
      end
      parts = args.zip(h["args"]).map do |arg, (pname, ptype)|
        r = expr(arg, env)
        helper_arg(arg, r, ptype.to_sym, h["name"], pname)
      end
      given = {}
      (kwn ? kwn.elements : []).each do |el|
        bad(el, "helper `#{h['name']}`: keyword arguments are written `name: value`") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped
        spec = h["kw"].find { |k| k["name"] == key } or
          bad(el, "helper `#{h['name']}` has no keyword `#{key}:`#{h['kw'].empty? ? '' : " (it has: #{h['kw'].map { |k| k['name'] }.join(', ')})"}", word: key, from: h["kw"].map { |k| k["name"] })
        bad(el, "duplicate `#{key}:`") if given.key?(key)
        given[key] = el.value
      end
      h["kw"].each do |k|
        kname = k["name"]
        if given.key?(kname)
          arg = given.fetch(kname)
          r = expr(arg, env)
          parts << helper_arg(arg, r, k["type"].to_sym, h["name"], kname)
        elsif k["required"]
          bad(node, "helper `#{h['name']}` is missing required keyword `#{kname}:`")
        else
          parts << helper_default_code(k["default"], k["type"].to_sym)
        end
      end
      (@flags["used_helpers"] ||= {})[h["name"]] = true
      call = "helper_#{h['name']}(#{parts.join(', ')})"
      if h["async"]
        refuse_async(node, "helper `#{h['name']}`", h["async_reason"])
        @uses_async = true
        @async_reason ||= "calls helper `#{h['name']}` (line #{node.location.start_line})#{h['async_reason'] ? ", which is async because it #{h['async_reason']}" : ''}"
        call = "#{call}.await"
      end
      return [call, h["returns"].to_sym, true] unless h["body"]["fallible"]

      @fallible = true
      ["#{call}?", h["returns"].to_sym, true]
    end

    # recent_notes(limit: 20): a call of a declared `query` or `execute` (docs/database.md). Keyword arguments
    # only, every declared argument given once and none extra, each fitting its scalar type. It awaits the
    # statement and propagates a failure the way `raise` does (the `error` filter, or a plain 500), so the body
    # is async and can fail. A route or a filter body may call one; a helper or a binding body may not, for the
    # reason `setting(:x)` is not there either: those bodies compute a value, they do not answer a request.
    # The `error` filter may not: it answers a request that already failed, in a function that cannot await.
    def query_call(node, args, env)
      q = @flags["queries"].fetch(node.name.to_s)
      what = "#{q['kind']} `#{q['name']}`"
      bad(node, "#{what} runs in a route, a filter or a `current` body, not in a helper or a binding") unless @route || @kind == :current
      bad(node, "#{what} cannot run in the `error` filter: it answers a request that already failed") if @kind == :error
      shape = "#{q['name']}(#{q['args'].map { |n, _| "#{n}: ..." }.join(', ')})"
      kwn = args.size == 1 && args[0].is_a?(Prism::KeywordHashNode) ? args[0] : nil
      bad(node, "#{what} takes keyword arguments only; write `#{shape}`") unless args.empty? || kwn
      names = q["args"].map(&:first)
      given = {}
      (kwn ? kwn.elements : []).each do |el|
        bad(el, "#{what}: arguments are written `name: value`") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped
        bad(el, "#{what} has no argument `#{key}:`#{names.empty? ? ' (it takes none)' : " (it takes: #{names.join(', ')})"}", word: key, from: names) unless names.include?(key)
        bad(el, "duplicate `#{key}:`") if given.key?(key)
        given[key] = el.value
      end
      parts = q["args"].map do |aname, atype|
        arg = given[aname] or bad(node, "#{what} is missing its argument `#{aname}:`; write `#{shape}`")
        r = transaction_arg_value(arg, env, what, aname)
        helper_arg(arg, r, atype.to_sym, q["name"], aname, what)
      end
      (@flags["used_queries"] ||= {})[q["name"]] = true
      @fallible = true
      if @in_transaction
        (@flags["queries_in_tx"] ||= {})[q["name"]] = true
        call = parts.empty? ? "#{Db.on_name(q)}(__tx)" : "#{Db.on_name(q)}(__tx, #{parts.join(', ')})"
        return ["#{call}?", q["rtype"].to_sym, true]
      end

      (@flags["queries_outside"] ||= {})[q["name"]] = true
      @uses_async = true
      @async_reason ||= "calls #{what} (line #{node.location.start_line})"
      ["#{Db.fn_name(q)}(#{parts.join(', ')}).await?", q["rtype"].to_sym, true]
    end

    # `transaction do ... end`: one pooled connection, one SQLite transaction, and a value. A body with a
    # database writes it wherever a statement call may run. Inside the block only a `query`/`execute` call
    # may stand: `name = statement(...)` declares a local, a bare call runs for its effect, and the final
    # expression (a statement call or a local) is the block's value. The calls use their sync `_on` cores
    # on the transaction's connection, and a database error (the `?` on each call) drops the transaction,
    # which rolls back; success commits before the value comes back.
    def transaction_expr(node, args, env)
      bad(node, "`transaction` takes no arguments; its block is the work") unless args.empty?
      bad(node, "`transaction` is a body form: write `transaction do ... end`") unless node.block
      bad(node, "a `transaction` cannot nest: the outer transaction already holds the connection; do the work in one block") if @in_transaction
      bad(node, "`transaction` needs a database; add `database :sqlite, path: \"app.sqlite3\"` (see docs/database.md)") unless @flags["database"]
      bad(node, "`transaction` runs in a route, a filter or a `current` body, not in a helper or a binding") unless @route || @kind == :current
      bad(node, "`transaction` cannot run in the `error` filter: it answers a request that already failed") if @kind == :error
      blk = node.block
      bad(blk.parameters, "a `transaction` block takes no parameters") if blk.parameters
      st = blk.body
      bad(blk, "empty `transaction` block; end it in a value") unless st.is_a?(Prism::StatementsNode) && !st.body.empty?
      @flags["transactions"] = true # the crate gets db_tx only when a body opens one
      body_env = env.dup
      outer = @in_transaction
      @in_transaction = true
      begin
        lets = st.body[0...-1].map { |n| transaction_statement(n, body_env) }
        final, type = transaction_final(st.body.last, body_env)
      ensure
        @in_transaction = outer
      end
      @fallible = true
      @uses_async = true
      @async_reason ||= "opens a `transaction` (line #{node.location.start_line})"
      ["{ let __out = db_tx(\"transaction\", move |__tx| { #{lets.join(' ')} Ok(#{final}) }).await?; __out }", type, true]
    end

    # One statement before the final expression of a `transaction` block: `name = query/execute call`, or a
    # bare call. Everything else is refused here rather than lowering to Rust that has no rollback.
    def transaction_statement(n, env)
      refusal = transaction_refusal(n)
      bad(n, refusal) if refusal
      if n.is_a?(Prism::LocalVariableWriteNode)
        if (refusal = transaction_refusal(n.value))
          bad(n.value, refusal)
        end
        bad(n.value, transaction_non_sql(n.value, "be assigned")) unless transaction_call?(n.value)
        return let_stmt(n, env)
      end
      return query_stmt(n, env) if transaction_call?(n)

      bad(n, transaction_non_sql(n, "stand"))
    end

    # The final expression of a `transaction` block: a statement call, or a local (the block's value).
    def transaction_final(n, env)
      refusal = transaction_refusal(n)
      bad(n, refusal) if refusal
      if n.is_a?(Prism::LocalVariableReadNode)
        return [n.name.to_s, env.fetch(n.name) { bad(n, "undefined local `#{n.name}`") }]
      end
      return expr(n, env)[0..1] if transaction_call?(n)

      bad(n, transaction_non_sql(n, "end"))
    end

    # A bare call of a declared query or execute: the only call a transaction block may hold.
    def transaction_call?(n)
      n.is_a?(Prism::CallNode) && n.receiver.nil? && n.block.nil? && bare_query_call?(n)
    end

    # What makes a node illegal inside a transaction block, if anything: the control flow that would skip the
    # rollback and the work that is not SQL. Nil when the node is one of the forms allowed there.
    def transaction_refusal(n)
      case n
      when Prism::ReturnNode
        "`return` inside a `transaction` block would bypass the rollback; end the block in a value instead, and keep non-SQL work out of a retried/rolled-back unit"
      when Prism::IfNode, Prism::UnlessNode
        "a guard clause cannot stand inside a `transaction` block: a `return` inside would bypass the rollback, and non-SQL work does not belong in a retried/rolled-back unit"
      when Prism::CallNode
        if n.receiver.nil? && n.name == :raise
          "`raise` inside a `transaction` block is non-SQL work: a `return` inside would bypass the rollback, and non-SQL work does not belong in a retried/rolled-back unit"
        elsif n.receiver.nil? && n.name == :transaction && n.block
          "a `transaction` cannot nest: the outer transaction already holds the connection; do the work in one block"
        end
      end
    end

    def transaction_non_sql(n, verb)
      what = n.is_a?(Prism::CallNode) ? "`#{n.name}`" : nodename(n)
      "#{what} cannot #{verb} inside a `transaction` block: only a `query`/`execute` call may run there; " \
        "a `return` inside would bypass the rollback, and non-SQL work does not belong in a retried/rolled-back unit"
    end

    # What is wrong with a statement argument inside a `transaction` block: the value is lowered inside the
    # block's `move` closure, after BEGIN, so it may only read what already exists. Nil when the node is one
    # of the allowed forms -- a literal, a local, `params[:field]`, a field read, a list/hash literal or an
    # interpolation of those -- otherwise a phrase for transaction_arg_message.
    def transaction_arg_refusal(n)
      case n
      when Prism::IntegerNode, Prism::FloatNode, Prism::StringNode,
           Prism::TrueNode, Prism::FalseNode, Prism::NilNode, Prism::LocalVariableReadNode
        nil
      when Prism::ParenthesesNode
        st = n.body
        return "is a grouping, not a value" unless st.is_a?(Prism::StatementsNode) && st.body.size == 1

        transaction_arg_refusal(st.body[0])
      when Prism::ArrayNode
        n.elements.each do |e|
          r = transaction_arg_refusal(e)
          return r if r
        end
        nil
      when Prism::HashNode
        n.elements.each do |el|
          return "uses a splat, not a hash literal" unless el.is_a?(Prism::AssocNode)
          return "uses a computed hash key" unless el.key.is_a?(Prism::SymbolNode) || el.key.is_a?(Prism::StringNode)

          r = transaction_arg_refusal(el.value)
          return r if r
        end
        nil
      when Prism::InterpolatedStringNode
        n.parts.each do |part|
          next if part.is_a?(Prism::StringNode)
          return "interpolates #{nodename(part)}, not a value" unless part.is_a?(Prism::EmbeddedStatementsNode)

          st = part.statements
          return "interpolates more than one value" unless st && st.body.size == 1

          r = transaction_arg_refusal(st.body[0])
          return r if r
        end
        nil
      when Prism::CallNode
        transaction_arg_call_refusal(n)
      else
        "is a #{nodename(n)}, not a value computed from what is already in scope"
      end
    end

    # A call in a transaction statement's argument: `params[:field]` and a field read (`x.id`, `x.id.to_s`)
    # read values the block was given; every other call either runs code after BEGIN or can fail where the
    # closure cannot propagate it.
    def transaction_arg_call_refusal(n)
      name = n.name
      args = n.arguments ? n.arguments.arguments : []
      if n.receiver.nil?
        return "calls helper `#{name}`" if @helpers.key?(name.to_s)
        return "calls `rust(...)`" if name == :rust
        return "calls statement `#{name}`" if @flags.dig("queries", name.to_s)
        return "reads `current(...)`" if name == :current
        return "reads `file_text(...)`" if name == :file_text
        return "calls `raise`" if name == :raise

        return "calls `#{n.slice}`"
      end
      pr = n.receiver
      if name == :[] && args.size == 1 && [Prism::SymbolNode, Prism::StringNode].any? { |k| args[0].is_a?(k) } &&
         pr.is_a?(Prism::CallNode) && pr.name == :params && pr.receiver.nil? && pr.arguments.nil? && pr.block.nil?
        return nil
      end
      return "calls `#{n.slice}`, a constant's method" if pr.is_a?(Prism::ConstantReadNode) || pr.is_a?(Prism::ConstantPathNode)
      return "calls `#{n.slice}`, a call with a block" if n.block
      if (ARITH + ORDER + EQ).include?(name) && args.size == 1
        r = transaction_arg_refusal(pr)
        return r if r

        return transaction_arg_refusal(args[0])
      end
      return "calls `#{n.slice}`, a call with arguments" unless args.empty?

      transaction_arg_refusal(pr)
    end

    # `what` names the statement, `aname` the argument. The message names the fix: the value is computed in
    # the closure, where a fallible call's `?` cannot become the closure's `rusqlite::Result` and non-SQL
    # work would run after BEGIN, so compute it before the block and pass the local.
    def transaction_arg_message(what, aname, reason)
      "#{what}: argument `#{aname}` #{reason} inside the `transaction` block; compute it before the block " \
        "(`#{aname} = ...` above `transaction do`, then pass `#{aname}: #{aname}`): a fallible call's error " \
        "cannot cross the SQL closure's `rusqlite::Result`, and non-SQL work must not run after BEGIN"
    end

    # One statement argument inside a `transaction` block: refuse a non-value before lowering it, then lower
    # it and refuse anything that turned out fallible or async. The check is conservative on purpose: a
    # refusal costs a local, while a `?` of another error type or an `.await` in the sync closure costs the
    # build.
    def transaction_arg_value(arg, env, what, aname)
      return expr(arg, env) unless @in_transaction

      if (reason = transaction_arg_refusal(arg))
        bad(arg, transaction_arg_message(what, aname, reason))
      end
      # The block already made the body fallible and async, so lower the argument against a clean slate:
      # anything it sets itself is a `?` or `.await` that would land in the closure.
      saved_fallible = @fallible
      saved_async = @uses_async
      @fallible = false
      @uses_async = false
      r = expr(arg, env)
      made_fallible = @fallible
      made_async = @uses_async
      @fallible = saved_fallible || made_fallible
      @uses_async = saved_async || made_async
      bad(arg, transaction_arg_message(what, aname, "computes a value that can fail")) if made_fallible || made_async
      r
    end

    # One helper argument: a value of the base type fits a nil-able parameter as Some(value), while a nil-able
    # value fits only a nil-able parameter. An owned value is cloned, because the parameter takes it by value.
    # `what` is how a refusal names the callee: a helper, or a query (query_call).
    def helper_arg(arg, r, want, hname, pname, what = "helper `#{hname}`")
      code = coerce(wrap(r), r[1], want) or bad(arg, "#{what}: argument `#{pname}` should be #{want}, got #{r[1]}")
      base = OPT.key?(want) ? OPT.fetch(want) : want
      %i[string strs i64s f64s].include?(base) && r[1] != :str ? "#{code}.clone()" : code
    end

    # Rust for a keyword parameter's default; the reader has already checked it is a literal of the type.
    def helper_default_code(value, want)
      if OPT.key?(want)
        return "None" if value.nil?

        return "Some(#{helper_default_code(value, OPT.fetch(want))})"
      end

      case want
      when :string then "#{AxumDsl.rstr(value)}.to_string()"
      when :strs then "vec![#{value.map { |v| "#{AxumDsl.rstr(v)}.to_string()" }.join(', ')}]"
      when :i64s then "vec![#{value.join(', ')}]"
      when :f64s then "vec![#{value.map { |v| v.is_a?(Integer) ? "((#{v}) as f64)" : v.to_s }.join(', ')}]"
      when :f64 then value.is_a?(Integer) ? "((#{value}) as f64)" : value.to_s
      else value.to_s
      end
    end

    def binop(n, op, l, r)
      bad(n, "a secret cannot be compared or combined (`#{op}`): it can only be passed to a binding or rust_fn function") if l[1] == :secret || r[1] == :secret
      if EQ.include?(op) || ORDER.include?(op)
        t = unify(n, norm(l[1]), norm(r[1]))
        bad(n, "`#{op}` needs numeric operands, got #{t}") if ORDER.include?(op) && !NUM.include?(t)
        return ["#{wrap(l)} #{op} #{wrap(r)}", :bool, false]
      end
      return str_repeat(n, l, r) if op == :* && %i[str string].include?(l[1]) && %i[int i32 i64].include?(r[1])

      if op == :+ && l[1] == :string && %i[str string].include?(r[1])
        return ["format!(\"{}{}\", #{l[0]}, #{r[0]})", :string, true]
      end
      if op == :+ && l[1] == :str && %i[str string].include?(r[1])
        bad(n, "a string literal cannot be prepended with `+` (write `s + \"...\"` instead)")
      end
      rust = RINT.key?(l[1]) || RINT.key?(r[1])
      t = unify(n, RINT.fetch(l[1], l[1]), RINT.fetch(r[1], r[1]))
      bad(n, "`#{op}` needs numeric operands, got #{t}") unless NUM.include?(t)
      return checked_op(n, op, l, r, t, rust) if INTS.include?(t)

      ["#{wrap(l)} #{op} #{wrap(r)}", t, false]
    end

    # The single plain parameter of a list block, checked like a local.
    def block_param(blk, env, what, type)
      ps = blk.parameters
      one = ps.is_a?(Prism::BlockParametersNode) && ps.locals.empty? && ps.parameters
      one &&= ps.parameters.requireds.size == 1 && ps.parameters.requireds[0].is_a?(Prism::RequiredParameterNode)
      one &&= [ps.parameters.optionals, ps.parameters.posts, ps.parameters.keywords].all?(&:empty?)
      one &&= !ps.parameters.rest && !ps.parameters.keyword_rest && !ps.parameters.block
      bad(blk, "#{what} takes a block with exactly one plain parameter") unless one
      name = ps.parameters.requireds[0].name
      bad(blk, "`#{name}` is already defined") if env.key?(name)
      @declared << [name, ps.parameters.requireds[0], "block parameter"]
      note_decl(ps.parameters.requireds[0].location, name, "parameter", type)
      if !name.to_s.match?(SNAKE) || RUST_KW.include?(name.to_s)
        bad(blk, "block parameter `#{name}` must be snake_case and not a Rust keyword")
      end
      name
    end

    # Methods on a list of strings (:strs), integers (:i64s) or floats (:f64s). Block methods compile to for loops, not
    # closures, so a block may use checked arithmetic, to_i and raise: they leave the enclosing closure
    # with `?` or `return Err`. A list is only ever borrowed, so a local list can be used again.
    def list_call(node, name, args, recv, env)
      elem = LISTS.fetch(recv[1])
      allowed = LIST_METHODS + (elem == :i64 ? INT_LIST_METHODS : [])
      allowed = (allowed + FLOAT_LIST_METHODS - %i[tally]) if elem == :f64
      unless allowed.include?(name)
        bad(node, "a list of #{{ i64: 'integers', f64: 'floats' }.fetch(elem, 'strings')} only supports #{allowed.join('/')} so far, not `#{name}`",
            word: name.to_s, from: allowed.map(&:to_s))
      end
      want = LIST_ARITY.fetch(name)
      unless want === args.size
        shape = want.is_a?(Range) ? ".#{name} or .#{name}(arg)" : (want.zero? ? ".#{name}" : ".#{name}(arg)")
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? 'at most one argument' : "#{want} argument(s)"}; write `#{shape}`")
      end

      case name
      when :length, :size then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      when :to_a then recv
      when :first, :last then list_end(name, recv, elem)
      when :[] then list_at(recv, args[0], env, elem)
      when :include? then list_include(recv, args[0], env, elem)
      when :join then join_list(recv, args, elem)
      when :tally then list_tally(node, recv, elem)
      when :sort, :uniq, :reverse then list_reorder(name, recv, elem)
      when :sum then list_sum(node, recv, elem)
      when :min, :max
        if elem == :f64
          ["#{wrap(recv)}.iter().copied().reduce(f64::#{name})", :of64, true]
        else
          ["#{wrap(recv)}.iter().copied().#{name}()", :oi64, true]
        end
      else list_block(node, name, recv, env, elem)
      end
    end

    # A list of another params struct (:"list<struct:Name>"): length/size, empty?, first/last, [], reverse,
    # each, map, select/reject, find, any?/all? and count. first/last/[]/find give a nil-able element
    # (:"opt<struct:Name>"); each and the block methods bind a non-nil :struct:Name. Ordering, equality and
    # stringification (sort, uniq, include?, join, sum, min, max) are refused: an object has none of them.
    def struct_list_call(node, name, args, recv, env)
      unless STRUCT_LIST_METHODS.include?(name)
        bad(node, "a list of #{struct_list_name(recv[1])} only supports #{STRUCT_LIST_METHODS.join("/")} so far, not `#{name}`",
            word: name.to_s, from: STRUCT_LIST_METHODS.map(&:to_s))
      end
      want = LIST_ARITY.fetch(name)
      unless want === args.size
        shape = want.is_a?(Range) ? ".#{name} or .#{name}(arg)" : (want.zero? ? ".#{name}" : ".#{name}(arg)")
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? "at most one argument" : "#{want} argument(s)"}; write `#{shape}`")
      end
      elem = list_elem(recv[1])
      opt_elem = OPT_OF.fetch(elem)
      case name
      when :length, :size then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      when :first, :last then ["#{wrap(recv)}.#{name}().cloned()", opt_elem, true]
      when :[] then struct_list_at(recv, args[0], env, opt_elem)
      when :reverse then ["{ let mut __v = #{wrap(recv)}.clone(); __v.reverse(); __v }", recv[1], false]
      when :each then each_expr(node, recv, env)
      else struct_list_block(node, name, recv, env, elem)
      end
    end

    # xs[i] for a list of objects: negative indexes count from the end, out of range is nil, as in Ruby.
    def struct_list_at(recv, arg, env, opt_elem)
      i = expr(arg, env)
      bad(arg, "a list index must be an integer, got #{i[1]}") unless %i[int i32 i64].include?(i[1])
      ["{ let __v = &#{wrap(recv)}; let __n = __v.len() as i64; let __i = #{wrap(i)} as i64; " \
       "let __j = if __i < 0 { __i + __n } else { __i }; " \
       "if __j >= 0 && __j < __n { Some(__v[__j as usize].clone()) } else { None } }", opt_elem, false]
    end

    # map / select / reject / find / any? / all? / count with a block over a list of objects. The block
    # parameter is an owned :struct:Name; map returns a list of strings, integers or floats (list_map).
    def struct_list_block(node, name, recv, env, elem)
      return ["(#{wrap(recv)}.len() as i64)", :i64, true] if name == :count && !node.block

      blk = node.block
      bad(node, "`#{name}` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`#{name}`", elem)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => elem))
      value = "{ let #{param} = (*__e).clone(); #{(lets + [unparen(e)]).join(" ")} }"
      src = "for __e in #{wrap(recv)}.iter()"
      return list_map(blk, value, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{t}") unless t == :bool
      ty = opaque?(elem) ? CompositeTypes::Opaque.rust(opaque_name(elem)) : elem.to_s.delete_prefix("struct:")
      case name
      when :select, :reject
        test = name == :select ? value : "!#{value}"
        ["{ let mut __out = Vec::<#{ty}>::new(); #{src} { if #{test} { __out.push((*__e).clone()); } } __out }", recv[1], false]
      when :find
        ["{ let mut __r: Option<#{ty}> = None; #{src} { if #{value} { __r = Some((*__e).clone()); break; } } __r }", OPT_OF.fetch(elem), false]
      when :any?
        ["{ let mut __r = false; #{src} { if #{value} { __r = true; break; } } __r }", :bool, false]
      when :all?
        ["{ let mut __r = true; #{src} { if !#{value} { __r = false; break; } } __r }", :bool, false]
      else
        ["{ let mut __r: i64 = 0; #{src} { if #{value} { __r += 1; } } __r }", :i64, false]
      end
    end

    # A list of maps (:"list<map<...>>"), the value `values` gives on a map of maps. It reads like a list of
    # objects: length/size, empty?, first/last, [], reverse, each, map, select/reject, find, any?/all? and
    # count. Ordering, equality and stringification (sort, uniq, include?, join, sum, min, max) are refused:
    # a map has none of them.
    def map_list_call(node, name, args, recv, env)
      unless STRUCT_LIST_METHODS.include?(name)
        bad(node, "a list of maps only supports #{STRUCT_LIST_METHODS.join("/")} so far, not `#{name}`",
            word: name.to_s, from: STRUCT_LIST_METHODS.map(&:to_s))
      end
      want = LIST_ARITY.fetch(name)
      unless want === args.size
        shape = want.is_a?(Range) ? ".#{name} or .#{name}(arg)" : (want.zero? ? ".#{name}" : ".#{name}(arg)")
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? "at most one argument" : "#{want} argument(s)"}; write `#{shape}`")
      end
      elem = CompositeTypes.map_list_value(recv[1])
      opt_elem = OPT_OF.fetch(elem)
      case name
      when :length, :size then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      when :first, :last then ["#{wrap(recv)}.#{name}().cloned()", opt_elem, true]
      when :[] then map_list_at(recv, args[0], env, opt_elem)
      when :reverse then ["{ let mut __v = #{wrap(recv)}.clone(); __v.reverse(); __v }", recv[1], false]
      when :each then each_expr(node, recv, env)
      else map_list_block(node, name, recv, env, elem)
      end
    end

    # xs[i] for a list of maps: negative indexes count from the end, out of range is nil, as in Ruby.
    def map_list_at(recv, arg, env, opt_elem)
      i = expr(arg, env)
      bad(arg, "a list index must be an integer, got #{i[1]}") unless %i[int i32 i64].include?(i[1])
      ["{ let __v = &#{wrap(recv)}; let __n = __v.len() as i64; let __i = #{wrap(i)} as i64; " \
       "let __j = if __i < 0 { __i + __n } else { __i }; " \
       "if __j >= 0 && __j < __n { Some(__v[__j as usize].clone()) } else { None } }", opt_elem, false]
    end

    # map / select / reject / find / any? / all? / count with a block over a list of maps. The block parameter
    # is an owned map; map returns a list of strings, integers or floats (list_map).
    def map_list_block(node, name, recv, env, elem)
      return ["(#{wrap(recv)}.len() as i64)", :i64, true] if name == :count && !node.block

      blk = node.block
      bad(node, "`#{name}` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`#{name}`", elem)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => elem))
      value = "{ let #{param} = (*__e).clone(); #{(lets + [unparen(e)]).join(" ")} }"
      src = "for __e in #{wrap(recv)}.iter()"
      return list_map(blk, value, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{TypeNames.display(t)}") unless t == :bool
      case name
      when :select, :reject
        test = name == :select ? value : "!#{value}"
        ["{ let mut __out = Vec::<#{CompositeTypes.map_value_rust(elem)}>::new(); #{src} { if #{test} { __out.push((*__e).clone()); } } __out }", recv[1], false]
      when :find
        ["{ let mut __r: Option<#{CompositeTypes.map_value_rust(elem)}> = None; #{src} { if #{value} { __r = Some((*__e).clone()); break; } } __r }", OPT_OF.fetch(elem), false]
      when :any?
        ["{ let mut __r = false; #{src} { if #{value} { __r = true; break; } } __r }", :bool, false]
      when :all?
        ["{ let mut __r = true; #{src} { if !#{value} { __r = false; break; } } __r }", :bool, false]
      else
        ["{ let mut __r: i64 = 0; #{src} { if #{value} { __r += 1; } } __r }", :i64, false]
      end
    end

    # xs.tally: how many times each string occurs, as a map from string to integer (keys come back sorted).
    def list_tally(node, recv, elem)
      bad(node, "`tally` needs a list of strings, because map keys are strings") unless elem == :string
      ["{ let mut __m = std::collections::BTreeMap::<String, i64>::new(); for __x in #{wrap(recv)}.iter() { " \
       "*__m.entry(__x.to_string()).or_insert(0) += 1; } __m }", CompositeTypes.map_symbol(:i64), false]
    end

    # `maybe || []` and `maybe || {}`: an empty collection of the same kind as the left side, so no default has to be built.
    def empty_default?(inner, node)
      ((LISTS.key?(inner) || struct_list?(inner)) && node.is_a?(Prism::ArrayNode) && node.elements.empty?) ||
        (MAPS.key?(inner) && node.is_a?(Prism::HashNode) && node.elements.empty?)
    end

    # { "a" => 1, "b" => 2 }: a map with String keys and values of one type (String, Integer, Float, true/false, or a list
    # of strings or integers). It is a Rust BTreeMap, so keys come back sorted. `{}` has no type of its own and fits
    # wherever a map is expected.
    def map_lit(n, env)
      return ["std::collections::BTreeMap::new()", :empty_map, true] if n.elements.empty?

      seen = {}
      pairs = n.elements.map do |el|
        bad(el, "a map literal is `\"key\" => value` pairs; `**` and splats are not supported") unless el.is_a?(Prism::AssocNode)
        key = el.key
        if key.is_a?(Prism::SymbolNode)
          bad(key, "map keys are strings: write \"#{key.unescaped}\" => value (a symbol is a different key in Ruby, and these maps have string keys)")
        end
        bad(key, "a map key must be a string literal such as \"name\"") unless key.is_a?(Prism::StringNode)
        bad(key, "duplicate map key \"#{key.unescaped}\"") if seen[key.unescaped]
        seen[key.unescaped] = true
        v = expr(el.value, env)
        bad(el.value, "a map value cannot be nil; use `|| default`") if OPT.key?(v[1])
        [key.unescaped, v, el.value]
      end
      value = map_value_type(n, pairs.map { |_, v, _| v[1] })
      items = pairs.map do |k, v, vnode|
        code = v[1] == :str ? "#{v[0]}.to_string()" : v[0]
        code = "(#{code} as i64)" if v[1] == :i32
        code = "#{wrap(v)}.iter().map(|__s| __s.to_string()).collect::<Vec<String>>()" if value == :strs # owned, whatever the list holds
        code = "#{code}.clone()" if vnode.is_a?(Prism::LocalVariableReadNode) && %i[string i64s f64s].include?(value)
        "(#{AxumDsl.rstr(k)}.to_string(), #{code})"
      end
      [CompositeTypes.map_rust(value).then { |t| "#{t.sub('<String', '::<String')}::from([#{items.join(', ')}])" },
       CompositeTypes.map_symbol(value), true]
    end

    # The one value type of a literal's values; mixed or unsupported types are refused with what to do instead.
    def map_value_type(node, types)
      kinds = types.map { |t| { str: :string, int: :i64, i32: :i64 }.fetch(t, t) }.uniq
      shown = types.map { |t| TypeNames.display(t) }.uniq
      if kinds.size > 1
        bad(node, "a map holds values of one type, got #{shown.join(' and ')}; for mixed values declare an `output` struct, " \
                  "or use a binding for open-ended JSON")
      end
      return kinds.first if CompositeTypes::BY_SYMBOL.key?(kinds.first)

      bad(node, "map values can be String, Integer, Float, true/false, or a list of strings or integers so far, not #{shown.first}")
    end

    # A map key: a string literal or a string value, as a &str.
    def map_key(arg, env)
      k = expr(arg, env)
      bad(arg, "map keys are strings, got #{TypeNames.display(k[1])}") unless %i[str string].include?(k[1])
      k[1] == :str ? k[0] : "#{wrap(k)}.as_str()"
    end

    # Reads and non-mutating methods of a map: m["k"] (nil-able), fetch, key?, keys, values, size, empty?, merge.
    def map_call(node, name, args, recv, env)
      value = MAPS.fetch(recv[1])
      unless MAP_ARITY.key?(name)
        bad(node, "a map only supports #{MAP_ARITY.keys.join('/')} so far, not `#{name}`", word: name.to_s, from: MAP_ARITY.keys.map(&:to_s))
      end
      want = MAP_ARITY.fetch(name)
      unless want === args.size
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? 'one or two arguments' : "#{want} argument(s)"} on a map")
      end

      case name
      when :[] then ["#{wrap(recv)}.get(#{map_key(args[0], env)}).cloned()", OPT_OF.fetch(value), true]
      when :fetch then map_fetch(node, recv, args, env, value)
      when :key?, :has_key?, :member?, :include? then ["#{wrap(recv)}.contains_key(#{map_key(args[0], env)})", :bool, true]
      when :keys then ["#{wrap(recv)}.keys().cloned().collect::<Vec<String>>()", :strs, true]
      when :values then map_values(node, recv, value)
      when :size, :length then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      when :map, :select, :reject, :each then map_block(node, name, recv, env, value)
      when :to_json
        @fallible = true
        ["serde_json::to_string(&#{wrap(recv)}).map_err(|e| format!(\"json: {e}\"))?", :string, true]
      else map_merge(node, recv, args, env)
      end
    end

    # Reads on a nil-able map (the value of a map of maps): m["a"] gives the inner map's value, nil when the
    # outer key is missing, and nil? tells whether the outer key was there. Anything else would need the map
    # itself, so it is refused until the value is branched on.
    def opt_map_call(node, name, args, recv, env, inner)
      value = MAPS.fetch(inner)
      case name
      when :nil?
        bad(node, "`nil?` takes no arguments") unless args.empty?
        ["#{wrap(recv)}.is_none()", :bool, true]
      when :[]
        bad(node, "`[]` takes one argument on a map") unless args.size == 1
        ["#{wrap(recv)}.as_ref().and_then(|__m| __m.get(#{map_key(args[0], env)}).cloned())", OPT_OF.fetch(value), false]
      else
        bad(node, "`#{node.receiver.slice}` may be nil, so index it (`#{node.receiver.slice}[...][...]`) or test `.nil?` first",
            word: name.to_s, from: %w[[] nil?])
      end
    end

    # m.fetch("k") ends the call with an error result when the key is missing, as Ruby raises KeyError;
    # m.fetch("k", default) answers the default.
    def map_fetch(node, recv, args, env, value)
      key = map_key(args[0], env)
      if args.size == 1
        @fallible = true
        return ["#{wrap(recv)}.get(#{key}).cloned().ok_or_else(|| format!(\"key not found: {:?}\", #{key}))?", value, false]
      end
      d = expr(args[1], env)
      code = coerce(d[0], d[1], value) or
        bad(args[1], "the default for fetch must be a #{TypeNames.display(value)}, got #{TypeNames.display(d[1])}")
      ["#{wrap(recv)}.get(#{key}).cloned().unwrap_or_else(|| #{unparen(code)})", value, false]
    end

    def map_values(node, recv, value)
      if value.to_s.start_with?("struct:") # a map of objects: a list of them
        name = value.to_s.delete_prefix("struct:")
        return ["#{wrap(recv)}.values().cloned().collect::<Vec<#{name}>>()", CompositeTypes.object_list_symbol(name), true]
      end
      if CompositeTypes.scalar_map?(value) # a map of maps: a list of the inner maps
        return ["#{wrap(recv)}.values().cloned().collect::<Vec<#{CompositeTypes.map_value_rust(value)}>>()", CompositeTypes.map_list_symbol(value), true]
      end
      list = { string: :strs, i64: :i64s }[value] or
        bad(node, "`values` needs a map of strings or integers so far (lists of floats, booleans and lists are not supported yet)")
      ["#{wrap(recv)}.values().cloned().collect::<#{CompositeTypes::BY_SYMBOL.fetch(list)[1]}>()", list, true]
    end

    # m.merge(other): a new map with other's entries added (other wins), as in Ruby; m itself is not changed.
    def map_merge(node, recv, args, env)
      o = expr(args[0], env)
      unless [recv[1], :empty_map].include?(o[1])
        bad(args[0], "`merge` takes a map of the same kind (#{TypeNames.display(recv[1])}), got #{TypeNames.display(o[1])}")
      end
      ["{ let mut __m = #{wrap(recv)}.clone(); __m.extend(#{wrap(o)}.clone()); __m }", recv[1], false]
    end

    # map / select / reject with a block on a map. `map` returns a list of strings or integers
    # (the result of the block decides), exactly like a list `map`; `select` and `reject` return
    # a new map with the same key and value types, built as a BTreeMap. The block takes |k, v|:
    # k is the String key and v the value type. A map is read-only; nothing here changes it.
    def map_block(node, name, recv, env, value)
      return each_expr(node, recv, env) if name == :each
      blk = node.block
      bad(node, "`#{name}` on a map needs a literal { |k, v| ... } block") unless blk.is_a?(Prism::BlockNode)
      kname, vname = map_block_params(blk, env, name, value)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(kname => :string, vname => value))
      bind = "let #{kname} = __k.to_string(); let #{vname} = #{map_block_value(value)}; "
      body = "{ #{bind}#{(lets + [unparen(e)]).join(", ")} }"
      src = "for (__k, __v) in #{wrap(recv)}.iter()"
      return map_map(blk, body, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{TypeNames.display(t)}") unless t == :bool
      test = name == :select ? body : "!#{body}"
      ["{ let mut __out = #{CompositeTypes.map_rust(value).sub('<String', '::<String')}::new(); #{src} { if #{test} { " \
       "__out.insert(__k.to_string(), (*__v).clone()); } } __out }", recv[1], false]
    end

    # The block binding for a value of the map value type: strings are owned, the Copy scalars
    # copied, and a list cloned.
    def map_block_value(value)
      case value
      when :string then "__v.to_string()"
      when :strs, :i64s, :f64s then "__v.clone()"
      when :i64, :f64, :bool then "*__v"
      else "(*__v).clone()" # a nested object or a nested map
      end
    end

    # The two plain parameters |k, v| of a map block; both must be read (reject_unused enforces it).
    def map_block_params(blk, env, name, value)
      ps = blk.parameters
      good = ps.is_a?(Prism::BlockParametersNode) && ps.locals.empty? && ps.parameters
      good &&= ps.parameters.requireds.size == 2 && ps.parameters.requireds.all? { |r| r.is_a?(Prism::RequiredParameterNode) }
      good &&= [ps.parameters.optionals, ps.parameters.posts, ps.parameters.keywords].all?(&:empty?)
      good &&= !ps.parameters.rest && !ps.parameters.keyword_rest && !ps.parameters.block
      bad(blk, "`#{name}` takes a block with exactly two plain parameters, |k, v|") unless good
      ks, vs = ps.parameters.requireds
      bad(blk, "the block parameters must have different names") if ks.name == vs.name
      [ks, vs].each do |r|
        bad(blk, "`#{r.name}` is already defined") if env.key?(r.name)
        bad(blk, "block parameter `#{r.name}` must be snake_case and not a Rust keyword") if !r.name.to_s.match?(SNAKE) || RUST_KW.include?(r.name.to_s)
        @declared << [r.name, r, "block parameter"]
      end
      note_decl(ks.location, ks.name, "parameter", :string)
      note_decl(vs.location, vs.name, "parameter", value)
      [ks.name, vs.name]
    end

    # map on a map: the result of the block decides whether the list holds strings or integers.
    def map_map(blk, body, type, src)
      kind = if %i[string str].include?(type) then :string
             elsif %i[i32 i64 int].include?(type) then :i64
             end
      bad(blk, "the `map` block must return a string or an integer, got #{TypeNames.display(type)}") unless kind
      push = if kind == :i64 then "#{body} as i64"
             elsif type == :str then "#{body}.to_string()"
             else body
             end
      ["{ let mut __out = Vec::<#{kind == :i64 ? "i64" : "String"}>::new(); #{src} { __out.push(#{push}); } __out }",
       LIST_OF.fetch(kind), false]
    end

    def list_end(name, recv, elem)
      return ["#{wrap(recv)}.#{name}().copied()", :of64, true] if elem == :f64
      return ["#{wrap(recv)}.#{name}().copied()", :oi64, true] if elem == :i64

      ["#{wrap(recv)}.#{name}().map(|__x| __x.to_string())", :ostr, true]
    end

    # xs[i]: negative indexes count from the end, and out of range is nil, as in Ruby.
    def list_at(recv, arg, env, elem)
      i = expr(arg, env)
      bad(arg, "a list index must be an integer, got #{i[1]}") unless %i[int i32 i64].include?(i[1])
      item = %i[i64 f64].include?(elem) ? "__v[__j as usize]" : "__v[__j as usize].to_string()"
      ["{ let __v = &#{wrap(recv)}; let __n = __v.len() as i64; let __i = #{wrap(i)} as i64; " \
       "let __j = if __i < 0 { __i + __n } else { __i }; " \
       "if __j >= 0 && __j < __n { Some(#{item}) } else { None } }", { i64: :oi64, f64: :of64 }.fetch(elem, :ostr), false]
    end

    def list_include(recv, arg, env, elem)
      a = expr(arg, env)
      if elem == :f64
        bad(arg, "`include?` on a list of floats takes a number, got #{a[1]}") unless NUM.include?(a[1])
        value = a[1] == :f64 ? wrap(a) : "#{wrap(a)} as f64"
        return ["{ let __a = #{value}; #{wrap(recv)}.iter().any(|__e| *__e == __a) }", :bool, false]
      end
      if elem == :i64
        bad(arg, "`include?` on a list of integers takes an integer, got #{a[1]}") unless %i[int i32 i64].include?(a[1])
        return ["#{wrap(recv)}.contains(&(#{wrap(a)} as i64))", :bool, true]
      end
      bad(arg, "`include?` on a list of strings takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      # The argument is evaluated once, outside the loop, so it may contain `?` or `return`.
      ["{ let __a = &#{wrap(a)}; #{wrap(recv)}.iter().any(|__e| __e.to_string() == *__a) }", :bool, false]
    end

    def join_list(recv, args, elem)
      sep = args[0]
      bad(sep, "join separator must be a plain string literal") if sep && !sep.is_a?(Prism::StringNode)
      lit = AxumDsl.rstr(sep ? sep.unescaped : "")
      return ["#{wrap(recv)}.join(#{lit})", :string, true] if elem == :string
      return ["#{wrap(recv)}.iter().map(|__e| #{f64_str('*__e')}).collect::<Vec<String>>().join(#{lit})", :string, true] if elem == :f64

      ["#{wrap(recv)}.iter().map(|__e| __e.to_string()).collect::<Vec<String>>().join(#{lit})", :string, true]
    end

    # sort (bytewise for strings, like Ruby), uniq (first occurrence wins) and reverse.
    def list_reorder(name, recv, elem)
      if elem == :f64
        code =
          case name
          when :sort then "{ let mut __v: Vec<f64> = #{wrap(recv)}.iter().copied().collect(); __v.sort_by(|__a, __b| __a.total_cmp(__b)); __v }"
          when :reverse then "{ let mut __v: Vec<f64> = #{wrap(recv)}.iter().copied().collect(); __v.reverse(); __v }"
          else "{ let mut __out: Vec<f64> = Vec::new(); for __e in #{wrap(recv)}.iter() { if !__out.contains(__e) { __out.push(*__e); } } __out }"
          end
        return [code, :f64s, false]
      end
      ty = elem == :i64 ? "i64" : "String"
      own = elem == :i64 ? "#{wrap(recv)}.iter().copied()" : "#{wrap(recv)}.iter().map(|__e| __e.to_string())"
      code =
        case name
        when :sort then "{ let mut __v: Vec<#{ty}> = #{own}.collect(); __v.sort(); __v }"
        when :reverse then "{ let mut __v: Vec<#{ty}> = #{own}.collect(); __v.reverse(); __v }"
        else "{ let mut __seen = std::collections::HashSet::new(); #{own}.filter(|__s| __seen.insert(__s.clone())).collect::<Vec<#{ty}>>() }"
        end
      [code, LIST_OF.fetch(elem), false]
    end

    # sum of integers, overflow-checked like every other integer addition.
    def list_sum(node, recv, elem)
      return ["#{wrap(recv)}.iter().copied().sum::<f64>()", :f64, true] if elem == :f64

      @fallible = true
      (@flags["checked"] ||= {})["add:i64"] = true
      ["{ let mut __s: i64 = 0; for __e in #{wrap(recv)}.iter() { __s = ck_add_i64(__s, *__e, " \
       "#{AxumDsl.rstr(where(node))})?; } __s }", :i64, false]
    end

    # map / select / reject / find / any? / all? / count with a block, as for loops over the borrowed list.
    def list_block(node, name, recv, env, elem)
      return ["(#{wrap(recv)}.len() as i64)", :i64, true] if name == :count && !node.block
      return each_expr(node, recv, env) if name == :each

      blk = node.block
      bad(node, "`#{name}` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`#{name}`", elem)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => elem))
      own = %i[i64 f64].include?(elem) ? "*__e" : "__e.to_string()"
      value = "{ let #{param} = #{own}; #{(lets + [unparen(e)]).join(' ')} }"
      src = "for __e in #{wrap(recv)}.iter()"
      return list_map(blk, value, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{t}") unless t == :bool
      ety = { i64: "i64", f64: "f64" }.fetch(elem, "String")
      case name
      when :select, :reject
        test = name == :select ? value : "!#{value}"
        ["{ let mut __out = Vec::<#{ety}>::new(); #{src} { if #{test} { __out.push(#{own}); } } __out }",
         LIST_OF.fetch(elem), false]
      when :find
        ["{ let mut __r: Option<#{ety}> = None; #{src} { if #{value} { __r = Some(#{own}); break; } } __r }",
         { i64: :oi64, f64: :of64 }.fetch(elem, :ostr), false]
      when :any?
        ["{ let mut __r = false; #{src} { if #{value} { __r = true; break; } } __r }", :bool, false]
      when :all?
        ["{ let mut __r = true; #{src} { if !#{value} { __r = false; break; } } __r }", :bool, false]
      else
        ["{ let mut __r: i64 = 0; #{src} { if #{value} { __r += 1; } } __r }", :i64, false]
      end
    end

    # map: a block that returns strings, integers or floats gives a list of that element type.
    def list_map(blk, value, type, src)
      kind = if %i[string str].include?(type) then :string
             elsif %i[i32 i64 int].include?(type) then :i64
             elsif type == :f64 then :f64
             end
      bad(blk, "the `map` block must return a string, an integer or a float, got #{type}") unless kind
      push = if kind == :i64 then "#{value} as i64"
             elsif type == :str then "#{value}.to_string()"
             else value
             end
      ty = { i64: "i64", f64: "f64" }.fetch(kind, "String")
      ["{ let mut __out = Vec::<#{ty}>::new(); #{src} { __out.push(#{push}); } __out }",
       LIST_OF.fetch(kind), false]
    end

    # ["a", "b"] is a list of strings and [1, 2] a list of integers; mixing them is refused.
    def array_lit(node, env)
      bad(node, "an array literal needs at least one element") if node.elements.empty?
      items = node.elements.map { |el| expr(el, env) }
      if items.all? { |e| %i[str string].include?(e[1]) }
        ["vec![#{items.map { |e| e[1] == :str ? "#{e[0]}.to_string()" : e[0] }.join(', ')}]", :strs, true]
      elsif items.all? { |e| NUM.include?(e[1]) } && items.any? { |e| e[1] == :f64 }
        ["vec![#{items.map { |e| e[1] == :f64 ? e[0] : "(#{wrap(e)} as f64)" }.join(', ')}]", :f64s, true]
      elsif items.all? { |e| %i[int i32 i64].include?(e[1]) }
        ["vec![#{items.map { |e| "#{wrap(e)} as i64" }.join(', ')}]", :i64s, true]
      elsif items.all? { |e| e[1] == :block }
        ["vec![#{items.map(&:first).join(', ')}]", :blocks, true]
      elsif items.all? { |e| e[1] == :rcontent }
        ["vec![#{items.map(&:first).join(', ')}]", :rcontents, true]
      else
        bad(node, "array elements must all be strings, all be numbers, all be content blocks or all be resource contents")
      end
    end

    # (a..b) and (a...b): a list of integers. An empty range (the ends the wrong way round) is an empty list.
    def range_lit(node, env)
      bad(node, "a range needs both ends") unless node.left && node.right
      ends = [node.left, node.right].map do |side|
        e = expr(side, env)
        bad(side, "range ends must be integers, got #{e[1]}") unless %i[int i32 i64].include?(e[1])
        "(#{wrap(e)} as i64)"
      end
      ["(#{ends[0]}#{node.exclude_end? ? '..' : '..='}#{ends[1]}).collect::<Vec<i64>>()", :i64s, true]
    end

    # a.upto(b) and a.downto(b).
    def int_run(name, recv, arg, env)
      b = expr(arg, env)
      bad(arg, "`#{name}` needs an integer, got #{b[1]}") unless %i[int i32 i64].include?(b[1])
      a = "(#{wrap(recv)} as i64)"
      z = "(#{wrap(b)} as i64)"
      code = name == :upto ? "(#{a}..=#{z}).collect::<Vec<i64>>()" : "(#{z}..=#{a}).rev().collect::<Vec<i64>>()"
      [code, :i64s, true]
    end

    # split("sep", limit) with an integer literal limit. A positive limit stops after that many
    # pieces and keeps trailing empty ones; a negative limit splits fully and keeps them; 0 is plain
    # split. The empty string splits to an empty list in every case, as in Ruby.
    def split_limit(recv, args)
      sep, lim = args
      bad(sep, "`split` takes a plain string literal separator") unless sep.is_a?(Prism::StringNode)
      bad(sep, "split(\" \", n) means whitespace in Ruby; use split with no argument") if sep.unescaped == " "
      bad(sep, "split with an empty separator is not supported") if sep.unescaped.empty?
      bad(lim, "the split limit must be an integer literal") unless lim.is_a?(Prism::IntegerNode)
      return split_sep(recv, sep) if lim.value.zero?

      lit = AxumDsl.rstr(sep.unescaped)
      pieces = lim.value.positive? ? "__s.splitn(#{lim.value}, #{lit})" : "__s.split(#{lit})"
      ["{ let __s = &#{wrap(recv)}; if __s.is_empty() { Vec::<String>::new() } else { " \
       "#{pieces}.map(|__p| __p.to_string()).collect::<Vec<String>>() } }", :strs, false]
    end

    # partition("sep"): [before, sep, after], or [whole, "", ""] when the separator is absent.
    def str_partition(recv, sep)
      bad(sep, "`partition` takes a plain string literal, not a regex") unless sep.is_a?(Prism::StringNode)
      lit = AxumDsl.rstr(sep.unescaped)
      ["{ let __s = &#{wrap(recv)}; match __s.find(#{lit}) { " \
       "Some(__i) => vec![__s[..__i].to_string(), #{lit}.to_string(), __s[__i + #{lit}.len()..].to_string()], " \
       "None => vec![__s.to_string(), String::new(), String::new()] } }", :strs, false]
    end

    # s[start, length] and s[index]: counted in characters, negative positions count from the end,
    # and out of range is nil, as in Ruby. Ranges are not supported.
    def str_slice(recv, args, env)
      bad(args[0], "string ranges are not supported; use s[start, length]") if args.any? { |a| a.is_a?(Prism::RangeNode) }
      nums = args.map do |a|
        e = expr(a, env)
        bad(a, "a string index must be an integer, got #{e[1]}") unless %i[int i32 i64].include?(e[1])
        "#{wrap(e)} as i64"
      end
      chars = "let __cs: Vec<char> = #{wrap(recv)}.chars().collect(); let __n = __cs.len() as i64;"
      code =
        if nums.size == 1
          "{ #{chars} let __i = #{nums[0]}; let __j = if __i < 0 { __i + __n } else { __i }; " \
          "if __j >= 0 && __j < __n { Some(__cs[__j as usize].to_string()) } else { None } }"
        else
          "{ #{chars} let mut __st = #{nums[0]}; let __ln = #{nums[1]}; if __st < 0 { __st += __n; } " \
          "if __st < 0 || __st > __n || __ln < 0 { None } else { let __en = __st.saturating_add(__ln).min(__n); " \
          "Some(__cs[__st as usize..__en as usize].iter().collect::<String>()) } }"
        end
      [code, :ostr, false]
    end

    # "ab" * 3. A negative count is an error result, as Ruby raises ArgumentError.
    def str_repeat(node, l, r)
      @fallible = true
      ["{ let __n = #{wrap(r)} as i64; if __n < 0 { return Err(format!(\"error: negative argument at {}: " \
       "String#* needs a count of zero or more, got {}\", #{AxumDsl.rstr(where(node))}, __n)); } " \
       "#{wrap(l)}.repeat(__n as usize) }", :string, false]
    end

    # Integer(text, 10): strict decimal parsing; an invalid value is an error result, like Ruby's
    # ArgumentError. The base must be written out, because Integer(text) alone also accepts 0x, 0b and
    # a leading 0 as octal, which the DSL does not reproduce.
    def integer_call(node, args, env)
      unless args.size == 2 && args[1].is_a?(Prism::IntegerNode) && args[1].value == 10
        bad(node, "Integer needs the base written out: Integer(text, 10); without it Ruby also accepts 0x, 0b and octal forms")
      end
      a = expr(args[0], env)
      bad(args[0], "Integer takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      @fallible = true
      (@flags["helpers"] ||= {})["str_to_int"] = true
      ["str_to_int(&#{wrap(a)}, #{AxumDsl.rstr(where(node))})?", :i64, true]
    end

    # String#to_i with Ruby's parsing rules, as an i64: a value that does not fit is an error
    # result, because Ruby would return a bignum. The parser is one small generated function.
    def str_to_i(node, recv)
      @fallible = true
      (@flags["helpers"] ||= {})["str_to_i"] = true
      ["str_to_i(&#{wrap(recv)}, #{AxumDsl.rstr(where(node))})?", :i64, true]
    end

    def note_capitalize(node)
      Notify.add(@path, node, "W-STR-CAPITALIZE",
                 "Ruby capitalize uses titlecase for some characters (for example ß, ǆ); " \
                 "Rust has only uppercase, so the result can differ for those")
    end

    # rust(:name, args...): a call into a function declared with rust_fn. The signature
    # is checked here; the body of the function is plain Rust that cargo checks.
    def rust_call(node, args, env)
      head = args[0]
      bad(node, "rust() takes the injected function's name as a symbol first") unless head.is_a?(Prism::SymbolNode)
      fname = head.unescaped
      ext = @externs[fname] or bad(head, "no rust_fn declared for `#{fname}`#{@externs.empty? ? '' : " (declared: #{@externs.keys.join(', ')})"}", word: fname, from: @externs.keys)
      (@flags["used_externs"] ||= {})[fname] = true
      rest = args.drop(1)
      unless rest.size == ext["args"].size
        bad(node, "`#{fname}` takes #{ext['args'].size} argument(s), got #{rest.size}; expected `rust(:#{fname}#{ext['args'].map { |t| ", #{t}" }.join})`")
      end
      parts = rest.zip(ext["args"]).map do |arg, want|
        r = expr(arg, env)
        want_t = want.to_sym
        rt = RINT.fetch(r[1], r[1])
        ok = (want_t == :string && %i[string str secret].include?(rt)) || rt == want_t ||
             (rt == :int && INTS.include?(want_t))
        bad(arg, "argument of `#{fname}` should be #{want_t}, got #{r[1]}") unless ok
        want_t == :string ? "&#{wrap(r)}" : wrap(r)
      end
      prefix = ext["from"] ? "#{ext["from"]}::" : ""
      call = "#{prefix}#{fname}(#{parts.join(', ')})"
      if ext["async"]
        refuse_async(node, "rust_fn `#{fname}`", ext["async_reason"])
        @uses_async = true
        @async_reason ||= "calls rust_fn `#{fname}` (line #{node.location.start_line})"
        call = "#{call}.await"
      end
      [call, ext["returns"].to_sym, true]
    end

    # Integer arithmetic is overflow-checked: a failure returns a message that says what went
    # wrong, where, and how to fix it (see Emit.checked_int_lines). The compiler decides this;
    # there is no setting. + - * and Ruby-style / % use the add, sub, mul, fdiv and fmod kinds;
    # an operand wrapped in Rust::Int32 / Rust::Int64 switches / and % to the div and rem kinds,
    # which truncate like Rust.
    OP_KIND = { :+ => "add", :- => "sub", :* => "mul", :/ => "fdiv", :% => "fmod" }.freeze
    # Rust::Int32(x) / Rust::Int64(x): the value carries Rust arithmetic (/ and % truncate toward zero)
    # and the carrier is sticky: any operation with such an operand is Rust-style.
    RUST_OP_KIND = OP_KIND.merge(:/ => "div", :% => "rem").freeze
    RUST_INTS = { Int32: :i32, Int64: :i64 }.freeze
    RINT = { r_i32: :i32, r_i64: :i64 }.freeze
    RINT_OF = RINT.invert.freeze

    # Content blocks a tool can return instead of one string (the MCP tool result's `content`): text, image, audio,
    # resource_link and the two embedded resources. The body ends in one block or an array of them. Positional
    # arguments come first (kinds: :string is any string expression, :uri a string that is a URI when written out,
    # :data base64 text, :mime a MIME type written out); then the keywords the block allows. Every block takes
    # `audience:` and `priority:`, the annotations of the spec (the same as on a resource).
    ANNOTATION_KW = { audience: :audience, priority: :priority }.freeze
    CONTENT_SHAPE = {
      text: { pos: %i[string], kw: ANNOTATION_KW },
      image: { pos: %i[data mime], kw: ANNOTATION_KW },
      audio: { pos: %i[data mime], kw: ANNOTATION_KW },
      resource_link: { pos: %i[uri], kw: { name: :string, title: :string, description: :string, mime_type: :mime, size: :size }.merge(ANNOTATION_KW), required: %i[name] },
      embedded_text: { pos: %i[uri string], kw: { mime_type: :mime }.merge(ANNOTATION_KW) },
      embedded_blob: { pos: %i[uri data], kw: { mime_type: :mime }.merge(ANNOTATION_KW) }
    }.freeze
    MIME = %r{\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*\z}
    BASE64 = %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}
    URI_SCHEME = /\A[A-Za-z][A-Za-z0-9+.-]*:/
    # `text` and `blob` build a resource content (not a tool/prompt content block): a resource body may end
    # in one or an array of them, and they become the contents of the ReadResourceResult.
    RESOURCE_CONTENT = {
      text: { pos: %i[string], kw: { uri: :uri, mime_type: :mime } },
      blob: { pos: %i[data], kw: { uri: :uri, mime_type: :mime } }
    }.freeze

    def resource_body? = @tool.to_s.start_with?("resource ")

    # text(s, uri:, mime_type:) and blob(base64, uri:, mime_type:) build MCP resource contents (the contents of
    # a ReadResourceResult). An axum response has no such shape, and `rmcp`, the crate they came from, is not a
    # dependency of this crate: the call is checked against the content's own keywords, then refused by name.
    def resource_content_call(node, args, env)
      name = node.name
      shape = RESOURCE_CONTENT.fetch(name)
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      unless args.size == shape[:pos].size
        bad(node, "#{name} takes #{shape[:pos].size} positional argument(s) (#{shape[:pos].join(', ')}), got #{args.size}")
      end
      given = content_keywords(node, kw, shape)
      args.zip(shape[:pos]).each { |arg, kind| content_arg(arg, kind, env, name) }
      given.each { |key, value| content_arg(value, shape[:kw].fetch(key), env, "#{name} #{key}:") }
      bad(node, "`#{name}` builds an MCP resource content, which an axum service has no equivalent for; " \
                "answer with text(...), json(...) or html(...)")
    end

    def content_call(node, args, env)
      name = node.name
      shape = CONTENT_SHAPE.fetch(name)
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      unless args.size == shape[:pos].size
        bad(node, "#{name} takes #{shape[:pos].size} positional argument(s) (#{shape[:pos].join(', ')}), got #{args.size}")
      end
      given = content_keywords(node, kw, shape)
      args.zip(shape[:pos]).each { |arg, kind| content_arg(arg, kind, env, name) }
      given.each { |key, value| content_arg(value, shape[:kw].fetch(key), env, "#{name} #{key}:") }
      # text/image/audio/resource_link/embedded_* build MCP content blocks (a tool result's `content`), which an
      # axum response has no shape for; `rmcp`, the crate they came from, is not a dependency of this crate. The
      # call is checked against the block's own keyword shape, then refused by name.
      bad(node, "`#{name}` builds an MCP content block, which an axum service has no equivalent for; " \
                "answer with text(...), json(...) or html(...)")
    end

    def content_keywords(node, kw, shape)
      given = {}
      (kw ? kw.elements : []).each do |el|
        bad(el, "unsupported #{nodename(el)} in #{node.name}(...) (use `keyword: value`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped.to_sym
        bad(el, "#{node.name} has no keyword `#{key}:` (it has: #{shape[:kw].keys.map { |k| "#{k}:" }.join(', ')})", word: key, from: shape[:kw].keys) unless shape[:kw].key?(key)
        bad(el, "duplicate `#{key}:`") if given.key?(key)
        given[key] = el.value
      end
      missing = (shape[:required] || []) - given.keys
      bad(node, "#{node.name} needs #{missing.map { |k| "`#{k}:`" }.join(', ')}") unless missing.empty?
      given
    end

    # One argument of a content block, as Rust. A literal is checked here (MIME type, base64, URI scheme, annotation
    # values); an expression only has to be a string.
    def content_arg(node, kind, env, what)
      case kind
      when :mime
        bad(node, "#{what}: the MIME type is written out, such as \"image/png\"") unless node.is_a?(Prism::StringNode)
        bad(node, "#{what}: `#{node.unescaped}` is not a MIME type (type/subtype, such as image/png)") unless node.unescaped.match?(MIME)
        AxumDsl.rstr(node.unescaped)
      when :size
        ok = node.is_a?(Prism::IntegerNode) && node.value >= 0
        bad(node, "#{what}: the size is a number of bytes written out, zero or more") unless ok
        "#{node.value}u64"
      when :audience
        ok = node.is_a?(Prism::ArrayNode) && !node.elements.empty? && node.elements.all? { |el| el.is_a?(Prism::SymbolNode) && %w[user assistant].include?(el.unescaped) }
        bad(node, "#{what}: a list of :user and/or :assistant, such as [:user]") unless ok
        node.elements.map(&:unescaped).uniq
      when :priority
        ok = (node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)) && (0..1).cover?(node.value)
        bad(node, "#{what}: a number from 0 to 1 written out (1 is the most important)") unless ok
        node.value.to_f
      else
        text_arg(node, kind, env, what)
      end
    end

    def text_arg(node, kind, env, what)
      if node.is_a?(Prism::StringNode)
        literal = node.unescaped
        bad(node, "#{what}: `#{literal.length > 24 ? "#{literal[0, 24]}..." : literal}` is not base64 text (A-Z a-z 0-9 + /, padded with =)") if kind == :data && !literal.match?(BASE64)
        bad(node, "#{what}: `#{literal}` is not a URI (it needs a scheme, such as file:///a.txt or notekit://guide)") if kind == :uri && !literal.match?(URI_SCHEME)
        return "#{AxumDsl.rstr(literal)}.to_string()"
      end
      e = expr(node, env)
      bad(node, "#{what}: needs a string, got #{TypeNames.display(e[1])}") unless %i[string str].include?(e[1])
      return "#{e[0]}.to_string()" if e[1] == :str

      # a local or parameter is read again later, so the block takes a copy
      node.is_a?(Prism::LocalVariableReadNode) ? "#{wrap(e)}.clone()" : e[0]
    end

    # setting(:name): the value of a server setting, read from the environment when the server started. A required
    # setting is a string, an optional one a nil-able string, and a secret has the type :secret, which only a binding or
    # rust_fn function may take (see the checks where a string is expected). A `type: :i64`, `:f64` or `:bool` setting
    # has that type (nil-able when optional).
    def setting_call(node, args)
      bad(node, "setting(:name) takes the name of a setting declared with `setting :name, env: \"...\"`") unless args.size == 1 && args[0].is_a?(Prism::SymbolNode)
      unless @route || @kind == :current || @tool.to_s.start_with?("tool ", "prompt ", "resource ")
        bad(node, "settings are read in a route or a filter body, not in a helper or a binding")
      end
      name = args[0].unescaped
      declared = @flags["settings"] || {}
      entry = declared[name] or
        bad(args[0], "no setting `#{name}` is declared#{declared.empty? ? '' : " (declared: #{declared.keys.join(', ')})"}; add `setting :#{name}, env: \"...\"` to the server",
            word: name, from: declared.keys)
      (@flags["used_settings"] ||= {})[name] = true
      if (typed = entry["type"])
        # A typed setting was parsed at startup; its Rust value is Copy, so it is read without a clone.
        base = typed.to_sym
        return ["settings().#{name}", entry["optional"] ? OPT_OF.fetch(base) : base, true]
      end
      type = entry["secret"] ? :secret : (entry["optional"] ? :ostr : :string)
      ["settings().#{name}.clone()", type, true]
    end

    # rails_signed_id(token, purpose: "user/avatar", secret: :secret_key): the integer id inside a Rails 8
    # signed ID, or nil when the token is not one this secret signed for this purpose. The secret names a
    # required string setting (usually SECRET_KEY_BASE); the purpose is the full `"<model>/<purpose>"` Rails
    # composes, because the compiler cannot infer a model from a token.
    def rails_signed_id_call(node, args, env)
      rest = args.dup
      hash = rest.last.is_a?(Prism::KeywordHashNode) ? rest.pop : nil
      bad(node, "rails_signed_id takes exactly one token") unless rest.size == 1
      token = expr(rest[0], env)
      bad(rest[0], "rails_signed_id takes a token string, got #{TypeNames.display(token[1])}") unless %i[str string].include?(token[1])
      purpose = nil
      secret = nil
      seen = {}
      hash&.elements&.each do |el|
        unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          bad(el, "unsupported #{nodename(el)} in rails_signed_id (write `purpose: \"user/avatar\", secret: :secret_key`)")
        end
        key = el.key.unescaped.to_sym
        unless %i[purpose secret].include?(key)
          bad(el, "unknown keyword `#{key}:` for rails_signed_id (allowed: purpose, secret)", word: key, from: %i[purpose secret])
        end
        bad(el, "duplicate keyword `#{key}:`") if seen[key]
        seen[key] = true
        if key == :purpose
          bad(el.value, "rails_signed_id's `purpose:` is a string literal, such as \"user/avatar\"") unless el.value.is_a?(Prism::StringNode)
          purpose = el.value.unescaped
          bad(el.value, "rails_signed_id's `purpose:` must not be empty") if purpose.empty?
        else
          bad(el.value, "rails_signed_id's `secret:` is a setting name, such as :secret_key") unless el.value.is_a?(Prism::SymbolNode)
          secret = el.value.unescaped
        end
      end
      bad(node, "rails_signed_id needs `purpose:` and `secret:`") if purpose.nil? || secret.nil?
      declared = @flags["settings"] || {}
      entry = declared[secret] or
        bad(node, "no setting `#{secret}` is declared#{declared.empty? ? '' : " (declared: #{declared.keys.join(', ')})"}; " \
                  "rails_signed_id's `secret:` names the required string setting that holds SECRET_KEY_BASE",
            word: secret, from: declared.keys)
      if entry["type"] || entry["optional"]
        bad(node, "rails_signed_id's `secret:` must name a required string setting, not #{entry['type'] ? "a `type: :#{entry['type']}`" : 'an optional'} one")
      end
      if (earlier = @flags["signed_id_secret"]) && earlier != secret
        bad(node, "rails_signed_id already uses setting `#{earlier}`; a service derives one signed-ID key per process, so every call must name the same `secret:`")
      end
      @flags["signed_id_secret"] = secret
      (@flags["used_settings"] ||= {})[secret] = true
      (@flags["builtins"] ||= {})["rails_signed_id"] = true
      token_arg = token[1] == :str ? token[0] : "&#{wrap(token)}"
      ["axum_dsl_rails_signed_id(settings().#{secret}.as_bytes(), #{token_arg}, #{AxumDsl.rstr(purpose)})", :oi64, true]
    end

    # h(value) escapes a value for HTML; raw(value) gives the same value with no escaping, the XSS door a
    # review greps for by name. Either takes any value a string interpolation takes and gives a string, so
    # both compose inside text(...), html(...) and interpolation. h is the only one that needs the escaper.
    def html_escape_call(node, name, args, env)
      bad(node, "#{name} takes exactly one value") unless args.size == 1
      [html_value(args[0], expr(args[0], env), name), :string, true]
    end

    # The Rust text of one value written into HTML: the escaped form `h(value)` uses, the unescaped one
    # `raw(value)` uses, or the cleaned one `sanitize` uses; `what` is the name a refusal reads. A view's
    # `{{ x }}`, `{{ x|raw }}` and `{{ x|sanitize }}` are these three forms, so a marker and its equivalent
    # helper call cannot escape differently.
    def html_value(node, v, what)
      bad(node, "a secret cannot be written into HTML; pass it to a binding or rust_fn function") if v[1] == :secret
      if what == :sanitize
        # The emitter writes the sanitiser and its dependency only into a crate whose views clean a value.
        @flags["sanitize"] = true
        return "axum_dsl_sanitize(#{v[1] == :str ? wrap(v) : "&#{wrap(v)}"})"
      end
      bad(node, "#{what} takes a string or a number, got #{TypeNames.display(v[1])}") unless %i[str string i32 i64 f64 bool int].include?(v[1])
      # raw is the value as it is; a stored string is copied so the local stays readable afterwards.
      return "#{wrap(v)}.to_string()" if what == :raw

      @flags["html_escape"] = true # the emitter writes the escaper only into a crate whose bodies use h -- or a view
      borrowed =
        case v[1]
        when :str then v[0]             # a string literal is already a &str
        when :string then "&#{wrap(v)}" # borrow the String, so nothing is copied before the escape
        else "&#{wrap(v)}.to_string()"  # a number: format it, then escape the text
        end
      # into_owned, because a body string is an owned String; the escaper itself returns the input borrowed
      # when there is nothing to escape (emit.rb: HTML_ESCAPE).
      "axum_dsl_html_escape(#{borrowed}).into_owned()"
    end

    # file_text(:name): the text of a file declared with `file "path", as: :name`, read from disk on this call, so
    # an edit to the file needs no rebuild. The read can fail, so the call is fallible. A helper may use it.
    def file_text_call(node, args)
      unless args.size == 1 && args[0].is_a?(Prism::SymbolNode)
        bad(node, "file_text(:name) takes the `as:` name of a file declared with `file \"path\", as: :name`")
      end
      f = declared_file(args[0], "file_text")
      (@flags["used_files"] ||= {})[f["name"]] = true
      (@flags["file_texts"] ||= {})[f["name"]] = true # the emitter writes file_text_<name> only for these
      @fallible = true
      ["file_text_#{f['name']}()?", :string, true]
    end

    # file_path(:name): the path the server reads a `file` from (the `env:` variable when it is set, else where the
    # compiler found it), for a message or a traceback that should name the file. It does not read the file.
    def file_path_call(node, args)
      unless args.size == 1 && args[0].is_a?(Prism::SymbolNode)
        bad(node, "file_path(:name) takes the `as:` name of a file declared with `file \"path\", as: :name`")
      end
      f = declared_file(args[0], "file_path")
      (@flags["used_files"] ||= {})[f["name"]] = true
      ["file_path_#{f['name']}().display().to_string()", :string, true]
    end

    # entry(:file, :name): the string "name", refused unless :name is one of that file's `entries:`, so a
    # function the server names is one the compiler found in the file.
    def entry_call(node, args)
      unless args.size == 2 && args.all?(Prism::SymbolNode)
        bad(node, "entry(:file, :name) takes the file's `as:` name and one of its entries: names")
      end
      f = declared_file(args[0], "entry")
      e = declared_entry(f, args[1], "entry")
      mark_entry(f, e, node)
      [AxumDsl.rstr(e), :str, true]
    end

    # entry_args(:file, :name, key: value, ...): the JSON text of a call's arguments, written by the compiler from
    # typed values (nil is null) and checked against what `def name` declares: the fields of its one TypedDict
    # parameter, or its plain parameters. With `unchecked: %i[args]` on the file the keys and types are not checked.
    def entry_args_call(node, args, env)
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.last : nil
      heads = kw ? args[0...-1] : args
      unless heads.size == 2 && heads.all?(Prism::SymbolNode)
        bad(node, "entry_args(:file, :name, key: value, ...) takes the file's `as:` name, one of its entries: names and the arguments as keywords")
      end
      f = declared_file(heads[0], "entry_args")
      e = declared_entry(f, heads[1], "entry_args")
      mark_entry(f, e, node)
      (@flags["built_entries"] ||= {})["#{f['name']}.#{e}"] = true
      sig = f["sigs"].fetch(e)
      call = "entry_args(:#{f['name']}, :#{e})"
      fields = sig["checked"] ? sig["fields"] : nil
      given = {}
      pairs = (kw ? kw.elements : []).map do |el|
        unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && !el.value.is_a?(Prism::ImplicitNode)
          bad(el, "#{call} takes `key: value` arguments")
        end
        key = el.key.unescaped
        bad(el, "#{call}: duplicate `#{key}:`") if given.key?(key)
        given[key] = true
        field = fields&.find { |x| x["name"] == key }
        if fields && field.nil?
          names = fields.map { |x| x["name"] }
          bad(el.key, "#{call}: `#{key}` is not a field of #{sig['of']} (#{names.join(', ')})", word: key, from: names)
        end
        "#{AxumDsl.rstr(key)}: #{entry_arg_value(el.value, field, call, sig['of'], env)}"
      end
      fields&.each do |x|
        next if !x["required"] || given.key?(x["name"])

        bad(node, "#{call}: #{sig['of']} requires `#{x['name']}` (#{f['path']}:#{x['line']})")
      end
      ["serde_json::json!({#{pairs.join(', ')}}).to_string()", :string, true]
    end

    # One entry_args value, as an expression json! serialises by reference (so a local is not moved). With a
    # field, its type must match the field's annotation, and a nil-able value needs a field that allows None.
    def entry_arg_value(vnode, field, call, of, env)
      nil_ok = field.nil? || field["nilable"]
      return "serde_json::Value::Null" if vnode.is_a?(Prism::NilNode) && nil_ok

      r = vnode.is_a?(Prism::NilNode) ? ["None", :nil, true] : expr(vnode, env)
      t = RINT.fetch(r[1], r[1])
      bad(vnode, "#{call}: a secret cannot be sent as an argument; pass it to a binding or rust_fn function") if t == :secret
      return "(#{wrap(r)})" unless field

      key = field["name"]
      if t == :nil || (OPT.key?(t) && !nil_ok)
        bad(vnode, "#{call}: `#{key}` may be nil here, but #{of} declares `#{key}: #{field['text']}`; use `|| default`")
      end
      inner = OPT.key?(t) ? OPT.fetch(t) : t
      want = field["base"].to_sym
      ok = case want
           when :string then %i[str string].include?(inner)
           when :int then %i[int i32 i64].include?(inner)
           when :f64 then %i[f64 int i32 i64].include?(inner)
           else inner == want
           end
      bad(vnode, "#{call}: `#{key}` is `#{key}: #{field['text']}` in #{of}, got #{TypeNames.display(r[1])}") unless ok
      entry_literal(vnode, field, call, of) if field["literals"]
      "(#{wrap(r)})"
    end

    # A `Literal["a", "b"]` field takes a string literal from its list, or a tool parameter whose `enum:` lists
    # only those values. Any other string could carry a value the callee does not accept, so it is refused.
    def entry_literal(vnode, field, call, of)
      allowed = field["literals"]
      key = field["name"]
      shown = allowed.map(&:inspect).join(", ")
      if vnode.is_a?(Prism::StringNode)
        return if allowed.include?(vnode.unescaped)

        bad(vnode, "#{call}: #{vnode.unescaped.inspect} is not one of `#{key}: #{field['text']}` in #{of}",
            word: vnode.unescaped, from: allowed)
      end
      enum = vnode.is_a?(Prism::LocalVariableReadNode) ? @enums[vnode.name.to_s] : nil
      bad(vnode, "#{call}: `#{key}` is `#{key}: #{field['text']}` in #{of}; pass one of #{shown}, or a parameter declared with enum:") unless enum
      extra = enum.compact - allowed
      return if extra.empty?

      bad(vnode, "#{call}: `#{vnode.name}` allows #{extra.map(&:inspect).join(', ')} (its enum:), which `#{key}: #{field['text']}` in #{of} does not")
    end

    # The `file` a call names, refused with the declared names when there is none.
    def declared_file(sym, call)
      name = sym.unescaped
      files = @flags["files"] || {}
      files[name] or
        bad(sym, "#{call}(:#{name}): no file has as: :#{name}#{files.empty? ? "; declare it with `file \"path\", as: :#{name}`" : " (declared: #{files.keys.join(', ')})"}",
            word: name, from: files.keys)
    end

    def declared_entry(f, sym, call)
      e = sym.unescaped
      return e if f["entries"].include?(e)

      listed = f["entries"].empty? ? "it lists none; add entries: %i[#{e}] to the file" : f["entries"].join(", ")
      bad(sym, "#{call}(:#{f['name']}, :#{e}): not in the entries of :#{f['name']} (#{listed})", word: e, from: f["entries"])
    end

    # Records that a body named an entry; the first call's node is kept for W-FILE-ARGS-UNCHECKED.
    def mark_entry(f, e, node)
      (@flags["used_files"] ||= {})[f["name"]] = true
      (@flags["used_entries"] ||= {})["#{f['name']}.#{e}"] ||= node
    end

    # The response helpers: the surface of a route body, where Sinatra's spelling meets axum's semantics.
    # `json(v)`, `text(s)`, `html(s)`, `halt(status, body)`, `redirect(path)` and `render(:name, locals: {})`
    # are values, and each lowers
    # to the definite Rust type :response (::axum::response::Response, what an axum handler returns). They are
    # built through IntoResponse, so each helper names its concrete type exactly once, in the emitted text.
    # `status(...)`, `content_type(...)` and `headers(...)` are statements (see status_stmt, content_type_stmt
    # and headers_stmt).
    def response_call(node, name, args, env)
      case name
      when :json then json_response(node, args, env)
      when :text then text_response(node, args, env, nil)
      when :html then text_response(node, args, env, "::axum::response::Html")
      when :redirect then redirect_response(node, args, env)
      when :halt then halt_response(node, args, env)
      when :render then render_response(node, args, env)
      when :send_file then send_file_response(node, args, env)
      end
    end

    # The optional `status:` and `content_type:` keywords of a response helper: the positional arguments
    # without the keyword hash, the StatusCode expression and the Content-Type literal (nil when the
    # keyword is absent). A status is an integer literal and a content type a string literal, so both are
    # known here, and both ride on the value the helper returns.
    def response_args(node, what, args)
      rest = args.dup
      hash = rest.last.is_a?(Prism::KeywordHashNode) ? rest.pop : nil
      return [rest, nil, nil] unless hash

      status = nil
      content_type = nil
      seen = {}
      hash.elements.each do |el|
        unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          bad(el, "unsupported #{nodename(el)} in #{what} (write `status: 401` or `content_type: \"text/html\"`)")
        end
        key = el.key.unescaped.to_sym
        unless RESPONSE_KEYWORDS.include?(key)
          bad(el, "unknown keyword `#{key}:` for #{what} (allowed: #{RESPONSE_KEYWORDS.join(', ')})",
              word: key, from: RESPONSE_KEYWORDS)
        end
        bad(el, "duplicate keyword `#{key}:`") if seen[key]
        seen[key] = true
        if key == :status
          status = status_literal(el.value, "#{what}'s status")
          helper_status(el.value, what)
        else
          content_type = content_type_literal(el.value, "#{what}'s content_type")
          helper_content_type(el.value, what)
        end
      end
      [rest, status, content_type]
    end

    # A helper's `status:` rides on the value it returns; `status(...)` (see status_stmt) is applied to the
    # final response. One body may not use both: which status answers the request would depend on the
    # path taken through the body. Record the helper's site, and refuse it when the statement is there.
    def helper_status(node, what)
      if @status_site
        bad(node, "this body uses `#{what}`'s `status:` here and `status(...)` at line #{@status_site.location.start_line}: use one; the statement applies to the final response, a helper's status: belongs to that value")
      end
      @helper_status ||= [node, what]
    end

    # A helper's `content_type:` rides on the value it returns, as `status:` does; `content_type(...)`
    # (see content_type_stmt) is the response default. One body may not use both: which type answers the
    # request would depend on the path taken through the body.
    def helper_content_type(node, what)
      if @content_type_site
        bad(node, "this body uses `#{what}`'s `content_type:` here and `content_type(...)` at line #{@content_type_site.location.start_line}: use one; the statement sets the response default for the routes that follow, a helper's content_type: belongs to that value")
      end
      @helper_content_type ||= [node, what]
    end

    # A `status:` value: an integer literal in 100..599, as the StatusCode expression a response wraps.
    def status_literal(arg, what)
      bad(arg, "#{what} is an integer literal between 100 and 599, such as `status: 401`") unless arg.is_a?(Prism::IntegerNode)
      bad(arg, "a status must be between 100 and 599, got #{arg.value}") unless arg.value.between?(100, 599)
      "::axum::http::StatusCode::from_u16(#{arg.value}).unwrap()"
    end

    # A `content_type:` value: the MIME type the response carries, as the static header text a Response
    # is given. Only a string literal is accepted, so the type is written in the source and cannot carry
    # a byte the header would reject; a symbol would have to come from CONTENT_TYPES, a closed list.
    def content_type_literal(arg, what)
      bad(arg, "#{what} is a string literal, such as `content_type: \"text/html\"`") unless arg.is_a?(Prism::StringNode)
      value = arg.unescaped
      unless value.ascii_only? && value.match?(MEDIA_TYPE)
        bad(arg, "#{what} is a MIME type written `type/subtype`, such as `text/html` or `text/vnd.turbo-stream.html`")
      end
      AxumDsl.rstr(value)
    end

    # A helper's value with its `content_type:` header on it. The status (when written) and the body are
    # already a Response through IntoResponse; this binds that Response, replaces its Content-Type header
    # and yields it, so the value is still the body's own :response and a `return` carries it.
    def with_content_type(value, content_type)
      return value unless content_type

      "{ let mut __response = #{value}; " \
        "__response.headers_mut().insert(::axum::http::header::CONTENT_TYPE, " \
        "::axum::http::HeaderValue::from_static(#{content_type})); __response }"
    end

    # `params[:id]` (or `params["id"]`): the value the route's params declared for that field, at the type it
    # declared, so the rest of the body reads it like any other value. A symbol is preferred: it is the same
    # name the `params` block declares. A route body takes no block parameters; this is how it reads its inputs.
    def params_read(node, args, env)
      bad(node, "params[...] takes exactly one field name") unless args.size == 1
      arg = args[0]
      name = case arg
             when Prism::SymbolNode, Prism::StringNode then arg.unescaped
             else bad(arg, "params[...] takes a literal field name, as a symbol (:id) or a string (\"id\")")
             end
      unless @types.key?(name)
        bad(arg, "`#{name}` is not a field of this route's params (fields: #{@types.keys.join(', ')})", word: name, from: @types.keys)
      end
      note_type(node.location, "parameter", @types.fetch(name), name)
      [name, @types.fetch(name), true]
    end

    # `errors[:name]` (or errors["name"]): the message the generated check() has for that field, and an
    # empty string when the request passed it (or that field had no violation), so a body interpolates it
    # with no conditional. The map is the handler's own, bound before the body runs (emit.rb:
    # errors_binding); a route has one only when it names `params:`, and the reader refuses one whose
    # group has no constraint the check() could report.
    def errors_read(node, args, env)
      bad(node, "errors[...] takes exactly one field name") unless args.size == 1
      unless @route && @params_name
        bad(node, "`errors` is the generated check()'s messages, so it is only there in a route that names `params:`")
      end
      arg = args[0]
      name = case arg
             when Prism::SymbolNode, Prism::StringNode then arg.unescaped
             else bad(arg, "errors[...] takes a literal field name, as a symbol (:name) or a string (\"name\")")
             end
      unless @types.key?(name)
        bad(arg, "`#{name}` is not a field of this route's params (fields: #{@types.keys.join(', ')})", word: name, from: @types.keys)
      end
      @errors_used = true
      note_type(node.location, "value", :string, "errors[:#{name}]")
      ["#{ERRORS_MAP}.get(#{AxumDsl.rstr(name)}).cloned().unwrap_or_default()", :string, true]
    end

    # `json(value)`: the value serialised as the response body. Anything a declared field or a literal can hold
    # is accepted, except the values the DSL will not put on the wire.
    def json_response(node, args, env)
      args, status, content_type = response_args(node, "json", args)
      bad(node, "json takes exactly one value") unless args.size == 1
      v = expr(args[0], env)
      bad(args[0], "a secret cannot be written into a response; pass it to a binding or rust_fn function") if v[1] == :secret
      bad(args[0], "a regex cannot be written into a response; use match? or read the string") if v[1] == :regex
      bad(args[0], "a content block cannot be written into a response; return it from the body") if %i[block blocks rcontent rcontents].include?(v[1])
      body = "::axum::Json(#{v[0]})"
      body = "(#{status}, #{body})" if status
      [with_content_type("#{INTO}(#{body})", content_type), :response, false]
    end

    # `text(s)` and `html(s)`: a string response. A body that ends in a plain string is text (Sinatra's rule),
    # so `text` is for saying so explicitly; either spells its own response type.
    def text_response(node, args, env, wrapper)
      what = wrapper ? "html" : "text"
      args, status, content_type = response_args(node, what, args)
      bad(node, "#{what} takes exactly one value") unless args.size == 1
      v = expr(args[0], env)
      bad(args[0], "a secret cannot be written into a response; pass it to a binding or rust_fn function") if v[1] == :secret
      unless %i[str string i32 i64 f64 bool].include?(v[1])
        bad(args[0], "#{what} writes a string or a number, got #{TypeNames.display(v[1])}")
      end
      body = "#{wrap(v)}.to_string()"
      body = "#{wrapper}(#{body})" if wrapper
      body = "(#{status}, #{body})" if status
      [with_content_type("#{INTO}(#{body})", content_type), :response, false]
    end

    # `send_file(path, content_type: "image/webp")`: a response whose body is the file at a path computed
    # while the request runs. The read is tokio's async fs, so the path need not be declared beside the DSL
    # file and the bytes are not copied into the crate. `content_type:` is required: a path's extension is
    # not a MIME type the compiler can trust. A read failure is a plain 500; a caller that wants a 404 checks
    # that the row exists first.
    def send_file_response(node, args, env)
      args, status, content_type = response_args(node, "send_file", args)
      bad(node, "send_file takes exactly one path") unless args.size == 1
      bad(node, "send_file needs `content_type:` with a MIME type, such as `content_type: \"image/webp\"`") if content_type.nil?
      v = expr(args[0], env)
      bad(args[0], "send_file takes a path string, got #{TypeNames.display(v[1])}") unless %i[str string].include?(v[1])
      (@flags["builtins"] ||= {})["send_file"] = true
      path = v[1] == :str ? "#{v[0]}.to_string()" : "#{wrap(v)}.clone()"
      status_code = status || "::axum::http::StatusCode::OK"
      code = <<~RS
        {
            let __path = #{path};
            match ::tokio::fs::read(&__path).await {
                Ok(__bytes) => {
                    let mut __response = ::axum::response::Response::new(::axum::body::Body::from(__bytes));
                    *__response.status_mut() = #{status_code};
                    __response.headers_mut().insert(::axum::http::header::CONTENT_TYPE, ::axum::http::HeaderValue::from_static(#{content_type}));
                    __response
                }
                Err(_) => ::axum::response::IntoResponse::into_response((::axum::http::StatusCode::INTERNAL_SERVER_ERROR, "")),
            }
        }
      RS
      [code.strip, :response, false]
    end

    # `redirect("/path")`: a 302 to that path, as Rails and Sinatra answer. `status:` names another
    # redirect status (301, 302, 303, 307 or 308). The path becomes the Location header, so it is written
    # in the source: a string literal, or a literal with only numbers and bools interpolated. The value is
    # still the body's own :response and can be returned.
    def redirect_response(node, args, env)
      args, status = redirect_args(node, args)
      bad(node, "redirect takes exactly one path") unless args.size == 1
      arg = args[0]
      v = expr(arg, env, header: true)
      bad(arg, "a redirect path must be a string, got #{TypeNames.display(v[1])}") unless %i[str string].include?(v[1])
      unless arg.is_a?(Prism::StringNode) || arg.is_a?(Prism::InterpolatedStringNode)
        bad(arg, "a redirect path is written in the source, because it becomes the Location header: write a string literal (redirect(\"/rooms\")) or interpolate numbers only (redirect(\"/rooms/\#{room_id}\")); a bare local, a params read, a method call or any other expression could carry a byte the header rejects")
      end
      redirect_literal_text(arg)
      path = v[1] == :str ? v[0] : "&#{wrap(v)}"
      code = status || "::axum::http::StatusCode::FOUND"
      ["{ let mut __redirect = #{INTO}((#{code}, ())); " \
       "__redirect.headers_mut().insert(::axum::http::header::LOCATION, " \
       "::axum::http::HeaderValue::from_str(#{path}).expect(\"a redirect path must be a valid header value\")); " \
       "__redirect }", :response, false]
    end

    # The literal text of a redirect path: every byte is visible ASCII (0x20-0x7E) or a tab, because the path
    # becomes the Location header and HeaderValue refuses anything else. `interp` proves the embedded values;
    # this proves the text written around them.
    def redirect_literal_text(node)
      parts = node.is_a?(Prism::InterpolatedStringNode) ? node.parts.grep(Prism::StringNode) : [node]
      parts.each do |part|
        part.unescaped.b.each_byte.with_index do |b, i|
          next if b == 0x09 || b.between?(0x20, 0x7e)

          bad(part, "a redirect path becomes the Location header, whose value is visible ASCII (0x20-0x7E, or a tab); this literal contains #{byte_name(b)} at byte #{i}")
        end
      end
      if node.is_a?(Prism::InterpolatedStringNode)
        first = node.parts.first
        last = node.parts.last
        redirect_edge_whitespace(first, :first) if first.is_a?(Prism::StringNode)
        redirect_edge_whitespace(last, :last) if last.is_a?(Prism::StringNode)
      else
        redirect_edge_whitespace(node, :first)
        redirect_edge_whitespace(node, :last)
      end
    end

    # The Location header carries no leading or trailing whitespace: a literal that starts or ends with a
    # space or tab is refused, while interior spaces stay legal. An interpolation at either end contributes
    # a number or a bool, so only a literal part at that end is checked.
    def redirect_edge_whitespace(part, side)
      bytes = part.unescaped.b.bytes
      b = side == :first ? bytes.first : bytes.last
      return unless b == 0x20 || b == 0x09

      bad(part, "a redirect path becomes the Location header, which carries no leading or trailing whitespace; this literal #{side == :first ? 'starts' : 'ends'} with #{b == 0x20 ? 'a space' : 'a tab'}")
    end

    # The offending byte in that refusal: the escape where it has one, hex otherwise.
    def byte_name(b)
      named = { 0x00 => "\\0", 0x0a => "\\n", 0x0d => "\\r" }[b]
      named ? "`#{named}`" : format("`0x%02x`", b)
    end

    # The optional `status:` keyword of a redirect: one of REDIRECT_STATUSES, written as an integer literal.
    def redirect_args(node, args)
      rest = args.dup
      hash = rest.last.is_a?(Prism::KeywordHashNode) ? rest.pop : nil
      return [rest, nil] unless hash

      allowed = REDIRECT_STATUSES.join(', ')
      status = nil
      hash.elements.each do |el|
        unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          bad(el, "unsupported #{nodename(el)} in redirect (write `status: 302`)")
        end
        key = el.key.unescaped.to_sym
        bad(el, "unknown keyword `#{key}:` for redirect (allowed: status)", word: key, from: [:status]) unless key == :status
        bad(el, "duplicate keyword `status:`") if status
        arg = el.value
        bad(arg, "a redirect status must be one of #{allowed}") unless arg.is_a?(Prism::IntegerNode)
        bad(arg, "a redirect status must be one of #{allowed}, got #{arg.value}") unless REDIRECT_STATUSES.include?(arg.value)
        status = "::axum::http::StatusCode::from_u16(#{arg.value}).unwrap()"
        helper_status(arg, "redirect")
      end
      [rest, status]
    end

    # `halt(status, body)`: stop here with that status and that body. `halt(status)` sends the status with an
    # empty body, as Sinatra's `halt 404` does.
    def halt_response(node, args, env)
      bad(node, "halt takes a status, and optionally a body") unless args.size.between?(1, 2)
      code = status_code(args[0])
      body =
        if args.size == 2
          v = expr(args[1], env)
          bad(args[1], "a secret cannot be written into a response; pass it to a binding or rust_fn function") if v[1] == :secret
          unless %i[str string i32 i64 f64 bool].include?(v[1])
            bad(args[1], "a halt body is written from a string or a number, got #{TypeNames.display(v[1])}")
          end
          "#{wrap(v)}.to_string()"
        else
          "String::new()"
        end
      ["{ let mut __halted = #{INTO}(#{body}); *__halted.status_mut() = #{code}; __halted }", :response, false]
    end

    # `render :signup, locals: { name: params[:name] }`: answer with views/signup.html (or the folder
    # `set :views` names), read here, at compile time, and compiled into the emitted Rust -- no template and
    # no `.html` file reaches the crate, which is what separates a view from `static` (which copies a file
    # for the running service to serve). `layout: :app` wraps the view in another view, which writes the
    # view's markup where its `{{ yield }}` is; `set :layout, :app` gives every render that layout, and
    # `layout: nil` opts out of it.
    #
    # The locals are exactly the names the markers read, minus `yield`, in both directions: the markers are
    # right here, so a marker that reads no local and a local no marker reads are both refused, with the name.
    # A `{{ partial :name, ... }}` marker reads its call's arguments instead, and the call's arguments are
    # exactly the names the partial's own markers read (expand_partial): the two scopes stay separate.
    def render_response(node, args, env)
      name, kw = render_args(node, args)
      status = kw.key?(:status) ? status_literal(kw[:status], "render's status") : nil
      helper_status(kw[:status], "render") if status
      content_type = kw.key?(:content_type) ? content_type_literal(kw[:content_type], "render's content_type") : nil
      helper_content_type(kw[:content_type], "render") if content_type
      dir = @flags["views"] || Views::DEFAULT_DIR
      folder = Views.folder(@path)
      report = ->(message) { bad(node, message) }
      view = view_file(name, dir, folder, report)
      layout = render_layout(kw, dir, folder, report)
      locals = render_locals(node, kw[:locals], env)
      check_view_locals(node, view, layout, locals)
      check_view_yield(node, view, layout)
      markup = view_expr(node, view, layout, locals, dir, folder, report)
      # A view is HTML, so a render answers through axum's Html like html(...) does. The markup is a String
      # either way -- a format!, or the block that binds the child when a layout wraps the view -- so it goes
      # to Html as it is: no `.to_string()`, and no parentheses around a block expression, which rustc would
      # report under -Dwarnings. A `status:` rides on the value as a (StatusCode, Html) pair, and a
      # `content_type:` as a CONTENT_TYPE header on the response the pair becomes; the status, the headers
      # and the errors 400 a body sets are applied by the emitter around whatever the body ended in
      # (emit.rb: response_expr).
      body = "::axum::response::Html(#{markup})"
      body = "(#{status}, #{body})" if status
      [with_content_type("#{INTO}(#{body})", content_type), :response, false]
    end

    # The arguments of a render: the view's name, then the optional `locals:`, `layout:`, `status:` and
    # `content_type:` keywords.
    def render_args(node, args)
      rest = args.dup
      hash = rest.last.is_a?(Prism::KeywordHashNode) ? rest.pop : nil
      positional = rest.last.is_a?(Prism::HashNode) ? rest.pop : nil
      bad(positional, "`render` takes its keywords, not a positional hash: write `locals: { ... }`") if positional
      bad(node, "render takes the view's name, as in `render :signup`") unless rest.size == 1
      name = rest[0]
      unless name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
        bad(name, "render names a view with a symbol (:signup) or a string (\"signup\"), not #{nodename(name)}")
      end
      kw = {}
      (hash ? hash.elements : []).each do |el|
        unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          bad(el, "unsupported #{nodename(el)} in render (write `locals: { ... }`, `layout: :app`, `status: 401` or `content_type: \"text/html\"`)")
        end
        key = el.key.unescaped.to_sym
        unless RENDER_KEYWORDS.include?(key)
          bad(el, "unknown keyword `#{key}:` for render (allowed: #{RENDER_KEYWORDS.join(', ')})",
              word: key, from: RENDER_KEYWORDS)
        end
        bad(el, "duplicate keyword `#{key}:`") if kw.key?(key)
        kw[key] = el.value
      end
      [name.unescaped, kw]
    end

    # One view file, read and parsed. Every view the compiler reads is an input of the compile, so a driver
    # can print it (--print-inputs) and watch it like any other source of the build. `report` raises in the
    # DSL file, at the declaration that named the view.
    def view_file(name, dir, folder, report)
      view = Views.load(name, dir, folder, bad: report)
      (@flags["view_inputs"] ||= {})[view.real] = true
      view
    end

    # The layout a render gets: `layout:` when it is written (`layout: nil` is the opt-out), the one
    # `set :layout` declared otherwise. The reader read and checked the declared one when it was declared,
    # so its file is known to be a layout; a `layout:` written here is read now.
    def render_layout(kw, dir, folder, report)
      if kw.key?(:layout)
        return nil if kw[:layout].is_a?(Prism::NilNode)

        arg = kw[:layout]
        unless arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
          bad(arg, "`layout:` names a view with a symbol (:app) or a string, or `nil` to render with no layout")
        end
        return view_file(arg.unescaped, dir, folder, report)
      end
      declared = @flags["layout"]
      declared && view_file(declared, dir, folder, report)
    end

    # The `locals:` hash: one entry per name a marker reads. A value is any expression the body language
    # allows, written by html_value's own rules, so there is nothing new to learn to pass one: a local takes
    # what h(...) or an interpolation takes.
    def render_locals(node, hash, env)
      return {} if hash.nil?
      unless hash.is_a?(Prism::HashNode) || hash.is_a?(Prism::KeywordHashNode)
        bad(hash, "`locals:` takes a hash of names and values, such as `locals: { name: params[:name] }`")
      end
      locals = {}
      hash.elements.each do |el|
        bad(el, "unsupported #{nodename(el)} in `locals:` (write `name: value`)") unless el.is_a?(Prism::AssocNode)
        key = el.key
        name = case key
               when Prism::SymbolNode, Prism::StringNode then key.unescaped
               else bad(key, "a local is named by the marker that reads it, so its name is a symbol or a string literal")
               end
        unless name.match?(Views::NAME)
          bad(key, "`#{name}` cannot be a local's name: a marker spells it literally, so the name is letters, " \
                   "digits and _, and does not start with a digit")
        end
        bad(el, "duplicate local `#{name}`") if locals.key?(name)
        if el.value.is_a?(Prism::NilNode)
          bad(el.value, "`#{name}: nil` gives the view nothing to write; a marker writes a string, a number or true/false")
        end
        locals[name] = [el.value, expr(el.value, env)]
      end
      locals
    end

    # The locals rule: what a render passes is exactly the union of the view's and its layout's markers, minus
    # `yield`. Both directions are refused with the name -- a marker that reads nothing, and a value nothing
    # reads -- because either one is a mistake the compiler can see from here.
    def check_view_locals(node, view, layout, locals)
      [view, layout].compact.each do |v|
        next unless v.args

        bad(node, "#{v.rel}: `{% args %}` declares a partial's arguments, and this file is #{v.equal?(view) ? "a view rendered directly" : "a layout"}; " \
                  "a view takes `locals:` and a layout takes the view's, so drop the `{% args %}`")
      end
      wanted = (view.names + (layout ? layout.names : [])).uniq
      if (missing = wanted - locals.keys).any?
        name = missing.first
        where = view.names.include?(name) ? view : layout
        at = view_name_line(where, name)
        reader = Views.flat(where.segments).find { |s| Views.reads(s).include?(name) }
        what =
          case reader["kind"]
          when "partial" then "a `{{ partial }}` argument reads the local `#{name}`"
          when "for" then "`{% for #{reader['var']} in #{name} %}` reads a list local"
          when "if" then "`{% if #{name} %}` reads a local"
          else "`{{ #{name} }}` reads a local"
          end
        given = locals.empty? ? "" : " (this render passes #{locals.keys.join(', ')})"
        bad(node, "#{at ? "#{where.rel}:#{at}" : where.rel}: #{what}, so the render must pass it: " \
                  "`locals: { #{name}: ... }`#{given}")
      end
      extra = locals.keys - wanted
      return if extra.empty?

      reads = wanted.empty? ? "has no markers, so this view takes no locals" : "reads #{wanted.join(', ')}"
      bad(node, "`#{extra.first}` is passed to this render but no marker reads it; #{view.rel} #{reads}")
    end

    # `{{ yield }}` is the layout's child output, already-built markup that is never re-escaped: a view
    # rendered directly has no child, so a yield in one is refused. A layout that never yields would drop the
    # view it wraps, which is refused too rather than silently answering a page without it.
    def check_view_yield(node, view, layout)
      if layout.nil?
        return unless view.yields

        line = view.segments.find { |s| s["kind"] == "yield" }["line"]
        bad(node, "#{view.rel}:#{line}: `{{ yield }}` is a layout's child output, and this render has no " \
                  "layout to put it in; name one (`set :layout, :app` or `layout: :app`), or drop the marker")
      end
      return if layout.yields

      bad(node, "#{layout.rel} has no `{{ yield }}`, so the layout would drop the view it wraps; a layout " \
                "writes the view where its `{{ yield }}` is")
    end

    # The Rust text of a render: a format! whose literal runs are the view's own bytes and whose arguments are
    # the markers' values, in marker order. A layout is compiled around the view: the child is built first,
    # bound to `__yield`, and written where the layout's `{{ yield }}` is. A partial is inlined into its
    # caller's format! (view_parts), so rendering one is not a call. Every literal `{`/`}` is doubled, as in an
    # interpolated string (Body#interp), because format! reads them.
    def view_expr(node, view, layout, locals, dir, folder, report)
      child = view_format(node, view, locals, dir, folder, report)
      return child unless layout

      outer = view_format(node, layout, locals, dir, folder, report, child: "__yield")
      "{ let __yield = #{child}; #{outer} }"
    end

    # One view's format!: the pieces view_parts writes, wrapped in the call. `yield` takes the child
    # expression, the one marker that is not a local; every other marker (and a partial's every marker) is
    # written by html_value, so `{{ x }}` and `{{ x|raw }}` are exactly `h(x)` and `raw(x)`.
    def view_format(node, view, locals, dir, folder, report, child: nil, chain: [])
      fmt, vals = view_parts(node, view, locals, child, chain, dir, folder, report)
      "format!(#{AxumDsl.rstr(fmt)}#{vals.map { |v| ", #{v}" }.join})"
    end

    # The literal runs and argument expressions of one view's format!, before the call is written around them.
    # A partial's own parts are spliced in place: its text becomes part of the caller's literal and its markers
    # become more of the caller's arguments, resolved against the call's arguments. `chain` is the partials
    # being expanded above this one, so a partial that reaches itself is refused instead of expanded.
    def view_parts(node, view, locals, child, chain, dir, folder, report)
      segment_parts(node, view, view.segments, locals, child, chain, dir, folder, report)
    end

    # The pieces of a run of segments: a view's own, or the body of one of its loops.
    def segment_parts(node, view, segments, locals, child, chain, dir, folder, report)
      fmt = +""
      vals = []
      segments.each do |seg|
        case seg["kind"]
        when "text"
          fmt << seg["text"].gsub("{", "{{").gsub("}", "}}")
        when "yield"
          fmt << "{}"
          vals << child
        when "partial"
          p_fmt, p_vals = expand_partial(node, view, seg, locals, chain, dir, folder, report)
          fmt << p_fmt
          vals.concat(p_vals)
        when "for"
          fmt << "{}"
          vals << view_loop(node, view, seg, locals, chain, dir, folder, report)
        when "if"
          fmt << "{}"
          vals << view_if(node, view, seg, locals, chain, dir, folder, report)
        when "csrf"
          unless @flags["csrf"]
            report.call("#{view.rel}:#{seg['line']}: `{{ csrf_token }}` needs `use_layer :csrf` at the top " \
                        "level of the file: that layer mints the token and checks it on a write")
          end
          unless REQUEST_KINDS.include?(@kind)
            report.call("#{view.rel}:#{seg['line']}: `{{ csrf_token }}` reads the request, and the " \
                        "`#{@kind}` filter runs without one; render it from a route or a `before` filter")
          end
          need(:csrf)
          fmt << "{}"
          vals << "__csrf.0.as_str()"
        when "asset"
          mounts = @flags["asset_mounts"].to_a
          if mounts.empty?
            report.call("#{view.rel}:#{seg['line']}: `{{ asset_path #{seg['name'].inspect} }}` needs " \
                        "a `static \"/assets\", dir: \"public\", digest: true` mount: the digest is what the " \
                        "path names")
          end
          if mounts.size > 1
            report.call("#{view.rel}:#{seg['line']}: `asset_path` resolves against one fingerprinted mount, " \
                        "and this file has #{mounts.size} (#{mounts.map(&:inspect).join(', ')}); give the " \
                        "file one mount")
          end
          url = (@flags["asset_urls"] || {}).dig(mounts[0], seg["name"])
          unless url
            known = ((@flags["asset_urls"] || {})[mounts[0]] || {}).keys.sort
            report.call("#{view.rel}:#{seg['line']}: `asset_path #{seg['name'].inspect}` names no file " \
                        "under the #{mounts[0].inspect} mount (files: #{known.join(', ')}); only a copied file " \
                        "has a fingerprinted path")
          end
          fmt << "{}"
          vals << AxumDsl.rstr(url)
        else
          value_node, v = seg["var"] ? loop_marker(view, seg, locals, report) : locals.fetch(seg["name"])
          spelling = seg["var"] ? (seg["field"] ? "#{seg['name']}.#{seg['field']}" : seg["name"]) : seg["name"]
          if seg["kind"] == "sanitize" && !%i[str string].include?(v[1])
            report.call("#{view.rel}:#{seg['line']}: `{{ #{spelling}|sanitize }}` needs a string, got " \
                        "#{TypeNames.display(v[1])}; |sanitize cleans an HTML string (an Action Text body), and " \
                        "`{{ #{spelling} }}` or `{{ #{spelling}|raw }}` writes any other value")
          end
          fmt << "{}"
          what = { "raw" => :raw, "sanitize" => :sanitize }.fetch(seg["kind"], :h)
          vals << html_value(value_node, v, what)
        end
      end
      [fmt, vals]
    end

    # One `{% for x in xs %}`: a block that builds the loop's text and is spliced into the caller's format! as
    # one argument, `{ let mut __s = String::new(); for __it_x in &xs { __s.push_str(&format!(...)); } __s }`.
    # The loop's markers are the body's own (segment_parts), resolved against the locals plus the loop variable,
    # whose Rust name is dunder-prefixed so a body that never reads it is no unused-variable warning. The loop
    # variable is a third element on its local's pair -- the list's element type -- which is what tells a marker
    # of it from an ordinary local. It is a new name: a local or an outer loop variable of the same name is refused.
    def view_loop(node, view, seg, locals, chain, dir, folder, report)
      where = "#{view.rel}:#{seg['line']}"
      var = seg["var"]
      report.call("#{where}: the loop variable `#{var}` is already a local; a loop variable is a new name") if locals.key?(var)
      list, type, label = loop_list(where, seg, locals, report)
      elem = LISTS[type] || (struct_list?(type) ? list_elem(type) : nil)
      unless elem
        report.call("#{where}: `#{label}` is #{TypeNames.display(type)}, not a list; `{% for #{var} in #{label} %}` " \
                    "loops over a list of strings, integers, records or params objects")
      end
      item = "__it_#{var}"
      shown = elem == :string ? ["#{item}.as_str()", :str, true] : [item, elem, true]
      fmt, vals = segment_parts(node, view, seg["body"], locals.merge(var => [node, shown, elem]), nil, chain, dir, folder, report)
      text =
        if vals.empty?
          AxumDsl.rstr(fmt.gsub("{{", "{").gsub("}}", "}"))
        else
          "&format!(#{AxumDsl.rstr(fmt)}#{vals.map { |v| ", #{v}" }.join})"
        end
      "{ let mut __s = String::new(); for #{item} in &#{list} { __s.push_str(#{text}); } __s }"
    end

    # One `{% if name %}`: a block that builds the taken branch's text and is spliced into the caller's
    # format! as one argument, as a loop is:
    # `{ let mut __s = String::new(); if cond { __s.push_str(&format!(...)); } else { ... } __s }`.
    # The condition is a bool, or a nil-able value with Ruby's truthiness (nil and false are false; for a
    # nil-able bool, `Some(false)` is false too). A nil-able name is narrowed inside the taken branch: the
    # branch is guarded by `if let Some(__if_name) = ...`, and the name resolves to that binding there, so a
    # `{{ name }}`, a `{{ name.field }}`, a `{% for x in name %}` or a partial argument reads the value and
    # never an `unwrap` that could panic. A field narrows the same way under its spelled key (`x.field`),
    # which is sound because a field has no binding of its own to shadow.
    def view_if(node, view, seg, locals, chain, dir, folder, report)
      where = "#{view.rel}:#{seg['line']}"
      cond, narrowed, key = if_condition(where, seg, locals, report)
      branch = narrowed ? locals.merge(key => [node, narrowed]) : locals
      taken = view_branch(node, view, seg["then"], branch, chain, dir, folder, report)
      otherwise = view_branch(node, view, seg["else"], locals, chain, dir, folder, report)
      # An if that writes nothing either way has no accumulator to mutate (and no `mut` warning to raise).
      return "String::new()" if taken.empty? && otherwise.empty?

      else_text = seg["else"].empty? ? "" : " else { #{otherwise} }"
      "{ let mut __s = String::new(); if #{cond} { #{taken} }#{else_text} __s }"
    end

    # One branch of an `{% if %}`: the pushes that build its text, or the empty string when it writes none.
    # It is built as a loop's body is (segment_parts), so a nested marker, partial, loop or `{% if %}` is
    # just more of it.
    def view_branch(node, view, segments, locals, chain, dir, folder, report)
      fmt, vals = segment_parts(node, view, segments, locals, nil, chain, dir, folder, report)
      return "" if fmt.empty?

      text =
        if vals.empty?
          AxumDsl.rstr(fmt.gsub("{{", "{").gsub("}}", "}"))
        else
          "&format!(#{AxumDsl.rstr(fmt)}#{vals.map { |v| ", #{v}" }.join})"
        end
      "__s.push_str(#{text});"
    end

    # The Rust condition of an `{% if %}`, the pair the taken branch reads the name as (or nil), and the key
    # the branch resolves that name through: the local's own name, or `x.field` for a narrowed loop field.
    # The pair is [code, type, atomic], the shape segment_parts resolves a marker through; `__if_...` begins
    # with an underscore, so a branch that never reads it raises no unused-variable warning.
    def if_condition(where, seg, locals, report)
      name = seg["name"]
      pair = locals.fetch(name)
      type, expr =
        if seg["var"]
          seg["field"] ? [loop_field_type(where, name, pair[2], seg["field"], report), "#{pair[1][0]}.#{seg['field']}"]
                       : [pair[2], pair[1][0]]
        else
          [pair[1][1], pair[1][0]]
        end
      shown = seg["field"] ? "#{name}.#{seg['field']}" : name
      value = wrap([expr, type, seg["var"] && seg["field"] ? true : pair[1][2]])
      return [value, nil, name] if type == :bool

      inner = OPT[type]
      unless inner
        report.call("#{where}: `{% if #{shown} %}` reads #{TypeNames.display(type)}, and a condition is a `bool` " \
                    "or a nil-able value (nil is false, everything else true); a view writes one of two " \
                    "branches, so it has no comparison")
      end
      if inner == :bool
        # Ruby truthiness: Some(false) is false, so the branch tests the value, not only that it is there.
        return ["matches!(#{value}, Some(true))", ["true", :bool, true], shown]
      end
      guard = "#{value}.is_some()"
      binding = seg["field"] ? "__if_#{name}_#{seg['field']}" : "__if_#{name}"
      source =
        case inner
        when :string then "#{value}.as_deref()"
        when :strs, :i64s, :f64s then "#{value}.as_ref()"
        when :i64, :i32, :f64 then value
        end
      return [guard, nil, shown] unless source

      shadow =
        case inner
        when :string then [binding, :str, true]
        when :strs, :i64s, :f64s then ["*#{binding}", inner, false]
        else [binding, inner, true]
        end
      ["let Some(#{binding}) = #{source}", shadow, shown]
    end

    # The list a loop runs over: [its Rust expression, its type, its name for a message]. A local is one of the
    # render's (or the partial's arguments); `x.field` is a field of the enclosing loop variable `x`.
    def loop_list(where, seg, locals, report)
      pair = locals.fetch(seg["over"])
      return [wrap(pair[1]), pair[1][1], seg["over"]] unless seg["over_field"]

      spelled = "#{seg['over']}.#{seg['over_field']}"
      return [wrap(narrowed[1]), narrowed[1][1], spelled] if (narrowed = locals[spelled])

      type = loop_field_type(where, seg["over"], pair[2], seg["over_field"], report)
      ["#{pair[1][0]}.#{seg['over_field']}", type, spelled]
    end

    # The fields of a loop variable's element, [[name, type]] and the name the element goes by in a message:
    # a record's or a params object's. Nil for a string or an integer, which has none.
    def loop_fields(elem)
      if record?(elem)
        name = opaque_name(elem)
        [CompositeTypes::Opaque.fields(name).map { |f| [f[0], f[1].to_sym] }, name]
      elsif elem.to_s.start_with?("struct:")
        name = elem.to_s.delete_prefix("struct:")
        st = (@structs + @outputs).find { |p| p["name"] == name } or return nil
        [st["fields"].map { |f| [f["name"], field_type(f)] }, name]
      end
    end

    # The type of `var.field` for a loop variable whose elements are `elem`, refused with the field list as
    # body field access is.
    def loop_field_type(where, var, elem, field, report)
      fields, owner = loop_fields(elem)
      if fields.nil?
        report.call("#{where}: `#{var}` is #{TypeNames.display(elem)}, which has no fields; write `{{ #{var} }}` " \
                    "for an element of a list of strings or integers, and `{{ #{var}.field }}` for a record's field")
      end
      found = fields.find { |n, _| n == field.to_s }
      report.call("#{where}: #{owner} has no field `#{field}` (its fields: #{fields.map(&:first).join(', ')})") unless found
      found[1]
    end

    # A loop variable's marker: `{{ x }}` for a list of strings or integers, `{{ x.field }}` for a record or a
    # params object, as the [node, [code, type, atomic]] pair html_value writes.
    def loop_marker(view, seg, locals, report)
      where = "#{view.rel}:#{seg['line']}"
      return locals["#{seg['name']}.#{seg['field']}"] if seg["field"] && locals.key?("#{seg['name']}.#{seg['field']}")

      pair = locals.fetch(seg["name"])
      loop_scalar(pair[0], where, seg["name"], pair, seg["field"], report)
    end

    # The value of loop variable `var` (`field` nil) or of `var.field`, as html_value writes it: refused when the
    # element is not the kind this spelling reads, when the field is nil-able (a marker never writes a nil: the
    # body is where a missing value gets its default) and when it is not a string, a number or true/false.
    def loop_scalar(node, where, var, pair, field, report)
      elem = pair[2]
      if field.nil?
        unless LISTS.value?(elem)
          fields, owner = loop_fields(elem)
          shown = fields ? "a #{owner} row; write one of its fields: #{fields.map { |n, _| "{{ #{var}.#{n} }}" }.join(', ')}" : TypeNames.display(elem)
          report.call("#{where}: `#{var}` is #{shown}, which a marker cannot write")
        end
        return [pair[0], pair[1]]
      end
      type = loop_field_type(where, var, elem, field, report)
      if OPT.key?(type)
        report.call("#{where}: `#{var}.#{field}` is optional and may be nil, and a marker never writes a nil; " \
                    "supply a value for it in the body (`|| default`) before the list reaches the view, or make the field required")
      end
      unless %i[string i32 i64 f64 bool].include?(type)
        report.call("#{where}: `#{var}.#{field}` is #{TypeNames.display(type)}; a marker writes a string, a number or true/false")
      end
      [node, ["#{pair[1][0]}.#{field}", type, true]]
    end

    # Inline one `{{ partial :name, ... }}`: read the partial (a compile-time input, like a view), check the
    # call against the names its markers read, resolve each argument's value in the caller's locals, then
    # splice the partial's own pieces into the caller's format!. `chain` catches a partial that reaches itself
    # directly or through a chain before the recursion can run away.
    def expand_partial(node, caller, seg, locals, chain, dir, folder, report)
      partial = view_file(seg["name"], dir, folder, report)
      where = "#{caller.rel}:#{seg['line']}"
      if chain.include?(partial.rel)
        report.call("#{where}: `{{ partial :#{seg['name']} }}` is a cycle: #{(chain + [partial.rel]).join(' -> ')}; " \
                    "a partial is inlined into its caller, so a partial that reaches itself would never finish expanding")
      end
      if partial.yields
        line = partial.segments.find { |s| s["kind"] == "yield" }["line"]
        report.call("#{where}: #{partial.rel}:#{line} writes `{{ yield }}`, but a partial is inlined into its " \
                    "caller and has no child of its own; `{{ yield }}` belongs only in a layout")
      end
      args = seg["args"]
      arg_locals = {}
      args.each { |a| arg_locals[a["name"]] = partial_arg(node, caller, seg, a, locals, report) }
      check_partial_locals(node, where, partial, args.map { |a| a["name"] })
      # An omitted argument the partial's `{% args %}` defaults takes the default literal, in the shapes partial_arg builds.
      (partial.args || []).each do |d|
        next if d["default"].nil? || arg_locals.key?(d["name"])

        arg_locals[d["name"]] = partial_arg(node, caller, seg, { "name" => d["name"], "value" => d["default"] }, locals, report)
      end
      view_parts(node, partial, arg_locals, nil, chain + [partial.rel], dir, folder, report)
    end

    # One partial argument's value, resolved in the caller's scope: a literal is its own Rust value, and a
    # bare name is one of the caller's locals -- the same value a caller marker of that name would write. The
    # partial's markers read only these, so a partial cannot reach any other local of its caller.
    def partial_arg(node, caller, seg, arg, locals, report)
      value = arg["value"]
      case value["kind"]
      when "string" then [node, [AxumDsl.rstr(value["text"]), :str, true]]
      when "int" then [node, [value["text"], :i64, !value["text"].start_with?("-")]]
      when "bool" then [node, [value["text"], :bool, true]]
      else
        spelled = "#{value['text']}.#{value['field']}"
        return locals[spelled] if value["var"] && value["field"] && locals.key?(spelled)

        pair = locals[value["text"]]
        unless pair
          report.call("#{caller.rel}:#{seg['line']}: `{{ partial :#{seg['name']}, #{arg['name']}: #{value['text']} }}` " \
                      "reads a local the render does not pass")
        end

        value["var"] ? loop_scalar(node, "#{caller.rel}:#{seg['line']}", value["text"], pair, value["field"], report) : pair
      end
    end

    # The locals rule for one partial call: the arguments passed are exactly the names the partial's markers
    # read, refused in both directions with the name, as a render's `locals:` is against its view. A partial
    # is a second scope, so this is a rule of the call and not of the render around it.
    def check_partial_locals(node, where, partial, keys)
      wanted = partial.names
      defaulted = (partial.args || []).reject { |a| a["default"].nil? }.map { |a| a["name"] }
      if (missing = wanted - keys - defaulted).any?
        name = missing.first
        at = view_name_line(partial, name)
        given = keys.empty? ? "" : " (this call passes #{keys.join(', ')})"
        bad(node, "#{where}: #{at ? "#{partial.rel}:#{at}" : partial.rel}: `{{ #{name} }}` reads an argument, " \
                  "so the partial call must pass one: `#{name}: ...`#{given}")
      end
      extra = keys - wanted
      return if extra.empty?

      reads = wanted.empty? ? "has no markers, so it takes no arguments" : "reads #{wanted.join(', ')}"
      bad(node, "#{where}: `#{extra.first}` is passed to #{partial.rel} but no marker reads it; #{partial.rel} #{reads}")
    end

    # The line of the segment in `view` that reads `name`, for a refusal that points into the file. A partial
    # segment reads the name as one of its argument values, so it is found there too.
    def view_name_line(view, name)
      seg = Views.flat(view.segments).find { |s| Views.reads(s).include?(name) }
      seg && seg["line"]
    end

    # A status as axum's StatusCode: an integer literal, or one of the Sinatra symbols in STATUS_CODES.
    def status_code(arg)
      case arg
      when Prism::IntegerNode
        bad(arg, "a status must be between 100 and 599, got #{arg.value}") unless arg.value.between?(100, 599)
        "::axum::http::StatusCode::from_u16(#{arg.value}).unwrap()"
      when Prism::SymbolNode
        status_symbol(arg)
      else
        bad(arg, "a status is an integer (404) or a symbol (:not_found)")
      end
    end

    # The axum StatusCode enum variant a Sinatra status symbol names.
    def status_symbol(arg)
      name = arg.unescaped.to_sym
      unless STATUS_CODES.key?(name)
        bad(arg, "`#{name}` is not a status symbol (use one of #{STATUS_CODES.keys.join(', ')})", word: name.to_s, from: STATUS_CODES.keys.map(&:to_s))
      end
      "::axum::http::StatusCode::#{STATUS_CODES.fetch(name)}"
    end

    # `etag(value)` as a statement: the ETag of the response this route returns, a string computed at run
    # time (a helper, an interpolation, a query field). The emitter sets it on the final response and, when
    # the request's If-None-Match lists it, answers 304 with no body. Route bodies only; `headers` stays
    # literal by design, and the body may set this once.
    def etag_stmt(node, args, env)
      bad(node, "etag takes one string value, such as `etag(\"\\\"v1\\\"\")`") unless args.size == 1
      bad(node, "`etag(...)` is a statement of a route body") unless @kind == :route
      bad(node, "a body sets `etag(...)` once") if @etag
      v = expr(args[0], env)
      bad(args[0], "etag's value is a string, got #{TypeNames.display(v[1])}") unless %i[str string].include?(v[1])
      @etag = "#{v[0]}.to_string()"
      need(:headers)
      []
    end

    # `status(201)` / `status(:created)` as a statement: the status of the response this body returns. It travels
    # in the IR ("status") and the emitter sets it on the response the body produced, whatever built it, so a
    # `status(...)` in a body that also ends in `halt(...)` overrides the status `halt` named.
    def status_stmt(node, args)
      bad(node, "status takes one argument, an integer (201) or a symbol (:created)") unless args.size == 1
      @status = status_code(args[0])
      if @helper_status
        hnode, hwhat = @helper_status
        bad(node, "this body uses `status(...)` here and `#{hwhat}`'s `status:` at line #{hnode.location.start_line}: use one; the statement applies to the final response, a helper's status: belongs to that value")
      end
      @status_site = node
      []
    end

    # `content_type(:json)` as a statement: the content type of the response. It is only meaningful inside a
    # `before do ... end` filter, where it is the default for every route that filter precedes (the reader
    # refuses it anywhere else); the type it names travels in the compiled body, for the emitter to apply.
    # A helper's `content_type:` (see helper_content_type) may not meet it in one body, as with status.
    def content_type_stmt(node, args)
      bad(node, "content_type takes one argument") unless args.size == 1
      arg = args[0]
      unless arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
        bad(arg, "content_type names a type with a symbol (:json) or a string")
      end
      name = arg.unescaped.to_sym
      unless CONTENT_TYPES.key?(name)
        bad(arg, "`#{name}` is not a content type the DSL knows (use one of #{CONTENT_TYPES.keys.join(', ')})", word: name.to_s, from: CONTENT_TYPES.keys.map(&:to_s))
      end
      @content_type = name
      if @helper_content_type
        hnode, hwhat = @helper_content_type
        bad(node, "this body uses `content_type(...)` here and `#{hwhat}`'s `content_type:` at line #{hnode.location.start_line}: use one; the statement sets the response default for the routes that follow, a helper's content_type: belongs to that value")
      end
      @content_type_site = node
      []
    end

    # A header name is an HTTP token: letters, digits and the punctuation below. The generated crate
    # lowercases it, because http's HeaderName::from_static wants a lowercase name.
    HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
    # A header value may carry any octet except the control characters; a tab may appear, but a space or a
    # tab at either end may not (see headers_stmt).
    HEADER_VALUE = /\A[^\x00-\x08\x0A-\x1F\x7F]*\z/

    # `headers "Cache-Control" => "public, max-age=60"` as a statement: header lines the response this body
    # produces carries, beside `status(...)` and `content_type(...)`. A name and a value are written out, so
    # the generated crate carries them as static text (HeaderName::from_static and HeaderValue::from_static)
    # and inserting one cannot fail while the service runs; a name or a value that no HTTP header may carry
    # is refused here instead. In a `before` filter that passes the request on, the headers go on the
    # response the route (or the file service mounted beside it) answers with.
    def headers_stmt(node, args)
      unless args.size == 1
        bad(node, "headers takes one hash of header names and values, such as `headers \"Cache-Control\" => \"no-store\"`")
      end
      hash = args[0]
      # A braceless `headers "A" => "b"` is a KeywordHashNode; only `headers({"A" => "b"})` is a HashNode.
      unless hash.is_a?(Prism::HashNode) || hash.is_a?(Prism::KeywordHashNode)
        bad(hash, "headers takes a hash written `headers \"Cache-Control\" => \"no-store\", \"X-Content-Type-Options\" => \"nosniff\"`; a header name is a string literal, not a symbol or a variable")
      end
      bad(node, "headers takes at least one header") if hash.elements.empty?
      given = []
      hash.elements.each do |el|
        bad(el, "unsupported #{nodename(el)} in headers (use `\"Name\" => \"value\"`)") unless el.is_a?(Prism::AssocNode)
        name = el.key
        value = el.value
        bad(name, "a header name is a string literal, such as \"Cache-Control\"") unless name.is_a?(Prism::StringNode)
        bad(value, "the value of header #{name.unescaped.inspect} is a string literal") unless value.is_a?(Prism::StringNode)
        n = name.unescaped
        unless n.match?(HEADER_NAME)
          bad(name, "#{n.inspect} is not a header name; a name is letters, digits and !#$%&'*+-.^_`|~")
        end
        v = value.unescaped
        bad(value, "the value of header #{n.inspect} cannot carry a control character") unless v.match?(HEADER_VALUE)
        if v.start_with?(" ", "\t") || v.end_with?(" ", "\t")
          bad(value, "the value of header #{n.inspect} cannot start or end with a space or a tab")
        end
        bad(el, "duplicate header #{n.inspect}") if given.any? { |g| g[0].casecmp?(n) }
        given << [n, v]
      end
      @headers = given
      []
    end

    # --- sessions: cookies, current, request values and Bcrypt (docs/sessions.md) -------------------------------

    # The calls that make a value from no arguments.
    REQUEST_VALUES = %i[random_token request_ip user_agent].freeze
    # The bodies that see the request: a route, a `before` filter and a `current`. `not_found` and `error` run
    # without it, and a helper or a binding computes a value from its arguments.
    REQUEST_KINDS = %i[route before current].freeze
    SAME_SITE = { lax: "Lax", strict: "Strict", none: "None" }.freeze
    # The keywords set_cookie takes: the attributes, then `signed:`/`format:` (a plain cookie has no format).
    COOKIE_KEYWORDS = %i[http_only same_site secure permanent max_age signed format].freeze
    # The keywords cookie (a read) takes. `format:` applies only to a signed cookie.
    COOKIE_READ_KEYWORDS = %i[signed format].freeze
    # Rails' `permanent` cookie: twenty years (a Rails year is 365.2425 days), as a Max-Age in seconds.
    PERMANENT_MAX_AGE = 20 * 31_556_952
    # The functions of the built-in Bcrypt module, and how many arguments each takes.
    BCRYPT_FNS = { verify: 2, hash: 1 }.freeze

    # The request values a body reads are bound by the emitter under fixed names (__headers, __peer, __currents);
    # what a body used travels in the IR ("request"), so a route adds exactly the extractors it needs.
    def need(*what) = what.each { |w| @needs[w] = true }

    # A read of the request: refused where there is no request to read.
    def request_only!(node, what)
      return if REQUEST_KINDS.include?(@kind)

      place = if @helper then "a helper"
              elsif %i[not_found error].include?(@kind) then "the `#{@kind}` filter, which runs without the request"
              else "a binding"
              end
      bad(node, "#{what} reads the request: use it in a route, a `before` filter or a `current` body, not in #{place}")
    end

    def cookies_declared!(node, what)
      return if @flags["cookies"]

      bad(node, "#{what} needs `cookies secret: :setting_name` at the top level of the file: it names the key the cookies are signed with")
    end

    def cookie_name(arg, what)
      bad(arg, "#{what} names the cookie with a symbol, such as :session_token") unless arg.is_a?(Prism::SymbolNode)
      name = arg.unescaped
      bad(arg, "#{what}: the cookie name `#{name}` must be snake_case") unless name.match?(SNAKE)
      name
    end

    # cookie(:session_token): the cookie's value, or nil when it is absent, malformed or its signature does not
    # verify. `signed: false` reads a plain value (no MAC); `format:` picks the wire format of a signed cookie
    # (:hmac, the declaration's default, or :rails).
    def cookie_call(node, args)
      request_only!(node, "cookie(:name)")
      cookies_declared!(node, "cookie(:name)")
      rest = args.dup
      kwn = rest.last.is_a?(Prism::KeywordHashNode) ? rest.pop : nil
      bad(node, "cookie takes the cookie's name, as in cookie(:session_token)") unless rest.size == 1
      name = cookie_name(rest[0], "cookie")
      o = cookie_read_options(kwn)
      need(:headers)
      use = (@flags["cookie_use"] ||= {})
      if o[:signed]
        use["read"] = true
        formats = (use["read_formats"] ||= [])
        formats << o[:format] unless formats.include?(o[:format])
        ["#{AxumDsl::Cookies.read_fn(o[:format])}(&__headers, #{AxumDsl.rstr(name)})", :ostr, true]
      else
        use["unsigned_read"] = true
        ["axum_dsl_cookie_raw(&__headers, #{AxumDsl.rstr(name)})", :ostr, true]
      end
    end

    # The format a cookie call names: a literal `:hmac`, `:rails` or `:rails7`; the declaration's format
    # when it says nothing. Cookies::FORMATS is the runtime registry; schema.rb's COOKIE_FORMATS is the
    # declaration-level list and has to name every format this seam emits.
    def default_cookie_format = @flags["cookie_format"] || "hmac"

    def cookie_format_value(value, what)
      formats = AxumDsl::Cookies::FORMATS.keys
      unless value.is_a?(Prism::SymbolNode) && formats.include?(value.unescaped)
        bad(value, "#{what} `format:` is #{formats.map { |format| ":#{format}" }.join(', ')}, written out")
      end
      value.unescaped
    end

    # A read's keywords: `signed:` (true or false, default true) and `format:` (a symbol, default the
    # declaration's). `format:` on an unsigned cookie is refused: there is no signature to format.
    def cookie_read_options(kwn)
      o = { signed: true, format: default_cookie_format }
      seen = {}
      (kwn ? kwn.elements : []).each do |el|
        bad(el, "unsupported #{nodename(el)} in cookie (write `signed: false`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped.to_sym
        unless COOKIE_READ_KEYWORDS.include?(key)
          bad(el, "cookie has no keyword `#{key}:` (it has: #{COOKIE_READ_KEYWORDS.join(', ')})", word: key.to_s, from: COOKIE_READ_KEYWORDS.map(&:to_s))
        end
        bad(el, "duplicate `#{key}:`") if seen[key]
        seen[key] = true
        v = el.value
        case key
        when :signed
          bad(v, "cookie `signed:` is true or false, written out") unless v.is_a?(Prism::TrueNode) || v.is_a?(Prism::FalseNode)
          o[:signed] = v.is_a?(Prism::TrueNode)
        when :format
          o[:format] = cookie_format_value(v, "cookie")
        end
      end
      if seen[:format] && !o[:signed]
        bad(kwn, "cookie: `format:` applies to a signed cookie, and `signed: false` reads no signature")
      end
      o
    end

    def cookie_stmt?(node, name = nil)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.nil? &&
        (name ? node.name == name : %i[set_cookie delete_cookie].include?(node.name))
    end

    # A cookie is written on the response a route answers with.
    def cookie_scope!(node, what)
      bad(node, "`#{what}` is a statement of a route body: a cookie goes on the response a route answers with") unless @kind == :route
      cookies_declared!(node, what)
    end

    # `set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true` as a statement. The
    # value is signed when the response is built. The attributes are written out: http_only defaults to true,
    # same_site to :lax, secure and permanent to false, and the cookie has no lifetime unless `permanent: true`
    # (Rails' twenty years) or `max_age:` (seconds) says so.
    def set_cookie_stmt(node, args, env)
      cookie_scope!(node, "set_cookie")
      rest = args.dup
      kwn = rest.last.is_a?(Prism::KeywordHashNode) ? rest.pop : nil
      unless rest.size == 2
        bad(node, "set_cookie takes the cookie's name and its value: `set_cookie :session_token, token, http_only: true`")
      end
      name = cookie_name(rest[0], "set_cookie")
      v = expr(rest[1], env)
      bad(rest[1], "a secret cannot be written into a cookie; pass it to a binding or rust_fn function") if v[1] == :secret
      bad(rest[1], "set_cookie writes a string, got #{TypeNames.display(v[1])}") unless %i[str string].include?(v[1])
      o = cookie_options(kwn)
      value = v[1] == :str ? v[0] : "&#{wrap(v)}"
      use = (@flags["cookie_use"] ||= {})
      @cookies_written = true
      attributes = "#{o[:http_only]}, #{AxumDsl.rstr(SAME_SITE.fetch(o[:same_site]))}, #{o[:secure]}, #{o[:max_age] ? "Some(#{o[:max_age]})" : 'None'}"
      if o[:signed]
        use["set"] = true
        formats = (use["set_formats"] ||= [])
        formats << o[:format] unless formats.include?(o[:format])
        ["__cookies.push(#{AxumDsl::Cookies.set_fn(o[:format])}(#{AxumDsl.rstr(name)}, #{value}, #{attributes}));"]
      else
        use["unsigned_write"] = true
        ["__cookies.push(axum_dsl_set_cookie_raw(#{AxumDsl.rstr(name)}, #{value}, #{attributes}));"]
      end
    end

    # The keywords of set_cookie, each a literal: [defaults, then what the call wrote]. A cookie is signed
    # unless `signed: false`; `format:` picks the signature's wire format and is refused on a plain cookie.
    def cookie_options(kwn)
      o = { http_only: true, same_site: :lax, secure: false, permanent: false, max_age: nil, signed: true, format: nil }
      seen = {}
      (kwn ? kwn.elements : []).each do |el|
        bad(el, "unsupported #{nodename(el)} in set_cookie (write `http_only: true`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped.to_sym
        unless COOKIE_KEYWORDS.include?(key)
          bad(el, "set_cookie has no keyword `#{key}:` (it has: #{COOKIE_KEYWORDS.join(', ')})", word: key.to_s, from: COOKIE_KEYWORDS.map(&:to_s))
        end
        bad(el, "duplicate `#{key}:`") if seen[key]
        seen[key] = true
        v = el.value
        case key
        when :same_site
          unless v.is_a?(Prism::SymbolNode) && SAME_SITE.key?(v.unescaped.to_sym)
            bad(v, "set_cookie `same_site:` is :lax, :strict or :none, written out")
          end
          o[:same_site] = v.unescaped.to_sym
        when :max_age
          bad(v, "set_cookie `max_age:` is a number of seconds written out, such as 3600") unless v.is_a?(Prism::IntegerNode) && !v.value.negative?
          o[:max_age] = v.value
        when :format
          o[:format] = cookie_format_value(v, "set_cookie")
        else
          bad(v, "set_cookie `#{key}:` is true or false, written out") unless v.is_a?(Prism::TrueNode) || v.is_a?(Prism::FalseNode)
          o[key] = v.is_a?(Prism::TrueNode)
        end
      end
      if seen[:format] && !o[:signed]
        bad(kwn, "set_cookie: `format:` applies to a signed cookie, and `signed: false` writes no signature")
      end
      if o[:permanent] && o[:max_age]
        bad(kwn, "set_cookie: `permanent: true` is a lifetime of twenty years and `max_age:` another; give one")
      end
      o[:max_age] = PERMANENT_MAX_AGE if o[:permanent]
      o[:format] ||= default_cookie_format if o[:signed]
      o
    end

    # `delete_cookie :session_token` as a statement: the response tells the browser to drop the cookie (Max-Age=0).
    def delete_cookie_stmt(node, args)
      cookie_scope!(node, "delete_cookie")
      bad(node, "delete_cookie takes the cookie's name, as in delete_cookie :session_token") unless args.size == 1
      name = cookie_name(args[0], "delete_cookie")
      (@flags["cookie_use"] ||= {})["delete"] = true
      @cookies_written = true
      ["__cookies.push(axum_dsl_delete_cookie(#{AxumDsl.rstr(name)}));"]
    end

    # random_token, request_ip and user_agent: values with no arguments. A token is 24 base58 characters from the
    # system's random source; the address is the peer's (the first X-Forwarded-For entry when `use_layer :trace,
    # forwarded: true` says a proxy is trusted) and the agent is the User-Agent header, empty when it is absent.
    def request_value_call(node, args)
      name = node.name
      bad(node, "#{name} takes no arguments") unless args.empty?
      request_only!(node, name) unless name == :random_token
      (@flags["builtins"] ||= {})[name.to_s] = true
      case name
      when :random_token then ["axum_dsl_random_token()", :string, true]
      when :request_ip
        need(:headers, :peer)
        ["axum_dsl_request_ip(&__headers, __peer)", :string, true]
      else
        need(:headers)
        ["axum_dsl_user_agent(&__headers)", :string, true]
      end
    end

    # current(:user): a per-request value declared with `current`, computed on its first read and kept for the
    # rest of the request (a tokio OnceCell the compiled service holds in the request's extensions). An error in
    # its block behaves like a `raise` in this body.
    def current_call(node, args)
      request_only!(node, "current(:name)")
      bad(node, "current takes the name of a `current`, as in current(:user)") unless args.size == 1 && args[0].is_a?(Prism::SymbolNode)
      name = args[0].unescaped
      table = @flags["currents"] || {}
      cur = table[name] or
        bad(args[0], "no current `#{name}` is declared above this body#{table.empty? ? '; declare one with `current :name, returns: :Record? do ... end`' : " (declared: #{table.keys.join(', ')})"}",
            word: name, from: table.keys)
      (@flags["used_currents"] ||= {})[name] = true
      @currents_read << name
      need(:headers, :peer, :currents)
      @fallible = true
      @uses_async = true
      @async_reason ||= "reads current `#{name}` (line #{node.location.start_line})"
      read = "__currents.#{name}.get_or_try_init(|| axum_dsl_current_#{name}(&__headers, __peer, &__currents)).await?"
      if cur["required"] && @kind == :route
        if @skips.include?(cur["required"])
          bad(node, "`current(:#{name})` is non-nil only after `before :#{cur['required']}`, but this route skips `:#{cur['required']}`; " \
                    "drop `:#{cur['required']}` from the route's `skip:`, or handle the nil-able current with `||`/`.nil?`")
        end
        @flags["required_current"] = true
        return ["axum_dsl_require_current(#{read}.clone(), #{AxumDsl.rstr(name)})?", cur["rtype_required"].to_sym, true]
      end
      ["#{read}.clone()", cur["rtype"].to_sym, true]
    end

    # The body of a `current`, lowered like a helper that takes nothing: it ends in a value of the declared type,
    # and `return` and `raise` leave it (the reader of the current then fails the way a `raise` would).
    def lower_current(blk, name, ret)
      @body_line = blk.location.start_line
      @ret = ret
      bad(blk.parameters, "a `current` block takes no parameters") if blk.parameters
      st = blk.body
      bad(blk, "empty current body") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, {})
      bad(st, "a current cannot end in `raise` or `return`; end it in a value") if t == :never
      code = coerce(unparen(e), t, ret) or
        bad(st, "current `#{name}` returns #{TypeNames.display(ret)} but its body ends in #{TypeNames.display(t)}")
      reject_unused
      { "locals" => lets, "expr" => code, "uses_async" => true, "async_reason" => @async_reason }
    end
    public :lower_current

    # Bcrypt.verify(plain, digest) -> bool (false on a malformed digest, never an error) and Bcrypt.hash(plain) ->
    # string (cost 12, Rails' default). A compiler built-in, not a binding. Both run on a blocking thread, since
    # bcrypt is CPU-heavy, so the body is async.
    def bcrypt_call(node, args, env)
      arity = BCRYPT_FNS[node.name] or
        bad(node, "Bcrypt has no method `#{node.name}`; the built-in Bcrypt has verify(plain, digest) and hash(plain)",
            word: node.name.to_s, from: BCRYPT_FNS.keys.map(&:to_s))
      what = "Bcrypt.#{node.name}"
      bad(node, "#{what} runs in a route, a filter, a `current` or a helper body, not in a binding") if @tool.nil?
      bad(node, "#{what} cannot run in the `error` filter: it answers a request that already failed") if @kind == :error
      unless args.size == arity
        bad(node, "#{what} takes #{arity} argument#{arity == 1 ? '' : 's'}, got #{args.size}; expected `#{node.name == :verify ? 'Bcrypt.verify(plain, digest)' : 'Bcrypt.hash(plain)'}`")
      end
      parts = args.each_with_index.map do |arg, i|
        r = expr(arg, env)
        label = i.zero? ? "plain" : "digest"
        bad(arg, "#{what}: `#{label}` is a string, got #{TypeNames.display(r[1])}") unless %i[str string].include?(r[1])
        r[1] == :str ? "#{r[0]}.to_string()" : "#{wrap(r)}.clone()"
      end
      (@flags["builtins"] ||= {})["bcrypt_#{node.name}"] = true
      @uses_async = true
      @async_reason ||= "calls #{what} (line #{node.location.start_line}), which runs on a blocking thread"
      return ["axum_dsl_bcrypt_verify(#{parts.join(', ')}).await", :bool, true] if node.name == :verify

      @fallible = true
      ["axum_dsl_bcrypt_hash(#{parts[0]}).await?", :string, true]
    end
    # Is this node a bare `status(...)`/`content_type(...)`/`headers(...)` call (with `name`, that one),
    # which only a statement position allows and only a response body may write?
    def route_stmt?(node, name = nil)
      @route && node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.nil? &&
        (name ? node.name == name : %i[status content_type headers etag].include?(node.name))
    end

    # The arguments of a call node, or none.
    def args_of(node) = node.arguments ? node.arguments.arguments : []

    # A value of a type a binding owns (class Value < AxumDsl::Opaque): held and passed on, never looked into.
    def opaque?(sym) = CompositeTypes::Opaque.symbol?(sym)

    def opaque_name(sym) = CompositeTypes::Opaque.name_of(sym)

    # Heck.snake_case(text): a call into a binding. Arguments are checked against the binding's sig
    # here; the generated wrapper function (Emit.binding_fn) is rustc-checked against the same sig.
    def binding_call(node, args, env)
      file = @bindings.fetch(node.receiver.name.to_s)
      fn = file.fns[node.name.to_s] or
        bad(node, "#{file.module_name} has no method `#{node.name}` (it has: #{file.fns.keys.join(', ')})", word: node.name, from: file.fns.keys)
      unless args.size == fn.params.size
        bad(node, "#{file.module_name}.#{fn.name} takes #{fn.params.size} argument(s), got #{args.size}; expected `#{file.module_name}.#{fn.name}(#{fn.params.map(&:first).join(', ')})`")
      end
      parts = args.zip(fn.params).map do |arg, (pname, ptype)|
        r = expr(arg, env)
        rt = RINT.fetch(r[1], r[1])
        next nilable_arg(arg, r, rt, ptype, "#{file.module_name}.#{fn.name}: argument `#{pname}`") if OPT.key?(ptype)

        ok = (ptype == :string && %i[string str secret].include?(rt)) || rt == ptype || (rt == :int && INTS.include?(ptype))
        bad(arg, "#{file.module_name}.#{fn.name}: argument `#{pname}` should be #{TypeNames.display(ptype)}, got #{TypeNames.display(rt)}") unless ok
        %i[string strs i64s].include?(ptype) || opaque?(ptype) ? "&#{wrap(r)}" : wrap(r)
      end
      (@flags["used_bindings"] ||= {})["#{file.module_name}.#{fn.name}"] = true
      call = "#{file.wrapper(fn)}(#{parts.join(', ')})"
      if fn.async
        refuse_async(node, "#{file.module_name}.#{fn.name}", "is declared `async: true`")
        @uses_async = true
        @async_reason ||= "calls `#{file.module_name}.#{fn.name}` (line #{node.location.start_line}), which is declared async"
        call = "#{call}.await"
      end
      [call, fn.returns, true]
    end

    # An argument for a T.nilable binding parameter, which the wrapper takes as an owned Option: a nil-able value
    # of that type passes as it is, nil as None, and a plain value of the inner type as Some(...). A local is
    # cloned (`kept`), since passing it would move it and Ruby lets it be read again.
    def nilable_arg(arg, r, rt, ptype, label)
      return "None" if rt == :nil
      return wrap(kept(arg, r)) if rt == ptype

      inner = OPT.fetch(ptype)
      fits = coerce(wrap(kept(arg, r)), rt, inner) or
        bad(arg, "#{label} should be #{TypeNames.display(ptype)} (a value or nil), got #{TypeNames.display(rt)}")
      "Some(#{fits})"
    end

    # A binding method written in Ruby (no rust template): the Ruby body IS the implementation.
    def lower_def(fn)
      node = fn.node
      @body_line = node.location.start_line
      env = fn.params.to_h { |n, t| [n.to_sym, t] }
      fn.params.each_with_index { |(n, _), i| @declared << [n.to_sym, node.parameters.requireds[i], "parameter"] }
      st = node.body
      bad(node, "`#{fn.name}` has an empty body") unless st.is_a?(Prism::StatementsNode)
      unless fn.returns == :string
        bad(node, "a binding compiled from Ruby must return String for now, but the sig says #{fn.returns}")
      end
      lets, e, t, = stmts(st, env)
      bad(st, "`#{fn.name}` must return a string, got #{t}; use .to_s") unless %i[string str].include?(t)
      e = "#{e}.to_string()" if t == :str
      reject_unused
      { "locals" => lets, "expr" => e, "fallible" => @fallible, "uses_async" => @uses_async, "async_reason" => @async_reason }
    end
    public :lower_def # the reader calls it from outside; everything around it is private

    # Rust::Int32(x) / Rust::Int64(x): mark an integer as "treat this like Rust".
    def rust_int(node, args, env)
      base = RUST_INTS[node.name] or
        bad(node, "unknown Rust type `Rust::#{node.name}` (known: #{(RUST_INTS.keys + [:Str]).map { |k| "Rust::#{k}" }.join(', ')})", word: node.name, from: RUST_INTS.keys + [:Str])
      bad(node, "Rust::#{node.name} takes exactly one integer") unless args.size == 1
      r = expr(args[0], env)
      rb = RINT.fetch(r[1], r[1])
      bad(args[0], "Rust::#{node.name} wraps an #{base} value, got #{rb}") unless rb == base || rb == :int
      [wrap(r), RINT_OF.fetch(base), true]
    end

    # Rust::Str(s): a string with Rust `str` behaviour (type :r_str, always an owned String in the Rust code).
    # Its methods are Rust's, named as Rust names them; `to_s` leaves it for a plain string.
    # Method => number of arguments. Ruby's String methods are untouched (`strip` there is not `trim`).
    RUST_STR_METHODS = { trim: 0, strip: 0, to_lowercase: 0, to_uppercase: 0, to_s: 0, len: 0, lines: 0,
                         split: 1, contains: 1, starts_with?: 1, replace: 2 }.freeze

    def rust_str(node, args, env)
      bad(node, "Rust::Str takes exactly one string") unless args.size == 1
      r = expr(args[0], env)
      bad(args[0], "Rust::Str wraps a string, got #{TypeNames.display(r[1])}") unless %i[str string].include?(r[1])
      ["#{wrap(r)}.to_string()", :r_str, true]
    end

    # A method on a Rust::Str: Rust's str method, spelled out. Results that are strings stay :r_str.
    def rust_str_call(node, name, args, recv, env)
      want = RUST_STR_METHODS[name]
      unless want
        bad(node, "unsupported method `#{name}` on Rust::Str (allowed: #{RUST_STR_METHODS.keys.join(', ')})",
            word: name, from: RUST_STR_METHODS.keys)
      end
      bad(node, "Rust::Str `#{name}` takes #{want} argument#{want == 1 ? '' : 's'}, got #{args.size}") unless args.size == want
      s = wrap(recv)
      pats = args.map do |a|
        v = expr(a, env)
        bad(a, "Rust::Str `#{name}` takes strings, got #{TypeNames.display(v[1])}") unless %i[str string].include?(v[1])
        v[1] == :str ? v[0] : "&#{wrap(v)}"
      end
      case name
      when :trim then ["#{s}.trim().to_string()", :r_str, true]
      when :strip
        Notify.add(@path, node, "N-STR-STRIP-RUST", "Rust::Str#strip uses Rust trim() (Unicode whitespace, including NBSP; NUL is not stripped)")
        ["#{s}.trim().to_string()", :r_str, true]
      when :to_lowercase, :to_uppercase then ["#{s}.#{name}()", :r_str, true]
      when :to_s then ["#{s}.to_string()", :string, true]
      when :len then ["(#{s}.len() as i64)", :i64, true]
      when :lines then ["#{s}.lines().map(|__l| __l.to_string()).collect::<Vec<String>>()", :strs, true]
      when :split then ["#{s}.split(#{pats[0]}).map(|__p| __p.to_string()).collect::<Vec<String>>()", :strs, true]
      when :contains then ["#{s}.contains(#{pats[0]})", :bool, true]
      when :starts_with? then ["#{s}.starts_with(#{pats[0]})", :bool, true]
      else ["#{s}.replace(#{pats[0]}, #{pats[1]})", :r_str, true]
      end
    end

    # An async function may only be awaited where there is an async context: a tool, helper, prompt or
    # resource body. A binding compiled from Ruby, or a `complete` block, has no async context (its
    # emitted code is a plain closure), so a call there is refused with the reason the callee is async.
    def async_context?
      @tool.to_s.start_with?("tool ", "helper ", "prompt ", "resource ", "current ")
    end

    def refuse_async(node, what, reason)
      return if async_context?

      place = @tool ? "a #{@tool}" : "a binding body"
      chain = reason ? ", which is async because it #{reason}" : ""
      bad(node, "#{what} is async#{chain}; an async call needs a tool, helper, prompt or resource body, not #{place}")
    end

    def where(node)
      loc = node.location
      tool = @tool ? " in #{@tool}" : ""
      "#{@path}:#{loc.start_line}:#{loc.start_column + 1}#{tool}"
    end

    # Each operation and type becomes one small generated function (ck_add_i32, ck_fdiv_i64, ...),
    # recorded in @flags["checked"] so Emit writes exactly the ones this server uses.
    def checked_op(node, op, l, r, t, rust)
      @fallible = true
      kind = (rust ? RUST_OP_KIND : OP_KIND).fetch(op)
      (@flags["checked"] ||= {})["#{kind}:#{t}"] = true
      # unparen drops one redundant outer pair from a cast operand: `ck_add_i64((x as i64), 1, ...)` makes
      # rustc warn (unused_parens), while `ck_add_i64(x as i64, 1, ...)` does not.
      ["ck_#{kind}_#{t}(#{unparen(wrap(l))}, #{unparen(wrap(r))}, #{AxumDsl.rstr(where(node))})?", rust ? RINT_OF.fetch(t) : t, true]
    end

    def checked_neg(node, recv)
      @fallible = true
      t = RINT.fetch(recv[1], recv[1])
      (@flags["checked"] ||= {})["neg:#{t}"] = true
      ["ck_neg_#{t}(#{wrap(recv)}, #{AxumDsl.rstr(where(node))})?", recv[1], true]
    end

    def note_strip(node)
      Notify.add(@path, node, "N-STR-STRIP-RUBY",
                 "Ruby strip (NUL and ASCII whitespace) compiles to an explicit-set trim, not Rust trim()")
    end

    # s.gsub(/re/) { |m| ... } and s.sub(/re/) { |m| ... }: the block receives the matched text and
    # returns the replacement. Only a regex literal is supported as the pattern, and the block cannot
    # read capture groups ($1, $~) or contain raise, to_i or integer arithmetic yet.
    def subst_block(node, name, recv, args, env)
      unless args.size == 1 && args[0].is_a?(Prism::RegularExpressionNode)
        bad(node, "`#{name}` with a block takes one regex literal as its pattern")
      end
      blk = node.block
      param = block_param(blk, env, "`#{name}`", :string)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      outer = @fallible
      @fallible = false
      outer_async = @uses_async
      @uses_async = false
      lets, e, t, = stmts(st, env.merge(param => :string))
      e = unparen(e)
      if @fallible
        bad(blk, "integer arithmetic, `to_i`, `raise` or `return` inside a #{name} block is not supported yet; do it outside the block")
      end
      if @uses_async
        bad(blk, "an async call inside a #{name} block is not supported: the block becomes a plain Rust closure, " \
                 "where `.await` is not allowed; do the async call before the substitution")
      end
      @fallible = outer
      @uses_async = outer_async
      bad(blk, "the `#{name}` block must return a string, got #{t}") unless %i[string str].include?(t)
      e = "#{e}.to_string()" if t == :str
      meth = name == :gsub ? "replace_all" : "replace"
      ["#{regex_id(args[0])}.#{meth}(&#{wrap(recv)}, |__c: &regex::Captures| { let #{param} = __c[0].to_string(); " \
       "#{(lets + [e]).join(' ')} }).into_owned()", :string, true]
    end

    # gsub/sub with a string literal -> str::replace/replacen; with a regex literal ->
    # a compiled regex static. Replacement is literal text (NoExpand): no backslash.
    def subst(node, name, recv, args, env = nil)
      bad(node, "`#{name}` needs a string receiver, got #{recv[1]}") unless %i[str string].include?(recv[1])
      return subst_block(node, name, recv, args, env) if node.block

      bad(node, "`#{name}` takes exactly two arguments, or one regex literal and a block; expected `#{name}(pattern, replacement)` or `#{name}(/re/) { |m| ... }`") unless args.size == 2
      pat, repl = args
      unless repl.is_a?(Prism::StringNode) && !repl.unescaped.include?("\\")
        bad(repl, "replacement must be a plain string literal without a backslash")
      end
      r = AxumDsl.rstr(repl.unescaped)
      code =
        case pat
        when Prism::StringNode
          a = AxumDsl.rstr(pat.unescaped)
          name == :gsub ? "#{wrap(recv)}.replace(#{a}, #{r})" : "#{wrap(recv)}.replacen(#{a}, #{r}, 1)"
        when Prism::RegularExpressionNode
          meth = name == :gsub ? "replace_all" : "replace"
          "#{regex_id(pat)}.#{meth}(&#{wrap(recv)}, regex::NoExpand(#{r})).into_owned()"
        else
          bad(pat, "`#{name}` needs a string or regex literal as its first argument, got #{nodename(pat)}")
        end
      [code, :string, true]
    end

    # Registers (or reuses) a compiled regex static and returns its name.
    def regex_id(node)
      bad(node, "regex flag `o` is not supported") if node.once?
      rust = RegexTranslate.translate(node.unescaped, multi_line: node.multi_line?,
                                                      ignore_case: node.ignore_case?, extended: node.extended?)
      found = @regexes.find { |r| r["pattern"] == rust }
      return found["id"] if found

      id = "RE_#{@regexes.size + 1}"
      @regexes << { "id" => id, "pattern" => rust }
      id
    rescue RegexTranslate::Unsupported => e
      bad(node, "unsupported regex: #{e.message}")
    end

    def norm(t) = (t = RINT.fetch(t, t)) == :str ? :string : t

    def unify(n, a, b)
      return a if a == b
      return b if a == :never # `raise` has no value, so it fits any type
      return a if b == :never
      return b if a == :int && INTS.include?(b)
      return a if b == :int && INTS.include?(a)
      if a == :nil || b == :nil
        return :nil if a == :nil && b == :nil

        nilable = a == :nil ? b : a
        return nilable if OPT.key?(nilable)
        return OPT_OF.fetch(nilable) if OPT_OF.key?(nilable)
      end
      hint = " (a string literal is a borrowed `str`; use interpolation or `.to_s`)" if (a == :str && b == :string) || (a == :string && b == :str)
      bad(n, "type mismatch: #{a} vs #{b}#{hint}")
    end
  end
end

