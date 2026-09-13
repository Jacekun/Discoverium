import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_package_manager/android_package_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/utils/color_utils.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:path_provider/path_provider.dart';

/// App persistence (load/save/remove), icons, and install-status helpers.
const _corruptFileSuffix = '.corrupt';

/// Curated icon URLs that failed to download this session, so they are not
/// re-requested on every app-list load.
final Set<String> _failedDiscoveriumIconUrls = <String>{};

extension AppsProviderLifecycle on AppsProvider {
  Future<Directory> getAppsDir() async {
    if (cachedAppsDir != null) return cachedAppsDir!;
    final Directory appsDir = Directory(
      '${(await getAppStorageDir()).path}/app_data',
    );
    if (!appsDir.existsSync()) {
      try {
        appsDir.createSync();
      } catch (_) {
        final fallbackDir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/app_data',
        );
        if (!fallbackDir.existsSync()) {
          fallbackDir.createSync(recursive: true);
        }
        return cachedAppsDir = fallbackDir;
      }
    }
    return cachedAppsDir = appsDir;
  }

  /// Records the package manager's own version of [app] as its installed
  /// version — its versionName and versionCode, or nothing when it is not
  /// installed. Returns the modified app, or null when nothing changed.
  ///
  /// The installed version is never inferred from a release. A track-only app
  /// is left alone: it has no APK, so its installed version is whatever the
  /// user marked.
  App? getCorrectedInstallStatusAppIfPossible(
    App app,
    PackageInfo? installedInfo,
  ) {
    if (app.settings.getBool('trackOnly')) return null;
    final installedVersion = installedInfo == null
        ? null
        : versionNameOrCode(
            installedInfo.versionName,
            installedInfo.versionCode,
          );
    final installedVersionCode = installedInfo?.versionCode;
    if (app.installedVersion == installedVersion &&
        app.installedVersionCode == installedVersionCode) {
      return null;
    }
    return app.copyWith(
      installedVersion: installedVersion,
      installedVersionCode: installedVersionCode,
    );
  }

  Future<void> loadApps({String? singleId}) async {
    await waitForAppsToLoad();
    appsLoadingCompleter = Completer<void>();
    loadingApps = true;
    notify();
    try {
      final sp = SourceProvider();
      final List<List<String>> errors = [];
      final installedAppsData = await getAllInstalledInfo();
      final Map<String, PackageInfo> installedAppsMap = {
        for (var i in installedAppsData)
          if (i.packageName != null) i.packageName!: i,
      };
      final List<String> removedAppIds = [];
      final List<App> correctedApps = [];
      await Future.wait(
        // TODO: Replace listSync() with async list().toList()
        (await getAppsDir()) // Parse Apps from JSON
            .listSync()
            .map((item) async {
              App? app;
              if (item.path.toLowerCase().endsWith('.json') &&
                  (singleId == null ||
                      item.path.split('/').last.toLowerCase() ==
                          '${singleId.toLowerCase()}.json')) {
                try {
                  app = App.fromJson(
                    jsonDecode(await File(item.path).readAsString()),
                  );
                } catch (err) {
                  if (err is FormatException) {
                    // Genuinely corrupt JSON: set it aside so it stops failing.
                    AppLogger.error(
                      err,
                      message: 'Corrupt JSON, renaming ${item.path}',
                    );
                    unawaited(item.rename('${item.path}$_corruptFileSuffix'));
                  } else {
                    // Other errors (e.g. a temporarily unresolvable source):
                    // skip but keep the file so it can load once resolved.
                    AppLogger.warn(
                      'Error loading app ${item.path} (skipped, file kept): $err',
                    );
                  }
                }
              }
              if (app != null) {
                apps.update(
                  app.id,
                  (value) => value.copyWith(app: app!),
                  ifAbsent: () => AppInMemory(app!, null, null, null),
                );
                try {
                  // Try getting the app's source to ensure no invalid apps get loaded
                  final src = sp.getSource(
                    app.url,
                    overrideSource: app.overrideSource,
                  );
                  final sourceType = src.sourceIdentifier;
                  // If the app is installed, grab its OS data and reconcile install statuses
                  final PackageInfo? installedInfo = installedAppsMap[app.id];
                  // Reconcile differences between the installed and recorded install info
                  final moddedApp = getCorrectedInstallStatusAppIfPossible(
                    app,
                    installedInfo,
                  );
                  if (moddedApp != null) {
                    app = moddedApp;
                    correctedApps.add(app);
                    // Note the app ID if it was uninstalled externally
                    if (moddedApp.installedVersion == null) {
                      removedAppIds.add(moddedApp.id);
                    }
                  }
                  // Update the app in memory with install info and corrections
                  apps.update(
                    app.id,
                    (value) => value.copyWith(
                      app: app!,
                      installedInfo: installedInfo,
                      sourceType: sourceType,
                    ),
                    ifAbsent: () => AppInMemory(
                      app!,
                      null,
                      installedInfo,
                      null,
                      sourceType: sourceType,
                    ),
                  );
                } catch (e) {
                  if (e is RateLimitError || e is SocketException) {
                    AppLogger.info(
                      'Transient error loading app ${app!.id}, will retry: $e',
                    );
                  } else {
                    errors.add([app!.id, app.finalName, e.toString()]);
                  }
                }
              }
            }),
      );
      if (errors.isNotEmpty) {
        for (var error in errors) {
          AppLogger.error(
            error[2],
            message: 'Removing app ${error[0]} (${error[1]}) due to load error',
          );
        }
        unawaited(removeApps(errors.map((e) => e[0]).toList()));
        unawaited(
          NotificationsProvider().notify(
            AppsRemovedNotification(errors.map((e) => [e[1], e[2]]).toList()),
          ),
        );
      }
      // Delete externally uninstalled Apps if needed
      if (removedAppIds.isNotEmpty &&
          settingsProvider.removeOnExternalUninstall) {
        await removeApps(removedAppIds);
      }
      if (correctedApps.isNotEmpty) {
        await saveApps(
          correctedApps,
          attemptToCorrectInstallStatus: false,
          reuseInstalledInfo: true,
        );
      }
    } finally {
      loadingApps = false;
      appsLoadingCompleter?.complete();
      appsLoadingCompleter = null;
      notify();
    }
    if (!isBg && apps.isNotEmpty) {
      unawaited(
        Future(() async {
          for (final entry in apps.entries.toList()) {
            await updateAppIcon(entry.key);
            await Future<void>.delayed(Duration.zero);
          }
          notify();
        }),
      );
    }
  }

  Future<void> updateAppIcon(String? appId, {bool ignoreCache = false}) async {
    if (apps[appId]?.icon == null) {
      final cachedIcon = File('${iconsCacheDir.path}/$appId.png');
      final alreadyCached = cachedIcon.existsSync() && !ignoreCache;
      Uint8List? icon;
      if (alreadyCached) {
        icon = await cachedIcon.readAsBytes();
      } else {
        // Apps added from Discoverium's curated repo carry an icon URL, which
        // gives a real icon even before the app is installed on device.
        icon = await _downloadDiscoveriumIcon(appId);
        icon ??= await apps[appId]?.installedInfo?.applicationInfo
            ?.getAppIcon();
      }
      if (icon != null && !alreadyCached) {
        unawaited(cachedIcon.writeAsBytes(icon));
      }
      if (icon != null) {
        // Re-read after the awaits above: the app may have been removed while
        // its icon was being fetched.
        final current = apps[appId];
        if (current == null) return;
        apps.update(
          current.app.id,
          (value) => value.copyWith(icon: icon),
          ifAbsent: () =>
              AppInMemory(current.app, null, current.installedInfo, icon),
        );
      }
    }
  }

  /// Downloads the curated icon recorded on the app by Discoverium's repo, if
  /// it has one. Returns null on any failure so the caller falls back to the
  /// installed app's own icon.
  Future<Uint8List?> _downloadDiscoveriumIcon(String? appId) async {
    final iconUrl = apps[appId]?.app.additionalSettings['discoveriumIconUrl'];
    if (iconUrl == null || iconUrl.toString().isEmpty) return null;
    final url = iconUrl.toString();
    // Nothing is written to the icon cache when a download fails, so without
    // this every app-list load would re-request a URL already known to fail.
    if (_failedDiscoveriumIconUrls.contains(url)) return null;
    try {
      final res = await get(Uri.parse(url));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        return res.bodyBytes;
      }
      _failedDiscoveriumIconUrls.add(url);
    } catch (e) {
      _failedDiscoveriumIconUrls.add(url);
      AppLogger.debug('Failed to download Discoverium icon for $appId: $e');
    }
    return null;
  }

  /// Persists a list of [App] objects to disk as JSON files and updates in-memory state.
  ///
  /// When [reuseInstalledInfo] is true, the already-loaded [PackageInfo]/icon
  /// for each app are reused instead of re-querying the platform and
  /// re-decoding icons. This avoids expensive per-app platform-channel calls
  /// and icon decoding on the UI isolate during bulk operations like update
  /// checks, where installed info and icons don't change.
  Future<void> saveApps(
    List<App> apps, {
    bool attemptToCorrectInstallStatus = true,
    bool onlyIfExists = true,
    bool reuseInstalledInfo = false,
  }) async {
    await Future.wait(
      apps.map((a) async {
        var app = a.copyWith();
        final bool canReuse =
            reuseInstalledInfo && this.apps.containsKey(app.id);
        final PackageInfo? info = canReuse
            ? this.apps[app.id]!.installedInfo
            : await getInstalledInfo(app.id);
        final Uint8List? icon = canReuse
            ? this.apps[app.id]!.icon
            : await info?.applicationInfo?.getAppIcon();
        if (!canReuse) {
          app = app.copyWith(
            name: await (info?.applicationInfo?.getAppLabel()) ?? app.name,
          );
        }
        if (attemptToCorrectInstallStatus) {
          app = getCorrectedInstallStatusAppIfPossible(app, info) ?? app;
        }
        if (!onlyIfExists || this.apps.containsKey(app.id)) {
          final String filePath = '${(await getAppsDir()).path}/${app.id}.json';
          await File(
            '$filePath.tmp',
          ).writeAsString(jsonEncode(app.toJson())); // #2089
          await File('$filePath.tmp').rename(filePath);
        }
        if (this.apps.containsKey(app.id)) {
          this.apps[app.id] = this.apps[app.id]!.copyWith(
            app: app,
            installedInfo: info,
            icon: icon,
          );
        } else if (!onlyIfExists) {
          this.apps[app.id] = AppInMemory(app, null, info, icon);
        }
        // Drop the cached icon of an app that is no longer installed — unless
        // it came from the curated repo's icon URL, which is exactly the case
        // that has no installed package to read an icon back from. Deleting
        // those makes every refresh re-download them.
        if (info == null &&
            app.settings.getStringOrNull('discoveriumIconUrl') == null) {
          final cachedIcon = File('${iconsCacheDir.path}/${app.id}.png');
          if (cachedIcon.existsSync()) cachedIcon.deleteSync();
        }
      }),
    );
    notify();
    scheduleAutoExport();
  }

  /// Deletes app JSON files, cached APKs, and icons for the given app IDs, then updates state.
  Future<void> removeApps(List<String> appIds) async {
    final apkFiles = await apkDir.list().toList();
    await Future.wait(
      appIds.map((appId) async {
        final File file = File('${(await getAppsDir()).path}/$appId.json');
        if (file.existsSync()) {
          deleteFile(file);
        }
        await Future.wait(
          apkFiles
              .where(
                (element) => element.path.split('/').last.startsWith('$appId-'),
              )
              .map((element) => element.delete(recursive: true)),
        );
        final cachedIcon = File('${iconsCacheDir.path}/$appId.png');
        if (cachedIcon.existsSync()) cachedIcon.deleteSync();
        if (apps.containsKey(appId)) {
          apps.remove(appId);
        }
      }),
    );
    if (appIds.isNotEmpty) {
      notify();
      scheduleAutoExport();
    }
  }

  Future<bool> removeAppsWithModal(BuildContext context, List<App> apps) async {
    final showUninstallOption = apps
        .where(
          (a) => a.installedVersion != null && !a.settings.getBool('trackOnly'),
        )
        .isNotEmpty;
    final values = await showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return GeneratedFormModal(
          primaryActionColour: Theme.of(context).colorScheme.error,
          title: plural('removeAppQuestion', apps.length),
          items: !showUninstallOption
              ? []
              : [
                  [
                    GeneratedFormSwitch(
                      'rmAppEntry',
                      label: tr('removeFromObtainium'),
                      value: true,
                    ),
                  ],
                  [
                    GeneratedFormSwitch(
                      'uninstallApp',
                      label: tr('uninstallFromDevice'),
                    ),
                  ],
                ],
          initValid: true,
        );
      },
    );
    if (values != null) {
      final bool uninstall =
          values['uninstallApp'] == true && showUninstallOption;
      final bool remove = values['rmAppEntry'] == true || !showUninstallOption;
      if (uninstall) {
        for (var i = 0; i < apps.length; i++) {
          if (apps[i].installedVersion != null) {
            await uninstallApp(apps[i].id);
            apps[i] = apps[i].copyWith(installedVersion: null);
          }
        }
        await saveApps(apps, attemptToCorrectInstallStatus: false);
      }
      if (remove) {
        await removeApps(apps.map((e) => e.id).toList());
      }
      return remove;
    }
    return false;
  }

  Future<void> openAppSettings(String appId) async {
    final AndroidIntent intent = AndroidIntent(
      action: 'action_application_details_settings',
      data: 'package:$appId',
    );
    await intent.launch();
  }

  void addMissingCategories(SettingsProvider settingsProvider) {
    final cats = Map<String, int>.from(settingsProvider.categories);
    apps.forEach((key, value) {
      for (var c in value.app.categories) {
        if (!cats.containsKey(c)) {
          cats[c] = generateRandomLightColor().toARGB32();
        }
      }
    });
    settingsProvider.setCategories(cats, appsProvider: this);
  }
}
