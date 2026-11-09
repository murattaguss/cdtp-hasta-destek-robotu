import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/test_task.dart';
import '../services/task_evaluator.dart';

// tamamlanan testlerin salt-okunur (değiştirilemez) olarak listelendiği ekran
class ImmutableReportsScreen extends StatelessWidget {
  final TaskEvaluatorService evaluator;

  const ImmutableReportsScreen({
    super.key,
    required this.evaluator,
  });

  @override
  Widget build(BuildContext context) {
    final reports = evaluator.immutableReports;
    final passedCount = reports.where((r) => r.passed).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E5EA)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Test Kayıtları',
                    style: TextStyle(
                      color: Color(0xFF1C1C1E),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${reports.length} kayıt · $passedCount başarılı',
                    style: const TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 13, color: Color(0xFFFF2D55)),
                    SizedBox(width: 5),
                    Text(
                      'Salt-Okunur',
                      style: TextStyle(
                        color: Color(0xFFFF2D55),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (reports.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE5E5EA)),
            ),
            child: const Column(
              children: [
                Icon(
                  Icons.assignment_outlined,
                  size: 34,
                  color: Color(0xFF8E8E93),
                ),
                SizedBox(height: 10),
                Text(
                  'Henüz tamamlanmış test kaydı yok',
                  style: TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Robot bağlandıktan sonra yapılan görev testlerinin sonuçları burada salt-okunur olarak listelenir.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF8E8E93),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          )
        else
          ...reports.map(
            (report) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildReportCard(context, report),
            ),
          ),
      ],
    );
  }

  Widget _buildReportCard(BuildContext context, TestReport report) {
    final bool passed = report.passed;
    final Color statusBg = passed ? const Color(0xFFE8F8ED) : const Color(0xFFFDECEC);
    final Color statusFg = passed ? const Color(0xFF248A3D) : const Color(0xFFD70015);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  report.taskType.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  passed ? 'GEÇTİ' : 'KALDI',
                  style: TextStyle(
                    color: statusFg,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            report.evaluationSummary,
            style: const TextStyle(
              color: Color(0xFF6C6C70),
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: Color(0xFFE5E5EA)),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _statCell('Süre', '${report.durationSeconds.toStringAsFixed(1)} sn'),
              _statCell(
                'Mesafe / Yön',
                '${report.measuredDistanceMeters.toStringAsFixed(2).replaceAll('.', ',')} m · ${report.detectedPrimaryDirection.label}',
              ),
              _statCell('Eğim', '${report.finalPitchDeg.toStringAsFixed(1)}°'),
              _statCell('Kutu', report.medicineBoxIntact ? 'Sabit' : 'Düştü'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _statCell('Dönüş', '${report.accumulatedRotationDeg.toStringAsFixed(0)}°'),
              _statCell(
                'En uzun tepki',
                report.maxCommandResponseSeconds == null
                    ? '-'
                    : '${report.maxCommandResponseSeconds!.toStringAsFixed(1)} sn',
              ),
              _statCell(
                'Şarj gecikmesi',
                report.chargingDelaySeconds == null
                    ? '-'
                    : '${report.chargingDelaySeconds!.toStringAsFixed(1)} sn',
              ),
              _statCell('Kamera', report.cameraMotionObserved ? 'Hareket gördü' : 'Hareket yok'),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: report.isSealValid ? const Color(0xFFF2F2F7) : const Color(0xFFFDECEC),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  report.isSealValid ? Icons.verified_user_outlined : Icons.gpp_bad_outlined,
                  size: 15,
                  color: report.isSealValid ? const Color(0xFF248A3D) : const Color(0xFFD70015),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    report.isSealValid
                        ? 'Mühür doğrulandı · ${report.integritySeal.substring(0, 16)}…'
                        : 'MÜHÜR DOĞRULANAMADI · kayıt değiştirilmiş veya eski sürüm',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF1C1C1E),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  report.startTime.toIso8601String().substring(11, 19),
                  style: const TextStyle(
                    color: Color(0xFF8E8E93),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => _showLogDialog(context, report),
                icon: const Icon(Icons.list_alt_rounded, size: 16),
                label: Text('Zaman damgalı kayıt (${report.timestampedLog.length})'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFF2D55),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                    text: const JsonEncoder.withIndent('  ').convert(report.toJson()),
                  ));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Rapor (mühürlü JSON) panoya kopyalandı'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Kopyala'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1C1C1E),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showLogDialog(BuildContext context, TestReport report) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${report.reportId} · kayıt'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: report.timestampedLog.isEmpty
              ? const Center(child: Text('Bu raporda kayıt örneği yok.'))
              : ListView.builder(
                  itemCount: report.timestampedLog.length,
                  itemBuilder: (_, i) {
                    final e = report.timestampedLog[i];
                    final t = ((e['t_ms'] as num?) ?? 0) / 1000.0;
                    return Text(
                      '${t.toStringAsFixed(1).padLeft(5)} sn  eğim ${e['pitch']}°  '
                      'mesafe ${e['dist']} m  dönüş ${e['yaw']}°  '
                      'şarj ${e['chg']} dock ${e['dock']} kutu ${e['box']}  '
                      '${e['cmd']}  ${e['state']}  kamera:${e['cam']}',
                      style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace'),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Kapat')),
        ],
      ),
    );
  }

  Widget _statCell(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFF1C1C1E),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
