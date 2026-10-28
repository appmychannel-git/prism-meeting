import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'dart:async';

import 'app_settings.dart';
import 'auth_service.dart';
import 'block_store.dart';
import 'call_signaling.dart';
import 'callkit_service.dart';
import 'cctv_share_screen.dart';
import 'cctv_store.dart';
import 'config.dart';
import 'device_id.dart';
import 'directory.dart';
import 'friends.dart';
import 'incoming_call_screen.dart';
import 'l10n.dart';

/// 앱 전역 Navigator 키. 백그라운드 알림 탭/수신 통화에서 화면 전환에 사용.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 수신 통화 풀스크린 알림 ID(한 번에 한 통화 → 고정 ID로 갱신/취소).
const int kIncomingCallNotifId = 1001;
const int kCctvWakeNotifId = 1002;
const int kCctvLiveNotifId = 1003;
// 커스텀 벨소리(res/raw/ring_classic)를 쓰려고 새 채널 ID로 만든다.
// (안드로이드는 채널 생성 후 사운드를 못 바꾸므로 기존 'incoming_calls' 대신 신규.)
const String kCallChannelId = 'incoming_calls_v2';
const RawResourceAndroidNotificationSound kCallSound =
    RawResourceAndroidNotificationSound('ring_classic');

/// 잠금화면 위로 뜨는 CATEGORY_CALL 풀스크린 통화 알림을 띄운다.
/// 백그라운드/종료 isolate 에서도 쓰이므로 top-level 로 둔다.
Future<void> showIncomingCallNotification({
  required String callId,
  required String fromName,
  required bool video,
}) async {
  try {
    await L.load(); // 백그라운드 isolate 에서도 사용자가 고른 언어로
    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin
        .initialize(settings: const InitializationSettings(android: androidInit));
    // 백그라운드 isolate 에도 채널이 있어야 하므로 멱등 생성.
    final channel = AndroidNotificationChannel(
      kCallChannelId,
      L.t('notif_call_channel'),
      description: L.t('notif_call_channel_desc'),
      importance: Importance.max,
      playSound: true,
      sound: kCallSound, // 커스텀 벨소리
    );
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    final details = AndroidNotificationDetails(
      kCallChannelId,
      L.t('notif_call_channel'),
      channelDescription: L.t('notif_call_channel_desc'),
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true, // 잠금화면 위로 통화 UI 실행(권한 허용 시)
      ongoing: true,
      autoCancel: false,
      ticker: L.t('notif_call_channel'),
      visibility: NotificationVisibility.public,
      sound: kCallSound, // 커스텀 벨소리
      // FLAG_INSISTENT(4): 풀스크린 권한이 없어도 알림이 뜨는 동안 소리를 반복(계속 벨).
      additionalFlags: Int32List.fromList(<int>[4]),
    );
    await plugin.show(
      id: kIncomingCallNotifId,
      title: fromName.isNotEmpty ? fromName : L.t('notif_call'),
      body: video ? L.t('incoming_video') : L.t('incoming_voice'),
      notificationDetails: NotificationDetails(android: details),
      payload: callId,
    );
  } catch (_) {}
}

/// 표시 중인 수신 통화 알림 제거(수락/거절/취소·화면 진입 시).
Future<void> cancelIncomingCallNotification() async {
  try {
    await FlutterLocalNotificationsPlugin().cancel(id: kIncomingCallNotifId);
  } catch (_) {}
}

/// FCM 백그라운드 수신 핸들러(별도 isolate). 반드시 top-level + vm:entry-point.
/// data-only 메시지가 오면 풀스크린 통화 알림을 직접 띄운다(잠금화면에서도 울림).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final d = message.data;
  final type = d['type'];
  if (type == 'incoming_call') {
    await showIncomingCallNotification(
      callId: (d['callId'] ?? '').toString(),
      fromName: (d['fromName'] ?? '').toString(),
      video: d['video'] == 'true' || d['video'] == true,
    );
  } else if (type == 'cctv_wake') {
    // 대기 플래그 기록(앱이 앞으로 오면 송출 화면으로 이동) + 풀스크린 알림으로 깨움.
    await CctvStore.setPendingWake();
    await showCctvWakeNotification();
  }
}

