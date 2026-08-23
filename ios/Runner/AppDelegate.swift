import Flutter
import UIKit
import PushKit
import CallKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // VoIP(PushKit) 등록 — 꺼진 앱도 통화 푸시로 깨워 CallKit 을 띄우기 위함.
    let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [PKPushType.voIP]
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
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
