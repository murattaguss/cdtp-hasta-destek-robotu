import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import '../models/vision_data.dart';

// Telefonun arka kamerasını yönetir ve görüntü akışında kare farkı (frame differencing)
// yöntemiyle robotun hareketini ve ekrandaki hareket yönünü tespit eder.
//
// Yöntem: her ~120 ms'de bir karenin parlaklık (Y) kanalı 48x36 hücreye indirgenir,
// bir önceki kareyle farkı alınır; eşik üstü hücreler "hareketli" sayılır. Hareketli
// bölgenin ağırlık merkezi ve kapladığı alanın son ~1,2 sn'deki değişiminden
// sola/sağa/yukarı/aşağı veya yaklaşıyor/uzaklaşıyor yönü çıkarılır.
class CameraVisionProcessor {
  CameraController? _cameraController;
  bool _isInitialized = false;
  bool _useRealCamera = false;
  bool _isInitializing = false;
  bool _streaming = false;
  String? _statusMessage;

  final void Function(CameraMotionResult result) onMotionUpdated;
  final VoidCallback onStateChanged;

  CameraVisionProcessor({
    required this.onMotionUpdated,
    required this.onStateChanged,
  });

  CameraController? get cameraController => _cameraController;
  bool get isCameraAvailable =>
      _isInitialized && _cameraController != null && _cameraController!.value.isInitialized;
  bool get isUsingRealCamera => _useRealCamera && isCameraAvailable;
  bool get isInitializing => _isInitializing;
  String? get statusMessage => _statusMessage;

  // ---- hareket dedektörü durumu ----
  static const int _gridW = 48;
  static const int _gridH = 36;
  static const int _diffThreshold = 22;
  static const double _minMotionRatio = 0.006;
  static const double _maxMotionRatio = 0.55; // bundan fazlası kamera sarsıntısı/ışık değişimi
  static const int _processIntervalMs = 120;

  Uint8List? _prevGrid;
  bool _busy = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  final List<bool> _recentMotion = [];
  final List<_MotionSample> _history = [];

  Future<void> initializeCamera() async {
    if (kIsWeb || _isInitializing) return;
    _isInitializing = true;
    _statusMessage = null;
    onStateChanged();

    try {
      await _stopStream();
      await _cameraController?.dispose();
      _cameraController = null;
      _isInitialized = false;

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _statusMessage = 'Kamera bulunamadı';
        _useRealCamera = false;
        _isInitializing = false;
        onStateChanged();
        return;
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup:
            Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();
      _cameraController = controller;
      _isInitialized = true;
      _useRealCamera = true;
      _isInitializing = false;
      await _startStream();
      onStateChanged();
    } catch (_) {
      _isInitialized = false;
      _useRealCamera = false;
      _isInitializing = false;
      _statusMessage = 'Kamera izni gerekli (Ayarlar > Kamera)';
      onStateChanged();
    }
  }

  // test başlarken kamera kapalıysa otomatik açılır
  Future<void> ensureCameraOn() async {
    if (isUsingRealCamera) return;
    if (isCameraAvailable) {
      _useRealCamera = true;
      await _startStream();
      onStateChanged();
      return;
    }
    await initializeCamera();
  }

  Future<void> toggleCameraMode() async {
    if (isUsingRealCamera) {
      _useRealCamera = false;
      await _stopStream();
      onMotionUpdated(CameraMotionResult.inactive());
      onStateChanged();
    } else {
      await ensureCameraOn();
    }
  }

  Future<void> _startStream() async {
    final c = _cameraController;
    if (c == null || _streaming || !c.value.isInitialized) return;
    _prevGrid = null;
    _recentMotion.clear();
    _history.clear();
    try {
      await c.startImageStream(_onFrame);
      _streaming = true;
    } catch (_) {
      _streaming = false;
      _statusMessage = 'Kamera görüntü akışı başlatılamadı';
    }
  }

  Future<void> _stopStream() async {
    final c = _cameraController;
    if (c == null || !_streaming) return;
    try {
      await c.stopImageStream();
    } catch (_) {}
    _streaming = false;
  }

  void _onFrame(CameraImage image) {
    final now = DateTime.now();
    if (_busy || now.difference(_lastProcessed).inMilliseconds < _processIntervalMs) return;
    _busy = true;
    _lastProcessed = now;
    try {
      final grid = _toLumaGrid(image);
      if (grid == null) return;
      final prev = _prevGrid;
      _prevGrid = grid;
      if (prev == null) return;
      onMotionUpdated(_analyze(prev, grid, now));
    } catch (_) {
      // bozuk kare gelirse atla
    } finally {
      _busy = false;
    }
  }

