import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/telemetry_data.dart';
import '../models/test_task.dart';
import 'telemetry_service.dart';

// Seçilen ÇDTP test görevini gerçek ESP32 telemetrisi ve kamera tespiti üzerinden
// takip eden, otomatik GEÇTİ/KALDI kararı veren ve mühürlü salt-okunur rapor üreten servis.
class TaskEvaluatorService extends ChangeNotifier {
  final RobotSystemController robotController;

  // kabul eşikleri (şartname + proje yönetim planı)
  static const double staticBalanceTargetSec = 30.0;
  static const double staticDriftLimitM = 0.20;
  static const double minDistanceM = 0.80;
  static const double maxDistanceM = 1.20;
  static const double minTurnDeg = 60.0;
  static const double maxTurnDeg = 120.0;
  static const double maxResponseSec = 2.0;
  static const double stopHoldSec = 3.0;
  static const double targetHoldSec = 5.0;
  static const double maxChargeDelaySec = 5.0;
  static const double dockedMaxPitchDeg = 5.0;

  TaskType _selectedTask = TaskType.staticBalance;
  bool _isTestRunning = false;
  DateTime? _testStartTime;
  double _elapsedSeconds = 0.0;
  Timer? _evaluationTicker;

  double _maxAbsPitchDuringTest = 0.0;
  int _startBattery = 0;
  MovementDirection _primaryDirectionObserved = MovementDirection.none;
  double _targetHoldSeconds = 0.0;
  double _staticSinceStopSec = 0.0;
  IntegratedPhase _integratedPhase = IntegratedPhase.initialBalance5s;
  int _integratedRunCounter = 1;

  // komut / tepki takibi
  RobotCommand _lastCmd = RobotCommand.idle;
  RobotCommand? _pendingCmd;
  DateTime? _pendingAt;
  double _pendingStartDist = 0.0;
  double _pendingStartYaw = 0.0;
  double? _maxResponseSec;
  bool _responseTimeout = false;
  bool _wrongDirection = false;
  RobotCommand? _firstLinearCmd;
  RobotCommand? _firstTurnCmd;
  final List<String> _commandsObserved = [];
  bool _humanCommandDuringAutonomy = false;
  bool _cameraMotionObserved = false;

  // şarj takibi
  DateTime? _dockAtInTest;
  double? _chargeDelayInTest;

  // zaman damgalı kayıt
  final List<Map<String, dynamic>> _log = [];
  int _lastLoggedSeq = -1;

  final List<TestReport> _immutableReports = [];
  TestReport? _lastCompletedReport;
  File? _storageFile;

  TaskEvaluatorService({required this.robotController}) {
    _loadPersistedReports();
  }

  TaskType get selectedTask => _selectedTask;
  bool get isTestRunning => _isTestRunning;
  double get elapsedSeconds => _elapsedSeconds;
  double get targetHoldSeconds => _targetHoldSeconds;
  IntegratedPhase get integratedPhase => _integratedPhase;
  int get integratedRunCounter => _integratedRunCounter;
  List<TestReport> get immutableReports => List.unmodifiable(_immutableReports);
  TestReport? get lastCompletedReport => _lastCompletedReport;

  String get formattedElapsedTime {
    final totalSec = _elapsedSeconds.floor();
    final mins = (totalSec ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSec % 60).toString().padLeft(2, '0');
    final tenths = ((_elapsedSeconds - totalSec) * 10).floor();
    return '$mins:$secs.$tenths';
  }

  void selectTask(TaskType task) {
    if (_isTestRunning) return;
    _selectedTask = task;
    _lastCompletedReport = null;
    notifyListeners();
  }

