#!/bin/zsh
# Çift tıkladığında HDRG100 mobil uygulamasını yerel Wi-Fi / Hotspot üzerinden yayına açar
# ve ekranda hem iPhone (iOS) hem Android telefonların okutup yükleyebileceği bir QR kod gösterir.

cd "$(dirname "$0")/.."

# Robotla UDP haberleşmesi ve kamera tespiti yalnızca yerel (native) uygulamada çalışır;
# bu yüzden Android için APK dağıtılır. iPhone'a kurulum Mac'e kabloyla bağlanıp yapılır
# (bkz. aşağıdaki iPhone notu).
DIST_DIR="build/dagitim"
APK_SRC="build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK_SRC" ] || [ -n "$(find lib pubspec.yaml android -newer "$APK_SRC" -type f 2>/dev/null | head -n 1)" ]; then
  echo "HDRG100 Android APK paketi hazırlanıyor (birkaç dakika sürebilir)..."
  flutter build apk --release || { echo "APK derlenemedi"; read -r; exit 1; }
fi
mkdir -p "$DIST_DIR"
cp "$APK_SRC" "$DIST_DIR/HDRG100.apk"

LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null)
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP=$(ipconfig getifaddr en1 2>/dev/null)
fi
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1)
fi
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP="192.168.4.1"
fi

PORT=8080
APP_URL="http://${LOCAL_IP}:${PORT}/"
APK_URL="${APP_URL}HDRG100.apk"

# İnternet olmasa bile çalışan çevrimdışı (offline) SVG QR kodlu indirme sayfası (index.html) üret
python3 - "$APP_URL" << 'PYEOF'
import sys

url = sys.argv[1]
data_bytes = url.encode("utf-8")[:78]

versions = [
    (19, 7, 21, 0),
    (34, 10, 25, 18),
    (55, 15, 29, 22),
    (80, 20, 33, 26),
]
for cap, ec_len, size, align_pos in versions:
    if len(data_bytes) + 2 <= cap:
        break

bits = []
def push_bits(val, count):
    for i in range(count - 1, -1, -1):
        bits.append((val >> i) & 1)

push_bits(0x4, 4)
push_bits(len(data_bytes), 8)
for b in data_bytes:
    push_bits(b, 8)
for _ in range(min(4, cap * 8 - len(bits))):
    bits.append(0)
while len(bits) % 8 != 0:
    bits.append(0)

data_cw = []
for i in range(0, len(bits), 8):
    v = 0
    for j in range(8):
        v = (v << 1) | bits[i + j]
    data_cw.append(v)

pad = 0
while len(data_cw) < cap:
    data_cw.append(0xEC if pad == 0 else 0x11)
    pad ^= 1

exp = [0] * 512
log = [0] * 256
x = 1
for i in range(255):
    exp[i] = x
    log[x] = i
    x <<= 1
    if x & 0x100:
        x ^= 0x11D
for i in range(255, 512):
    exp[i] = exp[i - 255]

def gf_mul(a, b):
    return 0 if (a == 0 or b == 0) else exp[log[a] + log[b]]

gen = [1]
for i in range(ec_len):
    nxt = [0] * (len(gen) + 1)
    for j in range(len(gen)):
        nxt[j] ^= gen[j]
        nxt[j + 1] ^= gf_mul(gen[j], exp[i])
    gen = nxt

rem = [0] * ec_len
for b in data_cw:
    factor = b ^ rem[0]
    for i in range(ec_len - 1):
        rem[i] = rem[i + 1] ^ gf_mul(gen[i + 1], factor)
    rem[ec_len - 1] = gf_mul(gen[ec_len], factor)

all_cw = data_cw + rem
modules = [[False] * size for _ in range(size)]
is_func = [[False] * size for _ in range(size)]

def set_func(r, c, dark):
    if 0 <= r < size and 0 <= c < size:
        modules[r][c] = dark
        is_func[r][c] = True

def draw_finder(tr, lc):
    for dr in range(-1, 8):
        for dc in range(-1, 8):
            dark = (0 <= dr <= 6 and 0 <= dc <= 6) and (
                dr in (0, 6) or dc in (0, 6) or (2 <= dr <= 4 and 2 <= dc <= 4)
            )
            set_func(tr + dr, lc + dc, dark)

draw_finder(0, 0)
draw_finder(0, size - 7)
draw_finder(size - 7, 0)

for i in range(8, size - 8):
    set_func(6, i, i % 2 == 0)
    set_func(i, 6, i % 2 == 0)

if align_pos > 0:
    for dr in range(-2, 3):
        for dc in range(-2, 3):
            set_func(align_pos + dr, align_pos + dc, max(abs(dr), abs(dc)) != 1)

for i in range(9):
    if i != 6:
        is_func[8][i] = True
        is_func[i][8] = True
for i in range(8):
    is_func[8][size - 1 - i] = True
    is_func[size - 1 - i][8] = True
set_func(size - 8, 8, True)

bit_idx = 0
total_bits = len(all_cw) * 8
right = size - 1
while right >= 1:
    if right == 6:
        right = 5
    for vert in range(size):
        for j in range(2):
            c = right - j
            upward = ((right + 1) & 2) == 0
            r = (size - 1 - vert) if upward else vert
            if not is_func[r][c]:
                dark = False
                if bit_idx < total_bits:
                    dark = ((all_cw[bit_idx >> 3] >> (7 - (bit_idx & 7))) & 1) != 0
                    bit_idx += 1
                if (r + c) % 2 == 0:
                    dark = not dark
                modules[r][c] = dark
    right -= 2

