import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../models/feed_item.dart';
import '../models/feed_subscription.dart';
import 'background_feed_store.dart';
import 'feed_cache_policy.dart';
import 'observed_article_persistence_io.dart';
import 'feed_service.dart';
import 'notification_delivery_policy.dart';
import 'notification_service.dart';
import 'observed_article_store.dart';
import 'widget_update_service.dart';

/// Unique name of the periodic background fetch task.
const String _bgTaskName = 'rss_bg_fetch';

/// WorkManager dispatcher entry-point. Runs in a background isolate, so it must
/// be a top-level function annotated with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await runBgFetch();
    } catch (e) {
      debugPrint('[WM] task error: $e');
    }
    // Always report success — a failed fetch shouldn't trigger WorkManager's
    // exponential backoff retry; the next periodic run will try again.
    return true;
  });
}

/// Registers the periodic background fetch task. Idempotent — `keep` policy
/// means re-registering on every launch never resets an existing schedule.
Future<void> registerBgFetch() async {
  await Workmanager().registerPeriodicTask(
    _bgTaskName,
    _bgTaskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

/// Fetches all subscribed feeds and fires a notification for new articles.
///
/// The worker uses atomic snapshots only; it never opens foreground Hive files.
Future<void> runBgFetch({BackgroundFeedStore? store}) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    store ??= BackgroundFeedStore(directory.path);
    final snapshot = await store.read();
    if (snapshot == null || snapshot['config'] is! Map) return;
    final config = Map<String, dynamic>.from(snapshot['config'] as Map);
    if (config['syncBackground'] != true) return;
    final revision = snapshot['revision'] as int;
    await NotificationService.instance.init();

    debugPrint('[BG] task started');

    // Delivery settings never short-circuit observation/synchronization.
    final bool notificationsEnabled = config['notificationsEnabled'] as bool? ?? true;
    final String digestMode = config['digestMode'] as String? ?? 'instant';
    final bool quietHoursEnabled = config['quietHoursEnabled'] as bool? ?? true;
    final int quietStart = config['quietHoursStart'] as int? ?? 22;
    final int quietEnd = config['quietHoursEnd'] as int? ?? 7;

    // Read subscriptions
    final String? subsData = config['subscriptions'] as String?;
    if (subsData == null) return;
    final List<dynamic> subsList = jsonDecode(subsData);
    final subscriptions = subsList
        .map((e) => FeedSubscription.fromJson(e))
        .toList();
    if (subscriptions.isEmpty) return;

    // Feed URLs where notifications are muted
    final mutedUrls = subscriptions
        .where((s) => !s.notificationsEnabled)
        .map((s) => s.url)
        .toSet();

    // Fetch all feeds — at learned redirect URLs when the foreground learned
    // one, so background passes skip the 301 hop too.
    final rawRedirects = config['feedRedirects'];
    final redirects = <String, String>{};
    if (rawRedirects is String && rawRedirects.isNotEmpty) {
      try {
        for (final e in (jsonDecode(rawRedirects) as Map).entries) {
          redirects[e.key.toString()] = e.value.toString();
        }
      } catch (_) {}
    }
    final feedService = FeedService();
    final results = await Future.wait(
      subscriptions.map((sub) async {
        final fetchUrl = redirects[sub.url] ?? sub.url;
        try {
          final result = await feedService.fetchFeed(fetchUrl, sub.category);
          return (
            subscription: sub,
            items: fetchUrl == sub.url
                ? result.items
                // Re-tag learned-URL items to canonical — the merge below is
                // keyed by subscription URL.
                : result.items
                      .map((i) => i.copyWith(feedUrl: sub.url))
                      .toList(),
            succeeded: true,
            fresh: !result.notModified,
            allowInitialization: !result.notModified,
          );
        } catch (_) {
          return (
            subscription: sub,
            items: <FeedItem>[],
            succeeded: false,
            fresh: false,
            allowInitialization: false,
          );
        }
      }),
    );
    feedService.dispose();

    final allItems = results.expand((result) => result.items).toList();
    debugPrint('[BG] fetched ${allItems.length} items total');

    final observedStore = ObservedArticleStore(
      FileObservedArticlePersistence(
        stateFile: File('${directory.path}/feeds.hive.observed-articles.json'),
      ),
    );
    final claimedItems = <FeedItem>[];
    for (final result in results) {
      if (!result.succeeded) continue;
      final claim = await observedStore.claimFeedBatch(
        feedUrl: result.subscription.url,
        observationEpoch: result.subscription.notificationEpoch,
        items: result.items,
        allowInitialization: result.allowInitialization,
      );
      claimedItems.addAll(claim.claimedItems);
    }

    // Replace only feeds with an authoritative fresh response. Failed and 304
    // feeds retain their durable articles.
    final freshItemsByFeed = <String, List<FeedItem>>{
      for (final result in results)
        if (result.succeeded && result.fresh)
          result.subscription.url: result.items,
    };
    if (freshItemsByFeed.isNotEmpty) {
      final merged = FeedCachePolicy.mergeFreshFeeds(
        existingItems: _readBgCache(snapshot['resultCache'] ?? config['cachedItemsJson']),
        freshItemsByFeed: freshItemsByFeed,
        subscribedFeedUrls: subscriptions.map((sub) => sub.url),
      );
      final limit = config['offlineCacheLimit'] as int? ?? 50;
      if (limit > 0) {
        final persisted = FeedCachePolicy.fairTrim(
          items: merged,
          subscribedFeedUrls: subscriptions.map((sub) => sub.url),
          limit: limit,
        );
        final committed = await store.commitCache(
          revision,
          jsonEncode(persisted.map((item) => item.toJson()).toList()),
        );
        if (!committed) return; // Configuration changed while fetching.
        await WidgetUpdateService.updateFeedWidgets(persisted);
      }
    }

    final currentSnapshot = await store.read();
    if (currentSnapshot?['revision'] != revision) return;

    final newItems = NotificationDeliveryPolicy.eligibleItems(
      claimedItems: claimedItems,
      notificationsEnabled: notificationsEnabled,
      digestMode: digestMode,
      quietHoursEnabled: quietHoursEnabled,
      quietHoursStart: quietStart,
      quietHoursEnd: quietEnd,
      mutedFeedUrls: mutedUrls,
    );

    debugPrint('[BG] ${newItems.length} new items, sending notification');
    if (newItems.isEmpty) return;

    // Sort newest-first so the notification headline and its tap target are the
    // most recent article — `allItems` arrives in feed-iteration order, not by
    // date, so `.first` would otherwise be an arbitrary new item.
    newItems.sort((a, b) => b.pubDate!.compareTo(a.pubDate!));

    final latestJson = jsonEncode(newItems.first.toJson());
    await NotificationService.instance.showNewArticlesNotification(
      newItems: newItems,
      notificationsEnabled: true,
      digestMode: 'instant',
      quietHoursEnabled: false, // already checked above
      quietHoursStart: 0,
      quietHoursEnd: 0,
      latestItemJson: latestJson,
    );
  } catch (e) {
    debugPrint('Background fetch error: $e');
  }
}

List<FeedItem> _readBgCache(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((entry) => FeedItem.fromJson(entry as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return const [];
  }
}
