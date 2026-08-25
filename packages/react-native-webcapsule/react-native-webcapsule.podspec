require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name = "react-native-webcapsule"
  s.version = package["version"]
  s.summary = "Signed offline web runtime for React Native"
  s.homepage = "https://github.com/JunDev76/webcapsule"
  s.license = { :type => "MIT", :file => "../../LICENSE" }
  s.author = "WebCapsule contributors"
  s.platform = :ios, "15.1"
  s.source = { :git => "https://github.com/JunDev76/webcapsule.git", :tag => s.version.to_s }
  s.source_files = "ios/Sources/WebCapsuleCore/**/*.swift"
  s.dependency "React-Core"
  s.frameworks = "WebKit"
  s.libraries = "z"
  s.user_target_xcconfig = {
    "OTHER_LDFLAGS" => "$(inherited) -Wl,-u,_WebCapsuleRegisterReactNativeModule"
  }
  s.swift_version = "5.9"
end
