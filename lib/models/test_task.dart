import 'dart:convert';
import 'telemetry_data.dart';

// ÇDTP şartnamesinde yer alan 4 değerlendirme görevi ve başarı kriterleri
enum TaskType {
  staticBalance(
    code: 'MOD_A_BALANCE',
    title: 'Statik Denge',
    moduleCode: 'Modül A',
    metricSummary: 'Hedef: 30 sn dengede kalma',
    targetDurationSec: 30.0,
    minDistanceM: 0.0,
    maxDistanceM: 0.15,
    expectedDirection: MovementDirection.none,
  ),
  gloveGuidance(
    code: 'MOD_B_GUIDANCE',
    title: 'Yönlendirme',
    moduleCode: 'Modül B',
    metricSummary: 'Hedef: Doğru yön, 0,8–1,2 m veya ~90° dönüş, ≤ 2 sn tepki',
    targetDurationSec: 45.0,
    minDistanceM: 0.80,
    maxDistanceM: 1.20,
    expectedDirection: MovementDirection.forward,
  ),
  autoCharging(
    code: 'MOD_C_CHARGING',
    title: 'Şarj Etme',
    moduleCode: 'Modül C',
    metricSummary: 'Hedef: Otonom yerleşme, ≤ 5 sn içinde şarj',
    targetDurationSec: 40.0,
    minDistanceM: 0.15,
    maxDistanceM: 0.50,
    expectedDirection: MovementDirection.forward,
  ),
  integratedMission(
    code: 'MOD_E_INTEGRATED',
    title: 'Bütünleşik Görev',
    moduleCode: 'Modül E',
    metricSummary: 'Hedef: Denge → ~1m taşıma → 5 sn bekleme → Şarj',
    targetDurationSec: 90.0,
    minDistanceM: 0.80,
    maxDistanceM: 1.40,
    expectedDirection: MovementDirection.forward,
  );

  final String code;
  final String title;
  final String moduleCode;
  final String metricSummary;
  final double targetDurationSec;
  final double minDistanceM;
  final double maxDistanceM;
  final MovementDirection expectedDirection;

  const TaskType({
    required this.code,
    required this.title,
    required this.moduleCode,
    required this.metricSummary,
    required this.targetDurationSec,
    required this.minDistanceM,
    required this.maxDistanceM,
    required this.expectedDirection,
  });

  static TaskType fromCode(String? code) {
    return TaskType.values.firstWhere(
      (t) => t.code == code,
      orElse: () => TaskType.staticBalance,
    );
  }
}

// Bütünleşik görev (Görev 4) çalışırken sırasıyla geçilen alt aşamalar
enum IntegratedPhase {
  initialBalance5s('1/6 · Başlangıçta 5 sn denge'),
  gloveNavigation1m('2/6 · Eldivenle ~1 m ilerleme'),
  targetHold5s('3/6 · Hedefte 5 sn bekleme'),
  approachZoneEntry('4/6 · 30 cm yaklaşma bölgesi'),
  autonomousDocking('5/6 · İstasyona otonom yerleşme'),
  autoChargeVerify5s('6/6 · Otomatik şarj kontrolü'),
  completed('Tamamlandı');

  final String label;
  const IntegratedPhase(this.label);
}

// Test bittiğinde oluşturulan salt-okunur (değiştirilemez) rapor modeli.
// Tüm alanlar final'dır; rapor içeriğinin tamamı (zaman damgalı kayıt dahil) FNV-1a tabanlı
// bir mühürle kapatılır. Kayıt sonradan elle değiştirilirse mühür doğrulaması başarısız olur.
class TestReport {
  final String reportId;
  final TaskType taskType;
  final int repetitionNumber;
  final DateTime startTime;
  final DateTime endTime;
  final double durationSeconds;
  final double measuredDistanceMeters;
  final double signedDistanceMeters;
  final double accumulatedRotationDeg;
  final MovementDirection detectedPrimaryDirection;
  final String finalPositionSummary;
  final double maxAbsPitchDeg;
  final double finalPitchDeg;
  final int startBatteryPercent;
  final int endBatteryPercent;
  final bool medicineBoxIntact;
  final bool chargingStartedWithin5Sec;
  final bool threeWayChargeVerified;
  final double? chargingDelaySeconds;
  final double? undockTurnOffDelaySeconds;
  final double? maxCommandResponseSeconds;
  final List<String> commandsObserved;
  final bool cameraMotionObserved;
  final bool connectionMaintainedUnder2Sec;
  final bool passed;
  final int scoreEarned;
  final String evaluationSummary;
  // zaman damgalı kayıt: test boyunca robottan gelen her telemetri örneği + kamera tespiti
  final List<Map<String, dynamic>> timestampedLog;
  final String integritySeal;

