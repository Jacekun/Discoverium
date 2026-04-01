import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/advanced_search.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:provider/provider.dart';

class DiscoveriumApp {
  final String name;
  final String description;
  final String? author;
  final String? url;
  final String? icon;
  final String? releasesUrl;
  final List<String> categories;
  final bool verified;
  final bool commercial;
  final String? releaseTitleFilterRegex;

  DiscoveriumApp({
    required this.name,
    required this.description,
    this.author,
    this.url,
    this.icon,
    this.releasesUrl,
    this.categories = const [],
    this.verified = true,
    this.commercial = false,
    this.releaseTitleFilterRegex,
  });

  factory DiscoveriumApp.fromYaml(Map<String, dynamic> yaml) {
    // Extract releases URL from nested structure
    String? releasesUrl;
    if (yaml['releases'] is Map && yaml['releases']['url'] != null) {
      releasesUrl = yaml['releases']['url'].toString();
    }

    // Handle both 'author' and 'authors' fields
    String? author;
    if (yaml['author'] != null) {
      author = yaml['author'].toString();
    } else if (yaml['authors'] != null) {
      author = yaml['authors'].toString();
    }

    // Handle both 'categories' (list) and 'category' (single) fields
    List<String> categories = [];
    if (yaml['categories'] is List) {
      categories = (yaml['categories'] as List).map((e) => e.toString()).toList();
    } else if (yaml['category'] != null) {
      categories = [yaml['category'].toString()];
    }

    // Parse verified field, default to true if not specified
    bool verified = yaml['verified'] == true;

    // Parse commercial field, default to false if not specified
    bool commercial = yaml['commercial'] == true; // Note: keeping the typo from YAML

    // Parse filters.release.title for release title regex filter
    String? releaseTitleFilterRegex;
    if (yaml['filters'] is Map) {
      final filters = yaml['filters'] as Map;
      final release = filters['release'];
      if (release is Map && release['title'] != null) {
        releaseTitleFilterRegex = release['title'].toString();
      }
    }

    return DiscoveriumApp(
      name: yaml['name']?.toString() ?? 'Unknown',
      description: yaml['description']?.toString() ?? 'No description',
      author: author,
      url: yaml['url']?.toString(),
      icon: yaml['icon']?.toString(),
      releasesUrl: releasesUrl,
      categories: categories,
      verified: verified,
      commercial: commercial,
      releaseTitleFilterRegex: releaseTitleFilterRegex,
    );
  }

