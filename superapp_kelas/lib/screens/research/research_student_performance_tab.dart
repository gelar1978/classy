import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/quizizz_service.dart';
import '../../services/socket_service.dart';

const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

class ResearchStudentPerformanceTab extends StatefulWidget {
  final String classId;
  final String className;
  final String? subject;

  const ResearchStudentPerformanceTab({
    super.key,
    required this.classId,
    required this.className,
    this.subject,
  });

  @override
  State<ResearchStudentPerformanceTab> createState() => _ResearchStudentPerformanceTabState();
}

class _ResearchStudentPerformanceTabState extends State<ResearchStudentPerformanceTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _students = [];
  Map<String, dynamic>? _myStudentData;
  int _myRank = 1;
  String _searchQuery = '';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadPerformanceData();
    _setupSocketListeners();
    // Auto-refresh berkala setiap 5 detik agar poin keaktifan selalu sinkron
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadPerformanceData(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _setupSocketListeners() {
    try {
      final socket = SocketService.socket;
      if (socket != null) {
        socket.on('class_chat_message', (_) {
          if (!mounted) return;
          _loadPerformanceData(silent: true);
        });
        socket.on('research_chat_message', (_) {
          if (!mounted) return;
          _loadPerformanceData(silent: true);
        });
        socket.on('research_document_submitted', (_) {
          if (!mounted) return;
          _loadPerformanceData(silent: true);
        });
        socket.on('research_document_updated', (_) {
          if (!mounted) return;
          _loadPerformanceData(silent: true);
        });
        socket.on('research_document_deleted', (_) {
          if (!mounted) return;
          _loadPerformanceData(silent: true);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadPerformanceData({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final data = await QuizizzService.getResearchStudentsActivity(widget.classId);
    if (!mounted) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final currentUserId = auth.user?['id']?.toString() ?? '';

    // Urutkan berdasarkan keaktifan tertinggi untuk menghitung rank
    List<Map<String, dynamic>> sorted = List.from(data);
    sorted.sort((a, b) {
      final pA = (a['keaktifan'] as num?) ?? 0;
      final pB = (b['keaktifan'] as num?) ?? 0;
      if (pA != pB) return pB.compareTo(pA);
      return (a['nama'] ?? '').toString().compareTo((b['nama'] ?? '').toString());
    });

    Map<String, dynamic>? myData;
    int rank = 1;
    for (int i = 0; i < sorted.length; i++) {
      final s = sorted[i];
      if (s['student_id'] == currentUserId || s['is_current_user'] == true) {
        myData = s;
        rank = i + 1;
        break;
      }
    }

    // Jika tidak ditemukan via ID, fallback ke data user dari auth
    if (myData == null && auth.user != null) {
      final u = auth.user!;
      myData = {
        'nama': u['name'] ?? u['full_name'] ?? 'Mahasiswa',
        'nim': u['nim'] ?? '-',
        'group_name': '-',
        'group_title': '-',
        'keaktifan': 0,
        'detail_keaktifan': {'chat_count': 0, 'chat_points': 0, 'doc_count': 0, 'doc_points': 0, 'total_points': 0},
      };
    }

    setState(() {
      _students = sorted;
      _myStudentData = myData;
      _myRank = rank;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _filteredStudents {
    if (_searchQuery.trim().isEmpty) return _students;
    final q = _searchQuery.trim().toLowerCase();
    return _students.where((s) {
      final name = (s['nama'] ?? '').toString().toLowerCase();
      final nim = (s['nim'] ?? '').toString().toLowerCase();
      final group = (s['group_name'] ?? '').toString().toLowerCase();
      final title = (s['group_title'] ?? '').toString().toLowerCase();
      return name.contains(q) || nim.contains(q) || group.contains(q) || title.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    }

    final myData = _myStudentData ?? {};
    final myPoints = (myData['keaktifan'] as num?)?.toInt() ?? 0;
    final myDetail = myData['detail_keaktifan'] as Map<String, dynamic>? ?? {};
    final myForumChatPoints = (myDetail['forum_chat_points'] as num?)?.toInt() ?? 0;
    final myForumChatCount = (myDetail['forum_chat_count'] as num?)?.toInt() ?? 0;
    final myGroupChatPoints = (myDetail['group_chat_points'] as num?)?.toInt() ?? 0;
    final myGroupChatCount = (myDetail['group_chat_count'] as num?)?.toInt() ?? 0;
    final myDocPoints = (myDetail['doc_points'] as num?)?.toInt() ?? 0;
    final myDocCount = (myDetail['doc_count'] as num?)?.toInt() ?? 0;

    final totalStudents = _students.length;
    final totalPointsAll = _students.fold<int>(0, (sum, s) => sum + ((s['keaktifan'] as num?)?.toInt() ?? 0));
    final avgPoints = totalStudents > 0 ? (totalPointsAll / totalStudents) : 0.0;

    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;

    // Badge Level Keaktifan
    String levelBadge = '🌱 Terus Tingkatkan';
    Color levelBg = const Color(0xFFEFF6FF);
    Color levelText = const Color(0xFF1D4ED8);
    if (myPoints >= 20 || _myRank == 1) {
      levelBadge = '🏆 Top Contributor (Sangat Aktif)';
      levelBg = const Color(0xFFFEF3C7);
      levelText = const Color(0xFFB45309);
    } else if (myPoints >= 8 || _myRank <= 5) {
      levelBadge = '🔥 Aktif Berkontribusi';
      levelBg = const Color(0xFFECFDF5);
      levelText = const Color(0xFF047857);
    }

    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. HERO CARD PERFORMA DIRI
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF001D39), Color(0xFF0A3A67)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: _kNavyDark, width: 2),
                boxShadow: const [BoxShadow(color: Color(0x33001D39), offset: Offset(4, 4), blurRadius: 10)],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // PROFILE INFO
                      Expanded(
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: isMobile ? 22 : 28,
                              backgroundColor: _kMustardYellow,
                              foregroundColor: _kNavyDark,
                              child: Text(
                                (myData['nama'] != null && myData['nama'].toString().isNotEmpty)
                                    ? myData['nama'].toString().substring(0, 1).toUpperCase()
                                    : 'M',
                                style: TextStyle(fontWeight: FontWeight.w900, fontSize: isMobile ? 18 : 22),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          myData['nama'] ?? 'Mahasiswa',
                                          style: TextStyle(fontWeight: FontWeight.w900, fontSize: isMobile ? 15 : 18, color: Colors.white),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: const Text('Akun Anda', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'NIM: ${myData['nim'] ?? '-'} • ${myData['group_name'] ?? 'Belum ada grup'}',
                                    style: const TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.w600),
                                  ),
                                  if (myData['group_title'] != null && myData['group_title'] != '-') ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Judul: ${myData['group_title']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11, color: Colors.white60),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      // REFRESH BUTTON
                      IconButton(
                        onPressed: () => _loadPerformanceData(),
                        icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
                        tooltip: 'Segarkan Performa',
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Divider(height: 1, color: Colors.white24),
                  const SizedBox(height: 16),

                  // HIGHLIGHT METRICS (TOTAL POIN & RANK)
                  Wrap(
                    spacing: 14,
                    runSpacing: 12,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // TOTAL POIN
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFBBF24),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.star_rounded, color: _kNavyDark, size: 26),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('TOTAL KEAKTIFAN ANDA', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white70, letterSpacing: 0.5)),
                              Text(
                                '$myPoints Poin',
                                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white),
                              ),
                            ],
                          ),
                        ],
                      ),

                      // PERINGKAT DI KELAS
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.emoji_events_rounded, color: Color(0xFFFBBF24), size: 26),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('PERINGKAT DI KELAS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white70, letterSpacing: 0.5)),
                              Text(
                                '#$_myRank dari $totalStudents Mahasiswa',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white),
                              ),
                            ],
                          ),
                        ],
                      ),

                      // STATUS BADGE
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: levelBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: levelText.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          levelBadge,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: levelText),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 2. BREAKDOWN AKTIVITAS DIRI (3 KOTAK)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                // FORUM KELAS (GRUP BESAR @2 POIN)
                Container(
                  width: isMobile ? double.infinity : (screenWidth - 64) / 3,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _kNavyDark, width: 1.5),
                    boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.forum_rounded, color: Color(0xFF1D4ED8), size: 20),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              '🏛️ Forum Kelas (Grup Besar)',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '$myForumChatPoints Poin',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1E40AF)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Total $myForumChatCount pesan valid (bobot 2x lipat, @2 poin/kalimat min 4 kata)',
                        style: const TextStyle(fontSize: 10, color: Colors.black54),
                      ),
                    ],
                  ),
                ),

                // GRUP RISET (GRUP KECIL @1 POIN)
                Container(
                  width: isMobile ? double.infinity : (screenWidth - 64) / 3,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _kNavyDark, width: 1.5),
                    boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: const Color(0xFFF5F3FF), borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.groups_rounded, color: Color(0xFF6D28D9), size: 20),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              '👥 Grup Riset/TA (Grup Kecil)',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '$myGroupChatPoints Poin',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF5B21B6)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Total $myGroupChatCount pesan valid (@1 poin/kalimat min 4 kata)',
                        style: const TextStyle(fontSize: 10, color: Colors.black54),
                      ),
                    ],
                  ),
                ),

                // DOKUMEN APPROVAL
                Container(
                  width: isMobile ? double.infinity : (screenWidth - 64) / 3,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _kNavyDark, width: 1.5),
                    boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.upload_file_rounded, color: Color(0xFF047857), size: 20),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              '📄 Dokumen Approval',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '$myDocPoints Poin',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF065F46)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Total $myDocCount berkas dokumen diajukan (@1 poin/dokumen)',
                        style: const TextStyle(fontSize: 10, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // CARD ATURAN DAN PERBANDINGAN
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFD97706), width: 1.2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Color(0xFFB45309), size: 20),
                      const SizedBox(width: 8),
                      const Text('Aturan Keaktifan:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF78350F))),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '• Poin 1 akan diberikan pada mahasiswa yang memberikan satu kalimat/pertanyaan/pernyataan di grup.\n'
                    '• Poin chat hanya diberikan jika dalam 1 kalimat minimal ada 4 kata (kalimat pendek tidak mendapat poin).\n'
                    '• Chat di Forum Kelas bernilai 2x lipat (2 poin/kalimat valid). Chat di Grup Riset bernilai 1 poin/kalimat valid.\n'
                    '• Pesan japri tidak mendapatkan poin. Setiap pengajuan berkas dokumen bernilai 1 poin.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF78350F), height: 1.35),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // CARD RATA-RATA KELAS
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFD97706), width: 1.2),
              ),
              child: Row(
                children: [
                  const Icon(Icons.analytics_outlined, color: Color(0xFFB45309), size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 12, color: Color(0xFF78350F)),
                        children: [
                          const TextSpan(text: 'Rata-rata keaktifan kelas adalah '),
                          TextSpan(
                            text: '${avgPoints.toStringAsFixed(1)} Poin. ',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          TextSpan(
                            text: myPoints >= avgPoints
                                ? '🎉 Performa Anda berada DI ATAS rata-rata kelas! Pertahankan keaktifan Anda.'
                                : '💡 Tingkatkan keaktifan Anda dengan lebih aktif berdiskusi di forum, grup, atau bertanya ke dosen.',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: myPoints >= avgPoints ? const Color(0xFF047857) : const Color(0xFF92400E),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 3. TABEL LEADERBOARD / KEAKTIFAN KELAS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tabel Keaktifan & Peringkat Kelas',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                    ),
                    Text(
                      'Posisi performa keaktifan seluruh mahasiswa dalam kelas riset ini',
                      style: TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                SizedBox(
                  width: isMobile ? 150 : 220,
                  height: 38,
                  child: TextField(
                    onChanged: (val) => setState(() => _searchQuery = val),
                    decoration: InputDecoration(
                      hintText: 'Cari Mahasiswa...',
                      hintStyle: const TextStyle(fontSize: 11),
                      prefixIcon: const Icon(Icons.search_rounded, size: 16, color: _kNavyDark),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _kNavyDark)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // LEADERBOARD DATA TABLE / LIST
            if (!isMobile)
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _kNavyDark, width: 1.8),
                  boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(const Color(0xFF001D39)),
                    dataRowMinHeight: 52,
                    dataRowMaxHeight: 68,
                    horizontalMargin: 16,
                    columnSpacing: 18,
                    columns: const [
                      DataColumn(label: Text('RANK', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('MAHASISWA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('NIM', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('GRUP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('JUDUL RISET', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('KEAKTIFAN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                    ],
                    rows: _filteredStudents.asMap().entries.map((entry) {
                      final rank = entry.key + 1;
                      final s = entry.value;
                      final isMe = s['is_current_user'] == true || s['student_id'] == (myData['student_id'] ?? '');
                      final pts = (s['keaktifan'] as num?)?.toInt() ?? 0;
                      final hasGroup = s['group_id'] != null && (s['group_name'] ?? '-') != '-';

                      return DataRow(
                        color: isMe
                            ? WidgetStateProperty.all(const Color(0xFFEFF6FF))
                            : (rank % 2 == 0 ? WidgetStateProperty.all(const Color(0xFFFAFAFA)) : null),
                        cells: [
                          // RANK
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (rank == 1)
                                  const Text('🥇', style: TextStyle(fontSize: 16))
                                else if (rank == 2)
                                  const Text('🥈', style: TextStyle(fontSize: 16))
                                else if (rank == 3)
                                  const Text('🥉', style: TextStyle(fontSize: 16))
                                else
                                  Text('#$rank', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              ],
                            ),
                          ),

                          // MAHASISWA
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 14,
                                  backgroundColor: isMe ? const Color(0xFF1D4ED8) : _kNavyDark,
                                  foregroundColor: Colors.white,
                                  child: Text(
                                    (s['nama'] != null && s['nama'].toString().isNotEmpty)
                                        ? s['nama'].toString().substring(0, 1).toUpperCase()
                                        : 'M',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          s['nama'] ?? 'Mahasiswa',
                                          style: TextStyle(
                                            fontWeight: isMe ? FontWeight.w900 : FontWeight.bold,
                                            fontSize: 12,
                                            color: isMe ? const Color(0xFF1D4ED8) : _kNavyDark,
                                          ),
                                        ),
                                        if (isMe) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1D4ED8),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: const Text('Anda', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),

                          // NIM
                          DataCell(
                            Text(
                              s['nim'] ?? '-',
                              style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
                            ),
                          ),

                          // GRUP
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: hasGroup ? const Color(0xFFEFF6FF) : const Color(0xFFFFF1F2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                s['group_name'] ?? '-',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: hasGroup ? const Color(0xFF1D4ED8) : const Color(0xFFDC2626),
                                ),
                              ),
                            ),
                          ),

                          // JUDUL RISET
                          DataCell(
                            SizedBox(
                              width: 200,
                              child: Text(
                                s['group_title'] ?? '-',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ),

                          // KEAKTIFAN
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isMe
                                    ? const Color(0xFFFEF3C7)
                                    : (pts > 0 ? const Color(0xFFF1F5F9) : const Color(0xFFFAFAFA)),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isMe ? const Color(0xFFD97706) : Colors.black12),
                              ),
                              child: Text(
                                '⭐ $pts Poin',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                  color: isMe ? const Color(0xFFB45309) : (pts > 0 ? _kNavyDark : Colors.black45),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              )
            else
              // MOBILE VIEW
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _filteredStudents.length,
                separatorBuilder: (ctx, i) => const SizedBox(height: 10),
                itemBuilder: (ctx, idx) {
                  final rank = idx + 1;
                  final s = _filteredStudents[idx];
                  final isMe = s['is_current_user'] == true || s['student_id'] == (myData['student_id'] ?? '');
                  final pts = (s['keaktifan'] as num?)?.toInt() ?? 0;

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isMe ? const Color(0xFFEFF6FF) : Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: isMe ? const Color(0xFF1D4ED8) : _kNavyDark, width: isMe ? 2 : 1.2),
                    ),
                    child: Row(
                      children: [
                        Text(
                          rank == 1 ? '🥇' : (rank == 2 ? '🥈' : (rank == 3 ? '🥉' : '#$rank')),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      s['nama'] ?? 'Mahasiswa',
                                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isMe ? const Color(0xFF1D4ED8) : _kNavyDark),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isMe) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(color: const Color(0xFF1D4ED8), borderRadius: BorderRadius.circular(4)),
                                      child: const Text('Anda', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ],
                              ),
                              Text('NIM: ${s['nim'] ?? '-'} • ${s['group_name'] ?? '-'}', style: const TextStyle(fontSize: 10, color: Colors.black54)),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFD97706)),
                          ),
                          child: Text(
                            '⭐ $pts Poin',
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Color(0xFFB45309)),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
