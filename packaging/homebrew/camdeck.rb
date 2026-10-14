cask "camdeck" do
  version "0.1.2"
  sha256 "77a4f1ffc944ddf294782a6388a03ab54180cf435f016d0b93454b2025fd4592"

  url "https://github.com/thevrus/camdeck/releases/download/v#{version}/Camdeck.dmg"
  name "Camdeck"
  desc "Webcam controls: zoom, exposure, colour and presets"
  homepage "https://github.com/thevrus/camdeck"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe

  app "Camdeck.app"

  zap trash: [
    "~/Library/Application Support/Camdeck",
    "~/Library/Caches/app.camdeck",
    "~/Library/Preferences/app.camdeck.plist",
  ]
end
