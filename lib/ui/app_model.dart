import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/controls.dart';
import '../core/game_library.dart';
import '../core/game_process.dart';
import '../core/game_settings.dart';
import '../core/host.dart';
import '../core/installer.dart';
import '../core/remote/adb_tunnel.dart';
import '../core/remote/mdns.dart';
import '../core/remote/paired_devices.dart';
import '../core/remote/remote_protocol.dart';
import '../core/remote/remote_server.dart';
import '../core/save_backup.dart';
import '../core/toolkit.dart';
import '../core/trophies.dart';
import 'strings.dart';
import 'theme.dart';

/// The launcher's own choices, kept as JSON in the config folder.
class Preferences {
  Preferences();

  factory Preferences.fromJson(Map<String, dynamic> json) => Preferences()
    ..language = json['language'] as String? ?? 'en'
    ..theme = (json['theme'] as num?)?.toInt() ?? 0
    ..accent = json['accent'] as String?
    ..profileName = json['profileName'] as String? ?? 'Player'
    ..gamesFolder = json['gamesFolder'] as String?
    ..toolkitFolder = json['toolkitFolder'] as String?
    ..onboarded = json['onboarded'] as bool? ?? false
    ..gameArtwork = json['gameArtwork'] as bool? ?? true
    ..reducedMotion = json['reducedMotion'] as bool? ?? false
    ..phoneServer = json['phoneServer'] as bool? ?? true
    ..lastPlayed = {
      for (final entry in (json['lastPlayed'] as Map<String, dynamic>? ?? const {}).entries)
        entry.key: entry.value as String,
    };

  String language = 'en';
  int theme = 0;
  String? accent;
  String profileName = 'Player';
  String? gamesFolder;
  String? toolkitFolder;
  bool onboarded = false;
  bool gameArtwork = true;
  bool reducedMotion = false;
  bool phoneServer = true;
  Map<String, String> lastPlayed = {};

  Map<String, Object?> toJson() => {
    'language': language,
    'theme': theme,
    'accent': accent,
    'profileName': profileName,
    'gamesFolder': gamesFolder,
    'toolkitFolder': toolkitFolder,
    'onboarded': onboarded,
    'gameArtwork': gameArtwork,
    'reducedMotion': reducedMotion,
    'phoneServer': phoneServer,
    'lastPlayed': lastPlayed,
  };

  static Preferences load(String file) {
    try {
      final json = jsonDecode(File(file).readAsStringSync());
      return json is Map<String, dynamic> ? Preferences.fromJson(json) : Preferences();
    } on Object {
      return Preferences();
    }
  }

  void save(String file) {
    try {
      File(file).parent.createSync(recursive: true);
      File(file).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
    } on FileSystemException {
      // Kept in memory for this run.
    }
  }
}

/// What the launcher shows about a game.
sealed class GameState {
  const GameState();
}

class Locked extends GameState {
  const Locked();
}

class Unreadable extends GameState {
  const Unreadable();
}

class Queued extends GameState {
  const Queued();
}

class Installing extends GameState {
  const Installing(this.step, this.fraction);
  final InstallStep step;
  final double fraction;

  /// The share of the whole install done, for one bar.
  double get overall => InstallSpan.overall(step, fraction);
}

class Failed extends GameState {
  const Failed(this.message);
  final String message;
}

class Installed extends GameState {
  const Installed({this.outdated = false});

  /// Made with another toolkit than the current one.
  final bool outdated;
}

class Starting extends GameState {
  const Starting();
}

class Running extends GameState {
  const Running();
}

/// Each install step's share of the whole, for one overall bar.
abstract final class InstallSpan {
  static (double, double) of(InstallStep step) => switch (step) {
    InstallStep.unwrap => (0, 0.12),
    InstallStep.relink => (0.12, 0.5),
    InstallStep.copy => (0.62, 0.26),
    InstallStep.layout => (0.88, 0.08),
    InstallStep.finish => (0.96, 0.04),
  };

  static double overall(InstallStep step, double fraction) {
    final (start, length) = of(step);
    return start + length * fraction;
  }

  static String title(InstallStep step) => T.text(switch (step) {
    InstallStep.unwrap => 'stepUnwrap',
    InstallStep.relink => 'stepRelink',
    InstallStep.copy => 'stepCopy',
    InstallStep.layout => 'stepBundle',
    InstallStep.finish => 'stepFinish',
  });
}

/// A move on the launcher's screen, from the keyboard or the phone.
enum Command { left, right, up, down, select, back, options, previousGame, nextGame, home }

/// Where the home screen's focus is: the tiles, a top-bar button, or a button under the title.
class HomeFocus {
  const HomeFocus._(this.area, this.index);
  static const tiles = HomeFocus._('tiles', 0);
  const HomeFocus.top(int index) : this._('top', index);
  const HomeFocus.actions(int index) : this._('actions', index);

  final String area;
  final int index;

  bool get isTiles => area == 'tiles';
  bool get isTop => area == 'top';
  bool get isActions => area == 'actions';

  @override
  bool operator ==(Object other) => other is HomeFocus && other.area == area && other.index == index;

  @override
  int get hashCode => Object.hash(area, index);
}

enum Layer { library, settings, gameSettings, controls, confirmUninstall, updateChoice, log, trophies }

/// A settings row the panels draw and the keyboard moves through.
class PanelRow {
  const PanelRow({required this.id, required this.title, required this.kind, this.detail, this.glyph});

  final String id;
  final String title;
  final String? detail;

  /// A face button drawn after the title.
  final PadGlyph? glyph;
  final RowKind kind;

  bool get focusable => kind is! InfoRow;
}

sealed class RowKind {
  const RowKind();
}

class ChoiceRow extends RowKind {
  const ChoiceRow(this.options, this.selected, this.set);
  final List<String> options;
  final int selected;
  final void Function(int) set;
}

class ToggleRow extends RowKind {
  const ToggleRow(this.value, this.set);
  final bool value;
  final void Function(bool) set;
}

class StepperRow extends RowKind {
  const StepperRow({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.set,
  });
  final int value;
  final int min;
  final int max;
  final int step;
  final String Function(int) format;
  final void Function(int) set;
}

class ActionRow extends RowKind {
  const ActionRow(this.run, {this.destructive = false});
  final void Function() run;
  final bool destructive;
}

class InfoRow extends RowKind {
  const InfoRow(this.text);
  final String text;
}

/// A pad action's keys and mouse buttons; choosing it waits for a key.
class KeysRow extends RowKind {
  const KeysRow(this.sources, {required this.capturing, required this.capture});
  final List<String> sources;
  final bool capturing;
  final void Function() capture;
}

