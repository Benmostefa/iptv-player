/// Analyse les noms de films / séries envoyés par les fournisseurs IPTV
/// (ex. "|FR| Avatar (2009) 4K", "FR - Avatar FHD MULTI") pour en tirer :
///  - une clé stable qui identifie l'œuvre quelle que soit la version,
///  - le titre propre à afficher,
///  - l'année, la qualité et la langue de la version.
class ParsedTitle {
  /// Clé de comparaison (minuscules, sans accents, sans tags).
  final String key;

  /// Titre nettoyé pour l'affichage.
  final String title;

  /// Année de sortie si elle figure dans le nom.
  final String? year;

  /// Libellé de qualité ("4K", "Full HD", "HD", "SD") ou null.
  final String? quality;

  /// Rang de qualité (4 = 4K ... 1 = SD, 0 = inconnu).
  final int qualityRank;

  /// Tags de langue détectés ("FR", "VOSTFR", "MULTI"...).
  final List<String> languages;

  /// Version HDR / Dolby Vision détectée.
  final bool hdr;

  const ParsedTitle({
    required this.key,
    required this.title,
    required this.year,
    required this.quality,
    required this.qualityRank,
    required this.languages,
    required this.hdr,
  });

  /// Libellé court de la version, ex. "4K HDR · MULTI".
  String get versionLabel {
    final parts = <String>[];
    final q = [if (quality != null) quality!, if (hdr) 'HDR'].join(' ');
    if (q.isNotEmpty) parts.add(q);
    if (languages.isNotEmpty) parts.add(languages.join('/'));
    return parts.join(' · ');
  }
}

class TitleNormalizer {
  TitleNormalizer._();

  static final Map<String, ParsedTitle> _cache = {};

  static const _languageTags = {
    'FR', 'VF', 'VFF', 'VFQ', 'VFI', 'VO', 'VOST', 'VOSTFR', 'TRUEFRENCH',
    'FRENCH', 'MULTI', 'EN', 'ENG', 'US', 'UK', 'AR', 'ES', 'DE', 'IT', 'PT',
    'TR', 'NL', 'BE', 'CA', 'QC', 'CH', 'AF', 'MA', 'DZ', 'TN', 'SN', 'CI',
    'NG', 'LAT', 'SUB', 'DUB',
  };

  // Tags de langue qu'on accepte de retirer en fin de titre.
  static const _trailingLanguageTags = {
    'FR', 'VF', 'VFF', 'VFQ', 'VFI', 'VO', 'VOST', 'VOSTFR', 'TRUEFRENCH',
    'FRENCH', 'MULTI', 'ENG', 'SUB', 'SUBFRENCH', 'VOSTA',
  };

  // Tags techniques à retirer du titre (hors qualité, traitée à part).
  static final _technicalTag = RegExp(
    r'\b(hevc|x26[45]|h[.\s]?26[45]|10\s?bits?|hdr10\+?|hdr|dolby\s?vision|dv|'
    r'atmos|dts(?:-?hd)?|truehd|ac3|e-?ac3|aac|web-?dl|webrip|bluray|blu-ray|'
    r'brrip|bdrip|remux|imax|3d|extended|director.?s cut|uncut)\b',
    caseSensitive: false,
  );

  static final _hdrTag = RegExp(
    r'\b(hdr10\+?|hdr|dolby\s?vision|dv)\b',
    caseSensitive: false,
  );

  static final _q4k = RegExp(r'\b(4k|uhd|2160p?)\b', caseSensitive: false);
  static final _qFhd = RegExp(r'\b(fhd|full\s?hd|1080[pi]?)\b',
      caseSensitive: false);
  static final _qHd = RegExp(r'\b(hd|720p?)\b', caseSensitive: false);
  static final _qSd = RegExp(r'\b(sd|480p?|576p?)\b', caseSensitive: false);

  // Préfixe entre délimiteurs : "|FR|", "[FR]", "(VF)", "★ FR ★"...
  static final _bracketPrefix =
      RegExp(r'^\s*[\[\(|★✦•*]\s*([^\]\)|★✦•*]{1,12}?)\s*[\]\)|★✦•*]\s*[-:–|]?\s*');

  // Préfixe simple : "FR - ", "FR: ", "4K | ", "VOD - "...
  static final _plainPrefix =
      RegExp(r'^\s*([A-Za-z0-9+]{2,8})\s*[-:–|]\s+');

  static final _yearAtEnd = RegExp(r'[\(\[\s\-]((?:19|20)\d{2})[\)\]]?\s*$');
  static final _yearInParens = RegExp(r'[\(\[]((?:19|20)\d{2})[\)\]]');

  static ParsedTitle parse(String raw) {
    final cached = _cache[raw];
    if (cached != null) return cached;
    final parsed = _parse(raw);
    if (_cache.length > 200000) _cache.clear();
    _cache[raw] = parsed;
    return parsed;
  }

  /// Clé de regroupement : clé + année si connue.
  static String groupKey(String raw) {
    final p = parse(raw);
    return p.year == null ? p.key : '${p.key}|${p.year}';
  }

