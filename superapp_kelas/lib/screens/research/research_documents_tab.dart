import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui' as ui;
// ignore: avoid_web_libraries_in_flutter
import 'dart:ui_web' as ui_web;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/quizizz_service.dart';
import '../../services/socket_service.dart';
import '../../utils/qr_scanner_helper.dart';
import 'signature_upload_dialog.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

class ResearchDocumentsTab extends StatefulWidget {
  final String classId;
  final String className;
  final String? subject;

  const ResearchDocumentsTab({
    super.key,
    required this.classId,
    required this.className,
    this.subject,
  });

  @override
  State<ResearchDocumentsTab> createState() => _ResearchDocumentsTabState();
}

class _ResearchDocumentsTabState extends State<ResearchDocumentsTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _documents = [];
  List<Map<String, dynamic>> _groups = [];
  String? _selectedGroupId;
  bool _dosenSignatureReady = false;
  Map<String, dynamic>? _dosenInfo;
  Timer? _refreshTimer;
  final Map<String, String> _docDraftNotes = {};

  String _activeSubTab = 'lks';

  static const List<Map<String, String>> _subTabs = [
    {
      'key': 'lks',
      'label': 'LKS',
      'title': 'Persetujuan & Tanda Tangan Dokumen LKS',
      'subtitle': 'Sistem pengesahan digital Lembar Kemajuan Studi (LKS)',
      'defaultName': 'Lembar Kemajuan Studi (LKS)',
    },
    {
      'key': 'cd',
      'label': 'CD',
      'title': 'Persetujuan & Tanda Tangan Dokumen CD',
      'subtitle': 'Sistem pengesahan digital kelengkapan berkas CD Tugas Akhir',
      'defaultName': 'Kelengkapan Berkas CD TA',
    },
    {
      'key': 'notes',
      'label': 'Notes',
      'title': 'Persetujuan Dokumen Notes',
      'subtitle': 'Sistem persetujuan dokumen catatan bimbingan & revisi',
      'defaultName': 'Catatan / Notes Bimbingan',
    },
    {
      'key': 'proposal',
      'label': 'Proposal',
      'title': 'Persetujuan & Tanda Tangan Dokumen Proposal',
      'subtitle': 'Sistem pengesahan digital proposal riset & tugas akhir',
      'defaultName': 'Proposal Tugas Akhir',
    },
    {
      'key': 'laporan_ta',
      'label': 'Laporan TA',
      'title': 'Persetujuan & Tanda Tangan Dokumen Laporan TA',
      'subtitle': 'Sistem pengesahan digital laporan tugas akhir',
      'defaultName': 'Laporan Tugas Akhir',
    },
    {
      'key': 'paper',
      'label': 'Paper',
      'title': 'Persetujuan Dokumen',
      'subtitle': 'Sistem persetujuan dokumen draft paper & publikasi ilmiah',
      'defaultName': 'Draft Paper Publikasi',
    },
  ];

  String _getDocType(Map<String, dynamic> doc) {
    final raw = (doc['doc_type']?.toString().toLowerCase().trim() ?? '');
    final name = (doc['document_name']?.toString().toLowerCase() ?? '');

    if (raw == 'cd' || raw == 'notes' || raw == 'proposal' || raw == 'laporan_ta' || raw == 'paper') {
      return raw;
    }
    if (raw == 'lks') {
      if (name.contains('cd')) return 'cd';
      if (name.contains('note') || name.contains('catatan')) return 'notes';
      if (name.contains('proposal')) return 'proposal';
      if (name.contains('laporan') || name.contains('ta') || name.contains('tugas akhir')) return 'laporan_ta';
      if (name.contains('paper') || name.contains('jurnal') || name.contains('publikasi') || name.contains('manuskrip') || name.contains('artikel')) return 'paper';
      return 'lks';
    }
    if (raw.isNotEmpty) {
      if (raw.contains('cd')) return 'cd';
      if (raw.contains('note') || raw.contains('catatan')) return 'notes';
      if (raw.contains('proposal')) return 'proposal';
      if (raw.contains('laporan') || raw.contains('ta')) return 'laporan_ta';
      if (raw.contains('paper') || raw.contains('jurnal') || raw.contains('publikasi')) return 'paper';
      return raw;
    }
    if (name.contains('cd')) return 'cd';
    if (name.contains('note') || name.contains('catatan')) return 'notes';
    if (name.contains('proposal')) return 'proposal';
    if (name.contains('laporan') || name.contains('ta') || name.contains('tugas akhir')) return 'laporan_ta';
    if (name.contains('paper') || name.contains('jurnal') || name.contains('publikasi') || name.contains('manuskrip') || name.contains('artikel')) return 'paper';
    return 'lks';
  }

  Map<String, String> get _currentSubTabConfig {
    return _subTabs.firstWhere(
      (t) => t['key'] == _activeSubTab,
      orElse: () => _subTabs.first,
    );
  }

  String _formatGroupName(dynamic groupOrDoc, [int? fallbackIndex]) {
    if (groupOrDoc == null) return fallbackIndex != null ? 'Grup-$fallbackIndex' : 'Grup';
    
    // 1. If group_number is present
    final numVal = groupOrDoc['group_number'];
    if (numVal != null && numVal.toString().trim().isNotEmpty) {
      return 'Grup-${numVal.toString().trim()}';
    }
    
    // 2. Extract digits from group_name or name
    final rawName = (groupOrDoc['group_name'] ?? groupOrDoc['name'] ?? '').toString().trim();
    final match = RegExp(r'(\d+)').firstMatch(rawName);
    if (match != null) {
      return 'Grup-${match.group(1)}';
    }
    
    if (rawName.isNotEmpty && rawName != 'Grup' && rawName != '-') {
      return rawName;
    }
    
    return fallbackIndex != null ? 'Grup-$fallbackIndex' : 'Grup';
  }

  int _getGroupNumber(Map<String, dynamic> g) {
    final numVal = g['group_number'];
    if (numVal != null) {
      final parsed = int.tryParse(numVal.toString());
      if (parsed != null) return parsed;
    }
    final rawName = (g['group_name'] ?? g['name'] ?? '').toString();
    final match = RegExp(r'(\d+)').firstMatch(rawName);
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 999;
    }
    return 999;
  }

  List<Map<String, dynamic>> get _availableGroups {
    final Map<String, Map<String, dynamic>> groupMap = {};
    for (int i = 0; i < _groups.length; i++) {
      final g = _groups[i];
      final id = g['id']?.toString();
      if (id != null && id.isNotEmpty) {
        final formattedName = _formatGroupName(g, i + 1);
        groupMap[id] = {
          ...g,
          'id': id,
          'name': formattedName,
          'group_name': formattedName,
          'title': g['title'] ?? '',
        };
      }
    }
    for (final d in _documents) {
      final id = d['group_id']?.toString();
      if (id != null && id.isNotEmpty && !groupMap.containsKey(id)) {
        final formattedName = _formatGroupName(d, groupMap.length + 1);
        groupMap[id] = {
          'id': id,
          'name': formattedName,
          'group_name': formattedName,
          'title': '',
        };
      }
    }
    final list = groupMap.values.toList();
    list.sort((a, b) => _getGroupNumber(a).compareTo(_getGroupNumber(b)));
    return list;
  }

  String get _selectedGroupName {
    if (_selectedGroupId == null) return 'Semua Grup';
    final found = _availableGroups.firstWhere(
      (g) => g['id']?.toString() == _selectedGroupId,
      orElse: () => {'name': 'Grup'},
    );
    return found['name']?.toString() ?? 'Grup';
  }

  List<Map<String, dynamic>> get _currentSubTabDocs {
    return _documents.where((d) {
      if (_getDocType(d) != _activeSubTab) return false;
      if (_selectedGroupId == null) return true;
      return d['group_id']?.toString() == _selectedGroupId;
    }).toList();
  }

  int _countPendingInSubTab(String key) {
    return _documents.where((d) {
      if (_getDocType(d) != key) return false;
      if (d['status'] == 'pending') return true;
      if (!_isDosen && d['status'] == 'rejected') return true;
      return false;
    }).length;
  }

  int _countTotalInSubTab(String key) {
    return _documents.where((d) => _getDocType(d) == key).length;
  }

  int _countTotalInGroup(String groupId) {
    return _documents.where((d) => _getDocType(d) == _activeSubTab && d['group_id']?.toString() == groupId).length;
  }

  int _countPendingInGroup(String groupId) {
    return _documents.where((d) => d['group_id']?.toString() == groupId && d['status'] == 'pending').length;
  }

  String _formatDateTimeWithTime(DateTime? dt) {
    if (dt == null) return '-';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year.toString();
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$d/$m/$y $h:$min:$s';
  }

  String _getStudentDisplayName(Map<String, dynamic> doc) {
    final rawName = (doc['student_name'] ?? doc['student_full_name'] ?? doc['user_full_name'] ?? doc['full_name'] ?? '').toString().trim();
    final nim = (doc['student_nim'] ?? doc['user_nim'] ?? doc['nim'] ?? '').toString().trim();

    String name = rawName;
    if (name.isEmpty || name.toLowerCase() == 'mahasiswa') {
      if (doc['student_full_name'] != null && doc['student_full_name'].toString().trim().isNotEmpty) {
        name = doc['student_full_name'].toString().trim();
      } else if (doc['user_full_name'] != null && doc['user_full_name'].toString().trim().isNotEmpty) {
        name = doc['user_full_name'].toString().trim();
      }
    }

    if (name.isNotEmpty && name.toLowerCase() != 'mahasiswa') {
      if (nim.isNotEmpty && nim != '-' && !name.contains(nim)) {
        return '$name ($nim)';
      }
      return name;
    }
    if (nim.isNotEmpty && nim != '-') {
      return nim;
    }
    return 'Mahasiswa';
  }

  @override
  void initState() {
    super.initState();
    _loadDocuments();
    _setupSocketListeners();
    // Auto-refresh berkala setiap 4 detik agar status dokumen selalu terupdate otomatis
    _refreshTimer = Timer.periodic(const Duration(seconds: 4), (_) => _loadDocuments(silent: true));
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
        socket.on('research_document_reviewed', (data) {
          if (!mounted) return;
          _loadDocuments(silent: true);
          if (data != null && data is Map) {
            final status = data['status']?.toString();
            final docName = data['document_name']?.toString() ?? 'Dokumen';
            final notes = data['notes']?.toString() ?? '';
            final isDosen = _isDosen;

            if (!isDosen) {
              if (status == 'rejected') {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('⚠️ Dokumen "$docName" PERLU REVISI dari Dosen.\nCatatan: $notes'),
                    backgroundColor: Colors.red.shade700,
                    duration: const Duration(seconds: 5),
                  ),
                );
              } else if (status == 'approved') {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('🎉 Dokumen "$docName" telah DISETUJUI & DITANDATANGANI oleh Dosen!'),
                    backgroundColor: const Color(0xFF059669),
                    duration: const Duration(seconds: 5),
                  ),
                );
              }
            }
          }
        });

        socket.on('research_document_submitted', (data) {
          if (!mounted) return;
          _loadDocuments(silent: true);
          if (_isDosen && data != null && data is Map) {
            final docMap = Map<String, dynamic>.from(data);
            final docName = docMap['document_name']?.toString() ?? 'Dokumen';
            final studentName = _getStudentDisplayName(docMap);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('📄 Dokumen baru diajukan oleh $studentName: "$docName"'),
                backgroundColor: _kNavyDark,
                duration: const Duration(seconds: 4),
              ),
            );
          }
        });

        socket.on('research_document_updated', (data) {
          if (!mounted) return;
          _loadDocuments(silent: true);
        });

        socket.on('research_document_deleted', (data) {
          if (!mounted) return;
          _loadDocuments(silent: true);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadDocuments({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final results = await Future.wait([
        QuizizzService.getResearchDocuments(widget.classId),
        QuizizzService.getResearchGroups(widget.classId),
      ]);
      if (!mounted) return;
      final docData = results[0] as Map<String, dynamic>;
      final groupsData = results[1] as List<Map<String, dynamic>>;

      setState(() {
        _documents = (docData['documents'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _groups = groupsData;
        _dosenSignatureReady = docData['dosen_signature_ready'] == true;
        _dosenInfo = docData['dosen_info'] as Map<String, dynamic>?;

        final available = _availableGroups;
        if (available.isNotEmpty) {
          final exists = available.any((g) => g['id']?.toString() == _selectedGroupId);
          if (!exists) {
            final groupWithPending = available.firstWhere(
              (g) => _documents.any((d) => d['group_id']?.toString() == g['id']?.toString() && d['status'] == 'pending'),
              orElse: () => available.first,
            );
            _selectedGroupId = groupWithPending['id']?.toString();
          }
        } else {
          _selectedGroupId = null;
        }

        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isDosen {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    return auth.role == 'dosen';
  }

  void _downloadFile(String fileUrl, String filename) {
    try {
      final downloadApiUrl = '${ApiService.baseUrl}/quizizz/download-file?url=${Uri.encodeComponent(fileUrl)}&name=${Uri.encodeComponent(filename)}';
      if (kIsWeb) {
        final anchor = html.AnchorElement(href: downloadApiUrl)
          ..target = '_blank'
          ..download = filename;
        html.document.body?.append(anchor);
        anchor.click();
        anchor.remove();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal mengunduh file: $e')),
      );
    }
  }

  // MAHASISWA: Dialog Unggah Dokumen Baru
  Future<void> _showUploadDocumentDialog({String? prefillName, String? existingGroupId, String? initialDocType}) async {
    String selectedDocType = initialDocType ?? _activeSubTab;
    String? selectedGroupId = existingGroupId;
    if (selectedGroupId == null || selectedGroupId.isEmpty) {
      if (_groups.isNotEmpty) {
        selectedGroupId = _groups.first['id']?.toString();
      }
    }
    final initialName = prefillName ?? _subTabs.firstWhere((t) => t['key'] == selectedDocType, orElse: () => _subTabs.first)['defaultName'] ?? '';
    final nameCtrl = TextEditingController(text: initialName);
    DateTime selectedDate = DateTime.now().add(const Duration(days: 7));
    Uint8List? fileBytes;
    String? fileName;
    bool isSubmitting = false;

    final uploaded = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
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
                  color: _kMustardYellow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kNavyDark, width: 1.5),
                ),
                child: const Icon(Icons.upload_file_rounded, color: _kNavyDark, size: 22),
              ),
              const SizedBox(width: 12),
              const Text(
                '📄 Unggah Dokumen Approval',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_groups.length > 1) ...[
                    const Text('Pilih Grup Riset', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _kNavyDark, width: 1),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedGroupId ?? _groups.first['id']?.toString(),
                          isExpanded: true,
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: _kNavyDark),
                          items: _groups.map((g) {
                            final gId = g['id']?.toString() ?? '';
                            final gName = _formatGroupName(g);
                            final title = (g['title'] ?? '').toString();
                            return DropdownMenuItem(
                              value: gId,
                              child: Text(
                                title.isNotEmpty ? '$gName - $title' : gName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (v) {
                            if (v != null) {
                              setDialogState(() {
                                selectedGroupId = v;
                              });
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text('Kategori / Jenis Dokumen', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _kNavyDark, width: 1),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedDocType,
                        isExpanded: true,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, color: _kNavyDark),
                        items: _subTabs.map((t) => DropdownMenuItem(
                          value: t['key'],
                          child: Row(
                            children: [
                              Icon(
                                t['key'] == 'paper'
                                    ? Icons.menu_book_rounded
                                    : (t['key'] == 'notes'
                                        ? Icons.sticky_note_2_rounded
                                        : (t['key'] == 'cd'
                                            ? Icons.album_rounded
                                            : (t['key'] == 'proposal'
                                                ? Icons.description_rounded
                                                : (t['key'] == 'laporan_ta'
                                                    ? Icons.folder_special_rounded
                                                    : Icons.assignment_rounded)))),
                                size: 16,
                                color: _kNavyDark,
                              ),
                              const SizedBox(width: 8),
                              Text(t['label']!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                            ],
                          ),
                        )).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() {
                              selectedDocType = v;
                              final defName = _subTabs.firstWhere((t) => t['key'] == v)['defaultName'] ?? '';
                              nameCtrl.text = defName;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Text('Nama Dokumen / Berkas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      hintText: 'Contoh: Lembar Pengesahan Proposal Tugas Akhir',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Text('Deadline Approval Dokumen', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) {
                        setDialogState(() => selectedDate = picked);
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _kNavyDark, width: 1),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.calendar_month_rounded, color: _kNavyDark, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark),
                              ),
                            ],
                          ),
                          const Text('Pilih Tanggal', style: TextStyle(color: Colors.black54, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Text('Pilih File Dokumen (PDF)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final result = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['pdf', 'doc', 'docx'],
                        withData: true,
                      );
                      if (result != null && result.files.isNotEmpty) {
                        final f = result.files.first;
                        if (f.bytes != null) {
                          setDialogState(() {
                            fileBytes = f.bytes;
                            fileName = f.name;
                          });
                        }
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: fileBytes != null ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: fileBytes != null ? const Color(0xFF059669) : _kNavyDark,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            fileBytes != null ? Icons.check_circle_rounded : Icons.cloud_upload_rounded,
                            color: fileBytes != null ? const Color(0xFF059669) : _kNavyDark,
                            size: 28,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            fileName ?? 'Klik untuk memilih file PDF',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: fileBytes != null ? const Color(0xFF059669) : _kNavyDark,
                            ),
                          ),
                          if (fileBytes == null)
                            const Text('Format yang didukung: PDF, DOC, DOCX (Maks 25MB)', style: TextStyle(fontSize: 10, color: Colors.black45)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Batal', style: TextStyle(color: _kNavyDark)),
            ),
            ElevatedButton(
              onPressed: () {
                if (isSubmitting) return;
                final docName = nameCtrl.text.trim();
                if (docName.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Nama dokumen wajib diisi')));
                  return;
                }
                if (fileBytes == null || fileName == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Silakan pilih file dokumen PDF terlebih dahulu')));
                  return;
                }

                isSubmitting = true;
                setDialogState(() {});
                final deadlineStr = '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')} 23:59:59';

                // Langsung tutup jendela formulir agar user tidak klik berkali-kali
                Navigator.pop(ctx, {
                  'groupId': selectedGroupId ?? '',
                  'documentName': docName,
                  'docType': selectedDocType,
                  'deadline': deadlineStr,
                  'fileBytes': fileBytes!,
                  'fileName': fileName!,
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _kNavyDark,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              child: const Text('Unggah Dokumen', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (uploaded != null && mounted) {
      final payload = uploaded;
      // Tampilkan progress bar dialog yang tidak bisa ditutup secara manual
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (pCtx) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: _kNavyDark, width: 1.5),
            ),
            content: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: _kNavyDark),
                      ),
                      const SizedBox(width: 14),
                      const Text(
                        'Sedang Mengunggah Dokumen...',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kNavyDark),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${payload['documentName']} (${payload['fileName']})',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: const LinearProgressIndicator(
                      minHeight: 6,
                      color: _kNavyDark,
                      backgroundColor: Color(0xFFE2E8F0),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      try {
        await QuizizzService.uploadResearchDocument(
          widget.classId,
          groupId: payload['groupId'],
          documentName: payload['documentName'],
          docType: payload['docType'],
          deadline: payload['deadline'],
          fileBytes: payload['fileBytes'],
          fileName: payload['fileName'],
        );

        if (mounted) {
          Navigator.of(context, rootNavigator: true).pop(); // Tutup progress bar dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Dokumen "${payload['documentName']}" berhasil diunggah!'),
              backgroundColor: const Color(0xFF059669),
            ),
          );
          _loadDocuments();
        }
      } catch (e) {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pop(); // Tutup progress bar dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Gagal mengunggah dokumen: $e'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
    }
  }

  // MAHASISWA: Dialog Edit Dokumen Approval
  Future<void> _showEditDocumentDialog(Map<String, dynamic> doc) async {
    String selectedDocType = _getDocType(doc);
    final nameCtrl = TextEditingController(text: doc['document_name'] ?? '');
    DateTime selectedDate = doc['deadline'] != null
        ? (DateTime.tryParse(doc['deadline'])?.toLocal() ?? DateTime.now().add(const Duration(days: 7)))
        : DateTime.now().add(const Duration(days: 7));
    Uint8List? fileBytes;
    String? fileName;

    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
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
                  color: const Color(0xFFDBEAFE),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kNavyDark, width: 1.5),
                ),
                child: const Icon(Icons.edit_document, color: _kNavyDark, size: 22),
              ),
              const SizedBox(width: 12),
              const Text(
                '✏️ Edit Dokumen Approval',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Kategori / Jenis Dokumen', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _kNavyDark, width: 1),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedDocType,
                        isExpanded: true,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, color: _kNavyDark),
                        items: _subTabs.map((t) => DropdownMenuItem(
                          value: t['key'],
                          child: Row(
                            children: [
                              Icon(
                                t['key'] == 'paper'
                                    ? Icons.menu_book_rounded
                                    : (t['key'] == 'notes'
                                        ? Icons.sticky_note_2_rounded
                                        : (t['key'] == 'cd'
                                            ? Icons.album_rounded
                                            : (t['key'] == 'proposal'
                                                ? Icons.description_rounded
                                                : (t['key'] == 'laporan_ta'
                                                    ? Icons.folder_special_rounded
                                                    : Icons.assignment_rounded)))),
                                size: 16,
                                color: _kNavyDark,
                              ),
                              const SizedBox(width: 8),
                              Text(t['label']!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                            ],
                          ),
                        )).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() {
                              selectedDocType = v;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Text('Nama Dokumen / Berkas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      hintText: 'Contoh: Lembar Pengesahan Proposal Tugas Akhir',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Text('Deadline Approval Dokumen', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime.now().subtract(const Duration(days: 30)),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) {
                        setDialogState(() => selectedDate = picked);
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _kNavyDark, width: 1),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.calendar_month_rounded, color: _kNavyDark, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark),
                              ),
                            ],
                          ),
                          const Text('Pilih Tanggal', style: TextStyle(color: Colors.black54, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const Text('Ganti File Dokumen (Opsional - PDF/DOC)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final result = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['pdf', 'doc', 'docx'],
                        withData: true,
                      );
                      if (result != null && result.files.isNotEmpty) {
                        final f = result.files.first;
                        if (f.bytes != null) {
                          setDialogState(() {
                            fileBytes = f.bytes;
                            fileName = f.name;
                          });
                        }
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: fileBytes != null ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: fileBytes != null ? const Color(0xFF059669) : _kNavyDark,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            fileBytes != null ? Icons.check_circle_rounded : Icons.cloud_upload_rounded,
                            color: fileBytes != null ? const Color(0xFF059669) : _kNavyDark,
                            size: 28,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            fileName ?? 'Klik jika ingin mengganti file PDF/DOC',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: fileBytes != null ? const Color(0xFF059669) : _kNavyDark,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            fileBytes != null ? 'File baru siap diunggah' : 'Biarkan kosong jika tidak ingin mengubah file',
                            style: const TextStyle(fontSize: 10, color: Colors.black45),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: _kNavyDark))),
            ElevatedButton(
              onPressed: () async {
                final docName = nameCtrl.text.trim();
                if (docName.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Nama dokumen wajib diisi')));
                  return;
                }

                try {
                  final deadlineStr = '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')} 23:59:59';
                  await QuizizzService.updateResearchDocument(
                    doc['id'],
                    documentName: docName,
                    docType: selectedDocType,
                    deadline: deadlineStr,
                    fileBytes: fileBytes,
                    fileName: fileName,
                  );
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Gagal memperbarui dokumen: $e')));
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _kNavyDark,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              child: const Text('Simpan Perubahan', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (updated == true) {
      _loadDocuments();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Dokumen berhasil diperbarui!'),
            backgroundColor: Color(0xFF059669),
          ),
        );
      }
    }
  }

  // DOSEN: Hapus Dokumen Approval (Permanen)
  Future<void> _deleteDocument(Map<String, dynamic> doc) async {
    final confirmed = await showDialog<bool>(
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
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade400),
              ),
              child: const Icon(Icons.delete_forever_rounded, color: Color(0xFFDC2626), size: 22),
            ),
            const SizedBox(width: 12),
            const Text(
              'Hapus Dokumen?',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isDosen
                  ? 'Apakah Anda yakin ingin menghapus dokumen "${doc['document_name']}" dari ${_getStudentDisplayName(doc)}?'
                  : 'Apakah Anda yakin ingin menghapus dokumen "${doc['document_name']}"?',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tindakan ini permanen dan file dokumen terkait akan dihapus dari sistem.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: _kNavyDark)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Hapus Dokumen', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await QuizizzService.deleteResearchDocument(doc['id']);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Dokumen berhasil dihapus.'),
              backgroundColor: Color(0xFF059669),
            ),
          );
        }
        _loadDocuments();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Gagal menghapus dokumen: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  // DOSEN & MAHASISWA: Dialog View Dokumen + Kotak Komentar Dosen dengan Speech to Text
  Future<void> _showViewDocumentDialog(Map<String, dynamic> doc) async {
    final docId = doc['id']?.toString() ?? '';
    final rawUrl = doc['file_url']?.toString() ?? '';
    final docName = doc['document_name'] ?? 'Dokumen';
    final studentDisplay = _getStudentDisplayName(doc);
    final submittedDate = doc['created_at'] != null ? DateTime.tryParse(doc['created_at'].toString())?.toLocal() : null;
    final groupName = _formatGroupName(doc);
    final isDosen = _isDosen;

    String fullUrl = rawUrl;
    if (!fullUrl.startsWith('http://') && !fullUrl.startsWith('https://')) {
      final base = ApiService.serverBaseUrl;
      final cleanPath = fullUrl.startsWith('/') ? fullUrl : '/$fullUrl';
      fullUrl = '$base$cleanPath';
    }

    final viewTypeKey = 'doc-preview-$docId-${DateTime.now().millisecondsSinceEpoch}';
    if (kIsWeb) {
      try {
        ui_web.platformViewRegistry.registerViewFactory(
          viewTypeKey,
          (int viewId) {
            final iframe = html.IFrameElement()
              ..src = fullUrl
              ..style.border = 'none'
              ..style.width = '100%'
              ..style.height = '100%';
            return iframe;
          },
        );
      } catch (e) {
        debugPrint('registerViewFactory error: $e');
      }
    }

    final initialNote = _docDraftNotes[docId] ?? (doc['notes']?.toString() ?? '');
    final notesCtrl = TextEditingController(text: initialNote);
    bool isRecording = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final screenWidth = MediaQuery.of(ctx).size.width;
          final screenHeight = MediaQuery.of(ctx).size.height;
          final isMobile = screenWidth < 850;

          String baseTextBeforeRecording = '';

          void toggleSpeech() {
            if (isRecording) {
              QrScannerHelper.stopSpeechToText();
              setDialogState(() => isRecording = false);
            } else {
              baseTextBeforeRecording = notesCtrl.text.trim();
              final ok = QrScannerHelper.startSpeechToText(
                onResult: (transcription) {
                  setDialogState(() {
                    if (baseTextBeforeRecording.isEmpty) {
                      notesCtrl.text = transcription;
                    } else {
                      notesCtrl.text = '$baseTextBeforeRecording $transcription';
                    }
                    notesCtrl.selection = TextSelection.fromPosition(TextPosition(offset: notesCtrl.text.length));
                  });
                },
                onEnd: () {
                  if (ctx.mounted) {
                    setDialogState(() => isRecording = false);
                  }
                },
              );
              if (ok) {
                setDialogState(() => isRecording = true);
              }
            }
          }

          final viewerWidget = Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kNavyDark, width: 1.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                if (kIsWeb)
                  HtmlElementView(viewType: viewTypeKey)
                else
                  const Center(child: Text('Pratinjau hanya tersedia di browser Web')),
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.open_in_new_rounded, size: 18, color: _kNavyDark),
                      tooltip: 'Buka di tab baru',
                      onPressed: () {
                        if (kIsWeb) {
                          html.window.open(fullUrl, '_blank');
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          );

          final commentPanel = Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kNavyDark, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _kMustardYellow,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _kNavyDark, width: 1.2),
                      ),
                      child: const Icon(Icons.edit_note_rounded, color: _kNavyDark, size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Catatan Review Dosen', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: _kNavyDark)),
                          Text('Komentar otomatis diteruskan saat Approve maupun Minta Revisi', style: TextStyle(fontSize: 10, color: Colors.black54)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // SPEECH TO TEXT BUTTON & STATUS
                if (isDosen) ...[
                  InkWell(
                    onTap: toggleSpeech,
                    borderRadius: BorderRadius.circular(12),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isRecording ? const Color(0xFFFEE2E2) : const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isRecording ? Colors.redAccent : const Color(0xFF93C5FD),
                          width: isRecording ? 2 : 1.2,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded,
                            color: isRecording ? Colors.red.shade700 : const Color(0xFF1D4ED8),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              isRecording
                                  ? '⏹️ Stop Rekam (Sedang Mendengarkan...)'
                                  : '🎙️ Rekam Suara (Speech to Text)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: isRecording ? Colors.red.shade800 : const Color(0xFF1D4ED8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (isRecording) ...[
                    const SizedBox(height: 6),
                    const Text(
                      '💡 Anda dapat terus berbicara sambil membaca & scroll dokumen di sebelah kiri.',
                      style: TextStyle(fontSize: 10, color: Color(0xFFB45309), fontStyle: FontStyle.italic),
                    ),
                  ],
                  const SizedBox(height: 12),
                ],

                // TEXT FIELD KOMENTAR
                Expanded(
                  child: TextField(
                    controller: notesCtrl,
                    maxLines: null,
                    expands: true,
                    readOnly: !isDosen,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 13, color: _kNavyDark),
                    decoration: InputDecoration(
                      hintText: isDosen
                          ? 'Ketik catatan review untuk mahasiswa di sini (atau gunakan tombol rekam suara di atas)...'
                          : 'Catatan dari dosen akan tampil di sini...',
                      hintStyle: const TextStyle(fontSize: 12, color: Colors.black38),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _kNavyDark, width: 1.2),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.black26),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _kNavyDark, width: 2),
                      ),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // ACTION BUTTONS
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          if (isRecording) QrScannerHelper.stopSpeechToText();
                          if (isDosen) {
                            final text = notesCtrl.text.trim();
                            _docDraftNotes[docId] = text;
                          }
                          Navigator.pop(ctx);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _kNavyDark,
                          side: const BorderSide(color: _kNavyDark, width: 1.2),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Tutup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ),
                    if (isDosen) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (isRecording) QrScannerHelper.stopSpeechToText();
                            final text = notesCtrl.text.trim();
                            _docDraftNotes[docId] = text;
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('✅ Catatan review dokumen tersimpan. Akan otomatis muncul saat Anda klik "Approve dan Sign", "Approve", atau "Minta Revisi".'),
                                backgroundColor: Color(0xFF059669),
                                duration: Duration(seconds: 4),
                              ),
                            );
                          },
                          icon: const Icon(Icons.save_rounded, size: 16),
                          label: const Text('Simpan Catatan', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _kNavyDark,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          );

          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: const BorderSide(color: _kNavyDark, width: 2),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: SizedBox(
              width: screenWidth > 1200 ? 1150 : screenWidth * 0.94,
              height: screenHeight > 850 ? 780 : screenHeight * 0.92,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // TOP BAR
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: _kMustardYellow,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: _kNavyDark, width: 1.5),
                                ),
                                child: const Icon(Icons.menu_book_rounded, color: _kNavyDark, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      docName,
                                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      'Pengunggah: $studentDisplay • $groupName${submittedDate != null ? ' • ${_formatDateTimeWithTime(submittedDate)}' : ''}',
                                      style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _downloadFile(rawUrl, '$docName.pdf'),
                              icon: const Icon(Icons.download_rounded, size: 16),
                              label: const Text('Unduh Dokumen Asli', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _kNavyDark,
                                side: const BorderSide(color: _kNavyDark, width: 1.2),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, color: _kNavyDark),
                              onPressed: () {
                                if (isRecording) QrScannerHelper.stopSpeechToText();
                                final text = notesCtrl.text.trim();
                                if (text.isNotEmpty) {
                                  _docDraftNotes[docId] = text;
                                }
                                Navigator.pop(ctx);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // BODY CONTENT: SPLIT VIEW
                    Expanded(
                      child: isMobile
                          ? Column(
                              children: [
                                Expanded(flex: 5, child: viewerWidget),
                                const SizedBox(height: 12),
                                Expanded(flex: 5, child: commentPanel),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(flex: 6, child: viewerWidget),
                                const SizedBox(width: 16),
                                SizedBox(width: 380, child: commentPanel),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // DOSEN: Review Approval (Approve & Sign / Approve biasa / Reject)
  Future<void> _reviewDocument(Map<String, dynamic> doc, String action, {bool sign = true}) async {
    final docId = doc['id']?.toString() ?? '';
    final draftNote = _docDraftNotes[docId] ?? (doc['notes']?.toString() ?? '');
    final notesCtrl = TextEditingController(text: draftNote);

    if (action == 'approve') {
      if (sign && !_dosenSignatureReady) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
            title: const Text('⚠️ Tanda Tangan Belum Diunggah', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
            content: const Text(
              'Fitur "Approve dan Sign" membutuhkan tanda tangan digital (PNG) di profil.\n\nSilakan unggah tanda tangan PNG terlebih dahulu, atau gunakan tombol "Approve" (tanpa tanda tangan).',
              style: TextStyle(fontSize: 13),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Nanti', style: TextStyle(color: _kNavyDark))),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  SignatureUploadDialog.show(context).then((_) => _loadDocuments());
                },
                style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('Unggah TTD Sekarang', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
        return;
      }

      bool isRecording = false;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            String baseTextBeforeRecording = '';

            void toggleSpeech() {
              if (isRecording) {
                QrScannerHelper.stopSpeechToText();
                setDialogState(() => isRecording = false);
              } else {
                baseTextBeforeRecording = notesCtrl.text.trim();
                final ok = QrScannerHelper.startSpeechToText(
                  onResult: (transcription) {
                    setDialogState(() {
                      if (baseTextBeforeRecording.isEmpty) {
                        notesCtrl.text = transcription;
                      } else {
                        notesCtrl.text = '$baseTextBeforeRecording $transcription';
                      }
                      notesCtrl.selection = TextSelection.fromPosition(TextPosition(offset: notesCtrl.text.length));
                    });
                  },
                  onEnd: () {
                    if (ctx.mounted) {
                      setDialogState(() => isRecording = false);
                    }
                  },
                );
                if (ok) {
                  setDialogState(() => isRecording = true);
                }
              }
            }

            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
              title: Text(
                sign ? '✍️ Konfirmasi Approve dan Sign' : '✅ Konfirmasi Approve Dokumen',
                style: TextStyle(fontWeight: FontWeight.bold, color: sign ? const Color(0xFF0D9488) : const Color(0xFF059669)),
              ),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sign
                          ? 'Apakah Anda ingin menyetujui dan menandatangani dokumen "${doc['document_name']}"?'
                          : 'Apakah Anda ingin menyetujui dokumen "${doc['document_name']}" tanpa tanda tangan digital?',
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: sign ? const Color(0xFFF0FDFA) : const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: sign ? const Color(0xFF0D9488) : const Color(0xFF059669)),
                      ),
                      child: Text(
                        sign
                            ? 'Dokumen PDF akan otomatis dibubuhi tanda tangan digital Anda dan lembar pengesahan resmi.'
                            : 'Dokumen disetujui langsung tanpa tanda tangan (cocok untuk draft paper, materi pptx presentasi, outline, dll).',
                        style: TextStyle(fontSize: 11, color: sign ? const Color(0xFF115E59) : const Color(0xFF065F46)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Catatan / Komentar Dosen (Opsional):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                        InkWell(
                          onTap: toggleSpeech,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isRecording ? const Color(0xFFFEE2E2) : const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isRecording ? Colors.redAccent : const Color(0xFF93C5FD)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded, size: 14, color: isRecording ? Colors.red : const Color(0xFF1D4ED8)),
                                const SizedBox(width: 4),
                                Text(isRecording ? 'Stop' : 'Voice/Mic', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isRecording ? Colors.red : const Color(0xFF1D4ED8))),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: notesCtrl,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: sign
                            ? 'Ketik catatan/komentar untuk mahasiswa (opsional, atau gunakan tombol Voice/Mic)...'
                            : 'Ketik catatan/komentar untuk mahasiswa (opsional, atau gunakan tombol Voice/Mic)...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (isRecording) QrScannerHelper.stopSpeechToText();
                    Navigator.pop(ctx, false);
                  },
                  child: const Text('Batal', style: TextStyle(color: _kNavyDark)),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (isRecording) QrScannerHelper.stopSpeechToText();
                    Navigator.pop(ctx, true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: sign ? const Color(0xFF0D9488) : const Color(0xFF059669),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(sign ? 'Approve & Sign' : 'Approve', style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        ),
      );

      if (confirmed == true) {
        try {
          final noteText = notesCtrl.text.trim();
          _docDraftNotes[docId] = noteText;
          final defaultNote = sign ? 'Disetujui dan ditandatangani Dosen' : 'Disetujui oleh Dosen';
          final finalNote = noteText.isEmpty ? defaultNote : noteText;

          await QuizizzService.reviewResearchDocument(
            doc['id'],
            action: 'approve',
            sign: sign,
            notes: finalNote,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(sign ? '✅ Dokumen berhasil disetujui & ditandatangani!' : '✅ Dokumen berhasil disetujui!'),
                backgroundColor: sign ? const Color(0xFF0D9488) : const Color(0xFF059669),
              ),
            );
          }
          _loadDocuments();
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal menyetujui: $e')));
          }
        }
      }
    } else {
      // REJECT / MINTA REVISI DENGAN CATATAN DRAFT + VOICE INPUT
      bool isRecording = false;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            String baseTextBeforeRecording = '';

            void toggleSpeech() {
              if (isRecording) {
                QrScannerHelper.stopSpeechToText();
                setDialogState(() => isRecording = false);
              } else {
                baseTextBeforeRecording = notesCtrl.text.trim();
                final ok = QrScannerHelper.startSpeechToText(
                  onResult: (transcription) {
                    setDialogState(() {
                      if (baseTextBeforeRecording.isEmpty) {
                        notesCtrl.text = transcription;
                      } else {
                        notesCtrl.text = '$baseTextBeforeRecording $transcription';
                      }
                      notesCtrl.selection = TextSelection.fromPosition(TextPosition(offset: notesCtrl.text.length));
                    });
                  },
                  onEnd: () {
                    if (ctx.mounted) {
                      setDialogState(() => isRecording = false);
                    }
                  },
                );
                if (ok) {
                  setDialogState(() => isRecording = true);
                }
              }
            }

            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
              title: const Text('❌ Tolak & Minta Revisi Dokumen', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dokumen "${doc['document_name']}" akan ditolak dan mahasiswa diminta melakukan revisi.'),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Catatan Revisi Dosen (Wajib):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                        InkWell(
                          onTap: toggleSpeech,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isRecording ? const Color(0xFFFEE2E2) : const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isRecording ? Colors.redAccent : const Color(0xFF93C5FD)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded, size: 14, color: isRecording ? Colors.red : const Color(0xFF1D4ED8)),
                                const SizedBox(width: 4),
                                Text(isRecording ? 'Stop' : 'Voice/Mic', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isRecording ? Colors.red : const Color(0xFF1D4ED8))),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: notesCtrl,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'Sebutkan bagian yang perlu diperbaiki mahasiswa (atau gunakan tombol Voice/Mic)...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (isRecording) QrScannerHelper.stopSpeechToText();
                    Navigator.pop(ctx, false);
                  },
                  child: const Text('Batal', style: TextStyle(color: _kNavyDark)),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (isRecording) QrScannerHelper.stopSpeechToText();
                    if (notesCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Catatan revisi wajib diisi')));
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: const Text('Kirim Catatan Revisi', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        ),
      );

      if (confirmed == true) {
        try {
          await QuizizzService.reviewResearchDocument(
            doc['id'],
            action: 'reject',
            notes: notesCtrl.text.trim(),
          );
          _docDraftNotes.remove(docId);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Dokumen ditolak dan catatan revisi telah dikirimkan ke mahasiswa.')),
          );
          _loadDocuments();
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mereview: $e')));
        }
      }
    }
  }

  Widget _buildSubTabBar() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kNavyDark, width: 1.5),
        boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(2, 2), blurRadius: 0)],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _subTabs.map((tab) {
            final key = tab['key']!;
            final label = tab['label']!;
            final isActive = _activeSubTab == key;
            final totalCount = _countTotalInSubTab(key);
            
            // Hitung dokumen pending/perlu perhatian pada subtab ini
            final int pendingCount = _documents.where((d) {
              if (_getDocType(d) != key) return false;
              if (d['status'] == 'pending') return true;
              // Jika mahasiswa, dokumen rejected (perlu revisi) juga perlu perhatian
              if (!_isDosen && d['status'] == 'rejected') return true;
              return false;
            }).length;

            IconData iconData;
            switch (key) {
              case 'cd':
                iconData = Icons.album_rounded;
                break;
              case 'notes':
                iconData = Icons.sticky_note_2_rounded;
                break;
              case 'proposal':
                iconData = Icons.description_rounded;
                break;
              case 'laporan_ta':
                iconData = Icons.folder_special_rounded;
                break;
              case 'paper':
                iconData = Icons.menu_book_rounded;
                break;
              case 'lks':
              default:
                iconData = Icons.assignment_rounded;
                break;
            }

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _activeSubTab = key;
                    });
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isActive ? _kNavyDark : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          iconData,
                          size: 18,
                          color: isActive ? Colors.white : _kNavyDark,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: isActive ? Colors.white : _kNavyDark,
                          ),
                        ),
                        if (pendingCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDC2626), // Lingkaran merah
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white, width: 1.5),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x66DC2626),
                                  blurRadius: 4,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$pendingCount',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ] else if (totalCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: isActive ? _kMustardYellow : const Color(0xFFE2E8F0),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$totalCount',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: isActive ? _kNavyDark : Colors.black87,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildGroupSidebar({bool isMobile = false}) {
    final groups = _availableGroups;
    final totalAll = _countTotalInSubTab(_activeSubTab);
    final pendingAll = _countPendingInSubTab(_activeSubTab);

    if (isMobile) {
      // Horizontal scrollable chips for mobile view
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kNavyDark, width: 1.5),
          boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(2, 2), blurRadius: 0)],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _buildGroupChip(
                  id: null,
                  name: 'Semua Grup',
                  total: totalAll,
                  pending: pendingAll,
                ),
              ),
              ...groups.map((g) {
                final gId = g['id']?.toString() ?? '';
                final gName = g['name']?.toString() ?? 'Grup';
                final gTotal = _countTotalInGroup(gId);
                final gPending = _countPendingInGroup(gId);
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _buildGroupChip(
                    id: gId,
                    name: gName,
                    total: gTotal,
                    pending: gPending,
                  ),
                );
              }),
            ],
          ),
        ),
      );
    }

    // Vertical Left Sidebar for Desktop / Tablet view
    return Container(
      width: 250,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kNavyDark, width: 2),
        boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _buildGroupSidebarItem(
              id: null,
              name: 'Semua Grup',
              subtitle: 'Tampilkan seluruh dokumen',
              total: totalAll,
              pending: pendingAll,
              icon: Icons.dashboard_customize_rounded,
            ),
          ),
          if (groups.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.black12),
              ),
              child: const Text(
                'Belum ada grup terdaftar di kelas ini.',
                style: TextStyle(fontSize: 11, color: Colors.black54),
                textAlign: TextAlign.center,
              ),
            )
          else
            ...groups.map((g) {
              final gId = g['id']?.toString() ?? '';
              final gName = g['name']?.toString() ?? 'Grup';
              final gTitle = g['title']?.toString() ?? '';
              final gTotal = _countTotalInGroup(gId);
              final gPending = _countPendingInGroup(gId);

              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _buildGroupSidebarItem(
                  id: gId,
                  name: gName,
                  subtitle: gTitle.isNotEmpty ? gTitle : null,
                  total: gTotal,
                  pending: gPending,
                  icon: Icons.folder_shared_rounded,
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildGroupSidebarItem({
    required String? id,
    required String name,
    String? subtitle,
    required int total,
    required int pending,
    required IconData icon,
  }) {
    final isSelected = _selectedGroupId == id;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedGroupId = id;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: isSelected ? _kNavyDark : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? _kNavyDark : Colors.black12,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? Colors.white : _kNavyDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: isSelected ? Colors.white : _kNavyDark,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 10,
                          color: isSelected ? Colors.white70 : Colors.black54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? (pending > 0 ? const Color(0xFFEF4444) : _kMustardYellow)
                      : (pending > 0 ? const Color(0xFFFEE2E2) : const Color(0xFFE2E8F0)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  pending > 0 ? '$pending/$total' : '$total',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: isSelected
                        ? (pending > 0 ? Colors.white : _kNavyDark)
                        : (pending > 0 ? const Color(0xFFDC2626) : Colors.black87),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupChip({
    required String? id,
    required String name,
    required int total,
    required int pending,
  }) {
    final isSelected = _selectedGroupId == id;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedGroupId = id;
          });
        },
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected ? _kNavyDark : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? _kNavyDark : Colors.black12,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  color: isSelected ? Colors.white : _kNavyDark,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected
                      ? (pending > 0 ? const Color(0xFFEF4444) : _kMustardYellow)
                      : (pending > 0 ? const Color(0xFFFEE2E2) : const Color(0xFFE2E8F0)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  pending > 0 ? '$pending/$total' : '$total',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    color: isSelected
                        ? (pending > 0 ? Colors.white : _kNavyDark)
                        : (pending > 0 ? const Color(0xFFDC2626) : Colors.black87),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDosen = _isDosen;

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    }

    final currentDocs = _currentSubTabDocs;
    final config = _currentSubTabConfig;
    final isPaperTab = _activeSubTab == 'paper' || _activeSubTab == 'notes';
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobileLayout = screenWidth < 850;

    Widget buildMainContent() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // BANNER HEADER STATS
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _kNavyDark, width: 2),
              boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
            ),
            child: Wrap(
              spacing: 14,
              runSpacing: 14,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _kMustardYellow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _kNavyDark, width: 1.5),
                      ),
                      child: Icon(
                        _activeSubTab == 'paper'
                            ? Icons.menu_book_rounded
                            : (_activeSubTab == 'notes'
                                ? Icons.sticky_note_2_rounded
                                : (_activeSubTab == 'cd'
                                    ? Icons.album_rounded
                                    : (_activeSubTab == 'proposal'
                                        ? Icons.description_rounded
                                        : (_activeSubTab == 'laporan_ta'
                                            ? Icons.folder_special_rounded
                                            : Icons.assignment_turned_in_rounded)))),
                        color: _kNavyDark,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedGroupId != null
                                ? '${isPaperTab ? 'Persetujuan Dokumen' : config['title']} — $_selectedGroupName (${currentDocs.length})'
                                : '${isPaperTab ? 'Persetujuan Dokumen' : config['title']} (${currentDocs.length})',
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                          ),
                          Text(
                            config['subtitle'] ?? 'Sistem pengesahan digital',
                            style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (!isDosen)
                  ElevatedButton.icon(
                    onPressed: () => _showUploadDocumentDialog(initialDocType: _activeSubTab),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kNavyDark,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text('Unggah ${config['label']} (+)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ALERT BANNER JIKA DOSEN BELUM UNGGAH TTD (Hanya untuk dokumen selain Paper)
          if (isDosen && !_dosenSignatureReady && !isPaperTab) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFD97706), width: 1.5),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFB45309), size: 28),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tanda Tangan Digital Belum Diunggah',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF78350F)),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Fitur "Approve dan Sign" membutuhkan tanda tangan digital berformat PNG di profil Anda.',
                          style: TextStyle(fontSize: 11, color: Color(0xFF92400E)),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => SignatureUploadDialog.show(context).then((_) => _loadDocuments()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB45309),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Unggah Sekarang', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // LIST DOKUMEN SESUAI SUBTAB AKTIF & GRUP TERPILIH
          if (currentDocs.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(36),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _kNavyDark, width: 1.5),
              ),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.folder_open_rounded, size: 48, color: Colors.black26),
                    const SizedBox(height: 12),
                    Text(
                      _selectedGroupId != null
                          ? 'Belum ada dokumen ${config['label']} dari $_selectedGroupName.'
                          : 'Belum ada dokumen ${config['label']} yang diunggah.',
                      style: const TextStyle(fontSize: 13, color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: currentDocs.length,
              separatorBuilder: (ctx, i) => const SizedBox(height: 14),
              itemBuilder: (ctx, idx) {
                final doc = currentDocs[idx];
                return _buildDocumentCard(doc);
              },
            ),
        ],
      );
    }

    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // SUB-TAB NAVIGATION BAR (LKS, CD, Proposal, Laporan TA, Paper)
            _buildSubTabBar(),
            const SizedBox(height: 16),

            // ROW LAYOUT (LEFT SIDEBAR GRUP + MAIN CONTENT) FOR DESKTOP
            if (!isMobileLayout)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildGroupSidebar(isMobile: false),
                  const SizedBox(width: 16),
                  Expanded(child: buildMainContent()),
                ],
              )
            // STACKED LAYOUT (CHIPS GRUP DI ATAS + MAIN CONTENT DI BAWAH) FOR MOBILE
            else ...[
              _buildGroupSidebar(isMobile: true),
              const SizedBox(height: 14),
              buildMainContent(),
            ],
          ],
        ),
      ),
    );
  }

  // Card Dokumen
  Widget _buildDocumentCard(Map<String, dynamic> doc) {
    final isDosen = _isDosen;
    final docType = _getDocType(doc);
    final isPaper = docType == 'paper' || docType == 'notes';
    final status = doc['status']?.toString() ?? 'pending';
    final isApproved = status == 'approved';
    final isRejected = status == 'rejected';
    final isPending = status == 'pending';

    Color statusColor = const Color(0xFFD97706);
    String statusText = '⏳ MENUNGGU APPROVAL DOSEN';
    Color statusBg = const Color(0xFFFEF3C7);

    if (isApproved) {
      statusColor = const Color(0xFF059669);
      statusText = isPaper ? '✅ DISETUJUI RESMI' : '✅ DISETUJUI & TERTANDATANGAN RESMI';
      statusBg = const Color(0xFFECFDF5);
    } else if (isRejected) {
      statusColor = const Color(0xFFDC2626);
      statusText = '❌ PERLU REVISI';
      statusBg = const Color(0xFFFEE2E2);
    }

    final deadlineDate = doc['deadline'] != null ? DateTime.tryParse(doc['deadline'])?.toLocal() : null;
    final submittedDate = doc['created_at'] != null ? DateTime.tryParse(doc['created_at'])?.toLocal() : null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isRejected ? Colors.red.shade400 : _kNavyDark, width: 1.8),
        boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // STATUS CHIP, WAKTU DIAJUKAN & DEADLINE BADGE (RESPONSIF)
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // WAKTU DIAJUKAN (DI SEBELAH KIRI) BESERTA JAM:MENIT:DETIK
              if (submittedDate != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _kNavyDark, width: 1.2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.access_time_filled_rounded, size: 14, color: _kNavyDark),
                      const SizedBox(width: 5),
                      Text(
                        _formatDateTimeWithTime(submittedDate),
                        style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 11),
                      ),
                    ],
                  ),
                ),

              // STATUS CHIP
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColor, width: 1.2),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(fontWeight: FontWeight.w900, color: statusColor, fontSize: 11),
                ),
              ),

              // DEADLINE BADGE
              if (deadlineDate != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.black12, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timer_outlined, size: 14, color: Colors.black54),
                      const SizedBox(width: 4),
                      Text(
                        'Deadline: ${_formatDateTimeWithTime(deadlineDate)}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // NAMA DOKUMEN
          Text(
            doc['document_name'] ?? 'Dokumen Riset',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatGroupName(doc)} — Pengunggah: ${_getStudentDisplayName(doc)}'
            '${submittedDate != null ? ' • Waktu Unggah: ${_formatDateTimeWithTime(submittedDate)}' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),

          // CATATAN REVISI / CATATAN DOSEN JIKA ADA
          if (doc['notes'] != null && doc['notes'].toString().isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isRejected ? const Color(0xFFFFF1F2) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: isRejected ? Colors.red.shade300 : Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isRejected ? '📌 CATATAN REVISI DARI DOSEN:' : '📌 Catatan Dosen:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isRejected ? Colors.red.shade800 : _kNavyDark,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    doc['notes'].toString(),
                    style: TextStyle(fontSize: 12, color: isRejected ? Colors.red.shade900 : Colors.black87),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          const Divider(height: 1, color: Colors.black12),
          const SizedBox(height: 12),

          // TOMBOL AKSI
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // UNDUH FILE ASLI
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _showViewDocumentDialog(doc),
                    icon: const Icon(Icons.visibility_rounded, size: 16),
                    label: const Text('View Dokumen', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kNavyDark,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _downloadFile(doc['file_url'] ?? '', doc['document_name'] ?? 'dokumen.pdf'),
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: const Text('Unduh Dokumen Asli', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kNavyDark,
                      side: const BorderSide(color: _kNavyDark, width: 1.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  if (isApproved && doc['signed_file_url'] != null && !isPaper)
                    ElevatedButton.icon(
                      onPressed: () => _downloadFile(doc['signed_file_url'] ?? '', 'signed-${doc['document_name']}.pdf'),
                      icon: const Icon(Icons.verified_rounded, size: 16),
                      label: const Text('📥 Unduh Hasil Tertandatangan (PDF)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF059669),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                    ),
                ],
              ),

              // AKSI DOSEN / MAHASISWA
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // JIKA DOSEN: BISA REVIEW & HAPUS DOKUMEN (TIDAK BISA EDIT & TAMBAH)
                  if (isDosen) ...[
                    if (isPending) ...[
                      // 1. APPROVE DAN SIGN (Hanya jika BUKAN tab/tipe Paper)
                      if (!isPaper)
                        ElevatedButton.icon(
                          onPressed: () => _reviewDocument(doc, 'approve', sign: true),
                          icon: const Icon(Icons.draw_rounded, size: 16),
                          label: const Text('Approve dan Sign', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0D9488),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          ),
                        ),
                      // 2. APPROVE (TANPA TANDA TANGAN DIGITAL)
                      ElevatedButton.icon(
                        onPressed: () => _reviewDocument(doc, 'approve', sign: false),
                        icon: const Icon(Icons.check_circle_rounded, size: 16),
                        label: const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF059669),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: () => _reviewDocument(doc, 'reject'),
                        icon: const Icon(Icons.cancel_rounded, size: 16),
                        label: const Text('Minta Revisi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                      ),
                    ],
                    OutlinedButton.icon(
                      onPressed: () => _deleteDocument(doc),
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      label: const Text('Hapus', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        side: BorderSide(color: Colors.red.shade300, width: 1.2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ]
                  // JIKA MAHASISWA: BISA EDIT & HAPUS DOKUMEN
                  else ...[
                    OutlinedButton.icon(
                      onPressed: () => _showEditDocumentDialog(doc),
                      icon: const Icon(Icons.edit_note_rounded, size: 16),
                      label: const Text('Edit Dokumen', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1D4ED8),
                        backgroundColor: const Color(0xFFEFF6FF),
                        side: const BorderSide(color: Color(0xFF93C5FD), width: 1.2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _deleteDocument(doc),
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      label: const Text('Hapus', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        backgroundColor: const Color(0xFFFEF2F2),
                        side: BorderSide(color: Colors.red.shade300, width: 1.2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    if (isRejected)
                      ElevatedButton.icon(
                        onPressed: () => _showUploadDocumentDialog(
                          prefillName: 'Revisi - ${doc['document_name']}',
                          existingGroupId: doc['group_id'],
                          initialDocType: docType,
                        ),
                        icon: const Icon(Icons.upload_rounded, size: 16),
                        label: const Text('Unggah Revisi (+)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
