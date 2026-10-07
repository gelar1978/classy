import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart';

class ApiService {
  static String get baseUrl {
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host != 'localhost' && host != '127.0.0.1' && host.isNotEmpty) {
        return '${Uri.base.origin}/api';
      }
    }
    return 'http://localhost:3100/api';
  }

  static String get serverBaseUrl {
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host != 'localhost' && host != '127.0.0.1' && host.isNotEmpty) {
        return Uri.base.origin;
      }
    }
    return 'http://localhost:3100';
  }

  static String? getFullMediaUrl(dynamic path) {
    if (path == null) return null;
    final str = path.toString().trim();
    if (str.isEmpty) return null;
    if (str.startsWith('http://') || str.startsWith('https://')) return str;
    final cleanPath = str.startsWith('/') ? str : '/$str';
    return '$serverBaseUrl$cleanPath';
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('token');
  }

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
  }

  static Future<Map<String, String>> _headers({bool withAuth = true}) async {
    final headers = {'Content-Type': 'application/json'};
    if (withAuth) {
      final token = await getToken();
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  static Future<Map<String, dynamic>> get(String endpoint, {bool withAuth = true}) async {
    final headers = await _headers(withAuth: withAuth);
    final response = await http.get(Uri.parse('$baseUrl$endpoint'), headers: headers);
    return _handleResponse(response);
  }

  static Future<Map<String, dynamic>> post(String endpoint, Map<String, dynamic> body, {bool withAuth = true}) async {
    final headers = await _headers(withAuth: withAuth);
    final response = await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
      body: jsonEncode(body),
    );
    return _handleResponse(response);
  }

  static Future<Map<String, dynamic>> patch(String endpoint, Map<String, dynamic> body, {bool withAuth = true}) async {
    final headers = await _headers(withAuth: withAuth);
    final response = await http.patch(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
      body: jsonEncode(body),
    );
    return _handleResponse(response);
  }

  static Future<Map<String, dynamic>> put(String endpoint, Map<String, dynamic> body, {bool withAuth = true}) async {
    final headers = await _headers(withAuth: withAuth);
    final response = await http.put(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
      body: jsonEncode(body),
    );
    return _handleResponse(response);
  }

  static Future<Map<String, dynamic>> delete(String endpoint, {bool withAuth = true}) async {
    final headers = await _headers(withAuth: withAuth);
    final response = await http.delete(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
    );
    return _handleResponse(response);
  }

  static Future<Map<String, dynamic>> postFile(
    String endpoint,
    List<int> fileBytes,
    String filename, {
    bool withAuth = true,
    Map<String, String>? fields,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl$endpoint'));
    if (withAuth) {
      final token = await getToken();
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
    }
    if (fields != null) {
      request.fields.addAll(fields);
    }
    request.files.add(http.MultipartFile.fromBytes('file', fileBytes, filename: filename));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    return _handleResponse(response);
  }

  static Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.body.trim().startsWith('<')) {
      throw Exception('Layanan backend (HTTP ${response.statusCode}) tidak merespons JSON. Pastikan server Node.js sudah di-restart.');
    }
    final decoded = jsonDecode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      // Jika response body adalah List, bungkus dalam Map dengan key 'data'
      if (decoded is List) {
        return {'data': decoded};
      }
      return decoded is Map<String, dynamic> ? decoded : {};
    } else {
      String errorMsg = 'Terjadi kesalahan (${response.statusCode})';
      if (decoded is Map && decoded.containsKey('message')) {
        errorMsg = decoded['message'];
      } else if (decoded is Map && decoded.containsKey('error')) {
        errorMsg = decoded['error'];
      }
      throw Exception(errorMsg);
    }
  }
}
