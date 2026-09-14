import 'package:flutter/material.dart';

import '../../../core/services/api_client.dart';
import '../../../core/theme/athur_colors.dart';

/// Stories screen showing friends' stories as horizontal rings.
class StoriesScreen extends StatefulWidget {
  const StoriesScreen({super.key});

  @override
  State<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends State<StoriesScreen> {
  List<StoryItem> _stories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStories();
  }

  void _loadStories() async {
    setState(() => _isLoading = true);
    try {
      final api = ApiClient.instance;
      final response = await api.get('/api/v1/stories/feed');
      final stories = response['stories'] as List<dynamic>? ?? [];
      _stories = stories.map((s) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(s as Map);
        return StoryItem(
          id: data['id'] as String? ?? '',
          authorName: data['author_name'] as String? ?? 'Unknown',
          storyType: data['story_type'] as String? ?? 'text',
          body: data['body'] as String?,
          viewCount: data['view_count'] as int? ?? 0,
          hasViewed: data['has_viewed'] as bool? ?? false,
          createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now(),
        );
      }).toList();
    } catch (e) {
      debugPrint('[Athur][stories] Failed to load stories: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  void _viewStory(StoryItem story) async {
    try {
      final api = ApiClient.instance;
      await api.post('/api/v1/stories/${story.id}/view');
      setState(() {
        story.hasViewed = true;
        story.viewCount++;
      });
    } catch (e) {
      debugPrint('[Athur][stories] Failed to view story: $e');
    }
  }

  void _createStory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _CreateStorySheet(onCreated: () {
        Navigator.pop(context);
        _loadStories();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'Stories',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AthurColors.gold))
          : _stories.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _stories.length,
                  itemBuilder: (context, index) {
                    final story = _stories[index];
                    return _StoryTile(
                      story: story,
                      onTap: () => _viewStory(story),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AthurColors.gold,
        foregroundColor: Colors.black,
        onPressed: _createStory,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_stories,
            size: 80,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          const SizedBox(height: 16),
          Text(
            'No stories yet',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Be the first to share a story!',
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

class _StoryTile extends StatelessWidget {
  const _StoryTile({required this.story, required this.onTap});

  final StoryItem story;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: story.hasViewed
              ? null
              : const LinearGradient(
                  colors: [AthurColors.gold, Colors.orange],
                ),
          border: story.hasViewed
              ? Border.all(color: Colors.white.withValues(alpha: 0.2), width: 2)
              : null,
        ),
        child: Center(
          child: Text(
            story.authorName[0].toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
      title: Text(
        story.authorName,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        '${story.storyType.toUpperCase()} • ${_formatTime(story.createdAt)}',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 13,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility,
            color: Colors.white.withValues(alpha: 0.3),
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(
            '${story.viewCount}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
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

class _CreateStorySheet extends StatefulWidget {
  const _CreateStorySheet({required this.onCreated});

  final VoidCallback onCreated;

  @override
  State<_CreateStorySheet> createState() => _CreateStorySheetState();
}

class _CreateStorySheetState extends State<_CreateStorySheet> {
  final _bodyController = TextEditingController();
  String _selectedType = 'text';
  String _selectedVisibility = 'contacts';
  bool _isCreating = false;

  void _createStory() async {
    if (_bodyController.text.isEmpty) return;

    setState(() => _isCreating = true);
    try {
      final api = ApiClient.instance;
      await api.post('/api/v1/stories', body: {
        'story_type': _selectedType,
        'body': _bodyController.text,
        'visibility': _selectedVisibility,
      });
      widget.onCreated();
    } catch (e) {
      debugPrint('[Athur][stories] Failed to create story: $e');
    }
    if (mounted) setState(() => _isCreating = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Create Story',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _bodyController,
            maxLines: 4,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: "What's on your mind?",
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildTypeChip('text', 'Text'),
              const SizedBox(width: 8),
              _buildTypeChip('image', 'Image'),
              const SizedBox(width: 8),
              _buildTypeChip('video', 'Video'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildVisibilityChip('contacts', 'Contacts'),
              const SizedBox(width: 8),
              _buildVisibilityChip('everyone', 'Everyone'),
              const SizedBox(width: 8),
              _buildVisibilityChip('private', 'Private'),
            ],
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isCreating ? null : _createStory,
            style: ElevatedButton.styleFrom(
              backgroundColor: AthurColors.gold,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isCreating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : const Text(
                    'Share Story',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeChip(String value, String label) {
    final isSelected = _selectedType == value;
    return GestureDetector(
      onTap: () => setState(() => _selectedType = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AthurColors.gold : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildVisibilityChip(String value, String label) {
    final isSelected = _selectedVisibility == value;
    return GestureDetector(
      onTap: () => setState(() => _selectedVisibility = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AthurColors.gold : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// Story item model.
class StoryItem {
  StoryItem({
    required this.id,
    required this.authorName,
    required this.storyType,
    this.body,
    required this.viewCount,
    required this.hasViewed,
    required this.createdAt,
  });

  final String id;
  final String authorName;
  final String storyType;
  final String? body;
  int viewCount;
  bool hasViewed;
  final DateTime createdAt;
}
