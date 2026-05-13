import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('renders POS keyboard controls', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Flutter Windows POS'), findsOneWidget);
    expect(find.text('打开Dialog'), findsOneWidget);
    expect(find.text('手动关闭键盘'), findsOneWidget);
    expect(find.text('点击这里不会再乱弹触摸键盘'), findsOneWidget);
  });

  testWidgets('tap outside clears text input focus', (tester) async {
    await tester.pumpWidget(const MyApp());

    await tester.tap(find.byType(SmartTextField));
    await tester.pump();

    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('点击这里不会再乱弹触摸键盘'));
    await tester.pump();

    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('dialog open and close do not leave text input visible', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await tester.tap(find.text('打开Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('测试弹框'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(find.text('测试弹框'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
  });
}