class PanelCategory {
  const PanelCategory({required this.id, required this.title, required this.rows});
  final String id;
  final String title;
  final List<PanelRow> rows;
}

/// What the launcher needs from the system, replaceable in tests.
class LauncherServices {
  const LauncherServices({
    this.pickFolder,
    this.openFolder,
    this.computerName,
    this.advertise = true,
    this.preferredPorts = true,
    this.cable = true,
  });

  /// Whether Android phones on a USB cable are joined through adb (off in tests).
  final bool cable;

  /// Whether the phone server is announced on the network (off in tests).
  final bool advertise;

  /// Whether the phone server tries its usual ports first (off in tests: any free port).
  final bool preferredPorts;

  /// Asks the user for a folder; null when they cancelled.
  final Future<String?> Function(String title)? pickFolder;

  /// Shows a folder in the system's file manager.
  final void Function(String folder)? openFolder;
  final String? computerName;
}

/// The launcher's state and everything the interface does with it.
class AppModel extends ChangeNotifier {
  AppModel({
    required this.paths,
    Preferences? preferences,
    this.services = const LauncherServices(),
    HostSystem? system,
    this.persist = true,
  }) : system = system ?? HostSystem.current,
       preferences = preferences ?? Preferences.load(paths.preferencesFile),
       settingsStore = GameSettingsStore(paths.gameSettingsFolder) {
    T.language = Language.byCode(this.preferences.language);
    Motion.reduced = this.preferences.reducedMotion;
  }

  final AppPaths paths;
  final Preferences preferences;
  final LauncherServices services;
  final HostSystem system;
  final GameSettingsStore settingsStore;

  /// Whether choices are written to disk (off in previews and tests).
  final bool persist;

  List<Game> games = [];
  int selected = 0;
  int libraryIndex = 0;
  HomeFocus focus = HomeFocus.tiles;
  Layer? overlay;
  bool scanning = false;

  /// The panel row the keyboard is on, and in the settings, the category.
  int panelRow = 0;
  int panelCategory = 0;

  /// The pad action waiting for a key in the controls panel.
  PadAction? capturing;

  final Map<String, InstallRecord> records = {};
  final Map<String, (InstallStep, double)> progress = {};
  final List<String> queue = [];
  final Map<String, String> failures = {};
  final Map<String, int> sizes = {};

  /// Each game's trophies, read at the scan; a game without trophy packages has none.
  final Map<String, TrophySet> trophies = {};
  int trophyIndex = 0;
  Timer? _trophyWatch;
  Set<String> _earned = {};
  Installer? _installer;
  String? _playAfterInstall;

  Game? starting;
  (Game, RunningGame)? running;

  /// A short message at the bottom of the screen.
  String? toast;
  Timer? _toastTimer;

  RemoteServer? remote;
  ServiceAdvertiser? _advertiser;
  AdbTunnel? _adb;
  PairingRequest? pairing;
  String? phoneConnecting;
  double? phoneLatency;
  String? remoteError;
  RemoteMessage? _toldLibrary;

  LookStyle get look => LookStyle.values[preferences.theme.clamp(0, LookStyle.values.length - 1)];

  Accent get accentChoice =>
      Accent.values.firstWhere((accent) => accent.name == preferences.accent, orElse: () => look.defaultAccent);

  Game? get selectedGame => games.isEmpty ? null : games[selected.clamp(0, games.length - 1)];

  Toolkit? get toolkit {
    final folder = preferences.toolkitFolder;
    return Toolkit.locate([?folder], system: system);
  }

  String? get root => preferences.gamesFolder;

  void _changed() {
    notifyListeners();
    _publishLibrary();
  }

  void savePreferences() {
    if (persist) preferences.save(paths.preferencesFile);
    _changed();
  }

  // Library.

  /// Scans the games folder, reads the installed records and the sizes.
  void rescan() {
    final folder = root;
    if (folder == null) {
      games = [];
      _changed();
      return;
    }
    final previous = selectedGame?.id;
    games = GameLibrary.scan(folder);
    records.clear();
    trophies.clear();
    for (final game in games) {
      final installed = Installer.installedFolder(game, folder);
      final record = Installer.record(installed, system: system);
      if (record != null) records[game.id] = record;
      _loadTrophies(game);
    }
    final index = games.indexWhere((game) => game.id == previous);
    selected = index >= 0 ? index : 0;
    _changed();
  }

  void _loadTrophies(Game game) {
    final folder = root;
    if (folder == null) return;
    final installed = Installer.installedFolder(game, folder);
    final language = ConsoleLanguage.tag(T.language.consoleLanguage);
    final set = Trophies.load(game, installed: installed, languages: [?language]);
    if (set == null) {
      trophies.remove(game.id);
    } else {
      trophies[game.id] = set;
    }
  }

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _rescanSoon;
  String? _watched;

  /// Watches the games folder: a dump copied in or removed shows up on its own, a moment after
  /// the folder settles. (Linux watches the folder itself, Windows and macOS the whole tree.)
  void watchGamesFolder() {
    final folder = root;
    if (folder == _watched) return;
    unawaited(_watch?.cancel());
    _watch = null;
    _watched = folder;
    if (folder == null || !Directory(folder).existsSync()) return;
    try {
      _watch = Directory(folder).watch(recursive: !Platform.isLinux).listen((event) {
        if (event.path.contains(GameLibrary.storeName)) return;
        _rescanSoon?.cancel();
        _rescanSoon = Timer(const Duration(seconds: 2), () {
          if (_installer == null) rescan();
        });
      }, onError: (Object _) {});
    } on FileSystemException {
      // No watching: the rescan in Settings still works.
    }
  }

  /// The size of the selected game, measured once.
  void measureSelected() {
    final game = selectedGame;
    if (game == null || sizes.containsKey(game.id)) return;
    sizes[game.id] = GameLibrary.size(game.folder);
  }

  GameState stateOf(Game game) {
    if (running?.$1 == game) return const Running();
    if (starting == game) return const Starting();
    final current = progress[game.id];
    if (current != null) return Installing(current.$1, current.$2);
    if (queue.contains(game.id)) return const Queued();
    final failure = failures[game.id];
    if (failure != null) return Failed(failure);
    final record = records[game.id];
    if (record != null) {
      final version = toolkit?.version;
      return Installed(outdated: version != null && version != record.toolkit);
    }
    if (game.executable == ExecutableKind.unreadable) return const Unreadable();
    return const Locked();
  }

