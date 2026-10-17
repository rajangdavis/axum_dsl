# frozen_string_literal: true

module AxumDsl
  # The version of this gem: its own SemVer, which changes for DSL features and fixes, not when axum does.
  VERSION = "0.1.0"

  # The axum minor every generated service is built against, and the only one tested. Emit writes
  # `axum = "0.8"` into each Cargo.toml (caret: any 0.8.x), so a build never picks up a 0.9 the
  # end-to-end suites have not seen. `axum_dsl --version` prints this.
  AXUM_VERSION = "0.8"
end
