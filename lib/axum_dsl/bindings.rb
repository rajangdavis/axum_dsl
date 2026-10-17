# frozen_string_literal: true

module AxumDsl
  # A binding is a trusted Ruby file in a bindings/ folder next to the DSL file that uses it. It describes functions to the compiler:
  # a Ruby stand-in for some functionality, with a `sig` (types), a Ruby body (required), and
  # optionally a `rust "..."` template that says "this Rust expression does the work instead".
  #
  #   no template  -> the Ruby body is compiled to Rust and IS the implementation
  #   with template -> the Rust is the implementation; the Ruby body is the reference that tests
  #                    compare it against (it never reaches the generated server)
  #
  # The compiler only PARSES these files with Prism (it never runs them). See DESIGN.md.
  module Bindings
    SCALARS = { "String" => :string, "Float" => :f64, "I32" => :i32, "I64" => :i64, "T::Boolean" => :bool }.freeze
    LISTS = { "T::Array[String]" => :strs, "T::Array[I64]" => :i64s, "T::Array[Float]" => :f64s }.freeze
    TYPES = SCALARS.merge(LISTS).freeze

    Fn = Struct.new(:name, :params, :returns, :rust, :body, :node, :no_reference, :async, keyword_init: true)

    # A type the binding owns: Json::Value, the Rust type behind it, and whether it may cross the wire. A record also
    # lists its fields ([name, type symbol, line], from `field :text, String` lines), which the DSL may read and the
    # generated server checks against the Rust struct; a plain opaque type has none.
    Opaque = Struct.new(:name, :rust, :wire, :node, :fields, keyword_init: true)

    BindingFile = Struct.new(:name, :module_name, :path, :source, :crates, :fns, :examples, :types, keyword_init: true) do
      # heck_snake_case for Heck.snake_case: the Rust function the wrapper becomes.
      # A name ending in ? becomes _p: Html.valid_selector? is html_valid_selector_p.
      def wrapper(fn) = "#{module_name.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase}_#{fn.name.sub(/\?\z/, '_p')}"

      def descriptor(fn)
        { "name" => wrapper(fn), "args" => fn.params.map { |n, t| [n, t.to_s] },
          "returns" => fn.returns.to_s, "rust" => fn.rust, "body" => nil, "async" => fn.async ? true : false }
      end
    end

    # Where a DSL file's bindings live: a bindings/ folder in the same directory as the file. Nothing is searched
    # beyond that, and the compiler ships no bindings of its own.
    def self.dir_for(dsl_path) = File.join(File.dirname(File.expand_path(dsl_path)), "bindings")

    def self.load(name, root:)
      raise CompileError, "binding name `#{name}` must be snake_case" unless name.to_s.match?(SNAKE)

      path = File.join(root, "#{name}.rb")
      unless File.file?(path) || Lsp::Sources[path]
        where = File.directory?(root) ? "#{root} has no #{name}.rb" : "there is no bindings/ folder next to the DSL file (expected #{root})"
        raise CompileError, "no binding named #{name}: #{where}; use_bindings :#{name} loads bindings/#{name}.rb from the same directory as the file that uses it"
      end

      Parser.new(name.to_s, path).parse
    end

    class Parser
      include Diag

      def initialize(name, path)
        @name = name
        @path = path
      end

      def parse
        text = Lsp::Sources[@path] || File.read(@path, encoding: "UTF-8")
        res = Prism.parse(text)
        unless res.errors.empty?
          raise CompileError, res.errors.map { |e|
            "#{@path}:#{e.location.start_line}:#{e.location.start_column + 1}: syntax error: #{e.message}"
          }.join("\n")
        end
        top = res.value.statements.body
        mods = top.grep(Prism::ModuleNode)
        bad(top.first || res.value, "a binding file must define exactly one module and nothing else") unless mods.size == 1 && top.size == 1
        mod = mods.first
        file = BindingFile.new(name: @name, module_name: mod.constant_path.slice, path: @path, source: text,
                               crates: [], fns: {}, examples: [], types: {})
        @file = file
        state = {}
        (mod.body&.body || []).each { |n| statement(n, file, state) }
        bad(mod, "a sig or annotation is not followed by a def") unless state.empty?
        bad(mod, "a binding must define at least one method") if file.fns.empty?
        file.examples.each do |ex|
          bad(mod, "example for unknown method `#{ex[:method]}`") unless file.fns.key?(ex[:method])
        end
        file
      end

      private

      def statement(node, file, state)
        case node
        when Prism::CallNode then call(node, file, state)
        when Prism::DefNode then define(node, file, state)
        when Prism::ClassNode then opaque(node, file)
        else
          bad(node, "unsupported #{nodename(node)} in a binding (allowed: extend, crate, sig, rust, no_reference, example, def self.name, class Name < AxumDsl::Opaque)")
        end
      end

      # class Value < AxumDsl::Opaque; type_rust "serde_json::Value", wire: true; end: a type the binding owns. The
      # DSL can hold a value of it and hand it to the binding's functions; it cannot look inside. A record adds
      # `field :text, String` lines after type_rust: the DSL may then read those fields (docs/specs/typed_record.md).
      def opaque(node, file)
        bad(node, "a type in a binding is written `class Name < AxumDsl::Opaque`") unless node.superclass&.slice == "AxumDsl::Opaque" && node.constant_path.is_a?(Prism::ConstantReadNode)
        name = node.constant_path.name.to_s
        bad(node, "type `#{name}` is declared twice") if file.types.key?(name)
        calls = node.body&.body || []
        ok = !calls.empty? && calls[0].is_a?(Prism::CallNode) && calls[0].name == :type_rust && calls[0].receiver.nil?
        bad(node, "`class #{name} < AxumDsl::Opaque` starts with type_rust \"the::rust::Type\", wire: true, then optionally `field :name, Type` lines") unless ok
        call = calls[0]
        args = call.arguments&.arguments || []
        kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
        bad(call, "type_rust takes the Rust type as a string, then optionally wire: true") unless args.size == 1
        rust = str(args[0])
        bad(args[0], "the Rust type `#{rust}` is not a path such as serde_json::Value") unless rust.match?(/\A(?:::)?[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/)
        wire = false
        (kw&.elements || []).each do |el|
          key = el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) ? el.key.unescaped : nil
          bad(el, "type_rust takes only wire: true or wire: false") unless key == "wire" && (el.value.is_a?(Prism::TrueNode) || el.value.is_a?(Prism::FalseNode))
          wire = el.value.is_a?(Prism::TrueNode)
        end
        # Registered before its fields are read, so a field of this very type is named as a record in a record.
        file.types[name] = Opaque.new(name: name, rust: rust, wire: wire, node: node, fields: [])
        calls.drop(1).each { |f| record_field(f, file.types[name]) }
      end

      # field :text, String inside a record: a name and a type a binding sig accepts, not another binding type.
      def record_field(node, record)
        ok = node.is_a?(Prism::CallNode) && node.name == :field && node.receiver.nil?
        bad(node, "after type_rust, a `class #{record.name} < AxumDsl::Opaque` holds only `field :name, Type` lines") unless ok
        args = node.arguments&.arguments || []
        bad(node, "field takes a name and a type, as in `field :text, String`") unless args.size == 2 && args[0].is_a?(Prism::SymbolNode)
        fname = args[0].unescaped
        bad(args[0], "field `#{fname}` must be snake_case and not a Rust keyword") if !fname.match?(SNAKE) || RUST_KW.include?(fname)
        bad(args[0], "record `#{record.name}` declares field `#{fname}` twice") if record.fields.any? { |f| f[0] == fname }
        sym = type(args[1])
        inner = Body::OPT[sym] || sym
        if CompositeTypes::Opaque.symbol?(inner) || CompositeTypes::Opaque.list_element(inner)
          bad(args[1], "field `#{fname}`: a record cannot hold another binding type (not yet)")
        end
        record.fields << [fname, sym, node.location.start_line]
      end

      def call(node, file, state)
        bad(node, "`#{node.name}` takes no receiver here") if node.receiver
        args = (node.arguments&.arguments || []).dup
        case node.name
        when :extend
          ok = args.size == 1 && %w[T::Sig AxumDsl::BindingDsl].include?(args[0].slice)
          bad(node, "only `extend T::Sig` and `extend AxumDsl::BindingDsl` are allowed") unless ok
        when :crate
          bad(node, "crate takes a name and a version") unless args.size == 2
          file.crates << [str(args[0]), str(args[1])]
        when :sig then state[:sig] = sig(node)
        when :rust
          kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
          bad(node, "rust takes one template string") unless args.size == 1
          state[:rust] = str(args[0])
          state[:rust_async] = rust_async(node, kw)
        when :no_reference
          bad(node, "no_reference takes a reason string") unless args.size == 1
          state[:no_reference] = str(args[0])
        when :example then file.examples << example(node, args)
        when :field then bad(node, "field belongs inside `class Name < AxumDsl::Opaque`, after its type_rust line")
        else bad(node, "unsupported call `#{node.name}` in a binding")
        end
      end

      def rust_async(node, kw)
        return false unless kw

        bad(node, "rust takes only `async: true` as a keyword") unless kw.elements.size == 1
        el = kw.elements[0]
        bad(node, "rust takes only `async: true` as a keyword") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && el.key.unescaped == "async"
        val = el.value
        bad(val, "`async:` must be true or false") unless val.is_a?(Prism::TrueNode) || val.is_a?(Prism::FalseNode)
        val.is_a?(Prism::TrueNode)
      end

      def str(node)
        return node.unescaped if node.is_a?(Prism::StringNode)
        return node.parts.map(&:unescaped).join if node.is_a?(Prism::InterpolatedStringNode) && node.parts.all?(Prism::StringNode)

        bad(node, "expected a plain string literal, got #{nodename(node)}")
      end

      # sig { params(s: String, n: I32).returns(String) }
      def sig(node)
        blk = node.block
        ok = blk.is_a?(Prism::BlockNode) && blk.body.is_a?(Prism::StatementsNode) && blk.body.body.size == 1
        bad(node, "sig needs a { params(...).returns(Type) } block") unless ok
        returns = blk.body.body[0]
        bad(returns, "a sig must be params(...).returns(Type) or returns(Type)") unless returns.is_a?(Prism::CallNode) && returns.name == :returns
        ret_arg = returns.arguments&.arguments&.first or bad(returns, "returns needs a type")
        params = []
        if (recv = returns.receiver)
          bad(recv, "expected params(...) before .returns") unless recv.is_a?(Prism::CallNode) && recv.name == :params && recv.receiver.nil?
          kw = recv.arguments&.arguments&.first
          bad(recv, "params needs name: Type pairs") unless kw.is_a?(Prism::KeywordHashNode)
          kw.elements.each do |el|
            bad(el, "expected name: Type") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
            params << [el.key.unescaped, type(el.value)]
          end
        end
        { params: params, returns: type(ret_arg) }
      end

      # A scalar or list type, or T.nilable(...) of one. A nil-able return is how a binding says "does not
      # exist" or "does not parse": the DSL decides whether that is an error (`|| default`, `|| raise("...")`),
      # so a binding never fails by itself. A nil-able parameter lets the callee decide what nil means
      # (rmcp-for-blender gap #15); it arrives as an owned Option.
      def type(node)
        text = node.slice.gsub(/\s+/, "")
        found = scalar_or_opaque(text)
        return found if found

        if (m = text.match(/\AT\.nilable\((.+)\)\z/))
          inner = scalar_or_opaque(m[1]) or bad(node, "unsupported type `#{node.slice}` (T.nilable takes one of: #{type_names})")
          return Body::OPT_OF.fetch(inner)
        end
        hint = text == "Integer" ? "; use I32 or I64 (the compiler must know the width)" : ""
        bad(node, "unsupported type `#{node.slice}` (supported: #{type_names}, or T.nilable of those)#{hint}")
      end

      # A scalar or list, or a type this file declared with `class Name < AxumDsl::Opaque` (written Name or Module::Name),
      # or T::Array of one of those types.
      def scalar_or_opaque(text)
        return TYPES.fetch(text) if TYPES.key?(text)

        if (m = text.match(/\AT::Array\[(.+)\]\z/))
          elem = own_type(m[1])
          return elem && CompositeTypes::Opaque.list_symbol(elem)
        end
        (name = own_type(text)) && CompositeTypes::Opaque.symbol(name)
      end

      # "Row" or "Html::Row" -> "Html::Row" when this file declares it; nil otherwise.
      def own_type(text)
        name = text.delete_prefix("#{@file.module_name}::")
        @file.types.key?(name) ? "#{@file.module_name}::#{name}" : nil
      end

      def type_names = (TYPES.keys + @file.types.keys.flat_map { |n| ["#{@file.module_name}::#{n}", "T::Array[#{@file.module_name}::#{n}]"] }).join(", ")

      def define(node, file, state)
        bad(node, "binding methods are written `def self.name(...)`") unless node.receiver.is_a?(Prism::SelfNode)
        name = node.name.to_s
        sig = state.delete(:sig) or bad(node, "`#{name}` has no sig; every binding method declares its types")
        rust = state.delete(:rust)
        async = state.delete(:rust_async)
        no_ref = state.delete(:no_reference)
        names = parameter_names(node)
        sig_names = sig[:params].map(&:first)
        bad(node, "the sig names #{sig_names.inspect} but `#{name}` takes #{names.inspect}") unless sig_names == names
        bad(node, "`#{name}` is defined twice") if file.fns.key?(name)
        empty = node.body.nil? || (node.body.is_a?(Prism::StatementsNode) && node.body.body.empty?)
        if empty && !no_ref
          bad(node, "`#{name}` needs a Ruby body (the reference implementation), or `no_reference \"why\"` before it")
        end
        bad(node, "`#{name}` has neither a rust template nor a Ruby body, so there is nothing to compile") if rust.nil? && empty
        file.fns[name] = Fn.new(name: name, params: sig[:params], returns: sig[:returns], rust: rust,
                                body: empty ? nil : node.body, node: node, no_reference: no_ref,
                                async: async ? true : false)
      end

      def parameter_names(node)
        ps = node.parameters
        return [] unless ps

        extra = [ps.optionals, ps.posts, ps.keywords].any? { |x| !x.empty? } || ps.rest || ps.keyword_rest || ps.block
        bad(ps, "binding methods take only plain required parameters") if extra
        ps.requireds.map do |r|
          bad(r, "unsupported #{nodename(r)} as a parameter") unless r.is_a?(Prism::RequiredParameterNode)
          r.name.to_s
        end
      end

      # example :snake_case, "HelloWorld", expect: "hello_world"
      def example(node, args)
        kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
        meth = args.shift
        bad(node, "example starts with the method name as a symbol") unless meth.is_a?(Prism::SymbolNode)
        expect = kw&.elements&.find { |e| e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) && e.key.unescaped == "expect" }
        bad(node, "example needs expect: value") unless expect
        { method: meth.unescaped, args: args.map { |a| literal(a) }, expect: literal(expect.value) }
      end

      def literal(node)
        case node
        when Prism::StringNode, Prism::InterpolatedStringNode then str(node)
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::NilNode then nil
        when Prism::ArrayNode then node.elements.map { |el| literal(el) }
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        else bad(node, "examples take string, number, boolean, nil or array literals, got #{nodename(node)}")
        end
      end
    end
  end
end
