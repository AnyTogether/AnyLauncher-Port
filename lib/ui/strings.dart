import 'strings_table.dart';
import 'strings_together.dart';

/// The launcher's two languages.
enum Language {
  english('en', 'English', 1),
  turkish('tr', 'Türkçe', 19);

  const Language(this.code, this.displayName, this.consoleLanguage);

  final String code;
  final String displayName;

  /// The console language a game starts in when its own setting follows the launcher.
  final int consoleLanguage;

  static Language byCode(String? code) => code == 'tr' ? Language.turkish : Language.english;
}

/// Every user-facing text in both languages: the macOS launcher's tables, with the Mac's words
/// replaced by the PC's and the texts only this launcher has.
abstract final class T {
  static Language language = Language.english;

  static const _english = <String, String>{
    'aboutText':
        'AnyPS5 runs PS5 games natively on Windows and Linux: the relinker turns a game into a program '
        'of this computer, with the system libraries AnyPS5 implements.',
    'welcomeSubtitle': "Play PS5 games on your PC. Let's set a few things up first.",
    'startingText':
        'The game is opening, please wait. The first start can take a few minutes while it builds its shaders.',
    'stepRelink': 'Converting for this PC',
    'stepBundle': 'Laying out',
    'showInFinder': 'Show folder',
    'themesOnMac': 'On this PC',
    'noToolkit': 'No AnyPS5 engine yet: download it in Settings › AnyPS5 Engine.',
    'saveSyncDetail': 'Saves and trophies stay the same on your other computers through %@',
    'saveSyncNoFolder': 'Saves and trophies stay the same on your other computers through a folder; choose one first',
    'syncFolderNone': 'None: choose Dropbox, OneDrive or a shared folder',
    'toolkit': 'Toolkit',
    'toolkitDetail': 'The relinker and system libraries for this system',
    'toolkitMissing': 'Not found',
    'toolkitChoose': 'Choose toolkit folder',
    'chooseToolkit': 'Get the AnyPS5 engine',
    'chooseToolkitSubtitle':
        'The engine turns your PS5 games into programs for this PC. AnyPS5 downloads it from GitHub '
        'and keeps it up to date, or you can use a build of your own.',
    'engine': 'AnyPS5 Engine',
    'engineDownload': 'Download the AnyPS5 engine',
    'engineRecommended': 'Recommended',
    'engineDownloadDetail': 'Version %@ · %@ · from GitHub',
    'engineLooking': 'Looking for the newest version…',
    'engineOffline': 'GitHub could not be reached. Try again, or use your own folder.',
    'engineProgress': '%@ of %@',
    'engineUnpacking': 'Unpacking…',
    'engineReady': 'AnyPS5 engine %@ is ready',
    'engineOwnFolder': 'I have my own folder',
    'engineOwnFolderDetail': 'The relinker and libs/ from an AnyPS5 build',
    'engineUnverified': 'GitHub gave no checksum for this version. Select it again to download it anyway.',
    'engineUnverifiedTitle': 'Download without a checksum',
    'engineUnverifiedDetail': 'GitHub gave no checksum for %@; only go on if you trust it',
    'engineFailed': 'The engine download failed: %@',
    'engineNoDownload': 'This release has no engine for this system',
    'engineInUse': 'In use',
    'engineCheck': 'Check for engine updates',
    'engineSource': 'From GitHub · boykopovar/AnyPS5',
    'engineNewest': 'Newest: %@',
    'engineUpToDate': 'The AnyPS5 engine is up to date (%@)',
    'engineUpdateToast': 'AnyPS5 engine %@ is out: Settings › AnyPS5 Engine',
    'engineUpdate': 'Update to %@',
    'engineDownloadVersion': 'Download %@',
    'engineDownloading': 'Downloading %@ · %d%%',
    'engineStop': 'select to stop',
    'engineDownloaded': 'Downloaded · select to use',
    'engineSizeDetail': '%@ · select to download',
    'enginePrerelease': 'Pre-release',
    'engineOwn': 'Use my own folder',
    'engineSwitched': 'Now using the AnyPS5 engine %@',
    'engineDeleteOld': 'Delete other versions',
    'engineDeleteOldDetail': 'Downloaded versions not in use: %d',
    'engineDeleted': 'Other engine versions deleted',
    'engineUpdateAndPlayDetail':
        'Downloads AnyPS5 engine %@ (%@), then unlocks the game again; saves and trophies stay',
    'resolutionReinstall': 'Takes effect when the game is installed again',
    'linkModeHard': 'Game files are linked to the dump and take no extra space',
    'phoneServer': 'Phone controller',
    'phoneServerDetail': 'AnyPS5 Remote on the same network finds this PC',
    'phoneAddress': 'Address for the phone',
    'backUpSavesDetail': 'Saves and trophies, into the AnyPS5 Backups folder',
    'restoreLatest': 'Restore the latest backup',
  };

