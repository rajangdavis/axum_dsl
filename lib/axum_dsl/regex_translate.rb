# frozen_string_literal: true

module AxumDsl
  # Ruby (Onigmo) regex source -> Rust `regex` crate source. A pure function, so it
  # can be tested without Prism. SPEC.md section 5. It rejects what the engines
  # disagree on or Rust lacks, instead of guessing.
  module RegexTranslate
    class Unsupported < StandardError; end

    # Ruby's \d \w \s are ASCII-only; Rust's are Unicode by default, so expand them.
    SHORT = { "d" => "0-9", "w" => "0-9A-Za-z_", "s" => ' \t\r\n\f\x0B' }.freeze
    PUNCT = /\A[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E]\z/
    # Ruby [[:word:]] on Unicode text is Onigmo's Word class: Alphabetic, Mark, Decimal_Number
    # and Connector_Punctuation (the "_" family). Rust's \w also adds Join_Control (ZWJ/ZWNJ),
    # which Onigmo's Word class leaves out, so it is not emitted here.
    POSIX = /\A\[:(\^?)(\w+):\]/
    POSIX_WORD = '\p{Alphabetic}\p{M}\p{Nd}\p{Pc}'
    # \p{Name} and \uXXXX: escapes that are longer than the two characters `escape` sees.
    PROPERTY = /\A\\p\{(\w+)\}/
    UNICODE = /\A\\u(\h{4})/
    # The \p names both engines share, except Ruby's Space, which is Rust's White_Space.
    PROPERTIES = {
      "Space" => "White_Space",
      "Emoji_Presentation" => "Emoji_Presentation",
      "Extended_Pictographic" => "Extended_Pictographic"
    }.freeze

    module_function

    # Ruby ^ and $ are always line anchors, hence the unconditional (?m).
    # Ruby /m means "dot matches newline", which is (?s) in Rust.
    def translate(src, multi_line: false, ignore_case: false, extended: false)
      flags = +"m"
      flags << "s" if multi_line
      flags << "i" if ignore_case
      flags << "x" if extended
      "(?#{flags})#{body(src)}"
    end

    def body(src)
      out = +""
      in_class = false
      quant = false
      i = 0
      while i < src.length
        ch = src[i]
        if ch == "\\" && (m = PROPERTY.match(src[i..]))
          out << property(m[1])
          quant = false
          i += m[0].length
        elsif ch == "\\" && (m = UNICODE.match(src[i..]))
          out << "\\x{#{m[1]}}"
          quant = false
          i += m[0].length
        elsif ch == "\\"
          nxt = src[i + 1] or raise Unsupported, "pattern ends with a lone backslash"
          out << escape(nxt, in_class)
          quant = false
          i += 2
        elsif in_class && ch == "[" && (m = POSIX.match(src[i..]))
          out << posix(m[1], m[2])
          i += m[0].length
        elsif in_class
          raise Unsupported, "nested or POSIX character classes are not supported" if ch == "["

          in_class = false if ch == "]"
          out << ch
          i += 1
        elsif ch == "["
          in_class = true
          out << ch
          i += 1
          if src[i] == "^"
            out << "^"
            i += 1
          end
          raise Unsupported, "a literal ] at the start of a class is not supported" if src[i] == "]"
        elsif ch == "("
          if src[i + 1] == "?"
            rest = src[i + 2, 2].to_s
            raise Unsupported, "lookahead is not supported" if rest.start_with?("=", "!")
            raise Unsupported, "lookbehind is not supported" if rest.start_with?("<=", "<!")
            raise Unsupported, "atomic groups are not supported" if rest.start_with?(">")

            out << "(?"
            i += 2
          else
            out << ch
            i += 1
          end
          quant = false
        elsif "+*?}".include?(ch)
          raise Unsupported, "possessive quantifiers are not supported" if quant && ch == "+"

          quant = !(quant && ch == "?")
          out << ch
          i += 1
        else
          quant = false
          out << ch
          i += 1
        end
      end
      raise Unsupported, "unterminated character class" if in_class

      out
    end

    def escape(nxt, in_class)
      case nxt
      when "A", "z", "b", "B"
        raise Unsupported, "\\#{nxt} inside a character class is not supported" if in_class

        "\\#{nxt}"
      when "n", "t", "r", "f", "v", "x" then "\\#{nxt}"
      when "d", "w", "s" then in_class ? SHORT.fetch(nxt) : "[#{SHORT.fetch(nxt)}]"
      when "D", "W", "S"
        raise Unsupported, "negated shorthand \\#{nxt} inside a character class is not supported" if in_class

        "[^#{SHORT.fetch(nxt.downcase)}]"
      when "<", ">" then raise Unsupported, "\\#{nxt} is a word boundary in Rust, not an escape"
      when PUNCT then "\\#{nxt}"
      else
        raise Unsupported, "escape \\#{nxt} is not supported (Ruby and Rust differ, or Rust lacks it)"
      end
    end

    # Only the positive [:word:] is supported; the set goes straight into the enclosing Rust class.
    def posix(caret, name)
      raise Unsupported, "POSIX class [:#{caret}#{name}:] is not supported (only [:word:])" unless name == "word" && caret.empty?

      POSIX_WORD
    end

    def property(name)
      rust = PROPERTIES.fetch(name) do
        raise Unsupported, "\\p{#{name}} is not supported (only \\p{Space}, \\p{Emoji_Presentation}, \\p{Extended_Pictographic})"
      end
      "\\p{#{rust}}"
    end
  end
end
