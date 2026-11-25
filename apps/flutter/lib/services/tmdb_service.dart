import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Acteur / membre de l'équipe d'un film.
class TmdbPerson {
  final int id;
  final String name;
  final String? role;
  final String? photoUrl;
  final String? department;

  TmdbPerson({
    required this.id,
    required this.name,
    this.role,
    this.photoUrl,
    this.department,
  });
}

/// Fiche d'un film ou d'une série sur TMDB.
class TmdbDetails {
  final int id;
  final bool isTv;
  final String title;
  final String? originalTitle;
  final String? overview;
  final double voteAverage;
  final int voteCount;
  final String? releaseDate;
  final int? runtimeMinutes;
  final List<String> genres;
  final String? posterUrl;
  final String? backdropUrl;
  final List<TmdbPerson> cast;
  final List<String> directors;
  final String? trailerKey;

  TmdbDetails({
    required this.id,
    required this.isTv,
    required this.title,
    this.originalTitle,
    this.overview,
    required this.voteAverage,
    required this.voteCount,
    this.releaseDate,
    this.runtimeMinutes,
    required this.genres,
    this.posterUrl,
    this.backdropUrl,
    required this.cast,
    required this.directors,
    this.trailerKey,
  });

  String? get year =>
      (releaseDate != null && releaseDate!.length >= 4) ? releaseDate!.substring(0, 4) : null;

  String get pageUrl =>
      'https://www.themoviedb.org/${isTv ? 'tv' : 'movie'}/$id';
}

/// Œuvre dans la filmographie d'un acteur.
class TmdbCredit {
  final int id;
  final bool isTv;
  final String title;
  final String? originalTitle;
  final String? year;
  final String? posterUrl;
  final String? character;
  final double popularity;

  TmdbCredit({
    required this.id,
    required this.isTv,
    required this.title,
    this.originalTitle,
    this.year,
    this.posterUrl,
    this.character,
    required this.popularity,
  });
}

/// Accès à l'API gratuite de The Movie Database (themoviedb.org) pour
/// récupérer résumé, note, acteurs et filmographies.
/// Nécessite une clé API gratuite, saisie dans les réglages.
class TmdbService {
  TmdbService._();
  static final TmdbService instance = TmdbService._();

  static const _prefKey = 'tmdb_api_key';
  static const _base = 'https://api.themoviedb.org/3';
  static const _img = 'https://image.tmdb.org/t/p';

  String? _apiKey;
  bool _loaded = false;
  String language = 'fr-FR';

  final Map<String, TmdbDetails?> _detailsCache = {};

  Future<String?> getApiKey() async {
    if (!_loaded) {
      final prefs = await SharedPreferences.getInstance();
      _apiKey = prefs.getString(_prefKey);
      _loaded = true;
    }
    return (_apiKey == null || _apiKey!.trim().isEmpty) ? null : _apiKey!.trim();
  }

  Future<bool> get isConfigured async => (await getApiKey()) != null;

