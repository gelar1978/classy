import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/quizizz_service.dart';
import '../../services/socket_service.dart';

const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

class ResearchStudentsTab extends StatefulWidget {
  final String classId;
  final String className;
  final String? subject;

  const ResearchStudentsTab({
    super.key,
    required this.classId,
    required this.className,
    this.subject,
  });

  @override
  State<ResearchStudentsTab> createState() => _ResearchStudentsTabState();
}

class _ResearchStudentsTabState extends State<ResearchStudentsTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _allStudents = [];
  String _searchQuery = '';
  String _filterGroup = 'all'; // 'all', 'with_group', 'no_group'
  String _sortBy = 'keaktifan_desc'; // 'keaktifan_desc', 'keaktifan_asc', 'name_asc', 'nim_asc'
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadStudentsActivity();
    _setupSocketListeners();
    // Auto-refresh berkala setiap 5 detik agar poin keaktifan selalu real-time
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadStudentsActivity(silent: true));
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
          _loadStudentsActivity(silent: true);
        });
        socket.on('research_chat_message', (_) {
          if (!mounted) return;
          _loadStudentsActivity(silent: true);
        });
        socket.on('research_document_submitted', (_) {
          if (!mounted) return;
          _loadStudentsActivity(silent: true);
        });
        socket.on('research_document_updated', (_) {
          if (!mounted) return;
          _loadStudentsActivity(silent: true);
        });
        socket.on('research_document_deleted', (_) {
          if (!mounted) return;
          _loadStudentsActivity(silent: true);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadStudentsActivity({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final data = await QuizizzService.getResearchStudentsActivity(widget.classId);
    if (!mounted) return;
    setState(() {
      _allStudents = data;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _filteredStudents {
    List<Map<String, dynamic>> list = List.from(_allStudents);

    // Filter Pencarian
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      list = list.where((s) {
        final name = (s['nama'] ?? '').toString().toLowerCase();
        final nim = (s['nim'] ?? '').toString().toLowerCase();
        final group = (s['group_name'] ?? '').toString().toLowerCase();
        final title = (s['group_title'] ?? '').toString().toLowerCase();
        return name.contains(q) || nim.contains(q) || group.contains(q) || title.contains(q);
      }).toList();
    }

    // Filter Status Grup
    if (_filterGroup == 'with_group') {
      list = list.where((s) => s['group_id'] != null && (s['group_name'] ?? '-') != '-').toList();
    } else if (_filterGroup == 'no_group') {
      list = list.where((s) => s['group_id'] == null || (s['group_name'] ?? '-') == '-').toList();
    }

    // Sorting
    list.sort((a, b) {
      if (_sortBy == 'keaktifan_desc') {
        final pA = (a['keaktifan'] as num?) ?? 0;
        final pB = (b['keaktifan'] as num?) ?? 0;
        if (pA != pB) return pB.compareTo(pA);
        return (a['nama'] ?? '').toString().compareTo((b['nama'] ?? '').toString());
      } else if (_sortBy == 'keaktifan_asc') {
        final pA = (a['keaktifan'] as num?) ?? 0;
        final pB = (b['keaktifan'] as num?) ?? 0;
        if (pA != pB) return pA.compareTo(pB);
        return (a['nama'] ?? '').toString().compareTo((b['nama'] ?? '').toString());
      } else if (_sortBy == 'name_asc') {
        return (a['nama'] ?? '').toString().compareTo((b['nama'] ?? '').toString());
      } else if (_sortBy == 'nim_asc') {
        return (a['nim'] ?? '').toString().compareTo((b['nim'] ?? '').toString());
      }
      return 0;
    });

    return list;
  }

  void _showActivityRuleDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _kNavyDark, width: 2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFD97706)),
              ),
              child: const Icon(Icons.star_rate_rounded, color: Color(0xFFB45309), size: 22),
            ),
            const SizedBox(width: 12),
            const Text(
              'Aturan Perhitungan Keaktifan',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRuleItem('💬 Partisipasi Diskusi di Grup', 'Poin 1 akan diberikan pada mahasiswa yang memberikan satu kalimat/pertanyaan/pernyataan di grup.'),
            const SizedBox(height: 10),
            _buildRuleItem('📝 Syarat Minimal 4 Kata', 'Poin hanya diberikan jika dalam 1 kalimat minimal terdiri dari 4 kata. Kalimat pendek (< 4 kata) tidak dihitung poin.'),
            const SizedBox(height: 10),
            _buildRuleItem('🏛️ Grup Besar (Forum Kelas) - 2 Poin', 'Setiap kalimat valid (min 4 kata) di forum kelas umum bernilai 2 poin (bobot 2x lebih tinggi).'),
            const SizedBox(height: 10),
            _buildRuleItem('👥 Grup Kecil (Grup TA/Riset) - 1 Poin', 'Setiap kalimat valid (min 4 kata) di ruang diskusi grup riset bernilai 1 poin.'),
            const SizedBox(height: 10),
            _buildRuleItem('🚫 Chat Japri (PM) - 0 Poin', 'Pesan japri/private message tidak mendapatkan poin keaktifan.'),
            const SizedBox(height: 10),
            _buildRuleItem('📄 Pengajuan Dokumen - 1 Poin', 'Setiap pengajuan/unggah berkas approval riset mendapatkan 1 poin per dokumen.'),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Mengerti', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleItem(String title, String desc) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
          const SizedBox(height: 3),
          Text(desc, style: const TextStyle(fontSize: 11, color: Colors.black87, height: 1.3)),
        ],
      ),
    );
  }

  void _showStudentDetail(Map<String, dynamic> s) {
    final detail = s['detail_keaktifan'] as Map<String, dynamic>? ?? {};
    final forumChatCount = (detail['forum_chat_count'] as num?)?.toInt() ?? 0;
    final forumChatPoints = (detail['forum_chat_points'] as num?)?.toInt() ?? 0;
    final groupChatCount = (detail['group_chat_count'] as num?)?.toInt() ?? 0;
    final groupChatPoints = (detail['group_chat_points'] as num?)?.toInt() ?? 0;
    final docCount = (detail['doc_count'] as num?)?.toInt() ?? 0;
    final docPoints = (detail['doc_points'] as num?)?.toInt() ?? 0;
    final totalPoints = s['keaktifan'] ?? 0;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _kNavyDark, width: 2),
        ),
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              radius: 20,
              child: Text(
                (s['nama'] != null && s['nama'].toString().isNotEmpty)
                    ? s['nama'].toString().substring(0, 1).toUpperCase()
                    : 'M',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s['nama'] ?? 'Mahasiswa',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark),
                  ),
                  Text(
                    'NIM: ${s['nim'] ?? '-'}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // GRUP & JUDUL RISET
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.groups_rounded, size: 16, color: _kNavyDark),
                        const SizedBox(width: 6),
                        Text(
                          'Grup: ${s['group_name'] ?? '-'}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text('Judul Riset:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black54)),
                    const SizedBox(height: 2),
                    Text(
                      s['group_title'] ?? '-',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // REKAP KEAKTIFAN (3 KOTAK: FORUM KELAS 2X, GRUP RISET 1X, DOKUMEN APPROVAL)
              const Text('Rincian Akumulasi Poin Keaktifan:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
              const SizedBox(height: 8),

              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF93C5FD)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('🏛️ Forum Kelas', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8))),
                          const SizedBox(height: 4),
                          Text('$forumChatPoints Poin', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF1E40AF))),
                          Text('($forumChatCount pesan valid, @2 poin/kalimat)', style: const TextStyle(fontSize: 9, color: Colors.black54)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F3FF),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFC4B5FD)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('👥 Grup Riset', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF6D28D9))),
                          const SizedBox(height: 4),
                          Text('$groupChatPoints Poin', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF5B21B6))),
                          Text('($groupChatCount pesan valid, @1 poin/kalimat)', style: const TextStyle(fontSize: 9, color: Colors.black54)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF6EE7B7)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('📄 Dokumen Approval', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF047857))),
                        Text('$docCount berkas dokumen diajukan', style: const TextStyle(fontSize: 10, color: Colors.black54)),
                      ],
                    ),
                    Text('$docPoints Poin', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF065F46))),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // TOTAL POIN BESAR
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFD97706), width: 1.2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('⭐ Total Keaktifan:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF78350F))),
                    Text(
                      '$totalPoints Poin',
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFFB45309)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Tutup', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmResetPassword(Map<String, dynamic> student) async {
    final studentId = student['student_id']?.toString() ?? '';
    final studentName = student['nama'] ?? 'Mahasiswa';
    final nim = (student['nim'] ?? '').toString().trim();

    if (nim.isEmpty || nim == '-') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ Mahasiswa $studentName belum memiliki NIM yang terdaftar.'),
          backgroundColor: Colors.orange.shade800,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: _kNavyDark, width: 2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDC2626)),
              ),
              child: const Icon(Icons.lock_reset_rounded, color: Color(0xFFDC2626), size: 22),
            ),
            const SizedBox(width: 10),
            const Text(
              'Reset Password Mahasiswa',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Apakah Anda yakin ingin mereset password untuk mahasiswa berikut?',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Nama : $studentName', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 4),
                  Text('NIM  : $nim', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark, fontFamily: 'monospace')),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Text(
                '🔑 Password baru mahasiswa akan diset sama dengan NIM: "$nim".',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF1E40AF)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: Colors.black54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Ya, Reset Password', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sedang mereset password mahasiswa...'), duration: Duration(seconds: 1)),
      );

      final res = await QuizizzService.resetStudentPasswordToNim(studentId);
      if (!mounted) return;

      if (res['status'] == 'sukses') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ${res['message'] ?? 'Password mahasiswa berhasil direset ke NIM!'}'),
            backgroundColor: const Color(0xFF059669),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Gagal mereset password: ${res['message'] ?? 'Terjadi kesalahan'}'),
            backgroundColor: const Color(0xFFDC2626),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    }

    final students = _filteredStudents;
    final totalStudents = _allStudents.length;
    final totalPointsAll = _allStudents.fold<int>(0, (sum, s) => sum + ((s['keaktifan'] as num?)?.toInt() ?? 0));
    final avgPoints = totalStudents > 0 ? (totalPointsAll / totalStudents).toStringAsFixed(1) : '0';
    final hasGroupCount = _allStudents.where((s) => s['group_id'] != null && (s['group_name'] ?? '-') != '-').length;

    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;

    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // BANNER STATS
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _kNavyDark, width: 2),
                boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _kMustardYellow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _kNavyDark, width: 1.5),
                        ),
                        child: const Icon(Icons.school_rounded, color: _kNavyDark, size: 26),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Rekap Mahasiswa & Keaktifan Riset ($totalStudents Mahasiswa)',
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                            ),
                            const Text(
                              'Daftar lengkap seluruh mahasiswa di kelas riset beserta grup, judul riset, dan poin keaktifan.',
                              style: TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _showActivityRuleDialog,
                        icon: const Icon(Icons.info_outline_rounded, color: _kNavyDark),
                        tooltip: 'Aturan Poin Keaktifan',
                      ),
                      IconButton(
                        onPressed: () => _loadStudentsActivity(),
                        icon: const Icon(Icons.refresh_rounded, color: _kNavyDark),
                        tooltip: 'Segarkan Data',
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: Colors.black12),
                  const SizedBox(height: 12),

                  // STAT METRICS CHIPS
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      _buildMetricChip(Icons.people_alt_rounded, 'Total Mahasiswa', '$totalStudents Orang', const Color(0xFFEFF6FF), const Color(0xFF1D4ED8)),
                      _buildMetricChip(Icons.groups_rounded, 'Sudah Punya Grup', '$hasGroupCount Mhs', const Color(0xFFECFDF5), const Color(0xFF059669)),
                      _buildMetricChip(Icons.person_off_rounded, 'Belum Ada Grup', '${totalStudents - hasGroupCount} Mhs', const Color(0xFFFFF1F2), const Color(0xFFDC2626)),
                      _buildMetricChip(Icons.star_rounded, 'Rata-Rata Keaktifan', '$avgPoints Poin', const Color(0xFFFEF3C7), const Color(0xFFD97706)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // SEARCH & FILTER BAR
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _kNavyDark, width: 1.5),
                boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)],
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  // SEARCH INPUT
                  SizedBox(
                    width: isMobile ? double.infinity : 280,
                    height: 40,
                    child: TextField(
                      onChanged: (val) => setState(() => _searchQuery = val),
                      decoration: InputDecoration(
                        hintText: 'Cari Nama, NIM, Grup, Judul...',
                        hintStyle: const TextStyle(fontSize: 11),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18, color: _kNavyDark),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _kNavyDark)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _kNavyDark, width: 1.5)),
                      ),
                    ),
                  ),

                  // FILTER & SORT
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Filter Dropdown
                      Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _kNavyDark, width: 1),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _filterGroup,
                            icon: const Icon(Icons.filter_list_rounded, size: 16, color: _kNavyDark),
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kNavyDark),
                            items: const [
                              DropdownMenuItem(value: 'all', child: Text('Semua Status Grup')),
                              DropdownMenuItem(value: 'with_group', child: Text('Sudah Ada Grup')),
                              DropdownMenuItem(value: 'no_group', child: Text('Belum Ada Grup')),
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _filterGroup = val);
                            },
                          ),
                        ),
                      ),

                      // Sort Dropdown
                      Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _kNavyDark, width: 1),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _sortBy,
                            icon: const Icon(Icons.sort_rounded, size: 16, color: _kNavyDark),
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kNavyDark),
                            items: const [
                              DropdownMenuItem(value: 'keaktifan_desc', child: Text('⭐ Keaktifan Tertinggi')),
                              DropdownMenuItem(value: 'keaktifan_asc', child: Text('Keaktifan Terendah')),
                              DropdownMenuItem(value: 'name_asc', child: Text('Nama (A-Z)')),
                              DropdownMenuItem(value: 'nim_asc', child: Text('NIM (0-9)')),
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _sortBy = val);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // TABLE / LIST MAHASISWA
            if (students.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _kNavyDark, width: 1.5),
                ),
                child: Center(
                  child: Column(
                    children: [
                      const Icon(Icons.person_search_rounded, size: 48, color: Colors.black26),
                      const SizedBox(height: 12),
                      Text(
                        _searchQuery.isNotEmpty ? 'Tidak ada mahasiswa yang cocok dengan pencarian "$_searchQuery"' : 'Belum ada mahasiswa yang terdaftar di kelas riset ini.',
                        style: const TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              )
            else if (!isMobile)
              // DESKTOP TABLE VIEW
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
                      DataColumn(label: Text('NO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('MAHASISWA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('NIM', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('GRUP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('JUDUL RISET', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('KEAKTIFAN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('DETAIL', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                      DataColumn(label: Text('RESET PASSWORD', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                    ],
                    rows: students.asMap().entries.map((entry) {
                      final idx = entry.key + 1;
                      final s = entry.value;
                      final pts = (s['keaktifan'] as num?)?.toInt() ?? 0;
                      final hasGroup = s['group_id'] != null && (s['group_name'] ?? '-') != '-';

                      return DataRow(
                        cells: [
                          // NO
                          DataCell(Text('$idx', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),

                          // MAHASISWA
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 15,
                                  backgroundColor: const Color(0xFF001D39),
                                  foregroundColor: Colors.white,
                                  backgroundImage: (s['avatar_url'] != null && s['avatar_url'].toString().isNotEmpty)
                                      ? NetworkImage(ApiService.getFullMediaUrl(s['avatar_url'])!)
                                      : null,
                                  child: (s['avatar_url'] == null || s['avatar_url'].toString().isEmpty)
                                      ? Text(
                                          (s['nama'] != null && s['nama'].toString().isNotEmpty)
                                              ? s['nama'].toString().substring(0, 1).toUpperCase()
                                              : 'M',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        s['nama'] ?? 'Mahasiswa',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (s['email'] != null && s['email'] != '-')
                                        Text(
                                          s['email'],
                                          style: const TextStyle(fontSize: 10, color: Colors.black45),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // NIM
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.black12),
                              ),
                              child: Text(
                                s['nim'] ?? '-',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace'),
                              ),
                            ),
                          ),

                          // GRUP
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: hasGroup ? const Color(0xFFEFF6FF) : const Color(0xFFFFF1F2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: hasGroup ? const Color(0xFF93C5FD) : const Color(0xFFFECDD3)),
                              ),
                              child: Text(
                                s['group_name'] ?? '-',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                  color: hasGroup ? const Color(0xFF1D4ED8) : const Color(0xFFDC2626),
                                ),
                              ),
                            ),
                          ),

                          // JUDUL RISET
                          DataCell(
                            SizedBox(
                              width: 220,
                              child: Text(
                                s['group_title'] ?? '-',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: (s['group_title'] == null || s['group_title'] == '-') ? Colors.black38 : Colors.black87,
                                  fontWeight: (s['group_title'] == null || s['group_title'] == '-') ? FontWeight.normal : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                          // KEAKTIFAN
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: pts > 0 ? const Color(0xFFFEF3C7) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: pts > 0 ? const Color(0xFFD97706) : Colors.black12, width: 1.2),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.star_rounded, size: 14, color: pts > 0 ? const Color(0xFFB45309) : Colors.black38),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$pts Poin',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11,
                                      color: pts > 0 ? const Color(0xFFB45309) : Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // DETAIL
                          DataCell(
                            IconButton(
                              icon: const Icon(Icons.info_rounded, size: 18, color: Color(0xFF1D4ED8)),
                              tooltip: 'Lihat Rincian Keaktifan',
                              onPressed: () => _showStudentDetail(s),
                            ),
                          ),

                          // RESET PASSWORD
                          DataCell(
                            ElevatedButton.icon(
                              onPressed: () => _confirmResetPassword(s),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFDC2626),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                elevation: 0,
                              ),
                              icon: const Icon(Icons.lock_reset_rounded, size: 14),
                              label: const Text('Reset NIM', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              )
            else
              // MOBILE CARD LIST VIEW
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: students.length,
                separatorBuilder: (ctx, i) => const SizedBox(height: 12),
                itemBuilder: (ctx, idx) {
                  final s = students[idx];
                  final pts = (s['keaktifan'] as num?)?.toInt() ?? 0;
                  final hasGroup = s['group_id'] != null && (s['group_name'] ?? '-') != '-';

                  return Container(
                    padding: const EdgeInsets.all(14),
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: _kNavyDark,
                              foregroundColor: Colors.white,
                              backgroundImage: (s['avatar_url'] != null && s['avatar_url'].toString().isNotEmpty)
                                  ? NetworkImage(ApiService.getFullMediaUrl(s['avatar_url'])!)
                                  : null,
                              child: (s['avatar_url'] == null || s['avatar_url'].toString().isEmpty)
                                  ? Text(
                                      (s['nama'] != null && s['nama'].toString().isNotEmpty)
                                          ? s['nama'].toString().substring(0, 1).toUpperCase()
                                          : 'M',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s['nama'] ?? 'Mahasiswa',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
                                  ),
                                  Text('NIM: ${s['nim'] ?? '-'}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: pts > 0 ? const Color(0xFFFEF3C7) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: pts > 0 ? const Color(0xFFD97706) : Colors.black12),
                              ),
                              child: Text(
                                '⭐ $pts Poin',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                  color: pts > 0 ? const Color(0xFFB45309) : Colors.black54,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Divider(height: 1, color: Colors.black12),
                        const SizedBox(height: 8),

                        Row(
                          children: [
                            const Text('Grup: ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black54)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: hasGroup ? const Color(0xFFEFF6FF) : const Color(0xFFFFF1F2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                s['group_name'] ?? '-',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 10,
                                  color: hasGroup ? const Color(0xFF1D4ED8) : const Color(0xFFDC2626),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Judul: ${s['group_title'] ?? '-'}',
                          style: const TextStyle(fontSize: 11, color: Colors.black87),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            ElevatedButton.icon(
                              onPressed: () => _confirmResetPassword(s),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFEE2E2),
                                foregroundColor: const Color(0xFFDC2626),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: const BorderSide(color: Color(0xFFFECDD3)),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              ),
                              icon: const Icon(Icons.lock_reset_rounded, size: 14),
                              label: const Text('Reset Password (NIM)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                            TextButton.icon(
                              onPressed: () => _showStudentDetail(s),
                              icon: const Icon(Icons.info_outline_rounded, size: 14),
                              label: const Text('Rincian Poin', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF1D4ED8),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              ),
                            ),
                          ],
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

  Widget _buildMetricChip(IconData icon, String label, String value, Color bg, Color textCol) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: textCol.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: textCol),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontSize: 9, color: Colors.black54, fontWeight: FontWeight.w600)),
              Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: textCol)),
            ],
          ),
        ],
      ),
    );
  }
}
