// Phase 1 tests for Athur.
//
// These verify real Phase 1 behaviour: the brand splash renders, and the main
// shell exposes the four primary destinations. No mock backend is involved
// because Phase 1 has no backend dependency.

import 'package:athur/core/constants/athur_assets.dart';
import 'package:athur/core/theme/athur_theme.dart';
import 'package:athur/features/home/presentation/home_shell.dart';
import 'package:athur/features/splash/presentation/splash_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SplashScreen', () {
    testWidgets('renders the Athur brand and calls onFinished', (tester) async {
      var finished = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AthurTheme.dark,
          home: SplashScreen(onFinished: () => finished = true),
        ),
      );

      // Brand must be visible immediately.
      expect(find.text('Athur'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);

      // Let the minimum splash duration elapse, then the entry animation.
      // NOTE: pumpAndSettle is not used here because the on-screen
      // CircularProgressIndicator animates indefinitely and would never
      // settle. Fixed pumps are the correct tool for an infinite animation.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 600));
      expect(finished, isTrue);
    });

    testWidgets('runs bootstrap and still finishes on failure', (tester) async {
      var finished = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AthurTheme.dark,
          home: SplashScreen(
            onFinished: () => finished = true,
            bootstrap: () async => throw StateError('boom'),
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 600));
      // Startup failure must not trap the user on the splash forever.
      expect(finished, isTrue);
    });
  });

  group('HomeShell', () {
    testWidgets('shows the four primary destinations', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AthurTheme.dark, home: const HomeShell()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Chats'), findsWidgets);
      expect(find.text('Calls'), findsWidgets);
      expect(find.text('Contacts'), findsWidgets);
      expect(find.text('Settings'), findsWidgets);
    });

    testWidgets('switching tabs updates the visible content', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AthurTheme.dark, home: const HomeShell()),
      );
      await tester.pumpAndSettle();

      // Chats empty state is the initial tab.
      expect(find.text('No chats yet'), findsOneWidget);

      await tester.tap(find.text('Calls').last);
      await tester.pumpAndSettle();
      expect(find.text('No calls yet'), findsOneWidget);

      await tester.tap(find.text('Contacts').last);
      await tester.pumpAndSettle();
      expect(find.text('No contacts yet'), findsOneWidget);
    });
  });

  group('Assets', () {
    test('asset paths are declared consistently', () {
      expect(AthurAssets.logo, endsWith('logo.png'));
      expect(AthurAssets.ringtone, endsWith('ringtone.mp3'));
    });
  });
}
