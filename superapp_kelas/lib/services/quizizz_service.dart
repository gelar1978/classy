import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class QuizizzService {
  // ----------------------------------------------------------------------
  // KONTEKS KELAS AKTIF (fitur "Manajemen Kelas")
  // ----------------------------------------------------------------------
  // Di-set SEKALI saat dosen/mahasiswa membuka modul Quizizz dari sebuah
  // kelas (lihat class_screen.dart). Setelah di-set, SEMUA pembuatan &
  // pengambilan kuis/PR/presentasi/flashcard di bawah otomatis
  // menyertakan class_id ini -- jadi kita tidak perlu mengubah ratusan
  // titik pemanggilan di quizizz_screen.dart satu per satu. Kalau null,
  // perilakunya sama seperti sebelum fitur kelas ada (kuis "umum").
  static String? currentClassId;
  static String? currentClassName;

  // ----------------------------------------------------------------------
  // FITUR "MANAJEMEN KELAS" (Class Management)
  // ----------------------------------------------------------------------
  // Dosen: buat kelas baru (nama kelas + mata kuliah wajib diisi).
  // Mendukung jenis kelas: 'mata_kuliah' atau 'riset'.
  static Future<Map<String, dynamic>?> createClass({
    required String className,
    required String subject,
    String classType = 'mata_kuliah',
  }) async {
    try {
      final res = await ApiService.post('/quizizz/classes', {
        'class_name': className,
        'subject': subject,
        'class_type': classType,
      });
      return Map<String, dynamic>.from(res['class'] ?? {});
    } catch (e) {
      return null;
    }
  }

  // Dosen: daftar semua kelas yang telah dibuat.
  static Future<List<Map<String, dynamic>>> getMyClasses() async {
    try {
      final res = await ApiService.get('/quizizz/classes/mine');
      final list = (res['classes'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // Mahasiswa: join kelas memakai token dari dosen ATAU kode/QR grup riset.
  static Future<Map<String, dynamic>?> joinClass(
    String tokenOrCode, {
    String? studentName,
    String? nim,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/classes/join', {
        'token': tokenOrCode,
        if (studentName != null) 'student_name': studentName,
        if (nim != null) 'nim': nim,
      });
      return Map<String, dynamic>.from(res);
    } catch (e) {
      rethrow;
    }
  }

  // ----------------------------------------------------------------------
  // FITUR "KELAS RISET / CAPSTONE"
  // ----------------------------------------------------------------------

  // 1. Ambil daftar semua grup riset dalam kelas beserta ringkasan chat kelas
  static Future<Map<String, dynamic>> getResearchGroupsWithSummary(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId/research-groups');
      final list = (res['groups'] as List?) ?? [];
      final summary = (res['class_chat_summary'] as Map?)?.cast<String, dynamic>() ?? {
        'class_forum_unread': 0,
        'total_pm_unread': 0,
        'total_unread': 0,
      };
      return {
        'groups': list.cast<Map<String, dynamic>>(),
        'class_chat_summary': summary,
      };
    } catch (_) {
      return {'groups': <Map<String, dynamic>>[], 'class_chat_summary': {'total_unread': 0}};
    }
  }

  // Backward-compatible getResearchGroups
  static Future<List<Map<String, dynamic>>> getResearchGroups(String classId) async {
    final data = await getResearchGroupsWithSummary(classId);
    return data['groups'] as List<Map<String, dynamic>>;
  }

  // 1b. Ambil riwayat diskusi seluruh kelas atau PM 1-on-1
  static Future<List<Map<String, dynamic>>> getClassDiscussions(String classId, {String? peerId}) async {
    try {
      final queryParam = (peerId != null && peerId.isNotEmpty && peerId != 'general') ? '?peer_id=$peerId' : '';
      final res = await ApiService.get('/quizizz/classes/$classId/class-discussions$queryParam');
      final list = (res['discussions'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // 1c. Kirim pesan ke forum kelas atau PM
  static Future<Map<String, dynamic>?> sendClassDiscussion(
    String classId, {
    required String message,
    String? recipientId,
    String? attachmentUrl,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/classes/$classId/class-discussions', {
        'message': message,
        if (recipientId != null && recipientId.isNotEmpty && recipientId != 'general') 'recipient_id': recipientId,
        if (attachmentUrl != null) 'attachment_url': attachmentUrl,
      });
      return Map<String, dynamic>.from(res['message'] ?? {});
    } catch (e) {
      rethrow;
    }
  }

  // 1d. Ambil kontak chat kelas (Dosen + Seluruh Mahasiswa)
  static Future<Map<String, dynamic>> getClassChatContacts(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId/chat-contacts');
      return {
        'dosen': res['dosen'] as Map<String, dynamic>?,
        'students': ((res['students'] as List?) ?? []).cast<Map<String, dynamic>>(),
        'class_forum_unread': res['class_forum_unread'] ?? 0,
      };
    } catch (_) {
      return {'dosen': null, 'students': <Map<String, dynamic>>[], 'class_forum_unread': 0};
    }
  }

  // 1e. Tandai pesan kelas/PM telah dibaca
  static Future<void> markClassDiscussionRead(String classId, {String? peerId}) async {
    try {
      await ApiService.post('/quizizz/classes/$classId/class-discussions/read', {
        if (peerId != null) 'peer_id': peerId,
      });
    } catch (_) {}
  }

  // 2. Buat grup capstone baru
  static Future<Map<String, dynamic>?> createResearchGroup(
    String classId, {
    required String title,
    String? dosenPembimbing1,
    String? dosenPembimbing2,
    String? dosenKelas,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/classes/$classId/research-groups', {
        'title': title,
        if (dosenPembimbing1 != null) 'dosen_pembimbing_1': dosenPembimbing1,
        if (dosenPembimbing2 != null) 'dosen_pembimbing_2': dosenPembimbing2,
        if (dosenKelas != null) 'dosen_kelas': dosenKelas,
      });
      return Map<String, dynamic>.from(res['group'] ?? {});
    } catch (e) {
      rethrow;
    }
  }

  // 3. Edit judul / nama grup / dosen pembimbing / dosen kelas riset
  static Future<bool> updateResearchGroup(
    String groupId, {
    String? title,
    String? groupName,
    String? dosenPembimbing1,
    String? dosenPembimbing2,
    String? dosenKelas,
  }) async {
    try {
      await ApiService.put('/quizizz/research-groups/$groupId', {
        if (title != null) 'title': title,
        if (groupName != null) 'group_name': groupName,
        if (dosenPembimbing1 != null) 'dosen_pembimbing_1': dosenPembimbing1,
        if (dosenPembimbing2 != null) 'dosen_pembimbing_2': dosenPembimbing2,
        if (dosenKelas != null) 'dosen_kelas': dosenKelas,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // 4. Hapus grup riset
  static Future<bool> deleteResearchGroup(String groupId) async {
    try {
      await ApiService.delete('/quizizz/research-groups/$groupId');
      return true;
    } catch (_) {
      return false;
    }
  }

  // 4b. Keluarkan / Hapus mahasiswa dari grup riset (Dosen)
  static Future<bool> removeResearchGroupMember(String groupId, String studentId) async {
    try {
      await ApiService.delete('/quizizz/research-groups/$groupId/members/$studentId');
      return true;
    } catch (_) {
      return false;
    }
  }

  // 5. Ambil riwayat diskusi grup / japri
  static Future<List<Map<String, dynamic>>> getResearchDiscussions(String groupId) async {
    try {
      final res = await ApiService.get('/quizizz/research-groups/$groupId/discussions');
      final list = (res['discussions'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // 6. Kirim pesan diskusi (grup atau japri)
  static Future<Map<String, dynamic>?> sendResearchDiscussion(
    String groupId, {
    required String message,
    String? recipientId,
    String? attachmentUrl,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/research-groups/$groupId/discussions', {
        'message': message,
        if (recipientId != null) 'recipient_id': recipientId,
        if (attachmentUrl != null) 'attachment_url': attachmentUrl,
      });
      return Map<String, dynamic>.from(res['message'] ?? {});
    } catch (e) {
      rethrow;
    }
  }

  // 7. Tandai pesan diskusi telah dibaca
  static Future<void> markResearchDiscussionRead(String groupId) async {
    try {
      await ApiService.post('/quizizz/research-groups/$groupId/discussions/read', {});
    } catch (_) {}
  }

  // 8. Ambil daftar dokumen approval dalam kelas
  static Future<Map<String, dynamic>> getResearchDocuments(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId/research-documents');
      return {
        'documents': ((res['documents'] as List?) ?? []).cast<Map<String, dynamic>>(),
        'dosen_signature_ready': res['dosen_signature_ready'] == true,
        'dosen_info': res['dosen_info'] as Map<String, dynamic>?,
      };
    } catch (_) {
      return {'documents': <Map<String, dynamic>>[], 'dosen_signature_ready': false};
    }
  }

  // 8b. Ambil seluruh mahasiswa kelas riset beserta grup, judul riset & keaktifan
  static Future<List<Map<String, dynamic>>> getResearchStudentsActivity(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId/research-students-activity');
      if (res['status'] == 'sukses') {
        return ((res['students'] as List?) ?? []).cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // 8c. Reset Password Mahasiswa Menjadi NIM
  static Future<Map<String, dynamic>> resetStudentPasswordToNim(String studentId) async {
    try {
      final res = await ApiService.post('/quizizz/students/$studentId/reset-password-nim', {});
      return res;
    } catch (e) {
      return {'status': 'gagal', 'message': e.toString().replaceAll('Exception: ', '')};
    }
  }

  // 9. Unggah dokumen untuk approval (Mahasiswa)
  static Future<Map<String, dynamic>?> uploadResearchDocument(
    String classId, {
    required String groupId,
    required String documentName,
    String docType = 'lks',
    required String deadline,
    required Uint8List fileBytes,
    required String fileName,
  }) async {
    try {
      final res = await ApiService.post(
        '/quizizz/classes/$classId/research-documents',
        {
          'group_id': groupId,
          'document_name': documentName,
          'doc_type': docType,
          'deadline': deadline,
          'file_base64': base64Encode(fileBytes),
          'filename': fileName.isEmpty ? 'dokumen.pdf' : fileName,
        },
      );
      return Map<String, dynamic>.from(res['document'] ?? {});
    } catch (e) {
      rethrow;
    }
  }

  // 9b. Edit / perbarui dokumen untuk approval (Mahasiswa)
  static Future<Map<String, dynamic>?> updateResearchDocument(
    String docId, {
    required String documentName,
    String? docType,
    required String deadline,
    Uint8List? fileBytes,
    String? fileName,
  }) async {
    try {
      final body = <String, dynamic>{
        'document_name': documentName,
        if (docType != null) 'doc_type': docType,
        'deadline': deadline,
      };
      if (fileBytes != null && fileBytes.isNotEmpty) {
        body['file_base64'] = base64Encode(fileBytes);
        body['filename'] = (fileName == null || fileName.isEmpty) ? 'dokumen.pdf' : fileName;
      }
      final res = await ApiService.put('/quizizz/research-documents/$docId', body);
      return Map<String, dynamic>.from(res['document'] ?? {});
    } catch (e) {
      rethrow;
    }
  }

  // 9c. Hapus dokumen approval (Dosen)
  static Future<void> deleteResearchDocument(String docId) async {
    try {
      await ApiService.delete('/quizizz/research-documents/$docId');
    } catch (e) {
      rethrow;
    }
  }

  // 10. Review dokumen (Dosen: Approve dengan TTD otomatis / Approve tanpa TTD atau Tolak/Revisi)
  static Future<Map<String, dynamic>?> reviewResearchDocument(
    String docId, {
    required String action, // 'approve' | 'reject'
    String? notes,
    bool? sign,
  }) async {
    try {
      final res = await ApiService.put('/quizizz/research-documents/$docId/review', {
        'action': action,
        if (notes != null) 'notes': notes,
        if (sign != null) 'sign': sign,
      });
      return Map<String, dynamic>.from(res);
    } catch (e) {
      rethrow;
    }
  }

  // 11. Unggah tanda tangan digital dosen (PNG)
  static Future<String?> uploadSignature(Uint8List pngBytes, String fileName) async {
    try {
      final res = await ApiService.post(
        '/auth/signature',
        {
          'image_base64': base64Encode(pngBytes),
          'filename': fileName.isEmpty ? 'ttd.png' : fileName,
        },
      );
      return res['signature_url']?.toString();
    } catch (e) {
      rethrow;
    }
  }

  // Mahasiswa: daftar kelas yang sudah pernah di-join — otomatis tampil di
  // dashboard setiap login, tanpa perlu input token ulang.
  static Future<List<Map<String, dynamic>>> getJoinedClasses() async {
    try {
      final res = await ApiService.get('/quizizz/classes/joined');
      final list = (res['classes'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, dynamic>?> getClassDetail(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId');
      return Map<String, dynamic>.from(res['class'] ?? {});
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getClassMembers(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId/members');
      final list = (res['members'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // Dosen: hapus kelas PERMANEN (ikut menghapus seluruh kuis/PR, presentasi,
  // dan flashcard yang terikat ke kelas ini beserta keanggotaan mahasiswa).
  static Future<bool> deleteClass(String classId) async {
    try {
      await ApiService.delete('/quizizz/classes/$classId');
      return true;
    } catch (_) {
      return false;
    }
  }

  // Mahasiswa: keluar dari kelas (hanya keanggotaan sendiri yang dihapus,
  // kelas & mahasiswa lain tidak terpengaruh).
  static Future<bool> leaveClass(String classId) async {
    try {
      await ApiService.delete('/quizizz/classes/$classId/leave');
      return true;
    } catch (_) {
      return false;
    }
  }

  // ----------------------------------------------------------------------
  // FITUR REKAP NILAI (GRADEBOOK)
  // ----------------------------------------------------------------------
  static Future<Map<String, dynamic>?> getGradebook(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId/gradebook');
      return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('getGradebook error: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getMyGrades([String? classId]) async {
    try {
      final cId = classId ?? currentClassId;
      final endpoint = (cId != null && cId.isNotEmpty)
          ? '/quizizz/classes/$cId/my-grades'
          : '/quizizz/student/my-grades';
      final res = await ApiService.get(endpoint);
      return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('getMyGrades error: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> createGradebookItem({
    required String classId,
    required String title,
    String type = 'quiz',
    int maxScore = 100,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/classes/$classId/gradebook/items', {
        'title': title,
        'type': type,
        'max_score': maxScore,
      });
      return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('createGradebookItem error: $e');
      return null;
    }
  }

  static Future<bool> updateStudentGrade({
    required String classId,
    required String assessmentId,
    required String studentId,
    double? score,
    String? notes,
  }) async {
    try {
      await ApiService.put('/quizizz/classes/$classId/gradebook/grades', {
        'assessment_id': assessmentId,
        'student_id': studentId,
        'score': score,
        'notes': notes,
      });
      return true;
    } catch (e) {
      debugPrint('updateStudentGrade error: $e');
      return false;
    }
  }

  static Future<bool> deleteGradebookItem(String classId, String itemId) async {
    try {
      await ApiService.delete('/quizizz/classes/$classId/gradebook/items/$itemId');
      return true;
    } catch (e) {
      debugPrint('deleteGradebookItem error: $e');
      return false;
    }
  }

  // ----------------------------------------------------------------------
  // FITUR PRESENSI & ABSENSI QR CODE PEKANAN
  // ----------------------------------------------------------------------
  static Future<List<Map<String, dynamic>>> getAttendanceSessions(String classId) async {
    try {
      final res = await ApiService.get('/quizizz/classes/$classId/attendance-sessions');
      final list = (res['sessions'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('getAttendanceSessions error: $e');
      return [];
    }
  }

  static Future<Map<String, dynamic>?> openAttendanceSession({
    required String classId,
    required int weekNumber,
    String? title,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/classes/$classId/attendance-sessions', {
        'week_number': weekNumber,
        if (title != null && title.isNotEmpty) 'title': title,
      });
      return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('openAttendanceSession error: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getAttendanceDetail(String sessionId) async {
    try {
      final res = await ApiService.get('/quizizz/attendance-sessions/$sessionId');
      return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('getAttendanceDetail error: $e');
      return null;
    }
  }

  static Future<bool> closeAttendanceSession(String sessionId) async {
    try {
      await ApiService.put('/quizizz/attendance-sessions/$sessionId/close', {});
      return true;
    } catch (e) {
      debugPrint('closeAttendanceSession error: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>> submitAttendance({
    String? sessionCode,
    String? sessionId,
    String? qrData,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/attendance/submit', {
        if (sessionCode != null && sessionCode.isNotEmpty) 'session_code': sessionCode,
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
        if (qrData != null && qrData.isNotEmpty) 'qr_data': qrData,
      });
      return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('submitAttendance error: $e');
      rethrow;
    }
  }

  static Future<bool> updateAttendanceStatus({
    required String recordId,
    required String status,
    String? notes,
  }) async {
    try {
      await ApiService.put('/quizizz/attendance-records/$recordId/status', {
        'status': status,
        'notes': notes,
      });
      return true;
    } catch (e) {
      debugPrint('updateAttendanceStatus error: $e');
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getStudentAttendanceHistory() async {
    try {
      final res = await ApiService.get('/quizizz/attendance/student-history');
      final list = (res['history'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('getStudentAttendanceHistory error: $e');
      return [];
    }
  }

  // ----------------------------------------------------------------------
  // QUIZ & HOMEWORK API ENDPOINTS
  // ----------------------------------------------------------------------
  static Set<String> _deletedQuizIds = {};

  // Menandai sebuah quiz_id sebagai "khusus PR" (dibuat lewat "Buat PR Baru",
  // BUKAN lewat "Buat Kuis Gamifikasi Baru"). Kuis semacam ini tidak boleh
  // muncul di Bank Kuis Gamifikasi, hanya muncul di daftar Pekerjaan Rumah.
  static Future<void> markQuizAsHomeworkOnly(String quizId) async {
    if (quizId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('homework_only_quiz_ids') ?? [];
      if (!list.contains(quizId)) {
        list.add(quizId);
        await prefs.setStringList('homework_only_quiz_ids', list);
      }
    } catch (_) {}
    if (kIsWeb) {
      try {
        final str = html.window.localStorage['homework_only_quiz_ids'];
        final List list = (str != null && str.isNotEmpty) ? jsonDecode(str) : [];
        final set = list.cast<String>().toSet()..add(quizId);
        html.window.localStorage['homework_only_quiz_ids'] = jsonEncode(set.toList());
      } catch (_) {}
    }
  }

  static Future<bool> isHomeworkOnlyQuiz(String quizId) async {
    if (quizId.isEmpty) return false;
    if (kIsWeb) {
      try {
        final str = html.window.localStorage['homework_only_quiz_ids'];
        if (str != null && str.isNotEmpty) {
          final List list = jsonDecode(str);
          if (list.cast<String>().contains(quizId)) return true;
        }
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList('homework_only_quiz_ids') ?? [];
      return list.contains(quizId);
    } catch (_) {
      return false;
    }
  }

  static Future<Set<String>> getHomeworkOnlyQuizIds() async {
    Set<String> result = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      result.addAll(prefs.getStringList('homework_only_quiz_ids') ?? []);
    } catch (_) {}
    if (kIsWeb) {
      try {
        final str = html.window.localStorage['homework_only_quiz_ids'];
        if (str != null && str.isNotEmpty) {
          final List list = jsonDecode(str);
          result.addAll(list.cast<String>());
        }
      } catch (_) {}
    }
    return result;
  }

  static Future<void> _loadDeletedQuizIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList('deleted_quiz_ids') ?? [];
      _deletedQuizIds.addAll(list);
    } catch (_) {}
    if (kIsWeb) {
      try {
        final str = html.window.localStorage['deleted_quiz_ids'];
        if (str != null && str.isNotEmpty) {
          final List parsed = jsonDecode(str);
          _deletedQuizIds.addAll(parsed.cast<String>());
        }
      } catch (_) {}
    }
  }

  static Future<void> _recordDeletedQuizId(String id) async {
    if (id.isEmpty) return;
    _deletedQuizIds.add(id);
    final list = _deletedQuizIds.toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('deleted_quiz_ids', list);
    } catch (_) {}
    if (kIsWeb) {
      try {
        html.window.localStorage['deleted_quiz_ids'] = jsonEncode(list);
      } catch (_) {}
    }
  }

  static Future<Map<String, dynamic>> createQuiz(String title, String description, {String? quizType}) async {
    return ApiService.post('/quizizz/quizzes', {
      'title': title,
      'description': description,
      if (quizType != null) 'quiz_type': quizType,
      if (currentClassId != null) 'class_id': currentClassId,
    });
  }

  static Future<Map<String, dynamic>> getMyQuizzes() async {
    await _loadDeletedQuizIds();
    try {
      final classParam = currentClassId != null ? '?class_id=$currentClassId' : '';
      final res = await ApiService.get('/quizizz/quizzes/mine$classParam');
      List quizzes = (res['quizzes'] as List?) ?? [];

      // PENTING: filter HANYA berdasarkan ID unik, bukan judul. Menyaring
      // berdasarkan judul (title) berbahaya karena dua kuis BERBEDA bisa
      // punya judul yang sama persis (mis. dua kuis sama-sama berjudul
      // "IPA") — menghapus salah satu tidak boleh ikut menyembunyikan yang
      // lain hanya karena judulnya kebetulan sama.
      //
      // PENGECUALIAN: "Live Host Gamifikasi" adalah teks fallback SISTEM
      // (bukan judul yang bisa diketik dosen secara wajar) yang dulu dipakai
      // sebagai default oleh bug lama di backend, menghasilkan kuis "hantu".
      // Baris dengan judul PERSIS itu selalu disaring sebagai lapis
      // pengaman tambahan, di luar perbaikan akar masalah di backend.
      quizzes.removeWhere((q) {
        final id = q['id']?.toString() ?? '';
        final title = q['title']?.toString().trim() ?? '';
        return _deletedQuizIds.contains(id) || title == 'Live Host Gamifikasi';
      });

      return {'status': 'success', 'quizzes': quizzes};
    } catch (_) {
      return {'status': 'success', 'quizzes': []};
    }
  }

  static Future<Map<String, dynamic>> deleteQuiz(String quizId) async {
    if (quizId.isNotEmpty) {
      await _recordDeletedQuizId(quizId);
    }

    Map<String, dynamic> result = {'status': 'success'};
    try {
      result = await ApiService.delete('/quizizz/quizzes/$quizId');
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_kQuizQuestionsKeyPrefix$quizId');
    } catch (_) {}

    if (kIsWeb) {
      try {
        html.window.localStorage.remove('flutter.$_kQuizQuestionsKeyPrefix$quizId');
        html.window.localStorage.remove('$_kQuizQuestionsKeyPrefix$quizId');
      } catch (_) {}
    }

    await deleteHomeworkByQuizId(quizId);
    return result;
  }

  static Future<void> deleteHomeworkByQuizId(String quizId) async {
    final list = await getAssignedHomework();
    list.removeWhere((hw) => hw['quiz_id']?.toString() == quizId || hw['id']?.toString() == 'hw_$quizId');
    await saveHomeworkList(list);
  }

  static Future<Map<String, dynamic>> addQuestion(
    String quizId,
    String questionText, {
    String questionType = 'multiple_choice',
    String? optionA,
    String? optionB,
    String? optionC,
    String? optionD,
    dynamic optionsJson,
    String correctAnswer = 'A',
    int orderIndex = 0,
  }) {
    return ApiService.post('/quizizz/quizzes/$quizId/questions', {
      'question_text': questionText,
      'question_type': questionType,
      'option_a': optionA,
      'option_b': optionB,
      'option_c': optionC,
      'option_d': optionD,
      'options_json': optionsJson,
      'correct_answer': correctAnswer,
      'order_index': orderIndex,
    });
  }

  static Future<Map<String, dynamic>> getQuestions(String quizId) {
    return ApiService.get('/quizizz/quizzes/$quizId/questions', withAuth: false);
  }

  static Future<Map<String, dynamic>> createSession(String quizId, {String mode = 'live', String? deadline}) async {
    final sessionCode = (100000 + (DateTime.now().millisecondsSinceEpoch % 899999)).toString();
    final settings = await getQuizSettings(quizId);
    final shuffleQuestions = settings['shuffle_questions'] == true;
    final shuffleAnswers = settings['shuffle_answers'] == true;

    final sessionData = {
      'id': 'sess_${DateTime.now().millisecondsSinceEpoch}',
      'quiz_id': quizId,
      'session_code': sessionCode,
      'mode': mode,
      'status': 'waiting',
      'shuffle_questions': shuffleQuestions,
      'shuffle_answers': shuffleAnswers,
      'created_at': DateTime.now().toIso8601String(),
    };
    await saveLiveSessionInfo(sessionCode, sessionData);
    await updateLiveSessionStatus(sessionCode, 'waiting');

    // PENTING: soal-soal yang dibuat dosen selama ini hanya tersimpan di
    // localStorage/SharedPreferences BROWSER DOSEN (lihat addCustomQuestion /
    // getCustomQuestions di bawah). Supaya mahasiswa di perangkat/browser lain
    // bisa mendapatkan soal yang sama dari backend, sinkronkan dulu ke server
    // setiap kali dosen membuat sesi live (sebelum PIN dibagikan).
    await syncLocalQuestionsToBackend(quizId);

    try {
      final apiRes = await ApiService.post('/quizizz/sessions', {
        'quiz_id': quizId,
        'mode': mode,
        'deadline': deadline,
        'shuffle_questions': shuffleQuestions,
        'shuffle_answers': shuffleAnswers,
      });
      if (apiRes['session'] != null) {
        final code = apiRes['session']['session_code']?.toString() ?? sessionCode;
        apiRes['session']['session_code'] = code;
        apiRes['session']['quiz_id'] = quizId;
        apiRes['session']['shuffle_questions'] = shuffleQuestions;
        apiRes['session']['shuffle_answers'] = shuffleAnswers;
        await saveLiveSessionInfo(code, Map<String, dynamic>.from(apiRes['session']));
        await updateLiveSessionStatus(code, 'waiting');
        return apiRes;
      }
    } catch (_) {}
    return {'status': 'success', 'session': sessionData};
  }

  // Menyinkronkan soal kuis yang dibuat dosen secara lokal (localStorage) ke
  // tabel `quizizz_questions` di BACKEND, supaya mahasiswa di device lain bisa
  // mengambilnya lewat GET /quizizz/sessions/pin/:pin (bukan cuma dari
  // localStorage dosen yang tidak bisa diakses device lain).
  //
  // Aman dipanggil berkali-kali: kalau jumlah soal di backend sudah sama atau
  // lebih banyak dari lokal, dianggap sudah sinkron dan tidak dikirim ulang
  // (mencegah duplikat). Kalau tidak sama (misal dosen mengedit soal secara
  // lokal), soal lama di backend dihapus dulu lalu dikirim ulang semuanya.
  static Future<void> syncLocalQuestionsToBackend(String quizId) async {
    if (quizId.isEmpty) return;
    try {
      final localQuestions = await getCustomQuestions(quizId);
      if (localQuestions.isEmpty) return;

      // PENTING: SELALU hapus dulu soal lama di backend lalu kirim ulang
      // SEMUA soal terbaru (bukan hanya jika JUMLAH soal berbeda). Sebelumnya
      // sync di-skip kalau jumlah soal sama persis — padahal dosen bisa saja
      // MENGEDIT isi/jawaban benar sebuah soal (jumlah soal tetap sama), yang
      // membuat backend menyimpan jawaban benar LAMA (basi). Akibatnya
      // jawaban mahasiswa yang sebenarnya sudah benar sesuai soal TERBARU
      // dianggap salah karena dicocokkan dengan data lama di backend.
      List backendQuestions = [];
      try {
        final res = await ApiService.get('/quizizz/quizzes/$quizId/questions', withAuth: false);
        backendQuestions = (res['questions'] as List?) ?? [];
      } catch (_) {}

      for (final bq in backendQuestions) {
        final qid = bq['id']?.toString();
        if (qid != null && qid.isNotEmpty) {
          try {
            await ApiService.delete('/quizizz/questions/$qid', withAuth: false);
          } catch (_) {}
        }
      }

      for (int i = 0; i < localQuestions.length; i++) {
        final q = localQuestions[i];
        try {
          await ApiService.post('/quizizz/quizzes/$quizId/questions', {
            'question': q['question'] ?? q['question_text'],
            'type': q['type'] ?? q['question_type'] ?? 'multiple_choice',
            'options': q['options'],
            'correct': q['correct'],
            'correct_list': q['correct_list'],
            'image_url': q['image_url'],
            'option_images': q['option_images'],
            'timer_seconds': q['timer_seconds'] ?? 30,
            'order_index': i,
            if (q['variable_calc_json'] != null) 'variable_calc_json': q['variable_calc_json'],
          }, withAuth: false);
        } catch (_) {
          // Satu soal gagal sync tidak boleh menghentikan proses soal lain.
        }
      }
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> getHomeworkSessions(dynamic userId, {bool includeDraft = false}) {
    final draftParam = includeDraft ? '&include_draft=1' : '';
    final classParam = currentClassId != null ? '&class_id=$currentClassId' : '';
    return ApiService.get('/quizizz/sessions/homework?userId=$userId$draftParam$classParam', withAuth: false);
  }

  static Future<Map<String, dynamic>> deleteSession(String sessionId) {
    return ApiService.delete('/quizizz/sessions/$sessionId');
  }

  static Future<Map<String, dynamic>> getSessionByPin(String pin) {
    return ApiService.get('/quizizz/sessions/pin/$pin', withAuth: false);
  }

  // Polling ringan status sesi langsung ke backend (lintas device: dosen & mahasiswa
  // bisa berada di browser/perangkat berbeda, jadi status TIDAK BOLEH hanya
  // bergantung pada localStorage/SharedPreferences lokal).
  static Future<Map<String, dynamic>> getServerSessionStatus(String pin) {
    return ApiService.get('/quizizz/sessions/pin/$pin/status', withAuth: false);
  }

  // Dosen menekan "Mulai Room Game Sekarang" -> update status sesi di BACKEND
  // (via kolom pin, tidak perlu tahu id internal) supaya seluruh mahasiswa yang
  // join dari perangkat lain langsung mendeteksi perubahan status ini.
  static Future<Map<String, dynamic>> setServerSessionStatus(String pin, String status) {
    return ApiService.patch('/quizizz/sessions/pin/$pin/status', {'status': status}, withAuth: false);
  }

  static Future<Map<String, dynamic>> joinSession(String sessionId, String displayName, {dynamic userId}) {
    return ApiService.post('/quizizz/sessions/$sessionId/join', {
      'display_name': displayName,
      'user_id': userId,
    }, withAuth: false);
  }

  static Future<Map<String, dynamic>> updateSessionStatus(String sessionId, String status) {
    return ApiService.patch('/quizizz/sessions/$sessionId/status', {'status': status});
  }

  static Future<Map<String, dynamic>> submitAnswer(String sessionId, String questionId, String playerId, dynamic answer, {int? totalTime, int? timeRemaining, bool? isCorrect}) {
    final body = <String, dynamic>{
      'player_id': playerId,
      'answer': answer,
    };
    // Dikirim supaya backend bisa menghitung bonus kecepatan dengan rumus
    // yang SAMA PERSIS dengan tampilan di Flutter (lihat catatan di
    // _revealAnswerAndAdvance) -- backend adalah sumber kebenaran skor.
    if (totalTime != null) body['total_time'] = totalTime;
    if (timeRemaining != null) body['time_remaining'] = timeRemaining;
    if (isCorrect != null) body['is_correct'] = isCorrect;
    return ApiService.post('/quizizz/sessions/$sessionId/questions/$questionId/answer', body, withAuth: false);
  }

  static Future<Map<String, dynamic>> completePlayer(String sessionId, String playerId) {
    return ApiService.post('/quizizz/sessions/$sessionId/players/$playerId/complete', {}, withAuth: false);
  }

  static Future<Map<String, dynamic>> getLeaderboard(String sessionId) {
    return ApiService.get('/quizizz/sessions/$sessionId/leaderboard', withAuth: false);
  }

  static Future<Map<String, dynamic>> getQuizReport(String quizId) {
    return ApiService.get('/quizizz/reports/$quizId');
  }

  static Future<Map<String, dynamic>> getMyHistory() {
    return ApiService.get('/quizizz/history/mine');
  }

  // ----------------------------------------------------------------------
  // LOCAL STORAGE & SERVICE HANDLERS UNTUK SOAL GAMIFIKASI & HOMEWORK (PR)
  // ----------------------------------------------------------------------
  static const String _kQuizQuestionsKeyPrefix = 'quiz_questions_';
  static const String _kHomeworkKey = 'assigned_homework_sessions';
  static const String _kLiveSessionStatusPrefix = 'live_session_status_';

  static Future<List<Map<String, dynamic>>> getCustomQuestions(String quizId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final str = prefs.getString('$_kQuizQuestionsKeyPrefix$quizId');
      if (str != null && str.isNotEmpty) {
        final List parsed = jsonDecode(str);
        return parsed.cast<Map<String, dynamic>>();
      }
    } catch (_) {}

    if (kIsWeb) {
      try {
        final htmlStr = html.window.localStorage['flutter.$_kQuizQuestionsKeyPrefix$quizId'] ??
            html.window.localStorage['$_kQuizQuestionsKeyPrefix$quizId'];
        if (htmlStr != null && htmlStr.isNotEmpty) {
          final List parsed = jsonDecode(htmlStr);
          return parsed.cast<Map<String, dynamic>>();
        }
      } catch (_) {}
    }

    try {
      final res = await getQuestions(quizId);
      if (res['questions'] != null && (res['questions'] as List).isNotEmpty) {
        return (res['questions'] as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}

    return [];
  }

  static Future<bool> saveCustomQuestions(String quizId, List<Map<String, dynamic>> questions) async {
    final jsonStr = jsonEncode(questions);
    bool prefsOk = false;
    bool htmlOk = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      prefsOk = await prefs.setString('$_kQuizQuestionsKeyPrefix$quizId', jsonStr);
    } catch (_) {}

    if (kIsWeb) {
      try {
        html.window.localStorage['flutter.$_kQuizQuestionsKeyPrefix$quizId'] = jsonStr;
        html.window.localStorage['$_kQuizQuestionsKeyPrefix$quizId'] = jsonStr;
        htmlOk = true;
      } catch (_) {
        // Biasanya gagal karena kuota localStorage penuh (mis. gambar base64
        // terlalu besar) — dilaporkan ke pemanggil, JANGAN ditelan diam-diam,
        // supaya dosen tahu soal gagal tersimpan alih-alih soal "menghilang".
        htmlOk = false;
      }
    } else {
      htmlOk = true; // Bukan platform web: cukup andalkan SharedPreferences.
    }

    return prefsOk || htmlOk;
  }

  static Future<bool> addCustomQuestion(String quizId, Map<String, dynamic> question) async {
    final qList = await getCustomQuestions(quizId);
    qList.add(question);
    final ok = await saveCustomQuestions(quizId, qList);
    if (!ok) {
      // Simpan gagal (mis. kuota penuh) -> jangan biarkan soal baru tampak
      // "berhasil ditambahkan" padahal sebenarnya tidak tersimpan.
      qList.removeLast();
    }
    return ok;
  }

  static Future<List<Map<String, dynamic>>> getAllSavedCustomQuestions() async {
    if (kIsWeb) {
      try {
        final keys = html.window.localStorage.keys;
        for (final k in keys) {
          if (k.contains('quiz_questions_')) {
            final str = html.window.localStorage[k];
            if (str != null && str.isNotEmpty && str != '[]') {
              final List parsed = jsonDecode(str);
              if (parsed.isNotEmpty) {
                return parsed.cast<Map<String, dynamic>>();
              }
            }
          }
        }
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final keys = prefs.getKeys();
      for (final k in keys) {
        if (k.contains('quiz_questions_')) {
          final str = prefs.getString(k);
          if (str != null && str.isNotEmpty && str != '[]') {
            final List parsed = jsonDecode(str);
            if (parsed.isNotEmpty) {
              return parsed.cast<Map<String, dynamic>>();
            }
          }
        }
      }
    } catch (_) {}

    return [];
  }

  // ----------------------------------------------------------------------
  // QUIZ & LESSON ANTI-CHEATING SETTINGS (ACAK SOAL & ACAK JAWABAN)
  // ----------------------------------------------------------------------
  static Future<Map<String, dynamic>> getQuizSettings(String quizId) async {
    try {
      if (kIsWeb) {
        final raw = html.window.localStorage['quiz_settings_$quizId'];
        if (raw != null && raw.isNotEmpty) {
          return Map<String, dynamic>.from(jsonDecode(raw));
        }
      }
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('quiz_settings_$quizId');
      if (raw != null && raw.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(raw));
      }
    } catch (_) {}
    return {'shuffle_questions': false, 'shuffle_answers': false};
  }

  static Future<void> saveQuizSettings(String quizId, Map<String, dynamic> settings) async {
    try {
      final jsonStr = jsonEncode(settings);
      if (kIsWeb) {
        html.window.localStorage['quiz_settings_$quizId'] = jsonStr;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('quiz_settings_$quizId', jsonStr);
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> getLessonSettings(String lessonId) async {
    try {
      if (kIsWeb) {
        final raw = html.window.localStorage['lesson_settings_$lessonId'];
        if (raw != null && raw.isNotEmpty) {
          return Map<String, dynamic>.from(jsonDecode(raw));
        }
      }
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('lesson_settings_$lessonId');
      if (raw != null && raw.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(raw));
      }
    } catch (_) {}
    return {'shuffle_questions': false, 'shuffle_answers': false};
  }

  static Future<void> saveLessonSettings(String lessonId, Map<String, dynamic> settings) async {
    try {
      final jsonStr = jsonEncode(settings);
      if (kIsWeb) {
        html.window.localStorage['lesson_settings_$lessonId'] = jsonStr;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lesson_settings_$lessonId', jsonStr);
    } catch (_) {}
  }

  // ----------------------------------------------------------------------
  // PEKERJAAN RUMAH (HOMEWORK / SELF-PACED) REACTIVE HANDLERS
  // ----------------------------------------------------------------------
  static final ValueNotifier<int> homeworkChangeNotifier = ValueNotifier<int>(0);
  static List<Map<String, dynamic>> _inMemoryAssignedHomework = [];
  static const String _kDeletedHomeworkKey = 'deleted_homework_ids';
  static Set<String> _deletedHomeworkIds = {};

  static Future<void> _loadDeletedHomeworkIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList(_kDeletedHomeworkKey) ?? [];
      _deletedHomeworkIds.addAll(list);
    } catch (_) {}
    if (kIsWeb) {
      try {
        final str = html.window.localStorage['assigned_deleted_homework_ids'];
        if (str != null && str.isNotEmpty) {
          final List parsed = jsonDecode(str);
          _deletedHomeworkIds.addAll(parsed.cast<String>());
        }
      } catch (_) {}
    }
  }

  static Future<void> _recordDeletedHomeworkId(String id) async {
    if (id.isEmpty) return;
    _deletedHomeworkIds.add(id);
    final list = _deletedHomeworkIds.toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kDeletedHomeworkKey, list);
    } catch (_) {}
    if (kIsWeb) {
      try {
        html.window.localStorage['assigned_deleted_homework_ids'] = jsonEncode(list);
      } catch (_) {}
    }
  }

  // includeDraft: true HANYA dipakai oleh halaman Dosen supaya PR yang baru
  // dibuat (status 'draft', belum ditekan "Aktifkan") tetap terlihat di
  // daftar dosen. Halaman Mahasiswa TIDAK BOLEH pernah mengirim true di
  // sini, supaya PR draft tidak pernah muncul di perangkat mahasiswa.
  static Future<List<Map<String, dynamic>>> getAssignedHomework({bool includeDraft = false}) async {
    await _loadDeletedHomeworkIds();
    List<Map<String, dynamic>> resultList = [];
    bool backendOk = false;

    // PENTING: BACKEND diperlakukan sebagai SUMBER KEBENARAN UTAMA dan
    // dicoba LEBIH DULU. Sebelumnya cache lokal (in-memory/SharedPreferences/
    // localStorage) selalu digabung duluan lalu backend hanya "menambahkan"
    // yang belum ada — akibatnya PR yang sudah DINONAKTIFKAN dosen (sehingga
    // tidak lagi muncul di hasil backend) tetap "hidup lagi" karena masih
    // tersimpan di cache lokal dari kunjungan sebelumnya, dan tidak pernah
    // dibersihkan. Sekarang: kalau backend berhasil dihubungi, hasil backend
    // itulah yang dipakai apa adanya (otomatis mengikuti status terbaru).
    try {
      final res = await getHomeworkSessions('all', includeDraft: includeDraft);
      final sessions = (res['sessions'] as List?) ?? [];
      backendOk = true;
      for (final s in sessions) {
        final quizId = s['quiz_id']?.toString() ?? '';
        final sessId = s['id']?.toString() ?? '';
        final rawTitle = s['title'] ?? s['quiz_title'] ?? 'PR Mandiri';
        final cleanTitle = rawTitle.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim();
        final formattedTitle = 'PR Mandiri: $cleanTitle';

        if (!resultList.any((existing) =>
            (quizId.isNotEmpty && existing['quiz_id']?.toString() == quizId) ||
            (sessId.isNotEmpty && existing['id']?.toString() == sessId))) {
          resultList.add({
            'id': sessId.isNotEmpty ? sessId : 'hw_$quizId',
            'quiz_id': quizId,
            'title': formattedTitle,
            'description': s['description'] ?? 'Tugas PR Mandiri dari Dosen',
            'deadline': s['deadline'] ?? DateTime.now().add(const Duration(days: 3)).toIso8601String(),
            'questions': s['questions'] ?? [],
            'created_at': s['created_at'] ?? DateTime.now().toIso8601String(),
            'status': s['status'] ?? 'active',
          });
        }
      }
    } catch (_) {
      backendOk = false;
    }

    // Cache lokal HANYA dipakai sebagai cadangan kalau backend benar-benar
    // tidak terjangkau (mis. sedang offline) — bukan digabung begitu saja
    // setiap saat, supaya PR yang sudah dinonaktifkan/dihapus dosen tidak
    // "hidup lagi" dari data lama di localStorage/SharedPreferences.
    if (!backendOk) {
      // 0. Include in-memory list first
      for (final item in _inMemoryAssignedHomework) {
        final itemId = item['id']?.toString() ?? '';
        final itemQid = item['quiz_id']?.toString() ?? '';
        if (!resultList.any((existing) =>
            (itemId.isNotEmpty && existing['id']?.toString() == itemId) ||
            (itemQid.isNotEmpty && existing['quiz_id']?.toString() == itemQid))) {
          resultList.add(Map<String, dynamic>.from(item));
        }
      }

      // 1. Read from SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final str = prefs.getString(_kHomeworkKey);
        if (str != null && str.isNotEmpty) {
          final List parsed = jsonDecode(str);
          for (final item in parsed.cast<Map<String, dynamic>>()) {
            final itemId = item['id']?.toString() ?? '';
            final itemQid = item['quiz_id']?.toString() ?? '';
            if (!resultList.any((existing) =>
                (itemId.isNotEmpty && existing['id']?.toString() == itemId) ||
                (itemQid.isNotEmpty && existing['quiz_id']?.toString() == itemQid))) {
              resultList.add(item);
            }
          }
        }
      } catch (_) {}

      // 2. Read from direct window.localStorage for Web Cross-Tab Sync
      if (kIsWeb) {
        try {
          final htmlStr = html.window.localStorage['flutter.assigned_homework_sessions'] ??
              html.window.localStorage['assigned_homework_sessions'];
          if (htmlStr != null && htmlStr.isNotEmpty) {
            final List parsed = jsonDecode(htmlStr);
            for (final item in parsed.cast<Map<String, dynamic>>()) {
              final itemId = item['id']?.toString() ?? '';
              final itemQid = item['quiz_id']?.toString() ?? '';
              if (!resultList.any((existing) =>
                  (itemId.isNotEmpty && existing['id']?.toString() == itemId) ||
                  (itemQid.isNotEmpty && existing['quiz_id']?.toString() == itemQid))) {
                resultList.add(item);
              }
            }
          }
        } catch (_) {}
      }
    }

    // Selalu simpan hasil TERBARU dari backend ke cache lokal (kalau backend
    // berhasil), supaya cadangan offline berikutnya tetap up-to-date dan
    // tidak menyimpan data basi untuk waktu lama. PENGECUALIAN: hasil yang
    // menyertakan draft (includeDraft=true, khusus halaman Dosen) TIDAK
    // ditulis ke cache offline bersama ini, supaya PR draft milik dosen
    // tidak pernah bocor ke fallback offline yang dibaca halaman Mahasiswa.
    if (backendOk && !includeDraft) {
      _inMemoryAssignedHomework = List<Map<String, dynamic>>.from(resultList);
      try {
        final prefs = await SharedPreferences.getInstance();
        final jsonStr = jsonEncode(resultList);
        await prefs.setString(_kHomeworkKey, jsonStr);
        if (kIsWeb) {
          html.window.localStorage['flutter.assigned_homework_sessions'] = jsonStr;
          html.window.localStorage['assigned_homework_sessions'] = jsonStr;
        }
      } catch (_) {}
    }

    resultList.removeWhere((hw) {
      final id = hw['id']?.toString() ?? '';
      final qId = hw['quiz_id']?.toString() ?? '';
      final title = (hw['title']?.toString() ?? '').toLowerCase();

      if (id == '1' || id == 'hw_1' || id == 'hw_default_1' || qId == '1' || title == 'pr mandiri: gamifikasi' || title == 'gamifikasi') {
        return true;
      }
      return false;
    });

    // Filter out any explicitly deleted homeworks
    resultList.removeWhere((hw) {
      final id = hw['id']?.toString() ?? '';
      final rawTitle = hw['title']?.toString() ?? '';
      final cleanT = rawTitle.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
      return _deletedHomeworkIds.contains(id) || (cleanT.isNotEmpty && _deletedHomeworkIds.contains('title_$cleanT'));
    });

    // Format all titles cleanly
    for (final hw in resultList) {
      final t = hw['title']?.toString() ?? 'PR Mandiri';
      final cleanT = t.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim();
      hw['title'] = 'PR Mandiri: $cleanT';
    }

    for (final hw in resultList) {
      final qList = (hw['questions'] as List?) ?? [];
      if (qList.isEmpty) {
        final hwId = hw['id']?.toString() ?? '';
        final qId = hw['quiz_id']?.toString() ?? '';
        List<Map<String, dynamic>> fetched = [];
        if (hwId.isNotEmpty) {
          fetched = await getCustomQuestions(hwId);
        }
        if (fetched.isEmpty && qId.isNotEmpty) {
          fetched = await getCustomQuestions(qId);
        }
        if (fetched.isNotEmpty) {
          hw['questions'] = fetched;
        }
      }
    }

    if (!includeDraft) {
      _inMemoryAssignedHomework = List<Map<String, dynamic>>.from(resultList);
    }
    return resultList;
  }

  static Future<void> saveHomeworkList(List<Map<String, dynamic>> list) async {
    _inMemoryAssignedHomework = List<Map<String, dynamic>>.from(list);
    
    String jsonStr = '[]';
    try {
      jsonStr = jsonEncode(list);
    } catch (_) {
      try {
        jsonStr = jsonEncode(list.map((item) => {
          'id': item['id']?.toString(),
          'quiz_id': item['quiz_id']?.toString(),
          'title': item['title']?.toString(),
          'description': item['description']?.toString(),
          'deadline': item['deadline']?.toString(),
          'questions': item['questions'],
          'created_at': item['created_at']?.toString(),
        }).toList());
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHomeworkKey, jsonStr);
    } catch (_) {}

    if (kIsWeb) {
      try {
        html.window.localStorage['flutter.assigned_homework_sessions'] = jsonStr;
        html.window.localStorage['assigned_homework_sessions'] = jsonStr;
      } catch (_) {}
    }
    homeworkChangeNotifier.value++;
  }

  static Future<void> deleteHomework(String homeworkId, {String? quizId, String? title}) async {
    if (homeworkId.isNotEmpty) {
      await _recordDeletedHomeworkId(homeworkId);
      await _recordDeletedHomeworkId(homeworkId.replaceAll('hw_', ''));
    }
    if (title != null && title.isNotEmpty) {
      final cleanT = title.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
      if (cleanT.isNotEmpty) {
        await _recordDeletedHomeworkId('title_$cleanT');
      }
    }

    _inMemoryAssignedHomework.removeWhere((hw) {
      final id = hw['id']?.toString() ?? '';
      final qId = hw['quiz_id']?.toString() ?? '';
      final rawTitle = hw['title']?.toString() ?? '';
      final cleanT = rawTitle.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
      final targetCleanT = (title ?? '').replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();

      return id == homeworkId || (quizId != null && quizId.isNotEmpty && qId == quizId) || id == homeworkId.replaceAll('hw_', '') || (targetCleanT.isNotEmpty && cleanT == targetCleanT);
    });
    homeworkChangeNotifier.value++;

    try {
      // PENTING: hapus di BACKEND memakai quiz_id sebagai target UTAMA
      // (selalu ID asli yang stabil), plus percobaan tambahan via homeworkId
      // sebagai cadangan. Sebelumnya hanya mencoba homeworkId yang di-strip
      // prefix 'hw_' — kalau ID itu bukan ID asli backend (mis. ID lokal
      // sementara), penghapusan di server gagal diam-diam sehingga PR yang
      // sudah dihapus dosen tetap muncul di perangkat mahasiswa manapun.
      if (quizId != null && quizId.isNotEmpty) {
        try {
          await ApiService.delete('/quizizz/homework/$quizId', withAuth: false);
        } catch (_) {}
      }
      final cleanId = homeworkId.replaceAll('hw_', '');
      if (cleanId.isNotEmpty) {
        try {
          await ApiService.delete('/quizizz/homework/$cleanId', withAuth: false);
        } catch (_) {}
      }
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final str = prefs.getString(_kHomeworkKey);
      if (str != null && str.isNotEmpty) {
        final List parsed = jsonDecode(str);
        final filtered = parsed.where((item) {
          final id = item['id']?.toString() ?? '';
          final qId = item['quiz_id']?.toString() ?? '';
          final rawTitle = item['title']?.toString() ?? '';
          final cleanT = rawTitle.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
          final targetCleanT = (title ?? '').replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
          return id != homeworkId && (quizId == null || quizId.isEmpty || qId != quizId) && id != homeworkId.replaceAll('hw_', '') && (targetCleanT.isEmpty || cleanT != targetCleanT);
        }).toList();
        await prefs.setString(_kHomeworkKey, jsonEncode(filtered));
      }
    } catch (_) {}

    if (kIsWeb) {
      try {
        final htmlStr = html.window.localStorage['flutter.assigned_homework_sessions'] ??
            html.window.localStorage['assigned_homework_sessions'];
        if (htmlStr != null && htmlStr.isNotEmpty) {
          final List parsed = jsonDecode(htmlStr);
          final filtered = parsed.where((item) {
            final id = item['id']?.toString() ?? '';
            final qId = item['quiz_id']?.toString() ?? '';
            final rawTitle = item['title']?.toString() ?? '';
            final cleanT = rawTitle.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
            final targetCleanT = (title ?? '').replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
            return id != homeworkId && (quizId == null || quizId.isEmpty || qId != quizId) && id != homeworkId.replaceAll('hw_', '') && (targetCleanT.isEmpty || cleanT != targetCleanT);
          }).toList();
          final jsonStr = jsonEncode(filtered);
          html.window.localStorage['flutter.assigned_homework_sessions'] = jsonStr;
          html.window.localStorage['assigned_homework_sessions'] = jsonStr;
        }
      } catch (_) {}
    }
    homeworkChangeNotifier.value++;
  }

  // Menonaktifkan PR (BUKAN menghapus) — hasil pengerjaan mahasiswa tetap
  // tersimpan untuk direkap di Laporan Rekap, tapi PR langsung hilang dari
  // daftar aktif SEMUA mahasiswa (lintas device) karena statusnya diubah di
  // backend, bukan cuma di localStorage dosen.
  static Future<void> deactivateHomework(String homeworkId, {String? quizId}) async {
    final targetId = (quizId != null && quizId.isNotEmpty) ? quizId : homeworkId;
    try {
      await ApiService.patch('/quizizz/homework/$targetId/status', {'status': 'deleted'}, withAuth: false);
    } catch (_) {}
    // Hapus dari daftar PR AKTIF lokal (supaya dosen langsung lihat perubahan
    // di device-nya sendiri tanpa menunggu polling berikutnya), TANPA
    // menghapus data soal/jawaban yang tersimpan.
    _inMemoryAssignedHomework.removeWhere((hw) {
      final id = hw['id']?.toString() ?? '';
      final qId = hw['quiz_id']?.toString() ?? '';
      return id == homeworkId || (quizId != null && quizId.isNotEmpty && qId == quizId);
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final str = prefs.getString(_kHomeworkKey);
      if (str != null && str.isNotEmpty) {
        final List parsed = jsonDecode(str);
        final filtered = parsed.where((item) {
          final id = item['id']?.toString() ?? '';
          final qId = item['quiz_id']?.toString() ?? '';
          return id != homeworkId && (quizId == null || quizId.isEmpty || qId != quizId);
        }).toList();
        await prefs.setString(_kHomeworkKey, jsonEncode(filtered));
      }
    } catch (_) {}
    if (kIsWeb) {
      try {
        final htmlStr = html.window.localStorage['flutter.assigned_homework_sessions'] ??
            html.window.localStorage['assigned_homework_sessions'];
        if (htmlStr != null && htmlStr.isNotEmpty) {
          final List parsed = jsonDecode(htmlStr);
          final filtered = parsed.where((item) {
            final id = item['id']?.toString() ?? '';
            final qId = item['quiz_id']?.toString() ?? '';
            return id != homeworkId && (quizId == null || quizId.isEmpty || qId != quizId);
          }).toList();
          final jsonStr = jsonEncode(filtered);
          html.window.localStorage['flutter.assigned_homework_sessions'] = jsonStr;
          html.window.localStorage['assigned_homework_sessions'] = jsonStr;
        }
      } catch (_) {}
    }
    homeworkChangeNotifier.value++;
  }

  // Mengaktifkan kembali PR yang sebelumnya dinonaktifkan (kebalikan dari
  // deactivateHomework) — PR akan tampil lagi di daftar PR aktif mahasiswa.
  static Future<void> reactivateHomework(String homeworkId, {String? quizId}) async {
    final targetId = (quizId != null && quizId.isNotEmpty) ? quizId : homeworkId;
    try {
      await ApiService.patch('/quizizz/homework/$targetId/status', {'status': 'active'}, withAuth: false);
    } catch (_) {}
    homeworkChangeNotifier.value++;
  }

  // Mengaktifkan PR yang baru dibuat (status 'draft') supaya langsung tampil
  // di daftar PR aktif mahasiswa. Memakai endpoint status yang sama dengan
  // reactivateHomework (keduanya hanya mengubah status jadi 'active'), tapi
  // diberi nama terpisah supaya jelas maksudnya dari sisi pemanggil UI.
  static Future<void> activateHomework(String homeworkId, {String? quizId}) =>
      reactivateHomework(homeworkId, quizId: quizId);

  // Menghapus PR yang sudah dinonaktifkan secara PERMANEN (dari Riwayat PR),
  // termasuk seluruh hasil pengerjaan mahasiswa untuk PR tersebut.
  static Future<void> deletePermanentlyFromHistory(String homeworkId, {String? quizId}) async {
    final targetId = (quizId != null && quizId.isNotEmpty) ? quizId : homeworkId;
    try {
      await ApiService.delete('/quizizz/homework/$targetId', withAuth: false);
    } catch (_) {}
  }

  // Daftar PR yang telah dinonaktifkan dosen, dipakai halaman Laporan Rekap.
  static Future<List<Map<String, dynamic>>> getDeactivatedHomeworkList() async {
    try {
      final res = await ApiService.get('/quizizz/homework/deactivated', withAuth: false);
      final List list = (res['homeworks'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getQuizResults(String quizId) async {
    try {
      final res = await ApiService.get('/quizizz/quizzes/$quizId/live-results', withAuth: false);
      final List list = (res['results'] as List?) ?? (res['submissions'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // Fitur "Riwayat Jawaban PR": ambil submission PR lengkap dengan detail
  // jawaban per soal (question, student_answer, correct_answer, is_correct)
  // — dipakai baik oleh halaman Dosen (rekap semua mahasiswa) maupun
  // Mahasiswa (riwayat jawaban milik sendiri).
  static Future<List<Map<String, dynamic>>> getHomeworkSubmissionsDetailed(String targetId) async {
    if (targetId.isEmpty) return [];
    try {
      final res = await ApiService.get('/quizizz/homework/$targetId/submissions', withAuth: false);
      final List list = (res['submissions'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> updateHomeworkDeadline(String homeworkId, DateTime newDeadline, {String? quizId}) async {
    // PENTING: selalu konversi ke UTC eksplisit sebelum dikirim. DateTime
    // lokal yang di-toIso8601String() TIDAK menyertakan penanda zona waktu
    // ('Z'), sehingga backend/mahasiswa di zona waktu berbeda bisa salah
    // menafsirkan jamnya. Dengan .toUtc(), string yang dikirim selalu
    // merepresentasikan instant yang sama persis di mana pun dibaca.
    final utcDeadline = newDeadline.toUtc();
    // PENTING: kirim ke BACKEND (bukan cuma disimpan lokal), supaya
    // perubahan tenggat waktu benar-benar tersimpan permanen dan konsisten
    // di halaman dosen maupun semua mahasiswa. Sebelumnya hanya tersimpan
    // di localStorage dosen sendiri, sehingga tertimpa lagi oleh data lama
    // dari backend begitu daftar PR di-refresh.
    final targetId = (quizId != null && quizId.isNotEmpty) ? quizId : homeworkId;
    try {
      await ApiService.patch('/quizizz/homework/$targetId/deadline', {
        'deadline': utcDeadline.toIso8601String(),
      }, withAuth: false);
    } catch (_) {}

    final list = await getAssignedHomework();
    for (final hw in list) {
      if (hw['id'] == homeworkId || (quizId != null && hw['quiz_id'] == quizId)) {
        hw['deadline'] = utcDeadline.toIso8601String();
        break;
      }
    }
    await saveHomeworkList(list);
    homeworkChangeNotifier.value++;
  }

  static Future<Map<String, dynamic>> assignHomework({
    required String quizId,
    required String title,
    required String description,
    required DateTime deadline,
  }) async {
    final cleanT = title.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim().toLowerCase();
    _deletedHomeworkIds.remove(quizId);
    _deletedHomeworkIds.remove('hw_$quizId');
    _deletedHomeworkIds.remove('title_$cleanT');

    try {
      final list = _deletedHomeworkIds.toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kDeletedHomeworkKey, list);
      if (kIsWeb) {
        html.window.localStorage['assigned_deleted_homework_ids'] = jsonEncode(list);
      }
    } catch (_) {}

    // PENTING: pakai endpoint KHUSUS PR (POST /homework), BUKAN endpoint sesi
    // live generik (createSession). Endpoint generik itu dulu membuat baris
    // KUIS "HANTU" tambahan di Bank Kuis (bertajuk fallback "Live Host
    // Gamifikasi") setiap kali PR dibuat, dan menduplikasi soal ke ID baru
    // sehingga Kelola Soal Bank Kuis & PR jadi tampak "terhubung". Endpoint
    // /homework ini hanya membuat SATU baris PR yang terikat langsung ke
    // quiz_id ASLI, tanpa membuat/menduplikasi apapun.
    String backendHwId = 'hw_${DateTime.now().millisecondsSinceEpoch}';
    // PENTING: konversi ke UTC eksplisit sebelum dikirim (lihat catatan di
    // updateHomeworkDeadline) supaya tenggat waktu tidak bergeser jam saat
    // dibaca ulang oleh mahasiswa.
    final utcDeadline = deadline.toUtc();
    try {
      final res = await ApiService.post('/quizizz/homework', {
        'quiz_id': quizId,
        'title': title,
        'description': description,
        'deadline': utcDeadline.toIso8601String(),
      });
      final hwRes = res['homework'] as Map<String, dynamic>?;
      if (hwRes != null && hwRes['id'] != null) {
        backendHwId = hwRes['id'].toString();
      }
    } catch (_) {}

    final questions = await getCustomQuestions(quizId);
    final newHw = {
      'id': backendHwId,
      'quiz_id': quizId,
      'title': title,
      'description': description,
      'deadline': utcDeadline.toIso8601String(),
      'questions': questions,
      'created_at': DateTime.now().toIso8601String(),
      // PENTING: PR baru SELALU dibuat sebagai draft (belum tampil ke
      // mahasiswa) — dosen harus menekan tombol "Aktifkan" terlebih dahulu.
      // Karena itu, entri baru ini TIDAK dimasukkan ke daftar PR aktif lokal
      // (yang di-cache untuk fallback offline mahasiswa); ia hanya akan
      // muncul saat dosen memuat ulang daftar dengan includeDraft: true.
      'status': 'draft',
    };

    return newHw;
  }

  // ----------------------------------------------------------------------
  // HOMEWORK SUBMISSIONS & GRADES
  // ----------------------------------------------------------------------
  static Future<List<Map<String, dynamic>>> getHomeworkSubmissions(String hwId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('hw_subs_$hwId');
      if (str != null && str.isNotEmpty) {
        final List parsed = jsonDecode(str);
        return parsed.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  // Mengirim hasil pengerjaan PR ke BACKEND (bukan cuma localStorage), supaya
  // dosen bisa melihat nilai mahasiswa dari perangkat manapun, dan supaya
  // status "sudah dikerjakan" bisa dicek ulang lintas device/refresh.
  static Future<void> submitHomeworkResultToServer({
    required String quizId,
    String? homeworkId,
    required String studentName,
    String? studentId,
    required int score,
    required int totalQuestions,
    List<Map<String, dynamic>>? answers,
  }) async {
    final targetId = quizId.isNotEmpty ? quizId : (homeworkId ?? '');
    if (targetId.isEmpty) return;
    try {
      await ApiService.post('/quizizz/homework/$targetId/submit', {
        'student_name': studentName,
        'student_id': studentId,
        'score': score,
        'total_questions': totalQuestions,
        if (answers != null) 'answers': answers,
      }, withAuth: false);
    } catch (_) {}
  }

  // Cek apakah mahasiswa (berdasarkan ID akun -> fallback nama) SUDAH PERNAH
  // mengerjakan/mengumpulkan PR ini. Memakai ID sebagai kunci utama (bukan
  // hanya nama) supaya status "sudah dikerjakan" benar-benar milik akun
  // mahasiswa yang login saat itu, dan TIDAK ikut tampil "sudah dikerjakan"
  // di akun mahasiswa lain hanya karena kebetulan nama sama/generik.
  static Future<Map<String, dynamic>?> getMyHomeworkSubmission({
    required String quizId,
    String? homeworkId,
    required String studentName,
    String? studentId,
  }) async {
    final targetId = quizId.isNotEmpty ? quizId : (homeworkId ?? '');
    if (targetId.isEmpty) return null;
    if (studentName.trim().isEmpty && (studentId == null || studentId.isEmpty)) return null;
    try {
      final res = await ApiService.get('/quizizz/homework/$targetId/submissions', withAuth: false);
      final List subs = (res['submissions'] as List?) ?? [];
      final cleanId = studentId?.trim();
      final cleanName = studentName.trim().toLowerCase();
      for (final s in subs) {
        final sId = s['student_id']?.toString().trim();
        if (cleanId != null && cleanId.isNotEmpty && sId != null && sId.isNotEmpty) {
          if (sId == cleanId) return Map<String, dynamic>.from(s);
          continue; // Submission ini punya student_id tapi bukan milik kita -> lewati.
        }
        // Fallback ke nama HANYA kalau salah satu (submission atau akun kita
        // sendiri) tidak memiliki student_id sama sekali (mis. data lama).
        final sName = (s['student_name']?.toString() ?? '').trim().toLowerCase();
        if (sName.isNotEmpty && sName == cleanName) {
          return Map<String, dynamic>.from(s);
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> recordHomeworkSubmission(String hwId, String studentName, int score, int totalQuestions) async {
    final subs = await getHomeworkSubmissions(hwId);
    subs.insert(0, {
      'student_name': studentName,
      'score': score,
      'total_questions': totalQuestions,
      'submitted_at': DateTime.now().toIso8601String(),
      'status': 'Selesai',
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('hw_subs_$hwId', jsonEncode(subs));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getLiveQuizSubmissions(String quizId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final str = prefs.getString('live_quiz_subs_$quizId');
      if (str != null && str.isNotEmpty) {
        final List parsed = jsonDecode(str);
        return parsed.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    if (kIsWeb) {
      try {
        final str = html.window.localStorage['live_quiz_subs_$quizId'];
        if (str != null && str.isNotEmpty) {
          final List parsed = jsonDecode(str);
          return parsed.cast<Map<String, dynamic>>();
        }
      } catch (_) {}
    }
    return [];
  }

  static Future<void> recordLiveQuizSubmission(String quizId, String studentName, int score, int totalQuestions) async {
    final subs = await getLiveQuizSubmissions(quizId);
    subs.insert(0, {
      'student_name': studentName,
      'score': score,
      'total_questions': totalQuestions,
      'submitted_at': DateTime.now().toIso8601String(),
    });
    final jsonStr = jsonEncode(subs);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('live_quiz_subs_$quizId', jsonStr);
    } catch (_) {}
    if (kIsWeb) {
      try {
        html.window.localStorage['live_quiz_subs_$quizId'] = jsonStr;
      } catch (_) {}
    }
  }



  static const String _kLiveSessionInfoPrefix = 'live_session_info_';
  static final ValueNotifier<int> liveStatusNotifier = ValueNotifier<int>(0);

  static Future<void> saveLiveSessionInfo(String pin, Map<String, dynamic> sessionData) async {
    final str = jsonEncode(sessionData);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_kLiveSessionInfoPrefix$pin', str);
    } catch (_) {}
    if (kIsWeb) {
      try {
        html.window.localStorage['$_kLiveSessionInfoPrefix$pin'] = str;
      } catch (_) {}
    }
  }

  static Future<Map<String, dynamic>> getLiveSessionInfo(String pin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('$_kLiveSessionInfoPrefix$pin');
      if (str != null && str.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(str));
      }
    } catch (_) {}
    if (kIsWeb) {
      try {
        final str = html.window.localStorage['$_kLiveSessionInfoPrefix$pin'];
        if (str != null && str.isNotEmpty) {
          return Map<String, dynamic>.from(jsonDecode(str));
        }
      } catch (_) {}
    }
    return {};
  }

  static Future<void> markLiveQuizDone(String quizId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('live_done_$quizId', true);
    } catch (_) {}
    if (kIsWeb) {
      try {
        html.window.localStorage['live_done_$quizId'] = 'true';
      } catch (_) {}
    }
  }

  static Future<bool> hasLiveQuizBeenDone(String quizId) async {
    if (kIsWeb) {
      try {
        if (html.window.localStorage['live_done_$quizId'] == 'true') return true;
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = prefs.getBool('live_done_$quizId');
      if (done == true) return true;
    } catch (_) {}
    final subs = await getLiveQuizSubmissions(quizId);
    return subs.isNotEmpty;
  }

  static Future<void> reactivateQuizToBank(String quizId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('live_done_$quizId');
      await prefs.remove('live_quiz_subs_$quizId');
    } catch (_) {}
    if (kIsWeb) {
      try {
        html.window.localStorage.remove('live_done_$quizId');
        html.window.localStorage.remove('live_quiz_subs_$quizId');
      } catch (_) {}
    }
  }

  static Future<void> updateLiveSessionStatus(String pin, String status) async {
    final cleanPin = pin.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_kLiveSessionStatusPrefix$cleanPin', status);
      await prefs.setString('active_live_pin', cleanPin);
      await prefs.setString('active_live_status', status);
    } catch (_) {}
    if (kIsWeb) {
      try {
        html.window.localStorage['$_kLiveSessionStatusPrefix$cleanPin'] = status;
        html.window.localStorage['live_session_status_$cleanPin'] = status;
        html.window.localStorage['active_live_pin'] = cleanPin;
        html.window.localStorage['active_live_status'] = status;
      } catch (_) {}
    }
    try {
      final info = await getLiveSessionInfo(cleanPin);
      if (info.isNotEmpty) {
        info['status'] = status;
        await saveLiveSessionInfo(cleanPin, info);
      }
    } catch (_) {}

    // PENTING: dorong status ke BACKEND (bukan hanya localStorage device ini).
    // Ini yang membuat dosen & mahasiswa di perangkat/browser BERBEDA bisa
    // saling sinkron saat dosen menekan "Mulai Room Game Sekarang".
    try {
      await setServerSessionStatus(cleanPin, status);
    } catch (_) {}

    liveStatusNotifier.value++;
  }

  static Future<String> getLiveSessionStatus(String pin) async {
    final cleanPin = pin.trim();

    // 1) Sumber kebenaran UTAMA: tanya langsung ke backend (berlaku lintas
    // device). Kalau dosen di laptop menekan mulai, mahasiswa di HP lain
    // akan langsung mendapati status ini berubah menjadi 'active'.
    try {
      final res = await getServerSessionStatus(cleanPin);
      final serverStatus = (res['session_status'] ?? res['status'])?.toString();
      if (serverStatus != null && serverStatus.isNotEmpty) {
        if (serverStatus == 'active' || serverStatus == 'in_progress' || serverStatus == 'started') {
          return 'active';
        }
        if (serverStatus == 'waiting') return 'waiting';
      }
    } catch (_) {
      // backend tidak terjangkau -> lanjut ke fallback lokal di bawah
    }

    if (kIsWeb) {
      try {
        final st = html.window.localStorage['$_kLiveSessionStatusPrefix$cleanPin'];
        if (st != null && st.isNotEmpty) return st;
        final st2 = html.window.localStorage['live_session_status_$cleanPin'];
        if (st2 != null && st2.isNotEmpty) return st2;
        final activePin = html.window.localStorage['active_live_pin'];
        final activeSt = html.window.localStorage['active_live_status'];
        if (activePin == cleanPin && activeSt != null && activeSt.isNotEmpty) {
          return activeSt;
        }
      } catch (_) {}
    }
    try {
      final info = await getLiveSessionInfo(cleanPin);
      if (info['status'] != null && info['status'].toString().isNotEmpty) {
        return info['status'].toString();
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final st = prefs.getString('$_kLiveSessionStatusPrefix$cleanPin');
      if (st != null && st.isNotEmpty) return st;
      final activePin = prefs.getString('active_live_pin');
      final activeSt = prefs.getString('active_live_status');
      if (activePin == cleanPin && activeSt != null && activeSt.isNotEmpty) {
        return activeSt;
      }
    } catch (_) {}
    return 'waiting';
  }

  static Future<List<Map<String, dynamic>>> getLiveQuizHistory() async {
    final allQuizzesRes = await getMyQuizzes();
    final List quizzes = (allQuizzesRes['quizzes'] as List?) ?? [];
    List<Map<String, dynamic>> history = [];

    for (final q in quizzes) {
      final qId = q['id']?.toString() ?? '';
      final done = await hasLiveQuizBeenDone(qId);
      if (done) {
        history.add(Map<String, dynamic>.from(q));
      }
    }
    return history;
  }

  // ----------------------------------------------------------------------
  // FITUR FLASHCARDS BELAJAR — SEPENUHNYA LEWAT BACKEND (bukan localStorage)
  // supaya begitu dosen membuat/menambah flashcard baru, SEMUA mahasiswa di
  // perangkat manapun langsung melihatnya di halaman "Flashcards Belajar"
  // TANPA perlu kode/token/PIN apapun (endpoint publik berbasis is_public).
  // ----------------------------------------------------------------------
  static Future<List<Map<String, dynamic>>> getFlashcardSets() async {
    try {
      final classParam = currentClassId != null ? '?class_id=$currentClassId' : '';
      final res = await ApiService.get('/quizizz/flashcards$classParam');
      final List list = (res['flashcards'] as List?) ?? [];
      return list.map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['cards'] is! List) m['cards'] = [];
        return m;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, dynamic>> createFlashcardSet({
    required String title,
    required String subject,
    required List<Map<String, dynamic>> cards,
    bool isPublic = true,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/flashcards', {
        'title': title,
        'subject': subject,
        'cards': cards,
        'is_public': isPublic,
        if (currentClassId != null) 'class_id': currentClassId,
      });
      return Map<String, dynamic>.from(res['flashcard'] ?? {});
    } catch (e) {
      // Kembalikan pesan errornya (mis. payload terlalu besar) supaya UI
      // bisa memberi tahu dosen -- sebelumnya gagal ditelan diam-diam
      // sehingga flashcard TAMPAK tersimpan padahal sebenarnya tidak.
      return {'error': e.toString()};
    }
  }

  static Future<bool> updateFlashcardSet(String setId, {String? title, String? subject, List<Map<String, dynamic>>? cards}) async {
    try {
      final body = <String, dynamic>{};
      if (title != null) body['title'] = title;
      if (subject != null) body['subject'] = subject;
      if (cards != null) body['cards'] = cards;
      await ApiService.put('/quizizz/flashcards/$setId', body);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> deleteFlashcardSet(String setId) async {
    try {
      await ApiService.delete('/quizizz/flashcards/$setId');
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> duplicateFlashcardSet(String setId) async {
    try {
      final res = await ApiService.post('/quizizz/flashcards/$setId/duplicate', {});
      return Map<String, dynamic>.from(res['flashcard'] ?? {});
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------------------
  // PROGRES BELAJAR FLASHCARD (Kartu "Mastered" / "Perlu Diulang")
  // Disimpan ke BACKEND (bukan cuma di memori sesi belajar saat ini) supaya
  // indikasi per-kartu tetap muncul lagi lain kali mahasiswa membuka set
  // flashcard yang sama, baik di device yang sama maupun berbeda.
  // ----------------------------------------------------------------------
  static Future<void> saveFlashcardProgress(
    String flashcardId, {
    required List<int> masteredCards,
    required List<int> reviewNeededCards,
  }) async {
    try {
      await ApiService.post('/quizizz/flashcards/$flashcardId/progress', {
        'mastered_cards': masteredCards,
        'review_needed_cards': reviewNeededCards,
      });
    } catch (_) {
      // Jaringan bermasalah: progres tetap berlaku untuk sesi belajar saat
      // ini (di memori), hanya tidak tersimpan permanen kali ini.
    }
  }

  static Future<Map<String, List<int>>> getFlashcardProgress(String flashcardId) async {
    try {
      final res = await ApiService.get('/quizizz/flashcards/$flashcardId/progress');
      final progress = (res['progress'] as Map?) ?? {};
      final mastered = ((progress['mastered_cards'] as List?) ?? []).map((e) => int.tryParse(e.toString()) ?? -1).where((e) => e >= 0).toList();
      final review = ((progress['review_needed_cards'] as List?) ?? []).map((e) => int.tryParse(e.toString()) ?? -1).where((e) => e >= 0).toList();
      return {'mastered': mastered, 'review': review};
    } catch (_) {
      return {'mastered': <int>[], 'review': <int>[]};
    }
  }

  // ----------------------------------------------------------------------
  // FITUR PRESENTASI INTERAKTIF (LESSON MODE) — LEWAT BACKEND (bukan
  // localStorage) supaya benar-benar bisa dipakai lintas device: dosen
  // mengunggah slide dari satu perangkat, mahasiswa join dari perangkat lain
  // memakai kode/token, dan status/slide aktif tersinkron real-time.
  // ----------------------------------------------------------------------
  static Future<List<Map<String, dynamic>>> getLessons() async {
    try {
      final classParam = currentClassId != null ? '?class_id=$currentClassId' : '';
      final res = await ApiService.get('/quizizz/lessons/mine$classParam');
      final List list = (res['lessons'] as List?) ?? [];
      return list.map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['slides'] is! List) m['slides'] = [];
        return m;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, dynamic>> createLesson({
    required String title,
    required String description,
    required List<Map<String, dynamic>> slides,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/lessons', {
        'title': title,
        'description': description,
        'slides': slides,
        if (currentClassId != null) 'class_id': currentClassId,
      });
      return Map<String, dynamic>.from(res['lesson'] ?? {});
    } catch (e) {
      // Kembalikan info error (mis. payload kegedean) supaya UI bisa
      // memberi tahu dosen -- sebelumnya gagal ditelan diam-diam sehingga
      // presentasi tampak "menghilang" padahal memang tidak pernah tersimpan.
      return {'error': e.toString()};
    }
  }

  // Upload file .pptx ke backend untuk diekstrak SETIAP SLIDE ASLI-nya
  // (teks + gambar per slide, sesuai urutan asli PowerPoint, tanpa
  // kompresi apapun pada byte gambar) — dipakai fitur "Upload File PPT
  // Langsung" pada presentasi. Mengembalikan slide LENGKAP (bukan cuma
  // daftar gambar) supaya slide teks-tanpa-gambar tidak hilang.
  static Future<List<Map<String, dynamic>>?> extractSlidesFromPptx(List<int> fileBytes, String fileName) async {
    try {
      final res = await ApiService.postFile('/quizizz/lessons/extract-pptx', fileBytes, fileName);
      final List slides = (res['slides'] as List?) ?? [];
      if (slides.isNotEmpty) {
        return slides.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      // Fallback kompatibilitas kalau backend lama masih mengembalikan
      // 'images' saja (tanpa struktur slide lengkap).
      final List images = (res['images'] as List?) ?? [];
      return images.map((img) => {'title': 'Slide PPT', 'type': 'image', 'content': '', 'media_url': img}).toList();
    } catch (_) {
      return null;
    }
  }

  @Deprecated('Gunakan extractSlidesFromPptx supaya slide teks-tanpa-gambar tidak hilang dan urutan slide sesuai aslinya')
  static Future<List<String>?> extractImagesFromPptx(List<int> fileBytes, String fileName) async {
    try {
      final res = await ApiService.postFile('/quizizz/lessons/extract-pptx', fileBytes, fileName);
      final List images = (res['images'] as List?) ?? [];
      return images.map((e) => e.toString()).toList();
    } catch (_) {
      return null;
    }
  }

  // Fitur "Riwayat Presentasi" di Report: daftar semua sesi live yang
  // pernah dijalankan untuk SATU presentasi (kapan dijalankan, sudah
  // diakhiri atau belum, berapa respon/jawaban/pertanyaan Q&A masuk).
  static Future<List<Map<String, dynamic>>> getLessonSessionHistory(String lessonId) async {
    try {
      final res = await ApiService.get('/quizizz/lessons/$lessonId/sessions');
      final list = (res['sessions'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> deleteLesson(String lessonId) async {
    try {
      await ApiService.delete('/quizizz/lessons/$lessonId');
    } catch (_) {}
  }

  // Dosen membuat SESI LIVE dari sebuah presentasi -> dapat kode/token untuk
  // dibagikan ke mahasiswa (mirip "Mulai Live Host Gamifikasi" pada kuis).
  // Status awal selalu 'waiting' (server-side) supaya mahasiswa menunggu di
  // waiting room sampai dosen menekan "Start Presentation Now".
  static Future<Map<String, dynamic>> createLessonSession(String lessonId) async {
    try {
      final res = await ApiService.post('/quizizz/lessons/$lessonId/session', {});
      final s = Map<String, dynamic>.from(res['session'] ?? {});
      return {
        'id': s['id'],
        'lesson_id': s['lesson_id'],
        'code': s['session_code'],
        'status': s['status'] ?? 'waiting',
        'active_slide_index': s['active_slide_index'] ?? 0,
      };
    } catch (_) {
      return {};
    }
  }

  // Mahasiswa mengambil detail sesi (judul, deskripsi, seluruh slide, status,
  // slide aktif, dan respons) lewat kode/token yang diberikan dosen. Dipakai
  // untuk join awal MAUPUN untuk polling berkala (waiting room, layar slide
  // mahasiswa, dan pemantauan dosen) karena satu endpoint ini sudah
  // menyertakan semua data yang diperlukan sekaligus.
  static Future<Map<String, dynamic>?> getLessonSessionByCode(String code) async {
    try {
      final res = await ApiService.get('/quizizz/lessons/session/code/${code.trim()}', withAuth: false);
      final session = Map<String, dynamic>.from(res['session'] ?? {});
      final lesson = Map<String, dynamic>.from(res['lesson'] ?? {});
      return {
        'id': session['id'],
        // PENTING (perbaikan bug "soal aktif tidak muncul di mahasiswa"):
        // 'id' di atas adalah ID SESI live, BUKAN id lesson-nya. Sebelumnya
        // field lesson_id tidak pernah disertakan sama sekali di sini,
        // sehingga saat layar mahasiswa mencari bank soal (yang butuh
        // lesson_id), ia salah pakai ID sesi dan selalu dapat hasil kosong.
        'lesson_id': session['lesson_id'],
        'code': session['session_code'],
        'status': session['status'] ?? 'waiting',
        'active_slide_index': session['active_slide_index'] ?? 0,
        'active_question_id': session['active_question_id'],
        // Fitur "Aktifkan hingga 2 soal sekaligus" & "Timer soal": daftar
        // soal aktif (maks 2) beserta kapan tiap soal itu diaktifkan.
        'active_question_ids': (session['active_question_ids'] as List?)?.map((e) => e.toString()).toList() ?? [],
        'question_activated_at': Map<String, dynamic>.from(session['question_activated_at'] ?? {}),
        'activated_history': (session['activated_history'] as List?)?.map((e) => e.toString()).toList() ?? [],
        'responses': session['responses'] ?? [],
        'title': lesson['title'],
        'description': lesson['description'],
        'slides': lesson['slides'] ?? [],
      };
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------------------
  // FITUR "KELOLA SOAL PRESENTASI" (poin 2)
  // ----------------------------------------------------------------------
  // Dosen: tambah soal baru ke bank soal SATU presentasi (terpisah dari
  // slide -- baru tampil ke mahasiswa saat diaktifkan lewat activateQuestion).
  static Future<Map<String, dynamic>?> createLessonQuestion({
    required String lessonId,
    required String questionText,
    required List<String> options,
    String? correctAnswer,
    String questionType = 'multiple_choice',
    int? timeLimitSeconds = 30,
    // FITUR "Gambar di Soal & Jawaban Presentasi" (poin 4): gambar
    // pertanyaan (opsional) & gambar per-opsi jawaban (opsional, sejajar
    // index dengan `options` -- isi null di posisi yang tidak punya gambar).
    String? imageUrl,
    List<String?>? optionImages,
    String? variableCalcJson,
  }) async {
    try {
      final res = await ApiService.post('/quizizz/lessons/$lessonId/questions', {
        'question_text': questionText,
        'options': options,
        'correct_answer': correctAnswer,
        'question_type': questionType,
        'time_limit_seconds': timeLimitSeconds,
        'image_url': imageUrl,
        'option_images': optionImages,
        if (variableCalcJson != null) 'variable_calc_json': variableCalcJson,
      });
      return Map<String, dynamic>.from(res['question'] ?? {});
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getLessonQuestions(String lessonId) async {
    try {
      final res = await ApiService.get('/quizizz/lessons/$lessonId/questions', withAuth: false);
      final list = (res['questions'] as List?) ?? [];
      return list.map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['options'] is! List) {
          try {
            m['options'] = List<String>.from(m['options'] ?? []);
          } catch (_) {
            m['options'] = [];
          }
        }
        // Gambar per-opsi jawaban: pastikan selalu berupa List<String?>
        // sepanjang jumlah opsi, walau backend lama belum mengirim field ini.
        final opts = m['options'] as List;
        if (m['option_images'] is List) {
          final imgs = (m['option_images'] as List).map((e) => e?.toString()).toList();
          m['option_images'] = List<String?>.generate(opts.length, (i) => i < imgs.length ? imgs[i] : null);
        } else {
          m['option_images'] = List<String?>.filled(opts.length, null);
        }
        return m;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> deleteLessonQuestion(String questionId) async {
    try {
      await ApiService.delete('/quizizz/lessons/questions/$questionId');
    } catch (_) {}
  }

  // FITUR "Edit Soal Presentasi" (poin 4): update soal bank presentasi
  // yang sudah ada (bukan hapus lalu buat baru), termasuk gambar
  // pertanyaan & per-opsi jawabannya.
  static Future<bool> updateLessonQuestion({
    required String questionId,
    required String questionText,
    required List<String> options,
    String? correctAnswer,
    String questionType = 'multiple_choice',
    int? timeLimitSeconds = 30,
    String? imageUrl,
    List<String?>? optionImages,
    String? variableCalcJson,
  }) async {
    try {
      await ApiService.put('/quizizz/lessons/questions/$questionId', {
        'question_text': questionText,
        'options': options,
        'correct_answer': correctAnswer,
        'question_type': questionType,
        'time_limit_seconds': timeLimitSeconds,
        'image_url': imageUrl,
        'option_images': optionImages,
        if (variableCalcJson != null) 'variable_calc_json': variableCalcJson,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // Dosen: aktifkan soal terpilih saat presentasi live (maks 2 soal aktif
  // bersamaan) -- mahasiswa yang sedang polling akan otomatis melihat soal
  // ini dan bisa langsung jawab. Return pesan error kalau gagal (mis. sudah
  // ada 2 soal aktif), supaya UI bisa kasih tahu dosen alasannya.
  static Future<String?> activateLessonQuestion(String code, String questionId) async {
    try {
      await ApiService.patch('/quizizz/lessons/session/${code.trim()}/activate-question', {'question_id': questionId}, withAuth: false);
      return null; // sukses, tidak ada pesan error
    } catch (e) {
      return 'Maksimal 2 soal aktif bersamaan. Nonaktifkan salah satu dulu.';
    }
  }

  static Future<void> deactivateLessonQuestion(String code, {String? questionId}) async {
    try {
      await ApiService.patch('/quizizz/lessons/session/${code.trim()}/deactivate-question', {if (questionId != null) 'question_id': questionId}, withAuth: false);
    } catch (_) {}
  }

  // Fitur "Hasil nilai quiz presentasi muncul saat sesi berakhir": rekap
  // skor semua mahasiswa dari seluruh soal yang pernah diaktifkan sepanjang
  // sesi, diurutkan seperti papan peringkat.
  static Future<Map<String, dynamic>> getLessonFinalResults(String code) async {
    try {
      final res = await ApiService.get('/quizizz/lessons/session/${code.trim()}/final-results', withAuth: false);
      return {
        'total_questions_asked': res['total_questions_asked'] ?? 0,
        'total_students_participated': res['total_students_participated'] ?? 0,
        'leaderboard': ((res['leaderboard'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e)).toList(),
      };
    } catch (_) {
      return {'total_questions_asked': 0, 'total_students_participated': 0, 'leaderboard': []};
    }
  }

  // Fitur "Upload PDF untuk Presentasi": ekstrak teks tiap HALAMAN PDF jadi
  // satu slide per halaman (khusus teks -- PDF tidak mendukung ekstraksi
  // gambar per halaman seperti PPTX tanpa software konversi tambahan).
  static Future<List<Map<String, dynamic>>?> extractSlidesFromPdf(List<int> fileBytes, String fileName, {String resolution = '150'}) async {
    try {
      final res = await ApiService.postFile('/quizizz/lessons/extract-pdf', fileBytes, fileName, fields: {'resolution': resolution});
      final List slides = (res['slides'] as List?) ?? [];
      return slides.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return null;
    }
  }

  // Mahasiswa: jawab soal yang sedang aktif secara langsung (gamifikasi
  // digabung presentasi).
  static Future<bool> answerLessonQuestion(String code, {required String questionId, required String studentName, String? studentId, required dynamic answer, bool? isCorrect}) async {
    try {
      final res = await ApiService.post('/quizizz/lessons/session/${code.trim()}/answer-question', {
        'question_id': questionId,
        'student_name': studentName,
        'student_id': studentId,
        'answer': answer,
        if (isCorrect != null) 'is_correct': isCorrect,
      }, withAuth: false);
      return res['is_correct'] == true;
    } catch (_) {
      return false;
    }
  }

  // Dosen: hasil live jawaban soal yang sedang/pernah aktif (tally per
  // opsi + daftar yang sudah menjawab), dipoll berkala untuk papan skor.
  static Future<Map<String, dynamic>> getLessonQuestionResults(String code, String questionId) async {
    try {
      final res = await ApiService.get('/quizizz/lessons/session/${code.trim()}/question-results?question_id=$questionId', withAuth: false);
      return {
        'total_answers': res['total_answers'] ?? 0,
        'correct_count': res['correct_count'] ?? 0,
        'tally': Map<String, dynamic>.from(res['tally'] ?? {}),
        'answers': (res['answers'] as List?) ?? [],
      };
    } catch (_) {
      return {'total_answers': 0, 'correct_count': 0, 'tally': {}, 'answers': []};
    }
  }

  // ----------------------------------------------------------------------
  // FITUR "TANYA-JAWAB LIVE" (poin 3)
  // ----------------------------------------------------------------------
  // Mahasiswa: ajukan pertanyaan bebas selama presentasi berlangsung --
  // langsung muncul di halaman mahasiswa & dosen (dipoll berkala).
  static Future<bool> askLessonQuestion(String code, {
    required String studentName, 
    String? studentId, 
    required String message,
    String senderRole = 'student',
    bool isPrivate = false,
    String? toUserId,
    String? toUserName,
  }) async {
    try {
      await ApiService.post('/quizizz/lessons/session/${code.trim()}/ask', {
        'student_name': studentName,
        'student_id': studentId,
        'sender_name': studentName,
        'sender_id': studentId,
        'sender_role': senderRole,
        'message': message,
        'is_private': isPrivate,
        'to_user_id': toUserId,
        'to_user_name': toUserName,
      }, withAuth: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getLessonQaMessages(String code) async {
    try {
      final res = await ApiService.get('/quizizz/lessons/session/${code.trim()}/qa', withAuth: false);
      final list = (res['questions'] as List?) ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> markLessonQaAnswered(String code, String qaId) async {
    try {
      await ApiService.patch('/quizizz/lessons/session/${code.trim()}/qa/$qaId/mark-answered', {}, withAuth: false);
    } catch (_) {}
  }

  // Dosen: balas pertanyaan mahasiswa secara langsung (bukan cuma menandai
  // "sudah dijawab") -- balasan otomatis muncul di layar mahasiswa.
  static Future<bool> replyLessonQa(String code, String qaId, String reply, {
    String? senderName,
    String? senderId,
    String senderRole = 'teacher',
  }) async {
    try {
      await ApiService.post('/quizizz/lessons/session/${code.trim()}/qa/$qaId/reply', {
        'reply': reply,
        'sender_name': senderName,
        'sender_id': senderId,
        'sender_role': senderRole,
      }, withAuth: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Dosen mengubah status (waiting -> live, dipakai tombol "Start
  // Presentation Now") dan/atau slide yang sedang aktif.
  static Future<void> updateLessonSessionState(String code, {String? status, int? currentSlideIndex}) async {
    try {
      final body = <String, dynamic>{};
      if (status != null) body['status'] = status;
      if (currentSlideIndex != null) body['active_slide_index'] = currentSlideIndex;
      if (body.isEmpty) return;
      await ApiService.patch('/quizizz/lessons/session/${code.trim()}/state', body, withAuth: false);
    } catch (_) {}
  }

  // Polling status + slide aktif + respons (dipakai waiting room & layar
  // slide mahasiswa supaya tetap sinkron dengan kontrol dosen, dan oleh
  // dosen untuk memantau jawaban mahasiswa secara live).
  static Future<Map<String, dynamic>> getLessonSessionState(String code) async {
    final full = await getLessonSessionByCode(code);
    if (full == null) return {'status': 'waiting', 'active_slide_index': 0, 'responses': []};
    return {
      'status': full['status'] ?? 'waiting',
      'active_slide_index': full['active_slide_index'] ?? 0,
      'responses': full['responses'] ?? [],
    };
  }

  // Mahasiswa mengirim jawaban untuk slide bertipe kuis di tengah presentasi.
  static Future<void> submitLessonResponse(String code, {required int slideIndex, required String studentName, String? studentId, required dynamic answer}) async {
    try {
      await ApiService.post('/quizizz/lessons/session/${code.trim()}/respond', {
        'slide_index': slideIndex,
        'student_name': studentName,
        'student_id': studentId,
        'answer': answer,
      }, withAuth: false);
    } catch (_) {}
  }
}