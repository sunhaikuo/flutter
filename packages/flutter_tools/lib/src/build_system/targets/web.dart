// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:package_config/package_config.dart';

import '../../artifacts.dart';
import '../../base/file_system.dart';
import '../../base/io.dart';
import '../../build_info.dart';
import '../../cache.dart';
import '../../convert.dart';
import '../../dart/language_version.dart';
import '../../dart/package_map.dart';
import '../../globals.dart' as globals;
import '../../project.dart';
import '../build_system.dart';
import '../depfile.dart';
import '../exceptions.dart';
import 'assets.dart';
import 'localizations.dart';

/// Whether the application has web plugins.
const String kHasWebPlugins = 'HasWebPlugins';

/// An override for the dart2js build mode.
///
/// Valid values are O1 (lowest, profile default) to O4 (highest, release default).
const String kDart2jsOptimization = 'Dart2jsOptimization';

/// Whether to disable dynamic generation code to satisfy csp policies.
const String kCspMode = 'cspMode';

/// Base href to set in index.html in flutter build command
const String kBaseHref = 'baseHref';

/// Placeholder for base href
const String kBaseHrefPlaceholder = r'$FLUTTER_BASE_HREF';

/// The caching strategy to use for service worker generation.
const String kServiceWorkerStrategy = 'ServiceWorkerStrategy';

/// Whether the dart2js build should output source maps.
const String kSourceMapsEnabled = 'SourceMaps';

/// Whether the dart2js native null assertions are enabled.
const String kNativeNullAssertions = 'NativeNullAssertions';

/// The caching strategy for the generated service worker.
enum ServiceWorkerStrategy {
  /// Download the app shell eagerly and all other assets lazily.
  /// Prefer the offline cached version.
  offlineFirst,
  /// Do not generate a service worker,
  none,
}

const String kOfflineFirst = 'offline-first';
const String kNoneWorker = 'none';

/// Convert a [value] into a [ServiceWorkerStrategy].
ServiceWorkerStrategy _serviceWorkerStrategyFromString(String? value) {
  switch (value) {
    case kNoneWorker:
      return ServiceWorkerStrategy.none;
    // offline-first is the default value for any invalid requests.
    default:
      return ServiceWorkerStrategy.offlineFirst;
  }
}

/// Generates an entry point for a web target.
// Keep this in sync with build_runner/resident_web_runner.dart
class WebEntrypointTarget extends Target {
  const WebEntrypointTarget();

  @override
  String get name => 'web_entrypoint';

  @override
  List<Target> get dependencies => const <Target>[];

  @override
  List<Source> get inputs => const <Source>[
    Source.pattern('{FLUTTER_ROOT}/packages/flutter_tools/lib/src/build_system/targets/web.dart'),
  ];

  @override
  List<Source> get outputs => const <Source>[
    Source.pattern('{BUILD_DIR}/main.dart'),
  ];

  @override
  Future<void> build(Environment environment) async {
    final String? targetFile = environment.defines[kTargetFile];
    final bool hasPlugins = environment.defines[kHasWebPlugins] == 'true';
    final Uri importUri = environment.fileSystem.file(targetFile).absolute.uri;
    // TODO(zanderso): support configuration of this file.
    const String packageFile = '.packages';
    final PackageConfig packageConfig = await loadPackageConfigWithLogging(
      environment.fileSystem.file(packageFile),
      logger: environment.logger,
    );
    final FlutterProject flutterProject = FlutterProject.current();
    final LanguageVersion languageVersion = determineLanguageVersion(
      environment.fileSystem.file(targetFile),
      packageConfig[flutterProject.manifest.appName],
      Cache.flutterRoot!,
    );

    // Use the PackageConfig to find the correct package-scheme import path
    // for the user application. If the application has a mix of package-scheme
    // and relative imports for a library, then importing the entrypoint as a
    // file-scheme will cause said library to be recognized as two distinct
    // libraries. This can cause surprising behavior as types from that library
    // will be considered distinct from each other.
    // By construction, this will only be null if the .packages file does not
    // have an entry for the user's application or if the main file is
    // outside of the lib/ directory.
    final String mainImport = packageConfig.toPackageUri(importUri)?.toString()
      ?? importUri.toString();

    String contents;
    if (hasPlugins) {
      final Uri generatedUri = environment.projectDir
        .childDirectory('lib')
        .childFile('generated_plugin_registrant.dart')
        .absolute
        .uri;
      final String generatedImport = packageConfig.toPackageUri(generatedUri)?.toString()
        ?? generatedUri.toString();
      contents = '''
// @dart=${languageVersion.major}.${languageVersion.minor}

import 'dart:ui' as ui;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import '$generatedImport';
import '$mainImport' as entrypoint;

Future<void> main() async {
  registerPlugins(webPluginRegistrar);
  await ui.webOnlyInitializePlatform();
  entrypoint.main();
}
''';
    } else {
      contents = '''
// @dart=${languageVersion.major}.${languageVersion.minor}

import 'dart:ui' as ui;

import '$mainImport' as entrypoint;

Future<void> main() async {
  await ui.webOnlyInitializePlatform();
  entrypoint.main();
}
''';
    }
    environment.buildDir.childFile('main.dart')
      .writeAsStringSync(contents);
  }
}

