import 'dart:async';
import 'dart:convert';

import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/services/tmdb_service.dart';
import 'package:another_iptv_player/utils/title_normalizer.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ce qu'on sait d'un film / d'une série pour le mode enfants.
class SafetyInfo {
  final int? age; // âge conseillé (null = inconnu)
  final bool horror;
  final bool found; // trouvé sur TMDB

  const SafetyInfo({this.age, this.horror = false, this.found = true});

  /// Flouté si déconseillé aux moins de 10 ans, ou film d'horreur.
  bool get unsafe => horror || (age != null && age! >= KidsMode.minAge);

  Map<String, dynamic> toJson() => {'a': age, 'h': horror, 'f': found};
  factory SafetyInfo.fromJson(Map<String, dynamic> j) => SafetyInfo(
        age: j['a'] as int?,
        horror: j['h'] == true,
        found: j['f'] != false,
      );
}

/// Mode enfants : floute les affiches des films / séries déconseillés aux
/// moins de 10 ans et des films d'horreur.
class KidsMode {
  KidsMode._();

  static const int minAge = 10;
  static const _prefEnabled = 'kids_mode_enabled';
  static const _prefCache = 'kids_mode_cache_v1';

  /// Interrupteur général (bouton œil).
  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  /// Change à chaque nouvelle info (affiche révélée, âge trouvé...).
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// Affiches que l'adulte a choisi d'afficher pendant cette session.
  static final Set<String> _revealed = {};

  /// Catégories du fournisseur dont le nom indique horreur / adulte.
  static final Set<String> unsafeCategoryIds = {};

  static final Map<String, SafetyInfo> _cache = {};
  static final Map<String, Future<SafetyInfo?>> _pending = {};
  static int _running = 0;
  static final List<Completer<void>> _queue = [];
  static Timer? _saveTimer;

  static final RegExp _unsafeWords = RegExp(
    r'horreur|horror|[ée]pouvante|terreur|gore|slasher|zombie|adult|xxx|'
    r'erotique|érotique|\+18|18\+|-18|\b18\b',
    caseSensitive: false,
  );

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_prefEnabled) ?? false;
      final raw = prefs.getString(_prefCache);
      if (raw != null) {
        final map = json.decode(raw) as Map<String, dynamic>;
        map.forEach((k, v) {
          if (v is Map<String, dynamic>) _cache[k] = SafetyInfo.fromJson(v);
        });
      }
      await TmdbService.instance.getApiKey(); // prépare isConfiguredSync
    } catch (e) {
      debugPrint('KidsMode load error: $e');
    }
  }

  static Future<void> toggle() async {
    enabled.value = !enabled.value;
    if (!enabled.value) _revealed.clear();
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, enabled.value);
  }

  static String keyOf(ContentItem item) =>
      '${item.contentType.name}|${TitleNormalizer.groupKey(item.name)}';

  static bool isRevealed(ContentItem item) => _revealed.contains(keyOf(item));

  static void toggleReveal(ContentItem item) {
    final k = keyOf(item);
    if (!_revealed.remove(k)) _revealed.add(k);
    revision.value++;
  }

  static void registerCategory(String categoryId, String categoryName) {
    if (_unsafeWords.hasMatch(categoryName)) unsafeCategoryIds.add(categoryId);
  }

  /// Indices sans internet : genre, catégorie, nom.
  static bool heuristicUnsafe(ContentItem item) {
    final genre = item.contentType == ContentType.vod
        ? item.vodStream?.genre
        : item.seriesStream?.genre;
    final cat = item.contentType == ContentType.vod
        ? item.vodStream?.categoryId
        : item.seriesStream?.categoryId;
    if (cat != null && unsafeCategoryIds.contains(cat)) return true;
    if (genre != null && _unsafeWords.hasMatch(genre)) return true;
    return false;
  }

  static SafetyInfo? cached(ContentItem item) => _cache[keyOf(item)];

  /// Cherche l'âge conseillé sur TMDB (3 recherches en parallèle maximum).
  static Future<SafetyInfo?> check(ContentItem item) {
    final k = keyOf(item);
    final c = _cache[k];
    if (c != null) return Future.value(c);
    return _pending[k] ??= _fetch(item, k);
  }

  static Future<SafetyInfo?> _fetch(ContentItem item, String k) async {
    if (_running >= 3) {
      final waiter = Completer<void>();
      _queue.add(waiter);
      await waiter.future;
    }
    _running++;
    try {
      final parsed = TitleNormalizer.parse(item.name);
      final res = await TmdbService.instance.getAgeInfo(
        isTv: item.contentType == ContentType.series,
        title: parsed.title,
        year: parsed.year,
      );
      final info = res == null
          ? const SafetyInfo(found: false)
          : SafetyInfo(age: res.age, horror: res.horror);
      _cache[k] = info;
      _scheduleSave();
      revision.value++;
      return info;
    } catch (_) {
      return null;
    } finally {
      _running--;
      _pending.remove(k);
      if (_queue.isNotEmpty) _queue.removeAt(0).complete();
    }
  }

  static void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () async {
      try {
        // On garde au plus 20 000 entrées.
        while (_cache.length > 20000) {
          _cache.remove(_cache.keys.first);
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _prefCache,
          json.encode(_cache.map((k, v) => MapEntry(k, v.toJson()))),
        );
      } catch (_) {}
    });
  }
}
