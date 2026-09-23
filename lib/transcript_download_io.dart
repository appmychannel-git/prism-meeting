// 모바일/TV/데스크톱: 텍스트 파일을 공유 시트로 저장/전송.
import 'dart:convert';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<void> saveTranscript(String filename, String content) async {
  final bytes = Uint8List.fromList(utf8.encode(content));
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(bytes, name: filename, mimeType: 'text/plain'),
      ],
    ),
  );
}
