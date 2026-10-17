# frozen_string_literal: true

module AxumDsl
  # The view language: a view is a `.html` file beside the DSL file, read at compile time and compiled into
  # the emitted Rust, so the crate carries no template and no template engine -- that is what separates a
  # view from `static`, which copies a file for the running service to serve.
  #
  # A view holds ten markers and nothing else: `{{ name }}` (an escaped local), `{{ name|raw }}` (the same
  # value with no escaping), `{{ name|sanitize }}` (the same value cleaned as HTML; only for a string),
  # `{{ yield }}` (a layout's child output, legal only in a layout),
  # `{% raw %}...{% endraw %}` (copied byte for byte, which is also how a literal `{{` is written),
  # `{{ partial :name, key: value }}` (a partial inlined here), `{% for x in xs %}...{% endfor %}` (the
  # body repeated for each element of a list local, as Askama's `{% for x in xs %}` is),
  # `{% if name %}...{% else %}...{% endif %}` (one of two branches, taken when the bool or nil-able `name`
  # is true), `{{ csrf_token }}` (the token `use_layer :csrf` puts on the request, for a form's hidden
  # `authenticity_token`) and `{{ asset_path "campfire.css" }}` (the fingerprinted path of a file under a
  # `static ... digest: true` mount). `partial` grows the marker grammar only as far as an attribute list,
  # `for` only as far as one list name and one new name, and `if` only as far as one name and one optional
  # `else`. There are no expressions, no filters beyond `|raw` and `|sanitize`, no comparisons, no negation
  # and no `elsif`: the logic lives in the route body and `locals:` carries its result, so the marker grammar
  # never has to grow a language behind it.
  #
  # A page whose `{{ }}` belongs to a client framework (Vue, Handlebars) is not a view but a static asset:
  # the browser evaluates the user data inside a live client template, which HTML escaping cannot prevent.
  # `{% raw %}` is for the region of a server-rendered page that such a framework owns.
  #
  # See docs/views.md for the surface, and Body#render_response for the Rust a view compiles to.
  module Views
    # The folder a `render` reads from when `set :views` names none.
    DEFAULT_DIR = "views"
    # What every refusal about the SHAPE of a marker ends with: the whole surface rather than the one
    # negated form, so a reader is told what to write instead of only what they wrote.
    FORMS = "a marker is one of `{{ name }}` (an escaped local), `{{ name|raw }}` (the same value " \
            "unescaped), `{{ name|sanitize }}` (the same value cleaned as HTML by the compiler's sanitiser), " \
            "`{{ yield }}` (a layout's child output), `{% raw %}...{% endraw %}` (copied byte " \
            "for byte, which is also how a literal `{{` is written), `{{ partial :name, key: value }}` " \
            "(a partial inlined here, whose markers read the arguments), `{% for x in xs %}...{% endfor %}` " \
            "(the body repeated for each element of the list `xs`) or `{% if name %}...{% else %}...{% endif %}` " \
            "(one of two branches, taken when the bool or nil-able `name` is true), `{{ csrf_token }}` " \
            "(the token of `use_layer :csrf`, written into a form's `authenticity_token`) or " \
            "`{{ asset_path \"campfire.css\" }}` (the fingerprinted path of a file under a `static ... " \
            "digest: true` mount)"
    # No loop variable in sight: the scope a marker is read in when it is not inside a `{% for %}`.
    NO_SCOPE = { open: [], closed: [] }.freeze
    # A loop variable: a new snake_case name.
    LOOP_VAR = /\A[a-z][a-z0-9_]*\z/
    # A local's name: what a marker can spell, and what a `locals:` key must be to be readable by one.
    NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    # A name that carries an extension is written `.html`. The extension is where a template engine infers
    # the escaping context from (Askama does); this DSL has one context, so a `.vue`, `.erb` or `.md` file is
    # not a view, and saying so by name beats reading it as HTML.
    EXT = /\.[A-Za-z0-9]+\z/

    # One loaded view: its path relative to the DSL file (for messages, and `--print-inputs`), its absolute
    # path, its markers in order, the local names they read in marker order (a `{{ partial }}` reads the
    # caller's locals its argument values name), and whether it writes `yield`.
    # `args` is the partial's `{% args %}` declaration -- [{ "name", "default" }] with a nil default for a
    # required argument -- or nil when the file declares none.
    Loaded = Struct.new(:rel, :real, :segments, :names, :yields, :args, keyword_init: true)

    # The folder a `render` reads its views from: the server file's folder. `set :views` is a server setting,
    # so a route in a `use_dsl` fragment (controllers/rooms.axum.rb) still reads views/ beside the file being
    # built, not a views/ folder beside the fragment. Every other relative path (use_dsl, rust_file, file,
    # openapi) resolves against the fragment that names it; only views are server-relative.
    def self.folder(path)
      File.realpath(File.dirname(File.expand_path(path)))
    end

    # The path of a view relative to the DSL file, from the name a `render`/`set :layout` names and the
    # folder `set :views` gives. Nil when the name carries an extension that is not `.html`. `bad` raises in
    # the caller's coordinates -- the declaration that named the view -- because that is the position the
    # emitted diagnostic can point at; the view's own line travels in the message.
    def self.rel(name, dir, bad:)
      n = name.to_s
      if n.empty? || n.start_with?("/") || n.include?("\0") || n.split("/").include?("..")
        bad.call("a view name is a path inside the DSL file's folder, without a leading /, without .., got #{n.inspect}")
      end
      base = dir.to_s.empty? ? n : "#{dir}/#{n}"
      return base if base.end_with?(".html")
      return nil if base.split("/").last.match?(EXT)

      "#{base}.html"
    end

    # Load and parse the view `name`: the file must be there (a view is read when the compiler runs, so it is
    # part of the source, not of the built crate) and it must be `.html` (`dir` is the folder `set :views`
    # named, `folder` the absolute folder of the DSL file or fragment that named the view).
    def self.load(name, dir, folder, bad:)
      rel = self.rel(name, dir, bad: bad)
      if rel.nil?
        bare = name.to_s.sub(EXT, "")
        bad.call("#{name.to_s.inspect} is not an `.html` file: the escaping context is inferred from the " \
                 "extension, as Askama does, so a view is only ever `.html`. Write `render :#{bare}` and the " \
                 "compiler reads #{dir}/#{bare}.html; a page whose `{{ }}` belongs to a client framework is a " \
                 "static asset, not a view")
      end
      real = File.expand_path(rel, folder)
      bad.call(not_found(rel, real)) unless File.file?(real) || Lsp::Sources[real]
      # An open editor buffer stands in for the file on disk, as it does for every other input the compiler
      # reads (Lsp::Sources): the language server then compiles the view the user is editing.
      text = Lsp::Sources[real] || File.read(real, encoding: "UTF-8")
      bad.call("#{rel} is not valid UTF-8 text; a view is read as its own text, so it must be valid text") unless text.valid_encoding?
      segments = parse(text, rel, bad: bad)
      decls = segments.select { |s| s["kind"] == "args" }
      if decls.size > 1
        bad.call("#{rel}:#{decls[1]['line']}: a file writes `{% args %}` once; the other is at line #{decls[0]['line']}")
      end
      segments -= decls
      names = read_names(segments)
      args = decls.first && decls.first["args"]
      check_args(args, names, segments, rel, decls.first["line"], bad: bad) if args
      Loaded.new(rel: rel, real: real, segments: segments, names: names,
                 yields: segments.any? { |s| s["kind"] == "yield" }, args: args)
    end

    # `{% args %}` against the markers: a partial that declares its arguments declares exactly the names its
    # markers read, so a marker reading an undeclared name and a declared name nothing reads are both refused.
    def self.check_args(args, names, segments, rel, line, bad:)
      declared = args.map { |a| a["name"] }
      if (undeclared = names - declared).any?
        name = undeclared.first
        at = flat(segments).find { |s| reads(s).include?(name) }["line"]
        bad.call("#{rel}:#{at}: `#{name}` is read here but `{% args %}` (line #{line}) does not declare it; " \
                 "`{% args %}` lists exactly the names the markers read")
      end
      return if (unread = declared - names).empty?

      bad.call("#{rel}:#{line}: `{% args %}` declares `#{unread.first}` but no marker reads it; " \
               "`{% args %}` lists exactly the names the markers read")
    end

    # The parameter list of `{% args label:, hint: "" %}`, read as Ruby keyword parameters (Prism parses it
    # as `def _(label:, hint: "")`): `label:` is required, `hint: ""` has a literal default -- a string, an
    # integer or true/false, the values a partial call can pass. Anything else is refused with what is allowed.
    def self.args_decl(src, rel, line, bad:)
      allowed = "`{% args %}` takes keyword parameters only: `label:` is required, `hint: \"\"` has a default, " \
                "and a default is a string, an integer or true/false"
      res = Prism.parse("def _(#{src}\n); end")
      bad.call("#{rel}:#{line}: `{% args #{src.strip} %}` is not a parameter list; #{allowed}") unless res.errors.empty?
      params = res.value.statements.body.first.parameters
      return [] if params.nil?

      unless params.requireds.empty? && params.posts.empty? && params.rest.nil? && params.keyword_rest.nil? &&
             params.block.nil? && params.optionals.empty?
        bad.call("#{rel}:#{line}: `{% args #{src.strip} %}` has a parameter that is not a keyword; #{allowed}")
      end
      params.keywords.map do |k|
        name = k.name.to_s
        bad.call("#{rel}:#{line}: `#{name}` cannot be an argument name; #{allowed}") unless name.match?(NAME)
        next { "name" => name, "default" => nil } if k.is_a?(Prism::RequiredKeywordParameterNode)

        v = k.value
        default =
          case v
          when Prism::StringNode then { "kind" => "string", "text" => v.unescaped }
          when Prism::IntegerNode then { "kind" => "int", "text" => v.value.to_s }
          when Prism::TrueNode, Prism::FalseNode then { "kind" => "bool", "text" => v.slice }
          else bad.call("#{rel}:#{line}: the default of `#{name}:` is `#{v.slice}`, which is not a literal; #{allowed}")
          end
        { "name" => name, "default" => default }
      end
    end

    # The local names a view reads, in marker order: a plain marker's own name, and a `{{ partial }}`'s
    # bare-name argument values, which are the caller's locals the call resolves against. A `{% for %}`
    # reads the list it loops over; its loop variable is no local, so a marker of it reads nothing.
    def self.read_names(segments) = flat(segments).flat_map { |s| reads(s) }.uniq

    # Every segment in marker order, with a loop's or an `{% if %}`'s segments after the block itself. Both
    # branches of an `{% if %}` are here: the locals rule counts every name either one reads, whether or not
    # that branch is taken at run time.
    def self.flat(segments)
      segments.flat_map do |s|
        case s["kind"]
        when "for" then [s] + flat(s["body"])
        when "if" then [s] + flat(s["then"]) + flat(s["else"])
        else [s]
        end
      end
    end

    # The locals one segment reads (see read_names).
    def self.reads(seg)
      case seg["kind"]
      when "partial" then seg["names"]
      when "for" then seg["over_field"] ? [] : [seg["over"]]
      when "if" then seg["var"] ? [] : [seg["name"]]
      when "text", "yield", "args", "csrf", "asset" then []
      else seg["var"] ? [] : [seg["name"]]
      end
    end

    # Why a view file is not there. A sibling that differs only in its extension is named, because that is the
    # extension rule seen from the other side: the escaping context is inferred from the extension (Askama's
    # idea), so `signup.erb` is not a view and is refused by name rather than read as HTML.
    def self.not_found(rel, real)
      dir = File.dirname(real)
      base = File.basename(real, ".html")
      sibling =
        begin
          File.directory?(dir) ? Dir.children(dir).sort.find { |c| c.start_with?("#{base}.") && File.file?(File.join(dir, c)) } : nil
        rescue SystemCallError
          nil
        end
      return "no view at #{rel}: a view is read at compile time and compiled into the emitted Rust, so the " \
             "file must be there when the compiler runs" unless sibling

      "#{rel} is not a view: #{File.dirname(rel)}/#{sibling} is there instead, and its extension is not " \
        "`.html`. The escaping context is inferred from the extension, as Askama does, so a view is only " \
        "ever `.html`"
    end

    # Split a view's text into segments, in order, keeping everything outside a marker verbatim. A refusal
    # names the view's own line, because a malformed marker is in the view and not in the DSL file; `bad`
    # still reports the position of the declaration, which is the only position a diagnostic has.
    def self.parse(text, rel, bad:)
      segments = []
      out = segments # the list a segment is added to: segments, or the body of the innermost open loop
      frames = []    # one frame per open `{% for %}` or `{% if %}`: { kind:, out:, seg:, else: }
      scope = { open: [], closed: [] } # the loop variables in scope, and those whose loop has ended
      buf = +""
      flush = lambda do
        next if buf.empty?

        out << { "kind" => "text", "text" => buf }
        buf = +""
      end
      i = 0
      while (open = text.index(/\{\{|\{%/, i))
        buf << text[i...open]
        line = line_at(text, open)
        if text[open, 2] == "{{"
          close = close_brace(text, open + 2)
          bad.call("#{rel}:#{line}: the `{{` here is never closed; #{FORMS}") unless close
          flush.call
          seg = marker(text[(open + 2)...close], rel, line, scope: scope, bad: bad)
          if seg["kind"] == "yield" && !frames.empty?
            bad.call("#{rel}:#{line}: `{{ yield }}` is a layout's child output, written once; it cannot sit inside a `{% for %}` or a `{% if %}`")
          end
          out << seg
          i = close + 2
        else
          close = text.index("%}", open + 2)
          bad.call("#{rel}:#{line}: the `{%` here is never closed; #{FORMS}") unless close
          directive = text[(open + 2)...close].strip
          if directive == "raw"
            after, stop = raw_region(text, close + 2)
            if after.nil?
              bad.call("#{rel}:#{line}: this `{% raw %}` is never closed; a raw region ends with " \
                       "`{% endraw %}`, and what it holds is copied byte for byte")
            end
            buf << text[(close + 2)...stop]
            i = after
          elsif directive.match?(/\Afor(\s|\z)/)
            flush.call
            seg = for_directive(directive, rel, line, scope, bad: bad)
            out << seg
            frames << { kind: "for", out: out, seg: seg }
            out = seg["body"]
            scope[:open] << seg["var"]
            i = close + 2
          elsif directive.match?(/\Aif(\s|\z)/)
            flush.call
            seg = if_directive(directive, rel, line, scope, bad: bad)
            out << seg
            frames << { kind: "if", out: out, seg: seg, else: false }
            out = seg["then"]
            i = close + 2
          elsif directive.match?(/\Aelse(\s|\z)/)
            frame = frames.last
            unless frame && frame[:kind] == "if"
              bad.call("#{rel}:#{line}: `{% else %}` here has no `{% if %}` before it; an `{% else %}` sits between `{% if name %}` and `{% endif %}`")
            end
            if directive != "else"
              bad.call("#{rel}:#{line}: `{% #{directive} %}` takes nothing; an `{% else %}` is written on its own, between the two branches")
            end
            if frame[:else]
              bad.call("#{rel}:#{line}: this `{% else %}` is a second one for the same `{% if %}`; a conditional has one optional `{% else %}`")
            end
            flush.call
            frame[:else] = true
            out = frame[:seg]["else"]
            i = close + 2
          elsif directive.match?(/\Aelsif(\s|\z)/)
            bad.call("#{rel}:#{line}: `{% #{directive} %}` is not a directive: there is no `{% elsif %}`; a " \
                     "conditional is `{% if name %}...{% else %}...{% endif %}`, one condition and one optional else")
          elsif directive == "endif"
            frame = frames.last
            unless frame && frame[:kind] == "if"
              bad.call("#{rel}:#{line}: `{% endif %}` here has no `{% if %}` before it; a conditional is `{% if name %}...{% endif %}`")
            end
            flush.call
            frames.pop
            out = frame[:out]
            i = close + 2
          elsif directive == "endfor"
            frame = frames.last
            unless frame && frame[:kind] == "for"
              if frame
                bad.call("#{rel}:#{line}: `{% endfor %}` here closes a `{% for %}` that is outside the open `{% if %}`; close the `{% if %}` with `{% endif %}` first")
              end
              bad.call("#{rel}:#{line}: `{% endfor %}` here has no `{% for %}` before it; a loop is `{% for x in xs %}...{% endfor %}`")
            end
            flush.call
            frames.pop
            out = frame[:out]
            scope[:open].pop
            scope[:closed] << frame[:seg]["var"]
            i = close + 2
          elsif directive.match?(/\Aargs(\s|\z)/)
            bad.call("#{rel}:#{line}: `{% args %}` declares the whole partial's arguments, so it sits outside any `{% for %}` or `{% if %}`") unless frames.empty?
            flush.call
            segments << { "kind" => "args", "line" => line, "args" => args_decl(directive.delete_prefix("args"), rel, line, bad: bad) }
            i = close + 2
          elsif directive == "endraw"
            bad.call("#{rel}:#{line}: `{% endraw %}` here has no `{% raw %}` before it; a raw region is " \
                     "`{% raw %}...{% endraw %}`")
          else
            bad.call("#{rel}:#{line}: `{% #{directive} %}` is not a directive: the only directives are " \
                     "`{% raw %}`, `{% endraw %}`, `{% args %}`, `{% for %}`, `{% endfor %}`, `{% if %}`, " \
                     "`{% else %}` and `{% endif %}`. #{FORMS}")
          end
        end
      end
      buf << text[i..text.length] if i < text.length
      flush.call
      unless frames.empty?
        frame = frames.last
        seg = frame[:seg]
        if frame[:kind] == "if"
          shown = seg["field"] ? "#{seg['name']}.#{seg['field']}" : seg["name"]
          bad.call("#{rel}:#{seg['line']}: this `{% if #{shown} %}` is never closed; a conditional ends with `{% endif %}`")
        else
          bad.call("#{rel}:#{seg['line']}: this `{% for #{seg['var']} in ... %}` is never closed; a loop ends with `{% endfor %}`")
        end
      end
      segments
    end

    # One `{% for x in name %}` (or `{% for x in y.field %}` over a field of an enclosing loop variable `y`):
    # an empty loop segment whose body parse fills in. `x` is a new snake_case name, so it may not be an
    # open loop variable; whether it is a local is checked where the locals are known (Body#view_loop).
    def self.for_directive(directive, rel, line, scope, bad:)
      m = directive.match(/\Afor\s+(\S+)\s+in\s+(\S+)\z/)
      unless m
        bad.call("#{rel}:#{line}: `{% #{directive} %}` is not a loop; a loop is `{% for note in notes %}` " \
                 "... `{% endfor %}`, over one list")
      end
      var, over = m[1], m[2]
      unless var.match?(LOOP_VAR) && var != "yield"
        bad.call("#{rel}:#{line}: `#{var}` cannot be a loop variable: a loop variable is a new snake_case name, as in `{% for note in notes %}`")
      end
      if scope[:open].include?(var)
        bad.call("#{rel}:#{line}: the loop variable `#{var}` is already the variable of an enclosing `{% for %}`; a loop variable is a new name")
      end
      base, dot, field = over.partition(".")
      unless base.match?(NAME) && (dot.empty? || field.match?(NAME))
        bad.call("#{rel}:#{line}: `#{over}` is not a list to loop over; write a local's name (`{% for note in notes %}`) " \
                 "or a field of an enclosing loop variable (`{% for tag in note.tags %}`)")
      end
      outside = ->(name) { bad.call("#{rel}:#{line}: `#{name}` is a loop variable used outside its `{% for %}`; it exists only between `{% for %}` and `{% endfor %}`") }
      if dot.empty?
        if scope[:open].include?(base)
          bad.call("#{rel}:#{line}: `#{base}` is a loop variable, not a list; loop over one of its fields (`{% for #{var} in #{base}.field %}`)")
        end
        outside.call(base) if scope[:closed].include?(base)
        return { "kind" => "for", "var" => var, "over" => base, "over_field" => nil, "line" => line, "body" => [] }
      end
      unless scope[:open].include?(base)
        outside.call(base) if scope[:closed].include?(base)
        bad.call("#{rel}:#{line}: `#{over}` is not a list to loop over: `#{base}` is not a loop variable, and only a field of one is read with a dot")
      end
      { "kind" => "for", "var" => var, "over" => base, "over_field" => field, "line" => line, "body" => [] }
    end

    # One `{% if name %}`: the condition is one name -- a bool or nil-able local, or a bool or nil-able field
    # of an enclosing loop variable (or the bool loop variable itself). There are no expressions, comparisons
    # or negation; the branch is chosen by Ruby truthiness (nil and false are false) and nothing else. An
    # empty if segment whose `then` and `else` bodies the caller's parse fills in. Whether the name is a
    # bool at all is checked where the locals are known (Body#view_if).
    def self.if_directive(directive, rel, line, scope, bad:)
      m = directive.match(/\Aif(?:\s+(.+))?\z/)
      form = m && m[1] && m[1].strip
      unless form && !form.empty?
        bad.call("#{rel}:#{line}: `{% #{directive} %}` has no condition; a conditional is `{% if name %}` " \
                 "... `{% endif %}`, over one bool or nil-able name")
      end
      base, dot, field = form.partition(".")
      if form == "yield"
        bad.call("#{rel}:#{line}: `{% if yield %}` is not a condition; `yield` is a layout's child output, not a local")
      end
      outside = ->(name) { bad.call("#{rel}:#{line}: `#{name}` is a loop variable used outside its `{% for %}`; it exists only between `{% for %}` and `{% endfor %}`") }
      if form.match?(NAME)
        outside.call(form) if scope[:closed].include?(form)
        return { "kind" => "if", "name" => form, "field" => nil, "var" => scope[:open].include?(form),
                 "line" => line, "then" => [], "else" => [] }
      end
      if base.match?(NAME) && !dot.empty? && field.match?(NAME) && scope[:open].include?(base)
        return { "kind" => "if", "name" => base, "field" => field, "var" => true,
                 "line" => line, "then" => [], "else" => [] }
      end
      outside.call(base) if base.match?(NAME) && scope[:closed].include?(base)
      bad.call("#{rel}:#{line}: `{% if #{form} %}` is not a condition; a condition is one name -- a bool or " \
               "nil-able local, or a bool or nil-able field of a loop variable -- with no expression, " \
               "comparison or negation (`{% if name %}...{% endif %}`)")
    end

    # The end of a raw region: the next `{% endraw %}` after `from`, as [the position after it, the position
    # it starts at]. A `{%` inside the region that is not `endraw` is text like any other, so one client
    # framework's template syntax may hold another's. [nil, nil] when the region never closes.
    def self.raw_region(text, from)
      j = from
      while (k = text.index("{%", j))
        m = text.index("%}", k + 2)
        break if m.nil?

        return [m + 2, k] if text[(k + 2)...m].strip == "endraw"

        j = m + 2
      end
      [nil, nil]
    end

    # The 1-based line of an offset in the view's own text, for a message that points into the view.
    def self.line_at(text, at) = text[0...at].count("\n") + 1

    # One `{{ ... }}` marker: `name` (escaped), `name|raw` (unescaped), `name|sanitize` (cleaned HTML),
    # `yield` or `partial`. The body holds no expression -- a name is a local, `|raw` and `|sanitize` are the
    # only filters and a partial takes literals and bare names -- so anything else is refused with the forms
    # rather than parsed as Ruby.
    def self.marker(text, rel, line, bad:, scope: NO_SCOPE)
      form = text.strip
      return partial(form, rel, line, scope, bad: bad) if form.match?(/\Apartial\s*:/)
      return { "kind" => "csrf", "line" => line } if form == "csrf_token"
      return asset_path_marker(form, rel, line, bad: bad) if form.match?(/\Aasset_path(\s|\z)/)

      if form.include?("|")
        name, _, filter = form.partition("|")
        name = name.strip
        filter = filter.strip
        unless %w[raw sanitize].include?(filter)
          bad.call("#{rel}:#{line}: `|#{filter}` is not a filter; `|raw` and `|sanitize` are the only ones " \
                   "(`{{ #{name}|raw }}` writes the value with no escaping, `{{ #{name}|sanitize }}` cleans it as HTML). #{FORMS}")
        end
        return named(name, filter, rel, line, scope, bad: bad)
      end
      return { "kind" => "yield", "line" => line } if form == "yield"

      named(form, "escaped", rel, line, scope, bad: bad)
    end

    # One `{{ asset_path "campfire.css" }}`: a file under the one `static ... digest: true` mount. The path
    # is relative to that mount's directory, as a double-quoted string with no expressions -- the digest is
    # computed at compile time, so there is nothing to compute here. Whether the mount exists and has the
    # file is checked where the render is compiled (Body#segment_parts), with the view's own line.
    def self.asset_path_marker(form, rel, line, bad:)
      rest = form.delete_prefix("asset_path").strip
      m = rest.match(/\A"([^"]*)"\z/)
      unless m
        bad.call("#{rel}:#{line}: `asset_path` takes a file's path as a double-quoted string, as in " \
                 "`{{ asset_path \"campfire.css\" }}`; the path is relative to a `static ... digest: true` directory")
      end
      name = m[1]
      if name.empty? || name.start_with?("/") || name.include?("\0") || name.split("/").include?("..")
        bad.call("#{rel}:#{line}: `#{name}` is not a file under the digest mount's directory: an asset_path " \
                 "is relative, without a leading / and without ..")
      end
      { "kind" => "asset", "name" => name, "line" => line }
    end

    # One `{{ partial :name, key: value, ... }}`: the partial to inline and its flat arguments. An argument

    # value is a literal -- a string, an integer or true/false -- or a bare name, which is a local of the
    # caller that holds the marker; there are no expressions and no nesting. The arguments are exactly the
    # names the partial's own markers read, checked when the partial is loaded (Body#expand_partial).
    def self.partial(form, rel, line, scope, bad:)
      rest = form.delete_prefix("partial")
      m = rest.match(/\A\s*:([A-Za-z_][A-Za-z0-9_]*)/)
      unless m
        bad.call("#{rel}:#{line}: `partial` takes the partial's name as a symbol, as in " \
                 "`{{ partial :field, label: \"Name\" }}`; the name is `field.html` beside the views")
      end
      args = partial_args(rest[m.end(0)..] || "", rel, line, scope, bad: bad)
      { "kind" => "partial", "name" => m[1], "args" => args, "line" => line,
        "names" => args.filter_map { |a| a["value"]["text"] if a["value"]["kind"] == "name" && !a["value"]["var"] } }
    end

    # The `key: value` list after a partial's name, comma-separated. An empty list is legal: a partial whose
    # markers read nothing takes no arguments. A key is a bare word, and the same key twice is refused here.
    def self.partial_args(rest, rel, line, scope, bad:)
      args = []
      seen = {}
      s = rest
      until s.empty?
        s = s.lstrip
        break if s.empty?

        unless s.start_with?(",")
          bad.call("#{rel}:#{line}: a partial's arguments are a flat `key: value` list separated by commas, " \
                   "as in `{{ partial :field, label: \"Name\" }}`")
        end
        s = (s[1..] || "").lstrip
        m = s.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s*:/)
        unless m
          bad.call("#{rel}:#{line}: an argument is named by a bare word and a colon, as in `label: \"Name\"`")
        end
        key = m[1]
        value, s = partial_value((s[m.end(0)..] || ""), rel, line, scope, bad: bad)
        bad.call("#{rel}:#{line}: duplicate partial argument `#{key}`") if seen.key?(key)

        seen[key] = true
        args << { "name" => key, "value" => value }
      end
      args
    end

    # One argument value: a double-quoted string (no escape sequences -- the marker is text, not Ruby), an
    # integer, true/false, or a bare name that resolves among the caller's locals -- or, inside a `{% for %}`,
    # the loop variable `x` or its field `x.field`. Returns [the value, what follows it].
    def self.partial_value(s, rel, line, scope, bad:)
      s = s.lstrip
      if s.start_with?('"')
        close = s.index('"', 1)
        bad.call("#{rel}:#{line}: this string is never closed; a partial's string value is double-quoted " \
                 "with no escape sequences, as in label: \"Name\"") if close.nil?
        [{ "kind" => "string", "text" => s[1...close] }, s[(close + 1)..] || ""]
      elsif (m = s.match(/\A-?[0-9]+\b/))
        [{ "kind" => "int", "text" => m[0] }, s[m.end(0)..] || ""]
      elsif (m = s.match(/\A(true|false)\b/))
        [{ "kind" => "bool", "text" => m[0] }, s[m.end(0)..] || ""]
      elsif (m = s.match(/\A[A-Za-z_][A-Za-z0-9_]*/))
        rest = s[m.end(0)..] || ""
        return [{ "kind" => "name", "text" => m[0] }, rest] unless scope[:open].include?(m[0])

        field = rest.match(/\A\.([A-Za-z_][A-Za-z0-9_]*)/)
        [{ "kind" => "name", "text" => m[0], "var" => true, "field" => field && field[1] }, field ? rest[field.end(0)..] || "" : rest]
      else
        bad.call("#{rel}:#{line}: a partial's argument value is a string, a number, true/false or a bare " \
                 "name (a local of the caller), not an expression")
      end
    end

    # The `}}` that ends a `{{ ... }}` marker: the first one that is not inside a double-quoted string, so a
    # partial's `label: "a }} b"` is one argument and not an early end. Character offsets, as parse's are;
    # nil when the marker never closes.
    def self.close_brace(text, from)
      j = from
      while j < text.length
        case text[j]
        when '"'
          j += 1
          j += 1 while j < text.length && text[j] != '"'
          j += 1
        when "}"
          return j if text[j, 2] == "}}"

          j += 1
        else
          j += 1
        end
      end
      nil
    end

    # A marker naming a local. `yield` is not a local but the layout's child output, so the filtered spelling
    # of it is refused too; its plain form is handled by `marker` above.
    def self.named(name, kind, rel, line, scope, bad:)
      if name == "csrf_token"
        bad.call("#{rel}:#{line}: `{{ csrf_token }}` takes no filter; write it on its own, as a form's " \
                 "`authenticity_token` value")
      end
      if name == "yield"
        bad.call("#{rel}:#{line}: `{{ yield }}` is a layout's child output, not a local; write it with no filter, in a layout")
      end
      base, dot, field = name.partition(".")
      outside = "#{rel}:#{line}: `#{base}` is a loop variable used outside its `{% for %}`; it exists only between `{% for %}` and `{% endfor %}`"
      if !dot.empty? && base.match?(NAME) && (scope[:open].include?(base) || scope[:closed].include?(base))
        bad.call(outside) unless scope[:open].include?(base)
        unless field.match?(NAME)
          bad.call("#{rel}:#{line}: `{{ #{name} }}` has more than one dot; a loop variable is read as `{{ #{base} }}` or `{{ #{base}.field }}`")
        end
        return { "kind" => kind, "name" => base, "field" => field, "var" => true, "line" => line }
      end
      if name.match?(NAME) && scope[:open].include?(name)
        return { "kind" => kind, "name" => name, "field" => nil, "var" => true, "line" => line }
      end
      bad.call(outside) if name.match?(NAME) && scope[:closed].include?(name)
      bad.call("#{rel}:#{line}: `{{ #{name} }}` is not a marker; #{FORMS}") unless name.match?(NAME)

      { "kind" => kind, "name" => name, "line" => line }
    end
  end
end
