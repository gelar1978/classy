import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math';
import 'dart:typed_data';
import 'package:math_expressions/math_expressions.dart' hide Stack, Column, Row;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'chat_panel.dart';
import 'gradebook_tab.dart';
import 'attendance_tab.dart';

import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/quizizz_service.dart';
import '../../services/socket_service.dart';
import '../../widgets/session_qr_code.dart';
import '../../utils/export_helper.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

double _evaluateScalarExpr(String exprStr, ContextModel cm, [Map<String, double>? directVars]) {
  String clean = exprStr.trim();
  if (clean.isEmpty) return 0.0;
  
  if (directVars != null) {
    directVars.forEach((k, v) {
      final formatted = _formatEvaluatedNumber(v);
      clean = clean.replaceAll(RegExp(r'\[' + RegExp.escape(k) + r'\]', caseSensitive: false), formatted);
      clean = clean.replaceAll(RegExp(r'\b' + RegExp.escape(k) + r'\b', caseSensitive: false), formatted);
    });
  }
  
  // Replace any leftover brackets [ ... ] with parentheses ( ... ) so math_expressions treats them as arithmetic groupings
  clean = clean.replaceAll('[', '(').replaceAll(']', ')');
  
  // Implicit multiplication: 2a -> 2*a, 2(3) -> 2*(3), (2)(3) -> (2)*(3)
  clean = clean.replaceAllMapped(RegExp(r'(\d+)\s*([a-zA-Z])'), (m) => '${m.group(1)}*${m.group(2)}');
  clean = clean.replaceAllMapped(RegExp(r'(\d+)\s*\('), (m) => '${m.group(1)}*(');
  clean = clean.replaceAllMapped(RegExp(r'\)\s*(\d+)'), (m) => ')*${m.group(1)}');
  clean = clean.replaceAllMapped(RegExp(r'\)\s*\('), (m) => ')*(');
  
  try {
    Parser p = Parser();
    Expression exp = p.parse(clean);
    final res = exp.evaluate(EvaluationType.REAL, cm);
    if (res is num) return res.toDouble();
  } catch (e) {
    debugPrint('Scalar eval error on "$clean": $e');
  }
  return 0.0;
}

String _formatEvaluatedNumber(double n) {
  if (n.isInfinite || n.isNaN) return '0';
  if (n == n.roundToDouble()) {
    return n.toInt().toString();
  }
  return n.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
}

String _evaluateOptionFormula(String optFormula, ContextModel cm, Map<String, double> varValues) {
  String f = optFormula.trim();
  if (f.isEmpty) return '';

  // Clean leading assignment like x = or ans =
  f = f.replaceFirst(RegExp(r'^(?:hitung\s+)?(?:[a-zA-Z_][a-zA-Z0-9_]*\s*=\s*)?', caseSensitive: false), '').trim();

  // Check if Matrix / Vector format: contains [ ... ]
  String matrixInner = '';
  bool isMatrix = false;
  if (f.startsWith('[') && f.endsWith(']')) {
    matrixInner = f.substring(1, f.length - 1).trim();
    isMatrix = true;
  } else if (f.contains('[') && f.contains(']')) {
    final m = RegExp(r'\[([^\]]+)\]').firstMatch(f);
    if (m != null) {
      matrixInner = m.group(1)!.trim();
      isMatrix = true;
    }
  }

  if (isMatrix) {
    List<String> rawRows = matrixInner.split(';');
    List<List<double>> matrixValues = [];
    bool useComma = matrixInner.contains(',');

    for (var r in rawRows) {
      r = r.trim();
      List<String> tokens;
      if (r.contains(',')) {
        tokens = r.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else {
        tokens = r.split(RegExp(r'\s+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      List<double> rowVals = [];
      for (var tok in tokens) {
        rowVals.add(_evaluateScalarExpr(tok, cm, varValues));
      }
      matrixValues.add(rowVals);
    }

    final rowsStr = matrixValues.map((row) {
      final sep = useComma ? ', ' : '  ';
      return row.map((v) => _formatEvaluatedNumber(v)).join(sep);
    }).join('; ');
    return '[$rowsStr]';
  }

  // Otherwise, evaluate as scalar
  final evalResult = _evaluateScalarExpr(f, cm, varValues);
  return _formatEvaluatedNumber(evalResult);
}

Map<String, dynamic> processVariableCalculations(
  Map<String, dynamic> rawQ, {
  required String studentIdentifier,
  int questionIndex = 0,
}) {
  final q = Map<String, dynamic>.from(rawQ);
  final varCalcRaw = q['variable_calc_json'];
  
  Map<String, dynamic> vData = {};
  if (varCalcRaw != null &&
      varCalcRaw.toString().trim().isNotEmpty &&
      varCalcRaw.toString() != 'null') {
    try {
      vData = (varCalcRaw is Map)
          ? Map<String, dynamic>.from(varCalcRaw)
          : jsonDecode(varCalcRaw.toString());
    } catch (_) {}
  }

  String processedText = (q['question'] ?? q['question_text'] ?? '').toString();
  final optsRaw = (q['options'] as List?)?.map((e) => e.toString()).toList() ?? [];
  final bool hasAutoOptions = optsRaw.any((o) => o.contains('[Opsi') || o.contains('Otomatis'));

  List vars = vData['variables'] as List? ?? [];
  String formulaStr = (vData['formula'] ?? '').toString().trim();

  // Fallback: If variables are empty, auto-detect [a], [b], [c], etc. from question text and options
  if (vars.isEmpty) {
    final allText = '$processedText ${optsRaw.join(' ')}';
    final matches = RegExp(r'\[\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\]').allMatches(allText);
    final detectedNames = matches.map((m) => m.group(1)!).toSet().toList();
    if (detectedNames.isNotEmpty) {
      vars = detectedNames.map((name) => {'name': name, 'min': 1, 'max': 10}).toList();
    }
  }

  if (vars.isEmpty && formulaStr.isEmpty && varCalcRaw == null && !hasAutoOptions) {
    return q;
  }

  try {
    final qIdStr = q['id']?.toString() ?? '$questionIndex';
    final seed = (studentIdentifier.hashCode ^ qIdStr.hashCode) & 0x7FFFFFFF;
    final rnd = Random(seed);

    ContextModel cm = ContextModel();
    Map<String, double> varValues = {};

    for (final v in vars) {
      final vName = (v['name'] ?? '').toString().trim();
      if (vName.isEmpty) continue;
      final vMin = (v['min'] is int)
          ? v['min'] as int
          : (int.tryParse('${v['min']}') ?? 1);
      final vMax = (v['max'] is int)
          ? v['max'] as int
          : (int.tryParse('${v['max']}') ?? 10);
      final range = (vMax - vMin + 1).clamp(1, 999999);
      final val = vMin + rnd.nextInt(range);

      final valDouble = val.toDouble();
      varValues[vName] = valDouble;
      cm.bindVariable(Variable(vName), Number(valDouble));
      cm.bindVariable(Variable(vName.toLowerCase()), Number(valDouble));
      cm.bindVariable(Variable(vName.toUpperCase()), Number(valDouble));

      processedText = processedText.replaceAll(
        RegExp(r'\[\s*' + RegExp.escape(vName) + r'\s*\]', caseSensitive: false),
        val.toString(),
      );
    }

    // CASE 1: Teacher wrote formulas directly into each option (A, B, C, D)
    final bool hasCustomOptionFormulas = optsRaw.isNotEmpty && !hasAutoOptions;
    if (hasCustomOptionFormulas) {
      // Determine which option index is marked correct
      int correctIdx = 0;
      if (vData['correct_index'] is int) {
        correctIdx = (vData['correct_index'] as int).clamp(0, optsRaw.length - 1);
      } else {
        final rawCorrect = (q['correct'] ?? q['correct_answer'] ?? '').toString().trim();
        final letterIdx = ['A', 'B', 'C', 'D'].indexOf(rawCorrect.toUpperCase());
        if (letterIdx >= 0 && letterIdx < optsRaw.length) {
          correctIdx = letterIdx;
        } else {
          final found = optsRaw.indexOf(rawCorrect);
          if (found >= 0) correctIdx = found;
        }
      }

      List<String> evaluatedOptions = [];
      for (int i = 0; i < optsRaw.length; i++) {
        final optStr = optsRaw[i];
        if (optStr.contains('[') || optStr.contains('+') || optStr.contains('-') || optStr.contains('*') || optStr.contains('/') || optStr.contains('^') || varValues.keys.any((k) => optStr.contains(k))) {
          evaluatedOptions.add(_evaluateOptionFormula(optStr, cm, varValues));
        } else {
          evaluatedOptions.add(optStr);
        }
      }

      final correctValStr = (correctIdx < evaluatedOptions.length) ? evaluatedOptions[correctIdx] : (evaluatedOptions.isNotEmpty ? evaluatedOptions.first : '');

      q['question'] = processedText;
      q['question_text'] = processedText;
      q['type'] = 'multiple_choice';
      q['question_type'] = 'multiple_choice';
      q['options'] = evaluatedOptions;
      q['options_json'] = jsonEncode(evaluatedOptions);
      q['correct'] = correctValStr;
      q['correct_answer'] = correctValStr;
      q['is_variable_calculated'] = true;
      return q;
    }

    // CASE 2: Legacy / Single formula with auto-distractor generation
    if (formulaStr.isEmpty) {
      final eqMatch = RegExp(r'(?:[a-zA-Z_][a-zA-Z0-9_]*\s*=\s*)([^,\n\r]+)').firstMatch(processedText);
      final matrixMatch = RegExp(r'(\[[^\]]+\])').firstMatch(processedText);
      if (eqMatch != null) {
        formulaStr = eqMatch.group(1)!.trim();
      } else if (matrixMatch != null) {
        formulaStr = matrixMatch.group(1)!.trim();
      }
    }

    String f = formulaStr.trim();
    f = f.replaceFirst(RegExp(r'^(?:hitung\s+)?(?:[a-zA-Z_][a-zA-Z0-9_]*\s*=\s*)?', caseSensitive: false), '').trim();

    // Check if Matrix / Vector format: contains [ ... ]
    String matrixInner = '';
    bool isMatrix = false;
    if (f.startsWith('[') && f.endsWith(']')) {
      matrixInner = f.substring(1, f.length - 1).trim();
      isMatrix = true;
    } else if (f.contains('[') && f.contains(']')) {
      final m = RegExp(r'\[([^\]]+)\]').firstMatch(f);
      if (m != null) {
        matrixInner = m.group(1)!.trim();
        isMatrix = true;
      }
    }

    if (isMatrix) {
      List<String> rawRows = matrixInner.split(';');
      List<List<double>> matrixValues = [];
      bool useComma = matrixInner.contains(',');

      for (var r in rawRows) {
        r = r.trim();
        List<String> tokens;
        if (r.contains(',')) {
          tokens = r.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        } else {
          tokens = r.split(RegExp(r'\s+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        }
        List<double> rowVals = [];
        for (var tok in tokens) {
          rowVals.add(_evaluateScalarExpr(tok, cm, varValues));
        }
        matrixValues.add(rowVals);
      }

      String formatMatrix(List<List<double>> m) {
        final rowsStr = m.map((row) {
          final sep = useComma ? ', ' : '  ';
          return row.map((v) => _formatEvaluatedNumber(v)).join(sep);
        }).join('; ');
        return '[$rowsStr]';
      }

      final correctMatrixStr = formatMatrix(matrixValues);
      final Set<String> matrixOptions = {correctMatrixStr};

      int attempts = 0;
      while (matrixOptions.length < 4 && attempts < 50) {
        attempts++;
        List<List<double>> wrongM = matrixValues.map((row) => List<double>.from(row)).toList();
        int rIdx = rnd.nextInt(wrongM.length);
        int cIdx = rnd.nextInt(wrongM[rIdx].length);
        double delta = ((attempts % 3) + 1).toDouble() * (rnd.nextBool() ? 1 : -1);
        wrongM[rIdx][cIdx] += delta;
        final wrongStr = formatMatrix(wrongM);
        matrixOptions.add(wrongStr);
      }
      int fallbackK = 1;
      while (matrixOptions.length < 4) {
        List<List<double>> wrongM = matrixValues.map((row) => List<double>.from(row)).toList();
        wrongM[0][0] += fallbackK;
        matrixOptions.add(formatMatrix(wrongM));
        fallbackK++;
      }

      final optionsList = matrixOptions.toList();
      optionsList.shuffle(rnd);

      q['question'] = processedText;
      q['question_text'] = processedText;
      q['type'] = 'multiple_choice';
      q['question_type'] = 'multiple_choice';
      q['options'] = optionsList;
      q['options_json'] = jsonEncode(optionsList);
      q['correct'] = correctMatrixStr;
      q['correct_answer'] = correctMatrixStr;
      q['is_variable_calculated'] = true;
      return q;
    }

    // Otherwise, standard scalar
    final evalResult = _evaluateScalarExpr(f, cm, varValues);
    final correctValStr = _formatEvaluatedNumber(evalResult);
    final Set<String> optionsSet = {correctValStr};

    double step = 1.0;
    final absVal = evalResult.abs();
    if (absVal >= 100) step = 5.0;
    else if (absVal >= 50) step = 2.0;
    else if (absVal < 5 && evalResult != evalResult.roundToDouble()) step = 0.5;

    final deltas = [step, -step, step * 2, -step * 2, step * 3, -step * 3, step * 4, -step * 4, step * 5, -step * 5];
    deltas.shuffle(rnd);

    for (final d in deltas) {
      if (optionsSet.length >= 4) break;
      final wrongStr = _formatEvaluatedNumber(evalResult + d);
      if (wrongStr != correctValStr) optionsSet.add(wrongStr);
    }

    int fallbackK = 1;
    while (optionsSet.length < 4) {
      final wrongStr = _formatEvaluatedNumber(evalResult + (fallbackK * step));
      if (wrongStr != correctValStr) optionsSet.add(wrongStr);
      fallbackK++;
    }

    final optionsList = optionsSet.toList();
    optionsList.shuffle(rnd);

    q['question'] = processedText;
    q['question_text'] = processedText;
    q['type'] = 'multiple_choice';
    q['question_type'] = 'multiple_choice';
    q['options'] = optionsList;
    q['options_json'] = jsonEncode(optionsList);
    q['correct'] = correctValStr;
    q['correct_answer'] = correctValStr;
    q['is_variable_calculated'] = true;
  } catch (e) {
    debugPrint('Error processing variable calculations: $e');
  }
  return q;
}


// Mengecilkan gambar hasil upload (data URL base64) sebelum disimpan ke
// localStorage/SharedPreferences. Foto langsung dari komputer/HP sering
// berukuran beberapa MB — kalau disimpan mentah-mentah sebagai base64, mudah
// melebihi kuota penyimpanan browser (~5-10MB total per origin) sehingga
// PENYIMPANAN SOAL GAGAL DIAM-DIAM (soal tampak "menghilang"). Fungsi ini
// mengubah ukuran gambar maksimal 900px pada sisi terpanjang dan
// mengompresnya sebagai JPEG kualitas 72%, cukup untuk tampilan soal kuis
// tanpa membebani kuota penyimpanan.
Future<String> _compressImageDataUrlForStorage(String dataUrl, {int maxDim = 900, double quality = 0.72}) async {
  if (!dataUrl.startsWith('data:image')) return dataUrl;
  try {
    final completer = Completer<String>();
    final img = html.ImageElement();
    img.onLoad.listen((_) {
      try {
        final w = img.naturalWidth;
        final h = img.naturalHeight;
        if (w <= 0 || h <= 0) {
          if (!completer.isCompleted) completer.complete(dataUrl);
          return;
        }
        double scale = 1.0;
        if (w > maxDim || h > maxDim) {
          scale = w >= h ? maxDim / w : maxDim / h;
        }
        final targetW = (w * scale).round().clamp(1, w);
        final targetH = (h * scale).round().clamp(1, h);
        final canvas = html.CanvasElement(width: targetW, height: targetH);
        final ctx2d = canvas.context2D;
        ctx2d.drawImageScaled(img, 0, 0, targetW, targetH);
        final compressed = canvas.toDataUrl('image/jpeg', quality);
        if (!completer.isCompleted) completer.complete(compressed);
      } catch (_) {
        if (!completer.isCompleted) completer.complete(dataUrl);
      }
    });
    img.onError.listen((_) {
      if (!completer.isCompleted) completer.complete(dataUrl);
    });
    img.src = dataUrl;
    return await completer.future.timeout(const Duration(seconds: 8), onTimeout: () => dataUrl);
  } catch (_) {
    return dataUrl;
  }
}

// Memilih BANYAK gambar sekaligus dari komputer (dipakai untuk "upload PPT"
// -- dosen mengekspor tiap slide PPT-nya sebagai gambar lalu unggah semua
// sekaligus di sini, tiap gambar jadi satu slide presentasi).
void _pickMultipleImagesWeb(Function(List<String> base64List) onSelected) {
  final uploadInput = html.FileUploadInputElement()
    ..accept = 'image/*'
    ..multiple = true;
  uploadInput.click();
  uploadInput.onChange.listen((e) async {
    final files = uploadInput.files;
    if (files == null || files.isEmpty) return;
    final results = <String>[];
    for (final file in files) {
      final reader = html.FileReader();
      reader.readAsDataUrl(file);
      await reader.onLoadEnd.first;
      final result = reader.result?.toString() ?? '';
      if (result.isNotEmpty) results.add(result);
    }
    onSelected(results);
  });
}

// Widget gambar bersama (dipakai kuis live & slide presentasi): BoxFit.contain
// + tinggi maksimum supaya gambar apapun rasio aspeknya tampil UTUH
// menyesuaikan lebar kartu, tidak terpotong. Fungsi top-level supaya bisa
// dipakai lintas kelas (soal kuis maupun slide presentasi).
Widget _buildQuestionImageWidget(String imageUrl, {String displayMode = 'default', BuildContext? context}) {
  double maxImgHeight = 260;
  if (context != null) {
    if (displayMode == 'semi') {
      maxImgHeight = MediaQuery.of(context).size.height * 0.75;
    } else if (displayMode == 'full') {
      maxImgHeight = MediaQuery.of(context).size.height * 0.95;
    }
  }

  if (imageUrl.startsWith('data:image')) {
    try {
      final base64Data = imageUrl.split(',').last;
      final bytes = base64Decode(base64Data);
      return Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: maxImgHeight),
        decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.5)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.memory(
            bytes,
            key: ValueKey(imageUrl),
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      );
    } catch (_) {
      return const SizedBox(height: 100, child: Center(child: Icon(Icons.broken_image, color: Colors.grey)));
    }
  }

  final resolvedUrl = (imageUrl.startsWith('/') && !imageUrl.startsWith('//'))
      ? '${ApiService.serverBaseUrl}$imageUrl'
      : imageUrl;

  return Container(
    width: double.infinity,
    constraints: BoxConstraints(maxHeight: maxImgHeight),
    decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.5)),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.network(
        resolvedUrl,
        key: ValueKey(resolvedUrl),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
      ),
    ),
  );
}

// Memilih SATU file (.pptx / .pdf) dari komputer, mengembalikan byte
// mentahnya untuk dikirim ke backend (yang akan mengekstrak isinya).
void _pickPresentationFileWeb(String accept, Function(List<int> bytes, String fileName) onSelected) {
  final uploadInput = html.FileUploadInputElement()..accept = accept;
  uploadInput.click();
  uploadInput.onChange.listen((e) {
    final files = uploadInput.files;
    if (files == null || files.isEmpty) return;
    final file = files[0];
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      Uint8List? bytes;
      if (result is ByteBuffer) {
        bytes = result.asUint8List();
      } else if (result is Uint8List) {
        bytes = result;
      } else if (result is List<int>) {
        bytes = Uint8List.fromList(result);
      }
      if (bytes != null) onSelected(bytes, file.name);
    });
  });
}

void _pickPptxFileWeb(Function(List<int> bytes, String fileName) onSelected) => _pickPresentationFileWeb('.pptx', onSelected);
void _pickPdfFileWeb(Function(List<int> bytes, String fileName) onSelected) => _pickPresentationFileWeb('.pdf', onSelected);

// Quizizz Pastel Identity Colors
const Color _kQuizizzPastelBg = Color(0xFF6EA2B3); // Pastel Purple
const Color _kQuizizzTextColor = Color(0xFF0A4174);

// ----------------------------------------------------------------------
// DIALOG BERSAMA "RIWAYAT JAWABAN PR" (dipakai halaman Dosen & Mahasiswa)
// Menampilkan tiap soal PR yang sudah dikerjakan beserta jawaban yang
// dipilih, jawaban yang benar, dan indikasi benar/salah per soal.
// ----------------------------------------------------------------------
void _showAnswerHistoryDialog(
  BuildContext context, {
  required String headerTitle,
  String? studentName,
  int? score,
  int? total,
  required List<dynamic> answers,
}) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
      title: Row(
        children: [
          const Icon(Icons.fact_check_rounded, color: Color(0xFF0284C7), size: 24),
          const SizedBox(width: 8),
          Expanded(child: Text('📜 Riwayat Jawaban${studentName != null ? " — $studentName" : ""}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 15))),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(headerTitle, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black54, fontSize: 12)),
            if (score != null && total != null) ...[
              const SizedBox(height: 4),
              Text('Skor: $score / $total Benar', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 14)),
            ],
            const SizedBox(height: 12),
            if (answers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('Detail jawaban per soal tidak tersedia untuk pengumpulan ini.', style: TextStyle(color: Colors.black54, fontSize: 12)),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: answers.asMap().entries.map((entry) {
                      final i = entry.key;
                      final a = Map<String, dynamic>.from(entry.value as Map);
                      final isCorrect = a['is_correct'] == true || a['is_correct'] == 'true';
                      final question = (a['question'] ?? a['question_text'] ?? 'Soal ${i + 1}').toString();
                      final studentAns = a['student_answer'];
                      final correctAns = a['correct_answer'];
                      String fmt(dynamic v) {
                        if (v == null) return '(Tidak dijawab)';
                        if (v is List) return v.isEmpty ? '(Tidak dijawab)' : v.join(', ');
                        final s = v.toString();
                        return s.isEmpty ? '(Tidak dijawab)' : s;
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: isCorrect ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: isCorrect ? const Color(0xFF16A34A) : const Color(0xFFDC2626), width: 1.4),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(isCorrect ? Icons.check_circle_rounded : Icons.cancel_rounded, color: isCorrect ? const Color(0xFF16A34A) : const Color(0xFFDC2626), size: 20),
                                const SizedBox(width: 8),
                                Expanded(child: Text('${i + 1}. $question', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13))),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text('Jawaban Mahasiswa: ${fmt(studentAns)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isCorrect ? const Color(0xFF166534) : const Color(0xFF991B1B))),
                            if (!isCorrect) ...[
                              const SizedBox(height: 2),
                              Text('Jawaban Benar: ${fmt(correctAns)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF166534))),
                            ],
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        ),
      ],
    ),
  );
}

// ----------------------------------------------------------------------
// DIALOG BERSAMA "KELOLA SOAL PRESENTASI" — dipakai dari Live Presenter
// MAUPUN langsung dari daftar presentasi dosen (TANPA perlu menekan
// "Mulai Presentasi" dulu). Mendukung 4 tipe soal: Pilihan Ganda,
// Multi-Select, Benar/Salah, dan Jawaban Singkat.
// ----------------------------------------------------------------------
// ----------------------------------------------------------------------
// DIALOG BERSAMA "HASIL AKHIR KUIS PRESENTASI" (poin 6) — ditampilkan ke
// dosen setelah menekan "Akhiri Presentasi", dan ke mahasiswa begitu
// mereka terdeteksi dikeluarkan karena presentasi berakhir. Menampilkan
// papan peringkat (leaderboard) skor semua mahasiswa dari seluruh soal
// interaktif yang pernah diaktifkan sepanjang sesi.
// ----------------------------------------------------------------------
Future<void> showLessonFinalResultsDialog(
  BuildContext context,
  Map<String, dynamic> results, {
  required bool isDosen,
  String? myName,
}) async {
  final leaderboard = (results['leaderboard'] as List).cast<Map<String, dynamic>>();
  if (!context.mounted) return;
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
      title: const Text('🏆 Hasil Akhir Kuis Presentasi', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 16)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${results['total_questions_asked']} soal diaktifkan • ${results['total_students_participated']} mahasiswa berpartisipasi', style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  children: leaderboard.asMap().entries.map((entry) {
                    final rank = entry.key + 1;
                    final row = entry.value;
                    final isMe = !isDosen && myName != null && row['student_name']?.toString() == myName;
                    final medal = rank == 1 ? '🥇' : (rank == 2 ? '🥈' : (rank == 3 ? '🥉' : '#$rank'));
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isMe ? _kMustardYellow : (rank <= 3 ? const Color(0xFFFFF7E0) : _kCreamBg),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _kNavyDark, width: isMe ? 1.6 : 1),
                      ),
                      child: Row(
                        children: [
                          SizedBox(width: 34, child: Text(medal, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                          Expanded(
                            child: Text(
                              row['student_name'] ?? 'Mahasiswa',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark, decoration: isMe ? TextDecoration.underline : null),
                            ),
                          ),
                          // FITUR "Riwayat Jawaban Mahasiswa di Presentasi"
                          // (poin 4): dosen bisa membuka rincian jawaban tiap
                          // soal per mahasiswa, sama seperti fitur Riwayat
                          // Jawaban yang sudah ada di PR & Kuis Gamifikasi.
                          if (isDosen)
                            IconButton(
                              tooltip: 'Lihat Riwayat Jawaban',
                              icon: const Icon(Icons.fact_check_rounded, color: Color(0xFF0284C7), size: 20),
                              onPressed: () => _showAnswerHistoryDialog(
                                context,
                                headerTitle: 'Presentasi',
                                studentName: row['student_name']?.toString() ?? 'Mahasiswa',
                                score: row['correct'] is int ? row['correct'] as int : int.tryParse(row['correct'].toString()),
                                total: row['answered'] is int ? row['answered'] as int : int.tryParse(row['answered'].toString()),
                                answers: (row['answers'] as List?) ?? [],
                              ),
                            ),
                          Text('${row['correct']}/${row['answered']} Benar', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: _kNavyDark)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx),
          style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: const Text('Tutup', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
}

Future<void> showManageLessonQuestionsDialog(
  BuildContext context, {
  required String lessonId,
  required String lessonTitle,
  VoidCallback? onChanged,
  List<String>? activatedHistory,
}) async {
  List<Map<String, dynamic>> lessonQuestions = await QuizizzService.getLessonQuestions(lessonId);
  final initialLessonSettings = await QuizizzService.getLessonSettings(lessonId);
  bool shuffleQuestions = initialLessonSettings['shuffle_questions'] == true;
  bool shuffleAnswers = initialLessonSettings['shuffle_answers'] == true;

  final questionCtrl = TextEditingController();
  final optionControllers = List.generate(4, (_) => TextEditingController());
  final shortAnswerCtrl = TextEditingController();
  String? correctAnswer; // dipakai untuk pilihan ganda (huruf A-D)
  Set<String> multiCorrectAnswers = {}; // dipakai untuk multi-select (huruf A-D)
  String questionType = 'multiple_choice'; // multiple_choice | multi_select | true_false | short_answer
  String trueFalseAnswer = 'Benar';
  int? timeLimitSeconds = 30; // Fitur "Timer Soal Presentasi" -- null = tanpa batas waktu.
  // FITUR "Gambar di Soal & Jawaban Presentasi" (poin 4): dosen bisa
  // mengupload gambar untuk pertanyaannya sendiri, dan/atau gambar
  // terpisah untuk masing-masing opsi jawaban (khusus Pilihan Ganda &
  // Multi-Select).
  String? questionImageBase64;
  List<String?> optionImageBase64 = List<String?>.filled(4, null);
  // FITUR "Edit Soal Presentasi" (poin 4): kalau tidak null, form sedang
  // MENGEDIT soal dengan id ini (bukan menambah soal baru).
  String? editingQuestionId;

  bool isVariableCalc = false;
  int varCount = 3;
  List<String> varNames = ['a', 'b', 'c', 'd', 'e'];
  List<TextEditingController> varMinCtrls = List.generate(5, (_) => TextEditingController(text: '1'));
  List<TextEditingController> varMaxCtrls = List.generate(5, (_) => TextEditingController(text: '10'));
  final formulaCtrl = TextEditingController();

  const typeLabels = {
    'multiple_choice': 'Pilihan Ganda',
    'multi_select': 'Multi-Select',
    'true_false': 'Benar / Salah',
    'short_answer': 'Jawaban Singkat',
  };
  const typeBadges = {
    'multiple_choice': 'PG',
    'multi_select': 'MULTI',
    'true_false': 'B/S',
    'short_answer': 'ISIAN',
  };

  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDState) {
        void uploadLessonQuestionsFromExcel() {
          ExportHelper.pickFileBytesWeb((filename, bytes) async {
            final imported = ExportHelper.parseQuestionsFromExcel(bytes, defaultTimer: 30);
            if (imported.isEmpty) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('⚠️ Tidak ada soal yang valid ditemukan di file Excel ini.'), backgroundColor: Colors.orange),
                );
              }
              return;
            }
            int successCount = 0;
            for (final q in imported) {
              final created = await QuizizzService.createLessonQuestion(
                lessonId: lessonId,
                questionText: q['question'] ?? '',
                options: (q['options'] as List?)?.map((e) => e.toString()).toList() ?? [],
                correctAnswer: q['correct']?.toString(),
                questionType: q['type'] ?? 'multiple_choice',
                timeLimitSeconds: q['timer_seconds'] is int ? q['timer_seconds'] as int : 30,
                variableCalcJson: q['variable_calc_json'],
              );
              if (created != null && created.isNotEmpty) successCount++;
            }
            final updated = await QuizizzService.getLessonQuestions(lessonId);
            setDState(() {
              lessonQuestions = updated;
            });
            onChanged?.call();
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(
                  content: Text('✅ Berhasil mengimpor $successCount soal presentasi dari file "$filename"!'),
                  backgroundColor: const Color(0xFF16A34A),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          });
        }

        return AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: Text('📋 Kelola Soal — $lessonTitle', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 15)),
        // PENTING (perbaikan bug "BOTTOM OVERFLOWED"): dialog dibungkus
        // dengan tinggi maksimum yang mengikuti ukuran layar, dan seluruh isi
        // (form + daftar bank soal) ada di dalam SATU SingleChildScrollView,
        // supaya tidak ada lagi ConstrainedBox tersarang yang bikin overflow
        // saat daftar soal panjang.
        content: SizedBox(
          width: 520,
          height: MediaQuery.of(ctx).size.height * 0.75,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // FITUR UNDUH TEMPLATE & UNGGAH SOAL EXCEL
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF16A34A).withOpacity(0.4), width: 1.2),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.table_view_rounded, color: Color(0xFF15803D), size: 24),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Template & Impor Excel:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF166534))),
                            SizedBox(height: 2),
                            Text('Unduh format Excel (.xlsx) atau impor banyak soal sekaligus.', style: TextStyle(fontSize: 11, color: Colors.black54)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => ExportHelper.downloadQuestionsTemplateExcel(title: lessonTitle),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF15803D),
                          side: const BorderSide(color: Color(0xFF15803D), width: 1.2),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text('Unduh Template', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: uploadLessonQuestionsFromExcel,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF16A34A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.upload_file_rounded, size: 16),
                        label: const Text('Unggah Excel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ],
                  ),
                ),

                // PENGATURAN ANTI-MENCONTEK: ACAK SOAL & ACAK JAWABAN
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _kNavyDark.withOpacity(0.3), width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune_rounded, size: 18, color: _kNavyDark),
                          SizedBox(width: 8),
                          Text(
                            'Pengaturan Soal (Anti-Mencontek):',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: _kNavyDark,
                              title: const Text('🔀 Acak Soal', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _kNavyDark)),
                              subtitle: const Text('Urutan soal diacak', style: TextStyle(fontSize: 11, color: Colors.black54)),
                              value: shuffleQuestions,
                              onChanged: (v) {
                                setDState(() => shuffleQuestions = v ?? false);
                                QuizizzService.saveLessonSettings(lessonId, {
                                  'shuffle_questions': shuffleQuestions,
                                  'shuffle_answers': shuffleAnswers,
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: _kNavyDark,
                              title: const Text('🔀 Acak Jawaban', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _kNavyDark)),
                              subtitle: const Text('Urutan opsi diacak', style: TextStyle(fontSize: 11, color: Colors.black54)),
                              value: shuffleAnswers,
                              onChanged: (v) {
                                setDState(() => shuffleAnswers = v ?? false);
                                QuizizzService.saveLessonSettings(lessonId, {
                                  'shuffle_questions': shuffleQuestions,
                                  'shuffle_answers': shuffleAnswers,
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Text('Buat soal baru untuk bank soal presentasi ini:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 10),
                // FITUR "Edit Soal Presentasi" (poin 4): indikator saat form
                // sedang mengedit soal yang sudah ada, bukan menambah baru.
                if (editingQuestionId != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFB45309))),
                    child: Row(
                      children: [
                        const Icon(Icons.edit_rounded, size: 16, color: Color(0xFFB45309)),
                        const SizedBox(width: 6),
                        const Expanded(child: Text('Sedang mengedit soal ini', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF92400E)))),
                        InkWell(
                          onTap: () {
                            setDState(() {
                              editingQuestionId = null;
                              questionImageBase64 = null;
                              optionImageBase64 = List<String?>.filled(4, null);
                              correctAnswer = null;
                              multiCorrectAnswers = {};
                            });
                            questionCtrl.clear();
                            shortAnswerCtrl.clear();
                            for (final c in optionControllers) {
                              c.clear();
                            }
                          },
                          child: const Text('Batal Edit', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFB45309), decoration: TextDecoration.underline)),
                        ),
                      ],
                    ),
                  ),
                ],
                // PEMILIH TIPE SOAL
                if (isVariableCalc) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFCBD5E1))),
                    child: const Row(
                      children: [
                        Icon(Icons.format_list_bulleted_rounded, size: 18, color: _kNavyDark),
                        SizedBox(width: 8),
                        Text('Tipe Soal: Pilihan Ganda (1 Jawaban)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                      ],
                    ),
                  ),
                ] else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: typeLabels.entries.map((e) {
                      return ChoiceChip(
                        label: Text(e.value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        selected: questionType == e.key,
                        onSelected: (_) => setDState(() {
                          questionType = e.key;
                          correctAnswer = null;
                          multiCorrectAnswers = {};
                        }),
                        selectedColor: _kMustardYellow,
                        backgroundColor: _kCreamBg,
                      );
                    }).toList(),
                  ),
                ],
                const SizedBox(height: 10),

                // FITUR VARIABLE CALCULATIONS
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF0F172A).withOpacity(0.5)),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.blue.withOpacity(0.05),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        title: const Text('Variable Calculations (Angka Acak Tiap Siswa)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))),
                        subtitle: const Text('Tulis variabel [a], [b], dsb di teks soal & rumus pada tiap opsi jawaban A, B, C, D.', style: TextStyle(fontSize: 11)),
                        value: isVariableCalc,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        activeColor: const Color(0xFFFBBF24),
                        checkColor: const Color(0xFF0F172A),
                        onChanged: (v) => setDState(() {
                          isVariableCalc = v ?? false;
                          if (isVariableCalc) {
                            questionType = 'multiple_choice';
                          }
                        }),
                      ),
                      if (isVariableCalc) ...[
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int>(
                          value: varCount,
                          decoration: const InputDecoration(labelText: 'Jumlah Variabel', border: OutlineInputBorder(), isDense: true),
                          items: [1,2,3,4,5].map((e) => DropdownMenuItem(value: e, child: Text('$e Variabel'))).toList(),
                          onChanged: (v) => setDState(() => varCount = v ?? 3),
                        ),
                        const SizedBox(height: 8),
                        for (int i=0; i<varCount; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Row(
                              children: [
                                Expanded(flex: 2, child: Text('Var [${varNames[i]}]:', style: const TextStyle(fontWeight: FontWeight.bold))),
                                Expanded(flex: 3, child: TextFormField(controller: varMinCtrls[i], decoration: const InputDecoration(labelText: 'Min', isDense: true, border: OutlineInputBorder()), keyboardType: TextInputType.number)),
                                const SizedBox(width: 8),
                                Expanded(flex: 3, child: TextFormField(controller: varMaxCtrls[i], decoration: const InputDecoration(labelText: 'Max', isDense: true, border: OutlineInputBorder()), keyboardType: TextInputType.number)),
                              ],
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFF59E0B))),
                          child: const Row(
                            children: [
                              Icon(Icons.lightbulb_outline_rounded, color: Color(0xFFB45309), size: 18),
                              SizedBox(width: 8),
                              Expanded(child: Text('Tulis rumus (misal: [1+[a] [b]-1 [c]^2] atau a+b) pada masing-masing kotak Opsi A, B, C, D di bawah. Pilih 1 opsi sebagai jawaban BENAR (3 opsi lainnya otomatis sebagai jawaban SALAH).', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF92400E)))),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: questionCtrl,
                  decoration: InputDecoration(hintText: 'Tulis pertanyaan...', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.all(12)),
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                // FITUR "Gambar di Pertanyaan" (poin 4).
                if (questionImageBase64 != null) ...[
                  SizedBox(height: 130, child: _buildQuestionImageWidget(questionImageBase64!)),
                  const SizedBox(height: 6),
                ],
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        ExportHelper.pickImageWeb((base64Data) async {
                          if (base64Data.isEmpty) return;
                          final compressed = await _compressImageDataUrlForStorage(base64Data);
                          setDState(() => questionImageBase64 = compressed);
                        });
                      },
                      style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2)),
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(questionImageBase64 == null ? '🖼️ Tambah Gambar Pertanyaan' : 'Ganti Gambar Pertanyaan', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    if (questionImageBase64 != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                        onPressed: () => setDState(() => questionImageBase64 = null),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                // FITUR "Timer Soal Presentasi": batas waktu menjawab sejak
                // soal ini diaktifkan dosen saat presentasi live.
                Row(
                  children: [
                    const Icon(Icons.timer_outlined, size: 16, color: _kNavyDark),
                    const SizedBox(width: 6),
                    const Text('Batas Waktu:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        children: [15, 30, 60, 90].map((sec) {
                          final selected = timeLimitSeconds == sec;
                          return ChoiceChip(
                            label: Text('${sec}s', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            selected: selected,
                            onSelected: (_) => setDState(() => timeLimitSeconds = sec),
                            selectedColor: _kMustardYellow,
                            backgroundColor: _kCreamBg,
                          );
                        }).toList()
                          ..add(ChoiceChip(
                            label: const Text('Tanpa Batas', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            selected: timeLimitSeconds == null,
                            onSelected: (_) => setDState(() => timeLimitSeconds = null),
                            selectedColor: _kMustardYellow,
                            backgroundColor: _kCreamBg,
                          )),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (questionType == 'multiple_choice') ...[
                  Text(isVariableCalc ? '🎯 Input Rumus Opsi Jawaban (Pilih 1 Rumus Benar):' : '🎯 Input Opsi Jawaban (Pilih 1 Jawaban Benar):', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                  const SizedBox(height: 8),
                  ...List.generate(4, (i) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(10)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Radio<String>(
                                  value: String.fromCharCode(65 + i),
                                  groupValue: correctAnswer,
                                  onChanged: (v) => setDState(() => correctAnswer = v),
                                  activeColor: const Color(0xFF16A34A),
                                ),
                                Expanded(
                                  child: TextField(
                                    controller: optionControllers[i],
                                    decoration: InputDecoration(hintText: isVariableCalc ? 'Rumus Opsi ${String.fromCharCode(65 + i)} (mis. [1+[a] [b]-1 [c]^2] atau a+b)' : 'Opsi ${String.fromCharCode(65 + i)}', isDense: true, filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                                  ),
                                ),
                                // FITUR "Gambar di Jawaban" (poin 4): gambar
                                // opsional untuk opsi jawaban ini.
                                IconButton(
                                  tooltip: 'Gambar opsi ini',
                                  icon: Icon(optionImageBase64[i] == null ? Icons.image_outlined : Icons.image, color: _kNavyDark, size: 18),
                                  onPressed: () {
                                    ExportHelper.pickImageWeb((base64Data) async {
                                      if (base64Data.isEmpty) return;
                                      final compressed = await _compressImageDataUrlForStorage(base64Data);
                                      setDState(() => optionImageBase64[i] = compressed);
                                    });
                                  },
                                ),
                                if (optionImageBase64[i] != null)
                                  IconButton(
                                    icon: const Icon(Icons.close, color: Colors.redAccent, size: 16),
                                    onPressed: () => setDState(() => optionImageBase64[i] = null),
                                  ),
                              ],
                            ),
                            if (optionImageBase64[i] != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 44, right: 8, bottom: 8),
                                child: SizedBox(height: 90, child: _buildQuestionImageWidget(optionImageBase64[i]!)),
                              ),
                          ],
                        ),
                      )),
                  const Text('(Pilih radio button di kiri opsi untuk menandai SATU jawaban benar. Ikon gambar di kanan tiap opsi untuk melampirkan gambar jawaban - opsional)', style: TextStyle(fontSize: 10, color: Colors.black45, fontStyle: FontStyle.italic)),
                ] else if (questionType == 'multi_select') ...[
                  ...List.generate(4, (i) {
                    final letter = String.fromCharCode(65 + i);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(10)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Checkbox(
                                value: multiCorrectAnswers.contains(letter),
                                onChanged: (checked) => setDState(() {
                                  if (checked == true) {
                                    multiCorrectAnswers.add(letter);
                                  } else {
                                    multiCorrectAnswers.remove(letter);
                                  }
                                }),
                                activeColor: const Color(0xFF16A34A),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: optionControllers[i],
                                  decoration: InputDecoration(hintText: 'Opsi $letter', isDense: true, filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Gambar opsi ini',
                                icon: Icon(optionImageBase64[i] == null ? Icons.image_outlined : Icons.image, color: _kNavyDark, size: 18),
                                onPressed: () {
                                  ExportHelper.pickImageWeb((base64Data) async {
                                    if (base64Data.isEmpty) return;
                                    final compressed = await _compressImageDataUrlForStorage(base64Data);
                                    setDState(() => optionImageBase64[i] = compressed);
                                  });
                                },
                              ),
                              if (optionImageBase64[i] != null)
                                IconButton(
                                  icon: const Icon(Icons.close, color: Colors.redAccent, size: 18),
                                  onPressed: () => setDState(() => optionImageBase64[i] = null),
                                ),
                            ],
                          ),
                          if (optionImageBase64[i] != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 44, right: 8, bottom: 8),
                              child: SizedBox(height: 90, child: _buildQuestionImageWidget(optionImageBase64[i]!)),
                            ),
                        ],
                      ),
                    );
                  }),
                  const Text('(Centang kotak di kiri opsi untuk menandai jawaban benar, boleh lebih dari satu. Ikon gambar untuk melampirkan gambar jawaban - opsional)', style: TextStyle(fontSize: 10, color: Colors.black45, fontStyle: FontStyle.italic)),
                ] else if (questionType == 'true_false') ...[
                  Row(
                    children: [
                      Expanded(
                        child: RadioListTile<String>(
                          value: 'Benar',
                          groupValue: trueFalseAnswer,
                          onChanged: (v) => setDState(() => trueFalseAnswer = v!),
                          title: const Text('Benar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          activeColor: const Color(0xFF16A34A),
                          dense: true,
                        ),
                      ),
                      Expanded(
                        child: RadioListTile<String>(
                          value: 'Salah',
                          groupValue: trueFalseAnswer,
                          onChanged: (v) => setDState(() => trueFalseAnswer = v!),
                          title: const Text('Salah', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          activeColor: const Color(0xFF16A34A),
                          dense: true,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  // Jawaban Singkat: mahasiswa mengetik jawaban bebas,
                  // dicocokkan (tanpa memandang besar/kecil huruf & spasi)
                  // dengan jawaban benar yang diisi dosen di sini.
                  TextField(
                    controller: shortAnswerCtrl,
                    decoration: InputDecoration(hintText: 'Jawaban benar (mis. "Jakarta")', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.all(12)),
                  ),
                  const SizedBox(height: 4),
                  const Text('(Jawaban mahasiswa dicocokkan otomatis, tidak peka huruf besar/kecil & spasi di awal-akhir)', style: TextStyle(fontSize: 10, color: Colors.black45, fontStyle: FontStyle.italic)),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final qText = questionCtrl.text.trim();
                      if (qText.isEmpty) {
                        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Isi pertanyaan terlebih dahulu')));
                        return;
                      }
                      
                      String? variableCalcJson;
                      if (isVariableCalc) {
                         List<Map<String, dynamic>> vars = [];
                         for (int i=0; i<varCount; i++) {
                           vars.add({
                             'name': varNames[i],
                             'min': int.tryParse(varMinCtrls[i].text) ?? 1,
                             'max': int.tryParse(varMaxCtrls[i].text) ?? 10,
                           });
                         }
                         final correctIdx = correctAnswer != null ? (correctAnswer!.codeUnitAt(0) - 65).clamp(0, 3) : 0;
                         variableCalcJson = jsonEncode({
                           'count': varCount,
                           'variables': vars,
                           'correct_index': correctIdx,
                         });
                         questionType = 'multiple_choice';
                      }
                      if (questionType == 'multiple_choice') {
                        final opts = optionControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
                        final ans = correctAnswer;
                        if (opts.length < 2) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Isi minimal 2 opsi jawaban')));
                          return;
                        }
                        if (editingQuestionId != null) {
                          await QuizizzService.updateLessonQuestion(
                            questionId: editingQuestionId!,
                            questionText: qText,
                            options: opts,
                            correctAnswer: ans,
                            questionType: 'multiple_choice',
                            timeLimitSeconds: timeLimitSeconds,
                            imageUrl: questionImageBase64,
                            optionImages: isVariableCalc ? null : optionImageBase64.take(opts.length).toList(),
                            variableCalcJson: variableCalcJson,
                          );
                        } else {
                          await QuizizzService.createLessonQuestion(
                            lessonId: lessonId,
                            questionText: qText,
                            options: opts,
                            correctAnswer: ans,
                            questionType: 'multiple_choice',
                            timeLimitSeconds: timeLimitSeconds,
                            imageUrl: questionImageBase64,
                            optionImages: isVariableCalc ? null : optionImageBase64.take(opts.length).toList(),
                            variableCalcJson: variableCalcJson,
                          );
                        }
                      } else if (questionType == 'multi_select') {
                        final opts = optionControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
                        if (opts.length < 2) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Isi minimal 2 opsi jawaban')));
                          return;
                        }
                        if (multiCorrectAnswers.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Centang minimal 1 jawaban benar')));
                          return;
                        }
                        if (editingQuestionId != null) {
                          await QuizizzService.updateLessonQuestion(
                            questionId: editingQuestionId!,
                            questionText: qText,
                            options: opts,
                            correctAnswer: multiCorrectAnswers.join(','),
                            questionType: 'multi_select',
                            timeLimitSeconds: timeLimitSeconds,
                            imageUrl: questionImageBase64,
                            optionImages: optionImageBase64.take(opts.length).toList(),
                          );
                        } else {
                          await QuizizzService.createLessonQuestion(
                            lessonId: lessonId,
                            questionText: qText,
                            options: opts,
                            correctAnswer: multiCorrectAnswers.join(','),
                            questionType: 'multi_select',
                            timeLimitSeconds: timeLimitSeconds,
                            imageUrl: questionImageBase64,
                            optionImages: optionImageBase64.take(opts.length).toList(),
                          );
                        }
                      } else if (questionType == 'true_false') {
                        if (editingQuestionId != null) {
                          await QuizizzService.updateLessonQuestion(questionId: editingQuestionId!, questionText: qText, options: const ['Benar', 'Salah'], correctAnswer: trueFalseAnswer, questionType: 'true_false', timeLimitSeconds: timeLimitSeconds, imageUrl: questionImageBase64, variableCalcJson: variableCalcJson);
                        } else {
                          await QuizizzService.createLessonQuestion(lessonId: lessonId, questionText: qText, options: const ['Benar', 'Salah'], correctAnswer: trueFalseAnswer, questionType: 'true_false', timeLimitSeconds: timeLimitSeconds, imageUrl: questionImageBase64, variableCalcJson: variableCalcJson);
                        }
                      } else {
                        final ans = shortAnswerCtrl.text.trim();
                        if (ans.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Isi jawaban benar terlebih dahulu')));
                          return;
                        }
                        if (editingQuestionId != null) {
                          await QuizizzService.updateLessonQuestion(questionId: editingQuestionId!, questionText: qText, options: const [], correctAnswer: ans, questionType: 'short_answer', timeLimitSeconds: timeLimitSeconds, imageUrl: questionImageBase64, variableCalcJson: variableCalcJson);
                        } else {
                          await QuizizzService.createLessonQuestion(lessonId: lessonId, questionText: qText, options: const [], correctAnswer: ans, questionType: 'short_answer', timeLimitSeconds: timeLimitSeconds, imageUrl: questionImageBase64, variableCalcJson: variableCalcJson);
                        }
                      }
                      questionCtrl.clear();
                      shortAnswerCtrl.clear();
                      for (final c in optionControllers) {
                        c.clear();
                      }
                      setDState(() {
                        correctAnswer = null;
                        multiCorrectAnswers = {};
                        questionImageBase64 = null;
                        optionImageBase64 = List<String?>.filled(4, null);
                        editingQuestionId = null;
                      });
                      lessonQuestions = await QuizizzService.getLessonQuestions(lessonId);
                      onChanged?.call();
                      setDState(() {});
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    icon: Icon(editingQuestionId != null ? Icons.save_rounded : Icons.add, size: 16),
                    label: Text(editingQuestionId != null ? 'Update Soal Ini' : 'Tambah Soal ke Bank Soal', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(color: _kNavyDark, height: 1),
                const SizedBox(height: 10),
                Text('Bank Soal Tersimpan (${lessonQuestions.length}):', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 8),
                // Daftar bank soal TIDAK dibungkus ConstrainedBox+scroll
                // tersendiri lagi (itu penyebab overflow) -- sekarang ikut
                // mengalir dalam SingleChildScrollView utama di atas.
                Column(
                  children: lessonQuestions.map((q) {
                    final isUsed = activatedHistory?.contains(q['id'].toString()) == true;
                    return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: _kNavyDark, width: 1)),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  margin: const EdgeInsets.only(right: 8, top: 2),
                                  decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(8)),
                                  child: Text(typeBadges[q['question_type']] ?? 'PG', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: _kQuizizzTextColor)),
                                ),
                                // Fitur "Indikator Soal Sudah Digunakan": soal
                                // yang pernah diaktifkan dosen di sesi live ini
                                // ditandai, walau sudah dinonaktifkan lagi.
                                if (isUsed) ...[
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(8)),
                                    child: const Text('✓ Dipakai', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                                  ),
                                ],
                              ],
                            ),
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(child: Text(q['question_text'] ?? '', style: const TextStyle(fontSize: 12, color: _kNavyDark, fontWeight: FontWeight.w600))),
                                  // Indikator kalau soal ini punya gambar pertanyaan
                                  // dan/atau gambar di salah satu opsi jawabannya.
                                  if ((q['image_url'] ?? '').toString().isNotEmpty)
                                    const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.image, size: 14, color: _kNavyDark)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_rounded, size: 18, color: _kNavyDark),
                              onPressed: () {
                                // FITUR "Edit Soal Presentasi" (poin 4): isi
                                // ulang form di atas dengan data soal ini.
                                final qType = (q['question_type'] ?? 'multiple_choice').toString();
                                final opts = (q['options'] as List?)?.map((e) => e.toString()).toList() ?? [];
                                final optImgs = (q['option_images'] as List?)?.map((e) => e?.toString()).toList() ?? [];
                                setDState(() {
                                  editingQuestionId = q['id'].toString();
                                  questionType = qType;
                                  questionCtrl.text = (q['question_text'] ?? '').toString();
                                  timeLimitSeconds = q['time_limit_seconds'] is int ? q['time_limit_seconds'] as int : 30;
                                  questionImageBase64 = (q['image_url'] != null && q['image_url'].toString().isNotEmpty) ? q['image_url'].toString() : null;
                                  optionImageBase64 = List<String?>.generate(4, (i) => i < optImgs.length ? optImgs[i] : null);
                                  for (var i = 0; i < optionControllers.length; i++) {
                                    optionControllers[i].text = i < opts.length ? opts[i] : '';
                                  }
                                  shortAnswerCtrl.text = qType == 'short_answer' ? (q['correct_answer'] ?? '').toString() : '';
                                  if (qType == 'multiple_choice') {
                                    correctAnswer = (q['correct_answer'] ?? 'A').toString();
                                  } else if (qType == 'true_false') {
                                    trueFalseAnswer = (q['correct_answer'] ?? 'Benar').toString();
                                  } else if (qType == 'multi_select') {
                                    final raw = (q['correct_answer'] ?? '').toString();
                                    multiCorrectAnswers = raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
                                  }
                                });
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                              onPressed: () async {
                                await QuizizzService.deleteLessonQuestion(q['id'].toString());
                                lessonQuestions = await QuizizzService.getLessonQuestions(lessonId);
                                onChanged?.call();
                                setDState(() {});
                              },
                            ),
                          ],
                        ),
                      );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold))),
        ],
      );
    },
  ),
);
}

// ----------------------------------------------------------------------
// FITUR "REVIEW & EDIT SLIDE PRESENTASI" (poin 2) + "Gambar di Soal &
// Jawaban Slide Kuis" (poin 4): dosen bisa meninjau ulang isi lengkap
// slide yang sudah ditambahkan (teks, gambar, dan -- khusus slide kuis --
// pertanyaan & tiap opsi jawabannya lengkap dengan gambar masing-masing)
// sebelum presentasi disimpan, langsung dari daftar slide di dialog buat
// presentasi.
// ----------------------------------------------------------------------
Future<void> _reviewOrEditSlideDialog(
  BuildContext context,
  List<Map<String, dynamic>> slides,
  int idx,
  StateSetter setOuterState,
) async {
  final slide = slides[idx];
  final type = (slide['type'] ?? 'text').toString();
  final isQuizType = type == 'quiz_mc' || type == 'poll' || type == 'short_answer';

  final titleCtrl = TextEditingController(text: (slide['title'] ?? '').toString());
  final contentCtrl = TextEditingController(text: (slide['content'] ?? '').toString());
  String? mediaUrl = slide['media_url']?.toString();

  // Khusus slide kuis: siapkan controller teks per opsi + gambar per opsi.
  List<TextEditingController> optionCtrls = [];
  List<String?> optionImages = [];
  String? correctAnswer = slide['correct_answer']?.toString();
  int timerSeconds = (slide['timer_seconds'] is int) ? slide['timer_seconds'] as int : 30;
  if (isQuizType) {
    final opts = (slide['options'] as List?)?.map((e) => e.toString()).toList() ?? ['Opsi A', 'Opsi B', 'Opsi C', 'Opsi D'];
    optionCtrls = opts.map((o) => TextEditingController(text: o)).toList();
    final imgs = (slide['option_images'] as List?)?.map((e) => e?.toString()).toList() ?? [];
    optionImages = List<String?>.generate(opts.length, (i) => i < imgs.length ? imgs[i] : null);
  }

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDState) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: Row(
          children: [
            Icon(type == 'text' ? Icons.text_snippet : (type == 'image' ? Icons.image : Icons.quiz_rounded), color: _kNavyDark),
            const SizedBox(width: 8),
            Expanded(child: Text('Review / Edit Slide ${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 15))),
          ],
        ),
        content: SizedBox(
          width: 520,
          height: MediaQuery.of(ctx).size.height * 0.72,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(labelText: 'Judul Slide (internal)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.all(12)),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: contentCtrl,
                  maxLines: 4,
                  style: const TextStyle(color: _kNavyDark),
                  decoration: InputDecoration(
                    labelText: isQuizType ? 'Pertanyaan / Teks Soal' : 'Isi Konten Slide',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 12),
                // Gambar utama slide / gambar pertanyaan (poin 4).
                Text(isQuizType ? '🖼️ Gambar Pertanyaan (opsional):' : '🖼️ Gambar Slide (opsional):', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 6),
                if (mediaUrl != null && mediaUrl!.isNotEmpty) ...[
                  _buildQuestionImageWidget(mediaUrl!),
                  const SizedBox(height: 6),
                ],
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        ExportHelper.pickImageWeb((base64Data) async {
                          if (base64Data.isEmpty) return;
                          final compressed = await _compressImageDataUrlForStorage(base64Data);
                          setDState(() => mediaUrl = compressed);
                        });
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: _kCreamBg, foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2)),
                      icon: const Icon(Icons.upload_file_rounded, size: 16),
                      label: Text(mediaUrl == null || mediaUrl!.isEmpty ? 'Upload Gambar' : 'Ganti Gambar', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    if (mediaUrl != null && mediaUrl!.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => setDState(() => mediaUrl = null),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent, width: 1.2)),
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Hapus', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ],
                ),
                if (isQuizType) ...[
                  const SizedBox(height: 16),
                  const Divider(color: _kNavyDark, height: 1),
                  const SizedBox(height: 12),
                  const Text('✍️ Opsi Jawaban (pilih bulatan untuk tandai jawaban benar, & bisa tambahkan gambar per opsi):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 8),
                  ...List.generate(optionCtrls.length, (i) {
                    final img = optionImages[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Radio<String>(
                                value: optionCtrls[i].text,
                                groupValue: correctAnswer,
                                onChanged: (v) => setDState(() => correctAnswer = optionCtrls[i].text),
                                activeColor: const Color(0xFF16A34A),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: optionCtrls[i],
                                  onChanged: (v) {
                                    // Kalau opsi ini sedang jadi jawaban benar, teks
                                    // jawaban benarnya ikut disinkronkan.
                                    if (correctAnswer == null) return;
                                  },
                                  decoration: InputDecoration(hintText: 'Opsi ${String.fromCharCode(65 + i)}', isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                                ),
                              ),
                            ],
                          ),
                          if (img != null && img.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            SizedBox(height: 120, child: _buildQuestionImageWidget(img)),
                            const SizedBox(height: 6),
                          ],
                          Row(
                            children: [
                              OutlinedButton.icon(
                                onPressed: () {
                                  ExportHelper.pickImageWeb((base64Data) async {
                                    if (base64Data.isEmpty) return;
                                    final compressed = await _compressImageDataUrlForStorage(base64Data);
                                    setDState(() => optionImages[i] = compressed);
                                  });
                                },
                                style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1)),
                                icon: const Icon(Icons.image_outlined, size: 14),
                                label: Text(img == null || img.isEmpty ? 'Tambah Gambar Opsi' : 'Ganti Gambar', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                              if (img != null && img.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 16),
                                  onPressed: () => setDState(() => optionImages[i] = null),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined, size: 16, color: _kNavyDark),
                      const SizedBox(width: 6),
                      const Text('Waktu Menjawab:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          children: [15, 30, 60, 90].map((sec) {
                            return ChoiceChip(
                              label: Text('${sec}s', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              selected: timerSeconds == sec,
                              onSelected: (_) => setDState(() => timerSeconds = sec),
                              selectedColor: _kMustardYellow,
                              backgroundColor: Colors.white,
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal', style: TextStyle(color: _kNavyDark))),
          ElevatedButton(
            onPressed: () {
              setOuterState(() {
                slide['title'] = titleCtrl.text.trim().isEmpty ? slide['title'] : titleCtrl.text.trim();
                slide['content'] = contentCtrl.text.trim();
                slide['media_url'] = mediaUrl;
                if (isQuizType) {
                  final newOptions = optionCtrls.map((c) => c.text.trim()).toList();
                  slide['options'] = newOptions;
                  slide['option_images'] = optionImages;
                  // Kalau jawaban benar sebelumnya kosong atau tidak ada lagi
                  // di daftar opsi (opsi diedit teksnya), fallback ke opsi
                  // pertama supaya selalu valid.
                  if (correctAnswer == null || !newOptions.contains(correctAnswer)) {
                    correctAnswer = newOptions.isNotEmpty ? newOptions.first : null;
                  }
                  slide['correct_answer'] = correctAnswer;
                  slide['timer_seconds'] = timerSeconds;
                }
              });
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
            child: const Text('Simpan Perubahan', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ),
  );
}

class QuizizzScreen extends StatelessWidget {
  // PENTING (fitur "Manajemen Kelas"): kalau dibuka dari dalam sebuah kelas
  // (lewat class_screen.dart), classId & className akan terisi, dan SEMUA
  // kuis/PR/presentasi/flashcard yang dibuat/ditampilkan di dalam modul ini
  // otomatis terikat ke kelas tersebut (lihat QuizizzService.currentClassId).
  // Kalau null (mode lama / akses langsung), berperilaku seperti sebelumnya.
  final String? classId;
  final String? className;

  const QuizizzScreen({super.key, this.classId, this.className});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final isDosen = user?['role'] == 'dosen';

    // Set konteks kelas aktif di service SEBELUM flow dibangun, supaya semua
    // pemanggilan create/list kuis-PR-presentasi-flashcard di bawah modul
    // ini otomatis ter-scope ke kelas ini tanpa perlu mengubah setiap
    // pemanggilan satu per satu.
    QuizizzService.currentClassId = classId;
    QuizizzService.currentClassName = className;

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.5),
          child: Container(color: _kNavyDark, height: 1.5),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _kQuizizzPastelBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _kNavyDark, width: 1.2),
              ),
              child: const Row(
                children: [
                  Icon(Icons.quiz_rounded, color: _kQuizizzTextColor, size: 16),
                  SizedBox(width: 4),
                  Text('Classly', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kQuizizzTextColor)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                className != null
                    ? '$className${isDosen ? " (Dosen)" : " (Mahasiswa)"}'
                    : (isDosen ? 'Classly Hub (Dosen)' : 'Classly Arena, PR & Flashcards (Mahasiswa)'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: _kNavyDark),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: isDosen ? const _DosenFlow() : const _MahasiswaFlow(),
    );
  }
}

// ======================================================================
// ALUR DOSEN
// ======================================================================
class _DosenFlow extends StatefulWidget {
  const _DosenFlow();

  @override
  State<_DosenFlow> createState() => _DosenFlowState();
}

class _DosenFlowState extends State<_DosenFlow> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = false;
  List<dynamic> _myQuizzes = [];
  Set<String> _doneQuizIds = {};
  Set<String> _homeworkOnlyQuizIds = {};
  List<Map<String, dynamic>> _flashcardSets = [];
  List<Map<String, dynamic>> _lessons = [];
  List<Map<String, dynamic>> _assignedHomeworkList = [];
  final Set<String> _locallyDeletedHwIds = {};
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _loadAllData();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _fetchHomeworkList());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _fetchHomeworkList() async {
    // includeDraft: true — halaman Dosen HARUS bisa melihat PR berstatus
    // draft (baru dibuat, belum ditekan "Aktifkan") supaya tombol Aktifkan
    // bisa ditampilkan. Halaman Mahasiswa tidak pernah memakai includeDraft.
    final list = await QuizizzService.getAssignedHomework(includeDraft: true);
    list.removeWhere((h) {
      final id = h['id']?.toString() ?? '';
      final qId = h['quiz_id']?.toString() ?? '';
      return _locallyDeletedHwIds.contains(id) ||
          _locallyDeletedHwIds.contains(qId) ||
          _locallyDeletedHwIds.contains('hw_$qId');
    });
    if (mounted) {
      setState(() {
        _assignedHomeworkList = list;
      });
    }
  }

  Future<void> _loadAllData() async {
    setState(() => _loading = true);
    await _loadQuizzes();
    await _loadFlashcardSets();
    await _loadLessons();
    await _fetchHomeworkList();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadQuizzes() async {
    try {
      final res = await QuizizzService.getMyQuizzes();
      List quizzes = res['quizzes'] ?? [];
      Set<String> doneIds = {};
      for (final q in quizzes) {
        final qId = q['id']?.toString() ?? '';
        if (await QuizizzService.hasLiveQuizBeenDone(qId)) {
          doneIds.add(qId);
        }
      }
      final homeworkOnlyIds = await QuizizzService.getHomeworkOnlyQuizIds();
      if (mounted) {
        setState(() {
          _myQuizzes = quizzes;
          _doneQuizIds = doneIds;
          _homeworkOnlyQuizIds = homeworkOnlyIds;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadFlashcardSets() async {
    try {
      final sets = await QuizizzService.getFlashcardSets();
      if (mounted) setState(() => _flashcardSets = sets);
    } catch (_) {}
  }

  Future<void> _loadLessons() async {
    try {
      final lessons = await QuizizzService.getLessons();
      if (mounted) setState(() => _lessons = lessons);
    } catch (_) {}
  }

  // ----------------------------------------------------------------------
  // DIALOG BUAT KUIS GAMIFIKASI BARU
  // ----------------------------------------------------------------------
  Future<void> _createQuizDialog() async {
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Text('🎮 Buat Kuis Gamifikasi Baru', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        // FITUR "Perbaikan Kolom Melebar" (poin 1): AlertDialog secara
        // default membungkus content-nya dengan IntrinsicWidth, sehingga
        // kalau ada TextField dengan kata panjang tanpa spasi, dialog ikut
        // melebar mengikuti panjang teks tersebut alih-alih membuat teksnya
        // turun ke baris berikutnya. Dibungkus SizedBox lebar tetap supaya
        // dialog tidak lagi ikut melebar.
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: 'Judul Kuis Gamifikasi',
                  labelStyle: const TextStyle(color: Colors.black54),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kMustardYellow, width: 2)),
                  filled: true,
                  fillColor: _kCreamBg,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                style: const TextStyle(color: _kNavyDark),
                // Deskripsi dibuat multi-baris (bukan 1 baris) supaya kata
                // yang tidak muat otomatis TURUN KE BAWAH, bukan membuat
                // field/dialog melebar ke samping.
                maxLines: 3,
                minLines: 1,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: 'Deskripsi singkat (opsional)',
                  labelStyle: const TextStyle(color: Colors.black54),
                  alignLabelWithHint: true,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kMustardYellow, width: 2)),
                  filled: true,
                  fillColor: _kCreamBg,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: _kNavyDark))),
          ElevatedButton(
            onPressed: () async {
              if (titleCtrl.text.trim().isEmpty) return;
              try {
                await QuizizzService.createQuiz(titleCtrl.text.trim(), descCtrl.text.trim());
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Error: $e')));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
            child: const Text('Simpan Kuis', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (created == true) _loadQuizzes();
  }

  // ----------------------------------------------------------------------
  // DIALOG KELOLA & TAMBAH SOAL GAMIFIKASI (MULTI-TIPE, GAMBAR, TIMER)
  // ----------------------------------------------------------------------
  Future<void> _manageQuestionsDialog(dynamic quiz, {bool isHomework = false}) async {
    final quizId = quiz['id'].toString();
    final quizTitle = quiz['title'] ?? 'Kuis Gamifikasi';
    List<Map<String, dynamic>> questions = await QuizizzService.getCustomQuestions(quizId);
    final initialSettings = await QuizizzService.getQuizSettings(quizId);
    bool shuffleQuestions = initialSettings['shuffle_questions'] == true;
    bool shuffleAnswers = initialSettings['shuffle_answers'] == true;

    if (!mounted) return;

    final qTextCtrl = TextEditingController();
    final imgUrlCtrl = TextEditingController();
    final optACtrl = TextEditingController();
    final optBCtrl = TextEditingController();
    final optCCtrl = TextEditingController();
    final optDCtrl = TextEditingController();

    String selectedType = 'multiple_choice';
    // PR/Pekerjaan Rumah TIDAK memakai fitur timer (dikerjakan mandiri kapan
    // saja oleh mahasiswa), jadi timer di-set null (tanpa batas waktu).
    int? selectedTimer = isHomework ? null : 30;
    int singleCorrectIndex = 0;
    String trueFalseCorrect = 'Benar';
    Set<int> multiCorrectIndices = {0};
    String? uploadedImageBase64;
    final shortAnswerCorrectCtrl = TextEditingController();
    // FITUR "Gambar di Jawaban PG" (poin 5): gambar opsional untuk
    // masing-masing opsi jawaban (Pilihan Ganda & Multi-Select), sejajar
    // index dengan optACtrl..optDCtrl (A=0, B=1, C=2, D=3).
    List<String?> optionImagesBase64 = List<String?>.filled(4, null);
    // FITUR "Edit Soal yang Sudah Ditambahkan" (poin 4): kalau tidak null,
    // berarti form di atas sedang MENGEDIT soal pada index ini (bukan
    // menambah soal baru) -- submit akan meng-UPDATE soal tsb di tempat.
    int? editingIndex;

    bool isVariableCalc = false;
    int varCount = 3;
    List<String> varNames = ['a', 'b', 'c', 'd', 'e'];
    List<TextEditingController> varMinCtrls = List.generate(5, (_) => TextEditingController(text: '1'));
    List<TextEditingController> varMaxCtrls = List.generate(5, (_) => TextEditingController(text: '10'));
    final formulaCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) {
          void addQuestionAction() async {
            if (qTextCtrl.text.trim().isEmpty) return;
            if (selectedType == 'short_answer' && shortAnswerCorrectCtrl.text.trim().isEmpty) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Isi jawaban benar untuk soal Jawaban Singkat ini')));
              return;
            }

            List<String> currentOptions = [];
            String correctVal = '';
            List<String>? correctListVal;

            if (selectedType == 'multiple_choice') {
              currentOptions = [
                optACtrl.text.trim().isEmpty ? 'Opsi A' : optACtrl.text.trim(),
                optBCtrl.text.trim().isEmpty ? 'Opsi B' : optBCtrl.text.trim(),
                optCCtrl.text.trim().isEmpty ? 'Opsi C' : optCCtrl.text.trim(),
                optDCtrl.text.trim().isEmpty ? 'Opsi D' : optDCtrl.text.trim(),
              ];
              correctVal = currentOptions[singleCorrectIndex];
            } else if (selectedType == 'true_false') {
              currentOptions = ['Benar', 'Salah'];
              correctVal = trueFalseCorrect;
            } else if (selectedType == 'multi_select') {
              currentOptions = [
                optACtrl.text.trim().isEmpty ? 'Opsi A' : optACtrl.text.trim(),
                optBCtrl.text.trim().isEmpty ? 'Opsi B' : optBCtrl.text.trim(),
                optCCtrl.text.trim().isEmpty ? 'Opsi C' : optCCtrl.text.trim(),
                optDCtrl.text.trim().isEmpty ? 'Opsi D' : optDCtrl.text.trim(),
              ];
              correctListVal = multiCorrectIndices.map((idx) => currentOptions[idx]).toList();
              correctVal = (correctListVal != null && correctListVal.isNotEmpty) ? correctListVal.first : currentOptions.first;
            } else if (selectedType == 'short_answer') {
              // Jawaban Singkat: tanpa opsi pilihan, mahasiswa mengetik
              // jawaban bebas yang dicocokkan dengan teks jawaban benar ini.
              currentOptions = [];
              correctVal = shortAnswerCorrectCtrl.text.trim();
            }

            final imageVal = uploadedImageBase64 ?? (imgUrlCtrl.text.trim().isEmpty || imgUrlCtrl.text.startsWith('[Gambar') ? null : imgUrlCtrl.text.trim());
            // Gambar per-opsi hanya relevan untuk tipe soal yang punya opsi
            // (multiple_choice & multi_select); dipangkas sesuai jumlah opsi.
            final optionImagesVal = (selectedType == 'multiple_choice' || selectedType == 'multi_select')
                ? optionImagesBase64.take(currentOptions.length).toList()
                : null;

            String? variableCalcJson;
            if (isVariableCalc) {
               List<Map<String, dynamic>> vars = [];
               for (int i=0; i<varCount; i++) {
                 vars.add({
                   'name': varNames[i],
                   'min': int.tryParse(varMinCtrls[i].text) ?? 1,
                   'max': int.tryParse(varMaxCtrls[i].text) ?? 10,
                 });
               }
               variableCalcJson = jsonEncode({
                 'count': varCount,
                 'variables': vars,
                 'correct_index': singleCorrectIndex,
               });
               selectedType = 'multiple_choice';
               currentOptions = [
                 optACtrl.text.trim().isEmpty ? 'Opsi A' : optACtrl.text.trim(),
                 optBCtrl.text.trim().isEmpty ? 'Opsi B' : optBCtrl.text.trim(),
                 optCCtrl.text.trim().isEmpty ? 'Opsi C' : optCCtrl.text.trim(),
                 optDCtrl.text.trim().isEmpty ? 'Opsi D' : optDCtrl.text.trim(),
               ];
               correctVal = currentOptions[singleCorrectIndex];
            }

            final newQ = {
              'question': qTextCtrl.text.trim(),
              'type': selectedType,
              'options': currentOptions,
              'correct': correctVal,
              'correct_list': correctListVal,
              'image_url': imageVal,
              'option_images': optionImagesVal,
              'timer_seconds': isHomework ? null : selectedTimer,
              if (variableCalcJson != null) 'variable_calc_json': variableCalcJson,
            };

            bool saved;
            final isEditing = editingIndex != null;
            if (isEditing) {
              // FITUR "Edit Soal yang Sudah Ditambahkan" (poin 4): update
              // soal di posisi index yang sama (bukan menambah soal baru
              // di akhir daftar), lalu simpan seluruh daftar.
              questions[editingIndex!] = newQ;
              saved = await QuizizzService.saveCustomQuestions(quizId, questions);
            } else {
              saved = await QuizizzService.addCustomQuestion(quizId, newQ);
            }
            if (!saved) {
              // Simpan GAGAL (biasanya kuota penyimpanan browser penuh akibat
              // gambar terlalu besar) — beri tahu dosen dengan jelas, JANGAN
              // bersihkan form / tampilkan pesan sukses palsu, supaya soal
              // yang baru diisi tidak terlihat "menghilang" tanpa penjelasan.
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text('❌ Gagal menyimpan soal (kemungkinan ukuran gambar terlalu besar). Coba gunakan gambar yang lebih kecil atau URL gambar.'),
                    backgroundColor: Colors.redAccent,
                    duration: Duration(seconds: 4),
                  ),
                );
              }
              return;
            }

            final updated = await QuizizzService.getCustomQuestions(quizId);
            setDState(() {
              questions = updated;
              uploadedImageBase64 = null;
              optionImagesBase64 = List<String?>.filled(4, null);
              editingIndex = null;
            });
            // PR: sinkronkan soal ke backend supaya mahasiswa di device lain
            // langsung bisa mengerjakan soal terbaru ini.
            if (isHomework) {
              QuizizzService.syncLocalQuestionsToBackend(quizId);
            }

            qTextCtrl.clear();
            imgUrlCtrl.clear();
            optACtrl.clear();
            optBCtrl.clear();
            optCCtrl.clear();
            optDCtrl.clear();
            shortAnswerCorrectCtrl.clear();

            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(isEditing ? '✅ Soal Berhasil Diperbarui!' : '✅ Soal Gamifikasi Berhasil Ditambahkan!'), backgroundColor: _kNavyDark, duration: const Duration(seconds: 1)));
            }
          }

          // FITUR "Edit Soal yang Sudah Ditambahkan" (poin 4): isi ulang
          // semua field form dengan data soal pada index tsb, supaya
          // dosen tinggal mengubah bagian yang perlu lalu menekan "Update
          // Soal" (bukan menulis ulang dari awal).
          void startEditQuestion(int idx) {
            final q = questions[idx];
            final qType = (q['type'] ?? 'multiple_choice').toString();
            final opts = (q['options'] as List?)?.map((e) => e.toString()).toList() ?? [];
            final optImgs = (q['option_images'] as List?)?.map((e) => e?.toString()).toList() ?? [];
            setDState(() {
              editingIndex = idx;
              selectedType = qType;
              qTextCtrl.text = (q['question'] ?? '').toString();
              selectedTimer = isHomework ? null : (q['timer_seconds'] is int ? q['timer_seconds'] as int : 30);
              uploadedImageBase64 = (q['image_url'] != null && q['image_url'].toString().isNotEmpty) ? q['image_url'].toString() : null;
              imgUrlCtrl.text = uploadedImageBase64 != null ? '[Gambar Komputer Terpilih]' : '';
              optionImagesBase64 = List<String?>.generate(4, (i) => i < optImgs.length ? optImgs[i] : null);

              optACtrl.text = opts.isNotEmpty ? opts[0] : '';
              optBCtrl.text = opts.length > 1 ? opts[1] : '';
              optCCtrl.text = opts.length > 2 ? opts[2] : '';
              optDCtrl.text = opts.length > 3 ? opts[3] : '';
              shortAnswerCorrectCtrl.text = qType == 'short_answer' ? (q['correct'] ?? '').toString() : '';
              
              if (q['variable_calc_json'] != null) {
                isVariableCalc = true;
                selectedType = 'multiple_choice';
                try {
                  final vData = jsonDecode(q['variable_calc_json'].toString());
                  varCount = vData['count'] ?? 3;
                  final vList = vData['variables'] as List? ?? [];
                  for (int i=0; i<vList.length; i++) {
                    varNames[i] = vList[i]['name'] ?? 'a';
                    varMinCtrls[i].text = (vList[i]['min'] ?? 1).toString();
                    varMaxCtrls[i].text = (vList[i]['max'] ?? 10).toString();
                  }
                  if (vData['correct_index'] is int) {
                    singleCorrectIndex = vData['correct_index'] as int;
                  }
                } catch (_) {}
              } else {
                isVariableCalc = false;
              }

              if (qType == 'multiple_choice') {
                final correctStr = (q['correct'] ?? '').toString();
                final foundIdx = opts.indexOf(correctStr);
                singleCorrectIndex = foundIdx >= 0 ? foundIdx : 0;
              } else if (qType == 'true_false') {
                trueFalseCorrect = (q['correct'] ?? 'Benar').toString();
              } else if (qType == 'multi_select') {
                final correctListRaw = (q['correct_list'] as List?)?.map((e) => e.toString()).toList() ?? [];
                multiCorrectIndices = correctListRaw.map((c) => opts.indexOf(c)).where((i) => i >= 0).toSet();
                if (multiCorrectIndices.isEmpty) multiCorrectIndices = {0};
              }
            });
          }

          void uploadQuestionsFromExcel() {
            ExportHelper.pickFileBytesWeb((filename, bytes) async {
              final imported = ExportHelper.parseQuestionsFromExcel(bytes, defaultTimer: isHomework ? null : 30);
              if (imported.isEmpty) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('⚠️ Tidak ada soal yang valid ditemukan di file Excel ini.'), backgroundColor: Colors.orange),
                  );
                }
                return;
              }
              questions.addAll(imported);
              final ok = await QuizizzService.saveCustomQuestions(quizId, questions);
              if (ok) {
                final updated = await QuizizzService.getCustomQuestions(quizId);
                setDState(() {
                  questions = updated;
                });
                if (isHomework) {
                  QuizizzService.syncLocalQuestionsToBackend(quizId);
                }
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text('✅ Berhasil mengimpor ${imported.length} soal dari file "$filename"!'),
                      backgroundColor: const Color(0xFF16A34A),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              }
            });
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
            title: Row(
              children: [
                const Icon(Icons.edit_note_rounded, color: _kNavyDark),
                const SizedBox(width: 8),
                Expanded(child: Text('Kelola Soal: $quizTitle', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                  child: Text('Total Soal: ${questions.length}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                ),
              ],
            ),
            content: SizedBox(
              width: 620,
              height: 560,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FITUR UNDUH TEMPLATE & UNGGAH SOAL EXCEL
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF16A34A).withOpacity(0.4), width: 1.2),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.table_view_rounded, color: Color(0xFF15803D), size: 24),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Template & Impor Excel:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF166534))),
                                SizedBox(height: 2),
                                Text('Unduh template format Excel (.xlsx) atau unggah kumpulan soal secara instan.', style: TextStyle(fontSize: 11, color: Colors.black54)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => ExportHelper.downloadQuestionsTemplateExcel(title: quizTitle),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF15803D),
                              side: const BorderSide(color: Color(0xFF15803D), width: 1.2),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.download_rounded, size: 16),
                            label: const Text('Unduh Template', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: uploadQuestionsFromExcel,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.upload_file_rounded, size: 16),
                            label: const Text('Unggah Excel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),

                    // PENGATURAN ANTI-MENCONTEK: ACAK SOAL & ACAK JAWABAN
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _kNavyDark.withOpacity(0.3), width: 1.2),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.tune_rounded, size: 18, color: _kNavyDark),
                              SizedBox(width: 8),
                              Text(
                                'Pengaturan Kuis (Anti-Mencontek):',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity: ListTileControlAffinity.leading,
                                  activeColor: _kNavyDark,
                                  title: const Text('🔀 Acak Urutan Soal', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _kNavyDark)),
                                  subtitle: const Text('Urutan soal diacak tiap siswa', style: TextStyle(fontSize: 11, color: Colors.black54)),
                                  value: shuffleQuestions,
                                  onChanged: (v) {
                                    setDState(() => shuffleQuestions = v ?? false);
                                    QuizizzService.saveQuizSettings(quizId, {
                                      'shuffle_questions': shuffleQuestions,
                                      'shuffle_answers': shuffleAnswers,
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity: ListTileControlAffinity.leading,
                                  activeColor: _kNavyDark,
                                  title: const Text('🔀 Acak Pilihan Jawaban', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _kNavyDark)),
                                  subtitle: const Text('Urutan A, B, C, D diacak tiap siswa', style: TextStyle(fontSize: 11, color: Colors.black54)),
                                  value: shuffleAnswers,
                                  onChanged: (v) {
                                    setDState(() => shuffleAnswers = v ?? false);
                                    QuizizzService.saveQuizSettings(quizId, {
                                      'shuffle_questions': shuffleQuestions,
                                      'shuffle_answers': shuffleAnswers,
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // FORM TAMBAH SOAL BARU
                    const Text('✨ Input Soal & Jawaban Kuis:', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: _kNavyDark)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (isVariableCalc) ...[
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFCBD5E1)),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.format_list_bulleted_rounded, size: 18, color: _kNavyDark),
                                  SizedBox(width: 8),
                                  Text('Tipe Soal: Pilihan Ganda (1 Jawaban)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                                ],
                              ),
                            ),
                          ),
                        ] else ...[
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: selectedType,
                              decoration: const InputDecoration(labelText: 'Tipe Soal', border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(value: 'multiple_choice', child: Text('Pilihan Ganda (1 Jawaban)')),
                                DropdownMenuItem(value: 'true_false', child: Text('Benar / Salah')),
                                DropdownMenuItem(value: 'multi_select', child: Text('Multi-Select (Jawaban Banyak)')),
                                DropdownMenuItem(value: 'short_answer', child: Text('Jawaban Singkat')),
                              ],
                              onChanged: (v) => setDState(() => selectedType = v!),
                            ),
                          ),
                        ],
                        // PR tidak memakai timer sama sekali — dropdown timer
                        // hanya tampil untuk Kuis Gamifikasi Live.
                        if (!isHomework) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: selectedTimer ?? 30,
                              decoration: const InputDecoration(labelText: 'Timer (Detik)', border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(value: 10, child: Text('10 Detik')),
                                DropdownMenuItem(value: 20, child: Text('20 Detik')),
                                DropdownMenuItem(value: 30, child: Text('30 Detik')),
                                DropdownMenuItem(value: 60, child: Text('60 Detik')),
                              ],
                              onChanged: (v) => setDState(() => selectedTimer = v!),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    // FITUR VARIABLE CALCULATIONS
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFF0F172A).withOpacity(0.5)),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.blue.withOpacity(0.05),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CheckboxListTile(
                            title: const Text('Variable Calculations (Angka Acak Tiap Siswa)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))),
                            subtitle: const Text('Tulis variabel [a], [b], dsb di teks soal & rumus pada tiap opsi jawaban A, B, C, D.', style: TextStyle(fontSize: 11)),
                            value: isVariableCalc,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            activeColor: const Color(0xFFFBBF24),
                            checkColor: const Color(0xFF0F172A),
                            onChanged: (v) => setDState(() {
                              isVariableCalc = v ?? false;
                              if (isVariableCalc) {
                                selectedType = 'multiple_choice';
                              }
                            }),
                          ),
                          if (isVariableCalc) ...[
                            const SizedBox(height: 8),
                            DropdownButtonFormField<int>(
                              value: varCount,
                              decoration: const InputDecoration(labelText: 'Jumlah Variabel', border: OutlineInputBorder(), isDense: true),
                              items: [1,2,3,4,5].map((e) => DropdownMenuItem(value: e, child: Text('$e Variabel'))).toList(),
                              onChanged: (v) => setDState(() => varCount = v ?? 3),
                            ),
                            const SizedBox(height: 8),
                            for (int i=0; i<varCount; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8.0),
                                child: Row(
                                  children: [
                                    Expanded(flex: 2, child: Text('Var [${varNames[i]}]:', style: const TextStyle(fontWeight: FontWeight.bold))),
                                    Expanded(flex: 3, child: TextFormField(controller: varMinCtrls[i], decoration: const InputDecoration(labelText: 'Min', isDense: true, border: OutlineInputBorder()), keyboardType: TextInputType.number)),
                                    const SizedBox(width: 8),
                                    Expanded(flex: 3, child: TextFormField(controller: varMaxCtrls[i], decoration: const InputDecoration(labelText: 'Max', isDense: true, border: OutlineInputBorder()), keyboardType: TextInputType.number)),
                                  ],
                                ),
                              ),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFF59E0B))),
                              child: const Row(
                                children: [
                                  Icon(Icons.lightbulb_outline_rounded, color: Color(0xFFB45309), size: 18),
                                  SizedBox(width: 8),
                                  Expanded(child: Text('Tulis rumus (misal: [1+[a] [b]-1 [c]^2] atau a+b) pada masing-masing kotak Opsi A, B, C, D di bawah. Pilih 1 opsi sebagai jawaban BENAR (3 opsi lainnya otomatis sebagai jawaban SALAH).', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF92400E)))),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: qTextCtrl,
                      style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(labelText: 'Pertanyaan / Teks Soal', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: imgUrlCtrl,
                            decoration: const InputDecoration(labelText: 'URL Gambar / Base64 Soal (Opsional)', prefixIcon: Icon(Icons.image), border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            ExportHelper.pickImageWeb((base64Data) async {
                              if (base64Data.isNotEmpty) {
                                final compressed = await _compressImageDataUrlForStorage(base64Data);
                                setDState(() {
                                  uploadedImageBase64 = compressed;
                                  imgUrlCtrl.text = '[Gambar Komputer Terpilih]';
                                });
                              }
                            });
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: _kCreamBg, foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16)),
                          icon: const Icon(Icons.upload_file_rounded, size: 18),
                          label: const Text('📁 Upload from Computer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      ],
                    ),
                    if (uploadedImageBase64 != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF16A34A))),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 18),
                            const SizedBox(width: 8),
                            const Expanded(child: Text('🖼️ Gambar dari komputer berhasil dimuat dan siap disimpan!', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF15803D)))),
                            InkWell(
                              onTap: () {
                                setDState(() {
                                  uploadedImageBase64 = null;
                                  imgUrlCtrl.clear();
                                });
                              },
                              child: const Icon(Icons.cancel_rounded, color: Colors.redAccent, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),
                    const Divider(color: _kNavyDark, height: 1),
                    const SizedBox(height: 12),

                    // INPUT OPSI & JAWABAN BENAR DINAMIS
                    if (selectedType == 'multiple_choice') ...[
                      Text(isVariableCalc ? '🎯 Input Rumus Opsi Jawaban (Pilih 1 Rumus Benar):' : '🎯 Input Opsi Jawaban (Pilih 1 Jawaban Benar):', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                      const SizedBox(height: 8),
                      ...[
                        {'ctrl': optACtrl, 'idx': 0, 'label': 'Opsi A'},
                        {'ctrl': optBCtrl, 'idx': 1, 'label': 'Opsi B'},
                        {'ctrl': optCCtrl, 'idx': 2, 'label': 'Opsi C'},
                        {'ctrl': optDCtrl, 'idx': 3, 'label': 'Opsi D'},
                      ].map((item) {
                        final idx = item['idx'] as int;
                        final ctrl = item['ctrl'] as TextEditingController;
                        final label = item['label'] as String;
                        final isCorrect = singleCorrectIndex == idx;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Radio<int>(
                                    value: idx,
                                    groupValue: singleCorrectIndex,
                                    activeColor: _kNavyDark,
                                    onChanged: (v) => setDState(() => singleCorrectIndex = v!),
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrl,
                                      decoration: InputDecoration(
                                        labelText: label,
                                        hintText: isVariableCalc ? 'Rumus $label (mis. [1+[a] [b]-1 [c]^2] atau a+b)' : 'Ketik isi $label...',
                                        border: const OutlineInputBorder(),
                                        filled: isCorrect,
                                        fillColor: isCorrect ? const Color(0xFFDCFCE7) : null,
                                        suffixIcon: isCorrect ? const Icon(Icons.check_circle_rounded, color: Colors.green) : null,
                                      ),
                                    ),
                                  ),
                                  // FITUR "Gambar di Jawaban PG" (poin 5): gambar
                                  // opsional untuk opsi jawaban ini.
                                  IconButton(
                                    tooltip: 'Gambar opsi ini',
                                    icon: Icon(optionImagesBase64[idx] == null ? Icons.image_outlined : Icons.image, color: _kNavyDark, size: 20),
                                    onPressed: () {
                                      ExportHelper.pickImageWeb((base64Data) async {
                                        if (base64Data.isEmpty) return;
                                        final compressed = await _compressImageDataUrlForStorage(base64Data);
                                        setDState(() => optionImagesBase64[idx] = compressed);
                                      });
                                    },
                                  ),
                                  if (optionImagesBase64[idx] != null)
                                    IconButton(
                                      icon: const Icon(Icons.close, color: Colors.redAccent, size: 18),
                                      onPressed: () => setDState(() => optionImagesBase64[idx] = null),
                                    ),
                                ],
                              ),
                              if (optionImagesBase64[idx] != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 44, right: 8, bottom: 4),
                                  child: SizedBox(height: 90, child: _buildQuestionImageWidget(optionImagesBase64[idx]!)),
                                ),
                            ],
                          ),
                        );
                      }),
                    ] else if (selectedType == 'true_false') ...[
                      const Text('🎯 Pilih Jawaban Kuis yang Benar:', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: RadioListTile<String>(
                              title: const Text('Benar (True)', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                              value: 'Benar',
                              groupValue: trueFalseCorrect,
                              activeColor: _kNavyDark,
                              onChanged: (v) => setDState(() => trueFalseCorrect = v!),
                            ),
                          ),
                          Expanded(
                            child: RadioListTile<String>(
                              title: const Text('Salah (False)', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                              value: 'Salah',
                              groupValue: trueFalseCorrect,
                              activeColor: _kNavyDark,
                              onChanged: (v) => setDState(() => trueFalseCorrect = v!),
                            ),
                          ),
                        ],
                      ),
                    ] else if (selectedType == 'multi_select') ...[
                      const Text('🎯 Input Opsi Jawaban (Centang SEMUA Jawaban Benar):', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                      const SizedBox(height: 8),
                      ...[
                        {'ctrl': optACtrl, 'idx': 0, 'label': 'Opsi A'},
                        {'ctrl': optBCtrl, 'idx': 1, 'label': 'Opsi B'},
                        {'ctrl': optCCtrl, 'idx': 2, 'label': 'Opsi C'},
                        {'ctrl': optDCtrl, 'idx': 3, 'label': 'Opsi D'},
                      ].map((item) {
                        final idx = item['idx'] as int;
                        final ctrl = item['ctrl'] as TextEditingController;
                        final label = item['label'] as String;
                        final isChecked = multiCorrectIndices.contains(idx);

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Checkbox(
                                    value: isChecked,
                                    activeColor: _kNavyDark,
                                    onChanged: (v) {
                                      setDState(() {
                                        if (v == true) {
                                          multiCorrectIndices.add(idx);
                                        } else {
                                          if (multiCorrectIndices.length > 1) {
                                            multiCorrectIndices.remove(idx);
                                          }
                                        }
                                      });
                                    },
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrl,
                                      decoration: InputDecoration(
                                        labelText: label,
                                        hintText: 'Ketik isi $label...',
                                        border: const OutlineInputBorder(),
                                        filled: isChecked,
                                        fillColor: isChecked ? const Color(0xFFDCFCE7) : null,
                                        suffixIcon: isChecked ? const Icon(Icons.check_circle_rounded, color: Colors.green) : null,
                                      ),
                                    ),
                                  ),
                                  // FITUR "Gambar di Jawaban PG" (poin 5).
                                  IconButton(
                                    tooltip: 'Gambar opsi ini',
                                    icon: Icon(optionImagesBase64[idx] == null ? Icons.image_outlined : Icons.image, color: _kNavyDark, size: 20),
                                    onPressed: () {
                                      ExportHelper.pickImageWeb((base64Data) async {
                                        if (base64Data.isEmpty) return;
                                        final compressed = await _compressImageDataUrlForStorage(base64Data);
                                        setDState(() => optionImagesBase64[idx] = compressed);
                                      });
                                    },
                                  ),
                                  if (optionImagesBase64[idx] != null)
                                    IconButton(
                                      icon: const Icon(Icons.close, color: Colors.redAccent, size: 18),
                                      onPressed: () => setDState(() => optionImagesBase64[idx] = null),
                                    ),
                                ],
                              ),
                              if (optionImagesBase64[idx] != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 44, right: 8, bottom: 4),
                                  child: SizedBox(height: 90, child: _buildQuestionImageWidget(optionImagesBase64[idx]!)),
                                ),
                            ],
                          ),
                        );
                      }),
                    ] else if (selectedType == 'short_answer') ...[
                      const Text('🎯 Jawaban Benar (Mahasiswa Mengetik Bebas):', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: shortAnswerCorrectCtrl,
                        decoration: const InputDecoration(labelText: 'Jawaban Benar', hintText: 'Contoh: Jakarta', border: OutlineInputBorder()),
                      ),
                      const SizedBox(height: 6),
                      const Text('(Jawaban mahasiswa dicocokkan otomatis, tidak peka huruf besar/kecil & spasi di awal-akhir)', style: TextStyle(fontSize: 11, color: Colors.black45, fontStyle: FontStyle.italic)),
                    ],

                    const SizedBox(height: 14),
                    if (editingIndex != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFB45309))),
                        child: Row(
                          children: [
                            const Icon(Icons.edit_rounded, size: 16, color: Color(0xFFB45309)),
                            const SizedBox(width: 6),
                            Expanded(child: Text('Sedang mengedit Soal ${editingIndex! + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF92400E)))),
                            InkWell(
                              onTap: () {
                                setDState(() {
                                  editingIndex = null;
                                  uploadedImageBase64 = null;
                                  optionImagesBase64 = List<String?>.filled(4, null);
                                });
                                qTextCtrl.clear();
                                imgUrlCtrl.clear();
                                optACtrl.clear();
                                optBCtrl.clear();
                                optCCtrl.clear();
                                optDCtrl.clear();
                                shortAnswerCorrectCtrl.clear();
                              },
                              child: const Text('Batal Edit', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFB45309), decoration: TextDecoration.underline)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: addQuestionAction,
                        style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, padding: const EdgeInsets.all(14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                        icon: Icon(editingIndex != null ? Icons.save_rounded : Icons.add_circle_rounded),
                        label: Text(editingIndex != null ? 'Update Soal Ini' : 'Simpan Soal Ke Kuis', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                    ),

                    // JIKA ADA SOAL TERIMPAN, TAMPILKAN DAFTAR RINGKAS DENGAN TOMBOL HAPUS SOAL
                    if (questions.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Divider(color: _kNavyDark, height: 1),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Daftar Soal Tersimpan (${questions.length}):', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...questions.asMap().entries.map((e) {
                        final idx = e.key;
                        final q = e.value;
                        final qType = q['type'] ?? 'multiple_choice';
                        final opts = (q['options'] as List?) ?? [];
                        final correct = q['correct'];
                        final correctList = (q['correct_list'] as List?) ?? [];

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.2)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kNavyDark, width: 1)),
                                    child: Text('Soal ${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark)),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kNavyDark, width: 1)),
                                    child: Text(qType == 'true_false' ? 'Benar / Salah' : (qType == 'multi_select' ? 'Multi-Select' : (qType == 'short_answer' ? 'Jawaban Singkat' : 'Pilihan Ganda')), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kQuizizzTextColor)),
                                  ),
                                  const Spacer(),
                                  if (!isHomework) ...[
                                    Text('⏱️ ${q['timer_seconds'] ?? 30}s', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark)),
                                    const SizedBox(width: 8),
                                  ],
                                  // FITUR "Edit Soal yang Sudah Ditambahkan" (poin 4).
                                  InkWell(
                                    onTap: () => startEditQuestion(idx),
                                    child: const Padding(
                                      padding: EdgeInsets.all(4.0),
                                      child: Icon(Icons.edit_rounded, size: 20, color: _kNavyDark),
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () async {
                                      questions.removeAt(idx);
                                      await QuizizzService.saveCustomQuestions(quizId, questions);
                                      setDState(() {});
                                      if (isHomework) {
                                        QuizizzService.syncLocalQuestionsToBackend(quizId);
                                      }
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.all(4.0),
                                      child: Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(q['question'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kNavyDark)),
                              if (q['image_url'] != null && q['image_url'].toString().isNotEmpty) ...[
                                Builder(builder: (_) {
                                  final imgStr = q['image_url'].toString().trim();
                                  Widget imgWidget;

                                  if (imgStr.startsWith('data:image/') || imgStr.contains(';base64,')) {
                                    try {
                                      final base64Part = imgStr.contains(',') ? imgStr.split(',').last : imgStr;
                                      final bytes = base64Decode(base64Part);
                                      imgWidget = Image.memory(
                                        bytes,
                                        height: 160,
                                        width: double.infinity,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) => const Padding(
                                          padding: EdgeInsets.all(8.0),
                                          child: Text('⚠️ Gambar tidak dapat dimuat', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                                        ),
                                      );
                                    } catch (_) {
                                      imgWidget = const Padding(
                                        padding: EdgeInsets.all(8.0),
                                        child: Text('🖼️ Gambar Soal', style: TextStyle(fontSize: 11, color: Colors.blueAccent)),
                                      );
                                    }
                                  } else if (imgStr.startsWith('http://') || imgStr.startsWith('https://')) {
                                    imgWidget = Image.network(
                                      imgStr,
                                      height: 160,
                                      width: double.infinity,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => const Padding(
                                        padding: EdgeInsets.all(8.0),
                                        child: Text('⚠️ URL Gambar tidak valid', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                                      ),
                                    );
                                  } else {
                                    imgWidget = Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Text('🖼️ $imgStr', style: const TextStyle(fontSize: 11, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                                    );
                                  }

                                  return Container(
                                    margin: const EdgeInsets.only(top: 8, bottom: 8),
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: _kNavyDark, width: 1.2),
                                      boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(2, 2), blurRadius: 0)],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: imgWidget,
                                    ),
                                  );
                                }),
                              ],
                              const SizedBox(height: 10),
                              if (qType == 'short_answer') ...[
                                Row(
                                  children: [
                                    const Text('Jawaban Benar: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.black54)),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.green.shade700, width: 1.5)),
                                      child: Text(correct?.toString() ?? '', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.green.shade900)),
                                    ),
                                  ],
                                ),
                              ] else ...[
                              const Text('Opsi Jawaban:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.black54)),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: opts.map((opt) {
                                  final optStr = opt.toString();
                                  final isCorrect = (qType == 'multi_select')
                                      ? (correctList.contains(optStr) || optStr == correct)
                                      : (optStr == correct);

                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: isCorrect ? const Color(0xFFDCFCE7) : Colors.white,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: isCorrect ? Colors.green.shade700 : _kNavyDark, width: isCorrect ? 1.5 : 1),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (isCorrect) ...[
                                          const Icon(Icons.check_circle, size: 14, color: Colors.green),
                                          const SizedBox(width: 4),
                                        ],
                                        Text(
                                          optStr,
                                          style: TextStyle(
                                            fontWeight: isCorrect ? FontWeight.bold : FontWeight.w600,
                                            fontSize: 12,
                                            color: isCorrect ? Colors.green.shade900 : _kNavyDark,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                              ],
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Finish & Save Quiz', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
              ),
            ],
          );
        },
      ),
    );
  }

  // ----------------------------------------------------------------------
  // DIALOG ASSIGN HOMEWORK (PR) UNTUK DOSEN
  // ----------------------------------------------------------------------
  Future<void> _assignHomeworkDialog(dynamic quiz) async {
    final quizId = quiz['id'].toString();
    final title = quiz['title'] ?? 'Kuis Gamifikasi';
    DateTime selectedDeadline = DateTime.now().add(const Duration(days: 3));

    final assigned = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
          title: const Text('📝 Assign Kuis Sebagai Pekerjaan Rumah (PR)', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Kuis: $title', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark)),
              const SizedBox(height: 8),
              const Text('Tugas PR ini akan langsung muncul di portal/dashboard mahasiswa tanpa perlu memasukkan PIN atau scan QR.', style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 16),
              const Text('Pilih Tenggat Waktu (Deadline):', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => setDState(() => selectedDeadline = DateTime.now().add(const Duration(days: 1))),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: _kNavyDark, width: 1)),
                    child: const Text('1 Day', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                  ),
                  OutlinedButton(
                    onPressed: () => setDState(() => selectedDeadline = DateTime.now().add(const Duration(days: 3))),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: _kNavyDark, width: 1)),
                    child: const Text('3 Days', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                  ),
                  OutlinedButton(
                    onPressed: () => setDState(() => selectedDeadline = DateTime.now().add(const Duration(days: 7))),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: _kNavyDark, width: 1)),
                    child: const Text('7 Days', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () async {
                  final pickedDate = await showDatePicker(
                    context: ctx,
                    initialDate: selectedDeadline,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (pickedDate != null && ctx.mounted) {
                    final pickedTime = await showTimePicker(
                      context: ctx,
                      initialTime: TimeOfDay.fromDateTime(selectedDeadline),
                    );
                    if (pickedTime != null) {
                      setDState(() {
                        selectedDeadline = DateTime(
                          pickedDate.year,
                          pickedDate.month,
                          pickedDate.day,
                          pickedTime.hour,
                          pickedTime.minute,
                        );
                      });
                    } else {
                      setDState(() {
                        selectedDeadline = DateTime(
                          pickedDate.year,
                          pickedDate.month,
                          pickedDate.day,
                          23,
                          59,
                        );
                      });
                    }
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1.2)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '🗓️ Deadline: ${selectedDeadline.day}/${selectedDeadline.month}/${selectedDeadline.year} Jam ${selectedDeadline.hour.toString().padLeft(2, '0')}:${selectedDeadline.minute.toString().padLeft(2, '0')} WIB',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13),
                      ),
                      const Icon(Icons.edit_calendar_rounded, size: 20, color: _kNavyDark),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: _kNavyDark))),
            ElevatedButton(
              onPressed: () async {
                await QuizizzService.assignHomework(
                  quizId: quizId,
                  title: 'PR Mandiri: $title',
                  description: 'Tugas Pekerjaan Rumah Mandiri dari Dosen',
                  deadline: selectedDeadline,
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
              child: const Text('Assign Homework to Students', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (assigned == true && mounted) {
      final newHw = {
        'id': 'hw_${DateTime.now().millisecondsSinceEpoch}',
        'quiz_id': quizId,
        'title': 'PR Mandiri: $title',
        'description': 'Tugas Pekerjaan Rumah Mandiri dari Dosen',
        'deadline': selectedDeadline.toIso8601String(),
        'status': 'draft',
      };
      _assignedHomeworkList.insert(0, newHw);
      setState(() {});

      await _loadQuizzes();
      final freshList = await QuizizzService.getAssignedHomework(includeDraft: true);
      if (mounted) {
        setState(() {
          _assignedHomeworkList = freshList;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('📝 PR berhasil dibuat sebagai draft. Tekan "🚀 Aktifkan" agar tampil ke mahasiswa!'), backgroundColor: _kNavyDark));
      }
    }
  }

  // ----------------------------------------------------------------------
  // DIALOG BUAT LESSON (PRESENTASI INTERAKTIF)
  // ----------------------------------------------------------------------
  Future<void> _createLessonDialog() async {
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    // FITUR "Presentasi Kosong dari Awal" (poin 1): dulu presentasi baru
    // otomatis diisi 1 slide contoh ("Pengantar Materi"). Sekarang daftar
    // slide dimulai BENAR-BENAR KOSONG -- slide hanya akan terisi kalau
    // dosen sendiri yang menambahkannya (lewat tombol Tambah Slide Kuis,
    // upload PPT/PDF, atau upload gambar).
    List<Map<String, dynamic>> slides = [];
    bool isUploadingPpt = false;
    bool isUploadingPdf = false;
    String pdfResolution = '150';

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
          title: const Text('🖥️ Buat Presentasi Interaktif (Lesson Mode)', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
          content: SizedBox(
            width: 550,
            height: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: titleCtrl,
                    style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      labelText: 'Judul Presentasi Lesson',
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                      filled: true,
                      fillColor: _kCreamBg,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: descCtrl,
                    style: const TextStyle(color: _kNavyDark),
                    maxLines: 3,
                    minLines: 1,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      labelText: 'Deskripsi Singkat Presentasi',
                      alignLabelWithHint: true,
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                      filled: true,
                      fillColor: _kCreamBg,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(child: Text('Daftar Slide Presentasi & Kuis Interaktif:', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark))),
                      // FITUR "Indikator Jumlah Slide" (poin 2): badge jumlah
                      // slide yang SUDAH ditambahkan dosen sejauh ini,
                      // ter-update langsung setiap ada slide ditambah/dihapus.
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: slides.isEmpty ? const Color(0xFFFEE2E2) : const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: slides.isEmpty ? Colors.redAccent : const Color(0xFF16A34A), width: 1.2),
                        ),
                        child: Text(
                          '${slides.length} Slide',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: slides.isEmpty ? Colors.redAccent : const Color(0xFF15803D)),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: () {
                          setDState(() {
                            slides.add({
                              'title': 'Slide Kuis ${slides.length + 1}',
                              'type': 'quiz_mc',
                              'content': 'Soal kuis interaktif',
                              'media_url': null,
                              'options': ['Opsi A', 'Opsi B', 'Opsi C', 'Opsi D'],
                              'option_images': <String?>[null, null, null, null],
                              'correct_answer': 'Opsi A',
                              'timer_seconds': 30,
                            });
                          });
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Tambah Slide Kuis', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: isUploadingPpt || isUploadingPdf ? null : () {
                        _pickPptxFileWeb((fileBytes, fileName) async {
                          setDState(() => isUploadingPpt = true);
                          try {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('⏳ Memproses $fileName, membaca slide asli (teks & gambar)...'), backgroundColor: _kNavyDark, duration: const Duration(seconds: 2)),
                              );
                            }
                            final pptSlides = await QuizizzService.extractSlidesFromPptx(fileBytes, fileName);
                            if (pptSlides == null || pptSlides.isEmpty) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(content: Text('❌ Gagal mengekstrak slide dari file PPT ini.'), backgroundColor: Colors.redAccent),
                                );
                              }
                              return;
                            }
                            setDState(() {
                              for (final s in pptSlides) {
                                slides.add({
                                  'title': (s['title'] ?? 'Slide PPT ${slides.length + 1}').toString(),
                                  'type': (s['type'] ?? 'image').toString(),
                                  'content': (s['content'] ?? '').toString(),
                                  'media_url': s['media_url'],
                                });
                              }
                            });
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('✅ ${pptSlides.length} slide asli berhasil diambil dari $fileName!'), backgroundColor: const Color(0xFF16A34A)),
                              );
                            }
                          } finally {
                            setDState(() => isUploadingPpt = false);
                          }
                        });
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white),
                      icon: isUploadingPpt ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.slideshow_rounded, size: 16),
                      label: Text(isUploadingPpt ? '⏳ Sedang mengunggah & memproses PPT...' : '📊 Upload File PPT (.pptx) Langsung', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('File .pptx akan dibaca sesuai struktur aslinya — setiap slide (teks & gambar aslinya, tanpa kompresi) dipetakan 1:1 sesuai urutan asli di PowerPoint.', style: TextStyle(fontSize: 10, color: Colors.black54, fontStyle: FontStyle.italic)),
                  const SizedBox(height: 8),
                  const SizedBox(height: 8),
                  const Text('Pilih Resolusi Gambar PDF:', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 11)),
                  Row(
                    children: [
                      Expanded(
                        child: RadioListTile<String>(
                          title: const Text('Rendah (Lebih Cepat & Hemat)', style: TextStyle(fontSize: 10)),
                          value: '75',
                          groupValue: pdfResolution,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          onChanged: (v) => setDState(() => pdfResolution = v!),
                        ),
                      ),
                      Expanded(
                        child: RadioListTile<String>(
                          title: const Text('Sedang (Standar)', style: TextStyle(fontSize: 10)),
                          value: '150',
                          groupValue: pdfResolution,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          onChanged: (v) => setDState(() => pdfResolution = v!),
                        ),
                      ),
                      Expanded(
                        child: RadioListTile<String>(
                          title: const Text('Tinggi (File Besar)', style: TextStyle(fontSize: 10)),
                          value: '300',
                          groupValue: pdfResolution,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          onChanged: (v) => setDState(() => pdfResolution = v!),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: isUploadingPdf || isUploadingPpt ? null : () {
                        _pickPdfFileWeb((fileBytes, fileName) async {
                          setDState(() => isUploadingPdf = true);
                          try {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('⏳ Memproses $fileName, mengonversi ke gambar... (proses ini butuh waktu beberapa detik)'), backgroundColor: _kNavyDark, duration: const Duration(seconds: 4)),
                              );
                            }
                            final pdfSlides = await QuizizzService.extractSlidesFromPdf(fileBytes, fileName, resolution: pdfResolution);
                            if (pdfSlides == null || pdfSlides.isEmpty) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(content: Text('❌ Gagal mengekstrak PDF ini.'), backgroundColor: Colors.redAccent),
                                );
                              }
                              return;
                            }
                            setDState(() {
                              for (final s in pdfSlides) {
                                slides.add({
                                  'title': (s['title'] ?? 'Halaman PDF ${slides.length + 1}').toString(),
                                  'type': (s['type'] ?? 'image').toString(),
                                  'content': (s['content'] ?? '').toString(),
                                  'media_url': s['media_url'],
                                });
                              }
                            });
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('✅ ${pdfSlides.length} halaman berhasil diambil dari $fileName!'), backgroundColor: const Color(0xFF16A34A)),
                              );
                            }
                          } finally {
                            setDState(() => isUploadingPdf = false);
                          }
                        });
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
                      icon: isUploadingPdf ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.picture_as_pdf_rounded, size: 16),
                      label: Text(isUploadingPdf ? '⏳ Sedang mengonversi PDF (Mohon Tunggu)...' : '📄 Upload File PDF (.pdf) Langsung', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('PDF kini dikonversi menjadi GAMBAR UTUH per halaman untuk mempertahankan tata letak (layout) persis seperti aslinya — 1 halaman PDF = 1 slide gambar.', style: TextStyle(fontSize: 10, color: Colors.black54, fontStyle: FontStyle.italic)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _pickMultipleImagesWeb((imagesBase64) async {
                          final compressedList = <String>[];
                          for (final img in imagesBase64) {
                            compressedList.add(await _compressImageDataUrlForStorage(img));
                          }
                          setDState(() {
                            for (int i = 0; i < compressedList.length; i++) {
                              slides.add({
                                'title': 'Slide PPT ${slides.length + 1}',
                                'type': 'image',
                                'content': '',
                                'media_url': compressedList[i],
                              });
                            }
                          });
                        });
                      },
                      style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2)),
                      icon: const Icon(Icons.upload_file_rounded, size: 16),
                      label: const Text('📤 Or Upload Slide Images One by One from Computer', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('Tips: export/save PPT Anda sebagai gambar (JPG/PNG) per slide dari PowerPoint, lalu unggah semua gambarnya sekaligus di sini.', style: TextStyle(fontSize: 10, color: Colors.black54, fontStyle: FontStyle.italic)),
                  if (slides.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              backgroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              title: const Text('Hapus Semua Slide?', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                              content: Text('Semua ${slides.length} slide yang sudah ditambahkan akan dihapus.', style: const TextStyle(color: Colors.black87)),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(dctx, true),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                                  child: const Text('Hapus Semua'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            setDState(() => slides.clear());
                          }
                        },
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent, width: 1.2)),
                        icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                        label: const Text('🗑️ Delete All Slides', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    onReorder: (oldIndex, newIndex) {
                      setDState(() {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final item = slides.removeAt(oldIndex);
                        slides.insert(newIndex, item);
                      });
                    },
                    children: [
                      for (int idx = 0; idx < slides.length; idx++)
                        Container(
                          key: ValueKey(idx),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                          child: ListTile(
                            leading: Icon(
                              slides[idx]['type'] == 'text' ? Icons.text_snippet : (slides[idx]['type'] == 'image' ? Icons.image : Icons.quiz_rounded),
                              color: _kNavyDark,
                            ),
                            title: Text(slides[idx]['title'], style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                            subtitle: Text('Tipe: ${slides[idx]['type']}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                            // FITUR "Review Slide" (poin 2): dosen bisa
                            // membuka & meninjau ulang isi lengkap slide yang
                            // sudah ditambahkan (teks, gambar, soal & opsi
                            // jawabannya) sebelum presentasi disimpan.
                            onTap: () => _reviewOrEditSlideDialog(context, slides, idx, setDState),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Tinjau / Review Slide',
                                  icon: const Icon(Icons.visibility_outlined, color: _kNavyDark, size: 18),
                                  onPressed: () => _reviewOrEditSlideDialog(context, slides, idx, setDState),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                  onPressed: () {
                                    setDState(() => slides.removeAt(idx));
                                  },
                                ),
                                const Icon(Icons.drag_handle_rounded, color: _kNavyDark),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: _kNavyDark))),
            ElevatedButton(
              onPressed: () async {
                if (titleCtrl.text.trim().isEmpty) return;
                if (slides.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Tambahkan minimal 1 slide terlebih dahulu.')));
                  return;
                }
                final result = await QuizizzService.createLesson(
                  title: titleCtrl.text.trim(),
                  description: descCtrl.text.trim(),
                  slides: slides,
                );
                if (result.isEmpty || result.containsKey('error')) {
                  // Sebelumnya kegagalan ini ditelan diam-diam: dialog tetap
                  // ditutup seolah berhasil padahal presentasi TIDAK
                  // tersimpan sama sekali (paling sering karena payload
                  // terlalu besar akibat banyak gambar slide PPT).
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('❌ Gagal menyimpan presentasi. Coba kurangi jumlah/ukuran gambar slide, lalu simpan lagi.'), backgroundColor: Colors.redAccent, duration: Duration(seconds: 4)),
                    );
                  }
                  return;
                }
                if (ctx.mounted) Navigator.pop(ctx);
                _loadLessons();
              },
              style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
              child: const Text('Simpan Lesson', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------------
  // DIALOG BUAT FLASHCARD SET
  // ----------------------------------------------------------------------
  Future<void> _createFlashcardDialog({Map<String, dynamic>? initialSet}) async {
    final titleCtrl = TextEditingController(text: initialSet?['title'] ?? '');
    final subjectCtrl = TextEditingController(text: initialSet?['subject'] ?? '');
    List<Map<String, dynamic>> cards = initialSet != null
        ? List<Map<String, dynamic>>.from(initialSet['cards'])
        : [
            {'front': '', 'back': '', 'image_url': null},
            {'front': '', 'back': '', 'image_url': null},
          ];

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
          title: Text(initialSet == null ? '🎴 Buat Set Flashcard Belajar' : '✏️ Edit Set Flashcard', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
          content: SizedBox(
            width: 520,
            height: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: titleCtrl,
                    style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      labelText: 'Judul Set Flashcard',
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                      filled: true,
                      fillColor: _kCreamBg,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: subjectCtrl,
                    style: const TextStyle(color: _kNavyDark),
                    decoration: InputDecoration(
                      labelText: 'Topik / Mata Kuliah',
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                      filled: true,
                      fillColor: _kCreamBg,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Daftar Kartu Flashcard:', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                      ElevatedButton.icon(
                        onPressed: () {
                          setDState(() {
                            cards.add({'front': '', 'back': '', 'image_url': null});
                          });
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Tambah Kartu', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...cards.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final c = entry.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.2)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Kartu ${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                              if (cards.length > 1)
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                  onPressed: () => setDState(() => cards.removeAt(idx)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          TextFormField(
                            key: ValueKey('fc_front_${identityHashCode(c)}'),
                            initialValue: c['front'],
                            style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold, fontSize: 13),
                            decoration: const InputDecoration(
                              labelText: 'Sisi Depan (Pertanyaan / Istilah)',
                              hintText: 'Contoh: Apa itu Rekursi?',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) => c['front'] = v,
                          ),
                          const SizedBox(height: 8),
                          // Gambar opsional untuk sisi depan kartu (tidak
                          // harus tulisan saja).
                          if (c['front_image'] != null && c['front_image'].toString().isNotEmpty) ...[
                            Stack(
                              children: [
                                Container(
                                  width: double.infinity,
                                  constraints: const BoxConstraints(maxHeight: 140),
                                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: _kNavyDark, width: 1)),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(9),
                                    child: c['front_image'].toString().startsWith('data:image')
                                        ? Image.memory(base64Decode(c['front_image'].toString().split(',').last), fit: BoxFit.contain)
                                        : Image.network(c['front_image'].toString(), fit: BoxFit.contain),
                                  ),
                                ),
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: InkWell(
                                    onTap: () => setDState(() => c['front_image'] = null),
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                                      child: const Icon(Icons.close, size: 14, color: Colors.white),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ] else
                            OutlinedButton.icon(
                              onPressed: () {
                                ExportHelper.pickImageWeb((base64Data) async {
                                  if (base64Data.isNotEmpty) {
                                    final compressed = await _compressImageDataUrlForStorage(base64Data);
                                    setDState(() => c['front_image'] = compressed);
                                  }
                                });
                              },
                              style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1)),
                              icon: const Icon(Icons.image_outlined, size: 16),
                              label: const Text('Add Front Image (Optional)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          const SizedBox(height: 8),
                          TextFormField(
                            key: ValueKey('fc_back_${identityHashCode(c)}'),
                            initialValue: c['back'],
                            style: const TextStyle(color: _kNavyDark, fontSize: 13),
                            decoration: const InputDecoration(
                              labelText: 'Sisi Belakang (Jawaban / Definisi)',
                              hintText: 'Contoh: Teknik pemanggilan fungsi ke dirinya sendiri',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) => c['back'] = v,
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: _kNavyDark))),
            ElevatedButton(
              onPressed: () async {
                if (titleCtrl.text.trim().isEmpty) return;
                // Buang kartu yang benar-benar kosong (belum diisi sama sekali).
                final validCards = cards.where((c) => (c['front']?.toString().trim().isNotEmpty ?? false) || (c['back']?.toString().trim().isNotEmpty ?? false)).toList();
                if (validCards.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Isi minimal 1 kartu flashcard terlebih dahulu.')));
                  return;
                }
                if (initialSet != null && initialSet['id'] != null) {
                  final ok = await QuizizzService.updateFlashcardSet(
                    initialSet['id'].toString(),
                    title: titleCtrl.text.trim(),
                    subject: subjectCtrl.text.trim().isEmpty ? 'Umum' : subjectCtrl.text.trim(),
                    cards: validCards,
                  );
                  if (!ok) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('❌ Gagal menyimpan flashcard. Coba lagi atau kurangi ukuran gambar.'), backgroundColor: Colors.redAccent),
                      );
                    }
                    return;
                  }
                } else {
                  final result = await QuizizzService.createFlashcardSet(
                    title: titleCtrl.text.trim(),
                    subject: subjectCtrl.text.trim().isEmpty ? 'Umum' : subjectCtrl.text.trim(),
                    cards: validCards,
                  );
                  if (result.isEmpty || result.containsKey('error')) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('❌ Gagal menyimpan flashcard. Coba lagi atau kurangi ukuran gambar.'), backgroundColor: Colors.redAccent),
                      );
                    }
                    return;
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx);
                _loadFlashcardSets();
              },
              style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
              child: const Text('Simpan Set Flashcard', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateOptionsDialog() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Text('✨ Pilih Jenis Modul Baru', style: TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Pilih jenis kuis atau tugas yang ingin Anda buat untuk mahasiswa:', style: TextStyle(color: _kNavyDark, fontSize: 13)),
            const SizedBox(height: 16),
            ListTile(
              onTap: () {
                Navigator.pop(ctx);
                _createQuizDialog();
              },
              tileColor: _kCreamBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2)),
              leading: const CircleAvatar(backgroundColor: _kMustardYellow, child: Icon(Icons.emoji_events_rounded, color: _kNavyDark)),
              title: const Text('🎮 Buat Kuis Gamifikasi Baru', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
              subtitle: const Text('Disimpan di Bank Kuis Gamifikasi untuk Host Live / Assign PR nanti', style: TextStyle(fontSize: 11, color: Colors.black54)),
            ),
            const SizedBox(height: 12),
            ListTile(
              onTap: () {
                Navigator.pop(ctx);
                _createDirectHomeworkDialog();
              },
              tileColor: const Color(0xFFE0F2FE),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2)),
              leading: const CircleAvatar(backgroundColor: Color(0xFF0284C7), child: Icon(Icons.assignment_rounded, color: Colors.white)),
              title: const Text('📝 Buat Pekerjaan Rumah (PR) Baru', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
              subtitle: const Text('Buat tugas PR baru dan langsung ditugaskan ke mahasiswa dengan deadline', style: TextStyle(fontSize: 11, color: Colors.black54)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close', style: TextStyle(color: _kNavyDark))),
        ],
      ),
    );
  }

  Future<void> _createDirectHomeworkDialog() async {
    final titleCtrl = TextEditingController();
    int selectedDays = 3;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
          title: const Text('📝 Buat Pekerjaan Rumah (PR) Baru', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: 'Judul Pekerjaan Rumah (PR)',
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kMustardYellow, width: 2)),
                    filled: true,
                    fillColor: _kCreamBg,
                  ),
                ),
                const SizedBox(height: 14),
                const Text('🗓️ Durasi Pengerjaan / Deadline:', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: selectedDays,
                  decoration: InputDecoration(
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                    filled: true,
                    fillColor: _kCreamBg,
                  ),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 Hari (Besok)', style: TextStyle(color: _kNavyDark))),
                    DropdownMenuItem(value: 3, child: Text('3 Hari', style: TextStyle(color: _kNavyDark))),
                    DropdownMenuItem(value: 7, child: Text('7 Hari (1 Pekan)', style: TextStyle(color: _kNavyDark))),
                    DropdownMenuItem(value: 14, child: Text('14 Hari (2 Pekan)', style: TextStyle(color: _kNavyDark))),
                  ],
                  onChanged: (val) {
                    if (val != null) setDState(() => selectedDays = val);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: _kNavyDark))),
            ElevatedButton(
              onPressed: () async {
                final rawT = titleCtrl.text.trim();
                if (rawT.isEmpty) return;

                final cleanT = rawT.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim();
                final formattedTitle = 'PR Mandiri: $cleanT';
                final deadline = DateTime.now().add(Duration(days: selectedDays));

                try {
                  // FITUR "PR Tidak Boleh Duplikat ke Gamified Quiz" (poin 1):
                  // dulu penandaan "kuis ini khusus PR" hanya disimpan di
                  // local storage BROWSER dosen (markQuizAsHomeworkOnly) --
                  // kalau dosen membuka app dari device/browser lain, atau
                  // cache browsernya kepakai/kehapus, penanda itu HILANG dan
                  // PR ini muncul lagi di Bank Kuis Gamifikasi seolah-olah
                  // kuis biasa. Sekarang ditandai langsung di kolom
                  // 'quiz_type' = 'homework' di BACKEND saat kuis dibuat,
                  // supaya tersimpan permanen dan konsisten di device manapun.
                  final quizRes = await QuizizzService.createQuiz(cleanT, '', quizType: 'homework');
                  final qId = quizRes['quiz']?['id']?.toString() ?? 'q_${DateTime.now().millisecondsSinceEpoch}';

                  await QuizizzService.assignHomework(
                    quizId: qId,
                    title: formattedTitle,
                    description: '',
                    deadline: deadline,
                  );

                  // Tetap tandai di local storage juga sebagai lapis
                  // pengaman tambahan untuk kompatibilitas kode lama.
                  await QuizizzService.markQuizAsHomeworkOnly(qId);

                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
              child: const Text('Assign Homework', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (created == true) {
      await _loadQuizzes();
      await _fetchHomeworkList();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('📝 Pekerjaan Rumah (PR) baru berhasil dibuat sebagai draft. Tekan "🚀 Aktifkan" agar tampil ke mahasiswa!'), backgroundColor: _kNavyDark));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(50),
        child: Container(
          color: _kCreamBg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(25), border: Border.all(color: _kNavyDark, width: 1.5)),
            child: TabBar(
              controller: _tabController,
              labelColor: _kNavyDark,
              unselectedLabelColor: Colors.black54,
              indicator: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 1.2)),
              tabs: const [
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.emoji_events_rounded, size: 16), SizedBox(width: 4), Text('🎮 Gamified Quiz', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.slideshow_rounded, size: 16), SizedBox(width: 4), Text('Presentation (Lesson)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.style_rounded, size: 16), SizedBox(width: 4), Text('Study Flashcards', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.table_chart_rounded, size: 16), SizedBox(width: 4), Text('📊 Rekap Nilai', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.qr_code_scanner_rounded, size: 16), SizedBox(width: 4), Text('📅 Presensi QR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.analytics_rounded, size: 16), SizedBox(width: 4), Text('Reports', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (_tabController.index == 1) {
            _createLessonDialog();
          } else if (_tabController.index == 2) {
            _createFlashcardDialog();
          } else {
            _showCreateOptionsDialog();
          }
        },
        backgroundColor: _kMustardYellow,
        foregroundColor: _kNavyDark,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25), side: const BorderSide(color: _kNavyDark, width: 1.5)),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Buat Modul Baru', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildQuizzesTab(),
          _buildLessonsTab(),
          _buildFlashcardsTab(),
          GradebookTabView(
            classId: QuizizzService.currentClassId,
            className: QuizizzService.currentClassName,
          ),
          AttendanceDosenTabView(
            classId: QuizizzService.currentClassId,
            className: QuizizzService.currentClassName,
          ),
          _buildReportsTab(),
        ],
      ),
    );
  }

  Widget _buildQuizzesTab() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _kNavyDark));

    return ValueListenableBuilder<int>(
      valueListenable: QuizizzService.homeworkChangeNotifier,
      builder: (context, _, __) {
        final quizzesList = _myQuizzes.where((q) {
          final qId = q['id']?.toString() ?? '';
          // FITUR "PR Tidak Boleh Duplikat ke Gamified Quiz" (poin 1): cek
          // 'quiz_type' dari BACKEND (sumber kebenaran, tersimpan permanen)
          // sebagai filter utama, plus set lokal (_homeworkOnlyQuizIds)
          // sebagai lapis tambahan untuk kompatibilitas data lama yang
          // dibuat sebelum kolom quiz_type dipakai.
          final isHomeworkType = q['quiz_type']?.toString() == 'homework';
          return !_homeworkOnlyQuizIds.contains(qId) && !isHomeworkType;
        }).toList();
        final hwList = _assignedHomeworkList;

        return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Row(
                  children: [
                    Icon(Icons.sports_esports_rounded, color: _kNavyDark, size: 20),
                    SizedBox(width: 8),
                    Text('Bank Kuis Gamifikasi:', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
                  ],
                ),
                const SizedBox(height: 12),
                if (quizzesList.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.5)),
                    child: const Column(
                      children: [
                        Icon(Icons.emoji_events_outlined, size: 48, color: _kNavyDark),
                        SizedBox(height: 8),
                        Text('Belum ada kuis gamifikasi di Bank Kuis. Tekan "Buat Modul Baru" untuk menambahkan.', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                      ],
                    ),
                  )
                else
                  ...quizzesList.map((q) {
                    final qId = q['id'].toString();
                    final title = q['title'] ?? 'Kuis Gamifikasi Classly';

                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: _kQuizizzPastelBg, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.2)),
                                child: const Icon(Icons.emoji_events_rounded, color: _kQuizizzTextColor, size: 24),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kNavyDark)),
                                    FutureBuilder<List<Map<String, dynamic>>>(
                                       future: QuizizzService.getCustomQuestions(qId),
                                       builder: (ctx, snapshot) {
                                         final count = snapshot.hasData ? snapshot.data!.length : ((q['questions'] as List?)?.length ?? (q['total_questions'] ?? 0));
                                         return Text('Total Soal Gamifikasi: $count', style: const TextStyle(color: Colors.black54, fontSize: 13, fontWeight: FontWeight.bold));
                                       },
                                     ),
                                     FutureBuilder<bool>(
                                       future: QuizizzService.hasLiveQuizBeenDone(qId),
                                       builder: (ctx, snap) {
                                         if (snap.hasData && snap.data == true) {
                                           return Container(
                                             margin: const EdgeInsets.only(top: 4),
                                             padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                             decoration: BoxDecoration(
                                               color: const Color(0xFFDCFCE7),
                                               borderRadius: BorderRadius.circular(8),
                                               border: Border.all(color: const Color(0xFF16A34A), width: 1),
                                             ),
                                             child: const Row(
                                               mainAxisSize: MainAxisSize.min,
                                               children: [
                                                 Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 14),
                                                 SizedBox(width: 4),
                                                 Text('🟢 Kuis Live Telah Dilakukan', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF15803D))),
                                               ],
                                             ),
                                           );
                                         }
                                         return const SizedBox.shrink();
                                       },
                                     ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          const Divider(color: _kNavyDark, height: 1),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ElevatedButton.icon(
                                onPressed: () async {
                                  final res = await QuizizzService.createSession(qId, mode: 'live');
                                  final pin = res['session']['session_code'];
                                  await QuizizzService.updateLiveSessionStatus(pin, 'waiting');

                                  if (mounted) {
                                    setState(() {});
                                    // Setelah dosen kembali dari layar Live Host (baik karena
                                    // room sudah dimulai/selesai maupun ditutup manual), Bank
                                    // Kuis di-refresh supaya kuis yang SUDAH DILAKUKAN otomatis
                                    // hilang dari daftar dan pindah ke bagian Riwayat.
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (_) => _HostLiveScreen(pin: pin, title: title, quizId: qId, sessionId: res['session']['id'].toString())),
                                    );
                                    if (mounted) await _loadQuizzes();
                                  }
                                },
                                style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                                label: const Text('🎮 Start Live Gamified Host', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _manageQuestionsDialog(q),
                                style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                                icon: const Icon(Icons.edit_note_rounded, size: 16),
                                label: const Text('✏️ Manage Questions', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                              ElevatedButton.icon(
                                onPressed: () => _viewLiveQuizGradesDialog(q),
                                style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                                icon: const Icon(Icons.analytics_rounded, size: 16),
                                label: const Text('📊 View Student Grades', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                              OutlinedButton.icon(
                                onPressed: () async {
                                  // PENTING: "Hapus Kuis" HANYA menghapus kuis ini dari Bank
                                  // Kuis. PR yang mungkin ditugaskan dari kuis ini TIDAK ikut
                                  // terhapus — keduanya independen sesuai permintaan.
                                  _myQuizzes.removeWhere((item) => item['id']?.toString() == qId);
                                  setState(() {});

                                  await QuizizzService.deleteQuiz(qId);
                                  await _loadQuizzes();
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('🗑️ Kuis berhasil dihapus!'), backgroundColor: Colors.redAccent),
                                    );
                                  }
                                },
                                style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                                label: const Text('🗑️ Delete Quiz', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),

                // SECTION: DAFTAR PEKERJAAN RUMAH (PR) AKTIF DITUGASKAN DOSEN
                // (Selalu tampil, walau belum ada PR sama sekali — tampilkan
                // keterangan "Belum ada PR aktif" alih-alih menyembunyikan
                // section ini sepenuhnya.)
                const SizedBox(height: 20),
                const Divider(color: _kNavyDark, height: 1),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Icon(Icons.assignment_rounded, color: _kNavyDark, size: 22),
                    const SizedBox(width: 8),
                    Text('📝 Pekerjaan Rumah (PR) Aktif (${hwList.length}):', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
                  ],
                ),
                const SizedBox(height: 12),
                if (hwList.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                    child: const Center(
                      child: Text('Belum ada riwayat.', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
                    ),
                  )
                else
                  ...hwList.map((hw) {
                    final deadlineStr = hw['deadline'] ?? '';
                    DateTime? deadline;
                    try {
                      // PENTING: parse lalu konversi ke waktu LOKAL perangkat.
                      // Deadline dikirim/disimpan dalam format UTC (ada 'Z'),
                      // tanpa .toLocal() jamnya akan tampil salah (berbeda
                      // dari yang diinput dosen di zona waktu lokalnya).
                      deadline = DateTime.parse(deadlineStr).toLocal();
                    } catch (_) {}

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
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
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: const Color(0xFFBAE6FD), shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1)),
                                child: const Icon(Icons.assignment_rounded, color: Color(0xFF0284C7), size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(child: Text(hw['title'] ?? 'PR Mandiri', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark), overflow: TextOverflow.ellipsis)),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: (hw['status']?.toString() == 'draft') ? const Color(0xFFFFEDD5) : const Color(0xFFD1FAE5),
                                            borderRadius: BorderRadius.circular(20),
                                            border: Border.all(color: _kNavyDark, width: 1),
                                          ),
                                          child: Text(
                                            (hw['status']?.toString() == 'draft') ? '📝 Draft' : '✅ Active',
                                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: (hw['status']?.toString() == 'draft') ? const Color(0xFFEA580C) : const Color(0xFF059669)),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    if (deadline != null)
                                      Text('🗓️ Deadline: ${deadline.day}/${deadline.month}/${deadline.year} Jam ${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')} WIB', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFFEA580C))),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(color: _kNavyDark, height: 1),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (hw['status']?.toString() == 'draft')
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    final hwId = hw['id']?.toString() ?? '';
                                    final quizId = hw['quiz_id']?.toString() ?? '';
                                    await QuizizzService.activateHomework(hwId, quizId: quizId);
                                    await _fetchHomeworkList();
                                    if (mounted) {
                                      setState(() {});
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('✅ PR berhasil diaktifkan dan kini muncul di halaman mahasiswa!'), backgroundColor: Color(0xFF059669)),
                                      );
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF059669), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                  icon: const Icon(Icons.play_circle_fill_rounded, size: 16),
                                  label: const Text('🚀 Aktifkan', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                ),
                              OutlinedButton.icon(
                                onPressed: () {
                                  // Pakai quiz_id sebagai kunci penyimpanan soal (STABIL),
                                  // bukan hw['id'] yang bisa berubah antar refresh polling
                                  // 2 detik — ini yang menyebabkan soal ke-3 dst hilang
                                  // dari "Daftar Soal Tersimpan" sebelumnya.
                                  final targetId = hw['quiz_id']?.toString().isNotEmpty == true
                                      ? hw['quiz_id'].toString()
                                      : (hw['id']?.toString() ?? '');
                                  final rawTitle = hw['title']?.toString() ?? 'PR Mandiri';
                                  final cleanTitle = rawTitle.replaceAll(RegExp(r'^(PR Mandiri:\s*|PR Mandiri\s*)', caseSensitive: false), '').trim();

                                  _manageQuestionsDialog({'id': targetId, 'title': 'PR Mandiri: $cleanTitle'}, isHomework: true);
                                },
                                style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                icon: const Icon(Icons.edit_note_rounded, size: 16),
                                label: const Text('✏️ Manage Questions', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _changeHomeworkDeadlineDialog(hw),
                                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFEA580C), side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                icon: const Icon(Icons.edit_calendar_rounded, size: 16),
                                label: const Text('📅 Edit Deadline', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              ),
                              ElevatedButton.icon(
                                onPressed: () => _viewHomeworkGradesDialog(hw),
                                style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                icon: const Icon(Icons.analytics_rounded, size: 16),
                                label: const Text('📊 View Student Grades', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              ),
                              OutlinedButton.icon(
                                onPressed: () async {
                                  final hwId = hw['id']?.toString() ?? '';
                                  final quizId = hw['quiz_id']?.toString() ?? '';
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      title: const Text('Nonaktifkan PR?', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                                      content: const Text('PR akan hilang dari daftar aktif mahasiswa, tapi hasil pekerjaan mahasiswa yang sudah ada tetap tersimpan dan bisa dilihat/di-download di Laporan Rekap.', style: TextStyle(color: Colors.black87)),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                        ElevatedButton(
                                          onPressed: () => Navigator.pop(ctx, true),
                                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEA580C), foregroundColor: Colors.white),
                                          child: const Text('Deactivate'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm != true) return;

                                  await QuizizzService.deactivateHomework(hwId, quizId: quizId);
                                  await _fetchHomeworkList();
                                  if (mounted) {
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('✅ PR berhasil dinonaktifkan. Hasil mahasiswa tetap tersimpan di Laporan Rekap.'), backgroundColor: _kNavyDark),
                                    );
                                  }
                                },
                                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFEA580C), side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                icon: const Icon(Icons.pause_circle_outline_rounded, size: 16),
                                label: const Text('⏸️ Deactivate', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              ),
                              OutlinedButton.icon(
                                onPressed: () async {
                                  final hwId = hw['id']?.toString() ?? '';
                                  final quizId = hw['quiz_id']?.toString() ?? '';

                                  _locallyDeletedHwIds.add(hwId);
                                  _locallyDeletedHwIds.add(quizId);
                                  _locallyDeletedHwIds.add('hw_$quizId');

                                  _assignedHomeworkList.removeWhere((h) => h['id']?.toString() == hwId || h['quiz_id']?.toString() == quizId);
                                  // PENTING: cocokkan HANYA berdasarkan ID unik (quiz_id), BUKAN
                                  // judul — dua kuis/PR berbeda bisa kebetulan berjudul sama,
                                  // dan menghapus satu tidak boleh ikut menyembunyikan yang lain.
                                  _myQuizzes.removeWhere((q) {
                                    final qId = q['id']?.toString() ?? '';
                                    return qId.isNotEmpty && qId == quizId;
                                  });

                                  setState(() {});

                                  // PENTING: "Hapus PR" HANYA menghapus PR-nya saja (baris
                                  // homework_assignments/sesi PR). Kuis yang mendasarinya TIDAK
                                  // ikut dihapus — karena PR bisa saja ditugaskan dari kuis yang
                                  // MASIH dipakai di Bank Kuis untuk live hosting. Menghapus kuis
                                  // di sini bisa salah menghapus kuis yang masih dipakai dosen.
                                  await QuizizzService.deleteHomework(hwId, quizId: quizId);
                                  await _loadQuizzes();
                                  await _fetchHomeworkList();
                                  if (mounted) {
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('🗑️ Pekerjaan Rumah (PR) Berhasil Dihapus!'), backgroundColor: Colors.redAccent),
                                    );
                                  }
                                },
                                style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                icon: const Icon(Icons.delete_forever_rounded, size: 16),
                                label: const Text('🗑️ Delete Homework', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),

              ],
            );
      },
    );
  }

  // ----------------------------------------------------------------------
  // DIALOG REVIEW SOAL PEKERJAAN RUMAH (PR) DOSEN
  // ----------------------------------------------------------------------
  Future<void> _reviewHomeworkQuestionsDialog(Map<String, dynamic> hw) async {
    final quizId = hw['quiz_id']?.toString() ?? '';
    final title = hw['title'] ?? 'PR Mandiri';

    List<Map<String, dynamic>> questions = [];
    if (hw['questions'] is List && (hw['questions'] as List).isNotEmpty) {
      questions = (hw['questions'] as List).cast<Map<String, dynamic>>();
    } else {
      questions = await QuizizzService.getCustomQuestions(quizId);
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: const Color(0xFFBAE6FD), shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1)),
                child: const Icon(Icons.quiz_rounded, color: Color(0xFF0284C7), size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Review Soal PR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: _kNavyDark)),
                    Text(title, style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 550,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: _kNavyDark, width: 1)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('📋 Total Soal Buatan Dosen: ${questions.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kNavyDark, width: 1)),
                        child: const Text('Tugas Mandiri', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (questions.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                    child: const Column(
                      children: [
                        Icon(Icons.help_outline_rounded, size: 40, color: _kNavyDark),
                        SizedBox(height: 8),
                        Text('Belum ada soal buatan Dosen yang tersimpan.', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 14), textAlign: TextAlign.center),
                        SizedBox(height: 4),
                        Text('Klik tombol "Kelola / Edit Soal" di bawah untuk menambahkan soal baru.', style: TextStyle(fontSize: 12, color: Colors.black54), textAlign: TextAlign.center),
                      ],
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 400),
                    child: SingleChildScrollView(
                      child: Column(
                        children: questions.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final q = entry.value;
                          final qType = q['type'] ?? 'multiple_choice';
                          final opts = (q['options'] as List?) ?? [];
                          final correct = q['correct'];
                          final correctList = (q['correct_list'] as List?) ?? [];
                          final imgUrl = q['image_url']?.toString();

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.2)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kNavyDark, width: 1)),
                                      child: Text('Soal ${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark)),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kNavyDark, width: 1)),
                                      child: Text(
                                        qType == 'true_false' ? 'Benar / Salah' : (qType == 'multi_select' ? 'Multi-Select' : 'Pilihan Ganda'),
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kQuizizzTextColor),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text('⏱️ ${q['timer_seconds'] ?? 30}s', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark)),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(q['question'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kNavyDark)),
                                if (imgUrl != null && imgUrl.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: imgUrl.startsWith('data:image')
                                        ? Image.memory(
                                            base64Decode(imgUrl.split(',').last),
                                            height: 120,
                                            width: double.infinity,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => const SizedBox(),
                                          )
                                        : Image.network(
                                            imgUrl,
                                            height: 120,
                                            width: double.infinity,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => const SizedBox(),
                                          ),
                                  ),
                                ],
                                const SizedBox(height: 10),
                                const Text('Opsi & Jawaban Benar:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.black54)),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: opts.map((opt) {
                                    final optStr = opt.toString();
                                    final isCorrect = (qType == 'multi_select')
                                        ? (correctList.contains(optStr) || optStr == correct)
                                        : (optStr == correct);

                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: isCorrect ? const Color(0xFFDCFCE7) : Colors.white,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: isCorrect ? Colors.green.shade700 : _kNavyDark, width: isCorrect ? 1.5 : 1),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isCorrect) ...[
                                            const Icon(Icons.check_circle, size: 14, color: Colors.green),
                                            const SizedBox(width: 4),
                                          ],
                                          Text(
                                            optStr,
                                            style: TextStyle(
                                              fontWeight: isCorrect ? FontWeight.bold : FontWeight.w600,
                                              fontSize: 12,
                                              color: isCorrect ? Colors.green.shade900 : _kNavyDark,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _manageQuestionsDialog({'id': quizId, 'title': title}, isHomework: true);
                final updatedQuestions = await QuizizzService.getCustomQuestions(quizId);
                hw['questions'] = updatedQuestions;
                final hwList = await QuizizzService.getAssignedHomework(includeDraft: true);
                for (final h in hwList) {
                  if (h['id'] == hw['id'] || h['quiz_id'] == quizId) {
                    h['questions'] = updatedQuestions;
                  }
                }
                await QuizizzService.saveHomeworkList(hwList);
                if (mounted) setState(() {});
              },
              style: OutlinedButton.styleFrom(side: const BorderSide(color: _kNavyDark, width: 1.2), foregroundColor: _kNavyDark),
              icon: const Icon(Icons.edit_note_rounded, size: 16),
              label: const Text('✏️ Manage / Edit Questions', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
              child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------------
  // DIALOG UBAH DEADLINE PR
  // ----------------------------------------------------------------------
  Future<void> _changeHomeworkDeadlineDialog(Map<String, dynamic> hw) async {
    final hwId = hw['id']?.toString() ?? '';
    final title = hw['title'] ?? 'PR Mandiri';
    // PENTING: konversi ke waktu lokal dulu, supaya time picker menampilkan
    // jam yang sama persis dengan yang dilihat dosen sebelumnya.
    DateTime currentDeadline = (DateTime.tryParse(hw['deadline'] ?? '') ?? DateTime.now().add(const Duration(days: 3))).toLocal();

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: currentDeadline,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (pickedDate != null && mounted) {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(currentDeadline),
      );

      if (pickedTime != null) {
        final newDeadline = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          pickedTime.hour,
          pickedTime.minute,
        );
        await QuizizzService.updateHomeworkDeadline(hwId, newDeadline, quizId: hw['quiz_id']?.toString());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('📅 Deadline PR "$title" berhasil diperbarui!'), backgroundColor: _kNavyDark),
          );
          setState(() {});
        }
      }
    }
  }

  // ----------------------------------------------------------------------
  // DIALOG LIHAT NILAI HASIL LIVE QUIZ GAMIFIKASI (BANK KUIS)
  // ----------------------------------------------------------------------
  Future<void> _viewLiveQuizGradesDialog(Map<String, dynamic> quiz) async {
    final quizId = quiz['id']?.toString() ?? '';
    final title = quiz['title'] ?? 'Kuis Gamifikasi';
    // PENTING: ambil dari BACKEND (bukan localStorage lokal), supaya dosen
    // bisa melihat hasil mahasiswa yang mengerjakan dari perangkat lain.
    final rawResults = await QuizizzService.getQuizResults(quizId);
    final submissions = rawResults.map((r) {
      final m = Map<String, dynamic>.from(r);
      m['submitted_at'] = m['submitted_at'] ?? m['completed_at'];
      return m;
    }).toList();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: Row(
          children: [
            const Icon(Icons.analytics_rounded, color: _kNavyDark, size: 24),
            const SizedBox(width: 8),
            Expanded(child: Text('📊 Nilai Live Host Gamifikasi: $title', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 16))),
          ],
        ),
        content: SizedBox(
          width: 580,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (submissions.isEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _kNavyDark, width: 1.2),
                    boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(2, 2), blurRadius: 0)],
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.assignment_late_rounded, size: 48, color: Color(0xFFEA580C)),
                      SizedBox(height: 12),
                      Text('quiz belum dilakukan', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark)),
                      SizedBox(height: 6),
                      Text('Belum ada mahasiswa yang mengerjakan kuis ini secara live dari Dosen.', style: TextStyle(fontSize: 12, color: Colors.black54), textAlign: TextAlign.center),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Total Peserta: ${submissions.length} Mahasiswa', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
                    ElevatedButton.icon(
                      onPressed: () {
                        final buffer = StringBuffer();
                        buffer.writeln('Peringkat,Nama Mahasiswa,Skor,Total Soal,Waktu Selesai');
                        for (int i = 0; i < submissions.length; i++) {
                          final sub = submissions[i];
                          final rank = i + 1;
                          final name = sub['student_name'] ?? 'Mahasiswa';
                          final score = sub['score'] ?? 0;
                          final totalQ = sub['total_questions'] ?? 0;
                          final timeStr = sub['submitted_at'] ?? '';
                          buffer.writeln('$rank,"$name",$score,$totalQ,"$timeStr"');
                        }
                        final cleanTitle = title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
                        ExportHelper.exportCsv(
                          filename: 'Nilai_Quiz_${cleanTitle}.csv',
                          content: buffer.toString(),
                        );
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('📥 File CSV Hasil Nilai Berhasil Di-download!'), backgroundColor: _kNavyDark),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('📥 Download CSV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: submissions.asMap().entries.map((entry) {
                        final idx = entry.key + 1;
                        final sub = entry.value;
                        final name = sub['student_name'] ?? 'Mahasiswa';
                        final score = sub['score'] ?? 0;
                        final totalQ = sub['total_questions'] ?? 0;
                        DateTime? time;
                        try {
                          time = DateTime.parse(sub['submitted_at']);
                        } catch (_) {}

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: idx == 1 ? const Color(0xFFFEF3C7) : _kCreamBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _kNavyDark, width: 1),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: idx == 1 ? const Color(0xFFF59E0B) : _kNavyDark,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(child: Text('#$idx', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kNavyDark)),
                                    if (time != null)
                                      Text('🕒 ${time.day}/${time.month}/${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} WIB', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                                  ],
                                ),
                              ),
                              // FITUR "Riwayat Jawaban Gamified Quiz" (poin 2):
                              // dosen sekarang bisa melihat rincian jawaban
                              // per soal (benar/salah) untuk tiap mahasiswa,
                              // bukan cuma total skornya saja.
                              IconButton(
                                tooltip: 'Lihat Riwayat Jawaban',
                                icon: const Icon(Icons.fact_check_rounded, color: Color(0xFF0284C7), size: 20),
                                onPressed: () => _showAnswerHistoryDialog(
                                  context,
                                  headerTitle: title,
                                  studentName: name,
                                  score: score is int ? score : int.tryParse(score.toString()),
                                  total: totalQ is int ? totalQ : int.tryParse(totalQ.toString()),
                                  answers: (sub['answers'] as List?) ?? [],
                                ),
                              ),
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: _kNavyDark, width: 1),
                                ),
                                child: Text('Skor: $score / $totalQ', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
            child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------------
  // DIALOG LIHAT NILAI HASIL MAHASISWA (PR)
  // ----------------------------------------------------------------------
  Future<void> _viewHomeworkGradesDialog(Map<String, dynamic> hw) async {
    final hwId = hw['id']?.toString() ?? '';
    final quizId = hw['quiz_id']?.toString() ?? '';
    final title = hw['title'] ?? 'PR Mandiri';
    // PENTING: ambil dari BACKEND memakai quiz_id (paling stabil), bukan
    // localStorage lokal — supaya dosen bisa melihat hasil PR mahasiswa yang
    // mengerjakan dari perangkat/browser manapun, bukan cuma yang kebetulan
    // memakai browser yang sama dengan dosen.
    final targetId = quizId.isNotEmpty ? quizId : hwId;
    final rawResults = await QuizizzService.getQuizResults(targetId);
    // Fitur "Riwayat Jawaban PR": ambil juga detail jawaban per soal supaya
    // dosen bisa membuka rincian benar/salah tiap mahasiswa.
    final detailedSubs = await QuizizzService.getHomeworkSubmissionsDetailed(targetId);
    final submissions = rawResults.map((r) {
      final m = Map<String, dynamic>.from(r);
      m['submitted_at'] = m['submitted_at'] ?? m['completed_at'];
      m['status'] = m['status'] ?? 'Selesai';
      // Cocokkan dengan submission detail (nama + skor) untuk melampirkan
      // daftar jawaban per soal, kalau tersedia.
      final match = detailedSubs.firstWhere(
        (d) => (d['student_name']?.toString().trim().toLowerCase() ?? '') == (m['student_name']?.toString().trim().toLowerCase() ?? '') &&
            (d['score']?.toString() ?? '') == (m['score']?.toString() ?? ''),
        orElse: () => <String, dynamic>{},
      );
      m['answers'] = match['answers'] ?? [];
      return m;
    }).toList();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: Row(
          children: [
            const Icon(Icons.analytics_rounded, color: Color(0xFF0284C7), size: 24),
            const SizedBox(width: 8),
            Expanded(child: Text('📊 Hasil Nilai Mahasiswa ($title)', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 16))),
          ],
        ),
        content: SizedBox(
          width: 540,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total Responden Mahasiswa: ${submissions.length} Orang', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
              const SizedBox(height: 12),
              if (submissions.isEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _kNavyDark, width: 1.2),
                    boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(2, 2), blurRadius: 0)],
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.assignment_late_rounded, size: 48, color: Color(0xFFEA580C)),
                      SizedBox(height: 12),
                      Text('belum ada yang mengerjakan PR', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark)),
                      SizedBox(height: 6),
                      Text('Belum ada mahasiswa yang mengumpulkan tugas Pekerjaan Rumah ini.', style: TextStyle(fontSize: 12, color: Colors.black54), textAlign: TextAlign.center),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ]
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: submissions.asMap().entries.map((entry) {
                        final idx = entry.key + 1;
                        final sub = entry.value;
                        final name = sub['student_name'] ?? 'Mahasiswa';
                        final score = sub['score'] ?? 0;
                        final status = sub['status'] ?? 'Selesai';
                        final answers = (sub['answers'] as List?) ?? [];
                        DateTime? time;
                        try {
                          time = DateTime.parse(sub['submitted_at']);
                        } catch (_) {}

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: idx == 1 ? const Color(0xFFFEF3C7) : _kCreamBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _kNavyDark, width: 1),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(color: _kMustardYellow, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1)),
                                    child: Center(child: Text('#$idx', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark))),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kNavyDark)),
                                        if (time != null)
                                          Text('🕒 ${time.day}/${time.month}/${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} WIB • $status', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: score >= 80 ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: score >= 80 ? Colors.green : Colors.red, width: 1),
                                    ),
                                    child: Text('$score Pts', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: score >= 80 ? Colors.green.shade900 : Colors.red.shade900)),
                                  ),
                                ],
                              ),
                              if (answers.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _showAnswerHistoryDialog(
                                      context,
                                      headerTitle: title,
                                      studentName: name.toString(),
                                      score: sub['score'] is int ? sub['score'] : int.tryParse(sub['score']?.toString() ?? ''),
                                      total: answers.length,
                                      answers: answers,
                                    ),
                                    style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                                    icon: const Icon(Icons.fact_check_rounded, size: 14),
                                    label: const Text('📜 Lihat Riwayat Jawaban', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------------
  // DIALOG OPSI HAPUS PR (KEMBALIKAN KE BANK KUIS / HAPUS TOTAL)
  // ----------------------------------------------------------------------
  Future<void> _deleteHomeworkOptionsDialog(Map<String, dynamic> hw) async {
    final hwId = hw['id']?.toString() ?? '';
    final quizId = hw['quiz_id']?.toString() ?? '';
    final title = hw['title'] ?? 'PR Mandiri';

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: Row(
          children: [
            const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 24),
            const SizedBox(width: 8),
            Expanded(child: Text('Penghapusan PR: $title', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 16))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Pilih tindakan penghapusan untuk tugas PR ini:', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'restore'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEFF6FF),
                foregroundColor: _kNavyDark,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1.2)),
                alignment: Alignment.centerLeft,
              ),
              icon: const Icon(Icons.restore_page_rounded, color: Color(0xFF0284C7), size: 26),
              label: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('🔄 Return to Quiz Bank', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                  SizedBox(height: 2),
                  Text('Hapus penugasan PR saja. Kuis kembali muncul di Bank Kuis Dosen.', style: TextStyle(fontSize: 10, color: Colors.black54)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'permanent'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFEF2F2),
                foregroundColor: Colors.redAccent,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.redAccent, width: 1.2)),
                alignment: Alignment.centerLeft,
              ),
              icon: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 26),
              label: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('❌ Delete Entirely (Permanent)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.redAccent)),
                  SizedBox(height: 2),
                  Text('Hapus penugasan PR sekaligus menghapus kuis dan seluruh soal secara permanen.', style: TextStyle(fontSize: 10, color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
          ),
        ],
      ),
    );

    if (choice == 'restore') {
      _assignedHomeworkList.removeWhere((h) => h['id']?.toString() == hwId || h['quiz_id']?.toString() == quizId);
      setState(() {});

      await QuizizzService.deleteHomework(hwId, quizId: quizId);
      await _loadQuizzes();
      final freshList = await QuizizzService.getAssignedHomework(includeDraft: true);
      if (mounted) {
        setState(() {
          _assignedHomeworkList = freshList;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ℹ️ PR dihapus. Kuis berhasil dikembalikan ke Bank Kuis Gamifikasi!'), backgroundColor: _kNavyDark),
        );
      }
    } else if (choice == 'permanent') {
      _assignedHomeworkList.removeWhere((h) => h['id']?.toString() == hwId || h['quiz_id']?.toString() == quizId);
      _myQuizzes.removeWhere((q) => q['id']?.toString() == quizId);
      setState(() {});

      await QuizizzService.deleteHomework(hwId, quizId: quizId);
      if (quizId.isNotEmpty) {
        try {
          await QuizizzService.deleteQuiz(quizId);
        } catch (_) {}
      }
      await _loadQuizzes();
      final freshList = await QuizizzService.getAssignedHomework(includeDraft: true);
      if (mounted) {
        setState(() {
          _assignedHomeworkList = freshList;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🗑️ PR dan Kuis berhasil dihapus secara permanen!'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Widget _buildLessonsTab() {
    if (_lessons.isEmpty) return const Center(child: Text('Belum ada Presentasi Lesson yang dibuat.', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)));

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _lessons.length,
      itemBuilder: (ctx, i) {
        final lsn = _lessons[i];
        final slides = (lsn['slides'] as List?) ?? [];

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: const Color(0xFFBAE6FD), shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.2)),
                    child: const Icon(Icons.slideshow_rounded, color: Color(0xFF0284C7), size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(lsn['title'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kNavyDark)),
                        Text('${lsn['description']} (${slides.length} Slide)', style: const TextStyle(color: Colors.black54, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(color: _kNavyDark, height: 1),
              const SizedBox(height: 12),
              // Fitur "Kelola Soal Presentasi": bisa dibuka LANGSUNG dari
              // sini, TANPA perlu menekan "Start Live Presentation" dulu —
              // dosen bisa menyiapkan bank soal kapan saja sebelum presentasi
              // berlangsung.
              OutlinedButton.icon(
                onPressed: () => showManageLessonQuestionsDialog(
                  context,
                  lessonId: lsn['id'].toString(),
                  lessonTitle: lsn['title']?.toString() ?? '',
                ),
                style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                icon: const Icon(Icons.quiz_rounded, size: 16),
                label: const Text('📋 Kelola Soal Presentasi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: () async {
                  final session = await QuizizzService.createLessonSession(lsn['id'].toString());
                  final code = session['code']?.toString();
                  if (code == null || code.isEmpty) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Gagal membuat sesi presentasi. Coba lagi.'), backgroundColor: Colors.redAccent),
                      );
                    }
                    return;
                  }
                  if (mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _HostLessonLiveScreen(sessionCode: code, lesson: lsn),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                icon: const Icon(Icons.cast_for_education_rounded, size: 16),
                label: const Text('🖥️ Start Live Presentation (Lesson Mode)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (dctx) => AlertDialog(
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Text('Hapus Presentasi?', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                      content: const Text('Presentasi ini akan dihapus permanen.', style: TextStyle(color: Colors.black87)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(dctx, true),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  await QuizizzService.deleteLesson(lsn['id'].toString());
                  await _loadLessons();
                },
                style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('🗑️ Delete Presentation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFlashcardsTab() {
    if (_flashcardSets.isEmpty) return const Center(child: Text('Belum ada set flashcard.', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)));

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _flashcardSets.length,
      itemBuilder: (ctx, i) {
        final fc = _flashcardSets[i];
        final cards = (fc['cards'] as List?) ?? [];

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: _kQuizizzPastelBg, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.2)),
                    child: const Icon(Icons.style_rounded, color: _kQuizizzTextColor, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(fc['title'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kNavyDark)),
                        Text('Topik: ${fc['subject']} | Total: ${cards.length} Kartu', style: const TextStyle(color: Colors.black54, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(color: _kNavyDark, height: 1),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => _FlashcardStudyScreen(set: fc)));
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                    icon: const Icon(Icons.play_circle_fill_rounded, size: 16),
                    label: const Text('Review Flashcards', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _createFlashcardDialog(initialSet: fc),
                    style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    icon: const Icon(Icons.edit, size: 14),
                    label: const Text('Edit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await QuizizzService.duplicateFlashcardSet(fc['id']);
                      _loadFlashcardSets();
                    },
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF0284C7), side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    icon: const Icon(Icons.copy_rounded, size: 14),
                    label: const Text('Duplicate', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await QuizizzService.deleteFlashcardSet(fc['id']);
                      _loadFlashcardSets();
                    },
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    icon: const Icon(Icons.delete_outline, size: 14),
                    label: const Text('Delete', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Rekap PR: gabungan PR AKTIF yang sudah punya minimal 1 hasil pengerjaan
  // mahasiswa + seluruh PR yang sudah dinonaktifkan — supaya rekap langsung
  // muncul begitu ada mahasiswa yang mengerjakan, tidak perlu menunggu PR
  // dinonaktifkan dulu, dan otomatis ter-update tiap kali daftar di-refresh.
  Future<List<Map<String, dynamic>>> _getReportablePrList() async {
    final List<Map<String, dynamic>> combined = [];
    final seenQuizIds = <String>{};

    try {
      final activeList = await QuizizzService.getAssignedHomework();
      for (final hw in activeList) {
        final quizId = hw['quiz_id']?.toString() ?? '';
        final hwId = hw['id']?.toString() ?? '';
        final targetId = quizId.isNotEmpty ? quizId : hwId;
        if (targetId.isEmpty) continue;
        final results = await QuizizzService.getQuizResults(targetId);
        if (results.isNotEmpty) {
          combined.add(hw);
          if (quizId.isNotEmpty) seenQuizIds.add(quizId);
        }
      }
    } catch (_) {}

    try {
      final deactivatedList = await QuizizzService.getDeactivatedHomeworkList();
      for (final hw in deactivatedList) {
        final quizId = hw['quiz_id']?.toString() ?? hw['id']?.toString() ?? '';
        if (quizId.isNotEmpty && seenQuizIds.contains(quizId)) continue;
        combined.add(hw);
      }
    } catch (_) {}

    return combined;
  }

  Widget _buildReportsTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // FITUR "Gabungkan Rekap & Riwayat Quiz/PR" (poin 3): sebelumnya ada
        // DUA daftar terpisah untuk Kuis Gamifikasi (satu berjudul "Rekap"
        // dengan tombol Lihat Hasil + Download CSV, satu lagi berjudul
        // "Riwayat" dengan tombol Reactivate + View Grades) yang menampilkan
        // DATA YANG SAMA PERSIS secara duplikat. Sekarang digabung jadi SATU
        // kolom "Riwayat" saja per kartu, dengan SEMUA aksi (Lihat Hasil,
        // Download CSV, Reactivate) sekaligus -- begitu juga untuk PR.
                // SECTION: RIWAYAT KUIS GAMIFIKASI (TELAH DILAKUKAN) & TOMBOL AKTIFKAN KEMBALI
                // (Selalu tampil, walau belum ada riwayat sama sekali.)
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: QuizizzService.getLiveQuizHistory(),
                  builder: (ctx, snapshot) {
                    final historyList = snapshot.data ?? [];

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),
                        const Divider(color: _kNavyDark, height: 1),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Icon(Icons.history_rounded, color: _kNavyDark, size: 22),
                            const SizedBox(width: 8),
                            Text('📜 Riwayat Kuis Live / Gamifikasi (${historyList.length}):', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (historyList.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                            child: const Center(
                              child: Text('Belum ada riwayat.', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
                            ),
                          )
                        else
                        ...historyList.map((hist) {
                          final qId = hist['id']?.toString() ?? '';
                          final title = hist['title'] ?? 'Kuis Gamifikasi';
                          final desc = hist['description'] ?? 'Kuis Gamifikasi Live yang Pernah Digelar';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
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
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(color: const Color(0xFFDCFCE7), shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1)),
                                      child: const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 20),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark)),
                                          const SizedBox(height: 4),
                                          Text(desc, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                          const SizedBox(height: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF16A34A), width: 1)),
                                            child: const Text('🟢 Live Host Completed / Previously Done', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Color(0xFF15803D))),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    ElevatedButton.icon(
                                      onPressed: () async {
                                        await QuizizzService.reactivateQuizToBank(qId);
                                        await _loadQuizzes();
                                        if (mounted) {
                                          setState(() {});
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('🔄 Kuis "$title" Berhasil Dikembalikan ke Bank Kuis Gamifikasi dan Siap Digunakan!'),
                                              backgroundColor: const Color(0xFF059669),
                                            ),
                                          );
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                      icon: const Icon(Icons.refresh_rounded, size: 16),
                                      label: const Text('🔄 Reactivate', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                    ElevatedButton.icon(
                                      // FITUR "Riwayat Jawaban Gamified Quiz Belum Ada"
                                      // (poin 2): tombol ini SEBELUMNYA salah memanggil
                                      // _viewHomeworkGradesDialog (khusus data PR, yang
                                      // mengambil dari tabel homework_submissions --
                                      // KOSONG untuk pemain Kuis Gamifikasi Live karena
                                      // data mereka ada di tabel berbeda,
                                      // quizizz_question_answers). Akibatnya tombol
                                      // "Lihat Riwayat Jawaban" di dalam dialog itu
                                      // tidak pernah muncul untuk Kuis Gamifikasi.
                                      // Sekarang dipanggil dialog yang benar
                                      // (_viewLiveQuizGradesDialog), yang sudah
                                      // menyertakan detail jawaban per soal.
                                      onPressed: () => _viewLiveQuizGradesDialog(hist),
                                      style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                      icon: const Icon(Icons.analytics_rounded, size: 16),
                                      label: const Text('📊 View Student Grades', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                    // FITUR "Gabungkan Rekap & Riwayat" (poin 3): tombol
                                    // Download CSV yang sebelumnya hanya ada di kartu
                                    // "Rekap" terpisah, sekarang jadi bagian dari SATU
                                    // kartu Riwayat ini.
                                    ElevatedButton.icon(
                                      onPressed: () async {
                                        final results = await QuizizzService.getQuizResults(qId);
                                        if (results.isEmpty) {
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Belum ada hasil mahasiswa untuk direkap.')));
                                          }
                                          return;
                                        }
                                        final buffer = StringBuffer();
                                        buffer.writeln('Peringkat,Nama Mahasiswa,Skor,Total Soal,Waktu Selesai');
                                        for (final r in results) {
                                          final name = (r['student_name'] ?? 'Mahasiswa').toString().replaceAll('"', '""');
                                          buffer.writeln('${r['rank'] ?? ''},"$name",${r['score'] ?? 0},${r['total_questions'] ?? 0},"${r['completed_at'] ?? ''}"');
                                        }
                                        final cleanTitle = title.toString().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
                                        ExportHelper.exportCsv(filename: 'Rekap_$cleanTitle.csv', content: buffer.toString());
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('📥 CSV Rekap Berhasil Di-download!'), backgroundColor: _kNavyDark),
                                          );
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                      icon: const Icon(Icons.download_rounded, size: 16),
                                      label: const Text('Download CSV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                    // FITUR "Tombol Delete di Riwayat Kuis" (poin 2).
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (dctx) => AlertDialog(
                                            backgroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                            title: const Text('Hapus Permanen?', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                                            content: const Text('Kuis beserta seluruh riwayat & hasil pengerjaan mahasiswa akan dihapus permanen dan tidak bisa dikembalikan.', style: TextStyle(color: Colors.black87)),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
                                              ElevatedButton(
                                                onPressed: () => Navigator.pop(dctx, true),
                                                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                                                child: const Text('Hapus Permanen'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm != true) return;
                                        await QuizizzService.deleteQuiz(qId);
                                        if (mounted) {
                                          setState(() {});
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('🗑️ Riwayat Kuis berhasil dihapus permanen!'), backgroundColor: Colors.redAccent),
                                          );
                                        }
                                      },
                                      style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                                      label: const Text('🗑️ Delete', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    );
                  },
                ),

                // SECTION: RIWAYAT PR (PEKERJAAN RUMAH) — digabung (poin 3):
                // dulu ada 2 sumber data terpisah ("Rekap PR" pakai
                // _getReportablePrList, "Riwayat PR" pakai hanya PR yang
                // sudah dinonaktifkan). Sekarang SATU daftar saja memakai
                // _getReportablePrList (PR aktif yang sudah ada hasil +
                // seluruh PR yang dinonaktifkan), dengan semua aksi (Lihat
                // Hasil, Download CSV, Reactivate, Delete) di satu kartu.
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: _getReportablePrList(),
                  builder: (ctx, snapshot) {
                    final deactivatedList = snapshot.data ?? [];

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),
                        const Divider(color: _kNavyDark, height: 1),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Icon(Icons.inventory_2_rounded, color: _kNavyDark, size: 22),
                            const SizedBox(width: 8),
                            Text('📜 Riwayat PR / Pekerjaan Rumah (${deactivatedList.length}):', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (deactivatedList.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                            child: const Center(
                              child: Text('Belum ada riwayat.', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
                            ),
                          )
                        else
                          ...deactivatedList.map((hw) {
                            final title = hw['title']?.toString() ?? hw['quiz_title']?.toString() ?? 'PR Mandiri';
                            final desc = hw['description']?.toString() ?? '';
                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
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
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(color: const Color(0xFFFDE68A), shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1)),
                                        child: const Icon(Icons.pause_circle_outline_rounded, color: Color(0xFFB45309), size: 20),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark)),
                                            if (desc.trim().isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Text(desc, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      ElevatedButton.icon(
                                        onPressed: () => _viewHomeworkGradesDialog(hw),
                                        style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                        icon: const Icon(Icons.analytics_rounded, size: 16),
                                        label: const Text('📊 View Student Results', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                      ),
                                      // FITUR "Gabungkan Rekap & Riwayat" (poin 3): tombol
                                      // Download CSV yang sebelumnya hanya ada di kartu
                                      // "Rekap PR" terpisah, sekarang jadi bagian dari
                                      // SATU kartu Riwayat PR ini.
                                      ElevatedButton.icon(
                                        onPressed: () async {
                                          final targetId = (hw['quiz_id']?.toString().isNotEmpty == true) ? hw['quiz_id'].toString() : (hw['id']?.toString() ?? '');
                                          final results = await QuizizzService.getQuizResults(targetId);
                                          if (results.isEmpty) {
                                            if (mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Belum ada hasil mahasiswa untuk direkap.')));
                                            }
                                            return;
                                          }
                                          final buffer = StringBuffer();
                                          buffer.writeln('Peringkat,Nama Mahasiswa,Skor,Total Soal,Waktu Selesai');
                                          for (final r in results) {
                                            final name = (r['student_name'] ?? 'Mahasiswa').toString().replaceAll('"', '""');
                                            buffer.writeln('${r['rank'] ?? ''},"$name",${r['score'] ?? 0},${r['total_questions'] ?? 0},"${r['completed_at'] ?? ''}"');
                                          }
                                          final cleanTitle = title.toString().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
                                          ExportHelper.exportCsv(filename: 'Rekap_$cleanTitle.csv', content: buffer.toString());
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('📥 CSV Rekap Berhasil Di-download!'), backgroundColor: _kNavyDark),
                                            );
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                        icon: const Icon(Icons.download_rounded, size: 16),
                                        label: const Text('Download CSV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                      ),
                                      ElevatedButton.icon(
                                        onPressed: () async {
                                          final hwId = hw['id']?.toString() ?? '';
                                          final quizId = hw['quiz_id']?.toString() ?? '';
                                          await QuizizzService.reactivateHomework(hwId, quizId: quizId);
                                          await _fetchHomeworkList();
                                          if (mounted) {
                                            setState(() {});
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('🔄 PR berhasil diaktifkan kembali!'), backgroundColor: Color(0xFF059669)),
                                            );
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                        icon: const Icon(Icons.refresh_rounded, size: 16),
                                        label: const Text('🔄 Reactivate', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () async {
                                          final hwId = hw['id']?.toString() ?? '';
                                          final quizId = hw['quiz_id']?.toString() ?? '';
                                          final confirm = await showDialog<bool>(
                                            context: context,
                                            builder: (dctx) => AlertDialog(
                                              backgroundColor: Colors.white,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                              title: const Text('Hapus Permanen?', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                                              content: const Text('PR beserta seluruh hasil pengerjaan mahasiswa akan dihapus permanen dan tidak bisa dikembalikan.', style: TextStyle(color: Colors.black87)),
                                              actions: [
                                                TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
                                                ElevatedButton(
                                                  onPressed: () => Navigator.pop(dctx, true),
                                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                                                  child: const Text('Hapus Permanen'),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (confirm != true) return;
                                          await QuizizzService.deletePermanentlyFromHistory(hwId, quizId: quizId);
                                          if (mounted) {
                                            setState(() {});
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('🗑️ Riwayat PR berhasil dihapus permanen!'), backgroundColor: Colors.redAccent),
                                            );
                                          }
                                        },
                                        style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: _kNavyDark, width: 1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                                        label: const Text('🗑️ Delete', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
                    );
                  },
                ),
        const SizedBox(height: 28),
        const Divider(color: _kNavyDark, height: 1),
        const SizedBox(height: 20),
        Row(
          children: [
            const Icon(Icons.slideshow_rounded, color: _kNavyDark, size: 22),
            const SizedBox(width: 8),
            const Text('🖥️ Riwayat Presentasi (Lesson) yang Pernah Dijalankan', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: _kNavyDark)),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: QuizizzService.getLessons(),
          builder: (ctx, lessonSnapshot) {
            final lessons = lessonSnapshot.data ?? [];
            if (!lessonSnapshot.hasData) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Center(child: CircularProgressIndicator(color: _kNavyDark)));
            }
            if (lessons.isEmpty) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                child: const Center(child: Text('Belum ada presentasi yang dibuat.', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600))),
              );
            }
            return Column(children: lessons.map((lsn) => _buildLessonHistoryCard(lsn)).toList());
          },
        ),
      ],
    );
  }

  // Kartu riwayat presentasi: menampilkan setiap kali presentasi ini pernah
  // dijalankan live (kode sesi, status, jumlah respon slide, jumlah
  // jawaban soal interaktif, dan jumlah pertanyaan Q&A yang masuk).
  Widget _buildLessonHistoryCard(Map<String, dynamic> lesson) {
    final lessonId = lesson['id']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFBAE6FD), shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1)),
                child: const Icon(Icons.slideshow_rounded, color: Color(0xFF0284C7), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(lesson['title']?.toString() ?? 'Presentasi', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: QuizizzService.getLessonSessionHistory(lessonId),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator(color: _kNavyDark));
              }
              final sessions = snap.data!;
              if (sessions.isEmpty) {
                return const Text('Belum pernah dijalankan secara live.', style: TextStyle(fontSize: 12, color: Colors.black54, fontStyle: FontStyle.italic));
              }
              return Column(
                children: sessions.map((s) {
                  DateTime? time;
                  try { time = DateTime.parse(s['created_at'].toString()); } catch (_) {}
                  final isEnded = s['status']?.toString() == 'ended';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isEnded ? const Color(0xFFE5E7EB) : const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _kNavyDark, width: 1),
                              ),
                              child: Text(isEnded ? '⚪ Selesai' : '🟢 ${s['status']}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: _kNavyDark)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Kode: ${s['session_code']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                                  if (time != null)
                                    Text('${time.day}/${time.month}/${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} WIB', style: const TextStyle(fontSize: 10, color: Colors.black54)),
                                ],
                              ),
                            ),
                            Text('📨 ${s['response_count']}  🎯 ${s['question_answer_count']}  💬 ${s['qa_count']}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black54)),
                          ],
                        ),
                        // FITUR "Riwayat & Nilai Presentasi di Report" (poin 1):
                        // dosen bisa melihat lagi nilai total hasil soal
                        // presentasi ini kapan saja, bukan cuma sekali muncul
                        // saat sesi baru diakhiri, dan bisa di-download CSV.
                        if (isEnded)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    final results = await QuizizzService.getLessonFinalResults(s['session_code'].toString());
                                    if (!context.mounted) return;
                                    if ((results['leaderboard'] as List).isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Belum ada soal yang dijawab pada sesi ini.')));
                                      return;
                                    }
                                    await showLessonFinalResultsDialog(context, results, isDosen: true);
                                  },
                                  style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                  icon: const Icon(Icons.analytics_rounded, size: 16),
                                  label: const Text('📊 Lihat Hasil', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                ),
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    final results = await QuizizzService.getLessonFinalResults(s['session_code'].toString());
                                    final leaderboard = (results['leaderboard'] as List?) ?? [];
                                    if (leaderboard.isEmpty) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Belum ada soal yang dijawab pada sesi ini.')));
                                      }
                                      return;
                                    }
                                    final buffer = StringBuffer();
                                    buffer.writeln('Peringkat,Nama Mahasiswa,Jawaban Benar,Total Dijawab');
                                    for (var i = 0; i < leaderboard.length; i++) {
                                      final row = leaderboard[i];
                                      final name = (row['student_name'] ?? 'Mahasiswa').toString().replaceAll('"', '""');
                                      buffer.writeln('${i + 1},"$name",${row['correct'] ?? 0},${row['answered'] ?? 0}');
                                    }
                                    final cleanTitle = (lesson['title']?.toString() ?? 'Presentasi').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
                                    ExportHelper.exportCsv(filename: 'Riwayat_Presentasi_$cleanTitle.csv', content: buffer.toString());
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('📥 CSV Riwayat Berhasil Di-download!'), backgroundColor: _kNavyDark),
                                      );
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                                  icon: const Icon(Icons.download_rounded, size: 16),
                                  label: const Text('Download CSV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildReportCard({
    required String title,
    required String subtitle,
    required String quizId,
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1)),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: () => _viewHomeworkGradesDialog({'id': quizId, 'title': title}),
                style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                icon: const Icon(Icons.visibility_rounded, size: 16),
                label: const Text('Lihat Hasil', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  final results = await QuizizzService.getQuizResults(quizId);
                  if (results.isEmpty) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Belum ada hasil mahasiswa untuk direkap.')));
                    }
                    return;
                  }
                  final buffer = StringBuffer();
                  buffer.writeln('Peringkat,Nama Mahasiswa,Skor,Total Soal,Waktu Selesai');
                  for (final r in results) {
                    final name = (r['student_name'] ?? 'Mahasiswa').toString().replaceAll('"', '""');
                    buffer.writeln('${r['rank'] ?? ''},"$name",${r['score'] ?? 0},${r['total_questions'] ?? 0},"${r['completed_at'] ?? ''}"');
                  }
                  final cleanTitle = title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
                  ExportHelper.exportCsv(filename: 'Rekap_$cleanTitle.csv', content: buffer.toString());
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('📥 CSV Rekap Berhasil Di-download!'), backgroundColor: _kNavyDark),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _kNavyDark, width: 1))),
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('Download CSV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ======================================================================
// DOSEN LIVE PRESENTATION (LESSON MODE) HOST SCREEN
// ======================================================================
class _HostLessonLiveScreen extends StatefulWidget {
  final String sessionCode;
  final Map<String, dynamic> lesson;

  const _HostLessonLiveScreen({required this.sessionCode, required this.lesson});

  @override
  State<_HostLessonLiveScreen> createState() => _HostLessonLiveScreenState();
}

class _HostLessonLiveScreenState extends State<_HostLessonLiveScreen> {
  String _displayMode = 'semi';
  int _currentSlideIndex = 0;
  List<dynamic> _slides = [];
  Map<String, dynamic> _lessonState = {};
  Timer? _timer;
  String _roomStatus = 'waiting';

  // Fitur "Kelola Soal Presentasi" (poin 2) + "Aktifkan hingga 2 soal
  // sekaligus" + "Timer soal" + "Indikator soal sudah digunakan"
  List<Map<String, dynamic>> _lessonQuestions = [];
  List<String> _activeQuestionIds = [];
  Map<String, dynamic> _questionActivatedAt = {};
  List<String> _activatedHistory = [];
  final Map<String, Map<String, dynamic>> _questionResultsById = {};

  // Fitur "Tanya-Jawab Live" (poin 3)
  List<Map<String, dynamic>> _qaMessages = [];

  bool _pointerActive = false;
  double? _localPointerX;
  double? _localPointerY;

  bool _showQaPanel = true;
  String? _notificationMsg;
  Timer? _notifTimer;

  void _showNotif(String msg) {
    setState(() => _notificationMsg = msg);
    _notifTimer?.cancel();
    _notifTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notificationMsg = null);
    });
  }

  @override
  void initState() {
    super.initState();
    SocketService.instance.on('connect', (_) {
      SocketService.instance.emit('join', widget.sessionCode);
    });
    if (SocketService.instance.connected == true) {
      SocketService.instance.emit('join', widget.sessionCode);
    }
    _slides = widget.lesson['slides'] ?? [];
    _loadQuestionBank();
    _pollState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollState());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadQuestionBank() async {
    final lessonId = widget.lesson['id']?.toString() ?? '';
    if (lessonId.isEmpty) return;
    final list = await QuizizzService.getLessonQuestions(lessonId);
    
    // PROCESS Variable Calculations for Lesson Questions
    for (int idx = 0; idx < list.length; idx++) {
      list[idx] = processVariableCalculations(list[idx], studentIdentifier: 'host', questionIndex: idx);
    }

    if (mounted) setState(() => _lessonQuestions = list);
  }

  Future<void> _pollState() async {
    // FITUR "Sinkronisasi Soal Dosen <-> Mahasiswa" (poin 1): ikut
    // menyegarkan bank soal di sisi dosen tiap polling, konsisten dengan
    // perbaikan yang sama di sisi mahasiswa (lihat _StudentLessonActiveScreenState._poll).
    _loadQuestionBank();
    final st = await QuizizzService.getLessonSessionState(widget.sessionCode);
    if (!mounted) return;
    setState(() {
      _lessonState = st;
      _roomStatus = st['status']?.toString() ?? 'waiting';
    });
    // Poll ulang detail sesi supaya tahu soal mana saja yang aktif saat ini.
    final full = await QuizizzService.getLessonSessionByCode(widget.sessionCode);
    if (mounted && full != null) {
      setState(() {
        _activeQuestionIds = List<String>.from(full['active_question_ids'] ?? []);
        _questionActivatedAt = Map<String, dynamic>.from(full['question_activated_at'] ?? {});
        _activatedHistory = List<String>.from(full['activated_history'] ?? []);
      });
    }
    for (final qId in _activeQuestionIds) {
      final results = await QuizizzService.getLessonQuestionResults(widget.sessionCode, qId);
      if (mounted) setState(() => _questionResultsById[qId] = results);
    }
    final qa = await QuizizzService.getLessonQaMessages(widget.sessionCode);
    if (mounted) {
      if (_qaMessages.isNotEmpty && qa.length > _qaMessages.length) {
        final newest = qa[0];
        final sender = newest['student_name'] ?? 'Mahasiswa';
        final text = (newest['message'] ?? '').toString();
        final preview = text.length > 40 ? text.substring(0, 40) + '...' : text;
        _showNotif('💬 $sender: $preview');
      }
      setState(() => _qaMessages = qa);
    }

  }

  // FITUR "Balas Pertanyaan" (poin 5): dosen mengetik jawaban langsung untuk
  // pertanyaan mahasiswa tertentu, tersimpan & otomatis muncul di layar
  // mahasiswa yang bertanya.
  Future<void> _showReplyToQaDialog(Map<String, dynamic> q) async {
    final replyCtrl = TextEditingController(text: q['reply']?.toString() ?? '');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: Text('💬 Balas Pertanyaan ${q['student_name'] ?? 'Mahasiswa'}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 15)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(10)),
                child: Text(q['message'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600, color: _kNavyDark, fontSize: 13)),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              final reply = replyCtrl.text.trim();
              if (reply.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Isi balasan terlebih dahulu')));
                return;
              }
              await QuizizzService.replyLessonQa(widget.sessionCode, q['id'].toString(), reply);
              if (ctx.mounted) Navigator.pop(ctx);
              await _pollState();
            },
            style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('Kirim Balasan', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _startPresentation() async {
    await QuizizzService.updateLessonSessionState(widget.sessionCode, status: 'active', currentSlideIndex: 0);
    setState(() => _roomStatus = 'active');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🖥️ Presentasi dimulai! Layar mahasiswa langsung berpindah.'), backgroundColor: _kNavyDark),
      );
    }
  }

  // Fitur "Tombol Akhiri Presentasi" + "Hasil nilai muncul saat sesi
  // berakhir": mengubah status sesi jadi 'ended' (mahasiswa otomatis
  // dikeluarkan), lalu tampilkan papan peringkat hasil kuis presentasi.
  Future<void> _endPresentation() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Text('🛑 Akhiri Presentasi?', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        content: const Text('Semua mahasiswa yang sedang mengikuti presentasi ini akan otomatis dikeluarkan dari layar presentasi. Tindakan ini tidak bisa dibatalkan.', style: TextStyle(color: Colors.black54)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('Ya, Akhiri Sekarang', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await QuizizzService.updateLessonSessionState(widget.sessionCode, status: 'ended');
    final results = await QuizizzService.getLessonFinalResults(widget.sessionCode);
    if (!mounted) return;
    if ((results['leaderboard'] as List).isNotEmpty) {
      await showLessonFinalResultsDialog(context, results, isDosen: true);
    }
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🛑 Presentasi diakhiri. Semua mahasiswa dikeluarkan dari sesi.'), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _changeSlide(int index) async {
    if (index < 0 || index >= _slides.length) return;
    setState(() => _currentSlideIndex = index);
    await QuizizzService.updateLessonSessionState(widget.sessionCode, currentSlideIndex: index);
  }

  Future<void> _activateQuestion(String questionId) async {
    final error = await QuizizzService.activateLessonQuestion(widget.sessionCode, questionId);
    if (error != null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('⚠️ $error'), backgroundColor: Colors.orange));
      return;
    }
    setState(() {
      if (!_activeQuestionIds.contains(questionId)) _activeQuestionIds.add(questionId);
      if (!_activatedHistory.contains(questionId)) _activatedHistory.add(questionId);
      _questionActivatedAt[questionId] = DateTime.now().toIso8601String();
      _questionResultsById[questionId] = {'total_answers': 0, 'correct_count': 0, 'tally': {}, 'answers': []};
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🎯 Soal diaktifkan! Mahasiswa sekarang bisa menjawab.'), backgroundColor: Color(0xFF16A34A)),
      );
    }
  }

  Future<void> _deactivateQuestion(String questionId) async {
    await QuizizzService.deactivateLessonQuestion(widget.sessionCode, questionId: questionId);
    setState(() => _activeQuestionIds.remove(questionId));
  }


  @override
  Widget build(BuildContext context) {
    final activeSlide = _slides.isNotEmpty ? _slides[_currentSlideIndex] : {};
    // Catatan: variabel respons-per-slide sengaja tidak lagi ditampilkan di
    // UI (panel "Respon Slide" dihapus atas permintaan), tapi datanya tetap
    // tersimpan di backend kalau suatu saat dibutuhkan lagi.

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        title: Text('Live Presenter: ${widget.lesson['title']}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
            child: Text('KODE PRESENTASI: ${widget.sessionCode}', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13)),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              onPressed: () => showManageLessonQuestionsDialog(
                context,
                lessonId: widget.lesson['id']?.toString() ?? '',
                lessonTitle: widget.lesson['title']?.toString() ?? '',
                onChanged: _loadQuestionBank,
                activatedHistory: _activatedHistory,
              ),
              style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              icon: const Icon(Icons.quiz_rounded, size: 16),
              label: const Text('Kelola Soal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ),
          if (_roomStatus != 'active')
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ElevatedButton.icon(
                onPressed: _startPresentation,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Mulai Presentasi Sekarang', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF16A34A), width: 1.2)),
                child: const Text('🔴 LIVE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF166534))),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _showQaPanel = !_showQaPanel),
              style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              icon: Icon(_showQaPanel ? Icons.forum_outlined : Icons.forum, size: 18),
              label: Text(_showQaPanel ? 'Sembunyikan Q&A' : 'Tampilkan Q&A', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ),
          Padding(

            padding: const EdgeInsets.only(right: 16),
            child: ElevatedButton.icon(
              onPressed: _endPresentation,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              icon: const Icon(Icons.stop_circle_rounded, size: 18),
              label: const Text('Akhiri Presentasi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Row(

        children: [
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // FITUR "Soal Menggantikan Tampilan Slide": begitu ada
                  // soal yang diaktifkan, tampilan slide disembunyikan dan
                  // digantikan sepenuhnya oleh soal yang aktif (bukan lagi
                  // tampil berdampingan) -- baik di layar dosen maupun
                  // mahasiswa.
                  if (_activeQuestionIds.isEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                                child: Text('Slide ${_currentSlideIndex + 1} dari ${_slides.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kQuizizzTextColor)),
                              ),
                              Row(
                                children: [
                                  const Text('Ukuran: ', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 12)),
                                  DropdownButton<String>(
                                    value: _displayMode,
                                    underline: const SizedBox(),
                                    style: const TextStyle(fontSize: 12, color: _kNavyDark, fontWeight: FontWeight.bold),
                                    items: const [
                                      DropdownMenuItem(value: 'default', child: Text('Default')),
                                      DropdownMenuItem(value: 'semi', child: Text('Semi Full Screen (3/4)')),
                                      DropdownMenuItem(value: 'full', child: Text('Full Screen (100%)')),
                                    ],
                                    onChanged: (v) {
                                      if (v != null) setState(() => _displayMode = v);
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(color: const Color(0xFFBAE6FD), borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                                    child: Text('Tipe: ${activeSlide['type']}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0284C7))),
                                  ),
                                  const SizedBox(width: 8),
                                  Row(
                                    children: [
                                      const Text('Laser Pointer', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 12)),
                                      Switch(
                                        value: _pointerActive,
                                        activeColor: Colors.red,
                                        onChanged: (v) {
                                          setState(() => _pointerActive = v);
                                          if (!v) {
                                            setState(() { _localPointerX = null; _localPointerY = null; });
                                            SocketService.instance.emit('pointer_update', {'room': widget.sessionCode, 'x': -1, 'y': -1});
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Text(activeSlide['title'] ?? 'Slide Materi', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: _kNavyDark)),
                          const SizedBox(height: 12),
                          const Divider(color: _kNavyDark, height: 1),
                          const SizedBox(height: 16),
                          if (activeSlide['media_url'] != null && activeSlide['media_url'].toString().isNotEmpty) ...[
                            Builder(
                              builder: (ctx) {
                                void handlePointer(PointerEvent e) {
                                  if (!_pointerActive) return;
                                  final size = ctx.size;
                                  if (size != null) {
                                    final px = e.localPosition.dx / size.width;
                                    final py = e.localPosition.dy / size.height;
                                    setState(() { _localPointerX = px; _localPointerY = py; });
                                    SocketService.instance.emit('pointer_update', {
                                      'room': widget.sessionCode,
                                      'x': px,
                                      'y': py,
                                    });
                                  }
                                }
                                void handlePointerExit(PointerEvent e) {
                                  if (mounted) setState(() { _localPointerX = null; _localPointerY = null; });
                                  SocketService.instance.emit('pointer_update', {'room': widget.sessionCode, 'x': -1, 'y': -1});
                                }
                                return Listener(
                                  onPointerHover: handlePointer,
                                  onPointerMove: handlePointer,
                                  onPointerDown: handlePointer,
                                  child: MouseRegion(
                                    onExit: handlePointerExit,
                                    child: Stack(
                                      children: [
                                        _buildQuestionImageWidget(activeSlide['media_url'].toString(), displayMode: _displayMode, context: context),
                                        if (_pointerActive && _localPointerX != null && _localPointerY != null)
                                          Positioned.fill(
                                            child: Align(
                                              alignment: FractionalOffset(_localPointerX!.clamp(0.0, 1.0), _localPointerY!.clamp(0.0, 1.0)),
                                              child: Transform.translate(
                                                offset: const Offset(-14, -14),
                                                child: Container(
                                                  width: 28,
                                                  height: 28,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: Colors.red.withOpacity(0.4),
                                                    border: Border.all(color: Colors.red, width: 4),
                                                    boxShadow: const [BoxShadow(color: Colors.white, blurRadius: 2, spreadRadius: 1)],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 16),
                          ],
                          Text(activeSlide['content'] ?? '', style: const TextStyle(fontSize: 16, height: 1.6, color: _kNavyDark, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _currentSlideIndex > 0 ? () => _changeSlide(_currentSlideIndex - 1) : null,
                          style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Slide Sebelumnya', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        ElevatedButton.icon(
                          onPressed: _currentSlideIndex + 1 < _slides.length ? () => _changeSlide(_currentSlideIndex + 1) : null,
                          style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Slide Berikutnya', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ] else
                    // Tampilan pengganti slide saat soal sedang aktif (bisa
                    // sampai 2 soal sekaligus): fokus penuh ke soal, tidak
                    // ada lagi slide materi yang mengganggu perhatian.
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(color: const Color(0xFFFFF7E0), borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.bolt_rounded, color: Color(0xFFEA580C), size: 28),
                              SizedBox(width: 8),
                              Text('SOAL SEDANG BERLANGSUNG', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFFEA580C))),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text('Slide materi disembunyikan sementara — mahasiswa sedang fokus menjawab.', style: TextStyle(fontSize: 12, color: Colors.black54, fontStyle: FontStyle.italic)),
                          const SizedBox(height: 16),
                          ..._activeQuestionIds.map((qId) {
                            final q = _lessonQuestions.firstWhere((qq) => qq['id'].toString() == qId, orElse: () => {});
                            final results = _questionResultsById[qId] ?? {'total_answers': 0, 'correct_count': 0, 'tally': {}};
                            return Container(
                              margin: const EdgeInsets.only(bottom: 14),
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF16A34A), width: 1.6)),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // FITUR "Gambar di Pertanyaan" (poin 4): dosen
                                  // juga melihat gambar soal di panel monitoringnya.
                                  if ((q['image_url'] ?? '').toString().isNotEmpty) ...[
                                    SizedBox(height: 140, child: _buildQuestionImageWidget(q['image_url'].toString())),
                                    const SizedBox(height: 10),
                                  ],
                                  Text(q['question_text'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kNavyDark)),
                                  const SizedBox(height: 10),
                                  Text('📊 ${results['total_answers']} mahasiswa menjawab, ${results['correct_count']} benar', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                                  const SizedBox(height: 6),
                                  ...((results['tally'] as Map).entries.map((e) => Padding(
                                        padding: const EdgeInsets.only(bottom: 3),
                                        child: Text('${e.key}: ${e.value} suara', style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600)),
                                      ))),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: () => _deactivateQuestion(qId),
                                    style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent, width: 1.2)),
                                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                                    label: const Text('Nonaktifkan & Kembali ke Slide', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),

                  // FITUR "AKTIFKAN SOAL" (poin 2 & 4): dosen pilih soal dari
                  // bank soal untuk ditampilkan & bisa langsung dijawab
                  // mahasiswa kapanpun saat presentasi berlangsung, terlepas
                  // dari slide. Mendukung MAKSIMAL 2 SOAL AKTIF BERSAMAAN.
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)]),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(child: Text('🎯 Soal Interaktif (Maks. 2 Aktif Bersamaan)', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: _kNavyDark))),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: _activeQuestionIds.length >= 2 ? const Color(0xFFFEE2E2) : _kCreamBg, borderRadius: BorderRadius.circular(12)),
                              child: Text('${_activeQuestionIds.length}/2 Aktif', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _activeQuestionIds.length >= 2 ? Colors.redAccent : _kNavyDark)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (_lessonQuestions.isEmpty)
                          const Text('Belum ada soal di bank soal. Tekan "Kelola Soal" di pojok kanan atas untuk membuat soal.', style: TextStyle(fontSize: 12, color: Colors.black54))
                        else
                          Column(
                            children: _lessonQuestions.map((q) {
                              final qId = q['id'].toString();
                              final isActive = _activeQuestionIds.contains(qId);
                              final isUsed = _activatedHistory.contains(qId);
                              const typeBadgesMap = {'true_false': 'B/S', 'multi_select': 'MULTI', 'short_answer': 'ISIAN'};
                              final typeBadge = typeBadgesMap[q['question_type']] ?? 'PG';
                              final canActivate = isActive || _activeQuestionIds.length < 2;
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isActive ? const Color(0xFFDCFCE7) : _kCreamBg,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: isActive ? const Color(0xFF16A34A) : _kNavyDark, width: isActive ? 1.6 : 1),
                                ),
                                child: Row(
                                  children: [
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          margin: const EdgeInsets.only(right: 10),
                                          decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(8)),
                                          child: Text(typeBadge, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: _kQuizizzTextColor)),
                                        ),
                                        // Fitur "Indikator Soal Sudah Digunakan"
                                        if (isUsed && !isActive) ...[
                                          const SizedBox(height: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            margin: const EdgeInsets.only(right: 10),
                                            decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(8)),
                                            child: const Text('✓ Dipakai', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.black54)),
                                          ),
                                        ],
                                      ],
                                    ),
                                    Expanded(
                                      child: Text(q['question_text'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                                    ),
                                    const SizedBox(width: 10),
                                    ElevatedButton.icon(
                                      onPressed: !canActivate ? null : () => isActive ? _deactivateQuestion(qId) : _activateQuestion(qId),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isActive ? const Color(0xFF16A34A) : _kNavyDark,
                                        foregroundColor: Colors.white,
                                        disabledBackgroundColor: Colors.black26,
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                      ),
                                      icon: Icon(isActive ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded, size: 16),
                                      label: Text(isActive ? 'Nonaktifkan' : '🚀 Aktifkan', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_displayMode != 'full' && _showQaPanel)
            SizedBox(
              width: 340,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: ChatPanelWidget(
                  qaMessages: _qaMessages,
                  currentUserRole: 'teacher',
                  currentUserName: 'Dosen',
                  currentUserId: null, // Teacher doesn't need ID here
                  onSendMessage: (msg, isPriv, toId, toName) async {
                    await QuizizzService.askLessonQuestion(
                      widget.sessionCode,
                      studentName: 'Dosen',
                      message: msg,
                      senderRole: 'teacher',
                      isPrivate: isPriv,
                      toUserId: toId,
                      toUserName: toName,
                    );
                    await _pollState();
                  },
                  onReplyMessage: (qId, reply) async {
                    await QuizizzService.replyLessonQa(
                      widget.sessionCode, 
                      qId, 
                      reply,
                      senderName: 'Dosen',
                      senderRole: 'teacher',
                    );
                    await _pollState();
                  },
                  onMarkAnswered: (qId) async {
                    await QuizizzService.markLessonQaAnswered(widget.sessionCode, qId);
                    await _pollState();
                  },
                ),
              ),
            ),
        ],
      )),
      if (_notificationMsg != null)
        Positioned(
          bottom: 24,
          right: 24,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            color: Colors.transparent,
            child: Container(
              width: 350,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(color: _kNavyDark, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kMustardYellow, width: 2)),
              child: Row(
                children: [
                  const Icon(Icons.notifications_active_rounded, color: _kMustardYellow, size: 28),
                  const SizedBox(width: 16),
                  Expanded(child: Text(_notificationMsg!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
                ],
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }
}
// ======================================================================
// DOSEN LIVE GAMIFIED QUIZ HOST SCREEN (CONTROL ROOM & START BUTTON)
// ======================================================================
class _HostLiveScreen extends StatefulWidget {
  final String pin;
  final String title;
  final String quizId;
  final String sessionId;

  const _HostLiveScreen({required this.pin, required this.title, required this.quizId, required this.sessionId});

  @override
  State<_HostLiveScreen> createState() => _HostLiveScreenState();
}

class _HostLiveScreenState extends State<_HostLiveScreen> {
  List<dynamic> _leaderboard = [];
  String _roomStatus = 'waiting'; // waiting -> active
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _pollLeaderboard();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollLeaderboard());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _pollLeaderboard() async {
    final st = await QuizizzService.getLiveSessionStatus(widget.pin);
    if (mounted && st != _roomStatus) {
      setState(() => _roomStatus = st);
    }
    try {
      final res = await QuizizzService.getLeaderboard(widget.sessionId);
      if (mounted) {
        setState(() {
          _leaderboard = (res['leaderboard'] as List?) ?? [];
        });
      }
    } catch (_) {}
  }

  Future<void> _startGameRoom() async {
    await QuizizzService.markLiveQuizDone(widget.quizId);
    await QuizizzService.updateLiveSessionStatus(widget.pin, 'active');
    setState(() => _roomStatus = 'active');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🚀 Room Game Resmi Dimulai! Kuis Otomatis Masuk Ke Riwayat!'), backgroundColor: _kNavyDark));
    }
  }

  void _showPodiumDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Text('🏆 PODIUM JUARA KUIS GAMIFIKASI 🏆', style: TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark), textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: _kMustardYellow, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.5)),
              child: const Icon(Icons.emoji_events_rounded, size: 50, color: _kNavyDark),
            ),
            const SizedBox(height: 16),
            if (_leaderboard.isEmpty)
              const Text('Belum ada mahasiswa yang menyelesaikan kuis live ini.', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark), textAlign: TextAlign.center)
            else ...[
              if (_leaderboard.isNotEmpty)
                Text('🥇 JUARA 1: ${_leaderboard[0]['display_name']} (${_leaderboard[0]['score']} Pts)', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
              if (_leaderboard.length > 1) ...[
                const SizedBox(height: 6),
                Text('🥈 JUARA 2: ${_leaderboard[1]['display_name']} (${_leaderboard[1]['score']} Pts)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0284C7))),
              ],
              if (_leaderboard.length > 2) ...[
                const SizedBox(height: 4),
                Text('🥉 JUARA 3: ${_leaderboard[2]['display_name']} (${_leaderboard[2]['score']} Pts)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFFEA580C))),
              ],
            ],
          ],
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: _leaderboard.isEmpty ? null : _downloadResultsCsv,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            icon: const Icon(Icons.download_rounded, size: 16),
            label: const Text('Download CSV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark))),
        ],
      ),
    );
  }

  // Unduh SELURUH hasil akhir mahasiswa yang bergabung di sesi ini sebagai
  // file CSV (Peringkat, Nama, Skor, Status Pengerjaan).
  void _downloadResultsCsv() {
    final buffer = StringBuffer();
    buffer.writeln('Peringkat,Nama Mahasiswa,Skor,Status');
    for (int i = 0; i < _leaderboard.length; i++) {
      final p = _leaderboard[i];
      final name = (p['display_name'] ?? 'Mahasiswa').toString().replaceAll('"', '""');
      final score = p['score'] ?? 0;
      final completed = (p['completed'] == 1 || p['completed'] == true) ? 'Selesai' : 'Belum Selesai';
      buffer.writeln('${i + 1},"$name",$score,$completed');
    }
    final cleanTitle = widget.title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    ExportHelper.exportCsv(filename: 'Hasil_Akhir_Quiz_${cleanTitle}.csv', content: buffer.toString());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('📥 File CSV Hasil Akhir Berhasil Di-download!'), backgroundColor: _kNavyDark),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        title: Text('Live Host Gamifikasi: ${widget.title}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, color: _kNavyDark),
            onPressed: _leaderboard.isEmpty ? null : _downloadResultsCsv,
            tooltip: 'Download CSV Hasil Akhir',
          ),
          IconButton(
            icon: const Icon(Icons.emoji_events_rounded, color: _kNavyDark),
            onPressed: _showPodiumDialog,
            tooltip: 'Lihat Podium Juara',
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(children: [


              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _roomStatus == 'waiting' ? const Color(0xFFFFEDD5) : const Color(0xFFA7F3D0),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _kNavyDark, width: 1),
                          ),
                          child: Text(
                            _roomStatus == 'waiting' ? '⏳ WAITING ROOM (MENUNGGU DOSEN START)' : '🟢 GAME AKTIF / SEDANG BERJALAN',
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: _roomStatus == 'waiting' ? const Color(0xFFEA580C) : const Color(0xFF059669)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('KODE PIN GAME GAMIFIKASI', style: TextStyle(color: _kNavyDark, fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(widget.pin, style: const TextStyle(color: _kNavyDark, fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 6)),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Salin Kode PIN',
                          icon: const Icon(Icons.copy_rounded, color: _kNavyDark, size: 22),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: widget.pin));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('📋 Kode PIN berhasil disalin ke clipboard!'), backgroundColor: _kNavyDark, duration: Duration(seconds: 2)),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // URL Info & Salin Link untuk Mahasiswa
                    Builder(
                      builder: (ctx) {
                        final origin = kIsWeb ? html.window.location.origin : 'http://localhost:4000';
                        final joinUrl = '$origin/?pin=${widget.pin}';
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: _kCreamBg.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _kNavyDark.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.link_rounded, color: _kNavyDark, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('URL Akses Mahasiswa:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
                                    SelectableText(joinUrl, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: _kNavyDark)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              ElevatedButton.icon(
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: joinUrl));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('🔗 Link akses mahasiswa berhasil disalin!'), backgroundColor: _kNavyDark, duration: Duration(seconds: 2)),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _kNavyDark,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                icon: const Icon(Icons.copy_all_rounded, size: 14),
                                label: const Text('Salin Link', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    if (_roomStatus == 'waiting')
                      ElevatedButton.icon(
                        onPressed: _startGameRoom,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kMustardYellow,
                          foregroundColor: _kNavyDark,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 1.5)),
                        ),
                        icon: const Icon(Icons.rocket_launch_rounded, size: 20),
                        label: const Text('🚀 START GAME ROOM NOW', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Builder(
                builder: (ctx) {
                  final origin = kIsWeb ? html.window.location.origin : 'http://localhost:4000';
                  final joinUrl = '$origin/?pin=${widget.pin}';
                  return SessionQrCode(
                    code: joinUrl,
                    color: _kNavyDark,
                    label: 'Scan QR untuk langsung gabung kuis',
                  );
                },
              ),
              const SizedBox(height: 24),
              Container(
                width: 480,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🏆 Live Leaderboard Skor Real-Time:', style: TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark)),
                    const SizedBox(height: 12),
                    ..._leaderboard.asMap().entries.map((entry) {
                      final rank = entry.key + 1;
                      final player = entry.value;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: rank == 1 ? _kMustardYellow : _kCreamBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                        child: Row(
                          children: [
                            Text('#$rank', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark)),
                            const SizedBox(width: 12),
                            Expanded(child: Text(player['display_name'] ?? 'Pemain', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark))),
                            Text('${player['score']} Pts', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark)),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _showPodiumDialog,
                        style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                        icon: const Icon(Icons.emoji_events_rounded, size: 18),
                        label: const Text('🎉 Show Winners Podium', style: TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// ALUR MAHASISWA (3 SUB TAB: JOIN LIVE, PR MANDIRI, FLASHCARDS)
// ======================================================================
class _MahasiswaFlow extends StatefulWidget {
  const _MahasiswaFlow();

  @override
  State<_MahasiswaFlow> createState() => _MahasiswaFlowState();
}

class _MahasiswaFlowState extends State<_MahasiswaFlow> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    // PENTING: tab "Join Live Host PIN" dan "Presentation" digabung jadi SATU
    // tab ("🚀 Join Live / Presentasi") supaya mahasiswa tidak perlu
    // berpindah tab untuk join kuis PIN vs join presentasi — keduanya
    // ditampilkan sekaligus pada halaman yang sama. Total tab jadi 3
    // (sebelumnya 4).
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          color: _kCreamBg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 1.2)),
            child: TabBar(
              controller: _tabController,
              labelColor: _kNavyDark,
              unselectedLabelColor: Colors.black54,
              indicator: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1)),
              tabs: const [
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.rocket_launch_rounded, size: 16), SizedBox(width: 4), Text('🚀 Join Live', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.analytics_rounded, size: 16), SizedBox(width: 4), Text('📊 Nilai Saya', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.qr_code_scanner_rounded, size: 16), SizedBox(width: 4), Text('📷 Presensi QR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.assignment_rounded, size: 16), SizedBox(width: 4), Text('📝 Homework', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
                Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.style_rounded, size: 16), SizedBox(width: 4), Text('🎴 Flashcards', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))])),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _MahasiswaJoinAndLessonSubTab(),
          MahasiswaGradesSubTab(),
          MahasiswaAttendanceSubTab(),
          _MahasiswaHomeworkSubTab(),
          _MahasiswaFlashcardsSubTab(),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------
// MAHASISWA SUB TAB 1 (GABUNGAN): JOIN LIVE HOST PIN + JOIN PRESENTASI
// ----------------------------------------------------------------------
// PENTING: sebelumnya "Join Live Host PIN" (_MahasiswaJoinSubTab) dan
// "Presentation" (_MahasiswaLessonJoinSubTab) adalah 2 tab terpisah.
// Sekarang digabung dalam SATU halaman/tab yang sama — kedua form join
// (PIN kuis & kode presentasi) ditampilkan sekaligus, dipisahkan garis
// "ATAU", tanpa mengubah logika join masing-masing sama sekali.
class _MahasiswaJoinAndLessonSubTab extends StatelessWidget {
  const _MahasiswaJoinAndLessonSubTab();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          const _MahasiswaJoinSubTab(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 4),
            child: Row(
              children: [
                Expanded(child: Divider(color: _kNavyDark.withOpacity(0.25), thickness: 1.2)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('ATAU', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: _kNavyDark.withOpacity(0.6))),
                ),
                Expanded(child: Divider(color: _kNavyDark.withOpacity(0.25), thickness: 1.2)),
              ],
            ),
          ),
          const _MahasiswaLessonJoinSubTab(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------
// MAHASISWA SUB TAB 1: JOIN SESI LIVE (PIN CODE -> WAITING ROOM)
// ----------------------------------------------------------------------
class _MahasiswaJoinSubTab extends StatefulWidget {
  const _MahasiswaJoinSubTab();

  @override
  State<_MahasiswaJoinSubTab> createState() => _MahasiswaJoinSubTabState();
}

class _MahasiswaJoinSubTabState extends State<_MahasiswaJoinSubTab> {
  final _pinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkUrlPinParam();
  }

  void _checkUrlPinParam() {
    if (kIsWeb) {
      try {
        final uri = Uri.base;
        final p = uri.queryParameters['pin'] ?? uri.queryParameters['join'] ?? uri.queryParameters['code'];
        if (p != null && p.trim().isNotEmpty) {
          _pinController.text = p.trim();
        }
      } catch (_) {}
    }
  }
  final _nameController = TextEditingController();
  // FITUR "Enter Langsung Submit" (poin 1): FocusNode agar Enter di field
  // PIN memindah fokus ke field Nama, lalu Enter di field Nama langsung join.
  final _nameFieldFocusNode = FocusNode();
  bool _loading = false;

  @override
  void dispose() {
    _pinController.dispose();
    _nameController.dispose();
    _nameFieldFocusNode.dispose();
    super.dispose();
  }

  Future<void> _joinSession() async {
    final pin = _pinController.text.trim();
    final name = _nameController.text.trim();
    if (pin.isEmpty || name.isEmpty) return;

    setState(() => _loading = true);
    try {
      // Sumber utama: langsung tanya BACKEND (berlaku untuk semua perangkat),
      // bukan hanya localStorage lokal, supaya PIN dari dosen di device lain
      // tetap dikenali.
      final sessionRes = await QuizizzService.getSessionByPin(pin);
      final session = (sessionRes['session'] as Map<String, dynamic>?) ?? {};
      final quizId = session['quiz_id']?.toString() ?? '';
      final sessionId = session['id']?.toString() ?? '';
      final status = (session['session_status'] ?? session['status'])?.toString() ?? 'waiting';
      final isActive = status == 'active' || status == 'in_progress' || status == 'started';

      if (mounted) {
        if (isActive && sessionId.isNotEmpty) {
          // Room sudah dimulai duluan oleh dosen -> daftar sebagai pemain lalu
          // langsung masuk ke soal (tanpa singgah di waiting room).
          String playerId = 'p_${DateTime.now().millisecondsSinceEpoch}';
          try {
            final joinRes = await QuizizzService.joinSession(sessionId, name);
            playerId = joinRes['player_id']?.toString() ?? playerId;
          } catch (_) {}

          final rawQuestions = (sessionRes['questions'] as List?) ?? [];
          final normalizedQuestions = rawQuestions
              .map((q) => _StudentWaitingRoomScreenState._normalizeServerQuestion(q as Map))
              .toList();

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _StudentQuizActiveScreen(
                session: {
                  'title': session['title'] ?? 'Kuis Gamifikasi Live',
                  'session_code': pin,
                  'shuffle_questions': session['shuffle_questions'],
                  'shuffle_answers': session['shuffle_answers'],
                  if (normalizedQuestions.isNotEmpty) 'questions': normalizedQuestions,
                },
                sessionId: sessionId,
                playerId: playerId,
                studentName: name,
                quizId: quizId,
                quizStartedAt: session['started_at']?.toString(),
              ),
            ),
          );
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _StudentWaitingRoomScreen(pin: pin, studentName: name, quizId: quizId),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _StudentWaitingRoomScreen(pin: pin, studentName: name, quizId: ''),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: _kQuizizzPastelBg, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.5)),
                  child: const Icon(Icons.rocket_launch_rounded, size: 40, color: _kQuizizzTextColor),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Masuk Kuis Gamifikasi / Lesson', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _kNavyDark), textAlign: TextAlign.center),
              const SizedBox(height: 4),
              const Text('Masukkan Kode 6-Digit dari Dosen untuk Join Live Host', style: TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold, letterSpacing: 2),
                decoration: InputDecoration(
                  labelText: 'Kode PIN Sesi',
                  prefixIcon: const Icon(Icons.pin_rounded, color: _kNavyDark),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kMustardYellow, width: 2)),
                  filled: true,
                  fillColor: _kCreamBg,
                ),
                // FITUR "Enter Langsung Submit" (poin 1): pindah fokus ke
                // field Nama kalau field PIN yang aktif saat Enter ditekan.
                onSubmitted: (_) => FocusScope.of(context).requestFocus(_nameFieldFocusNode),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _nameController,
                focusNode: _nameFieldFocusNode,
                textInputAction: TextInputAction.done,
                style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: 'Nama Anda',
                  prefixIcon: const Icon(Icons.person_rounded, color: _kNavyDark),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kMustardYellow, width: 2)),
                  filled: true,
                  fillColor: _kCreamBg,
                ),
                // FITUR "Enter Langsung Submit" (poin 1): tekan Enter di
                // field terakhir (Nama) langsung join, tidak perlu klik
                // tombol "Join Live Waiting Room" pakai mouse.
                onSubmitted: (_) {
                  if (!_loading) _joinSession();
                },
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _joinSession,
                  style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: _kNavyDark, width: 1.5))),
                  child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text('🎮 Join Live Waiting Room', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// MAHASISWA SUB TAB 2: PEKERJAAN RUMAH (PR) LANGSUNG TANPA PIN/QR
// ----------------------------------------------------------------------
class _MahasiswaHomeworkSubTab extends StatefulWidget {
  const _MahasiswaHomeworkSubTab();

  @override
  State<_MahasiswaHomeworkSubTab> createState() => _MahasiswaHomeworkSubTabState();
}

class _MahasiswaHomeworkSubTabState extends State<_MahasiswaHomeworkSubTab> {
  Timer? _timer;
  List<Map<String, dynamic>> _homeworkList = [];
  bool _loading = true;
  // Menyimpan status "sudah dikerjakan" per PR (key: quiz_id/hw id) supaya
  // mahasiswa tidak bisa mengerjakan PR yang sama dua kali, dan supaya ada
  // indikasi visual jelas mana yang sudah & belum dikerjakan.
  final Map<String, Map<String, dynamic>?> _submissionStatus = {};
  bool _checkingStatus = false;

  @override
  void initState() {
    super.initState();
    _fetchHomework();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _fetchHomework());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _currentStudentName(BuildContext context) {
    final user = context.read<AuthProvider>().user;
    // Catatan: field nama bisa berupa 'name' (saat baru login) atau
    // 'full_name' (saat auto-login lewat /auth/me) — cek keduanya.
    final name = (user?['name'] ?? user?['full_name'])?.toString().trim();
    return (name != null && name.isNotEmpty) ? name : 'Mahasiswa';
  }

  // ID akun mahasiswa yang login — dipakai sebagai kunci UTAMA untuk
  // membedakan status "sudah dikerjakan" antar mahasiswa (bukan cuma nama,
  // supaya tidak salah tandai akun lain sebagai "sudah dikerjakan" juga).
  String? _currentStudentId(BuildContext context) {
    final user = context.read<AuthProvider>().user;
    final id = user?['id'];
    return id?.toString();
  }

  Future<void> _fetchHomework() async {
    final list = await QuizizzService.getAssignedHomework();
    if (mounted) {
      setState(() {
        _homeworkList = list;
        _loading = false;
      });
      _refreshSubmissionStatus();
    }
  }

  // Cek ke backend PR mana saja yang sudah dikerjakan mahasiswa yang sedang
  // login, supaya tombol "Kerjakan PR" bisa diganti indikator "Sudah
  // Dikerjakan" secara otomatis.
  Future<void> _refreshSubmissionStatus() async {
    if (_checkingStatus || !mounted) return;
    _checkingStatus = true;
    final studentName = _currentStudentName(context);
    final studentId = _currentStudentId(context);
    for (final hw in _homeworkList) {
      final quizId = hw['quiz_id']?.toString() ?? '';
      final hwId = hw['id']?.toString() ?? '';
      final key = quizId.isNotEmpty ? quizId : hwId;
      if (key.isEmpty || _submissionStatus.containsKey(key)) continue;
      final sub = await QuizizzService.getMyHomeworkSubmission(
        quizId: quizId,
        homeworkId: hwId,
        studentName: studentName,
        studentId: studentId,
      );
      if (mounted) {
        setState(() => _submissionStatus[key] = sub);
      }
    }
    _checkingStatus = false;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: QuizizzService.homeworkChangeNotifier,
      builder: (context, _, __) {
        if (_loading) {
          return const Center(child: CircularProgressIndicator(color: _kNavyDark));
        }

        if (_homeworkList.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.assignment_outlined, size: 64, color: _kNavyDark),
                const SizedBox(height: 12),
                const Text('Belum ada Pekerjaan Rumah (PR) yang ditugaskan Dosen.', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 15)),
              ],
            ),
          );
        }

        final studentName = _currentStudentName(context);

        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: _homeworkList.length,
          itemBuilder: (ctx, i) {
            final hw = _homeworkList[i];
            final title = hw['title'] ?? 'PR Mandiri';
            final desc = hw['description'] ?? 'Tugas PR dari Dosen';
            final questions = (hw['questions'] as List?) ?? [];
            final deadlineStr = hw['deadline'] ?? '';
            DateTime? deadline;
            try {
              // PENTING: konversi ke waktu LOKAL mahasiswa supaya tenggat
              // yang ditampilkan sama persis dengan yang diset dosen.
              deadline = DateTime.parse(deadlineStr).toLocal();
            } catch (_) {}

            final quizId = hw['quiz_id']?.toString() ?? '';
            final hwId = hw['id']?.toString() ?? '';
            final statusKey = quizId.isNotEmpty ? quizId : hwId;
            final submission = _submissionStatus[statusKey];
            final alreadyDone = submission != null;
            final isExpired = deadline != null && !alreadyDone && DateTime.now().isAfter(deadline);

                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: alreadyDone ? const Color(0xFF16A34A) : (isExpired ? Colors.redAccent : _kNavyDark), width: 2), boxShadow: [BoxShadow(color: alreadyDone ? const Color(0xFF16A34A) : (isExpired ? Colors.redAccent : _kNavyDark), offset: const Offset(4, 4), blurRadius: 0)]),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: alreadyDone ? const Color(0xFFDCFCE7) : (isExpired ? const Color(0xFFFEE2E2) : const Color(0xFFBAE6FD)), shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.2)),
                            child: Icon(alreadyDone ? Icons.check_circle_rounded : (isExpired ? Icons.timer_off_rounded : Icons.assignment_rounded), color: alreadyDone ? const Color(0xFF16A34A) : (isExpired ? Colors.redAccent : const Color(0xFF0284C7)), size: 24),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kNavyDark)),
                                Text('$desc (${questions.length} Soal Mandiri)', style: const TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                          if (alreadyDone) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF16A34A), width: 1.2)),
                              child: const Text('✅ Completed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF166534))),
                            ),
                            // FITUR "Riwayat Jawaban Lebih Kecil, di Samping
                            // Indikator Completed" (poin 2): dipindah dari
                            // tombol besar full-width di bawah, jadi ikon
                            // kecil bulat langsung di sebelah badge ini.
                            if (((submission['answers'] as List?) ?? []).isNotEmpty) ...[
                              const SizedBox(width: 6),
                              InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () => _showAnswerHistoryDialog(
                                  context,
                                  headerTitle: title,
                                  score: submission['score'] is int ? submission['score'] : int.tryParse(submission['score']?.toString() ?? ''),
                                  total: submission['total_questions'] is int ? submission['total_questions'] : int.tryParse(submission['total_questions']?.toString() ?? ''),
                                  answers: (submission['answers'] as List?) ?? [],
                                ),
                                child: Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.2)),
                                  child: const Icon(Icons.fact_check_rounded, size: 15, color: _kNavyDark),
                                ),
                              ),
                            ],
                          ]
                          else if (isExpired)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.redAccent, width: 1.2)),
                              child: const Text('⏰ Deadline Passed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.redAccent)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (deadline != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: isExpired ? const Color(0xFFFEE2E2) : const Color(0xFFFFEDD5), borderRadius: BorderRadius.circular(10), border: Border.all(color: _kNavyDark, width: 1)),
                          child: Text('Tenggat Waktu: ${deadline.day}/${deadline.month}/${deadline.year} Jam ${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')} WIB', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: isExpired ? Colors.redAccent : const Color(0xFFEA580C))),
                        ),
                      const SizedBox(height: 14),
                      const Divider(color: _kNavyDark, height: 1),
                      const SizedBox(height: 12),
                      if (alreadyDone)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                          child: Text(
                            'Nilai Anda: ${submission['score'] ?? 0} / ${submission['total_questions'] ?? questions.length} Benar',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else if (isExpired)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.redAccent, width: 1.2)),
                          child: const Center(
                            child: Text(
                              '⏰ Tenggat waktu sudah lewat. PR ini tidak bisa dikerjakan lagi.',
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent, fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      else
                        ElevatedButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _StudentQuizActiveScreen(
                                  session: {'title': title, 'questions': questions, 'hw_id': hw['id']},
                                  playerId: 'p_hw',
                                  studentName: studentName,
                                  studentId: _currentStudentId(context),
                                  quizId: quizId.isNotEmpty ? quizId : 'default_1',
                                  isHomework: true,
                                ),
                              ),
                            );
                            // Refresh status setelah kembali dari mengerjakan PR,
                            // supaya langsung berubah jadi "Sudah Dikerjakan".
                            if (statusKey.isNotEmpty) _submissionStatus.remove(statusKey);
                            _refreshSubmissionStatus();
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                          icon: const Icon(Icons.play_circle_fill_rounded, size: 16),
                          label: const Text('Kerjakan PR Sekarang (Tanpa PIN/QR)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
  }
}

// ----------------------------------------------------------------------
// MAHASISWA SUB TAB 3: FLASHCARDS BELAJAR MANDIRI
// ----------------------------------------------------------------------
class _MahasiswaFlashcardsSubTab extends StatefulWidget {
  const _MahasiswaFlashcardsSubTab();

  @override
  State<_MahasiswaFlashcardsSubTab> createState() => _MahasiswaFlashcardsSubTabState();
}

class _MahasiswaFlashcardsSubTabState extends State<_MahasiswaFlashcardsSubTab> {
  List<Map<String, dynamic>> _sets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSets();
  }

  Future<void> _loadSets() async {
    final res = await QuizizzService.getFlashcardSets();
    if (mounted) {
      setState(() {
        _sets = res;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    if (_sets.isEmpty) return const Center(child: Text('Belum ada set flashcard tersedia.', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)));

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _sets.length,
      itemBuilder: (ctx, i) {
        final fc = _sets[i];
        final cards = (fc['cards'] as List?) ?? [];

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: _kQuizizzPastelBg, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.2)),
                    child: const Icon(Icons.style_rounded, color: _kQuizizzTextColor, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(fc['title'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kNavyDark)),
                        Text('Mata Kuliah: ${fc['subject']} | ${cards.length} Kartu', style: const TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(color: _kNavyDark, height: 1),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => _FlashcardStudyScreen(set: fc)));
                },
                style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                icon: const Icon(Icons.style_rounded, size: 16),
                label: const Text('🎴 Open Flip-Card Study Mode', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ======================================================================
// STUDENT WAITING ROOM SCREEN (BEFORE HOST STARTS THE GAME)
// ======================================================================
class _StudentWaitingRoomScreen extends StatefulWidget {
  final String pin;
  final String studentName;
  final String quizId;

  const _StudentWaitingRoomScreen({required this.pin, required this.studentName, required this.quizId});

  @override
  State<_StudentWaitingRoomScreen> createState() => _StudentWaitingRoomScreenState();
}

class _StudentWaitingRoomScreenState extends State<_StudentWaitingRoomScreen> {
  Timer? _timer;
  StreamSubscription? _storageSub;
  bool _navigating = false;
  String? _sessionId;
  String? _playerId;
  String _sessionDescription = '';
  String _sessionTitle = '';

  @override
  void initState() {
    super.initState();
    _joinBackendSessionEarly();
    _checkStatus();
    // Polling ke BACKEND setiap ~1.2 detik. Cukup responsif untuk terasa
    // "langsung" berpindah begitu dosen menekan tombol mulai, tapi tidak
    // membanjiri server seperti polling 150ms sebelumnya.
    _timer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _checkStatus());
    QuizizzService.liveStatusNotifier.addListener(_checkStatus);

    if (kIsWeb) {
      try {
        _storageSub = html.window.onStorage.listen((event) {
          if (event.key != null && event.key!.contains(widget.pin)) {
            _checkStatus();
          }
        });
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _storageSub?.cancel();
    QuizizzService.liveStatusNotifier.removeListener(_checkStatus);
    super.dispose();
  }

  // Daftarkan mahasiswa sebagai pemain di sesi BACKEND sedini mungkin (saat
  // masih di waiting room), supaya skor & jawabannya nanti benar-benar
  // tercatat di database dan muncul di leaderboard / CSV dosen. Sekalian
  // ambil judul & deskripsi kuis yang diisi dosen untuk ditampilkan di
  // bawah kode PIN.
  Future<void> _joinBackendSessionEarly() async {
    try {
      final sessionRes = await QuizizzService.getSessionByPin(widget.pin);
      final session = sessionRes['session'] as Map<String, dynamic>?;
      if (session == null) return;
      _sessionId = session['id']?.toString();
      if (mounted) {
        setState(() {
          _sessionTitle = session['title']?.toString() ?? '';
          _sessionDescription = session['description']?.toString() ?? '';
        });
      }
      if (_sessionId == null || _sessionId!.isEmpty) return;

      final joinRes = await QuizizzService.joinSession(_sessionId!, widget.studentName);
      _playerId = joinRes['player_id']?.toString();
    } catch (_) {
      // Offline / backend belum siap: tetap lanjut, nanti dicoba lagi saat status aktif.
    }
  }

  Future<void> _checkStatus() async {
    final status = await QuizizzService.getLiveSessionStatus(widget.pin);
    bool webActive = false;
    if (kIsWeb) {
      try {
        final st = html.window.localStorage['live_session_status_${widget.pin.trim()}'];
        final st2 = html.window.localStorage['live_session_status_global'];
        if (st == 'active' || st == 'live' || st2 == 'active') {
          webActive = true;
        }
      } catch (_) {}
    }

    if (!_navigating && mounted && (status == 'active' || status == 'live' || webActive)) {
      _navigating = true;
      _timer?.cancel();
      _storageSub?.cancel();
      QuizizzService.liveStatusNotifier.removeListener(_checkStatus);

      // Ambil sesi + soal terbaru langsung dari backend (sumber kebenaran
      // yang sama untuk semua mahasiswa), dengan fallback ke info lokal.
      Map<String, dynamic> sessionData = {};
      List<dynamic> serverQuestions = [];
      try {
        final sessionRes = await QuizizzService.getSessionByPin(widget.pin);
        sessionData = (sessionRes['session'] as Map<String, dynamic>?) ?? {};
        serverQuestions = (sessionRes['questions'] as List?) ?? (sessionData['questions'] as List? ?? []);
        _sessionId ??= sessionData['id']?.toString();
      } catch (_) {}

      // Pastikan sudah terdaftar sebagai player di backend (kalau belum
      // sempat join sebelumnya, misalnya waktu join awal offline).
      if ((_playerId == null || _playerId!.isEmpty) && _sessionId != null && _sessionId!.isNotEmpty) {
        try {
          final joinRes = await QuizizzService.joinSession(_sessionId!, widget.studentName);
          _playerId = joinRes['player_id']?.toString();
        } catch (_) {}
      }

      final sessionInfo = await QuizizzService.getLiveSessionInfo(widget.pin);
      final realQuizId = (sessionData['quiz_id']?.toString().isNotEmpty == true)
          ? sessionData['quiz_id'].toString()
          : (sessionInfo['quiz_id']?.toString().isNotEmpty == true ? sessionInfo['quiz_id'].toString() : widget.quizId);

      final normalizedQuestions = serverQuestions.map((q) => _normalizeServerQuestion(q as Map)).toList();

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => _StudentQuizActiveScreen(
            session: {
              'title': sessionData['title'] ?? sessionInfo['title'] ?? 'Kuis Gamifikasi Live',
              'session_code': widget.pin,
              'shuffle_questions': sessionData['shuffle_questions'] ?? sessionInfo['shuffle_questions'],
              'shuffle_answers': sessionData['shuffle_answers'] ?? sessionInfo['shuffle_answers'],
              if (normalizedQuestions.isNotEmpty) 'questions': normalizedQuestions,
            },
            sessionId: _sessionId ?? widget.pin,
            playerId: _playerId ?? 'p_${DateTime.now().millisecondsSinceEpoch}',
            studentName: widget.studentName,
            quizId: realQuizId,
            quizStartedAt: sessionData['started_at']?.toString(),
          ),
        ),
      );
    }
  }

  // Menyamakan format soal dari backend (field: question/type/options/correct/
  // timer_seconds) ke bentuk yang dipakai layar kuis mahasiswa, termasuk
  // menyiapkan 'correct_list' untuk tipe soal multi_select.
  static Map<String, dynamic> _normalizeServerQuestion(Map q) {
    final map = Map<String, dynamic>.from(q);
    final correct = map['correct'];
    final options = (map['options'] as List?) ?? [];
    if (correct is List) {
      map['correct_list'] = correct.map((e) => e.toString()).toList();
    } else if (map['type'] == 'multi_select' && correct is String && correct.trim().startsWith('[')) {
      try {
        final parsed = jsonDecode(correct);
        if (parsed is List) map['correct_list'] = parsed.map((e) => e.toString()).toList();
      } catch (_) {}
    } else if (correct is String && RegExp(r'^[A-D]$').hasMatch(correct.trim().toUpperCase()) && options.isNotEmpty) {
      // Jika correct disimpan sebagai huruf 'A'/'B'/'C'/'D', konversikan ke teks opsi aktualnya
      final idx = 'ABCD'.indexOf(correct.trim().toUpperCase());
      if (idx >= 0 && idx < options.length) {
        map['correct'] = options[idx].toString();
      }
    }
    map['question'] = map['question'] ?? map['question_text'];
    map['type'] = map['type'] ?? map['question_type'] ?? 'multiple_choice';
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(title: const Text('🎮 Ruang Tunggu (Waiting Room)'), backgroundColor: _kCreamBg, foregroundColor: _kNavyDark, elevation: 0),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 440,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: _kQuizizzPastelBg, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.5)),
                  child: const Icon(Icons.hourglass_top_rounded, size: 50, color: _kQuizizzTextColor),
                ),
                const SizedBox(height: 20),
                Text('Halo, ${widget.studentName}! 👋', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _kNavyDark)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                  child: Text('KODE PIN GAME: ${widget.pin}', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13)),
                ),
                if (_sessionDescription.trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: _kCreamBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_sessionTitle.isEmpty ? '📋 Deskripsi Kuis' : '📋 Deskripsi: $_sessionTitle', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                        const SizedBox(height: 6),
                        Text(_sessionDescription, style: const TextStyle(fontSize: 12, color: Colors.black87), textAlign: TextAlign.left),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                const CircularProgressIndicator(color: _kNavyDark),
                const SizedBox(height: 16),
                const Text('⏳ tunggu dosen memulai quiz', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFFEA580C)), textAlign: TextAlign.center),
                const SizedBox(height: 6),
                const Text('Layar Anda akan otomatis beralih mengerjakan soal begitu Dosen menekan tombol Start!', style: TextStyle(fontSize: 12, color: Colors.black54), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// INTERACTIVE STUDENT LESSON MODE SCREEN (AUTO-SYNC SLIDE VIEW)
// ======================================================================
// ----------------------------------------------------------------------
// MAHASISWA SUB TAB 4: JOIN PRESENTASI (KODE/TOKEN -> WAITING ROOM)
// ----------------------------------------------------------------------
class _MahasiswaLessonJoinSubTab extends StatefulWidget {
  const _MahasiswaLessonJoinSubTab();

  @override
  State<_MahasiswaLessonJoinSubTab> createState() => _MahasiswaLessonJoinSubTabState();
}

class _MahasiswaLessonJoinSubTabState extends State<_MahasiswaLessonJoinSubTab> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  bool _loading = false;

  Future<void> _joinLesson() async {
    final code = _codeController.text.trim();
    final name = _nameController.text.trim();
    if (code.isEmpty || name.isEmpty) return;

    setState(() => _loading = true);
    final session = await QuizizzService.getLessonSessionByCode(code);
    if (mounted) setState(() => _loading = false);

    if (session == null || session.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kode presentasi tidak ditemukan. Periksa kembali kode dari dosen.'), backgroundColor: Colors.redAccent),
        );
      }
      return;
    }

    if (!mounted) return;
    final status = session['status']?.toString() ?? 'waiting';
    if (status == 'active') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _StudentLessonActiveScreen(sessionCode: code, studentName: name, lesson: session),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _StudentLessonWaitingRoomScreen(code: code, studentName: name, lesson: session),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.slideshow_rounded, size: 48, color: _kNavyDark),
              const SizedBox(height: 12),
              const Text('Masuk ke Presentasi Live', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark)),
              const SizedBox(height: 4),
              const Text('Masukkan kode/token presentasi dari dosen', style: TextStyle(fontSize: 12, color: Colors.black54), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextField(
                controller: _codeController,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 22, color: _kNavyDark, letterSpacing: 4),
                decoration: InputDecoration(
                  hintText: 'KODE PRESENTASI',
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                  filled: true,
                  fillColor: _kCreamBg,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: 'Nama Anda',
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                  filled: true,
                  fillColor: _kCreamBg,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _joinLesson,
                  style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                  child: _loading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: _kNavyDark))
                      : const Text('Masuk Presentasi', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// WAITING ROOM PRESENTASI MAHASISWA (menunggu dosen menekan "Mulai
// Presentasi Sekarang")
// ----------------------------------------------------------------------
class _StudentLessonWaitingRoomScreen extends StatefulWidget {
  final String code;
  final String studentName;
  final Map<String, dynamic> lesson;

  const _StudentLessonWaitingRoomScreen({required this.code, required this.studentName, required this.lesson});

  @override
  State<_StudentLessonWaitingRoomScreen> createState() => _StudentLessonWaitingRoomScreenState();
}

class _StudentLessonWaitingRoomScreenState extends State<_StudentLessonWaitingRoomScreen> {
  Timer? _timer;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _checkStatus());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    if (_navigating) return;
    final st = await QuizizzService.getLessonSessionState(widget.code);
    final status = st['status']?.toString() ?? 'waiting';
    if (status == 'active' && mounted) {
      _navigating = true;
      _timer?.cancel();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => _StudentLessonActiveScreen(sessionCode: widget.code, studentName: widget.studentName, lesson: widget.lesson),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        title: Text(widget.lesson['title'] ?? 'Presentasi', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 460,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Halo, ${widget.studentName}! 👋', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                  child: Text('KODE PRESENTASI: ${widget.code}', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13)),
                ),
                if (widget.lesson['description'] != null && widget.lesson['description'].toString().trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(widget.lesson['description'].toString(), style: const TextStyle(fontSize: 12, color: Colors.black87), textAlign: TextAlign.center),
                ],
                const SizedBox(height: 20),
                const CircularProgressIndicator(color: _kNavyDark),
                const SizedBox(height: 16),
                const Text('⏳ Tunggu dosen memulai presentasi', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFFEA580C)), textAlign: TextAlign.center),
                const SizedBox(height: 6),
                const Text('Layar Anda akan otomatis berpindah ke slide presentasi begitu dosen menekan "Mulai Presentasi Sekarang".', style: TextStyle(fontSize: 12, color: Colors.black54), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StudentLessonActiveScreen extends StatefulWidget {
  final String sessionCode;
  final String studentName;
  final Map<String, dynamic> lesson;

  const _StudentLessonActiveScreen({required this.sessionCode, required this.studentName, required this.lesson});

  @override
  State<_StudentLessonActiveScreen> createState() => _StudentLessonActiveScreenState();
}

class _StudentLessonActiveScreenState extends State<_StudentLessonActiveScreen> {
  String _displayMode = 'semi';
  int _activeSlideIndex = 0;
  List<dynamic> _slides = [];
  Timer? _timer;
  final _answerCtrl = TextEditingController();
  final _askCtrl = TextEditingController();
  bool _submitted = false;
  bool _kickedOut = false;

  bool _showQaPanel = true;
  String? _notificationMsg;
  Timer? _notifTimer;

  void _showNotif(String msg) {
    setState(() => _notificationMsg = msg);
    _notifTimer?.cancel();
    _notifTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notificationMsg = null);
    });
  }

  // Fitur "Kelola Soal Presentasi" (poin 2) + "Aktifkan hingga 2 soal
  // sekaligus" + "Timer soal": soal-soal (maks 2) yang sedang diaktifkan
  // dosen, muncul otomatis di layar mahasiswa terlepas dari slide yang
  // sedang tampil, dan mahasiswa bisa langsung menjawabnya sekali per soal,
  // dengan hitung mundur waktu kalau soal itu punya batas waktu.
  List<Map<String, dynamic>> _lessonQuestions = [];
  List<String> _activeQuestionIds = [];
  Map<String, dynamic> _questionActivatedAt = {};
  final Set<String> _answeredQuestionIds = {};
  final Map<String, bool> _questionCorrectById = {};
  // State tambahan untuk tipe soal Multi-Select (checkbox) & Jawaban
  // Singkat (text field) pada soal interaktif presentasi, per question id.
  final Map<String, Set<String>> _selectedMultiAnswersById = {};
  // FITUR "Mahasiswa Bisa Ubah Jawaban Sebelum Dikirim" (poin 3): dulu
  // menyentuh satu opsi Pilihan Ganda/Benar-Salah LANGSUNG mengirim
  // jawaban itu sebagai final (tidak bisa diubah lagi). Sekarang menyentuh
  // opsi hanya MENANDAI pilihan sementara (disimpan di sini) -- jawaban
  // baru benar-benar terkirim & terkunci setelah mahasiswa menekan tombol
  // "Kirim Jawaban", sama seperti tipe soal Multi-Select & Jawaban Singkat.
  final Map<String, String> _selectedSingleAnswerById = {};
  final Map<String, TextEditingController> _shortAnswerCtrlById = {};

  // Fitur "Hasil nilai quiz presentasi muncul saat sesi berakhir"
  bool _finalResultsShown = false;

  // Fitur "Tanya-Jawab Live" (poin 3)
  List<Map<String, dynamic>> _qaMessages = [];
  bool _sendingQuestion = false;

  double? _pointerX;
  double? _pointerY;
  Timer? _pointerClearTimer;

  void _onPointerUpdate(dynamic data) {
    if (mounted && data is Map) {
      final px = (data['x'] as num).toDouble();
      final py = (data['y'] as num).toDouble();
      if (px < 0 || py < 0) {
        setState(() { _pointerX = null; _pointerY = null; });
        _pointerClearTimer?.cancel();
        return;
      }
      setState(() {
        _pointerX = px;
        _pointerY = py;
      });
      // Clear pointer after 2 seconds of inactivity
      _pointerClearTimer?.cancel();
      _pointerClearTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() { _pointerX = null; _pointerY = null; });
      });
    }
  }

  @override
  void initState() {
    super.initState();
    SocketService.instance.on('connect', (_) {
      SocketService.instance.emit('join', widget.sessionCode);
    });
    if (SocketService.instance.connected == true) {
      SocketService.instance.emit('join', widget.sessionCode);
    }
    SocketService.instance.on('pointer_update', _onPointerUpdate);
    _slides = widget.lesson['slides'] ?? [];
    _loadQuestionBank();
    _poll();
    // Timer 1 detik supaya hitung mundur soal terlihat mengalir mulus,
    // sementara polling data ke server tetap tiap ~2 detik (di dalam _poll).
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (t.tick % 2 == 0) _poll();
      _autoSubmitExpiredQuestions();
      if (mounted) setState(() {}); // refresh tampilan countdown timer
    });
  }



  // FITUR "Auto-Submit Saat Waktu Habis" (poin 2): untuk soal Jawaban
  // Singkat & Multi-Select di Presentasi -- yang perlu tombol "Kirim
  // Jawaban" eksplisit -- kalau mahasiswa TIDAK menekan tombol itu sampai
  // waktunya habis, jawaban yang sedang diisi (atau kosong kalau belum
  // diisi sama sekali) otomatis terkirim sendiri, sama seperti soal
  // Pilihan Ganda yang langsung terkirim begitu opsi disentuh.
  void _autoSubmitExpiredQuestions() {
    for (final q in _lessonQuestions) {
      final qId = q['id']?.toString();
      if (qId == null || !_activeQuestionIds.contains(qId)) continue;
      if (_answeredQuestionIds.contains(qId)) continue;
      final remaining = _remainingSeconds(q);
      if (remaining == null || remaining > 0) continue;

      final qType = (q['question_type'] ?? 'multiple_choice').toString();
      if (qType == 'short_answer') {
        final text = _shortAnswerCtrlById[qId]?.text.trim() ?? '';
        _answerActiveQuestion(qId, text);
      } else if (qType == 'multi_select') {
        final selected = _selectedMultiAnswersById[qId] ?? {};
        _answerActiveQuestion(qId, selected.join(','));
      } else {
        // multiple_choice & true_false: sejak fitur "Mahasiswa Bisa Ubah
        // Jawaban Sebelum Dikirim" (poin 3), tipe ini JUGA butuh tombol
        // "Kirim Jawaban" eksplisit (tidak lagi langsung terkirim begitu
        // opsi disentuh) -- jadi ikut perlu auto-submit saat waktu habis,
        // memakai opsi terakhir yang sempat dipilih (atau kosong/belum
        // memilih sama sekali kalau memang belum sempat menyentuh opsi apa
        // pun sampai waktunya habis).
        final selected = _selectedSingleAnswerById[qId] ?? '';
        _answerActiveQuestion(qId, selected);
      }
    }
  }

  @override
  void dispose() {
    SocketService.instance.off('pointer_update', _onPointerUpdate);
    _pointerClearTimer?.cancel();
    _timer?.cancel();
    for (final c in _shortAnswerCtrlById.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadQuestionBank() async {
    // PENTING: pakai 'lesson_id' (id lesson yang benar), BUKAN 'id' (yang
    // ternyata adalah id sesi live) -- ini akar bug "soal aktif tidak
    // muncul di mahasiswa" sebelumnya.
    final lessonId = (widget.lesson['lesson_id'] ?? widget.lesson['id'])?.toString() ?? '';
    if (lessonId.isEmpty) return;
    final list = await QuizizzService.getLessonQuestions(lessonId);
    final lessonSettings = await QuizizzService.getLessonSettings(lessonId);
    final bool shouldShuffleAnswers = lessonSettings['shuffle_answers'] == true;
    
    // PROCESS Variable Calculations & Option Shuffling for Lesson Questions
    for (int idx = 0; idx < list.length; idx++) {
      var processed = processVariableCalculations(list[idx], studentIdentifier: widget.studentName, questionIndex: idx);
      if (shouldShuffleAnswers) {
        final qType = (processed['type'] ?? processed['question_type'] ?? 'multiple_choice').toString();
        if (qType == 'multiple_choice' || qType == 'multi_select') {
          final rawOptions = (processed['options'] as List?)?.map((e) => e.toString()).toList() ?? [];
          final rawOptionImages = (processed['option_images'] as List?)?.map((e) => e?.toString()).toList() ?? [];
          if (rawOptions.length > 1) {
            final paired = List.generate(rawOptions.length, (i) => {
              'text': rawOptions[i],
              'image': i < rawOptionImages.length ? rawOptionImages[i] : null,
            });
            final ansSeed = (widget.studentName.hashCode ^ (processed['question'] ?? processed['question_text'] ?? '').hashCode ^ idx).abs();
            final ansRng = Random(ansSeed);
            for (int i = paired.length - 1; i > 0; i--) {
              int n = ansRng.nextInt(i + 1);
              var temp = paired[i];
              paired[i] = paired[n];
              paired[n] = temp;
            }
            processed['options'] = paired.map((e) => e['text']).toList();
            processed['option_images'] = paired.map((e) => e['image']).toList();
          }
        }
      }
      list[idx] = processed;
    }

    if (mounted) setState(() => _lessonQuestions = list);
  }

  Future<void> _poll() async {
    if (_kickedOut) return;
    final full = await QuizizzService.getLessonSessionByCode(widget.sessionCode);
    if (full == null || !mounted) return;

    // FITUR "Sinkronisasi Soal Dosen <-> Mahasiswa" (poin 1): sebelumnya
    // bank soal presentasi mahasiswa (_lessonQuestions) hanya diambil SEKALI
    // saat pertama kali join. Kalau dosen menambah soal baru atau MENGEDIT
    // soal yang sudah ada di tengah presentasi berlangsung, mahasiswa yang
    // sudah lebih dulu join tidak pernah melihat perubahan itu -- soal baru
    // yang diaktifkan dosen bahkan bisa tidak muncul sama sekali di layar
    // mahasiswa. Sekarang bank soal ikut disegarkan di setiap siklus polling
    // (~tiap 2 detik, sama seperti data sesi lainnya) supaya selalu sinkron.
    _loadQuestionBank();

    // FITUR "TOMBOL AKHIRI PRESENTASI" + "Hasil nilai muncul saat sesi
    // berakhir": kalau dosen sudah mengakhiri sesi, mahasiswa otomatis
    // dikeluarkan, tapi TERLEBIH DAHULU ditampilkan hasil akhir kuis
    // presentasinya (kalau ada soal yang pernah dikerjakan).
    if (full['status']?.toString() == 'ended') {
      _timer?.cancel();
      _kickedOut = true;
      if (mounted && !_finalResultsShown) {
        _finalResultsShown = true;
        final results = await QuizizzService.getLessonFinalResults(widget.sessionCode);
        if (!mounted) return;
        if ((results['leaderboard'] as List).isNotEmpty) {
          await showLessonFinalResultsDialog(context, results, isDosen: false, myName: widget.studentName);
        }
        if (mounted) {
          Navigator.of(context).maybePop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('🛑 Presentasi telah diakhiri oleh dosen.'), backgroundColor: Colors.redAccent),
          );
        }
      }
      return;
    }

    final idx = (full['active_slide_index'] as num?)?.toInt() ?? 0;
    final newActiveIds = List<String>.from(full['active_question_ids'] ?? []);
    final newActivatedAt = Map<String, dynamic>.from(full['question_activated_at'] ?? {});

    setState(() {
      if (idx != _activeSlideIndex) {
        _activeSlideIndex = idx;
        _submitted = false;
        _answerCtrl.clear();
      }
      // Soal baru yang aktif (belum pernah dilihat) -> siapkan state
      // jawabannya, dan soal yang sudah dinonaktifkan dosen -> bersihkan
      // state lokalnya supaya tidak menumpuk.
      for (final qId in newActiveIds) {
        _shortAnswerCtrlById.putIfAbsent(qId, () => TextEditingController());
        _selectedMultiAnswersById.putIfAbsent(qId, () => {});
      }
      _activeQuestionIds = newActiveIds;
      _questionActivatedAt = newActivatedAt;
    });

    if (mounted) {
    final qa = await QuizizzService.getLessonQaMessages(widget.sessionCode);

      bool newReply = false;
      String notifSender = '';
      String notifText = '';
      for (final newQ in qa) {
        final oldQ = _qaMessages.firstWhere((q) => q['id'] == newQ['id'], orElse: () => <String, dynamic>{});
        if (newQ['reply'] != null && newQ['reply'].toString().isNotEmpty && (oldQ.isEmpty || oldQ['reply'] != newQ['reply'])) {
          newReply = true;
          notifSender = 'Dosen';
          notifText = newQ['reply'].toString();
          break;
        }
      }
      if (_qaMessages.isNotEmpty && (newReply || qa.length > _qaMessages.length)) {
        if (!newReply && qa.length > _qaMessages.length) {
          notifSender = qa[0]['student_name'] ?? 'Mahasiswa';
          notifText = qa[0]['message']?.toString() ?? '';
        }
        final preview = notifText.length > 40 ? notifText.substring(0, 40) + '...' : notifText;
        _showNotif('💬 $notifSender: $preview');
      }
      setState(() => _qaMessages = qa);
    }

  }

  Future<void> _submitAnswer(dynamic val) async {
    if (_submitted) return;
    await QuizizzService.submitLessonResponse(
      widget.sessionCode,
      slideIndex: _activeSlideIndex,
      studentName: widget.studentName,
      answer: val.toString(),
    );
    setState(() => _submitted = true);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Jawaban berhasil terkirim!'), backgroundColor: _kNavyDark));
  }

  // Fitur "Kelola Soal Presentasi" (poin 2): mahasiswa menjawab salah satu
  // soal aktif secara langsung (mirip kuis gamifikasi, tapi digabung
  // dengan presentasi). Sekarang menerima questionId eksplisit karena bisa
  // ada hingga 2 soal aktif bersamaan.
  Future<void> _answerActiveQuestion(String questionId, dynamic val) async {
    if (_answeredQuestionIds.contains(questionId)) return;
    final activeQ = _lessonQuestions.firstWhere((q) => q['id']?.toString() == questionId, orElse: () => <String, dynamic>{});
    bool? localIsCorrect;
    if (activeQ.isNotEmpty && activeQ['correct'] != null) {
      localIsCorrect = (val != null && val.toString().trim().toUpperCase() == activeQ['correct'].toString().trim().toUpperCase());
    }
    final isCorrect = await QuizizzService.answerLessonQuestion(
      widget.sessionCode,
      questionId: questionId,
      studentName: widget.studentName,
      answer: val,
      isCorrect: localIsCorrect,
    );
    if (!mounted) return;
    setState(() {
      _answeredQuestionIds.add(questionId);
      _questionCorrectById[questionId] = isCorrect;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isCorrect ? '✅ Jawaban benar!' : '📨 Jawaban terkirim!'), backgroundColor: isCorrect ? const Color(0xFF16A34A) : _kNavyDark),
    );
  }

  // Fitur "Timer Soal Presentasi": sisa detik menjawab soal ini (null =
  // tanpa batas waktu, atau soal tidak/belum aktif).
  int? _remainingSeconds(Map<String, dynamic> question) {
    final timeLimit = question['time_limit_seconds'];
    if (timeLimit == null) return null;
    final qId = question['id'].toString();
    final activatedAtStr = _questionActivatedAt[qId]?.toString();
    if (activatedAtStr == null) return null;
    final activatedAt = DateTime.tryParse(activatedAtStr);
    if (activatedAt == null) return null;
    final elapsed = DateTime.now().difference(activatedAt).inSeconds;
    final remaining = (timeLimit as num).toInt() - elapsed;
    return remaining < 0 ? 0 : remaining;
  }

  // Fitur "Tanya-Jawab Live" (poin 3): mahasiswa mengajukan pertanyaan
  // bebas selama presentasi berlangsung -- muncul juga di layar dosen.
  Future<void> _askQuestion() async {
    final msg = _askCtrl.text.trim();
    if (msg.isEmpty || _sendingQuestion) return;
    setState(() => _sendingQuestion = true);
    final ok = await QuizizzService.askLessonQuestion(widget.sessionCode, studentName: widget.studentName, message: msg);
    if (!mounted) return;
    setState(() => _sendingQuestion = false);
    if (ok) {
      _askCtrl.clear();
      await _poll();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❓ Pertanyaan terkirim ke dosen!'), backgroundColor: _kNavyDark));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSlide = _slides.isNotEmpty && _activeSlideIndex < _slides.length ? _slides[_activeSlideIndex] : {};
    final isQuiz = currentSlide['type'] == 'quiz_mc' || currentSlide['type'] == 'poll' || currentSlide['type'] == 'short_answer';
    // FITUR "Urutan Soal Saat 2 Diaktifkan Sekaligus" (poin 5): kalau dosen
    // mengaktifkan sampai 2 soal bersamaan, mahasiswa TIDAK melihat
    // keduanya sekaligus di layar. Soal yang PERTAMA KALI diaktifkan
    // (index 0 di _activeQuestionIds, karena backend selalu menambahkan
    // soal baru ke akhir daftar) yang tampil duluan; begitu soal itu
    // "selesai" (sudah dijawab mahasiswa ini, ATAU waktunya habis), baru
    // giliran soal berikutnya yang aktif ditampilkan. Kalau semua soal
    // aktif sudah selesai, soal terakhir tetap ditampilkan (supaya
    // mahasiswa masih bisa melihat status "sudah menjawab") sampai dosen
    // menonaktifkannya / mengganti slide.
    final orderedActiveQuestions = _activeQuestionIds
        .map((qId) => _lessonQuestions.firstWhere((q) => q['id'].toString() == qId, orElse: () => {}))
        .where((q) => q.isNotEmpty)
        .toList();
    Map<String, dynamic>? questionToShow;
    for (final q in orderedActiveQuestions) {
      final qId = q['id'].toString();
      final isAnswered = _answeredQuestionIds.contains(qId);
      final remaining = _remainingSeconds(q);
      final isTimeUp = remaining != null && remaining <= 0;
      if (!isAnswered && !isTimeUp) {
        questionToShow = q;
        break;
      }
    }
    questionToShow ??= orderedActiveQuestions.isNotEmpty ? orderedActiveQuestions.last : null;
    final activeQuestions = questionToShow != null ? [questionToShow] : <Map<String, dynamic>>[];

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        title: Text(widget.lesson['title'] ?? 'Lesson Mode', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _showQaPanel = !_showQaPanel),
              style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              icon: Icon(_showQaPanel ? Icons.forum_outlined : Icons.forum, size: 18),
              label: Text(_showQaPanel ? 'Sembunyikan Q&A' : 'Tampilkan Q&A', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ),

          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
              child: Text(widget.studentName, style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 12)),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Row(
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),

          child: ConstrainedBox(
            // Fitur "Maksimalkan tampilan presentasi ke ukuran layar
            // laptop": sebelumnya lebar tampilan dikunci 500px persis
            // (kecil di layar besar). Sekarang mengikuti lebar layar
            // sampai maksimum 1000px (tetap nyaman dibaca di layar sangat
            // lebar), bukan lagi terkunci sempit.
            constraints: BoxConstraints(maxWidth: _displayMode == 'full' ? MediaQuery.of(context).size.width : 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              // FITUR "KELOLA SOAL PRESENTASI" (poin 2) + "Aktifkan hingga 2
              // soal sekaligus": soal live yang sedang diaktifkan dosen
              // muncul di sini (bisa 2 sekaligus), terpisah dari slide, dan
              // bisa langsung dijawab.
              ...activeQuestions.map((activeQuestion) {
                final qId = activeQuestion['id'].toString();
                final answered = _answeredQuestionIds.contains(qId);
                final isCorrect = _questionCorrectById[qId] ?? false;
                final remaining = _remainingSeconds(activeQuestion);
                final timeUp = remaining != null && remaining <= 0;
                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7E0),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kNavyDark, width: 2),
                    boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.bolt_rounded, color: Color(0xFFEA580C)),
                          const SizedBox(width: 6),
                          const Expanded(child: Text('🎯 SOAL AKTIF DARI DOSEN!', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFFEA580C)))),
                          // Fitur "Timer Soal Presentasi"
                          if (remaining != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: timeUp ? Colors.redAccent : _kNavyDark, borderRadius: BorderRadius.circular(14)),
                              child: Text('⏱ ${timeUp ? "Habis" : "${remaining}s"}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // FITUR "Gambar di Pertanyaan" (poin 4).
                      if ((activeQuestion['image_url'] ?? '').toString().isNotEmpty) ...[
                        _buildQuestionImageWidget(activeQuestion['image_url'].toString()),
                        const SizedBox(height: 10),
                      ],
                      Text(activeQuestion['question_text'] ?? '', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _kNavyDark)),
                      const SizedBox(height: 14),
                      if (answered)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: const Color(0xFFA7F3D0), borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, color: Color(0xFF059669)),
                              const SizedBox(width: 8),
                              Text(isCorrect ? '✅ Jawaban Anda Benar!' : '📨 Jawaban Terkirim', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF059669))),
                            ],
                          ),
                        )
                      else if (timeUp)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.redAccent, width: 1)),
                          child: const Row(
                            children: [
                              Icon(Icons.timer_off_rounded, color: Colors.redAccent),
                              SizedBox(width: 8),
                              Text('⏱ Waktu habis, tidak bisa menjawab lagi.', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
                            ],
                          ),
                        )
                      else
                        Builder(builder: (_) {
                          final qType = activeQuestion['question_type'] ?? 'multiple_choice';
                          final options = (activeQuestion['options'] as List? ?? []);
                          // FITUR "Gambar di Jawaban" (poin 4): gambar
                          // opsional per-opsi jawaban, sejajar index dengan
                          // `options` di atas.
                          final optionImages = (activeQuestion['option_images'] as List? ?? []);
                          final shortAnswerCtrl = _shortAnswerCtrlById[qId] ?? TextEditingController();
                          final selectedMulti = _selectedMultiAnswersById[qId] ?? {};

                          if (qType == 'short_answer') {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  controller: shortAnswerCtrl,
                                  textInputAction: TextInputAction.done,
                                  decoration: InputDecoration(hintText: 'Ketik jawaban Anda...', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark))),
                                  // FITUR "Enter Langsung Submit" (poin 1):
                                  // tekan Enter di keyboard langsung mengirim
                                  // jawaban, tidak perlu klik tombol "Kirim
                                  // Jawaban" pakai mouse.
                                  onSubmitted: (val) => _answerActiveQuestion(qId, val.trim()),
                                ),
                                const SizedBox(height: 10),
                                ElevatedButton(
                                  onPressed: () => _answerActiveQuestion(qId, shortAnswerCtrl.text.trim()),
                                  style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                  child: const Text('Kirim Jawaban', style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ],
                            );
                          }

                          if (qType == 'multi_select') {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ...options.asMap().entries.map((entry) {
                                  final letter = String.fromCharCode(65 + entry.key);
                                  final selected = selectedMulti.contains(letter);
                                  final optImg = entry.key < optionImages.length ? optionImages[entry.key]?.toString() : null;
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.2)),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        CheckboxListTile(
                                          value: selected,
                                          onChanged: (v) => setState(() {
                                            final set = _selectedMultiAnswersById.putIfAbsent(qId, () => {});
                                            if (v == true) {
                                              set.add(letter);
                                            } else {
                                              set.remove(letter);
                                            }
                                          }),
                                          title: Text('$letter. ${entry.value}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                                          activeColor: const Color(0xFF16A34A),
                                          controlAffinity: ListTileControlAffinity.leading,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                        ),
                                        if (optImg != null && optImg.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                            child: SizedBox(height: 130, child: _buildQuestionImageWidget(optImg)),
                                          ),
                                      ],
                                    ),
                                  );
                                }),
                                const SizedBox(height: 6),
                                ElevatedButton(
                                  onPressed: selectedMulti.isEmpty ? null : () => _answerActiveQuestion(qId, selectedMulti.join(',')),
                                  style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                  child: const Text('Kirim Jawaban', style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ],
                            );
                          }

                          // multiple_choice & true_false: pilih opsi dulu (bisa
                          // diubah-ubah), baru terkirim final setelah menekan
                          // tombol "Kirim Jawaban" di bawah.
                          //
                          // FITUR "Perbaikan Bug Benar/Salah Disalahkan"
                          // (poin 1): dulu kode ini SELALU mengirim HURUF opsi
                          // (A/B) sebagai jawaban, cocok untuk Pilihan Ganda
                          // (yang jawaban benarnya memang disimpan sebagai
                          // huruf). Tapi untuk Benar/Salah, jawaban benar
                          // disimpan sebagai TEKS PENUH ("Benar"/"Salah"), jadi
                          // kalau yang dikirim tetap huruf "A"/"B", jawaban
                          // TIDAK PERNAH cocok walau mahasiswa pilih opsi yang
                          // benar. Sekarang untuk tipe Benar/Salah, teks opsi
                          // itu sendiri ("Benar"/"Salah") yang dipakai sebagai
                          // nilai jawaban, bukan hurufnya.
                          final selectedSingle = _selectedSingleAnswerById[qId];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ...options.asMap().entries.map((entry) {
                                final letter = String.fromCharCode(65 + entry.key);
                                final valueToUse = qType == 'true_false' ? entry.value.toString() : letter;
                                final optImg = entry.key < optionImages.length ? optionImages[entry.key]?.toString() : null;
                                final isSelected = selectedSingle == valueToUse;
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  width: double.infinity,
                                  child: OutlinedButton(
                                    onPressed: () => setState(() => _selectedSingleAnswerById[qId] = valueToUse),
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor: isSelected ? _kMustardYellow : Colors.white,
                                      padding: const EdgeInsets.all(14),
                                      side: BorderSide(color: _kNavyDark, width: isSelected ? 2 : 1.2),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(6),
                                              decoration: BoxDecoration(color: isSelected ? Colors.white : _kQuizizzPastelBg, shape: BoxShape.circle),
                                              child: isSelected
                                                  ? const Icon(Icons.check, size: 14, color: _kQuizizzTextColor)
                                                  : Text(letter, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kQuizizzTextColor)),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(child: Text(entry.value.toString(), style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark))),
                                          ],
                                        ),
                                        if (optImg != null && optImg.isNotEmpty) ...[
                                          const SizedBox(height: 8),
                                          SizedBox(height: 130, width: double.infinity, child: _buildQuestionImageWidget(optImg)),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                              const SizedBox(height: 6),
                              ElevatedButton(
                                onPressed: selectedSingle == null ? null : () => _answerActiveQuestion(qId, selectedSingle),
                                style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                child: const Text('Kirim Jawaban', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ],
                          );
                        }),
                    ],
                  ),
                );
              }).toList(),

              // FITUR "Soal Menggantikan Tampilan Slide": kalau ada soal
              // aktif, slide materi disembunyikan sepenuhnya (mahasiswa
              // hanya fokus ke kartu soal di atas). Slide muncul lagi
              // otomatis begitu dosen menonaktifkan semua soal aktif.
              if (activeQuestions.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                          child: Text('Slide ${_activeSlideIndex + 1} dari ${_slides.length} (Sinkron Dosen)', style: const TextStyle(fontWeight: FontWeight.bold, color: _kQuizizzTextColor, fontSize: 12)),
                        ),
                        Row(
                          children: [
                            const Text('Ukuran: ', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark, fontSize: 12)),
                            DropdownButton<String>(
                              value: _displayMode,
                              underline: const SizedBox(),
                              style: const TextStyle(fontSize: 12, color: _kNavyDark, fontWeight: FontWeight.bold),
                              items: const [
                                DropdownMenuItem(value: 'default', child: Text('Default')),
                                DropdownMenuItem(value: 'semi', child: Text('Semi Full Screen (3/4)')),
                                DropdownMenuItem(value: 'full', child: Text('Full Screen (100%)')),
                              ],
                              onChanged: (v) {
                                if (v != null) setState(() => _displayMode = v);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(currentSlide['title'] ?? 'Materi Presentasi', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _kNavyDark)),
                    const SizedBox(height: 12),
                    const Divider(color: _kNavyDark, height: 1),
                    const SizedBox(height: 14),
                    if (currentSlide['media_url'] != null && currentSlide['media_url'].toString().isNotEmpty) ...[
                      Stack(
                        children: [
                          _buildQuestionImageWidget(currentSlide['media_url'].toString(), displayMode: _displayMode, context: context),
                          if (_pointerX != null && _pointerY != null)
                            Positioned.fill(
                              child: Align(
                                alignment: FractionalOffset(_pointerX!.clamp(0.0, 1.0), _pointerY!.clamp(0.0, 1.0)),
                                child: Transform.translate(
                                  offset: const Offset(-14, -14),
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.red.withOpacity(0.4),
                                      border: Border.all(color: Colors.red, width: 4),
                                      boxShadow: const [BoxShadow(color: Colors.white, blurRadius: 2, spreadRadius: 1)],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                    Text(currentSlide['content'] ?? '', style: const TextStyle(fontSize: 16, height: 1.6, color: _kNavyDark, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 20),
                    if (isQuiz) ...[
                      const Text('✍️ Silakan Jawab Soal / Polling:', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                      const SizedBox(height: 10),
                      if (currentSlide['options'] != null)
                        ...((currentSlide['options'] as List).map((opt) => Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: _submitted ? null : () => _submitAnswer(opt),
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: _kCreamBg,
                                  padding: const EdgeInsets.all(14),
                                  side: const BorderSide(color: _kNavyDark, width: 1.2),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                                child: Text(opt.toString(), style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                              ),
                            )))
                      else ...[
                        TextField(
                          controller: _answerCtrl,
                          decoration: const InputDecoration(labelText: 'Ketik jawaban anda...', border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton(
                          onPressed: _submitted ? null : () => _submitAnswer(_answerCtrl.text.trim()),
                          style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark),
                          child: const Text('Kirim Jawaban'),
                        ),
                      ],
                      if (_submitted) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: const Color(0xFFA7F3D0), borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                          child: const Row(
                            children: [
                              Icon(Icons.check_circle_rounded, color: Color(0xFF059669)),
                              SizedBox(width: 8),
                              Text('✅ Jawaban Terkirim Ke Layar Dosen', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF059669))),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),


            ],
          ),
        ),
      ),
    ),
  ),
  if (_displayMode != 'full' && _showQaPanel)
    SizedBox(
      width: 340,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.all(16),
        child: ChatPanelWidget(
          qaMessages: _qaMessages,
          currentUserRole: 'student',
          currentUserName: widget.studentName,
          currentUserId: widget.studentName,
          onSendMessage: (msg, isPriv, toId, toName) async {
            await QuizizzService.askLessonQuestion(
              widget.sessionCode,
              studentName: widget.studentName,
              studentId: widget.studentName,
              message: msg,
              senderRole: 'student',
              isPrivate: isPriv,
              toUserId: toId,
              toUserName: toName,
            );
            await _poll();
          },
          onReplyMessage: (qId, reply) async {
            await QuizizzService.replyLessonQa(
              widget.sessionCode, 
              qId, 
              reply,
              senderName: widget.studentName,
              senderId: widget.studentName,
              senderRole: 'student',
            );
            await _poll();
          },
        ),
      ),
    ),
              ],
            ),
          ),
          if (_notificationMsg != null)
            Positioned(
              bottom: 24,
              right: 24,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                color: Colors.transparent,
                child: Container(
                  width: 350,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFBBF24), width: 2)),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active_rounded, color: Color(0xFFFBBF24), size: 28),
                      const SizedBox(width: 16),
                      Expanded(child: Text(_notificationMsg!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ======================================================================
// FLASHCARD STUDY INTERACTIVE SCREEN (3D FLIP CARD & SPACED REPETITION)
// ======================================================================
class _FlashcardStudyScreen extends StatefulWidget {
  final Map<String, dynamic> set;

  const _FlashcardStudyScreen({required this.set});

  @override
  State<_FlashcardStudyScreen> createState() => _FlashcardStudyScreenState();
}

class _FlashcardStudyScreenState extends State<_FlashcardStudyScreen> {
  List<dynamic> _cards = [];
  int _currentIndex = 0;
  bool _showBack = false;
  final List<int> _needReviewIndices = [];
  final List<int> _masteredIndices = [];
  bool _loadingProgress = true;

  String get _flashcardId => widget.set['id']?.toString() ?? widget.set['code']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _cards = List.from(widget.set['cards'] ?? []);
    _loadSavedProgress();
  }

  // Memuat indikasi "Mastered" / "Perlu Diulang" per-kartu yang sudah
  // tersimpan dari sesi belajar sebelumnya (lintas device), supaya
  // mahasiswa langsung melihat status tiap kartu begitu set dibuka lagi.
  Future<void> _loadSavedProgress() async {
    final id = _flashcardId;
    if (id.isEmpty) {
      setState(() => _loadingProgress = false);
      return;
    }
    final progress = await QuizizzService.getFlashcardProgress(id);
    if (!mounted) return;
    setState(() {
      _masteredIndices
        ..clear()
        ..addAll(progress['mastered'] ?? []);
      _needReviewIndices
        ..clear()
        ..addAll(progress['review'] ?? []);
      _loadingProgress = false;
    });
  }

  Future<void> _persistProgress() async {
    final id = _flashcardId;
    if (id.isEmpty) return;
    await QuizizzService.saveFlashcardProgress(
      id,
      masteredCards: _masteredIndices,
      reviewNeededCards: _needReviewIndices,
    );
  }

  void _flipCard() {
    setState(() => _showBack = !_showBack);
  }

  void _nextCard() {
    if (_currentIndex + 1 < _cards.length) {
      setState(() {
        _currentIndex += 1;
        _showBack = false;
      });
    }
  }

  void _prevCard() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex -= 1;
        _showBack = false;
      });
    }
  }

  void _shuffleCards() {
    setState(() {
      _cards.shuffle();
      _currentIndex = 0;
      _showBack = false;
    });
  }

  void _markCard(bool mastered) {
    if (mastered) {
      if (!_masteredIndices.contains(_currentIndex)) _masteredIndices.add(_currentIndex);
      _needReviewIndices.remove(_currentIndex);
    } else {
      if (!_needReviewIndices.contains(_currentIndex)) _needReviewIndices.add(_currentIndex);
      _masteredIndices.remove(_currentIndex);
    }
    _persistProgress();
    _nextCard();
  }

  @override
  Widget build(BuildContext context) {
    if (_cards.isEmpty) {
      return Scaffold(
        backgroundColor: _kCreamBg,
        appBar: AppBar(title: Text(widget.set['title']), backgroundColor: _kCreamBg, foregroundColor: _kNavyDark),
        body: const Center(child: Text('Kartu flashcard kosong.')),
      );
    }

    final card = _cards[_currentIndex];
    final isCurrentMastered = _masteredIndices.contains(_currentIndex);
    final isCurrentNeedReview = _needReviewIndices.contains(_currentIndex);
    // PENTING: maksimalkan ukuran tampilan flashcard mengikuti lebar layar
    // (dosen maupun mahasiswa), bukan lagi lebar/tinggi tetap yang kecil —
    // supaya kartu terasa lega dibaca di layar besar maupun kecil.
    final screenSize = MediaQuery.of(context).size;
    final cardWidth = (screenSize.width - 64).clamp(320.0, 900.0);
    final cardHeight = (screenSize.height * 0.55).clamp(320.0, 620.0);

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        title: Text('${widget.set['title']} (${_currentIndex + 1}/${_cards.length})', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.shuffle_rounded, color: _kNavyDark),
            onPressed: _shuffleCards,
            tooltip: 'Acak Urutan Kartu',
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _kNavyDark, width: 1.5)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('✅ Hafal: ${_masteredIndices.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF059669))),
                    const SizedBox(width: 16),
                    Text('🔄 Perlu Diulang: ${_needReviewIndices.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFEA580C))),
                    if (_loadingProgress) ...[
                      const SizedBox(width: 12),
                      const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: _kNavyDark)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: _flipCard,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: cardWidth,
                      height: cardHeight,
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: _showBack ? _kQuizizzPastelBg : Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: _kNavyDark, width: 2.5),
                        boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                                child: Text(_showBack ? 'SISI BELAKANG (DEFINISI)' : 'SISI DEPAN (ISTILAH)', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: _kNavyDark)),
                              ),
                              const Icon(Icons.touch_app_rounded, color: _kNavyDark, size: 20),
                            ],
                          ),
                          Expanded(
                            child: Center(
                              child: (!_showBack && card['front_image'] != null && card['front_image'].toString().isNotEmpty)
                                  ? SingleChildScrollView(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            constraints: BoxConstraints(maxHeight: cardHeight * 0.45),
                                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(11),
                                              child: card['front_image'].toString().startsWith('data:image')
                                                  ? Image.memory(base64Decode(card['front_image'].toString().split(',').last), fit: BoxFit.contain)
                                                  : Image.network(card['front_image'].toString(), fit: BoxFit.contain),
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Text(card['front'] ?? '', textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _kNavyDark)),
                                        ],
                                      ),
                                    )
                                  : Text(
                                      _showBack ? card['back'] : card['front'],
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: _showBack ? 24 : 30,
                                        fontWeight: FontWeight.w900,
                                        color: _kNavyDark,
                                      ),
                                    ),
                            ),
                          ),
                          const Text('(Klik / Tap Kartu Untuk Membalik)', style: TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    // Indikasi status kartu ini: Mastered (hijau) / Perlu
                    // Diulang (oranye), tampil di pojok kanan-atas kartu.
                    if (isCurrentMastered || isCurrentNeedReview)
                      Positioned(
                        top: -12,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: isCurrentMastered ? const Color(0xFFA7F3D0) : const Color(0xFFFFEDD5),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: _kNavyDark, width: 1.5),
                            boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(2, 2), blurRadius: 0)],
                          ),
                          child: Text(
                            isCurrentMastered ? '✅ Sudah Dikuasai' : '🔄 Perlu Diulang',
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: isCurrentMastered ? const Color(0xFF059669) : const Color(0xFFEA580C)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _markCard(false),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFEDD5),
                      foregroundColor: const Color(0xFFEA580C),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2)),
                    ),
                    icon: const Icon(Icons.replay_rounded, size: 18),
                    label: const Text('🔄 Still Need Review', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 14),
                  ElevatedButton.icon(
                    onPressed: () => _markCard(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFA7F3D0),
                      foregroundColor: const Color(0xFF059669),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2)),
                    ),
                    icon: const Icon(Icons.check_circle_rounded, size: 18),
                    label: const Text('✅ Mastered', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: _kNavyDark, size: 28),
                    onPressed: _currentIndex > 0 ? _prevCard : null,
                  ),
                  const SizedBox(width: 20),
                  Text('${_currentIndex + 1} / ${_cards.length}', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 16)),
                  const SizedBox(width: 20),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_rounded, color: _kNavyDark, size: 28),
                    onPressed: _currentIndex + 1 < _cards.length ? _nextCard : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// MAHASISWA GAMIFIED QUIZ ACTIVE PLAYER (STREAK COMBO & MULTI-TYPE QUIZ)
// ======================================================================
class _StudentQuizActiveScreen extends StatefulWidget {
  final Map<String, dynamic> session;
  final String playerId;
  final String studentName;
  final String quizId;
  final String? sessionId;
  final bool isHomework;
  final String? studentId;
  // Waktu server (ISO8601) persis saat dosen menekan "Mulai Room Game
  // Sekarang" — SAMA untuk semua mahasiswa yang join, dipakai supaya timer
  // tiap soal identik di semua perangkat (bukan dihitung ulang dari kapan
  // masing-masing perangkat membuka layar soal).
  final String? quizStartedAt;

  const _StudentQuizActiveScreen({required this.session, required this.playerId, required this.studentName, required this.quizId, this.sessionId, this.isHomework = false, this.studentId, this.quizStartedAt});

  @override
  State<_StudentQuizActiveScreen> createState() => _StudentQuizActiveScreenState();
}

class _StudentQuizActiveScreenState extends State<_StudentQuizActiveScreen> {
  int _score = 0;
  int _streak = 0;
  int _currentQuestionIndex = 0;
  List<Map<String, dynamic>> _questions = [];
  bool _loadingQuestions = true;

  String? _selectedSingleOption;
  final List<String> _selectedMultiOptions = [];
  // (Fitur "mengunci jawaban" DIHAPUS — mahasiswa boleh mengubah jawaban
  // bebas selama waktu masih tersisa; jawaban TERAKHIR saat waktu habis
  // itulah yang dinilai, lihat _revealAnswerAndAdvance.)
  // _answered = jawaban sudah DIUNGKAP (benar/salah terlihat). Untuk mode PR
  // (isHomework) nilai ini tidak dipakai sama sekali karena PR tidak
  // mengungkap benar/salah per soal, hanya di akhir setelah "Kumpulkan".
  bool _answered = false;

  // Timer countdown per soal (HANYA untuk kuis live, PR tidak memakai timer
  // sama sekali sesuai permintaan).
  Timer? _questionTimer;
  Timer? _advanceTimer;
  int _remainingSeconds = 30;
  // Sisa waktu (detik) saat mahasiswa MENGUNCI jawaban — dipakai untuk
  // menghitung poin berbasis kecepatan (makin banyak sisa waktu saat
  // menjawab = makin cepat = poin makin besar).
  int? _answerLockedRemainingSeconds;
  // Banner streak (setiap 3 jawaban benar berturut-turut) tampil 5 detik.
  bool _showStreakBonusBanner = false;
  int _lastStreakBonusValue = 0;

  // --- Sinkronisasi timer ANTAR MAHASISWA ---
  // Waktu server (UTC) persis saat dosen menekan "Mulai Room Game Sekarang".
  // Kalau tersedia, timer soal DIHITUNG dari titik waktu ini (sama untuk
  // semua mahasiswa), bukan dari kapan masing-masing perangkat membuka
  // layar soal — supaya semua mahasiswa benar-benar melihat soal & sisa
  // waktu yang SAMA PERSIS di saat yang sama.
  DateTime? _quizStartTimeUtc;
  List<int> _questionEndOffsets = [];

  // --- Khusus mode PR (Pekerjaan Rumah / Homework) ---
  // Menyimpan jawaban tiap soal per index agar mahasiswa bisa bolak-balik
  // (Sebelumnya / Berikutnya) tanpa kehilangan jawaban yang sudah dipilih.
  List<dynamic> _hwAnswers = [];

  @override
  void initState() {
    super.initState();
    _loadQuizQuestions();
  }

  @override
  void dispose() {
    _questionTimer?.cancel();
    _advanceTimer?.cancel();
    super.dispose();
  }

  void _startTimerForCurrentQuestion() {
    if (widget.isHomework) return; // PR tidak memakai timer sama sekali.
    _questionTimer?.cancel();
    if (_currentQuestionIndex >= _questions.length) return;

    // Kalau jadwal absolut tersedia (dosen sudah menekan mulai), sinkronkan
    // sisa waktu dari jadwal itu supaya sama persis dengan mahasiswa lain.
    // Kalau tidak tersedia (fallback), pakai durasi penuh soal saat ini.
    final scheduled = _computeScheduledPosition();
    if (scheduled != null) {
      _remainingSeconds = scheduled['remaining']!.clamp(0, 1 << 30);
    } else {
      final currentQ = _questions[_currentQuestionIndex];
      _remainingSeconds = (currentQ['timer_seconds'] is int)
          ? currentQ['timer_seconds']
          : int.tryParse('${currentQ['timer_seconds'] ?? 30}') ?? 30;
    }
    _answerLockedRemainingSeconds = null;

    _questionTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      // PENTING: timer TETAP berjalan dan mahasiswa boleh terus berganti
      // jawaban (tidak dikunci). Benar/salah baru diungkap setelah waktu
      // benar-benar habis, baru pindah ke soal berikutnya.
      if (_answered) {
        t.cancel();
        return;
      }

      // Sinkronisasi ulang tiap detik terhadap jadwal absolut (kalau ada),
      // supaya sisa waktu TIDAK PERNAH melenceng antar mahasiswa walau ada
      // sedikit keterlambatan render/jaringan di salah satu perangkat.
      final pos = _computeScheduledPosition();
      if (pos != null) {
        if (pos['index']! != _currentQuestionIndex) {
          // Jadwal bilang seharusnya sudah pindah ke soal lain (mis. tab
          // sempat tidak aktif/lag) -> langsung ungkap & lanjut mengejar.
          t.cancel();
          _revealAnswerAndAdvance();
          return;
        }
        setState(() {
          _remainingSeconds = pos['remaining']!.clamp(0, 1 << 30);
        });
      } else {
        setState(() {
          _remainingSeconds -= 1;
        });
      }

      if (_remainingSeconds <= 0) {
        t.cancel();
        _revealAnswerAndAdvance();
      }
    });
  }

  // Waktu HABIS -> ungkap benar/salah berdasarkan jawaban yang sudah dipilih
  // mahasiswa (atau kosong/salah kalau belum sempat menjawab sama sekali),
  // sinkronkan ke backend, lalu otomatis lanjut ke soal berikutnya.
  Future<void> _revealAnswerAndAdvance() async {
    if (_answered || !mounted) return;
    final currentQ = _questions[_currentQuestionIndex];
    final qType = currentQ['type'] ?? 'multiple_choice';
    bool isCorrect = false;
    dynamic answerToSync;

    if (qType == 'multi_select') {
      final List correctList = currentQ['correct_list'] ?? [];
      // PENTING: bandingkan dengan trim+uppercase, SAMA PERSIS dengan
      // normalisasi yang dipakai backend (checkAnswerCorrectness), supaya
      // status benar/salah yang tampil ke mahasiswa selalu konsisten dengan
      // yang dihitung backend untuk leaderboard.
      final correctSet = correctList.map((e) => e.toString().trim().toUpperCase()).toSet();
      final selectedSet = _selectedMultiOptions.map((e) => e.trim().toUpperCase()).toSet();
      isCorrect = selectedSet.isNotEmpty &&
          selectedSet.length == correctSet.length &&
          selectedSet.every((element) => correctSet.contains(element));
      answerToSync = List<String>.from(_selectedMultiOptions);
    } else {
      final selected = _selectedSingleOption?.trim().toUpperCase();
      final correctAns = currentQ['correct']?.toString().trim().toUpperCase();
      isCorrect = selected != null && selected.isNotEmpty && selected == correctAns;
      // FITUR "Perbaikan Bug PG Disalahkan" (poin 6): pengaman tambahan --
      // sama seperti di backend (checkAnswerCorrectness) -- kalau salah
      // satu nilai ternyata berupa HURUF opsi (A/B/C/D) sedangkan yang
      // lain berupa TEKS LENGKAP opsi, coba resolusi lewat daftar opsi
      // sebelum benar-benar dianggap salah.
      if (!isCorrect && selected != null && selected.isNotEmpty && correctAns != null && correctAns.isNotEmpty) {
        final options = (currentQ['options'] as List?) ?? [];
        String? letterToText(String letter) {
          final idx = 'ABCD'.indexOf(letter);
          if (idx < 0 || idx >= options.length) return null;
          return options[idx].toString().trim().toUpperCase();
        }

        final isSelectedLetter = RegExp(r'^[A-D]$').hasMatch(selected);
        final isCorrectLetter = RegExp(r'^[A-D]$').hasMatch(correctAns);
        final resolvedSelected = isSelectedLetter ? letterToText(selected) : selected;
        final resolvedCorrect = isCorrectLetter ? letterToText(correctAns) : correctAns;
        if (resolvedSelected != null && resolvedCorrect != null && resolvedSelected == resolvedCorrect) {
          isCorrect = true;
        }
      }
      answerToSync = _selectedSingleOption ?? '';
    }

    // PENTING (poin berbasis kecepatan menjawab): mahasiswa yang mengunci
    // jawaban lebih cepat (sisa waktu di timer lebih banyak saat itu) dapat
    // poin lebih besar; yang menjawab belakangan / mepet waktu habis dapat
    // poin lebih kecil. Base 500 pts untuk jawaban benar, ditambah bonus
    // kecepatan hingga 500 pts (total maksimum 1000 pts kalau langsung
    // menjawab tepat saat soal muncul).
    final totalTime = (currentQ['timer_seconds'] is int)
        ? currentQ['timer_seconds'] as int
        : (int.tryParse('${currentQ['timer_seconds'] ?? 30}') ?? 30);
    final timeLeftAtAnswer = (_answerLockedRemainingSeconds ?? 0).clamp(0, totalTime);
    final speedRatio = totalTime > 0 ? (timeLeftAtAnswer / totalTime) : 0.0;

    bool streakMilestoneHit = false;
    int milestoneBonus = 0;

    // Tampilkan reveal warna benar/salah SEKETIKA (tidak menunggu jaringan),
    // memakai hasil hitungan lokal untuk UMPAN BALIK VISUAL saja.
    setState(() {
      _answered = true;
    });

    // PENTING: BACKEND adalah SUMBER KEBENARAN UTAMA untuk skor (dipakai
    // Live Leaderboard & Podium Juara dosen). Supaya "Total Skor
    // Gamifikasi" yang dilihat mahasiswa SELALU sama dengan yang dilihat
    // dosen, kita tunggu respons backend lalu pakai skor/streak dari sana
    // -- bukan menghitung sendiri secara lokal (yang dulu bisa berbeda
    // rumus/hasil dari backend).
    final serverResult = await _syncAnswerToServer(answerToSync, totalTime: totalTime, timeRemaining: timeLeftAtAnswer, isCorrect: isCorrect);

    if (serverResult != null) {
      final srvScore = serverResult['score'];
      final srvStreak = serverResult['streak'];
      final srvPoin = serverResult['poin_didapat'];
      if (srvStreak != null && (srvPoin ?? 0) > 0 && srvStreak % 3 == 0) {
        streakMilestoneHit = true;
        milestoneBonus = 100;
      }
      if (mounted) {
        setState(() {
          if (srvScore != null) _score = (srvScore as num).toInt();
          if (srvStreak != null) _streak = (srvStreak as num).toInt();
        });
      }
    } else {
      // Jaringan gagal -> fallback hitung lokal supaya mahasiswa tetap
      // dapat umpan balik (skor sinkron ulang nanti lewat leaderboard).
      final speedBonus = (500 * speedRatio).round();
      if (mounted) {
        setState(() {
          if (isCorrect) {
            _score += 500 + speedBonus;
            _streak += 1;
            if (_streak > 0 && _streak % 3 == 0) {
              streakMilestoneHit = true;
              milestoneBonus = 100;
              _score += milestoneBonus;
            }
          } else {
            _streak = 0;
          }
        });
      }
    }

    _advanceTimer?.cancel();
    if (streakMilestoneHit) {
      // Tampilkan banner streak selama 5 detik sebelum lanjut ke soal
      // berikutnya (kalau masih ada soal).
      setState(() {
        _showStreakBonusBanner = true;
        _lastStreakBonusValue = milestoneBonus;
      });
      _advanceTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() => _showStreakBonusBanner = false);
          _nextQuestion();
        }
      });
    } else {
      _advanceTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) _nextQuestion();
      });
    }
  }

  // Kirim jawaban mahasiswa ke BACKEND supaya tercatat di leaderboard & CSV
  // dosen, dan ambil skor/streak resmi yang dihitung backend (single source
  // of truth). Mengembalikan null kalau gagal (mis. offline).
  Future<Map<String, dynamic>?> _syncAnswerToServer(dynamic answer, {int? totalTime, int? timeRemaining, bool? isCorrect}) async {
    final sessionId = widget.sessionId;
    if (sessionId == null || sessionId.isEmpty) return null;
    if (_currentQuestionIndex >= _questions.length) return null;
    final currentQ = _questions[_currentQuestionIndex];
    final questionId = currentQ['id']?.toString();
    if (questionId == null || questionId.isEmpty) return null;
    try {
      final res = await QuizizzService.submitAnswer(
        sessionId,
        questionId,
        widget.playerId,
        answer,
        totalTime: totalTime,
        timeRemaining: timeRemaining,
        isCorrect: isCorrect,
      );
      return res;
    } catch (_) {
      // Jaringan bermasalah: skor tetap dihitung secara lokal agar mahasiswa
      // tidak terganggu, backend hanya kehilangan satu baris jawaban ini.
      return null;
    }
  }

  Future<void> _loadQuizQuestions() async {
    List<Map<String, dynamic>> qList = [];

    // 1. Check if session object passed custom questions directly
    if (widget.session['questions'] != null && (widget.session['questions'] as List).isNotEmpty) {
      qList = (widget.session['questions'] as List).cast<Map<String, dynamic>>();
    } else {
      // 2. Fetch custom questions for quizId
      qList = await QuizizzService.getCustomQuestions(widget.quizId);

      // 3. Search in assigned homework if quizId matches or empty
      if (qList.isEmpty) {
        final hwList = await QuizizzService.getAssignedHomework();
        for (final hw in hwList) {
          if (hw['quiz_id'] == widget.quizId || hw['id'] == widget.quizId) {
            final hwQ = hw['questions'] as List?;
            if (hwQ != null && hwQ.isNotEmpty) {
              qList = hwQ.cast<Map<String, dynamic>>();
              break;
            }
          }
        }
      }

      // 4. If still empty, search across ALL saved custom questions in storage
      if (qList.isEmpty) {
        qList = await QuizizzService.getAllSavedCustomQuestions();
      }
    }

    // Ambil pengaturan anti-mencontek (Acak Soal & Acak Jawaban)
    final quizSettings = await QuizizzService.getQuizSettings(widget.quizId);
    final bool shouldShuffleQuestions = widget.session['shuffle_questions'] == true ||
        (widget.session['shuffle_questions'] == null && quizSettings['shuffle_questions'] == true);
    final bool shouldShuffleAnswers = widget.session['shuffle_answers'] == true ||
        (widget.session['shuffle_answers'] == null && quizSettings['shuffle_answers'] == true);

    if (mounted) {
      final sName = widget.studentName.isNotEmpty ? widget.studentName : (widget.studentId ?? 'student');

      // 1. ACAK URUTAN SOAL (deterministik per siswa berdasarkan nama & quizId)
      if (shouldShuffleQuestions && qList.length > 1) {
        final qSeed = (sName.hashCode ^ widget.quizId.hashCode).abs();
        final qRng = Random(qSeed);
        qList = List<Map<String, dynamic>>.from(qList);
        for (int i = qList.length - 1; i > 0; i--) {
          int n = qRng.nextInt(i + 1);
          var temp = qList[i];
          qList[i] = qList[n];
          qList[n] = temp;
        }
      }

      setState(() {
        // FITUR "Perbaikan Bug Multi-Select Selalu Disalahkan" (poin 4):
        // soal yang diambil LANGSUNG dari backend (mis. mahasiswa membuka
        // PR di device berbeda dari dosen, jadi local storage browsernya
        // kosong) belum melalui normalisasi 'correct_list' seperti soal
        // Kuis Gamifikasi Live yang join lewat PIN. Akibatnya untuk soal
        // Multi-Select, field 'correct_list' selalu kosong/null padahal
        // datanya SEBENARNYA ada (di field 'correct', yang untuk
        // multi_select berupa array) -- membuat soal SELALU dianggap
        // salah walau jawaban mahasiswa sudah tepat. Sekarang SEMUA soal
        // dinormalisasi dengan cara yang sama di sini, apa pun sumbernya.
        _questions = qList.asMap().entries.map((entry) {
          final norm = _StudentWaitingRoomScreenState._normalizeServerQuestion(entry.value);
          final processed = processVariableCalculations(norm, studentIdentifier: sName, questionIndex: entry.key);

          // 2. ACAK PILIHAN JAWABAN (A, B, C, D) deterministik per siswa & per soal
          if (shouldShuffleAnswers) {
            final qType = (processed['type'] ?? 'multiple_choice').toString();
            if (qType == 'multiple_choice' || qType == 'multi_select') {
              final rawOptions = (processed['options'] as List?)?.map((e) => e.toString()).toList() ?? [];
              final rawOptionImages = (processed['option_images'] as List?)?.map((e) => e?.toString()).toList() ?? [];
              if (rawOptions.length > 1) {
                final paired = List.generate(rawOptions.length, (idx) => {
                  'text': rawOptions[idx],
                  'image': idx < rawOptionImages.length ? rawOptionImages[idx] : null,
                });
                final ansSeed = (sName.hashCode ^ (processed['question'] ?? '').hashCode ^ entry.key).abs();
                final ansRng = Random(ansSeed);
                for (int i = paired.length - 1; i > 0; i--) {
                  int n = ansRng.nextInt(i + 1);
                  var temp = paired[i];
                  paired[i] = paired[n];
                  paired[n] = temp;
                }
                processed['options'] = paired.map((e) => e['text']).toList();
                processed['option_images'] = paired.map((e) => e['image']).toList();
              }
            }
          }

          return processed;
        }).toList();
        _loadingQuestions = false;
        if (widget.isHomework) {
          _hwAnswers = List<dynamic>.filled(qList.length, null);
        }
      });
      _buildScheduleIfNeeded();
      _jumpToScheduledPositionIfNeeded();
      _startTimerForCurrentQuestion();
    }
  }

  // Membangun jadwal kumulatif [akhir soal-1, akhir soal-2, ...] (dalam detik
  // sejak dosen menekan mulai) berdasarkan durasi timer tiap soal. Dipakai
  // supaya SEMUA mahasiswa menghitung posisi soal & sisa waktu dari titik
  // acuan waktu yang SAMA (bukan dari kapan device masing-masing membuka
  // layar soal).
  void _buildScheduleIfNeeded() {
    if (widget.isHomework || widget.quizStartedAt == null || widget.quizStartedAt!.isEmpty) return;
    try {
      _quizStartTimeUtc = DateTime.parse(widget.quizStartedAt!).toUtc();
    } catch (_) {
      _quizStartTimeUtc = null;
      return;
    }
    int cum = 0;
    final offsets = <int>[];
    for (final q in _questions) {
      final t = (q['timer_seconds'] is int) ? q['timer_seconds'] as int : (int.tryParse('${q['timer_seconds'] ?? 30}') ?? 30);
      cum += t;
      offsets.add(cum);
    }
    _questionEndOffsets = offsets;
  }

  // Kalau mahasiswa baru masuk SETELAH kuis sebenarnya sudah berjalan
  // beberapa detik (mis. koneksi agak lambat), langsung loncat ke soal &
  // sisa waktu yang SEHARUSNYA sedang berjalan saat ini — supaya tetap
  // sinkron dengan mahasiswa lain, bukan mulai dari soal 1 dengan waktu penuh.
  void _jumpToScheduledPositionIfNeeded() {
    final pos = _computeScheduledPosition();
    if (pos == null) return;
    if (pos['index']! > 0 && pos['index']! != _currentQuestionIndex) {
      setState(() {
        _currentQuestionIndex = pos['index']!.clamp(0, _questions.isEmpty ? 0 : _questions.length - 1);
      });
    }
  }

  // Menghitung soal ke berapa & sisa detik yang SEHARUSNYA sedang berjalan
  // saat ini, berdasarkan jadwal absolut. Return null kalau mode PR atau
  // waktu mulai server tidak tersedia (fallback ke timer lokal biasa).
  Map<String, int>? _computeScheduledPosition() {
    if (_quizStartTimeUtc == null || _questionEndOffsets.isEmpty) return null;
    final elapsed = DateTime.now().toUtc().difference(_quizStartTimeUtc!).inSeconds;
    for (int i = 0; i < _questionEndOffsets.length; i++) {
      if (elapsed < _questionEndOffsets[i]) {
        final prevEnd = i == 0 ? 0 : _questionEndOffsets[i - 1];
        return {'index': i, 'remaining': _questionEndOffsets[i] - elapsed, 'elapsedInQuestion': elapsed - prevEnd};
      }
    }
    // Sudah melewati semua jadwal soal.
    return {'index': _questions.length, 'remaining': 0, 'elapsedInQuestion': 0};
  }

  // === MODE KUIS LIVE (isHomework == false) ===
  // Memilih jawaban HANYA mengunci pilihan; benar/salah baru terlihat & skor
  // baru dihitung saat timer habis (lihat _revealAnswerAndAdvance).
  void _chooseSingleOption(String option) {
    if (widget.isHomework) {
      // Mode PR: jawaban bisa diganti-ganti bebas, tidak dikunci.
      setState(() {
        _selectedSingleOption = option;
        _hwAnswers[_currentQuestionIndex] = option;
      });
      return;
    }
    // Mode kuis live: TIDAK dikunci — mahasiswa boleh berganti pilihan
    // sebanyak apapun selama timer belum habis (_answered masih false).
    // Waktu tersisa dicatat ulang setiap kali berganti pilihan, supaya poin
    // kecepatan mengikuti pilihan TERAKHIR mahasiswa saat waktu benar-benar
    // habis.
    if (_answered) return;
    setState(() {
      _selectedSingleOption = option;
      _answerLockedRemainingSeconds = _remainingSeconds;
    });
  }

  void _toggleMultiOption(String option) {
    if (widget.isHomework) {
      setState(() {
        if (_selectedMultiOptions.contains(option)) {
          _selectedMultiOptions.remove(option);
        } else {
          _selectedMultiOptions.add(option);
        }
        _hwAnswers[_currentQuestionIndex] = List<String>.from(_selectedMultiOptions);
      });
      return;
    }
    if (_answered) return;
    setState(() {
      if (_selectedMultiOptions.contains(option)) {
        _selectedMultiOptions.remove(option);
      } else {
        _selectedMultiOptions.add(option);
      }
      _answerLockedRemainingSeconds = _remainingSeconds;
    });
  }

  void _nextQuestion() {
    _questionTimer?.cancel();
    _advanceTimer?.cancel();
    if (_currentQuestionIndex + 1 < _questions.length) {
      setState(() {
        _currentQuestionIndex += 1;
        _selectedSingleOption = null;
        _selectedMultiOptions.clear();
        _answered = false;
        _answerLockedRemainingSeconds = null;
        _showStreakBonusBanner = false;
      });
      _startTimerForCurrentQuestion();
    } else {
      _showFinalGamifiedResults();
    }
  }

  // === MODE PR (isHomework == true) ===
  // Mahasiswa bebas berpindah maju/mundur antar soal; jawaban yang sudah
  // dipilih tetap tersimpan di _hwAnswers sesuai index soalnya.
  void _goToHomeworkQuestion(int index) {
    if (index < 0 || index >= _questions.length) return;
    _questionTimer?.cancel();
    final saved = _hwAnswers[index];
    setState(() {
      _currentQuestionIndex = index;
      final qType = _questions[index]['type'] ?? 'multiple_choice';
      if (qType == 'multi_select') {
        _selectedMultiOptions
          ..clear()
          ..addAll((saved is List) ? saved.cast<String>() : <String>[]);
        _selectedSingleOption = null;
      } else {
        _selectedSingleOption = saved is String ? saved : null;
        _selectedMultiOptions.clear();
      }
    });
  }

  // Hitung skor PR dari seluruh jawaban tersimpan, lalu tampilkan hasil akhir.
  void _finishHomework() {
    int correctCount = 0;
    // PENTING (fitur "Riwayat Jawaban PR"): rekam detail tiap soal (bukan
    // cuma skor total) supaya bisa ditampilkan ulang di halaman Riwayat
    // baik oleh mahasiswa maupun dosen — soal apa, jawaban mahasiswa apa,
    // jawaban benarnya apa, dan status benar/salah.
    final List<Map<String, dynamic>> answerDetails = [];
    for (int i = 0; i < _questions.length; i++) {
      final q = _questions[i];
      final qType = q['type'] ?? 'multiple_choice';
      final ans = _hwAnswers[i];
      bool isCorrect = false;
      if (qType == 'multi_select') {
        final List correctList = q['correct_list'] ?? [];
        final List givenList = (ans is List) ? ans : [];
        // PENTING: bandingkan dengan trim+uppercase, sama persis dengan
        // normalisasi backend (checkAnswerCorrectness) supaya konsisten.
        final correctSet = correctList.map((e) => e.toString().trim().toUpperCase()).toSet();
        final givenSet = givenList.map((e) => e.toString().trim().toUpperCase()).toSet();
        isCorrect = givenSet.isNotEmpty &&
            givenSet.length == correctSet.length &&
            givenSet.every((e) => correctSet.contains(e));
      } else {
        final givenAns = ans?.toString().trim().toUpperCase();
        final correctAns = q['correct']?.toString().trim().toUpperCase();
        isCorrect = givenAns != null && givenAns.isNotEmpty && givenAns == correctAns;
      }
      if (isCorrect) correctCount += 1;
      answerDetails.add({
        'question_id': q['id']?.toString() ?? 'q_$i',
        'question': q['question'] ?? q['question_text'] ?? '',
        'options': q['options'] ?? [],
        'type': qType,
        'student_answer': ans,
        'correct_answer': qType == 'multi_select' ? (q['correct_list'] ?? []) : q['correct'],
        'is_correct': isCorrect,
      });
    }
    setState(() {
      _score = correctCount;
    });
    _showHomeworkResults(correctCount, _questions.length, answerDetails);
  }

  // Hasil akhir khusus PR: tampilkan jumlah benar, catat nilai ke dosen, lalu
  // kembali ke daftar PR (BUKAN podium/leaderboard, karena PR dikerjakan
  // mandiri kapan saja, bukan kompetisi real-time).
  Future<void> _showHomeworkResults(int correctCount, int total, [List<Map<String, dynamic>>? answerDetails]) async {
    final hwId = widget.session['hw_id']?.toString() ?? widget.quizId;
    try {
      await QuizizzService.recordHomeworkSubmission(hwId, widget.studentName, correctCount, total);
    } catch (_) {}
    try {
      await QuizizzService.submitHomeworkResultToServer(
        quizId: widget.quizId,
        homeworkId: hwId,
        studentName: widget.studentName,
        studentId: widget.studentId,
        score: correctCount,
        totalQuestions: total,
        answers: answerDetails,
      );
    } catch (_) {}

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Text('📝 Pekerjaan Rumah Selesai Dikumpulkan', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark), textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: _kMustardYellow, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.5)),
              child: const Icon(Icons.task_alt_rounded, size: 50, color: _kNavyDark),
            ),
            const SizedBox(height: 16),
            Text('Jawaban Benar: $correctCount dari $total Soal', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark)),
            const SizedBox(height: 6),
            const Text('Hasil pekerjaan Anda sudah dikirim ke dosen.', style: TextStyle(color: Colors.black54, fontSize: 12)),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark),
            child: const Text('Back to Homework List', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _showFinalGamifiedResults() async {
    QuizizzService.markLiveQuizDone(widget.quizId);

    // Tandai pemain selesai & ambil peringkat akhir (Top 3) dari BACKEND agar
    // seluruh mahasiswa melihat papan peringkat yang sama secara real-time.
    List<dynamic> leaderboard = [];
    final sessionId = widget.sessionId;
    if (sessionId != null && sessionId.isNotEmpty) {
      try {
        await QuizizzService.completePlayer(sessionId, widget.playerId);
      } catch (_) {}
      try {
        final res = await QuizizzService.getLeaderboard(sessionId);
        leaderboard = (res['leaderboard'] as List?) ?? [];
      } catch (_) {}
    }

    final myRank = leaderboard.indexWhere((p) => p['id']?.toString() == widget.playerId) + 1;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Text('🎉 KUIS GAMIFIKASI SELESAI 🎉', style: TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark), textAlign: TextAlign.center),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: _kMustardYellow, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.5)),
                child: const Icon(Icons.emoji_events_rounded, size: 50, color: _kNavyDark),
              ),
              const SizedBox(height: 16),
              Text('Pemain: ${widget.studentName}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black54)),
              const SizedBox(height: 4),
              Text('TOTAL SKOR GAMIFIKASI: $_score PTS', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Color(0xFF059669))),
              const SizedBox(height: 6),
              Text('Max Streak Combo: 🔥 $_streak x', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFEA580C))),
              if (myRank > 0) ...[
                const SizedBox(height: 6),
                Text('Peringkat Anda: #$myRank dari ${leaderboard.length} peserta', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
              ],
              const SizedBox(height: 18),
              const Divider(color: _kNavyDark, height: 1),
              const SizedBox(height: 12),
              const Text('🏆 PODIUM JUARA 🏆', style: TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark)),
              const SizedBox(height: 10),
              if (leaderboard.isEmpty)
                const Text('Belum ada data peringkat.', style: TextStyle(color: Colors.black54, fontSize: 12))
              else ...[
                if (leaderboard.isNotEmpty)
                  Text('🥇 JUARA 1: ${leaderboard[0]['display_name']} (${leaderboard[0]['score']} Pts)', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: _kNavyDark)),
                if (leaderboard.length > 1) ...[
                  const SizedBox(height: 4),
                  Text('🥈 JUARA 2: ${leaderboard[1]['display_name']} (${leaderboard[1]['score']} Pts)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0284C7))),
                ],
                if (leaderboard.length > 2) ...[
                  const SizedBox(height: 4),
                  Text('🥉 JUARA 3: ${leaderboard[2]['display_name']} (${leaderboard[2]['score']} Pts)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFEA580C))),
                ],
              ],
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Kembali ke Beranda Quizizz (menutup layar kuis, kembali ke
              // tab join/beranda mahasiswa).
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark),
            child: const Text('Back to Classly Home', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingQuestions) return const Scaffold(backgroundColor: _kCreamBg, body: Center(child: CircularProgressIndicator(color: _kNavyDark)));
    if (_questions.isEmpty) return const Scaffold(backgroundColor: _kCreamBg, body: Center(child: Text('Soal kuis kosong.')));

    return widget.isHomework ? _buildHomeworkScaffold() : _buildLiveQuizScaffold();
  }

  // ============================================================
  // MODE PR (PEKERJAAN RUMAH): tanpa timer, bisa maju/mundur bebas
  // antar soal, benar/salah baru diketahui setelah "Kumpulkan PR".
  // ============================================================
  Widget _buildHomeworkScaffold() {
    final currentQ = _questions[_currentQuestionIndex];
    final qType = currentQ['type'] ?? 'multiple_choice';
    final options = (currentQ['options'] as List?) ?? ['Opsi A', 'Opsi B'];
    final imageUrl = currentQ['image_url'];
    final isFirst = _currentQuestionIndex == 0;
    final isLast = _currentQuestionIndex == _questions.length - 1;
    final answeredCount = _hwAnswers.where((a) => a != null && !(a is List && a.isEmpty)).length;

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        title: Text(widget.session['title'] ?? 'Pekerjaan Rumah', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                child: Text('Terjawab: $answeredCount / ${_questions.length}', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13)),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 540,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Navigasi nomor soal (bisa loncat langsung ke soal manapun)
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _questions.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final isActive = i == _currentQuestionIndex;
                      final isFilled = _hwAnswers[i] != null && !(_hwAnswers[i] is List && (_hwAnswers[i] as List).isEmpty);
                      return InkWell(
                        onTap: () => _goToHomeworkQuestion(i),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isActive ? _kNavyDark : (isFilled ? _kMustardYellow : _kCreamBg),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _kNavyDark, width: 1.2),
                          ),
                          child: Text('${i + 1}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isActive ? Colors.white : _kNavyDark)),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                  child: Text('Soal ${_currentQuestionIndex + 1} dari ${_questions.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kQuizizzTextColor)),
                ),
                const SizedBox(height: 16),

                if (imageUrl != null && imageUrl.toString().isNotEmpty) ...[
                  _buildQuestionImageWidget(imageUrl.toString()),
                  const SizedBox(height: 14),
                ],

                Text(currentQ['question'] ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _kNavyDark)),
                const SizedBox(height: 16),
                const Divider(color: _kNavyDark, height: 1),
                const SizedBox(height: 16),

                if (qType == 'multiple_choice' || qType == 'true_false')
                  ...options.map((opt) {
                    final optStr = opt.toString();
                    final isSelected = _selectedSingleOption == optStr;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => _chooseSingleOption(optStr),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: isSelected ? _kMustardYellow : _kCreamBg,
                          padding: const EdgeInsets.all(16),
                          side: const BorderSide(color: _kNavyDark, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Text(optStr, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark)),
                      ),
                    );
                  })
                else if (qType == 'multi_select') ...[
                  const Text('Pilihlah seluruh jawaban yang benar (Centang Banyak):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(height: 10),
                  ...options.map((opt) {
                    final optStr = opt.toString();
                    final isChecked = _selectedMultiOptions.contains(optStr);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(color: isChecked ? _kMustardYellow : _kCreamBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.2)),
                      child: CheckboxListTile(
                        value: isChecked,
                        title: Text(optStr, style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                        activeColor: _kNavyDark,
                        onChanged: (_) => _toggleMultiOption(optStr),
                      ),
                    );
                  }),
                ] else if (qType == 'short_answer') ...[
                  const Text('Ketik jawaban Anda:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(height: 10),
                  TextFormField(
                    key: ValueKey('short_answer_hw_$_currentQuestionIndex'),
                    initialValue: _selectedSingleOption,
                    onChanged: (val) => _chooseSingleOption(val),
                    decoration: InputDecoration(
                      hintText: 'Jawaban Anda...',
                      filled: true,
                      fillColor: _kCreamBg,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark),
                  ),
                ],

                const SizedBox(height: 20),
                const Divider(color: _kNavyDark, height: 1),
                const SizedBox(height: 16),

                // NAVIGASI: Sebelumnya / Berikutnya / Kumpulkan PR
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isFirst ? null : () => _goToHomeworkQuestion(_currentQuestionIndex - 1),
                        style: OutlinedButton.styleFrom(foregroundColor: _kNavyDark, side: const BorderSide(color: _kNavyDark, width: 1.2), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                        icon: const Icon(Icons.arrow_back_rounded, size: 18),
                        label: const Text('Previous', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: isLast
                          ? ElevatedButton.icon(
                              onPressed: _finishHomework,
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                              icon: const Icon(Icons.check_circle_rounded, size: 18),
                              label: const Text('Submit Homework', style: TextStyle(fontWeight: FontWeight.bold)),
                            )
                          : ElevatedButton.icon(
                              onPressed: () => _goToHomeworkQuestion(_currentQuestionIndex + 1),
                              style: ElevatedButton.styleFrom(backgroundColor: _kMustardYellow, foregroundColor: _kNavyDark, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _kNavyDark, width: 1.2))),
                              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                              label: const Text('Next', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // MODE KUIS GAMIFIKASI LIVE: pakai timer & reveal benar/salah
  // ============================================================
  Widget _buildLiveQuizScaffold() {
    final currentQ = _questions[_currentQuestionIndex];
    final qType = currentQ['type'] ?? 'multiple_choice';
    final options = (currentQ['options'] as List?) ?? ['Opsi A', 'Opsi B'];
    // FITUR "Gambar di Jawaban PG" (poin 5): gambar opsional per-opsi
    // jawaban, sejajar index dengan `options`.
    final optionImages = (currentQ['option_images'] as List?) ?? options.map((_) => null).toList();
    final imageUrl = currentQ['image_url'];
    final timerSec = _remainingSeconds;
    final isTimeCritical = timerSec <= 5;
    final List correctList = (currentQ['correct_list'] as List?) ?? [];

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        title: Text('Kuis Gamifikasi: ${widget.session['title'] ?? 'Live Game'}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        backgroundColor: _kCreamBg,
        foregroundColor: _kNavyDark,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(16), border: Border.all(color: _kNavyDark, width: 1.2)),
                child: Text('🔥 Streak: $_streak x | $_score Pts', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13)),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                width: 540,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: _kNavyDark, width: 2), boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)]),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: _kQuizizzPastelBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                          child: Text('Soal ${_currentQuestionIndex + 1} dari ${_questions.length}', style: const TextStyle(fontWeight: FontWeight.bold, color: _kQuizizzTextColor)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isTimeCritical ? const Color(0xFFFECACA) : const Color(0xFFBAE6FD),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _kNavyDark, width: 1),
                      ),
                      child: Text(
                        '⏱️ $timerSec s',
                        style: TextStyle(fontWeight: FontWeight.w900, color: isTimeCritical ? const Color(0xFFDC2626) : const Color(0xFF0284C7), fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // IMAGES IF PROVIDED (URL / FILE UPLOAD BASE64)
                if (imageUrl != null && imageUrl.toString().isNotEmpty) ...[
                  _buildQuestionImageWidget(imageUrl.toString()),
                  const SizedBox(height: 14),
                ],

                Text(currentQ['question'] ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _kNavyDark)),
                const SizedBox(height: 16),
                const Divider(color: _kNavyDark, height: 1),
                const SizedBox(height: 16),

                // MULTIPLE CHOICE / TRUE FALSE OPTIONS — TIDAK dikunci,
                // mahasiswa bebas berganti pilihan selama timer belum habis.
                if (qType == 'multiple_choice' || qType == 'true_false')
                  ...options.asMap().entries.map((entry) {
                    final optIdx = entry.key;
                    final optStr = entry.value.toString();
                    final isSelected = _selectedSingleOption == optStr;
                    final rawCorrect = currentQ['correct']?.toString().trim().toUpperCase() ?? '';
                    // FITUR "Perbaikan Bug PG Disalahkan" (poin 6): kalau
                    // correct ternyata huruf opsi (A/B/C/D), cocokkan lewat
                    // posisi opsi juga, bukan cuma perbandingan teks
                    // langsung, supaya highlight opsi benar tetap akurat.
                    final isCorrect = optStr.trim().toUpperCase() == rawCorrect ||
                        (RegExp(r'^[A-D]$').hasMatch(rawCorrect) && 'ABCD'.indexOf(rawCorrect) == optIdx);

                    Color bg = _kCreamBg;
                    if (isSelected && !_answered) bg = const Color(0xFFFDE68A);
                    if (_answered) {
                      if (isCorrect) bg = const Color(0xFFA7F3D0);
                      if (isSelected && !isCorrect) bg = const Color(0xFFFBCFE8);
                    }

                    return Container(
                      key: ValueKey('opt_${_currentQuestionIndex}_$optStr'),
                      margin: const EdgeInsets.only(bottom: 10),
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _answered ? null : () => _chooseSingleOption(optStr),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: bg,
                          padding: const EdgeInsets.all(16),
                          side: const BorderSide(color: _kNavyDark, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(optStr, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark)),
                            // FITUR "Gambar di Jawaban PG" (poin 5).
                            if (optionImages.length > optIdx && optionImages[optIdx] != null && optionImages[optIdx].toString().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              SizedBox(height: 130, width: double.infinity, child: _buildQuestionImageWidget(optionImages[optIdx].toString())),
                            ],
                          ],
                        ),
                      ),
                    );
                  })

                // MULTI SELECT OPTIONS (CHECKBOXES) — TIDAK dikunci, mahasiswa
                // bebas centang/hapus centang selama timer belum habis.
                else if (qType == 'multi_select') ...[
                  const Text('Pilihlah seluruh jawaban yang benar (Centang Banyak):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(height: 10),
                  ...options.asMap().entries.map((entry) {
                    final optIdx = entry.key;
                    final optStr = entry.value.toString();
                    final isChecked = _selectedMultiOptions.contains(optStr);
                    final isCorrectOpt = correctList.map((e) => e.toString().trim().toUpperCase()).contains(optStr.trim().toUpperCase());

                    Color bg = isChecked ? _kMustardYellow : _kCreamBg;
                    if (_answered) {
                      if (isCorrectOpt) bg = const Color(0xFFA7F3D0);
                      if (isChecked && !isCorrectOpt) bg = const Color(0xFFFBCFE8);
                    }

                    return Container(
                      key: ValueKey('opt_${_currentQuestionIndex}_$optStr'),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.2)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CheckboxListTile(
                            value: isChecked,
                            title: Text(optStr, style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
                            activeColor: _kNavyDark,
                            onChanged: _answered ? null : (_) => _toggleMultiOption(optStr),
                          ),
                          // FITUR "Gambar di Jawaban PG" (poin 5).
                          if (optionImages.length > optIdx && optionImages[optIdx] != null && optionImages[optIdx].toString().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: SizedBox(height: 130, width: double.infinity, child: _buildQuestionImageWidget(optionImages[optIdx].toString())),
                            ),
                        ],
                      ),
                    );
                  }),
                ]

                // JAWABAN SINGKAT — mahasiswa mengetik jawaban bebas, terkunci
                // begitu timer habis / _answered true seperti tipe lainnya.
                else if (qType == 'short_answer') ...[
                  const Text('Ketik jawaban Anda:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(height: 10),
                  TextFormField(
                    key: ValueKey('short_answer_live_$_currentQuestionIndex'),
                    enabled: !_answered,
                    initialValue: _selectedSingleOption,
                    onChanged: (val) => _chooseSingleOption(val),
                    decoration: InputDecoration(
                      hintText: 'Jawaban Anda...',
                      filled: true,
                      fillColor: _answered ? const Color(0xFFA7F3D0) : _kCreamBg,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _kNavyDark, width: 1.2)),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
          // Banner streak (muncul 5 detik setiap 3 jawaban benar berturut-turut).
          if (_showStreakBonusBanner)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.45),
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.7, end: 1.0),
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.elasticOut,
                    builder: (ctx, scale, child) => Transform.scale(scale: scale, child: child),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
                      decoration: BoxDecoration(
                        color: _kMustardYellow,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: _kNavyDark, width: 3),
                        boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(6, 6), blurRadius: 0)],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('🔥🔥🔥', style: TextStyle(fontSize: 40)),
                          const SizedBox(height: 10),
                          Text('STREAK $_streak x BERTURUT-TURUT!', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: _kNavyDark), textAlign: TextAlign.center),
                          const SizedBox(height: 6),
                          Text('+$_lastStreakBonusValue Bonus Poin! 🎉', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF16A34A))),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}