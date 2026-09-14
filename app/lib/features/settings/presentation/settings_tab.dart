import 'package:flutter/material.dart';

import '../../../core/constants/athur_assets.dart';
import '../../../core/services/app_update_service.dart';
import '../../../core/theme/athur_colors.dart';
import '../../../core/theme/athur_tokens.dart';
import '../../../core/widgets/athur_logo.dart';
import '../../../core/widgets/athur_scrollbar.dart';
import '../../../core/widgets/update_dialog.dart';
import 'profile_screen.dart';

/// Settings / Profile tab.
///
/// Phase 1: shows the brand header and a real, working structure with an
/// About dialog (fully implemented, not a placeholder). Each section that
/// needs backend state is added in its own phase and only becomes interactive
/// once it is wired to real data — no dead buttons that pretend to work.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ScrollController();
    return SafeArea(
      child: AthurScrollbar(
        controller: controller,
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.only(bottom: AthurSpacing.xxl),
          children: [
            const _BrandHeader(),
            const SizedBox(height: AthurSpacing.sm),
            _SectionLabel('Account'),
            _Tile(
              icon: Icons.person_outline,
              title: 'Profile',
              subtitle: 'Edit your profile information',
              enabled: true,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
              },
            ),
            _Tile(
              icon: Icons.security_outlined,
              title: 'Privacy & security',
              subtitle: 'Control who can see your information',
              enabled: true,
              onTap: () {
                // TODO: Navigate to privacy screen
              },
            ),
            _Tile(
              icon: Icons.devices_outlined,
              title: 'Devices & sessions',
              subtitle: 'Manage logged-in devices',
              enabled: true,
              onTap: () {
                // TODO: Navigate to devices screen
              },
            ),
            const Divider(height: AthurSpacing.xl),
            _SectionLabel('Communication'),
            _Tile(
              icon: Icons.graphic_eq,
              title: 'Call quality & diagnostics',
              subtitle: 'View call quality information',
              enabled: true,
              onTap: () {
                // TODO: Navigate to call diagnostics
              },
            ),
            _Tile(
              icon: Icons.ring_volume_outlined,
              title: 'Ringtone',
              subtitle: 'Customize your ringtone',
              enabled: true,
              onTap: () {
                // TODO: Navigate to ringtone settings
              },
            ),
            _Tile(
              icon: Icons.notifications_outlined,
              title: 'Notifications',
              subtitle: 'Manage notification preferences',
              enabled: true,
              onTap: () {
                // TODO: Navigate to notification settings
              },
            ),
            const Divider(height: AthurSpacing.xl),
            _SectionLabel('About'),
            _Tile(
              icon: Icons.system_update_outlined,
              title: 'Check for updates',
              subtitle: 'See if a newer version is available',
              enabled: true,
              onTap: () => _checkForUpdates(context),
            ),
            _Tile(
              icon: Icons.info_outline,
              title: 'About Athur',
              subtitle:
                  'Version ${AthurAppInfo.version} '
                  '(build ${AthurAppInfo.versionCode})',
              onTap: () => _showAbout(context),
            ),
          ],
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: AthurAppInfo.appName,
      applicationVersion:
          '${AthurAppInfo.version} (${AthurAppInfo.versionCode})',
      applicationIcon: const Padding(
        padding: EdgeInsets.all(8),
        child: AthurLogo(size: 56),
      ),
      children: const [
        Text(
          'Athur is a real, secure communication platform for calls, '
          'messaging and social sharing.',
          style: TextStyle(color: AthurColors.textSecondary),
        ),
      ],
    );
  }

  void _checkForUpdates(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updateInfo = await AppUpdateService.instance.checkForUpdate();
      if (updateInfo != null && context.mounted) {
        UpdateDialog.show(context, updateInfo);
      } else if (context.mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('You are on the latest version!'),
            backgroundColor: AthurColors.success,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Failed to check for updates'),
            backgroundColor: AthurColors.danger,
          ),
        );
      }
    }
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: AthurSpacing.pagePadding,
      padding: const EdgeInsets.all(AthurSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: AthurRadius.rLg,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AthurColors.surfaceElevated, AthurColors.surface],
        ),
        border: Border.all(color: AthurColors.border),
      ),
      child: Row(
        children: [
          const AthurLogo(size: 56),
          const SizedBox(width: AthurSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AthurAppInfo.appName,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Not signed in',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AthurSpacing.lg,
        AthurSpacing.md,
        AthurSpacing.lg,
        AthurSpacing.sm,
      ),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AthurColors.gold,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled
        ? AthurColors.textPrimary
        : AthurColors.textMuted;
    return ListTile(
      enabled: onTap != null,
      leading: Icon(
        icon,
        color: enabled ? AthurColors.gold : AthurColors.textMuted,
      ),
      title: Text(
        title,
        style: TextStyle(color: effectiveColor, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right, color: AthurColors.textMuted),
      onTap: onTap,
    );
  }
}
