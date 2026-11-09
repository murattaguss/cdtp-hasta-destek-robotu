import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import '../models/telemetry_data.dart';
import '../models/vision_data.dart';
import 'camera_vision_service.dart';

// üst bardaki bağlantı durumu göstergesi.
// şartnameye göre 2 saniyeden uzun kopmalar hata olarak işaretlenir.
enum ConnectionHealth {
  waitingForRobot('Robot Bekleniyor'),
  connected1Hz('Bağlı'),
  reconnectingWarning('Sinyal Zayıf'),
  disconnectedFault('Bağlantı Koptu (>2 sn)');

  final String badgeText;
  const ConnectionHealth(this.badgeText);
}

// Robottaki ESP32 ile UDP 4210 üzerinden haberleşen ve telefon kamerasını yöneten ana kontrolcü.
//
// Haberleşme:
//  - Telefon her 1 sn'de robota (192.168.4.1:4210) "HELLO" gönderir; robot telefonun adresini
//    kaydedip telemetriyi doğrudan bu telefona (tekil UDP) gönderir. Böylece iOS'ta yayın
//    (broadcast) izni gerekmez ve bazı Android cihazlardaki yayın filtrelemesi sorun olmaz.
//  - Mesafe/dönüş sıfırlama "RESET:<n>" ile yapılır; robot n değerini telemetride "rst" olarak
//    geri yansıtana kadar komut tekrarlanır (UDP paket kaybına karşı).
class RobotSystemController extends ChangeNotifier {
  static const String robotIp = '192.168.4.1';
  static const int udpPort = 4210;

  ConnectionHealth _connectionHealth = ConnectionHealth.waitingForRobot;
  final bool _soundAlertsEnabled = true;

  late final CameraVisionProcessor _cameraProcessor;
  Timer? _watchdogTimer;
  Timer? _helloTimer;
  RawDatagramSocket? _udpSocket;
  DateTime? _lastRealHardwarePacketAt;
  bool _hadConnectionDropOver2Sec = false;
  int _lastSeq = -1;

  RobotTelemetry? _latestTelemetry;
  final List<double> _pitchHistory = [];

  // RESET onayı
  int _resetToken = 0;
  bool _resetAcked = true;
  double _localDistOffset = 0.0;
  double _localYawOffset = 0.0;

  // hız / dönüş hızı hesabı
  double? _prevDist;
  double? _prevYaw;
  DateTime? _prevSampleAt;
  double _speedMps = 0.0;
  double _yawRateDps = 0.0;

  // şarj olayları (robot telemetrisinden ölçülür)
  DateTime? _dockedAt;
  DateTime? _undockedAt;
  DateTime? _lastChargeStartAt;
  double? _lastChargeStartDelaySec; // kenetlenme -> şarj başlangıcı
  DateTime? _lastChargeOffAt;
  double? _lastUndockChargeOffDelaySec; // istasyondan ayrılma -> şarjın kesilmesi

  CameraMotionResult _cameraMotion = CameraMotionResult.inactive();
  VisionFrameResult _latestVision = VisionFrameResult.initial();

  RobotSystemController() {
    _cameraProcessor = CameraVisionProcessor(
      onMotionUpdated: (result) {
        _cameraMotion = result;
        _rebuildVision();
        notifyListeners();
      },
      onStateChanged: notifyListeners,
    );
    _startServices();
  }

  ConnectionHealth get connectionHealth => _connectionHealth;
  bool get isRobotConnected =>
      _lastRealHardwarePacketAt != null &&
      DateTime.now().difference(_lastRealHardwarePacketAt!).inMilliseconds <= 2000;
  bool get soundAlertsEnabled => _soundAlertsEnabled;
  CameraController? get cameraController => _cameraProcessor.cameraController;
  bool get isUsingRealCamera => _cameraProcessor.isUsingRealCamera;
  bool get isCameraAvailable => _cameraProcessor.isCameraAvailable;
  String? get cameraStatusMessage => _cameraProcessor.statusMessage;
  List<double> get pitchHistory => List.unmodifiable(_pitchHistory);

  RobotTelemetry get latestTelemetry =>
      _latestTelemetry ??
      RobotTelemetry(
        sequenceNumber: 0,
        timestamp: DateTime.now(),
        pitchAngleDeg: 0.0,
        batteryPercent: 0,
        isCharging: false,
      );
  VisionFrameResult get latestVision => _latestVision;
  bool get hadConnectionDropOver2Sec => _hadConnectionDropOver2Sec;
  bool get isResetConfirmed => _resetAcked;

