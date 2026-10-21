import Flutter
import UIKit
import PushKit
import CallKit
import flutter_callkit_incoming
import KakaoSDKCommon
import KakaoSDKAuth
import KakaoSDKUser

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  // 카카오 네이티브 앱 키(viewplus 카카오앱). 브랜드가 여러 키로 나뉘면 Info.plist 로 뺀다.
  private let kakaoNativeAppKey = "bd28f3b76080e0b4d64865386a35319d"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 카카오 SDK 초기화(super 전).
    KakaoSDK.initSDK(appKey: kakaoNativeAppKey)

    // VoIP(PushKit) 등록 — 꺼진 앱도 통화 푸시로 깨워 CallKit 을 띄우기 위함.
    let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [PKPushType.voIP]

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // 강제종료 후 VoIP 콜드 런치에서도 CallKit 을 띄우려면, 푸시 수신 시점에
    // 플러그인 sharedInstance 가 준비돼 있어야 한다. implicit-engine 등록은 시점이
    // 늦어 nil 일 수 있으므로 여기서 미리(멱등) 등록한다.
    if SwiftFlutterCallkitIncomingPlugin.sharedInstance == nil,
       let registrar = self.registrar(forPlugin: "SwiftFlutterCallkitIncomingPlugin") {
      SwiftFlutterCallkitIncomingPlugin.register(with: registrar)
    }
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupKakaoChannel(engineBridge)
    setupFullscreenChannel(engineBridge)
  }

  // ── 카카오 로그인 채널(app/kakao) ──
  // Dart loginKakao() 계약: login → accessToken, 취소 → "cancelled", 실패 → "kakao".
  private func setupKakaoChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let reg = engineBridge.pluginRegistry.registrar(forPlugin: "AppKakaoChannel") else { return }
    let ch = FlutterMethodChannel(name: "app/kakao", binaryMessenger: reg.messenger())
    ch.setMethodCallHandler { call, result in
      guard call.method == "login" else { result(FlutterMethodNotImplemented); return }
      let done: (OAuthToken?, Error?) -> Void = { token, error in
        if let token = token { result(token.accessToken); return }
        if let e = error as? SdkError, case .ClientFailed(let reason, _) = e, reason == .Cancelled {
          result(FlutterError(code: "cancelled", message: "user cancelled", details: nil)); return
        }
        result(FlutterError(code: "kakao", message: error?.localizedDescription ?? "login failed", details: nil))
      }
      if UserApi.isKakaoTalkLoginAvailable() {
        UserApi.shared.loginWithKakaoTalk { token, error in
          // 톡 로그인 실패(취소 제외) → 카카오계정(웹)으로 폴백 — 안드로이드와 동일.
          if token == nil, let e = error as? SdkError, case .ClientFailed(let r, _) = e, r == .Cancelled {
            done(nil, error)
          } else if token == nil {
            UserApi.shared.loginWithKakaoAccount(completion: done)
          } else {
            done(token, nil)
          }
        }
      } else {
        UserApi.shared.loginWithKakaoAccount(completion: done)
      }
    }
  }

  // ── [등록하기]·업데이트 열기 채널(app/fullscreen) ──
  private func setupFullscreenChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let reg = engineBridge.pluginRegistry.registrar(forPlugin: "AppFullscreenChannel") else { return }
    let ch = FlutterMethodChannel(name: "app/fullscreen", binaryMessenger: reg.messenger())
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "openUrl":
        if let s = (call.arguments as? [String: Any])?["url"] as? String, let u = URL(string: s) {
          UIApplication.shared.open(u)
        }
        result(true)
      case "openStore":
        // App Store 등록 후 실제 앱 ID 로 교체: itms-apps://apps.apple.com/app/id<APP_ID>
        result(false)
      default:
        result(FlutterMethodNotImplemented)   // 안드로이드 전용 메서드(전체화면 알림 설정 등)
      }
    }
  }

  // VoIP 토큰 갱신 → 플러그인에 전달(=Dart 가 서버 deviceTokens 에 저장).
  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  // VoIP 푸시 수신(앱 종료/잠금/절전 포함) → 즉시 CallKit 통화 UI 표시(Apple 요구).
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    guard type == .voIP else { completion(); return }
    let p = payload.dictionaryPayload
    let id = p["id"] as? String ?? UUID().uuidString
    let nameCaller = p["nameCaller"] as? String ?? "전화"
    let handle = p["handle"] as? String ?? ""
    let isVideo = (p["isVideo"] as? Bool) ?? (p["video"] as? Bool) ?? false
    let room = p["room"] as? String ?? ""
    let fromUuid = p["fromUuid"] as? String ?? ""

    let data = flutter_callkit_incoming.Data(id: id, nameCaller: nameCaller, handle: handle, type: isVideo ? 1 : 0)
    data.appName = "Prism Meeting"
    data.supportsVideo = isVideo
    // Dart 수락 핸들러가 방으로 입장할 수 있도록 부가정보 전달.
    data.extra = [
      "callId": id,
      "room": room,
      "fromUuid": fromUuid,
      "fromName": nameCaller,
      "video": isVideo,
    ]
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true) {
      completion()
    }
  }
}
