import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider_versions.dart';
import 'package:obtainium/providers/source_provider.dart';

const _releases = 'https://github.com/Keeperorowner/NagramXF/releases/download';

App _app({
  String release = '1450',
  List<MapEntry<String, String>> apks = const [
    MapEntry(
      'NagramXF-arm64-v8a.apk',
      '$_releases/1450/NagramXF-arm64-v8a.apk',
    ),
    MapEntry(
      'NagramXF-universal.apk',
      '$_releases/1450/NagramXF-universal.apk',
    ),
  ],
  int preferredApkIndex = 0,
  int? code,
  String? name,
  String? apkName,
  bool trackOnly = false,
}) => App(
  id: 'fork.risin42.nagramx',
  url: 'https://github.com/Keeperorowner/NagramXF',
  author: 'Keeperorowner',
  name: 'Nagram XF',
  installedVersion: '12.10.1-dec46b0',
  installedVersionCode: 1250,
  latestVersion: release,
  latestVersionCode: code,
  latestVersionName: name,
  latestVersionApkName: apkName,
  apkUrls: apks,
  preferredApkIndex: preferredApkIndex,
  additionalSettings: {'trackOnly': trackOnly},
);

/// The app as the last check left it: its arm64 APK read for release 1450.
final _read = _app(
  code: 1250,
  name: '12.10.1-dec46b0',
  apkName: 'NagramXF-arm64-v8a.apk',
);

void main() {
  group('latestApkVersionWithoutReading', () {
    test('reuses the reading for the same APK of the same release', () {
      final settled = latestApkVersionWithoutReading(_app(), previous: _read);
      expect(settled?.latestVersionCode, 1250);
      expect(settled?.latestVersionName, '12.10.1-dec46b0');
      expect(settled?.latestVersionApkName, 'NagramXF-arm64-v8a.apk');
    });

    test('reuses it when only the download link changed', () {
      // APKCombo, for one, hands out presigned links that differ every check.
      final resigned = _app(
        apks: const [
          MapEntry(
            'NagramXF-arm64-v8a.apk',
            'https://cdn.example/NagramXF-arm64-v8a.apk?X-Amz-Signature=new',
          ),
        ],
      );
      expect(
        latestApkVersionWithoutReading(
          resigned,
          previous: _read,
        )?.latestVersionCode,
        1250,
      );
    });

    test('reads again for a new release', () {
      expect(
        latestApkVersionWithoutReading(_app(release: '1451'), previous: _read),
        isNull,
      );
    });

    test('reads again when a different APK is preferred', () {
      expect(
        latestApkVersionWithoutReading(
          _app(preferredApkIndex: 1),
          previous: _read,
        ),
        isNull,
      );
    });

    test('reads when there is no earlier reading to reuse', () {
      expect(latestApkVersionWithoutReading(_app()), isNull);
      expect(latestApkVersionWithoutReading(_app(), previous: _app()), isNull);
    });

    test('an out-of-range preference means the last APK, as for downloads', () {
      final universal = _app(
        code: 1250,
        name: '12.10.1-dec46b0',
        apkName: 'NagramXF-universal.apk',
      );
      expect(
        latestApkVersionWithoutReading(
          _app(preferredApkIndex: 5),
          previous: universal,
        )?.latestVersionApkName,
        'NagramXF-universal.apk',
      );
    });

    test('clears the version of an app with no APK to read', () {
      for (final app in [
        _read.copyWith(additionalSettings: {'trackOnly': true}),
        _read.copyWith(apkUrls: const []),
      ]) {
        final settled = latestApkVersionWithoutReading(app, previous: _read);
        expect(settled, isNotNull);
        expect(settled!.latestVersionCode, isNull);
        expect(settled.latestVersionName, isNull);
        expect(settled.latestVersionApkName, isNull);
      }
    });
  });
}
