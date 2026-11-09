// robot ana kontrol kodu (esp32) - LQR durum geri beslemeli denge
//
// pin bağlantıları özeti:
// - mpu6050: sda -> gpio 21, scl -> gpio 22, vcc -> 3.3V, gnd -> GND
// - sol bts7960b sürücü: rpwm -> gpio 25, lpwm -> gpio 26 (r_en ve l_en -> 3.3V/5V)
// - sağ bts7960b sürücü: rpwm -> gpio 27, lpwm -> gpio 14 (r_en ve l_en -> 3.3V/5V)
// - sol motor enkoder (jgb37-520): faz A -> gpio 32, faz B -> gpio 33
// - sağ motor enkoder (jgb37-520): faz A -> gpio 18, faz B -> gpio 19
// - tsop4038 38khz ir alıcılar: sol -> gpio 16, orta -> gpio 17, sağ -> gpio 5
// - dc171 micro switchler: ilaç kutusu -> gpio 4, şarj istasyonu teması -> gpio 15 (diğer uçları GND)
// - batarya gerilimi (33k + 10k bölücü, BMS P+ tarafı): orta uç -> gpio 34
// - şarj girişi gerilimi (33k + 10k bölücü, şarj pedi + ucu, 1N5822'den ÖNCE): orta uç -> gpio 35
//
// denge kontrolü:
//   durum x = [eğim (rad), eğim hızı (rad/s), tekerlek konumu (m), tekerlek hızı (m/s)]
//   u = -K (x - x_ref)   [volt]  ->  pwm = u / pil_gerilimi * 255
//   K matrisi esp32_firmware/lqr_tasarim/lqr_hesapla.py ile hesaplanır (Ts = 5 ms).
//
// seri monitör (115200) komutları: 'd' tanı çıktısını açar/kapatır,
//   'l' / 'r' robot HAVADAYKEN sol / sağ motoru 0,5 sn ileri yönde döndürür (yön testi).

#include <Arduino.h>
#include <Wire.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <esp_now.h>
#include <math.h>

// ======================= pinler =======================
const int PIN_I2C_SDA       = 21;
const int PIN_I2C_SCL       = 22;
const uint8_t MPU6050_ADDR  = 0x68;

const int PIN_LEFT_RPWM     = 25;
const int PIN_LEFT_LPWM     = 26;
const int PIN_RIGHT_RPWM    = 27;
const int PIN_RIGHT_LPWM    = 14;

const int PIN_ENC_LEFT_A    = 32;
const int PIN_ENC_LEFT_B    = 33;
const int PIN_ENC_RIGHT_A   = 18;
const int PIN_ENC_RIGHT_B   = 19;

// tsop4038 normalde HIGH, 38 khz ir görünce LOW
const int PIN_IR_LEFT       = 16;
const int PIN_IR_CENTER     = 17;
const int PIN_IR_RIGHT      = 5;

// dc171 (input_pullup, basılınca LOW)
const int PIN_SWITCH_BOX    = 4;
const int PIN_SWITCH_DOCK   = 15;

// adc1 pinleri (wifi açıkken adc2 kullanılamıyor)
const int PIN_BATTERY_ADC   = 34;
const int PIN_CHARGE_IN_ADC = 35;
const float DIVIDER_RATIO   = (33.0f + 10.0f) / 10.0f;  // 4.3

// ======================= LQR ve kontrol ayarları =======================
// lqr_hesapla.py çıktısı - şasi ölçülünce betik tekrar çalıştırılıp buraya yapıştırılır
const float LQR_K[4] = {-102.9819f, -8.0667f, -28.4655f, -41.2240f};

const float CONTROL_PERIOD_US   = 5000.0f;   // 200 Hz
const float FALL_CUTOFF_DEG     = 35.0f;     // bu açıyı aşınca motorlar kesilir
const float REARM_ANGLE_DEG     = 5.0f;      // devrildikten sonra bu açının içine dik tutulunca yeniden başlar
const unsigned long REARM_HOLD_MS = 500;
const float MAX_POS_ERROR_M     = 0.25f;     // konum hatası sınırı (ani sıçramayı önler)
const float MAX_MOTOR_VOLT      = 11.0f;

