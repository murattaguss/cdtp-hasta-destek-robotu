import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/telemetry_data.dart';
import '../models/test_task.dart';
import '../models/vision_data.dart';
import '../services/task_evaluator.dart';
import '../services/telemetry_service.dart';
import '../widgets/camera_hud_view.dart';

// canlı izleme ekranı: görev seçimi, kamera vizörü, 2x2 gerçek telemetri
// kartları (şarj, eğim, süre, hareket) ve testi başlat/bitir butonunu içerir.
class LiveMonitorScreen extends StatefulWidget {
  final RobotSystemController robotController;
  final TaskEvaluatorService evaluator;

  const LiveMonitorScreen({
    super.key,
    required this.robotController,
    required this.evaluator,
  });

  @override
  State<LiveMonitorScreen> createState() => _LiveMonitorScreenState();
}

class _LiveMonitorScreenState extends State<LiveMonitorScreen> {
  RobotSystemController get robotController => widget.robotController;
  TaskEvaluatorService get evaluator => widget.evaluator;

  void _handleTestButtonPressed(BuildContext context) {
    HapticFeedback.mediumImpact();
    if (evaluator.isTestRunning) {
      evaluator.finishTest();
      return;
    }

    if (!robotController.isRobotConnected) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            content: const Text(
              'Robot bağlı değil. Testi başlatmak için önce telefonunuzdan HDRG100-Robot Wi-Fi ağına bağlanın.',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      return;
    }

    evaluator.startTest();
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = robotController.latestTelemetry;
    final vision = robotController.latestVision;
    final lastReport = evaluator.lastCompletedReport;
    final bool isConnected = robotController.isRobotConnected;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTaskSelectorCard(),
          const SizedBox(height: 10),
          CameraVisionHudView(
            vision: vision,
            telemetry: telemetry,
            isRobotConnected: isConnected,
            isRecording: evaluator.isTestRunning,
            elapsedFormatted: evaluator.formattedElapsedTime,
            cameraController: robotController.cameraController,
            isUsingRealCamera: robotController.isUsingRealCamera,
            onToggleCameraMode: robotController.toggleRealCameraMode,
            onOpenFullscreen: () => _openFullscreenCameraDialog(context),
          ),
          const SizedBox(height: 10),
          _buildTelemetryGrid(telemetry, vision, isConnected),
          const SizedBox(height: 10),
          _buildActionAndVerdictSection(context, lastReport, isConnected),
        ],
      ),
    );
  }

  // çdtp şartnamesindeki 4 ana değerlendirme görevini seçtiğimiz üst kart
  Widget _buildTaskSelectorCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 4.8,
            children: TaskType.values.map((task) {
              final selected = task == evaluator.selectedTask;
              return InkWell(
                onTap: evaluator.isTestRunning
                    ? null
                    : () {
                        if (!selected) {
                          HapticFeedback.selectionClick();
                          evaluator.selectTask(task);
                        }
                      },
                borderRadius: BorderRadius.circular(10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFFFF2D55) : const Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? const Color(0xFFFF2D55) : const Color(0xFFE5E5EA),
                    ),
                  ),
                  child: Text(
                    task.title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : const Color(0xFF1C1C1E),
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          if (evaluator.selectedTask == TaskType.integratedMission)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    evaluator.isTestRunning
                        ? '${evaluator.integratedPhase.label}'
                            '${evaluator.integratedPhase == IntegratedPhase.targetHold5s ? " (${evaluator.targetHoldSeconds.toStringAsFixed(1)} sn)" : ""}'
                        : evaluator.selectedTask.metricSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFF2D55),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEF),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Tur ${evaluator.integratedRunCounter}/4',
                    style: const TextStyle(
                      color: Color(0xFFFF2D55),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            )
          else
            Text(
              evaluator.selectedTask.metricSummary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF8E8E93),
                fontSize: 11.5,
              ),
            ),
        ],
      ),
    );
  }

  // şarj yüzdesi, gövde eğimi, geçen süre ve hareket durumunu gösteren 2x2 özet kartları
  Widget _buildTelemetryGrid(
    RobotTelemetry telemetry,
    VisionFrameResult vision,
    bool isConnected,
  ) {
    final directionLabel = (!isConnected || vision.movementDirection == MovementDirection.none)
        ? ''
        : ' · ${vision.movementDirection.label}';

    final double batteryProgress =
        isConnected ? (telemetry.batteryPercent / 100.0).clamp(0.0, 1.0) : 0.0;
    final double timeProgress =
        (evaluator.elapsedSeconds / evaluator.selectedTask.targetDurationSec).clamp(0.0, 1.0);
    final double distanceProgress =
        isConnected ? (vision.distanceTraveledMeters / 1.0).clamp(0.0, 1.0) : 0.0;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                icon: Icons.bolt_rounded,
                accentColor: const Color(0xFF34C759),
                label: 'Şarj',
                value: isConnected ? '%${telemetry.batteryPercent}' : '--',
                footnote: !isConnected
                    ? 'Robot bağlı değil'
                    : (telemetry.isCharging
                        ? 'Şarj oluyor'
                        : (telemetry.isDocked ? 'İstasyonda (şarj yok)' : 'Bataryada')),
                footnoteHighlight: isConnected && telemetry.isCharging,
                indicator: _buildSlimProgressBar(
                  progress: batteryProgress,
                  activeColor: const Color(0xFF34C759),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                icon: Icons.explore_outlined,
                accentColor: const Color(0xFF007AFF),
                label: 'Eğim',
                value: isConnected
                    ? '${telemetry.pitchAngleDeg.toStringAsFixed(1).replaceAll('.', ',')}°'
                    : '--',
                footnote: !isConnected
                    ? 'Veri bekleniyor'
                    : (vision.isDocked
                        ? 'İstasyonda'
                        : (telemetry.pitchAngleDeg.abs() < 5.0 ? 'Dengede' : 'Toparlanıyor')),
                indicator: _buildPitchBalanceBar(isConnected ? telemetry.pitchAngleDeg : 0.0),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                icon: Icons.timer_outlined,
                accentColor: const Color(0xFFFF9500),
                label: 'Süre',
                value: evaluator.formattedElapsedTime.substring(0, 5),
                footnote: 'Hedef: ${evaluator.selectedTask.targetDurationSec.toInt()} sn',
                indicator: _buildSlimProgressBar(
                  progress: timeProgress,
                  activeColor: const Color(0xFFFF9500),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                icon: Icons.favorite_rounded,
                accentColor: const Color(0xFFFF2D55),
                label: 'Hareket',
                value: isConnected ? vision.movementState.shortLabel : '--',
                footnote: isConnected
                    ? '${vision.distanceTraveledMeters.toStringAsFixed(2).replaceAll('.', ',')} m · '
                        '${vision.accumulatedRotationDeg.toStringAsFixed(0)}°$directionLabel'
                    : '0,00 m',
                indicator: _buildSlimProgressBar(
                  progress: distanceProgress,
                  activeColor: const Color(0xFFFF2D55),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required Color accentColor,
    required String label,
    required String value,
    required String footnote,
    bool footnoteHighlight = false,
    Widget? indicator,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: accentColor),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF1C1C1E),
              fontSize: 22,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            footnote,
            style: TextStyle(
              color: footnoteHighlight ? const Color(0xFF248A3D) : const Color(0xFF8E8E93),
              fontSize: 11,
              fontWeight: footnoteHighlight ? FontWeight.w600 : FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (indicator != null) ...[
            const SizedBox(height: 6),
            indicator,
          ],
        ],
      ),
    );
  }

  Widget _buildSlimProgressBar({
    required double progress,
    required Color activeColor,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 4,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: const Color(0xFFE5E5EA),
          valueColor: AlwaysStoppedAnimation<Color>(activeColor),
        ),
      ),
    );
  }

  Widget _buildPitchBalanceBar(double pitchDeg) {
    final double normalized = ((pitchDeg / 15.0) + 1.0) * 0.5;
    final double alignmentX = ((normalized.clamp(0.0, 1.0) * 2.0) - 1.0);
    final bool isStable = pitchDeg.abs() < 5.0;

    return SizedBox(
      height: 5,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE5E5EA),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          Container(
            width: 1.5,
            height: 5,
            color: const Color(0xFF8E8E93),
          ),
          AnimatedAlign(
            duration: const Duration(milliseconds: 120),
            alignment: Alignment(alignmentX, 0),
            child: Container(
              width: 18,
              height: 4,
              decoration: BoxDecoration(
                color: isStable ? const Color(0xFF007AFF) : const Color(0xFFFF2D55),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openFullscreenCameraDialog(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) {
          return AnimatedBuilder(
            animation: Listenable.merge([robotController, evaluator]),
            builder: (innerCtx, _) {
              final telemetry = robotController.latestTelemetry;
              final vision = robotController.latestVision;
              final isConnected = robotController.isRobotConnected;
              return Scaffold(
                backgroundColor: const Color(0xFF1C1C1E),
                body: SafeArea(
                  child: Column(
                    children: [
                      Expanded(
                        child: CameraVisionHudView(
                          vision: vision,
                          telemetry: telemetry,
                          isRobotConnected: isConnected,
                          isRecording: evaluator.isTestRunning,
                          elapsedFormatted: evaluator.formattedElapsedTime,
                          cameraController: robotController.cameraController,
                          isUsingRealCamera: robotController.isUsingRealCamera,
                          onToggleCameraMode: robotController.toggleRealCameraMode,
                          isFullscreen: true,
                          onOpenFullscreen: () => Navigator.of(ctx).pop(),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                        color: Colors.white,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isConnected
                                    ? '${evaluator.selectedTask.title} · Şarj %${telemetry.batteryPercent} · Eğim ${telemetry.pitchAngleDeg.toStringAsFixed(1)}°'
                                    : '${evaluator.selectedTask.title} · Robot bekleniyor',
                                style: const TextStyle(
                                  color: Color(0xFF1C1C1E),
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              onPressed: () => _handleTestButtonPressed(innerCtx),
                              style: FilledButton.styleFrom(
                                backgroundColor: evaluator.isTestRunning
                                    ? const Color(0xFF1C1C1E)
                                    : const Color(0xFFFF2D55),
                                foregroundColor: Colors.white,
                              ),
                              child: Text(
                                evaluator.isTestRunning ? 'Bitir' : 'Testi Başlat',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  // testi başlatıp bitiren ana buton ve son tamamlanan testin sonucunu gösteren kutu
  Widget _buildActionAndVerdictSection(
    BuildContext context,
    TestReport? lastReport,
    bool isConnected,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 46,
          child: FilledButton(
            onPressed: () => _handleTestButtonPressed(context),
            style: FilledButton.styleFrom(
              backgroundColor: evaluator.isTestRunning
                  ? const Color(0xFF1C1C1E)
                  : (isConnected ? const Color(0xFFFF2D55) : const Color(0xFF8E8E93)),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              evaluator.isTestRunning
                  ? 'Testi Bitir'
                  : (isConnected ? 'Testi Başlat' : 'Testi Başlat (Robot Bekleniyor)'),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: (!evaluator.isTestRunning && lastReport != null)
              ? Padding(
                  key: ValueKey(lastReport.reportId),
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    decoration: BoxDecoration(
                      color: lastReport.passed
                          ? const Color(0xFFE8F8ED)
                          : const Color(0xFFFDECEC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: lastReport.passed
                            ? const Color(0xFFB7E4C7)
                            : const Color(0xFFF5C2C7),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          lastReport.passed ? 'GEÇTİ' : 'KALDI',
                          style: TextStyle(
                            color: lastReport.passed
                                ? const Color(0xFF248A3D)
                                : const Color(0xFFD70015),
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          width: 1,
                          height: 20,
                          color: lastReport.passed
                              ? const Color(0xFFB7E4C7)
                              : const Color(0xFFF5C2C7),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            lastReport.evaluationSummary,
                            style: const TextStyle(
                              color: Color(0xFF1C1C1E),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