/// Compiles a web entry point with dart2js.
class Dart2JSTarget extends Target {
  const Dart2JSTarget();

  @override
  String get name => 'dart2js';

  @override
  List<Target> get dependencies => const <Target>[
    WebEntrypointTarget(),
    GenerateLocalizationsTarget(),
  ];

  @override
  List<Source> get inputs => const <Source>[
    Source.hostArtifact(HostArtifact.flutterWebSdk),
    Source.hostArtifact(HostArtifact.dart2jsSnapshot),
    Source.hostArtifact(HostArtifact.engineDartBinary),
    Source.pattern('{BUILD_DIR}/main.dart'),
    Source.pattern('{PROJECT_DIR}/.dart_tool/package_config_subset'),
  ];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  List<String> get depfiles => const <String>[
    'dart2js.d',
  ];

  String _collectOutput(ProcessResult result) {
    final String stdout = result.stdout is List<int>
        ? utf8.decode(result.stdout as List<int>)
        : result.stdout as String;
    final String stderr = result.stderr is List<int>
        ? utf8.decode(result.stderr as List<int>)
        : result.stderr as String;
    return stdout + stderr;
  }

  @override
  Future<void> build(Environment environment) async {
    final String? buildModeEnvironment = environment.defines[kBuildMode];
    if (buildModeEnvironment == null) {
      throw MissingDefineException(kBuildMode, name);
    }
    final BuildMode buildMode = getBuildModeForName(buildModeEnvironment);
    final bool sourceMapsEnabled = environment.defines[kSourceMapsEnabled] == 'true';
    final bool nativeNullAssertions = environment.defines[kNativeNullAssertions] == 'true';
    final Artifacts artifacts = globals.artifacts!;
    final String librariesSpec = (artifacts.getHostArtifact(HostArtifact.flutterWebSdk) as Directory).childFile('libraries.json').path;
    final List<String> sharedCommandOptions = <String>[
      artifacts.getHostArtifact(HostArtifact.engineDartBinary).path,
      '--disable-dart-dev',
      artifacts.getHostArtifact(HostArtifact.dart2jsSnapshot).path,
      '--libraries-spec=$librariesSpec',
      ...decodeCommaSeparated(environment.defines, kExtraFrontEndOptions),
      if (nativeNullAssertions)
        '--native-null-assertions',
      if (buildMode == BuildMode.profile)
        '-Ddart.vm.profile=true'
      else
        '-Ddart.vm.product=true',
      for (final String dartDefine in decodeDartDefines(environment.defines, kDartDefines))
        '-D$dartDefine',
      if (!sourceMapsEnabled)
        '--no-source-maps',
    ];

    // Run the dart2js compilation in two stages, so that icon tree shaking can
    // parse the kernel file for web builds.
    final ProcessResult kernelResult = await globals.processManager.run(<String>[
      ...sharedCommandOptions,
      '-o',
      environment.buildDir.childFile('app.dill').path,
      '--packages=.packages',
      '--cfe-only',
      environment.buildDir.childFile('main.dart').path, // dartfile
    ]);
    if (kernelResult.exitCode != 0) {
      throw Exception(_collectOutput(kernelResult));
    }

    final String? dart2jsOptimization = environment.defines[kDart2jsOptimization];
    final File outputJSFile = environment.buildDir.childFile('main.dart.js');
    final bool csp = environment.defines[kCspMode] == 'true';

    final ProcessResult javaScriptResult = await environment.processManager.run(<String>[
      ...sharedCommandOptions,
      if (dart2jsOptimization != null) '-$dart2jsOptimization' else '-O4',
      if (buildMode == BuildMode.profile) '--no-minify',
      if (csp) '--csp',
      '-o',
      outputJSFile.path,
      environment.buildDir.childFile('app.dill').path, // dartfile
    ]);
    if (javaScriptResult.exitCode != 0) {
      throw Exception(_collectOutput(javaScriptResult));
    }
    final File dart2jsDeps = environment.buildDir
      .childFile('app.dill.deps');
    if (!dart2jsDeps.existsSync()) {
      globals.printWarning('Warning: dart2js did not produced expected deps list at '
        '${dart2jsDeps.path}');
      return;
    }
    final DepfileService depfileService = DepfileService(
      fileSystem: globals.fs,
      logger: globals.logger,
    );
    final Depfile depfile = depfileService.parseDart2js(
      environment.buildDir.childFile('app.dill.deps'),
      outputJSFile,
    );
    depfileService.writeToFile(
      depfile,
      environment.buildDir.childFile('dart2js.d'),
    );
  }
}

