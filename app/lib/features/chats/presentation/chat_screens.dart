import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_view/photo_view.dart';

import '../../../core/services/file_sharing_service.dart';
import '../../../core/services/voice_recording_service.dart';
import '../../../core/services/websocket_service.dart';
import '../../../core/theme/athur_colors.dart';

/// Displays the list of active conversations.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'Chats',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white70),
            onPressed: () {},
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 80,
              color: Colors.white.withValues(alpha: 0.1),
            ),
            const SizedBox(height: 16),
            Text(
              'No chats yet',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start a conversation with\nyour contacts',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AthurColors.gold,
        foregroundColor: Colors.black,
        onPressed: () {},
        child: const Icon(Icons.chat_bubble_outline),
      ),
    );
  }
}

/// Chat screen with full messaging capabilities:
/// - Text messages
/// - Voice recording
/// - Image/video/file sharing
/// - Typing indicator
/// - Last seen display
/// - Read receipts
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.chatId,
    required this.recipientName,
    this.isOnline = false,
    this.lastSeen,
  });

  final String chatId;
  final String recipientName;
  final bool isOnline;
  final DateTime? lastSeen;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  final _wsService = WebSocketService.instance;
  final _voiceService = VoiceRecordingService.instance;
  final _fileService = FileSharingService.instance;

  bool _isTyping = false;
  Timer? _typingTimer;
  bool _isRecipientTyping = false;
  RecordingState _recordingState = RecordingState.idle;
  StreamSubscription<RecordingState>? _recordingSubscription;
  StreamSubscription<WsMessage>? _wsSubscription;

  @override
  void initState() {
    super.initState();
    _initServices();
    _listenToWebSocket();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _typingTimer?.cancel();
    _recordingSubscription?.cancel();
    _wsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initServices() async {
    await _voiceService.init();
    _recordingSubscription = _voiceService.state.listen((state) {
      if (mounted) setState(() => _recordingState = state);
    });
  }

  void _listenToWebSocket() {
    _wsSubscription = _wsService.messages.listen((message) {
      if (message.type == 'typing' && message.chatId == widget.chatId) {
        if (mounted) setState(() => _isRecipientTyping = true);
        // Auto-clear typing after 3 seconds.
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isRecipientTyping = false);
        });
      } else if (message.type == 'message' && message.chatId == widget.chatId) {
        if (mounted) {
          setState(() {
            _messages.add(ChatMessage(
              id: message.messageId ?? '',
              content: message.content ?? '',
              isMe: false,
              timestamp: DateTime.now(),
              type: MessageType.text,
            ));
          });
          _scrollToBottom();
        }
      }
    });
  }

  // ────────────────────────── Messaging ──────────────────────────

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final clientMessageId = DateTime.now().millisecondsSinceEpoch.toString();

    setState(() {
      _messages.add(ChatMessage(
        id: clientMessageId,
        content: text,
        isMe: true,
        timestamp: DateTime.now(),
        type: MessageType.text,
      ));
    });

    _messageController.clear();
    _stopTyping();
    _scrollToBottom();

    _wsService.sendMessage(
      chatId: widget.chatId,
      content: text,
      clientMessageId: clientMessageId,
    );
  }

  void _sendVoiceMessage(VoiceRecordingResult recording) async {
    final clientMessageId = DateTime.now().millisecondsSinceEpoch.toString();

    // Add message to UI immediately with loading state.
    setState(() {
      _messages.add(ChatMessage(
        id: clientMessageId,
        content: '',
        isMe: true,
        timestamp: DateTime.now(),
        type: MessageType.voice,
        voiceFilePath: recording.filePath,
        voiceDuration: recording.durationSeconds,
        isUploading: true,
      ));
    });

    _scrollToBottom();

    // Upload voice recording to server.
    final uploadResult = await _fileService.uploadVoiceRecording(recording.filePath);

    if (mounted) {
      setState(() {
        // Find the message and update with upload URL.
        final index = _messages.indexWhere((m) => m.id == clientMessageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            mediaUrl: uploadResult?.url,
            isUploading: false,
          );
        }
      });
    }

    // Send via WebSocket.
    _wsService.sendMessage(
      chatId: widget.chatId,
      content: uploadResult?.url ?? '[Voice Message]',
      type: 'voice',
      clientMessageId: clientMessageId,
    );
  }

  void _sendFileMessage(SharedFile file) async {
    final clientMessageId = DateTime.now().millisecondsSinceEpoch.toString();

    // Add message to UI immediately with loading state.
    setState(() {
      _messages.add(ChatMessage(
        id: clientMessageId,
        content: file.fileName,
        isMe: true,
        timestamp: DateTime.now(),
        type: _getMessageType(file.type),
        filePath: file.filePath,
        fileName: file.fileName,
        fileSize: file.fileSize,
        mimeType: file.mimeType,
        isUploading: true,
      ));
    });

    _scrollToBottom();

    // Upload file to server.
    final uploadResult = await _fileService.uploadFileToServer(file);

    if (mounted) {
      setState(() {
        // Find the message and update with upload URL.
        final index = _messages.indexWhere((m) => m.id == clientMessageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            mediaUrl: uploadResult?.url,
            isUploading: false,
          );
        }
      });
    }

    // Send via WebSocket.
    _wsService.sendMessage(
      chatId: widget.chatId,
      content: uploadResult?.url ?? file.fileName,
      type: _getMessageType(file.type).name,
      clientMessageId: clientMessageId,
    );
  }

  MessageType _getMessageType(SharedFileType fileType) {
    return switch (fileType) {
      SharedFileType.image => MessageType.image,
      SharedFileType.video => MessageType.video,
      SharedFileType.audio => MessageType.audio,
      SharedFileType.document => MessageType.document,
      SharedFileType.file => MessageType.file,
    };
  }

  // ────────────────────────── Typing ──────────────────────────

  void _onTextChanged(String text) {
    if (text.isNotEmpty && !_isTyping) {
      _isTyping = true;
      _wsService.sendTyping(chatId: widget.chatId);
    }

    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      _stopTyping();
    });
  }

  void _stopTyping() {
    if (_isTyping) {
      _isTyping = false;
      _typingTimer?.cancel();
    }
  }

  // ────────────────────────── Voice Recording ──────────────────────────

  Future<void> _toggleRecording() async {
    if (_recordingState == RecordingState.recording) {
      final result = await _voiceService.stopRecording();
      if (result != null) {
        _sendVoiceMessage(result);
      }
    } else {
      await _voiceService.startRecording();
    }
  }

  Future<void> _cancelRecording() async {
    await _voiceService.cancelRecording();
  }

  // ────────────────────────── File Sharing ──────────────────────────

  void _showAttachmentOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _AttachmentSheet(
        onImagePick: _pickImage,
        onVideoPick: _pickVideo,
        onFilePick: _pickFile,
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.of(context).pop();
    final file = await _fileService.pickImage(source: source);
    if (file != null) _sendFileMessage(file);
  }

  Future<void> _pickVideo(ImageSource source) async {
    Navigator.of(context).pop();
    final file = await _fileService.pickVideo(source: source);
    if (file != null) _sendFileMessage(file);
  }

  Future<void> _pickFile() async {
    Navigator.of(context).pop();
    final file = await _fileService.pickFile();
    if (file != null) _sendFileMessage(file);
  }

  // ────────────────────────── Helpers ──────────────────────────

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatLastSeen(DateTime? time) {
    if (time == null) return '';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'last seen just now';
    if (diff.inMinutes < 60) return 'last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'last seen ${diff.inHours}h ago';
    return 'last seen ${diff.inDays}d ago';
  }

  // ────────────────────────── Build ──────────────────────────

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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.recipientName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_isRecipientTyping)
              Text(
                'typing...',
                style: TextStyle(
                  color: AthurColors.gold,
                  fontSize: 12,
                ),
              )
            else if (widget.isOnline)
              Text(
                'Online',
                style: TextStyle(
                  color: AthurColors.success,
                  fontSize: 12,
                ),
              )
            else
              Text(
                _formatLastSeen(widget.lastSeen),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone, color: Colors.white70),
            onPressed: () {
              // Start voice call.
              // TODO: Implement voice call initiation
            },
          ),
          IconButton(
            icon: const Icon(Icons.videocam, color: Colors.white70),
            onPressed: () {
              // Start video call.
              // TODO: Implement video call initiation
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyChat()
                : Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        return _buildMessageBubble(_messages[index]);
                      },
                    ),
                  ),
          ),

          // Typing indicator
          if (_isRecipientTyping) _buildTypingIndicator(),

          // Recording indicator
          if (_recordingState == RecordingState.recording)
            _buildRecordingIndicator(),

          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildEmptyChat() {
    return Center(
      child: Text(
        'Send a message to start the conversation',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.3),
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTypingDot(0),
                const SizedBox(width: 4),
                _buildTypingDot(1),
                const SizedBox(width: 4),
                _buildTypingDot(2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1.0),
      duration: const Duration(milliseconds: 600),
      builder: (context, value, child) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AthurColors.gold.withValues(alpha: value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }

  Widget _buildRecordingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AthurColors.danger.withValues(alpha: 0.1),
        border: Border(
          top: BorderSide(
            color: AthurColors.danger.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // Recording dot
          Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: AthurColors.danger,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),

          // Duration
          Text(
            '${_voiceService.durationSeconds.toString().padLeft(2, '0')}:00',
            style: const TextStyle(
              color: AthurColors.danger,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),

          const Spacer(),

          // Cancel
          TextButton(
            onPressed: _cancelRecording,
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),

          // Send
          Container(
            decoration: const BoxDecoration(
              color: AthurColors.gold,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.black, size: 20),
              onPressed: () async {
                final result = await _voiceService.stopRecording();
                if (result != null) _sendVoiceMessage(result);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: _buildMessageContent(message),
      ),
    );
  }

  Widget _buildMessageContent(ChatMessage message) {
    switch (message.type) {
      case MessageType.text:
        return _buildTextBubble(message);
      case MessageType.image:
        return _buildImageBubble(message);
      case MessageType.video:
        return _buildVideoBubble(message);
      case MessageType.voice:
      case MessageType.audio:
        return _buildVoiceBubble(message);
      case MessageType.document:
      case MessageType.file:
        return _buildFileBubble(message);
    }
  }

  Widget _buildTextBubble(ChatMessage message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: message.isMe
            ? AthurColors.gold
            : Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16).copyWith(
          bottomRight: message.isMe ? const Radius.circular(4) : null,
          bottomLeft: !message.isMe ? const Radius.circular(4) : null,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            message.content,
            style: TextStyle(
              color: message.isMe ? Colors.black : Colors.white,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatTime(message.timestamp),
            style: TextStyle(
              color: message.isMe
                  ? Colors.black.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageBubble(ChatMessage message) {
    return GestureDetector(
      onTap: () => _openImageViewer(message),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withValues(alpha: 0.1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Image from server or local file
            Container(
              height: 200,
              width: double.infinity,
              color: Colors.white.withValues(alpha: 0.05),
              child: message.isUploading
                  ? const Center(
                      child: CircularProgressIndicator(color: AthurColors.gold),
                    )
                  : message.mediaUrl != null
                      ? Image.network(
                          message.mediaUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return const Icon(
                              Icons.image,
                              color: Colors.white38,
                              size: 48,
                            );
                          },
                        )
                      : message.filePath != null
                          ? Image.file(
                              File(message.filePath!),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return const Icon(
                                  Icons.image,
                                  color: Colors.white38,
                                  size: 48,
                                );
                              },
                            )
                          : const Icon(
                              Icons.image,
                              color: Colors.white38,
                              size: 48,
                            ),
            ),
            // Caption and time
            if (message.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  message.content,
                  style: TextStyle(
                    color: message.isMe ? Colors.black : Colors.white,
                    fontSize: 14,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 4),
              child: Text(
                _formatTime(message.timestamp),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoBubble(ChatMessage message) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Video thumbnail placeholder
          Container(
            height: 200,
            width: double.infinity,
            color: Colors.white.withValues(alpha: 0.05),
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(
                  Icons.videocam,
                  color: Colors.white38,
                  size: 48,
                ),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ],
            ),
          ),
          // Duration and time
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  message.fileName ?? '',
                  style: TextStyle(
                    color: message.isMe ? Colors.black : Colors.white,
                    fontSize: 13,
                  ),
                ),
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceBubble(ChatMessage message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: message.isMe
            ? AthurColors.gold
            : Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16).copyWith(
          bottomRight: message.isMe ? const Radius.circular(4) : null,
          bottomLeft: !message.isMe ? const Radius.circular(4) : null,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Play button
          Icon(
            Icons.play_arrow,
            color: message.isMe ? Colors.black : Colors.white,
          ),
          const SizedBox(width: 8),

          // Waveform placeholder
          Container(
            width: 100,
            height: 30,
            decoration: BoxDecoration(
              color: message.isMe
                  ? Colors.black.withValues(alpha: 0.1)
                  : Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Center(
              child: Text(
                message.formattedVoiceDuration,
                style: TextStyle(
                  color: message.isMe ? Colors.black : Colors.white,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileBubble(ChatMessage message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: message.isMe
            ? AthurColors.gold
            : Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16).copyWith(
          bottomRight: message.isMe ? const Radius.circular(4) : null,
          bottomLeft: !message.isMe ? const Radius.circular(4) : null,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _getFileIcon(message.mimeType),
            color: message.isMe ? Colors.black : Colors.white,
            size: 32,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.fileName ?? '',
                  style: TextStyle(
                    color: message.isMe ? Colors.black : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  message.formattedFileSize,
                  style: TextStyle(
                    color: message.isMe
                        ? Colors.black.withValues(alpha: 0.5)
                        : Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String? mimeType) {
    if (mimeType == null) return Icons.insert_drive_file;
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('video/')) return Icons.videocam;
    if (mimeType.startsWith('audio/')) return Icons.audiotrack;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('word') || mimeType.contains('document')) {
      return Icons.description;
    }
    if (mimeType.contains('sheet') || mimeType.contains('excel')) {
      return Icons.table_chart;
    }
    return Icons.insert_drive_file;
  }

  void _openImageViewer(ChatMessage message) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            leading: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: PhotoView(
            imageProvider: message.mediaUrl != null
                ? NetworkImage(message.mediaUrl!)
                : FileImage(File(message.filePath!)),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 2,
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  // ────────────────────────── Input Bar ──────────────────────────

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          // Attachment button
          IconButton(
            icon: Icon(
              Icons.attach_file,
              color: Colors.white.withValues(alpha: 0.5),
            ),
            onPressed: _showAttachmentOptions,
          ),

          // Message field
          Expanded(
            child: TextField(
              controller: _messageController,
              style: const TextStyle(color: Colors.white),
              maxLines: 4,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Type a message...',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              onChanged: _onTextChanged,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),

          const SizedBox(width: 8),

          // Send / Voice button
          if (_messageController.text.trim().isEmpty)
            // Voice recording button
            GestureDetector(
              onLongPress: _toggleRecording,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: AthurColors.gold,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _recordingState == RecordingState.recording
                      ? Icons.stop
                      : Icons.mic,
                  color: Colors.black,
                  size: 22,
                ),
              ),
            )
          else
            // Send button
            Container(
              decoration: const BoxDecoration(
                color: AthurColors.gold,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.black, size: 20),
                onPressed: _sendMessage,
              ),
            ),
        ],
      ),
    );
  }
}

/// Attachment bottom sheet.
class _AttachmentSheet extends StatelessWidget {
  const _AttachmentSheet({
    required this.onImagePick,
    required this.onVideoPick,
    required this.onFilePick,
  });

  final Function(ImageSource) onImagePick;
  final Function(ImageSource) onVideoPick;
  final VoidCallback onFilePick;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _AttachmentOption(
                icon: Icons.camera_alt,
                label: 'Camera',
                onTap: () => onImagePick(ImageSource.camera),
              ),
              _AttachmentOption(
                icon: Icons.photo_library,
                label: 'Gallery',
                onTap: () => onImagePick(ImageSource.gallery),
              ),
              _AttachmentOption(
                icon: Icons.videocam,
                label: 'Video',
                onTap: () => onVideoPick(ImageSource.gallery),
              ),
              _AttachmentOption(
                icon: Icons.insert_drive_file,
                label: 'File',
                onTap: onFilePick,
              ),
            ],
          ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}

class _AttachmentOption extends StatelessWidget {
  const _AttachmentOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AthurColors.gold.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AthurColors.gold, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chat message model.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.content,
    required this.isMe,
    required this.timestamp,
    required this.type,
    this.filePath,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.voiceFilePath,
    this.voiceDuration,
    this.mediaUrl,
    this.isUploading = false,
  });

  final String id;
  final String content;
  final bool isMe;
  final DateTime timestamp;
  final MessageType type;
  final String? filePath;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? voiceFilePath;
  final int? voiceDuration;
  final String? mediaUrl;
  final bool isUploading;

  ChatMessage copyWith({
    String? mediaUrl,
    bool? isUploading,
  }) {
    return ChatMessage(
      id: id,
      content: content,
      isMe: isMe,
      timestamp: timestamp,
      type: type,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      voiceFilePath: voiceFilePath,
      voiceDuration: voiceDuration,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      isUploading: isUploading ?? this.isUploading,
    );
  }

  String get formattedVoiceDuration {
    if (voiceDuration == null) return '0:00';
    final m = voiceDuration! ~/ 60;
    final s = voiceDuration! % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String get formattedFileSize {
    if (fileSize == null) return '';
    if (fileSize! < 1024) return '${fileSize!} B';
    if (fileSize! < 1024 * 1024) {
      return '${(fileSize! / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSize! / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Message type enum.
enum MessageType { text, image, video, voice, audio, document, file }
