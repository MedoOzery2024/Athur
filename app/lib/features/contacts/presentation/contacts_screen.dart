import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/api_client.dart';
import '../../../core/services/presence_service.dart';
import '../../../core/theme/athur_colors.dart';
import '../../chats/presentation/chat_screens.dart';

/// Displays the user's contacts and allows searching for new users.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  List<ContactItem> _contacts = [];
  List<ContactItem> _filteredContacts = [];
  bool _isSearching = false;
  bool _isLoading = true;
  StreamSubscription<PresenceUpdate>? _presenceSubscription;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _presenceSubscription = PresenceService.instance.presenceUpdates.listen((update) {
      if (mounted) _refreshPresence();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _presenceSubscription?.cancel();
    super.dispose();
  }

  void _loadContacts() async {
    setState(() => _isLoading = true);
    try {
      final api = ApiClient.instance;
      final response = await api.get('/api/v1/friends');
      final friends = response['friends'] as List<dynamic>? ?? [];
      _contacts = friends.map((f) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(f as Map);
        return ContactItem(
          id: data['id'] as String? ?? '',
          name: data['display_name'] as String? ?? 'Unknown',
          phone: data['phone_number'] as String? ?? '',
          isOnline: PresenceService.instance.isOnline(data['id'] as String? ?? ''),
          lastSeen: PresenceService.instance.getLastSeen(data['id'] as String? ?? '') ?? DateTime.now(),
        );
      }).toList();
      _filteredContacts = _contacts;
      // Fetch presence for all contacts.
      PresenceService.instance.fetchPresence(_contacts.map((c) => c.id).toList());
    } catch (e) {
      debugPrint('[Athur][contacts] Failed to load contacts: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  void _refreshPresence() {
    setState(() {
      for (final c in _contacts) {
        c.isOnline = PresenceService.instance.isOnline(c.id);
        final lastSeen = PresenceService.instance.getLastSeen(c.id);
        if (lastSeen != null) c.lastSeen = lastSeen;
      }
      _filteredContacts = _contacts
          .where((c) => c.name.toLowerCase().contains(_searchController.text.toLowerCase()))
          .toList();
    });
  }

  void _filterContacts(String query) {
    setState(() {
      _filteredContacts = _contacts
          .where((c) => c.name.toLowerCase().contains(query.toLowerCase()))
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search contacts...',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                  border: InputBorder.none,
                ),
                onChanged: _filterContacts,
              )
            : const Text(
                'Contacts',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
        actions: [
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: Colors.white70,
            ),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  _filteredContacts = _contacts;
                }
              });
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AthurColors.gold),
            )
          : _filteredContacts.isEmpty
              ? _buildEmptyState()
              : Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _filteredContacts.length,
                    itemBuilder: (context, index) {
                      return _ContactTile(
                        contact: _filteredContacts[index],
                        onTap: () {
                          // Navigate to chat with this contact.
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(
                                chatId: _filteredContacts[index].id,
                                recipientName: _filteredContacts[index].name,
                                isOnline: _filteredContacts[index].isOnline,
                                lastSeen: _filteredContacts[index].lastSeen,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AthurColors.gold,
        foregroundColor: Colors.black,
        onPressed: _showAddContactDialog,
        child: const Icon(Icons.person_add),
      ),
    );
  }

  void _showAddContactDialog() {
    final phoneController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'Add Contact',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: phoneController,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '+1234567890',
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
            ),
          ),
          TextButton(
            onPressed: () async {
              final phone = phoneController.text.trim();
              if (phone.isEmpty) return;

              Navigator.pop(context);

              final messenger = ScaffoldMessenger.of(context);
              try {
                final api = ApiClient.instance;
                await api.post('/api/v1/friends/request', body: {
                  'phone_number': phone,
                });
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Friend request sent!'),
                      backgroundColor: AthurColors.success,
                    ),
                  );
                }
              } catch (e) {
                debugPrint('[Athur][contacts] Failed to send friend request: $e');
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Failed to send friend request'),
                      backgroundColor: AthurColors.danger,
                    ),
                  );
                }
              }
            },
            child: const Text(
              'Add',
              style: TextStyle(color: AthurColors.gold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.people_outline,
            size: 80,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          const SizedBox(height: 16),
          Text(
            'No contacts found',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add contacts by phone number\nor search for users',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

/// Single contact tile.
class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.contact,
    required this.onTap,
  });

  final ContactItem contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Stack(
        children: [
          // Avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.1),
            ),
            child: Center(
              child: Text(
                contact.name[0].toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          // Online indicator
          if (contact.isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: AthurColors.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        contact.name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        contact.isOnline ? 'Online' : 'Last seen ${_formatLastSeen(contact.lastSeen)}',
        style: TextStyle(
          color: contact.isOnline
              ? AthurColors.success
              : Colors.white.withValues(alpha: 0.4),
          fontSize: 13,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: Colors.white.withValues(alpha: 0.3),
      ),
    );
  }

  String _formatLastSeen(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Contact item model.
class ContactItem {
  ContactItem({
    required this.id,
    required this.name,
    required this.phone,
    required this.isOnline,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String phone;
  bool isOnline;
  DateTime lastSeen;
}
