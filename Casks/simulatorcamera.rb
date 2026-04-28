cask "simulatorcamera" do
  version "0.2.0"
  if Hardware::CPU.arm?
    sha256 "ARM64_SHA256"
    url "https://github.com/Akylas/SimulatorCamera/releases/download/v#{version}/SimulatorCamera-#{version}-arm64.dmg"
  else
    sha256 "X86_64_SHA256"
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
