# MacCommand

Mac’inin sistem durumuna bak, dosyalarını al ve terminal komutları çalıştır. iPhone’dan Wi‑Fi veya mobil internetle bağlanabilirsin. İstekler kendi iCloud hesabın üzerinden şifreli olarak iletilir.

**[Mac için DMG’yi indir](https://github.com/eminaydin19/MacCommand/releases/download/v3.1.0/MacCommand-3.1-CloudKit.dmg)** · [3.1 beta sürüm notları](https://github.com/eminaydin19/MacCommand/releases/tag/v3.1.0)

Mac için Apple Silicon ve macOS 14+ gerekir. iPhone sürümü iOS 17+ için davetli TestFlight betasında.

<p align="center">
  <img src="docs/media/system.png" width="230" alt="Sistem ekranında Mac’in işlemci, bellek ve disk kullanımı">
  &nbsp;&nbsp;
  <img src="docs/media/files.png" width="230" alt="Dosyalar ekranında favori klasörler ve Mac’teki dosyalar">
</p>
<p align="center"><sub>Sistem ve Dosyalar ekranları, iPhone simülatöründe örnek verilerle.</sub></p>

## İlk bağlantı

1. Mac’te DMG’yi aç. **MacCommand**’i **Uygulamalar** klasörüne taşı ve çalıştır.
2. iPhone’a TestFlight davetinden MacCommand’i yükle. Mac ve iPhone’da aynı iCloud hesabını kullan.
3. Mac’te **iPhone eşleştir**’e bas. iPhone ile QR kodunu tara ve **Mac’e bağlan**’ı seç.

Bağlantı için Mac uyanık ve çevrimiçi olmalı. Mac’in menü çubuğundan erişimi kapatabilir veya eşleştirmeyi yenileyebilirsin.

## Dosyalar ve terminal

- **Dosyalar.** Sık kullandığın klasörleri favorilere ekle. Mac’ten dosya indirebilir veya iPhone’un paylaş menüsünden **Mac’e Gönder** ile 50 MiB’a kadar dosya gönderebilirsin.
- **Terminal.** Face ID veya cihaz parolasıyla açılır. Komutlar Mac’te oturum açmış kullanıcının yetkileriyle çalışır. Çıktı komut tamamlandığında görünür. Durdurma isteğinin Mac’e ulaşması zaman alabilir.

[Derleme ve CloudKit kurulumu](docs/build.md) · [MIT lisansı](LICENSE)
