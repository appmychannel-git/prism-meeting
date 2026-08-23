// 이 서비스는 위젯이 아닌 전역 NavigatorState 의 context 로 화면 전환하므로
// async 이후 context 사용은 의도된 안전 패턴이다.
// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'app_settings.dart';
import 'block_store.dart';
import 'call.dart';
import 'call_log.dart';
import 'call_signaling.dart';
import 'device_id.dart';
import 'friends.dart';
import 'l10n.dart';

/// iOS 전용 CallKit + VoIP(PushKit) 통화 수신.
///
/// iOS는 데이터 전용 FCM 으로는 꺼진 앱을 못 깨우므로(안드로이드와 다름),
/// VoIP 푸시로 앱을 깨워 시스템 통화 UI(CallKit)를 띄운다. 실제 VoIP 푸시 수신은
/// iOS 네이티브(AppDelegate PushKit)가 처리하고, 여기선 그 결과 이벤트(수락/거절)를
/// 받아 기존 통화 흐름(joinDmRoom / CallSignaling)으로 연결한다.
///
/// Android 는 기존 FCM 데이터 메시지 흐름을 그대로 쓰므로 이 서비스는 무동작.
class CallKitService {
  CallKitService._();
  static final CallKitService instance = CallKitService._();

  static bool get isSupported => !kIsWeb && Platform.isIOS;

  GlobalKey<NavigatorState>? _navKey;
  bool _started = false;
  final Set<String> _acceptedIds = <String>{}; // 수락 중복 처리 방지
  // 통화별 취소 감시 구독. 발신자가 취소/종료하면 CallKit 벨을 내려야 한다.
  final Map<String, StreamSubscription<CallDoc?>> _cancelWatchers = {};

  /// 앱 시작 시 1회 호출. CallKit 이벤트 리스너 등록.
  Future<void> init(GlobalKey<NavigatorState> navKey) async {
    if (!isSupported || _started) return;
    _started = true;
    _navKey = navKey;
    FlutterCallkitIncoming.onEvent.listen(_onEvent);
    // 콜드 스타트(CallKit 수락으로 앱이 켜진 경우) 대비: 활성 통화 확인.
    unawaited(_resumeActiveCall());
  }

