cask "camdeck" do
  version "0.2.0"
  sha256 "64a0063ea66b11bb4fb36d54a1b6fea9a60f2898fa69b5b78711c72b26661f52"

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