  const TestReport({
    required this.reportId,
    required this.taskType,
    required this.repetitionNumber,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
    required this.measuredDistanceMeters,
    this.signedDistanceMeters = 0.0,
    this.accumulatedRotationDeg = 0.0,
    required this.detectedPrimaryDirection,
    this.finalPositionSummary = '0,00 m',
    required this.maxAbsPitchDeg,
    required this.finalPitchDeg,
    required this.startBatteryPercent,
    required this.endBatteryPercent,
    required this.medicineBoxIntact,
    required this.chargingStartedWithin5Sec,
    this.threeWayChargeVerified = false,
    this.chargingDelaySeconds,
    this.undockTurnOffDelaySeconds,
    this.maxCommandResponseSeconds,
    this.commandsObserved = const [],
    this.cameraMotionObserved = false,
    required this.connectionMaintainedUnder2Sec,
    required this.passed,
    required this.scoreEarned,
    required this.evaluationSummary,
    this.timestampedLog = const [],
    this.integritySeal = '',
  });

  // mühür hariç tüm içerik (alan sırası sabit)
  Map<String, dynamic> _contentJson() => {
        'reportId': reportId,
        'taskCode': taskType.code,
        'repetitionNumber': repetitionNumber,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'durationSeconds': durationSeconds,
        'measuredDistanceMeters': measuredDistanceMeters,
        'signedDistanceMeters': signedDistanceMeters,
        'accumulatedRotationDeg': accumulatedRotationDeg,
        'detectedPrimaryDirection': detectedPrimaryDirection.name,
        'finalPositionSummary': finalPositionSummary,
        'maxAbsPitchDeg': maxAbsPitchDeg,
        'finalPitchDeg': finalPitchDeg,
        'startBatteryPercent': startBatteryPercent,
        'endBatteryPercent': endBatteryPercent,
        'medicineBoxIntact': medicineBoxIntact,
        'chargingStartedWithin5Sec': chargingStartedWithin5Sec,
        'threeWayChargeVerified': threeWayChargeVerified,
        'chargingDelaySeconds': chargingDelaySeconds,
        'undockTurnOffDelaySeconds': undockTurnOffDelaySeconds,
        'maxCommandResponseSeconds': maxCommandResponseSeconds,
        'commandsObserved': commandsObserved,
        'cameraMotionObserved': cameraMotionObserved,
        'connectionMaintainedUnder2Sec': connectionMaintainedUnder2Sec,
        'passed': passed,
        'scoreEarned': scoreEarned,
        'evaluationSummary': evaluationSummary,
        'timestampedLog': timestampedLog,
      };

  Map<String, dynamic> toJson() => {
        ..._contentJson(),
        'integritySeal': integritySeal,
      };

  // aynı içerikle mühürlenmiş kopyasını üretir (yalnızca rapor oluşturulurken kullanılır)
  TestReport sealed() => TestReport(
        reportId: reportId,
        taskType: taskType,
        repetitionNumber: repetitionNumber,
        startTime: startTime,
        endTime: endTime,
        durationSeconds: durationSeconds,
        measuredDistanceMeters: measuredDistanceMeters,
        signedDistanceMeters: signedDistanceMeters,
        accumulatedRotationDeg: accumulatedRotationDeg,
        detectedPrimaryDirection: detectedPrimaryDirection,
        finalPositionSummary: finalPositionSummary,
        maxAbsPitchDeg: maxAbsPitchDeg,
        finalPitchDeg: finalPitchDeg,
        startBatteryPercent: startBatteryPercent,
        endBatteryPercent: endBatteryPercent,
        medicineBoxIntact: medicineBoxIntact,
        chargingStartedWithin5Sec: chargingStartedWithin5Sec,
        threeWayChargeVerified: threeWayChargeVerified,
        chargingDelaySeconds: chargingDelaySeconds,
        undockTurnOffDelaySeconds: undockTurnOffDelaySeconds,
        maxCommandResponseSeconds: maxCommandResponseSeconds,
        commandsObserved: commandsObserved,
        cameraMotionObserved: cameraMotionObserved,
        connectionMaintainedUnder2Sec: connectionMaintainedUnder2Sec,
        passed: passed,
        scoreEarned: scoreEarned,
        evaluationSummary: evaluationSummary,
        timestampedLog: timestampedLog,
        integritySeal: computeSeal(jsonEncode(_contentJson())),
      );

