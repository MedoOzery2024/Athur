import 'package:flutter/material.dart';

import 'chat_screens.dart';

/// Chats tab in the home shell.
///
/// Displays the list of active conversations.
class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const ChatListScreen();
  }
}