// sensör şasiye tam düz yapışmadıysa denge noktası buradan kaydırılır (tanı çıktısından okunur)
float balanceOffsetDeg = 0.0f;

// motorun ölü bölgesini (sürtünmeyi) yenmek için eklenen minimum pwm
const int MOTOR_DEADBAND_PWM = 10;

// montaja göre işaret ayarları (seri monitör 'd' ve 'l'/'r' testleriyle doğrulanır):
//   robot ÖNE eğilince pitch ARTI olmalı, robot ileri itilince x ARTI olmalı,
//   robot yukarıdan bakınca SAĞA dönünce yaw ARTI olmalı.
const float PITCH_SIGN      = 1.0f;   // ivmeölçer açısının işareti
const float GYRO_PITCH_SIGN = -1.0f;  // pitch = atan2(ax, az) için eşleşen gyro ekseni Y, işareti ters
const float GYRO_YAW_SIGN   = -1.0f;  // Z ekseni yukarı bakıyorsa sağa dönüş negatif okunur
const int   LEFT_ENC_SIGN   = 1;
const int   RIGHT_ENC_SIGN  = -1;     // karşılıklı monte edilen motorda enkoder ters sayar
const int   LEFT_MOTOR_SIGN = 1;
const int   RIGHT_MOTOR_SIGN = 1;

// hareket hedefleri
const float DRIVE_SPEED_MPS     = 0.20f;  // eldiven ileri/geri
const float TURN_RATE_DPS       = 60.0f;  // eldiven sağ/sol (~1,5 sn'de 90°)
const float DOCK_SPEED_MPS      = 0.10f;  // istasyona yaklaşma
const float DOCK_SLOW_MPS       = 0.05f;  // hizalanırken
const float DOCK_TURN_DPS       = 30.0f;
const float DOCK_PRESS_M        = 0.01f;  // pedlere bastırmak için ileri konum payı
const unsigned long DOCK_SETTLE_MS  = 1500;  // temas sonrası stabil bekleme, sonra motorlar durur
const unsigned long IR_LOST_TIMEOUT_MS = 3000;

// dönüş (yaw hızı) kontrolü - volt cinsinden fark gerilimi
const float YAW_FF_V_PER_DPS = 0.020f;
const float YAW_KP_V_PER_DPS = 0.030f;

// 333 rpm, 1:30 redüksiyon, 11 ppr enkoder (A fazı yükselen kenar), 65 mm teker -> ~1615 darbe/m
const float PULSES_PER_METER = 1615.0f;

const float CHARGE_DETECT_VOLT = 9.0f;   // şarj pedinde bu gerilimin üstü = şarj akımı başladı

// ======================= haberleşme =======================
typedef struct __attribute__((packed)) GlovePacket {
  uint32_t seq;
  char cmd[8];
  float glovePitch;
  float gloveRoll;
} GlovePacket;

WiFiUDP udp;
const uint16_t UDP_PORT = 4210;
const char* AP_SSID = "HDRG100-Robot";
const char* AP_PASS = "12345678";
const unsigned long CLIENT_TIMEOUT_MS = 5000;
IPAddress phoneIp;
unsigned long lastPhoneMsgMs = 0;
bool phoneKnown = false;

// eldiven paketleri esp-now görevinde gelir; ana döngüye kilitle aktarılır
portMUX_TYPE gloveMux = portMUX_INITIALIZER_UNLOCKED;
volatile bool gloveFresh = false;
char gloveCmdShared[8] = "IDLE";
volatile unsigned long gloveRecvMsShared = 0;

// ======================= durum değişkenleri =======================
volatile long leftEncoderCount  = 0;
volatile long rightEncoderCount = 0;

