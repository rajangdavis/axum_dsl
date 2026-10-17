# frozen_string_literal: true

module AxumDsl
  module Lsp
    # The text of open editor buffers, keyed by canonical path. The compiler reads a file through this: a
    # binding through Bindings::Parser, and the DSL file, a use_dsl fragment or a rust_file/file, through the
    # reader's own lookup. That is what makes a check or the language server work on what is on screen rather
    # than what is on disk. The server fills the table on didOpen/didChange and empties it on didClose.
    class Sources
      @text = {}

      class << self
        attr_reader :text

        def [](path) = @text[AxumDsl.canon(path)]

        # `[]=` cannot be written with the endless syntax: Ruby refuses a setter defined that way.
        def []=(path, text)
          @text[AxumDsl.canon(path)] = text
        end

        def delete(path) = @text.delete(AxumDsl.canon(path))

        def clear = @text.clear

        # Compiles the block with `text` standing in for `path`, then puts the table back.
        def with(path, text)
          key = AxumDsl.canon(path)
          had = @text.key?(key)
          before = @text[key]
          @text[key] = text
          yield
        ensure
          had ? (@text[key] = before) : @text.delete(key)
        end

        # Compiles the block with a whole table of open documents standing in for their paths, so a compile of
        # one file reads another (a binding, a fragment) from its buffer too. The previous table is put back
        # after, so a plain AxumDsl.read elsewhere reads disk again.
        def with_all(table)
          before = @text
          @text = table.to_h { |path, text| [AxumDsl.canon(path), text] }
          yield
        ensure
          @text = before
        end
      end
    end
  end
end
