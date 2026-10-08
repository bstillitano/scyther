Pod::Spec.new do |s|
  s.name             = 'Scyther'
  s.version          = '4.9.0'
  s.summary          = 'Just like scyther, this menu helps you cut through bugs in your iOS app.'

  s.homepage         = 'https://github.com/bstillitano/Scyther'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Brandon Stillitano' => 'b.stillitano95@gmail.com' }
  s.source           = { :git => 'https://github.com/bstillitano/Scyther.git', :tag => s.version.to_s }

  # Matches Package.swift: iOS 16 and the Swift 6 language mode.
  s.ios.deployment_target = '16.0'
  s.swift_versions = ['6.0']

  # Swift only. `Sources/Scyther/**/*` also swept in the DocC catalog and the string
  # catalog as if they were source files.
  s.source_files = 'Sources/Scyther/**/*.swift'

  # A resource bundle rather than loose resources, because the toolkit reads everything
  # through `Bundle.module` — which CocoaPods synthesises for a pod that declares one, and
  # does not for a pod that declares plain `resources`. The old glob named only
  # `{gpx,xml}`, which left `Localizable.xcstrings` out entirely: every string in the menu
  # would have fallen back to its English key in all twelve languages.
  s.resource_bundles = { 'Scyther' => ['Sources/Scyther/Resources/**/*'] }

  # No dependencies. The SnapKit dependency declared here was left over from the UIKit
  # menu; no source file has imported it since the SwiftUI rewrite.
end
