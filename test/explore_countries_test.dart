import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:provider/provider.dart';

import 'package:ice_cream_rss_reader/l10n/app_localizations.dart';
import 'package:ice_cream_rss_reader/models/suggested_feed.dart';
import 'package:ice_cream_rss_reader/providers/subscription_provider.dart';
import 'package:ice_cream_rss_reader/screens/explore_feeds_page.dart';
import 'package:ice_cream_rss_reader/services/suggested_feeds_service.dart';

SuggestedFeed _feed(String name) => SuggestedFeed(
  name: name,
  url: 'https://example.test/${Uri.encodeComponent(name)}.rss',
  category: 'News',
  popularity: 1,
);

class _CatalogService extends SuggestedFeedsService {
  final Map<SuggestedFeedCountry, Completer<List<SuggestedFeed>>> pending = {};

  @override
  Future<List<SuggestedFeed>> fetchGlobal() async => [_feed('Global feed')];

  @override
  Future<List<SuggestedFeed>> fetchCountry(SuggestedFeedCountry country) =>
      pending[country]?.future ??
      Future.value([
        _feed(
          country == SuggestedFeedCountry.norway
              ? 'Norwegian feed'
              : 'Turkish feed',
        ),
      ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SubscriptionProvider subscriptions;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('explore-countries-');
    Hive.init(directory.path);
    await Hive.openBox('feeds');
    subscriptions = SubscriptionProvider();
  });

  tearDownAll(() async {
    subscriptions.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Widget page(SuggestedFeedsService service) => ChangeNotifierProvider.value(
    value: subscriptions,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExploreFeedsPage(service: service),
    ),
  );

  test(
    'country catalogs are bundled and preserve Turkish suggestions',
    () async {
      final service = SuggestedFeedsService();
      final norway = await service.fetchCountry(SuggestedFeedCountry.norway);
      expect(norway, hasLength(17));
      expect(
        norway.map((feed) => feed.name),
        containsAll([
          'VG',
          'Aftenposten',
          'E24',
          'Teknisk Ukeblad',
          'Sykepleien',
          'Khrono',
          'forskning.no',
          'Dagens Medisin',
          'Utdanningsnytt',
        ]),
      );
      expect(norway.map((feed) => feed.url).toSet(), hasLength(norway.length));
      expect(
        norway.every((feed) => Uri.parse(feed.url).scheme == 'https'),
        isTrue,
      );
      expect(
        await service.fetchCountry(SuggestedFeedCountry.turkey),
        isNotEmpty,
      );
    },
  );

  test(
    'global suggestions fall back to bundled data on HTTP failure',
    () async {
      // The Flutter test binding's HTTP client returns 400.
      expect(await SuggestedFeedsService().fetchGlobal(), isNotEmpty);
    },
  );

  testWidgets('Countries defaults to Norway and can switch back and forth', (
    tester,
  ) async {
    await tester.pumpWidget(page(_CatalogService()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Countries'));
    await tester.pumpAndSettle();
    expect(find.text('Norwegian feed'), findsOneWidget);
    expect(find.text('Turkish'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('feed-country-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turkey').last);
    await tester.pumpAndSettle();
    expect(find.text('Turkish feed'), findsOneWidget);
    expect(find.text('Norwegian feed'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('feed-country-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Norway').last);
    await tester.pumpAndSettle();
    expect(find.text('Norwegian feed'), findsOneWidget);
    await tester.tap(find.text('Global'));
    await tester.pumpAndSettle();
    expect(find.text('Global feed'), findsOneWidget);
  });

  testWidgets('late country response cannot overwrite the selected country', (
    tester,
  ) async {
    final service = _CatalogService();
    final norway = Completer<List<SuggestedFeed>>();
    final turkey = Completer<List<SuggestedFeed>>();
    service.pending.addAll({
      SuggestedFeedCountry.norway: norway,
      SuggestedFeedCountry.turkey: turkey,
    });
    await tester.pumpWidget(page(service));
    await tester.pump();
    await tester.tap(find.text('Countries'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('feed-country-selector')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Turkey').last);
    turkey.complete([_feed('Turkish feed')]);
    await tester.pumpAndSettle();
    norway.complete([_feed('Wrong late feed')]);
    await tester.pumpAndSettle();
    expect(find.text('Turkish feed'), findsOneWidget);
    expect(find.text('Wrong late feed'), findsNothing);
  });

  testWidgets('closing discovery while a catalog loads is safe', (
    tester,
  ) async {
    final service = _CatalogService();
    final pending = Completer<List<SuggestedFeed>>();
    service.pending[SuggestedFeedCountry.norway] = pending;
    await tester.pumpWidget(page(service));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete([_feed('Late feed')]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
