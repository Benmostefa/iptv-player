import 'package:flutter/material.dart';
import 'package:another_iptv_player/models/api_response.dart';
import 'package:another_iptv_player/models/playlist_model.dart';
import 'package:another_iptv_player/services/app_state.dart';
import 'package:another_iptv_player/l10n/localization_extension.dart';
import '../../widgets/playlist_info_widget.dart';
import '../../widgets/server_info_widget.dart';
import '../../widgets/status_card_widget.dart';
import '../../widgets/subscription_info_widget.dart';
import '../settings/general_settings_section.dart';
import 'package:another_iptv_player/widgets/subscription_account_card.dart';
import 'package:another_iptv_player/screens/xtream-codes/xtream_code_data_loader_screen.dart';

class XtreamCodePlaylistSettingsScreen extends StatefulWidget {
  final Playlist playlist;

  const XtreamCodePlaylistSettingsScreen({super.key, required this.playlist});

  @override
  State<XtreamCodePlaylistSettingsScreen> createState() =>
      _XtreamCodePlaylistSettingsScreenState();
}

class _XtreamCodePlaylistSettingsScreenState
    extends State<XtreamCodePlaylistSettingsScreen> {
  ApiResponse? _serverInfo;

  @override
  void initState() {
    super.initState();
    _loadServerInfo();
  }

  Future<void> _loadServerInfo() async {
    if (AppState.xtreamCodeRepository != null) {
      final info = await AppState.xtreamCodeRepository!.getPlayerInfo();
      if (mounted) {
        setState(() {
          _serverInfo = info;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: SelectableText(
          context.loc.settings,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        children: [
          SubscriptionAccountCard(
            playlist: widget.playlist,
            onRenewed: (updated) {
              // Recharge l'application avec le nouveau code.
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(
                  builder: (_) => XtreamCodeDataLoaderScreen(playlist: updated),
                ),
                (route) => false,
              );
            },
          ),
          const SizedBox(height: 12),
          StatusCardWidget(serverInfo: _serverInfo),
          const SizedBox(height: 12),
          const GeneralSettingsWidget(),
          const SizedBox(height: 16),
          PlaylistInfoWidget(playlist: widget.playlist),
          const SizedBox(height: 16),
          SubscriptionInfoWidget(serverInfo: _serverInfo),
          const SizedBox(height: 16),
          if (_serverInfo?.serverInfo != null) ...[
            ServerInfoWidget(serverInfo: _serverInfo!),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}
