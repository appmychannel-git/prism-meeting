import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// 웹 STT — 브라우저 SpeechRecognition(webkitSpeechRecognition) 직접 호출.
///
/// speech_to_text 의 웹 지원이 불안정해(초기화가 false 반환) 직접 구현한다.
/// [stt_mobile.dart] 와 동일한 공개 인터페이스.
class PlatformStt {
  JSObject? _rec;
  bool _listening = false;
  void Function()? _onEnd;
  void Function(String)? _onError;
  void Function(String text, bool isFinal)? _onResult;

  bool get isListening => _listening;

  JSFunction? get _ctor {
    final a = globalContext.getProperty<JSFunction?>('SpeechRecognition'.toJS);
    if (a != null) return a;
    return globalContext.getProperty<JSFunction?>(
      'webkitSpeechRecognition'.toJS,
    );
  }

  bool get isSupported => _ctor != null;

  Future<bool> initialize({
    void Function()? onEnd,
    void Function(String error)? onError,
  }) async {
    _onEnd = onEnd;
    _onError = onError;
    return isSupported;
  }

  void listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
  }) {
    final ctor = _ctor;
    if (ctor == null) return;
    _onResult = onResult;
    final rec = ctor.callAsConstructor<JSObject>();
    _rec = rec;
    // BCP-47 로 변환(ko_KR -> ko-KR)
    rec.setProperty('lang'.toJS, localeId.replaceAll('_', '-').toJS);
    rec.setProperty('continuous'.toJS, true.toJS);
    rec.setProperty('interimResults'.toJS, true.toJS);
    rec.setProperty('onresult'.toJS, ((JSObject e) => _handleResult(e)).toJS);
    rec.setProperty('onerror'.toJS, ((JSObject e) {
      final err = e.getProperty<JSString?>('error'.toJS)?.toDart ?? 'error';
      _onError?.call(err);
    }).toJS);
    rec.setProperty('onend'.toJS, ((JSObject e) {
      _listening = false;
      _onEnd?.call();
    }).toJS);
    try {
      rec.callMethod('start'.toJS);
      _listening = true;
    } catch (_) {
      _listening = false;
      _onError?.call('start-failed');
    }
  }

  void _handleResult(JSObject e) {
    final results = e.getProperty<JSObject?>('results'.toJS);
    if (results == null) return;
    final len = results.getProperty<JSNumber>('length'.toJS).toDartInt;
    final resultIndex =
        e.getProperty<JSNumber?>('resultIndex'.toJS)?.toDartInt ?? 0;
    var interim = '';
    var finalText = '';
    for (var i = resultIndex; i < len; i++) {
      final r = results.callMethod<JSObject>('item'.toJS, i.toJS);
      final isFinal = r.getProperty<JSBoolean>('isFinal'.toJS).toDart;
      final alt = r.callMethod<JSObject>('item'.toJS, 0.toJS);
      final transcript = alt.getProperty<JSString>('transcript'.toJS).toDart;
      if (isFinal) {
        finalText += transcript;
      } else {
        interim += transcript;
      }
    }
    if (finalText.trim().isNotEmpty) {
      _onResult?.call(finalText, true);
    } else if (interim.trim().isNotEmpty) {
      _onResult?.call(interim, false);
    }
  }

  Future<void> stop() async {
    final rec = _rec;
    if (rec != null) {
      try {
        rec.callMethod('stop'.toJS);
      } catch (_) {}
    }
    _listening = false;
  }
}
