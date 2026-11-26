import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/utils/title_normalizer.dart';

/// Regroupe les films présents en plusieurs versions (4K / HD / SD / langues)
/// pour n'afficher qu'une seule affiche par film.
class ContentGrouping {
  ContentGrouping._();

  /// Retourne une liste où chaque film n'apparaît qu'une fois.
  /// L'élément conservé est la meilleure qualité ; toutes les versions
  /// (y compris lui-même) sont rangées dans [ContentItem.variants].
  /// Les chaînes et séries sont renvoyées telles quelles.
  static List<ContentItem> groupMovies(List<ContentItem> items) {
    if (items.isEmpty || items.first.contentType == ContentType.liveStream) {
      return items;
    }

    final groups = <String, List<ContentItem>>{};
    final order = <String>[];
    // Pour rattacher un film sans année à l'unique groupe "titre|année".
    final yearsByKey = <String, Set<String>>{};

    for (final item in items) {
      final p = TitleNormalizer.parse(item.name);
      if (p.year != null) {
        yearsByKey.putIfAbsent(p.key, () => {}).add(p.year!);
      }
    }

    for (final item in items) {
      final p = TitleNormalizer.parse(item.name);
      var key = p.key;
      if (p.year != null) {
        key = '${p.key}|${p.year}';
      } else {
        final years = yearsByKey[p.key];
        if (years != null && years.length == 1) {
          key = '${p.key}|${years.first}';
        }
      }
      if (!groups.containsKey(key)) {
        groups[key] = [];
        order.add(key);
      }
      groups[key]!.add(item);
    }

    return order.map((key) {
      final versions = sortVersions(groups[key]!);
      final main = versions.first;
      main.variants = versions;
      return main;
    }).toList();
  }

  /// Clés de regroupement pour une liste de noms (fonction pure, utilisable
  /// dans un isolate avec `compute` pour les gros catalogues).
  static List<String> groupKeysFor(List<String> names) {
    final parsed = names.map(TitleNormalizer.parse).toList();
    final yearsByKey = <String, Set<String>>{};
    for (final p in parsed) {
      if (p.year != null) yearsByKey.putIfAbsent(p.key, () => {}).add(p.year!);
    }
    return parsed.map((p) {
      if (p.year != null) return '${p.key}|${p.year}';
      final years = yearsByKey[p.key];
      if (years != null && years.length == 1) return '${p.key}|${years.first}';
      return p.key;
    }).toList();
  }

  /// Regroupe à partir de clés déjà calculées (voir [groupKeysFor]).
  static List<ContentItem> groupByKeys(
    List<ContentItem> items,
    List<String> keys,
  ) {
    final groups = <String, List<ContentItem>>{};
    final order = <String>[];
    for (var i = 0; i < items.length; i++) {
      final list = groups[keys[i]];
      if (list == null) {
        groups[keys[i]] = [items[i]];
        order.add(keys[i]);
      } else {
        list.add(items[i]);
      }
    }
    return order.map((k) {
      final versions = groups[k]!;
      final sorted = versions.length > 1 ? sortVersions(versions) : versions;
      final main = sorted.first;
      main.variants = sorted;
      return main;
    }).toList();
  }

  /// Trie les versions de la meilleure à la moins bonne qualité.
  static List<ContentItem> sortVersions(List<ContentItem> versions) {
    final sorted = [...versions];
    sorted.sort((a, b) {
      final pa = TitleNormalizer.parse(a.name);
      final pb = TitleNormalizer.parse(b.name);
      final byQuality = pb.qualityRank.compareTo(pa.qualityRank);
      if (byQuality != 0) return byQuality;
      // À qualité égale, privilégie celle qui a une affiche.
      final aImg = a.imagePath.isNotEmpty ? 1 : 0;
      final bImg = b.imagePath.isNotEmpty ? 1 : 0;
      return bImg.compareTo(aImg);
    });
    return sorted;
  }

  /// Vrai si [candidate] est une version du même film que [reference].
  static bool isSameWork(String reference, String candidate) {
    final a = TitleNormalizer.parse(reference);
    final b = TitleNormalizer.parse(candidate);
    if (a.key != b.key || a.key.isEmpty) return false;
    if (a.year != null && b.year != null && a.year != b.year) return false;
    return true;
  }
}
