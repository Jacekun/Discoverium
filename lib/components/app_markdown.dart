import 'dart:async';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Every markdown surface in the app renders through this widget.
///
/// `flutter_markdown_plus` still reads `package:flutter/material.dart`'s
/// [Theme], which this app no longer installs anywhere above it — so without
/// [LegacyMaterialBridge] its `Theme.of` falls back to Flutter's built-in
/// light theme and the markdown comes out near-black on the dark surface.
/// Funnelling every call site through one widget is what stops that bridge
/// from being forgotten at one of them, and gives the goldens in
/// `test/goldens/app_markdown_golden_test.dart` a single surface to pin.
class AppMarkdown extends StatelessWidget {
  const AppMarkdown({super.key, required this.data, this.relativeLinkBase});

  /// The markdown to render.
  final String data;

  /// The URL a relative link is resolved against, normally the app's own page.
  /// When null, a relative link is opened exactly as written.
  final String? relativeLinkBase;

  /// Resolves [href] the way the call site that supplied [relativeLinkBase]
  /// expects: absolute links are always left alone.
  String _resolveLink(String href) {
    final base = relativeLinkBase;
    if (base == null) return href;
    if (href.startsWith('http://') || href.startsWith('https://')) return href;
    return '${Uri.parse(base).origin}/$href';
  }

  @override
  Widget build(BuildContext context) {
    // Read outside the bridge, from the modern theme: the bridge maps the
    // colour scheme and the text theme across to the legacy [ThemeData] but
    // not cardColor, so the blockquote has to come from this side.
    final blockquoteColor = Theme.of(context).cardColor;
    return LegacyMaterialBridge(
      child: MarkdownBody(
        data: data,
        styleSheet: MarkdownStyleSheet(
          blockquoteDecoration: BoxDecoration(color: blockquoteColor),
        ),
        onTapLink: (text, href, title) {
          if (href == null) return;
          unawaited(
            launchUrlString(
              _resolveLink(href),
              mode: LaunchMode.externalApplication,
            ),
          );
        },
        extensionSet: md.ExtensionSet(
          md.ExtensionSet.gitHubFlavored.blockSyntaxes,
          [md.EmojiSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
        ),
      ),
    );
  }
}
