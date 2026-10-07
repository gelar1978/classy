import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xls;

// Utility export dipakai di berbagai modul (Kahoot, Quizizz, dll)
// buat men-download leaderboard/hasil sebagai PDF atau Excel.
class ExportHelper {
  // ============ EXPORT KE PDF ============
  static Future<void> exportLeaderboardToPdf({
    required String title,
    required List<Map<String, dynamic>> rows, // tiap row: {rank, name, score}
  }) async {
    final doc = pw.Document();

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 16),
              pw.TableHelper.fromTextArray(
                headers: ['Peringkat', 'Nama', 'Skor'],
                data: rows.map((r) => [r['rank'].toString(), r['name'].toString(), r['score'].toString()]).toList(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                cellAlignment: pw.Alignment.centerLeft,
                headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
              ),
            ],
          );
        },
      ),
    );

    final bytes = await doc.save();
    await Printing.sharePdf(bytes: bytes, filename: '${_sanitize(title)}.pdf');
  }

  // ============ EXPORT KE EXCEL ============
  static void exportLeaderboardToExcel({
    required String title,
    required List<Map<String, dynamic>> rows,
  }) {
    final excel = xls.Excel.createExcel();
    final sheet = excel['Leaderboard'];
    excel.setDefaultSheet('Leaderboard');

    sheet.appendRow([
      xls.TextCellValue('Peringkat'),
      xls.TextCellValue('Nama'),
      xls.TextCellValue('Skor'),
    ]);

    for (final r in rows) {
      sheet.appendRow([
        xls.IntCellValue(r['rank'] is int ? r['rank'] : int.tryParse(r['rank'].toString()) ?? 0),
        xls.TextCellValue(r['name'].toString()),
        xls.IntCellValue(r['score'] is int ? r['score'] : int.tryParse(r['score'].toString()) ?? 0),
      ]);
    }

    final bytes = excel.save();
    if (bytes == null) return;

    final blob = html.Blob([Uint8List.fromList(bytes)]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', '${_sanitize(title)}.xlsx')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  // ============ EXPORT KE CSV ============
  static void exportCsv({
    required String filename,
    required String content,
  }) {
    final bytes = utf8.encode(content);
    final blob = html.Blob([Uint8List.fromList(bytes)], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  static void pickFileWeb(Function(String filename, String contentText) onSelected, {String accept = '.pptx,.ppt,.pdf,.png,.jpg,.txt'}) {
    final uploadInput = html.FileUploadInputElement()..accept = accept;
    uploadInput.click();
    uploadInput.onChange.listen((e) {
      final files = uploadInput.files;
      if (files != null && files.isNotEmpty) {
        final file = files[0];
        final reader = html.FileReader();
        reader.readAsText(file);
        reader.onLoadEnd.listen((_) {
          final text = reader.result?.toString() ?? '';
          onSelected(file.name, text);
        });
      }
    });
  }

  static void pickImageWeb(Function(String base64Data) onSelected) {
    final uploadInput = html.FileUploadInputElement()..accept = 'image/*';
    uploadInput.click();
    uploadInput.onChange.listen((e) {
      final files = uploadInput.files;
      if (files != null && files.isNotEmpty) {
        final file = files[0];
        final reader = html.FileReader();
        reader.readAsDataUrl(file);
        reader.onLoadEnd.listen((_) {
          final result = reader.result?.toString() ?? '';
          onSelected(result);
        });
      }
    });
  }

  // ============ UNDUH TEMPLATE SOAL EXCEL ============
  static void downloadQuestionsTemplateExcel({String title = 'Template_Soal_Kuis'}) {
    final excel = xls.Excel.createExcel();
    const sheetName = 'Template Soal';
    final sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);

    // Header Kolom
    sheet.appendRow([
      xls.TextCellValue('No'),
      xls.TextCellValue('Pertanyaan'),
      xls.TextCellValue('Tipe Soal (Pilihan Ganda / Benar / Salah / Multi-Select / Jawaban Singkat)'),
      xls.TextCellValue('Pilihan A'),
      xls.TextCellValue('Pilihan B'),
      xls.TextCellValue('Pilihan C'),
      xls.TextCellValue('Pilihan D'),
      xls.TextCellValue('Kunci Jawaban (A/B/C/D atau Benar/Salah atau A,C atau teks isian)'),
      xls.TextCellValue('Timer Detik (10/20/30/60)'),
      xls.TextCellValue('Hitung Variabel (Ya / Tidak)'),
      xls.TextCellValue('Jumlah Variabel (1-5)'),
      xls.TextCellValue('Rentang Variabel a (contoh: 1-10)'),
      xls.TextCellValue('Rentang Variabel b (contoh: 1-10)'),
      xls.TextCellValue('Rentang Variabel c (contoh: 1-10)'),
    ]);

    // Contoh Soal 1: Pilihan Ganda Biasa
    sheet.appendRow([
      xls.IntCellValue(1),
      xls.TextCellValue('Ibu kota negara Indonesia saat ini adalah?'),
      xls.TextCellValue('Pilihan Ganda'),
      xls.TextCellValue('Jakarta'),
      xls.TextCellValue('Bandung'),
      xls.TextCellValue('Surabaya'),
      xls.TextCellValue('Medan'),
      xls.TextCellValue('A'),
      xls.IntCellValue(30),
      xls.TextCellValue('Tidak'),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
    ]);

    // Contoh Soal 2: Variable Calculations / Rumus Matriks & Aljabar
    sheet.appendRow([
      xls.IntCellValue(2),
      xls.TextCellValue('Jika a = [a], b = [b], c = [c], tentukan matriks R = [1+[a] b-1 c^2]:'),
      xls.TextCellValue('Pilihan Ganda'),
      xls.TextCellValue('[1+[a] [b]-1 [c]^2]'),
      xls.TextCellValue('[2+[a] [b]-1 [c]^2]'),
      xls.TextCellValue('[1+[a] [b]+1 [c]^2]'),
      xls.TextCellValue('[1+[a] [b]-1 [c]^3]'),
      xls.TextCellValue('A'),
      xls.IntCellValue(30),
      xls.TextCellValue('Ya'),
      xls.IntCellValue(3),
      xls.TextCellValue('1-10'),
      xls.TextCellValue('1-10'),
      xls.TextCellValue('1-10'),
    ]);

    // Contoh Soal 3: Benar / Salah
    sheet.appendRow([
      xls.IntCellValue(3),
      xls.TextCellValue('Matahari terbit dari arah timur dan terbenam di barat.'),
      xls.TextCellValue('Benar / Salah'),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue('Benar'),
      xls.IntCellValue(20),
      xls.TextCellValue('Tidak'),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
    ]);

    // Contoh Soal 4: Multi-Select (Centang Banyak)
    sheet.appendRow([
      xls.IntCellValue(4),
      xls.TextCellValue('Manakah bilangan di bawah ini yang merupakan bilangan prima?'),
      xls.TextCellValue('Multi-Select'),
      xls.TextCellValue('2'),
      xls.TextCellValue('3'),
      xls.TextCellValue('4'),
      xls.TextCellValue('5'),
      xls.TextCellValue('A,B,D'),
      xls.IntCellValue(30),
      xls.TextCellValue('Tidak'),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
    ]);

    // Contoh Soal 5: Jawaban Singkat (Isian)
    sheet.appendRow([
      xls.IntCellValue(5),
      xls.TextCellValue('Planet terbesar di tata surya kita adalah planet...'),
      xls.TextCellValue('Jawaban Singkat'),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue('Yupiter'),
      xls.IntCellValue(30),
      xls.TextCellValue('Tidak'),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
    ]);

    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    final bytes = excel.save();
    if (bytes == null) return;

    final blob = html.Blob([Uint8List.fromList(bytes)]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', '${_sanitize(title)}_Template.xlsx')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  // ============ UPLOAD & PARSE SOAL DARI EXCEL ============
  static void pickFileBytesWeb(Function(String filename, Uint8List bytes) onSelected, {String accept = '.xlsx,.xls'}) {
    final uploadInput = html.FileUploadInputElement()..accept = accept;
    uploadInput.click();
    uploadInput.onChange.listen((e) {
      final files = uploadInput.files;
      if (files != null && files.isNotEmpty) {
        final file = files[0];
        final reader = html.FileReader();
        reader.readAsArrayBuffer(file);
        reader.onLoadEnd.listen((_) {
          final result = reader.result;
          if (result is Uint8List) {
            onSelected(file.name, result);
          } else if (result is List<int>) {
            onSelected(file.name, Uint8List.fromList(result));
          } else if (result is ByteBuffer) {
            onSelected(file.name, result.asUint8List());
          }
        });
      }
    });
  }

  static String _cellValToString(xls.Data? cell) {
    if (cell == null || cell.value == null) return '';
    final val = cell.value;
    if (val is xls.TextCellValue) return val.value.toString().trim();
    if (val is xls.IntCellValue) return val.value.toString().trim();
    if (val is xls.DoubleCellValue) {
      if (val.value % 1 == 0) return val.value.toInt().toString();
      return val.value.toString().trim();
    }
    if (val is xls.BoolCellValue) return val.value ? 'Ya' : 'Tidak';
    return val.toString().trim();
  }

  static List<Map<String, dynamic>> parseQuestionsFromExcel(Uint8List bytes, {int? defaultTimer = 30}) {
    final List<Map<String, dynamic>> result = [];
    try {
      final excel = xls.Excel.decodeBytes(bytes);
      for (final table in excel.tables.keys) {
        final rows = excel.tables[table]?.rows;
        if (rows == null || rows.length <= 1) continue;

        // Mulai dari baris ke-2 (index 1) untuk melewati header
        for (int r = 1; r < rows.length; r++) {
          final row = rows[r];
          if (row.isEmpty) continue;

          String qText = row.length > 1 ? _cellValToString(row[1]) : '';
          if (qText.isEmpty) {
            // Coba periksa kolom 0 kalau kolom 1 kosong
            qText = row.isNotEmpty ? _cellValToString(row[0]) : '';
            if (qText.isEmpty || qText.toLowerCase() == 'no' || qText.toLowerCase() == 'pertanyaan') continue;
          }

          final typeRaw = (row.length > 2 ? _cellValToString(row[2]) : '').toLowerCase();
          String optA = row.length > 3 ? _cellValToString(row[3]) : '';
          String optB = row.length > 4 ? _cellValToString(row[4]) : '';
          String optC = row.length > 5 ? _cellValToString(row[5]) : '';
          String optD = row.length > 6 ? _cellValToString(row[6]) : '';
          final correctRaw = row.length > 7 ? _cellValToString(row[7]) : '';
          final timerStr = row.length > 8 ? _cellValToString(row[8]) : '';
          final isVarStr = (row.length > 9 ? _cellValToString(row[9]) : '').toLowerCase();
          final varCountStr = row.length > 10 ? _cellValToString(row[10]) : '';

          String selectedType = 'multiple_choice';
          if (typeRaw.contains('benar') || typeRaw.contains('salah') || typeRaw.contains('true') || typeRaw.contains('false')) {
            selectedType = 'true_false';
          } else if (typeRaw.contains('multi')) {
            selectedType = 'multi_select';
          } else if (typeRaw.contains('singkat') || typeRaw.contains('short') || typeRaw.contains('isian')) {
            selectedType = 'short_answer';
          }

          int? timerSeconds = defaultTimer;
          if (timerStr.isNotEmpty) {
            final parsedTimer = int.tryParse(timerStr);
            if (parsedTimer != null && parsedTimer > 0) {
              timerSeconds = parsedTimer;
            }
          }

          List<String> options = [];
          String correctVal = '';
          List<String>? correctListVal;

          if (selectedType == 'multiple_choice') {
            options = [
              optA.isEmpty ? 'Opsi A' : optA,
              optB.isEmpty ? 'Opsi B' : optB,
              optC.isEmpty ? 'Opsi C' : optC,
              optD.isEmpty ? 'Opsi D' : optD,
            ];
            final kUpper = correctRaw.trim().toUpperCase();
            if (kUpper == 'A') {
              correctVal = options[0];
            } else if (kUpper == 'B') {
              correctVal = options[1];
            } else if (kUpper == 'C') {
              correctVal = options[2];
            } else if (kUpper == 'D') {
              correctVal = options[3];
            } else if (options.contains(correctRaw)) {
              correctVal = correctRaw;
            } else {
              correctVal = options[0];
            }
          } else if (selectedType == 'true_false') {
            options = ['Benar', 'Salah'];
            final kUpper = correctRaw.trim().toUpperCase();
            if (kUpper == 'SALAH' || kUpper == 'FALSE' || kUpper == 'B') {
              correctVal = 'Salah';
            } else {
              correctVal = 'Benar';
            }
          } else if (selectedType == 'multi_select') {
            options = [
              optA.isEmpty ? 'Opsi A' : optA,
              optB.isEmpty ? 'Opsi B' : optB,
              optC.isEmpty ? 'Opsi C' : optC,
              optD.isEmpty ? 'Opsi D' : optD,
            ];
            final parts = correctRaw.split(RegExp(r'[,;]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            final List<String> matched = [];
            for (final p in parts) {
              final pUpper = p.toUpperCase();
              if (pUpper == 'A') {
                matched.add(options[0]);
              } else if (pUpper == 'B') {
                matched.add(options[1]);
              } else if (pUpper == 'C') {
                matched.add(options[2]);
              } else if (pUpper == 'D') {
                matched.add(options[3]);
              } else if (options.contains(p)) {
                matched.add(p);
              }
            }
            if (matched.isEmpty) matched.add(options[0]);
            correctListVal = matched;
            correctVal = matched.first;
          } else if (selectedType == 'short_answer') {
            options = [];
            correctVal = correctRaw.trim();
          }

          // Variable Calculations check
          String? variableCalcJson;
          final bool isVarCalc = isVarStr.contains('ya') || isVarStr.contains('yes') || isVarStr.contains('true') || isVarStr == '1';
          if (isVarCalc) {
            selectedType = 'multiple_choice';
            int count = int.tryParse(varCountStr) ?? 3;
            if (count < 1) count = 1;
            if (count > 5) count = 5;

            final varNames = ['a', 'b', 'c', 'd', 'e'];
            List<Map<String, dynamic>> vars = [];
            for (int i = 0; i < count; i++) {
              final colIdx = 11 + i;
              final rangeStr = colIdx < row.length ? _cellValToString(row[colIdx]) : '';
              int minVal = 1;
              int maxVal = 10;
              if (rangeStr.isNotEmpty) {
                final splitRange = rangeStr.split(RegExp(r'[-:,_]'));
                if (splitRange.length >= 2) {
                  minVal = int.tryParse(splitRange[0].trim()) ?? 1;
                  maxVal = int.tryParse(splitRange[1].trim()) ?? 10;
                } else if (splitRange.length == 1) {
                  maxVal = int.tryParse(splitRange[0].trim()) ?? 10;
                }
              }
              vars.add({
                'name': varNames[i],
                'min': minVal,
                'max': maxVal,
              });
            }

            int correctIdx = 0;
            final kUpper = correctRaw.trim().toUpperCase();
            if (kUpper == 'B') {
              correctIdx = 1;
            } else if (kUpper == 'C') {
              correctIdx = 2;
            } else if (kUpper == 'D') {
              correctIdx = 3;
            } else if (options.contains(correctRaw)) {
              correctIdx = options.indexOf(correctRaw);
            }

            variableCalcJson = jsonEncode({
              'count': count,
              'variables': vars,
              'correct_index': correctIdx,
            });
            options = [
              optA.isEmpty ? 'Opsi A' : optA,
              optB.isEmpty ? 'Opsi B' : optB,
              optC.isEmpty ? 'Opsi C' : optC,
              optD.isEmpty ? 'Opsi D' : optD,
            ];
            correctVal = options[correctIdx];
          }

          result.add({
            'question': qText,
            'type': selectedType,
            'options': options,
            'correct': correctVal,
            'correct_list': correctListVal,
            'image_url': null,
            'option_images': null,
            'timer_seconds': timerSeconds,
            if (variableCalcJson != null) 'variable_calc_json': variableCalcJson,
          });
        }
        if (result.isNotEmpty) break;
      }
    } catch (_) {}
    return result;
  }

  // ============ EXPORT REKAP NILAI (GRADEBOOK) KE EXCEL ============
  static void exportGradebookToExcel({
    required String className,
    required List<Map<String, dynamic>> students,
    required List<Map<String, dynamic>> assessments,
    required Map<String, dynamic> grades,
  }) {
    final excel = xls.Excel.createExcel();
    final sheetName = 'Rekap Nilai';
    final sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);

    // Header baris
    List<xls.CellValue> headers = [
      xls.TextCellValue('No.'),
      xls.TextCellValue('NIM'),
      xls.TextCellValue('Nama Mahasiswa'),
    ];
    for (final a in assessments) {
      headers.add(xls.TextCellValue(a['title']?.toString() ?? 'Penilaian'));
    }
    headers.add(xls.TextCellValue('Rata-rata'));
    headers.add(xls.TextCellValue('Catatan'));
    sheet.appendRow(headers);

    // Baris data per mahasiswa
    for (final s in students) {
      final sId = s['student_id']?.toString() ?? s['id']?.toString() ?? '';
      final studentGrades = (grades[sId] as Map?) ?? {};

      List<xls.CellValue> row = [
        xls.IntCellValue(s['no'] is int ? s['no'] : int.tryParse(s['no'].toString()) ?? 0),
        xls.TextCellValue(s['nim']?.toString() ?? '-'),
        xls.TextCellValue(s['name']?.toString() ?? s['full_name']?.toString() ?? '-'),
      ];

      double sum = 0;
      int count = 0;
      List<String> studentNotes = [];

      for (final a in assessments) {
        final aId = a['id']?.toString() ?? '';
        final g = studentGrades[aId];
        final score = g?['score'];
        final note = g?['notes'];

        if (score != null) {
          final numVal = (score is num) ? score.toDouble() : (double.tryParse(score.toString()) ?? 0.0);
          row.add(xls.DoubleCellValue(numVal));
          sum += numVal;
          count++;
        } else if (note != null && note.toString().isNotEmpty) {
          row.add(xls.TextCellValue(note.toString()));
          studentNotes.add('${a['title']}: $note');
        } else {
          row.add(xls.TextCellValue('-'));
        }
      }

      // Rata-rata
      if (count > 0) {
        final avg = sum / count;
        row.add(xls.DoubleCellValue(double.parse(avg.toStringAsFixed(2))));
      } else {
        row.add(xls.TextCellValue('-'));
      }

      // Catatan
      row.add(xls.TextCellValue(studentNotes.join('; ')));
      sheet.appendRow(row);
    }

    final bytes = excel.save();
    if (bytes == null) return;

    final blob = html.Blob([Uint8List.fromList(bytes)]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', '${_sanitize(className)}_Rekap_Nilai.xlsx')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  // ============ EXPORT PRESENSI KE EXCEL ============
  static void exportAttendanceToExcel({
    required String sessionTitle,
    required List<Map<String, dynamic>> attendees,
  }) {
    final excel = xls.Excel.createExcel();
    final sheetName = 'Presensi';
    final sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);

    sheet.appendRow([
      xls.TextCellValue('No.'),
      xls.TextCellValue('NIM'),
      xls.TextCellValue('Nama Mahasiswa'),
      xls.TextCellValue('Status Kehadiran'),
      xls.TextCellValue('Waktu Presensi'),
      xls.TextCellValue('Keterangan'),
    ]);

    for (final a in attendees) {
      final status = (a['status']?.toString() ?? 'belum_hadir').toUpperCase();
      final timeStr = a['attended_at']?.toString() ?? '-';
      final noteStr = a['notes']?.toString() ?? '';

      sheet.appendRow([
        xls.IntCellValue(a['no'] is int ? a['no'] : int.tryParse(a['no'].toString()) ?? 0),
        xls.TextCellValue(a['nim']?.toString() ?? '-'),
        xls.TextCellValue(a['student_name']?.toString() ?? a['name']?.toString() ?? '-'),
        xls.TextCellValue(status),
        xls.TextCellValue(timeStr),
        xls.TextCellValue(noteStr),
      ]);
    }

    final bytes = excel.save();
    if (bytes == null) return;

    final blob = html.Blob([Uint8List.fromList(bytes)]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', '${_sanitize(sessionTitle)}.xlsx')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  static String _sanitize(String text) {
    return text.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }
}