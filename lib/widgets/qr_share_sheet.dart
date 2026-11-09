import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// takım arkadaşlarının Android telefonlarına APK'yı QR okutarak indirebilmeleri için paylaşım penceresi.
// APK'yı bilgisayardaki QR_Ile_Telefona_Yukle.command betiği yayınlar; burada o adresin QR'ı gösterilir.
class QrAppShareSheet extends StatefulWidget {
  const QrAppShareSheet({super.key});

  static Future<void> show(BuildContext context) async {
    // adres, bilgisayardaki betiğin ekrana yazdığı adresle değiştirilir
    String initialUrl = 'http://192.168.1.100:8080/';
    if (kIsWeb) initialUrl = Uri.base.origin;

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _QrShareContent(initialUrl: initialUrl),
    );
  }

  @override
  State<QrAppShareSheet> createState() => _QrAppShareSheetState();
}

class _QrAppShareSheetState extends State<QrAppShareSheet> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _QrShareContent extends StatefulWidget {
  final String initialUrl;
  const _QrShareContent({required this.initialUrl});

  @override
  State<_QrShareContent> createState() => _QrShareContentState();
}

class _QrShareContentState extends State<_QrShareContent> {
  late final TextEditingController _urlController;
  late String _activeUrl;

  @override
  void initState() {
    super.initState();
    _activeUrl = widget.initialUrl;
    _urlController = TextEditingController(text: _activeUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  // üzerine dokunulduğunda QR kodu tam ekran büyüten pencere
  void _showEnlargedQrDialog(BuildContext context, List<List<bool>> matrix) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) {
          final media = MediaQuery.of(ctx).size;
          final double qrSize = math.min(media.width, media.height) - 24;
          return Scaffold(
            backgroundColor: Colors.white,
            appBar: AppBar(
              backgroundColor: Colors.white,
              elevation: 0,
              title: const Text(
                'QR Kodu Okutun',
                style: TextStyle(
                  color: Color(0xFF1C1C1E),
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              leading: IconButton(
                icon: const Icon(Icons.close_rounded, color: Color(0xFF1C1C1E), size: 28),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: qrSize,
                      height: qrSize,
                      child: CustomPaint(
                        size: Size.square(qrSize),
                        painter: _QrMatrixPainter(matrix: matrix),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _activeUrl,
                      style: const TextStyle(
                        color: Color(0xFF1C1C1E),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Küçültmek için ekrana dokunun',
                      style: TextStyle(
                        color: Color(0xFF8E8E93),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matrix = _SimpleQrEncoder.encode(_activeUrl);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 24 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFD1D1D6),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'QR ile Android\'e Yükle (APK)',
            style: TextStyle(
              color: Color(0xFF1C1C1E),
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Bilgisayarda scripts/QR_Ile_Telefona_Yukle.command dosyasını açın, ekrandaki adresi aşağıya yazın ve aynı ağdaki telefona bu kodu okutun.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showEnlargedQrDialog(context, matrix),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFE5E5EA), width: 1.5),
                  ),
                  child: SizedBox(
                    width: 220,
                    height: 220,
                    child: CustomPaint(
                      size: const Size.square(220),
                      painter: _QrMatrixPainter(matrix: matrix),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.zoom_in_rounded, size: 17, color: Color(0xFFFF2D55)),
                      SizedBox(width: 5),
                      Text(
                        'Tam ekran büyütmek için dokunun',
                        style: TextStyle(
                          color: Color(0xFFFF2D55),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  onChanged: (v) {
                    if (v.trim().isNotEmpty) {
                      setState(() => _activeUrl = v.trim());
                    }
                  },
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1C1C1E),
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF2F2F7),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.link_rounded, size: 18, color: Color(0xFFFF2D55)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _activeUrl));
                  HapticFeedback.selectionClick();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Bağlantı adresi kopyalandı'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                tooltip: 'Adresi Kopyala',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '• Android: QR okutun -> HDRG100.apk iner -> açıp "Bu kaynaktan yüklemeye izin ver" -> Yükle.',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF1C1C1E)),
                ),
                SizedBox(height: 5),
                Text(
                  '• iPhone: Mac\'e kabloyla bağlayıp proje klasöründe "flutter run --release" ile kurulur.',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF1C1C1E)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QrMatrixPainter extends CustomPainter {
  final List<List<bool>> matrix;
  _QrMatrixPainter({required this.matrix});

  @override
  void paint(Canvas canvas, Size size) {
    final int n = matrix.length;
    if (n == 0) return;

    // telefon kameralarının QR kodu anında tanıması için standart 4 birimlik beyaz çerçeve (quiet zone)
    const int quietZone = 4;
    final int totalModules = n + quietZone * 2;
    final double cell = size.width / totalModules;

    final bgPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final darkPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        if (matrix[r][c]) {
          final double left = ((c + quietZone) * cell).roundToDouble();
          final double top = ((r + quietZone) * cell).roundToDouble();
          final double right = ((c + quietZone + 1) * cell).roundToDouble();
          final double bottom = ((r + quietZone + 1) * cell).roundToDouble();
          canvas.drawRect(
            Rect.fromLTRB(left, top, right, bottom),
            darkPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrMatrixPainter oldDelegate) =>
      oldDelegate.matrix != matrix;
}

// harici paket gerektirmeden ISO/IEC 18004 (Byte modu, Seviye L) QR matrisi üreten sınıf
class _SimpleQrEncoder {
  // versiyon 1..4 için [toplam veri byte, ec byte, boyut]
  static const List<List<int>> _versions = [
    [19, 7, 21, 0],
    [34, 10, 25, 18],
    [55, 15, 29, 22],
    [80, 20, 33, 26],
  ];

  static List<List<bool>> encode(String text) {
    List<int> bytes = utf8.encode(text);
    if (bytes.length > 78) {
      bytes = bytes.sublist(0, 78);
    }

    int verIdx = 0;
    for (int i = 0; i < _versions.length; i++) {
      if (bytes.length + 2 <= _versions[i][0]) {
        verIdx = i;
        break;
      }
    }

    final int dataCap = _versions[verIdx][0];
    final int ecLen = _versions[verIdx][1];
    final int size = _versions[verIdx][2];
    final int alignPos = _versions[verIdx][3];

    // bit akışını hazırla: 0100 (byte modu) + 8-bit uzunluk + veri + 0000 + dolgu byte'ları
    final List<int> bits = [];
    void pushBits(int val, int count) {
      for (int i = count - 1; i >= 0; i--) {
        bits.add((val >> i) & 1);
      }
    }

    pushBits(0x4, 4);
    pushBits(bytes.length, 8);
    for (final b in bytes) {
      pushBits(b, 8);
    }
    for (int i = 0; i < 4 && bits.length < dataCap * 8; i++) {
      bits.add(0);
    }
    while (bits.length % 8 != 0) {
      bits.add(0);
    }

    final List<int> dataCw = [];
    for (int i = 0; i < bits.length; i += 8) {
      int b = 0;
      for (int j = 0; j < 8; j++) {
        b = (b << 1) | bits[i + j];
      }
      dataCw.add(b);
    }

    int padToggle = 0;
    while (dataCw.length < dataCap) {
      dataCw.add(padToggle == 0 ? 0xEC : 0x11);
      padToggle ^= 1;
    }

    final List<int> ecCw = _reedSolomonEncode(dataCw, ecLen);
    final List<int> allCw = [...dataCw, ...ecCw];

    final List<List<bool>> modules =
        List.generate(size, (_) => List.filled(size, false));
    final List<List<bool>> isFunc =
        List.generate(size, (_) => List.filled(size, false));

    void setFunc(int r, int c, bool dark) {
      if (r < 0 || r >= size || c < 0 || c >= size) return;
      modules[r][c] = dark;
      isFunc[r][c] = true;
    }

    void drawFinder(int topR, int leftC) {
      for (int dr = -1; dr <= 7; dr++) {
        for (int dc = -1; dc <= 7; dc++) {
          final int r = topR + dr;
          final int c = leftC + dc;
          final bool dark = (dr >= 0 &&
                  dr <= 6 &&
                  dc >= 0 &&
                  dc <= 6) &&
              (dr == 0 ||
                  dr == 6 ||
                  dc == 0 ||
                  dc == 6 ||
                  (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4));
          setFunc(r, c, dark);
        }
      }
    }

    drawFinder(0, 0);
    drawFinder(0, size - 7);
    drawFinder(size - 7, 0);

    for (int i = 8; i < size - 8; i++) {
      setFunc(6, i, i % 2 == 0);
      setFunc(i, 6, i % 2 == 0);
    }

    if (alignPos > 0) {
      for (int dr = -2; dr <= 2; dr++) {
        for (int dc = -2; dc <= 2; dc++) {
          final int dist = dr.abs() > dc.abs() ? dr.abs() : dc.abs();
          setFunc(alignPos + dr, alignPos + dc, dist != 1);
        }
      }
    }

    // format bitleri için yer ayır
    for (int i = 0; i <= 8; i++) {
      if (i != 6) {
        isFunc[8][i] = true;
        isFunc[i][8] = true;
      }
    }
    for (int i = 0; i < 8; i++) {
      isFunc[8][size - 1 - i] = true;
      isFunc[size - 1 - i][8] = true;
    }
    setFunc(size - 8, 8, true);

    // veri bitlerini zikzak olarak yerleştir
    int bitIdx = 0;
    final int totalBits = allCw.length * 8;
    for (int right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (int vert = 0; vert < size; vert++) {
        for (int j = 0; j < 2; j++) {
          final int c = right - j;
          final bool upward = ((right + 1) & 2) == 0;
          final int r = upward ? (size - 1 - vert) : vert;
          if (!isFunc[r][c]) {
            bool dark = false;
            if (bitIdx < totalBits) {
              dark = ((allCw[bitIdx >> 3] >> (7 - (bitIdx & 7))) & 1) != 0;
              bitIdx++;
            }
            // maske 0: (r + c) % 2 == 0
            if ((r + c) % 2 == 0) {
              dark = !dark;
            }
            modules[r][c] = dark;
          }
        }
      }
    }

    // Seviye L (01) ve Maske 0 (000) için önceden hesaplanmış BCH format değeri = 0x77C4
    const int formatBits = 0x77C4;
    bool fBit(int i) => ((formatBits >> i) & 1) != 0;

    for (int i = 0; i <= 5; i++) {
      modules[8][i] = fBit(14 - i);
    }
    modules[8][7] = fBit(8);
    modules[8][8] = fBit(7);
    modules[7][8] = fBit(6);
    for (int i = 9; i < 15; i++) {
      modules[14 - i][8] = fBit(14 - i);
    }

    for (int i = 0; i < 8; i++) {
      modules[8][size - 1 - i] = fBit(i);
    }
    for (int i = 8; i < 15; i++) {
      modules[size - 15 + i][8] = fBit(i);
    }

    return modules;
  }

  static List<int> _reedSolomonEncode(List<int> data, int ecLen) {
    final List<int> exp = List.filled(512, 0);
    final List<int> log = List.filled(256, 0);
    int x = 1;
    for (int i = 0; i < 255; i++) {
      exp[i] = x;
      log[x] = i;
      x <<= 1;
      if ((x & 0x100) != 0) x ^= 0x11D;
    }
    for (int i = 255; i < 512; i++) {
      exp[i] = exp[i - 255];
    }

    int gfMul(int a, int b) {
      if (a == 0 || b == 0) return 0;
      return exp[log[a] + log[b]];
    }

    List<int> gen = [1];
    for (int i = 0; i < ecLen; i++) {
      final List<int> next = List.filled(gen.length + 1, 0);
      for (int j = 0; j < gen.length; j++) {
        next[j] ^= gen[j];
        next[j + 1] ^= gfMul(gen[j], exp[i]);
      }
      gen = next;
    }

    final List<int> rem = List.filled(ecLen, 0);
    for (final b in data) {
      final int factor = b ^ rem[0];
      for (int i = 0; i < ecLen - 1; i++) {
        rem[i] = rem[i + 1] ^ gfMul(gen[i + 1], factor);
      }
      rem[ecLen - 1] = gfMul(gen[ecLen], factor);
    }
    return rem;
  }
}

