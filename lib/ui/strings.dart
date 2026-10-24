import 'strings_table.dart';

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
    'noToolkit': 'No AnyPS5 toolkit yet: choose the folder with the relinker and the libs folder in Settings.',
    'saveSyncDetail': 'Saves and trophies stay the same on your other computers through %@',
    'saveSyncNoFolder': 'Saves and trophies stay the same on your other computers through a folder; choose one first',
    'syncFolderNone': 'None: choose Dropbox, OneDrive or a shared folder',
    'toolkit': 'Toolkit',
    'toolkitDetail': 'The relinker and system libraries for this system',
    'toolkitMissing': 'Not found',
    'toolkitChoose': 'Choose toolkit folder',
    'chooseToolkit': 'Where is the toolkit?',
    'chooseToolkitSubtitle':
        'The folder with the relinker and libs/ built for this system, as the AnyPS5 release '
        'archives lay it out. You can also set it later in Settings.',
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
    'noToolkit': "Henüz AnyPS5 araç seti yok: Ayarlar'dan relinker ve libs klasörünün olduğu klasörü seç.",
    'saveSyncDetail': 'Kayıtlar ve kupalar %@ üzerinden diğer bilgisayarlarla aynı kalır',
    'saveSyncNoFolder': 'Kayıtlar ve kupalar bir klasör üzerinden diğer bilgisayarlarla aynı kalır; önce klasör seç',
    'syncFolderNone': 'Seçilmedi: Dropbox, OneDrive ya da paylaşılan bir klasör seç',
    'toolkit': 'Araç seti',
    'toolkitDetail': 'Bu sistem için relinker ve sistem kütüphaneleri',
    'toolkitMissing': 'Bulunamadı',
    'toolkitChoose': 'Araç seti klasörünü seç',
    'chooseToolkit': 'Araç seti nerede?',
    'chooseToolkitSubtitle':
        'Bu sistem için derlenmiş relinker ve libs/ klasörünün olduğu klasör, AnyPS5 '
        "sürüm arşivlerindeki gibi. Sonra Ayarlar'dan da seçebilirsin.",
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
    return (turkish ? _turkish[key] ?? turkishTable[key] : null) ?? _english[key] ?? englishTable[key] ?? key;
  }

  /// [text] with its %@ and %d placeholders filled in order; %% is a percent sign.
  static String format(String key, List<Object> arguments) {
    final template = text(key);
    final out = StringBuffer();
    var next = 0;
    for (var index = 0; index < template.length; index++) {
      final char = template[index];
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
