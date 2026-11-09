// eldiven kumanda kodu (nodemcu esp8266 için ayarladım)
//
// mpu6050 bağlantıları:
// vcc -> 3V
// gnd -> G
// scl -> D1 (gpio 5)
// sda -> D2 (gpio 4)
// pil / tp4056 çıkışı -> Vin ve G
//
// not: arduino ide'de esp8266 kartları yoksa file -> preferences kısmına şu linki yapıştır:
// http://arduino.esp8266.com/stable/package_esp8266com_index.json
// sonra boards manager'dan esp8266'yı kurup kart olarak "NodeMCU 1.0 (ESP-12E Module)" seçebilirsin.

#include <Arduino.h>
#include <Wire.h>

#if defined(ESP8266)
  #include <ESP8266WiFi.h>
  #include <espnow.h>
  extern "C" {
    #include <user_interface.h>
  }
  // nodemcu üzerinde D2 = gpio4 (sda), D1 = gpio5 (scl), D4 = gpio2 (karttaki mavi led)
  const int PIN_SDA = 4;
  const int PIN_SCL = 5;
  const int PIN_LED = 2;
#elif defined(ESP32)
  #include <WiFi.h>
  #include <esp_now.h>
  #include <esp_wifi.h>
  const int PIN_SDA = 21;
  const int PIN_SCL = 22;
  const int PIN_LED = 2;
#else
  #error "Kart olarak NodeMCU 1.0 (ESP-12E) veya ESP32 secilmesi lazim"
#endif

// robotun mac adresini tek tek bulmakla uğraşmayalım diye broadcast (ff:ff:ff:ff:ff:ff) yaptım, direkt alıyor
uint8_t robotMacAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

const uint8_t MPU_ADDR = 0x68;

// el normal dururken ufak titremelerde hemen komut gitmesin diye 20 derece eşik verdim.
// denerken çok veya az gelirse buradan değiştiririz.
const float PITCH_ESIK = 20.0f; // ileri - geri eğim
const float ROLL_ESIK  = 22.0f; // sağa - sola eğim

// esp8266 ile robottaki esp32 arasında byte kayması olmasın diye packed yapıyoruz
typedef struct __attribute__((packed)) GlovePacket {
  uint32_t seq;
  char cmd[8];
  float glovePitch;
  float gloveRoll;
} GlovePacket;

GlovePacket txPacket;

#if defined(ESP32)
esp_now_peer_info_t peerInfo;
#endif

float filteredPitch   = 0.0f;
float filteredRoll    = 0.0f;
float pitchZeroOffset = 0.0f;
float rollZeroOffset  = 0.0f;
bool mpuSensorOk      = false;

unsigned long lastSampleMicros = 0;
unsigned long lastSendMillis   = 0;
uint32_t packetCounter = 0;

// ekstra mpu6050 kütüphanesi kurmakla uğraşmayalım diye direkt wire ile registerlardan başlattım
void initMPU6050() {
  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(400000);

  // 0x6B registerına 0 yazınca sensör uykudan uyanıyor
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);
  Wire.write(0x00);
  uint8_t err = Wire.endTransmission(true);
  mpuSensorOk = (err == 0);

  // ivmeölçer ayarı (+-4g)
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1C);
  Wire.write(0x08);
  Wire.endTransmission(true);

  // gyro ayarı (+-500 derece/sn)
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1B);
  Wire.write(0x08);
  Wire.endTransmission(true);
}

// eldivene sensörü tam düz yapıştıramazsak diye açılışta ufak bir sıfırlama yapıyor
void calibrateGloveZero() {
  float sumPitch = 0.0f;
  float sumRoll  = 0.0f;
  int validCount = 0;

  for (int i = 0; i < 50; i++) {
    Wire.beginTransmission(MPU_ADDR);
    Wire.write(0x3B);
    Wire.endTransmission(false);
    Wire.requestFrom(MPU_ADDR, (uint8_t)6);

    if (Wire.available() >= 6) {
      int16_t accX = (int16_t)((Wire.read() << 8) | Wire.read());
      int16_t accY = (int16_t)((Wire.read() << 8) | Wire.read());
      int16_t accZ = (int16_t)((Wire.read() << 8) | Wire.read());

      float p = atan2((float)accY, sqrt((float)accX * accX + (float)accZ * accZ)) * 180.0f / PI;
      float r = atan2((float)-accX, (float)accZ) * 180.0f / PI;
      sumPitch += p;
      sumRoll  += r;
      validCount++;
    }
    delay(4);
  }

  if (validCount > 0) {
    float avgP = sumPitch / (float)validCount;
    float avgR = sumRoll  / (float)validCount;
    // açılışta el çok eğik değilse o anki duruşu sıfır noktası olarak kaydet
    if (fabs(avgP) < 30.0f && fabs(avgR) < 30.0f) {
      pitchZeroOffset = avgP;
      rollZeroOffset  = avgR;
    }
  }
}