  static const _turkish = <String, String>{
    'aboutText':
        "AnyPS5, PS5 oyunlarını Windows ve Linux'ta doğrudan çalıştırır: relinker oyunu bu bilgisayarın "
        'programına çevirir, sistem kütüphanelerini AnyPS5 sağlar.',
    'welcomeSubtitle': 'PS5 oyunlarını bilgisayarında oyna. Önce birkaç şeyi ayarlayalım.',
    'startingText':
        'Oyun açılıyor, lütfen bekle. İlk açılış, oyun gölgelendiricilerini hazırlarken birkaç dakika sürebilir.',
    'stepRelink': 'Bu bilgisayar için çevriliyor',
    'stepBundle': 'Yerleştiriliyor',
    'showInFinder': 'Klasörü göster',
    'themesOnMac': 'Bu bilgisayarda',
    'noToolkit': "Henüz AnyPS5 motoru yok: Ayarlar › AnyPS5 Motoru'ndan indir.",
    'saveSyncDetail': 'Kayıtlar ve kupalar %@ üzerinden diğer bilgisayarlarla aynı kalır',
    'saveSyncNoFolder': 'Kayıtlar ve kupalar bir klasör üzerinden diğer bilgisayarlarla aynı kalır; önce klasör seç',
    'syncFolderNone': 'Seçilmedi: Dropbox, OneDrive ya da paylaşılan bir klasör seç',
    'toolkit': 'Araç seti',
    'toolkitDetail': 'Bu sistem için relinker ve sistem kütüphaneleri',
    'toolkitMissing': 'Bulunamadı',
    'toolkitChoose': 'Araç seti klasörünü seç',
    'chooseToolkit': 'AnyPS5 motorunu al',
    'chooseToolkitSubtitle':
        "Motor, PS5 oyunlarını bu bilgisayarın programlarına çevirir. AnyPS5 onu GitHub'dan indirir "
        've güncel tutar; istersen kendi derlemeni de kullanabilirsin.',
    'engine': 'AnyPS5 Motoru',
    'engineDownload': 'AnyPS5 motorunu indir',
    'engineRecommended': 'Önerilen',
    'engineDownloadDetail': "Sürüm %@ · %@ · GitHub'dan",
    'engineLooking': 'En yeni sürüm aranıyor…',
    'engineOffline': "GitHub'a ulaşılamadı. Yeniden dene ya da kendi klasörünü kullan.",
    'engineProgress': '%@ / %@',
    'engineUnpacking': 'Açılıyor…',
    'engineReady': 'AnyPS5 motoru %@ hazır',
    'engineOwnFolder': 'Kendi klasörüm var',
    'engineOwnFolderDetail': 'Bir AnyPS5 derlemesinden relinker ve libs/',
    'engineUnverified': 'GitHub bu sürüm için sağlama toplamı vermedi. Yine de indirmek için tekrar seç.',
    'engineUnverifiedTitle': 'Sağlama toplamı olmadan indir',
    'engineUnverifiedDetail': 'GitHub %@ için sağlama toplamı vermedi; yalnızca güveniyorsan devam et',
    'engineFailed': 'Motor indirilemedi: %@',
    'engineNoDownload': 'Bu sürümde bu sistem için motor yok',
    'engineInUse': 'Kullanımda',
    'engineCheck': 'Motor güncellemelerini denetle',
    'engineSource': "GitHub'dan · boykopovar/AnyPS5",
    'engineNewest': 'En yeni: %@',
    'engineUpToDate': 'AnyPS5 motoru güncel (%@)',
    'engineUpdateToast': 'AnyPS5 motoru %@ çıktı: Ayarlar › AnyPS5 Motoru',
    'engineUpdate': '%@ sürümüne güncelle',
    'engineDownloadVersion': '%@ indir',
    'engineDownloading': '%@ indiriliyor · %%%d',
    'engineStop': 'durdurmak için seç',
    'engineDownloaded': 'İndirildi · kullanmak için seç',
    'engineSizeDetail': '%@ · indirmek için seç',
    'enginePrerelease': 'Ön sürüm',
    'engineOwn': 'Kendi klasörümü kullan',
    'engineSwitched': 'Artık AnyPS5 motoru %@ kullanılıyor',
    'engineDeleteOld': 'Diğer sürümleri sil',
    'engineDeleteOldDetail': 'Kullanılmayan indirilmiş sürüm: %d',
    'engineDeleted': 'Diğer motor sürümleri silindi',
    'engineUpdateAndPlayDetail':
        'AnyPS5 motoru %@ (%@) indirilir, sonra oyunun kilidi yeniden açılır; kayıtlar ve kupalar korunur',
    'resolutionReinstall': 'Oyun yeniden kurulunca geçerli olur',
    'linkModeHard': 'Oyun dosyaları dump\'a bağlanır, fazladan yer kaplamaz',
    'phoneServer': 'Telefon kumandası',
    'phoneServerDetail': 'Aynı ağdaki AnyPS5 Remote bu bilgisayarı bulur',
    'phoneAddress': 'Telefon için adres',
    'backUpSavesDetail': 'Kayıtlar ve kupalar, AnyPS5 Backups klasörüne',
    'restoreLatest': 'Son yedeği geri yükle',
  };

  /// The text for [key] in the current language, English when the language has none.
  static String text(String key) {
    final turkish = language == Language.turkish;
    return (turkish ? _turkish[key] ?? togetherTurkish[key] ?? turkishTable[key] : null) ??
        _english[key] ??
        togetherEnglish[key] ??
        englishTable[key] ??
        key;
  }

  /// [text] with its %@ and %d placeholders filled in order (%1\$@ names its argument);
  /// %% is a percent sign.
  static String format(String key, List<Object> arguments) {
    final template = text(key);
    final out = StringBuffer();
    var next = 0;
    for (var index = 0; index < template.length; index++) {
      final char = template[index];
      final positional = RegExp(r'%(\d)\$([@d])').matchAsPrefix(template, index);
      if (positional != null) {
        final at = int.parse(positional.group(1)!) - 1;
        out.write(at >= 0 && at < arguments.length ? arguments[at] : '');
        index += positional.group(0)!.length - 1;
        continue;
      }
      if (char == '%' && index + 1 < template.length) {
        final kind = template[index + 1];
        if (kind == '%') {
          out.write('%');
          index++;
          continue;
        }
        if (kind == '@' || kind == 'd') {
          out.write(next < arguments.length ? arguments[next] : '');
          next++;
          index++;
          continue;
        }
      }
      out.write(char);
    }
    return out.toString();
  }
}
