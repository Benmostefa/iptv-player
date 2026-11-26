import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';

/// Note du fournisseur sur 10 — la MÊME valeur partout (affiche, fiche film,
/// fiche série), pour que le raccourci sur la couverture corresponde.
double? providerRating(ContentItem item) {
  double? parse(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim().replaceAll(',', '.'));
  }

  double? r;
  double? r5;
  if (item.contentType == ContentType.vod) {
    r = parse(item.vodStream?.rating);
    r5 = item.vodStream?.rating5based;
  } else if (item.contentType == ContentType.series) {
    r = parse(item.seriesStream?.rating);
    r5 = item.seriesStream?.rating5based;
  }
  if (r != null && r > 0) return r > 10 ? 10 : r;
  if (r5 != null && r5 > 0) return r5 * 2;
  return null;
}

/// "7", "6.8"...
String formatRating(double r) =>
    r % 1 == 0 ? r.toStringAsFixed(0) : r.toStringAsFixed(1);