/// CCTV 원격 켜기 풀스크린 알림 — 잠금/대기화면 위로 앱을 실행해 송출 시작.
Future<void> showCctvWakeNotification() async {
  try {
    await L.load(); // 백그라운드 isolate 에서도 사용자가 고른 언어로
    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin
        .initialize(settings: const InitializationSettings(android: androidInit));
    final channel = AndroidNotificationChannel(
      kCallChannelId,
      L.t('notif_call_channel'),
      importance: Importance.max,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    final details = AndroidNotificationDetails(
      kCallChannelId,
      L.t('notif_call_channel'),
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
    );
    await plugin.show(
      id: kCctvWakeNotifId,
      title: 'CCTV',
      body: L.t('notif_cctv_start'),
      notificationDetails: NotificationDetails(android: details),
      payload: 'cctv_wake',
    );
  } catch (_) {}
}

Future<void> cancelCctvWakeNotification() async {
  try {
    await FlutterLocalNotificationsPlugin().cancel(id: kCctvWakeNotifId);
  } catch (_) {}
}

/// CCTV 송출 중 상시 알림(방송 중임을 사용자가 항상 인지하도록).
Future<void> showCctvLiveNotification(int viewers) async {
  try {
    await L.load(); // 백그라운드 isolate 에서도 사용자가 고른 언어로
    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin
        .initialize(settings: const InitializationSettings(android: androidInit));
    final channel = AndroidNotificationChannel(
      'cctv_live',
      L.t('notif_cctv_channel'),
      importance: Importance.low,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    final details = AndroidNotificationDetails(
      'cctv_live',
      L.t('notif_cctv_channel'),
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      color: const Color(0xFFE5484D),
      colorized: true,
    );
    await plugin.show(
      id: kCctvLiveNotifId,
      title: L.t('notif_cctv_live'),
      body: L.t('notif_cctv_live_body', {'n': '$viewers'}),
      notificationDetails: NotificationDetails(android: details),
    );
  } catch (_) {}
}

Future<void> cancelCctvLiveNotification() async {
  try {
    await FlutterLocalNotificationsPlugin().cancel(id: kCctvLiveNotifId);
  } catch (_) {}
}

/// FCM(수신벨) + 기기 등록(Firestore) 을 담당.
/// 회원 없이 기기 UUID 로 식별하며, 모바일(Android/iOS)에서만 동작.
class PushService with WidgetsBindingObserver {
  PushService._();
  static final PushService instance = PushService._();

  bool _started = false;
  String? _myUuid;
  Timer? _heartbeat;
  // presence 는 앱이 화면에 있거나 통화 중일 때만 갱신(홈으로 나가면 멈춤 — Firestore 쓰기 절감).
  bool _foreground = true;
  bool _inCall = false;

  /// 이미 처리(표시)한 통화 ID — 스트림/푸시 중복 표시 방지.
  final Set<String> _handled = <String>{};

  /// 통화 기능이 켜진 플랫폼에서만 Firebase/FCM 초기화.
  /// 실패해도(구성 누락 등) 예외를 삼켜 앱 실행을 막지 않는다.
  Future<void> initIfEnabled() async {
    if (_started) return;
    if (!AppConfig.supportsDeviceFeatures) return;
    if (!(AppConfig.callEnabled ||
        AppConfig.friendsEnabled ||
        AppConfig.cctvEnabled)) {
      return;
    }
    try {
      await Firebase.initializeApp();
      await _configureFirestore();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      // iOS: VoIP(PushKit)+CallKit 로 꺼진 앱에서도 수신 통화(안드로이드는 FCM 그대로).
      await CallKitService.instance.init(appNavigatorKey);
      await _createCallChannel(); // 수신벨용 고importance 채널(백그라운드 헤드업+소리)
      await _setupLocalNotifRouting(); // 알림으로 앱 실행 시 라우팅(CCTV 원격 켜기)

      final msg = FirebaseMessaging.instance;
      await msg.requestPermission(); // Android 13+ 알림 권한 프롬프트 포함

      _myUuid = await DeviceId.uuid();
      // Firestore 접근 전에 우리 uuid 로 로그인(보안 규칙용). 실패해도 진행.
      // 아래 Firestore 작업은 서버 응답을 기다리므로 제한시간을 둔다 — 멈춰도
      // 수신 통화 리스너 등 나머지 초기화는 계속되게.
      await _limit(AuthService.ensureSignedIn(_myUuid!));
      await _limit(_registerDevice());
      msg.onTokenRefresh.listen((_) => _registerDevice());
      // iOS VoIP 토큰도 서버가 읽는 deviceTokens 에 저장.
      await _limit(CallKitService.instance.registerVoipToken(_myUuid!));
      // 앱 시작 시엔 통화 중일 수 없다. 이전 세션이 강제종료/크래시로 통화중(inCall)
      // 상태를 못 내린 경우가 있으므로 여기서 확실히 해제(친구목록 "통화중" 잔상 제거).
      await _limit(setInCall(false));

      // presence: 앱이 떠 있는 동안 주기적으로 lastSeen 갱신 + 생명주기 관찰.
      WidgetsBinding.instance.addObserver(this);
      _syncHeartbeat();

      // 재설치 후 로컬 친구목록이 비어도, 서버(내가 추가한 edge)에서 복구.
      try {
        final mine = await DirectoryService.myFriends(_myUuid!)
            .timeout(const Duration(seconds: 8));
        await FriendStore.mergeAll(mine);
      } catch (_) {}

      // 끝났거나 오래된 통화 문서 정리(비용↓). 진행 중 통화는 안 건드림.
      // 기다릴 필요 없는 정리 작업이라 백그라운드로.
      unawaited(CallSignaling.sweepMyOldCalls(_myUuid!).catchError((_) {}));

      // 포그라운드 수신
      FirebaseMessaging.onMessage.listen(_onRemoteMessage);
      // 백그라운드에서 알림 탭으로 열림
      FirebaseMessaging.onMessageOpenedApp.listen(_onRemoteMessage);
      // 종료 상태에서 알림 탭으로 시작됨
      final initial = await msg.getInitialMessage();
      if (initial != null) {
        // 첫 프레임 이후 라우팅(Navigator 준비 대기)
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _onRemoteMessage(initial));
      }

      // 앱이 떠 있을 때의 1차 벨(Firestore) — 푸시가 늦거나 실패해도 울리게.
      // 싱글턴이라 앱 생명주기 동안 유지(별도 취소 없음).
      CallSignaling.incoming(_myUuid!).listen(_onIncomingDoc);

      // 콜드 스타트가 CCTV 원격 켜기로 시작됐으면 송출 화면으로(Navigator 준비 후).
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _checkPendingWake());
      // 초기화가 runApp 뒤 백그라운드라, 이미 그려진 화면이면 다음 프레임을 요청해
      // 위의 postFrame 콜백(알림으로 시작·원격 켜기 라우팅)이 실행되게 한다.
      WidgetsBinding.instance.scheduleFrame();

      _started = true;
    } catch (e) {
      debugPrint('[PushService] init skipped: $e');
    }
  }

  // 서버 응답을 기다리는 초기화 단계의 제한시간. 넘으면 기다리지 않고 다음으로
  // (작업 자체는 Firestore 가 계속 진행). 예외도 삼킨다.
  static Future<void> _limit(Future<void> f) =>
      f.timeout(const Duration(seconds: 8)).catchError((_) {});

  /// Firestore 설정: 오프라인 캐시(로컬 영속성) 끔 + 이전 캐시 1회 삭제.
  /// 이 앱은 오프라인 데이터가 필요 없다. TV 박스처럼 늘 켜진 기기에서
  /// 못 보낸 쓰기(heartbeat 등)가 캐시에 쌓이면 시작 때 FirestoreWorker 가
  /// CPU 100% 로 이를 처리하며 다른 요청을 막는 현상이 있었다(2026-10-23).
  /// 반드시 첫 Firestore 사용 전에 호출해야 한다.
  static const _kFsCacheCleared = 'fs_cache_cleared_v1';
  Future<void> _configureFirestore() async {
    final fs = FirebaseFirestore.instance;
    // 설정은 다른 어떤 호출보다 먼저(이후엔 바꿀 수 없음).
    try {
      fs.settings = const Settings(persistenceEnabled: false);
    } catch (e) {
      debugPrint('[PushService] firestore settings skipped: $e');
    }
    // 이전 버전이 남긴 디스크 캐시(쌓인 쓰기 포함)를 1회 삭제.
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getBool(_kFsCacheCleared) != true) {
        await fs.clearPersistence().timeout(const Duration(seconds: 5));
        await sp.setBool(_kFsCacheCleared, true);
      }
    } catch (e) {
      debugPrint('[PushService] clearPersistence skipped: $e');
    }
  }

  /// 알림 탭/풀스크린으로 앱이 열린 경우 라우팅(CCTV 원격 켜기).
  Future<void> _setupLocalNotifRouting() async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await plugin.initialize(
        settings: const InitializationSettings(android: androidInit),
        onDidReceiveNotificationResponse: (resp) {
          if (resp.payload == 'cctv_wake') _showCctvShare();
        },
      );
      // 종료 상태에서 CCTV 깨우기 알림으로 실행된 경우.
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true &&
          launch?.notificationResponse?.payload == 'cctv_wake') {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _showCctvShare());
      }
    } catch (e) {
      debugPrint('[PushService] notif routing setup failed: $e');
    }
  }

  /// 백그라운드/종료 상태에서 FCM notification 이 헤드업+소리로 뜨도록
  /// 고importance 알림 채널을 미리 만든다(서버 /call 이 이 채널로 보냄).
  Future<void> _createCallChannel() async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await plugin.initialize(
          settings: const InitializationSettings(android: androidInit));
      final channel = AndroidNotificationChannel(
        kCallChannelId,
        L.t('notif_call_channel'),
        description: L.t('notif_call_channel_desc'),
        importance: Importance.max,
        playSound: true,
        sound: kCallSound, // 커스텀 벨소리
      );
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
    } catch (e) {
      debugPrint('[PushService] createCallChannel failed: $e');
    }
  }

  /// 기기 등록/갱신: devices/{uuid} = { name, fcmToken, platform, updatedAt }.
  Future<void> _registerDevice() async {
    try {
      final uuid = _myUuid ?? await DeviceId.uuid();
      final name = await DeviceId.name();
      final token = await FirebaseMessaging.instance.getToken();
      final db = FirebaseFirestore.instance;
      // 프로필(이름/플랫폼): 친구에게 이름 표시용 → 인증 사용자면 조회 가능.
      await db.collection('devices').doc(uuid).set({
        'name': name,
        'platform': defaultTargetPlatform.name,
        'lastSeen': FieldValue.serverTimestamp(), // presence
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      // 번들 ID(=브랜드별로 다름). 서버가 iOS VoIP 토픽(<bundleId>.voip)을 이 값으로
      // 만든다 → 브랜드가 5개여도 서버 환경변수 변경 없이 각 기기에 맞는 토픽으로 전송.
      String? bundleId;
      try {
        bundleId = (await PackageInfo.fromPlatform()).packageName;
      } catch (_) {}
      // FCM 토큰: 클라이언트는 못 읽는 별도 컬렉션(서버 Admin만 읽음) → 토큰 탈취 방지.
      await db.collection('deviceTokens').doc(uuid).set({
        'fcmToken': token,
        if (bundleId != null && bundleId.isNotEmpty) 'bundleId': bundleId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[PushService] registerDevice failed: $e');
    }
  }

  /// 이름 변경 시 외부에서 호출(내 ID 화면에서 이름 편집 후).
  Future<void> refreshDevice() async {
    if (!_started) return;
    await _registerDevice();
  }

  // ── presence(온라인 표시) ──
  // 화면에 있거나 통화 중이면 3분마다 lastSeen 갱신, 아니면(홈/백그라운드) 멈춤.
  // 멈춘 기기는 최대 7분 뒤 친구 목록에서 오프라인으로 보인다(통화·원격 켜기는 FCM 이라 무관).
  // 45초였을 땐 상시 켜둔 TV 1대가 하루 1,920회 써서 Firestore 무료 한도(2만/일)에 닿았다.
  void _syncHeartbeat() {
    if (_foreground || _inCall) {
      _heartbeat ??=
          Timer.periodic(const Duration(minutes: 3), (_) => _touch());
    } else {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  Future<void> _touch() async {
    final uuid = _myUuid;
    if (uuid == null) return;
    try {
      await FirebaseFirestore.instance.collection('devices').doc(uuid).set(
        {'lastSeen': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _syncHeartbeat();
      _touch();
      _checkPendingWake(); // 백그라운드서 깨워졌으면 송출 화면으로 이동
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // inactive(다이얼로그·알림창 등 잠깐 가림)는 제외 — 앱이 아직 화면에 있다.
      _foreground = false;
      _syncHeartbeat();
    }
  }

  /// 원격 켜기 대기 플래그가 있으면 송출 화면으로 이동(중복은 active 로 방지).
  Future<void> _checkPendingWake() async {
    if (await CctvStore.consumePendingWake()) _showCctvShare();
  }

  /// 통화 시작/종료 시 통화중 상태 갱신(친구 목록의 "통화중" 표시용).
  Future<void> setInCall(bool value) async {
    _inCall = value;
    if (_started) _syncHeartbeat(); // 통화 중엔 홈에 나가 있어도 갱신 유지
    final uuid = _myUuid;
    if (uuid == null) return;
    try {
      await FirebaseFirestore.instance.collection('devices').doc(uuid).set(
        {'inCall': value, 'lastSeen': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  /// 부재중 전화 알림(로컬). 기본 채널로 1회 표시.
  Future<void> showMissedCall(String fromName) async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await plugin.initialize(
          settings: const InitializationSettings(android: androidInit));
      final channel = AndroidNotificationChannel(
        'missed_calls',
        L.t('notif_missed'),
        importance: Importance.defaultImportance,
      );
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
      final details = AndroidNotificationDetails(
        'missed_calls',
        L.t('notif_missed'),
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      await plugin.show(
        id: 2001,
        title: L.t('notif_missed'),
        body: fromName.isNotEmpty ? fromName : L.t('notif_call'),
        notificationDetails: NotificationDetails(android: details),
      );
    } catch (_) {}
  }

  void _onRemoteMessage(RemoteMessage m) {
    final d = m.data;
    if (d['type'] == 'cctv_wake') {
      _showCctvShare();
      return;
    }
    if (d['type'] != 'incoming_call') return;
    _showIncoming(
      callId: (d['callId'] ?? '').toString(),
      fromUuid: (d['fromUuid'] ?? '').toString(),
      fromName: (d['fromName'] ?? '').toString(),
      room: (d['room'] ?? '').toString(),
      video: d['video'] == 'true' || d['video'] == true,
    );
  }

  /// CCTV 원격 켜기 수신 → 송출 화면 열기(중복 방지).
  void _showCctvShare() {
    cancelCctvWakeNotification();
    if (CctvShareScreen.active) return; // 이미 송출 중이면 무시
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    // 같은 프레임에 여러 경로(콜드스타트/알림/대기플래그)가 동시에 호출해도
    // 두 번 열리지 않도록 push 직전에 즉시 플래그를 세운다(중복 연결 방지).
    CctvShareScreen.active = true;
    // 원격 켜기(FCM)는 사용자가 없으므로 비번 입력창을 띄우지 않고 저장된 비번으로 바로 송출.
    nav.push(MaterialPageRoute(
        builder: (_) => const CctvShareScreen(promptPassword: false)));
  }

  void _onIncomingDoc(CallDoc c) {
    _showIncoming(
      callId: c.callId,
      fromUuid: c.fromUuid,
      fromName: c.fromName,
      room: c.room,
      video: c.video,
    );
  }

  Future<void> _showIncoming({
    required String callId,
    required String fromUuid,
    required String fromName,
    required String room,
    required bool video,
  }) async {
    if (callId.isEmpty || room.isEmpty) return;
    if (_handled.contains(callId)) return; // 중복 방지
    _handled.add(callId);
    // 차단한 사람의 전화는 무조건 자동 거절.
    if (fromUuid.isNotEmpty && await BlockStore.isBlocked(fromUuid)) {
      await CallSignaling.setStatus(callId, CallStatus.declined);
      cancelIncomingCallNotification();
      return;
    }
    // 수락형 친구요청: 켜져 있으면 "내 친구가 아닌 사람"의 전화는 자동 거절.
    if (AppSettings.requireAccept && fromUuid.isNotEmpty) {
      final ok = await FriendStore.isFriend(fromUuid);
      if (!ok) {
        await CallSignaling.setStatus(callId, CallStatus.declined);
        cancelIncomingCallNotification();
        return;
      }
    }
    // iOS: 시스템 통화 UI(CallKit)로 표시. 꺼진 앱은 VoIP 푸시가, 포그라운드는 이 폴백이 담당.
    if (CallKitService.isSupported) {
      await CallKitService.instance.showIncoming(
        callId: callId,
        fromName: fromName,
        room: room,
        video: video,
        fromUuid: fromUuid,
      );
      return;
    }
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    cancelIncomingCallNotification(); // 풀스크린 알림이 떠 있었다면 정리
    nav.push(MaterialPageRoute(
      builder: (_) => IncomingCallScreen(
        callId: callId,
        fromUuid: fromUuid,
        fromName: fromName,
        room: room,
        video: video,
      ),
    ));
  }
}
