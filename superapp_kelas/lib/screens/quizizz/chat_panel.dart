import 'package:flutter/material.dart';

class ChatPanelWidget extends StatefulWidget {
  final List<dynamic> qaMessages;
  final String currentUserRole;
  final String currentUserName;
  final String? currentUserId;
  final Future<void> Function(String message, bool isPrivate, String? toUserId, String? toUserName) onSendMessage;
  final Future<void> Function(String qId, String reply) onReplyMessage;
  final Future<void> Function(String qId)? onMarkAnswered;

  const ChatPanelWidget({
    Key? key,
    required this.qaMessages,
    required this.currentUserRole,
    required this.currentUserName,
    this.currentUserId,
    required this.onSendMessage,
    required this.onReplyMessage,
    this.onMarkAnswered,
  }) : super(key: key);

  @override
  State<ChatPanelWidget> createState() => _ChatPanelWidgetState();
}

class _ChatPanelWidgetState extends State<ChatPanelWidget> {
  final _chatCtrl = TextEditingController();
  bool _sending = false;
  String _toUserId = 'all'; 

  Future<void> _send() async {
    final msg = _chatCtrl.text.trim();
    if (msg.isEmpty || _sending) return;
    setState(() => _sending = true);
    
    bool isPrivate = _toUserId != 'all';
    String? toUserName;
    if (isPrivate) {
      final target = widget.qaMessages.firstWhere(
        (q) => q['sender_id'] == _toUserId || q['student_id'] == _toUserId, 
        orElse: () => <String, dynamic>{}
      );
      toUserName = target['sender_name'] ?? target['student_name'];
    }

    await widget.onSendMessage(msg, isPrivate, isPrivate ? _toUserId : null, toUserName);
    
    if (mounted) {
      setState(() => _sending = false);
      _chatCtrl.clear();
    }
  }

  Future<void> _showReplyDialog(Map<String, dynamic> q) async {
    final replyCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF0F172A), width: 2)),
        title: Text('💬 Balas ke ${q['sender_name'] ?? q['student_name'] ?? 'Peserta'}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A), fontSize: 15)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(10)),
                child: Text(q['message'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF0F172A), fontSize: 13)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: replyCtrl,
                maxLines: 3,
                autofocus: true,
                decoration: InputDecoration(hintText: 'Tulis balasan Anda...', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.all(12)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal', style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              if (replyCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx);
              await widget.onReplyMessage(q['id'].toString(), replyCtrl.text.trim());
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A), foregroundColor: Colors.white),
            child: const Text('Kirim Balasan'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Collect unique users for dropdown
    final Map<String, String> participants = {};
    for (final q in widget.qaMessages) {
      final sId = (q['sender_id'] ?? q['student_id'])?.toString();
      final sName = (q['sender_name'] ?? q['student_name'])?.toString();
      if (sId != null && sName != null && sId != widget.currentUserId) {
        participants[sId] = sName;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('💬 Live Chat', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F172A))),
        const SizedBox(height: 12),
        Expanded(
          child: widget.qaMessages.isEmpty
              ? const Center(child: Text('Belum ada pesan.', style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 12)))
              : ListView.builder(
                  itemCount: widget.qaMessages.length,
                  itemBuilder: (ctx, idx) {
                    final q = widget.qaMessages[idx];
                    final isPrivate = q['is_private'] == true;
                    // Skip private messages not meant for us
                    if (isPrivate) {
                       final toId = q['to_user_id']?.toString();
                       final fromId = (q['sender_id'] ?? q['student_id'])?.toString();
                       // Teacher sees all? No, teacher sees only messages to/from them if private.
                       if (toId != widget.currentUserId && fromId != widget.currentUserId && widget.currentUserRole != 'teacher') {
                          return const SizedBox.shrink(); // Hide
                       }
                    }

                    final answered = q['answered'] == true;
                    final replies = q['replies'] as List<dynamic>? ?? [];
                    final oldReply = q['reply']?.toString(); // fallback
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isPrivate ? const Color(0xFFFCE7F3) : (widget.currentUserRole == 'teacher' && answered ? const Color(0xFFECFDF5) : const Color(0xFFFFFBEB)),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isPrivate ? const Color(0xFFBE185D) : const Color(0xFF0F172A), width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(q['sender_name'] ?? q['student_name'] ?? 'User', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: isPrivate ? const Color(0xFFBE185D) : const Color(0xFF0284C7))),
                              if (isPrivate) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.lock_rounded, size: 10, color: Color(0xFFBE185D)),
                                Text(' (Privat ke ${q['to_user_name'] ?? 'User'})', style: const TextStyle(fontSize: 9, color: Color(0xFFBE185D), fontStyle: FontStyle.italic)),
                              ]
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(q['message'] ?? '', style: const TextStyle(fontSize: 12, color: Color(0xFF0F172A), fontWeight: FontWeight.w600)),
                          
                          if (oldReply != null && oldReply.isNotEmpty && replies.isEmpty) ...[
                             const SizedBox(height: 8),
                             _buildReplyBubble('Dosen', oldReply, 'teacher'),
                          ],
                          
                          for (final r in replies) ...[
                             const SizedBox(height: 8),
                             _buildReplyBubble(r['sender_name'] ?? 'User', r['message'] ?? '', r['sender_role'] ?? 'student'),
                          ],
                          
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (widget.currentUserRole == 'teacher' && !answered && widget.onMarkAnswered != null)
                                TextButton.icon(
                                  onPressed: () => widget.onMarkAnswered!(q['id'].toString()),
                                  icon: const Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF16A34A)),
                                  label: const Text('Tandai Selesai', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                                ),
                              TextButton.icon(
                                onPressed: () => _showReplyDialog(q),
                                icon: const Icon(Icons.reply_rounded, size: 14, color: Color(0xFF0F172A)),
                                label: const Text('Balas Thread', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 12),
        if (participants.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFF0F172A)), borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _toUserId,
                isExpanded: true,
                style: const TextStyle(fontSize: 12, color: Color(0xFF0F172A), fontWeight: FontWeight.w600),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('Kirim ke: Semua Orang (Publik)')),
                  ...participants.entries.map((e) => DropdownMenuItem(value: e.key, child: Text('Kirim ke: ${e.value} (Privat)'))),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _toUserId = v);
                },
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _chatCtrl,
                decoration: InputDecoration(
                  hintText: 'Ketik pesan baru...', 
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), 
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send_rounded, color: Color(0xFF0F172A)),
              style: IconButton.styleFrom(backgroundColor: const Color(0xFFFBBF24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF0F172A), width: 1.2))),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildReplyBubble(String senderName, String message, String role) {
    bool isTeacher = role == 'teacher';
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isTeacher ? const Color(0xFFF0FDF4) : Colors.white, 
        borderRadius: BorderRadius.circular(10), 
        border: Border.all(color: isTeacher ? const Color(0xFF16A34A) : const Color(0xFF94A3B8), width: 1)
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: isTeacher ? const Color(0xFF16A34A) : const Color(0xFF64748B)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(senderName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: isTeacher ? const Color(0xFF166534) : const Color(0xFF475569))),
                Text(message, style: TextStyle(fontSize: 12, color: isTeacher ? const Color(0xFF166534) : const Color(0xFF0F172A), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
