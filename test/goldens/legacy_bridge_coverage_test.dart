import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Packages that still render `package:flutter/material.dart` widgets
/// internally. This app installs no app-wide `MaterialUiCompatibilityBridge`,
/// so anything from one of these draws against Flutter's built-in light theme
/// unless the call site wraps it in `LegacyMaterialBridge`.
const Set<String> _legacyMaterialPackages = {
  'package:flutter/material.dart',
  'package:flutter_markdown_plus/flutter_markdown_plus.dart',
  'package:flutter_typeahead/flutter_typeahead.dart',
};

/// The files allowed to reach for one of those packages, each because it owns
/// the bridge for that surface and has a golden pinning how it renders.
///
/// The allowlist is per file, not per call site: a second unbridged surface
/// added inside one of these files is not caught here, only by that file's
/// golden. It is new files this guards.
///
///
/// * `app_markdown.dart` — every markdown surface in the app
///   (`app_markdown_golden_test.dart`).
/// * `generated_form_renderer.dart` — the typeahead suggestion overlay
///   (`typeahead_suggestions_golden_test.dart`).
const Set<String> _bridgedFiles = {
  'lib/components/app_markdown.dart',
  'lib/components/generated_form_renderer.dart',
};

final RegExp _importLine = RegExp(
  r'''^\s*import\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main() {
  test('every legacy-Material import is in a file that owns a bridge', () {
    final offenders = <String, String>{};
    final unbridged = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      final imports = _importLine
          .allMatches(source)
          .map((m) => m.group(1)!)
          .where(_legacyMaterialPackages.contains);
      if (imports.isEmpty) continue;

      if (!_bridgedFiles.contains(entity.path)) {
        offenders[entity.path] = imports.join(', ');
      } else if (!source.contains('LegacyMaterialBridge')) {
        unbridged.add(entity.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files import a legacy-Material package without owning a '
          'bridge, so whatever they render takes Flutter\'s built-in light '
          'theme instead of the app\'s:\n'
          '${offenders.entries.map((e) => '  ${e.key} -> ${e.value}').join('\n')}\n'
          'Render markdown through AppMarkdown instead. For a genuinely new '
          'surface, wrap it in LegacyMaterialBridge, add a golden for it '
          'under test/goldens, and list the file in _bridgedFiles here.',
    );

    expect(
      unbridged,
      isEmpty,
      reason:
          'These files are listed as owning a bridge but no longer mention '
          'LegacyMaterialBridge: ${unbridged.join(', ')}',
    );
  });

  test('every file listed as bridged still exists', () {
    for (final path in _bridgedFiles) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason:
            '$path is listed in _bridgedFiles but is gone; the allowlist is '
            'stale and would let a new unbridged surface through.',
      );
    }
  });
}
