import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

class QrScannerHelper {
  /// Membuka kamera web scanner
  static Future<String?> scanQr() async {
    if (kIsWeb) {
      final completer = Completer<String?>();
      try {
        js.context.callMethod('startQrScanner', [
          (dynamic result) {
            if (!completer.isCompleted) {
              completer.complete(result?.toString());
            }
          }
        ]);
      } catch (e) {
        debugPrint('Error opening QR scanner: $e');
        completer.complete(null);
      }
      return completer.future;
    }
    return null;
  }

  /// Memilih file gambar QR langsung dari penyimpanan / galeri
  static Future<String?> scanQrFromFile() async {
    if (kIsWeb) {
      final completer = Completer<String?>();
      try {
        js.context.callMethod('scanQrFromFile', [
          (dynamic result) {
            if (!completer.isCompleted) {
              completer.complete(result?.toString());
            }
          }
        ]);
      } catch (e) {
        debugPrint('Error scanning QR from file: $e');
        completer.complete(null);
      }
      return completer.future;
    }
    return null;
  }

  /// Membuka dialog selfie webcam untuk capture foto profil close-up
  static Future<Uint8List?> captureSelfiePhoto() async {
    if (kIsWeb) {
      final completer = Completer<Uint8List?>();
      try {
        js.context.callMethod('captureSelfiePhoto', [
          (dynamic dataUrl) {
            if (!completer.isCompleted) {
              if (dataUrl != null && dataUrl.toString().startsWith('data:image')) {
                final base64Str = dataUrl.toString().split(',').last;
                final bytes = base64Decode(base64Str);
                completer.complete(bytes);
              } else {
                completer.complete(null);
              }
            }
          }
        ]);
      } catch (e) {
        debugPrint('Error capturing selfie photo: $e');
        completer.complete(null);
      }
      return completer.future;
    }
    return null;
  }

  /// Memulai Speech-to-Text (Rekam Suara ke Teks Bahasa Indonesia)
  static bool startSpeechToText({
    required Function(String text) onResult,
    required VoidCallback onEnd,
  }) {
    if (kIsWeb) {
      try {
        final ok = js.context.callMethod('startSpeechRecognition', [
          (dynamic text) {
            if (text != null) {
              onResult(text.toString());
            }
          },
          () {
            onEnd();
          }
        ]);
        return ok == true;
      } catch (e) {
        debugPrint('Error starting speech recognition: $e');
        onEnd();
        return false;
      }
    }
    onEnd();
    return false;
  }

  /// Menghentikan Speech-to-Text
  static void stopSpeechToText() {
    if (kIsWeb) {
      try {
        js.context.callMethod('stopSpeechRecognition', []);
      } catch (e) {
        debugPrint('Error stopping speech recognition: $e');
      }
    }
  }
}

