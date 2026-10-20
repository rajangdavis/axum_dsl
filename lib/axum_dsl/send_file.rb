# frozen_string_literal: true

module AxumDsl
  # `send_file(path, content_type:)`: the response helper for a file named at run time (an Active Storage
  # blob, an upload the request chose). It reads the path when the request arrives, so the file need not be
  # declared beside the DSL file and is not copied into the crate; a path a request chooses is the
  # application's trust decision. The body language has no Result from a missing file: a read failure is a
  # plain 500, while a caller that wants a 404 checks the row first and answers 404 itself.
  #
  # The helper is only emitted as a call; this module carries the one Cargo feature it needs.
  module SendFile
    module_function

    def used?(ir) = ir["builtins"].to_a.include?("send_file")

    # tokio's `fs` feature enables `tokio::fs::read`, which the emitted helper awaits.
    def tokio_features(ir) = used?(ir) ? ", \"fs\"" : ""
  end
end