enum RobotMode { MODE_NORMAL, MODE_DOCK_SEEK, MODE_DOCK_CONTACT, MODE_DOCKED, MODE_FALLEN };
RobotMode mode = MODE_NORMAL;

char gloveCmd[8] = "IDLE";
unsigned long lastGloveRecvMs = 0;

float pitchDeg = 0.0f;       // tamamlayıcı filtre çıktısı
float pitchRateDps = 0.0f;
float yawDeg = 0.0f;         // görev başından beri toplam dönüş (RESET ile sıfırlanır)
float yawRateDps = 0.0f;
float gyroBiasY = 0.0f, gyroBiasZ = 0.0f;

float posM = 0.0f, velMps = 0.0f, prevPosM = 0.0f;
float posRefM = 0.0f;
float velRefMps = 0.0f;
float yawRateRefDps = 0.0f;
float distOffsetM = 0.0f;    // telemetrideki mesafe için RESET ofseti
long lastResetToken = 0;     // uygulamanın son gönderdiği RESET numarası

float batteryVolt = 12.0f;
float chargeInVolt = 0.0f;

unsigned long lastControlUs = 0;
unsigned long lastTelemetryMs = 0;
unsigned long lastSlowReadMs = 0;
unsigned long dockContactMs = 0;
unsigned long lastIrSeenMs = 0;
unsigned long uprightSinceMs = 0;
int lastIrSide = 0;  // -1 sol, 0 orta, 1 sağ
uint32_t telemetrySeq = 0;
bool diagnostics = false;
unsigned long lastDiagMs = 0;

// ======================= kesmeler ve geri çağırmalar =======================
void IRAM_ATTR onLeftEncoderA() {
  if (digitalRead(PIN_ENC_LEFT_B) == HIGH) leftEncoderCount = leftEncoderCount + 1;
  else leftEncoderCount = leftEncoderCount - 1;
}

void IRAM_ATTR onRightEncoderA() {
  if (digitalRead(PIN_ENC_RIGHT_B) == HIGH) rightEncoderCount = rightEncoderCount + 1;
  else rightEncoderCount = rightEncoderCount - 1;
}

#if defined(ESP_ARDUINO_VERSION_MAJOR) && (ESP_ARDUINO_VERSION_MAJOR >= 3)
void onGloveDataRecv(const esp_now_recv_info_t* info, const uint8_t* incomingData, int len) {
  (void)info;
#else
void onGloveDataRecv(const uint8_t* mac, const uint8_t* incomingData, int len) {
  (void)mac;
#endif
  if (len < (int)sizeof(GlovePacket)) return;
  GlovePacket pkt;
  memcpy(&pkt, incomingData, sizeof(GlovePacket));
  pkt.cmd[sizeof(pkt.cmd) - 1] = '\0';
  portENTER_CRITICAL(&gloveMux);
  memcpy(gloveCmdShared, pkt.cmd, sizeof(gloveCmdShared));
  gloveRecvMsShared = millis();
  gloveFresh = true;
  portEXIT_CRITICAL(&gloveMux);
}

// ======================= motor =======================
int voltToPwm(float volt) {
  float vb = batteryVolt < 9.0f ? 9.0f : batteryVolt;
  int pwm = (int)(fabsf(volt) / vb * 255.0f);
  if (pwm > 0) pwm += MOTOR_DEADBAND_PWM;
  if (pwm > 255) pwm = 255;
  return volt >= 0 ? pwm : -pwm;
}

void writeMotor(int rpwmPin, int lpwmPin, int pwm) {
  if (pwm >= 0) {
    analogWrite(rpwmPin, pwm);
    analogWrite(lpwmPin, 0);
  } else {
    analogWrite(rpwmPin, 0);
    analogWrite(lpwmPin, -pwm);
  }
}

void driveMotorsPwm(int leftPwm, int rightPwm) {
  writeMotor(PIN_LEFT_RPWM, PIN_LEFT_LPWM, constrain(leftPwm * LEFT_MOTOR_SIGN, -255, 255));
  writeMotor(PIN_RIGHT_RPWM, PIN_RIGHT_LPWM, constrain(rightPwm * RIGHT_MOTOR_SIGN, -255, 255));
}

void stopMotors() { driveMotorsPwm(0, 0); }

// ======================= sensörler =======================
bool readMpuRaw(int16_t* ax, int16_t* az, int16_t* gy, int16_t* gz) {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(0x3B);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(MPU6050_ADDR, (size_t)14, true) < 14) return false;
  int16_t v[7];
  for (int i = 0; i < 7; i++) v[i] = (int16_t)((Wire.read() << 8) | Wire.read());
  *ax = v[0];   // ivme x
  *az = v[2];   // ivme z
  *gy = v[5];   // gyro y
  *gz = v[6];   // gyro z
  return true;
}