  // kayıttaki mühür, içerikten yeniden hesaplanan mühürle aynı mı?
  bool get isSealValid =>
      integritySeal.isNotEmpty && integritySeal == computeSeal(jsonEncode(_contentJson()));

  // Telefon hafızasından okunan JSON verisini tekrar TestReport nesnesine dönüştürür
  factory TestReport.fromJson(Map<String, dynamic> map) {
    final dirName = map['detectedPrimaryDirection'] as String?;
    final direction = MovementDirection.values.firstWhere(
      (d) => d.name == dirName,
      orElse: () => MovementDirection.none,
    );
    double d(String k) => (map[k] as num?)?.toDouble() ?? 0.0;
    double? dn(String k) => (map[k] as num?)?.toDouble();
    return TestReport(
      reportId: map['reportId'] as String? ?? 'CDTP-000',
      taskType: TaskType.fromCode(map['taskCode'] as String?),
      repetitionNumber: (map['repetitionNumber'] as num?)?.toInt() ?? 1,
      startTime: DateTime.tryParse(map['startTime'] as String? ?? '') ?? DateTime(2000),
      endTime: DateTime.tryParse(map['endTime'] as String? ?? '') ?? DateTime(2000),
      durationSeconds: d('durationSeconds'),
      measuredDistanceMeters: d('measuredDistanceMeters'),
      signedDistanceMeters: d('signedDistanceMeters'),
      accumulatedRotationDeg: d('accumulatedRotationDeg'),
      detectedPrimaryDirection: direction,
      finalPositionSummary: map['finalPositionSummary'] as String? ?? '0,00 m',
      maxAbsPitchDeg: d('maxAbsPitchDeg'),
      finalPitchDeg: d('finalPitchDeg'),
      startBatteryPercent: (map['startBatteryPercent'] as num?)?.toInt() ?? 0,
      endBatteryPercent: (map['endBatteryPercent'] as num?)?.toInt() ?? 0,
      medicineBoxIntact: map['medicineBoxIntact'] as bool? ?? false,
      chargingStartedWithin5Sec: map['chargingStartedWithin5Sec'] as bool? ?? false,
      threeWayChargeVerified: map['threeWayChargeVerified'] as bool? ?? false,
      chargingDelaySeconds: dn('chargingDelaySeconds'),
      undockTurnOffDelaySeconds: dn('undockTurnOffDelaySeconds'),
      maxCommandResponseSeconds: dn('maxCommandResponseSeconds'),
      commandsObserved:
          ((map['commandsObserved'] as List<dynamic>?) ?? const []).map((e) => '$e').toList(),
      cameraMotionObserved: map['cameraMotionObserved'] as bool? ?? false,
      connectionMaintainedUnder2Sec: map['connectionMaintainedUnder2Sec'] as bool? ?? false,
      passed: map['passed'] as bool? ?? false,
      scoreEarned: (map['scoreEarned'] as num?)?.toInt() ?? 0,
      evaluationSummary: map['evaluationSummary'] as String? ?? '',
      timestampedLog: ((map['timestampedLog'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(),
      // eski sürüm kayıtlarında alan adı farklıydı; onların mühürü doğrulanamaz
      integritySeal: map['integritySeal'] as String? ?? '',
    );
  }

  // FNV-1a (32 bit) özetinin 8 farklı başlangıç değeriyle çalıştırılıp birleştirilmesiyle
  // 256 bitlik bütünlük mühürü üretir
  static String computeSeal(String payload) {
    final bytes = utf8.encode(payload);
    const List<int> seeds = [
      0x811C9DC5,
      0x9E3779B9,
      0x85EBCA6B,
      0xC2B2AE35,
      0x27D4EB2F,
      0x165667B1,
      0xD3A2646C,
      0xFD7046C5,
    ];
    final buffer = StringBuffer();
    for (final seed in seeds) {
      int hash = seed;
      for (final b in bytes) {
        hash ^= b;
        hash = (hash * 0x01000193) & 0xFFFFFFFF;
      }
      buffer.write(hash.toRadixString(16).padLeft(8, '0'));
    }
    return buffer.toString().toUpperCase();
  }
}