/// Unpacks the dart2js compilation and resources to a given output directory.
class WebReleaseBundle extends Target {
  const WebReleaseBundle();

  @override
  String get name => 'web_release_bundle';

  @override
  List<Target> get dependencies => const <Target>[
    Dart2JSTarget(),
  ];

  @override
  List<Source> get inputs => const <Source>[
    Source.pattern('{BUILD_DIR}/main.dart.js'),
    Source.pattern('{PROJECT_DIR}/pubspec.yaml'),
  ];

  @override
  List<Source> get outputs => const <Source>[
    Source.pattern('{OUTPUT_DIR}/main.dart.js'),
  ];

  @override
  List<String> get depfiles => const <String>[
    'dart2js.d',
    'flutter_assets.d',
    'web_resources.d',
  ];

  @override
  Future<void> build(Environment environment) async {
    for (final File outputFile in environment.buildDir.listSync(recursive: true).whereType<File>()) {
      final String basename = globals.fs.path.basename(outputFile.path);
      if (!basename.contains('main.dart.js')) {
        continue;
      }
      // Do not copy the deps file.
      if (basename.endsWith('.deps')) {
        continue;
      }
      outputFile.copySync(
        environment.outputDir.childFile(globals.fs.path.basename(outputFile.path)).path
      );
    }

    final String versionInfo = FlutterProject.current().getVersionInfo();
    environment.outputDir
        .childFile('version.json')
        .writeAsStringSync(versionInfo);
    final Directory outputDirectory = environment.outputDir.childDirectory('assets');
    outputDirectory.createSync(recursive: true);
    final Depfile depfile = await copyAssets(
      environment,
      environment.outputDir.childDirectory('assets'),
      targetPlatform: TargetPlatform.web_javascript,
    );
    final DepfileService depfileService = DepfileService(
      fileSystem: globals.fs,
      logger: globals.logger,
    );
    depfileService.writeToFile(
      depfile,
      environment.buildDir.childFile('flutter_assets.d'),
    );

    final Directory webResources = environment.projectDir
      .childDirectory('web');
    final List<File> inputResourceFiles = webResources
      .listSync(recursive: true)
      .whereType<File>()
      .toList();

    // Copy other resource files out of web/ directory.
    final List<File> outputResourcesFiles = <File>[];
    for (final File inputFile in inputResourceFiles) {
      final File outputFile = globals.fs.file(globals.fs.path.join(
        environment.outputDir.path,
        globals.fs.path.relative(inputFile.path, from: webResources.path)));
      if (!outputFile.parent.existsSync()) {
        outputFile.parent.createSync(recursive: true);
      }
      outputResourcesFiles.add(outputFile);
      // insert a random hash into the requests for service_worker.js. This is not a content hash,
      // because it would need to be the hash for the entire bundle and not just the resource
      // in question.
      if (environment.fileSystem.path.basename(inputFile.path) == 'index.html') {
        final String randomHash = Random().nextInt(4294967296).toString();
        String resultString = inputFile.readAsStringSync()
          .replaceFirst(
            'var serviceWorkerVersion = null',
            "var serviceWorkerVersion = '$randomHash'",
          )
          // This is for legacy index.html that still use the old service
          // worker loading mechanism.
          .replaceFirst(
            "navigator.serviceWorker.register('flutter_service_worker.js')",
            "navigator.serviceWorker.register('flutter_service_worker.js?v=$randomHash')",
          );
        final String? baseHref = environment.defines[kBaseHref];
        if (resultString.contains(kBaseHrefPlaceholder) && baseHref == null) {
          resultString = resultString.replaceAll(kBaseHrefPlaceholder, '/');
        } else if (resultString.contains(kBaseHrefPlaceholder) && baseHref != null) {
          resultString = resultString.replaceAll(kBaseHrefPlaceholder, baseHref);
        }
        outputFile.writeAsStringSync(resultString);
        continue;
      }
      inputFile.copySync(outputFile.path);
    }
    final Depfile resourceFile = Depfile(inputResourceFiles, outputResourcesFiles);
    depfileService.writeToFile(
      resourceFile,
      environment.buildDir.childFile('web_resources.d'),
    );
    // add js / images file with hash
    await ResourcesHandler.init(environment);
  }
}