void initMPU6050() {
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, 400000);
  const uint8_t cfg[][2] = {
    {0x6B, 0x00},  // uykudan çık
    {0x1A, 0x03},  // dahili alçak geçiren filtre ~44 Hz (motor titreşimi için)
    {0x1C, 0x08},  // ivmeölçer ±4g
    {0x1B, 0x08},  // gyro ±500 °/s
  };
  for (auto& c : cfg) {
    Wire.beginTransmission(MPU6050_ADDR);
    Wire.write(c[0]);
    Wire.write(c[1]);
    Wire.endTransmission(true);
  }
}

// açılışta robot hareketsizken gyro sıfır kaymasını ve ilk eğimi ölçer
void calibrateImu() {
  float sumY = 0, sumZ = 0, sumAng = 0;
  int n = 0;
  for (int i = 0; i < 400; i++) {
    int16_t ax, az, gy, gz;
    if (readMpuRaw(&ax, &az, &gy, &gz)) {
      sumY += gy;
      sumZ += gz;
      sumAng += atan2f((float)ax, (float)az);
      n++;
    }
    delay(2);
  }
  if (n > 0) {
    gyroBiasY = sumY / n;
    gyroBiasZ = sumZ / n;
    pitchDeg = PITCH_SIGN * (sumAng / n) * 180.0f / PI;
  }
}

void updateImu(float dt) {
  int16_t ax, az, gy, gz;
  if (!readMpuRaw(&ax, &az, &gy, &gz)) {
    // motor titreşiminden kablo anlık temassızlık yaparsa sensörü yeniden başlat
    initMPU6050();
    return;
  }
  float accelPitchDeg = PITCH_SIGN * atan2f((float)ax, (float)az) * 180.0f / PI;
  pitchRateDps = GYRO_PITCH_SIGN * PITCH_SIGN * ((float)gy - gyroBiasY) / 65.5f;
  yawRateDps   = GYRO_YAW_SIGN * ((float)gz - gyroBiasZ) / 65.5f;

  // tamamlayıcı filtre: %98 gyro + %2 ivmeölçer
  pitchDeg = 0.98f * (pitchDeg + pitchRateDps * dt) + 0.02f * accelPitchDeg;
  yawDeg += yawRateDps * dt;
}

void updateOdometry(float dt) {
  long l, r;
  noInterrupts();
  l = leftEncoderCount;
  r = rightEncoderCount;
  interrupts();
  posM = 0.5f * (LEFT_ENC_SIGN * l + RIGHT_ENC_SIGN * r) / PULSES_PER_METER;
  float rawVel = (posM - prevPosM) / dt;
  prevPosM = posM;
  // enkoder çözünürlüğü kaba olduğu için ~30 ms zaman sabitli alçak geçiren filtre
  velMps += 0.14f * (rawVel - velMps);
}

float readDividerVolt(int pin) {
  return analogReadMilliVolts(pin) * 0.001f * DIVIDER_RATIO;
}

int batteryPercent() {
  int p = (int)((batteryVolt - 9.9f) / (12.6f - 9.9f) * 100.0f);
  return constrain(p, 0, 100);
}