  GameSettings settingsFor(Game game) => settingsStore.load(game.slug);

  void saveSettings(Game game, GameSettings settings) {
    if (persist) settingsStore.save(game.slug, settings);
    _cachedSettings[game.slug] = settings;
    _changed();
  }

  final Map<String, GameSettings> _cachedSettings = {};

  GameSettings currentSettings(Game game) => _cachedSettings.putIfAbsent(game.slug, () => settingsFor(game));

  Future<void> chooseGamesFolder() async {
    final folder = await services.pickFolder?.call(T.text('chooseFolder'));
    if (folder == null) return;
    preferences.gamesFolder = folder;
    savePreferences();
    rescan();
    watchGamesFolder();
  }

  Future<void> chooseToolkit() async {
    final folder = await services.pickFolder?.call(T.text('toolkitChoose'));
    if (folder == null) return;
    preferences.toolkitFolder = folder;
    savePreferences();
  }

  // Installing.

  void primaryAction(Game game) {
    switch (stateOf(game)) {
      case Installed(:final outdated):
        outdated ? open(Layer.updateChoice) : play(game);
      case Locked() || Failed():
        unlock(game);
      case Installing() || Queued():
        cancelUnlock(game);
      case Unreadable():
        show(T.text('unreadableDump'));
      case Starting() || Running():
        break;
    }
  }

  void unlock(Game game) {
    if (root == null) return;
    if (toolkit == null) return show(T.text('noToolkit'));
    failures.remove(game.id);
    if (!queue.contains(game.id) && !progress.containsKey(game.id)) queue.add(game.id);
    _changed();
    _startNext();
  }

  void updateAndPlay(Game game) {
    _playAfterInstall = game.id;
    unlock(game);
  }

  void cancelUnlock(Game game) {
    if (_playAfterInstall == game.id) _playAfterInstall = null;
    if (queue.remove(game.id)) return _changed();
    if (progress.containsKey(game.id)) _installer?.cancel();
  }

  void _startNext() {
    final folder = root;
    final kit = toolkit;
    if (_installer != null || queue.isEmpty || folder == null || kit == null) return;
    final id = queue.removeAt(0);
    final game = games.where((game) => game.id == id).firstOrNull;
    if (game == null) return _startNext();
    progress[id] = (InstallStep.unwrap, 0);
    final installer = Installer(
      game: game,
      toolkit: kit,
      root: folder,
      resolution: currentSettings(game).resolution,
      onProgress: (step, fraction) {
        progress[id] = (step, fraction);
        notifyListeners();
        _publishActivity();
      },
      onLog: (line) => _appendLog(game, line),
    );
    _installer = installer;
    _changed();
    unawaited(() async {
      try {
        final installed = await installer.run();
        final record = Installer.record(installed, system: system);
        if (record != null) records[id] = record;
        show('${game.name} · ${T.text('ready')}');
        if (_playAfterInstall == id) {
          _playAfterInstall = null;
          unawaited(play(game));
        }
      } on InstallCancelled {
        // Nothing to say.
      } on Object catch (error) {
        failures[id] = error.toString();
        show('${T.text('unlockFailed')}: ${game.name}');
      } finally {
        _installer = null;
        progress.remove(id);
        _changed();
        _publishActivity();
        _startNext();
      }
    }());
  }

  void uninstall(Game game) {
    final folder = root;
    if (folder == null) return;
    Installer.uninstall(game, folder);
    records.remove(game.id);
    show(T.text('uninstallDone'));
    _changed();
  }

  void clearShaderCache(Game game) {
    final cache = Directory(p.dirname(paths.shaderCache(game.slug)));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    show(T.text('cacheCleared'));
  }

  String backupFolder(Game game) => SaveBackup.folderFor(paths.backupsFolder, game.name, game.titleId);

  String? _lastBackupText(Game game) {
    final latest = SaveBackup.backups(backupFolder(game)).firstOrNull;
    if (latest == null) return null;
    return T.format('lastBackup', [p.basenameWithoutExtension(latest)]);
  }

  void backUpSaves(Game game) {
    final folder = root;
    if (folder == null) return;
    try {
      SaveBackup.backUp(Installer.installedFolder(game, folder), backupFolder(game), DateTime.now());
      show(T.text('savesBackedUp'));
    } on Object catch (error) {
      show('${T.text('backupFailed')}: $error');
    }
    _changed();
  }

  void restoreLatestSaves(Game game) {
    final folder = root;
    final latest = SaveBackup.backups(backupFolder(game)).firstOrNull;
    if (folder == null || latest == null) return;
    if (running?.$1 == game) return show(T.text('closeGameFirst'));
    try {
      SaveBackup.restore(latest, Installer.installedFolder(game, folder), backupFolder(game), DateTime.now());
      _loadTrophies(game);
      show(T.text('savesRestored'));
    } on Object catch (error) {
      show('${T.text('backupFailed')}: $error');
    }
    _changed();
  }

  void _appendLog(Game game, String line) {
    try {
      final file = File(paths.logFile(game.titleId));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } on FileSystemException {
      // The log is a help, not a need.
    }
  }

  String logText(Game game) {
    try {
      final text = File(paths.logFile(game.titleId)).readAsStringSync();
      return text.length > 60000 ? text.substring(text.length - 60000) : text;
    } on FileSystemException {
      return '';
    }
  }

  // Playing.

  Future<void> play(Game game) async {
    final folder = root;
    if (folder == null || starting != null || running != null) return;
    final settings = currentSettings(game);
    final inputFile = p.join(paths.inputFilesFolder, '${game.slug}.ini');
    var written = true;
    try {
      settings.writeInputFile(inputFile);
    } on FileSystemException {
      written = false;
    }
    try {
      Directory(paths.pictures).createSync(recursive: true);
    } on FileSystemException {
      // Screenshots go nowhere then.
    }
    final environment = {
      ...settings.environment(
        launcherLanguage: T.language.consoleLanguage,
        inputFile: written ? inputFile : null,
        screenshots: paths.pictures,
        fonts: Directory(paths.fontsFolder).existsSync() ? paths.fontsFolder : null,
        shaderCacheFolder: paths.shaderCache(game.slug),
      ),
      ...?remote?.bridgeEnvironment,
    };
    starting = game;
    preferences.lastPlayed[game.id] = DateTime.now().toIso8601String();
    savePreferences();
    try {
      final run = await GameProcess.start(
        installed: Installer.installedFolder(game, folder),
        environment: environment,
        logFile: paths.logFile(game.titleId),
        system: system,
      );
      starting = null;
      running = (game, run);
      _watchTrophies(game);
      _changed();
      final code = await run.exitCode;
      _trophyWatch?.cancel();
      _loadTrophies(game);
      if (running?.$1 == game) running = null;
      if (code != 0) show('${T.text('gameEnded')} ($code)');
      _changed();
    } on Object catch (error) {
      starting = null;
      show('${T.text('startFailed')}: $error');
      _changed();
    }
  }

