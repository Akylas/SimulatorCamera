Pod::Spec.new do |s|
  s.name = 'SimulatorCameraClient'
  s.version = '1.0.0'
  s.license = 'MIT'
  s.summary = 'Camera for iOS Simulator'
  s.homepage = 'https://github.com/farfromrefug/SimulatorCamera'
  s.authors = { 'Ruslan Dautov' => 'dautov2@gmail.com', 'Martin Guillon' => 'dev@akylas.fr' }
  s.source = { :git => 'https://github.com/farfromrefug/SimulatorCamera.git', :tag => s.version }
  s.documentation_url = 'https://github.com/farfromrefug/SimulatorCamera'
  s.ios.deployment_target = '12.0'
  s.source_files = 'Sources/SimulatorCameraClient/*.swift'
  s.requires_arc = true
  s.swift_version = '5.0'
end