// ======================= komut ve mod yönetimi =======================
bool isMotionCmd(const char* c) {
  return !strcmp(c, "FWD") || !strcmp(c, "BWD") || !strcmp(c, "LEFT") || !strcmp(c, "RIGHT");
}

void resetBalanceStates() {
  posRefM = posM;
  velMps = 0.0f;
  velRefMps = 0.0f;
  yawRateRefDps = 0.0f;
}

void handleGloveInput() {
  if (gloveFresh) {
    portENTER_CRITICAL(&gloveMux);
    memcpy(gloveCmd, gloveCmdShared, sizeof(gloveCmd));
    lastGloveRecvMs = gloveRecvMsShared;
    gloveFresh = false;
    portEXIT_CRITICAL(&gloveMux);
  }
  // eldivenden 500 ms veri gelmezse dur
  if (millis() - lastGloveRecvMs > 500) {
    strncpy(gloveCmd, "STOP", sizeof(gloveCmd));
  }
}

void applyGloveCommand() {
  velRefMps = 0.0f;
  yawRateRefDps = 0.0f;
  if (!strcmp(gloveCmd, "FWD"))        velRefMps = DRIVE_SPEED_MPS;
  else if (!strcmp(gloveCmd, "BWD"))   velRefMps = -DRIVE_SPEED_MPS;
  else if (!strcmp(gloveCmd, "RIGHT")) yawRateRefDps = TURN_RATE_DPS;
  else if (!strcmp(gloveCmd, "LEFT"))  yawRateRefDps = -TURN_RATE_DPS;
}

// 3 ir alıcı ile istasyona hizalanma
void applyDockGuidance() {
  bool irL = digitalRead(PIN_IR_LEFT) == LOW;
  bool irC = digitalRead(PIN_IR_CENTER) == LOW;
  bool irR = digitalRead(PIN_IR_RIGHT) == LOW;
  unsigned long now = millis();

  if (irC) {
    lastIrSeenMs = now;
    lastIrSide = 0;
    velRefMps = DOCK_SPEED_MPS;
    yawRateRefDps = irL ? -DOCK_TURN_DPS * 0.3f : (irR ? DOCK_TURN_DPS * 0.3f : 0.0f);
  } else if (irL) {
    lastIrSeenMs = now;
    lastIrSide = -1;
    velRefMps = DOCK_SLOW_MPS;
    yawRateRefDps = -DOCK_TURN_DPS;
  } else if (irR) {
    lastIrSeenMs = now;
    lastIrSide = 1;
    velRefMps = DOCK_SLOW_MPS;
    yawRateRefDps = DOCK_TURN_DPS;
  } else if (now - lastIrSeenMs < IR_LOST_TIMEOUT_MS) {
    // sinyal kısa süre kaybolduysa son görülen tarafa yerinde dönerek ara
    velRefMps = 0.0f;
    yawRateRefDps = (lastIrSide < 0 ? -1.0f : 1.0f) * DOCK_TURN_DPS * 0.6f;
  } else {
    velRefMps = 0.0f;
    yawRateRefDps = 0.0f;
    mode = MODE_NORMAL;
  }
}