/// Static assets provided by the Flutter SDK that do not change, such as
/// CanvasKit.
///
/// These assets can be cached forever and are only invalidated when the
/// Flutter SDK is upgraded to a new version.
class WebBuiltInAssets extends Target {
  const WebBuiltInAssets(this.fileSystem, this.cache);

  final FileSystem fileSystem;
  final Cache cache;

  @override
  String get name => 'web_static_assets';

  @override
  List<Target> get dependencies => const <Target>[];

  @override
  List<String> get depfiles => const <String>[];

  @override
  List<Source> get inputs => const <Source>[];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  Future<void> build(Environment environment) async {
    // TODO(yjbanov): https://github.com/flutter/flutter/issues/52588
    //
    // Update this when we start building CanvasKit from sources. In the
    // meantime, get the Web SDK directory from cache rather than through
    // Artifacts. The latter is sensitive to `--local-engine`, which changes
    // the directory to point to ENGINE/src/out. However, CanvasKit is not yet
    // built as part of the engine, but fetched from CIPD, and so it won't be
    // found in ENGINE/src/out.
    final Directory flutterWebSdk = cache.getWebSdkDirectory();
    final Directory canvasKitDirectory = flutterWebSdk.childDirectory('canvaskit');
    for (final File file in canvasKitDirectory.listSync(recursive: true).whereType<File>()) {
      final String relativePath = fileSystem.path.relative(file.path, from: canvasKitDirectory.path);
      final String targetPath = fileSystem.path.join(environment.outputDir.path, 'canvaskit', relativePath);
      file.copySync(targetPath);
    }
  }
}

/// Generate a service worker for a web target.
class WebServiceWorker extends Target {
  const WebServiceWorker(this.fileSystem, this.cache);

  final FileSystem fileSystem;
  final Cache cache;

  @override
  String get name => 'web_service_worker';

  @override
  List<Target> get dependencies => <Target>[
    const Dart2JSTarget(),
    const WebReleaseBundle(),
    WebBuiltInAssets(fileSystem, cache),
  ];

  @override
  List<String> get depfiles => const <String>[
    'service_worker.d',
  ];

  @override
  List<Source> get inputs => const <Source>[];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  Future<void> build(Environment environment) async {
    final List<File> contents = environment.outputDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File file) => !file.path.endsWith('flutter_service_worker.js')
        && !globals.fs.path.basename(file.path).startsWith('.'))
      .toList();

    final Map<String, String> urlToHash = <String, String>{};
    for (final File file in contents) {
      // Do not force caching of source maps.
      if (file.path.endsWith('main.dart.js.map') ||
        file.path.endsWith('.part.js.map')) {
        continue;
      }
      final String url = globals.fs.path.toUri(
        globals.fs.path.relative(
          file.path,
          from: environment.outputDir.path),
        ).toString();
      final String hash = md5.convert(await file.readAsBytes()).toString();
      urlToHash[url] = hash;
      // Add an additional entry for the base URL.
      if (globals.fs.path.basename(url) == 'index.html') {
        urlToHash['/'] = hash;
      }
    }

    final File serviceWorkerFile = environment.outputDir
      .childFile('flutter_service_worker.js');
    final Depfile depfile = Depfile(contents, <File>[serviceWorkerFile]);
    final ServiceWorkerStrategy serviceWorkerStrategy = _serviceWorkerStrategyFromString(
      environment.defines[kServiceWorkerStrategy],
    );
    final String mainJsHash = ResourcesHandler.getMainJsHash(environment);
    final String serviceWorker = generateServiceWorker(
      urlToHash,
      <String>[
        '/',
        'main.dart.$mainJsHash.js',
        'index.html',
        'assets/NOTICES',
        if (urlToHash.containsKey('assets/AssetManifest.json'))
          'assets/AssetManifest.json',
        if (urlToHash.containsKey('assets/FontManifest.json'))
          'assets/FontManifest.json',
      ],
      serviceWorkerStrategy: serviceWorkerStrategy,
    );
    serviceWorkerFile
      .writeAsStringSync(serviceWorker);
    final DepfileService depfileService = DepfileService(
      fileSystem: globals.fs,
      logger: globals.logger,
    );
    depfileService.writeToFile(
      depfile,
      environment.buildDir.childFile('service_worker.d'),
    );
  }
}

