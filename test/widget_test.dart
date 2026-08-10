import 'package:flutter_test/flutter_test.dart';
import 'package:ozon_profit_flutter/main.dart';

void main() {
  testWidgets('renders agent shell', (tester) async {
    await tester.pumpWidget(const AgentShellApp());
    expect(find.text('PROFIT / AGENT WORKSPACE v0.6.0'), findsOneWidget);
    expect(find.byTooltip('Start dry run'), findsOneWidget);
    expect(find.byTooltip('Refresh current page'), findsOneWidget);
    expect(find.byTooltip('Show pinned task tab'), findsOneWidget);
    expect(find.byTooltip('Show search tab'), findsOneWidget);
    expect(find.byTooltip('Toggle low-latency manual takeover'), findsOneWidget);
    expect(find.byTooltip('Toggle native Chromium window'), findsOneWidget);
    expect(find.byTooltip('More actions'), findsOneWidget);
  });
}
