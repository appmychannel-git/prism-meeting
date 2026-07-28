// 플랫폼별 음성 인식(STT) 구현 선택.
// - 모바일/데스크톱: speech_to_text 패키지(stt_mobile.dart)
// - 웹: 브라우저 SpeechRecognition 직접 호출(stt_web.dart)
//   (speech_to_text 의 웹 지원이 불안정해 직접 구현으로 대체)
export 'stt_mobile.dart' if (dart.library.js_interop) 'stt_web.dart';
