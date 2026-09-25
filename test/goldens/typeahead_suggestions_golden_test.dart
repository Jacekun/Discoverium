import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';

import 'golden_harness.dart';

/// The second legacy-package surface in the app, and so the second place the
/// missing-bridge defect can appear: `flutter_typeahead` floats its suggestion
/// list in an overlay of its own, outside whatever theme the field sits in.
///
/// Here the bridge assertion is the detector, not the pixels. Everything
/// visible in the overlay today is drawn by `material_ui` widgets that read
/// the modern theme directly, so dropping the bridge leaves the golden
/// byte-identical — verified by removing it. The golden still earns its place
/// as a guard on the overlay's appearance, and becomes a bridge detector too
/// the moment typeahead paints anything of its own.
void main() {
  setUpAll(loadAppFont);

  Widget form() => GeneratedForm(
    items: [
      [
        GeneratedFormTextField(
          'subreddit',
          label: 'Subreddit',
          value: '',
          autoCompleteOptions: const ['androiddev', 'androidapps', 'fossdroid'],
        ),
      ],
    ],
    onValueChanges: (_, _, _) {},
  );

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<void> openSuggestions(WidgetTester tester) async {
      useFixedSurface(tester, size: const Size(700, 500));
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
          child: goldenApp(brightness, child: form()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'android');
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsWidgets);
    }

    testWidgets('typeahead suggestions render in the app theme ($name)', (
      tester,
    ) async {
      await openSuggestions(tester);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('images/typeahead_suggestions_$name.png'),
      );
    });

    testWidgets('typeahead suggestions bridge the legacy theme ($name)', (
      tester,
    ) async {
      await openSuggestions(tester);

      expectLegacyThemeBridged(
        tester,
        find.byType(ListTile),
        brightness,
        describedAs: 'The typeahead suggestion list',
      );
    });
  }
}
