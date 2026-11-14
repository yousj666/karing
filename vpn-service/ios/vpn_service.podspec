Pod::Spec.new do |s|
  s.name             = 'vpn_service'
  s.version          = '0.12.15'
  s.summary          = 'Vendored reconstruction of the vpn_service plugin (yousj-plus).'
  s.description      = 'Dart API surface reconstructed from the Karing app call sites; native side is a stub.'
  s.homepage         = 'https://github.com/yousj666/karing'
  s.license          = { :file => '../LICENSE.md' }
  s.author           = { 'yousj666' => 'hello@yousj.cc' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
end
