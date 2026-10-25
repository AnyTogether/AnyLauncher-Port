import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/audio/atrac9.dart';
import '../core/audio/audio_out.dart';
import '../core/audio/interface_sounds.dart';
import '../core/audio/theme_music.dart';
import '../core/audio/tones.dart';
import '../core/controls.dart';
import '../core/desktop/desktop.dart';
import '../core/font_download.dart';
import '../core/family/family_rules.dart' show TitleVerdict;
import '../core/gamepad/pad_navigation.dart';
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
import '../core/screenshots.dart';
import '../core/toolkit.dart';
import '../core/toolkit_download.dart';
import '../core/together/talk_key.dart';
import '../core/together/token_store.dart';
import '../core/together/voice_mesh.dart';
import '../core/trophies.dart';
import 'components.dart';
import 'engine_model.dart';
import 'fonts_model.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';
import 'update_model.dart';
import 'trophy_card.dart';

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
    ..togetherServer = json['togetherServer'] as String?
    ..friendsJoin = json['friendsJoin'] as bool? ?? true
    ..pushToTalk = json['pushToTalk'] as bool? ?? false
    ..talkKey = (json['talkKey'] as num?)?.toInt()
    ..sounds = json['sounds'] as bool? ?? true
    ..soundVolume = (json['soundVolume'] as num?)?.toInt()
    ..musicVolume = (json['musicVolume'] as num?)?.toInt()
    ..engineSource = json['engineSource'] as String? ?? 'upstream'
    ..fontsFolder = json['fontsFolder'] as String?
    ..showHiddenTrophies = json['showHiddenTrophies'] as bool? ?? false
    ..cjkGames = {
      for (final id in json['cjkGames'] as List<dynamic>? ?? const <dynamic>[])
        if (id is String) id,
    }
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

  /// Another AnyTogether server than AnyTogether's own; null for that one.
  String? togetherServer;

  /// While a game runs, friends see it and can join (an AnyTogether game session).
  bool friendsJoin = true;

  /// In party voice: the talk key held to talk (else it turns the microphone on and off), and
  /// which key it is (a USB HID usage; null for the default).
  bool pushToTalk = false;
  int? talkKey;

  /// Interface sounds, and their volume and the selected game's theme song's in percent; null
  /// keeps the default.
  bool sounds = true;
  int? soundVolume;
  int? musicVolume;
  Map<String, String> lastPlayed = {};

  /// Which engine the settings offer: 'upstream' (boykopovar/AnyPS5) or 'arm' (AnyPS5-ARM's,
  /// with the phone controller, full screen and window size).
  String engineSource = 'upstream';

  /// A folder of the user's own fonts (the console's, say) games get first; null for none.
  String? fontsFolder;

  /// Hidden trophies show their name, description and icon before they are earned.
  bool showHiddenTrophies = false;

  /// The title IDs of games seen asking for Japanese, Chinese or Korean fonts: their next start
  /// waits for those to download.
  Set<String> cjkGames = {};

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
    'togetherServer': togetherServer,
    'friendsJoin': friendsJoin,
    'pushToTalk': pushToTalk,
    'talkKey': talkKey,
    'sounds': sounds,
    'soundVolume': soundVolume,
    'musicVolume': musicVolume,
    'lastPlayed': lastPlayed,
    'engineSource': engineSource,
    'fontsFolder': fontsFolder,
    'showHiddenTrophies': showHiddenTrophies,
    'cjkGames': cjkGames.toList()..sort(),
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

/// A parent's family settings keep the game from the child: too old a rating, or none known.
class FamilyLocked extends GameState {
  const FamilyLocked(this.verdict);
  final TitleVerdict verdict;
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

enum Layer {
  library,
  settings,
  gameSettings,
  controls,
  confirmUninstall,
  updateChoice,
  log,
  trophies,

  /// The selected game's pictures: F12 screenshots and the ones taken when trophies were earned.
  gallery,

  /// AnyTogether: friends and requests, what can be done with one friend, the messages, the
  /// party and its voice.
  friends,
  friendOptions,
  messages,
  party,
  profile,

  /// Family limits: today's play time, asking a parent for more.
  family,
}

/// A settings row the panels draw and the keyboard moves through.
class PanelRow {
  const PanelRow({required this.id, required this.title, required this.kind, this.detail, this.glyph, this.person});

  final String id;
  final String title;
  final String? detail;

  /// A face button drawn after the title.
  final PadGlyph? glyph;
  final RowKind kind;

  /// Someone on AnyTogether the row is about, drawn as their picture before the title.
  final PanelPerson? person;

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

/// A field to type in: choosing the row puts the cursor in it; Enter sends [submit].
class TextRow extends RowKind {
  const TextRow(this.value, this.set, {this.submit, this.hint});
  final String value;
  final void Function(String) set;
  final void Function()? submit;
  final String? hint;
}

/// How a person shows in a row: their initials or picture, a dot for what they are doing, a
/// ring while they speak in party voice.
class PanelPerson {
  const PanelPerson({required this.name, this.avatar, this.status, this.speaking = false});
  final String name;
  final String? avatar;
  final PersonStatus? status;
  final bool speaking;