void updateMode() {
  bool docked = digitalRead(PIN_SWITCH_DOCK) == LOW;
  bool irVisible = digitalRead(PIN_IR_LEFT) == LOW || digitalRead(PIN_IR_CENTER) == LOW ||
                   digitalRead(PIN_IR_RIGHT) == LOW;
  bool motion = isMotionCmd(gloveCmd);
  unsigned long now = millis();

  switch (mode) {
    case MODE_FALLEN:
      return;  // devrilme durumundan çıkış controlStep içinde
    case MODE_NORMAL:
      if (docked) {
        mode = MODE_DOCK_CONTACT;
        dockContactMs = now;
        posRefM = posM + DOCK_PRESS_M;
      } else if (irVisible && !motion) {
        // eldiven "dur" konumundayken istasyon görülürse kontrol otonom güdüme geçer
        mode = MODE_DOCK_SEEK;
        lastIrSeenMs = now;
      }
      break;
    case MODE_DOCK_SEEK:
      if (motion) {
        mode = MODE_NORMAL;
      } else if (docked) {
        mode = MODE_DOCK_CONTACT;
        dockContactMs = now;
        posRefM = posM + DOCK_PRESS_M;
      }
      break;
    case MODE_DOCK_CONTACT:
      if (!docked) {
        mode = MODE_NORMAL;
        resetBalanceStates();
      } else if (now - dockContactMs >= DOCK_SETTLE_MS && fabsf(velMps) < 0.03f) {
        // şartname: dock'a dayandıktan ve stabil olduktan sonra motorlar durdurulur
        mode = MODE_DOCKED;
        stopMotors();
      }
      break;
    case MODE_DOCKED:
      if (!docked || motion) {
        // elle çekildi veya eldivenle hareket komutu geldi -> aktif dengeye geri dön
        mode = MODE_NORMAL;
        resetBalanceStates();
      }
      break;
  }
}

// ======================= 200 Hz kontrol adımı =======================
void controlStep(float dt) {
  updateImu(dt);
  updateOdometry(dt);
  handleGloveInput();
  updateMode();

  unsigned long now = millis();

  if (mode == MODE_FALLEN) {
    stopMotors();
    // biri robotu dik tutarsa (|eğim| < 5° ve 0,5 sn) dengeye yeniden başla
    if (fabsf(pitchDeg - balanceOffsetDeg) < REARM_ANGLE_DEG) {
      if (uprightSinceMs == 0) uprightSinceMs = now;
      if (now - uprightSinceMs >= REARM_HOLD_MS) {
        mode = MODE_NORMAL;
        resetBalanceStates();
      }
    } else {
      uprightSinceMs = 0;
    }
    return;
  }

  if (fabsf(pitchDeg - balanceOffsetDeg) > FALL_CUTOFF_DEG) {
    // devrilme: motorları kes, LQR durum referanslarını sıfırla
    mode = MODE_FALLEN;
    uprightSinceMs = 0;
    stopMotors();
    resetBalanceStates();
    return;
  }

  if (mode == MODE_DOCKED) {
    stopMotors();
    return;
  }

  if (mode == MODE_NORMAL) applyGloveCommand();
  else if (mode == MODE_DOCK_SEEK) applyDockGuidance();
  else {  // MODE_DOCK_CONTACT: pedlere hafif bastırarak yerinde dengede dur
    velRefMps = 0.0f;
    yawRateRefDps = 0.0f;
  }

  posRefM += velRefMps * dt;
  float posErr = posM - posRefM;
  if (posErr > MAX_POS_ERROR_M) { posRefM = posM - MAX_POS_ERROR_M; posErr = MAX_POS_ERROR_M; }
  if (posErr < -MAX_POS_ERROR_M) { posRefM = posM + MAX_POS_ERROR_M; posErr = -MAX_POS_ERROR_M; }

  float theta = (pitchDeg - balanceOffsetDeg) * PI / 180.0f;
  float thetaDot = pitchRateDps * PI / 180.0f;
  float velErr = velMps - velRefMps;

  float u = -(LQR_K[0] * theta + LQR_K[1] * thetaDot + LQR_K[2] * posErr + LQR_K[3] * velErr);
  float uTurn = YAW_FF_V_PER_DPS * yawRateRefDps + YAW_KP_V_PER_DPS * (yawRateRefDps - yawRateDps);

  float uLeft  = constrain(u + uTurn, -MAX_MOTOR_VOLT, MAX_MOTOR_VOLT);
  float uRight = constrain(u - uTurn, -MAX_MOTOR_VOLT, MAX_MOTOR_VOLT);
  driveMotorsPwm(voltToPwm(uLeft), voltToPwm(uRight));
}

