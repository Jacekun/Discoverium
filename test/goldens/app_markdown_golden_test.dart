import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/app_markdown.dart';

import 'golden_harness.dart';

/// Exercises every part of the markdown style sheet that takes its colour from
/// the theme, so a theme that did not reach the renderer shows up as a pixel
/// difference rather than passing unnoticed.
const String _sampleNotes = '''
# Release notes - 8.0.6

Body copy that has to stay readable, with a [link](https://example.com)
and some `inline code` in it.

## What changed

- A bullet item
- Another bullet item

> A quoted line from the release.

```
a fenced code block
```

| Column A | Column B |
| --- | --- |
| Cell one | Cell two |
''';

void main() {
  setUpAll(loadAppFont);

  // The regression these pin: `flutter_markdown_plus` reads the legacy
  // `package:flutter/material.dart` theme, which this app does not install
  // app-wide. Rendered without LegacyMaterialBridge the notes come out in
  // Flutter's built-in light theme — near-black text on the dark card, with
  // only the blue link legible. In dark mode that is a large pixel diff; the
  // light golden is here so the reverse (a bridge that maps the theme wrongly)
  // cannot slip through either.
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testWidgets('AppMarkdown renders in the app theme ($name)', (tester) async {
      useFixedSurface(tester);
      await tester.pumpWidget(
        goldenApp(brightness, child: const AppMarkdown(data: _sampleNotes)),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('images/app_markdown_$name.png'),
      );
    });

    testWidgets('AppMarkdown bridges the legacy theme ($name)', (tester) async {
      useFixedSurface(tester);
      await tester.pumpWidget(
        goldenApp(brightness, child: const AppMarkdown(data: _sampleNotes)),
      );
      await tester.pumpAndSettle();

      expectLegacyThemeBridged(
        tester,
        find.byType(MarkdownBody),
        brightness,
        describedAs: 'The release-notes markdown',
      );
    });
  }
}