  /// VoIP 푸시 토큰을 발급받아 서버가 읽는 deviceTokens 에 저장한다.
  /// (네이티브 AppDelegate 가 setDevicePushTokenVoIP 로 넣어둔 값을 조회.)
  Future<void> registerVoipToken(String uuid) async {
    if (!isSupported) return;
    try {
      final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      if (token == null || token.isEmpty) return;
      await FirebaseFirestore.instance.collection('deviceTokens').doc(uuid).set({
        'voipToken': token,
        'platform': 'ios',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[CallKit] registerVoipToken failed: $e');
    }
  }

  /// 포그라운드/Firestore 폴백에서 iOS 수신 통화를 CallKit 으로 표시한다.
  /// (VoIP 푸시가 늦거나 실패해도 앱이 떠 있으면 여기서 울림. id 로 중복 제거됨.)
  Future<void> showIncoming({
    required String callId,
    required String fromName,
    required String room,
    required bool video,
    required String fromUuid,
  }) async {
    if (!isSupported || callId.isEmpty || room.isEmpty) return;
    final params = CallKitParams(
      id: callId, // callId 는 Uuid v4 → CallKit UUID 로 그대로 사용
      nameCaller: fromName.isNotEmpty ? fromName : L.t('unnamed'),
      appName: 'Prism Meeting',
      handle: fromName,
      type: video ? 1 : 0,
      extra: <String, dynamic>{
        'callId': callId,
        'room': room,
        'fromUuid': fromUuid,
        'fromName': fromName,
        'video': video,
      },
      ios: const IOSParams(
        handleType: 'generic',
        supportsVideo: true,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
      ),
    );
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(params);
    } catch (e) {
      debugPrint('[CallKit] showIncoming failed: $e');
    }
  }

  // ── 내부 ────────────────────────────────────────────────────────────────

  Future<void> _onEvent(CallEvent? event) async {
    if (event == null) return;
    switch (event) {
      case CallEventActionDidUpdateDevicePushTokenVoip():
        // 토큰 갱신 → 다시 저장.
        final uuid = await DeviceId.uuid();
        await registerVoipToken(uuid);
        break;
      case CallEventActionCallIncoming(:final callKitParams):
        // 수신 표시됨 → 발신자가 취소/종료하면 벨을 내리도록 문서 감시 시작.
        _watchForCancel(_callIdOf(callKitParams));
        break;
      case CallEventActionCallAccept(:final callKitParams):
        _stopWatch(_callIdOf(callKitParams));
        await _accept(callKitParams);
        break;
      case CallEventActionCallDecline(:final callKitParams):
        final id = _callIdOf(callKitParams);
        _stopWatch(id);
        if (id.isNotEmpty) {
          try {
            await CallSignaling.setStatus(id, CallStatus.declined);
          } catch (_) {}
        }
        break;
      case CallEventActionCallEnded(:final callKitParams):
        _stopWatch(_callIdOf(callKitParams));
        break;
      case CallEventActionCallTimeout(:final id):
        _stopWatch(id);
        break;
      default:
        break;
    }
  }

  String _callIdOf(CallKitParams p) =>
      (p.extra?['callId'] ?? p.id ?? '').toString();

  /// 수신 통화 문서를 감시해, 발신자가 취소/종료(문서 삭제 포함)하면 CallKit 벨을 내린다.
  void _watchForCancel(String callId) {
    if (callId.isEmpty || _cancelWatchers.containsKey(callId)) return;
    _cancelWatchers[callId] = CallSignaling.watch(callId).listen((c) async {
      final callerEnded = c == null ||
          c.status == CallStatus.canceled ||
          c.status == CallStatus.ended ||
          c.status == CallStatus.declined;
      if (callerEnded) {
        _stopWatch(callId);
        try {
          await FlutterCallkitIncoming.endCall(callId);
        } catch (_) {}
      }
    }, onError: (_) {});
  }

  void _stopWatch(String callId) {
    _cancelWatchers.remove(callId)?.cancel();
  }

  Future<void> _accept(CallKitParams p) async {
    final extra = p.extra ?? const <String, dynamic>{};
    final callId = (extra['callId'] ?? p.id ?? '').toString();
    final room = (extra['room'] ?? '').toString();
    final fromUuid = (extra['fromUuid'] ?? '').toString();
    final fromName = (extra['fromName'] ?? p.nameCaller ?? '').toString();
    final video = extra['video'] == true || extra['video'] == 'true';
    if (callId.isEmpty || room.isEmpty) return;
    if (!_acceptedIds.add(callId)) return; // 이미 수락 처리한 통화면 무시

    // 차단/수락형 필터: 차단했거나(요구 시) 친구가 아니면 자동 거절.
    if (fromUuid.isNotEmpty && await BlockStore.isBlocked(fromUuid)) {
      await _safeDecline(callId);
      return;
    }
    if (AppSettings.requireAccept && fromUuid.isNotEmpty) {
      final ok = await FriendStore.isFriend(fromUuid);
      if (!ok) {
        await _safeDecline(callId);
        return;
      }
    }

    try {
      await CallSignaling.setStatus(callId, CallStatus.accepted);
    } catch (_) {}
    try {
      CallLog.add(CallLogEntry(
        peerUuid: fromUuid,
        peerName: fromName,
        type: CallType.incoming,
        video: video,
        ts: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (_) {}

    final uuid = await DeviceId.uuid();
    final nm = await DeviceId.name();
    final ctx = await _waitNavigatorContext();
    if (ctx == null) return;
    // ctx 는 위젯이 아닌 전역 NavigatorState 의 context 라 async 이후에도 유효.
    // CallKit 경로는 대체할 Flutter 화면(수신 화면)이 없다. replace 로 홈을 교체하면
    // 통화 종료 후 스택이 비어 검정화면이 되므로, 홈 위에 push 한다(종료 시 홈 복귀).
    await joinDmRoom(
      ctx,
      room: room,
      name: nm.isNotEmpty ? nm : L.t('guest'),
      uuid: uuid,
      video: video,
      peerName: fromName,
      replace: false,
    );
  }

  Future<void> _safeDecline(String callId) async {
    try {
      await CallSignaling.setStatus(callId, CallStatus.declined);
    } catch (_) {}
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}
  }

  /// 콜드 스타트로 이미 수락된 통화가 있으면 그 방으로 이어준다.
  Future<void> _resumeActiveCall() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      if (calls.isNotEmpty) {
        await _accept(calls.first);
      }
    } catch (e) {
      debugPrint('[CallKit] resumeActiveCall: $e');
    }
  }

  /// Navigator 준비를 최대 ~5초 대기(콜드 스타트 타이밍 보정).
  Future<BuildContext?> _waitNavigatorContext() async {
    for (var i = 0; i < 50; i++) {
      final ctx = _navKey?.currentContext;
      if (ctx != null) return ctx;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _navKey?.currentContext;
  }
}