// ======================= telefon haberleşmesi =======================
void handleUdpInput() {
  int packetSize = udp.parsePacket();
  if (packetSize <= 0) return;
  char buf[16];
  int len = udp.read(buf, sizeof(buf) - 1);
  if (len <= 0) return;
  buf[len] = '\0';
  if (buf[0] == '{') return;  // kendi yayınımız geri geldiyse yoksay

  // telefonun adresini kaydet; telemetri artık doğrudan bu telefona gönderilir
  phoneIp = udp.remoteIP();
  phoneKnown = true;
  lastPhoneMsgMs = millis();

  if (strncmp(buf, "RESET", 5) == 0) {
    // "RESET:<n>" -> mesafe ve dönüş açısı sayaçlarını sıfırla (denge referansına dokunmaz).
    // n telemetride "rst" olarak geri yansıtılır; uygulama onayı görene kadar komutu tekrarlar.
    long token = (buf[5] == ':') ? atol(buf + 6) : 0;
    if (token != lastResetToken) {
      distOffsetM = posM;
      yawDeg = 0.0f;
      lastResetToken = token;
    }
  }
}

const char* modeCmdText() {
  if (mode == MODE_DOCK_SEEK || mode == MODE_DOCK_CONTACT || mode == MODE_DOCKED) return "DOCK";
  return gloveCmd;
}

void sendTelemetry() {
  int isDocked   = digitalRead(PIN_SWITCH_DOCK) == LOW ? 1 : 0;
  // şarj: istasyon pedinden gelen gerilim (1N5822 öncesi) eşik üstündeyse şarj akımı akıyor demektir
  int isCharging = chargeInVolt > CHARGE_DETECT_VOLT ? 1 : 0;
  int boxPresent = digitalRead(PIN_SWITCH_BOX) == LOW ? 1 : 0;

  char json[240];
  snprintf(json, sizeof(json),
           "{\"seq\":%lu,\"pitch\":%.1f,\"bat\":%d,\"chg\":%d,\"dock\":%d,\"box\":%d,"
           "\"dist\":%.3f,\"yaw\":%.1f,\"rst\":%ld,\"cmd\":\"%s\"}",
           (unsigned long)(++telemetrySeq), pitchDeg - balanceOffsetDeg, batteryPercent(),
           isCharging, isDocked, boxPresent, posM - distOffsetM, yawDeg, lastResetToken,
           modeCmdText());

  bool unicast = phoneKnown && (millis() - lastPhoneMsgMs < CLIENT_TIMEOUT_MS);
  if (unicast) udp.beginPacket(phoneIp, UDP_PORT);
  else udp.beginPacket(IPAddress(192, 168, 4, 255), UDP_PORT);
  udp.write((const uint8_t*)json, strlen(json));
  udp.endPacket();
}

// ======================= seri tanı =======================
const char* modeName() {
  switch (mode) {
    case MODE_NORMAL: return "NORMAL";
    case MODE_DOCK_SEEK: return "DOCK_SEEK";
    case MODE_DOCK_CONTACT: return "DOCK_CONTACT";
    case MODE_DOCKED: return "DOCKED";
    default: return "FALLEN";
  }
}

void handleSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == 'd') {
      diagnostics = !diagnostics;
    } else if ((c == 'l' || c == 'r') && mode == MODE_FALLEN) {
      // yalnızca robot devrik/havadayken: tek motoru 0,5 sn ileri döndür
      Serial.printf("%s motor ileri yonde donmeli\n", c == 'l' ? "SOL" : "SAG");
      if (c == 'l') driveMotorsPwm(90, 0); else driveMotorsPwm(0, 90);
      delay(500);
      stopMotors();
    }
  }
  if (diagnostics && millis() - lastDiagMs >= 200) {
    lastDiagMs = millis();
    Serial.printf("mod:%s pitch:%.2f rate:%.1f x:%.3f v:%.2f yaw:%.1f | ir L%d C%d R%d | kutu:%d dock:%d | "
                  "pil:%.2fV sarjGiris:%.2fV | eldiven:%s\n",
                  modeName(), pitchDeg, pitchRateDps, posM, velMps, yawDeg,
                  digitalRead(PIN_IR_LEFT) == LOW, digitalRead(PIN_IR_CENTER) == LOW,
                  digitalRead(PIN_IR_RIGHT) == LOW, digitalRead(PIN_SWITCH_BOX) == LOW,
                  digitalRead(PIN_SWITCH_DOCK) == LOW, batteryVolt, chargeInVolt, gloveCmd);
  }
}