  Future<void> setApiKey(String? key) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = key?.trim() ?? '';
    if (clean.isEmpty) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, clean);
    }
    _apiKey = clean;
    _loaded = true;
    _detailsCache.clear();
  }

  /// Vérifie qu'une clé fonctionne.
  Future<bool> testKey(String key) async {
    final res = await _get('/configuration', {}, overrideKey: key.trim());
    return res != null;
  }

  Future<Map<String, dynamic>?> _get(
    String path,
    Map<String, String> params, {
    String? overrideKey,
  }) async {
    final key = overrideKey ?? await getApiKey();
    if (key == null || key.isEmpty) return null;

    // Clé v3 (32 caractères) en paramètre, jeton v4 (long) en en-tête.
    final isBearer = key.length > 40;
    final query = <String, String>{
      ...params,
      if (!isBearer) 'api_key': key,
    };
    final uri = Uri.parse('$_base$path').replace(queryParameters: query);
    try {
      final res = await http.get(
        uri,
        headers: {
          'Accept': 'application/json',
          if (isBearer) 'Authorization': 'Bearer $key',
        },
      ).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final data = json.decode(utf8.decode(res.bodyBytes));
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  static String? _image(dynamic path, String size) {
    if (path is String && path.isNotEmpty) return '$_img/$size$path';
    return null;
  }

  /// Trouve la fiche d'un film. [tmdbId] (fourni par certains serveurs IPTV)
  /// est utilisé en priorité, sinon recherche par titre et année.
  Future<TmdbDetails?> getMovie({
    String? tmdbId,
    required String title,
    String? year,
  }) =>
      _getDetails(isTv: false, tmdbId: tmdbId, title: title, year: year);

  Future<TmdbDetails?> getTv({
    String? tmdbId,
    required String title,
    String? year,
  }) =>
      _getDetails(isTv: true, tmdbId: tmdbId, title: title, year: year);

  Future<TmdbDetails?> _getDetails({
    required bool isTv,
    String? tmdbId,
    required String title,
    String? year,
  }) async {
    final cacheKey = '${isTv ? 'tv' : 'movie'}|${tmdbId ?? ''}|$title|${year ?? ''}|$language';
    if (_detailsCache.containsKey(cacheKey)) return _detailsCache[cacheKey];
    if (!await isConfigured) return null;

    int? id = int.tryParse(tmdbId ?? '');
    if (id == null || id <= 0) {
      id = await _searchId(isTv: isTv, title: title, year: year);
      // Sans résultat avec l'année, on réessaie sans.
      if (id == null && year != null) {
        id = await _searchId(isTv: isTv, title: title, year: null);
      }
    }
    if (id == null) {
      _detailsCache[cacheKey] = null;
      return null;
    }

    final type = isTv ? 'tv' : 'movie';
    final data = await _get('/$type/$id', {
      'language': language,
      'append_to_response': 'credits,videos',
      'include_video_language': '${language.split('-').first},en,null',
    });
    if (data == null) {
      _detailsCache[cacheKey] = null;
      return null;
    }

    var overview = data['overview'] as String?;
    if (overview == null || overview.trim().isEmpty) {
      // Pas de résumé dans la langue choisie : on prend l'anglais.
      final en = await _get('/$type/$id', {'language': 'en-US'});
      overview = en?['overview'] as String?;
    }

    final credits = data['credits'] as Map<String, dynamic>? ?? {};
    final cast = (credits['cast'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .take(20)
        .map((c) => TmdbPerson(
              id: c['id'] as int,
              name: (c['name'] ?? '') as String,
              role: c['character'] as String?,
              photoUrl: _image(c['profile_path'], 'w185'),
            ))
        .toList();

    final directors = <String>[];
    if (isTv) {
      for (final c in (data['created_by'] as List? ?? [])) {
        if (c is Map && c['name'] is String) directors.add(c['name']);
      }
    } else {
      for (final c in (credits['crew'] as List? ?? [])) {
        if (c is Map && c['job'] == 'Director' && c['name'] is String) {
          directors.add(c['name']);
        }
      }
    }

    String? trailer;
    final videos = (data['videos']?['results'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .where((v) => v['site'] == 'YouTube')
        .toList();
    final t = videos.firstWhere(
      (v) => v['type'] == 'Trailer',
      orElse: () => videos.isNotEmpty ? videos.first : <String, dynamic>{},
    );
    trailer = t['key'] as String?;

    int? runtime = data['runtime'] as int?;
    if (runtime == null && isTv) {
      final rt = data['episode_run_time'];
      if (rt is List && rt.isNotEmpty && rt.first is int) runtime = rt.first;
    }

    final details = TmdbDetails(
      id: id,
      isTv: isTv,
      title: ((isTv ? data['name'] : data['title']) ?? title) as String,
      originalTitle:
          (isTv ? data['original_name'] : data['original_title']) as String?,
      overview: overview,
      voteAverage: (data['vote_average'] as num?)?.toDouble() ?? 0,
      voteCount: (data['vote_count'] as num?)?.toInt() ?? 0,
      releaseDate:
          (isTv ? data['first_air_date'] : data['release_date']) as String?,
      runtimeMinutes: runtime,
      genres: (data['genres'] as List? ?? [])
          .whereType<Map>()
          .map((g) => g['name'].toString())
          .toList(),
      posterUrl: _image(data['poster_path'], 'w500'),
      backdropUrl: _image(data['backdrop_path'], 'w1280'),
      cast: cast,
      directors: directors,
      trailerKey: trailer,
    );
    _detailsCache[cacheKey] = details;
    return details;
  }

  Future<int?> _searchId({
    required bool isTv,
    required String title,
    String? year,
  }) async {
    final data = await _get('/search/${isTv ? 'tv' : 'movie'}', {
      'query': title,
      'language': language,
      'include_adult': 'false',
      if (year != null) (isTv ? 'first_air_date_year' : 'year'): year,
    });
    final results = data?['results'] as List?;
    if (results == null || results.isEmpty) return null;
    final first = results.first;
    return first is Map ? first['id'] as int? : null;
  }

  /// Recherche d'acteurs / actrices par nom.
  Future<List<TmdbPerson>> searchPeople(String query) async {
    if (query.trim().isEmpty) return [];
    final data = await _get('/search/person', {
      'query': query.trim(),
      'language': language,
      'include_adult': 'false',
    });
    return (data?['results'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((p) => TmdbPerson(
              id: p['id'] as int,
              name: (p['name'] ?? '') as String,
              photoUrl: _image(p['profile_path'], 'w185'),
              department: p['known_for_department'] as String?,
            ))
        .toList();
  }

  /// Filmographie complète (films + séries) d'une personne.
  Future<List<TmdbCredit>> getPersonCredits(int personId) async {
    final data = await _get('/person/$personId/combined_credits', {
      'language': language,
    });
    final list = <TmdbCredit>[];
    final seen = <String>{};
    final all = [
      ...(data?['cast'] as List? ?? []),
      ...(data?['crew'] as List? ?? []).where(
        (c) => c is Map && c['job'] == 'Director',
      ),
    ];
    for (final c in all.whereType<Map<String, dynamic>>()) {
      final isTv = c['media_type'] == 'tv';
      final id = c['id'] as int?;
      if (id == null || !seen.add('$isTv$id')) continue;
      final date = (isTv ? c['first_air_date'] : c['release_date']) as String?;
      list.add(TmdbCredit(
        id: id,
        isTv: isTv,
        title: ((isTv ? c['name'] : c['title']) ?? '') as String,
        originalTitle:
            (isTv ? c['original_name'] : c['original_title']) as String?,
        year: (date != null && date.length >= 4) ? date.substring(0, 4) : null,
        posterUrl: _image(c['poster_path'], 'w342'),
        character: c['character'] as String?,
        popularity: (c['popularity'] as num?)?.toDouble() ?? 0,
      ));
    }
    list.sort((a, b) => b.popularity.compareTo(a.popularity));
    return list;
  }
}
