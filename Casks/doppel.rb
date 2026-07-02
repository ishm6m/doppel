# Homebrew Cask for Doppel. Canonical copy lives here; copy/point a tap repo
# (github.com/ishm6m/homebrew-doppel) at it so users can `brew install ishm6m/doppel/doppel`
# and `brew upgrade`. The release workflow prints the new version + sha256 to bump on each release.
cask "doppel" do
  version "0.1.1"
  sha256 "b0d1bc8413539b10977a0e5293b100c38c5fe79595cbeb718c5848e0b097f577"

  url "https://github.com/ishm6m/doppel/releases/download/v#{version}/Doppel.zip"
  name "Doppel"
  desc "100% offline duplicate & near-duplicate file finder"
  homepage "https://github.com/ishm6m/doppel"

  depends_on macos: :sonoma
  app "Doppel.app"

  caveats <<~EOS
    Doppel is open source and ad-hoc signed — it is NOT notarized (that needs a paid
    Apple Developer account). If macOS blocks the first launch, either install with
      brew install --cask --no-quarantine doppel
    or right-click Doppel.app in Finder and choose Open once to approve it.
  EOS
end
