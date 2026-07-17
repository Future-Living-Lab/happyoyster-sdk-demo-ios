Pod::Spec.new do |s|
  s.name     = 'HappyOysterSDK'
  s.version = '1.0.3'
  s.summary  = 'Happy Oyster iOS SDK.'
  s.description = 'Happy Oyster iOS SDK for real-time interactive video experiences.'
  s.homepage = 'https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios'
  s.license  = { :type => 'Proprietary', :file => 'LICENSE' }
  s.authors  = { 'Happy Oyster' => 'HappyOyster@service.alibaba.com' }

  s.source = {
    :http => "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/#{s.version}/HappyOysterSDK-xcframeworks.zip",
    :sha256 => '10d9848020591ee19d21c2efb56d245590dc80bd47b994f24dc09c8fbbc11d73'
  }

  s.platform = :ios, '15.0'
  s.swift_version = '5.9'

  s.cocoapods_version = '>= 1.12.0'

  s.requires_arc = true

  s.static_framework = true

  s.default_subspecs = ['SDK']

  s.subspec 'Core' do |core|
    core.vendored_frameworks = 'HappyOysterCore.xcframework'
  end

  s.subspec 'World' do |world|
    world.vendored_frameworks = 'HappyOysterWorld.xcframework'
    world.dependency 'HappyOysterSDK/Core'
  end

  s.subspec 'Stream' do |stream|
    stream.vendored_frameworks = 'HappyOysterStream.xcframework'
    stream.dependency 'HappyOysterSDK/Core'
    stream.dependency 'HappyOysterSDK/World'
  end

  s.subspec 'SDK' do |sdk|
    sdk.vendored_frameworks = 'HappyOysterSDK.xcframework'
    sdk.dependency 'HappyOysterSDK/Core'
    sdk.dependency 'HappyOysterSDK/World'
    sdk.dependency 'HappyOysterSDK/Stream'
  end

  s.subspec 'StreamAliRTC' do |alirtc|
    alirtc.vendored_frameworks = 'HappyOysterStreamAliRTC.xcframework'
    alirtc.dependency 'HappyOysterSDK/Core'
    alirtc.dependency 'HappyOysterSDK/World'
    alirtc.dependency 'HappyOysterSDK/Stream'
    alirtc.dependency 'AliVCSDK_ARTC', '>= 7.10.0'
  end

  s.subspec 'UI' do |ui|
    ui.vendored_frameworks = 'HappyOysterUI.xcframework'
    ui.dependency 'HappyOysterSDK/Core'
    ui.dependency 'HappyOysterSDK/World'
  end

end
