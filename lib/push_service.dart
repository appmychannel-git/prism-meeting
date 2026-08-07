import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'call_signaling.dart';
import 'config.dart';
import 'device_id.dart';
import 'incoming_call_screen.dart';

/// 앱 전역 Navigator 키. 백그라운드 알림 탭/수신 통화에서 화면 전환에 사용.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// FCM 백그라운드 수신 핸들러(별도 isolate). 반드시 top-level + vm:entry-point.
/// notification 페이로드는 시스템이 트레이에 표시하므로 여기선 할 일 없음.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // 백그라운드에서 UI를 띄우진 않는다(트레이 알림 탭 → onMessageOpenedApp 로 라우팅).
}

/// FCM(수신벨) + 기기 등록(Firestore) 을 담당.
/// 회원 없이 기기 UUID 로 식별하며, 모바일(Android/iOS)에서만 동작.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _started = false;
  String? _myUuid;

  /// 이미 처리(표시)한 통화 ID — 스트림/푸시 중복 표시 방지.
  final Set<String> _handled = <String>{};

  /// 통화 기능이 켜진 플랫폼에서만 Firebase/FCM 초기화.
  /// 실패해도(구성 누락 등) 예외를 삼켜 앱 실행을 막지 않는다.
  Future<void> initIfEnabled() async {
    if (_started) return;
    if (!AppConfig.supportsDeviceFeatures) return;
    if (!(AppConfig.callEnabled || AppConfig.friendsEnabled)) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      final msg = FirebaseMessaging.instance;
      await msg.requestPermission(); // Android 13+ 알림 권한 프롬프트 포함

      _myUuid = await DeviceId.uuid();
      await _registerDevice();
      msg.onTokenRefresh.listen((_) => _registerDevice());

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

  /// 기기 등록/갱신: devices/{uuid} = { name, fcmToken, platform, updatedAt }.
  Future<void> _registerDevice() async {
    try {
      final uuid = _myUuid ?? await DeviceId.uuid();
      final name = await DeviceId.name();
      final token = await FirebaseMessaging.instance.getToken();
      await FirebaseFirestore.instance.collection('devices').doc(uuid).set({
        'name': name,
        'fcmToken': token,
        'platform': defaultTargetPlatform.name,
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

  void _onRemoteMessage(RemoteMessage m) {
    final d = m.data;
    if (d['type'] != 'incoming_call') return;
    _showIncoming(
      callId: (d['callId'] ?? '').toString(),
      fromName: (d['fromName'] ?? '').toString(),
      room: (d['room'] ?? '').toString(),
      video: d['video'] == 'true' || d['video'] == true,
    );
  }

  void _onIncomingDoc(CallDoc c) {
    _showIncoming(
      callId: c.callId,
      fromName: c.fromName,
      room: c.room,
      video: c.video,
    );
  }

  void _showIncoming({
    required String callId,
    required String fromName,
    required String room,
    required bool video,
  }) {
    if (callId.isEmpty || room.isEmpty) return;
    if (_handled.contains(callId)) return; // 중복 방지
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    _handled.add(callId);
    nav.push(MaterialPageRoute(
      builder: (_) => IncomingCallScreen(
        callId: callId,
        fromName: fromName,
        room: room,
        video: video,
      ),
    ));
  }
}
