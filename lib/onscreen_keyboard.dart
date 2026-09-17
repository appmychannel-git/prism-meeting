import 'package:flutter/material.dart';

import 'l10n.dart';

/// 앱 내부 온스크린 키보드(TV·태블릿용). 시스템 IME를 띄우지 않고 화면 안에서
/// 직접 입력받는다(그래야 옆의 QR이 키보드에 가려지지 않는다).
///
/// 한글은 자모(ㄱ, ㅏ …)를 [onInput] 으로 넘긴다 — 실제 음절 조합은 부모가 쥔
/// [HangulComposer] 가 담당. 영문/숫자는 완성된 글자를 그대로 [onInput] 으로 넘긴다.
class OnScreenKeyboard extends StatefulWidget {
  final void Function(String ch) onInput; // 자모 또는 완성문자
  final VoidCallback onBackspace;
  final VoidCallback onSpace;
  final VoidCallback onClear;
  final VoidCallback onDone;
  const OnScreenKeyboard({
    super.key,
    required this.onInput,
    required this.onBackspace,
    required this.onSpace,
    required this.onClear,
    required this.onDone,
  });

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

enum _Mode { kr, en, num }

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  _Mode _mode = _Mode.kr;
  bool _shift = false;

  // 한글 두벌식 배열(기본).
  static const List<List<String>> _krBase = [
    ['ㅂ','ㅈ','ㄷ','ㄱ','ㅅ','ㅛ','ㅕ','ㅑ','ㅐ','ㅔ'],
    ['ㅁ','ㄴ','ㅇ','ㄹ','ㅎ','ㅗ','ㅓ','ㅏ','ㅣ'],
    ['ㅋ','ㅌ','ㅊ','ㅍ','ㅠ','ㅜ','ㅡ'],
  ];
  // shift(쌍자음/이중모음)로 바뀌는 글자만 매핑.
  static const Map<String, String> _krShift = {
    'ㅂ':'ㅃ','ㅈ':'ㅉ','ㄷ':'ㄸ','ㄱ':'ㄲ','ㅅ':'ㅆ','ㅐ':'ㅒ','ㅔ':'ㅖ',
  };

  static const List<List<String>> _enRows = [
    ['q','w','e','r','t','y','u','i','o','p'],
    ['a','s','d','f','g','h','j','k','l'],
    ['z','x','c','v','b','n','m'],
  ];
  static const List<List<String>> _numRows = [
    ['1','2','3','4','5','6','7','8','9','0'],
    ['-','_','.',',','@','!','?','(',')'],
  ];

  String _shifted(String k) {
    if (!_shift) return k;
    if (_mode == _Mode.kr) return _krShift[k] ?? k;
    if (_mode == _Mode.en) return k.toUpperCase();
    return k;
  }

  void _tap(String display) {
    widget.onInput(display);
    // 한글 쌍자음은 한 번 입력 후 shift 자동 해제(일반 자판 동작).
    if (_shift && _mode == _Mode.kr) setState(() => _shift = false);
  }

  void _cycleMode() {
    setState(() {
      _mode = _Mode.values[(_mode.index + 1) % _Mode.values.length];
      _shift = false;
    });
  }

  String get _modeLabel => switch (_mode) {
        _Mode.kr => '한글',
        _Mode.en => 'ABC',
        _Mode.num => '123',
      };

  @override
  Widget build(BuildContext context) {
    final List<List<String>> rows = switch (_mode) {
      _Mode.kr => _krBase,
      _Mode.en => _enRows,
      _Mode.num => _numRows,
    };
    final showShift = _mode == _Mode.kr || _mode == _Mode.en;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF11151C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int r = 0; r < rows.length; r++)
            _row([
              // 마지막 글자 행 앞에 shift, 뒤에 백스페이스.
              if (showShift && r == rows.length - 1)
                _special(
                  label: _mode == _Mode.kr ? '쌍자음' : '⇧',
                  active: _shift,
                  onTap: () => setState(() => _shift = !_shift),
                  flex: 3,
                ),
              for (final k in rows[r]) _char(_shifted(k)),
              if (r == rows.length - 1)
                _special(
                  icon: Icons.backspace_outlined,
                  onTap: widget.onBackspace,
                  flex: 2,
                ),
            ]),
          // 기능 행: 모드전환 · 공백 · 전체지움 · 확인
          _row([
            _special(label: _modeLabel, onTap: _cycleMode, flex: 3),
            _special(label: L.lang == 'ko' ? '공백' : 'Space',
                onTap: widget.onSpace, flex: 5),
            _special(
                icon: Icons.clear, label: L.t('clear'), onTap: widget.onClear, flex: 3),
            _special(
                label: L.t('ok'),
                onTap: widget.onDone,
                flex: 3,
                primary: true),
          ]),
        ],
      ),
    );
  }

  Widget _row(List<Widget> children) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: children),
      );

  // 문자 키(자모/영문/숫자).
  Widget _char(String display) => Expanded(
        flex: 2,
        child: _KeyButton(
          label: display,
          onTap: () => _tap(display),
        ),
      );

  // 특수 키(shift·backspace·mode·space·clear·done).
  Widget _special({
    String? label,
    IconData? icon,
    required VoidCallback onTap,
    int flex = 2,
    bool active = false,
    bool primary = false,
  }) =>
      Expanded(
        flex: flex,
        child: _KeyButton(
          label: label,
          icon: icon,
          onTap: onTap,
          active: active,
          primary: primary,
          small: true,
        ),
      );
}

class _KeyButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool active;
  final bool primary;
  final bool small;
  const _KeyButton({
    this.label,
    this.icon,
    required this.onTap,
    this.active = false,
    this.primary = false,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = primary
        ? const Color(0xFF3B6EF5)
        : active
            ? const Color(0xFF2A4A8A)
            : const Color(0xFF1E2530);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            child: icon != null && label == null
                ? Icon(icon, size: 20, color: Colors.white)
                : (icon != null
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 16, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(label!,
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: small ? 13 : 18)),
                        ],
                      )
                    : Text(
                        label ?? '',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: small ? 14 : 20,
                          fontWeight:
                              primary ? FontWeight.bold : FontWeight.w500,
                        ),
                      )),
          ),
        ),
      ),
    );
  }
}
