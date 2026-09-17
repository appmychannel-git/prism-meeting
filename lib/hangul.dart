/// 한글 조합기(오토마타) — 온스크린 키보드에서 자모(ㄱ, ㅏ …)를 눌러 음절(가·각·닭)을
/// 만든다. 시스템 IME 없이 앱 자체 키패드로 한글 입력을 하기 위한 것.
///
/// 사용:
///   final c = HangulComposer()..committed = '기존이름';
///   c.input('ㄱ'); c.input('ㅏ'); // → text == '기존이름가'
///   c.backspace();
///   final result = c.text;
///
/// 지원: 두벌식 자모 입력 + 겹받침(ㄳ ㄺ …)·겹모음(ㅘ ㅢ …) 조합/분해, 받침 이동
/// (각+ㅏ → 가가). 영어·숫자·기타 문자는 [input] 대신 [insert] 로 그대로 붙인다.
class HangulComposer {
  // 초성 19 / 중성 21 / 종성 28(0=받침없음). 값은 호환 자모(키에 찍히는 글자와 동일).
  static const List<String> cho = [
    'ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ','ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'
  ];
  static const List<String> jung = [
    'ㅏ','ㅐ','ㅑ','ㅒ','ㅓ','ㅔ','ㅕ','ㅖ','ㅗ','ㅘ','ㅙ','ㅚ','ㅛ','ㅜ','ㅝ','ㅞ','ㅟ','ㅠ','ㅡ','ㅢ','ㅣ'
  ];
  static const List<String> jong = [
    '','ㄱ','ㄲ','ㄳ','ㄴ','ㄵ','ㄶ','ㄷ','ㄹ','ㄺ','ㄻ','ㄼ','ㄽ','ㄾ','ㄿ','ㅀ','ㅁ','ㅂ','ㅄ','ㅅ','ㅆ','ㅇ','ㅈ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'
  ];

  // 겹받침 합치기: 받침글자 + 다음자음 → 겹받침.
  static const Map<String, String> _jongCombine = {
    'ㄱㅅ': 'ㄳ', 'ㄴㅈ': 'ㄵ', 'ㄴㅎ': 'ㄶ', 'ㄹㄱ': 'ㄺ', 'ㄹㅁ': 'ㄻ',
    'ㄹㅂ': 'ㄼ', 'ㄹㅅ': 'ㄽ', 'ㄹㅌ': 'ㄾ', 'ㄹㅍ': 'ㄿ', 'ㄹㅎ': 'ㅀ', 'ㅂㅅ': 'ㅄ',
  };
  // 겹받침 분해(받침 뒤 모음이 오면 뒷자음이 새 초성으로): 겹받침 → (남는받침, 이동자음).
  static const Map<String, List<String>> _jongSplit = {
    'ㄳ': ['ㄱ','ㅅ'], 'ㄵ': ['ㄴ','ㅈ'], 'ㄶ': ['ㄴ','ㅎ'], 'ㄺ': ['ㄹ','ㄱ'],
    'ㄻ': ['ㄹ','ㅁ'], 'ㄼ': ['ㄹ','ㅂ'], 'ㄽ': ['ㄹ','ㅅ'], 'ㄾ': ['ㄹ','ㅌ'],
    'ㄿ': ['ㄹ','ㅍ'], 'ㅀ': ['ㄹ','ㅎ'], 'ㅄ': ['ㅂ','ㅅ'],
  };
  // 백스페이스용: 겹받침 → 한 자모 뺀 받침.
  static const Map<String, String> _jongBackspace = {
    'ㄳ': 'ㄱ', 'ㄵ': 'ㄴ', 'ㄶ': 'ㄴ', 'ㄺ': 'ㄹ', 'ㄻ': 'ㄹ', 'ㄼ': 'ㄹ',
    'ㄽ': 'ㄹ', 'ㄾ': 'ㄹ', 'ㄿ': 'ㄹ', 'ㅀ': 'ㄹ', 'ㅄ': 'ㅂ',
  };
  // 겹모음 합치기: 기존모음 + 다음모음 → 겹모음.
  static const Map<String, String> _jungCombine = {
    'ㅗㅏ': 'ㅘ', 'ㅗㅐ': 'ㅙ', 'ㅗㅣ': 'ㅚ', 'ㅜㅓ': 'ㅝ', 'ㅜㅔ': 'ㅞ',
    'ㅜㅣ': 'ㅟ', 'ㅡㅣ': 'ㅢ',
  };
  // 백스페이스용: 겹모음 → 앞 모음.
  static const Map<String, String> _jungBackspace = {
    'ㅘ': 'ㅗ', 'ㅙ': 'ㅗ', 'ㅚ': 'ㅗ', 'ㅝ': 'ㅜ', 'ㅞ': 'ㅜ', 'ㅟ': 'ㅜ', 'ㅢ': 'ㅡ',
  };

  /// 조합이 끝나 확정된 앞부분 텍스트.
  String committed = '';
  // 현재 조합 중인 음절(없으면 -1 / 받침 0).
  int _cho = -1, _jung = -1, _jong = 0;

  bool _isVowel(String c) => jung.contains(c);
  bool _isConsonant(String c) => cho.contains(c);