  /// One or two letters for a person with no picture.
  String get initials {
    final words = name.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).take(2);
    final letters = words.map((word) => String.fromCharCode(word.runes.first).toUpperCase()).join();
    return letters.isEmpty ? '?' : letters;
  }
}

enum PersonStatus { playing, online, away, offline }

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
    this.openUrl,
    this.copyText,
    this.environment,
    this.togetherStore,
    this.togetherServer,
    this.togetherPollEvery,
    this.voiceEngine,
    this.talkKeys,
    this.engineReleases,
    this.launcherReleases,
    this.hostGlibc,
    this.audio,
    this.decodeSong,
    this.armEngineReleases,
    this.pads,
    this.desktop,
    this.renderTrophyCard,
    this.cjkFonts,
    this.fontClient,
    this.builtInFonts,
  });

  /// The Japanese, Chinese and Korean fonts downloaded when a game needs them (Noto Sans CJK
  /// from GitHub); none in tests without a fake, which then download nothing.
  final FontArchive? cjkFonts;

  /// The HTTP client that downloads them; dart:io's by default.
  final HttpClient Function()? fontClient;

  /// The folder of the fonts that come with the launcher; found beside the executable (its
  /// Flutter assets) when not given.
  final String? builtInFonts;

  /// Where AnyPS5-ARM's engine is read from (its signed GitHub releases); none in tests without
  /// a fake.
  final GitHubReleases? armEngineReleases;

  /// Where controller input comes from (XInput and winmm on Windows, evdev on Linux); none when
  /// not given.
  final PadSource Function()? pads;

  /// The game's window, its picture and the trophy card over it; nothing when not given.
  final DesktopWindows? desktop;

  /// Draws the trophy card for the desktop's window; TrophyCard.render by default.
  final Future<RgbaImage> Function(Trophy trophy, double scale)? renderTrophyCard;

  /// The sound card for the interface sounds and theme songs; none (silence) when not given.
  final AudioOut Function()? audio;

  /// Reads a game's theme song; LibAtrac9 away from the interface by default.
  final Future<PlayableSong?> Function(String path)? decodeSong;

  /// This system's glibc version, checked against what a Linux engine needs; the system's own
  /// by default (null: unknown, nothing is said).
  final String? Function()? hostGlibc;

  /// Where the AnyPS5 engine's releases are read from (GitHub); none in tests without a fake.
  final GitHubReleases? engineReleases;

  /// Where AnyPS5 Desktop's own releases are read from (GitHub, signed); none in tests without a
  /// fake.
  final GitHubReleases? launcherReleases;

  /// Party voice's microphone and connections; flutter_webrtc by default.
  final VoiceEngine Function()? voiceEngine;

  /// Reads the talk key anywhere on the desktop; the system's reader by default, none in tests.
  final KeyStateReader? Function()? talkKeys;

  /// Opens a web page in the browser.
  final void Function(Uri url)? openUrl;

  /// Puts a text on the clipboard.
  final void Function(String text)? copyText;

  /// The environment the launcher reads (ANYTOGETHER_URL); the process's by default.
  final Map<String, String>? environment;

  /// Where the AnyTogether session is kept; the system's own store by default.
  final TokenStore? togetherStore;

  /// An AnyTogether server that wins over every choice (tests).
  final Uri? togetherServer;

  /// How often an AnyTogether sign-in asks whether it was approved (tests go faster).
  final Duration? togetherPollEvery;

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
    together = TogetherModel(this);
    _applySound();
  }

  late final AudioOut _audio = services.audio?.call() ?? const SilentAudio();

  /// The interface's soft sounds (moving, selecting, going back, something finished).
  late final InterfaceSounds sounds = InterfaceSounds(_audio);

  /// The selected game's theme song.
  late final ThemeMusic music = ThemeMusic(_audio, decode: services.decodeSong);

  /// Whether the launcher's window is in front: the theme song plays only then.
  bool active = true;

  /// Opens the sound card and makes the interface sounds.
  Future<void> startAudio() => sounds.start();

  static const defaultMusicVolume = 50;

  int get musicVolume => preferences.musicVolume ?? defaultMusicVolume;

  void _applySound() {
    sounds
      ..enabled = preferences.sounds
      ..volume = (preferences.soundVolume ?? 100) / 100;
    music.volume = musicVolume / 100;
  }

  void setActive(bool value) {
    if (active == value) return;
    active = value;
    // Back in front: a toolkit rebuilt meanwhile is read again.
    if (value) _forgetDiskFacts();
    notifyListeners();
  }

  /// The selected game's song while the launcher is in front and idle, silence otherwise (the
  /// first start, a game starting or playing, the volume at 0); the interface sounds are quiet
  /// while a game is in front.
  void _updateMusic() {
    final quiet = !preferences.onboarded || !active || running != null || starting != null || musicVolume == 0;
    music.play(quiet ? null : selectedGame);
    // With the game in front, the launcher says nothing.
    sounds.muted = running != null && !active;
  }

  /// AnyTogether: the account, friends, messages, parties.
  late final TogetherModel together;

  DesktopWindows get desktop => services.desktop ?? const NoDesktop();

  PadSource? _pads;
  PadNavigator? _navigator;

  /// Reads the controllers: their moves become the same commands as the keys.
  void startPads() {
    if (_pads != null) return;
    final source = services.pads?.call();
    if (source == null) return;
    final navigator = PadNavigator(padCommand);
    _navigator = navigator;
    _pads = source..start(navigator.handle);
  }

  /// A controller command. With the launcher behind a game (or another window) only PS/Guide
  /// counts: it brings the launcher in front, as on the Mac.
  void padCommand(PadCommand command) {
    final mapped = switch (command) {
      PadCommand.left => Command.left,
      PadCommand.right => Command.right,
      PadCommand.up => Command.up,
      PadCommand.down => Command.down,
      PadCommand.select => Command.select,
      PadCommand.back => Command.back,
      PadCommand.options => Command.options,
      PadCommand.previousGame => Command.previousGame,
      PadCommand.nextGame => Command.nextGame,
      PadCommand.home => Command.home,
    };
    if (!active && mapped != Command.home) return;
    if (editingRow != null) return;
    if (capturing != null && mapped != Command.back) return;
    if (overlay == Layer.settings && (mapped == Command.previousGame || mapped == Command.nextGame)) {
      return moveCategory(mapped == Command.nextGame ? 1 : -1);
    }
    handle(mapped);
  }

  /// The AnyPS5 engine downloaded from upstream: versions, the download, the one in use.
  late final EngineModel engine = EngineModel(this);
  late final LauncherUpdateModel updates = LauncherUpdateModel(this);

  /// The system fonts games get: the folder put together for them, the CJK download.
  late final FontsModel fonts = FontsModel(this);

  /// The text row the cursor is in, by id; null while the keys move through the launcher.
  String? editingRow;

  void startEditing(String id) {
    editingRow = id;
    notifyListeners();
  }

  void stopEditing() {
    if (editingRow == null) return;
    editingRow = null;
    notifyListeners();
  }

  /// Something outside the model changed what the screen shows.
  void refresh() => _changed();

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

  /// The selected game's pictures while the gallery is open, newest first; the one the focus is
  /// on and whether it is shown over the whole screen.
  List<String> galleryShots = const [];
  int galleryIndex = 0;
  bool galleryViewing = false;
  Layer? _galleryFrom;

  /// The picture taken when each trophy of the selected game was earned, by trophy id.
  Map<String, String> trophyShots = const {};

  static const galleryColumns = 4;

  List<String> screenshotsOf(Game game) => Screenshots.list(paths.pictures, game);

  void _loadShots() {
    final game = selectedGame;
    galleryShots = game == null ? const [] : screenshotsOf(game);
    trophyShots = Screenshots.trophyShots(galleryShots);
  }

  /// Opens the gallery of the selected game, coming back to [from] (or home) after.
  void openGallery({String? shot}) {
    _galleryFrom = overlay;
    open(Layer.gallery);
    final index = shot == null ? -1 : galleryShots.indexOf(shot);
    if (index >= 0) {
      galleryIndex = index;
      galleryViewing = true;
      _changed();
    }
  }

  void _galleryCommand(Command command) {
    final count = galleryShots.length;
    void move(int delta) {
      final next = (galleryIndex + delta).clamp(0, count == 0 ? 0 : count - 1);
      if (next == galleryIndex) return;
      galleryIndex = next;
      sounds.play(Cue.move);
      _changed();
    }

    switch (command) {
      case Command.left:
        move(-1);
      case Command.right:
        move(1);
      case Command.up:
        if (!galleryViewing) move(-galleryColumns);
      case Command.down:
        if (!galleryViewing) move(galleryColumns);
      case Command.select:
        if (count == 0) return;
        galleryViewing = !galleryViewing;
        sounds.play(galleryViewing ? Cue.select : Cue.back);
        _changed();
      case Command.back || Command.options:
        if (galleryViewing) {
          galleryViewing = false;
          sounds.play(Cue.back);
          _changed();
        } else if (_galleryFrom case final Layer from) {
          final trophy = trophyIndex;
          final revealed = revealedTrophies;
          open(from, cue: Cue.back);
          if (from == Layer.trophies) {
            trophyIndex = trophy;
            revealedTrophies = revealed;
          }
        } else {
          closeOverlay();
        }
      default:
        break;
    }
  }

  /// A click on a picture in the gallery: shown big; a click on the big one goes back.
  void tapShot(int index) {
    if (index < 0 || index >= galleryShots.length) return;
    galleryIndex = index;
    galleryViewing = true;
    sounds.play(Cue.select);
    _changed();
  }

  /// Each game's trophies, read at the scan; a game without trophy packages has none.
  final Map<String, TrophySet> trophies = {};
  int trophyIndex = 0;

  /// The hidden trophies shown in the list open now (△ on one), by id; forgotten when it closes.
  Set<String> revealedTrophies = {};

  /// Whether [trophy] is hidden from the list until it is earned, and can be shown with △.
  bool canReveal(Trophy trophy) => trophy.hidden && trophy.unlocked == null && !preferences.showHiddenTrophies;

  /// Whether the list shows [trophy] as a hidden trophy: no name, description or icon.
  bool isSecret(Trophy trophy) => canReveal(trophy) && !revealedTrophies.contains(trophy.id);

  /// The trophy the list's focus is on.
  Trophy? get focusedTrophy => trophies[selectedGame?.id]?.trophies.elementAtOrNull(trophyIndex);

  /// Shows a hidden trophy in the list, or hides it again (△, or a click on its Show).
  void toggleReveal(int index) {
    final trophy = trophies[selectedGame?.id]?.trophies.elementAtOrNull(index);
    if (trophy == null || !canReveal(trophy)) return;
    trophyIndex = index;
    final shown = !revealedTrophies.remove(trophy.id);
    if (shown) revealedTrophies = {...revealedTrophies, trophy.id};
    sounds.play(shown ? Cue.select : Cue.back);
    _changed();
  }

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

  /// The chosen toolkit; without one (or when it is gone), the newest downloaded engine.
  ///
  /// Finding it reads the disk (the relinker, every library, version.txt), and the screen asks
  /// for it for every game on every frame it builds: it is looked up again only when the choice,
  /// the downloaded engines or the library change.
  Toolkit? get toolkit {
    final key = (preferences.toolkitFolder, identityHashCode(engine.downloaded), _toolkitEpoch);
    if (key != _toolkitKey) {
      final folder = preferences.toolkitFolder;
      _toolkit = Toolkit.locate([?folder, for (final kit in engine.downloaded) kit.root], system: system);
      _toolkitVersion = _toolkit?.version;
      _toolkitKey = key;
    }
    return _toolkit;
  }

  Toolkit? _toolkit;
  String? _toolkitVersion;
  Object? _toolkitKey;
  int _toolkitEpoch = 0;

  /// The version.txt of [toolkit], read once with it.
  String? get toolkitVersion {
    toolkit;
    return _toolkitVersion;
  }

  /// Facts about a game the settings rows show that cost a disk read (its patch file, its
  /// backups), read when its settings open rather than on every frame.
  final Map<String, ({bool resolution, List<String> backups})> _gameFacts = {};

  ({bool resolution, List<String> backups}) _factsOf(Game game) => _gameFacts.putIfAbsent(game.id, () {
    final patch = toolkit?.patchFile(game.titleId);
    var resolution = false;
    try {
      resolution = patch != null && ResolutionPatch.supports(File(patch).readAsStringSync());
    } on FileSystemException {
      resolution = false;
    }
    return (resolution: resolution, backups: SaveBackup.backups(backupFolder(game)));
  });

  /// The log shown in the log layer, read as it opens.
  String shownLog = '';

  /// Reads the disk again for what the screen keeps (the toolkit, a game's facts).
  void _forgetDiskFacts() {
    _toolkitEpoch++;
    _gameFacts.clear();
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
    _forgetDiskFacts();
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
      together.recordTrophies(game, set);
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
    if (together.family.ageLock(game) case final FamilyLocked lock) return lock;
    final current = progress[game.id];
    if (current != null) return Installing(current.$1, current.$2);
    if (queue.contains(game.id)) return const Queued();
    final failure = failures[game.id];
    if (failure != null) return Failed(failure);
    final record = records[game.id];
    if (record != null) {
      final version = toolkitVersion;
      return Installed(outdated: (version != null && version != record.toolkit) || engine.updateAvailable);
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
      case FamilyLocked():
        unawaited(together.family.askToPlay(game));
    }
  }

  void unlock(Game game) {
    if (root == null) return;
    final kit = toolkit;
    if (kit == null) return show(T.text('noToolkit'));
    // Unlocked all the same (another glibc may be at hand), but said first.
    if (engine.glibcWarning(kit) case final String warning) show(warning);
    failures.remove(game.id);
    if (!queue.contains(game.id) && !progress.containsKey(game.id)) {
      queue.add(game.id);
      sounds.play(Cue.select);
    }
    _changed();
    _startNext();
  }

  /// Unlocks the game again and plays it; with a newer engine out, downloads that first.
  void updateAndPlay(Game game) {
    _playAfterInstall = game.id;
    if (engine.updateAvailable) {
      unawaited(
        engine.download().then((done) {
          if (done) {
            unlock(game);
          } else if (_playAfterInstall == game.id) {
            _playAfterInstall = null;
          }
        }),
      );
      return;
    }
    unlock(game);
  }

  void cancelUnlock(Game game) {
    if (_playAfterInstall == game.id) _playAfterInstall = null;
    if (queue.remove(game.id)) return _changed();
    if (progress.containsKey(game.id)) _installer?.cancel();
    sounds.play(Cue.back);
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
        sounds.play(Cue.unlocked);
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
    final latest = _factsOf(game).backups.firstOrNull;
    if (latest == null) return null;
    return T.format('lastBackup', [p.basenameWithoutExtension(latest)]);
  }

  void backUpSaves(Game game) {
    final folder = root;
    if (folder == null) return;
    try {
      SaveBackup.backUp(Installer.installedFolder(game, folder), backupFolder(game), DateTime.now());
      _gameFacts.remove(game.id);
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
      _gameFacts.remove(game.id);
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
    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) || starting != null || running != null) return;
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
    sounds.play(Cue.select);
    starting = game;
    preferences.lastPlayed[game.id] = DateTime.now().toIso8601String();
    savePreferences();
    final logFile = paths.logFile(game.titleId);
    try {
      // A game in Japanese, Korean or Chinese waits for those fonts; every game gets the folder
      // the fonts are put together in.
      final systemFonts = await fonts.prepare(game, settings.language ?? T.language.consoleLanguage);
      final environment = {
        ...settings.environment(
          launcherLanguage: T.language.consoleLanguage,
          inputFile: written ? inputFile : null,
          screenshots: paths.pictures,
          fonts: systemFonts,
          shaderCacheFolder: paths.shaderCache(game.slug),
        ),
        ...?remote?.bridgeEnvironment,
        // The engine's online bridge reads the AnyTogether game session there.
        if (together.signedIn) 'ANYPS5_TOGETHER_SESSION': together.hub.games.bridgeFile,
      };
      fonts.watch(game, logFile);
      final run = await GameProcess.start(
        installed: Installer.installedFolder(game, folder),
        environment: environment,
        logFile: logFile,
        system: system,
      );
      starting = null;
      running = (game, run);
      _stopped = false;
      final began = DateTime.now();
      // Upstream's engine does not read ANYPS5_FULLSCREEN or ANYPS5_WINDOW_SIZE: the launcher
      // sizes its window or presses its F11 once the window is open.
      if (!engine.readsDisplaySettings) {
        unawaited(desktop.applyDisplay(run.pid, fullscreen: settings.fullscreen, windowSize: settings.windowSize));
      }
      _watchTrophies(game);
      together.gameChanged();
      _changed();
      final code = await run.exitCode;
      fonts.ended();
      together.recordPlay(game, began, DateTime.now(), exit: _stopped ? 'killed' : (code == 0 ? 'normal' : 'crashed'));
      _trophyWatch?.cancel();
      _loadTrophies(game);
      if (running?.$1 == game) running = null;
      together.gameChanged();
      if (code != 0) show('${T.text('gameEnded')} ($code)');
      _changed();
    } on Object catch (error) {
      starting = null;
      fonts.ended();
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
      // Heard over the game too.
      sounds.play(Cue.unlocked, overGame: true);
      for (final id in fresh) {
        final trophy = trophies[game.id]?.trophies.where((trophy) => trophy.id == id).firstOrNull;
        if (trophy == null) continue;
        show('${T.text('trophyEarned')} · ${trophy.name}');
        if (running case (final Game playing, final RunningGame run) when playing == game) {
          unawaited(celebrate(game, trophy, run.pid));
        }
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

  Future<void> _cards = Future.value();

  /// A trophy earned while the game is in front: a picture of the game at that moment (taken
  /// before the card covers any of it) into its pictures folder, then the card over the game,
  /// one after another when several come at once; a notification where no card can be shown.
  Future<void> celebrate(Game game, Trophy trophy, int pid) async {
    final shot = await _trophyShot(game, trophy, pid);
    if (shot != null) {
      trophyShots = {...trophyShots, trophy.id: shot};
      if (overlay == Layer.trophies || overlay == Layer.gallery) _loadShots();
      notifyListeners();
    }
    final previous = _cards;
    final done = Completer<void>();
    _cards = done.future;
    await previous;
    try {
      final scale = desktop.cardScale(pid);
      final card = await (services.renderTrophyCard ?? (trophy, scale) => TrophyCard.render(trophy, scale: scale))(
        trophy,
        scale,
      );
      if (!await desktop.showCard(card, pid: pid)) {
        await desktop.notify(
          T.text('trophyEarned'),
          trophy.name.isEmpty ? T.text('trophyHidden') : trophy.name,
          icon: shot,
        );
      }
    } on Object {
      // The toast in the launcher and the phone still say it.
    } finally {
      done.complete();
    }
  }

  /// Saves the game's window as it is now as the picture of [trophy]; its path, or null.
  Future<String?> _trophyShot(Game game, Trophy trophy, int pid) async {
    try {
      final frame = await desktop.captureGame(pid);
      if (frame == null) return null;
      final path = Screenshots.trophyPath(paths.pictures, game, trophy.id, DateTime.now());
      await Isolate.run(() {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(PngEncoder.rgba(frame.width, frame.height, frame.pixels));
      });
      return path;
    } on Object {
      return null;
    }
  }

  /// Whether the user (or the phone) closed the game playing.
  bool _stopped = false;

  void stopGame() {
    if (running != null) _stopped = true;
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

  /// Opens a layer with the select sound, or [cue] (going back to the panel before).
  void open(Layer next, {Cue cue = Cue.select}) {
    sounds.play(cue);
    overlay = next;
    panelRow = 0;
    panelCategory = 0;
    capturing = null;
    if (next == Layer.library) libraryIndex = selected;
    if (next == Layer.gameSettings) _gameFacts.clear();
    if (next == Layer.log) shownLog = selectedGame == null ? '' : logText(selectedGame!);
    if (next == Layer.trophies) {
      trophyIndex = 0;
      revealedTrophies = {};
    }
    if (next == Layer.trophies || next == Layer.gallery) _loadShots();
    if (next == Layer.gallery) {
      galleryIndex = 0;
      galleryViewing = false;
    }
    _skipToFocusable();
    _changed();
  }

  void closeOverlay() {
    overlay = null;
    capturing = null;
    revealedTrophies = {};
    sounds.play(Cue.back);
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
    sounds.play(Cue.move);
    if (focus.isActions && focus.index >= actionCount) focus = HomeFocus.actions(actionCount - 1);
    if (overlay == Layer.trophies) {
      trophyIndex = 0;
      revealedTrophies = {};
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
      // PS/Guide: from the game to the launcher and back; behind another window, to the front.
      if (running case (_, final RunningGame run)) {
        unawaited(active ? desktop.focusGame(run.pid) : desktop.raiseLauncher());
        return;
      }
      if (!active) {
        unawaited(desktop.raiseLauncher());
        return;
      }
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
      case Layer.gallery:
        _galleryCommand(command);
        return;
      case Layer.trophies:
        final count = trophies[selectedGame?.id]?.trophies.length ?? 0;
        switch (command) {
          case Command.up || Command.down:
            final next = (trophyIndex + (command == Command.down ? 1 : -1)).clamp(0, count == 0 ? 0 : count - 1);
            if (next != trophyIndex) sounds.play(Cue.move);
            trophyIndex = next;
            _changed();
          case Command.select:
            final trophy = trophies[selectedGame?.id]?.trophies.elementAtOrNull(trophyIndex);
            if (trophyShots[trophy?.id] case final String shot) openGallery(shot: shot);
          // △ (Triangle, Y, O) on a hidden trophy shows it, and hides it again.
          case Command.options when focusedTrophy != null && canReveal(focusedTrophy!):
            toggleReveal(trophyIndex);
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
            sounds.play(Cue.back);
            _changed();
          }
          return;
        }
        if (command == Command.back || command == Command.options) {
          open(Layer.gameSettings, cue: Cue.back);
          return;
        }
        _panelCommand(command);
        return;
      case Layer.messages:
        together.messagesCommand(command);
        return;
      case Layer.profile:
        together.profileCommand(command);
        return;
      case Layer.friendOptions when command == Command.back || command == Command.options:
        open(Layer.friends, cue: Cue.back);
        return;
      case Layer.settings ||
          Layer.gameSettings ||
          Layer.confirmUninstall ||
          Layer.updateChoice ||
          Layer.friends ||
          Layer.friendOptions ||
          Layer.party ||
          Layer.family:
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
        _moveFocus(HomeFocus.top((focus.index - 1).clamp(0, topButtons - 1)));
      case ('top', Command.right):
        _moveFocus(HomeFocus.top((focus.index + 1).clamp(0, topButtons - 1)));
      case ('top', Command.down) || ('top', Command.back):
        _moveFocus(HomeFocus.tiles);
      case ('top', Command.select):
        final layer = topLayers[focus.index.clamp(0, topButtons - 1)];
        layer == Layer.messages ? unawaited(together.openMessages()) : open(layer);
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

  /// The top bar's buttons, left to right.
  static const topLayers = [Layer.library, Layer.settings, Layer.friends, Layer.messages, Layer.party];
  static int get topButtons => topLayers.length;

  void _moveLibrary(int delta) {
    final next = (libraryIndex + delta).clamp(0, games.isEmpty ? 0 : games.length - 1);
    if (next == libraryIndex) return;
    libraryIndex = next;
    sounds.play(Cue.move);
    _changed();
  }

  void _moveFocus(HomeFocus next) {
    if (next == focus) return;
    focus = next;
    sounds.play(Cue.move);
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
      case Layer.friends:
        return [PanelCategory(id: 'friends', title: T.text('friendsTitle'), rows: together.friendRows())];
      case Layer.party:
        return [PanelCategory(id: 'party', title: T.text('partyTitle'), rows: together.partyRows())];
      case Layer.family:
        return [PanelCategory(id: 'family', title: T.text('familyTitle'), rows: together.family.rows())];
      case Layer.friendOptions:
        return [
          PanelCategory(
            id: 'friend',
            title: together.chosen?.person.displayName ?? T.text('friendsTitle'),
            rows: together.friendOptionRows(),
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
                detail: switch (engine.latestPackage) {
                  final ToolkitPackage newest when engine.updateAvailable => T.format('engineUpdateAndPlayDetail', [
                    'v${newest.version}',
                    byteText(newest.size),
                  ]),
                  _ => T.text('updateAndPlayDetail'),
                },
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
        ],
      ),
      PanelCategory(id: 'engine', title: T.text('engine'), rows: engine.settingsRows()),
      PanelCategory(id: 'fonts', title: T.text('fonts'), rows: fonts.settingsRows()),
      PanelCategory(id: 'together', title: 'AnyTogether', rows: together.settingsRows()),
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
        title: T.text('behaviour'),
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
          PanelRow(
            id: 'sounds',
            title: T.text('sounds'),
            kind: StepperRow(
              value: preferences.sounds ? preferences.soundVolume ?? 100 : 0,
              min: 0,
              max: 100,
              step: 10,
              format: _percent,
              set: (value) {
                preferences.sounds = value > 0;
                if (value > 0) preferences.soundVolume = value;
                _applySound();
                savePreferences();
              },
            ),
          ),
          PanelRow(
            id: 'music',
            title: T.text('gameMusic'),
            detail: T.text('gameMusicDetail'),
            kind: StepperRow(
              value: musicVolume,
              min: 0,
              max: 100,
              step: 10,
              format: _percent,
              set: (value) {
                preferences.musicVolume = value;
                _applySound();
                savePreferences();
              },
            ),
          ),
          PanelRow(
            id: 'hiddenTrophies',
            title: T.text('showHiddenTrophies'),
            detail: T.text('showHiddenTrophiesDetail'),
            kind: ToggleRow(preferences.showHiddenTrophies, (value) {
              preferences.showHiddenTrophies = value;
              savePreferences();
            }),
          ),
        ],
      ),
      PanelCategory(
        id: 'about',
        title: T.text('about'),
        rows: [
          PanelRow(id: 'about', title: 'AnyPS5', kind: InfoRow(T.text('aboutText'))),
          PanelRow(
            id: 'toolkitVersion',
            title: T.text('toolkitVersion'),
            kind: InfoRow(kit == null ? '—' : EngineModel.label(kit)),
          ),
          ...updates.aboutRows(),
        ],
      ),
    ];
  }

  static String _percent(int value) => value == 0 ? T.text('off') : '$value%';

  List<PanelRow> _gameRows(Game game) {
    final settings = currentSettings(game);
    void change(GameSettings next) => saveSettings(game, next);
    final installed = records.containsKey(game.id);
    final supportsResolution = _factsOf(game).resolution;
    final languages = ConsoleLanguage.all;
    final languageIndex = settings.language == null
        ? 0
        : languages.indexWhere((entry) => entry.$1 == settings.language) + 1;
    return [
      PanelRow(
        id: 'display',
        title: T.text('display'),
        // Upstream's engine ignores the choice: the launcher presses F11 for it, and says so.
        detail: engine.readsDisplaySettings ? null : T.text('displayUpstream'),
        kind: ChoiceRow([T.text('windowed'), T.text('fullscreen')], settings.fullscreen ? 1 : 0, (index) {
          change(settings.copyWith(fullscreen: index == 1));
        }),
      ),
      if (!settings.fullscreen)
        PanelRow(
          id: 'windowSize',
          title: T.text('windowSize'),
          detail: engine.readsDisplaySettings ? null : T.text('windowSizeUpstream'),
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
        id: 'gallery',
        title: T.text('screenshotsTitle'),
        detail: T.text('screenshotsDetail'),
        kind: ActionRow(openGallery),
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
        if (_factsOf(game).backups.isNotEmpty)
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
              sounds.play(Cue.select);
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
    sounds.play(Cue.move);
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
      case Command.up || Command.down:
        final next = nextFocusable(panelRow, command == Command.down ? 1 : -1);
        if (next != panelRow) sounds.play(Cue.move);
        panelRow = next;
        _changed();
      case Command.left || Command.right:
        final delta = command == Command.right ? 1 : -1;
        switch (row?.kind) {
          // As on the Mac: the arrows stop at the first and the last option (only a select goes
          // round), so ← always goes back, even on a row of two.
          case ChoiceRow(:final options, selected: final current, :final set):
            final next = (current + delta).clamp(0, options.length - 1);
            if (next != current) {
              set(next);
              sounds.play(Cue.move);
            }
          case StepperRow(:final value, :final min, :final max, :final step, :final set):
            final next = (value + delta * step).clamp(min, max);
            if (next != value) {
              set(next);
              sounds.play(Cue.move);
            }
          case ToggleRow(:final value, :final set):
            set(!value);
            sounds.play(Cue.move);
          default:
            if (overlay == Layer.settings && categories.length > 1) {
              final next = (panelCategory + delta).clamp(0, categories.length - 1);
              if (next != panelCategory) sounds.play(Cue.move);
              panelCategory = next;
              panelRow = 0;
              _skipToFocusable();
              _changed();
            }
        }
      case Command.select:
        switch (row?.kind) {
          case ChoiceRow(:final options, selected: final current, :final set):
            set((current + 1) % options.length);
            sounds.play(Cue.move);
          case ToggleRow(:final value, :final set):
            set(!value);
            sounds.play(Cue.move);
          case ActionRow(:final run):
            sounds.play(Cue.select);
            run();
          case KeysRow(:final capture):
            capture();
          case TextRow():
            if (row != null) startEditing(row.id);
          default:
            break;
        }
      case Command.back || Command.options:
        closeOverlay();
      default:
        break;
    }
  }

  /// A click on a row: the focus goes there and the row does what Enter does.
  void activateRow(int index) {
    final rows = _currentRows;
    if (index < 0 || index >= rows.length || !rows[index].focusable) return;
    panelRow = index;
    handle(Command.select);
  }

  /// A click on a row's ‹ › or − + : one step back or on, the focus going to the row.
  void stepRow(int index, int delta) {
    final rows = _currentRows;
    if (index < 0 || index >= rows.length || !rows[index].focusable) return;
    if (panelRow != index) {
      panelRow = index;
      _changed();
    }
    handle(delta < 0 ? Command.left : Command.right);
  }

  /// The pointer moved over a row: the focus follows it, quietly.
  void hoverRow(int index) {
    final rows = _currentRows;
    if (index == panelRow || index < 0 || index >= rows.length || !rows[index].focusable) return;
    panelRow = index;
    _changed();
  }

  /// The pointer moved over a game in the library.
  void hoverLibrary(int index) {
    if (index == libraryIndex || index < 0 || index >= games.length) return;
    libraryIndex = index;
    _changed();
  }

  /// The pointer moved over a trophy.
  void hoverTrophy(int index) {
    if (index == trophyIndex || index < 0) return;
    trophyIndex = index;
    _changed();
  }

  void selectCategory(int index) {
    if (index != panelCategory) sounds.play(Cue.move);
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
    final next = (panelCategory + delta).clamp(0, categories.length - 1);
    if (next != panelCategory) sounds.play(Cue.move);
    panelCategory = next;
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
    _ => toolkit == null ? 0 : 2,
  };

  int get _onboardingCount => switch (onboardingStep) {
    0 => Language.values.length,
    1 => LookStyle.values.length,
    2 => preferences.gamesFolder == null ? 1 : 2,
    _ => 3,
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
          _enterToolkitStep();
        } else {
          unawaited(
            chooseGamesFolder().then((_) {
              if (preferences.gamesFolder != null) onboardingChoice = 1;
              notifyListeners();
            }),
          );
        }
      default:
        switch (onboardingChoice) {
          case 0:
            onboardingDownload();
          case 1:
            unawaited(
              chooseToolkit().then((_) {
                if (toolkit != null && onboardingStep == 3) onboardingChoice = 2;
                notifyListeners();
              }),
            );
          default:
            finishOnboarding();
        }
    }
    notifyListeners();
  }

  /// The toolkit step asks GitHub for the newest engine as it opens.
  void _enterToolkitStep() {
    if (engine.latest == null && !engine.checking) unawaited(engine.check(quiet: true));
  }

  /// The toolkit step's download card: downloads the newest engine (asked once more when
  /// GitHub gave no checksum), or asks GitHub again when it could not be reached.
  void onboardingDownload() {
    if (engine.downloading != null) return;
    final pending = engine.unverified;
    final package = pending ?? engine.latestPackage;
    if (package == null) {
      unawaited(engine.check(quiet: true));
      return;
    }
    unawaited(
      engine.download(package, pending != null).then((done) {
        if (done && onboardingStep == 3) onboardingChoice = 2;
        notifyListeners();
      }),
    );
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
          sounds.play(Cue.select);
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
      server.togetherServer = together.account.base.toString();
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
    sounds.play(allow ? Cue.select : Cue.back);
    pairing = null;
    _changed();
  }

  void _phoneRequest(RemoteMessage message, String deviceId) {
    switch (message) {
      case RemoteSelect(:final id):
        final index = games.indexWhere((game) => game.id == id);
        if (index < 0) return;
        if (index != selected) sounds.play(Cue.move);
        select(index);
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
      case RemoteTogetherHandoff() || RemoteTogetherHandoffAnswer():
        together.phoneMessage(message, deviceId);
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
              Locked() || Failed() || FamilyLocked() => RemoteGameState.locked,
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
    if (_disposed) return;
    super.notifyListeners();
    _updateMusic();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_watch?.cancel());
    _rescanSoon?.cancel();
    _trophyWatch?.cancel();
    _toastTimer?.cancel();
    _pads?.stop();
    _navigator?.dispose();
    _installer?.cancel();
    engine.cancel();
    fonts.dispose();
    together.dispose();
    music.dispose();
    unawaited(stopPhoneServer());
    super.dispose();
  }
}
