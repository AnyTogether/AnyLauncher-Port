/// The texts of the free-space check before an unlock and of new games prepared in the
/// background, in both languages; kept apart from the other tables like the Steam ones.
const prepareEnglish = <String, String>{
  'prepareNewGames': 'Prepare New Games Automatically',
  'prepareNewGamesDetail':
      "A game copied into the games folder unlocks in the background while you're not playing, so it's ready "
      'when you get to it. Never during a game or on a low battery',
  'newGamePreparing': 'New game: %@ · Preparing…',
  'newGamesPreparing': '%d new games · Preparing…',
  'newGameWaiting': 'New game: %@ · Prepares after your game',
  'newGamesWaiting': '%d new games · Prepare after your game',
  'newGameNotPreparedBattery': 'New game: %@ · Plug in to prepare it',
  'newGameNotPreparedSpace': 'New game: %@ · Not enough space to prepare it',
  'preparing': 'Preparing…',
  'preparingStep': 'Preparing · %@',
  'preparingPaused': 'Paused for your game',
  'waitingToPrepare': 'Prepares after your game',
  'playWhenReady': 'Play When Ready',
  'startsWhenReady': "%@ starts as soon as it's ready",
  'readyToPlay': '%@ · Ready to play',
  'readyToPlayDetail': 'Prepared in the background',
  'notPreparedBattery': "%@ wasn't prepared: the battery is low",
  'notPreparedSpace': "%@ wasn't prepared: it needs %@, %@ is free",
  'noSpaceTitle': 'Not enough space',
  'noSpaceAmount': 'Needs %@ · %@ free where your games folder is',
  'noSpaceNothingWritten':
      'The unlock did not start and nothing was written. Make room, or unlock into a games folder on a drive with '
      'more space.',
  'noSpaceWhy':
      "Unlocking writes the game's executable and modules converted for this PC. Linked game files take no extra "
      'space; copied ones take their whole size.',
  'noSpaceCopying': 'Most of it is the game\'s files, which must be copied: %@',
  'noSpaceFolder': 'Choose a games folder on a drive with more room',
  'noSpaceFolderDetail': "On the dump's drive the game's files are linked, so they cost nothing",
  'noSpaceRetry': 'Try again',
  'noSpaceRetryDetail': 'After making room',
  'copySpace': 'Needs %@ · %@ free',
};

const prepareTurkish = <String, String>{
  'prepareNewGames': 'Yeni Oyunları Otomatik Hazırla',
  'prepareNewGamesDetail':
      'Oyun klasörüne kopyalanan oyun, sen oynamıyorken arka planda açılır; sıra ona geldiğinde hazırdır. Oyun '
      'sırasında ya da pil azken asla',
  'newGamePreparing': 'Yeni oyun: %@ · Hazırlanıyor…',
  'newGamesPreparing': '%d yeni oyun · Hazırlanıyor…',
  'newGameWaiting': 'Yeni oyun: %@ · Oyunun bitince hazırlanacak',
  'newGamesWaiting': '%d yeni oyun · Oyunun bitince hazırlanacak',
  'newGameNotPreparedBattery': 'Yeni oyun: %@ · Hazırlamak için şarja tak',
  'newGameNotPreparedSpace': 'Yeni oyun: %@ · Hazırlamaya yer yok',
  'preparing': 'Hazırlanıyor…',
  'preparingStep': 'Hazırlanıyor · %@',
  'preparingPaused': 'Oyun için durdu',
  'waitingToPrepare': 'Oyunun bitince hazırlanacak',
  'playWhenReady': 'Hazır Olunca Oyna',
  'startsWhenReady': '%@ hazır olur olmaz başlayacak',
  'readyToPlay': '%@ · Oynamaya hazır',
  'readyToPlayDetail': 'Arka planda hazırlandı',
  'notPreparedBattery': '%@ hazırlanmadı: pil az',
  'notPreparedSpace': '%@ hazırlanmadı: %@ gerekiyor, %@ boş',
  'noSpaceTitle': 'Yeterli alan yok',
  'noSpaceAmount': '%@ gerekiyor · oyun klasörünün olduğu yerde %@ boş',
  'noSpaceNothingWritten':
      'Kilit açma başlamadı, hiçbir şey yazılmadı. Yer aç ya da daha fazla alanı olan bir sürücüde oyun klasörü seç.',
  'noSpaceWhy':
      'Kilit açma, oyunun çalıştırılabilir dosyasını ve modüllerini bu PC için dönüştürüp yazar. Bağlanan oyun '
      'dosyaları ek yer kaplamaz; kopyalananlar boyutları kadar yer kaplar.',
  'noSpaceCopying': 'Çoğu, kopyalanması gereken oyun dosyaları: %@',
  'noSpaceFolder': 'Daha fazla yeri olan bir sürücüde oyun klasörü seç',
  'noSpaceFolderDetail': "Dump'ın olduğu sürücüde oyunun dosyaları bağlanır, yer kaplamaz",
  'noSpaceRetry': 'Yeniden dene',
  'noSpaceRetryDetail': 'Yer açtıktan sonra',
  'copySpace': '%@ gerekiyor · %@ boş',
};
