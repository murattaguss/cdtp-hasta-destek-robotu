#!/bin/zsh
# iPhone'u bu Mac'e kabloyla bağlayıp çift tıklayın: HDRG100 uygulamasını iPhone'a kurar.
# İlk seferde Xcode'da Runner > Signing & Capabilities kısmından kendi (ücretsiz) Apple ID
# takımınızı seçmeniz gerekir. Kurulumdan sonra iPhone'da:
# Ayarlar > Genel > VPN ve Aygıt Yönetimi > geliştirici uygulamasına "Güven" deyin.

cd "$(dirname "$0")/.."

# Masaüstü iCloud ile eşitlendiğinde iOS derlemesi "resource fork / Finder information"
# hatası verir; bu yüzden iOS derleme klasörü /tmp altına yönlendirilir.
IOS_BUILD_DIR="/tmp/cdtp_hasta_destek_mobil_ios_build"
mkdir -p "$IOS_BUILD_DIR" build
if [ ! -L build/ios ]; then
  rm -rf build/ios
  ln -s "$IOS_BUILD_DIR" build/ios
fi

flutter run --release
echo "Kapatmak için Enter'a basın"; read -r
