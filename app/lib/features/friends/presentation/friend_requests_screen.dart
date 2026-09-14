import 'package:flutter/material.dart';

import '../../../core/services/api_client.dart';
import '../../../core/theme/athur_colors.dart';

/// Displays incoming and outgoing friend requests.
class FriendRequestsScreen extends StatefulWidget {
  const FriendRequestsScreen({super.key});

  @override
  State<FriendRequestsScreen> createState() => _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends State<FriendRequestsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<FriendRequest> _incomingRequests = [];
  List<FriendRequest> _outgoingRequests = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadRequests();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _loadRequests() async {
    setState(() => _isLoading = true);
    try {
      final api = ApiClient.instance;
      final response = await api.get('/api/v1/friends/requests');
      final incoming = response['incoming'] as List<dynamic>? ?? [];
      final outgoing = response['outgoing'] as List<dynamic>? ?? [];

      _incomingRequests = incoming.map((r) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(r as Map);
        return FriendRequest(
          id: data['id'] as String? ?? '',
          name: data['display_name'] as String? ?? 'Unknown',
          message: data['message'] as String? ?? '',
          createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now(),
        );
      }).toList();

      _outgoingRequests = outgoing.map((r) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(r as Map);
        return FriendRequest(
          id: data['id'] as String? ?? '',
          name: data['display_name'] as String? ?? 'Unknown',
          message: data['message'] as String? ?? '',
          createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now(),
        );
      }).toList();
    } catch (e) {
      debugPrint('[Athur][friends] Failed to load requests: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white70),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Friend Requests',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AthurColors.gold,
          labelColor: AthurColors.gold,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(text: 'Incoming'),
            Tab(text: 'Outgoing'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AthurColors.gold))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildIncomingRequests(),
                _buildOutgoingRequests(),
              ],
            ),
    );
  }

  Widget _buildIncomingRequests() {
    if (_incomingRequests.isEmpty) {
      return _buildEmptyState('No incoming requests');
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _incomingRequests.length,
      itemBuilder: (context, index) {
        final request = _incomingRequests[index];
        return _RequestCard(
          request: request,
          isIncoming: true,
          onAccept: () => _acceptRequest(request.id),
          onReject: () => _rejectRequest(request.id),
        );
      },
    );
  }

  Widget _buildOutgoingRequests() {
    if (_outgoingRequests.isEmpty) {
      return _buildEmptyState('No outgoing requests');
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _outgoingRequests.length,
      itemBuilder: (context, index) {
        final request = _outgoingRequests[index];
        return _RequestCard(
          request: request,
          isIncoming: false,
          onCancel: () => _cancelRequest(request.id),
        );
      },
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.person_add_outlined,
            size: 80,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  void _acceptRequest(String id) async {
    try {
      final api = ApiClient.instance;
      await api.post('/api/v1/friends/accept/$id');
      _loadRequests();
    } catch (e) {
      debugPrint('[Athur][friends] Failed to accept request: $e');
    }
  }

  void _rejectRequest(String id) async {
    try {
      final api = ApiClient.instance;
      await api.post('/api/v1/friends/reject/$id');
      _loadRequests();
    } catch (e) {
      debugPrint('[Athur][friends] Failed to reject request: $e');
    }
  }

  void _cancelRequest(String id) async {
    try {
      final api = ApiClient.instance;
      await api.post('/api/v1/friends/cancel/$id');
      _loadRequests();
    } catch (e) {
      debugPrint('[Athur][friends] Failed to cancel request: $e');
    }
  }
}

/// Friend request card widget.
class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.isIncoming,
    this.onAccept,
    this.onReject,
    this.onCancel,
  });

  final FriendRequest request;
  final bool isIncoming;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [AthurColors.gold, Colors.orange],
              ),
            ),
            child: Center(
              child: Text(
                request.name[0].toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (request.message.isNotEmpty)
                  Text(
                    request.message,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                Text(
                  _formatTime(request.createdAt),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

          // Actions
          if (isIncoming) ...[
            IconButton(
              icon: const Icon(Icons.check_circle, color: AthurColors.success),
              onPressed: onAccept,
            ),
            IconButton(
              icon: const Icon(Icons.cancel, color: AthurColors.danger),
              onPressed: onReject,
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.cancel, color: AthurColors.danger),
              onPressed: onCancel,
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Friend request model.
class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.name,
    required this.message,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String message;
  final DateTime createdAt;
}
