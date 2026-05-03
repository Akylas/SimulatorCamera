cask "simulatorcamera" do
  version "1.0.0"
  if Hardware::CPU.arm?
    sha256 "16cdc6cbdddbb9dd412bab86c0b22ea9b103fa2636240d88b9d975c50564fde4"
    url "https://github.com/Akylas/SimulatorCamera/releases/download/v#{version}/SimulatorCamera-#{version}-arm64.dmg"
  else
    sha256 "e2a9ec1abc33749c62dfd1dde5950e08be7de2469c9326a9ef3c796cdfc224da"
    url "https://github.com/Akylas/SimulatorCamera/releases/download/v#{version}/SimulatorCamera-#{version}-x86_64.dmg"
  end

  name "SimulatorCamera"
  desc "Stream a real Mac camera, video file, or screen region into the iOS Simulator"
  homepage "https://github.com/Akylas/SimulatorCamera"

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
