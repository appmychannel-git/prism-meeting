import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';

/// 모바일/데스크톱 STT — speech_to_text 래퍼.
///
/// [stt_platform.dart] 의 조건부 export 로 웹이 아닐 때 이 구현이 쓰인다.
/// 웹 구현([stt_web.dart])과 동일한 공개 인터페이스를 가진다.
class PlatformStt {
  final stt.SpeechToText _s = stt.SpeechToText();
  bool _supported = false;

  bool get isSupported => _supported;
  bool get isListening => _s.isListening;

  Future<bool> initialize({
    void Function()? onEnd,
    void Function(String error)? onError,
  }) async {
    try {
      _supported = await _s.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') onEnd?.call();
        },
        onError: (e) => onError?.call(e.errorMsg),
      );
    } catch (_) {
      _supported = false;
    }
    return _supported;
  }

  void listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
  }) {
    _s.listen(
      onResult: (SpeechRecognitionResult r) =>
          onResult(r.recognizedWords, r.finalResult),
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        localeId: localeId,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> stop() => _s.stop();
}
