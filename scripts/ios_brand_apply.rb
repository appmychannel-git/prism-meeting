#!/usr/bin/env ruby
# ============================================================================
#  iOS 브랜드 빌드용: Runner.xcodeproj / Info.plist / entitlements 를 해당 브랜드로 변형.
#  build_ios_brand.sh 가 호출한다. 빌드 후 `git checkout -- ios/` 로 원복(prism 기준).
#
#  사용법: ruby scripts/ios_brand_apply.rb <brand> <bundleId> "<displayName>" <withExtension:0|1> <scheme>
#    - withExtension=1 : 화면공유 Broadcast Extension 유지(현재 prism 만)
#    - withExtension=0 : 확장 제거(브랜드 앱 — 화면공유 송출 보류, 수신은 됨)
#    - scheme          : 커스텀 URL 스킴(딥링크). 브랜드마다 달라야 앱 충돌 없음(예: gbledmeeting)
# ============================================================================
require 'xcodeproj'

brand    = ARGV[0]
bundleId = ARGV[1]
display  = ARGV[2]
withExt  = ARGV[3] == '1'
scheme   = ARGV[4] # nil 이면 스킴 변경 안 함

proj = 'ios/Runner.xcodeproj'
p = Xcodeproj::Project.open(proj)

runner = p.targets.find { |t| t.name == 'Runner' }
tests  = p.targets.find { |t| t.name == 'RunnerTests' }
ext    = p.targets.find { |t| t.name == 'BroadcastExtension' }

# 1) 번들 ID
runner.build_configurations.each { |c| c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundleId }
tests&.build_configurations&.each { |c| c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{bundleId}.RunnerTests" }

unless withExt
  # 2) 확장 제거: 임베드 단계 + 의존성 + 타깃 자체
  if ext
    # Runner 의 embed(PlugIns) 카피 단계에서 appex 제거
    runner.copy_files_build_phases.each do |ph|
      next unless ph.symbol_dst_subfolder_spec == :plug_ins
      ph.files.dup.each do |bf|
        ph.remove_build_file(bf) if bf.display_name.to_s.include?('BroadcastExtension')
      end
    end
    # 의존성 제거
    runner.dependencies.dup.each do |d|
      d.remove_from_project if d.target == ext
    end
    # 타깃/프로덕트 제거
    ext.product_reference&.remove_from_project
    ext.remove_from_project
  end

  # 3) Runner entitlements 에서 App Group 제거(확장 없으니 불필요). aps-environment/associated-domains 는 유지.
  ent = 'ios/Runner/Runner.entitlements'
  if File.exist?(ent)
    xml = File.read(ent)
    # com.apple.security.application-groups <key>...</key><array>...</array> 블록 제거
    xml = xml.sub(%r{\s*<key>com\.apple\.security\.application-groups</key>\s*<array>.*?</array>}m, '')
    File.write(ent, xml)
  end

  # 4) Info.plist 에서 RTC 화면공유 키 제거
  info = 'ios/Runner/Info.plist'
  ixml = File.read(info)
  ixml = ixml.sub(%r{\s*<key>RTCAppGroupIdentifier</key>\s*<string>.*?</string>}m, '')
  ixml = ixml.sub(%r{\s*<key>RTCScreenSharingExtension</key>\s*<string>.*?</string>}m, '')
  File.write(info, ixml)
end

# 5) 표시 이름(CFBundleDisplayName) + 커스텀 URL 스킴(브랜드별)
info = 'ios/Runner/Info.plist'
ixml = File.read(info)
if ixml =~ %r{<key>CFBundleDisplayName</key>\s*<string>.*?</string>}m
  ixml = ixml.sub(%r{(<key>CFBundleDisplayName</key>\s*<string>).*?(</string>)}m, "\\1#{display}\\2")
end
if scheme && !scheme.empty?
  # CFBundleURLSchemes 의 스킴 문자열(prismmeeting)을 브랜드 스킴으로 교체
  ixml = ixml.sub(%r{(<key>CFBundleURLSchemes</key>\s*<array>\s*<string>).*?(</string>)}m, "\\1#{scheme}\\2")
  # CFBundleURLName 을 번들 ID 로
  ixml = ixml.sub(%r{(<key>CFBundleURLName</key>\s*<string>).*?(</string>)}m, "\\1#{bundleId}\\2")
end
File.write(info, ixml)

p.save
puts "[ios_brand_apply] brand=#{brand} bundle=#{bundleId} name=#{display} ext=#{withExt}"