  DateTime? get dockedAt => _dockedAt;
  DateTime? get lastChargeStartAt => _lastChargeStartAt;
  double? get lastChargeStartDelaySec => _lastChargeStartDelaySec;
  DateTime? get lastChargeOffAt => _lastChargeOffAt;
  double? get lastUndockChargeOffDelaySec => _lastUndockChargeOffDelaySec;

  double get _displayDist {
    final t = _latestTelemetry;
    if (t == null) return 0.0;
    return t.signedDistanceMeters - (_resetAcked ? 0.0 : _localDistOffset);
  }

  double get _displayYaw {
    final t = _latestTelemetry;
    if (t == null) return 0.0;
    return t.yawDeg - (_resetAcked ? 0.0 : _localYawOffset);
  }

  // esp32'den gelen json paketini işler
  void ingestHardwareJsonPacket(String rawJson) {
    Map<String, dynamic> decoded;
    try {
      final d = jsonDecode(rawJson);
      if (d is! Map<String, dynamic>) return;
      decoded = d;
    } catch (_) {
      return; // bozuk paket
    }

    final packet = RobotTelemetry.fromJson(decoded);
    // aynı paket iki kez gelirse (tekil + yayın) tekrar işleme
    if (packet.sequenceNumber > 0 && packet.sequenceNumber == _lastSeq) return;
    final bool robotRestarted = packet.sequenceNumber > 0 && packet.sequenceNumber < _lastSeq - 5;
    _lastSeq = packet.sequenceNumber;

    final now = DateTime.now();
    final prev = _latestTelemetry;
    _lastRealHardwarePacketAt = now;
    _connectionHealth = ConnectionHealth.connected1Hz;

    // RESET onayı: robot bizim gönderdiğimiz numarayı geri yansıttıysa değerler zaten sıfırlanmıştır
    final int rst = (decoded['rst'] as num?)?.toInt() ?? -1;
    if (!_resetAcked && rst == _resetToken) {
      _resetAcked = true;
      _prevDist = null;
      _prevYaw = null;
    }
    if (robotRestarted) {
      _prevDist = null;
      _prevYaw = null;
    }

    _latestTelemetry = packet;

    // hız ve dönüş hızı (ardışık paketlerden)
    final double dist = _displayDist;
    final double yaw = _displayYaw;
    if (_prevDist != null && _prevYaw != null && _prevSampleAt != null) {
      final double dt = now.difference(_prevSampleAt!).inMilliseconds / 1000.0;
      if (dt > 0.05) {
        _speedMps = ((dist - _prevDist!) / dt).clamp(-3.0, 3.0);
        _yawRateDps = ((yaw - _prevYaw!) / dt).clamp(-720.0, 720.0);
      }
    }
    _prevDist = dist;
    _prevYaw = yaw;
    _prevSampleAt = now;

    // kenetlenme / şarj geçişleri
    final bool wasDocked = prev?.isDocked ?? false;
    final bool wasCharging = prev?.isCharging ?? false;
    if (packet.isDocked && !wasDocked) {
      _dockedAt = now;
    } else if (!packet.isDocked && wasDocked) {
      _undockedAt = now;
    }
    if (packet.isCharging && !wasCharging) {
      _lastChargeStartAt = now;
      _lastChargeStartDelaySec =
          _dockedAt != null ? now.difference(_dockedAt!).inMilliseconds / 1000.0 : null;
    } else if (!packet.isCharging && wasCharging) {
      _lastChargeOffAt = now;
      _lastUndockChargeOffDelaySec = (!packet.isDocked && _undockedAt != null)
          ? now.difference(_undockedAt!).inMilliseconds / 1000.0
          : null;
    }

    _pitchHistory.add(double.parse(packet.pitchAngleDeg.toStringAsFixed(1)));
    if (_pitchHistory.length > 40) _pitchHistory.removeAt(0);

    _rebuildVision();
    notifyListeners();
  }

