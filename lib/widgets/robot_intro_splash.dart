import 'dart:math';
import 'package:flutter/material.dart';

// Uygulama açıldığında iki tekerlekli denge robotunun ön sepetinde Parol kutusuyla
// soldan sağa doğru ilerlediği karşılama animasyonu bileşeni.
class RobotIntroSplash extends StatefulWidget {
  final VoidCallback onFinished;

  const RobotIntroSplash({
    super.key,
    required this.onFinished,
  });

  @override
  State<RobotIntroSplash> createState() => _RobotIntroSplashState();
}

class _RobotIntroSplashState extends State<RobotIntroSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _driveProgress;
  late final Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2700),
    );

    // Animasyonun ilk %86'lık kısmında robot soldan sağa doğru sürülür
    _driveProgress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.86, curve: Curves.easeInOutCubic),
    );

    // Son kısımda ekran yumuşakça kaybolup ana izleme ekranına geçer
    _fadeOut = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.84, 1.0, curve: Curves.easeOut),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onFinished();
      }
    });

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Kullanıcı beklemek istemezse ekrana dokunarak animasyonu doğrudan geçebilir
    return GestureDetector(
      onTap: widget.onFinished,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Opacity(
            opacity: (1.0 - _fadeOut.value).clamp(0.0, 1.0),
            child: Scaffold(
              backgroundColor: const Color(0xFFF2F2F7),
              body: SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(flex: 3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFEBEF),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.favorite_rounded,
                            color: Color(0xFFFF2D55),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'HDRG100',
                          style: TextStyle(
                            color: Color(0xFF1C1C1E),
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Ev İçi İlaç Taşıma ve Hasta Destek Robotu',
                      style: TextStyle(
                        color: Color(0xFF8E8E93),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 36),
                    SizedBox(
                      height: 190,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _RobotParolDrivePainter(
                          progress: _driveProgress.value,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 64),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          height: 5,
                          child: LinearProgressIndicator(
                            value: _driveProgress.value,
                            backgroundColor: const Color(0xFFE5E5EA),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFFFF2D55),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'İlaç sepeti kontrol ediliyor...',
                      style: TextStyle(
                        color: Color(0xFF8E8E93),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(flex: 4),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// Robotun tekerlek dönüşünü, denge eğimini ve sepetteki Parol kutusunu çizen sınıf
class _RobotParolDrivePainter extends CustomPainter {
  final double progress;

  _RobotParolDrivePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final double floorY = size.height * 0.84;

    // Zemin çizgisi
    final Paint floorPaint = Paint()
      ..color = const Color(0xFFD1D1D6)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(24, floorY),
      Offset(size.width - 24, floorY),
      floorPaint,
    );

    // Robotun soldan (-70 px) sağa (ekran dışına) ilerleme konumu
    const double startX = -70.0;
    final double endX = size.width + 70.0;
    final double robotX = startX + (endX - startX) * progress;

    // Robotun geçtiği yerde bıraktığı pembe iz çizgisi
    if (robotX > 30) {
      final Paint trailPaint = Paint()
        ..color = const Color(0xFFFF2D55).withValues(alpha: 0.25)
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(24, floorY),
        Offset(robotX.clamp(24.0, size.width - 24.0), floorY),
        trailPaint,
      );
    }

    // Denge robotu hızlanırken hafif öne eğilir, sabit hızda doğrulur
    final double velocityFactor = sin(progress * pi);
    final double pitchRadians =
        (velocityFactor * 0.11) + sin(progress * pi * 6) * 0.025;
    final double bounceY = sin(progress * pi * 10).abs() * 2.5;

    // Robotun altındaki zemin gölgesi
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(robotX + 8, floorY + 2),
        width: 84,
        height: 10,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.08),
    );

    canvas.save();
    canvas.translate(robotX, floorY - 22 - bounceY);
    canvas.rotate(pitchRadians);

    // Robotun beyaz ana gövdesi
    final RRect bodyRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: const Offset(0, -38), width: 64, height: 82),
      const Radius.circular(20),
    );
    canvas.drawRRect(
      bodyRRect,
      Paint()..color = Colors.white,
    );
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = const Color(0xFFD1D1D6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Kafa kısmındaki siyah ekran ve sağa bakan gözler
    final RRect visorRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: const Offset(4, -56), width: 46, height: 28),
      const Radius.circular(13),
    );
    canvas.drawRRect(
      visorRRect,
      Paint()..color = const Color(0xFF1C1C1E),
    );

    canvas.drawOval(
      Rect.fromCenter(center: const Offset(-4, -56), width: 6.5, height: 10),
      Paint()..color = Colors.white,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(14, -56), width: 6.5, height: 10),
      Paint()..color = Colors.white,
    );

    // Göğüs kısmındaki pembe kalp (hareket sırasında hafifçe büyüyüp küçülür)
    final double heartScale = 1.0 + 0.08 * sin(progress * pi * 8);
    canvas.save();
    canvas.translate(0, -24);
    canvas.scale(heartScale);
    _drawPinkHeart(canvas, Offset.zero, 20);
    canvas.restore();

    // Ön sepet bağlantı kolu
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(24, -22, 14, 6),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFFAEAEB2),
    );

    // Sepetin içindeki Parol ilaç kutusu
    canvas.save();
    canvas.translate(50, -31);
    canvas.rotate(-0.06);

    final RRect parolBox = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 38, height: 24),
      const Radius.circular(4),
    );
    canvas.drawRRect(parolBox, Paint()..color = Colors.white);
    canvas.drawRRect(
      parolBox,
      Paint()
        ..color = const Color(0xFFD1D1D6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Parol kutusunun mavi ve kırmızı şeritleri
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        const Rect.fromLTWH(-19, -12, 38, 6),
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFF0055A5),
    );
    canvas.drawRect(
      const Rect.fromLTWH(-19, -6, 38, 3),
      Paint()..color = const Color(0xFFE3004F),
    );

    final TextPainter parolTp = TextPainter(
      text: const TextSpan(
        text: 'PAROL',
        style: TextStyle(
          color: Color(0xFF0055A5),
          fontSize: 8.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    parolTp.paint(canvas, Offset(-parolTp.width / 2, -1.5));

    canvas.restore();

    // İlaç kutusunu tutan ön sepet çerçevesi
    final RRect basketTray = RRect.fromRectAndRadius(
      const Rect.fromLTWH(28, -24, 44, 15),
      const Radius.circular(5),
    );
    canvas.drawRRect(
      basketTray,
      Paint()..color = const Color(0xFFF2F2F7).withValues(alpha: 0.72),
    );
    canvas.drawRRect(
      basketTray,
      Paint()
        ..color = const Color(0xFFFF2D55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );

    final Paint basketGridPaint = Paint()
      ..color = const Color(0xFFFF2D55).withValues(alpha: 0.45)
      ..strokeWidth = 1.2;
    canvas.drawLine(const Offset(39, -24), const Offset(39, -9), basketGridPaint);
    canvas.drawLine(const Offset(50, -24), const Offset(50, -9), basketGridPaint);
    canvas.drawLine(const Offset(61, -24), const Offset(61, -9), basketGridPaint);

    // İlerledikçe dönen tekerlek
    final double wheelRotation = progress * pi * 5.0;
    _drawSpinningWheel(canvas, const Offset(0, 0), 22.0, wheelRotation);

    canvas.restore();
  }

  void _drawSpinningWheel(
    Canvas canvas,
    Offset center,
    double radius,
    double angle,
  ) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()..color = const Color(0xFF2C2C2E),
    );
    canvas.drawCircle(
      Offset.zero,
      radius * 0.65,
      Paint()..color = const Color(0xFFE5E5EA),
    );

    final Paint spokePaint = Paint()
      ..color = const Color(0xFF8E8E93)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 4; i++) {
      final double a = i * (pi / 2);
      canvas.drawLine(
        Offset(cos(a) * (-radius * 0.58), sin(a) * (-radius * 0.58)),
        Offset(cos(a) * (radius * 0.58), sin(a) * (radius * 0.58)),
        spokePaint,
      );
    }

    canvas.drawCircle(
      Offset.zero,
      5.5,
      Paint()..color = const Color(0xFFFF2D55),
    );
    canvas.restore();
  }

  void _drawPinkHeart(Canvas canvas, Offset center, double width) {
    final double w = width;
    final double h = width * 0.92;
    final Path heartPath = Path();
    heartPath.moveTo(center.dx, center.dy + h * 0.45);
    heartPath.cubicTo(
      center.dx - w * 0.65,
      center.dy + h * 0.05,
      center.dx - w * 0.55,
      center.dy - h * 0.48,
      center.dx,
      center.dy - h * 0.16,
    );
    heartPath.cubicTo(
      center.dx + w * 0.55,
      center.dy - h * 0.48,
      center.dx + w * 0.65,
      center.dy + h * 0.05,
      center.dx,
      center.dy + h * 0.45,
    );
    heartPath.close();

    canvas.drawPath(
      heartPath,
      Paint()
        ..color = const Color(0xFFFF2D55)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _RobotParolDrivePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
