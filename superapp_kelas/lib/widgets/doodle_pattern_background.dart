import 'dart:math' as math;
import 'package:flutter/material.dart';

// ----------------------------------------------------------------------
// PATTERN DEKORATIF "DOODLE EDUKASI" — meniru gaya gambar referensi yang
// dikirim (ikon coretan tangan bertema sekolah: roket, robot, bola, buku,
// lampu ide, bintang, awan, not musik, dll., tersebar & sedikit dirotasi).
// Dipakai sebagai lapisan latar belakang HALUS (opasitas rendah) di
// belakang konten utama, bukan pengganti isi halaman.
// ----------------------------------------------------------------------
class DoodlePatternBackground extends StatelessWidget {
  final Color color;
  final double opacity;
  final double iconSize;
  final double spacing;

  const DoodlePatternBackground({
    super.key,
    this.color = const Color(0xFF001D39),
    this.opacity = 0.055,
    this.iconSize = 30,
    this.spacing = 78,
  });

  static const List<IconData> _icons = [
    Icons.rocket_launch_outlined,
    Icons.smart_toy_outlined,
    Icons.sports_soccer,
    Icons.menu_book_outlined,
    Icons.lightbulb_outline,
    Icons.star_border_rounded,
    Icons.cloud_outlined,
    Icons.music_note_outlined,
    Icons.chat_bubble_outline_rounded,
    Icons.school_outlined,
    Icons.public,
    Icons.favorite_border_rounded,
    Icons.smartphone_outlined,
    Icons.auto_awesome_outlined,
    Icons.emoji_events_outlined,
    Icons.science_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: ClipRect(
          child: CustomPaint(
            painter: _DoodlePatternPainter(color: color, iconSize: iconSize, spacing: spacing),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _DoodlePatternPainter extends CustomPainter {
  final Color color;
  final double iconSize;
  final double spacing;

  _DoodlePatternPainter({required this.color, required this.iconSize, required this.spacing});

  @override
  void paint(Canvas canvas, Size size) {
    final cols = (size.width / spacing).ceil() + 1;
    final rows = (size.height / spacing).ceil() + 1;
    var index = 0;

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final icon = DoodlePatternBackground._icons[index % DoodlePatternBackground._icons.length];
        // Offset & rotasi semu-acak tapi DETERMINISTIK (berdasarkan index),
        // supaya pola tetap sama tiap kali di-render ulang (tidak "kedip"
        // berubah posisi saat rebuild), meniru sebaran doodle yang natural.
        final jitterX = (index * 37 % 23) - 11.0;
        final jitterY = (index * 53 % 19) - 9.0;
        final rotation = ((index * 29 % 40) - 20) * math.pi / 180;

        final dx = col * spacing + (row.isOdd ? spacing / 2 : 0) + jitterX;
        final dy = row * spacing + jitterY;

        final textPainter = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
              fontSize: iconSize,
              fontFamily: icon.fontFamily,
              package: icon.fontPackage,
              color: color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        canvas.save();
        canvas.translate(dx, dy);
        canvas.rotate(rotation);
        textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
        canvas.restore();

        index++;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DoodlePatternPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.iconSize != iconSize || oldDelegate.spacing != spacing;
}