  // görüntünün parlaklık kanalını 48x36 hücreye indirger (her hücrede 4 örnek ortalaması)
  Uint8List? _toLumaGrid(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final int rowStride = plane.bytesPerRow;
    final bool bgra = image.format.group == ImageFormatGroup.bgra8888;
    final int pixelStride = bgra ? 4 : (plane.bytesPerPixel ?? 1);
    final int channelOffset = bgra ? 1 : 0; // BGRA'da G kanalı parlaklığa en yakın
    final int w = image.width;
    final int h = image.height;
    final grid = Uint8List(_gridW * _gridH);

    for (int gy = 0; gy < _gridH; gy++) {
      final int y0 = ((gy + 0.33) * h / _gridH).floor();
      final int y1 = ((gy + 0.66) * h / _gridH).floor();
      for (int gx = 0; gx < _gridW; gx++) {
        final int x0 = ((gx + 0.33) * w / _gridW).floor();
        final int x1 = ((gx + 0.66) * w / _gridW).floor();
        int sum = 0;
        sum += bytes[y0 * rowStride + x0 * pixelStride + channelOffset];
        sum += bytes[y0 * rowStride + x1 * pixelStride + channelOffset];
        sum += bytes[y1 * rowStride + x0 * pixelStride + channelOffset];
        sum += bytes[y1 * rowStride + x1 * pixelStride + channelOffset];
        grid[gy * _gridW + gx] = sum >> 2;
      }
    }
    return grid;
  }

  CameraMotionResult _analyze(Uint8List prev, Uint8List cur, DateTime now) {
    // otomatik pozlama değişimini telafi etmek için ortalama parlaklık farkını çıkar
    int sumPrev = 0, sumCur = 0;
    for (int i = 0; i < cur.length; i++) {
      sumPrev += prev[i];
      sumCur += cur[i];
    }
    final int bias = ((sumCur - sumPrev) / cur.length).round();

    int count = 0;
    double sx = 0, sy = 0;
    int minX = _gridW, maxX = -1, minY = _gridH, maxY = -1;
    for (int gy = 0; gy < _gridH; gy++) {
      for (int gx = 0; gx < _gridW; gx++) {
        final int i = gy * _gridW + gx;
        if ((cur[i] - prev[i] - bias).abs() > _diffThreshold) {
          count++;
          sx += gx;
          sy += gy;
          if (gx < minX) minX = gx;
          if (gx > maxX) maxX = gx;
          if (gy < minY) minY = gy;
          if (gy > maxY) maxY = gy;
        }
      }
    }

    final double ratio = count / cur.length;
    final bool frameMotion = ratio >= _minMotionRatio && ratio <= _maxMotionRatio;
    _recentMotion.add(frameMotion);
    if (_recentMotion.length > 3) _recentMotion.removeAt(0);
    final bool motion = _recentMotion.where((m) => m).length >= 2;

    double cx = 0.5, cy = 0.5;
    if (frameMotion && count > 0) {
      // sensör koordinatından telefonun dikey ekran koordinatına çevir
      final double ix = (sx / count + 0.5) / _gridW;
      final double iy = (sy / count + 0.5) / _gridH;
      final int rot = _cameraController?.description.sensorOrientation ?? 90;
      switch (rot) {
        case 90:
          cx = 1.0 - iy;
          cy = ix;
          break;
        case 270:
          cx = iy;
          cy = 1.0 - ix;
          break;
        case 180:
          cx = 1.0 - ix;
          cy = 1.0 - iy;
          break;
        default:
          cx = ix;
          cy = iy;
      }
      final double area = ((maxX - minX + 1) * (maxY - minY + 1)) / (_gridW * _gridH);
      _history.add(_MotionSample(now, cx, cy, area));
    }
    _history.removeWhere((s) => now.difference(s.time).inMilliseconds > 1200);

    CameraImageDirection dir = CameraImageDirection.none;
    if (motion && _history.length >= 3) {
      final first = _history.first;
      final last = _history.last;
      final double dx = last.cx - first.cx;
      final double dy = last.cy - first.cy;
      final double areaRatio = first.area > 0 ? last.area / first.area : 1.0;
      if (dx.abs() >= 0.06 || dy.abs() >= 0.06) {
        if (dx.abs() >= dy.abs()) {
          dir = dx > 0 ? CameraImageDirection.right : CameraImageDirection.left;
        } else {
          dir = dy > 0 ? CameraImageDirection.down : CameraImageDirection.up;
        }
      } else if (areaRatio >= 1.25) {
        dir = CameraImageDirection.approaching;
      } else if (areaRatio <= 0.8) {
        dir = CameraImageDirection.receding;
      }
    }

    return CameraMotionResult(
      timestamp: now,
      cameraActive: true,
      motionDetected: motion,
      motionRatio: ratio,
      centroidX: cx,
      centroidY: cy,
      direction: dir,
    );
  }

  void dispose() {
    _stopStream();
    _cameraController?.dispose();
  }
}

class _MotionSample {
  final DateTime time;
  final double cx;
  final double cy;
  final double area;
  _MotionSample(this.time, this.cx, this.cy, this.area);
}