  bool matchesSearch(String query) {
    final lowercaseQuery = query.toLowerCase();
    return name.toLowerCase().contains(lowercaseQuery) ||
          description.toLowerCase().contains(lowercaseQuery) ||
          (author?.toLowerCase().contains(lowercaseQuery) ?? false) ||
          categories.any((category) => category.toLowerCase().contains(lowercaseQuery));
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  // Static variables to preserve state across widget rebuilds
  static String _persistentSearchQuery = '';
  static List<DiscoveriumApp> _persistentAllApps = [];
  static List<DiscoveriumApp> _persistentFilteredApps = [];
  static bool _hasLoadedApps = false;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<DiscoveriumApp> _allApps = [];
  List<DiscoveriumApp> _filteredApps = [];
  bool _isLoading = false;
  String? _error;
  final Set<String> _failedImageUrls = <String>{};

  @override
  void initState() {
    super.initState();

    // Restore persistent state
    _searchController.text = _persistentSearchQuery;
    _allApps = List.from(_persistentAllApps);
    _filteredApps = List.from(_persistentFilteredApps);

    _searchController.addListener(_filterApps);

    // Auto-load apps only if not already loaded
    if (!_hasLoadedApps) {
      _loadApps();
    }
  }

  @override
  void dispose() {
    // Save persistent state
    _persistentSearchQuery = _searchController.text;
    _persistentAllApps = List.from(_allApps);
    _persistentFilteredApps = List.from(_filteredApps);

    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Get the branch setting from SettingsProvider
      final settingsProvider = context.read<SettingsProvider>();
      final branch = settingsProvider.discoveriumBranch;

      // Fetch apps.yml with the new simplified format
      final appsResponse = await http.get(
        Uri.parse('https://raw.githubusercontent.com/cygnusx-1-org/Discoverium/refs/heads/$branch/repo/apps.yml'),
      );

      if (appsResponse.statusCode != 200) {
        throw Exception('Failed to load apps.yml: ${appsResponse.statusCode}');
      }

      // Parse apps.yml directly as a list of apps
      final appsYaml = loadYaml(appsResponse.body);

      final List<DiscoveriumApp> apps = [];

      // The YAML is now directly a list of app objects
      if (appsYaml is List) {
        for (final appData in appsYaml) {
          if (appData is Map) {
            try {
              apps.add(DiscoveriumApp.fromYaml(Map<String, dynamic>.from(appData)));
            } catch (e) {
              print('Error parsing app data: $e');
              // Continue with other apps even if one fails
            }
          }
        }
      }

      setState(() {
        _allApps = apps;
        _isLoading = false;
      });

      // Mark apps as loaded
      _hasLoadedApps = true;

      // Apply filtering after loading
      _filterApps();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _filterApps() {
    final query = _searchController.text;
    final settingsProvider = context.read<SettingsProvider>();
    final allowUnverified = settingsProvider.allowUnverifiedApps;
    final allowCommercial = settingsProvider.allowCommercialApps;

    // Get existing apps to filter out already added apps
    final appsProvider = context.read<AppsProvider>();
    final existingApps = appsProvider.apps.values.map((appInfo) => appInfo.app).toList();

    // Create sets for efficient lookup
    final existingAppUrls = existingApps.map((app) => app.url.trim().toLowerCase()).toSet();
    final existingAppNames = existingApps.map((app) => '${app.name.toLowerCase()}|${app.author.toLowerCase()}').toSet();

    bool isAppAlreadyAdded(DiscoveriumApp app) {
      // Check if the release URL matches any existing app URL
      if (app.releasesUrl != null) {
        final normalizedReleaseUrl = app.releasesUrl!.trim().toLowerCase();
        if (existingAppUrls.contains(normalizedReleaseUrl)) {
          return true;
        }
      }

      // Also check by name + author combination as a fallback
      final appNameAuthor = '${app.name.toLowerCase()}|${(app.author ?? '').toLowerCase()}';
      if (existingAppNames.contains(appNameAuthor)) {
        return true;
      }

      return false;
    }

    setState(() {
      if (query.isEmpty) {
        _filteredApps = _allApps
            .where((app) =>
                (allowUnverified || app.verified) &&
                (allowCommercial || !app.commercial) &&
                !isAppAlreadyAdded(app))
            .toList();
      } else {
        _filteredApps = _allApps
            .where((app) =>
                app.matchesSearch(query) &&
                (allowUnverified || app.verified) &&
                (allowCommercial || !app.commercial) &&
                !isAppAlreadyAdded(app))
            .toList();
      }
    });
  }

  Future<void> _showAddAppDialog(DiscoveriumApp app) async {
    if (app.releasesUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('noReleasesUrl')),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(app.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.description),
              const SizedBox(height: 16),
              Text(
                tr('addAppConfirmation'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (app.author != null) ...[
                const SizedBox(height: 8),
                Text(
                  'By ${app.author}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('add')),
            ),
          ],
        );
      },
    );

    if (result == true) {
      await _addAppToMainList(app);
    }
  }

  Future<void> _addAppToMainList(DiscoveriumApp discoveriumApp) async {
    try {
      final releasesUrl = discoveriumApp.releasesUrl!;
      // Get providers
      final appsProvider = context.read<AppsProvider>();
      final settingsProvider = context.read<SettingsProvider>();
      final notificationsProvider = context.read<NotificationsProvider>();
      final sourceProvider = SourceProvider();

      // Show loading snackbar instead of changing main loading state
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Text(tr('addApp')),
            ],
          ),
          duration: const Duration(seconds: 30), // Long duration, will be dismissed manually
        ),
      );

      // Get app info from the releases URL
      final source = sourceProvider.getSource(releasesUrl);
      final defaultSettings = source != null
          ? getDefaultValuesFromFormItems(source.combinedAppSpecificSettingFormItems)
          : <String, dynamic>{};

      // Apply release title filter if provided in repo metadata
      if (discoveriumApp.releaseTitleFilterRegex != null &&
          discoveriumApp.releaseTitleFilterRegex!.isNotEmpty) {
        defaultSettings['filterReleaseTitlesByRegEx'] =
            discoveriumApp.releaseTitleFilterRegex;
      }

      final app = await sourceProvider.getApp(
        source,
        releasesUrl.trim(),
        defaultSettings,
        trackOnlyOverride: false,
        sourceIsOverriden: false,
        inferAppIdIfOptional: true,
      );

      // Check if app already exists
      if (appsProvider.apps.containsKey(app.id)) {
        throw ObtainiumError(tr('appAlreadyAdded'));
      }

      // Download APK if needed for package ID (only if not track-only)
      if (isTempId(app) && app.additionalSettings['trackOnly'] != true) {
        final apkUrl = await appsProvider.confirmAppFileUrl(app, context, false);
        if (apkUrl == null) {
          throw ObtainiumError(tr('cancelled'));
        }
        app.preferredApkIndex = app.apkUrls.map((e) => e.value).toList().indexOf(apkUrl.value);

        final downloadedArtifact = await appsProvider.downloadApp(
          app,
          globalNavigatorKey.currentContext,
          notificationsProvider: notificationsProvider,
        );

        DownloadedApk? downloadedFile;
        DownloadedDir? downloadedDir;
        if (downloadedArtifact is DownloadedApk) {
          downloadedFile = downloadedArtifact;
        } else {
          downloadedDir = downloadedArtifact as DownloadedDir;
        }
        app.id = downloadedFile?.appId ?? downloadedDir!.appId;
      }

      // Set installed version for track-only or non-version-detection apps
      if (app.additionalSettings['trackOnly'] == true ||
          app.additionalSettings['versionDetection'] != true) {
        app.installedVersion = app.latestVersion;
      }

      // Save the app
      await appsProvider.saveApps([app], onlyIfExists: false);

      // Dismiss the loading snackbar
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      // Show success message and navigate to app page
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('appAdded')),
          action: SnackBarAction(
            label: tr('view'),
            onPressed: () {
              Navigator.push(
                globalNavigatorKey.currentContext ?? context,
                MaterialPageRoute(builder: (context) => AppPage(appId: app.id)),
              );
            },
          ),
        ),
      );
    } catch (e) {
      // Hide loading snackbar and show error
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      showError(e, context);
    }
  }

    @override
  Widget build(BuildContext context) {
    // Watch the settings provider to rebuild when allowUnverifiedApps changes
    final settingsProvider = context.watch<SettingsProvider>();
    // Watch the apps provider to rebuild when apps are added/removed
    final appsProvider = context.watch<AppsProvider>();

    // Re-filter apps when the settings or apps change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_allApps.isNotEmpty) {
        _filterApps();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('searchApps')),
        elevation: 0,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AdvancedSearchPage()),
              );
            },
            child: const Text('Advanced Search'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: tr('searchHint'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_allApps.isEmpty && !_isLoading && _error != null)
                  ElevatedButton.icon(
                    onPressed: _loadApps,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr('retry')),
                  ),
              ],
            ),
          ),

          // Content area
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 64,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              tr('errorOccurred'),
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadApps,
                              child: Text(tr('retry')),
                            ),
                          ],
                        ),
                      )
                    : _filteredApps.isEmpty && _allApps.isNotEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.search_off,
                                  size: 64,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  tr('noResultsFound'),
                                  style: Theme.of(context).textTheme.headlineSmall,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  tr('tryDifferentSearch'),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          )
                        : _allApps.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.apps,
                                      size: 64,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      tr('noAppsLoaded'),
                                      style: Theme.of(context).textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      tr('loadAppsToSearch'),
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                key: const PageStorageKey<String>('searchList'),
                                controller: _scrollController,
                                itemCount: _filteredApps.length,
                                itemBuilder: (context, index) {
                                  final app = _filteredApps[index];
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 4,
                                    ),
                                    child: ListTile(
                                      leading: app.icon != null && !_failedImageUrls.contains(app.icon!)
                                          ? CircleAvatar(
                                              backgroundColor: Colors.white,
                                              backgroundImage: NetworkImage(app.icon!),
                                              onBackgroundImageError: (_, __) {
                                                setState(() {
                                                  _failedImageUrls.add(app.icon!);
                                                });
                                              },
                                            )
                                          : const CircleAvatar(
                                              child: Icon(Icons.apps),
                                            ),
                                      title: Text(
                                        app.name,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(app.description),
                                          if (app.author != null) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              'By ${app.author}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                          if (app.categories.isNotEmpty || app.commercial || !app.verified) ...[
                                            const SizedBox(height: 4),
                                            Wrap(
                                              spacing: 4,
                                              runSpacing: 4,
                                              children: [
                                                ...app.categories.map((category) => Chip(
                                                      label: Text(
                                                        category,
                                                        style: const TextStyle(fontSize: 10),
                                                      ),
                                                      materialTapTargetSize:
                                                          MaterialTapTargetSize.shrinkWrap,
                                                      visualDensity: VisualDensity.compact,
                                                    )),
                                                if (app.commercial)
                                                  Chip(
                                                    label: Text(
                                                      'Commercial',
                                                      style: const TextStyle(
                                                          fontSize: 10, color: Colors.white),
                                                    ),
                                                    backgroundColor:
                                                        const Color(0xFF4B0000), // Darker red
                                                    materialTapTargetSize:
                                                        MaterialTapTargetSize.shrinkWrap,
                                                    visualDensity: VisualDensity.compact,
                                                  ),
                                                if (!app.verified)
                                                  Chip(
                                                    label: Text(
                                                      'Unverified',
                                                      style: const TextStyle(
                                                          fontSize: 10, color: Colors.white),
                                                    ),
                                                    backgroundColor:
                                                        const Color(0xFF4B0000), // Darker red
                                                    materialTapTargetSize:
                                                        MaterialTapTargetSize.shrinkWrap,
                                                    visualDensity: VisualDensity.compact,
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                      isThreeLine: true,
                                      onTap: app.releasesUrl != null
                                          ? () {
                                              _showAddAppDialog(app);
                                            }
                                          : null,
                                    ),
                                  );
                                },
                              ),
          ),
        ],
      ),
    );
  }
}
