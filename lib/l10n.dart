import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// 앱 UI 다국어(로컬라이제이션).
///
/// 채팅·자막 "번역"과는 별개다. 이건 앱 고정 문구(참여하기·음소거 등)를
/// 언어별로 미리 준비해 통째로 바꾸는 것.
///
/// 사용: `L.t('join')`, 파라미터는 `L.t('room_title', {'room': r, 'count': '3'})`.
/// 언어 변경: `L.setLang('en')` → [localeNotifier] 로 앱 전체가 다시 그려짐.
///
/// 지금은 한국어(ko)·영어(en)만. 언어 추가는 [uiLanguages] 와 각 문자열에
/// 해당 코드 항목만 넣으면 된다(없으면 en→ko 순으로 폴백).
class L {
  /// 선택 가능한 UI 언어: 코드 -> 표시 이름(각 언어 고유 표기).
  static const Map<String, String> uiLanguages = {
    'ko': '한국어',
    'en': 'English',
  };

  /// 현재 UI 언어. 바뀌면 앱 전체가 rebuild.
  static final ValueNotifier<String> localeNotifier =
      ValueNotifier<String>(_defaultLang());

  static String get lang => localeNotifier.value;

  static void setLang(String code) {
    if (uiLanguages.containsKey(code)) localeNotifier.value = code;
  }

  static String _defaultLang() {
    final code = ui.PlatformDispatcher.instance.locale.languageCode
        .toLowerCase();
    return uiLanguages.containsKey(code) ? code : 'ko';
  }

  /// 키에 해당하는 현재 언어 문자열. 없으면 en→ko→키 순으로 폴백.
  /// [args] 가 있으면 `{name}` 형태 자리표시자를 치환한다.
  static String t(String key, [Map<String, String>? args]) {
    final m = _s[key];
    var out = m == null ? key : (m[lang] ?? m['en'] ?? m['ko'] ?? key);
    if (args != null) {
      args.forEach((k, v) => out = out.replaceAll('{$k}', v));
    }
    return out;
  }

