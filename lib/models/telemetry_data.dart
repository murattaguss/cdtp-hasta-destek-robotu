import 'dart:convert';

// Eldivenden gelen 5 temel hareket komutu + robotun otonom şarj güdümündeyken bildirdiği DOCK durumu.
// ESP32 tarafındaki "FWD", "BWD", "LEFT", "RIGHT", "STOP", "DOCK" metinleriyle eşleşir.
enum RobotCommand {
  idle('Beklemede', 'IDLE'),
  forward('İleri', 'FWD'),
  backward('Geri', 'BWD'),
  turnLeft('Sola Dön', 'LEFT'),
  turnRight('Sağa Dön', 'RIGHT'),
  stop('Dur', 'STOP'),
  dock('Otonom Şarj', 'DOCK');

  final String label;
  final String code;
  const RobotCommand(this.label, this.code);

  bool get isMotion =>
      this == forward || this == backward || this == turnLeft || this == turnRight;
  bool get isLinear => this == forward || this == backward;
  bool get isTurn => this == turnLeft || this == turnRight;

  // JSON paketinden gelen komut metnini enum değerine çevirir
  static RobotCommand fromCode(String? code) {
    return RobotCommand.values.firstWhere(
      (e) => e.code == code?.toUpperCase(),
      orElse: () => RobotCommand.idle,
    );
  }
}

// Robotun o anki genel çalışma durumu (arayüzdeki Hareket kartında gösterilir)
enum MovementState {
  staticBalance('Statik Denge', 'Denge'),
  moving('Hareket Ediyor', 'Hareket'),
  turning('Dönüyor', 'Dönüş'),
  recovering('Toparlanıyor', 'Toparlanma'),
  docked('Şarj İstasyonunda', 'Şarjda'),
  fallen('Devrildi', 'Devrildi');

  final String label;
  final String shortLabel;
  const MovementState(this.label, this.shortLabel);
}

// Robotun sensörlerinden (enkoder + gyro) tespit edilen hareket yönü
enum MovementDirection {
  none('-'),
  forward('İleri'),
  backward('Geri'),
  left('Sol'),
  right('Sağ');

  final String label;
  const MovementDirection(this.label);
}

// Robot üzerindeki ESP32'den UDP 4210 ile gelen telemetri paketi.
// Örnek: {"seq":12,"pitch":1.4,"bat":85,"chg":1,"dock":1,"box":1,"dist":0.452,"yaw":-3.5,"cmd":"FWD"}
class RobotTelemetry {
  final int sequenceNumber;
  final DateTime timestamp;
  final double pitchAngleDeg;
  final int batteryPercent;
  final bool isCharging; // şarj pedinde gerilim var (şarj akımı başladı)
  final bool isDocked; // istasyon temas anahtarı (DC171, GPIO 15) kapalı
  final bool boxPresent; // ilaç kutusu anahtarı (DC171, GPIO 4) kapalı
  final double signedDistanceMeters; // RESET'ten beri enkoder konumu (ileri +, geri -)
  final double yawDeg; // RESET'ten beri gyro ile ölçülen toplam dönüş (sağ +, sol -)
  final RobotCommand lastGloveCommand;

  const RobotTelemetry({
    required this.sequenceNumber,
    required this.timestamp,
    required this.pitchAngleDeg,
    required this.batteryPercent,
    required this.isCharging,
    this.isDocked = false,
    this.boxPresent = false,
    this.signedDistanceMeters = 0.0,
    this.yawDeg = 0.0,
    this.lastGloveCommand = RobotCommand.idle,
  });

  static bool _flag(dynamic v) => v == 1 || v == true;

  factory RobotTelemetry.fromJson(Map<String, dynamic> json) {
    return RobotTelemetry(
      sequenceNumber: (json['seq'] as num?)?.toInt() ?? 0,
      timestamp: DateTime.now(),
      pitchAngleDeg: (json['pitch'] as num?)?.toDouble() ?? 0.0,
      batteryPercent: ((json['bat'] as num?)?.toInt() ?? 0).clamp(0, 100),
      isCharging: _flag(json['chg']),
      isDocked: _flag(json['dock']),
      boxPresent: _flag(json['box']),
      signedDistanceMeters: (json['dist'] as num?)?.toDouble() ?? 0.0,
      yawDeg: (json['yaw'] as num?)?.toDouble() ?? 0.0,
      lastGloveCommand: RobotCommand.fromCode(json['cmd'] as String?),
    );
  }

  factory RobotTelemetry.fromRawString(String payload) {
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    return RobotTelemetry.fromJson(decoded);
  }

  Map<String, dynamic> toJson() => {
        'seq': sequenceNumber,
        'ts': timestamp.toIso8601String(),
        'pitch': double.parse(pitchAngleDeg.toStringAsFixed(2)),
        'bat': batteryPercent,
        'chg': isCharging ? 1 : 0,
        'dock': isDocked ? 1 : 0,
        'box': boxPresent ? 1 : 0,
        'dist': double.parse(signedDistanceMeters.toStringAsFixed(3)),
        'yaw': double.parse(yawDeg.toStringAsFixed(1)),
        'cmd': lastGloveCommand.code,
      };
}
