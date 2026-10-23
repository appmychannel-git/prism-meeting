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

# 구글 iOS OAuth 클라이언트 ID(번들별로 다름 — GCP 프로젝트 800914840538 "viewplus").
# ".apps.googleusercontent.com" 앞부분만 적는다. 없는 브랜드는 iOS 구글 버튼이 숨겨진다.
GOOGLE_IOS = {
  'viewplus' => '800914840538-84imtcij272icat6n5eh0tbgqfo1v29m',
  'gbled'    => '800914840538-fbnmau61j0gk5qu8gog07466879pam18',
}.freeze
# 서버(웹) 클라이언트 ID — 전 브랜드 공용. id_token 의 aud 가 이 값이 되어야 서버 대조 통과.
# GIDServerClientID 로 Info.plist 에 넣는다(Dart serverClientId 와 동일값, 이게 더 확실).
GOOGLE_SERVER = '800914840538-k4ovs9na1rg7patpc2q85qk81dnagevv.apps.googleusercontent.com'
# 카카오 네이티브 앱 키 — 기본값(e553, viewplus)과 다른 브랜드만 여기서 override.
# (카카오앱 1개당 번들 5개 제한이라 viewplus/gbled 를 별도 카카오앱으로 분리)
KAKAO_KEY = {
  'gbled' => '6d61ca2ac4c26833b136abca29340bff',
}.freeze

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

# 6) 구글 로그인(iOS 클라이언트 ID — 번들별). 맵에 있으면 GIDClientID + 역순 URL 스킴 주입.
#    없으면 GIDClientID 부재 → iOS 에서 구글 버튼 자동 숨김(네이티브 크래시 방지).
if (gid = GOOGLE_IOS[brand])
  gx = File.read(info)
  unless gx.include?('<key>GIDClientID</key>')
    client = "#{gid}.apps.googleusercontent.com"
    rev    = "com.googleusercontent.apps.#{gid}"
    gx = gx.sub(%r{(<key>CFBundleURLTypes</key>)},
                "<key>GIDClientID</key>\n\t<string>#{client}</string>\n\t" \
                "<key>GIDServerClientID</key>\n\t<string>#{GOOGLE_SERVER}</string>\n\t\\1")
    gdict = "\n\t\t<dict>\n\t\t\t<key>CFBundleTypeRole</key>\n\t\t\t<string>Editor</string>" \
            "\n\t\t\t<key>CFBundleURLName</key>\n\t\t\t<string>google</string>" \
            "\n\t\t\t<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n\t\t\t\t<string>#{rev}</string>" \
            "\n\t\t\t</array>\n\t\t</dict>"
    gx = gx.sub(%r{(<key>CFBundleURLTypes</key>\s*<array>)}m, "\\1#{gdict}")
    File.write(info, gx)
  end
end

# 7) 카카오 키 — 기본(e553)과 다른 브랜드만 override(앱키 + kakao<key> 스킴 동시 교체).
if (kk = KAKAO_KEY[brand])
  kx = File.read(info)
  kx = kx.sub(%r{(<key>KAKAO_APP_KEY</key>\s*<string>).*?(</string>)}m, "\\1#{kk}\\2")
  kx = kx.sub(/kakao[0-9a-f]{32}/, "kakao#{kk}")
  File.write(info, kx)
end

p.save
puts "[ios_brand_apply] brand=#{brand} bundle=#{bundleId} name=#{display} ext=#{withExt} google=#{GOOGLE_IOS[brand] ? 'y' : 'n'}"
