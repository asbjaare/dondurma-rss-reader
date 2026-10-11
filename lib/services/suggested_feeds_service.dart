import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/suggested_feed.dart';

/// Curated global suggestions with an offline fallback, and country catalogs
/// bundled with the app so country discovery needs no network connection.
class SuggestedFeedsService {
  SuggestedFeedsService({AssetBundle? assets}) : _assets = assets ?? rootBundle;

  final AssetBundle _assets;
  static const _base =
      'https://raw.githubusercontent.com/DevOpen-io/dondurma-rss-reader/'
      'refs/heads/main/remote_data';

  Future<List<SuggestedFeed>> fetchGlobal() async {
    try {
      final response = await http
          .get(Uri.parse('$_base/suggested_feeds.json'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception('Failed to load feeds: ${response.statusCode}');
      }
      return _decode(response.body);
    } catch (_) {
      return _fetchAsset('suggested_feeds.json');
    }
  }

  Future<List<SuggestedFeed>> fetchCountry(SuggestedFeedCountry country) =>
      _fetchAsset(country.catalogFile);

  Future<List<SuggestedFeed>> _fetchAsset(String file) async =>
      _decode(await _assets.loadString('remote_data/$file'));

  List<SuggestedFeed> _decode(String data) =>
      (jsonDecode(data) as List<dynamic>)
          .map((item) => SuggestedFeed.fromJson(item as Map<String, dynamic>))
          .toList();
}