/// Generate a service worker with an app-specific cache name a map of
/// resource files.
///
/// The tool embeds file hashes directly into the worker so that the byte for byte
/// invalidation will automatically reactivate workers whenever a new
/// version is deployed.
String generateServiceWorker(
  Map<String, String> resources,
  List<String> coreBundle, {
  required ServiceWorkerStrategy serviceWorkerStrategy,
}) {
  if (serviceWorkerStrategy == ServiceWorkerStrategy.none) {
    return '';
  }
  return '''
'use strict';
const MANIFEST = 'flutter-app-manifest';
const TEMP = 'flutter-temp-cache';
const CACHE_NAME = 'flutter-app-cache';
const RESOURCES = {
  ${resources.entries.map((MapEntry<String, String> entry) => '"${entry.key}": "${entry.value}"').join(",\n")}
};

// The application shell files that are downloaded before a service worker can
// start.
const CORE = [
  ${coreBundle.map((String file) => '"$file"').join(',\n')}];
// During install, the TEMP cache is populated with the application shell files.
self.addEventListener("install", (event) => {
  self.skipWaiting();
  return event.waitUntil(
    caches.open(TEMP).then((cache) => {
      return cache.addAll(
        CORE.map((value) => new Request(value, {'cache': 'reload'})));
    })
  );
});

// During activate, the cache is populated with the temp files downloaded in
// install. If this service worker is upgrading from one with a saved
// MANIFEST, then use this to retain unchanged resource files.
self.addEventListener("activate", function(event) {
  return event.waitUntil(async function() {
    try {
      var contentCache = await caches.open(CACHE_NAME);
      var tempCache = await caches.open(TEMP);
      var manifestCache = await caches.open(MANIFEST);
      var manifest = await manifestCache.match('manifest');
      // When there is no prior manifest, clear the entire cache.
      if (!manifest) {
        await caches.delete(CACHE_NAME);
        contentCache = await caches.open(CACHE_NAME);
        for (var request of await tempCache.keys()) {
          var response = await tempCache.match(request);
          await contentCache.put(request, response);
        }
        await caches.delete(TEMP);
        // Save the manifest to make future upgrades efficient.
        await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
        return;
      }
      var oldManifest = await manifest.json();
      var origin = self.location.origin;
      for (var request of await contentCache.keys()) {
        var key = request.url.substring(origin.length + 1);
        if (key == "") {
          key = "/";
        }
        // If a resource from the old manifest is not in the new cache, or if
        // the MD5 sum has changed, delete it. Otherwise the resource is left
        // in the cache and can be reused by the new service worker.
        if (!RESOURCES[key] || RESOURCES[key] != oldManifest[key]) {
          await contentCache.delete(request);
        }
      }
      // Populate the cache with the app shell TEMP files, potentially overwriting
      // cache files preserved above.
      for (var request of await tempCache.keys()) {
        var response = await tempCache.match(request);
        await contentCache.put(request, response);
      }
      await caches.delete(TEMP);
      // Save the manifest to make future upgrades efficient.
      await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
      return;
    } catch (err) {
      // On an unhandled exception the state of the cache cannot be guaranteed.
      console.error('Failed to upgrade service worker: ' + err);
      await caches.delete(CACHE_NAME);
      await caches.delete(TEMP);
      await caches.delete(MANIFEST);
    }
  }());
});

// The fetch handler redirects requests for RESOURCE files to the service
// worker cache.
self.addEventListener("fetch", (event) => {
  if (event.request.method !== 'GET') {
    return;
  }
  var origin = self.location.origin;
  var key = event.request.url.substring(origin.length + 1);
  // Redirect URLs to the index.html
  if (key.indexOf('?v=') != -1) {
    key = key.split('?v=')[0];
  }
  if (event.request.url == origin || event.request.url.startsWith(origin + '/#') || key == '') {
    key = '/';
  }
  // If the URL is not the RESOURCE list then return to signal that the
  // browser should take over.
  if (!RESOURCES[key]) {
    return;
  }
  // If the URL is the index.html, perform an online-first request.
  if (key == '/') {
    return onlineFirst(event);
  }
  event.respondWith(caches.open(CACHE_NAME)
    .then((cache) =>  {
      return cache.match(event.request).then((response) => {
        // Either respond with the cached resource, or perform a fetch and
        // lazily populate the cache.
        return response || fetch(event.request).then((response) => {
          cache.put(event.request, response.clone());
          return response;
        });
      })
    })
  );
});

self.addEventListener('message', (event) => {
  // SkipWaiting can be used to immediately activate a waiting service worker.
  // This will also require a page refresh triggered by the main worker.
  if (event.data === 'skipWaiting') {
    self.skipWaiting();
    return;
  }
  if (event.data === 'downloadOffline') {
    downloadOffline();
    return;
  }
});

// Download offline will check the RESOURCES for all files not in the cache
// and populate them.
async function downloadOffline() {
  var resources = [];
  var contentCache = await caches.open(CACHE_NAME);
  var currentContent = {};
  for (var request of await contentCache.keys()) {
    var key = request.url.substring(origin.length + 1);
    if (key == "") {
      key = "/";
    }
    currentContent[key] = true;
  }
  for (var resourceKey of Object.keys(RESOURCES)) {
    if (!currentContent[resourceKey]) {
      resources.push(resourceKey);
    }
  }
  return contentCache.addAll(resources);
}

// Attempt to download the resource online before falling back to
// the offline cache.
function onlineFirst(event) {
  return event.respondWith(
    fetch(event.request).then((response) => {
      return caches.open(CACHE_NAME).then((cache) => {
        cache.put(event.request, response.clone());
        return response;
      });
    }).catch((error) => {
      return caches.open(CACHE_NAME).then((cache) => {
        return cache.match(event.request).then((response) => {
          if (response != null) {
            return response;
          }
          throw error;
        });
      });
    })
  );
}
''';
}