  static const Map<String, Map<String, String>> _s = {
    // ── 공통 ──
    'ok': {'ko': '확인', 'en': 'OK'},
    'cancel': {'ko': '취소', 'en': 'Cancel'},
    'close': {'ko': '닫기', 'en': 'Close'},
    'skip': {'ko': '건너뛰기', 'en': 'Skip'},
    'random': {'ko': '랜덤', 'en': 'Random'},
    'end': {'ko': '종료', 'en': 'End'},
    'back': {'ko': '돌아가기', 'en': 'Go back'},
    'app_language': {'ko': '앱 언어', 'en': 'App language'},

    // ── 입장 화면 ──
    'tagline': {
      'ko': '소규모 화상회의 · 웹 / 모바일 / 디스플레이',
      'en': 'Small-group video meetings · Web / Mobile / Display',
    },
    'tab_join': {'ko': '참여하기', 'en': 'Join'},
    'tab_create': {'ko': '방 만들기', 'en': 'Create room'},
    'room_code': {'ko': '방 코드', 'en': 'Room code'},
    'room_code_hint': {'ko': '예: abc-defg-hij', 'en': 'e.g., abc-defg-hij'},
    'room_name_opt': {'ko': '방 이름 (선택)', 'en': 'Room name (optional)'},
    'room_name_hint': {
      'ko': '영문·숫자·- 만 (비우면 자동)',
      'en': 'Letters, numbers, - only (blank = auto)',
    },
    'private_room': {'ko': '비공개 방 (입장 코드)', 'en': 'Private room (entry code)'},
    'entry_code': {'ko': '입장 코드', 'en': 'Entry code'},
    'entry_code_hint6': {'ko': '숫자 6자리', 'en': '6 digits'},
    'entry_code_join': {
      'ko': '입장 코드 (비공개 방일 경우)',
      'en': 'Entry code (if private room)',
    },
    'entry_code_join_hint': {
      'ko': '공개 방이면 비워두세요',
      'en': 'Leave blank for public rooms',
    },
    'my_name_opt': {'ko': '내 이름 (선택)', 'en': 'My name (optional)'},
    'connecting': {'ko': '접속 중...', 'en': 'Connecting...'},
    'enter_meeting': {'ko': '회의 입장', 'en': 'Join meeting'},
    'create_enter': {'ko': '방 만들기 & 입장', 'en': 'Create & join'},
    'powered_by': {'ko': 'Powered by 마이채널', 'en': 'Powered by MyChannel'},
    'joining': {'ko': '회의에 입장하는 중...', 'en': 'Joining the meeting...'},
    'name_set': {'ko': '이름 설정', 'en': 'Set name'},
    'display_name': {'ko': '표시 이름', 'en': 'Display name'},
    'name_hint': {
      'ko': '회의에서 보일 이름 (예: 홍길동)',
      'en': 'Name shown in the meeting (e.g., John)',
    },
    'err_room_required': {'ko': '방 코드를 입력하세요.', 'en': 'Please enter a room code.'},
    'err_private_pin': {
      'ko': '비공개 방은 입장 코드를 입력하세요.',
      'en': 'A private room requires an entry code.',
    },
    'err_no_token': {
      'ko': '토큰 서버 주소가 설정되지 않았습니다. (LK_TOKEN_URL)',
      'en': 'Token server address is not set. (LK_TOKEN_URL)',
    },
    'err_permission': {
      'ko': '카메라/마이크 권한이 필요합니다. 설정에서 허용해주세요.',
      'en': 'Camera/mic permission is required. Please allow it in settings.',
    },
    'guest': {'ko': '게스트', 'en': 'Guest'},
    'conn_fail': {
      'ko': '토큰 서버에 연결할 수 없습니다',
      'en': "Can't reach the token server",
    },
    'http_fail': {'ko': '접속 실패', 'en': 'Connection failed'},
    'resp_invalid': {'ko': '서버 응답이 올바르지 않습니다', 'en': 'Invalid server response'},

    // ── 회의 화면: 이름/공통 ──
    'name_change': {'ko': '이름 변경', 'en': 'Change name'},
    'host_ended': {'ko': '호스트가 회의를 종료했습니다.', 'en': 'The host ended the meeting.'},
    'peer': {'ko': '상대', 'en': 'Guest'},
    'me_suffix': {'ko': '{name} (나)', 'en': '{name} (me)'},
    'my_screen': {'ko': '내 화면', 'en': 'My screen'},
    'screen_of': {'ko': '{name} 화면', 'en': "{name}'s screen"},
    'room_title': {'ko': '{room} · {count}명', 'en': '{room} · {count}'},

    // ── 회의 화면: 자막 ──
    'stt_unavailable': {
      'ko': '이 기기/브라우저에서 음성 인식을 사용할 수 없습니다.',
      'en': "Speech recognition isn't available on this device/browser.",
    },
    'caption_lang_title': {'ko': '자막 언어 (내 언어)', 'en': 'Caption language (my language)'},
    'caption_on': {'ko': '자막 켜기', 'en': 'Turn on captions'},
    'caption_off': {'ko': '자막 끄기', 'en': 'Turn off captions'},
    'caption_lang_menu': {'ko': '자막 언어: {lang}', 'en': 'Caption language: {lang}'},
    'cap_to_ptt': {'ko': '자막: 눌러 말하기로', 'en': 'Captions: push-to-talk'},
    'cap_to_cont': {'ko': '자막: 연속으로', 'en': 'Captions: continuous'},
    'caption_hint_on': {
      'ko': '자막 켜짐 — 내 음성이 자막으로 전송됩니다. 상대방도 자막을 켜야 서로 보이고, "자막 언어"는 내가 말하는 언어로 설정하세요.',
      'en': 'Captions on — your speech is sent as captions. Others must also turn on captions, and set "Caption language" to the language you speak.',
    },
    'caption_empty_hint': {
      'ko': '말하는 참가자도 자막을 켜야 자막이 표시됩니다.',
      'en': 'Captions appear only when the speaker also turns captions on.',
    },
    'transcript': {'ko': '자막 기록', 'en': 'Transcript'},

    // ── 메뉴 / 친구 · 통화 ──
    'menu': {'ko': '메뉴', 'en': 'Menu'},
    'menu_my_id': {'ko': '내 ID (QR)', 'en': 'My ID (QR)'},
    'menu_friends': {'ko': '친구', 'en': 'Friends'},
    'my_id_title': {'ko': '내 ID', 'en': 'My ID'},
    'my_id_desc': {
      'ko': '상대가 이 QR을 스캔하면 나를 친구로 추가하거나 전화할 수 있어요.',
      'en': 'Others can scan this QR to add you as a friend or call you.',
    },
    'my_id_name_hint': {'ko': '친구에게 보일 이름', 'en': 'Name shown to friends'},
    'friends_empty': {
      'ko': '아직 친구가 없습니다.\nQR을 스캔해 친구를 추가하세요.',
      'en': 'No friends yet.\nScan a QR to add a friend.',
    },
    'scan_qr': {'ko': 'QR 스캔', 'en': 'Scan QR'},
    'add_friend': {'ko': '친구 추가', 'en': 'Add friend'},
    'already_friend': {'ko': '이미 친구', 'en': 'Already a friend'},
    'friend_added': {'ko': '친구로 추가했습니다', 'en': 'Added as a friend'},
    'remove_friend': {'ko': '친구 삭제', 'en': 'Remove friend'},
    'call_voice': {'ko': '음성통화', 'en': 'Voice call'},
    'call_video': {'ko': '영상통화', 'en': 'Video call'},
    'scan_invalid': {'ko': '올바른 ID QR이 아닙니다.', 'en': 'Not a valid ID QR.'},
    'calling': {'ko': '전화 거는 중...', 'en': 'Calling...'},
    'unnamed': {'ko': '이름 없음', 'en': 'Unnamed'},

    // ── 통화(발신/수신) ──
    'incoming_voice': {'ko': '음성통화 수신', 'en': 'Incoming voice call'},
    'incoming_video': {'ko': '영상통화 수신', 'en': 'Incoming video call'},
    'call_accept': {'ko': '수락', 'en': 'Accept'},
    'call_decline': {'ko': '거절', 'en': 'Decline'},
    'call_cancel': {'ko': '취소', 'en': 'Cancel'},
    'call_calling': {'ko': '연결 중...', 'en': 'Ringing...'},
    'call_connecting': {'ko': '입장 중...', 'en': 'Connecting...'},
    'call_declined': {'ko': '상대가 통화를 거절했습니다.', 'en': 'Call was declined.'},
    'call_no_answer': {'ko': '응답이 없습니다.', 'en': 'No answer.'},
    'call_canceled_by_caller': {
      'ko': '통화가 취소되었습니다.',
      'en': 'The call was canceled.',
    },
    'call_failed': {'ko': '통화 연결에 실패했습니다', 'en': 'Failed to place the call'},
    'call_hangup': {'ko': '통화 종료', 'en': 'Hang up'},
    'call_ended': {'ko': '통화가 종료되었습니다.', 'en': 'Call ended.'},
    'my_id_need_name': {
      'ko': '먼저 아래에서 표시 이름을 입력하면\nQR이 생성됩니다.',
      'en': 'Enter a display name below\nto generate your QR.',
    },
    // ── 코드/링크 공유 · 친구 추천 ──
    'my_code': {'ko': '내 코드', 'en': 'My code'},
    'code_copied': {'ko': '코드를 복사했습니다', 'en': 'Code copied'},
    'copy': {'ko': '복사', 'en': 'Copy'},
    'share_my_link': {'ko': '내 ID 링크 공유', 'en': 'Share my ID link'},
    'add_by_code': {'ko': '코드로 추가', 'en': 'Add by code'},
    'code_hint': {'ko': '상대의 코드 입력 (예: ABC123)', 'en': "Enter their code (e.g. ABC123)"},
    'code_not_found': {
      'ko': '코드를 찾을 수 없습니다. 다시 확인하세요.',
      'en': 'Code not found. Please check it.',
    },
    'friend_suggestions': {'ko': '친구 추천 (나를 추가한 사람)', 'en': 'Suggestions (added you)'},
    'added_you': {'ko': '나를 친구추가함', 'en': 'Added you'},
    'from_gallery': {'ko': '갤러리에서 선택', 'en': 'Choose from gallery'},
    'qr_not_found': {
      'ko': '이미지에서 QR을 찾지 못했습니다.',
      'en': 'No QR code found in the image.',
    },

    // ── 회의 화면: 카메라/공유 ──
    'cam_switch_fail': {'ko': '카메라 전환 실패', 'en': 'Failed to switch camera'},
    'usb_camera': {'ko': 'USB 카메라', 'en': 'USB camera'},
    'camera_n': {'ko': '카메라 {n}', 'en': 'Camera {n}'},
    'share_mobile_unsupported': {
      'ko': '모바일 브라우저에서는 화면공유를 지원하지 않습니다. PC 브라우저나 앱을 사용하세요.',
      'en': "Screen sharing isn't supported on mobile browsers. Use a PC browser or the app.",
    },
    'capture_denied': {'ko': '화면 캡처 권한이 거부되었습니다.', 'en': 'Screen capture permission was denied.'},
    'share_bg_fail': {
      'ko': '화면공유용 백그라운드 실행을 시작할 수 없습니다.',
      'en': "Couldn't start the background service for screen sharing.",
    },
    'share_start_fail': {'ko': '화면공유를 시작할 수 없습니다', 'en': "Couldn't start screen sharing"},
    'share_notif_title': {'ko': '화면 공유 중', 'en': 'Sharing screen'},
    'share_notif_text': {
      'ko': 'Prism Meeting 이 화면을 공유하고 있습니다.',
      'en': 'Prism Meeting is sharing your screen.',
    },

    // ── 회의 화면: 종료/초대 ──
    'meeting_end': {'ko': '회의 종료', 'en': 'End meeting'},
    'meeting_end_confirm': {
      'ko': '회의를 종료하면 모든 참가자가 나가게 됩니다. 종료할까요?',
      'en': 'Ending the meeting removes all participants. End it?',
    },
    'invite_qr': {'ko': 'QR로 초대', 'en': 'Invite by QR'},
    'qr_fail': {
      'ko': 'QR 생성 실패\n아래 링크를 복사해 사용하세요',
      'en': 'QR generation failed\nCopy the link below instead',
    },
    'room_code_val': {'ko': '방 코드: {room}', 'en': 'Room code: {room}'},
    'entry_code_val': {'ko': '입장 코드: {pin}', 'en': 'Entry code: {pin}'},
    'qr_scan_hint': {
      'ko': '휴대폰으로 QR을 스캔하면 이 방으로 입장합니다.',
      'en': 'Scan the QR with a phone to join this room.',
    },
    'link_copied': {'ko': '초대 링크 복사됨', 'en': 'Invite link copied'},
    'copy_link': {'ko': '링크 복사', 'en': 'Copy link'},

    // ── 회의 화면: 상태/툴팁 ──
    'waiting': {'ko': '참가자를 기다리는 중...', 'en': 'Waiting for participants...'},
    'pinned_hint': {'ko': '고정됨 · 탭하여 해제', 'en': 'Pinned · tap to release'},
    'connecting_meeting': {'ko': '회의에 접속하는 중...', 'en': 'Connecting to the meeting...'},
    'tt_switch_cam': {'ko': '카메라 전환', 'en': 'Switch camera'},
    'tt_gallery': {'ko': '갤러리 뷰', 'en': 'Gallery view'},
    'tt_speaker': {'ko': '발표자 뷰', 'en': 'Speaker view'},
    'tt_invite': {'ko': '초대 (QR·링크)', 'en': 'Invite (QR/link)'},
    'tt_chat': {'ko': '채팅', 'en': 'Chat'},
    'tt_more': {'ko': '더보기', 'en': 'More'},
    'hide_video': {'ko': '화면 숨기기(저사양)', 'en': 'Hide video (low-end)'},
    'show_video': {'ko': '화면 다시 보기', 'en': 'Show video again'},
    'reconnecting': {'ko': '네트워크 재연결 중...', 'en': 'Reconnecting...'},
    'prev': {'ko': '이전', 'en': 'Prev'},
    'next': {'ko': '다음', 'en': 'Next'},

    // ── 회의 화면: 하단 컨트롤 ──
    'mic_mute': {'ko': '음소거', 'en': 'Mute'},
    'mic_unmute': {'ko': '해제', 'en': 'Unmute'},
    'cam_off': {'ko': '카메라 끄기', 'en': 'Camera off'},
    'cam_on': {'ko': '카메라 켜기', 'en': 'Camera on'},
    'share_stop': {'ko': '공유 중지', 'en': 'Stop sharing'},
    'share': {'ko': '화면 공유', 'en': 'Share screen'},
    'ptt_speaking': {'ko': '말하는 중', 'en': 'Speaking'},
    'ptt_talk': {'ko': '말하기', 'en': 'Talk'},
    'leave': {'ko': '나가기', 'en': 'Leave'},

    // ── 채팅 ──
    'chat': {'ko': '채팅', 'en': 'Chat'},
    'no_messages': {'ko': '아직 메시지가 없습니다.', 'en': 'No messages yet.'},
    'message_hint': {'ko': '메시지 입력...', 'en': 'Type a message...'},
    'send': {'ko': '보내기', 'en': 'Send'},
    'translate_off': {'ko': '사용 안 함', 'en': 'Off'},
    'translate_lang': {'ko': '번역 언어', 'en': 'Translation language'},
    'translating': {'ko': '번역 중...', 'en': 'Translating...'},
    'translation': {'ko': '번역', 'en': 'Translation'},
    'translate_fail': {'ko': '번역 실패', 'en': 'Translation failed'},
  };
}

/// UI 언어 선택 다이얼로그(현재 언어에 체크).
Future<void> showAppLanguagePicker(BuildContext context) async {
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(L.t('app_language')),
      children: [
        for (final e in L.uiLanguages.entries)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, e.key),
            child: Row(
              children: [
                Icon(
                  e.key == L.lang ? Icons.check_circle : Icons.circle_outlined,
                  size: 18,
                  color: e.key == L.lang ? const Color(0xFF4ADE80) : null,
                ),
                const SizedBox(width: 10),
                Text(e.value),
              ],
            ),
          ),
      ],
    ),
  );
  if (picked != null) L.setLang(picked);
}

/// 앱바/화면에 놓는 언어 선택 버튼(🌐 + 현재 언어명).
class AppLanguageButton extends StatelessWidget {
  const AppLanguageButton({super.key});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => showAppLanguagePicker(context),
      icon: const Icon(Icons.language, size: 18),
      label: Text(L.uiLanguages[L.lang] ?? L.lang),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white70,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
