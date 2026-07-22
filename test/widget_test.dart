import 'package:flutter_test/flutter_test.dart';

import 'package:prism_meeting/main.dart';

void main() {
  testWidgets('입장 화면이 렌더링된다', (WidgetTester tester) async {
    await tester.pumpWidget(const PrismMeetingApp());
    expect(find.text('Prism Meeting'), findsOneWidget);
    expect(find.text('회의 입장'), findsOneWidget);
  });
}