/// To make images / main.dart.js / xxx.part.js with hash.
/// the resources with hash can block browser use cache.
class ResourcesHandler {
  /// to cache the resources name and path
  static Map<String, List<String>> resourcesMap = <String, List<String>>{};
  // calculated main.dart.js hash
  static String _mainJsHash = '';

  /// the ResourcesHandler entry
  static Future<bool> init(Environment environment) async {
    await createResourcesMap(environment);
    await imagesAddHash(environment);
    _mainJsHash = await jsAddHash(environment);
    await replaceMainJsNameInHtml(environment, _mainJsHash);
    return true;
  }

  // get Instance
  ResourcesHandler getResourcesHandlerInstance() {
    return this;
  }

  /// get cached mainJsHash to test or other use
  static String getMainJsHash(Environment environment) {
    return _mainJsHash;
  }

  /// to general images map, the key is image relative path and the value is image with hash path
  /// like a/b/c.png --> a/b/c.[hash].png
  static Future<Map<String, String>> _getImagesMap(Environment environment) async {
    final Map<String, String> imagesMap = <String, String>{};
    final List<String> imageList = resourcesMap['image'] ?? <String>[];
    if (imageList != null) {
      for (int i = 0; i < imageList.length; i++) {
        final String imgPath = imageList[i];
        final List<String> list = imgPath.split('/');
        final String relativePath = list.sublist(list.length - 2).join('/');
        // final File file = globals.fs.file(imgPath);
        final File? file = _convertFullPathToFile(environment, imgPath);
        if (file != null) {
          final String hash = await _getFileMd5(file);
          imagesMap.putIfAbsent(
            relativePath,
                () => renameFileName(relativePath, hash),
          );
          final String newPath = renameFileName(imgPath, hash);
          await file.copy(newPath);
        }
        deleteFile(environment, imgPath);
      }
    }
    return Future<Map<String, String>>.value(imagesMap);
  }