// ======================= kurulum ve ana döngü =======================
void setup() {
  Serial.begin(115200);

  pinMode(PIN_LEFT_RPWM, OUTPUT);
  pinMode(PIN_LEFT_LPWM, OUTPUT);
  pinMode(PIN_RIGHT_RPWM, OUTPUT);
  pinMode(PIN_RIGHT_LPWM, OUTPUT);
  stopMotors();

  pinMode(PIN_ENC_LEFT_A, INPUT_PULLUP);
  pinMode(PIN_ENC_LEFT_B, INPUT_PULLUP);
  pinMode(PIN_ENC_RIGHT_A, INPUT_PULLUP);
  pinMode(PIN_ENC_RIGHT_B, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_LEFT_A), onLeftEncoderA, RISING);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_RIGHT_A), onRightEncoderA, RISING);

  pinMode(PIN_IR_LEFT, INPUT_PULLUP);
  pinMode(PIN_IR_CENTER, INPUT_PULLUP);
  pinMode(PIN_IR_RIGHT, INPUT_PULLUP);
  pinMode(PIN_SWITCH_BOX, INPUT_PULLUP);
  pinMode(PIN_SWITCH_DOCK, INPUT_PULLUP);
  analogSetAttenuation(ADC_11db);

  initMPU6050();
  Serial.println("imu kalibrasyonu: robotu 1 sn hareketsiz tutun...");
  calibrateImu();

  batteryVolt = readDividerVolt(PIN_BATTERY_ADC);
  chargeInVolt = readDividerVolt(PIN_CHARGE_IN_ADC);

  // telefon için 1. kanalda wifi erişim noktası; eldiven aynı kanaldan esp-now gönderir
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, AP_PASS, 1);
  udp.begin(UDP_PORT);

  if (esp_now_init() == ESP_OK) {
    esp_now_register_recv_cb(onGloveDataRecv);
  } else {
    Serial.println("esp-now baslatilamadi");
  }

  // açılışta robot elle dik tutulana kadar motorlar kapalı bekler
  mode = MODE_FALLEN;
  updateOdometry(0.005f);
  resetBalanceStates();
  lastControlUs = micros();

  Serial.print("robot hazir, mac: ");
  Serial.println(WiFi.macAddress());
  Serial.print("wifi ip: ");
  Serial.println(WiFi.softAPIP());
}

void loop() {
  unsigned long nowUs = micros();
  if (nowUs - lastControlUs >= (unsigned long)CONTROL_PERIOD_US) {
    float dt = (nowUs - lastControlUs) * 1e-6f;
    lastControlUs = nowUs;
    if (dt <= 0.0f || dt > 0.05f) dt = 0.005f;
    controlStep(dt);
  }

  handleUdpInput();
  handleSerial();

  unsigned long nowMs = millis();
  // pil ve şarj girişi gerilimi 20 Hz okunur ve yumuşatılır
  if (nowMs - lastSlowReadMs >= 50) {
    lastSlowReadMs = nowMs;
    batteryVolt  += 0.2f * (readDividerVolt(PIN_BATTERY_ADC) - batteryVolt);
    chargeInVolt += 0.5f * (readDividerVolt(PIN_CHARGE_IN_ADC) - chargeInVolt);
  }

  // 2 Hz telemetri (şartname minimumu 1 Hz)
  if (nowMs - lastTelemetryMs >= 500) {
    lastTelemetryMs = nowMs;
    sendTelemetry();
  }
}