  static ParsedTitle _parse(String raw) {
    var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Noms façon fichier : "Avatar.2009.MULTI.2160p" → "Avatar 2009 MULTI 2160p".
    final dots = '.'.allMatches(s).length + '_'.allMatches(s).length;
    if (dots >= 2 && ' '.allMatches(s).length < dots) {
      s = s.replaceAll(RegExp(r'[._]+'), ' ').trim();
    }
    final languages = <String>[];

    // Qualité (détectée sur le nom complet, préfixes compris).
    String? quality;
    var rank = 0;
    if (_q4k.hasMatch(s)) {
      quality = '4K';
      rank = 4;
    } else if (_qFhd.hasMatch(s)) {
      quality = 'Full HD';
      rank = 3;
    } else if (_qHd.hasMatch(s)) {
      quality = 'HD';
      rank = 2;
    } else if (_qSd.hasMatch(s)) {
      quality = 'SD';
      rank = 1;
    }
    final hdr = _hdrTag.hasMatch(s);

    // 1. Retire les préfixes de langue / catégorie (jusqu'à 3).
    for (var i = 0; i < 3; i++) {
      final b = _bracketPrefix.firstMatch(s);
      if (b != null &&
          b
              .group(1)!
              .split(RegExp(r'[\s/,+\-]+'))
              .where((t) => t.isNotEmpty)
              .every(_isPrefixToken)) {
        _collectLanguages(b.group(1)!, languages);
        s = s.substring(b.end);
        continue;
      }
      final p = _plainPrefix.firstMatch(s);
      if (p != null && _isPrefixToken(p.group(1)!)) {
        _collectLanguages(p.group(1)!, languages);
        s = s.substring(p.end);
        continue;
      }
      break;
    }

    // 3. Année.
    String? year;
    final yParens = _yearInParens.firstMatch(s);
    if (yParens != null) {
      year = yParens.group(1);
      s = s.replaceRange(yParens.start, yParens.end, ' ');
    } else {
      final yEnd = _yearAtEnd.firstMatch(s);
      // On ne retire pas l'année si c'est tout le titre (ex. "1917", "2012").
      if (yEnd != null && yEnd.start > 0) {
        year = yEnd.group(1);
        s = s.substring(0, yEnd.start);
      }
    }

    // 4. Retire qualité, tags techniques et tags de langue isolés.
    s = s
        .replaceAll(_q4k, ' ')
        .replaceAll(_qFhd, ' ')
        .replaceAll(_qHd, ' ')
        .replaceAll(_qSd, ' ')
        .replaceAll(_technicalTag, ' ');

    s = s.replaceAllMapped(RegExp(r'[\[\(]([^\]\)]*)[\]\)]'), (m) {
      final inner = m.group(1)!.trim();
      if (inner.isEmpty) return ' ';
      final tokens = inner.split(RegExp(r'[\s/,+\-]+'));
      if (tokens.every((t) => t.isEmpty || _languageTags.contains(t.toUpperCase()))) {
        _collectLanguages(inner, languages);
        return ' ';
      }
      return m.group(0)!;
    });

    final words = s.split(' ');
    while (words.isNotEmpty) {
      final last = words.last.replaceAll(RegExp(r'[^A-Za-z]'), '');
      if (words.last.trim().isEmpty ||
          RegExp(r'^[\-–|:•.]+$').hasMatch(words.last)) {
        words.removeLast();
      } else if (_trailingLanguageTags.contains(last.toUpperCase()) &&
          last.length >= 2 &&
          words.length > 1 &&
          (last.length >= 4 || words.last == words.last.toUpperCase())) {
        _collectLanguages(last, languages);
        words.removeLast();
      } else {
        break;
      }
    }
    s = words.join(' ');

    // Année placée avant les tags : "Avatar 2009 MULTI 2160p".
    if (year == null) {
      final yEnd = _yearAtEnd.firstMatch(s.trimRight());
      if (yEnd != null && yEnd.start > 0) {
        year = yEnd.group(1);
        s = s.substring(0, yEnd.start);
      }
    }

    var title = s
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s\-–|:•.]+|[\s\-–|:•.]+$'), '')
        .trim();
    if (title.isEmpty) title = raw.trim();

    return ParsedTitle(
      key: normalizeKey(title),
      title: title,
      year: year,
      quality: quality,
      qualityRank: rank,
      languages: languages,
      hdr: hdr,
    );
  }

  static bool _isPrefixToken(String token) {
    final up = token.toUpperCase();
    return _languageTags.contains(up) ||
        RegExp(r'^(4K|UHD|FHD|HD|SD|VOD|NF|NETFLIX|AMZ|DSNP|APPLE|HBO|CANAL|TOP|NEW|MULTI)$')
            .hasMatch(up) ||
        // Codes pays/catégorie courts en majuscules (ex. "AFR", "EXYU").
        (token == up && RegExp(r'^[A-Z]{2,4}$').hasMatch(token));
  }

  static void _collectLanguages(String chunk, List<String> out) {
    for (final t in chunk.split(RegExp(r'[\s/,+\-]+'))) {
      final up = t.toUpperCase();
      if (_languageTags.contains(up) && !out.contains(up)) out.add(up);
    }
  }

  static const _accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae',
    'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i', 'í': 'i',
    'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o',
    'ö': 'o', 'ø': 'o', 'œ': 'oe', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y', 'ß': 'ss',
  };

  /// Minuscules, sans accents ni ponctuation, espaces simples.
  static String normalizeKey(String input) {
    final lower = input.toLowerCase();
    final buf = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      buf.write(_accents[ch] ?? ch);
    }
    return buf
        .toString()
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r"[’'`]"), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}
