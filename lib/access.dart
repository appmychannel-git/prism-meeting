import 'package:flutter/foundation.dart';

/// 기능 권한 티어 — 로그인 + 기기시리얼 인증(registered) 여부로 결정한다.
///
/// - [full]    : 시리얼 인증된(계정에 등록된 TV 시리얼이 하나라도 있는) 로그인 사용자
///               → 미팅·CCTV 모든 기능.
/// - [limited] : 미로그인 또는 미인증(시리얼 없음) 사용자
///               → 방 참여 / CCTV 코드추가·시청만. (방 생성·친구·통화·CCTV 송출 불가)
enum AccessLevel { full, limited }

/// 앱 전역 접근 권한. [StoreLoginGate]가 기동/세션변경 때 [set]으로 갱신하고,
/// UI는 [levelListenable]을 구독해 제한 기능을 숨기거나 막는다.
///
/// 판정원:
///  - TV(마켓앱): ContentProvider `registered`(계정 단위 시리얼 등록 여부).
///  - 모바일(viewplus 자체 로그인): 서버 `registration.registered` (Phase 2).
///  - 둘 다 아니면(미로그인/마켓 없음) → [limited].
class Access {
  Access._();

  static final ValueNotifier<AccessLevel> _level =
      ValueNotifier<AccessLevel>(AccessLevel.limited);

  /// UI 구독용(ValueListenableBuilder).
  static ValueListenable<AccessLevel> get levelListenable => _level;

  static AccessLevel get level => _level.value;
  static bool get isFull => _level.value == AccessLevel.full;
  static bool get isLimited => !isFull;

  static void set(AccessLevel l) {
    if (_level.value != l) _level.value = l;
  }

  // ── 티어별 기능 게이트 ──
  // (브랜드 플래그 friendsEnabled/callEnabled/cctvEnabled 와 AND 로 함께 쓴다.
  //  여기선 "로그인·인증 티어" 만 판단한다.)

  /// 미팅 방 "만들기"(참여는 티어 무관 항상 허용).
  static bool get canCreateRoom => isFull;

  /// 친구 목록/추가.
  static bool get canUseFriends => isFull;

  /// 음성·영상 통화.
  static bool get canCall => isFull;

  /// CCTV 송출(이 기기 공유)·대기 중 원격 켜기. (시청·코드추가는 항상 허용)
  static bool get canShareCctv => isFull;
}
