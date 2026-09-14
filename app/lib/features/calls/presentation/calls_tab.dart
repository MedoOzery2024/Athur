import 'package:flutter/material.dart';

import '../../../core/widgets/athur_empty_state.dart';

/// Calls tab — call history.
///
/// Phase 1: honest empty state. Phase 12 populates this from real call history
/// stored in PostgreSQL (`calls` / `call_history` tables).
class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: AthurEmptyState(
        icon: Icons.call_outlined,
        title: 'No calls yet',
        message:
            'Your audio and video call history will show up here, with real '
            'duration and connection-quality details after each call.',
      ),
    );
  }
}
