import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce/hive.dart';

import 'observed_article_persistence_io.dart';

/// Atomic handoff between the foreground Hive owner and WorkManager.
/// Background isolates must never open the foreground's Hive files.
class BackgroundFeedStore {
  BackgroundFeedStore(String directory)
    : _file = FileObservedArticlePersistence(
        stateFile: File('$directory/dondurma-background-sync.json'),
      );

  final FileObservedArticlePersistence _file;

  Future<Map<String, dynamic>?> read() async {
    final raw = await _file.read();
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> &&
              decoded['revision'] is int && decoded['config'] is Map
          ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> publish(Map<String, dynamic> config) async {
    final result = await _file.runExclusive(() async {
      final previous = await read();
      if (jsonEncode(previous?['config']) == jsonEncode(config)) return;
      await _file.write(jsonEncode({
        'revision': ((previous?['revision'] as int?) ?? 0) + 1,
        'config': config,
      }));
    });
    if (!result.acquired) throw StateError('Background snapshot lock timed out');
  }

  /// Reject work begun before a subscription change, cache clear, or reset.
  Future<bool> commitCache(int revision, String cache) async {
    final result = await _file.runExclusive(() async {
      final current = await read();
      if (current == null || current['revision'] != revision) return false;
      current['resultCache'] = cache;
      await _file.write(jsonEncode(current));
      return true;
    });
    return result.acquired && result.value == true;
  }
}

/// Only used in the foreground. All Hive reads/writes stay in its owner isolate.
class BackgroundFeedBridge {
  BackgroundFeedBridge({required this.feeds, required this.settings})
    : store = BackgroundFeedStore(File(feeds.path!).parent.path);

  final Box feeds;
  final Box settings;
  final BackgroundFeedStore store;
  final List<StreamSubscription<BoxEvent>> _subscriptions = [];
  Future<void> _tail = Future<void>.value();

  static const _subscriptionKeys = [
    'subscriptions', 'custom_categories', 'category_icons', 'category_order',
  ];

  Map<String, dynamic> _configuration() => {
    for (final key in _subscriptionKeys) key: feeds.get(key),
    'cachedItemsJson': feeds.get('cachedItemsJson'),
    'feedRedirects': feeds.get('feedRedirects'),
    'syncBackground': settings.get('syncBackground', defaultValue: true),
    'offlineCacheLimit': settings.get('offlineCacheLimit', defaultValue: 50),
    'notificationsEnabled': settings.get('notificationsEnabled', defaultValue: true),
    'digestMode': settings.get('digestMode', defaultValue: 'instant'),
    'quietHoursEnabled': settings.get('quietHoursEnabled', defaultValue: true),
    'quietHoursStart': settings.get('quietHoursStart', defaultValue: 22),
    'quietHoursEnd': settings.get('quietHoursEnd', defaultValue: 7),
  };

  Future<void> start() async {
    // A missing subscription key is not an intentional empty list. Restore
    // the last atomic snapshot before anything can publish an empty default.
    try {
      final snapshot = await store.read();
      final saved = snapshot?['config'];
      if (feeds.get('subscriptions') == null && saved is Map &&
          saved['subscriptions'] is String &&
          jsonDecode(saved['subscriptions'] as String) is List) {
        for (final key in _subscriptionKeys) {
          if (feeds.get(key) == null && saved[key] != null) {
            await feeds.put(key, saved[key]);
          }
        }
      }
      await importCache();
    } catch (error) {
      debugPrint('Background snapshot recovery failed: $error');
    }
    try {
      await publish();
    } catch (error) {
      // A failed handoff disables background work, not access to user data.
      debugPrint('Background snapshot initialization failed: $error');
    }
    _subscriptions.add(feeds.watch().listen((_) => _publishSafely()));
    _subscriptions.add(settings.watch().listen((_) => _publishSafely()));
  }

  Future<void> publish() {
    final config = _configuration();
    final run = _tail.then((_) => store.publish(config));
    _tail = run.catchError((Object error) {
      debugPrint('Background snapshot save failed: $error');
    });
    return run;
  }

  void _publishSafely() => publish().ignore();

  Future<bool> importCache() async {
    await _tail;
    final snapshot = await store.read();
    if (snapshot == null ||
        jsonEncode(snapshot['config']) != jsonEncode(_configuration())) return false;
    final cache = snapshot['resultCache'];
    if (cache is String && cache != feeds.get('cachedItemsJson')) {
      await feeds.put('cachedItemsJson', cache);
      return true;
    }
    return false;
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _tail;
  }
}
