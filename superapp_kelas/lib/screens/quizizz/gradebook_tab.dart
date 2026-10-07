import 'package:flutter/material.dart';
import '../../services/quizizz_service.dart';
import '../../utils/export_helper.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);
const Color _kPastelAccent = Color(0xFF6EA2B3);

class GradebookTabView extends StatefulWidget {
  final String? classId;
  final String? className;

  const GradebookTabView({
    super.key,
    this.classId,
    this.className,
  });

  @override
  State<GradebookTabView> createState() => _GradebookTabViewState();
}

class _GradebookTabViewState extends State<GradebookTabView> {
  bool _loading = true;
  String _searchQuery = '';
  Map<String, dynamic>? _gradebookData;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadGradebook();
  }

  String get _effectiveClassId =>
      widget.classId ?? QuizizzService.currentClassId ?? '';

  Future<void> _loadGradebook() async {
    final cId = _effectiveClassId;
    if (cId.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);
    final data = await QuizizzService.getGradebook(cId);
    if (!mounted) return;
    setState(() {
      _gradebookData = data;
      _loading = false;
    });
  }

  Future<void> _showAddAssessmentDialog() async {
    final titleCtrl = TextEditingController();
    final maxScoreCtrl = TextEditingController(text: '100');
    String type = 'quiz';

    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: _kNavyDark, width: 2),
          ),
          title: const Text(
            '➕ Tambah Kolom Penilaian',
            style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark),
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Judul Penilaian / Kuis / Tugas',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 6),
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                    hintText: 'Contoh: Kuis Pekan 2, Tugas 1, UTS',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Tipe Penilaian',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: type,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'quiz', child: Text('Kuis (Quiz)')),
                    DropdownMenuItem(value: 'homework', child: Text('Tugas / PR (Homework)')),
                    DropdownMenuItem(value: 'exam', child: Text('Ujian (UTS / UAS)')),
                    DropdownMenuItem(value: 'other', child: Text('Lainnya (Praktikum / Proyek)')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDlgState(() => type = val);
                  },
                ),
                const SizedBox(height: 16),
                const Text('Nilai Maksimum',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 6),
                TextField(
                  controller: maxScoreCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '100',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal', style: TextStyle(color: _kNavyDark)),
            ),
            ElevatedButton(
              onPressed: () async {
                if (titleCtrl.text.trim().isEmpty) return;
                final maxScore = int.tryParse(maxScoreCtrl.text.trim()) ?? 100;
                final res = await QuizizzService.createGradebookItem(
                  classId: _effectiveClassId,
                  title: titleCtrl.text.trim(),
                  type: type,
                  maxScore: maxScore,
                );
                if (ctx.mounted) Navigator.pop(ctx, res != null);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _kNavyDark,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Tambah Kolom'),
            ),
          ],
        ),
      ),
    );

    if (added == true) await _loadGradebook();
  }

  Future<void> _showEditGradeDialog({
    required Map<String, dynamic> student,
    required Map<String, dynamic> assessment,
    dynamic currentScore,
    dynamic currentNotes,
  }) async {
    final scoreCtrl = TextEditingController(
      text: currentScore != null ? currentScore.toString() : '',
    );
    final notesCtrl = TextEditingController(
      text: currentNotes != null ? currentNotes.toString() : '',
    );

    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _kNavyDark, width: 2),
        ),
        title: Text(
          '✏️ Nilai: ${student['name']}',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NIM: ${student['nim']} | Penilaian: ${assessment['title']}',
                style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              const Text('Nilai (Skor 0 - 100)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
              const SizedBox(height: 6),
              TextField(
                controller: scoreCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  hintText: 'Kosongkan jika belum ada nilai',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Keterangan / Catatan',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
              const SizedBox(height: 6),
              TextField(
                controller: notesCtrl,
                decoration: InputDecoration(
                  hintText: 'Contoh: Sakit, Izin, Magang, Alana-Grace',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: _kNavyDark)),
          ),
          ElevatedButton(
            onPressed: () async {
              final sId = student['student_id']?.toString() ?? '';
              final aId = assessment['id']?.toString() ?? '';
              final scoreText = scoreCtrl.text.trim();
              final scoreVal = scoreText.isNotEmpty ? double.tryParse(scoreText) : null;
              final notesVal = notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null;

              final ok = await QuizizzService.updateStudentGrade(
                classId: _effectiveClassId,
                assessmentId: aId,
                studentId: sId,
                score: scoreVal,
                notes: notesVal,
              );
              if (ctx.mounted) Navigator.pop(ctx, ok);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Simpan Nilai'),
          ),
        ],
      ),
    );

    if (updated == true) await _loadGradebook();
  }

  void _exportExcel(List<Map<String, dynamic>> students, List<Map<String, dynamic>> assessments, Map<String, dynamic> grades) {
    final className = widget.className ?? _gradebookData?['class']?['class_name'] ?? 'Stegano';
    ExportHelper.exportGradebookToExcel(
      className: className,
      students: students,
      assessments: assessments,
      grades: grades,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ File Rekap Nilai (.xlsx) berhasil diunduh!'), backgroundColor: Color(0xFF059669)),
    );
  }

  void _exportCsv(List<Map<String, dynamic>> students, List<Map<String, dynamic>> assessments, Map<String, dynamic> grades) {
    final className = widget.className ?? _gradebookData?['class']?['class_name'] ?? 'Stegano';
    final sb = StringBuffer();
    
    // Header
    List<String> headers = ['No', 'NIM', 'Nama Mahasiswa'];
    for (final a in assessments) {
      headers.add('"${a['title']}"');
    }
    headers.add('Rata-rata');
    headers.add('Catatan');
    sb.writeln(headers.join(','));

    // Rows
    for (final s in students) {
      final sId = s['student_id']?.toString() ?? '';
      final studentGrades = (grades[sId] as Map?) ?? {};
      List<String> row = [
        s['no'].toString(),
        '"${s['nim']}"',
        '"${s['name']}"',
      ];
      double sum = 0;
      int count = 0;
      List<String> notes = [];

      for (final a in assessments) {
        final aId = a['id']?.toString() ?? '';
        final g = studentGrades[aId];
        final sc = g?['score'];
        final nt = g?['notes'];
        if (sc != null) {
          row.add(sc.toString());
          sum += (sc as num).toDouble();
          count++;
        } else if (nt != null && nt.toString().isNotEmpty) {
          row.add('"$nt"');
          notes.add('${a['title']}: $nt');
        } else {
          row.add('-');
        }
      }

      if (count > 0) {
        row.add((sum / count).toStringAsFixed(2));
      } else {
        row.add('-');
      }

      row.add('"${notes.join('; ')}"');
      sb.writeln(row.join(','));
    }

    ExportHelper.exportCsv(
      filename: '${className}_Rekap_Nilai.csv',
      content: sb.toString(),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ File CSV Rekap Nilai berhasil diunduh!'), backgroundColor: Color(0xFF059669)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    }

    if (_gradebookData == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48, color: _kNavyDark),
            const SizedBox(height: 12),
            const Text('Gagal memuat rekap nilai kelas.', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadGradebook,
              icon: const Icon(Icons.refresh),
              label: const Text('Coba Lagi'),
              style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white),
            ),
          ],
        ),
      );
    }

    final rawStudents = (_gradebookData?['students'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final assessments = (_gradebookData?['assessments'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final grades = (_gradebookData?['grades'] as Map<String, dynamic>?) ?? {};
    final classInfo = _gradebookData?['class'] as Map<String, dynamic>?;

    // Filter students
    final filteredStudents = rawStudents.where((s) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery.toLowerCase();
      final name = (s['name'] ?? '').toString().toLowerCase();
      final nim = (s['nim'] ?? '').toString().toLowerCase();
      return name.contains(query) || nim.contains(query);
    }).toList();

    // Compute stats
    int totalScored = 0;
    double totalSum = 0;
    for (final s in rawStudents) {
      final sId = s['student_id']?.toString() ?? '';
      final studentGrades = (grades[sId] as Map?) ?? {};
      for (final a in assessments) {
        final aId = a['id']?.toString() ?? '';
        final sc = studentGrades[aId]?['score'];
        if (sc != null) {
          totalSum += (sc as num).toDouble();
          totalScored++;
        }
      }
    }
    final classAverage = totalScored > 0 ? (totalSum / totalScored).toStringAsFixed(1) : '0';

    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // BANNER STATS
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _kNavyDark, width: 2),
              boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _kMustardYellow,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: _kNavyDark, width: 1.5),
                          ),
                          child: const Icon(Icons.analytics_rounded, color: _kNavyDark, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Rekap Nilai Kelas ${classInfo?['class_name'] ?? 'Stegano'}',
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark),
                            ),
                            Text(
                              'Mata Kuliah: ${classInfo?['subject'] ?? 'Steganografi dan Watermarking'}',
                              style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ],
                    ),
                    ElevatedButton.icon(
                      onPressed: _showAddAssessmentDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kNavyDark,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Tambah Kolom Nilai', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Divider(color: _kNavyDark, thickness: 1),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _buildStatCard('👥 Total Mahasiswa', '${rawStudents.length} Mahasiswa', Icons.people_alt_outlined),
                    const SizedBox(width: 12),
                    _buildStatCard('📝 Total Penilaian', '${assessments.length} Kolom', Icons.quiz_outlined),
                    const SizedBox(width: 12),
                    _buildStatCard('🎯 Rata-rata Nilai', '$classAverage / 100', Icons.star_rounded),
                    const SizedBox(width: 12),
                    _buildStatCard('✅ Sudah Kuis 1', '39 / 47 (83%)', Icons.check_circle_outline_rounded),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // CONTROLS BAR: SEARCH + EXPORT
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  decoration: InputDecoration(
                    hintText: 'Cari berdasarkan Nama atau NIM Mahasiswa...',
                    prefixIcon: const Icon(Icons.search, color: _kNavyDark),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: _kNavyDark, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: () => _exportExcel(rawStudents, assessments, grades),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF059669),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: _kNavyDark, width: 1.5),
                  ),
                ),
                icon: const Icon(Icons.table_chart_rounded, size: 18),
                label: const Text('Export Excel (.xlsx)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _exportCsv(rawStudents, assessments, grades),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kMustardYellow,
                  foregroundColor: _kNavyDark,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: _kNavyDark, width: 1.5),
                  ),
                ),
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Export CSV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _loadGradebook,
                tooltip: 'Refresh Data Nilai',
                icon: const Icon(Icons.refresh_rounded, color: _kNavyDark),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: _kNavyDark, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // GRADEBOOK TABLE
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _kNavyDark, width: 2),
              boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(_kPastelAccent.withValues(alpha: 0.3)),
                  headingTextStyle: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13),
                  dataRowColor: WidgetStateProperty.resolveWith<Color>((states) {
                    return Colors.white;
                  }),
                  columnSpacing: 24,
                  horizontalMargin: 20,
                  columns: [
                    const DataColumn(label: Text('No.')),
                    const DataColumn(label: Text('NIM')),
                    const DataColumn(label: Text('Nama Mahasiswa')),
                    ...assessments.map((a) => DataColumn(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(a['title'] ?? 'Penilaian'),
                              const SizedBox(width: 4),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, size: 16, color: _kNavyDark),
                                tooltip: 'Kelola Kolom',
                                onSelected: (val) async {
                                  if (val == 'delete') {
                                    final confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Hapus Kolom Penilaian?'),
                                        content: Text('Kolom "${a['title']}" dan seluruh nilai di dalamnya akan dihapus.'),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
                                          ElevatedButton(
                                            onPressed: () => Navigator.pop(ctx, true),
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                                            child: const Text('Hapus'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true) {
                                      await QuizizzService.deleteGradebookItem(_effectiveClassId, a['id']);
                                      await _loadGradebook();
                                    }
                                  }
                                },
                                itemBuilder: (ctx) => [
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                        SizedBox(width: 8),
                                        Text('Hapus Kolom', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        )),
                    const DataColumn(label: Text('Rata-rata')),
                    const DataColumn(label: Text('Keterangan')),
                  ],
                  rows: filteredStudents.map((s) {
                    final sId = s['student_id']?.toString() ?? '';
                    final studentGrades = (grades[sId] as Map?) ?? {};

                    double sum = 0;
                    int count = 0;
                    List<String> studentNotes = [];

                    final cells = <DataCell>[
                      DataCell(Text(s['no'].toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                      DataCell(Text(s['nim'] ?? '-', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: _kNavyDark))),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 14,
                              backgroundColor: _kMustardYellow,
                              child: Text(
                                (s['name'] != null && s['name'].toString().isNotEmpty) ? s['name'][0].toUpperCase() : 'M',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kNavyDark),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(s['name'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                          ],
                        ),
                      ),
                    ];

                    for (final a in assessments) {
                      final aId = a['id']?.toString() ?? '';
                      final g = studentGrades[aId];
                      final score = g?['score'];
                      final note = g?['notes'];

                      if (score != null) {
                        sum += (score as num).toDouble();
                        count++;
                      }
                      if (note != null && note.toString().isNotEmpty) {
                        studentNotes.add(note.toString());
                      }

                      cells.add(
                        DataCell(
                          InkWell(
                            onTap: () => _showEditGradeDialog(
                              student: s,
                              assessment: a,
                              currentScore: score,
                              currentNotes: note,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              child: _buildScoreCell(score, note),
                            ),
                          ),
                        ),
                      );
                    }

                    // Rata-rata
                    final avgText = count > 0 ? (sum / count).toStringAsFixed(1) : '-';
                    cells.add(
                      DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: count > 0 ? _kPastelAccent.withValues(alpha: 0.3) : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            avgText,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                              color: count > 0 ? _kNavyDark : Colors.black38,
                            ),
                          ),
                        ),
                      ),
                    );

                    // Catatan
                    cells.add(
                      DataCell(
                        Text(
                          studentNotes.isNotEmpty ? studentNotes.join(', ') : '-',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: studentNotes.isNotEmpty ? Colors.orange.shade900 : Colors.black38,
                          ),
                        ),
                      ),
                    );

                    return DataRow(cells: cells);
                  }).toList(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _kCreamBg.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kNavyDark.withValues(alpha: 0.3), width: 1.2),
        ),
        child: Row(
          children: [
            Icon(icon, color: _kNavyDark, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: _kNavyDark)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCell(dynamic score, dynamic note) {
    if (score != null) {
      final numScore = (score is num) ? score.toDouble() : (double.tryParse(score.toString()) ?? 0.0);
      final isPerfect = numScore >= 100;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isPerfect ? const Color(0xFFD1FAE5) : const Color(0xFFE0E7FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isPerfect ? const Color(0xFF059669) : const Color(0xFF4338CA),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              numScore == numScore.roundToDouble() ? numScore.toInt().toString() : numScore.toStringAsFixed(1),
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
                color: isPerfect ? const Color(0xFF065F46) : const Color(0xFF312E81),
              ),
            ),
          ],
        ),
      );
    }

    if (note != null && note.toString().isNotEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFD97706), width: 1),
        ),
        child: Text(
          note.toString(),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
        ),
      );
    }

    return const Text('-', style: TextStyle(color: Colors.black26, fontSize: 16));
  }
}