  /// images add hash, like user.png --> user.[hash].png
  static Future<void> imagesAddHash(Environment environment) async{
    final Map<String, String> imagesMap = await _getImagesMap(environment);
    final List<String> list = resourcesMap['js'] ?? <String>[];
    final List<String> jsPartArr = <String>[];
    final RegExp mainJsReg = RegExp(r'main\.(.+)\.part\.js$');
    String mainDartJsPath = '';
    for (final String path in list) {
      if (mainJsReg.hasMatch(path)) {
        jsPartArr.add(path);
      } else if (path.endsWith('main.dart.js')) {
        mainDartJsPath = path;
      }
    }

    // final File mainJsFile = globals.fs.file(mainDartJsPath);
    final File? mainJsFile = _convertFullPathToFile(environment, mainDartJsPath);
    if (mainJsFile != null && mainJsFile.existsSync()) {
      String mainJsFileContent = mainJsFile.readAsStringSync();
      /// replace image new path in main.dart.js
      for (final String noMd5Path in imagesMap.keys) {
        final String md5Path = imagesMap[noMd5Path] ?? '';
        if (mainJsFileContent.contains(noMd5Path)) {
          final String newMainFileContent = mainJsFileContent.replaceAll(noMd5Path, md5Path);
          mainJsFile.writeAsStringSync(newMainFileContent);
          mainJsFileContent = newMainFileContent;
        }
        /// replace images new path in xxx.part.js
        for (final String jsPath in jsPartArr) {
          // final File jsFile = globals.fs.file(jsPath);
          final File? jsFile = _convertFullPathToFile(environment, jsPath);
          if (jsFile != null) {
            final String jsFileContent = jsFile.readAsStringSync();
            if (jsFileContent.contains(noMd5Path)) {
              final String newFileContent = jsFileContent.replaceAll(noMd5Path, md5Path);
              jsFile.writeAsStringSync(newFileContent);
            }
          }
        }
      }
    }
  }

  /// use js path to add sourcemap hash
  static void _sourceMapAddHash(Environment environment, String noMd5JsPath, String md5JsPath, String hash) {
    final String sourceMapPath = '$noMd5JsPath.map';
    final File? sourceMapFile = _convertFullPathToFile(environment, sourceMapPath);

    final String jsName = _getFileNameFromPath(noMd5JsPath);
    final String jsNameWithMd5 = _getFileNameFromPath(md5JsPath);
    final String sourceMapName = '$jsName.map';
    final String sourceMapNameWithHash = '$jsNameWithMd5.map';

    // final File jsFile = globals.fs.file(noMd5JsPath);
    final File? jsFile = _convertFullPathToFile(environment, noMd5JsPath);
    if (jsFile != null) {
      final String jsContent = jsFile.readAsStringSync();
      final String newJsContent = jsContent.replaceAll(sourceMapName, sourceMapNameWithHash);
      jsFile.writeAsStringSync(newJsContent);
    }
    // sourceMapFile.rename('$md5JsPath.map');
    if (sourceMapFile != null && sourceMapFile.existsSync()) {
      sourceMapFile.copy('$md5JsPath.map');
    }
  }

  /// xxx.part.js add hash, like main.dart.js_1.part.js --> main.dart.js_1.part.[hash].js
  static Future<String> jsAddHash(Environment environment) async{
    final List<String> list = resourcesMap['js'] ?? <String>[];
    final List<String> partJsPathArr = <String>[];
    String mainJsPath = '';
    String mainJsContent = '';
    final RegExp partReg = RegExp(r'main\.(.+)\.part\.js$');
    final RegExp mainReg = RegExp(r'main.dart.js$');
    String newMainJsPath = '';
    String mainHash = '';
    /// filter main.dart.js and xxx.part.js
    for (final String path in list) {
      if (partReg.hasMatch(path)) {
        partJsPathArr.add(path);
      } else if (mainReg.hasMatch(path)) {
        mainJsPath = path;
      }
    }
    // final File mainJsFile = globals.fs.file(mainJsPath);
    final File? mainJsFile = _convertFullPathToFile(environment, mainJsPath);
    if (mainJsFile != null) {
      mainHash = await _getFileMd5(mainJsFile);
      newMainJsPath = renameFileName(mainJsPath, mainHash);
      // main.dart.js add hash
      _sourceMapAddHash(environment, mainJsPath, newMainJsPath, mainHash);
      mainJsContent = mainJsFile.readAsStringSync();
    }


    /// craete xxx.part.[hash].js and replace new name in main.dart.js
    /// 1. rename part.js with hash
    /// 2. replace part.[hash].js in main.dart.js
    /// 3. modify sourcemap in part.js
    Future<void> _dealPartJs(String partJsPath) async {
      // final File partJsFile = globals.fs.file(partJsPath);
      final File? partJsFile = _convertFullPathToFile(environment, partJsPath);
      if (partJsFile != null) {
        final String partHash = await _getFileMd5(partJsFile);
        final String newPartJsPath = renameFileName(partJsPath, partHash);
        final String oldPartJsName = _getFileNameFromPath(partJsPath);
        final String newPartJsName = _getFileNameFromPath(newPartJsPath);
        // modify sourcemap in part.js
        _sourceMapAddHash(environment, partJsPath, newPartJsPath, partHash);
        // rename part.js with hash
        await partJsFile.rename(newPartJsPath);
        // replace part.[hash].js in main.dart.js
        mainJsContent = mainJsContent.replaceAll(oldPartJsName, newPartJsName);
      }
    }

    final List<Future<void>> futureList = <Future<void>>[];
    for (final String partJsPath in partJsPathArr) {
      futureList.add(_dealPartJs(partJsPath));
    }
    await Future.wait(futureList);

    // final File newMainJsFile = globals.fs.file(newMainJsPath);
    final File? newMainJsFile = _convertFullPathToFile(environment, newMainJsPath);
    if (newMainJsFile != null) {
      newMainJsFile.writeAsStringSync(mainJsContent);
      deleteFile(environment, mainJsPath);
    }
    return Future<String>.value(mainHash);
  }

