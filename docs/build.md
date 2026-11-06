# Derleme ve dağıtım

iOS ana uygulaması, paylaşma uzantısı ve Mac hedefi **iCloud.com.eminaydin.maccommand** kapsayıcısını kullanır. Apple Developer portalında üç hedefin uygulama kimliğine aynı kapsayıcıyı bağla ve imza profillerini yenile. Mac dağıtımı, CloudKit yetkili Developer ID profiliyle yapılır. Kendi fork’unu dağıtıyorsan takımına ait uygulama kimliklerini ve CloudKit kapsayıcısını kullan. iOS uygulamasının ve paylaşma uzantısının App Group kimliği de aynı olmalı.

[cloudkit/MacCommand.ckdb](../cloudkit/MacCommand.ckdb) iş kaydını ve dizinleri tanımlar. Önce mevcut geliştirme şemasını dışa aktar ve MacCommandJob tanımını birleştir. Geliştirme şemasını doğrulayıp içe aktar. Ardından CloudKit Console’dan değişiklikleri **Production** ortamına dağıt. Uygulamanın kullanıcı veritabanı özeldir. Şema public database erişim izni vermez. [Apple şema dağıtım kılavuzu](https://developer.apple.com/documentation/CloudKit/deploying-an-icloud-container-s-schema).

Komutları depo kökünden çalıştır. Mac paketi için Python ve PyInstaller derleme makinesinde gerekir. Önce `build-mac.sh` ile yerleşik servisi hazırla, ardından Xcode projesinden CloudKit yetkili dağıtım arşivini oluştur.

~~~sh
python3.14 -m venv .packaging
.packaging/bin/python -m pip install -r requirements.txt 'pyinstaller>=6.19,<7'
export MACCOMMAND_BUILD_PYTHON=.packaging/bin/python
export MACCOMMAND_SIGN_IDENTITY='Developer ID Application: …'
MACCOMMAND_PREVIEW=1 ./scripts/build-mac.sh
xcodebuild -project macos/MacCommandMac.xcodeproj -scheme MacCommand \
  -configuration Release -destination generic/platform=macOS \
  -archivePath build/macos/MacCommand.xcarchive DEVELOPMENT_TEAM=TAKIM_KIMLIGI \
  -allowProvisioningUpdates archive
~~~

Mac arşivini Xcode Organizer’da **Developer ID** ile dışa aktar. Çıktının iCloud yetkisinin **Production** olduğunu kontrol et. Ardından Developer ID imzalı DMG’yi paketle ve Apple noter onayı için gönder. [Apple Developer ID belgesi](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

~~~sh
export MACCOMMAND_NOTARY_PROFILE=MacCommand
./scripts/package-dmg.sh path/to/MacCommand.app MacCommand-3.1-CloudKit.dmg
~~~

iPhone arşivi ve iç TestFlight yüklemesi:

~~~sh
export MACCOMMAND_IOS_TEAM='TAKIM_KIMLIGI'
./scripts/archive-ios.sh
MACCOMMAND_IOS_DESTINATION=upload MACCOMMAND_IOS_REUSE_ARCHIVE=1 ./scripts/archive-ios.sh
~~~

Apple işleme durumunu kontrol et. Şifreleme ihracat sorularını ve beta bilgilerini App Store Connect’te tamamla. İlk dağıtım iç test grubunu hedefler.

## Doğrulama

~~~sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
./scripts/test.sh
.venv/bin/python scripts/test-relay-swift.py
~~~

Mac helper testi CloudKit paket biçimi, dosya aktarımı, şifreli QR, istek süresi ve tekrar korumasını yerelde doğrular. Gerçek CloudKit testi için imzalı uygulama, aynı Apple hesabı ve ilgili ortama dağıtılmış şema gerekir.

3.0 bağlantı sunucusu için eski eşleştirme biçimi iOS’ta okunabilir. Yeni Mac paketinin CloudKit yolu o altyapıya ihtiyaç duymaz.
