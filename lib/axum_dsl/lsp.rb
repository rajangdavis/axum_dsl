# frozen_string_literal: true

module AxumDsl
  # The language server for DSL files, driven by the compiler. Diagnostics are what `check` reports: the
  # compiler's errors with their "did you mean" suggestions, and the warnings and notices the gates allow.
  # Hover and completion are rendered from SIG - the table the reader validates against, and the one bin/gen_rbi,
  # skill.rb and docs.rb already derive their output from - so what the editor shows cannot describe a different
  # DSL than the one that compiles. Parts load on first use so each can be built and tested on its own.
  #
  # Positions: the compiler reports 1-based lines and 1-based BYTE columns (Prism). LSP uses 0-based lines and
  # 0-based UTF-16 columns. Everything below Server works in the compiler's positions; Position converts at the
  # edge.
  module Lsp
    autoload :Sources, File.expand_path("lsp/sources", __dir__)
    autoload :Position, File.expand_path("lsp/position", __dir__)
    autoload :Analysis, File.expand_path("lsp/analysis", __dir__)
    autoload :SigDoc, File.expand_path("lsp/sig_doc", __dir__)
    autoload :Hover, File.expand_path("lsp/hover", __dir__)
    autoload :Completion, File.expand_path("lsp/completion", __dir__)
    autoload :Server, File.expand_path("lsp/server", __dir__)
  end
end