  /// 현재 조합 중 음절을 글자로 렌더(없으면 '').
  String _composing() {
    if (_cho >= 0 && _jung >= 0) {
      final code = 0xAC00 + (_cho * 21 + _jung) * 28 + _jong;
      return String.fromCharCode(code);
    }
    if (_cho >= 0) return cho[_cho];
    if (_jung >= 0) return jung[_jung];
    return '';
  }

  /// 확정 + 조합중 = 현재 표시 텍스트.
  String get text => committed + _composing();

  bool get _hasComposing => _cho >= 0 || _jung >= 0;

  void _commit() {
    committed += _composing();
    _cho = -1;
    _jung = -1;
    _jong = 0;
  }

  /// 자모 한 글자 입력(ㄱ, ㅏ …). 그 외 문자는 [insert] 사용.
  void input(String ch) {
    if (_isVowel(ch)) {
      _inputVowel(ch);
    } else if (_isConsonant(ch)) {
      _inputConsonant(ch);
    } else {
      insert(ch); // 자모가 아니면 그대로
    }
  }

  void _inputConsonant(String ch) {
    if (!_hasComposing) {
      _cho = cho.indexOf(ch);
      return;
    }
    // 초성만 있고 중성 없음 → 두 자음 연속: 앞 초성 확정 후 새 초성.
    if (_cho >= 0 && _jung < 0) {
      _commit();
      _cho = cho.indexOf(ch);
      return;
    }
    // 초성 없이 모음만(홀로 모음) → 모음 확정 후 새 초성.
    if (_cho < 0 && _jung >= 0) {
      _commit();
      _cho = cho.indexOf(ch);
      return;
    }
    // 초성+중성(+받침) 상태.
    if (_jong == 0) {
      final ji = jong.indexOf(ch);
      if (ji > 0) {
        _jong = ji; // 받침으로
      } else {
        _commit(); // 받침 불가 자음(ㄸㅃㅉ) → 새 초성
        _cho = cho.indexOf(ch);
      }
      return;
    }
    // 이미 받침 있음 → 겹받침 시도.
    final combo = _jongCombine[jong[_jong] + ch];
    if (combo != null) {
      _jong = jong.indexOf(combo);
    } else {
      _commit();
      _cho = cho.indexOf(ch);
    }
  }

  void _inputVowel(String ch) {
    // 초성만 있음 → 중성 붙여 음절 시작(가).
    if (_cho >= 0 && _jung < 0) {
      _jung = jung.indexOf(ch);
      return;
    }
    // 받침 있음 → 받침(뒷자음)이 새 초성으로 이동(각+ㅏ→가가, 닭+ㅏ→달가).
    if (_jong > 0) {
      final cur = jong[_jong];
      final split = _jongSplit[cur];
      final String moved;
      if (split != null) {
        _jong = jong.indexOf(split[0]); // 남는 받침
        moved = split[1];
      } else {
        _jong = 0; // 홑받침 전체 이동
        moved = cur;
      }
      _commit();
      _cho = cho.indexOf(moved);
      _jung = jung.indexOf(ch);
      return;
    }
    // 초성+중성(받침 없음) → 겹모음 시도.
    if (_cho >= 0 && _jung >= 0) {
      final combo = _jungCombine[jung[_jung] + ch];
      if (combo != null) {
        _jung = jung.indexOf(combo);
      } else {
        _commit();
        _jung = jung.indexOf(ch); // 홀로 모음
      }
      return;
    }
    // 홀로 모음 상태에서 모음 → 겹모음 시도, 아니면 확정 후 새 모음.
    if (_cho < 0 && _jung >= 0) {
      final combo = _jungCombine[jung[_jung] + ch];
      if (combo != null) {
        _jung = jung.indexOf(combo);
      } else {
        _commit();
        _jung = jung.indexOf(ch);
      }
      return;
    }
    // 완전 초기 → 홀로 모음 시작.
    _jung = jung.indexOf(ch);
  }

  /// 자모가 아닌 문자(영문·숫자·공백 등)를 그대로 붙인다(조합 중이면 확정 후).
  void insert(String s) {
    if (_hasComposing) _commit();
    committed += s;
  }

  /// 한 자모/글자 지우기. 조합 중이면 마지막 자모부터, 아니면 확정 텍스트 끝 글자.
  void backspace() {
    if (_jong > 0) {
      final cur = jong[_jong];
      final base = _jongBackspace[cur];
      _jong = base != null ? jong.indexOf(base) : 0;
      return;
    }
    if (_jung >= 0) {
      final cur = jung[_jung];
      final base = _jungBackspace[cur];
      _jung = base != null ? jung.indexOf(base) : -1;
      return;
    }
    if (_cho >= 0) {
      _cho = -1;
      return;
    }
    // 조합 중 아님 → 확정 텍스트 끝 글자 삭제.
    if (committed.isNotEmpty) {
      committed = committed.substring(0, committed.length - 1);
    }
  }

  /// 전체 지우기.
  void clear() {
    committed = '';
    _cho = -1;
    _jung = -1;
    _jong = 0;
  }

  /// 조합을 끝내고(확정) 현재 전체 텍스트 반환.
  String finish() {
    _commit();
    return committed;
  }

  /// 기존 텍스트로 초기화(조합 상태 없이 확정 텍스트로 취급).
  void setText(String s) {
    clear();
    committed = s;
  }
}
