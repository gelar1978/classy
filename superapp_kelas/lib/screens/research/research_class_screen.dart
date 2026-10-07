import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/auth_provider.dart';
import '../../services/quizizz_service.dart';
import '../../services/socket_service.dart';
import 'research_groups_tab.dart';
import 'research_documents_tab.dart';
import 'research_students_tab.dart';
import 'research_student_performance_tab.dart';
import 'signature_upload_dialog.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

class ResearchClassScreen extends StatefulWidget {
  final String classId;
  final String className;
  final String? subject;
  final String? dosenId;

  const ResearchClassScreen({
    super.key,
    required this.classId,
    required this.className,
    this.subject,
    this.dosenId,
  });

  @override
  State<ResearchClassScreen> createState() => _ResearchClassScreenState();
}

class _ResearchClassScreenState extends State<ResearchClassScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _pendingDocCount = 0;
  bool _hasUnreadDocResponse = false;
  Timer? _docPollTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_handleTabChange);
    _checkDocBadge();
    _setupSocketListeners();
    _docPollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _checkDocBadge());
  }

  void _handleTabChange() async {
    if (_tabController.index == 1) {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      if (auth.role != 'dosen') {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_viewed_doc_approval_${widget.classId}', DateTime.now().toIso8601String());
        if (mounted) {
          setState(() {
            _hasUnreadDocResponse = false;
          });
        }
      }
    }
  }

  void _setupSocketListeners() {
    try {
      final socket = SocketService.socket;
      if (socket != null) {
        socket.on('research_document_submitted', (_) {
          if (mounted) _checkDocBadge();
        });
        socket.on('research_document_reviewed', (_) {
          if (mounted) _checkDocBadge();
        });
        socket.on('research_document_deleted', (_) {
          if (mounted) _checkDocBadge();
        });
      }
    } catch (_) {}
  }

  Future<void> _checkDocBadge() async {
    try {
      final res = await QuizizzService.getResearchDocuments(widget.classId);
      if (!mounted) return;
      final docs = (res['documents'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final isDosen = auth.role == 'dosen';

      if (isDosen) {
        final pending = docs.where((d) => d['status'] == 'pending').length;
        if (mounted) {
          setState(() {
            _pendingDocCount = pending;
          });
        }
      } else {
        final prefs = await SharedPreferences.getInstance();
        final lastViewedStr = prefs.getString('last_viewed_doc_approval_${widget.classId}');
        DateTime? lastViewed;
        if (lastViewedStr != null) {
          lastViewed = DateTime.tryParse(lastViewedStr);
        }

        bool hasUnread = false;
        for (final d in docs) {
          if (d['status'] != 'pending') {
            final updatedAtStr = d['updated_at'] ?? d['approved_at'] ?? d['created_at'];
            if (updatedAtStr != null) {
              final updatedAt = DateTime.tryParse(updatedAtStr.toString());
              if (updatedAt != null) {
                if (lastViewed == null || updatedAt.isAfter(lastViewed)) {
                  hasUnread = true;
                  break;
                }
              }
            }
          }
        }

        if (mounted) {
          setState(() {
            _hasUnreadDocResponse = hasUnread;
          });
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _docPollTimer?.cancel();
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final isDosen = auth.role == 'dosen';
    final hasSignature = auth.user?['signature_url'] != null && auth.user!['signature_url'].toString().isNotEmpty;

    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: _kNavyDark),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            if (!isMobile) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF818CF8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kNavyDark, width: 1.2),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.biotech_rounded, size: 14, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      'KELAS RISET',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, color: Colors.white),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.className,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: isMobile ? 14 : 16, color: _kNavyDark),
                  ),
                  if (widget.subject != null)
                    Text(
                      widget.subject!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Colors.black54, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (isDosen) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TextButton.icon(
                onPressed: () => SignatureUploadDialog.show(context),
                icon: Icon(
                  hasSignature ? Icons.check_circle_rounded : Icons.draw_rounded,
                  size: 15,
                  color: hasSignature ? const Color(0xFF059669) : const Color(0xFFD97706),
                ),
                label: Text(
                  hasSignature ? (isMobile ? 'TTD' : 'TTD Digital Siap') : (isMobile ? 'Upload TTD' : 'Upload TTD PNG'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: hasSignature ? const Color(0xFF059669) : const Color(0xFFD97706),
                  ),
                ),
                style: TextButton.styleFrom(
                  backgroundColor: hasSignature ? const Color(0xFFECFDF5) : const Color(0xFFFEF3C7),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: hasSignature ? const Color(0xFF059669) : const Color(0xFFD97706), width: 1),
                  ),
                  padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 10, vertical: 4),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Container(
            color: _kCreamBg,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _kNavyDark, width: 1.2),
              ),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: _kNavyDark,
                unselectedLabelColor: Colors.black54,
                indicatorSize: TabBarIndicatorSize.tab,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                splashBorderRadius: BorderRadius.circular(16),
                indicator: BoxDecoration(
                  color: _kMustardYellow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _kNavyDark, width: 1),
                ),
                tabs: [
                  const Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.groups_rounded, size: 16),
                        SizedBox(width: 6),
                        Text('👥 Grup Capstone', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                  ),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.assignment_turned_in_rounded, size: 16),
                        const SizedBox(width: 6),
                        const Text('📑 Approval Dokumen', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        if (isDosen && _pendingDocCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDC2626),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                            child: Text(
                              '$_pendingDocCount',
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ] else if (!isDosen && _hasUnreadDocResponse) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 1.5),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x99EF4444),
                                  blurRadius: 6,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(isDosen ? Icons.school_rounded : Icons.analytics_rounded, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          isDosen ? '🎓 Mahasiswa & Keaktifan' : '📊 Performa Keaktifan',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          ResearchGroupsTab(
            classId: widget.classId,
            className: widget.className,
            subject: widget.subject,
            dosenId: widget.dosenId,
          ),
          ResearchDocumentsTab(
            classId: widget.classId,
            className: widget.className,
            subject: widget.subject,
          ),
          if (isDosen)
            ResearchStudentsTab(
              classId: widget.classId,
              className: widget.className,
              subject: widget.subject,
            )
          else
            ResearchStudentPerformanceTab(
              classId: widget.classId,
              className: widget.className,
              subject: widget.subject,
            ),
        ],
      ),
    );
  }
}
