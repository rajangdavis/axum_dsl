# frozen_string_literal: true

module AxumDsl
  # Walks the Prism AST of the DSL file into an IR hash (string keys, JSON-ready).
  # Deny by default: anything that is not a CallNode matching SIG is an error. The shape of a file is
  # Sinatra's: the optional `server`, the `set` settings, the `params` groups, the routes, the request
  # filters and the typed helpers all sit at the top level, and there is no enclosing block.
  class Reader
    include Diag

    def initialize(path, types: nil)
      @path = path
      @regexes = []
      @types = types # a TypeNames::Collector when `check --types` asks for the inferred types
      @flags = types ? { "types" => types } : {}
      @bindings = {}         # use_bindings name => BindingFile
      @binding_modules = {}  # module name (Heck) => BindingFile
      @binding_nodes = {}
      CompositeTypes::Opaque.reset # the types a binding owns are registered as this file's use_bindings are read
      text = Lsp::Sources[path] # an editor's unsaved buffer, when the language server is compiling it
      res = text ? Prism.parse(text) : Prism.parse_file(path)
      unless res.errors.empty?
        src = text || File.read(path, encoding: "UTF-8")
        raise CompileError, res.errors.map { |e|
          "#{path}:#{e.location.start_line}:#{e.location.start_column + 1}: syntax error: #{e.message}#{heredoc_do_hint(e, src)}"
        }.join("\n")
      end
      @program = res.value
      AxumDsl::SOURCE_FILES.clear
      AxumDsl.register_source(@program, path, AxumDsl.canon(path))
      @included = {} # use_dsl: absolute path of each fragment => "FILE:LINE" of the use_dsl that brought it in
    end

    HEREDOC_OPENER = /<<[~-]?(['"]?)[A-Za-z_][A-Za-z0-9_]*\1/

    # A heredoc as a keyword value (instructions: <<~TXT) with the block's `do` written after the terminator is
    # Ruby's own syntax error, and its message names only the stray `do`. The block opens on the line that starts
    # the heredoc, so say so when a heredoc opens above that `do` (rmcp-for-blender gap #18).
    def heredoc_do_hint(err, src)
      return "" unless err.message.include?("unexpected 'do'")
      return "" unless src.lines.first(err.location.start_line - 1).any? { |l| l.match?(HEREDOC_OPENER) }

      "; a block's `do` goes at the end of the line that opens the heredoc, as in " \
        "`server \"x\", version: \"0.1.0\", instructions: <<~TXT do`, with the heredoc's text and its terminator on the lines after it"
    end

    # Reads the whole file into the IR. The file is a Sinatra-shaped service: an optional `server` naming the
    # crate, `set` settings, `params` groups, routes (`get "/x" do ... end`), the request filters (`before`,
    # `not_found`, `error`), typed `helper`s, and the `use_bindings`/`rust_*`/`file` escape hatches. Routes and
    # filters are lowered last, after every helper is declared, so a body may call any helper.
    def read
      nodes = @program.statements.body
      if nodes[0].is_a?(Prism::CallNode) && nodes[0].name == :fragment
        bad(nodes[0], "#{@path} is a fragment; build the file that says use_dsl for it")
      end
      srv = { "name" => nil, "version" => nil, "port" => nil, "bind" => nil,
              "params" => [], "routes" => [], "before" => [], "not_found" => nil, "error" => nil,
              "user_helpers" => [], "settings" => [], "regexes" => @regexes, "inputs" => [File.expand_path(@path)],
              "crates" => [], "items" => [], "item_lines" => [], "externs" => {}, "modules" => [],
              "files" => [], "subprocs" => [], "binding_fns" => [], "opaque_types" => [],
              "statics" => [], "serve_files" => [], "assets" => [], "layers" => [], "views" => nil, "layout" => nil,
              "database" => nil, "migrations" => nil, "records" => [], "queries" => [],
              "cookies" => nil, "currents" => [], "builtins" => [] }
      @helper_table = {}   # helpers compiled so far, in declaration order: name -> record
      @helper_decls = {}   # helper name -> its DSL node (for messages)
      helper_nodes = []
      current_nodes = []
      route_nodes = []
      filters = []
      # One declaration of the file, from this file or from a fragment use_dsl splices in at its line.
      declare = lambda do |n, p, k, b|
        case n.name
        when :use_dsl then splice(n, p[0], srv, &declare)
        when :server then server_decl(n, p, k, srv)
        when :set then add_set(n, p, srv)
        when :params then srv["params"] << params_decl(n, p, b, srv)
        when :helper then helper_nodes << [n, p, k, b]
        when :setting then add_setting(n, p, k, srv)
        when :cookies then add_cookies(n, k, srv)
        when :current then current_nodes << [n, p, k, b]
        when :database then add_database(n, p, k, srv)
        when :migrations then add_migrations(n, p, srv)
        when :record then add_record(n, p, b, srv)
        when :query, :execute then add_query(n, p, k, srv)
        when :rust_crate then add_crate(n, p, srv, k)
        when :rust_item then add_item(n, p, srv)
        when :rust_fn then add_extern(n, p, k, srv)
        when :rust_file then add_file(n, p, k, srv)
        when :file then add_any_file(n, p, k, srv)
        when :static then add_static(n, p[0], k[:dir], k, srv)
        when :serve_file then add_serve_file(n, p[0], k[:from], srv)
        when :openapi then add_openapi(n, p[0], k, srv)
        when :use_layer then add_layer(n, p, k, srv)
        when :use_bindings then add_bindings(n, p, srv)
        when :cmd_fn then add_cmd(n, p, k, srv)
        when :script_fn then add_script(n, p, k, srv)
        when :before, :not_found, :error then filters << [n, p, k, b]
        when :get, :post, :put, :patch, :delete, :options, :head then route_nodes << [n, p, k, b]
        when :fragment then bad(n, "`fragment` is only written in a file use_dsl includes; this file is built directly")
        else bad(n, "unexpected declaration `#{n.name}`")
        end
      end
      nodes.each do |n|
        p, k, b = call(n, :top)
        declare.call(n, p, k, b)
      end
      bad(@program, "the file names no server; add `server \"name\", version: \"0.1.0\"` or `set :name, \"name\"`") if srv["name"].nil?
      bad(@program, "the file names no version for `#{srv['name']}`; add `version: \"0.1.0\"` to `server` or `set :version`") if srv["version"].nil?
      srv["externs"].each do |fname, ext|
        next if ext["from"].nil? || srv["modules"].any? { |m| m["name"] == ext["from"] }

        bad(@extern_nodes.fetch(fname), "rust_fn `#{fname}` says from: :#{ext['from']}, but no rust_file has as: :#{ext['from']}")
      end
      check_layout(srv)
      check_listener(srv)
      check_cookies(srv)
      check_database(srv)
      check_queries(srv)
      @helper_async = resolve_helper_async(helper_nodes, srv)
      helper_nodes.each { |n, p, k, b| helper_decl(n, p, k, b, srv) }
      srv["user_helpers"] = @helper_table.values
      current_nodes.each { |n, p, k, b| current_decl(n, p, k, b, srv) }
      filters.each { |n, p, k, b| filter_decl(n, p, k, b, srv) }
      check_required_currents(srv)
      check_static_skips(srv)
      route_nodes.each do |n, p, k, b|
        decl = route_decl(n, p, k, b, srv)
        srv["routes"] << decl
        (@route_decl_nodes ||= []) << [decl, n]
      end
      check_private_cache_except(srv) # statics and routes are both complete now
      check_filter_skips(srv)
      srv["filter_skips"] = true if srv["routes"].any? { |r| r["skip"].to_a.any? } || srv["statics"].any? { |s| s["skip"].to_a.any? }
      check_errors_routes(srv)
      check_openapi(srv)
      lower_bindings(srv)
      srv["checked"] = (@flags["checked"] || {}).keys.sort
      srv["helpers"] = (@flags["helpers"] || {}).keys.sort
      srv["html_escape"] = true if @flags["html_escape"] # a body used h(...), so the crate gets the escaper
      srv["transactions"] = true if @flags["transactions"] # a body opened a transaction, so the crate gets db_tx
      srv["queries_in_tx"] = (@flags["queries_in_tx"] || {}).keys.sort # statements called inside a transaction
      srv["queries_outside"] = (@flags["queries_outside"] || {}).keys.sort # statements whose pooled wrapper is emitted
      srv["sanitize"] = true if @flags["sanitize"] # a view used |sanitize, so the crate gets the sanitiser
      srv["required_current"] = true if @flags["required_current"] # a route read a `required:` current at its non-nil type
      srv["builtins"] = (@flags["builtins"] || {}).keys.sort # random_token, request_ip, user_agent, Bcrypt.*: the runtime each needs
      srv["cookies"].merge!((@flags["cookie_use"] || {}).transform_keys(&:to_s)) if srv["cookies"]
      # Every view the compiler read is an input of the compile, like a binding or a rust_file, so
      # --print-inputs names it and a driver can watch it.
      srv["inputs"].concat((@flags["view_inputs"] || {}).keys.reject { |p| srv["inputs"].include?(p) })
      reject_unused_declarations(srv)
      warn_missing_module_fns(srv)
      check_unloaded_bindings(srv)
      srv
    end

    private

    # use_dsl "dsl/x.axum.rb": the declarations of a fragment, a file whose one top-level call is
    # `fragment do ... end`, spliced in at this line and yielded one by one as if written here. The path is
    # relative to the file that says use_dsl and stays inside the root's folder; a fragment may use_dsl another,
    # but no file is included twice.
    def splice(node, rel, srv)
      unless rel.end_with?(".axum.rb") && !rel.start_with?("/") && !rel.include?("\0") && !rel.split("/").include?("..")
        bad(node, "use_dsl path must be relative, inside the DSL file's folder, without .., and end in .axum.rb")
      end
      dir = dir_of(node)
      full = File.expand_path(rel, dir)
      bad(node, "use_dsl file not found: #{rel} (looked in #{dir})") unless Lsp::Sources[full] || File.file?(full)
      root = File.realpath(File.dirname(File.expand_path(@path)))
      real = File.file?(full) ? File.realpath(full) : full
      bad(node, "use_dsl file must stay inside #{root}") unless real.start_with?(root + File::SEPARATOR)
      shown = File.dirname(@path) == "." ? real.delete_prefix(root + File::SEPARATOR) : File.join(File.dirname(@path), real.delete_prefix(root + File::SEPARATOR))
      bad(node, "#{shown} is the file being built; it cannot be included") if real == File.realpath(File.expand_path(@path))
      bad(node, "#{shown} is already included (by #{@included[real]})") if @included.key?(real)
      @included[real] = "#{AxumDsl.file_of(node) || @path}:#{node.location.start_line}"
      text = Lsp::Sources[real] || File.read(real, encoding: "UTF-8")
      bad(node, "use_dsl file is not valid UTF-8: #{rel}") unless text.valid_encoding?
      bad(node, "use_dsl file is larger than #{MAX_RS_BYTES} bytes: #{rel}") if text.bytesize > MAX_RS_BYTES
      res = Prism.parse(text)
      unless res.errors.empty?
        raise CompileError, res.errors.map { |e|
          "#{shown}:#{e.location.start_line}:#{e.location.start_column + 1}: syntax error: #{e.message}#{heredoc_do_hint(e, text)}"
        }.join("\n")
      end
      AxumDsl.register_source(res.value, shown, real)
      srv["inputs"] << real
      top = res.value.statements.body
      unless top.size == 1 && top[0].is_a?(Prism::CallNode) && top[0].name == :fragment
        bad(top[1] || top[0] || res.value, "expected exactly one top-level `fragment` call in a file use_dsl includes")
      end
      _, _, blk = call(top[0], :top)
      each_child(blk, :top) { |n, p, k, b| yield n, p, k, b }
    end
    # The folder of the file a node was read from: the root, or the fragment that holds it. A relative path in
    # a declaration (rust_file, file, openapi, use_dsl) resolves against it.
    def dir_of(node) = File.realpath(File.dirname(AxumDsl.real_file_of(node) || File.expand_path(@path)))

    # The "line" of a declaration for the IR and the source map, and its "file" when a fragment holds it.
    def located(node)
      file = AxumDsl.file_of(node)
      line = node.location.start_line
      file && file != @path ? { "line" => line, "file" => file } : { "line" => line }
    end

    # Where the earlier of two same-named declarations is, for a duplicate refused at the later one: " (first at
    # FILE:LINE)" when it is in another file of a use_dsl split, "" when both are in one file. `earlier` is its IR
    # record ("line", and "file" when a fragment holds it) or its node.
    def first_at(node, earlier)
      return "" unless earlier

      file, line =
        if earlier.is_a?(Prism::Node) then [AxumDsl.file_of(earlier) || @path, earlier.location.start_line]
        else [earlier["file"] || @path, earlier["line"]]
        end
      line.nil? || file == (AxumDsl.file_of(node) || @path) ? "" : " (first at #{file}:#{line})"
    end
    # A bindings/*.rb that no `use_bindings` names is never parsed, so its crates never reach
    # Cargo.toml and the failure surfaces later as a missing crate in generated Rust. One bindings/
    # folder can serve several servers, so skip a file a sibling .axum.rb names.
    def check_unloaded_bindings(srv)
      bdir = Bindings.dir_for(@path)
      return unless File.directory?(bdir)

      loaded = @bindings.each_value.map { |f| File.basename(f.path) }
      dir = File.dirname(File.expand_path(@path))
      Dir.glob(File.join(bdir, "*.rb")).sort.each do |path|
        base = File.basename(path)
        next if loaded.include?(base)
        next if named_by_a_sibling?(dir, File.basename(base, ".rb"))

        Notify.add(@path, @program, "W-BINDING-UNLOADED",
                   "bindings/#{base} is not loaded by any `use_bindings` here; its crates are not declared (add `use_bindings :#{File.basename(base, '.rb')}` if this server needs it)")
      end
    end

    def named_by_a_sibling?(dir, name)
      pattern = /use_bindings\s+:#{Regexp.escape(name)}(?![\w?])/
      Dir.glob(File.join(dir, "*.axum.rb")).any? do |other|
        next false if File.expand_path(other) == File.expand_path(@path)

        File.readable?(other) && File.read(other, encoding: "UTF-8").match?(pattern)
      end
    end

    # A declaration nothing uses would only become a rustc dead-code warning in the generated
    # crate. The DSL refuses it instead, so the file says exactly what the service does.
    def reject_unused_declarations(srv)
      called = @flags["used_externs"] || {}
      srv["externs"].each_key do |fname|
        next if called[fname]

        bad(@extern_nodes.fetch(fname),
            "`#{fname}` is declared but never called; call it as rust(:#{fname}, ...) in a body, or remove it")
      end
      used_settings = @flags["used_settings"] || {}
      srv["settings"].each do |s|
        next if used_settings[s["name"]]

        bad(@setting_nodes.fetch(s["name"]), "setting `#{s['name']}` is declared but no body reads it; use setting(:#{s['name']}) in a body, or remove it")
      end
      reject_unused_files(srv)
      called_queries = @flags["used_queries"] || {}
      srv["queries"].each do |q|
        next if called_queries[q["name"]]

        bad(@query_nodes.fetch(q["name"]), "#{q['kind']} `#{q['name']}` is declared but no route or filter calls it; call #{q['name']}(...) in a body, or remove it")
      end
      returned = srv["queries"].filter_map { |q| q["record"] }
      srv["records"].each do |r|
        next if returned.include?(r["name"])

        bad(@record_nodes.fetch(r["name"]), "record `#{r['name']}` is declared but no query returns it; name it in a query's `returns:`, or remove it")
      end
      used_currents = @flags["used_currents"] || {}
      srv["currents"].each do |c|
        next if used_currents[c["name"]]

        bad(@current_nodes.fetch(c["name"]), "current `#{c["name"]}` is declared but nothing reads it; read it as current(:#{c["name"]}) in a route, a filter or a later current, or remove it")
      end
      cookie_formats = srv["cookies"] ? srv["cookies"]["read_formats"].to_a + srv["cookies"]["set_formats"].to_a : []
      cookie_layer = srv["layers"].any? { |l| l["name"] == "csrf" } # the CSRF layer reads and writes its token cookie

      if srv["cookies"] && !cookie_layer && !srv["cookies"].values_at("read", "set", "delete", "unsigned_read", "unsigned_write").any? && cookie_formats.empty?
        bad(@cookies_node, "`cookies` is declared but no body reads or writes a cookie; use cookie(:name), set_cookie or delete_cookie in a body, or remove it")
      end
      called_helpers = @flags["used_helpers"] || {}
      @helper_table.each_key do |hname|
        next if called_helpers[hname]

        bad(@helper_decls.fetch(hname), "helper `#{hname}` is declared but never called; call it from a route body or a later helper, or remove it")
      end
      # A params struct a route names, or one that appears as another struct's nested field, list element or
      # map value, counts as used.
      referenced = lambda do |fields|
        fields.map { |f| f["type"] }.flat_map do |t|
          [CompositeTypes.nested_struct_name(t), CompositeTypes.object_list_name(t), CompositeTypes.object_map_name(t)].compact
        end
      end
      used = srv["routes"].filter_map { |r| r["params"] } + srv["params"].flat_map { |p| referenced.call(p["fields"]) }
      srv["params"].each do |p|
        next if used.include?(p["name"])

        bad(@params_nodes.fetch(p["name"]), "params `#{p['name']}` is declared but no route uses it; remove it or add a route")
      end
    end
    # A `file` nothing reads, or an entry nothing names, is refused like any unused declaration. An entry that
    # entry(...) names but no entry_args(...) builds arguments for gets W-FILE-ARGS-UNCHECKED on that call.
    def reject_unused_files(srv)
      read = @flags["used_files"] || {}
      named = @flags["used_entries"] || {}
      built = @flags["built_entries"] || {}
      texts = @flags["file_texts"] || {}
      srv["files"].each do |f|
        node = @file_nodes.fetch(f["name"])
        f["text_read"] = texts[f["name"]] ? true : false
        unless read[f["name"]]
          bad(node, "file `#{f['name']}` is declared but nothing reads it; use file_text(:#{f['name']}) or entry(:#{f['name']}, ...) in a body or helper, or remove it")
        end
        f["entries"].each do |e|
          key = "#{f['name']}.#{e}"
          bad(node, "entry `#{e}` of file `#{f['name']}` is listed but nothing names it; use entry(:#{f['name']}, :#{e}), or remove it from entries:") unless named[key]
          next if built[key] || !f["sigs"].fetch(e)["checked"]

          Notify.add(@path, named[key], "W-FILE-ARGS-UNCHECKED",
                     "entry(:#{f['name']}, :#{e}) is named, but no entry_args(:#{f['name']}, :#{e}, ...) builds its arguments, so they are not checked against `def #{e}` in #{f['path']}")
        end
      end
    end

    # Best effort, and only a warning: a rust_fn says its function lives in a loaded module, and a
    # text search of that file catches a typo at the DSL line instead of in generated Rust. The
    # compiler cannot see through macros or re-exports, so cargo stays the authority.
    def warn_missing_module_fns(srv)
      srv["externs"].each do |fname, ext|
        mod = srv["modules"].find { |m| m["name"] == ext["from"] } if ext["from"]
        next unless mod
        next if mod["source"].match?(/\bpub(?:\([^)]*\))?\s+(?:(?:const|async|unsafe)\s+)*fn\s+#{Regexp.escape(fname)}\b/)

        Notify.add(@path, @extern_nodes.fetch(fname), "W-RUST-FN-MISSING",
                   "`#{fname}` is declared as living in module `#{mod['name']}` (#{mod['path']}), " \
                   "but no `pub fn #{fname}` appears in that file; cargo will fail if it is really missing")
      end
    end

    # use_bindings :heck loads bindings/heck.rb from the directory of the DSL file (parsed, never run). Its crates join the server's.
    def add_bindings(node, pos, srv)
      name = pos[0]
      bad(node, "use_bindings :#{name} appears twice") if @bindings.key?(name)
      file = begin
        Bindings.load(name, root: Bindings.dir_for(@path))
      rescue CompileError => e
        bad(node, "cannot load binding `#{name}`: #{e.message}")
      end
      bad(node, "module `#{file.module_name}` is already provided by another binding") if @binding_modules.key?(file.module_name)
      bad(node, "module `Bcrypt` is built into the compiler (Bcrypt.verify, Bcrypt.hash); name the binding's module something else") if file.module_name == "Bcrypt"
      file.crates.each do |crate, version|
        have = srv["crates"].find { |c| c["name"] == crate }
        if have && have["version"] != version
          bad(node, "binding `#{name}` needs crate #{crate} #{version}, but rust_crate says #{have['version']}")
        end
        add_crate(node, [crate, version], srv) unless have
      end
      file.types.each_value do |t|
        qualified = "#{file.module_name}::#{t.name}"
        fields = t.fields.map { |n, sym, line| [n, sym.to_s, line] }
        CompositeTypes::Opaque.register(qualified, t.rust, t.wire, fields, file.path, t.node.location.start_line)
        entry = { "name" => qualified, "rust" => t.rust, "wire" => t.wire }
        # a record's fields and where they are declared, for Emit's check against the Rust type
        srv["opaque_types"] << (fields.empty? ? entry : entry.merge("fields" => fields, "path" => file.path, "line" => t.node.location.start_line))
      end
      @bindings[name] = file
      @binding_modules[file.module_name] = file
      @binding_nodes[name] = node
      srv["inputs"] << file.path
    end
    # What a setting's `default:` must be for each `type:`. A typed setting is parsed when the server starts, so its
    # default is a value of that type, not text to parse.
    SETTING_DEFAULT_OK = {
      "string" => ->(v) { v.is_a?(String) }, "i64" => ->(v) { v.is_a?(Integer) && v.bit_length < 64 },
      "f64" => ->(v) { v.is_a?(Numeric) }, "bool" => ->(v) { v == true || v == false }
    }.freeze
    SETTING_DEFAULT_WORDS = { "string" => "a string literal", "i64" => "an integer literal", "f64" => "a number literal",
                              "bool" => "true or false" }.freeze

    # setting :api_key, env: "API_KEY", secret: true. A setting is read from its environment variable once, when the
    # server starts; a required one that is missing (or empty) stops the server with a message naming the variable, so a
    # misconfigured server never answers a call. A body reads it with setting(:api_key). A secret can only be handed to a
    # binding or rust_fn function (the body language refuses to print or return it), and is never written to a message.
    def add_setting(node, pos, kw, srv)
      name = pos[0]
      bad(node, "duplicate setting `#{name}`#{first_at(node, @setting_nodes&.[](name))}") if srv["settings"].any? { |s| s["name"] == name }
      bad(node, "`env:` is an environment variable name in capitals, such as \"API_KEY\", got #{kw[:env].inspect}") unless kw[:env].match?(/\A[A-Z][A-Z0-9_]*\z/)
      dup = srv["settings"].find { |s| s["env"] == kw[:env] }
      bad(node, "setting `#{dup['name']}` already reads #{kw[:env]}; one variable, one setting") if dup
      bad(node, "`optional: false` is the default; leave `optional:` out") if kw[:optional] == false
      bad(node, "`secret: false` is the default; leave `secret:` out") if kw[:secret] == false
      bad(node, "a setting with a `default:` is never missing, so `optional: true` has nothing to add") if kw.key?(:default) && kw[:optional]
      bad(node, "a secret has no `default:`: a key written in the file is not a secret") if kw[:secret] && kw.key?(:default)
      bad(node, "a secret is either there or the server does not start, so it cannot be `optional:`") if kw[:secret] && kw[:optional]
      type = (kw[:type] || :string).to_s
      bad(node, "`type: :string` is the default; leave `type:` out") if kw[:type] == :string
      bad(node, "a secret is text, so `type: :#{type}` does not apply to `secret: true`") if kw[:secret] && type != "string"
      if kw.key?(:default) && !SETTING_DEFAULT_OK.fetch(type).call(kw[:default])
        bad(node, "`default:` must be #{SETTING_DEFAULT_WORDS.fetch(type)} for #{type == 'string' ? 'a' : "a `type: :#{type}`"} setting, got #{kw[:default].inspect}")
      end
      entry = { "name" => name, "env" => kw[:env] }
      entry["type"] = type unless type == "string"
      %i[description default].each { |k| entry[k.to_s] = kw[k] if kw.key?(k) }
      entry["optional"] = true if kw[:optional]
      entry["secret"] = true if kw[:secret]
      srv["settings"] << entry
      (@setting_nodes ||= {})[name] = node
      (@flags["settings"] ||= {})[name] = entry
    end
    # The shortest key a cookie may be signed with (Cookies::KEY_MIN).
    COOKIE_KEY_MIN = Cookies::KEY_MIN

    # cookies secret: :secret_key, format: :hmac. Every signed cookie uses the value of that setting
    # (docs/sessions.md); `format:` is :hmac (the default), :rails (the classic Marshal value) or :rails7 (JSON/metadata), and a cookie call may override it. The
    # setting is read once as the server starts, so its length is checked there (Cookies.start_lines); here the
    # reader checks what it can: the setting is declared, is a required string, and a `default:` is long enough.
    # Which cookie calls the bodies make is known only once they are lowered (check_cookies reads it then).
    def add_cookies(node, kw, srv)
      bad(node, "duplicate `cookies`#{first_at(node, @cookies_node)}; a service signs every cookie with one key") if srv["cookies"]
      format = (kw[:format] || :hmac).to_s
      srv["cookies"] = { "secret" => kw[:secret].to_s, "format" => format, **located(node) }
      @cookies_node = node
      @flags["cookies"] = true # a cookie call in a body is refused without it
      @flags["cookie_format"] = format # the default a cookie call uses
    end

    # Once every setting is read: the secret names one of them, and it can sign.
    def check_cookies(srv)
      decl = srv["cookies"]
      if decl.nil?
        if srv["layers"].any? { |l| l["name"] == "csrf" }
          bad(@csrf_node, "`use_layer :csrf` needs `cookies secret: :setting_name` at the top level of the file: the token is a signed cookie, and that setting is the key")
        end
        return
      end
      name = decl["secret"]
      setting = srv["settings"].find { |s| s["name"] == name }
      unless setting
        undeclared(@cookies_node, "`cookies secret: :#{name}` names a setting that is not declared", name, srv["settings"].map { |s| s["name"] })
      end
      if setting["optional"] || setting["type"]
        bad(@cookies_node, "`cookies secret: :#{name}` needs a required string setting, but `#{name}` is #{setting['optional'] ? 'optional' : "a `type: :#{setting['type']}`"}")
      end
      if setting["default"].is_a?(String) && setting["default"].bytesize < COOKIE_KEY_MIN
        bad(@cookies_node, "`cookies secret: :#{name}`: the default of setting `#{name}` is #{setting['default'].bytesize} bytes, and the key cookies are signed with must be at least #{COOKIE_KEY_MIN}")
      end
      decl["env"] = setting["env"]
      (@flags["used_settings"] ||= {})[name] = true
    end

    # current :user, returns: :User? do ... end: a per-request value (docs/sessions.md). The body is lowered like a
    # route's, in declaration order, so it may read the currents above it; a route or a filter reads it with
    # current(:user), and the compiled service computes it at most once per request.
    def current_decl(node, pos, kw, blk, srv)
      name = pos[0]
      earlier = srv["currents"].find { |c| c["name"] == name }
      bad(node, "duplicate current `#{name}`#{first_at(node, earlier && @current_nodes[name])}") if earlier
      bad(node, "`#{name}` is reserved; pick another current name") if RESERVED_HELPERS.include?(name) || name.start_with?("__")
      ret = current_returns(node, kw[:returns], srv)
      required = kw[:required]
      if required
        nilable = ret["shape"] == "one" || ret["nilable"]
        bad(node, "current `#{name}` already returns #{TypeNames.display(ret['rtype'].to_sym)}; `required:` is for a nil-able current, `returns: :Record?` or a `:type?`") unless nilable
      end
      body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "current `#{name}`", @binding_modules,
                      @helper_table, srv["params"] + srv["records"], kind: :current).lower_current(blk, name, ret["rtype"].to_sym)
      entry = { "name" => name, **ret, "body" => body, **located(node) }
      if required
        entry["required"] = required
        entry["rtype_required"] = ret["shape"] == "one" ? "struct:#{ret['record']}" : ret["type"]
      end
      srv["currents"] << entry
      (@current_nodes ||= {})[name] = node
      (@flags["currents"] ||= {})[name] = entry
    end

    # What a current answers, resolved against the records like a query's `returns:` (check_queries): the shape,
    # the record or scalar, and "rtype", the type a body sees the value as.
    def current_returns(node, ret, srv)
      if %w[list one].include?(ret["shape"])
        names = srv["records"].map { |r| r["name"] }
        names.include?(ret["record"]) or
          undeclared(node, "current returns record `#{ret['record']}`, which is not declared", ret["record"], names)
        return ret.merge("rtype" => ret["shape"] == "list" ? "list<struct:#{ret['record']}>" : "opt<struct:#{ret['record']}>")
      end
      ret.merge("rtype" => ret["nilable"] ? Body::OPT_OF.fetch(ret["type"].to_sym).to_s : ret["type"])
    end

    # `set :rust, :none` (docs/sessions.md): the file takes no Rust of its own. Everything that injects some calls
    # this with what it is (`rust_fn`, `rust_file`, `rust_item`, `set :listener`, a binding backed by a Rust
    # template). The setting may come after the declaration, so a declaration seen first is kept and refused when
    # the setting arrives; one seen after it is refused at once.
    def injection(node, what)
      return (@rust_injections ||= []) << [node, what] unless @rust_none_node

      bad(node, "#{what} injects Rust, which `set :rust, :none` (line #{@rust_none_node.location.start_line}) refuses; " \
                "write it in the DSL, or take the setting out")
    end
    # database :sqlite, path: "notes.sqlite3", env: "DATABASE_PATH": the one database the file's `query` and
    # `execute` declarations run against (docs/database.md). The first argument is the adapter, and the backend
    # that emits for it is in Db::ADAPTERS; only :sqlite is built. `env:` names a variable that replaces `path:`
    # when it is set and not empty as the server starts.
    def add_database(node, pos, kw, srv)
      adapter = pos[0]
      bad(node, "`:#{adapter}` is not an adapter yet; `:sqlite` is the only one") unless Db::ADAPTERS.key?(adapter)
      bad(node, "duplicate `database`#{first_at(node, @database_node)}; a service has one database") if srv["database"]
      bad(node, "`path:` must not be empty") if kw[:path].strip.empty?
      if kw[:env] && !kw[:env].match?(/\A[A-Z][A-Z0-9_]*\z/)
        bad(node, "`env:` is an environment variable name in capitals, such as \"DATABASE_PATH\", got #{kw[:env].inspect}")
      end
      srv["database"] = { "adapter" => adapter, "path" => kw[:path], "env" => kw[:env], **located(node) }.compact
      @flags["database"] = true # a body may open a `transaction` block
      @database_node = node
    end

    # A migration file is numbered, so that sorting the names applies them in the order they were written.
    MIGRATION_FILE = /\A\d+_[a-z0-9_]+\.sql\z/

    # migrations "db/migrate": the folder of *.sql files the server applies at startup, in file-name order,
    # each in its own transaction. The files are read here and embedded in the binary, so they are inputs of
    # the compile (--print-inputs names them) and the running service needs no folder.
    def add_migrations(node, pos, srv)
      rel = pos[0]
      bad(node, "duplicate `migrations`#{first_at(node, @migrations_node)}; a service has one migrations folder") if srv["migrations"]
      if rel.start_with?("/") || rel.include?("\0") || rel.split("/").include?("..")
        bad(node, "migrations folder must be relative, inside the DSL file's folder, without .., got #{rel.inspect}")
      end
      base = dir_of(node)
      full = File.expand_path(rel, base)
      bad(node, "migrations folder not found: #{rel} (looked in #{base})") unless File.directory?(full)
      real_dir = File.realpath(full)
      bad(node, "migrations folder must stay inside #{base}") unless real_dir.start_with?(base + File::SEPARATOR)
      names = Dir.children(real_dir).select { |f| f.end_with?(".sql") && File.file?(File.join(real_dir, f)) }.sort
      bad(node, "migrations folder #{rel} has no *.sql files") if names.empty?
      files = names.map do |file|
        unless file.match?(MIGRATION_FILE)
          bad(node, "migration file #{rel}/#{file} must be named like 001_create_notes.sql: digits, an underscore, lowercase letters, digits and underscores, then .sql")
        end
        real = File.realpath(File.join(real_dir, file))
        bad(node, "migration file #{rel}/#{file} must stay inside #{base}") unless real.start_with?(base + File::SEPARATOR)
        sql = Lsp::Sources[real] || File.read(real, encoding: "UTF-8")
        bad(node, "migration file #{rel}/#{file} is not valid UTF-8") unless sql.valid_encoding?
        srv["inputs"] << real
        { "file" => file, "sha256" => Digest::SHA256.hexdigest(sql), "sql" => sql }
      end
      srv["migrations"] = { "path" => rel, "files" => files, **located(node) }
      @migrations_node = node
    end

    # record :Note do field :id, :i64 ... end: the row a query returns. Its fields are columns, so each has a
    # scalar type, and `optional: true` marks a column that may be NULL (an Option in Rust, nil-able in a body).
    # A record is read in a body exactly like a nested params object (`note.body`, `notes.map`, `json(note)`):
    # the body compiler is given the records beside the params groups.
    def add_record(node, pos, blk, srv)
      name = pos[0]
      earlier = srv["records"].find { |r| r["name"] == name }
      bad(node, "duplicate record `#{name}`#{first_at(node, earlier && @record_nodes[name])}") if earlier
      fields = []
      each_child(blk, :record) do |n, p, k, _b|
        fname, ftype = p
        bad(n, "duplicate field `#{fname}`") if fields.any? { |f| f["name"] == fname }
        unless Db::SCALARS.include?(ftype)
          bad(n, "record field `#{fname}` is a column, so its type is one of #{Db::SCALARS.map { |t| ":#{t}" }.join(', ')}, not :#{ftype}")
        end
        k.each_key do |key|
          bad(n, "`#{key}:` does not apply to a record field; the only option is `optional: true`, for a column that may be NULL") unless key == :optional
        end
        bad(n, "`optional: false` is the default; leave `optional:` out") if k[:optional] == false
        field = { "name" => fname, "type" => ftype }
        field["optional"] = true if k[:optional]
        note_field(n, field)
        fields << field
      end
      bad(node, "record `#{name}` has no fields") if fields.empty?
      srv["records"] << { "name" => name, "kind" => "record", "fields" => fields, **located(node) }
      (@record_nodes ||= {})[name] = node
    end

    # What `returns:` of a query says, as the IR carries it until the records are all read (check_queries):
    # `list(:Note)` is every row, `:Note?` the first row or nil, and a scalar type (`:i64`, `?` for nil-able)
    # the first column of the first row.
    def query_returns(node)
      if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :list
        args = node.arguments&.arguments || []
        unless args.size == 1 && node.block.nil? && args[0].is_a?(Prism::SymbolNode) && args[0].unescaped.match?(CAMEL)
          bad(node, "`list(...)` here takes the name of a record, such as list(:Note)")
        end
        return { "shape" => "list", "record" => args[0].unescaped }
      end
      unless node.is_a?(Prism::SymbolNode)
        bad(node, "`returns:` is list(:Record), :Record? or a scalar type (#{Db::SCALARS.map { |t| ":#{t}" }.join(', ')}, with ? for nil-able), got #{nodename(node)}")
      end
      text = node.unescaped
      base = text.delete_suffix("?")
      nilable = text.end_with?("?")
      if base.match?(CAMEL)
        unless nilable
          bad(node, "`returns: :#{text}` would be one row, which may be missing: write `:#{text}?` for the first row or nil, or list(:#{text}) for every row")
        end
        return { "shape" => "one", "record" => base }
      end
      unless Db::SCALARS.include?(base)
        bad(node, "`:#{text}` is not something a query returns: list(:Record), :Record? or a scalar type (#{Db::SCALARS.map { |t| ":#{t}" }.join(', ')}, with ? for nil-able)")
      end
      { "shape" => "scalar", "type" => base, "nilable" => nilable }
    end

    # query :find_note, args: { id: :i64 }, returns: :Note?, sql: "SELECT ... WHERE id = :id" and
    # execute :delete_note, args: { id: :i64 }, sql: "DELETE ...": one statement each. The SQL is kept as
    # written and run as written; the compiler only reads it for its `:name` placeholders (Db::Sql) and
    # refuses a placeholder `args:` does not declare, an argument no placeholder uses, and the other
    # placeholder spellings (`?`, `?NNN`, `$name`, `@name`). A body calls the statement by name with keyword
    # arguments (Body#query_call); what it returns is checked against the database once, as the server starts.
    def add_query(node, pos, kw, srv)
      name = pos[0]
      what = node.name.to_s
      if (earlier = srv["queries"].find { |q| q["name"] == name })
        bad(node, "`#{name}` is already declared by #{earlier['kind'] == 'query' ? 'a query' : 'an execute'}#{first_at(node, @query_nodes[name])}")
      end
      if RESERVED_HELPERS.include?(name) || %w[errors headers render h raw].include?(name)
        bad(node, "`#{name}` is reserved; pick another #{what} name")
      end
      sql = kw[:sql]
      bad(node, "`sql:` is empty") if sql.strip.empty?
      args = kw[:args]
      named = []
      Db::Sql.placeholders(sql).each do |ph|
        case ph.kind
        when :named then named << ph.name
        when :anonymous, :numbered
          bad(node, "#{what} `#{name}` uses a `?` placeholder; write `:name` and declare it in `args:` (SQLite binds `:name` natively, so the SQL stays as written)")
        else
          sigil = ph.kind == :dollar ? "$" : "@"
          bad(node, "#{what} `#{name}` uses `#{sigil}#{ph.name}`; write `:#{ph.name}` instead: `:name` is the placeholder syntax here")
        end
      end
      named.uniq!
      if (missing = (named - args.keys).first)
        declared = args.empty? ? "" : " (declared: #{args.keys.join(', ')})"
        bad(node, "#{what} `#{name}`: the SQL uses `:#{missing}` but `args:` does not declare it#{declared}", word: missing, from: args.keys)
      end
      if (extra = (args.keys - named).first)
        bad(node, "#{what} `#{name}`: `args:` declares `#{extra}` but the SQL has no `:#{extra}` placeholder")
      end
      entry = { "name" => name, "kind" => what, "args" => args.to_a, "sql" => sql,
                "at" => "#{AxumDsl.file_of(node) || @path}:#{node.location.start_line}", **located(node) }
      if what == "query"
        entry["returns"] = kw[:returns]
      else
        entry["shape"] = "execute"
        entry["rtype"] = "i64"
      end
      srv["queries"] << entry
      (@query_nodes ||= {})[name] = node
      (@flags["queries"] ||= {})[name] = entry
    end

    # Once every declaration is read: a statement, a record or a migrations folder needs the `database` they
    # run against, and a `database` that nothing queries is refused like any unused declaration.
    def check_database(srv)
      user = [*@query_nodes&.values, *@record_nodes&.values, @migrations_node].compact.first
      if srv["database"].nil?
        return unless user

        bad(user, "`#{user.name}` needs a database; add `database :sqlite, path: \"app.sqlite3\"` (see docs/database.md)")
      end
      bad(@database_node, "the database is declared but no `query` or `execute` runs against it; add one, or remove `database`") if srv["queries"].empty?
    end

    # What a query returns, resolved against the records (a record may be declared after the query that returns
    # it): the IR then carries the shape, the record's field names the server checks the columns against at
    # startup, and the type a body sees the call as.
    def check_queries(srv)
      srv["records"].each do |r|
        next unless srv["params"].any? { |p| p["name"] == r["name"] }

        bad(@record_nodes.fetch(r["name"]), "record `#{r['name']}` has the same name as a params group; both become a struct of that name")
      end
      srv["queries"].each do |q|
        node = @query_nodes.fetch(q["name"])
        bad(node, "#{q['kind']} `#{q['name']}` has the same name as a rust_fn, cmd_fn or script_fn") if srv["externs"].key?(q["name"])
        ret = q.delete("returns") or next
        if %w[list one].include?(ret["shape"])
          names = srv["records"].map { |r| r["name"] }
          rec = srv["records"].find { |r| r["name"] == ret["record"] } or
            undeclared(node, "query `#{q['name']}` returns record `#{ret['record']}`, which is not declared", ret["record"], names)
          q.merge!("shape" => ret["shape"], "record" => rec["name"], "fields" => rec["fields"].map { |f| f["name"] })
          q["rtype"] = ret["shape"] == "list" ? "list<struct:#{rec['name']}>" : "opt<struct:#{rec['name']}>"
        else
          q.merge!("shape" => "scalar", "type" => ret["type"], "nilable" => ret["nilable"])
          q["rtype"] = ret["nilable"] ? Body::OPT_OF.fetch(ret["type"].to_sym).to_s : ret["type"]
        end
      end
    end
    # After the tools are lowered: emit exactly the binding functions the bodies called, compile the
    # ones written in Ruby, and refuse a use_bindings that nothing uses.
    def lower_bindings(srv)
      used = @flags["used_bindings"] || {}
      @bindings.each do |name, file|
        fns = file.fns.values.select { |f| used["#{file.module_name}.#{f.name}"] }
        if fns.empty?
          bad(@binding_nodes[name], "use_bindings :#{name} is declared but no body calls #{file.module_name}.<method>; remove it or call it")
        end
        backed = fns.count(&:rust)
        if @rust_none_node && (rusty = fns.find(&:rust))
          bad(@binding_nodes[name], "`use_bindings :#{name}`: `#{file.module_name}.#{rusty.name}` is backed by a Rust template, which `set :rust, :none` " \
                                    "(line #{@rust_none_node.location.start_line}) refuses; bindings compiled from Ruby are fine")
        end
        crates = file.crates.map(&:first)
        Notify.add(@path, @binding_nodes[name], "N-BINDING",
                   "bindings/#{name}.rb (sha256 #{AxumDsl.short_digest(file.source)}): #{fns.size} function(s) used, #{backed} backed by Rust" \
                   "#{" (#{crates.join(', ')})" unless crates.empty?}, #{fns.size - backed} compiled from Ruby")
        fns.each do |fn|
          ir = file.descriptor(fn)
          unless fn.rust
            shown = File.join("bindings", File.basename(file.path)) # bindings/words.rb, like other messages
            body = Body.new(shown, { "fields" => [] }, @regexes, srv["externs"], @flags, nil, @binding_modules)
            ir["body"] = body.lower_def(fn)
          end
          srv["binding_fns"] << ir
        end
      end
    end
    OWN_CRATES = %w[axum serde schemars tokio anyhow regex].freeze

    CRATE_FEATURE = /\A[A-Za-z0-9_+.\-]+\z/
    def add_crate(node, pos, srv, kw = {})
      name, ver = pos
      bad(node, "crate name must match [a-z][a-z0-9_-]*") unless name.match?(/\A[a-z][a-z0-9_-]*\z/)
      bad(node, "`#{name}` is already a dependency of every generated server") if OWN_CRATES.include?(name)
      bad(node, "crate version must look like 1, 1.2 or 1.2.3 (optionally ^ or ~)") unless ver.match?(/\A[\^~]?\d+(\.\d+){0,2}\z/)
      bad(node, "duplicate rust_crate `#{name}`") if srv["crates"].any? { |c| c["name"] == name }
      entry = { "name" => name, "version" => ver }
      feats = kw[:features]
      if feats
        bad(node, "`rust_crate #{name.inspect}` needs at least one name in `features:`; leave the keyword out for none") if feats.empty?
        feats.each do |f|
          bad(node, "`rust_crate #{name.inspect}` feature #{f.inspect} must use only letters, digits and _ + . -") unless f.match?(CRATE_FEATURE)
        end
        dup = feats.find { |f| feats.count(f) > 1 }
        bad(node, "`rust_crate #{name.inspect}` lists feature #{dup.inspect} twice") if dup
        entry["features"] = feats
      end
      entry["default_features"] = kw[:default_features] unless kw[:default_features].nil?
      srv["crates"] << entry
    end

    def add_item(node, pos, srv)
      code = pos[0]
      injection(node, "`rust_item`")
      bad(node, "rust_item is empty") if code.strip.empty?
      srv["items"] << code
      srv["item_lines"] << item_body_line(node) # the DSL line the snippet text starts on, so a Rust diagnostic can be mapped back
      Notify.add(@path, node, "N-RUST-INJECTED",
                 "#{code.lines.size} line(s) of injected Rust; the compiler does not check them (cargo does)")
    end

    # The first line of a `rust_item` string: a heredoc body starts on the line after the call.
    def item_body_line(node)
      arg = node.arguments&.arguments&.first
      if arg.respond_to?(:content_loc) && arg.content_loc then arg.content_loc.start_line
      elsif arg.respond_to?(:parts) && arg.parts.first then arg.parts.first.location.start_line # a multi-line <<~ is parts, one per line
      else node.location.start_line
      end
    end

    MAX_RS_BYTES = 1_000_000

    # rust_file "rust/x.rs", as: :x copies a hand-written file into the crate as module x.
    # The path comes from the DSL file, so it is confined to that file's own folder.
    def add_file(node, pos, kw, srv)
      rel = pos[0]
      mod = kw[:as].to_s
      injection(node, "`rust_file`")
      if rel.start_with?("/") || rel.include?("\0") || rel.split("/").include?("..") || !rel.end_with?(".rs")
        bad(node, "rust_file path must be relative, inside the DSL file's folder, without .., and end in .rs")
      end
      bad(node, "module name `#{mod}` is reserved") if %w[tests main].include?(mod)
      bad(node, "duplicate rust_file module `#{mod}`") if srv["modules"].any? { |m| m["name"] == mod }
      real, source = local_source(node, rel, "rust_file")
      srv["modules"] << { "name" => mod, "path" => rel, "source" => source, "uses" => kw[:uses]&.to_s }
      srv["inputs"] << real
      Notify.add(@path, node, "N-RUST-INJECTED",
                 "#{rel} (#{source.lines.size} line(s), sha256 #{AxumDsl.short_digest(source)}) loaded as module `#{mod}`; the compiler does not check it")
    end

    # The text of a file a declaration names, as [real path, text]. The path comes from the DSL file, so it is
    # confined to that file's own folder; an open editor buffer stands in for the disk (Lsp::Sources).
    def local_source(node, rel, what)
      base = dir_of(node)
      full = File.expand_path(rel, base)
      bad(node, "#{what} not found: #{rel}") unless Lsp::Sources[full] || File.file?(full)
      real = File.file?(full) ? File.realpath(full) : full
      bad(node, "#{what} must stay inside #{base}") unless real.start_with?(base + File::SEPARATOR)
      buffered = Lsp::Sources[real]
      size = buffered ? buffered.bytesize : File.size(real)
      bad(node, "#{what} is larger than #{MAX_RS_BYTES} bytes") if size > MAX_RS_BYTES
      source = buffered || File.read(real, encoding: "UTF-8")
      bad(node, "#{what} is not valid UTF-8") unless source.valid_encoding?
      [real, source]
    end

    # The path a `static` mount or a `serve_file` route answers on: written out, with no capture, wildcard
    # or regex character, because the axum service under it reads the request path, not the parameters.
    def service_path(node, path, what)
      bad(node, "#{what} must start with /, got #{path.inspect}") unless path.start_with?("/")
      if (m = path.match(/[:*?()\[\]{}+^$|\\]/))
        bad(node, "#{what} #{path.inspect} holds #{m[0].inspect}; a path a file service answers is written out, with no `:name` capture, `*splat` or regex character")
      end
      path
    end

    # The real path of a declared asset (a `static` dir or a `serve_file` from), confined to the folder of
    # the DSL file that named it exactly as rust_file and file are: a relative path, without .., whose real
    # path stays inside that folder.
    def asset_path(node, rel, what)
      if rel.start_with?("/") || rel.include?("\0") || rel.split("/").include?("..")
        bad(node, "#{what} must be a relative path inside the DSL file's folder, without .., got #{rel.inspect}")
      end
      base = dir_of(node)
      full = File.expand_path(rel, base)
      bad(node, "#{what} not found: #{rel}") unless File.exist?(full)
      real = File.realpath(full)
      bad(node, "#{what} must stay inside #{base}") unless real.start_with?(base + File::SEPARATOR)
      real
    end

    # One file of a declared asset, held in the IR as its path in the crate and its text, for Emit to write
    # beside the crate's own Cargo.toml: that is where the running service looks for it, because its working
    # directory is the crate directory. The text is what the compiler read, so an open editor buffer stands
    # in for the file on disk, as it does for every other input.
    ASSET_MAX_BYTES = 8 * 1024 * 1024
    # The crate's own files and folders: an asset at one of these paths, or under one, would overwrite what
    # Emit writes there (the crate manifest, the lock file, the sources, the build output, the provenance
    # map) or what a build records after it (the emitted-file manifest).
    CRATE_OWNED = ["Cargo.toml", "Cargo.lock", "src", "target", CargoBuild::MAP, Manifest::NAME].freeze
    def add_asset(node, srv, crate_path, real, text: nil)
      owned = crate_path.split("/").reject { |s| s.empty? || s == "." }.first
      if CRATE_OWNED.include?(owned)
        bad(node, "#{crate_path} would overwrite #{owned}, which the emitted crate writes itself; give the asset another path (not Cargo.toml, Cargo.lock, src/, target/, #{CargoBuild::MAP} or #{Manifest::NAME})")
      end
      text ||= asset_text(real)
      bad(node, "#{crate_path} is larger than #{ASSET_MAX_BYTES} bytes") if text.bytesize > ASSET_MAX_BYTES
      srv["assets"].reject! { |a| a["path"] == crate_path }
      srv["assets"] << { "path" => crate_path, "text" => text }
      srv["inputs"] << real
    end

    # The bytes of one declared asset: an open editor buffer stands in for the file on disk, as it does for
    # every other input the compiler reads.
    def asset_text(real) = Lsp::Sources[real] || File.binread(real)

    # The name a file is served under with `digest: true`: its own name with `-<12 hex digits of SHA-256>`
    # before the extension, so `campfire.css` becomes `campfire-3f9a0c1b2d4e.css`. The digest is of the bytes
    # the compiler read (the same short digest a build notice names), so the name changes exactly when the file
    # does -- which is what makes a far-future Cache-Control safe on it.
    def fingerprinted(rel, text)
      dir = File.dirname(rel)
      base = File.basename(rel)
      ext = File.extname(base)
      stem = ext.empty? ? base : base.delete_suffix(ext)
      name = "#{stem}-#{AxumDsl.short_digest(text)}#{ext}"
      dir == "." ? name : "#{dir}/#{name}"
    end

    # Every file under a declared asset directory, as [path in the crate, real path] pairs, sorted depth
    # first, so two compilations of one file copy the same bytes in the same order. A symlink that leaves the
    # directory is refused rather than copied.
    def asset_dir_files(node, real_dir, rel_dir, base)
      out = []
      Dir.children(real_dir).sort.each do |child|
        full = File.join(real_dir, child)
        rel = File.join(rel_dir, child)
        if File.directory?(full)
          out.concat(asset_dir_files(node, full, rel, base))
        elsif File.file?(full)
          real = File.realpath(full)
          bad(node, "asset #{rel} must stay inside #{base}") unless real.start_with?(base + File::SEPARATOR)
          out << [rel, real]
        else
          bad(node, "asset #{rel} is neither a regular file nor a directory")
        end
      end
      out
    end

    # static "/assets", dir: "public" mounts a directory of files at a path prefix. tower-http's ServeDir
    # answers every request under the prefix from the directory, guessing each file's content type from its
    # extension and answering an empty 404 for a missing file and for a path holding `..` or a backslash.
    # The directory is copied into the emitted crate at its own relative path (add_asset), and the emitted
    # binary has to run with the crate directory as its working directory to find it.
    #
    # `digest: true` opts into fingerprinted names: every copied file is written into the crate as
    # `<stem>-<12 hex digits of the file's SHA-256><ext>` and only that name is copied, so the undigested path
    # is a 404 and a response may carry a far-future Cache-Control. A view names one with
    # `{{ asset_path "campfire.css" }}` (Body#segment_parts), which resolves against the one digest mount. A
    # mount without the keyword copies and serves exactly the paths it always did.
    def add_static(node, prefix, dir, kw, srv)
      pre = service_path(node, prefix, "a static mount path")
      if pre == "/" && kw[:skip].to_a.any?
        bad(node, "`static \"/\"` is axum's fallback for every GET path, so a `skip:` on it cannot be scoped; " \
                  "mount the directory at a prefix such as \"/assets\" and skip that mount instead")
      end
      srv["statics"].each do |s|
        next unless pre == s["prefix"] || pre.start_with?("#{s['prefix']}/") || s["prefix"].start_with?("#{pre}/")

        bad(node, "the static mount #{pre.inspect} overlaps `static #{s['prefix'].inspect}, dir: #{s['dir'].inspect}`; axum answers each path with one service, and two mounts over one path panic when the router is built")
      end
      real = asset_path(node, dir, "static dir")
      bad(node, "static dir #{dir.inspect} is not a directory") unless File.directory?(real)
      (@static_nodes ||= {})[pre] = node
      files = asset_dir_files(node, real, dir, real)
      if kw[:digest]
        base = dir.chomp("/")
        urls = {}
        used = {}
        files.each do |crate_path, file|
          text = asset_text(file)
          rel = crate_path.delete_prefix("#{base}/")
          finger = fingerprinted(rel, text)
          target = "#{base}/#{finger}"
          if used.key?(target)
            bad(node, "two files under static dir #{dir.inspect} both fingerprint to #{target}; rename one")
          end
          used[target] = true
          add_asset(node, srv, target, file, text: text)
          urls[rel] = pre == "/" ? "/#{finger}" : "#{pre}/#{finger}"
        end
        (@flags["asset_mounts"] ||= []) << pre
        (@flags["asset_urls"] ||= {})[pre] = urls
        entry = { "prefix" => pre, "dir" => dir, "files" => files.size, "digest" => true, **located(node) }
        entry["skip"] = kw[:skip] if kw[:skip]
        srv["statics"] << entry
      else
        files.each { |crate_path, file| add_asset(node, srv, crate_path, file) }
        entry = { "prefix" => pre, "dir" => dir, "files" => files.size, **located(node) }
        entry["skip"] = kw[:skip] if kw[:skip]
        srv["statics"] << entry
      end
    end

    # serve_file "/report.txt", from: "public/report.txt": one route answered by one file, copied into the
    # crate at its own relative path like a static mount. It is deliberately declarative: a body-level
    # send_file would have to await a file service, and the body language has no such await.
    def add_serve_file(node, path, from, srv)
      route = service_path(node, path, "a serve_file path")
      bad(node, "duplicate serve_file #{route.inspect}") if srv["serve_files"].any? { |f| f["path"] == route }
      real = asset_path(node, from, "serve_file from")
      bad(node, "serve_file from #{from.inspect} is a directory; mount a directory with `static \"/assets\", dir: ...`") if File.directory?(real)
      srv["serve_files"] << { "path" => route, "from" => from, **located(node) }
      add_asset(node, srv, from, real)
    end

    # openapi "/openapi.json", title: "Notes", version: "1.0.0": the service answers GET at that path with an
    # OpenAPI 3.1 document of its routes, written by the compiler (OpenApi, lib/axum_dsl/openapi.rb). The path
    # is written out like a serve_file's; `title:` and `version:` default to the server's name and version,
    # which the document takes when the crate is emitted, because `server` may come after this line. Whether
    # the path clashes with a route is decided once the routes are read (check_openapi).
    def add_openapi(node, path, kw, srv)
      doc_path = service_path(node, path, "an openapi path")
      bad(node, "duplicate `openapi`#{first_at(node, @openapi_node)}; one document is served per service") if srv["openapi"]
      %i[title version].each do |key|
        bad(node, "`openapi` `#{key}:` must not be empty") if kw[key] && kw[key].strip.empty?
      end
      srv["openapi"] = { "path" => doc_path, "title" => kw[:title], "version" => kw[:version], **located(node) }.compact
      @openapi_node = node
    end

    # The document is a GET route, so a route (or a mount, or a served file) that answers its path would make
    # axum panic when it builds the router; the compiler refuses the pair here, where it can name both.
    def check_openapi(srv)
      decl = srv["openapi"] or return
      node = @openapi_node
      refuse_route_mount_clash(node, decl["path"], srv)
      srv["routes"].each do |route|
        next unless route["path"] == decl["path"] && %w[get head].include?(route["method"])

        bad(node, "the openapi document is served at #{decl['path'].inspect}, which `#{route['method']} #{route['path']}` (line #{route['line']}) already answers; give the document another path")
      end
      Notify.add(@path, node, "N-OPENAPI", "GET #{decl['path']} serves an OpenAPI 3.1 document of #{srv['routes'].size} operation(s)")
    end

    # use_layer :compression (or :cors, :timeout, :trace, :fetch_metadata, :csrf, :private_cache): name a
    # middleware the whole router is wrapped in. A layer answers every route, and the emitter fixes the
    # order it puts them on the router (Emit::LAYER_ORDER), so where the declaration sits in the file does
    # not change the service.
    # A layer's own keywords are checked here, because SIG takes the same keyword list for every name:
    # `:cors` takes `origins:` (a list of origins, each a string that looks like https://example.com;
    # without it the layer is permissive) and `:timeout` takes `secs:` (a positive whole number of
    # seconds), `:trace` takes `forwarded:` (true logs the visitor's address from X-Forwarded-For
    # instead of the peer's), `:rate_limit` takes `per:` (window seconds), `burst:` (requests in it)
    # and an optional `path:`, and `:csrf` takes nothing: it needs the `cookies secret:` declaration (checked
    # in check_cookies), and its runtime is Csrf::RUNTIME. `:private_cache` appends cache headers to every
    # response, or takes `except:` to leave them off the public files under a `static` mount. A name declared
    # twice is refused rather than emitted twice.
    LAYER_KEYWORDS = { "compression" => [], "cors" => [:origins], "timeout" => [:secs], "trace" => [:forwarded],
                       "fetch_metadata" => [], "csrf" => [], "rate_limit" => [:per, :burst, :path],
                       "private_cache" => [:except] }.freeze
    LAYER_ORIGIN = /\A[A-Za-z][A-Za-z0-9+.\-]*:\/\/[!-~]+\z/
    def add_layer(node, pos, kw, srv)
      name = pos[0].to_s
      allowed = LAYER_KEYWORDS.fetch(name)
      (kw.keys - allowed).each do |extra|
        takes = allowed.empty? ? "takes no keywords" : "takes #{allowed.map { |k| "`#{k}:`" }.join(' and ')}"
        bad(node, "`use_layer :#{name}` #{takes}, so it does not take `#{extra}:`")
      end
      earlier = srv["layers"].find { |l| l["name"] == name }
      bad(node, "duplicate `use_layer :#{name}`#{first_at(node, earlier)}") if earlier
      entry = { "name" => name, **located(node) }
      case name
      when "cors"
        origins = kw[:origins]
        if origins
          bad(node, "`use_layer :cors` needs at least one origin in `origins:`; an empty list allows no origin") if origins.empty?
          origins.each do |origin|
            bad(node, "`use_layer :cors` origin #{origin.inspect} must look like \"https://example.com\"") unless origin.match?(LAYER_ORIGIN)
          end
          entry["origins"] = origins
        end
      when "timeout"
        secs = kw[:secs]
        bad(node, "`use_layer :timeout` needs `secs:` (a positive whole number of seconds)") if secs.nil?
        bad(node, "`use_layer :timeout` needs a positive `secs:`, got #{secs}") if secs && secs < 1
        entry["secs"] = secs
      when "trace"
        entry["forwarded"] = true if kw[:forwarded]
      when "rate_limit"
        per = kw[:per]
        burst = kw[:burst]
        bad(node, "`use_layer :rate_limit` needs `per:` (the window in seconds)") if per.nil?
        bad(node, "`use_layer :rate_limit` needs a positive `per:`, got #{per}") if per && per < 1
        bad(node, "`use_layer :rate_limit` needs `burst:` (how many requests the window allows)") if burst.nil?
        bad(node, "`use_layer :rate_limit` needs a positive `burst:`, got #{burst}") if burst && burst < 1
        limit_path = kw[:path]
        if limit_path
          bad(node, "`use_layer :rate_limit` `path:` must start with /, got #{limit_path.inspect}") unless limit_path.start_with?("/")
          bad(node, "`use_layer :rate_limit` `path:` is one path and cannot carry ? or #") if limit_path.include?("?") || limit_path.include?("#")
        end
        entry["per"] = per
        entry["burst"] = burst
        entry["path"] = limit_path if limit_path
        # The limiter counts per client address, from the same runtime `request_ip` reads.
        (@flags["builtins"] ||= {})["request_ip"] = true
      when "csrf"
        # The token is a signed cookie (hmac, whatever the service's default format is), minted by the
        # random_token runtime; a view writes it with `{{ csrf_token }}`, so the body sees the flag.
        @flags["csrf"] = true
        (@flags["builtins"] ||= {})["random_token"] = true
        use = (@flags["cookie_use"] ||= {})
        use["read"] = true
        use["set"] = true
        reads = (use["read_formats"] ||= [])
        reads << "hmac" unless reads.include?("hmac")
        writes = (use["set_formats"] ||= [])
        writes << "hmac" unless writes.include?("hmac")
        @csrf_node = node
      when "private_cache"
        # `except:` is the explicit list of public static prefixes that leave the layer off. It stays on for
        # every other response, so a page with a session or a CSRF token cannot be exempted by accident.
        except = kw[:except]
        if except
          if except.empty?
            bad(node, "`use_layer :private_cache` `except:` needs at least one path prefix; drop the keyword to keep the layer on every response")
          end
          except.each do |prefix|
            unless prefix.start_with?("/")
              bad(node, "`use_layer :private_cache` `except:` entry #{prefix.inspect} must start with /, a path prefix as `static` writes it")
            end
            if prefix != "/" && prefix.end_with?("/")
              bad(node, "`use_layer :private_cache` `except:` entry #{prefix.inspect} must not end with /; name the static mount's prefix without it")
            end
            if prefix.match?(/[?#*{}]/)
              bad(node, "`use_layer :private_cache` `except:` entry #{prefix.inspect} must be one literal path prefix without ? # * { or }")
            end
          end
          duplicated = except.tally.find { |_, count| count > 1 }
          bad(node, "`use_layer :private_cache` `except:` lists #{duplicated[0].inspect} twice") if duplicated
          entry["except"] = except
        end
        @private_cache_node = node
      end
      srv["layers"] << entry
    end

    # `use_layer :private_cache, except: ["/assets"]`: the layer stays on for every response except a GET
    # under one of the listed prefixes, and each prefix must be served by a `static` mount (the mount itself,
    # or a path inside it at a segment boundary). Only public files may leave the layer off: a route's page
    # can carry a session or a CSRF token, so a prefix no mount serves is refused rather than guessed at. A
    # route under a mount's prefix is already refused by refuse_route_mount_clash, which is why this needs
    # no second route-overlap rule. Statics and routes are both complete when this runs.
    def check_private_cache_except(srv)
      entry = srv["layers"].find { |l| l["name"] == "private_cache" }
      return unless entry && entry["except"]

      entry["except"].each do |prefix|
        if prefix == "/"
          bad(@private_cache_node, "`use_layer :private_cache` `except: [\"/\"]` is refused: the layer would not apply anywhere; name the static mount's prefix instead")
        end
        next if srv["statics"].any? { |s| s["prefix"] == prefix || prefix.start_with?("#{s['prefix']}/") }

        bad(@private_cache_node, "`use_layer :private_cache` `except:` entry #{prefix.inspect} is not served by a `static` mount; only public files may leave the layer off: name a static mount's prefix, or drop the prefix")
      end
    end

    # A route and a mount (or a served file) that answer one path would panic inside axum when it builds the
    # router, so the compiler refuses the pair, where it can name both declarations.
    def refuse_route_mount_clash(node, path, srv)
      srv["statics"].each do |s|
        next if s["prefix"] == "/"
        next unless path == s["prefix"] || path.start_with?("#{s['prefix']}/")

        bad(node, "route path #{path.inspect} is under the `static #{s['prefix'].inspect}, dir: #{s['dir'].inspect}` mount, which answers every path under that prefix; the route would never run")
      end
      srv["serve_files"].each do |f|
        next unless f["path"] == path

        bad(node, "route path #{path.inspect} is already served by `serve_file #{f['path'].inspect}, from: #{f['from'].inspect}`")
      end
    end

    # file "python/x.py", as: :x: a file the server reads from disk on each call, as file_text(:x). Its
    # `entries:` are the Python functions bodies name with entry(:x, :f); each is checked here against the
    # file's `def`s, and with the args check on, its parameters are read for entry_args.
    def add_any_file(node, pos, kw, srv)
      rel = pos[0]
      name = kw[:as].to_s
      if rel.start_with?("/") || rel.include?("\0") || rel.split("/").include?("..")
        bad(node, "file path must be relative, inside the DSL file's folder, without ..")
      end
      bad(node, "duplicate file `#{name}`#{first_at(node, srv["files"].find { |f| f["name"] == name })}") if srv["files"].any? { |f| f["name"] == name }
      if kw[:env] && !kw[:env].match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        bad(node, "`env:` is an environment variable name, such as \"BLENDER_PYTHON\"")
      end
      real, source = local_source(node, rel, "file")
      entries = kw[:entries] || []
      twice = entries.find { |e| entries.count(e) > 1 }
      bad(node, "`#{twice}` is listed twice in entries:") if twice
      bad(node, "`entries:` names Python functions, but #{rel} is not a .py file") if !entries.empty? && !rel.end_with?(".py")
      unchecked = (kw[:unchecked] || []).uniq
      sigs = entries.to_h { |e| [e, python_entry(node, rel, source, e, !unchecked.include?("args"))] }
      record = { "name" => name, "path" => rel, "real" => real, "env" => kw[:env], "entries" => entries,
                 "unchecked" => unchecked, "sigs" => sigs, **located(node) }
      srv["files"] << record
      (@flags["files"] ||= {})[name] = record
      (@file_nodes ||= {})[name] = node
      add_asset(node, srv, rel, real) # the crate carries a copy at its declared path, read from the working directory
      return if unchecked.empty?

      Notify.add(@path, node, "N-FILE-UNCHECKED", "#{rel}: the #{unchecked.join(' and ')} check(s) are turned off with unchecked:")
    end
    # One `entries:` name: its top-level `def` must exist with every parameter and the return annotated. With
    # the args check on, its parameters are read too: one TypedDict parameter (its fields) or plain parameters.
    def python_entry(node, rel, source, name, args_checked)
      unless defined?(PythonSig)
        # the python_sig wave is not loaded yet: the entries are accepted but left unchecked
        return { "line" => nil, "checked" => false, "header" => "", "dict" => "", "dict_lines" => [] }
      end
      sig = begin
        PythonSig.signature(source, name)
      rescue PythonSig::Unreadable => e
        bad(node, "#{rel}: #{e.message}")
      end
      bad(node, "`#{name}` is listed in entries: but #{rel} has no top-level `def #{name}(`") unless sig
      if sig.returns.nil? || sig.params.any? { |p| p.annotation.nil? }
        bad(node, "`#{sig.header.delete_suffix(':')}` in #{rel} needs a type on each parameter and a return type (`-> ...`)")
      end
      # header and dict_lines are what the running server compares the file against; an empty header means only
      # that the `def` still exists is checked (the args check is off).
      entry = { "line" => sig.line, "checked" => args_checked, "header" => args_checked ? sig.header : "", "dict" => "", "dict_lines" => [] }
      return entry unless args_checked

      begin
        dict = sig.params.size == 1 ? PythonSig.typed_dict(source, sig.params[0].annotation) : nil
        if dict
          entry.merge!("shape" => "dict", "of" => sig.params[0].annotation, "dict" => sig.params[0].annotation,
                       "dict_lines" => dict.map { |f| [f.name, f.source] },
                       "fields" => dict.map { |f| python_field(f.name, f.type, f.required, f.line) })
        else
          entry.merge!("shape" => "params", "of" => "def #{name}",
                       "fields" => sig.params.map { |p| python_field(p.name, PythonSig.parse_type(p.annotation, "def #{name} `#{p.name}`"), p.default.nil?, sig.line) })
        end
      rescue PythonSig::Unreadable => e
        bad(node, "#{rel}: #{e.message}")
      end
      entry
    end

    def python_field(name, type, required, line)
      { "name" => name, "base" => type.base.to_s, "nilable" => type.nilable, "text" => type.text, "required" => required, "line" => line,
        "literals" => type.literals }
    end
    PROGRAM_RE = %r{\A[A-Za-z0-9._+/-]+\z}
    # interpreter => [flag that takes the source, extra argv before the call arguments]
    INTERPRETERS = { "python3" => ["-c"], "python" => ["-c"], "ruby" => ["-e"], "perl" => ["-e"],
                     "node" => ["-e"], "sh" => ["-c", "_"], "bash" => ["-c", "_"] }.freeze

    def add_cmd(node, pos, kw, srv)
      refuse_subproc_async(node, kw[:async])
      register_subproc(node, pos[0], kw[:program], kw[:argv] || [], kw[:args], (kw[:pass] || :argv).to_s, srv, "command")
    end

    def add_script(node, pos, kw, srv)
      refuse_subproc_async(node, kw[:async])
      interp = kw[:interpreter]
      flags = kw[:flag] ? [kw[:flag]] : INTERPRETERS[File.basename(interp)]
      bad(node, "script_fn needs flag: for interpreter `#{interp}` (known: #{INTERPRETERS.keys.join(', ')})") unless flags
      bad(node, "script_fn code is empty") if kw[:code].strip.empty?
      register_subproc(node, pos[0], interp, [flags[0], kw[:code], *flags.drop(1)], kw[:args], "argv", srv, "inline script")
    end

    # A subprocess is exposed to bodies as a rust_fn returning :string, so rust(:name, ...) works.
    def register_subproc(node, name, program, prefix, args, pass, srv, kind)
      bad(node, "program `#{program}` may only contain letters, digits and . _ + - /") unless program.match?(PROGRAM_RE)
      bad(node, "`#{name}` is already declared#{first_at(node, @extern_nodes&.[](name))}") if srv["externs"].key?(name)
      bad(node, "argv entries must not contain NUL") if prefix.any? { |s| s.include?("\0") }
      bad(node, "pass: :stdin needs exactly one :string argument") if pass == "stdin" && args != ["string"]
      srv["subprocs"] << { "name" => name, "program" => program, "argv" => prefix, "args" => args, "pass" => pass,
                           **located(node) }
      srv["externs"][name] = { "args" => args, "returns" => "string", "from" => nil }
      (@extern_nodes ||= {})[name] = node
      Notify.add(@path, node, "N-EXEC-INJECTED",
                 "#{kind} runs as subprocess `#{program}` on every call; the machine running the server needs it, and there is no sandbox")
    end

    def add_extern(node, pos, kw, srv)
      injection(node, "`rust_fn`")
      bad(node, "duplicate rust_fn `#{pos[0]}`#{first_at(node, @extern_nodes&.[](pos[0]))}") if srv["externs"].key?(pos[0])
      (@extern_nodes ||= {})[pos[0]] = node
      srv["externs"][pos[0]] = { "args" => kw[:args], "returns" => HELPER_TYPES.fetch(kw[:returns].to_sym).to_s, "from" => kw[:from],
                                 "async" => kw[:async] ? true : false,
                                 "async_reason" => (kw[:async] ? "is declared `async: true`" : nil) }
    end

    # Async is inferred: a function is async iff it calls an async function. A helper is async when its
    # body calls an async helper, rust_fn or binding function; the result is the fixpoint over the
    # helper-call graph. A cycle among async helpers is refused (an async function that calls itself
    # would need `Box::pin`, which the DSL does not emit). A helper may only call helpers declared above
    # it, so a real cycle is unreachable from a well-formed file; the guard stays as a backstop.
    def resolve_helper_async(helper_nodes, srv)
      names = helper_nodes.map { |_n, pos, _k, _b| pos[0] }
      node_for = helper_nodes.to_h { |n, pos, _k, _b| [pos[0], n] }
      edges = {}
      direct = {}
      helper_nodes.each do |_n, pos, _kw, blk|
        name = pos[0]
        edges[name] ||= []
        walk_nodes(blk.body) do |n|
          next unless n.is_a?(Prism::CallNode)

          if n.receiver.nil? && names.include?(n.name.to_s)
            edges[name] << n.name.to_s unless edges[name].include?(n.name.to_s)
          elsif n.receiver.nil? && n.name == :rust
            sym = n.arguments&.arguments&.first
            direct[name] = true if sym.is_a?(Prism::SymbolNode) && srv["externs"][sym.unescaped]&.dig("async")
          elsif n.receiver.is_a?(Prism::ConstantReadNode)
            fn = @binding_modules[n.receiver.name.to_s]&.fns&.[](n.name.to_s)
            direct[name] = true if fn&.async
          end
        end
      end
      async = names.to_h { |n| [n, direct[n] || false] }
      changed = true
      while changed
        changed = false
        names.each do |n|
          next if async[n]

          if edges[n].any? { |m| async[m] }
            async[n] = true
            changed = true
          end
        end
      end
      cycle = async_helper_cycle(names, edges, async)
      if cycle
        path = cycle.join(" -> ")
        bad(node_for.fetch(cycle[0]),
            "helper `#{cycle[0]}` is async and is part of a recursive helper cycle (#{path}); " \
            "an async function in a cycle would need Box::pin, which the DSL does not emit. Break the cycle.")
      end
      async
    end

    # Every node under `node`, for the async helper scan.
    def walk_nodes(node, &blk)
      return unless node

      yield node
      node.compact_child_nodes.each { |c| walk_nodes(c, &blk) }
    end

    # The first cycle among async helpers (`a -> b -> ... -> a`), or nil.
    def async_helper_cycle(names, edges, async)
      state = {}
      stack = []
      cycle = nil
      visit = lambda do |n|
        return if cycle

        state[n] = :visiting
        stack.push(n)
        edges[n].each do |m|
          next unless names.include?(m) && async[m]

          if state[m] == :visiting
            cycle = stack[stack.index(m)..] + [m]
            return
          elsif state[m].nil?
            visit.call(m)
            return if cycle
          end
        end
        stack.pop
        state[n] = :done
      end
      names.each { |n| visit.call(n) if async[n] && state[n].nil? }
      cycle
    end

    def refuse_subproc_async(node, async)
      return unless async

      bad(node, "`async: true` is not supported on a subprocess: cmd_fn and script_fn run a blocking " \
                "std::process::Command, so the call would block the async runtime; async subprocesses are planned for a later wave")
    end

    def refuse_helper_async(node, name, async)
      return unless async

      bad(node, "`async: true` is not supported on helper `#{name}`: async is inferred from the body, " \
                "so remove `async: true` and call an async rust_fn or binding instead")
    end

    NUMERIC_TYPES = %w[i32 i64 f64].freeze
    # The types a path segment can carry: axum's Path<T> reads every `in: :path` field from one string, so a
    # list, a map or a nested object cannot be one. params_decl refuses those by name.
    SCALAR_FIELD_TYPES = %w[string i32 i64 f64 bool].freeze
    # Options on a `field`: optional, and JSON schema constraints the generated server also enforces.
    # Each option has to make sense for the field's type, so `min:` on a string is refused here.
    LIST_TYPES = %w[string_list i64_list f64_list].freeze

    def field_options(node, field, opts, srv, pool = srv["params"], label = "params")
      type = field["type"]
      if (oname = CompositeTypes.object_list_name(type)) # a list of another params struct, declared above
        bad(node, "#{label} `#{oname}` is not declared above this field; declare it first") unless pool.any? { |x| x["name"] == oname }
        bad(node, "`default:` does not apply to a list of objects") if opts.key?(:default)
        field["optional"] = true if opts[:optional]
        stray = opts.keys - %i[description optional min_items max_items]
        bad(node, "`#{stray.first}:` does not apply to a list of objects") unless stray.empty?
        %i[min_items max_items].each { |key| field[key.to_s] = opts[key] if opts.key?(key) }
        bad(node, "`min_items:` is above `max_items:`") if field["min_items"] && field["max_items"] && field["min_items"] > field["max_items"]
        return
      end
      if type.match?(CAMEL) # a nested object: the other struct must be declared above, so schemas cannot loop
        bad(node, "#{label} `#{type}` is not declared above this field; declare it first") unless pool.any? { |x| x["name"] == type }
        if opts.key?(:default)
          bad(node, "`default:` and `optional:` cannot be combined (a field with a default is always present)") if opts[:optional]
          bad(node, "`default:` does not apply to a nested object field")
        end
        field["optional"] = true if opts[:optional]
        stray = opts.keys - %i[description optional]
        bad(node, "`#{stray.first}:` does not apply to a nested object field") unless stray.empty?
        return
      end
      if (mname = CompositeTypes.object_map_name(type)) # a map of another params struct, declared above
        bad(node, "#{label} `#{mname}` is not declared above this field; declare it first") unless pool.any? { |x| x["name"] == mname }
      end
      field["optional"] = true if opts[:optional]
      %i[min max exclusive_min exclusive_max multiple_of].each do |key|
        next unless opts.key?(key)

        bad(node, "`#{key}:` applies to numeric fields, not :#{type}") unless NUMERIC_TYPES.include?(type)
        if key == :multiple_of
          bad(node, "`multiple_of:` applies to :i32 and :i64 fields, not :#{type}") if type == "f64"
          bad(node, "`multiple_of:` must be a positive integer") unless opts[key].is_a?(Integer) && opts[key].positive?
        else
          bad(node, "`#{key}:` must be an integer for an :#{type} field") if type != "f64" && !opts[key].is_a?(Integer)
          bad(node, "`#{key}:` does not fit in an :i32 field") if type == "i32" && !(-2**31..2**31 - 1).cover?(opts[key])
        end
        field[key.to_s] = opts[key]
      end
      bad(node, "`min:` is above `max:`") if field["min"] && field["max"] && field["min"] > field["max"]
      bad(node, "`min:` and `exclusive_min:` both set a lower bound; keep one") if field["min"] && field["exclusive_min"]
      bad(node, "`max:` and `exclusive_max:` both set an upper bound; keep one") if field["max"] && field["exclusive_max"]
      bad(node, "`exclusive_min:` is not below `exclusive_max:`") if field["exclusive_min"] && field["exclusive_max"] && field["exclusive_min"] >= field["exclusive_max"]
      %i[min_length max_length pattern enum format].each do |key|
        bad(node, "`#{key}:` applies to :string fields, not :#{type}") if opts.key?(key) && type != "string"
      end
      %i[min_items max_items].each do |key|
        next unless opts.key?(key)

        bad(node, "`#{key}:` applies to list fields, not :#{type}") unless LIST_TYPES.include?(type) || CompositeTypes.map_field_text?(type)
        field[key.to_s] = opts[key]
      end
      bad(node, "`min_items:` is above `max_items:`") if field["min_items"] && field["max_items"] && field["min_items"] > field["max_items"]
      %i[min_length max_length].each { |key| field[key.to_s] = opts[key] if opts.key?(key) }
      if field["min_length"] && field["max_length"] && field["min_length"] > field["max_length"]
        bad(node, "`min_length:` is above `max_length:`")
      end
      field["format"] = opts[:format].to_s.tr("_", "-") if opts.key?(:format)
      if opts.key?(:pattern)
        field["pattern"] = opts[:pattern]
        id = "RE_#{@regexes.size + 1}"
        rust = begin
          RegexTranslate.translate(opts[:pattern])
        rescue RegexTranslate::Unsupported => e
          bad(node, "unsupported regex in `pattern:`: #{e.message}")
        end
        @regexes << { "id" => id, "pattern" => rust }
        field["pattern_id"] = id
      end
      if opts.key?(:enum)
        bad(node, "`enum:` needs at least one value") if opts[:enum].empty?
        bad(node, "`enum:` values must be distinct") unless opts[:enum].uniq.size == opts[:enum].size
        field["enum"] = opts[:enum]
      end
      field_default(node, field, opts[:default]) if opts.key?(:default)
    end

    DEFAULT_KINDS = { "string" => "a string", "i32" => "an integer", "i64" => "an integer", "f64" => "a number",
                      "bool" => "true or false" }.freeze
    # A list field's default is a literal list whose items are the field's element type; [] is allowed.
    LIST_DEFAULT_KINDS = {
      "string_list" => ["a list of strings, such as [\"a\", \"b\"]", ->(v) { v.is_a?(String) }],
      "i64_list" => ["a list of integers, such as [1, 2]", ->(v) { v.is_a?(Integer) && v.bit_length < 64 }],
      "f64_list" => ["a list of numbers, such as [1.5, 2]", ->(v) { v.is_a?(Numeric) }]
    }.freeze
    # The default of a :string_list, :i64_list or :f64_list field (rmcp-for-blender gap #15): an optional list was
    # otherwise `optional: true` plus `|| []` in every body that read it.
    def list_default(node, field, value)
      type = field["type"]
      words, item_ok = LIST_DEFAULT_KINDS.fetch(type)
      bad(node, "`default:` must be #{words} for the :#{type} field") unless value.is_a?(Array) && value.all?(&item_ok)
      bad(node, "`default:` has fewer items than `min_items:`") if field["min_items"] && value.size < field["min_items"]
      bad(node, "`default:` has more items than `max_items:`") if field["max_items"] && value.size > field["max_items"]
      field["default"] = value
    end

    # A default makes the field always present (so it is not nil-able in the body) and is advertised in the
    # schema. It has to be a value the field would accept, so it is checked against the other options.
    def field_default(node, field, value)
      type = field["type"]
      bad(node, "`default:` and `optional:` cannot be combined (a field with a default is always present)") if field["optional"]
      return list_default(node, field, value) if LIST_DEFAULT_KINDS.key?(type)

      bad(node, "`default:` applies to :string, :i32, :i64, :f64, :bool and :*_list fields, not :#{type}") unless DEFAULT_KINDS.key?(type)
      bad(node, "`default:` must be #{DEFAULT_KINDS[type]} for the :#{type} field, not a list") if value.is_a?(Array)
      ok = case type
           when "string" then value.is_a?(String)
           when "i32", "i64" then value.is_a?(Integer)
           when "f64" then value.is_a?(Integer) || value.is_a?(Float)
           else value == true || value == false
           end
      bad(node, "`default:` must be #{DEFAULT_KINDS[type]} for the :#{type} field") unless ok
      bad(node, "`default:` does not fit in an :i32 field") if type == "i32" && !(-2**31..2**31 - 1).cover?(value)
      bad(node, "`default:` is below `min:`") if field["min"] && value < field["min"]
      bad(node, "`default:` is above `max:`") if field["max"] && value > field["max"]
      bad(node, "`default:` is not above `exclusive_min:`") if field["exclusive_min"] && value <= field["exclusive_min"]
      bad(node, "`default:` is not below `exclusive_max:`") if field["exclusive_max"] && value >= field["exclusive_max"]
      bad(node, "`default:` is not a multiple of `multiple_of:`") if field["multiple_of"] && value % field["multiple_of"] != 0
      if value.is_a?(String)
        bad(node, "`default:` is shorter than `min_length:`") if field["min_length"] && value.length < field["min_length"]
        bad(node, "`default:` is longer than `max_length:`") if field["max_length"] && value.length > field["max_length"]
        bad(node, "`default:` is not one of the `enum:` values") if field["enum"] && !field["enum"].include?(value)
        if field["pattern"] && !Regexp.new(field["pattern"]).match?(value)
          bad(node, "`default:` #{value.inspect} for field `#{field['name']}` does not match the `pattern:` #{field['pattern'].inspect}")
        end
      end
      field["default"] = value
    end
    # A field's type: a symbol (:string, :i64_list, :Address), `list(:string)` (the same as :string_list) or
    # `map(:i64)` (a typed map with String keys). Returns the canonical text the rest of the compiler reads:
    # "string", "string_list", "Address", "map(i64)", "map(string_list)".
    def field_type_expr(node, inside: nil)
      return field_collection(node, inside) if node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[map list].include?(node.name)

      return opaque_field_type(node, inside) if node.is_a?(Prism::ConstantPathNode)

      bad(node, "expected a type symbol like :string, or map(...) / list(...), got #{nodename(node)}") unless node.is_a?(Prism::SymbolNode)
      s = node.unescaped
      unless TYPES.key?(s.to_sym) || FIELD_LISTS.include?(s.to_sym) || s.match?(CAMEL)
        bad(node, "`:#{s}` is not a field type (#{(TYPES.keys + FIELD_LISTS).map(&:inspect).join(" ")}, map(...), list(...), or the CamelCase name of another params)",
            word: s, from: TYPES.keys + FIELD_LISTS)
      end
      bad(node, "`:#{s}` is a Rust keyword") if RUST_KW.include?(s)
      s
    end

    # A field typed with a type a binding owns (`field :doc, Json::Value`): the binding must be loaded above, and the
    # type must say `wire: true`, because it becomes part of the tool's input or result schema.
    def opaque_field_type(node, inside)
      text = node.slice
      mod, _, name = text.rpartition("::")
      file = @binding_modules[mod]
      bad(node, "`#{inside}(#{text})` is not supported yet: a map holds basic types, not a binding's own types") if inside && inside != :list
      bad(node, "`#{text}`: no binding provides module `#{mod}` (declare `use_bindings :#{mod.downcase}` above the params)", word: mod, from: @binding_modules.keys) unless file
      type = file.types[name] or
        bad(node, "binding #{mod} has no type `#{name}` (its types: #{file.types.keys.join(', ').then { |s| s.empty? ? 'none' : s }})", word: name, from: file.types.keys)
      unless type.wire
        bad(node, "#{text} cannot be a field: its binding does not say `wire: true`. A field becomes part of the tool's schema, " \
                  "so the Rust type must be serde Serialize and Deserialize and schemars JsonSchema; add `wire: true` to its type_rust line if it is")
      end
      text
    end

    def field_collection(node, inside)
      args = node.arguments&.arguments || []
      example = node.name == :map ? "map(:i64)" : "list(:string)"
      bad(node, "`#{node.name}` takes one type, for example #{example}") unless args.size == 1 && node.block.nil?
      if inside == :list
        bad(node, "`list(...)` cannot hold `#{node.name}(...)` yet: lists of maps or lists are not supported")
      end
      inner = field_type_expr(args[0], inside: node.name)
      if node.name == :list
        return "list(#{inner})" if inner.match?(CAMEL) || inner.match?(CompositeTypes::OPAQUE_FIELD)

        return { "string" => "string_list", "i64" => "i64_list", "f64" => "f64_list" }.fetch(inner) do
          bad(args[0], "`list(:#{inner})` is not supported yet; lists hold :string, :i64 or :f64")
        end
      end
      # map(<inner>): a scalar or list value type, a nested object, or a map of a scalar value type.
      return "map(#{inner})" if CompositeTypes::VALUES.key?(inner)
      return "map(#{inner})" if inner.match?(CAMEL)
      if inner.start_with?("map(")
        if (m = inner.match(/\Amap\(([A-Z]\w*)\)\z/))
          bad(args[0], "`map(map(:#{m[1]}))` is not supported yet: maps of maps of objects are not supported")
        end
        unless inner.match?(/\Amap\((?:string|i64|f64|bool|string_list|i64_list|f64_list)\)\z/)
          bad(args[0], "`map(#{inner})` is not supported yet: maps nest one level, as in map(map(:i64))")
        end
        return "map(#{inner})"
      end
      if inner.match?(/\Alist\([A-Z]\w*\)\z/)
        bad(args[0], "`map(#{inner})` is not supported yet: maps of lists of objects are not supported")
      end

      hint = case inner
             when "i32" then "map values use :i64 for integers"
             else "map values can be :string, :i64, :f64, :bool, list(:string), list(:i64), list(:f64), a params object, or map(<value>)"
             end
      bad(args[0], "`map(:#{inner})` is not supported: #{hint}")
    end

    # Calls that already have a richer entry (field, helper) are skipped.
    DECLARATION_SKIP = %i[field helper].freeze

    # One "declaration" entry per DSL call: the call, its keyword values as text, and where its name token
    # sits (the target of go-to-definition). The editor reads these for hover, definition and the outline.
    def note_declaration(node, pos, kw)
      return if DECLARATION_SKIP.include?(node.name)

      first = node.arguments&.arguments&.first
      extra = { call: node.name.to_s,
                keywords: kw.to_h { |k, v| [k.to_s, v.is_a?(Array) ? v.map(&:to_s) : v.to_s] } }
      if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
        loc = first.location
        extra.merge!(name_line: loc.start_line, name_col: loc.start_column + 1, name_end_col: loc.end_column + 1)
      end
      @types.add(node.location, "declaration", node.name.to_s, name: pos[0], extra: extra)
    end

    def note_field(node, field)
      @types&.add(node.location, "field", TypeNames.display(TypeNames.field_symbol(field)), name: field["name"])
    end

    # params :UserId do field :id, :i64, in: :path end. A group of fields a route's body reads with
    # params[:name]; `in:` is the part of the request a field comes from and is left out when the route's
    # verb decides it. Nested objects, lists and maps are declared above the field that uses them.
    def params_decl(node, pos, blk, srv)
      (@params_nodes ||= {})[pos[0]] = node
      bad(node, "duplicate params `#{pos[0]}`#{first_at(node, srv["params"].find { |x| x["name"] == pos[0] })}") if srv["params"].any? { |x| x["name"] == pos[0] }
      fields = []
      each_child(blk, :params) do |n, p, k, _b|
        bad(n, "duplicate field `#{p[0]}`") if fields.any? { |f| f["name"] == p[0] }
        field = { "name" => p[0], "type" => p[1].to_s }
        field["description"] = k[:description] if k[:description]
        field["in"] = k.delete(:in).to_s if k.key?(:in)
        field["wire_name"] = k.delete(:name) if k.key?(:name)
        field_options(n, field, k, srv)
        if field["in"] == "path" && !SCALAR_FIELD_TYPES.include?(field["type"])
          bad(n, "field `#{field['name']}` is `in: :path`, so its type must be a scalar " \
                 "(:string, :i32, :i64, :f64 or :bool), not :#{field['type']}: a path capture is one value")
        end
        if field["in"] == "form" && !SCALAR_FIELD_TYPES.include?(field["type"])
          bad(n, "field `#{field['name']}` is `in: :form`, so its type must be a scalar " \
                 "(:string, :i32, :i64, :f64 or :bool), not :#{field['type']}: a urlencoded body is flat, and " \
                 "serde_urlencoded cannot build a list, a map or a nested object; send those as a JSON body " \
                 "(`in: :body`)")
        end
        if field.key?("wire_name")
          wire = field["wire_name"]
          bad(n, "`name:` renames a form field's wire key, so field `#{field['name']}` must be `in: :form`") unless field["in"] == "form"
          bad(n, "`name:` is a wire key and cannot be empty") if wire.empty?
          bad(n, "`name:` cannot carry a control character") if wire.match?(/[\x00-\x1f\x7f]/)
          earlier = fields.find { |f| (f["wire_name"] || f["name"]) == wire }
          bad(n, "`name: #{wire}` is already the wire key of another field in params `#{pos[0]}`") if earlier
          shadow = fields.find { |f| f["wire_name"] == field["name"] }
          bad(n, "field `#{field['name']}` has the same name as the wire key of another field") if shadow
        end
        (@field_nodes ||= {})["#{pos[0]}:#{field['name']}"] = n
        note_field(n, field)
        fields << field
      end
      # A renamable form field can make two DSL names one wire key even when neither is a duplicate of the
      # other's name; check the key each field actually arrives as, from either side.
      wire_seen = {}
      fields.each do |f|
        key = f["wire_name"] || f["name"]
        at = @field_nodes["#{pos[0]}:#{f["name"]}"]
        bad(at, "two fields of params `#{pos[0]}` arrive as `#{key}`; give one a different `name:`") if wire_seen[key]
        wire_seen[key] = true
      end
      { "name" => pos[0], "fields" => fields, **located(node) }
    end

    # Names a helper cannot take: they would collide with something the generated crate defines, with a
    # response helper or statement the body language handles by name, or with a body built-in.
    RESERVED_HELPERS = %w[main check run_subprocess arith_error str_to_i str_to_int result rust setting
                          file_text file_path entry entry_args json text html halt redirect status content_type
                          etag params raise Integer current cookie set_cookie delete_cookie random_token request_ip
                          user_agent transaction].freeze

    # helper :guard, args: [:string], returns: :string do |url| ... end. A helper is compiled in declaration
    # order and may only call helpers declared above it, so recursion cannot happen. Types are never inferred.
    # A nil-able argument (:string?) is Option<T> in Rust and follows the nil-able rules in the body.
    def helper_decl(node, pos, kw, blk, srv)
      name = pos[0]
      refuse_helper_async(node, name, kw[:async])
      bad(node, "duplicate helper `#{name}`#{first_at(node, @helper_table[name])}") if @helper_table.key?(name)
      bad(node, "helper `#{name}` has the same name as a rust_fn, cmd_fn or script_fn") if srv["externs"].key?(name)
      bad(node, "helper `#{name}` has the same name as a #{@flags["queries"][name]["kind"]}#{first_at(node, @query_nodes[name])}") if @flags.dig("queries", name)
      bad(node, "`#{name}` is reserved; pick another helper name") if RESERVED_HELPERS.include?(name) || name.start_with?("__")
      arg_syms = kw[:args].map(&:to_sym)
      arg_types = arg_syms.map { |s| HELPER_TYPES.fetch(s) }
      ret = HELPER_TYPES.fetch(kw[:returns])
      kw_specs = kw[:kw] || {}
      parsed = helper_params(blk, node)
      names = parsed[:pos]
      bad(node, "helper `#{name}` declares #{arg_types.size} argument type(s) but its block takes #{names.size}") unless names.size == arg_types.size
      kw_specs.each_key { |k| bad(node, "keyword parameter `#{k}:` has the same name as a positional parameter") if names.include?(k.to_s) }
      kw_body = []
      kw_record = []
      kw_specs.each do |kname, (tsym, required)|
        found = parsed[:kw].find { |p| p[:name] == kname.to_s } or
          bad(node, "helper `#{name}` declares keyword `#{kname}:` but its block has no such parameter")
        ir = HELPER_TYPES.fetch(tsym)
        if required
          bad(found[:node], "keyword parameter `#{kname}:` is required in `kw:` but the block gives it a default") if found[:default]
          kw_record << { "name" => kname.to_s, "type" => ir.to_s, "required" => true }
        else
          bad(found[:node], "keyword parameter `#{kname}:` is optional in `kw:` so the block must give it a literal default") unless found[:default]
          dflt = helper_default(found[:default], tsym, kname)
          kw_record << { "name" => kname.to_s, "type" => ir.to_s, "required" => false, "default" => dflt }
        end
        kw_body << [kname.to_s, ir, found[:node]]
      end
      parsed[:kw].each do |p|
        next if kw_specs.key?(p[:name].to_sym)

        bad(p[:node], "helper `#{name}` block has keyword parameter `#{p[:name]}:` that `kw:` does not declare")
      end
      body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "helper `#{name}`", @binding_modules,
                      @helper_table.dup).lower_helper(blk, names, arg_types, ret, kw_body)
      @helper_decls[name] = node
      async = body["uses_async"]
      reason = async ? body["async_reason"] : nil
      @types&.add(node.location, "helper", "(#{arg_types.map { |t| TypeNames.display(t) }.join(", ")}) -> #{TypeNames.display(ret)}",
                  name: name, extra: async ? { async: true, async_reason: reason } : nil)
      @helper_table[name] = { "name" => name, "args" => names.zip(arg_types.map(&:to_s)), "kw" => kw_record,
                              "returns" => ret.to_s, "body" => body, "async" => async, "async_reason" => reason,
                              **located(node) }
    end
    # The positional and keyword parameters a helper block declares. Positional parameters come first, then
    # keyword ones: a required keyword has no default, an optional one a literal default. Optional or post
    # positional parameters, rest/keyword-rest/block parameters and block-locals are refused.
    def helper_params(blk, node)
      ps = blk.parameters
      return { pos: [], kw: [] } unless ps

      bad(ps, "unsupported #{nodename(ps)} as helper parameters") unless ps.is_a?(Prism::BlockParametersNode)
      bad(ps, "block-local variables are not allowed") unless ps.locals.empty?
      pn = ps.parameters
      return { pos: [], kw: [] } unless pn

      extra = [pn.optionals, pn.posts].any? { |x| !x.empty? } || pn.rest || pn.keyword_rest || pn.block
      bad(pn, "only required positional parameters and keyword parameters are allowed") if extra
      seen = []
      pos = pn.requireds.map do |r|
        bad(r, "unsupported #{nodename(r)} as a helper parameter") unless r.is_a?(Prism::RequiredParameterNode)
        bad(r, "parameter `#{r.name}` must be snake_case and not a Rust keyword") if !r.name.to_s.match?(SNAKE) || RUST_KW.include?(r.name.to_s)
        bad(r, "duplicate parameter `#{r.name}`") if seen.include?(r.name.to_s)
        seen << r.name.to_s
        r.name.to_s
      end
      kw = pn.keywords.map do |k|
        unless k.is_a?(Prism::RequiredKeywordParameterNode) || k.is_a?(Prism::OptionalKeywordParameterNode)
          bad(k, "unsupported #{nodename(k)} as a helper keyword parameter")
        end
        bad(k, "parameter `#{k.name}` must be snake_case and not a Rust keyword") if !k.name.to_s.match?(SNAKE) || RUST_KW.include?(k.name.to_s)
        bad(k, "duplicate parameter `#{k.name}`") if seen.include?(k.name.to_s)
        seen << k.name.to_s
        { name: k.name.to_s, node: k, default: k.is_a?(Prism::OptionalKeywordParameterNode) ? k.value : nil }
      end
      { pos: pos, kw: kw }
    end

    # A keyword parameter's default must be a literal of its declared type; a nil default is allowed only for
    # a nil-able type. Returns the Ruby literal the IR carries (nil means the default is nil, i.e. Rust None).
    def helper_default(node, tsym, kname)
      literals = [Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode,
                  Prism::ArrayNode, Prism::NilNode]
      bad(node, "keyword parameter `#{kname}:` needs a literal default, got #{nodename(node)}") unless literals.any? { |k| node.is_a?(k) }
      nilable = tsym.to_s.end_with?("?")
      if node.is_a?(Prism::NilNode)
        bad(node, "keyword parameter `#{kname}:` is not nil-able, so its default cannot be nil") unless nilable
        return nil
      end
      base = nilable ? Body::OPT.fetch(HELPER_TYPES.fetch(tsym)) : HELPER_TYPES.fetch(tsym)
      case base
      when :string
        bad(node, "the default for keyword `#{kname}:` must be a string literal, got #{nodename(node)}") unless node.is_a?(Prism::StringNode)
        node.unescaped
      when :i32, :i64
        bad(node, "the default for keyword `#{kname}:` must be an integer literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode)
        node.value
      when :f64
        bad(node, "the default for keyword `#{kname}:` must be a number literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)
        node.value
      when :bool
        bad(node, "the default for keyword `#{kname}:` must be true or false, got #{nodename(node)}") unless node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)
        node.is_a?(Prism::TrueNode)
      when :strs
        bad(node, "the default for keyword `#{kname}:` must be an array of string literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode) && node.elements.all? { |el| el.is_a?(Prism::StringNode) }
        node.elements.map(&:unescaped)
      when :i64s
        bad(node, "the default for keyword `#{kname}:` must be an array of integer literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode) && node.elements.all? { |el| el.is_a?(Prism::IntegerNode) }
        node.elements.map(&:value)
      when :f64s
        bad(node, "the default for keyword `#{kname}:` must be an array of number literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode) && node.elements.all? { |el| el.is_a?(Prism::IntegerNode) || el.is_a?(Prism::FloatNode) }
        node.elements.map(&:value)
      else
        bad(node, "keyword parameter `#{kname}:` of type :#{tsym} cannot have a literal default")
      end
    end

    # Sinatra path syntax -> axum 0.8: `:name` becomes `{name}` and a splat `*rest` becomes `{*rest}`. axum's
    # router has no optional segments and no patterns beyond one named capture, so `?`, parentheses and a regex
    # metacharacter in a path are refused rather than silently matched differently.
    def route_path(node, path)
      bad(node, "route path must start with /, got #{path.inspect}") unless path.start_with?("/")
      if path.include?("?")
        bad(node, "route path #{path.inspect} uses an optional segment (`?`), which axum's router cannot express; write the whole path explicitly")
      end
      if path.match?(/[()]/)
        bad(node, "route path #{path.inspect} uses a group in parentheses (an optional segment or an inline regex), which axum's router cannot express; a path may contain literal text, `:name` captures and a `*splat`")
      end
      if (m = path.match(/[\[\]{}+^$|\\]/))
        bad(node, "route path #{path.inspect} uses the regex metacharacter #{m[0].inspect}, which axum's router cannot express; a path may contain literal text, `:name` captures and a `*splat`")
      end
      out = +""
      names = []
      i = 0
      while i < path.length
        ch = path[i]
        if ch == ":" || ch == "*"
          j = i + 1
          j += 1 while j < path.length && path[j].match?(/[A-Za-z0-9_]/)
          name = path[(i + 1)...j]
          bad(node, "route path #{path.inspect} has a `#{ch}` with no capture name") if name.empty?
          bad(node, "route path #{path.inspect} has the capture name `#{name}`, which must start with a letter or _ and contain only letters, digits and _") unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          bad(node, "route path #{path.inspect} repeats the capture name `#{name}`") if names.include?(name)
          names << name
          out << (ch == "*" ? "{*#{name}}" : "{#{name}}")
          i = j
        else
          out << ch
          i += 1
        end
      end
      [out, names]
    end

    # `get "/users/:id", params: :UserId do ... end`. The params group says which fields the body reads; the verb
    # fixes the default location of a field that does not say `in:` (:body for post/put/patch, :query for
    # get/delete/head/options). The block is a response body (Body kind :route): it ends in a string or one of
    # `json`, `text`, `html`, `halt`, `redirect`, and reads its inputs with `params[:name]`.
    def route_decl(node, pos, kw, blk, srv)
      verb = node.name.to_s
      path = pos[0]
      axum_path, names = route_path(node, path)
      refuse_route_mount_clash(node, axum_path, srv)
      prm_name = kw[:params]
      prm = nil
      if prm_name
        prm = srv["params"].find { |x| x["name"] == prm_name } or
          undeclared(node, "route `#{verb} #{path}` refers to undeclared params `#{prm_name}`", prm_name, srv["params"].map { |x| x["name"] })
      end
      default_in = %w[post put patch].include?(verb) ? "body" : "query"
      field_in = (prm ? prm["fields"] : []).to_h { |f| [f["name"], f["in"] || default_in] }
      if field_in.value?("form") && field_in.value?("body")
        bad(node, "route `#{verb} #{path}` reads params `#{prm_name}` from both a JSON body and a form; axum lets only one extractor consume the request body, so the group's fields must be all `in: :body` or all `in: :form`")
      end
      if field_in.value?("form") && !%w[post put patch].include?(verb)
        bad(node, "route `#{verb} #{path}` reads params `#{prm_name}` from a form, but a browser sends a form body only on POST (or PUT/PATCH); on `#{verb}` the fields belong in the query string — use `in: :query`, or make the route a `post`")
      end
      path_fields = field_in.select { |_, loc| loc == "path" }.keys
      (names - path_fields).each do |name|
        bad(node, "route path #{path.inspect} captures `#{name}`, but no field of params `#{prm_name}` is `in: :path`; add `field :#{name}, :string, in: :path`")
      end
      (path_fields - names).each do |name|
        bad(node, "field `#{name}` of params `#{prm_name}` says `in: :path`, but route path #{path.inspect} has no `:#{name}` capture")
      end
      skips = kw[:skip] || []
      named_filters = srv["before"].filter_map { |f| f["name"] }
      skips.each do |filter_name|
        next if named_filters.include?(filter_name)

        bad(node, "route `#{verb} #{path}` skips `:#{filter_name}`, but no `before :#{filter_name}` filter is declared#{named_filters.empty? ? '' : " (named filters: #{named_filters.join(', ')})"}")
      end
      body = Body.new(@path, prm || { "fields" => [] }, @regexes, srv["externs"], @flags, "route `#{verb} #{path}`",
                      @binding_modules, @helper_table, srv["params"] + srv["records"], kind: :route, skip: skips).lower(blk)
      if body["content_type"]
        bad(node, "`content_type(...)` is only meaningful in a `before` filter; it sets the default for the routes that follow")
      end
      # A body that read errors[:field] needs a params group whose check() can report something; that test
      # needs every params group, so it runs once the whole file is read (check_errors_routes).
      (@errors_routes ||= []) << [node, prm_name] if body["errors"]
      decl = { "method" => verb, "path" => axum_path, "names" => names, "params" => prm_name,
               "description" => kw[:description], "body" => body, **located(node) }
      decl["field_in"] = field_in unless field_in.empty?
      decl["skip"] = skips unless skips.empty?
      decl
    end

    # A static mount can name the named `before` filters it does not run. The mount is declared before the
    # filters are read, so the names are checked here, once both lists are complete. A mount at "/" takes
    # no skip at all (add_static refuses one: the fallback would cover every GET path), and `serve_file`
    # and `set :public_folder` take no skip for now.
    def check_static_skips(srv)
      named = srv["before"].filter_map { |f| f["name"] }
      srv["statics"].each do |s|
        s["skip"].to_a.each do |filter_name|
          next if named.include?(filter_name)

          bad(@static_nodes[s["prefix"]], "static `#{s['prefix']}` skips `:#{filter_name}`, but no `before :#{filter_name}` filter is declared#{named.empty? ? '' : " (named filters: #{named.join(', ')})"}")
        end
      end
    end

    # `current :user, returns: :User?, required: :authenticate`: the named `before` filter must exist and must
    # read the current (a filter that never reads it cannot stop the request when it is nil). Filters are read
    # after the currents, so this runs once both lists are complete, before any route is lowered.
    def check_required_currents(srv)
      srv["currents"].each do |c|
        req = c["required"] or next
        node = @current_nodes[c["name"]]
        filter = srv["before"].find { |f| f["name"] == req }
        unless filter
          named = srv["before"].filter_map { |f| f["name"] }
          bad(node, "current `#{c['name']}` says `required: :#{req}`, but no `before :#{req}` filter is declared" \
                    "#{named.empty? ? '' : " (named filters: #{named.join(', ')})"}")
        end
        unless filter["currents"].to_a.include?(c["name"])
          bad(node, "`before :#{req}` is named by current `#{c['name']}`'s `required:`, but its body never reads " \
                    "`current(:#{c['name']})`, so it cannot establish it; read the current there and stop when it is nil")
        end
      end
    end

    # A route's `skip:` is matched at run time by method and path, so a skip pattern must not also match a
    # route that does not skip that filter: `/rooms/:id` would match a request for a literal `/rooms/new`.
    # Refused rather than narrowed, because the filter layer runs before axum has chosen a route.
    def check_filter_skips(srv)
      by_method = srv["routes"].group_by { |r| r["method"] }
      # A `serve_file` and the OpenAPI document are axum routes too, but neither takes `skip:`, so a route
      # pattern that matches one of them would step the filter aside for it. Compare against them as routes
      # that do not skip the filter, exactly like a literal route beside a capture.
      srv["serve_files"].to_a.each do |f|
        %w[get head].each { |method| (by_method[method] ||= []) << { "method" => method, "path" => f["path"], "skip" => [] } }
      end
      if srv["openapi"]
        %w[get head].each { |method| (by_method[method] ||= []) << { "method" => method, "path" => srv["openapi"]["path"], "skip" => [] } }
      end
      @route_decl_nodes.to_a.each do |route, node|
        route["skip"].to_a.each do |filter_name|
          by_method.fetch(route["method"], []).each do |other|
            next if other.equal?(route) || other["skip"].to_a.include?(filter_name)
            next unless path_patterns_overlap?(route["path"], other["path"])

            bad(node, "route `#{route['method']} #{route['path']}` skips `:#{filter_name}`, but the run-time skip " \
                      "(method and path) also matches `#{other['method']} #{other['path']}`, which does not skip it; " \
                      "give every handler that path reaches the same `skip:` (a `serve_file` or the OpenAPI " \
                      "document takes none, so narrow this route's path), or use paths that cannot overlap")
          end
        end
      end
    end

    # Whether two axum path patterns can match one request path: the same segment count and every segment
    # compatible (a `{name}` capture matches any non-empty segment), or a `{*name}` tail, which matches the rest.
    def path_patterns_overlap?(a, b)
      left = a.split("/")
      right = b.split("/")
      i = 0
      loop do
        x = left[i]
        y = right[i]
        return true if x.nil? && y.nil?
        return true if wildcard_segment?(x) || wildcard_segment?(y)
        return false if x.nil? || y.nil?
        return false unless x == y || capture_segment?(x) || capture_segment?(y)

        i += 1
      end
    end

    def capture_segment?(seg) = seg.start_with?("{") && seg.end_with?("}") && !seg.start_with?("{*")

    def wildcard_segment?(seg) = seg.to_s.start_with?("{*")

    # A route whose body reads errors[:field] takes the generated check()'s messages into its own body, so
    # its params group has to carry a constraint that check() can report. Emit.checked? is the same
    # predicate the emitter decides a struct's checks with, and every params group has been read by now
    # (a group may nest one declared further down the file), so the refusal names the real constraint list.
    def check_errors_routes(srv)
      @errors_routes.to_a.each do |node, prm_name|
        prm = srv["params"].find { |p| p["name"] == prm_name } or next
        next if Emit.checked?(prm, srv)

        bad(node, "route reads `errors`, but params `#{prm_name}` declares no constraint " \
                  "(#{Emit::CHECKED_OPTIONS.join(', ')}), so the generated check() can never report a violation; " \
                  "add one to a field, or drop errors")
      end
    end

    # `before`, `not_found` and `error` are request filters; each is a response body (Body kinds :before,
    # :not_found, :error), so the response helpers are in scope. `before` may be repeated and runs before the
    # routes that follow it; `not_found` and `error` describe what one request answers with.
    def filter_decl(node, pos, _kw, blk, srv)
      if node.name == :not_found && srv["statics"].any? { |s| s["prefix"] == "/" }
        bad(node, "a `not_found` filter and a directory mounted at \"/\" (`set :public_folder`) both answer a request no route matched, and axum has one fallback; mount the directory at a prefix with `static \"/assets\", dir: ...` instead")
      end
      # `located` gives the filter body the line and file of its declaration, so Emit's source map can
      # point a generated-rustc error back at the filter, like every other declaration.
      if node.name == :before
        name = pos[0]
        if name
          earlier = srv["before"].find { |f| f["name"] == name }
          bad(node, "duplicate `before :#{name}` filter#{first_at(node, (@before_nodes ||= {})[name])}") if earlier
          (@before_nodes ||= {})[name] = node
        end
        srv["before"] << filter_body(node, blk, srv).merge(located(node)).merge(name ? { "name" => name } : {})
      else
        key = node.name.to_s
        bad(node, "duplicate `#{node.name}` filter#{first_at(node, @filter_nodes&.[](key))}") if srv[key]
        srv[key] = filter_body(node, blk, srv).merge(located(node))
        (@filter_nodes ||= {})[key] = node
      end
    end

    # A filter body. `content_type(...)` is only meaningful in `before`, where it is the default for the routes
    # that follow; in `not_found` and `error` the response says its own type.
    def filter_body(node, blk, srv)
      body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "#{node.name} filter",
                      @binding_modules, @helper_table, srv["params"] + srv["records"], kind: node.name).lower(blk)
      if node.name != :before && body["content_type"]
        bad(node, "`content_type(...)` is only meaningful in a `before` filter, not in `#{node.name}`; it sets the default for the routes that follow")
      end
      body
    end

    # `server "name", version: "0.1.0"`: the crate a file compiles to. Optional; `set :name`/`set :version` name
    # the same crate.
    def server_decl(node, pos, kw, srv)
      bad(node, "server name must match [a-z][a-z0-9_-]*") unless pos[0].match?(/\A[a-z][a-z0-9_-]*\z/)
      bad(node, "version must be semver like 0.1.0, got #{kw[:version].inspect}") unless kw[:version].match?(SEMVER)
      set_name(node, pos[0], srv)
      set_version(node, kw[:version], srv)
    end

    # What `set :listener` accepts: "module::Type", the module being the `as:` of a rust_file.
    LISTENER_TYPE = /\A[a-z][a-z0-9_]*::[A-Z][A-Za-z0-9]*\z/

    # `set :name, value`: Sinatra's way of configuring a service without a `configure` block. `port` and `bind`
    # configure the listener; `listener` swaps the TCP listener for a Rust type of the file's own (TLS), and
    # `log` picks the log format; `name` and `version` name the crate, as the `server` declaration does;
    # `public_folder` mounts a directory of files at "/", which is Sinatra's own meaning for the name; and
    # `views`/`layout` say where a body's `render` reads its views and which one wraps them (see Views). The
    # value of a setting is a literal, or a symbol where the setting names something (`set :layout, :app`),
    # which is why each branch below checks the type the setting takes before it uses the value.
    def add_set(node, pos, srv)
      name, value = pos
      case name
      when :port
        bad(node, "`set :port` must be 0 to 65535, got #{value.inspect}") unless value.is_a?(Integer) && (0..65_535).cover?(value)
        bad(node, "duplicate `set :port`#{first_at(node, @port_node)}") if srv["port"]
        srv["port"] = value
        @port_node = node
      when :bind
        bad(node, "`set :bind` is a host or IP address, such as \"0.0.0.0\" or \"127.0.0.1\"") unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_.:-]+\z/)
        bad(node, "duplicate `set :bind`#{first_at(node, @bind_node)}") if srv["bind"]
        srv["bind"] = value
        @bind_node = node
      when :name
        bad(node, "server name must match [a-z][a-z0-9_-]*") unless value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_-]*\z/)
        set_name(node, value, srv)
      when :version
        bad(node, "version must be semver like 0.1.0, got #{value.inspect}") unless value.is_a?(String) && value.match?(SEMVER)
        set_version(node, value, srv)
      when :public_folder
        bad(node, "`set :public_folder` takes the directory as a string, such as \"public\"") unless value.is_a?(String)
        add_static(node, "/", value, {}, srv)
      when :views
        bad(node, "`set :views` takes the folder as a string, such as \"views\"") unless value.is_a?(String)
        bad(node, "duplicate `set :views`#{first_at(node, @views_node)}") if srv["views"]
        if value.start_with?("/") || value.include?("\0") || value.split("/").include?("..")
          bad(node, "`set :views` is a folder inside the DSL file's folder, without a leading /, without .., got #{value.inspect}")
        end
        # The folder resolves against the server file, not the fragment that names a render: `set :views`
        # is a server setting (Body#render_response). A folder that is not there is each render's own
        # refusal, with the view's path in it.
        srv["views"] = value
        @flags["views"] = value # a render resolves its views against it (Body#render_response)
        @views_node = node
      when :layout
        unless value.is_a?(String) || value.is_a?(Symbol)
          bad(node, "`set :layout` names a view with a symbol (:app) or a string (\"app\"), or leave the setting out")
        end
        bad(node, "duplicate `set :layout`#{first_at(node, @layout_node)}") if srv["layout"]
        # The file itself is read and checked once the whole file is walked (check_layout), because
        # `set :views` may be written after this line and the name resolves against it.
        srv["layout"] = value.to_s
        @flags["layout"] = value.to_s # every render that names no `layout:` gets it (Body#render_layout)
        @layout_node = node
      when :listener
        # The type is spelled module::Type, the module being the `as:` of a rust_file; check_listener
        # looks for that module once the whole file is walked, because the rust_file may come after.
        unless value.is_a?(String) && value.match?(LISTENER_TYPE)
          bad(node, "`set :listener` names a Rust type as \"module::Type\", where module is the `as:` of a rust_file, such as \"tls::TlsListener\", got #{value.inspect}")
        end
        bad(node, "duplicate `set :listener`#{first_at(node, @listener_node)}") if srv["listener"]
        injection(node, "`set :listener`")
        srv["listener"] = value
        @listener_node = node
      when :rust
        bad(node, "`set :rust` takes :none, the mode that refuses injected Rust; got #{value.inspect}") unless value == :none
        bad(node, "duplicate `set :rust`#{first_at(node, @rust_none_node)}") if @rust_none_node
        @rust_none_node = node
        pending = @rust_injections.to_a
        injection(*pending.first) unless pending.empty?
      when :log
        unless %i[text json].include?(value)
          bad(node, "`set :log` is :text or :json, got #{value.inspect}")
        end
        bad(node, "duplicate `set :log`#{first_at(node, @log_node)}") if srv["log"]
        srv["log"] = value.to_s
        @log_node = node
      end
    end

    # `set :layout, :app`: every render that names no `layout:` gets this view, and `layout: nil` opts out.
    # The layout is read and checked here, once, so a setting that names a view which is not there, is not
    # `.html`, or writes no `{{ yield }}` is refused at the setting rather than at each render that inherits
    # it. Its markers are read again per render, where the locals are checked against them. The layout is a
    # view, so it reads the server file's folder even when the setting is written in a fragment.
    def check_layout(srv)
      return unless srv["layout"]

      node = @layout_node
      view = Views.load(srv["layout"], srv["views"] || Views::DEFAULT_DIR, Views.folder(@path), bad: ->(m) { bad(node, m) })
      unless view.yields
        bad(node, "#{view.rel} has no `{{ yield }}`, so the layout would drop the view it wraps; " \
                  "a layout writes the view where its `{{ yield }}` is")
      end
      (@flags["view_inputs"] ||= {})[view.real] = true
    end

    # `set :listener, "tls::TlsListener"`: the type lives in a rust_file the same file declares, so the
    # module before the :: has to be the `as:` of one. Without any rust_file the message says what to add.
    def check_listener(srv)
      type = srv["listener"] or return
      mod = type.split("::").first
      return if srv["modules"].any? { |m| m["name"] == mod }

      if srv["modules"].empty?
        bad(@listener_node, "`set :listener, #{type.inspect}` names a Rust type, which comes from a rust_file, and this file declares none; " \
                            "add `rust_file \"rust/#{mod}.rs\", as: :#{mod}` with the type in it")
      else
        have = srv["modules"].map { |m| ":#{m['name']}" }.join(", ")
        bad(@listener_node, "`set :listener, #{type.inspect}` names module `#{mod}`, but no rust_file has as: :#{mod} (declared: #{have})")
      end
    end

    def set_name(node, value, srv)
      bad(node, "duplicate server name#{first_at(node, @server_node)}; the name is set once, by `server` or `set :name`") if srv["name"]
      srv["name"] = value
      @server_node = node
    end

    def set_version(node, value, srv)
      bad(node, "duplicate version#{first_at(node, @version_node)}; the version is set once, by `server` or `set :version`") if srv["version"]
      srv["version"] = value
      @version_node = node
    end
    # Yields (node, positional, keywords, block) for every DSL call directly inside blk.
    def each_child(blk, ctx)
      st = blk.body
      return unless st
      bad(st, "unsupported #{nodename(st)} in `#{ctx}` block") unless st.is_a?(Prism::StatementsNode)
      st.body.each do |n|
        p, k, b = call(n, ctx)
        yield n, p, k, b
      end
    end

    # Validates one call against SIG; returns [positional values, keyword values, block].
    def call(node, ctx)
      where = ctx == :top ? "the top level" : "`#{ctx}`"
      bad(node, "unsupported #{nodename(node)} in #{where} (only DSL calls are allowed)") unless node.is_a?(Prism::CallNode)
      sig = SIG[node.name] or bad(node, "unknown DSL call `#{node.name}` (valid in #{where}: #{calls_in(ctx).join(", ")})", word: node.name, from: calls_in(ctx))
      unless Array(sig[:in]).include?(ctx)
        bad(node, "`#{node.name}` is not allowed in #{where} (valid there: #{calls_in(ctx).join(", ")}); it belongs in #{Array(sig[:in]).map { |c| c == :top ? "the top level" : "`#{c}`" }.join(" or ")}")
      end
      bad(node.receiver, "`#{node.name}` takes no receiver") if node.receiver
      pos, kw = args(node, sig)
      note_declaration(node, pos, kw) if @types
      [pos, kw, block(node, sig)]
    end

    # The DSL calls allowed directly inside `ctx`.
    def calls_in(ctx) = SIG.select { |_, s| Array(s[:in]).include?(ctx) }.keys.map(&:to_s)

    # The call shape for error messages, e.g. `tool(name, params:, description:, [title:], ...)`: optional keywords are bracketed.
    def shape(name, sig)
      optional = sig[:optional_pos] || 0
      pos = sig[:names].each_with_index.map { |arg, i| i >= sig[:names].size - optional ? "[#{arg}]" : arg.to_s }
      kws = sig[:kw].map { |k, (_, req)| req ? "#{k}:" : "[#{k}:]" }
      "#{name}(#{(pos + kws).join(", ")})"
    end

    # Refuses a reference to a params/output struct that was not declared above, listing what is.
    def undeclared(node, msg, name, declared)
      list = declared.empty? ? "none is declared above" : "declared above: #{declared.join(", ")}"
      bad(node, "#{msg} (#{list})", word: name, from: declared)
    end

    def args(node, sig)
      list = (node.arguments&.arguments || []).dup
      kwn = list.last.is_a?(Prism::KeywordHashNode) ? list.pop : nil
      optional = sig[:optional_pos] || 0
      least = sig[:pos].size - optional
      unless list.size.between?(least, sig[:pos].size)
        takes = optional.zero? ? "#{sig[:pos].size} positional argument(s)" : "#{least} to #{sig[:pos].size} positional argument(s)"
        bad(node, "`#{node.name}` takes #{takes}, got #{list.size}; expected `#{shape(node.name, sig)}`")
      end
      pos = list.each_with_index.map { |n, i| value(n, sig[:pos][i]) }
      kw = {}
      (kwn ? kwn.elements : []).each do |el|
        ok = el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && !el.value.is_a?(Prism::ImplicitNode)
        bad(el, "unsupported #{nodename(el)} in `#{node.name}` arguments (no **opts, no shorthand `key:`)") unless ok
        key = el.key.unescaped.to_sym
        spec = sig[:kw][key] or bad(el, "unknown keyword `#{key}:` for `#{node.name}` (allowed: #{sig[:kw].keys.join(', ')})", word: key, from: sig[:kw].keys)
        bad(el, "duplicate keyword `#{key}:`") if kw.key?(key)
        kw[key] = value(el.value, spec[0])
      end
      sig[:kw].each { |k, (_, req)| bad(node, "`#{node.name}` requires `#{k}:`") if req && !kw.key?(k) }
      [pos, kw]
    end

    def value(node, want)
      return field_type_expr(node) if want == :fieldtype
      if want == :default
        # A field default: a scalar literal, or a flat list of them for a list field.
        return node.elements.map { |el| value(el, :lit) } if node.is_a?(Prism::ArrayNode)

        return value(node, :lit)
      end
      if want == :setting
        # A setting's value: a literal, or a symbol naming what the setting points at (`set :layout, :app`
        # names views/app.html). Each branch of add_set checks which kind of value its setting takes.
        return node.unescaped.to_sym if node.is_a?(Prism::SymbolNode)

        return value(node, :lit)
      end
      if want == :lit
        case node
        when Prism::IntegerNode, Prism::FloatNode then return node.value
        when Prism::StringNode then return node.unescaped
        when Prism::TrueNode then return true
        when Prism::FalseNode then return false
        else bad(node, "expected a string, number or true/false literal, got #{nodename(node)}")
        end
      end
      if want == :bool
        bad(node, "expected true or false, got #{nodename(node)}") unless node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)
        return node.is_a?(Prism::TrueNode)
      end
      if want == :num
        bad(node, "expected a number literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)
        return node.value
      end
      if want == :uint
        bad(node, "expected a non-negative integer literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode) && !node.value.negative?
        return node.value
      end
      if want == :sqlargs
        bad(node, "expected a hash literal of the query's arguments, such as { limit: :i64 }, got #{nodename(node)}") unless node.is_a?(Prism::HashNode)
        out = {}
        node.elements.each do |el|
          bad(el, "unsupported #{nodename(el)} in `args:` (use `name: :type`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          k = el.key.unescaped
          bad(el, "argument `#{k}` must be snake_case and not a Rust keyword") if !k.match?(SNAKE) || RUST_KW.include?(k)
          bad(el, "duplicate argument `#{k}`") if out.key?(k)
          out[k] = value(el.value, Db::SCALARS.map(&:to_sym)).to_s
        end
        return out
      end
      return query_returns(node) if want == :qreturns
      if want == :htypes
        bad(node, "expected an array of type symbols, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, HELPER_TYPES.keys).to_s }
      end
      if want == :helper_kw
        bad(node, "expected a hash literal `{ name: [type, required] }`, got #{nodename(node)}") unless node.is_a?(Prism::HashNode)
        out = {}
        node.elements.each do |el|
          bad(el, "unsupported #{nodename(el)} in `kw:` (use `name: [type, true]`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          k = el.key.unescaped
          bad(el, "keyword parameter `#{k}` must be snake_case and not a Rust keyword") if !k.match?(SNAKE) || RUST_KW.include?(k)
          bad(el, "duplicate keyword parameter `#{k}`") if out.key?(k.to_sym)
          arr = el.value
          bad(el, "keyword parameter `#{k}:` needs `[type, required]`, got #{nodename(arr)}") unless arr.is_a?(Prism::ArrayNode) && arr.elements.size == 2
          ty = value(arr.elements[0], HELPER_TYPES.keys)
          req = value(arr.elements[1], :bool)
          out[k.to_sym] = [ty, req]
        end
        return out
      end
      if want == :types
        bad(node, "expected an array of type symbols, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, TYPES.keys).to_s }
      end
      if want == :snakes
        bad(node, "expected an array of symbols such as %i[place look], got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, :snake) }
      end
      if want == :file_checks
        bad(node, "expected an array of check names such as %i[each_read], got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, FILE_CHECKS).to_s }
      end
      if want == :strs
        bad(node, "expected an array of string literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, :str) }
      end
      if want == :filter_name
        if node.is_a?(Prism::TrueNode)
          bad(node, "`required:` names the `before` filter that establishes the current, as in `required: :authenticate`; `required: true` cannot say which filter stops the request")
        end
        return value(node, :snake)
      end
      if want == :str
        # A squiggly heredoc (<<~) arrives as an InterpolatedStringNode whose parts are plain
        # StringNode lines. Real interpolation adds an EmbeddedStatementsNode part and is refused.
        if node.is_a?(Prism::InterpolatedStringNode) && node.parts.all?(Prism::StringNode)
          return node.parts.map(&:unescaped).join
        end

        bad(node, "expected a plain string literal, got #{nodename(node)}") unless node.is_a?(Prism::StringNode)
        return node.unescaped
      end
      bad(node, "expected a symbol literal, got #{nodename(node)}") unless node.is_a?(Prism::SymbolNode)
      s = node.unescaped
      if want == :snake || want == :camel
        shape = want == :snake ? "snake_case" : "CamelCase"
        bad(node, "`:#{s}` must be #{shape}") unless s.match?(want == :snake ? SNAKE : CAMEL)
        bad(node, "`:#{s}` is a Rust keyword") if RUST_KW.include?(s)
        s
      else
        bad(node, "`:#{s}` is not one of #{want.map(&:inspect).join(' ')}", word: s, from: want) unless want.include?(s.to_sym)
        s.to_sym
      end
    end

    def block(node, sig)
      b = node.block
      if sig[:block].nil?
        bad(b, "`#{node.name}` takes no block") if b
        return nil
      end
      bad(node, "`#{node.name}` needs a do ... end block") unless b
      bad(b, "unsupported #{nodename(b)} (a literal block is required)") unless b.is_a?(Prism::BlockNode)
      bad(b.parameters, "`#{node.name}` block takes no parameters") if sig[:block] == :decls && b.parameters
      b
    end
  end
end
