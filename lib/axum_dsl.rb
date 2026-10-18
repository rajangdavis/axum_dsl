# frozen_string_literal: true

require "prism"
require "digest"
require_relative "axum_dsl/version"
require "json"

module AxumDsl
  # `suggestions` is the optional list of nearby valid names a "did you mean" hint was built from.
  class CompileError < StandardError
    attr_reader :suggestions

    def initialize(msg = nil, suggestions: [])
      super(msg)
      @suggestions = suggestions
    end
  end

  # Shared diagnostics: every error is "FILE:LINE:COL: message" (col is 1-based).
  module Diag
    def nodename(node) = node.class.name.split("::").last

    # `word:` is the misspelt name and `from:` the valid ones: the nearest are appended as "; did you mean
    # `x`?" and carried in CompileError#suggestions.
    def bad(node, msg, word: nil, from: nil)
      loc = node.location
      near = word && from ? Suggest.nearest_n(word, from) : []
      msg = "#{msg}; did you mean #{near.map { |n| "`#{n}`" }.join(" or ")}?" unless near.empty?
      raise CompileError.new("#{AxumDsl.file_of(node) || @path}:#{loc.start_line}:#{loc.start_column + 1}: #{msg}", suggestions: near)
    end
  end

  # The file each parse came from, for the files `use_dsl` splices in. A Prism node knows its parse's Source
  # object but no path, so the reader registers each parse here ([shown path, absolute path]) and an error or a
  # notice on any node, however late it is raised, names that node's own file. Reset for each compile.
  SOURCE_FILES = {}.compare_by_identity

  def self.register_source(program, shown, real) = SOURCE_FILES[program.location.send(:source)] = [shown, real]
  def self.file_of(node) = SOURCE_FILES[node.location.send(:source)]&.first
  def self.real_file_of(node) = SOURCE_FILES[node.location.send(:source)]&.last

  # A path as the registry and the language server compare it: resolved when it exists, absolute when it does
  # not (an editor buffer not yet saved).
  def self.canon(path) = File.exist?(path) ? File.realpath(path) : File.expand_path(path)

  RUST_ESC = { "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\x00" => "\\0" }.freeze

  # Escape order matters: callers double `{`/`}` AFTER esc, and esc never emits braces.
  def self.esc(str) = str.gsub(/[\\"\n\r\t\x00]/, RUST_ESC)
  def self.rstr(str) = "\"#{esc(str)}\""

  # A Rust char literal for one character (used by tr and delete).
  def self.rchar(chr)
    return "'\\''" if chr == "'"

    chr.ord.between?(0x20, 0x7e) ? "'#{chr}'" : format("'\\u{%x}'", chr.ord)
  end

  # The notes accumulate in the module across compiles; a long-lived process (the language server) compiles
  # many times, so every compile starts from an empty set. `check` and `build` read once and report, so this
  # is invisible to them.
  def self.read(path, types: nil)
    Notify.reset!
    Reader.new(path, types: types).read
  end

  # A short content digest, for a notice that names which bytes of an input a build read: a driver can
  # compare it against a buffer to tell whether the build used stale disk text.
  def self.short_digest(text) = Digest::SHA256.hexdigest(text)[0, 12]
end

require_relative "axum_dsl/suggest"
require_relative "axum_dsl/schema"
require_relative "axum_dsl/notify"
require_relative "axum_dsl/regex_translate"
require_relative "axum_dsl/bindings"
require_relative "axum_dsl/composite_types"
require_relative "axum_dsl/type_names"
require_relative "axum_dsl/json_literal"
require_relative "axum_dsl/views"
require_relative "axum_dsl/db"
require_relative "axum_dsl/cookies"
require_relative "axum_dsl/sessions"
require_relative "axum_dsl/csrf"
require_relative "axum_dsl/sanitize"
require_relative "axum_dsl/body"
require_relative "axum_dsl/cargo_build"
require_relative "axum_dsl/manifest"
require_relative "axum_dsl/rbi"
require_relative "axum_dsl/reader"
require_relative "axum_dsl/emit"

# The doc sentences and the generated skill read the compiler's tables (SIG, TYPES, Body::ALLOWED_METHODS,
# Notify::CODES and the shim catalog), so a reference page cannot drift from the compiler.
require_relative "axum_dsl/docs"
require_relative "axum_dsl/skill"
require_relative "axum_dsl/lsp"

require_relative "axum_dsl/openapi"

require_relative "axum_dsl/dev"

# Later waves add their requires here.
