#!/usr/bin/env python3
# HDRG100 - iki tekerlekli denge robotu için LQR kazanç hesabı
#
# Kullanım:
#   pip3 install numpy
#   python3 lqr_hesapla.py
#
# Çıktıdaki "const float LQR_K[4] = {...};" satırını robot_ana_beyin.ino içindeki
# aynı satırın yerine yapıştırın.
#
# Model: doğrusallaştırılmış tekerlekli ters sarkaç (iki teker birlikte, düzlemsel)
#   durum  x = [teta (rad), teta_dot (rad/s), konum (m), hiz (m/s)]
#   giriş  u = her iki motora uygulanan gerilim (V)
#   kontrol u = -K x   (ayrık zamanlı, Ts = 5 ms -> 200 Hz)
#   teta > 0 : gövde ÖNE eğik,  konum/hiz > 0 : robot İLERİ gidiyor
#
# 9. haftada şasi kurulunca aşağıdaki "ÖLÇÜLECEK" değerleri tartı/cetvel ile güncelleyip
# betiği tekrar çalıştırın. Q/R ağırlıkları ince ayar içindir.

import numpy as np

# ---------------- fiziksel parametreler (ÖLÇÜLECEK) ----------------
m_govde = 1.40      # kg   - gövde + pil + elektronik + ilaç kutusu (tekerler hariç)
m_teker = 0.08      # kg   - tek teker + kaplin
r = 0.0325          # m    - teker yarıçapı (65 mm teker)
l = 0.11            # m    - teker ekseninden gövde ağırlık merkezine yükseklik
govde_yukseklik = 0.22  # m - eylemsizlik momenti yaklaşımı için
govde_derinlik = 0.08   # m
g = 9.81

# JGB37-520 12V 333 RPM (1:30) - redüktör çıkışına indirgenmiş değerler
Ke = 12.0 / (333.0 * 2 * np.pi / 60.0)  # V/(rad/s)  boşta hızdan: ~0.344
Kt = Ke                                  # N.m/A     (SI'da Kt = Ke kabulü)
R_motor = 8.0                            # ohm (etkin) - kilitli rotor akımından ölçülecek

# ---------------- LQR ağırlıkları (Bryson kuralı) ----------------
teta_max = np.deg2rad(3.0)   # rad
tetad_max = 1.5              # rad/s
konum_max = 0.15             # m
hiz_max = 0.40               # m/s
u_max = 6.0                  # V
Q = np.diag([1 / teta_max**2, 1 / tetad_max**2, 1 / konum_max**2, 1 / hiz_max**2])
R = np.array([[1 / u_max**2]])
Ts = 0.005  # s (200 Hz)

# ---------------- model ----------------
Ib = m_govde * (govde_yukseklik**2 + govde_derinlik**2) / 12.0
Iw = 0.5 * m_teker * r**2

M11 = m_govde + 2 * m_teker + 2 * Iw / r**2
M12 = m_govde * l
M22 = Ib + m_govde * l**2
M = np.array([[M11, M12], [M12, M22]])
Minv = np.linalg.inv(M)

# iki motorun toplam tork katsayıları:  tau = a*u - b*(hiz/r - teta_dot)
a = 2 * Kt / R_motor
b = 2 * Kt * Ke / R_motor

# [M] [konum_dd, teta_dd]^T = [ tau/r , m g l teta - tau ]^T
# tau = a u - (b/r) hiz + b teta_dot
def rhs_coeffs():
    # her satır: [teta, teta_dot, konum, hiz, u] katsayıları
    tau = np.array([0.0, b, 0.0, -b / r, a])
    row_x = tau / r
    row_t = -tau + np.array([m_govde * g * l, 0, 0, 0, 0])
    return np.vstack([row_x, row_t])

acc = Minv @ rhs_coeffs()  # 2x5 -> [konum_dd; teta_dd]
A = np.zeros((4, 4))
B = np.zeros((4, 1))
A[0, 1] = 1.0
A[2, 3] = 1.0
A[1, :] = acc[1, :4]
B[1, 0] = acc[1, 4]
A[3, :] = acc[0, :4]
B[3, 0] = acc[0, 4]


def expm(Mx):
    # ölçekle-kare al + Taylor serisi (scipy gerektirmesin diye)
    norm = np.linalg.norm(Mx, 1)
    s = max(0, int(np.ceil(np.log2(norm))) + 1) if norm > 0 else 0
    X = Mx / (2**s)
    E = np.eye(Mx.shape[0])
    term = np.eye(Mx.shape[0])
    for k in range(1, 25):
        term = term @ X / k
        E = E + term
    for _ in range(s):
        E = E @ E
    return E


# sıfırıncı derece tutucu ile ayrıklaştırma
aug = np.zeros((5, 5))
aug[:4, :4] = A
aug[:4, 4:] = B
Ead = expm(aug * Ts)
Ad = Ead[:4, :4]
Bd = Ead[:4, 4:]

# ayrık Riccati denklemi (yinelemeli çözüm)
P = Q.copy()
for _ in range(200000):
    BtP = Bd.T @ P
    Kd = np.linalg.solve(R + BtP @ Bd, BtP @ Ad)
    Pn = Q + Ad.T @ P @ Ad - Ad.T @ P @ Bd @ Kd
    if np.max(np.abs(Pn - P)) < 1e-10 * max(1.0, np.max(np.abs(P))):
        P = Pn
        break
    P = Pn
K = np.linalg.solve(R + Bd.T @ P @ Bd, Bd.T @ P @ Ad)

acik = np.linalg.eigvals(A)
kapali = np.linalg.eigvals(Ad - Bd @ K)

np.set_printoptions(precision=4, suppress=True)
print("Açık çevrim kutupları (sürekli):", acik)
print("Kapalı çevrim kutupları |z|   :", np.abs(kapali))
print("Kararlı mı (tümü |z|<1)       :", bool(np.all(np.abs(kapali) < 1.0)))
print()
print("K =", K.flatten())
print()
print("// lqr_hesapla.py çıktısı - robot_ana_beyin.ino içine yapıştırın")
print("const float LQR_K[4] = {%.4ff, %.4ff, %.4ff, %.4ff};" % tuple(K.flatten()))