  /// While a game runs, a trophy it earns shows and goes to the phones.
  void _watchTrophies(Game game) {
    final folder = root;
    if (folder == null) return;
    final installed = Installer.installedFolder(game, folder);
    _earned = Trophies.earned(installed);
    _trophyWatch?.cancel();
    _trophyWatch = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = Trophies.earned(installed);
      final fresh = now.difference(_earned);
      _earned = now;
      if (fresh.isEmpty) return;
      _loadTrophies(game);
      for (final id in fresh) {
        final trophy = trophies[game.id]?.trophies.where((trophy) => trophy.id == id).firstOrNull;
        if (trophy == null) continue;
        show('${T.text('trophyEarned')} · ${trophy.name}');
        remote?.publish(
          RemoteTrophy(
            name: trophy.name,
            detail: trophy.detail,
            grade: trophy.grade.name,
            icon: trophy.icon == null ? null : base64.encode(trophy.icon!),
          ),
        );
      }
      _changed();
    });
  }

  void stopGame() {
    running?.$2.stop();
  }

  // Messages.

  void show(String message) {
    toast = message;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      toast = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // Navigation.

  void open(Layer next) {
    overlay = next;
    panelRow = 0;
    panelCategory = 0;
    capturing = null;
    if (next == Layer.library) libraryIndex = selected;
    if (next == Layer.trophies) trophyIndex = 0;
    _skipToFocusable();
    _changed();
  }

  void closeOverlay() {
    overlay = null;
    capturing = null;
    _changed();
  }

  void select(int index) {
    if (index < 0 || index >= games.length) return;
    selected = index;
    focus = HomeFocus.tiles;
    measureSelected();
    _changed();
  }

  /// Play, the trophies when the game has any, and the settings.
  int get actionCount => selectedGame != null && trophies.containsKey(selectedGame!.id) ? 3 : 2;

  /// Which of the buttons under the title opens the settings.
  int get settingsAction => actionCount - 1;

  void moveSelection(int delta) {
    final next = (selected + delta).clamp(0, games.isEmpty ? 0 : games.length - 1);
    if (next == selected) return;
    selected = next;
    if (focus.isActions && focus.index >= actionCount) focus = HomeFocus.actions(actionCount - 1);
    if (overlay == Layer.trophies) {
      trophyIndex = 0;
      if (!trophies.containsKey(selectedGame?.id)) overlay = null;
    }
    measureSelected();
    _changed();
  }

  /// Home screen, library and panels: what a command does where the user is.
  void handle(Command command) {
    if (pairing != null) {
      if (command == Command.select) answerPairing(true);
      if (command == Command.back) answerPairing(false);
      return;
    }
    if (!preferences.onboarded) return _onboardingCommand(command);
    if (command == Command.home) {
      if (overlay != null) closeOverlay();
      return;
    }
    if (command == Command.previousGame || command == Command.nextGame) {
      if (capturing == null &&
          (overlay == null ||
              overlay == Layer.gameSettings ||
              overlay == Layer.controls ||
              overlay == Layer.trophies)) {
        moveSelection(command == Command.nextGame ? 1 : -1);
      }
      return;
    }
    switch (overlay) {
      case Layer.library:
        final columns = libraryColumns;
        switch (command) {
          case Command.left:
            _moveLibrary(-1);
          case Command.right:
            _moveLibrary(1);
          case Command.up:
            _moveLibrary(-columns);
          case Command.down:
            _moveLibrary(columns);
          case Command.select:
            select(libraryIndex);
            closeOverlay();
          case Command.back || Command.options:
            closeOverlay();
          default:
            break;
        }
        return;
      case Layer.log:
        if (command == Command.back || command == Command.select) closeOverlay();
        return;
      case Layer.trophies:
        final count = trophies[selectedGame?.id]?.trophies.length ?? 0;
        switch (command) {
          case Command.up:
            trophyIndex = (trophyIndex - 1).clamp(0, count == 0 ? 0 : count - 1);
            _changed();
          case Command.down:
            trophyIndex = (trophyIndex + 1).clamp(0, count == 0 ? 0 : count - 1);
            _changed();
          case Command.back || Command.options:
            closeOverlay();
          default:
            break;
        }
        return;
      case Layer.controls:
        if (capturing != null) {
          if (command == Command.back) {
            capturing = null;
            _changed();
          }
          return;
        }
        if (command == Command.back || command == Command.options) {
          open(Layer.gameSettings);
          return;
        }
        _panelCommand(command);
        return;
      case Layer.settings || Layer.gameSettings || Layer.confirmUninstall || Layer.updateChoice:
        _panelCommand(command);
        return;
      case null:
        break;
    }
    final game = selectedGame;
    if (game == null) {
      if (command == Command.select) unawaited(chooseGamesFolder());
      return;
    }
    switch ((focus.area, command)) {
      case ('tiles', Command.left):
        moveSelection(-1);
      case ('tiles', Command.right):
        moveSelection(1);
      case ('tiles', Command.down):
        _moveFocus(const HomeFocus.actions(0));
      case ('tiles', Command.up):
        _moveFocus(const HomeFocus.top(1));
      case ('tiles', Command.select):
        primaryAction(game);
      case ('top', Command.left):
        _moveFocus(HomeFocus.top((focus.index - 1).clamp(0, 1)));
      case ('top', Command.right):
        _moveFocus(HomeFocus.top((focus.index + 1).clamp(0, 1)));
      case ('top', Command.down) || ('top', Command.back):
        _moveFocus(HomeFocus.tiles);
      case ('top', Command.select):
        open(focus.index == 0 ? Layer.library : Layer.settings);
      case ('actions', Command.left):
        _moveFocus(HomeFocus.actions((focus.index - 1).clamp(0, actionCount - 1)));
      case ('actions', Command.right):
        _moveFocus(HomeFocus.actions((focus.index + 1).clamp(0, actionCount - 1)));
      case ('actions', Command.up) || ('actions', Command.back):
        _moveFocus(HomeFocus.tiles);
      case ('actions', Command.select):
        if (focus.index == 0) {
          primaryAction(game);
        } else if (focus.index == 1 && actionCount == 3) {
          open(Layer.trophies);
        } else {
          open(Layer.gameSettings);
        }
      case (_, Command.options):
        open(Layer.gameSettings);
      default:
        break;
    }
  }

  static const libraryColumns = 6;

  void _moveLibrary(int delta) {
    final next = (libraryIndex + delta).clamp(0, games.isEmpty ? 0 : games.length - 1);
    if (next == libraryIndex) return;
    libraryIndex = next;
    _changed();
  }

  void _moveFocus(HomeFocus next) {
    if (next == focus) return;
    focus = next;
    _changed();
  }

  // Panels.

  List<PanelCategory> panelCategories() {
    final game = selectedGame;
    switch (overlay) {
      case Layer.settings:
        return _settingsCategories();
      case Layer.gameSettings when game != null:
        return [PanelCategory(id: 'game', title: game.name, rows: _gameRows(game))];
      case Layer.controls when game != null:
        return [PanelCategory(id: 'controls', title: game.name, rows: _controlRows(game))];
      case Layer.confirmUninstall when game != null:
        return [
          PanelCategory(
            id: 'confirm',
            title: T.text('uninstall'),
            rows: [
              PanelRow(
                id: 'confirm',
                title: T.text('uninstall'),
                detail: T.text('uninstallConfirm'),
                kind: ActionRow(() {
                  uninstall(game);
                  closeOverlay();
                }, destructive: true),
              ),
              PanelRow(id: 'cancel', title: T.text('cancel'), kind: ActionRow(closeOverlay)),
            ],
          ),
        ];
      case Layer.updateChoice when game != null:
        return [
          PanelCategory(
            id: 'update',
            title: T.text('updateAvailable'),
            rows: [
              PanelRow(
                id: 'update',
                title: T.text('updateAndPlay'),
                detail: T.text('updateAndPlayDetail'),
                kind: ActionRow(() {
                  closeOverlay();
                  updateAndPlay(game);
                }),
              ),
              PanelRow(
                id: 'play',
                title: T.text('playNow'),
                detail: T.text('playNowDetail'),
                kind: ActionRow(() {
                  closeOverlay();
                  unawaited(play(game));
                }),
              ),
            ],
          ),
        ];
      default:
        return const [];
    }
  }

  List<PanelCategory> _settingsCategories() {
    final kit = toolkit;
    return [
      PanelCategory(
        id: 'appearance',
        title: T.text('appearance'),
        rows: [
          PanelRow(
            id: 'theme',
            title: T.text('theme'),
            kind: ChoiceRow([for (final style in LookStyle.values) style.title], preferences.theme, (index) {
              preferences
                ..theme = index
                ..accent = null;
              savePreferences();
            }),
          ),
          PanelRow(
            id: 'accent',
            title: T.text('accent'),
            kind: ChoiceRow([for (final accent in Accent.values) accent.title], accentChoice.index, (index) {
              preferences.accent = Accent.values[index].name;
              savePreferences();
            }),
          ),
          PanelRow(
            id: 'artwork',
            title: T.text('gameArtwork'),
            kind: ToggleRow(preferences.gameArtwork, (value) {
              preferences.gameArtwork = value;
              savePreferences();
            }),
          ),
          PanelRow(
            id: 'motion',
            title: T.text('motion'),
            kind: ChoiceRow([T.text('motionFull'), T.text('motionReduced')], preferences.reducedMotion ? 1 : 0, (
              index,
            ) {
              preferences.reducedMotion = index == 1;
              Motion.reduced = preferences.reducedMotion;
              savePreferences();
            }),
          ),
        ],
      ),
      PanelCategory(
        id: 'library',
        title: T.text('library'),
        rows: [
          PanelRow(
            id: 'folder',
            title: T.text('folder'),
            detail: preferences.gamesFolder ?? '—',
            kind: ActionRow(() => unawaited(chooseGamesFolder())),
          ),
          PanelRow(id: 'rescan', title: T.text('rescan'), kind: ActionRow(rescan)),
          PanelRow(
            id: 'toolkit',
            title: T.text('toolkit'),
            detail: kit == null ? T.text('toolkitMissing') : '${kit.root} · ${kit.version}',
            kind: ActionRow(() => unawaited(chooseToolkit())),
          ),
        ],
      ),
      PanelCategory(
        id: 'phone',
        title: T.text('phones'),
        rows: [
          PanelRow(
            id: 'server',
            title: T.text('phoneServer'),
            detail: T.text('phoneServerDetail'),
            kind: ToggleRow(preferences.phoneServer, (value) {
              preferences.phoneServer = value;
              savePreferences();
              unawaited(value ? startPhoneServer() : stopPhoneServer());
            }),
          ),
          if (remote?.port case final int port)
            PanelRow(
              id: 'address',
              title: T.text('phoneAddress'),
              kind: InfoRow('${services.computerName ?? Platform.localHostname} · $port'),
            ),
          for (final device in remote?.devices.all ?? const <PairedDevice>[])
            PanelRow(
              id: 'device-${device.id}',
              title: device.name,
              detail: T.text('phoneRemove'),
              kind: ActionRow(() {
                remote?.devices.remove(device.id);
                _changed();
              }, destructive: true),
            ),
        ],
      ),
      PanelCategory(
        id: 'general',
        title: T.text('language'),
        rows: [
          PanelRow(
            id: 'language',
            title: T.text('language'),
            kind: ChoiceRow([for (final language in Language.values) language.displayName], T.language.index, (index) {
              T.language = Language.values[index];
              preferences.language = T.language.code;
              savePreferences();
            }),
          ),
          PanelRow(id: 'profile', title: T.text('profileName'), kind: InfoRow(preferences.profileName)),
        ],
      ),
      PanelCategory(
        id: 'about',
        title: T.text('about'),
        rows: [
          PanelRow(id: 'about', title: 'AnyPS5', kind: InfoRow(T.text('aboutText'))),
          PanelRow(id: 'toolkitVersion', title: T.text('toolkitVersion'), kind: InfoRow(kit?.version ?? '—')),
        ],
      ),
    ];
  }

  List<PanelRow> _gameRows(Game game) {
    final settings = currentSettings(game);
    void change(GameSettings next) => saveSettings(game, next);
    final installed = records.containsKey(game.id);
    final patch = toolkit?.patchFile(game.titleId);
    final supportsResolution = patch != null && ResolutionPatch.supports(File(patch).readAsStringSync());
    final languages = ConsoleLanguage.all;
    final languageIndex = settings.language == null
        ? 0
        : languages.indexWhere((entry) => entry.$1 == settings.language) + 1;
    return [
      PanelRow(
        id: 'display',
        title: T.text('display'),
        kind: ChoiceRow([T.text('windowed'), T.text('fullscreen')], settings.fullscreen ? 1 : 0, (index) {
          change(settings.copyWith(fullscreen: index == 1));
        }),
      ),
      if (!settings.fullscreen)
        PanelRow(
          id: 'windowSize',
          title: T.text('windowSize'),
          kind: StepperRow(
            value: settings.windowSize,
            min: 30,
            max: 100,
            step: 5,
            format: (value) => '$value%',
            set: (value) => change(settings.copyWith(windowSize: value)),
          ),
        ),
      if (supportsResolution)
        PanelRow(
          id: 'resolution',
          title: T.text('resolution'),
          detail: T.text('resolutionReinstall'),
          kind: ChoiceRow(
            [T.text('resolutionDefault'), ...ResolutionPatch.choices],
            settings.resolution == null ? 0 : ResolutionPatch.choices.indexOf(settings.resolution!) + 1,
            (index) => change(settings.copyWith(resolution: index == 0 ? null : ResolutionPatch.choices[index - 1])),
          ),
        ),
      PanelRow(
        id: 'vsync',
        title: T.text('vsync'),
        kind: ToggleRow(settings.vsync, (value) => change(settings.copyWith(vsync: value))),
      ),
      PanelRow(
        id: 'overlay',
        title: T.text('overlay'),
        kind: ChoiceRow(
          [
            T.text('overlayOff'),
            T.text('overlayTopLeft'),
            T.text('overlayTopRight'),
            T.text('overlayBottomLeft'),
            T.text('overlayBottomRight'),
          ],
          settings.overlay.index,
          (index) => change(settings.copyWith(overlay: OverlayCorner.values[index])),
        ),
      ),
      if (settings.overlay != OverlayCorner.off)
        PanelRow(
          id: 'overlayStyle',
          title: T.text('overlayStyle'),
          kind: ChoiceRow(
            [T.text('overlayMinimal'), T.text('overlayDetailed')],
            settings.style.index,
            (index) => change(settings.copyWith(overlayStyle: OverlayStyle.values[index])),
          ),
        ),
      PanelRow(
        id: 'language',
        title: T.text('gameLanguage'),
        kind: ChoiceRow(
          [T.text('followLauncher'), for (final entry in languages) entry.$2],
          languageIndex,
          (index) => change(settings.copyWith(language: index == 0 ? null : languages[index - 1].$1)),
        ),
      ),
      PanelRow(
        id: 'controls',
        title: T.text('controls'),
        detail: T.text('controlsHint'),
        kind: ActionRow(() => open(Layer.controls)),
      ),
      PanelRow(
        id: 'shaderCache',
        title: T.text('shaderCache'),
        detail: T.text('shaderCacheDetail'),
        kind: ToggleRow(
          settings.shaderCache ?? true,
          (value) => change(settings.copyWith(shaderCache: value ? null : false)),
        ),
      ),
      if (installed) ...[
        PanelRow(
          id: 'reinstall',
          title: T.text('reinstall'),
          kind: ActionRow(() {
            closeOverlay();
            unlock(game);
          }),
        ),
        PanelRow(id: 'log', title: T.text('openLog'), kind: ActionRow(() => open(Layer.log))),
        PanelRow(
          id: 'folder',
          title: T.text('showInFinder'),
          kind: ActionRow(() => services.openFolder?.call(Installer.installedFolder(game, root!))),
        ),
        PanelRow(id: 'cache', title: T.text('clearShaderCache'), kind: ActionRow(() => clearShaderCache(game))),
        PanelRow(
          id: 'backup',
          title: T.text('backUpSaves'),
          detail: _lastBackupText(game) ?? T.text('backUpSavesDetail'),
          kind: ActionRow(() => backUpSaves(game)),
        ),
        if (SaveBackup.backups(backupFolder(game)).isNotEmpty)
          PanelRow(
            id: 'restore',
            title: T.text('restoreLatest'),
            detail: T.text('restoreSavesDetail'),
            kind: ActionRow(() => restoreLatestSaves(game)),
          ),
        PanelRow(
          id: 'uninstall',
          title: T.text('uninstall'),
          kind: ActionRow(() => open(Layer.confirmUninstall), destructive: true),
        ),
      ] else
        PanelRow(id: 'log', title: T.text('openLog'), kind: ActionRow(() => open(Layer.log))),
    ];
  }

  List<PanelRow> _controlRows(Game game) {
    final settings = currentSettings(game);
    final changes = settings.controls ?? const <String, List<String>>{};
    return [
      for (final action in PadAction.values)
        PanelRow(
          id: action.key,
          title: padActionTitle(action),
          glyph: switch (action) {
            PadAction.cross => PadGlyph.cross,
            PadAction.circle => PadGlyph.circle,
            PadAction.square => PadGlyph.square,
            PadAction.triangle => PadGlyph.triangle,
            _ => null,
          },
          kind: KeysRow(
            Controls.sources(action, changes),
            capturing: capturing == action,
            capture: () {
              capturing = action;
              _changed();
            },
          ),
        ),
      PanelRow(
        id: 'reset',
        title: T.text('resetControls'),
        kind: ActionRow(() => saveSettings(game, settings.copyWith(controls: null)), destructive: true),
      ),
    ];
  }

  /// A key pressed while a pad action waits for one (a USB HID usage, see Controls.keyName).
  bool captureKey(int usage) {
    final action = capturing;
    final game = selectedGame;
    if (action == null || game == null) return false;
    final name = Controls.keyName(usage);
    if (name == null) return true;
    final settings = currentSettings(game);
    capturing = null;
    saveSettings(
      game,
      settings.copyWith(controls: Controls.assign('KEY:$name', action, settings.controls ?? const {})),
    );
    return true;
  }

  static String padActionTitle(PadAction action) {
    final turkish = T.language == Language.turkish;
    String direction(String key) => T.text(key);
    return switch (action) {
      PadAction.cross => 'Cross',
      PadAction.circle => 'Circle',
      PadAction.square => 'Square',
      PadAction.triangle => 'Triangle',
      PadAction.options => 'Options',
      PadAction.touchLeft => T.text('touchpadLeft'),
      PadAction.touchRight => T.text('touchpadRight'),
      PadAction.up => '${T.text('dpad')} · ${direction('directionUp')}',
      PadAction.down => '${T.text('dpad')} · ${direction('directionDown')}',
      PadAction.left => '${T.text('dpad')} · ${direction('directionLeft')}',
      PadAction.right => '${T.text('dpad')} · ${direction('directionRight')}',
      PadAction.leftStickUp => '${T.text('leftStick')} · ${direction('directionUp')}',
      PadAction.leftStickDown => '${T.text('leftStick')} · ${direction('directionDown')}',
      PadAction.leftStickLeft => '${T.text('leftStick')} · ${direction('directionLeft')}',
      PadAction.leftStickRight => '${T.text('leftStick')} · ${direction('directionRight')}',
      PadAction.rightStickUp => '${T.text('rightStick')} · ${direction('directionUp')}',
      PadAction.rightStickDown => '${T.text('rightStick')} · ${direction('directionDown')}',
      PadAction.rightStickLeft => '${T.text('rightStick')} · ${direction('directionLeft')}',
      PadAction.rightStickRight => '${T.text('rightStick')} · ${direction('directionRight')}',
      PadAction.stickModifier => turkish ? 'Yavaş yürüme' : T.text('stickModifier'),
      _ => action.key,
    };
  }

  List<PanelRow> get _currentRows {
    final categories = panelCategories();
    if (categories.isEmpty) return const [];
    return categories[panelCategory.clamp(0, categories.length - 1)].rows;
  }

  void _skipToFocusable() {
    final rows = _currentRows;
    while (panelRow < rows.length && !rows[panelRow].focusable) {
      panelRow++;
    }
    if (panelRow >= rows.length) panelRow = 0;
  }

  void _panelCommand(Command command) {
    final categories = panelCategories();
    final rows = _currentRows;
    int nextFocusable(int from, int delta) {
      var index = from + delta;
      while (index >= 0 && index < rows.length && !rows[index].focusable) {
        index += delta;
      }
      return index >= 0 && index < rows.length ? index : from;
    }

    final row = panelRow < rows.length ? rows[panelRow] : null;
    switch (command) {
      case Command.up:
        panelRow = nextFocusable(panelRow, -1);
        _changed();
      case Command.down:
        panelRow = nextFocusable(panelRow, 1);
        _changed();
      case Command.left || Command.right:
        final delta = command == Command.right ? 1 : -1;
        switch (row?.kind) {
          case ChoiceRow(:final options, selected: final current, :final set):
            set((current + delta) % options.length);
          case StepperRow(:final value, :final min, :final max, :final step, :final set):
            set((value + delta * step).clamp(min, max));
          case ToggleRow(:final value, :final set):
            set(!value);
          default:
            if (overlay == Layer.settings && categories.length > 1) {
              panelCategory = (panelCategory + delta).clamp(0, categories.length - 1);
              panelRow = 0;
              _skipToFocusable();
              _changed();
            }
        }
      case Command.select:
        switch (row?.kind) {
          case ChoiceRow(:final options, selected: final current, :final set):
            set((current + 1) % options.length);
          case ToggleRow(:final value, :final set):
            set(!value);
          case ActionRow(:final run):
            run();
          case KeysRow(:final capture):
            capture();
          default:
            break;
        }
      case Command.back || Command.options:
        closeOverlay();
      default:
        break;
    }
  }

  void selectCategory(int index) {
    panelCategory = index;
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  /// The onboarding's theme cards preview on a click.
  void previewTheme(int index) {
    onboardingChoice = index;
    preferences.theme = index;
    _changed();
  }

  /// The settings' category tabs move with Q and E as well.
  void moveCategory(int delta) {
    final categories = panelCategories();
    if (categories.length < 2) return;
    panelCategory = (panelCategory + delta).clamp(0, categories.length - 1);
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  // Onboarding: language, theme, games folder, toolkit.

  static const onboardingSteps = 4;
  int onboardingStep = 0;
  final Map<int, int> _onboardingChoices = {};

  int get onboardingChoice => _onboardingChoices[onboardingStep] ?? _defaultChoice(onboardingStep);
  set onboardingChoice(int value) => _onboardingChoices[onboardingStep] = value;

  int _defaultChoice(int step) => switch (step) {
    0 => T.language.index,
    1 => preferences.theme,
    2 => preferences.gamesFolder == null ? 0 : 1,
    _ => toolkit == null ? 0 : 1,
  };

  int get _onboardingCount => switch (onboardingStep) {
    0 => Language.values.length,
    1 => LookStyle.values.length,
    2 => preferences.gamesFolder == null ? 1 : 2,
    _ => 2,
  };

  void _onboardingCommand(Command command) {
    switch (command) {
      case Command.left:
        if (onboardingChoice > 0) {
          onboardingChoice = onboardingChoice - 1;
          _previewChoice();
        }
      case Command.right:
        if (onboardingChoice < _onboardingCount - 1) {
          onboardingChoice = onboardingChoice + 1;
          _previewChoice();
        }
      case Command.select:
        onboardingConfirm();
      case Command.back:
        onboardingBack();
      default:
        break;
    }
    notifyListeners();
  }

  /// The language and theme steps show their choice at once.
  void _previewChoice() {
    if (onboardingStep == 0) {
      T.language = Language.values[onboardingChoice];
      preferences.language = T.language.code;
    }
    if (onboardingStep == 1) preferences.theme = onboardingChoice;
  }

  void onboardingConfirm() {
    switch (onboardingStep) {
      case 0 || 1:
        _previewChoice();
        onboardingStep++;
      case 2:
        if (onboardingChoice == 1 && preferences.gamesFolder != null) {
          onboardingStep++;
        } else {
          unawaited(
            chooseGamesFolder().then((_) {
              if (preferences.gamesFolder != null) onboardingChoice = 1;
              notifyListeners();
            }),
          );
        }
      default:
        if (onboardingChoice == 1) {
          finishOnboarding();
        } else {
          unawaited(
            chooseToolkit().then((_) {
              if (toolkit != null) onboardingChoice = 1;
              notifyListeners();
            }),
          );
        }
    }
    notifyListeners();
  }

  void onboardingBack() {
    if (onboardingStep == 0) return;
    onboardingStep--;
    notifyListeners();
  }

  void finishOnboarding() {
    preferences.onboarded = true;
    focus = HomeFocus.tiles;
    savePreferences();
    rescan();
  }

  // Phone.

  Future<void> startPhoneServer() async {
    if (remote != null || !preferences.phoneServer) return;
    final name = services.computerName ?? Platform.localHostname;
    try {
      final events = RemoteEvents(
        pairing: (request) {
          pairing = request;
          _changed();
        },
        connecting: (device) {
          phoneConnecting = device;
          if (device == null) pairing = null;
          _changed();
        },
        connected: (device) {
          phoneConnecting = null;
          pairing = null;
          show(T.format('phoneConnected', [device]));
          _toldLibrary = null;
          _changed();
          _publishLook();
        },
        disconnected: _changed,
        latency: (milliseconds) {
          phoneLatency = milliseconds;
          notifyListeners();
        },
        request: _phoneRequest,
      );
      final devices = PairedDevices(paths.pairedDevicesFile);
      final RemoteServer server;
      if (services.preferredPorts) {
        server = await RemoteServer.startPreferred(name: name, devices: devices, events: events);
      } else {
        server = RemoteServer(name: name, devices: devices, events: events);
        await server.start();
      }
      remote = server;
      remoteError = null;
      if (services.cable) {
        final adb = await AdbTunnel.locate();
        if (adb != null) _adb = AdbTunnel(adb: adb, targetPort: server.port!)..start();
      }
      if (!services.advertise) {
        _changed();
        return;
      }
      final advertiser = await AvahiAdvertiser.available()
          ? AvahiAdvertiser(instance: name, serviceType: RemoteServer.serviceType, port: server.port!)
          : MdnsResponder(instance: name, serviceType: RemoteServer.serviceType, port: server.port!);
      try {
        await advertiser.start();
        _advertiser = advertiser;
      } on Object {
        // Without advertising the phone still connects by address.
      }
    } on Object catch (error) {
      remoteError = error.toString();
    }
    _changed();
  }

  Future<void> stopPhoneServer() async {
    await _adb?.stop();
    _adb = null;
    await _advertiser?.stop();
    _advertiser = null;
    await remote?.stop();
    remote = null;
    pairing = null;
    phoneConnecting = null;
    _changed();
  }

  void answerPairing(bool allow) {
    final request = pairing;
    if (request == null) return;
    remote?.respond(request.id, allow: allow);
    pairing = null;
    _changed();
  }

  void _phoneRequest(RemoteMessage message, String deviceId) {
    switch (message) {
      case RemoteSelect(:final id):
        final index = games.indexWhere((game) => game.id == id);
        if (index >= 0) select(index);
      case RemoteLaunch(:final id):
        final game = games.where((game) => game.id == id).firstOrNull;
        if (game == null) return;
        select(games.indexOf(game));
        if (running != null && running!.$1 != game) stopGame();
        primaryAction(game);
      case RemoteClose():
        stopGame();
      case RemoteHome():
        handle(Command.home);
      case RemoteCommand(:final name):
        final command = switch (name) {
          'left' => Command.left,
          'right' => Command.right,
          'up' => Command.up,
          'down' => Command.down,
          'select' => Command.select,
          'back' => Command.back,
          'options' => Command.options,
          'l1' => Command.previousGame,
          'r1' => Command.nextGame,
          _ => null,
        };
        if (command != null) handle(command);
      case RemoteWantArt(:final id):
        final game = games.where((game) => game.id == id).firstOrNull;
        if (game == null) return;
        String? encode(String? file) {
          if (file == null) return null;
          try {
            return base64.encode(File(file).readAsBytesSync());
          } on FileSystemException {
            return null;
          }
        }
        remote?.tell(RemoteArt(id: id, icon: encode(game.icon), background: encode(game.background)), deviceId);
      case RemoteSaveLayout(:final id, :final layout):
        final game = games.where((game) => game.id == id).firstOrNull;
        if (game != null) saveSettings(game, currentSettings(game).copyWith(phoneLayout: layout));
      default:
        break;
    }
  }

  void _publishLibrary() {
    final server = remote;
    if (server == null || server.connectedDevices.isEmpty) return;
    final library = RemoteLibrary(
      games: [
        for (final game in games)
          RemoteGame(
            id: game.id,
            name: game.name,
            state: switch (stateOf(game)) {
              Installed(:final outdated) => outdated ? RemoteGameState.update : RemoteGameState.installed,
              Locked() || Failed() => RemoteGameState.locked,
              Queued() || Installing() => RemoteGameState.installing,
              Starting() => RemoteGameState.starting,
              Running() => RemoteGameState.running,
              Unreadable() => RemoteGameState.unavailable,
            },
            trophies: switch (trophies[game.id]) {
              final TrophySet set => '${set.unlockedCount}/${set.trophies.length}',
              null => null,
            },
            art:
                '${game.icon != null ? _stamp(game.icon!) : 0}-${game.background != null ? _stamp(game.background!) : 0}',
            layout: currentSettings(game).phoneLayout,
          ),
      ],
      selected: selectedGame?.id,
      running: running?.$1.id,
      language: T.language.code,
    );
    if (library == _toldLibrary) return;
    _toldLibrary = library;
    server.publish(library);
  }

  RemoteActivity? _toldActivity;

  void _publishActivity() {
    final server = remote;
    if (server == null) return;
    RemoteActivity? now;
    for (final entry in progress.entries) {
      final (step, fraction) = entry.value;
      now = RemoteActivity(
        id: entry.key,
        phase: switch (step) {
          InstallStep.unwrap => RemotePhase.unwrap,
          InstallStep.relink => RemotePhase.relink,
          InstallStep.copy => RemotePhase.copy,
          InstallStep.layout => RemotePhase.bundle,
          InstallStep.finish => RemotePhase.finish,
        },
        updating: records.containsKey(entry.key),
        fraction: InstallSpan.overall(step, fraction),
        elapsed: 0,
      );
    }
    if (RemoteActivity.same(_toldActivity, now)) return;
    _toldActivity = now;
    server.publish(RemoteActivityUpdate(now));
  }

  void _publishLook() {
    remote?.publish(
      RemoteLook(
        deep: LookStyle.hex(look.deep),
        middle: LookStyle.hex(look.middle),
        accent: LookStyle.hex(accentChoice.color),
      ),
    );
  }

  static int _stamp(String file) {
    try {
      return File(file).lastModifiedSync().millisecondsSinceEpoch;
    } on FileSystemException {
      return 0;
    }
  }

  bool _disposed = false;

  /// Work that ends after the launcher closed (an install, a game, the phone server stopping)
  /// tells no one.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_watch?.cancel());
    _rescanSoon?.cancel();
    _trophyWatch?.cancel();
    _toastTimer?.cancel();
    _installer?.cancel();
    unawaited(stopPhoneServer());
    super.dispose();
  }
}
