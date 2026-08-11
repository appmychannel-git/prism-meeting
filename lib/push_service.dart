import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'dart:async';

import 'app_settings.dart';
import 'auth_service.dart';
import 'block_store.dart';
import 'call_signaling.dart';
import 'cctv_share_screen.dart';
import 'config.dart';
import 'device_id.dart';
import 'directory.dart';
import 'friends.dart';
import 'incoming_call_screen.dart';

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
    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin
        .initialize(settings: const InitializationSettings(android: androidInit));
    // 백그라운드 isolate 에도 채널이 있어야 하므로 멱등 생성.
    const channel = AndroidNotificationChannel(
      kCallChannelId,
      '수신 전화',
      description: '친구의 음성·영상 통화 수신 알림',
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
      '수신 전화',
      channelDescription: '친구의 음성·영상 통화 수신 알림',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true, // 잠금화면 위로 통화 UI 실행(권한 허용 시)
      ongoing: true,
      autoCancel: false,
      ticker: '수신 전화',
      visibility: NotificationVisibility.public,
      sound: kCallSound, // 커스텀 벨소리
      // FLAG_INSISTENT(4): 풀스크린 권한이 없어도 알림이 뜨는 동안 소리를 반복(계속 벨).
      additionalFlags: Int32List.fromList(<int>[4]),
    );
    await plugin.show(
      id: kIncomingCallNotifId,
      title: fromName.isNotEmpty ? fromName : '전화',
      body: video ? '영상통화 수신' : '음성통화 수신',
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
    // 대기모드에서 CCTV 송출을 시작하도록 풀스크린 알림으로 앱을 깨운다.
    await showCctvWakeNotification();
  }
}

/// CCTV 원격 켜기 풀스크린 알림 — 잠금/대기화면 위로 앱을 실행해 송출 시작.
Future<void> showCctvWakeNotification() async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin
        .initialize(settings: const InitializationSettings(android: androidInit));
    const channel = AndroidNotificationChannel(
      kCallChannelId,
      '수신 전화',
      importance: Importance.max,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    const details = AndroidNotificationDetails(
      kCallChannelId,
      '수신 전화',
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
      body: 'CCTV 송출을 시작합니다',
      notificationDetails: const NotificationDetails(android: details),
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
    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin
        .initialize(settings: const InitializationSettings(android: androidInit));
    const channel = AndroidNotificationChannel(
      'cctv_live',
      'CCTV 송출',
      importance: Importance.low,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    final details = AndroidNotificationDetails(
      'cctv_live',
      'CCTV 송출',
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
      title: '● CCTV 송출 중',
      body: '시청자 $viewers명 · 카메라가 켜져 있습니다',
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
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await _createCallChannel(); // 수신벨용 고importance 채널(백그라운드 헤드업+소리)
      await _setupLocalNotifRouting(); // 알림으로 앱 실행 시 라우팅(CCTV 원격 켜기)

      final msg = FirebaseMessaging.instance;
      await msg.requestPermission(); // Android 13+ 알림 권한 프롬프트 포함

      _myUuid = await DeviceId.uuid();
      // Firestore 접근 전에 우리 uuid 로 로그인(보안 규칙용). 실패해도 진행.
      await AuthService.ensureSignedIn(_myUuid!);
      await _registerDevice();
      msg.onTokenRefresh.listen((_) => _registerDevice());

      // presence: 앱이 떠 있는 동안 주기적으로 lastSeen 갱신 + 생명주기 관찰.
      WidgetsBinding.instance.addObserver(this);
      _startHeartbeat();

      // 재설치 후 로컬 친구목록이 비어도, 서버(내가 추가한 edge)에서 복구.
      try {
        final mine = await DirectoryService.myFriends(_myUuid!);
        await FriendStore.mergeAll(mine);
      } catch (_) {}

      // 끝났거나 오래된 통화 문서 정리(비용↓). 진행 중 통화는 안 건드림.
      try {
        await CallSignaling.sweepMyOldCalls(_myUuid!);
      } catch (_) {}

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

      _started = true;
    } catch (e) {
      debugPrint('[PushService] init skipped: $e');
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
      const channel = AndroidNotificationChannel(
        kCallChannelId,
        '수신 전화',
        description: '친구의 음성·영상 통화 수신 알림',
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
      // FCM 토큰: 클라이언트는 못 읽는 별도 컬렉션(서버 Admin만 읽음) → 토큰 탈취 방지.
      await db.collection('deviceTokens').doc(uuid).set({
        'fcmToken': token,
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
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) => _touch());
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
    if (state == AppLifecycleState.resumed) _touch();
  }

  /// 통화 시작/종료 시 통화중 상태 갱신(친구 목록의 "통화중" 표시용).
  Future<void> setInCall(bool value) async {
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
      const channel = AndroidNotificationChannel(
        'missed_calls',
        '부재중 전화',
        importance: Importance.defaultImportance,
      );
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
      const details = AndroidNotificationDetails(
        'missed_calls',
        '부재중 전화',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      await plugin.show(
        id: 2001,
        title: '부재중 전화',
        body: fromName.isNotEmpty ? fromName : '전화',
        notificationDetails: const NotificationDetails(android: details),
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
    nav.push(MaterialPageRoute(builder: (_) => const CctvShareScreen()));
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
