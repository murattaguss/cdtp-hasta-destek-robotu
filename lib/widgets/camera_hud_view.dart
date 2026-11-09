import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/telemetry_data.dart';
import '../models/vision_data.dart';

// canlı kamera görüntüsünü ve gerçek esp32 durum bilgisini gösteren vizör bileşeni
class CameraVisionHudView extends StatelessWidget {
  final VisionFrameResult vision;
  final RobotTelemetry telemetry;
  final bool isRobotConnected;
  final bool isRecording;
  final String elapsedFormatted;
  final CameraController? cameraController;
  final bool isUsingRealCamera;
  final VoidCallback? onToggleCameraMode;
  final VoidCallback? onOpenFullscreen;
  final bool isFullscreen;

  const CameraVisionHudView({
    super.key,
    required this.vision,
    required this.telemetry,
    required this.isRobotConnected,
    required this.isRecording,
    required this.elapsedFormatted,
    this.cameraController,
    this.isUsingRealCamera = false,
    this.onToggleCameraMode,
    this.onOpenFullscreen,
    this.isFullscreen = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool cameraReady = isUsingRealCamera &&
        cameraController != null &&
        cameraController!.value.isInitialized;

    final String boxBadgeText = !isRobotConnected
        ? 'Robot: Bekleniyor'
        : (vision.medicineBoxPresent ? 'Kutu: Sabit' : 'Kutu: Düştü');

    final Color boxBadgeColor = !isRobotConnected
        ? const Color(0xBF1C1C1E)
        : (vision.medicineBoxPresent
            ? const Color(0xBF1C1C1E)
            : const Color(0xE6FF2D55));

    return Container(
      height: isFullscreen ? null : 245,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(isFullscreen ? 0 : 16),
        border: isFullscreen
            ? null
            : Border.all(
                color: isRecording ? const Color(0xFFFF2D55) : const Color(0xFFE5E5EA),
                width: isRecording ? 1.5 : 1.0,
              ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (cameraReady)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: cameraController!.value.previewSize?.height ?? 320,
                height: cameraController!.value.previewSize?.width ?? 240,
                child: CameraPreview(cameraController!),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.videocam_off_outlined,
                      color: Color(0xFF8E8E93),
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Kamera Kapalı',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'Canlı görüntü için sol üstten Kamerayı Aç\'a dokunun',
                    style: TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),

          CustomPaint(
            painter: _ViewfinderCornerPainter(),
          ),

          // kamera kare farkı tespiti: hareketli bölgenin merkezi
          if (cameraReady && vision.camera.motionDetected)
            LayoutBuilder(
              builder: (context, box) => Stack(
                children: [
                  Positioned(
                    left: vision.camera.centroidX * box.maxWidth - 14,
                    top: vision.camera.centroidY * box.maxHeight - 14,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF34C759), width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // kameradan tespit edilen hareket ve yön
          if (cameraReady)
            Positioned(
              top: 42,
              left: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: vision.camera.motionDetected
                      ? const Color(0xD9248A3D)
                      : const Color(0xBF1C1C1E),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  'Kamera: ${vision.camera.summary}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () {
                    if (onToggleCameraMode != null) {
                      HapticFeedback.selectionClick();
                      onToggleCameraMode!();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: cameraReady
                          ? const Color(0xE6FF2D55)
                          : const Color(0xBF1C1C1E),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isRecording)
                          const _PulsingRecordDot()
                        else
                          Icon(
                            cameraReady
                                ? Icons.videocam_rounded
                                : Icons.camera_alt_outlined,
                            size: 13.5,
                            color: Colors.white,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          isRecording
                              ? 'KAYIT  $elapsedFormatted'
                              : (cameraReady ? 'Kamera Açık' : 'Kamerayı Aç'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: boxBadgeColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        boxBadgeText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onOpenFullscreen != null) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onOpenFullscreen!();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: const Color(0xBF1C1C1E),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            isFullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // alt şerit: robottan gelen gerçek enkoder mesafesi, eldiven komutu, eğim ve şarj durumu
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: const Color(0xD91C1C1E),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildInlineStat(
                    'Mesafe',
                    isRobotConnected
                        ? '${vision.distanceTraveledMeters.toStringAsFixed(2).replaceAll('.', ',')} m'
                        : '0,00 m',
                  ),
                  _buildInlineStat(
                    'Komut',
                    isRobotConnected ? telemetry.lastGloveCommand.label : '-',
                  ),
                  _buildInlineStat(
                    'Eğim',
                    isRobotConnected
                        ? '${telemetry.pitchAngleDeg.toStringAsFixed(1).replaceAll('.', ',')}°'
                        : '--',
                  ),
                  _buildInlineStat(
                    'Şarj',
                    !isRobotConnected
                        ? '--'
                        : (telemetry.isCharging ? 'Şarj oluyor' : '%${telemetry.batteryPercent}'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineStat(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: const TextStyle(
            color: Color(0xFFAEAEB2),
            fontSize: 11,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _PulsingRecordDot extends StatefulWidget {
  const _PulsingRecordDot();

  @override
  State<_PulsingRecordDot> createState() => _PulsingRecordDotState();
}

class _PulsingRecordDotState extends State<_PulsingRecordDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_controller),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _ViewfinderCornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    const double pad = 16;
    const double topPad = 44;
    const double bottomPad = 42;
    const double len = 14;

    canvas.drawPath(
      Path()
        ..moveTo(pad, topPad + len)
        ..lineTo(pad, topPad)
        ..lineTo(pad + len, topPad),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width - pad - len, topPad)
        ..lineTo(size.width - pad, topPad)
        ..lineTo(size.width - pad, topPad + len),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(pad, size.height - bottomPad - len)
        ..lineTo(pad, size.height - bottomPad)
        ..lineTo(pad + len, size.height - bottomPad),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width - pad - len, size.height - bottomPad)
        ..lineTo(size.width - pad, size.height - bottomPad)
        ..lineTo(size.width - pad, size.height - bottomPad - len),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant _ViewfinderCornerPainter oldDelegate) => false;
}