  // testi başlatır (yalnızca gerçek robot bağlıysa); kamera kapalıysa açılır
  bool startTest() {
    if (_isTestRunning) return false;
    if (!robotController.isRobotConnected) return false;

    robotController.ensureCameraOn();
    robotController.resetRobotPosition();
    final t = robotController.latestTelemetry;

    _isTestRunning = true;
    _lastCompletedReport = null;
    _testStartTime = DateTime.now();
    _elapsedSeconds = 0.0;
    _targetHoldSeconds = 0.0;
    _staticSinceStopSec = 0.0;
    _maxAbsPitchDuringTest = t.pitchAngleDeg.abs();
    _startBattery = t.batteryPercent;
    _primaryDirectionObserved = MovementDirection.none;
    _integratedPhase = IntegratedPhase.initialBalance5s;

    _lastCmd = t.lastGloveCommand;
    _pendingCmd = null;
    _pendingAt = null;
    _maxResponseSec = null;
    _responseTimeout = false;
    _wrongDirection = false;
    _firstLinearCmd = null;
    _firstTurnCmd = null;
    _commandsObserved.clear();
    _humanCommandDuringAutonomy = false;
    _cameraMotionObserved = false;
    _dockAtInTest = null;
    _chargeDelayInTest = null;
    _log.clear();
    _lastLoggedSeq = -1;

    _evaluationTicker?.cancel();
    _evaluationTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _onEvaluationTick();
    });

    if (robotController.soundAlertsEnabled) {
      SystemSound.play(SystemSoundType.click);
    }
    notifyListeners();
    return true;
  }

  void _onEvaluationTick() {
    if (!_isTestRunning || _testStartTime == null) return;

    final now = DateTime.now();
    _elapsedSeconds = now.difference(_testStartTime!).inMilliseconds / 1000.0;
    final telemetry = robotController.latestTelemetry;
    final vision = robotController.latestVision;

    _appendLog(now);
    _maxAbsPitchDuringTest = max(_maxAbsPitchDuringTest, telemetry.pitchAngleDeg.abs());
    if (vision.camera.motionDetected) _cameraMotionObserved = true;
    if (vision.movementDirection != MovementDirection.none &&
        _primaryDirectionObserved == MovementDirection.none) {
      _primaryDirectionObserved = vision.movementDirection;
    }
    _trackCommands(now, telemetry.lastGloveCommand, vision.signedDistanceMeters,
        vision.accumulatedRotationDeg);
    _trackCharging();

    // ortak başarısızlık koşulları: kutu düşmesi, devrilme, >2 sn bağlantı kopması
    if (!vision.medicineBoxPresent) {
      finishTest(forcedFailReason: 'İlaç kutusu robot üzerinden düştü.');
      return;
    }
    if (vision.movementState == MovementState.fallen) {
      finishTest(
        forcedFailReason: 'Robot dengesini kaybetti (${telemetry.pitchAngleDeg.toStringAsFixed(1)}°).',
      );
      return;
    }
    if (robotController.hadConnectionDropOver2Sec) {
      finishTest(forcedFailReason: 'Kablosuz bağlantı 2 saniyeden uzun süre koptu.');
      return;
    }

    final bool isStatic = vision.movementState == MovementState.staticBalance;
    final bool stopped = !telemetry.lastGloveCommand.isMotion;
    _staticSinceStopSec = (isStatic && stopped) ? _staticSinceStopSec + 0.1 : 0.0;

    switch (_selectedTask) {
      case TaskType.staticBalance:
        if (_elapsedSeconds >= staticBalanceTargetSec) finishTest();
        break;

      case TaskType.gloveGuidance:
        // hareket komutlarından sonra "dur" verilip 3 sn dengede beklenince test biter
        if (_commandsObserved.isNotEmpty && _pendingCmd == null &&
            _staticSinceStopSec >= stopHoldSec) {
          finishTest();
        }
        break;

      case TaskType.autoCharging:
        if (telemetry.lastGloveCommand.isMotion) _humanCommandDuringAutonomy = true;
        if (_chargeDelayInTest != null && telemetry.isCharging) {
          finishTest();
        } else if (_dockAtInTest != null &&
            DateTime.now().difference(_dockAtInTest!).inMilliseconds / 1000.0 >
                maxChargeDelaySec + 1.0) {
          finishTest(forcedFailReason: 'Kenetlendikten sonra 5 sn içinde şarj başlamadı.');
        }
        break;

      case TaskType.integratedMission:
        _updateIntegratedMissionPhases();
        if (_integratedPhase == IntegratedPhase.completed) finishTest();
        break;
    }

    notifyListeners();
  }

  void _appendLog(DateTime now) {
    final t = robotController.latestTelemetry;
    if (t.sequenceNumber == _lastLoggedSeq) return;
    _lastLoggedSeq = t.sequenceNumber;
    final v = robotController.latestVision;
    _log.add({
      't_ms': now.difference(_testStartTime!).inMilliseconds,
      'seq': t.sequenceNumber,
      'pitch': double.parse(t.pitchAngleDeg.toStringAsFixed(1)),
      'bat': t.batteryPercent,
      'chg': t.isCharging ? 1 : 0,
      'dock': t.isDocked ? 1 : 0,
      'box': t.boxPresent ? 1 : 0,
      'dist': double.parse(v.signedDistanceMeters.toStringAsFixed(3)),
      'yaw': double.parse(v.accumulatedRotationDeg.toStringAsFixed(1)),
      'cmd': t.lastGloveCommand.code,
      'state': v.movementState.name,
      'cam': v.camera.cameraActive ? (v.camera.motionDetected ? v.camera.direction.name : 'still') : 'off',
    });
  }

  // her hareket komutu için robotun ≤ 2 sn içinde doğru yönde tepki verip vermediğini ölçer
  void _trackCommands(DateTime now, RobotCommand cmd, double dist, double yaw) {
    if (cmd != _lastCmd) {
      _lastCmd = cmd;
      if (cmd.isMotion) {
        _pendingCmd = cmd;
        _pendingAt = now;
        _pendingStartDist = dist;
        _pendingStartYaw = yaw;
        _commandsObserved.add(cmd.code);
        if (cmd.isLinear) _firstLinearCmd ??= cmd;
        if (cmd.isTurn) _firstTurnCmd ??= cmd;
      } else {
        _pendingCmd = null;
      }
    }

    final pending = _pendingCmd;
    if (pending == null || _pendingAt == null) return;
    final double waited = now.difference(_pendingAt!).inMilliseconds / 1000.0;

    double progress;
    double threshold;
    if (pending.isLinear) {
      final sign = pending == RobotCommand.forward ? 1.0 : -1.0;
      progress = (dist - _pendingStartDist) * sign;
      threshold = 0.02; // 2 cm
    } else {
      final sign = pending == RobotCommand.turnRight ? 1.0 : -1.0;
      progress = (yaw - _pendingStartYaw) * sign;
      threshold = 5.0; // 5°
    }

    if (progress >= threshold) {
      _maxResponseSec = max(_maxResponseSec ?? 0.0, waited);
      _pendingCmd = null;
    } else if (progress <= -threshold) {
      _wrongDirection = true;
      _pendingCmd = null;
    } else if (waited > maxResponseSec) {
      _responseTimeout = true;
      _maxResponseSec = max(_maxResponseSec ?? 0.0, waited);
      _pendingCmd = null;
    }
  }

  void _trackCharging() {
    final start = _testStartTime!;
    final dockedAt = robotController.dockedAt;
    if (_dockAtInTest == null && dockedAt != null && dockedAt.isAfter(start) &&
        robotController.latestTelemetry.isDocked) {
      _dockAtInTest = dockedAt;
    }
    final chargeAt = robotController.lastChargeStartAt;
    if (_chargeDelayInTest == null && _dockAtInTest != null && chargeAt != null &&
        !chargeAt.isBefore(_dockAtInTest!)) {
      _chargeDelayInTest = chargeAt.difference(_dockAtInTest!).inMilliseconds / 1000.0;
    }
  }

  void _updateIntegratedMissionPhases() {
    final vision = robotController.latestVision;
    final telemetry = robotController.latestTelemetry;
    final prevPhase = _integratedPhase;
    final bool isStatic = vision.movementState == MovementState.staticBalance;

    switch (_integratedPhase) {
      case IntegratedPhase.initialBalance5s:
        if (telemetry.lastGloveCommand.isMotion && _elapsedSeconds < targetHoldSec) {
          finishTest(forcedFailReason: 'Başlangıçta 5 sn dengede beklemeden harekete geçildi.');
          return;
        }
        if (_elapsedSeconds >= targetHoldSec && isStatic) {
          _integratedPhase = IntegratedPhase.gloveNavigation1m;
        }
        break;
      case IntegratedPhase.gloveNavigation1m:
        if (vision.distanceTraveledMeters >= minDistanceM && _staticSinceStopSec > 0) {
          _integratedPhase = IntegratedPhase.targetHold5s;
          _targetHoldSeconds = 0.0;
        }
        break;
      case IntegratedPhase.targetHold5s:
        if (isStatic && !telemetry.lastGloveCommand.isMotion) {
          _targetHoldSeconds += 0.1;
          if (_targetHoldSeconds >= targetHoldSec) {
            _integratedPhase = IntegratedPhase.approachZoneEntry;
          }
        } else {
          _targetHoldSeconds = 0.0;
        }
        break;
      case IntegratedPhase.approachZoneEntry:
        // robot istasyonun IR fenerini görüp otonom moda geçtiğinde "DOCK" bildirir
        if (telemetry.lastGloveCommand == RobotCommand.dock || telemetry.isDocked) {
          _integratedPhase = IntegratedPhase.autonomousDocking;
        }
        break;
      case IntegratedPhase.autonomousDocking:
        if (telemetry.lastGloveCommand.isMotion) _humanCommandDuringAutonomy = true;
        if (telemetry.isDocked) _integratedPhase = IntegratedPhase.autoChargeVerify5s;
        break;
      case IntegratedPhase.autoChargeVerify5s:
        if (_chargeDelayInTest != null && telemetry.isCharging &&
            telemetry.pitchAngleDeg.abs() <= dockedMaxPitchDeg && telemetry.batteryPercent > 0) {
          _integratedPhase = IntegratedPhase.completed;
        } else if (_dockAtInTest != null &&
            DateTime.now().difference(_dockAtInTest!).inMilliseconds / 1000.0 >
                maxChargeDelaySec + 1.0) {
          finishTest(forcedFailReason: 'Kenetlendikten sonra 5 sn içinde şarj başlamadı.');
          return;
        }
        break;
      case IntegratedPhase.completed:
        break;
    }

    if (_integratedPhase != prevPhase && robotController.soundAlertsEnabled) {
      HapticFeedback.selectionClick();
      SystemSound.play(SystemSoundType.click);
    }
  }

  void finishTest({String? forcedFailReason}) {
    if (!_isTestRunning || _testStartTime == null) return;

    _evaluationTicker?.cancel();
    _isTestRunning = false;

    final endTime = DateTime.now();
    final duration = endTime.difference(_testStartTime!).inMilliseconds / 1000.0;
    final telemetry = robotController.latestTelemetry;
    final vision = robotController.latestVision;
    _appendLog(endTime);

    final double? chargeDelay = _chargeDelayInTest;
    final bool chargeWithin5 = chargeDelay != null && chargeDelay <= maxChargeDelaySec;
    // şartname: şarj durumu = istasyona yerleşme + robot eğimi + pil/şarj telemetrisi
    final bool threeWayChargeOk = telemetry.isDocked &&
        telemetry.isCharging &&
        telemetry.pitchAngleDeg.abs() <= dockedMaxPitchDeg &&
        telemetry.batteryPercent > 0 &&
        chargeWithin5;

    final String fmtDist = vision.distanceTraveledMeters.toStringAsFixed(2).replaceAll('.', ',');
    final String finalPosText =
        telemetry.isDocked ? 'Şarj istasyonunda ($fmtDist m)' : '$fmtDist m';

    bool passed = false;
    String summary = '';
    int usedRepetition = 1;

    if (forcedFailReason != null) {
      summary = forcedFailReason;
      if (_selectedTask == TaskType.integratedMission) usedRepetition = _integratedRunCounter;
    } else {
      switch (_selectedTask) {
        case TaskType.staticBalance:
          final durationOk = (duration - staticBalanceTargetSec).abs() <= 2.0;
          final driftOk = vision.distanceTraveledMeters <= staticDriftLimitM;
          passed = durationOk && driftOk && vision.medicineBoxPresent;
          summary = passed
              ? '${duration.toStringAsFixed(1)} sn boyunca kutuyu düşürmeden dengede kaldı.'
              : !durationOk
                  ? 'Hedef 30 sn (±2 sn) denge süresi sağlanmadı (${duration.toStringAsFixed(1)} sn).'
                  : 'Denge sırasında robot ${vision.distanceTraveledMeters.toStringAsFixed(2)} m kaydı (sınır 0,20 m).';
          break;

        case TaskType.gloveGuidance:
          final List<String> problems = [];
          if (_commandsObserved.isEmpty) problems.add('eldivenden hareket komutu gelmedi');
          if (_responseTimeout) problems.add('komuta 2 sn içinde tepki verilmedi');
          if (_wrongDirection) problems.add('robot komutun tersi yönde hareket etti');
          final double signedDist = vision.signedDistanceMeters;
          final double yaw = vision.accumulatedRotationDeg;
          if (_firstLinearCmd != null) {
            final double along = _firstLinearCmd == RobotCommand.forward ? signedDist : -signedDist;
            if (along < minDistanceM || along > maxDistanceM) {
              problems.add('mesafe ${signedDist.abs().toStringAsFixed(2)} m (hedef 0,8–1,2 m, doğru yönde)');
            }
          }
          if (_firstTurnCmd != null) {
            final double turned = _firstTurnCmd == RobotCommand.turnRight ? yaw : -yaw;
            if (turned < minTurnDeg || turned > maxTurnDeg) {
              problems.add('dönüş ${yaw.abs().toStringAsFixed(0)}° (hedef ~90°, doğru yönde)');
            }
          }
          passed = problems.isEmpty && vision.medicineBoxPresent;
          final resp = _maxResponseSec == null ? '-' : '${_maxResponseSec!.toStringAsFixed(1)} sn';
          summary = passed
              ? 'Komutlar: ${_commandsObserved.join(", ")} · ${signedDist.abs().toStringAsFixed(2)} m, '
                  '${yaw.abs().toStringAsFixed(0)}° · en uzun tepki $resp.'
              : 'Başarısız: ${problems.join("; ")}.';
          break;

        case TaskType.autoCharging:
          passed = threeWayChargeOk && vision.medicineBoxPresent && !_humanCommandDuringAutonomy;
          summary = passed
              ? 'Otonom yerleşme tamamlandı, şarj ${chargeDelay.toStringAsFixed(1)} sn içinde başladı.'
              : _humanCommandDuringAutonomy
                  ? 'Yerleşme sırasında eldiven komutu algılandı (otonom değil).'
                  : 'Otonom yerleşme veya ≤ 5 sn şarj başlangıcı doğrulanamadı.';
          break;

        case TaskType.integratedMission:
          usedRepetition = _integratedRunCounter;
          final bool holdOk = _targetHoldSeconds >= targetHoldSec ||
              _integratedPhase.index > IntegratedPhase.targetHold5s.index;
          passed = _integratedPhase == IntegratedPhase.completed &&
              holdOk &&
              threeWayChargeOk &&
              vision.medicineBoxPresent &&
              !_humanCommandDuringAutonomy;
          summary = passed
              ? 'Tur $usedRepetition/4: 5 sn denge, ${vision.distanceTraveledMeters.toStringAsFixed(2)} m taşıma, '
                  '5 sn bekleme ve otonom şarj (${chargeDelay.toStringAsFixed(1)} sn) tamamlandı.'
              : _humanCommandDuringAutonomy
                  ? 'Tur $usedRepetition/4: otonom yerleşme sırasında eldiven komutu algılandı.'
                  : 'Tur $usedRepetition/4: tamamlanamayan adım: ${_integratedPhase.label}.';
          break;
      }
    }

    // bütünleşik görevde her deneme bir turdur (1..4)
    if (_selectedTask == TaskType.integratedMission) {
      _integratedRunCounter = _integratedRunCounter >= 4 ? 1 : _integratedRunCounter + 1;
    }

    if (passed) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
    if (robotController.soundAlertsEnabled) {
      SystemSound.play(SystemSoundType.alert);
    }

    final datePart =
        '${endTime.year}${endTime.month.toString().padLeft(2, '0')}${endTime.day.toString().padLeft(2, '0')}';
    final reportId = 'CDTP-$datePart-${101 + _immutableReports.length}';

    final double? undockDelay = robotController.lastChargeOffAt != null &&
            robotController.lastChargeOffAt!.isAfter(_testStartTime!)
        ? robotController.lastUndockChargeOffDelaySec
        : null;

    final report = TestReport(
      reportId: reportId,
      taskType: _selectedTask,
      repetitionNumber: usedRepetition,
      startTime: _testStartTime!,
      endTime: endTime,
      durationSeconds: duration,
      measuredDistanceMeters: vision.distanceTraveledMeters,
      signedDistanceMeters: vision.signedDistanceMeters,
      accumulatedRotationDeg: vision.accumulatedRotationDeg,
      detectedPrimaryDirection: _primaryDirectionObserved,
      finalPositionSummary: finalPosText,
      maxAbsPitchDeg: _maxAbsPitchDuringTest,
      finalPitchDeg: telemetry.pitchAngleDeg,
      startBatteryPercent: _startBattery,
      endBatteryPercent: telemetry.batteryPercent,
      medicineBoxIntact: vision.medicineBoxPresent,
      chargingStartedWithin5Sec: chargeWithin5,
      threeWayChargeVerified: threeWayChargeOk,
      chargingDelaySeconds: chargeDelay,
      undockTurnOffDelaySeconds: undockDelay,
      maxCommandResponseSeconds: _maxResponseSec,
      commandsObserved: List.of(_commandsObserved),
      cameraMotionObserved: _cameraMotionObserved,
      connectionMaintainedUnder2Sec: !robotController.hadConnectionDropOver2Sec,
      passed: passed,
      scoreEarned: passed ? 5 : 0,
      evaluationSummary: summary,
      timestampedLog: List.of(_log),
    ).sealed();

    _immutableReports.insert(0, report);
    _lastCompletedReport = report;
    _persistReportsToDisk();
    notifyListeners();
  }

  Future<File?> _resolveStorageFile() async {
    if (kIsWeb) return null;
    if (_storageFile != null) return _storageFile;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/hdrg100_test_raporlari_v3.json');
      return _storageFile;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadPersistedReports() async {
    final file = await _resolveStorageFile();
    if (file == null || !file.existsSync()) return;
    try {
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      _immutableReports
        ..clear()
        ..addAll(decoded.whereType<Map<String, dynamic>>().map(TestReport.fromJson));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persistReportsToDisk() async {
    final file = await _resolveStorageFile();
    if (file == null) return;
    try {
      final payload = jsonEncode(_immutableReports.map((r) => r.toJson()).toList());
      await file.writeAsString(payload, flush: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _evaluationTicker?.cancel();
    super.dispose();
  }
}
