import Flutter
import UIKit
import KakaoSDKAuth

class SceneDelegate: FlutterSceneDelegate {
  // 카카오톡 앱에서 로그인 후 돌아오는 URL 을 가로채 SDK 에 넘긴다.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url, AuthApi.isKakaoTalkLoginUrl(url) {
      _ = AuthController.handleOpenUrl(url: url)
      return
    }
    super.scene(scene, openURLContexts: URLContexts)   // 딥링크(prismmeeting://) 등 기존 처리 유지
  }
}