  // robot telemetrisi + kamera tespitinden anlık hareket durumunu üretir
  void _rebuildVision() {
    final t = _latestTelemetry;
    if (t == null) {
      _latestVision = VisionFrameResult(
        timestamp: DateTime.now(),
        medicineBoxPresent: false,
        isDocked: false,
        distanceTraveledMeters: 0.0,
        signedDistanceMeters: 0.0,
        accumulatedRotationDeg: 0.0,
        instantaneousSpeedMps: 0.0,
        yawRateDps: 0.0,
        movementState: MovementState.staticBalance,
        movementDirection: MovementDirection.none,
        camera: _cameraMotion,
      );
      return;
    }

    final double pitchAbs = t.pitchAngleDeg.abs();
    final bool sensorsTurning = _yawRateDps.abs() >= 15.0;
    final bool sensorsMoving = _speedMps.abs() >= 0.03;
    final bool cameraSaysMoving = _cameraMotion.cameraActive && _cameraMotion.motionDetected;

    MovementState state;
    MovementDirection dir = MovementDirection.none;
    if (pitchAbs >= 35.0) {
      state = MovementState.fallen;
    } else if (t.isDocked) {
      state = MovementState.docked;
    } else if (pitchAbs >= 6.5) {
      state = MovementState.recovering;
    } else if (sensorsTurning) {
      state = MovementState.turning;
      dir = _yawRateDps > 0 ? MovementDirection.right : MovementDirection.left;
    } else if (sensorsMoving) {
      state = MovementState.moving;
      dir = _speedMps > 0 ? MovementDirection.forward : MovementDirection.backward;
    } else if (cameraSaysMoving && t.lastGloveCommand.isMotion) {
      // enkoder henüz yakalamadan kamera hareketi gördüyse
      state = t.lastGloveCommand.isTurn ? MovementState.turning : MovementState.moving;
    } else {
      state = MovementState.staticBalance;
    }

    final double dist = _displayDist;
    _latestVision = VisionFrameResult(
      timestamp: DateTime.now(),
      medicineBoxPresent: t.boxPresent,
      isDocked: t.isDocked,
      distanceTraveledMeters: dist.abs(),
      signedDistanceMeters: dist,
      accumulatedRotationDeg: _displayYaw,
      instantaneousSpeedMps: _speedMps,
      yawRateDps: _yawRateDps,
      movementState: state,
      movementDirection: dir,
      camera: _cameraMotion,
    );
  }

  Future<void> _startUdpListener() async {
    if (kIsWeb) return;
    try {
      _udpSocket?.close();
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: true,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        Datagram? dg;
        while ((dg = _udpSocket?.receive()) != null) {
          final payload = utf8.decode(dg!.data, allowMalformed: true).trim();
          if (payload.startsWith('{')) ingestHardwareJsonPacket(payload);
        }
      });
    } catch (_) {
      // soket açılamazsa birkaç saniye sonra tekrar dene
      Future.delayed(const Duration(seconds: 3), _startUdpListener);
    }
  }

  void _sendToRobot(String text) {
    try {
      _udpSocket?.send(utf8.encode(text), InternetAddress(robotIp), udpPort);
    } catch (_) {}
  }

  Future<void> toggleRealCameraMode() async {
    await _cameraProcessor.toggleCameraMode();
  }

  Future<void> ensureCameraOn() async {
    await _cameraProcessor.ensureCameraOn();
  }

  void _startServices() {
    _startUdpListener();

    // robotun telefonu tanıması için düzenli HELLO; bekleyen RESET varsa onu tekrarla
    _helloTimer?.cancel();
    _helloTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!_resetAcked) {
        _sendToRobot('RESET:$_resetToken');
      } else if (timer.tick.isEven) {
        _sendToRobot('HELLO');
      }
    });

    // gerçek robottan paket gelip gelmediğini kontrol eden bağlantı bekçisi
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_lastRealHardwarePacketAt == null) {
        if (_connectionHealth != ConnectionHealth.waitingForRobot) {
          _connectionHealth = ConnectionHealth.waitingForRobot;
          notifyListeners();
        }
        return;
      }

      final elapsedMs = DateTime.now().difference(_lastRealHardwarePacketAt!).inMilliseconds;
      ConnectionHealth nextHealth;
      if (elapsedMs > 2000) {
        nextHealth = ConnectionHealth.disconnectedFault;
        _hadConnectionDropOver2Sec = true;
      } else if (elapsedMs > 1250) {
        nextHealth = ConnectionHealth.reconnectingWarning;
      } else {
        nextHealth = ConnectionHealth.connected1Hz;
      }

      if (nextHealth != _connectionHealth) {
        _connectionHealth = nextHealth;
        notifyListeners();
      }
    });
  }

  // mesafe ve dönüş sayaçlarını sıfırlar; robot onaylayana kadar yerel ofset kullanılır
  void resetRobotPosition() {
    final t = _latestTelemetry;
    _localDistOffset = t?.signedDistanceMeters ?? 0.0;
    _localYawOffset = t?.yawDeg ?? 0.0;
    _resetToken = (_resetToken % 9999) + 1;
    _resetAcked = false;
    _hadConnectionDropOver2Sec = false;
    _prevDist = null;
    _prevYaw = null;
    _speedMps = 0.0;
    _yawRateDps = 0.0;
    _sendToRobot('RESET:$_resetToken');
    _rebuildVision();
    notifyListeners();
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _helloTimer?.cancel();
    _udpSocket?.close();
    _cameraProcessor.dispose();
    super.dispose();
  }
}
