# Homebrew formula for grove.
#
# Activated with the first tagged release: set `url` to the release tarball and
# fill `sha256` (brew fetch --build-from-source ./Formula/grove.rb prints it).
# Typically lives in a tap repo (jlopez/homebrew-tap) but kept here for reference.
class Grove < Formula
  desc "Spawn parallel Claude Code agents in git worktrees, grouped in cmux"
  homepage "https://github.com/jlopez/grove"
  url "https://github.com/jlopez/grove/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  version "0.1.0"

  depends_on "jq"

  def install
    bin.install "bin/grove"
  end

  def caveats
    <<~EOS
      grove wires worktrunk + cmux + Claude Code together. Finish setup with:
        grove doctor   # check dependencies
        grove init     # optional: wt alias, cmux plugin, multi-account

      cmux.app and Claude Code are installed separately:
        https://cmux.dev   https://claude.com/claude-code
      worktrunk:  brew install worktrunk
    EOS
  end

  test do
    assert_match "grove v", shell_output("#{bin}/grove version")
  end
end