fmt = 0x77C4
def fbit(i):
    return ((fmt >> i) & 1) != 0

for i in range(6):
    modules[8][i] = fbit(14 - i)
modules[8][7] = fbit(8)
modules[8][8] = fbit(7)
modules[7][8] = fbit(6)
for i in range(9, 15):
    modules[14 - i][8] = fbit(14 - i)
for i in range(8):
    modules[8][size - 1 - i] = fbit(i)
for i in range(8, 15):
    modules[size - 15 + i][8] = fbit(i)

rects = []
q = 4
tot = size + q * 2
for r in range(size):
    for c in range(size):
        if modules[r][c]:
            rects.append(f'<rect x="{c+q}" y="{r+q}" width="1" height="1" fill="#000000"/>')

svg = f'<svg viewBox="0 0 {tot} {tot}" width="280" height="280" shape-rendering="crispEdges" xmlns="http://www.w3.org/2000/svg"><rect width="{tot}" height="{tot}" fill="#FFFFFF"/>{"".join(rects)}</svg>'

html = f"""<!DOCTYPE html>
<html lang="tr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>HDRG100 - QR ile Telefona Yükle</title>
  <style>
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #F2F2F7;
      color: #1C1C1E;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
    }}
    .card {{
      background: #fff;
      border-radius: 24px;
      padding: 32px 28px;
      max-width: 440px;
      width: 90%;
      text-align: center;
      box-shadow: 0 10px 30px rgba(0,0,0,0.08);
      border: 1px solid #E5E5EA;
    }}
    h1 {{ font-size: 22px; margin: 0 0 6px; }}
    p.sub {{ color: #8E8E93; font-size: 13.5px; margin: 0 0 18px; }}
    .qr-box {{
      display: inline-block;
      padding: 12px;
      border: 2px solid #E5E5EA;
      border-radius: 18px;
      background: #fff;
      cursor: zoom-in;
      transition: transform 0.2s ease;
    }}
    .qr-box.zoomed {{
      position: fixed;
      inset: 0;
      margin: auto;
      z-index: 999;
      width: min(82vw, 82vh);
      height: min(82vw, 82vh);
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 0 0 9999px rgba(0,0,0,0.82);
      cursor: zoom-out;
    }}
    .qr-box.zoomed svg {{
      width: 100%;
      height: 100%;
    }}
    .zoom-hint {{
      color: #FF2D55;
      font-size: 12.5px;
      font-weight: 600;
      margin: 6px 0 14px;
    }}
    .url-pill {{
      display: inline-block;
      background: #FFEBEF;
      color: #FF2D55;
      font-weight: 700;
      font-size: 14px;
      padding: 8px 14px;
      border-radius: 10px;
      margin-bottom: 18px;
      text-decoration: none;
    }}
    .steps {{
      text-align: left;
      background: #F2F2F7;
      padding: 14px 16px;
      border-radius: 14px;
      font-size: 13px;
      line-height: 1.5;
    }}
    .steps div + div {{ margin-top: 8px; }}
  </style>
</head>
<body>
  <div class="card">
    <h1>HDRG100 Mobil Uygulama</h1>
    <p class="sub"><b>Android</b> telefonun kamerasıyla okutup APK'yı indirin</p>
    <div class="qr-box" onclick="this.classList.toggle('zoomed')" title="Büyütmek için tıklayın">{svg}</div>
    <div class="zoom-hint">🔍 Büyütmek için QR koda dokunun</div>
    <a class="url-pill" href="{url}HDRG100.apk">{url}HDRG100.apk</a>
    <div class="steps">
      <div><b>Android:</b> QR kodu okutun &rarr; <b>HDRG100.apk</b> iner &rarr; açın &rarr; istenirse <b>"Bu kaynaktan yüklemeye izin ver"</b> &rarr; <b>Yükle</b>.</div>
      <div><b>iPhone (iOS):</b> Telefonu bu Mac'e kabloyla bağlayın, proje klasöründe <code>flutter run --release</code> çalıştırın (Xcode'da ücretsiz Apple ID ile imzalama). Ardından iPhone'da Ayarlar &rarr; Genel &rarr; VPN ve Aygıt Yönetimi'nden geliştiriciye güvenin.</div>
      <div><b>Kullanım:</b> Telefonu <b>HDRG100-Robot</b> Wi-Fi ağına (şifre 12345678) bağlayıp uygulamayı açın.</div>
    </div>
  </div>
</body>
</html>
"""

with open("build/dagitim/index.html", "w", encoding="utf-8") as f:
    f.write(html)
PYEOF

echo "========================================================"
echo "  HDRG100 - QR İLE ANDROID APK YÜKLEME SUNUCUSU"
echo "  Uygulama Adresi: ${APP_URL}"
echo "  QR Kod Sayfası : http://localhost:${PORT}/"
echo "========================================================"

(sleep 1 && open "http://localhost:${PORT}/") &
python3 -m http.server ${PORT} --directory "$DIST_DIR"
