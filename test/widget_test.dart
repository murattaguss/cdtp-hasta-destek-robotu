import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cdtp_hasta_destek_mobil/models/telemetry_data.dart';
import 'package:cdtp_hasta_destek_mobil/models/test_task.dart';

TestReport _sampleReport() => TestReport(
      reportId: 'CDTP-20261110-101',
      taskType: TaskType.gloveGuidance,
      repetitionNumber: 1,
      startTime: DateTime(2026, 11, 10, 12, 0, 0),
      endTime: DateTime(2026, 11, 10, 12, 0, 21),
      durationSeconds: 21.0,
      measuredDistanceMeters: 0.98,
      signedDistanceMeters: 0.98,
      accumulatedRotationDeg: 2.0,
      detectedPrimaryDirection: MovementDirection.forward,
      maxAbsPitchDeg: 4.1,
      finalPitchDeg: 0.4,
      startBatteryPercent: 88,
      endBatteryPercent: 87,
      medicineBoxIntact: true,
      chargingStartedWithin5Sec: false,
      maxCommandResponseSeconds: 0.6,
      commandsObserved: const ['FWD'],
      cameraMotionObserved: true,
      connectionMaintainedUnder2Sec: true,
      passed: true,
      scoreEarned: 5,
      evaluationSummary: 'test',
      timestampedLog: const [
        {'t_ms': 500, 'seq': 3, 'pitch': 1.0, 'dist': 0.05, 'cmd': 'FWD'},
      ],
    ).sealed();

void main() {
  test('robot telemetri paketi ayrıştırılır', () {
    final t = RobotTelemetry.fromRawString(
      '{"seq":12,"pitch":1.4,"bat":85,"chg":1,"dock":1,"box":1,"dist":-0.452,"yaw":91.5,"rst":3,"cmd":"DOCK"}',
    );
    expect(t.sequenceNumber, 12);
    expect(t.pitchAngleDeg, 1.4);
    expect(t.batteryPercent, 85);
    expect(t.isCharging, isTrue);
    expect(t.isDocked, isTrue);
    expect(t.boxPresent, isTrue);
    expect(t.signedDistanceMeters, -0.452);
    expect(t.yawDeg, 91.5);
    expect(t.lastGloveCommand, RobotCommand.dock);
  });

  test('mühürlü rapor kaydedilip okununca mühür geçerli kalır', () {
    final report = _sampleReport();
    expect(report.isSealValid, isTrue);
    final restored = TestReport.fromJson(
      jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>,
    );
    expect(restored.isSealValid, isTrue);
  });

  test('rapor sonradan "geçti" yapılırsa mühür bozulur', () {
    final report = _sampleReport();
    final json = jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>;
    json['passed'] = false;
    expect(TestReport.fromJson(json).isSealValid, isFalse);

    final json2 = jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>;
    (json2['timestampedLog'] as List)[0]['dist'] = 1.0;
    expect(TestReport.fromJson(json2).isSealValid, isFalse);
  });
}