bool readGloveAngles(float dt) {
  // 0x3B adresinden başlayıp 14 byte (ivme + sıcaklık + gyro) okuyoruz
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);
  if (Wire.endTransmission(false) != 0) {
    // kabloda temassızlık olursa sensörü tekrar başlatmayı denesin
    initMPU6050();
    return false;
  }

  Wire.requestFrom(MPU_ADDR, (uint8_t)14);
  if (Wire.available() < 14) return false;

  int16_t accX = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t accY = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t accZ = (int16_t)((Wire.read() << 8) | Wire.read());
  Wire.read(); Wire.read(); // aradaki 2 byte sıcaklık verisi, kullanmıyoruz
  int16_t gyrX = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t gyrY = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t gyrZ = (int16_t)((Wire.read() << 8) | Wire.read());
  (void)gyrZ;

  float accelPitch = (atan2((float)accY, sqrt((float)accX * accX + (float)accZ * accZ)) * 180.0f / PI) - pitchZeroOffset;
  float accelRoll  = (atan2((float)-accX, (float)accZ) * 180.0f / PI) - rollZeroOffset;

  float gyroPitchRate = (float)gyrX / 65.5f;
  float gyroRollRate  = (float)gyrY / 65.5f;

  // sadece ivmeölçer kullanınca çok gürültülü oluyor, gyro da tek başına zamanla kayıyor.
  // o yüzden ikisini filtreyle birleştirdim.
  filteredPitch = 0.96f * (filteredPitch + gyroPitchRate * dt) + 0.04f * accelPitch;
  filteredRoll  = 0.96f * (filteredRoll  + gyroRollRate  * dt) + 0.04f * accelRoll;
  return true;
}

const char* decideCommand(float pitch, float roll) {
  if (pitch > PITCH_ESIK) {
    return "FWD";   // ileri
  } else if (pitch < -PITCH_ESIK) {
    return "BWD";   // geri
  } else if (roll > ROLL_ESIK) {
    return "RIGHT"; // sağa dön
  } else if (roll < -ROLL_ESIK) {
    return "LEFT";  // sola dön
  }
  return "STOP";    // el düzken dur
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_LED, OUTPUT);
#if defined(ESP8266)
  digitalWrite(PIN_LED, HIGH); // nodemcu'da mavi led HIGH verince sönüyor
#else
  digitalWrite(PIN_LED, LOW);
#endif

  initMPU6050();
  calibrateGloveZero();

  // robottaki esp32 wifi ağını 1. kanalda açtığı için bunu da 1. kanala sabitledim
#if defined(ESP8266)
  WiFi.persistent(false);
  WiFi.setAutoConnect(false);
  WiFi.setAutoReconnect(false);
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();

  wifi_promiscuous_enable(1);
  wifi_set_channel(1);
  wifi_promiscuous_enable(0);

  if (esp_now_init() != 0) {
    Serial.println("esp-now baslatilamadi");
    return;
  }

  esp_now_set_self_role(ESP_NOW_ROLE_CONTROLLER);
  esp_now_add_peer(robotMacAddress, ESP_NOW_ROLE_SLAVE, 1, NULL, 0);
#elif defined(ESP32)
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);

  if (esp_now_init() != ESP_OK) {
    Serial.println("esp-now baslatilamadi");
    return;
  }

  memset(&peerInfo, 0, sizeof(peerInfo));
  memcpy(peerInfo.peer_addr, robotMacAddress, 6);
  peerInfo.channel = 0;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);
#endif

  lastSampleMicros = micros();
  Serial.println("eldiven hazir");
}

void loop() {
  unsigned long nowMicros = micros();
  float dt = (nowMicros - lastSampleMicros) * 1e-6f;
  if (dt <= 0.0f || dt > 0.2f) dt = 0.01f;
  lastSampleMicros = nowMicros;

  bool readOk = readGloveAngles(dt);

  // 50 ms'de bir (saniyede 20 kere) robota komutu gönderiyoruz
  unsigned long nowMillis = millis();
  if (nowMillis - lastSendMillis >= 50) {
    lastSendMillis = nowMillis;

    // sensör kablosu çıkarsa robot takılı kalmasın diye direkt STOP yollasın
    const char* cmd = readOk ? decideCommand(filteredPitch, filteredRoll) : "STOP";
    txPacket.seq = ++packetCounter;
    strncpy(txPacket.cmd, cmd, sizeof(txPacket.cmd) - 1);
    txPacket.cmd[sizeof(txPacket.cmd) - 1] = '\0';
    txPacket.glovePitch = readOk ? filteredPitch : 0.0f;
    txPacket.gloveRoll  = readOk ? filteredRoll  : 0.0f;

#if defined(ESP8266)
    esp_now_send(robotMacAddress, (uint8_t*)&txPacket, sizeof(txPacket));
    // el eğildiğinde kartın üstündeki mavi led yansın, düzken sönsün
    if (strcmp(txPacket.cmd, "STOP") == 0) {
      digitalWrite(PIN_LED, HIGH);
    } else {
      digitalWrite(PIN_LED, LOW);
    }
#elif defined(ESP32)
    esp_now_send(robotMacAddress, (const uint8_t*)&txPacket, sizeof(txPacket));
    digitalWrite(PIN_LED, (strcmp(txPacket.cmd, "STOP") == 0) ? LOW : HIGH);
#endif

    if (readOk) {
      Serial.printf("komut: %-5s | pitch: %5.1f | roll: %5.1f\n",
                    txPacket.cmd, txPacket.glovePitch, txPacket.gloveRoll);
    } else {
      Serial.println("mpu6050 okunamiyor, d1 ve d2 kablolarini kontrol et");
    }
  }

  delay(5);
}
