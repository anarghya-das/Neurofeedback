import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/src/ui/test_screen.dart';

class _Run extends ChangeNotifier {
  bool running = true;
  int stops = 0;

  void stop() {
    stops++;
    running = false;
    notifyListeners();
  }

  void finish() {
    running = false;
    notifyListeners();
  }
}

Widget _app(_Run run) => MaterialApp(
  home: Builder(
    builder: (context) => TextButton(
      onPressed: () => Navigator.of(context).push(
        TestScreen.route(
          TestScreen(
            listenable: run,
            isRunning: () => run.running,
            onStop: run.stop,
            instruction: () => 'Close your eyes',
          ),
        ),
      ),
      child: const Text('open'),
    ),
  ),
);

void main() {
  testWidgets('shows the instruction and closes when the run ends', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(run));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Close your eyes'), findsOneWidget);
    expect(find.text('Stop (Esc)'), findsOneWidget);

    run.finish();
    await tester.pumpAndSettle();
    expect(find.text('Close your eyes'), findsNothing);
    expect(run.stops, 0);
  });

  testWidgets('Esc stops a running test and closes the screen', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(run));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(run.stops, 1);
    expect(find.text('Close your eyes'), findsNothing);
  });
}