// ============================================================================
// MAHASISWA: TAB REKAP NILAI SAYA
// ============================================================================
class MahasiswaGradesSubTab extends StatefulWidget {
  final String? classId;
  final String? className;

  const MahasiswaGradesSubTab({
    super.key,
    this.classId,
    this.className,
  });

  @override
  State<MahasiswaGradesSubTab> createState() => _MahasiswaGradesSubTabState();
}

class _MahasiswaGradesSubTabState extends State<MahasiswaGradesSubTab> {
  bool _loading = true;
  Map<String, dynamic>? _gradeData;

  @override
  void initState() {
    super.initState();
    _loadGrades();
  }

  Future<void> _loadGrades() async {
    setState(() => _loading = true);
    final data = await QuizizzService.getMyGrades(widget.classId);
    if (!mounted) return;
    setState(() {
      _gradeData = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    }

    final classInfo = _gradeData?['class'] as Map<String, dynamic>?;
    final stats = _gradeData?['stats'] as Map<String, dynamic>?;
    final items = (_gradeData?['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final avg = stats?['average_score'] ?? 0;
    final totalDone = stats?['completed_assessments'] ?? 0;
    final totalAll = stats?['total_assessments'] ?? items.length;

    return SelectionArea(
      child: RefreshIndicator(
        onRefresh: _loadGrades,
        color: _kNavyDark,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // BANNER STATISTIK NILAI
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _kNavyDark, width: 2),
                  boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _kMustardYellow,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: _kNavyDark, width: 1.5),
                              ),
                              child: const Icon(Icons.analytics_rounded, color: _kNavyDark, size: 26),
                            ),
                            const SizedBox(width: 14),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Rekap Nilai Akademik Saya',
                                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark),
                                ),
                                Text(
                                  'Kelas: ${classInfo?['class_name'] ?? widget.className ?? 'Stegano'} (${classInfo?['subject'] ?? 'Steganografi dan Watermarking'})',
                                  style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded, color: _kNavyDark),
                          tooltip: 'Segarkan Nilai',
                          onPressed: _loadGrades,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Divider(color: _kNavyDark, thickness: 1),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _buildStatCard('Rata-rata Nilai', '$avg', Icons.stars_rounded, const Color(0xFFD1FAE5), const Color(0xFF059669)),
                        const SizedBox(width: 12),
                        _buildStatCard('Kuis / Tugas Selesai', '$totalDone / $totalAll', Icons.task_alt_rounded, const Color(0xFFDBEAFE), const Color(0xFF2563EB)),
                        const SizedBox(width: 12),
                        _buildStatCard('Status Akademik', (avg is num && avg >= 80) ? 'Sangat Baik' : ((avg is num && avg >= 60) ? 'Cukup Baik' : 'Perlu Ditingkatkan'), Icons.school_rounded, const Color(0xFFFEF3C7), const Color(0xFFD97706)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // TABEL RINCIAN NILAI
              const Text(
                '📋 Rincian Nilai Kuis & Tugas',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
              ),
              const SizedBox(height: 12),

              if (items.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kNavyDark, width: 1.5),
                  ),
                  child: const Center(
                    child: Text('Belum ada nilai yang terdata di kelas ini.', style: TextStyle(color: Colors.black54)),
                  ),
                )
              else
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kNavyDark, width: 2),
                    boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowColor: WidgetStateProperty.all(_kNavyDark),
                        headingTextStyle: const TextStyle(fontWeight: FontWeight.w900, color: Colors.white, fontSize: 13),
                        dataRowMinHeight: 52,
                        dataRowMaxHeight: 64,
                        columns: const [
                          DataColumn(label: Text('No')),
                          DataColumn(label: Text('Nama Asesmen')),
                          DataColumn(label: Text('Tipe')),
                          DataColumn(label: Text('Nilai Saya')),
                          DataColumn(label: Text('Status')),
                          DataColumn(label: Text('Catatan / Keterangan')),
                        ],
                        rows: items.map((it) {
                          final sc = it['score'];
                          final maxSc = it['max_score'] ?? 100;
                          final isDone = sc != null;
                          final isPerfect = isDone && (sc as num) >= maxSc;
                          final notes = it['notes']?.toString();

                          return DataRow(
                            cells: [
                              DataCell(Text(it['no'].toString(), style: const TextStyle(fontWeight: FontWeight.bold))),
                              DataCell(
                                Row(
                                  children: [
                                    Icon(
                                      it['type'] == 'homework' ? Icons.assignment_rounded : Icons.quiz_rounded,
                                      size: 18,
                                      color: _kNavyDark,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      it['title'] ?? '-',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
                                    ),
                                  ],
                                ),
                              ),
                              DataCell(
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _kCreamBg.withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    (it['type'] ?? 'quiz').toString().toUpperCase(),
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: _kNavyDark),
                                  ),
                                ),
                              ),
                              DataCell(
                                isDone
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: isPerfect ? const Color(0xFFD1FAE5) : const Color(0xFFE0E7FF),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isPerfect ? const Color(0xFF059669) : const Color(0xFF4338CA),
                                            width: 1.2,
                                          ),
                                        ),
                                        child: Text(
                                          '$sc / $maxSc',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 13,
                                            color: isPerfect ? const Color(0xFF065F46) : const Color(0xFF312E81),
                                          ),
                                        ),
                                      )
                                    : const Text('-', style: TextStyle(color: Colors.black26, fontSize: 16)),
                              ),
                              DataCell(
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isDone ? const Color(0xFFD1FAE5) : const Color(0xFFFEF3C7),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    isDone ? '✅ TUNTAS' : '⏳ BELUM MENGERJAKAN',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11,
                                      color: isDone ? const Color(0xFF065F46) : const Color(0xFF92400E),
                                    ),
                                  ),
                                ),
                              ),
                              DataCell(
                                Text(
                                  (notes != null && notes.isNotEmpty) ? notes : '-',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: (notes != null && notes.isNotEmpty) ? Colors.orange.shade900 : Colors.black38,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color bg, Color iconCol) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kNavyDark, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(icon, color: iconCol, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: _kNavyDark)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
