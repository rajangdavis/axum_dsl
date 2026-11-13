# frozen_string_literal: true

module AxumDsl
  # Walks the Prism AST of the DSL file into an IR hash (string keys, JSON-ready).
  # Deny by default: anything that is not a CallNode matching SIG is an error. The shape of a file is
  # Sinatra's: the optional `server`, the `set` settings, the `params` groups, the routes, the request
  # filters and the typed helpers all sit at the top level, and there is no enclosing block.
  class Reader
    include Diag
    include RelationQueries
    include TypeGraph::Sites

    def initialize(path, types: nil, graph: nil)
      @path = path
      @graph = graph # a TypeGraph when `axum_dsl graph` or the language server asks how the types derive
      @regexes = []
      @types = types # a TypeNames::Collector when `check --types` asks for the inferred types
      @flags = types ? { "types" => types } : {}
      @flags["graph"] = graph if graph
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
              "database" => nil, "migrations" => nil, "records" => [], "tables" => [], "models" => [], "exprs" => [], "queries" => [],
              "cookies" => nil, "currents" => [], "builtins" => [], "sanitizers" => [], "cable" => nil }
      @helper_table = {}   # helpers compiled so far, in declaration order: name -> record
      @helper_decls = {}   # helper name -> its DSL node (for messages)
      helper_nodes = []
      current_nodes = []
      route_nodes = []
      cable_nodes = []
      law_nodes = []
      filters = []
      # One declaration of the file, from this file or from a fragment use_dsl splices in at its line.
      declare = lambda do |n, p, k, b|
        next add_def(n, nil) if n.is_a?(Prism::DefNode) # a top-level def: a model or concern method any route may call
        case n.name
        when :use_dsl then splice(n, p[0], srv, &declare)
        when :server then server_decl(n, p, k, srv)
        when :set then add_set(n, p, srv)
        when :params then srv["params"] << params_decl(n, p, b, srv)
        when :helper then helper_nodes << [n, p, k, b]
        when :law then law_nodes << [n, p, k, b]
        when :controller then controller_decl(n, p, b, srv, route_nodes, declare)
        when :model then model_decl(n, p, k, b, declare)
        when :concern then concern_decl(n, p, b, srv)
        when :expr then add_expr(n, p, k, srv)
        when :flash then add_flash(n, k, srv)
        when :default_locale then default_locale_decl(n, p)
        when :setting then add_setting(n, p, k, srv)
        when :cookies then add_cookies(n, k, srv)
        when :sanitizer then add_sanitizer(n, p, k, srv)
        when :current then current_nodes << [n, p, k, b]
        when :view_local then view_local_decl(n, p, b)
        when :page_locals then page_locals_decl(n, b)
        when :layout_locals then layout_locals_decl(n, b)
        when :database then add_database(n, p, k, srv)
        when :migrations then add_migrations(n, p, srv)
        when :record then add_record(n, p, b, srv)
        when :table then add_table(n, p, b, srv)
        when :query, :execute then add_query(n, p, k, srv, b)
        when :rust_crate then add_crate(n, p, srv, k)
        when :rust_item then add_item(n, p, srv)
        when :rust_fn then add_extern(n, p, k, srv)
        when :rust_file then add_file(n, p, k, srv)
        when :file then add_any_file(n, p, k, srv)
        when :static then add_static(n, p[0], k[:dir], k, srv)
        when :serve_file then add_serve_file(n, p[0], k[:from], k, srv)
        when :cable then cable_nodes << [n, p, k, b]
        when :openapi then add_openapi(n, p[0], k, srv)
        when :use_layer then add_layer(n, p, k, srv)
        when :use_bindings then add_bindings(n, p, srv)
        when :cmd_fn then add_cmd(n, p, k, srv)
        when :script_fn then add_script(n, p, k, srv)
        when :before, :not_found, :error then filters << [n, p, k, b]
        when :resources then resources_decl(n, p, k, b, srv, route_nodes)
        when :scope then scope_decl(n, k, b, declare)
        when :get, :post, :put, :patch, :delete, :options, :head then route_nodes << [n, prefixed_pos(p), k, b, nil]
        when :fragment then bad(n, "`fragment` is only written in a file use_dsl includes; this file is built directly")
        else bad(n, "unexpected declaration `#{n.name}`")
        end
      end
      nodes.each do |n|
        next declare.call(n, nil, nil, nil) if n.is_a?(Prism::DefNode)

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
      check_models(srv)
      check_attached(srv)
      check_relation_queries(srv)
      announce_attached(srv)
      @helper_names = helper_nodes.map { |_n, p, _k, _b| p[0].to_s } # a record method may not call one
      check_queries(srv)
      @helper_async = resolve_helper_async(helper_nodes, srv)
      @helper_blocks = helper_nodes.to_h { |_n, p, _k, b| [p[0].to_s, b] } # a cached route is refused when a helper it calls is not repeatable
      helper_nodes.each { |n, p, k, b| helper_decl(n, p, k, b, srv) }
      srv["user_helpers"] = @helper_table.values
      ((@global_defs || {}).merge(*(@controller_defs || {}).values)).each do |dname, dnode|
        bad(dnode, "def `#{dname}` has the name of a helper, which it would hide") if @helper_table.key?(dname)
      end
      current_nodes.each { |n, p, k, b| current_decl(n, p, k, b, srv) }
      check_current_readers(srv)
      filters.each { |n, p, k, b| filter_decl(n, p, k, b, srv) }
      check_required_currents(srv)
      check_static_skips(srv)
      route_nodes.each do |n, p, k, b, verb|
        decl = route_decl(n, p, k, b, srv, verb: verb)
        srv["routes"] << decl
        (@route_decl_nodes ||= []) << [decl, n]
      end
      cable_nodes.each { |n, p, k, b| add_cable(n, p, k, b, srv) } # after the routes, the currents and the queries it names
      srv["laws"] = []
      # Laws compile last, so the checked arithmetic and to_i runtime only they add is known: the release build has no
      # caller for it.
      runtime_before = [(@flags["checked"] || {}).keys, (@flags["helpers"] || {}).keys]
      outside_before = (@flags["queries_outside"] || {}).keys
      law_nodes.each { |n, p, k, b| law_decl(n, p, k, b, srv) } # after every helper: a law calls helpers by name
      srv["law_only_runtime"] = ((@flags["checked"] || {}).keys - runtime_before[0]) + ((@flags["helpers"] || {}).keys - runtime_before[1])
      srv["law_only_queries"] = (@flags["queries_outside"] || {}).keys - outside_before # statements whose pooled wrapper only laws call
      check_broadcast_sites(srv)
      check_private_cache_except(srv) # statics and routes are both complete now
      check_rack_defaults(srv)
      check_response_cache(srv)
      check_rate_limit(srv)
      check_filter_skips(srv)
      # The response cache finds its routes by the same run-time path match a `skip:` uses.
      srv["filter_skips"] = true if srv["routes"].any? { |r| r["skip"].to_a.any? || r["cache"] } || srv["statics"].any? { |s| s["skip"].to_a.any? } || srv["serve_files"].any? { |f| f["skip"].to_a.any? } || (srv["cable"] && srv["before"].any? { |f| f["name"] })
      check_errors_routes(srv)
      check_openapi(srv)
      lower_bindings(srv)
      srv["checked"] = (@flags["checked"] || {}).keys.sort
      srv["helpers"] = (@flags["helpers"] || {}).keys.sort
      srv["law_only_helpers"] = law_only_helpers
      srv["route_laws"] = true if @flags["route_laws"] # a law sends requests or runs a query: main's startup and router become functions
      srv["law_record_eq"] = true if @flags["law_record_eq"] # a law compares query results, so the records derive PartialEq
      srv["html_escape"] = true if @flags["html_escape"] # a body used h(...), so the crate gets the escaper
      srv["html_escape_into"] = true if @flags["html_escape_into"] # a view escaped a value into its buffer
      srv["transactions"] = true if @flags["transactions"] # a body opened a transaction, so the crate gets db_tx
      srv["queries_in_tx"] = (@flags["queries_in_tx"] || {}).keys.sort # statements called inside a transaction
      srv["queries_outside"] = (@flags["queries_outside"] || {}).keys.sort # statements whose pooled wrapper is emitted
      srv["sanitize"] = true if @flags["sanitize"] # a view used |sanitize, so the crate gets the sanitiser
      srv["all_emoji"] = true if @flags["all_emoji"] # a view used `{% if x|all_emoji %}`
      srv["sanitize_profiles"] = (@flags["sanitize_profiles"] || {}).keys.sort # the declared `sanitizer`s a view named
      srv["sanitize_renderers"] = @flags["sanitize_renderers"] || {} # the Rust each one's attachment and sound partials compile to
      srv["editable_profiles"] = (@flags["editable_profiles"] || {}).keys.sort # the sanitizers a view named with `|editable`
      srv["required_current"] = true if @flags["required_current"] # a route read a `required:` current at its non-nil type
      srv["flash_used"] = true if @flags["flash_used"] # a body called take_flash or redirect(..., notice:/alert:)
      # A file that calls `t` carries its locale functions; one that never does has no "i18n" key, so it emits as it always did.
      if @flags["i18n_used"] && !@flags["i18n_used"].empty?
        srv["i18n"] = Locales.ir(@flags["i18n_table"], @flags["i18n_used"])
        srv["inputs"].concat(@flags["i18n_table"].files.reject { |p| srv["inputs"].include?(p) })
      end
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
      unless top.size == 1 && top[0].is_a?(Prism::CallNode) && FILE_KINDS.include?(top[0].name)
        bad(top[1] || top[0] || res.value, "expected exactly one top-level `fragment`, `model` or `controller` call in a file use_dsl includes")
      end
      pos, kw, blk = call(top[0], :top)
      # A model or a controller file is that one declaration; a fragment's block holds what a file holds.
      return yield(top[0], pos, kw, blk) unless top[0].name == :fragment

      each_child(blk, :top) { |n, p, k, b| yield n, p, k, b }
    end

    # The calls a file use_dsl includes may hold: `fragment` (anything a file holds: concerns, settings),
    # `model` (records, SQL, model methods), `concern` (the exprs several models share) and `controller` (routes and their filters).
    FILE_KINDS = %i[fragment model concern controller].freeze

    # The name of a `model do` or `controller do` that does not write one: the path of its file under `models/` or
    # `controllers/` (the folder beside the file being built), camelized as Rails does, `::` between folders. A file
    # elsewhere names its model or controller.
    def inferred_name(node, kind)
      folder = "#{kind}s"
      root = File.realpath(File.dirname(File.expand_path(@path)))
      file = AxumDsl.real_file_of(node) || File.realpath(File.expand_path(@path))
      rel = file.delete_prefix(root + File::SEPARATOR)
      parts = rel.delete_suffix(".axum.rb").split(File::SEPARATOR)
      unless rel != file && parts.size > 1 && parts[0] == folder && rel.end_with?(".axum.rb")
        example = kind == :model ? 'models/room.axum.rb is "Room"' : 'controllers/accounts/bots.axum.rb is "Accounts::Bots"'
        bad(node, "`#{kind} do` takes its name from a file under #{folder}/ (#{example}); this one is #{rel}, so name it: `#{kind} \"Name\" do`")
      end
      name = parts.drop(1).map { |seg| seg.split("_").map(&:capitalize).join }.join("::")
      bad(node, "#{rel} does not name a #{kind} (#{name.inspect}); name the file in snake_case, or write `#{kind} \"Name\" do`") unless name.match?(CONTROLLER_NAME)
      name
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
      srv["sanitizers"].each do |s|
        next if (@flags["sanitize_profiles"] || {})[s["name"]]

        bad(@sanitizer_nodes.fetch(s["name"]), "sanitizer `#{s['name']}` is declared but no view names it; write `{{ body|sanitize :#{s['name']} }}` in a view, or remove it")
      end
      used_settings = @flags["used_settings"] || {}
      srv["settings"].each do |s|
        next if used_settings[s["name"]]

        bad(@setting_nodes.fetch(s["name"]), "setting `#{s['name']}` is declared but no body reads it; use setting(:#{s['name']}) in a body, or remove it")
      end
      reject_unused_files(srv)
      called_queries = @flags["used_queries"] || {}
      # The statements a `has_one_attached` derives are made for `attach` to run: one nothing calls is dropped, not refused.
      srv["queries"].reject! do |q|
        dropped = q["derived"] && !called_queries[q["name"]]
        @graph&.forget("query:#{q['name']}") if dropped
        dropped
      end
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
      # A law's forall: group counts too: the emitted structs are the routes', so a law-only group writes no struct.
      used = srv["routes"].filter_map { |r| r["params"] } + srv["params"].flat_map { |p| referenced.call(p["fields"]) } +
             srv["laws"].to_a.filter_map { |l| l["forall"] }
      srv["params"].each do |p|
        next if used.include?(p["name"])

        bad(@params_nodes.fetch(p["name"]), "params `#{p['name']}` is declared but no route or law uses it; remove it or add a route")
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
    # Tags and attributes a `sanitizer` may never allow: they run script or load active content, whatever else
    # the file says.
    SANITIZER_FORBIDDEN_TAGS = %w[script style iframe object embed frame frameset applet base meta link noscript template svg math].freeze
    SANITIZER_FORBIDDEN_ATTRIBUTES = %w[style srcdoc formaction].freeze

    # sanitizer :message_body, tags: %w[p a], attributes: %w[href class], link_rel: false, autolink_target: "_blank"
    # (docs/views.md): a named allowlist that `{{ body|sanitize :message_body }}` cleans a string with. The lists are
    # checked here, once; a view naming a sanitizer that is not declared is refused where the view is compiled.
    def add_sanitizer(node, pos, kw, srv)
      name = pos[0]
      bad(node, "duplicate sanitizer `#{name}`#{first_at(node, @sanitizer_nodes&.[](name))}") if srv["sanitizers"].any? { |s| s["name"] == name }
      tags = kw[:tags]
      attributes = kw[:attributes]
      bad(node, "`tags:` of sanitizer `#{name}` names no tag; a sanitizer that allows nothing is `{{ x }}`") if tags.empty?
      tags.each do |t|
        bad(node, "`#{t.inspect}` is not a tag name in sanitizer `#{name}`: lowercase letters, digits and `-`") unless t.match?(/\A[a-z][a-z0-9-]*\z/)
        bad(node, "sanitizer `#{name}` may not allow the tag `#{t}`: it runs script or loads active content") if SANITIZER_FORBIDDEN_TAGS.include?(t)
      end
      attributes.each do |a|
        bad(node, "`#{a.inspect}` is not an attribute name in sanitizer `#{name}`: lowercase letters, digits, `-`, `_` and `:`") unless a.match?(/\A[a-z][a-z0-9_:-]*\z/)
        bad(node, "sanitizer `#{name}` may not allow the attribute `#{a}`: an event handler or an embedded document runs script") if a.start_with?("on") || SANITIZER_FORBIDDEN_ATTRIBUTES.include?(a)
      end
      bad(node, "`tags:` of sanitizer `#{name}` lists a tag twice") unless tags.uniq.size == tags.size
      bad(node, "`attributes:` of sanitizer `#{name}` lists an attribute twice") unless attributes.uniq.size == attributes.size
      bad(node, "`link_rel: true` is the default (ammonia adds rel=\"noopener noreferrer\" to links); leave `link_rel:` out, or write `link_rel: false`") if kw[:link_rel] == true
      target = kw[:autolink_target]
      bad(node, "`autolink_target:` of sanitizer `#{name}` is a browsing-context name such as \"_blank\", got #{target.inspect}") if target && !target.match?(/\A_?[A-Za-z][A-Za-z0-9_-]*\z/)
      entry = { "name" => name, "tags" => tags, "attributes" => attributes, **located(node) }
      entry["link_rel"] = false if kw[:link_rel] == false
      entry["autolink_target"] = target if target
      attachments = sanitizer_attachments(node, name, kw[:attachments])
      entry["attachments"] = attachments unless attachments.empty?
      sounds, partials = sanitizer_sounds(node, name, kw[:sounds], kw[:sound_partials])
      unless sounds.empty?
        entry["sounds"] = sounds
        entry["sound_partials"] = partials
      end
      srv["sanitizers"] << entry
      (@sanitizer_nodes ||= {})[name] = node
      (@flags["sanitizers"] ||= {})[name] = entry
    end

    # The attachment content types a `sanitizer` can render, and the partial arguments each reads (Body::SANITIZER_PARTIALS).
    SANITIZER_ATTACHMENTS = ["application/vnd.actiontext.opengraph-embed", "application/vnd.campfire.mention"].freeze

    # `attachments: { "application/vnd.actiontext.opengraph-embed" => :opengraph_embed }`: the view partial that draws
    # an <action-text-attachment> of each content type. Only a type the compiler can read the details of is accepted.
    def sanitizer_attachments(node, name, hash)
      (hash || {}).to_h do |type, partial|
        unless SANITIZER_ATTACHMENTS.include?(type)
          bad(node, "sanitizer `#{name}` cannot render the attachment type #{type.inspect}; it reads #{SANITIZER_ATTACHMENTS.join(", ")}")
        end
        unless partial.is_a?(Symbol) && partial.to_s.match?(Views::NAME)
          bad(node, "`attachments:` of sanitizer `#{name}` names the partial that draws #{type} with a symbol, such as :opengraph_embed")
        end
        [type, partial.to_s]
      end
    end

    # `sounds: { "bell" => "🔔", "56k" => ["sounds/56k.webp", 79, 33] }, sound_partials: { text: :sound_with_text, image: :sound_with_image }`:
    # the names a body of exactly `/play NAME` plays, each with its text or its image (a file under the digest
    # mount, its width and height), and the two partials that draw them. Returns [the sounds, the partials].
    def sanitizer_sounds(node, name, sounds, partials)
      if sounds.nil? || sounds.empty?
        bad(node, "`sound_partials:` of sanitizer `#{name}` draws the `sounds:` it lists, and it lists none") if partials
        return [[], nil]
      end
      unless partials && %w[text image].sort == partials.keys.map(&:to_s).sort && partials.values.all? { |v| v.is_a?(Symbol) && v.to_s.match?(Views::NAME) }
        bad(node, "sanitizer `#{name}` lists `sounds:`, so it needs `sound_partials: { text: :sound_with_text, image: :sound_with_image }`: the partials that draw a text sound and an image sound")
      end
      list = sounds.map do |sound, what|
        bad(node, "`#{sound.inspect}` is not a sound name in sanitizer `#{name}`: letters, digits and _ (a body is `/play NAME`)") unless sound.match?(/\A[A-Za-z0-9_]+\z/)
        if what.is_a?(String)
          { "name" => sound, "text" => what }
        elsif what.is_a?(Array) && what.size == 3 && what[0].is_a?(String) && what[1..].all? { |n| n.is_a?(Integer) && n.positive? }
          { "name" => sound, "image" => what[0], "width" => what[1], "height" => what[2] }
        else
          bad(node, "sound `#{sound}` of sanitizer `#{name}` is its text (\"🔔\") or its image [\"sounds/#{sound}.webp\", width, height]")
        end
      end
      [list, partials.to_h { |k, v| [k.to_s, v.to_s] }]
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
      missing = kw[:missing]
      bad(node, "current `#{name}` says both `missing:` and `required:`; `missing:` fails the request itself, `required:` leaves it to a `before` filter: pick one") if missing && required
      if ret["bare"]
        bad(node, "current `#{name}` returns :#{ret["record"]}, which may be missing: write `returns: :#{ret["record"]}?` (nil when absent) " \
                  "or `returns: :#{ret["record"]}, missing: \"message\"` (the request fails with the message when the body yields nothing)") unless missing
      elsif missing
        bad(node, "`missing:` is for a current that returns a record without `?`, as in `returns: :Record, missing: \"message\"`; this one returns #{TypeNames.display(ret["rtype"].to_sym)}")
      end
      if required
        nilable = ret["shape"] == "one" || ret["nilable"]
        bad(node, "current `#{name}` already returns #{TypeNames.display(ret['rtype'].to_sym)}; `required:` is for a nil-able current, `returns: :Record?` or a `:type?`") unless nilable
      end
      body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "current `#{name}`", @binding_modules,
                      @helper_table, srv["params"] + srv["records"], kind: :current).lower_current(blk, name, ret["rtype"].to_sym)
      entry = { "name" => name, **ret.except("bare"), "body" => body, **located(node) }
      if missing # the body yields the row or nil; the value is the row, and nil fails the request like `raise`
        entry["missing"] = missing
        entry["rtype"] = "struct:#{ret["record"]}"
      end
      if required
        entry["required"] = required
        entry["rtype_required"] = ret["shape"] == "one" ? "struct:#{ret['record']}" : ret["type"]
      end
      srv["currents"] << entry
      (@current_nodes ||= {})[name] = node
      (@flags["currents"] ||= {})[name] = entry
      return unless (reader = kw[:reader])

      readers = (@flags["current_readers"] ||= {})
      bad(node, "`reader: :#{reader}` already reads current `#{readers[reader]}`") if readers.key?(reader)
      bad(node, "`reader: :#{reader}` is a name the DSL keeps; pick another") if RESERVED_HELPERS.include?(reader) || reader.start_with?("__")
      readers[reader] = name
      (@reader_nodes ||= {})[reader] = node
    end

    # view_local :vapid_key do setting(:vapid_public_key) end: a named value a view may read without a `locals:` entry
    # (docs/views.md, "Locals without locals:"). Only the declaration is kept here; Body#bind_view_locals lowers the block
    # in the route that renders a view reading the name, so a view_local no render reads costs nothing. In a controller
    # the entry is scoped to that controller; a controller entry of the same name wins over a top-level one.
    def view_local_decl(node, pos, blk, ctrl = nil)
      name = pos[0]
      table = view_local_table(ctrl)
      bad(node, "duplicate view_local `#{name}`#{first_at(node, table[name] && table[name]['node'])}") if table.key?(name)
      bad(blk.parameters, "a `view_local` block takes no parameters") if blk.parameters
      bad(blk, "empty view_local body") unless blk.body.is_a?(Prism::StatementsNode)
      table[name] = { "node" => node, "block" => blk, "kind" => "view_local", "scope" => nil }
    end

    # page_locals do account_css = account_custom_styles; signed_in = true end: a block of page locals declared once
    # for a controller (or the top level). Each line is `name = value`, lowered only in a route whose render reads the
    # name. A name the layout reads is refused here: it belongs in `layout_locals`. See view_local_decl for the
    # scoping rule.
    def page_locals_decl(node, blk, ctrl = nil) = locals_block_decl(node, blk, ctrl, :page)

    # layout_locals do account_css = account_custom_styles; signed_in = true end: the same block for the names the
    # layout reads. A layout local may also feed a page (a frame page, or a page that repeats a layout marker); a page
    # local may not feed the layout, which is the shadowing the split prevents.
    def layout_locals_decl(node, blk, ctrl = nil) = locals_block_decl(node, blk, ctrl, :layout)

    def locals_block_decl(node, blk, ctrl, scope)
      label = "#{scope}_locals"
      bad(blk.parameters, "a `#{label}` block takes no parameters") if blk.parameters
      st = blk.body
      bad(blk, "empty #{label} body") unless st.is_a?(Prism::StatementsNode) && !st.body.empty?
      table = view_local_table(ctrl, scope)
      st.body.each do |n|
        unless n.is_a?(Prism::LocalVariableWriteNode) || n.is_a?(Prism::InstanceVariableWriteNode)
          bad(n, "#{label} takes `name = value` or `@name = value` lines, as in `#{label} do title = \"Campfire\" end`")
        end
        # `@x = ...` is read by a template as `{{ @x }}`; it lives in the same table under the name the parser gives
        # the marker (Views.mangle) and lowers to the same `let`, so it costs nothing a plain entry does not.
        ivar = n.is_a?(Prism::InstanceVariableWriteNode)
        name = ivar ? "#{Views::IVAR_PREFIX}#{n.name.to_s.delete_prefix("@")}" : n.name.to_s
        unless name.match?(Views::NAME)
          bad(n, "`#{name}` cannot be a #{scope} local's name: a marker spells it literally, so the name is letters, " \
                 "digits and _, and does not start with a digit")
        end
        bad(n, "duplicate #{scope} local `#{Views.show(name)}`#{first_at(n, table[name] && table[name]['node'])}") if table.key?(name)
        table[name] = { "node" => n, "value" => n.value, "kind" => label, "scope" => scope.to_s }
        table[name]["ivar"] = true if ivar
      end
    end

    # The view_locals a controller (or the top level, when ctrl is nil) declares. A controller's table is merged over
    # the top-level one by Body#bind_view_locals. `view_local` is the agnostic single-name form (scope nil); the two
    # blocks say which side of the layout/page split a name belongs to.
    def view_local_table(ctrl, scope = :page)
      if ctrl
        key = scope == :layout ? "controller_layout_view_locals" : "controller_view_locals"
        (@flags[key] ||= {})[ctrl] ||= {}
      else
        key = scope == :layout ? "layout_view_locals" : "view_locals"
        @flags[key] ||= {}
      end
    end

    # A current's `reader:` is a bare call in a body, so no def, helper or statement may share its name: one of them
    # would hide the other, and a reader of the code could not tell which `current_user` they are reading.
    def check_current_readers(srv)
      (@flags["current_readers"] || {}).each_key do |reader|
        node = @reader_nodes.fetch(reader)
        defs = (@global_defs || {}).merge(*(@controller_defs || {}).values)
        bad(node, "`reader: :#{reader}` has the name of a def#{first_at(node, defs[reader])}") if defs.key?(reader)
        bad(node, "`reader: :#{reader}` has the name of a helper") if @helper_table.key?(reader)
        bad(node, "`reader: :#{reader}` has the name of a query") if srv["queries"].any? { |q| q["name"] == reader }
      end
    end

    # flash cookie: "_campfire_session", notice: { notice_saved: "✓" }, alert: { room_not_found: "..." }: Rails' flash
    # as Campfire's port carries it, a suffix `.<key>` on a plain cookie's value (docs/sessions.md, "Flash"). The keys
    # are every message the service can show; `redirect(path, notice: :key)` and `take_flash` name them.
    def add_flash(node, kw, srv)
      bad(node, "duplicate `flash`#{first_at(node, @flash_node)}; a service declares its messages once") if @flash_node
      @flash_node = node
      cookie = kw[:cookie]
      bad(node, "flash `cookie:` names a cookie, such as \"_campfire_session\"") unless cookie.match?(SNAKE) || cookie.match?(/\A_[a-z][a-z0-9_]*\z/)
      messages = []
      { notice: false, alert: true }.each do |kind, alert|
        (kw[kind] || {}).each do |key, text|
          bad(node, "flash `#{kind}:` key `#{key}` must be snake_case: it is the cookie's `.#{key}` suffix") unless key.match?(SNAKE)
          bad(node, "flash `#{kind}: { #{key}: ... }` is the message's text, a string") unless text.is_a?(String)
          bad(node, "flash key `#{key}` is declared twice") if messages.any? { |m| m["key"] == key }
          messages << { "key" => key, "text" => text, "alert" => alert }
        end
      end
      bad(node, "flash declares no message; give `notice: { key: \"text\" }` or `alert: { ... }`") if messages.empty?
      srv["flash"] = { "cookie" => cookie, "messages" => messages, **located(node) }
      @flags["flash"] = srv["flash"]
    end

    # default_locale :en: the locale a request is answered in when its `locale` query parameter names none that a locale
    # file holds (docs/views.md, "Locales"). Optional: a file that calls `t` and never says it uses :en when a file holds it,
    # else the only locale there is. Whether a file holds the locale is checked when the files are read (Body#i18n_table).
    def default_locale_decl(node, pos)
      bad(node, "duplicate `default_locale`#{first_at(node, @default_locale_node)}; a service has one default locale") if @default_locale_node
      @default_locale_node = node
      @flags["default_locale"] = pos[0].to_s
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
      defs = {}
      each_child(blk, :record) do |n, p, k, _b|
        next add_record_method(n, name, defs) if n.is_a?(Prism::DefNode)

        fname, ftype = p
        bad(n, "duplicate field `#{fname}`") if fields.any? { |f| f["name"] == fname }
        if (elem = CompositeTypes.object_list_name(ftype))
          # A list of records is not a column: the query named by `from:` runs once per row, its arguments filled
          # from this row's fields of the same names (checked in check_queries, once every record is read).
          from = k[:from] or bad(n, "record field `#{fname}` is a list of #{elem}, which no column holds: name the query that fills it, `field :#{fname}, list(:#{elem}), from: :a_query`")
          k.each_key { |key| bad(n, "`#{key}:` does not apply to a list field of a record; the only option is `from:`") unless key == :from }
          field = { "name" => fname, "type" => ftype, "from" => from }
          note_field(n, field)
          fields << field
          next
        end
        fields << column_field(n, fname, ftype, k, "record", "; a list of records is `list(:Record), from: :a_query`")
      end
      bad(node, "record `#{name}` has no fields") if fields.empty?
      defs.each do |mname, dnode|
        bad(dnode, "record `#{name}` has a field and a def named `#{mname}`; a name is a field or a def, never both") if fields.any? { |f| f["name"] == mname }
      end
      (@record_defs ||= {})[name] = defs unless defs.empty?
      srv["records"] << { "name" => name, "kind" => "record", "fields" => fields, **located(node) }
      (@record_nodes ||= {})[name] = node
    end

    # A `def` in a record block is a method of the row (docs/database.md, "Record methods"): no parameters, the body
    # language, compiled by lower_record_methods once every record is read.
    def add_record_method(node, rname, defs)
      mname = node.name.to_s
      bad(node, "a def takes no receiver (`def self.x` is a class method; write `def x`)") if node.receiver
      bad(node, "record method `#{mname}` must be snake_case") unless mname.match?(SNAKE)
      bad(node.parameters, "record method `#{mname}` of #{rname} takes parameters, and parameters are not supported on record methods yet; write it without, and read the row's fields by name") if node.parameters
      bad(node, "duplicate def `#{mname}` in record `#{rname}`#{first_at(node, defs[mname])}") if defs[mname]
      bad(node, "record method `#{mname}` is empty") unless node.body
      defs[mname] = node
    end

    # One column of a record or a table: a scalar type, and `optional: true` for a column that may be NULL.
    # `owner` ("record" or "table") words the refusals; `hint` is what a record adds to the type refusal.
    def column_field(n, fname, ftype, k, owner, hint = "")
      unless Db::COLUMNS.include?(ftype)
        bad(n, "#{owner} field `#{fname}` is a column, so its type is one of #{Db::COLUMNS.map { |t| ":#{t}" }.join(', ')}, not :#{ftype}#{hint}")
      end
      k.each_key do |key|
        bad(n, "`from:` fills a list field; a column has none") if key == :from
        bad(n, "`#{key}:` does not apply to a #{owner} field; the only option is `optional: true`, for a column that may be NULL") unless key == :optional
      end
      bad(n, "`optional: false` is the default; leave `optional:` out") if k[:optional] == false
      field = { "name" => fname, "type" => ftype }
      field["optional"] = true if k[:optional]
      note_field(n, field)
      field
    end

    # table :rooms do field :id, :i64 ... end: a table of the database, for the schema registry (Db::Schema) the model
    # layer will read. It emits no Rust and adds no statement, and nothing consumes it yet, so an unused one is not
    # refused. Its fields are the columns of a record, and `id` is the primary key, which is never NULL.
    def add_table(node, pos, blk, srv)
      name = pos[0]
      earlier = srv["tables"].find { |t| t["name"] == name }
      bad(node, "duplicate table `#{name}`#{first_at(node, earlier && @table_nodes[name])}") if earlier
      columns = []
      each_child(blk, :table) do |n, p, k, _b|
        fname, ftype = p
        bad(n, "duplicate column `#{fname}` in table `#{name}`") if columns.any? { |c| c["name"] == fname }
        column = column_field(n, fname, ftype, k, "table")
        bad(n, "`id` is the primary key of table `#{name}`, which is never NULL; leave `optional:` out") if fname == "id" && column["optional"]
        columns << column
        @graph&.declare("column:#{name}.#{fname}", at: n, type: column["type"].to_s)
      end
      bad(node, "table `#{name}` has no fields") if columns.empty?
      srv["tables"] << { "name" => name, "columns" => columns.map { |c| { "name" => c["name"], "type" => c["type"], "optional" => c["optional"] == true } }, **located(node) }
      (@table_nodes ||= {})[name] = node
    end

    # What `returns:` of a query says, as the IR carries it until the records are all read (check_queries):
    # `list(:Note)` is every row, `:Note?` the first row or nil, and a scalar type (`:i64`, `?` for nil-able)
    # the first column of the first row.
    def query_returns(node, bare: false)
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
        return { "shape" => "one", "record" => base, "bare" => true } if bare && !nilable # a `current`: Reader#current_decl asks for `missing:`
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
    # Inside a `model` that names its table the statement may take a block (`relation`) instead of `sql:`, one
    # relation chain that RelationQueries renders to SQL once the file is read (docs/database.md, "Queries as relations").
    def add_query(node, pos, kw, srv, relation = nil)
      name = pos[0]
      what = node.name.to_s
      if (earlier = srv["queries"].find { |q| q["name"] == name })
        bad(node, "`#{name}` is already declared by #{earlier['kind'] == 'query' ? 'a query' : 'an execute'}#{first_at(node, @query_nodes[name])}")
      end
      if RESERVED_HELPERS.include?(name) || %w[errors headers render h raw].include?(name)
        bad(node, "`#{name}` is reserved; pick another #{what} name")
      end
      add_statement(srv, node, name, what, kw[:args], kw[:returns], kw[:sql], relation)
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

    # A record's list fields (`field :boosts, list(:Boost), from: :boosts_of`): the sub-query runs once per row of
    # the record, so it must be a query returning list(:Boost), whose arguments are columns of this record with the
    # same names and types, and the element record is a plain row (one level: no list fields of its own). The
    # sub-query counts as called, and as called inside a transaction (the row's own connection), so it gets no
    # pooled wrapper unless a body also calls it.
    def check_record_lists(srv)
      names = srv["records"].map { |r| r["name"] }
      srv["records"].each do |r|
        node = @record_nodes.fetch(r["name"])
        r["fields"].select { |f| f["from"] }.each do |f|
          elem = CompositeTypes.object_list_name(f["type"])
          child = srv["records"].find { |x| x["name"] == elem } or
            undeclared(node, "record `#{r['name']}`: field `#{f['name']}` is a list of `#{elem}`, which is not a declared record", elem, names)
          bad(node, "record `#{r['name']}`: field `#{f['name']}` lists `#{elem}`, which has list fields of its own; one level of lists is supported") if child["fields"].any? { |x| x["from"] }
          qnames = srv["queries"].select { |q| q["kind"] == "query" }.map { |q| q["name"] }
          sub = srv["queries"].find { |q| q["name"] == f["from"] && q["kind"] == "query" } or
            undeclared(node, "record `#{r['name']}`: field `#{f['name']}` is filled `from: :#{f['from']}`, which is not a query", f["from"], qnames)
          ret = sub["returns"]
          unless ret && ret["shape"] == "list" && ret["record"] == elem
            bad(node, "record `#{r['name']}`: field `#{f['name']}` is a list of `#{elem}`, so query `#{sub['name']}` must return list(:#{elem})")
          end
          sub["args"].each do |aname, atype|
            col = r["fields"].find { |x| x["name"] == aname && !x["from"] }
            bad(node, "record `#{r['name']}`: query `#{sub['name']}` takes `#{aname}`, which the sub-query is filled with from the row's field of that name, and record `#{r['name']}` has no such column (its columns: #{r['fields'].reject { |x| x['from'] }.map { |x| x['name'] }.join(', ')})") unless col
            bad(node, "record `#{r['name']}`: query `#{sub['name']}` takes `#{aname}` as :#{atype}, but the column `#{aname}` is :#{col['type']}") unless col["type"] == atype
            bad(node, "record `#{r['name']}`: column `#{aname}` is optional, so it cannot be bound as an argument of `#{sub['name']}`") if col["optional"]
          end
          (@flags["used_queries"] ||= {})[sub["name"]] = true
          (@flags["queries_in_tx"] ||= {})[sub["name"]] = true
        end
      end
    end

    # The methods of each record, compiled (Body#lower_record_method) once every record is read, in dependency order:
    # a method that reads another is compiled after it, so it knows the type. A method that reaches itself, directly
    # or through others, is refused. The IR record then carries "methods", which the body and view compilers read like
    # fields (Body#struct_field) and the emitter writes as `impl` functions (Db::Sqlite.record_lines).
    def lower_record_methods(srv)
      srv["records"].each do |r|
        defs = (@record_defs ||= {})[r["name"]] or next
        done = {}
        pending = []
        compile = lambda do |mname|
          next done[mname] if done[mname]

          node = defs.fetch(mname)
          if (i = pending.index(mname))
            bad(node, "record method `#{mname}` of #{r['name']} reaches itself (#{(pending[i..] + [mname]).join(' -> ')}); a record method is a plain function, so it cannot recurse")
          end
          pending.push(mname)
          deps = Body.bare_reads(node, defs.keys).to_h { |d| [d, compile.call(d)] }
          sibling_types = deps.to_h { |d, m| [d, TypeNames.field_symbol(m)] }
          pending.pop
          done[mname] = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "record method `#{mname}` of #{r['name']}", @binding_modules, {})
                            .lower_record_method(node, r, sibling_types, @helper_names.to_a)
        end
        r["methods"] = defs.keys.map { |m| compile.call(m) }
      end
    end

    # What a query returns, resolved against the records (a record may be declared after the query that returns
    # it): the IR then carries the shape, the record's field names the server checks the columns against at
    # startup, and the type a body sees the call as.
    def check_queries(srv)
      srv["records"].each do |r|
        next unless srv["params"].any? { |p| p["name"] == r["name"] }

        bad(@record_nodes.fetch(r["name"]), "record `#{r['name']}` has the same name as a params group; both become a struct of that name")
      end
      check_record_lists(srv)
      lower_record_methods(srv)
      srv["queries"].each do |q|
        node = @query_nodes.fetch(q["name"])
        bad(node, "#{q['kind']} `#{q['name']}` has the same name as a rust_fn, cmd_fn or script_fn") if srv["externs"].key?(q["name"])
        ret = q.delete("returns") or next
        if %w[list one].include?(ret["shape"])
          names = srv["records"].map { |r| r["name"] }
          rec = srv["records"].find { |r| r["name"] == ret["record"] } or
            undeclared(node, "query `#{q['name']}` returns record `#{ret['record']}`, which is not declared", ret["record"], names)
          q.merge!("shape" => ret["shape"], "record" => rec["name"], "fields" => rec["fields"].reject { |f| f["from"] }.map { |f| f["name"] })
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

    # A `file ..., binary: true` (an image send_file answers with): found and confined like local_source, but never
    # read as text, so its bytes need not be UTF-8. [real path, ""].
    def local_binary(node, rel)
      base = dir_of(node)
      full = File.expand_path(rel, base)
      bad(node, "file not found: #{rel}") unless File.file?(full)
      real = File.realpath(full)
      bad(node, "file must stay inside #{base}") unless real.start_with?(base + File::SEPARATOR)
      bad(node, "file is larger than #{MAX_RS_BYTES} bytes") if File.size(real) > MAX_RS_BYTES
      [real, ""]
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

    # The name a file is served under with `digest: true`: its own name with `-<8 hex digits>` before the
    # extension, so `campfire.css` becomes `campfire-3f9a0c1b.css`. The digits are Propshaft's (AxumDsl::Propshaft.digest:
    # SHA-1 of the file, the files its CSS refers to, and the assets version), so the name changes exactly when the
    # file or one it refers to does -- which is what makes a far-future Cache-Control safe on it -- and is the
    # name Rails serves the same file under.
    def fingerprinted(rel, digest)
      dir = File.dirname(rel)
      base = File.basename(rel)
      ext = File.extname(base)
      stem = ext.empty? ? base : base.delete_suffix(ext)
      name = "#{stem}-#{digest}#{ext}"
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
        reals = {}
        texts = {}
        files.each do |crate_path, file|
          rel = crate_path.delete_prefix("#{base}/")
          reals[rel] = file
          texts[rel] = asset_text(file)
        end
        version = kw[:version] || Propshaft::VERSION
        fingers = texts.keys.to_h { |rel| [rel, fingerprinted(rel, Propshaft.digest(rel, texts, version))] }
        mount = pre == "/" ? "" : pre
        texts.each do |rel, text|
          finger = fingers[rel]
          target = "#{base}/#{finger}"
          if used.key?(target)
            bad(node, "two files under static dir #{dir.inspect} both fingerprint to #{target}; rename one")
          end
          used[target] = true
          add_asset(node, srv, target, reals[rel], text: Propshaft.compile(rel, text, fingers, mount))
          urls[rel] = "#{mount}/#{finger}"
        end
        (@flags["asset_mounts"] ||= []) << pre
        (@flags["asset_urls"] ||= {})[pre] = urls
        entry = { "prefix" => pre, "dir" => dir, "files" => files.size, "digest" => true, **located(node) }
        entry["version"] = kw[:version] if kw[:version]
        entry["max_age"] = kw[:max_age] if kw[:max_age]
        entry["skip"] = kw[:skip] if kw[:skip]
        srv["statics"] << entry
      else
        bad(node, "`static` `version:` is the assets version of a `digest: true` mount; add `digest: true` or drop `version:`") if kw[:version]
        files.each { |crate_path, file| add_asset(node, srv, crate_path, file) }
        entry = { "prefix" => pre, "dir" => dir, "files" => files.size, **located(node) }
        entry["max_age"] = kw[:max_age] if kw[:max_age]
        entry["skip"] = kw[:skip] if kw[:skip]
        srv["statics"] << entry
      end
    end

    # serve_file "/report.txt", from: "public/report.txt": one route answered by one file, copied into the
    # crate at its own relative path like a static mount. It is deliberately declarative: a body-level
    # send_file would have to await a file service, and the body language has no such await.
    def add_serve_file(node, path, from, kw, srv)
      route = service_path(node, path, "a serve_file path")
      bad(node, "duplicate serve_file #{route.inspect}") if srv["serve_files"].any? { |f| f["path"] == route }
      real = asset_path(node, from, "serve_file from")
      bad(node, "serve_file from #{from.inspect} is a directory; mount a directory with `static \"/assets\", dir: ...`") if File.directory?(real)
      entry = { "path" => route, "from" => from, **located(node) }
      entry["max_age"] = kw[:max_age] if kw[:max_age]
      entry["skip"] = kw[:skip] if kw[:skip]
      (@serve_file_nodes ||= {})[route] = node
      srv["serve_files"] << entry
      add_asset(node, srv, from, real)
    end

    # cable "/cable", authenticate_with: :user do channel "HeartbeatChannel" ... end: an Action Cable endpoint
    # (docs/cable.md). The path is written out like a serve_file's. The connection is authenticated by a nil-able
    # `current`, each `channel` is a subscription name the client may confirm, and the options of a channel say what
    # its identifier must carry. Read after the routes, the currents and the queries, so each name is checked.
    def add_cable(node, pos, kw, blk, srv)
      bad(node, "duplicate `cable`#{first_at(node, @cable_node)}; a service has one Action Cable endpoint") if srv["cable"]
      path = service_path(node, pos[0], "a cable path")
      taken = srv["routes"].any? { |r| r["method"] == "get" && r["path"] == path } ||
              srv["serve_files"].any? { |f| f["path"] == path } || srv["openapi"]&.[]("path") == path ||
              srv["statics"].any? { |s| path == s["prefix"] || path.start_with?("#{s['prefix'].chomp('/')}/") }
      bad(node, "the cable path #{path.inspect} is already answered by a GET route, a `serve_file`, the OpenAPI document or a `static` mount") if taken
      @cable_node = node
      name = kw[:authenticate_with]
      cur = srv["currents"].find { |c| c["name"] == name } or
        undeclared(node, "`cable` authenticates with current `#{name}`, which is not declared", name, srv["currents"].map { |c| c["name"] })
      unless (cur["shape"] == "one" && !cur["missing"]) || (cur["shape"] == "scalar" && cur["nilable"])
        bad(node, "`cable authenticate_with: :#{name}` needs a nil-able current (`returns: :Record?` or a `:type?`): nil is the connection that is not signed in")
      end
      (@flags["used_currents"] ||= {})[name] = true
      channels = []
      each_child(blk, :cable) do |n, p, k, b|
        channels << cable_channel(n, p[0], k, b, channels, cur, srv)
      end
      bad(node, "`cable` declares no channel; add one inside the block, such as `channel \"HeartbeatChannel\"`") if channels.empty?
      entry = { "path" => path, "authenticate_with" => name, "channels" => channels, "user_rust" => cable_user_types(cur).last, **located(node) }
      member = channels.find { |c| c["member_of"] }
      entry["user_id"] = cable_user_id(@cable_member_nodes[member["name"]], cur, srv) if member
      # `close_remote_connections(key)` finds a connection by the identity its session holds.
      closers = @flags["close_sites"]
      entry["user_key"] = cable_user_key(closers, cur, srv) if closers
      srv["cable"] = entry
    end

    # The signed-in user as a channel callback sees it: [the body language's type, the Rust type]. A record current is
    # the record, a scalar current its scalar (it is never nil once the connection is authenticated).
    def cable_user_types(cur)
      return [:"struct:#{cur['record']}", cur["record"]] if cur["shape"] == "one"

      [cur["type"].to_sym, Sessions::SCALAR_RUST.fetch(cur["type"])]
    end

    # A broadcast needs the hub the `cable` declaration writes, so a file that broadcasts and has no `cable` is refused,
    # at the first broadcast (the bodies that call it are compiled before the cable is read).
    def check_broadcast_sites(srv)
      site = @flags["broadcast_sites"]&.first
      return if site.nil? || srv["cable"]

      bad(site, "this broadcasts to Action Cable subscribers, and the file declares no `cable`; add `cable \"/cable\", authenticate_with: :user do ... end`")
    end

    # One `channel "Name", signed_stream:, room_param:, member_of:, on_subscribe:` of a cable: its IR hash.
    def cable_channel(node, name, kw, blk, earlier, cur, srv)
      unless name.match?(/\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/)
        bad(node, "channel name #{name.inspect} is the class name the client subscribes with, such as \"RoomMessagesChannel\"")
      end
      bad(node, "duplicate channel #{name.inspect}") if earlier.any? { |c| c["name"] == name }
      bad(node, "channel #{name.inspect} names both `signed_stream:` and `room_param:`; a subscription finds its room one way") if kw[:signed_stream] && kw[:room_param]
      channel = { "name" => name }
      channel["signed_stream"] = cable_secret(node, kw[:signed_stream], srv) if kw[:signed_stream]
      channel["room_param"] = kw[:room_param] if kw[:room_param]
      if kw[:member_of]
        bad(node, "channel #{name.inspect}: `member_of:` needs `signed_stream:` or `room_param:` to say which room to ask about") unless channel["signed_stream"] || channel["room_param"]
        channel["member_of"] = cable_member_query(node, kw[:member_of], srv)
        (@cable_member_nodes ||= {})[name] = node
      end
      if kw[:on_subscribe]
        bad(node, "channel #{name.inspect}: `on_subscribe:` needs `member_of:`, because it runs for the room and the user the subscription proved") unless channel["member_of"]
        channel["on_subscribe"] = cable_subscribe_statement(node, kw[:on_subscribe], srv)
      end
      channel["broadcasting"] = Cable.channel_name(name)
      cable_callbacks(node, name, blk, channel, cur, srv) if blk
      channel
    end

    # The callbacks in a channel's block, lowered into the channel's IR (docs/cable.md). `stream_from` and `stream_for`
    # name what the subscription listens to; `after_subscribe` runs once the streams are joined, `on_unsubscribe` when the
    # subscription is dropped or the socket closes, and each `perform :action` answers that action of a client's `message`.
    # A callback names the values it wants as block parameters: the signed-in user (under the `current`'s name), `room_id` when the
    # channel finds a room, and `room` (the row `member_of:` found) while the subscription is being made.
    def cable_callbacks(node, name, blk, channel, cur, srv)
      calls = []
      each_child(blk, :channel) { |n, p, k, b| calls << [n, p, k, b] }
      declares_for = calls.any? { |n, _, _, _| n.name == :stream_for }
      user_type, user_rust = cable_user_types(cur)
      vars = { cur["name"] => [user_type, user_rust] }
      vars["room_id"] = [:i64, "i64"] if channel["room_param"] || (channel["signed_stream"] && channel["member_of"])
      subscribing = vars.dup
      subscribing["room"] = [:"struct:#{channel['member_of']['record']}", channel["member_of"]["record"]] if channel["member_of"]
      lower = lambda do |n, b, label, scope, ret, stream_for|
        Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "channel #{name.inspect} #{label}", @binding_modules,
                 @helper_table, srv["params"] + srv["records"], kind: :cable).lower_cable(b, scope, ret, stream_for).merge("label" => label, **located(n))
      end
      calls.each do |n, p, _k, b|
        case n.name
        when :stream_from, :stream_for, :after_subscribe, :on_unsubscribe
          key = n.name.to_s
          bad(n, "channel #{name.inspect} declares `#{key}` twice") if channel[key]
          if n.name == :stream_from || n.name == :stream_for
            channel[key] = lower.call(n, b, key, subscribing, :string, false)
          elsif n.name == :after_subscribe
            channel[key] = lower.call(n, b, key, subscribing, :unit, declares_for)
          else
            channel[key] = lower.call(n, b, key, vars, :unit, declares_for)
          end
        when :perform
          action = p[0]
          performs = (channel["performs"] ||= [])
          bad(n, "channel #{name.inspect} performs `#{action}` twice") if performs.any? { |x| x["action"] == action }
          performs << { "action" => action, "body" => lower.call(n, b, "perform :#{action}", vars, :unit, declares_for) }
        end
      end
    end

    # `signed_stream: :secret_key`: the setting Turbo's signed stream names are verified with, held to the rules of
    # every signing call (Body#signed_secret!): a required string setting, one secret for the whole service.
    def cable_secret(node, secret, srv)
      declared = @flags["settings"] || {}
      entry = declared[secret] or
        bad(node, "no setting `#{secret}` is declared#{declared.empty? ? '' : " (declared: #{declared.keys.join(', ')})"}; `signed_stream:` names the required string setting that holds SECRET_KEY_BASE",
            word: secret, from: declared.keys)
      if entry["type"] || entry["optional"]
        bad(node, "`signed_stream:` must name a required string setting, not #{entry['type'] ? "a `type: :#{entry['type']}`" : 'an optional'} one")
      end
      if (earlier = @flags["signed_id_secret"]) && earlier != secret
        bad(node, "`signed_stream: :#{secret}`: the service already signs with setting `#{earlier}`; a service derives one signed-ID key per process, so every call must name the same secret")
      end
      @flags["signed_id_secret"] = secret
      (@flags["used_settings"] ||= {})[secret] = true
      (@flags["builtins"] ||= {})[SignedId::TURBO_VERIFY] = true
      secret
    end

    # `member_of: :room_for_user`: a query taking `id:` (the room) and `user_id:`, both :i64, and returning `:Record?`.
    # The room is a member's when it finds a row. Marked called, with its pooled wrapper, so the crate emits it.
    def cable_member_query(node, name, srv)
      queries = @flags["queries"] || {}
      q = queries[name] or undeclared(node, "`member_of:` names query `#{name}`, which is not declared", name, queries.keys)
      unless q["kind"] == "query" && q["shape"] == "one" && q["args"].map(&:first).sort == %w[id user_id] && q["args"].all? { |_, t| t == "i64" }
        bad(node, "`member_of: :#{name}` needs a query with the arguments `id:` and `user_id:` (both :i64) that returns `:Record?`: the row of the room and the user, or nil")
      end
      (@flags["used_queries"] ||= {})[name] = true
      (@flags["queries_outside"] ||= {})[name] = true
      { "name" => name, "args" => q["args"].map(&:first), "record" => q["record"] }
    end

    # `on_subscribe: :connect_membership`: an `execute` (or `query`) taking `room_id:` and `user_id:`, both :i64, run
    # once for each confirmed subscription. Marked called, with its pooled wrapper, so the crate emits it.
    def cable_subscribe_statement(node, name, srv)
      queries = @flags["queries"] || {}
      q = queries[name] or undeclared(node, "`on_subscribe:` names statement `#{name}`, which is not declared", name, queries.keys)
      unless q["args"].map(&:first).sort == %w[room_id user_id] && q["args"].all? { |_, t| t == "i64" }
        bad(node, "`on_subscribe: :#{name}` needs an `execute` with the arguments `room_id:` and `user_id:` (both :i64)")
      end
      (@flags["used_queries"] ||= {})[name] = true
      (@flags["queries_outside"] ||= {})[name] = true
      { "name" => name, "args" => q["args"].map(&:first) }
    end

    # The Rust expression of the signed-in user's id for a `member_of` query: the `id` field of a record current, or
    # the value of an :i64 one.
    def cable_user_id(node, cur, srv)
      if cur["shape"] == "one"
        rec = srv["records"].find { |r| r["name"] == cur["record"] }
        return "user.id" if rec["fields"].any? { |f| f["name"] == "id" && f["type"] == "i64" }

        bad(node, "`member_of:` asks about the user's id, but record `#{cur['record']}` (the current `#{cur['name']}`) has no `id` field of type :i64")
      end
      return "user" if cur["type"] == "i64"

      bad(node, "`member_of:` asks about the user's id, but the current `#{cur['name']}` is a #{cur['type']}, not an :i64 or a record with an `id`")
    end

    # What `close_remote_connections(key)` is matched against: the connection's identity as a Rust String expression of `user`
    # (a record current is its `id`, an :i64 current its value, a string current itself), and the argument types the call
    # may pass for it. `sites` are the calls, as [node, the argument's type].
    def cable_user_key(sites, cur, srv)
      node = sites.first.first
      if cur["shape"] == "one"
        rec = srv["records"].find { |r| r["name"] == cur["record"] }
        bad(node, "`close_remote_connections` closes the connections of a user id, but record `#{cur['record']}` (the current `#{cur['name']}`) has no `id` field of type :i64") unless rec["fields"].any? { |f| f["name"] == "id" && f["type"] == "i64" }
        key, id = "user.id.to_string()", true
      elsif cur["type"] == "i64"
        key, id = "user.to_string()", true
      elsif cur["type"] == "string"
        key, id = "user.clone()", false
      else
        bad(node, "`close_remote_connections` identifies a connection by its current `#{cur['name']}`, which is a #{cur['type']}, not an :i64, a :string or a record with an `id`")
      end
      sites.each do |site, type|
        next if id ? %i[int i64 i32].include?(type) : %i[str string].include?(type)

        bad(site, "`close_remote_connections` takes #{id ? 'the user\'s id (an :i64)' : "the user's name (a string)"}, as the current `#{cur['name']}` is #{id ? 'a record or an :i64' : 'a string'}, got #{TypeNames.display(type)}")
      end
      key
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
                       "fetch_metadata" => [], "csrf" => [], "rate_limit" => [:per, :burst, :path, :enabled],
                       "private_cache" => [:except],
                       "rack_defaults" => RackDefaults::KEYWORDS, "front" => [:cache_mb, :enabled], "method_override" => [], "format_extension" => [] }.freeze
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
        if kw.key?(:enabled)
          entry["enabled"] = kw[:enabled].to_s
          (@enabled_nodes ||= {})["rate_limit"] = node
        end
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
      when "rack_defaults"
        add_rack_defaults(node, kw, entry)
      when "front"
        entry["cache_mb"] = kw[:cache_mb] if kw[:cache_mb]
        if kw.key?(:enabled)
          entry["enabled"] = kw[:enabled].to_s
          (@enabled_nodes ||= {})["front"] = node
        end
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

    # `use_layer :rack_defaults, security_headers: true, etag: true, ...` (RackDefaults): one keyword per part,
    # and at least one must be written. The names a keyword takes are checked here; the settings, the static
    # mounts and the fingerprinted files they name are checked once the whole file is read
    # (check_rack_defaults).
    RACK_COOKIE_NAME = /\A[A-Za-z_][A-Za-z0-9_\-]*\z/
    def add_rack_defaults(node, kw, entry)
      @rack_defaults_node = node
      bad(node, "`use_layer :rack_defaults` needs at least one part: #{RackDefaults::KEYWORDS.map { |k| "`#{k}:`" }.join(', ')}") if kw.empty?
      %i[security_headers etag vary_accept].each { |key| entry[key.to_s] = true if kw[key] }
      %i[version revision].each { |key| entry[key.to_s] = kw[key].to_s if kw[key] }
      %i[preload refresh_cookies except].each do |key|
        next unless kw[key]

        bad(node, "`use_layer :rack_defaults` `#{key}:` needs at least one entry; drop the keyword to leave that part off") if kw[key].empty?
        entry[key.to_s] = kw[key]
      end
      entry["refresh_cookies"].to_a.each do |name|
        bad(node, "`use_layer :rack_defaults` `refresh_cookies:` entry #{name.inspect} must be a cookie name") unless name.match?(RACK_COOKIE_NAME)
      end
      cookie = kw[:session_cookie]
      if cookie
        bad(node, "`use_layer :rack_defaults` `session_cookie:` #{cookie.inspect} must be a cookie name") unless cookie.match?(RACK_COOKIE_NAME)
        entry["session_cookie"] = cookie
        (@flags["builtins"] ||= {})["random_token"] = true
      end
      entry["except"].to_a.each do |prefix|
        bad(node, "`use_layer :rack_defaults` `except:` entry #{prefix.inspect} must start with /, a path prefix as `static` writes it") unless prefix.start_with?("/")
        bad(node, "`use_layer :rack_defaults` `except:` entry #{prefix.inspect} must be a static mount's prefix without a trailing /") if prefix == "/" || prefix.end_with?("/")
      end
    end

    # What needs the whole file: `version:` and `revision:` name declared settings (the layer reads them, so
    # they count as used), `except:` names static mounts, and `preload:` names files of the one fingerprinted
    # mount, resolved here to the URLs the Link header carries.
    def check_rack_defaults(srv)
      entry = srv["layers"].find { |l| l["name"] == "rack_defaults" }
      return unless entry

      node = @rack_defaults_node
      %w[version revision].each do |key|
        next unless entry[key]

        declared = srv["settings"].map { |s| s["name"] }
        unless declared.include?(entry[key])
          bad(node, "`use_layer :rack_defaults` `#{key}:` names setting `#{entry[key]}`, which is not declared (declared: #{declared.join(', ')})", word: entry[key], from: declared)
        end
        (@flags["used_settings"] ||= {})[entry[key]] = true
      end
      entry["except"].to_a.each do |prefix|
        next if srv["statics"].any? { |s| s["prefix"] == prefix || prefix.start_with?("#{s['prefix']}/") }
        next if srv["serve_files"].any? { |f| f["path"] == prefix }

        bad(node, "`use_layer :rack_defaults` `except:` entry #{prefix.inspect} is not served by a `static` mount or a `serve_file`; name a static mount's prefix or a served file's path")
      end
      return unless entry["preload"]

      mounts = @flags["asset_mounts"].to_a
      bad(node, "`use_layer :rack_defaults` `preload:` needs one `static ..., digest: true` mount: the file's fingerprinted URL is the link") unless mounts.size == 1
      urls = (@flags["asset_urls"] || {})[mounts[0]] || {}
      entry["preload_urls"] = entry["preload"].map do |file|
        urls[file] or bad(node, "`use_layer :rack_defaults` `preload:` names #{file.inspect}, which is no file under the #{mounts[0].inspect} mount (files: #{urls.keys.sort.join(', ')})")
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
      binary = kw[:binary] == true
      bad(node, "a `binary: true` file is sent by its path (file_path); it has no `entries:`") if binary && kw[:entries]
      real, source = binary ? local_binary(node, rel) : local_source(node, rel, "file")
      entries = kw[:entries] || []
      twice = entries.find { |e| entries.count(e) > 1 }
      bad(node, "`#{twice}` is listed twice in entries:") if twice
      bad(node, "`entries:` names Python functions, but #{rel} is not a .py file") if !entries.empty? && !rel.end_with?(".py")
      unchecked = (kw[:unchecked] || []).uniq
      sigs = entries.to_h { |e| [e, python_entry(node, rel, source, e, !unchecked.include?("args"))] }
      record = { "name" => name, "path" => rel, "real" => real, "env" => kw[:env], "entries" => entries,
                 "unchecked" => unchecked, "sigs" => sigs, "binary" => binary, **located(node) }
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
      if type == "upload" # a file input: nil when no file was chosen, and nothing about its content is checked here
        bad(node, "an :upload field is part of a `params` group (a browser's multipart form), not of a #{label}") unless label == "params"
        field["optional"] = true
        stray = opts.keys - %i[description optional]
        bad(node, "`#{stray.first}:` does not apply to an :upload field") unless stray.empty?
        return
      end
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
      unless TYPES.key?(s.to_sym) || FIELD_LISTS.include?(s.to_sym) || FIELD_UPLOADS.include?(s.to_sym) || s.match?(CAMEL) || s == "time"
        bad(node, "`:#{s}` is not a field type (#{(TYPES.keys + FIELD_LISTS + FIELD_UPLOADS).map(&:inspect).join(" ")}, map(...), list(...), or the CamelCase name of another params)",
            word: s, from: TYPES.keys + FIELD_LISTS + FIELD_UPLOADS)
      end
      bad(node, "`:#{s}` is a Rust keyword") if RUST_KW.include?(s)
      bad(node, "`:time` is a column type of a `record` or a `table` (a Rails timestamp stored as text); it cannot be the element of a #{inside}") if s == "time" && inside
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
      bad(node, "`Upload` is the type of an :upload field in a body (`avatar.filename`, `avatar.store(...)`); name this params group something else") if pos[0] == "Upload"
      bad(node, "duplicate params `#{pos[0]}`#{first_at(node, srv["params"].find { |x| x["name"] == pos[0] })}") if srv["params"].any? { |x| x["name"] == pos[0] }
      fields = []
      each_child(blk, :params) do |n, p, k, _b|
        bad(n, "duplicate field `#{p[0]}`") if fields.any? { |f| f["name"] == p[0] }
        field = { "name" => p[0], "type" => p[1].to_s }
        bad(n, "`from:` fills a list field of a `record` (docs/database.md); a params field is read from the request") if k.key?(:from)
        bad(n, "`:time` is a column type of a `record` or a `table`; a params field is read from the request, so declare it :string") if field["type"] == "time"
        field["description"] = k[:description] if k[:description]
        field["in"] = k.delete(:in).to_s if k.key?(:in)
        field["wire_name"] = k.delete(:name) if k.key?(:name)
        field_options(n, field, k, srv)
        if field["in"] == "path" && !SCALAR_FIELD_TYPES.include?(field["type"])
          bad(n, "field `#{field['name']}` is `in: :path`, so its type must be a scalar " \
                 "(:string, :i32, :i64, :f64 or :bool), not :#{field['type']}: a path capture is one value")
        end
        if field["type"] == "upload" && field["in"] != "form"
          bad(n, "field `#{field['name']}` is an :upload, which a browser sends in a multipart/form-data body: say `in: :form` " \
                 "(and `name: \"user[avatar]\"` for a Rails form's key)")
        end
        if field["in"] == "form" && field["type"] != "upload" && !LIST_TYPES.include?(field["type"]) && !SCALAR_FIELD_TYPES.include?(field["type"])
          bad(n, "field `#{field['name']}` is `in: :form`, so its type must be a scalar " \
                 "(:string, :i32, :i64, :f64 or :bool), a list of them (:string_list, :i64_list, :f64_list: Rails' `name[]` keys) or an :upload, " \
                 "not :#{field['type']}: a form body is flat, and it cannot build a map or a nested object; send those as a JSON body " \
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
                          request_base_url request_path request_query request_method user_agent request_referrer turbo_frame_request? turbo_stream_request? transaction plain_text action_text_html request_body request_upload image_variant url_encode urlsafe_decode64 qr_code_svg opengraph_unfurl web_push webhook_post later active_storage_disk_path active_storage_verified_id active_storage_verified_key active_storage_direct_upload_url active_storage_disk_upload active_storage_key active_storage_blob_id rate_limited? respond cookie_header inline_disposition].freeze

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
    # law :name, forall: :Params, cases: 256 do |a, b| <bool> end. Laws::Decl (lib/laws, shared with clap_dsl) does
    # the law's own checks; this supplies what is axum_dsl's: params groups as domains, and the body compiler for the
    # boolean body, compiled as a helper's is. The helpers a law calls count as called, and those only laws call are
    # compiled out of the release build (#[cfg(test)] dead-code allowance).
    LAW_CONVERTIBLE = %w[string i32 i64 f64 bool string_list i64_list f64_list].freeze

    def law_decl(node, pos, kw, blk, srv)
      parsed = helper_params(blk, node)
      bad(node, "a law's block takes only plain parameters (the fields of its forall: params group)") unless parsed[:kw].empty?
      resolve = lambda do |name|
        prm = srv["params"].find { |x| x["name"] == name } or
          bad(node, "law `#{pos[0]}` quantifies over `#{name}`, but no params group has that name", word: name, from: srv["params"].map { |x| x["name"] })
        { "name" => name, "fields" => prm["fields"].map { |f| law_domain(node, pos[0], name, f) } }
      end
      compile = lambda do |label, names, domains|
        types = domains.map { |d| HELPER_TYPES.fetch(:"#{d['type']}#{d['optional'] ? '?' : ''}") }
        body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, label, @binding_modules,
                        @helper_table.dup, srv["params"] + srv["records"]).lower_helper(blk, names, types, :bool, [])
        bad(node, "#{label} calls an async helper (#{body['async_reason']}); a law's body runs synchronously") if body["uses_async"]
        body
      end
      law = Laws::Decl.read(node: node, blk: blk, name: pos[0], forall: kw[:forall], cases: kw[:cases], params: parsed[:pos],
                            known: srv["laws"].map { |l| l["name"] }, diag: self, resolve: resolve, compile: compile)
      srv["laws"] << law.merge(located(node))
    end

    # The helpers nothing but a law calls, directly or through other such helpers: the release build has no caller for
    # them. Callers are body labels ("law `x`", "helper `y`", a route's), recorded at each call.
    def law_only_helpers
      callers = @flags["helper_callers"] || {}
      only = {}
      loop do
        grew = false
        callers.each do |name, by|
          next if only[name]

          next unless by.keys.all? { |c| c.start_with?("law `") || ((h = c[/\Ahelper `(\w+)`\z/, 1]) && only[h]) }

          only[name] = true
          grew = true
        end
        break unless grew
      end
      only.keys.sort
    end

    # One params field as a Laws::Domain record. The domain has inclusive bounds only, so an exclusive integer bound
    # becomes the inclusive one beside it; what a domain cannot generate exactly is refused rather than approximated.
    def law_domain(node, law, group, f)
      where = "law `#{law}`: #{group}.#{f['name']}"
      bad(node, "#{where} is :#{f['type']}; a law generates :#{LAW_CONVERTIBLE.join(', :')} fields") unless LAW_CONVERTIBLE.include?(f["type"])
      %w[multiple_of format].each { |k| bad(node, "#{where} has `#{k}:`, which a law cannot generate exactly yet") if f.key?(k) }
      d = f.dup
      if f.key?("exclusive_min") || f.key?("exclusive_max")
        bad(node, "#{where} has an exclusive bound on an :f64; a law needs inclusive bounds there") if f["type"] == "f64"
        d["min"] = f["exclusive_min"] + 1 if f.key?("exclusive_min")
        d["max"] = f["exclusive_max"] - 1 if f.key?("exclusive_max")
      end
      Laws::Domain.of(d)
    end

    # ---- controllers and defs ------------------------------------------------------------------------------------
    # `controller "Accounts::Bots" do ... end`: its routes, params, `before :name, only:/except:` filters and defs.
    # A def is a private method expanded inline where it is called (Body#def_call): its `return` answers the request,
    # as a Rails before_action's head/render halts. Values are explicit: an action calls `bot = set_bot`; a filter only
    # guards. Top-level defs are shared by every route (model and concern methods); a controller's are its own.
    CONTROLLER_NAME = /\A[A-Z][A-Za-z0-9]*(::[A-Z][A-Za-z0-9]*)*\z/

    def add_def(node, ctrl)
      bad(node, "a def takes no receiver (`def self.x` is a class method; write `def x`)") if node.receiver
      ps = node.parameters
      if ps
        extra = [ps.optionals, ps.posts, ps.keywords].any? { |x| !x.empty? } || ps.rest || ps.keyword_rest || ps.block
        bad(ps, "a def takes plain required parameters only") if extra
      end
      name = node.name.to_s
      bad(node, "def `#{name}` must be snake_case") unless name.match?(SNAKE)
      table = ctrl ? ((@controller_defs ||= {})[ctrl] ||= {}) : (@global_defs ||= {})
      clash = table[name] || (ctrl && @global_defs&.[](name))
      bad(node, "duplicate def `#{name}`#{first_at(node, clash)}") if clash
      table[name] = node
    end

    def defs_for(ctrl)
      (@global_defs || {}).merge(ctrl ? (@controller_defs || {})[ctrl] || {} : {})
    end

    def controller_decl(node, pos, blk, srv, route_nodes, declare)
      name = pos[0] || inferred_name(node, :controller)
      bad(node, "a controller is named like a Rails one: \"Accounts::Bots\"") unless name.match?(CONTROLLER_NAME)
      bad(node, "duplicate controller \"#{name}\"#{first_at(node, (@controller_nodes ||= {})[name])}") if @controller_nodes&.key?(name)
      (@controller_nodes ||= {})[name] = node
      filters = ((@controller_filters ||= {})[name] = [])
      actions = {}
      each_child(blk, :controller) do |n, p, k, b|
        if n.is_a?(Prism::DefNode)
          add_def(n, name)
          next
        end
        case n.name
        when :private then nil
        when :params then srv["params"] << params_decl(n, p, b, srv)
        when :helper, :law then declare.call(n, p, k, b) # a typed helper and a law are the file's, as at the top level
        when :view_local then view_local_decl(n, p, b, name)
        when :page_locals then page_locals_decl(n, b, name)
        when :layout_locals then layout_locals_decl(n, b, name)
        when :before
          bad(n, "a controller's filter names one of its defs, `before :#{p[0] || 'name'}`; a do ... end filter is a top-level one") if b || p[0].nil?
          bad(n, "`only:` and `except:` both say which actions; give one") if k[:only] && k[:except]
          filters << { "def" => p[0], "only" => k[:only], "except" => k[:except], "provides" => k[:provides], "node" => n }
        else # a route
          if (a = k[:action])
            bad(n, "duplicate action `#{a}` in #{name}#{first_at(n, actions[a])}") if actions[a]
            actions[a] = n
          end
          (@route_controller ||= {})[n.object_id] = name
          route_nodes << [n, p, k, b, nil]
        end
      end
      filters.each do |f|
        defs = defs_for(name)
        bad(f["node"], "`before :#{f['def']}` names no def of #{name} or the top level", word: f["def"], from: defs.keys) unless defs.key?(f["def"])
        (f["only"].to_a + f["except"].to_a).each do |a|
          next if actions.key?(a.to_s) || defs.key?(a.to_s)

          bad(f["node"], "#{name} has no action `#{a}` (its actions: #{actions.keys.join(', ')}; defs: #{defs.keys.join(', ')})",
              word: a.to_s, from: actions.keys.map(&:to_s) + defs.keys)
        end
      end
    end

    # model "Room" do ... end, or `model do` in models/room.axum.rb: the records, statements and model methods of one
    # model. Its declarations are the file's, as a fragment's are (a def is shared by every route, a query is called
    # by name); the block only says what kind of file this is, so a route, a filter or a controller written in it is
    # refused by the signature table (`in:`), which lists what a model may hold.
    #
    # `has_many`, `has_one`, `belongs_to` and `scope` are the model's own: they are kept in @models, and check_models
    # resolves them against the tables and the other models once the whole file is read (nothing emits Rust from them).
    # `table:` names the declared table the model owns; it is required once the model declares one of those.
    MODEL_CALLS = %i[has_many has_one has_one_attached belongs_to scope include].freeze

    def model_decl(node, pos, kw, blk, declare)
      name = pos[0] || inferred_name(node, :model)
      bad(node, "a model is named like a Rails one: \"Room\" or \"Account::Bot\"") unless name.match?(CONTROLLER_NAME)
      bad(node, "duplicate model \"#{name}\"#{first_at(node, (@model_nodes ||= {})[name])}") if @model_nodes&.key?(name)
      (@model_nodes ||= {})[name] = node
      model = { "name" => name, "table" => kw[:table], "associations" => [], "scopes" => [], **located(node) }
      (@models ||= {})[name] = model
      @declaring_model = name # a query or execute inside is a relation of this model
      each_child(blk, :model) do |n, p, k, b|
        if n.is_a?(Prism::CallNode) && MODEL_CALLS.include?(n.name)
          case n.name
          when :scope then add_model_scope(n, model, p)
          when :has_one_attached then add_attached(n, model, p)
          when :include then add_include(n, model, p)
          else add_association(n, model, p, k)
          end
        else
          declare.call(n, p, k, b)
        end
      end
      @declaring_model = nil
      return unless model["table"].nil? && !(model["associations"].empty? && model["scopes"].empty?)

      bad(node, "model \"#{name}\" declares associations or scopes, so it names its table: `model :#{name}, table: :a_declared_table`")
    end

    # `include :Timestamps` inside a model: the exprs of that concern are the model's. Whether the concern exists, whether the model's
    # table has the columns the exprs read and whether two included concerns clash are checked once the file is read (check_includes).
    def add_include(node, model, pos)
      name = pos[0].to_s
      list = (model["includes"] ||= [])
      bad(node, "model \"#{model["name"]}\" includes concern \"#{name}\" twice#{first_at(node, (@include_nodes ||= {})[[model["name"], name]])}") if list.include?(name)
      list << name
      (@include_nodes ||= {})[[model["name"], name]] = node
    end

    # concern :Timestamps do expr ... end, or the one call of models/concerns/timestamps.axum.rb: the exprs several models share
    # (docs/database.md, "Models"). It holds nothing but `expr`s; a model brings them in with `include :Timestamps`, and a relation
    # of that model finds them by name.
    def concern_decl(node, pos, blk, srv)
      name = pos[0].to_s
      bad(node, "a concern is named like a Rails one: \"Timestamps\"") unless name.match?(CONTROLLER_NAME)
      bad(node, "duplicate concern \"#{name}\"#{first_at(node, (@concern_nodes ||= {})[name])}") if @concern_nodes&.key?(name)
      (@concern_nodes ||= {})[name] = node
      @declaring_concern = name
      each_child(blk, :concern) { |n, p, k, _b| add_expr(n, p, k, srv) }
      @declaring_concern = nil
    end

    # has_many / has_one / belongs_to inside a model: the keywords are checked against each other here, the names
    # they point at once the file is read (check_models).
    def add_association(node, model, pos, kw)
      name = pos[0]
      kind = node.name.to_s
      who = "model \"#{model['name']}\" #{kind} :#{name}"
      bad(node, "#{who} is declared twice") if model["associations"].any? { |a| a["name"] == name }
      bad(node, "#{who}: `#{name}` is already a scope of the model") if model["scopes"].any? { |s| s["name"] == name }
      if kind == "belongs_to"
        %i[dependent through as].each { |key| bad(node, "#{who}: `#{key}:` applies to has_many and has_one, not belongs_to") if kw.key?(key) }
      end
      if kw[:through]
        other = %i[table model foreign_key as dependent].find { |key| kw.key?(key) }
        bad(node, "#{who}: `through:` takes its table and keys from the associations it goes through, so `#{other}:` does not apply") if other
      end
      bad(node, "#{who}: `as:` already names the foreign key (`#{kw[:as]}_id`), so leave `foreign_key:` out") if kw[:as] && kw[:foreign_key]
      conditions = nil
      if pos[1]
        bad(node, "#{who}: `through:` takes its table and keys from the associations it goes through, so a condition lambda does not apply") if kw[:through]
        bad(node, "#{who}: a condition lambda and `dependent:` can not be combined (it is not said whether destroy deletes every row or only those the condition names); leave one out") if kw[:dependent]
        conditions = association_conditions(pos[1], who)
      end
      model["associations"] << { "name" => name, "kind" => kind, "through" => kw[:through], "dependent" => kw[:dependent]&.to_s,
                                 "table" => kw[:table], "model" => kw[:model], "foreign_key" => kw[:foreign_key], "as" => kw[:as], "conditions" => conditions, **located(node) }
      (@model_member_nodes ||= {})[[model["name"], name]] = node
    end

    # `has_one_attached :avatar` inside a model (docs/database.md, "Attachments"): the two associations it derives are declared
    # here as if written, each carrying where it came from ("derived"); the Active Storage models are found, and the statements
    # `attach` runs made, once the whole file is read (resolve_attached, check_attached).
    def add_attached(node, model, pos)
      name = pos[0]
      who = "model \"#{model['name']}\" has_one_attached :#{name}"
      attached = (model["attached"] ||= [])
      bad(node, "#{who} is declared twice") if attached.any? { |a| a["name"] == name }
      derived = { "from" => "has_one_attached :#{name}", "at" => "#{AxumDsl.file_of(node) || @path}:#{node.location.start_line}" }
      ["#{name}_attachment", "#{name}_blob"].each do |assoc|
        bad(node, "#{who} derives the association `#{assoc}`, which the model already declares") if model["associations"].any? { |a| a["name"] == assoc }
        bad(node, "#{who} derives the association `#{assoc}`, which is already a scope of the model") if model["scopes"].any? { |s| s["name"] == assoc }
      end
      attached << { "name" => name, **derived }
      model["associations"] << { "name" => "#{name}_attachment", "kind" => "has_one", "through" => nil, "dependent" => nil, "table" => nil, "model" => nil,
                                 "foreign_key" => nil, "as" => "record", "conditions" => { "name" => name }, "derived" => derived, **located(node) }
      model["associations"] << { "name" => "#{name}_blob", "kind" => "has_one", "through" => "#{name}_attachment", "source" => "blob", "dependent" => nil,
                                 "table" => nil, "model" => nil, "foreign_key" => nil, "as" => nil, "conditions" => nil, "derived" => derived, **located(node) }
      @model_member_nodes ||= {}
      @model_member_nodes[[model["name"], "#{name}_attachment"]] = node
      @model_member_nodes[[model["name"], "#{name}_blob"]] = node
      (@attached_nodes ||= {})[[model["name"], name]] = node
      graph_attached_associations(model["name"], name, derived)
    end
    # The lambda of `has_one :body_text, -> { where(name: "body") }, ...`: one `where` of `column: literal` pairs on the target
    # table, as { column => String | Integer | true | false } in the order written.
    def association_conditions(lam, who)
      bad(lam, "#{who}: the condition lambda takes no parameters, `-> { where(name: \"body\") }`") if lam.parameters
      call = lam.body
      call = call.body.first if call.is_a?(Prism::StatementsNode) && call.body.size == 1
      unless call.is_a?(Prism::CallNode) && call.receiver.nil? && call.name == :where && call.block.nil?
        bad(lam, "#{who}: the condition lambda holds one `where(column: literal, ...)` on the target table and nothing else, `-> { where(name: \"body\") }`")
      end
      list = call.arguments&.arguments || []
      unless list.size == 1 && list[0].is_a?(Prism::KeywordHashNode)
        bad(call, "#{who}: the condition lambda's `where` takes `column: literal` pairs, `-> { where(name: \"body\") }`")
      end
      out = {}
      list[0].elements.each do |el|
        bad(el, "#{who}: write `column: literal` pairs in the condition lambda (no splat, no string keys, no shorthand)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && !el.value.is_a?(Prism::ImplicitNode)
        column = el.key.unescaped
        bad(el, "#{who}: the condition lambda gives `#{column}` twice") if out.key?(column)
        out[column] = case el.value
                      when Prism::StringNode then el.value.unescaped
                      when Prism::IntegerNode then el.value.value
                      when Prism::TrueNode then true
                      when Prism::FalseNode then false
                      else bad(el.value, "#{who}: a condition's value is a string, integer, true or false literal, got #{nodename(el.value)}")
                      end
      end
      out
    end

    # scope :name, ->(a, b) { ... } inside a model: the lambda is kept unevaluated (its parameter names and its body
    # node) for the queries that will call it.
    def add_model_scope(node, model, pos)
      name, lam = pos
      who = "model \"#{model['name']}\" scope :#{name}"
      bad(node, "#{who} is declared twice") if model["scopes"].any? { |s| s["name"] == name }
      bad(node, "#{who}: `#{name}` is already an association of the model") if model["associations"].any? { |a| a["name"] == name }
      if Db::Models::OPERATIONS.include?(name)
        bad(node, "#{who}: `#{name}` is a relation operation (#{Db::Models::OPERATIONS.join(', ')}), which a scope would hide; name it differently")
      end
      bad(lam, "#{who} has an empty lambda; write the relation it stands for, `-> { where(...) }`") if lam.body.nil?
      model["scopes"] << { "name" => name, "params" => scope_params(lam, who), "body" => lam.body, **located(node) }
    end

    # The parameter names of a scope's lambda: plain required names.
    def scope_params(lam, who)
      ps = lam.parameters
      return [] if ps.nil?

      bad(ps, "#{who}: a scope lambda names its parameters, `->(a, b) { ... }`, not `_1` or `it`") unless ps.is_a?(Prism::BlockParametersNode)
      bad(ps, "#{who}: a scope lambda has no block-local variables") unless ps.locals.empty?
      pn = ps.parameters
      return [] if pn.nil?

      extra = [pn.optionals, pn.posts, pn.keywords].any? { |x| !x.empty? } || pn.rest || pn.keyword_rest || pn.block
      bad(pn, "#{who}: the parameters of a scope lambda are plain required names, `->(a, b) { ... }`") if extra
      seen = []
      pn.requireds.map do |r|
        bad(r, "#{who}: unsupported #{nodename(r)} as a scope parameter") unless r.is_a?(Prism::RequiredParameterNode)
        bad(r, "#{who}: parameter `#{r.name}` must be snake_case and not a Rust keyword") if !r.name.to_s.match?(SNAKE) || RUST_KW.include?(r.name.to_s)
        bad(r, "#{who}: duplicate parameter `#{r.name}`") if seen.include?(r.name.to_s)
        seen << r.name.to_s
        r.name.to_s
      end
    end

    # expr :name, type: :string, sql: "..." (of: :t when the template writes its table as `{t}`): a named SQL
    # expression for the relations to come. It emits nothing, and an unused one is not refused. Written in a `model` it is that
    # model's (`{t}` is its table, `of:` implied), in a `concern` it is shared, at the top level it is everyone's.
    def add_expr(node, pos, kw, srv)
      name = pos[0]
      owner = @declaring_concern ? { "concern" => @declaring_concern } : @declaring_model ? { "model" => @declaring_model } : {}
      # A model's expr is its own, so the same name on two models is two exprs, and so is the same name in two concerns (a model that
      # includes both is refused); a concern's name may not be a top-level one, and a top-level name is taken once.
      earlier = srv["exprs"].find do |e|
        next false unless e["name"] == name

        if owner.key?("model") then e["model"] == owner["model"]
        elsif owner.key?("concern") then e["concern"] == owner["concern"] || !(e["model"] || e["concern"])
        else !e["model"]
        end
      end
      bad(node, "duplicate expr `#{name}`#{first_at(node, earlier)}") if earlier
      sql = kw[:sql]
      holes = sql.scan(/\{([A-Za-z_][A-Za-z0-9_]*)\}/).flatten
      of = kw[:of] || (!owner.empty? && holes.include?("t") ? "t" : nil) # in a model or a concern `{t}` is that table: `of: :t` is implied
      if of
        bad(node, "expr `#{name}` says `of: :#{of}`, so its sql writes that table as `{#{of}}` at least once") unless holes.include?(of)
        other = holes.find { |h| h != of }
        bad(node, "expr `#{name}` takes one table reference, `{#{of}}`, and its sql also writes `{#{other}}`") if other
      elsif holes.any?
        bad(node, "expr `#{name}` writes `{#{holes.first}}` but has no `of:`; add `of: :#{holes.first}` to name the table it applies to")
      end
      args = kw[:args] || {}
      named = []
      Db::Sql.placeholders(sql).each do |ph|
        text = sql[ph.offset, 1 + ph.name.to_s.size]
        if ph.kind != :named || args.empty?
          bad(node, "expr `#{name}` has the placeholder `#{text}` in its sql; an expression is a fixed piece of SQL, so the value is bound where the relation uses it")
        end
        bad(node, "expr `#{name}` writes `:#{ph.name}` but `args:` does not declare it (declared: #{args.keys.join(', ')})") unless args.key?(ph.name)
        named << ph.name
      end
      unused = args.keys - named
      bad(node, "expr `#{name}` declares `args: { #{unused.first}: ... }` but its sql never writes `:#{unused.first}`") unless unused.empty?
      rec = { "name" => name, "type" => kw[:type].to_s, "sql" => sql, "of" => of, **owner, **(args.empty? ? {} : { "args" => args }), **located(node) }
      srv["exprs"] << rec
      (@expr_nodes ||= {}.compare_by_identity)[rec] = node
      @graph&.declare("expr:#{[owner.values.first, name].compact.join('.')}", at: node, type: kw[:type].to_s)
    end

    # A model's expr may not hide a top-level one or one of a concern it includes, and a concern is not named like a model: the two
    # would share the owner part of an `expr:Owner.name` node of the type graph.
    def check_expr_owners(srv, models)
      (@concern_nodes || {}).each do |name, node|
        bad(node, "concern \"#{name}\" is also the name of a model; name one of them differently") if models.key?(name)
      end
      srv["exprs"].each do |e|
        next unless e["model"]

        includes = models.fetch(e["model"])["includes"] || []
        hidden = srv["exprs"].find { |s| s["name"] == e["name"] && !s["model"] && (!s["concern"] || includes.include?(s["concern"])) } or next
        node = @expr_nodes.fetch(e)
        owner = hidden["concern"] ? "concern #{hidden["concern"]}" : "the top level"
        bad(node, "expr `#{e["name"]}` of model #{e["model"]} has the name of an expr of #{owner}#{first_at(node, hidden)}, which it would hide; name it differently")
      end
    end

    # Each `include :Concern` of a model: the concern is declared, the model's table has every column its exprs read from `{t}` (the
    # refusal is on the include line and names the concern, the expr, the table and the column), and no two included concerns have an
    # expr of one name. An included expr is a node of the type graph of the model, `expr:User.updated_ms`, taken from the concern's.
    def check_includes(models, registry)
      models.each_value do |m|
        seen = {}
        (m["includes"] || []).each do |concern|
          node = @include_nodes.fetch([m["name"], concern])
          unless registry.concern?(concern)
            names = registry.concern_names
            bad(node, "model \"#{m["name"]}\" includes concern \"#{concern}\", which is not declared (#{names.empty? ? "none is declared" : "declared: #{names.join(", ")}"})", word: concern, from: names)
          end
          have = (m["table"] ? registry.schema.columns(m["table"]) : nil).to_a.map { |c| c[:name] }
          registry.concern_exprs(concern).each do |name, found|
            missing = registry.expr_columns(found).find { |c| !have.include?(c) }
            if missing
              why = m["table"] ? "table `#{m["table"]}` has no column `#{missing}`" : "the model names no table"
              bad(node, "model \"#{m["name"]}\" includes concern \"#{concern}\", but its expr `#{name}` reads `{t}.#{missing}` and #{why}")
            end
            if (other = seen[name])
              bad(node, "model \"#{m["name"]}\" includes concerns \"#{other}\" and \"#{concern}\", which both have an expr `#{name}`; include one of them")
            end
            seen[name] = concern
            @graph&.derive("expr:#{m["name"]}.#{name}", from: ["expr:#{concern}.#{name}"], rule: "include", at: node, type: found[:type])
          end
        end
      end
    end

    # The models read, resolved once every table and model is known: a model's table is a declared one, each
    # association finds its target and its columns, and the dependent: tree has no cycle. Db::Models does the
    # resolving and says what is wrong; this puts the message on the declaration.
    def check_models(srv)
      models = @models || {}
      srv["models"] = models.values
      tables = srv["tables"].map { |t| t["name"] }
      models.each_value do |m|
        next if m["table"].nil? || tables.include?(m["table"])

        list = tables.empty? ? "none is declared" : "declared: #{tables.join(', ')}"
        bad(@model_nodes.fetch(m["name"]), "model \"#{m['name']}\": table `#{m['table']}` is not declared (#{list})", word: m["table"], from: tables)
      end
      resolve_attached(models)
      check_expr_owners(srv, models)
      registry = Db::Models.from_ir(srv["models"], srv["exprs"], Db::Schema.from_ir(srv["tables"]))
      check_includes(models, registry)
      models.each_value do |m|
        m["associations"].each do |a|
          registry.association(m["name"], a["name"])
        rescue Db::Models::Unresolved => e
          bad(@model_member_nodes.fetch([m["name"], a["name"]]), e.message, word: e.word, from: e.from)
        end
      end
      models.each_value do |m|
        registry.destroy_plan(m["name"])
      rescue Db::Models::Unresolved => e
        bad(@model_nodes.fetch(m["name"]), e.message)
      end
    end

    # The defs a controller's filters run first in a route with this action, in declaration order.
    def controller_filters_for(ctrl, action)
      @controller_filters.fetch(ctrl).filter_map do |f|
        runs = if f["only"] then f["only"].map(&:to_s).include?(action.to_s)
               elsif f["except"] then !f["except"].map(&:to_s).include?(action.to_s)
               else true
               end
        [f["def"], f["node"], f["provides"]] if runs
      end
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
    def route_decl(node, pos, kw, blk, srv, verb: nil)
      verb = verb || node.name.to_s
      path = pos[0]
      axum_path, names = route_path(node, path)
      refuse_route_mount_clash(node, axum_path, srv)
      prm_name = kw[:params]
      prm = nil
      if prm_name
        prm = srv["params"].find { |x| x["name"] == prm_name } or
          undeclared(node, "route `#{verb} #{path}` refers to undeclared params `#{prm_name}`", prm_name, srv["params"].map { |x| x["name"] })
      end
      if (resource = kw[:resource])
        if (model_name = kw[:resource_model]) && (@models || {}).values.none? { |m| m["name"] == model_name }
          known = (@models || {}).values.map { |m| m["name"] }
          bad(node, "`resources :#{resource}` names model `#{model_name}`, which is not declared#{known.empty? ? "" : " (declared: #{known.join(", ")})"}", word: model_name, from: known)
        end
        derived = resource_id_source(resource, srv, kw[:resource_model])
        if derived
          prm, prm_name = apply_derived_path(node, { "id" => derived }, prm, prm_name, srv)
          graph_path_param("#{verb.upcase} #{path}", { "name" => "id", "type" => derived["type"], "derived" => derived.except("type") }, node)
        elsif prm.nil?
          bad(node, "`resources :#{resource}` generates `#{verb} #{path}`, whose path captures `:id`; no model with `table: :#{resource}` declares that table's `id` column, so add `params: :Group` naming a group with `field :id, :i64, in: :path`")
        end
      end
      default_in = %w[post put patch].include?(verb) ? "body" : "query"
      field_in = (prm ? prm["fields"] : []).to_h { |f| [f["name"], f["in"] || default_in] }
      if field_in.value?("form") && field_in.value?("body")
        bad(node, "route `#{verb} #{path}` reads params `#{prm_name}` from both a JSON body and a form; axum lets only one extractor consume the request body, so the group's fields must be all `in: :body` or all `in: :form`")
      end
      # A DELETE carries a form too: Rails' `button_to ..., method: :delete` posts its fields with `_method=delete`.
      if field_in.value?("form") && !%w[post put patch delete].include?(verb)
        bad(node, "route `#{verb} #{path}` reads params `#{prm_name}` from a form, but a browser sends a form body only on POST (or PUT/PATCH, or a DELETE through `_method`); on `#{verb}` the fields belong in the query string — use `in: :query`, or make the route a `post`")
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
      cache = kw[:cache]
      ctrl = @route_controller&.[](node.object_id)
      if (named = kw[:controller])
        bad(node, "`controller:` is for a route outside a controller; this route is already in `#{ctrl}`") if ctrl
        known = (@controller_nodes || {}).keys
        bad(node, "no controller `#{named}` is declared#{known.empty? ? '' : " (declared: #{known.join(', ')})"}", word: named, from: known) unless known.include?(named)
        ctrl = named
      end
      bad(node, "`action:` names a route in a controller; this route is in none") if kw[:action] && ctrl.nil?

      def_node = nil
      if blk.nil?
        bad(node, "a route needs a do ... end block, or `action:` naming one of its controller's defs") unless kw[:action]
        def_node = (@controller_defs || {}).dig(ctrl, kw[:action].to_s) if ctrl
        unless def_node
          known = ((@controller_defs || {})[ctrl] || {}).keys
          bad(node, "#{ctrl} has no def `#{kw[:action]}` for this route#{known.empty? ? '' : " (its defs: #{known.join(', ')})"}",
              word: kw[:action].to_s, from: known)
        end
      end
      check_route_cache(node, verb, path, def_node ? def_node.body : blk, srv) if cache
      body = Body.new(@path, prm || { "fields" => [] }, @regexes, srv["externs"], @flags, "route `#{verb} #{path}`",
                      @binding_modules, @helper_table, srv["params"] + srv["records"], kind: :route, skip: skips)
      body.defs = defs_for(ctrl)
      body.controller = ctrl
      body.preludes = ctrl ? controller_filters_for(ctrl, kw[:action]) : []
      body.controller_provides = ctrl ? @controller_filters.fetch(ctrl).select { |f| f["provides"] }.to_h { |f| [f["provides"].to_s, f["def"]] } : {}
      body.action = kw[:action]
      provided = {}
      body.preludes.each do |fname, fnode, provides|
        next unless provides
        bad(fnode, "`before :#{fname}` provides `#{provides}`, but another filter on this action already provides it") if provided[provides]
        provided[provides] = true
      end
      body = def_node ? body.lower_action_def(def_node) : body.lower(blk)
      if body["content_type"]
        bad(node, "`content_type(...)` is only meaningful in a `before` filter; it sets the default for the routes that follow")
      end
      if body["request"].to_a.include?("body") && (body_field = field_in.find { |_, loc| %w[body form].include?(loc) })
        bad(node, "route `#{verb} #{path}` reads the raw request body with `request_body` and also reads params `#{prm_name}` field `#{body_field[0]}` from the #{body_field[1] == "form" ? "form" : "JSON"} body; " \
                  "axum lets only one extractor consume the request body, so the group's fields must be `in: :path` or `in: :query`")
      end
      # A body that read errors[:field] needs a params group whose check() can report something; that test
      # needs every params group, so it runs once the whole file is read (check_errors_routes).
      (@errors_routes ||= []) << [node, prm_name] if body["errors"]
      decl = { "method" => verb, "path" => axum_path, "names" => names, "params" => prm_name,
               "description" => kw[:description], "body" => body, **located(node) }
      decl["field_in"] = field_in unless field_in.empty?
      decl["skip"] = skips unless skips.empty?
      decl["cache"] = cache.to_s if cache
      also = (kw[:also] || []).map(&:to_s)
      unless also.empty?
        # Rails' `resources` routes `update` on both PATCH and PUT; `also: [:put]` answers the second verb with this body.
        bad(node, "route `#{verb} #{path}` has `also:`, which is for an update route (`patch` or `put`) answering the other verb as Rails' resources do") unless %w[patch put].include?(verb)
        also.each do |m|
          bad(node, "route `#{verb} #{path}` `also:` takes :put or :patch, got :#{m}") unless %w[patch put].include?(m)
          bad(node, "route `#{verb} #{path}` lists its own verb in `also:`") if m == verb
          clash = srv["routes"].find { |r| r["path"] == axum_path && (r["method"] == m || r["also"].to_a.include?(m)) }
          bad(node, "route `#{verb} #{path}` `also: [:#{m}]` clashes with `#{m} #{path}` (line #{clash['line']})") if clash
        end
        decl["also"] = also
      end
      if (twin = srv["routes"].find { |r| r["path"] == axum_path && r["also"].to_a.include?(verb) })
        bad(node, "route `#{verb} #{path}` is already answered by `#{twin['method']} #{path}`'s `also: [:#{verb}]`")
      end
      decl
    end

    RESOURCE_ACTIONS = %w[index new create show edit update destroy].freeze
    RESOURCE_MEMBER = %w[show edit update destroy].freeze

    # `resources :rooms, only: %i[show edit], params: :RoomPath, controller: "Rooms"`: Rails' resource table,
    # lowered to the routes an explicit `get`/`patch` would declare. The controller's action defs (RB2) and
    # their `before` filters apply as they do to any `action:` route. A member route captures `:id`, so it
    # needs `params:` naming a group with an `id` field `in: :path`. Nested resources are not implemented yet,
    # and `create`/`update` take no form group of their own: write those routes explicitly until the strong
    # params envelope lands (Track RB4). The resource also declares Rails' path helpers (rooms_path, room_path,
    # new_room_path, edit_room_path and their _url forms) for the bodies to call.
    def resources_decl(node, pos, kw, blk, srv, route_nodes)
      name = pos[0]
      bad(node, "nested `resources` is not implemented yet; write the nested routes explicitly") if blk
      only = kw[:only]
      except = kw[:except]
      bad(node, "`resources :#{name}` takes `only:` or `except:`, not both") if only && except
      named = only || except
      unknown = named.to_a - RESOURCE_ACTIONS
      unless unknown.empty?
        bad(node, "`resources :#{name}` `#{only ? 'only' : 'except'}:` names #{unknown.map { |a| "`:#{a}`" }.join(', ')}, which #{unknown.size == 1 ? 'is' : 'are'} not one of the seven: #{RESOURCE_ACTIONS.join(', ')}",
            word: unknown.first, from: RESOURCE_ACTIONS)
      end
      chosen = (only || (except ? RESOURCE_ACTIONS - except : RESOURCE_ACTIONS)).uniq
      bad(node, "`resources :#{name}` has `except:` naming every action, so it routes nothing") if chosen.empty?
      controller = kw[:controller] || camelize(name)
      known = (@controller_nodes || {}).keys
      unless known.include?(controller)
        bad(node, "`resources :#{name}` names no controller `#{controller}`#{known.empty? ? '' : " (declared: #{known.join(', ')})"}; write `controller:` when the resource's name differs from its controller",
            word: controller, from: known)
      end
      params = kw[:params]
      descriptions = kw[:description]
      { "params" => params, "description" => descriptions }.each do |what, given|
        stray = given.is_a?(Hash) ? given.keys - chosen : []
        bad(node, "`resources :#{name}` `#{what}:` names #{stray.map { |a| "`#{a}`" }.join(", ")}, which the resource does not route (it routes #{chosen.join(", ")})") unless stray.empty?
      end
      base = prefixed("/#{name}")
      chosen.each do |action|
        verb, path, also = resource_route(base, action)
        route_kw = { controller: controller, action: action.to_sym }
        # one group for every member action, or the hash's group for the action it names (create and update take their form group so)
        group = params.is_a?(Hash) ? params[action] : (params if RESOURCE_MEMBER.include?(action))
        route_kw[:params] = group if group
        if RESOURCE_MEMBER.include?(action) # route_decl derives its :id once every model and table is read
          route_kw[:resource] = name
          route_kw[:resource_model] = kw[:model] if kw[:model]
        end
        route_kw[:cache] = kw[:cache] if kw[:cache]
        text = descriptions.is_a?(Hash) ? descriptions[action] : descriptions
        route_kw[:description] = text if text
        route_kw[:also] = also if also
        route_nodes << [node, [path], route_kw, nil, verb]
      end
      register_resource_paths(node, name, base, chosen)
    end

    # What `resources :rooms` knows about its `:id` (Track RR6): the model declared with `table: :rooms`, that table, and
    # the type of the table's `id` column (the primary key). Nothing is read from the URL or guessed from a plural: the
    # resource name is the table name, as `model :Room, table: :rooms` says. Nil when no model owns that table or its
    # `id` is not a scalar a path can carry, and the resource then needs a `params:` group as before. The hash is the
    # provenance, kept as data for the notice, the hover and a later derivation graph.
    def resource_id_source(name, srv, model_name = nil)
      model = (@models || {}).values.find { |m| model_name ? m["name"] == model_name : m["table"].to_s == name.to_s }
      table = model && srv["tables"].find { |t| t["name"].to_s == model["table"].to_s }
      column = table && table["columns"].find { |c| c["name"] == "id" }
      return nil unless column && SCALAR_FIELD_TYPES.include?(column["type"])

      { "type" => column["type"], "from" => "#{table['name']}.id", "via" => "resources :#{name}", "resource" => name.to_s,
        "model" => model["name"], "at" => "#{table['file'] || @path}:#{table['line']}" }
    end

    # Applies what a resource derives for its captures to the route: a declared `in: :path` field of another type is
    # refused naming both sources; one that repeats the type gets the notice N-PATH-PARAM-DERIVED; a capture the group
    # does not declare is added to it, or to a group of the resource's own when the route names none.
    def apply_derived_path(node, derived, prm, prm_name, srv)
      fields = prm ? prm["fields"] : []
      derived.each do |cap, d|
        f = fields.find { |x| x["name"] == cap && x["in"] == "path" && !x["derived"] } or next
        sources = "`#{d['via']}` derives `:#{cap}` as :#{d['type']} (#{d['from']}, model #{d['model']}, table at #{d['at']})"
        if f["type"] != d["type"]
          bad(node, "field `#{cap}` of params `#{prm_name}` is declared :#{f['type']}, but #{sources}; the declaration contradicts the derivation, so delete the line (or fix the table)")
        end
        Notify.add(@path, node, "N-PATH-PARAM-DERIVED", "field `#{cap}` of params `#{prm_name}` repeats what #{sources}; the line can go unless another route that uses the group needs it")
      end
      missing = derived.reject { |cap, _| fields.any? { |x| x["name"] == cap } }
      return [prm, prm_name] if missing.empty?

      added = missing.map { |cap, d| { "name" => cap, "type" => d["type"], "in" => "path", "derived" => d.except("type") } }
      if prm
        prm["fields"].unshift(*added)
      else
        name = "#{camelize(missing.first[1]['resource'])}MemberPath"
        prm = srv["params"].find { |x| x["name"] == name && x["synthesized"] }
        unless prm
          bad(node, "`resources :#{missing.first[1]['resource']}` needs the params name `#{name}`, which is declared") if srv["params"].any? { |x| x["name"] == name }
          prm = { "name" => name, "fields" => added, "synthesized" => true, **located(node) }
          srv["params"] << prm
        end
        prm_name = name
      end
      if @types
        at = (node.respond_to?(:arguments) && node.arguments&.arguments&.first) || node
        added.each do |f|
          @types.add(at.location, "path param", TypeNames.display(TypeNames.field_symbol(f)), name: f["name"], detail: "#{f['derived']['from']} via #{f['derived']['via']}")
        end
      end
      [prm, prm_name]
    end

    # The verb, path and second update verb (`also:`) of one Rails resource action.

    def resource_route(base, action)
      case action
      when "index" then ["get", base, nil]
      when "new" then ["get", "#{base}/new", nil]
      when "create" then ["post", base, nil]
      when "show" then ["get", "#{base}/:id", nil]
      when "edit" then ["get", "#{base}/:id/edit", nil]
      when "update" then ["patch", "#{base}/:id", ["put"]]
      when "destroy" then ["delete", "#{base}/:id", nil]
      end
    end

    # The path helpers a resource declares, for a body to call: `room_path(id)` compiles to the same
    # `format!` a hand-written interpolation would, and `room_url(id)` puts request_base_url in front.
    def register_resource_paths(node, name, base, chosen)
      helpers = (@flags["path_helpers"] ||= {})
      singular = name.sub(/s\z/, "")
      add = lambda do |hname, path, url|
        bad(node, "resource `#{name}` needs the path helper `#{hname}`, which another resource already declares") if helpers.key?(hname)
        helpers[hname] = { "path" => path, "captures" => path.scan(/:([A-Za-z_][A-Za-z0-9_]*)/).flatten, "url" => url }
      end
      if (chosen & %w[index create]).any?
        add.call("#{name}_path", base, false)
        add.call("#{name}_url", base, true)
      end
      if chosen.include?("new")
        add.call("new_#{singular}_path", "#{base}/new", false)
        add.call("new_#{singular}_url", "#{base}/new", true)
      end
      if (chosen & RESOURCE_MEMBER).any?
        add.call("#{singular}_path", "#{base}/:id", false)
        add.call("#{singular}_url", "#{base}/:id", true)
      end
      return unless chosen.include?("edit")

      add.call("edit_#{singular}_path", "#{base}/:id/edit", false)
      add.call("edit_#{singular}_url", "#{base}/:id/edit", true)
    end

    # `scope path: "rooms/opens" do ... end`: a path prefix for the routes in the block, as Rails' `scope`.
    def scope_decl(node, kw, blk, declare)
      path = kw[:path]
      bad(node, "`scope path:` is a path such as \"rooms/opens\"") if path.nil? || path.empty?
      if path.include?("?") || path.match?(/[()]/)
        bad(node, "`scope path:` #{path.inspect} uses an optional segment or a group, which axum's router cannot express; a scope path is literal text and `:name` captures")
      end
      outer = @route_prefix
      @route_prefix = join_prefix(outer, path)
      begin
        each_child(blk, :top) { |n, p, k, b| declare.call(n, p, k, b) }
      ensure
        @route_prefix = outer
      end
    end

    # A route path under the innermost scope. Only explicit routes and a resource's base path use it: a route
    # inside a controller is not scoped.
    def prefixed(path)
      return path if @route_prefix.nil? || @route_prefix.empty?

      "/#{@route_prefix}/#{path.to_s.sub(%r{\A/}, '')}"
    end

    def prefixed_pos(pos) = [prefixed(pos[0])] + pos[1..]

    def join_prefix(outer, path)
      inner = path.to_s.sub(%r{\A/}, "").sub(%r{/\z}, "")
      outer.nil? || outer.empty? ? inner : "#{outer.sub(%r{/\z}, '')}/#{inner}"
    end

    # The controller Rails names for `resources :account_bots`: AccountBots.
    def camelize(name) = name.split("_").map { |part| part[0].upcase + part[1..] }.join

    # The calls whose answer a database commit does not explain: a cached copy would repeat a random token, a
    # file read from disk, the caller's address (it is not in the cache key) or the result of Rust or a
    # subprocess the compiler cannot see into.
    UNCACHEABLE_CALLS = %i[random_token send_file file_text request_ip request_body rust active_storage_key active_storage_disk_upload active_storage_direct_upload_url rate_limited?].freeze

    # `get "/x", cache: :private do ... end` (AP1, the reference is once-campfire-rust/crates/campfire/src/response_cache.rs):
    # the whole response is kept until the next commit, so the route must be a read of the database, and the crate
    # must have one to watch.
    def check_route_cache(node, verb, path, blk, srv)
      bad(node, "route `#{verb} #{path}` has `cache: :private`, but only a `get` route can be cached; a `#{verb}` changes something, and a cached answer would skip it") unless verb == "get"
      bad(node, "route `get #{path}` has `cache: :private`, which watches the database for commits; declare `database :sqlite, path: \"...\"` or drop `cache:`") unless srv["database"]
      call, name = uncacheable_call(blk, srv, [])
      return unless call

      bad(call, "route `get #{path}` has `cache: :private`, but its body calls `#{name}`, whose result a database commit does not explain, so a cached copy would repeat it; drop `cache:` or the call")
    end

    # The first call in a node that a cache must not repeat, as [call node, how it is named]; a helper it calls is searched too.
    def uncacheable_call(node, srv, seen)
      if node.is_a?(Prism::CallNode) && node.receiver.nil?
        name = node.name.to_s
        return [node, name] if UNCACHEABLE_CALLS.include?(node.name) || srv["subprocs"].any? { |s| s["name"].to_s == name } || srv["externs"].key?(name)

        helper = @helper_blocks[name]
        if helper && !seen.include?(name)
          seen << name
          inner = uncacheable_call(helper, srv, seen)
          return [node, "#{name}` (its helper calls `#{inner[1]}"] if inner
        end
      end
      node.compact_child_nodes.each do |child|
        found = uncacheable_call(child, srv, seen)
        return found if found
      end
      nil
    end

    # `use_layer :rate_limit, enabled: :name` (and :front's): a declared integer setting the layer reads on each request;
    # 0 lets every request through, as Rails' test environment has rate_limit on a :null_store cache and no Thruster.
    def check_rate_limit(srv)
      srv["layers"].each do |entry|
        next unless %w[rate_limit front].include?(entry["name"]) && entry["enabled"]

        check_enabled_setting(srv, entry)
      end
    end

    def check_enabled_setting(srv, entry)
      layer = entry["name"]
      s = srv["settings"].find { |x| x["name"].to_s == entry["enabled"] }
      declared = srv["settings"].map { |x| x["name"] }
      bad(@enabled_nodes[layer], "`use_layer :#{layer}` `enabled:` names setting `#{entry['enabled']}`, which is not declared (declared: #{declared.join(', ')})", word: entry["enabled"], from: declared) unless s
      bad(@setting_nodes[s["name"]], "setting `#{s['name']}` turns `use_layer :#{layer}` on or off (0 is off), so it must be a required-or-defaulted integer: `setting :#{s['name']}, env: \"...\", default: 1, type: :i64`") unless s["type"] == "i64" && !s["optional"]
      (@flags["used_settings"] ||= {})[s["name"]] = true
    end

    # The cache's size is the setting `response_cache_mb` when the file declares one, so it has to be a whole number of MB.
    def check_response_cache(srv)
      return unless srv["routes"].any? { |r| r["cache"] }

      s = srv["settings"].find { |x| x["name"].to_s == "response_cache_mb" } or return
      (@flags["used_settings"] ||= {})[s["name"]] = true # the cache reads it, not a body
      return if s["type"] == "i64" && !s["optional"]

      bad(@setting_nodes[s["name"]], "setting `response_cache_mb` is the response cache's size in MB (0 turns it off), so it must be a required-or-defaulted integer: `setting :response_cache_mb, env: \"...\", default: 64, type: :i64`")
    end

    # A static mount can name the named `before` filters it does not run. The mount is declared before the
    # filters are read, so the names are checked here, once both lists are complete. A mount at "/" takes
    # no skip at all (add_static refuses one: the fallback would cover every GET path), and
    # `set :public_folder` takes no skip for now. A `serve_file` names its filters the same way.
    def check_static_skips(srv)
      named = srv["before"].filter_map { |f| f["name"] }
      srv["statics"].each do |s|
        s["skip"].to_a.each do |filter_name|
          next if named.include?(filter_name)

          bad(@static_nodes[s["prefix"]], "static `#{s['prefix']}` skips `:#{filter_name}`, but no `before :#{filter_name}` filter is declared#{named.empty? ? '' : " (named filters: #{named.join(', ')})"}")
        end
      end
      srv["not_found"]&.[]("skip").to_a.each do |filter_name|
        next if named.include?(filter_name)

        bad(@filter_nodes["not_found"], "not_found skips `:#{filter_name}`, but no `before :#{filter_name}` filter is declared#{named.empty? ? '' : " (named filters: #{named.join(', ')})"}")
      end
      srv["serve_files"].each do |f|
        f["skip"].to_a.each do |filter_name|
          next if named.include?(filter_name)

          bad(@serve_file_nodes[f["path"]], "serve_file `#{f['path']}` skips `:#{filter_name}`, but no `before :#{filter_name}` filter is declared#{named.empty? ? '' : " (named filters: #{named.join(', ')})"}")
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
      # A `serve_file` and the OpenAPI document are axum routes too. A `serve_file` carries its own `skip:`, the
      # OpenAPI document takes none, so a route pattern that matches either would step the filter aside for it.
      # Compare against them as routes, exactly like a literal route beside a capture.
      file_routes = []
      srv["serve_files"].to_a.each do |f|
        %w[get head].each do |method|
          entry = { "method" => method, "path" => f["path"], "skip" => f["skip"].to_a }
          (by_method[method] ||= []) << entry
          file_routes << [entry, @serve_file_nodes[f["path"]]]
        end
      end
      if srv["openapi"]
        %w[get head].each { |method| (by_method[method] ||= []) << { "method" => method, "path" => srv["openapi"]["path"], "skip" => [] } }
      end
      # The cable endpoint steps every named filter aside for GET of its path, as a serve_file that skips them all does.
      if srv["cable"]
        entry = { "method" => "get", "path" => srv["cable"]["path"], "skip" => srv["before"].filter_map { |f| f["name"] } }
        (by_method["get"] ||= []) << entry
        file_routes << [entry, @cable_node]
      end
      (@route_decl_nodes.to_a + file_routes).each do |route, node|
        route["skip"].to_a.each do |filter_name|
          by_method.fetch(route["method"], []).each do |other|
            next if other.equal?(route) || other["skip"].to_a.include?(filter_name)
            next unless path_patterns_overlap?(route["path"], other["path"])

            bad(node, "route `#{route['method']} #{route['path']}` skips `:#{filter_name}`, but the run-time skip " \
                      "(method and path) also matches `#{other['method']} #{other['path']}`, which does not skip it; " \
                      "give every handler that path reaches the same `skip:` (the OpenAPI " \
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
        return false unless segments_overlap?(x, y)

        i += 1
      end
    end

    # Two non-tail segments can match one part: equal, or a capture whose literal prefix and suffix agree with the
    # other side (`@{id}` meets `@7` and `{id}`, but not `messages`).
    def segments_overlap?(x, y)
      return true if x == y

      px, sx = capture_edges(x)
      py, sy = capture_edges(y)
      return false if px.nil? && py.nil?
      return x.length > py.length + sy.length && x.start_with?(py) && x.end_with?(sy) if px.nil?
      return y.length > px.length + sx.length && y.start_with?(px) && y.end_with?(sx) if py.nil?

      (px.start_with?(py) || py.start_with?(px)) && (sx.end_with?(sy) || sy.end_with?(sx))
    end

    # The literal text before and after a segment's `{name}` capture, or nil when it has none.
    def capture_edges(seg)
      open = seg.index("{")
      close = seg.rindex("}")
      open && close ? [seg[0...open], seg[(close + 1)..]] : nil
    end

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
    def filter_decl(node, pos, kw, blk, srv)
      if node.name == :not_found && srv["statics"].any? { |s| s["prefix"] == "/" }
        bad(node, "a `not_found` filter and a directory mounted at \"/\" (`set :public_folder`) both answer a request no route matched, and axum has one fallback; mount the directory at a prefix with `static \"/assets\", dir: ...` instead")
      end
      # `located` gives the filter body the line and file of its declaration, so Emit's source map can
      # point a generated-rustc error back at the filter, like every other declaration.
      if node.name == :before
        bad(node, "a `before` filter outside a controller needs a do ... end block; `before :name, only:` naming a def is for a controller") unless blk
        bad(node, "`only:` and `except:` are for a controller's `before :name`; a top-level filter runs for every route (`skip:` opts one out)") if kw[:only] || kw[:except]
        bad(node, "`provides:` is for a controller's `before :name` filter; a top-level filter is a layer and sets nothing a route reads") if kw[:provides]
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
        srv[key]["skip"] = kw[:skip].map(&:to_s) if node.name == :not_found && kw[:skip]
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
    # `log` picks the log format; `trust_forwarded_for` makes request_ip trust X-Forwarded-For without the trace
    # layer that normally declares that trust; `name` and `version` name the crate, as the `server` declaration does;
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
      when :locales
        bad(node, "`set :locales` takes the folder of the locale files as a string, such as \"config/locales\"") unless value.is_a?(String)
        bad(node, "duplicate `set :locales`#{first_at(node, @locales_node)}") if @flags["locales_dir"]
        if value.start_with?("/") || value.include?("\0") || value.split("/").include?("..")
          bad(node, "`set :locales` is a folder inside the DSL file's folder, without a leading /, without .., got #{value.inspect}")
        end
        @flags["locales_dir"] = value # Body#i18n_table reads the files there, when a body or a view calls `t`
        @locales_node = node
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
      when :turbo_frame_layout
        # turbo-rails' `layout "turbo_rails/frame"` for a request with a Turbo-Frame header: every render that has a
        # layout uses this one instead for such a request (Body#render_response).
        unless value.is_a?(String) || value.is_a?(Symbol)
          bad(node, "`set :turbo_frame_layout` names a view with a symbol (:turbo_frame) or a string")
        end
        bad(node, "duplicate `set :turbo_frame_layout`") if srv["turbo_frame_layout"]
        srv["turbo_frame_layout"] = value.to_s
        @flags["turbo_frame_layout"] = value.to_s
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
      when :merge_query_params
        # Rails' params: query_parameters.merge(request_parameters), so a form field the body lacks is read from the
        # query string (the body wins a key both carry, a list included).
        bad(node, "`set :merge_query_params` is true or false, written out") unless value == true || value == false
        bad(node, "duplicate `set :merge_query_params`") if srv.key?("merge_query_params")
        srv["merge_query_params"] = value
      when :trust_forwarded_for
        unless value == true || value == false
          bad(node, "`set :trust_forwarded_for` is true or false, written out: it trusts the first " \
                    "X-Forwarded-For entry for request_ip")
        end
        bad(node, "duplicate `set :trust_forwarded_for`#{first_at(node, @trust_forwarded_for_node)}") if @trust_forwarded_for_node
        srv["trust_forwarded_for"] = value
        @trust_forwarded_for_node = node
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
        next yield(n, nil, nil, nil) if n.is_a?(Prism::DefNode) && %i[top controller model record].include?(ctx)

        p, k, b = call(n, ctx)
        yield n, p, k, b
      end
    end

    # Validates one call against SIG; returns [positional values, keyword values, block].
    def call(node, ctx)
      where = ctx == :top ? "the top level" : "`#{ctx}`"
      bad(node, "unsupported #{nodename(node)} in #{where} (only DSL calls are allowed)") unless node.is_a?(Prism::CallNode)
      variants = AxumDsl.sig_variants(node.name)
      bad(node, "unknown DSL call `#{node.name}` (valid in #{where}: #{calls_in(ctx).join(", ")})", word: node.name, from: calls_in(ctx)) if variants.empty?
      sig = AxumDsl.sig(node.name, ctx)
      if sig.nil?
        bad(node, "`#{node.name}` is not allowed in #{where} (valid there: #{calls_in(ctx).join(", ")}); it belongs in #{variants.flat_map { |s| Array(s[:in]) }.map { |c| c == :top ? "the top level" : "`#{c}`" }.join(" or ")}")
      end
      bad(node.receiver, "`#{node.name}` takes no receiver") if node.receiver
      if node.block && sig[:pos].include?(:lambda)
        bad(node.block, "`#{node.name}` takes its body as a lambda, not a block: write `#{node.name} :name, -> { where(...) }` or `#{node.name} :name, ->(arg) { where(...) }`")
      end
      pos, kw = args(node, sig)
      note_declaration(node, pos, kw) if @types
      [pos, kw, block(node, sig)]
    end

    # The DSL calls allowed directly inside `ctx`.
    def calls_in(ctx) = AxumDsl.sig_names(ctx).map(&:to_s)

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
      return query_returns(node, bare: true) if want == :creturns
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
      if want == :hash
        # A hash literal of string or symbol keys; a value is a string, a symbol (kept as its name), an integer or a list of them.
        bad(node, "expected a hash literal such as { \"a\" => :b }, got #{nodename(node)}") unless node.is_a?(Prism::HashNode)
        scalar = lambda do |v|
          case v
          when Prism::StringNode then v.unescaped
          when Prism::SymbolNode then v.unescaped.to_sym
          when Prism::IntegerNode then v.value
          else bad(v, "a hash value is a string, symbol or integer literal, or a list of them, got #{nodename(v)}")
          end
        end
        out = {}
        node.elements.each do |el|
          bad(el, "unsupported #{nodename(el)} in a hash literal (write `\"key\" => value`)") unless el.is_a?(Prism::AssocNode) && (el.key.is_a?(Prism::StringNode) || el.key.is_a?(Prism::SymbolNode))
          key = el.key.unescaped
          bad(el, "duplicate key #{key.inspect}") if out.key?(key)
          out[key] = el.value.is_a?(Prism::ArrayNode) ? el.value.elements.map(&scalar) : scalar.call(el.value)
        end
        return out
      end
      if want == :camel_or_actions || want == :str_or_actions
        # `resources`: one value for every action (`params: :RoomPath`), or a hash by action (`params: { edit: :BotPath }`).
        each = want == :camel_or_actions ? :camel : :str
        return value(node, each) unless node.is_a?(Prism::HashNode)

        out = {}
        node.elements.each do |el|
          bad(el, "unsupported #{nodename(el)} in a by-action hash (write `edit: value`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          key = el.key.unescaped
          bad(el, "`#{key}` is not one of the seven resource actions: #{RESOURCE_ACTIONS.join(', ')}", word: key, from: RESOURCE_ACTIONS) unless RESOURCE_ACTIONS.include?(key)
          bad(el, "duplicate action #{key}") if out.key?(key)
          out[key] = value(el.value, each)
        end
        return out
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
      if want == :model_name
        # A model is named like a Rails class: `model :Room`, or a string for a namespaced one, `model "Account::Bot"`.
        name = node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
        bad(node, "expected a model name such as :Room or \"Account::Bot\", got #{nodename(node)}") unless name
        bad(node, "a model is named like a Rails one: \"Room\" or \"Account::Bot\"") unless name.match?(CONTROLLER_NAME)
        return name
      end
      if want == :lambda
        bad(node, "expected a lambda such as `-> { where(...) }` or `->(arg) { where(...) }`, got #{nodename(node)}") unless node.is_a?(Prism::LambdaNode)
        return node
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
      if want == :column
        bad(node, "`:#{s}` must be snake_case") unless s.match?(SNAKE)
        return s
      end
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
      return nil if b.nil? && sig[:optional_block]

      bad(node, "`#{node.name}` needs a do ... end block") unless b
      bad(b, "unsupported #{nodename(b)} (a literal block is required)") unless b.is_a?(Prism::BlockNode)
      bad(b.parameters, "`#{node.name}` block takes no parameters") if sig[:block] == :decls && b.parameters
      b
    end
  end
end
