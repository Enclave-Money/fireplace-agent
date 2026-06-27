# typed: false
# frozen_string_literal: true
#
# ============================================================================
# PLACEHOLDER — NOT FUNCTIONAL YET (spec §12)
# ============================================================================
# This is a stub Homebrew formula for the Fireplace Agent CLI. It does NOT work
# as written: the `url`/`sha256` point at a release artifact that does not exist
# yet, and the install path is illustrative. Do not `brew install` from this.
#
# The canonical install path today is the curl installer:
#     curl -fsSL https://get.fireplace.gg/install.sh | bash
#
# TODO before this formula is real:
#   [ ] Create the Homebrew tap repo:  fireplace/homebrew-tap
#       (so users can `brew install fireplace/tap/fireplace`).
#   [ ] Cut a versioned release tarball of THIS bundle (shim + bundle/) and host
#       it at a stable URL; set `url` + `sha256` to it (use `brew fetch`/`shasum -a 256`).
#   [ ] Decide the install strategy. Homebrew formulae should not pipe to bash.
#       Either:
#         (a) vendor a self-contained launcher that, on first run, provisions the
#             isolated ~/.fireplace venv + pinned Hermes (uv) — keeping the
#             HERMES_HOME isolation model intact; or
#         (b) declare a `depends_on "uv"` (and Python 3.11) and run the same
#             provisioning logic the curl installer uses, from `def install`.
#   [ ] Keep the pinned engine ref in sync with ../ENGINE_VERSION (v2026.6.19).
#   [ ] Add a `test do` block that asserts `fireplace --help` / version works and
#       that the shim exports HERMES_HOME (mirror test/smoke.sh invariants).
#   [ ] Verify ~/.local/bin vs Homebrew prefix PATH interaction so only one
#       `fireplace` shim wins.
# ============================================================================

class Fireplace < Formula
  desc "Fireplace Agent — terminal copilot for prediction markets (read-only by default)"
  homepage "https://fireplace.gg"

  # TODO: replace with the real release tarball URL + checksum once published.
  url "https://get.fireplace.gg/releases/fireplace-0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  version "0.1.0"
  license "MIT" # TODO: confirm license for the wrapper bundle.

  # The wrapper provisions an isolated uv venv with the pinned Hermes build.
  # TODO: enable once `def install` actually provisions it.
  # depends_on "uv"
  # depends_on "python@3.11"

  def install
    # TODO: real implementation. Placeholder raises so nobody ships this by mistake.
    odie <<~EOS
      The Fireplace Homebrew formula is a placeholder and is not functional yet.
      Install with:  curl -fsSL https://get.fireplace.gg/install.sh | bash
      Track the tap work in README.md (TODO: Homebrew tap).
    EOS
  end

  test do
    # TODO: assert the shim works and isolates HERMES_HOME, e.g.:
    #   assert_match "Fireplace", shell_output("#{bin}/fireplace --version")
    true
  end
end
