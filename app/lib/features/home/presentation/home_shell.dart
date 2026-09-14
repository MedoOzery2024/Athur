import 'package:flutter/material.dart';

import '../../../core/services/app_update_service.dart';
import '../../../core/theme/athur_colors.dart';
import '../../../core/widgets/athur_logo.dart';
import '../../../core/widgets/update_dialog.dart';
import '../../calls/presentation/calls_tab.dart';
import '../../chats/presentation/chats_tab.dart';
import '../../contacts/presentation/contacts_tab.dart';
import '../../settings/presentation/settings_tab.dart';
import '../../stories/presentation/stories_screen.dart';

/// The main authenticated shell.
///
/// Structure: five primary destinations (Chats, Stories, Calls, Contacts, Settings).
/// Each tab keeps its own scroll position and state via [IndexedStack], so
/// switching tabs is instant and does not rebuild lists (performance rule).
///
/// Later phases inject: an active-call mini-window overlay, an unread badge on
/// Chats, and connectivity/presence banners. Phase 1 keeps it clean.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _titles = ['Chats', 'Stories', 'Calls', 'Contacts', 'Settings'];

  @override
  void initState() {
    super.initState();
    // Check for updates on startup.
    _checkForUpdates();
  }

  void _checkForUpdates() async {
    try {
      final updateInfo = await AppUpdateService.instance.checkForUpdate();
      if (updateInfo != null && mounted) {
        UpdateDialog.show(context, updateInfo);
      }
    } catch (e) {
      debugPrint('[Athur][update] Error checking for updates: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const AthurLogo(size: 28),
            const SizedBox(width: 10),
            Text(_titles[_index]),
          ],
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: const [ChatsTab(), StoriesScreen(), CallsTab(), ContactsTab(), SettingsTab()],
      ),
      bottomNavigationBar: _AthurBottomNav(
        index: _index,
        onChanged: (i) => setState(() => _index = i),
      ),
    );
  }
}

/// Custom bottom navigation with a gold active indicator pill and haptic
/// feedback on tap — part of Athur's own visual language (not a stock bar).
class _AthurBottomNav extends StatelessWidget {
  const _AthurBottomNav({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const _items = <_NavItem>[
    _NavItem(Icons.forum_outlined, Icons.forum, 'Chats'),
    _NavItem(Icons.auto_stories_outlined, Icons.auto_stories, 'Stories'),
    _NavItem(Icons.call_outlined, Icons.call, 'Calls'),
    _NavItem(Icons.people_outline, Icons.people, 'Contacts'),
    _NavItem(Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AthurColors.background,
          border: Border(top: BorderSide(color: AthurColors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              Expanded(
                child: _NavButton(
                  item: _items[i],
                  selected: i == index,
                  onTap: () => onChanged(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.activeIcon, this.label);
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AthurColors.gold : AthurColors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: () {
          // Light haptic feedback is part of Athur's micro-interactions.
          Feedback.forTap(context);
          onTap();
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: selected ? AthurColors.goldWash : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(
                  selected ? item.activeIcon : item.icon,
                  size: 22,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
