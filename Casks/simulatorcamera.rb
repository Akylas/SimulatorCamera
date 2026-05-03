cask "simulatorcamera" do
  version "1.0.1"
  if Hardware::CPU.arm?
    sha256 "625b2f7579d080baa95facbdc94b00d84b4b90a8e422a7ba9922150f8b8c344e"
    url "https://github.com/Akylas/SimulatorCamera/releases/download/v#{version}/SimulatorCamera-#{version}-arm64.dmg"
  else
    sha256 "a43836c7b45b42f4bcc1fd8b02aaff8a8862a2b129fdd13d77be40718e954b69"
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