  /// convert the full path to environment.outputDir for input
  static File? _convertFullPathToFile(Environment environment, String fullPath) {
    final Directory webResources = environment.outputDir;
    final String webPath = webResources.path;
    final List<String> list = fullPath.split(webPath);
    if (list != null && list.length > 1) {
      // /a/b/c/d.js --> c/d.js
      final String relativePath = list[1].substring(1);
      return webResources.childFile(relativePath);
    }
    return null;
  }

  /// to collect index.html / main.dart.js / xxx.part.js(s) to the resourcesMap
  /// to key is js or image or html, the values is the file path
  static Future<void> createResourcesMap(Environment environment) async {
    final Directory buildDir = environment.outputDir;
    if (await buildDir.exists()) {
      final Stream<FileSystemEntity> buildList = buildDir.list(recursive: true);
      await buildList.forEach((FileSystemEntity element) {
        final String path = element.path;
        final bool isDir = element.fileSystem.isDirectorySync(path);
        if (!isDir) {
          // like.gif close.png
          final String basename = element.basename;
          final RegExp mainJSReg = RegExp(r'main\.(.+)\.js');
          const String imageStr = '/images/';
          const String htmlStr = 'index.html';
          if (mainJSReg.hasMatch(basename)) {
            updateMap('js', path);
          } else if (path.contains(imageStr)) {
            updateMap('image', path);
          } else if (path.contains(htmlStr)) {
            updateMap('html', path);
          }
        }
      });
    }
  }

  /// the method to add / update key with values
  static void updateMap(String key, String value) {
    if (resourcesMap.containsKey(key)) {
      resourcesMap.update(key, (List<String> preList) {
        preList.add(value);
        return preList;
      });
    } else {
      resourcesMap.putIfAbsent(key, () {
        final List<String> list = <String>[];
        list.add(value);
        return list;
      });
    }
  }

  /// replace main.dart.js to hashed main.dart.js
  static Future<void> replaceMainJsNameInHtml(Environment environment, String mainJsHash) async{
    final File htmlFile = environment.outputDir.childFile('index.html');
    if (await htmlFile.exists()) {
      final String htmlContent = htmlFile.readAsStringSync();
      final String newHtmlContent = htmlContent.replaceAll('main.dart.js', 'main.dart.$mainJsHash.js');
      htmlFile.writeAsStringSync(newHtmlContent);
    }
  }

  /// rename file with new path
  /// like images/search.png to images/search.360e06.png
  static String renameFileName(String source, String insertStr) {
    final int end = source.lastIndexOf('.');
    final String preStr = source.substring(0, end);
    final String endStr = source.substring(end);
    final String newPath = '$preStr.$insertStr$endStr';
    return newPath;
  }

  /// like a/b/c.js --> c.js
  static String _getFileNameFromPath(String path) {
    final List<String> list = path.split('/');
    return list[list.length - 1];
  }

  /// delete one file
  static void deleteFile(Environment environment, String path) {
    // final File file = globals.fs.file(path);
    final File? file = _convertFullPathToFile(environment, path);
    if (file != null && file.existsSync()) {
      file.deleteSync();
    }
  }

  /// calculate file md5 value
  static Future<String> _getFileMd5(File file) async {
    final String md5Str = md5.convert(await file.readAsBytes()).toString();
    final String shortMd5 = md5Str.substring(md5Str.length - 6);
    return shortMd5;
  }
}
