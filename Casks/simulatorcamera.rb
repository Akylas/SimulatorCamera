cask "simulatorcamera" do
  version "0.2.0"
  sha256 "REPLACE_WITH_ACTUAL_DMG_SHA256_ON_RELEASE"

  url "https://github.com/dautovri/SimulatorCamera/releases/download/v#{version}/SimulatorCamera-#{version}.dmg",
      verified: "github.com/dautovri/SimulatorCamera/"
  name "SimulatorCamera"
  desc "Stream a real Mac camera, video file, or screen region into the iOS Simulator"
  homepage "https://github.com/dautovri/SimulatorCamera"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "SimulatorCameraServer.app"

  zap trash: [
    "~/Library/Preferences/com.simulatorcamera.server.plist",
    "~/Library/Application Support/SimulatorCameraServer",
  ]
end
