import 'telemetry_data.dart';

// Telefon kamerasında kare farkı ile bulunan hareketin ekrandaki yönü
enum CameraImageDirection {
  none('-'),
  left('Sola'),
  right('Sağa'),
  up('Yukarı'),
  down('Aşağı'),
  approaching('Yaklaşıyor'),
  receding('Uzaklaşıyor');

  final String label;
  const CameraImageDirection(this.label);
}

// Kamera hareket dedektörünün son çıktısı
class CameraMotionResult {
  final DateTime timestamp;
  final bool cameraActive; // görüntü akışı çalışıyor mu
  final bool motionDetected; // ardışık karelerde anlamlı değişim var mı
  final double motionRatio; // değişen hücre oranı (0..1)
  final double centroidX; // hareketli bölgenin ekran koordinatı (0..1, soldan sağa)
  final double centroidY; // (0..1, yukarıdan aşağı)
  final CameraImageDirection direction;

  const CameraMotionResult({
    required this.timestamp,
    required this.cameraActive,
    required this.motionDetected,
    required this.motionRatio,
    required this.centroidX,
    required this.centroidY,
    required this.direction,
  });

  factory CameraMotionResult.inactive() => CameraMotionResult(
        timestamp: DateTime.now(),
        cameraActive: false,
        motionDetected: false,
        motionRatio: 0.0,
        centroidX: 0.5,
        centroidY: 0.5,
        direction: CameraImageDirection.none,
      );

  String get summary {
    if (!cameraActive) return 'Kamera kapalı';
    if (!motionDetected) return 'Hareket yok';
    return direction == CameraImageDirection.none ? 'Hareket var' : 'Hareket · ${direction.label}';
  }
}

// Robot telemetrisi ve kamera tespitinin birleştirildiği anlık durum
class VisionFrameResult {
  final DateTime timestamp;
  final bool medicineBoxPresent;
  final bool isDocked;

  final double distanceTraveledMeters; // |konum| (RESET'ten beri)
  final double signedDistanceMeters; // ileri +, geri -
  final double accumulatedRotationDeg; // sağ +, sol -
  final double instantaneousSpeedMps; // ileri +, geri -
  final double yawRateDps;

  final MovementState movementState;
  final MovementDirection movementDirection;
  final CameraMotionResult camera;

  const VisionFrameResult({
    required this.timestamp,
    required this.medicineBoxPresent,
    required this.isDocked,
    required this.distanceTraveledMeters,
    required this.signedDistanceMeters,
    required this.accumulatedRotationDeg,
    required this.instantaneousSpeedMps,
    required this.yawRateDps,
    required this.movementState,
    required this.movementDirection,
    required this.camera,
  });

  // uygulama ilk açıldığında (robot henüz bağlanmadan önce) kullanılan sıfırlanmış değerler
  factory VisionFrameResult.initial() {
    return VisionFrameResult(
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
      camera: CameraMotionResult.inactive(),
    );
  }
}
