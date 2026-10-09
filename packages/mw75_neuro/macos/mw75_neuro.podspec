Pod::Spec.new do |s|
  s.name             = 'mw75_neuro'
  s.version          = '0.1.0'
  s.summary          = 'Neurable MW75 Neuro RFCOMM transport for macOS.'
  s.homepage         = 'https://example.invalid/mw75_neuro'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Anarghya Das' => 'anarghya@buffalo.edu' }
  s.source           = { :path => '.' }
  s.source_files     = 'mw75_neuro/Sources/mw75_neuro/**/*.swift'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'IOBluetooth', 'CoreBluetooth'
  s.platform         = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
