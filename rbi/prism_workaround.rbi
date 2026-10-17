# typed: true
# prism 1.9.0 ships an RBI whose `Prism.lex_compat` returns Prism::LexCompat::Result, a constant its
# RBI never defines, and Sorbet loads gem RBIs once Gemfile.lock exists. This stub defines it so
# `srb tc` passes. Delete it when a newer prism fixes its RBI. (Written by hand, not by bin/gen_rbi.)
class Prism::LexCompat::Result < Prism::Result; end