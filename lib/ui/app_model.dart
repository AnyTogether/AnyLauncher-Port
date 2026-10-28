import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:path/path.dart' as p;

import '../core/audio/atrac9.dart';
import '../core/audio/audio_out.dart';
import '../core/audio/interface_sounds.dart';
import '../core/audio/theme_music.dart';
import '../core/audio/tones.dart';
import '../core/controllers/pad_info.dart';
import '../core/controllers/troubleshooter.dart';
import '../core/controls.dart';
import '../core/crash_report.dart' show Diagnosis, SystemInfo;
import '../core/desktop_notice.dart';
import '../core/desktop/desktop.dart';
import '../core/desktop/launcher_window.dart';
import '../core/desktop/window_backdrop.dart';
import '../core/font_download.dart';
import '../core/free_space.dart';
import '../core/family/family_rules.dart' show TitleVerdict;
import '../core/gamepad/feel.dart';
import '../core/gamepad/guide_switch.dart';
import '../core/gamepad/pad_gate.dart';
import '../core/gamepad/pad_navigation.dart';
import '../core/gamepad/shortcuts.dart';
import '../core/game_library.dart';
import '../core/game_log.dart';
import '../core/game_process.dart';
import '../core/game_presets.dart';
import '../core/game_settings.dart';
import '../core/gyro_aiming.dart';
import '../core/host.dart';
import '../core/installer.dart';
import '../core/library_watch.dart';
import '../core/power.dart';
import '../core/prepare_queue.dart';
import '../core/remote/adb_tunnel.dart';
import '../core/remote/assist.dart';
import '../core/remote/mdns.dart';
import '../core/remote/paired_devices.dart';
import '../core/remote/remote_protocol.dart';
import '../core/remote/remote_server.dart';
import '../core/replay_buffer.dart';
import '../core/save_backup.dart';
import '../core/steam/steam_launch.dart';
import '../core/screenshots.dart';
import '../core/toolkit.dart';
import '../core/toolkit_download.dart';
import '../core/profiles/profile_saves.dart';
import '../core/profiles/profiles.dart';
import '../core/together/account.dart' show ClientTooOld, TogetherAccount;
import '../core/together/levels.dart';
import '../core/together/talk_key.dart';
import '../core/together/token_store.dart';
import '../core/online/online_peer_mesh.dart';
import '../core/together/voice_mesh.dart';
import '../core/trophies.dart';
import '../core/unlock_space.dart';
import 'browser_play.dart';
import 'components.dart';
import 'controllers_model.dart';
import 'crash_model.dart';
import 'engine_model.dart';
import 'fonts_model.dart';
import 'steam_model.dart';
import 'glass.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';
import 'update_model.dart';
import 'trophy_card.dart';

part 'profiles_model.dart';

/// The launcher's own choices, kept as JSON in the config folder.
class Preferences {
  Preferences();

  factory Preferences.fromJson(Map<String, dynamic> json) => Preferences()
    ..language = json['language'] as String? ?? 'en'
    // A look this launcher does not know (or garbage) is Cosmic; the rest of the file still counts.
    ..theme = switch (json['theme']) {
      final num index => LookStyle.fromIndex(index.toInt()).index,
      _ => LookStyle.cosmic.index,
    }
    ..accent = json['accent'] as String?
    ..profileName = json['profileName'] as String? ?? 'Player'
    ..gamesFolder = json['gamesFolder'] as String?
    ..toolkitFolder = json['toolkitFolder'] as String?
    ..onboarded = json['onboarded'] as bool? ?? false
    ..gameArtwork = json['gameArtwork'] as bool? ?? true
    ..reducedMotion = json['reducedMotion'] as bool? ?? false
    ..reduceTransparency = json['reduceTransparency'] == true
    ..glassTooSlow = json['glassTooSlow'] == true
    ..glassTransparency = switch (json['glassTransparency']) {
      final num percent => percent.toInt().clamp(0, 100),
      _ => null,
    }
    ..glassArtwork = json['glassArtwork'] == true
    ..phoneServer = json['phoneServer'] as bool? ?? true
    ..browserPlay = json['browserPlay'] as bool? ?? true
    ..browserPlayAlways = json['browserPlayAlways'] == true
    ..togetherServer = json['togetherServer'] as String?
    ..friendsJoin = json['friendsJoin'] as bool? ?? true
    ..onlinePlay = json['onlinePlay'] == true
    ..onlinePlatformGroups = json['onlinePlatformGroups'] as bool? ?? true
    ..pushToTalk = json['pushToTalk'] as bool? ?? false
    ..talkKey = (json['talkKey'] as num?)?.toInt()
    ..sounds = json['sounds'] as bool? ?? true
    ..soundVolume = (json['soundVolume'] as num?)?.toInt()
    ..musicVolume = (json['musicVolume'] as num?)?.toInt()
    ..engineSource = json['engineSource'] as String? ?? 'upstream'
    ..fontsFolder = json['fontsFolder'] as String?
    ..showHiddenTrophies = json['showHiddenTrophies'] as bool? ?? false
    ..controllerVibration = json['controllerVibration'] as bool? ?? true
    ..steamUser = json['steamUser'] as String?
    ..steamGames = json['steamGames'] == true
    ..steamFullscreen = json['steamFullscreen'] as bool? ?? true
    ..controllerLight = json['controllerLight'] as String?
    ..confirmCircle = json['confirmCircle'] == true
    ..assistPlayerOne = json['assistPlayerOne'] as String?
    ..stickDeadzone = switch (json['stickDeadzone']) {
      final num percent => percent.toInt().clamp(0, StickDeadzone.maximum),
      _ => 0,
    }
    ..cjkGames = {
      for (final id in json['cjkGames'] as List<dynamic>? ?? const <dynamic>[])
        if (id is String) id,
    }
    ..prepareNewGames = json['prepareNewGames'] as bool? ?? true
    ..launcherFullscreen = json['launcherFullscreen'] as bool?
    ..pauseOnMenu = json['pauseOnMenu'] as bool? ?? true
    ..replayBuffer = json['replayBuffer'] == true
    ..replaySeconds = switch (json['replaySeconds']) {
      final num seconds when ReplayBuffer.lengths.contains(seconds.toInt()) => seconds.toInt(),
      _ => ReplayBuffer.defaultLength,
    }
    ..shortcuts = ShortcutMap.fromJson(json['shortcuts'])
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

  /// Glass draws its surfaces solid, without the blur behind them.
  bool reduceTransparency = false;

  /// The graphics card fell behind drawing Glass's transparency once: it starts solid from then
  /// on, until Glass is picked again in Settings › Appearance.
  bool glassTooSlow = false;

  /// Glass's see-through window: how much of the desktop shows, in percent (null for
  /// GlassWindow.defaultTransparency), and whether the selected game's picture is laid over it.
  int? glassTransparency;
  bool glassArtwork = false;
  bool phoneServer = true;

  /// Play from a browser (browser_play.dart), and whether its server stays up all the time.
  bool browserPlay = true;
  bool browserPlayAlways = false;

  /// Another AnyTogether server than AnyTogether's own; null for that one.
  String? togetherServer;

  /// While a game runs, friends see it and can join (an AnyTogether game session).
  bool friendsJoin = true;

  /// Settings › AnyTogether › Online play (experimental): games are started with the launcher's
  /// online bridge (signed in as the AnyTogether user, friends, Player Sessions, game packets to
  /// the other players). Off by default.
  bool onlinePlay = false;

  /// With online play on, the platform's web API groups the launcher knows (userProfile,
  /// communicationRestrictionStatus, sessionManager) are answered; off answers them all "not
  /// offered", for a clean observation run. Not in the interface.
  bool onlinePlatformGroups = true;

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

  /// Soft pulses in the controller for select, back, errors, trophies, invitations and the end
  /// of a row.
  bool controllerVibration = true;

  /// Settings › Steam: the account the shortcuts go to (`<Steam folder>|<account ID>`; null for
  /// the one signed in last), each unlocked game its own shortcut too, the launcher full screen
  /// when Steam starts it.
  String? steamUser;
  bool steamGames = false;
  bool steamFullscreen = true;

  /// Settings › Controllers: the light bar's colour (PadLight's name; null for the theme's
  /// accent), Circle confirming instead of Cross, and the sticks' dead zone in percent.
  String? controllerLight;
  bool confirmCircle = false;
  int stickDeadzone = 0;

  /// Settings › Controllers › Assist Player 1 (AssistTarget): null off, "controllers", or the
  /// device ID of the phone or browser pad that helps.
  String? assistPlayerOne;

  /// The title IDs of games seen asking for Japanese, Chinese or Korean fonts: their next start
  /// waits for those to download.
  Set<String> cjkGames = {};

  /// Settings › Game Library: new games unlocked in the background like a console installing them.
  bool prepareNewGames = true;

  /// Settings › Appearance › Full Screen: null until the user chooses (the launcher starts full
  /// screen then), the choice after.
  bool? launcherFullscreen;

  /// Settings › Behaviour: before the quick menu covers a game, its Options is pressed so it
  /// pauses.
  bool pauseOnMenu = true;

  /// Settings › Captures: the last [replaySeconds] of play kept while a game runs, for Share.
  bool replayBuffer = false;
  int replaySeconds = ReplayBuffer.defaultLength;

  /// Settings › Shortcuts.
  ShortcutMap shortcuts = ShortcutMap();

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
    'reduceTransparency': reduceTransparency,
    if (glassTooSlow) 'glassTooSlow': true,
    'glassTransparency': glassTransparency,
    'glassArtwork': glassArtwork,
    'phoneServer': phoneServer,
    'browserPlay': browserPlay,
    'browserPlayAlways': browserPlayAlways,
    'togetherServer': togetherServer,
    'friendsJoin': friendsJoin,
    'onlinePlay': onlinePlay,
    if (!onlinePlatformGroups) 'onlinePlatformGroups': false,
    'pushToTalk': pushToTalk,
    'talkKey': talkKey,
    'sounds': sounds,
    'soundVolume': soundVolume,
    'musicVolume': musicVolume,
    'lastPlayed': lastPlayed,
    'engineSource': engineSource,
    'fontsFolder': fontsFolder,
    'showHiddenTrophies': showHiddenTrophies,
    'controllerVibration': controllerVibration,
    'steamUser': steamUser,
    'steamGames': steamGames,
    'steamFullscreen': steamFullscreen,
    'controllerLight': controllerLight,
    'confirmCircle': confirmCircle,
    'stickDeadzone': stickDeadzone,
    'assistPlayerOne': assistPlayerOne,
    'cjkGames': cjkGames.toList()..sort(),
    'prepareNewGames': prepareNewGames,
    'launcherFullscreen': launcherFullscreen,
    'pauseOnMenu': pauseOnMenu,
    'replayBuffer': replayBuffer,
    'replaySeconds': replaySeconds,
    if (!shortcuts.isDefault) 'shortcuts': shortcuts.toJson(),
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
  const Locked({this.waitingToPrepare = false});

  /// In line to be prepared in the background once the game playing closes.
  final bool waitingToPrepare;
}

class Unreadable extends GameState {
  const Unreadable();
}

class Queued extends GameState {
  const Queued();
}

class Installing extends GameState {
  const Installing(this.step, this.fraction, {this.preparing = false, this.paused = false});
  final InstallStep step;
  final double fraction;

  /// Prepared in the background (a new game), not asked for by the user.
  final bool preparing;

  /// Stopped where it is while a game plays.
  final bool paused;

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

/// Where the home screen's focus is: the tiles, a top-bar button, a button under the title, or
/// one of the update notice's (0 Restart Now, 1 Later), left of the top bar's.
class HomeFocus {
  const HomeFocus._(this.area, this.index);
  static const tiles = HomeFocus._('tiles', 0);
  const HomeFocus.top(int index) : this._('top', index);
  const HomeFocus.actions(int index) : this._('actions', index);
  const HomeFocus.notice(int index) : this._('notice', index);

  final String area;
  final int index;

  bool get isTiles => area == 'tiles';
  bool get isTop => area == 'top';
  bool get isActions => area == 'actions';
  bool get isNotice => area == 'notice';

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

  /// AnyTogether no longer answers this launcher's version (client_too_old): update.
  updateRequired,
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

  /// Comparing trophies with someone: the games either has trophies in, then one game's trophies
  /// side by side.
  compare,

  /// Family limits: today's play time, asking a parent for more.
  family,

  /// A game's last start: why it stopped, crash_log.txt to save, the issue to open.
  crashReport,

  /// Before an unlock that would copy the game's files: how much and why, the two ways to link
  /// instead (the games folder on the dump's drive, Windows' Developer Mode), copying anyway.
  copyWarning,

  /// Settings › Controllers › Test Buttons and Sticks.
  controllerTest,

  /// Settings › Phones › Play from a browser: the QR code a phone scans (browser_play.dart).
  browserPlay,

  /// PS in a game: the game paused under Resume, Game Settings and Close Game.
  quickMenu,

  /// PS held in a game: Close Game?
  closeGame,

  /// PS held in the launcher: Switch Profile, Quit AnyPS5.
  homeMenu,

  /// "Who's playing?": the profiles' tiles and Add Profile (profiles_model.dart).
  profilePicker,

  /// A new profile: its name, then offline or online.
  addProfile,

  /// Signing in to AnyTogether for a profile (a new one, one going online or signing in again).
  signIn,

  /// Options (or a right click) on Home: the game's settings, Switch Profile, online or offline.
  profileMenu,
}

/// A settings row the panels draw and the keyboard moves through.
class PanelRow {
  const PanelRow({
    required this.id,
    required this.title,
    required this.kind,
    this.detail,
    this.glyph,
    this.person,
    this.level,
  });

  final String id;
  final String title;
  final String? detail;

  /// A face button drawn after the title.
  final PadGlyph? glyph;
  final RowKind kind;

  /// Someone on AnyTogether the row is about, drawn as their picture before the title.
  final PanelPerson? person;

  /// Their trophy level, drawn after the title.
  final LevelBadge? level;

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

/// A shortcut's key and controller binding (Settings › Shortcuts); choosing it waits for a key or
/// buttons.
class ShortcutRow extends RowKind {
  const ShortcutRow({required this.key, required this.pad, required this.capturing, required this.capture});
  final String? key;
  final String? pad;
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
    this.togetherStoreFor,
    this.togetherServer,
    this.togetherPollEvery,
    this.voiceEngine,
    this.gameLinks,
    this.talkKeys,
    this.engineReleases,
    this.launcherReleases,
    this.hostGlibc,
    this.audio,
    this.decodeSong,
    this.armEngineReleases,
    this.pads,
    this.systemProbe,
    this.desktop,
    this.backdrop,
    this.renderTrophyCard,
    this.cjkFonts,
    this.fontClient,
    this.builtInFonts,
    this.saveFile,
    this.pickImage,
    this.systemInfo,
    this.startDetached,
    this.quit,
    this.window,
    this.replay,
  });

  /// The launcher's own window: full screen or not; nothing when not given.
  final LauncherWindow? window;

  /// The replay buffer for a game about to start, [seconds] long; ffmpeg found on this system by
  /// default (null: none, or a desktop it cannot record).
  final ReplayBuffer? Function(int seconds)? replay;

  /// Starts a program that outlives the launcher (an update's installer, the new AppImage);
  /// Process.start detached by default.
  final Future<void> Function(String executable, List<String> arguments)? startDetached;

  /// Ends the launcher (Restart Now); exit by default.
  final void Function(int code)? quit;

  /// Asks the user for a picture (PNG or JPEG); null when they cancelled.
  final Future<String?> Function()? pickImage;

  /// Asks the user where to save a file, [suggestedName] first; null when they cancelled.
  final Future<String?> Function(String suggestedName)? saveFile;

  /// This computer for a crash report; read from the system when not given.
  final Future<SystemInfo> Function()? systemInfo;

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

  /// What the controller troubleshooter asks the system (running programs, drivers, Steam's
  /// setting, permissions); nothing asked when not given.
  final SystemProbe Function()? systemProbe;

  /// The game's window, its picture and the trophy card over it; nothing when not given.
  final DesktopWindows? desktop;

  /// The launcher window's see-through backdrop for Glass (Acrylic on Windows, an RGBA window
  /// and KWin's blur on Linux); an opaque window when not given.
  final WindowBackdrop? backdrop;

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

  /// Online play's peer connections to the other players; flutter_webrtc by default.
  final GameLinks Function()? gameLinks;

  /// Reads the talk key anywhere on the desktop; the system's reader by default, none in tests.
  final KeyStateReader? Function()? talkKeys;

  /// Opens a web page in the browser.
  final void Function(Uri url)? openUrl;

  /// Puts a text on the clipboard.
  final void Function(String text)? copyText;

  /// The environment the launcher reads (ANYTOGETHER_URL); the process's by default.
  final Map<String, String>? environment;

  /// Where the AnyTogether session is kept (the first profile's); the system's own store by
  /// default.
  final TokenStore? togetherStore;

  /// Where another launcher profile's session is kept; its own system store by default.
  final TokenStore Function(String profile)? togetherStoreFor;

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
    // Profiles: a launcher set up before them becomes its first profile at once.
    profiles = ProfileStore(
      p.join(paths.config, 'Profiles'),
      existing: ExistingSetup(onboarded: this.preferences.onboarded, name: this.preferences.profileName),
      persist: persist,
    );
    T.language = Language.byCode(this.preferences.language);
    Motion.reduced = this.preferences.reducedMotion;
    together = TogetherModel(this);
    _applySound();
    sounds.onCue = _cueAsked;
  }

  // Feel: the controller's pulses, the end-of-row bump, the hover tick.

  /// The launcher's own clock for the feel's timings.
  final Stopwatch _clock = Stopwatch()..start();
  Duration get feelNow => _clock.elapsed;

  /// When the last cue other than the hover tick was asked for.
  Duration? _lastCue;

  late final PulsePlayer _pulses = PulsePlayer(_PadMotors(this));

  /// The pulses the controller gives: Settings › Behaviour › Controller Vibration, never while a
  /// game (or another window) is in front, only while the pad is the device in use.
  late final HapticFeedback haptics = HapticFeedback(_pulses, enabled: preferences.controllerVibration);

  final EdgeBump _edge = EdgeBump();
  final HoverGate _hover = HoverGate();

  void _cueAsked(Cue cue) {
    if (cue != Cue.hover) _lastCue = feelNow;
    final haptic = HapticCue.forSound(cue.name);
    if (haptic != null) _pulse(haptic);
  }

  /// A pulse told on its own: a trophy, an invitation, an error.
  void vibrate(HapticCue cue) => _pulse(cue);

  /// A pulse, only while the launcher is in front: asked of the desktop each time, as Flutter's
  /// own report of the window's focus is not enough on its own (see [launcherInFront]).
  void _pulse(HapticCue cue) {
    haptics.launcherInFront = launcherInFront;
    haptics.play(cue, now: feelNow);
  }

  /// The keyboard or the mouse was used: the controller on the desk stays still.
  void usedKeyboard() {
    haptics.padInUse = false;
    _usedInput(InputMode.keyboardMouse);
  }

  /// The mouse moved over the launcher: its hints and controls show again.
  void usedPointer() {
    if (inputMode == InputMode.keyboardMouse) return;
    usedKeyboard();
  }

  /// What a command may change where the eye is: a direction that changed none of it and asked
  /// for no sound hit the end of its row.
  Object _focusMark() => (
    overlay,
    focus.area,
    focus.index,
    selected,
    libraryIndex,
    panelRow,
    panelCategory,
    trophyIndex,
    galleryIndex,
    galleryViewing,
    capturing,
    editingRow,
    panelSections,
    editingValue,
    shortcutCapture,
  );

  /// A command from the keys or a controller: handled, and a direction that did nothing bumps
  /// (once per press, once in a hold that reaches the end).
  void command(Command command, {bool repeat = false}) {
    if (pointerFocus) {
      // The keys or the pad move the focus from here: the lists follow it again.
      pointerFocus = false;
      notifyListeners();
    }
    final mark = _focusMark();
    final asked = sounds.requests;
    handle(command);
    final direction =
        command == Command.left || command == Command.right || command == Command.up || command == Command.down;
    if (_edge.handled(
      direction: direction,
      repeat: repeat,
      changed: sounds.requests != asked || _focusMark() != mark,
    )) {
      sounds.play(Cue.bump);
    }
  }

  /// The pointer arrived on a control, tile, row or card: the quiet tick, when [HoverGate] lets
  /// it.
  void hoverArrived(Object id, {required double x, required double y, required bool buttonsDown}) {
    // Not while a list is dragged or still gliding after one: rows passing under the pointer
    // are not arrivals.
    final allowed = preferences.sounds && active && preferences.onboarded && !panning;
    if (_hover.arrive(id, x: x, y: y, now: feelNow, lastCue: _lastCue, buttonsDown: buttonsDown, allowed: allowed)) {
      sounds.play(Cue.hover);
    }
  }

  void hoverLeft(Object id) => _hover.leave(id);

  /// A list is being dragged with the mouse, or still gliding after it: no hover ticks.
  bool panning = false;

  /// The focus was last moved by the pointer (a row hovered or clicked), not by the keys or a
  /// controller: the lists stay where they are ([KeepVisible] scrolls only for the keys and the
  /// pad, so a list never chases the mouse).
  bool pointerFocus = false;

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
    _shownInFront = launcherInFront;
    // Behind a game (or any other window) the pad is the game's: the motors stop at once, and a
    // direction held on it lets go.
    haptics.launcherInFront = value;
    _padLog?.call('window ${value ? 'in front' : 'behind'} (Flutter)');
    if (!value) _gate?.close();
    if (value) updates.activated();
    // A game may have changed the light bars: the launcher's colour again.
    if (value) controllers.applyLights();
    // Back in front: a toolkit rebuilt meanwhile is read again.
    if (value) _forgetDiskFacts();
    // Something copied in while the launcher was away shows at once.
    if (value) _library?.rescanSoon();
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

  /// An unlock the user asked for finished (the game's id, whether it worked): Play Together
  /// joins a game it unlocked first.
  void Function(String gameId, bool succeeded)? onUnlocked;

  DesktopWindows get desktop => services.desktop ?? const NoDesktop();

  PadSource? _pads;
  PadNavigator? _navigator;
  PadGate? _gate;
  DeadzoneStage? _deadzone;

  /// Settings › Controllers: the controllers, their log, lights and troubleshooter.
  late final ControllersModel controllers = ControllersModel(this);

  /// The motors of whatever controllers are read now.
  PadRumble? get padMotors => _pads?.motors;

  /// Started from Steam: Steam's virtual controller stands for the real one.
  bool get launchedFromSteam => steamLaunch.fromSteam;

  /// The accent as red, green and blue (0 to 255), for the light bars' Theme Colour.
  (int, int, int) get accentRgb {
    final color = accentChoice.color;
    return ((color.r * 255).round(), (color.g * 255).round(), (color.b * 255).round());
  }

  /// A controller connect or disconnect: the debug log (ANYPS5_PAD_LOG) and the console.
  void padLogLine(String line) {
    _padLog?.call(line);
    debugPrint('[anyps5-launcher] $line');
  }

  /// The controller settings that act at once: Circle confirming, the dead zone, the hints.
  void _applyPadPreferences() {
    _navigator
      ?..circleConfirms = preferences.confirmCircle
      ..shortcuts = preferences.shortcuts;
    _deadzone?.percent = preferences.stickDeadzone;
    Hint.circleConfirms = preferences.confirmCircle;
    applyAssist();
  }

  /// Assist as the phone server needs it.
  void applyAssist() {
    final target = AssistTarget.stored(preferences.assistPlayerOne);
    remote?.setAssist(devices: target.devices, controllers: target.controllers);
  }

  void openControllerTest() {
    unawaited(controllers.probe());
    open(Layer.controllerTest);
  }

  /// Back from the controller test to Settings › Controllers, where it was opened from.
  void closeControllerTest() {
    open(Layer.settings, cue: Cue.back);
    final categories = panelCategories();
    final index = categories.indexWhere((category) => category.id == 'controllers');
    if (index < 0) return;
    panelCategory = index;
    panelRow = categories[index].rows
        .indexWhere((row) => row.id == 'padTest')
        .clamp(0, categories[index].rows.length - 1);
    _changed();
  }

  /// Whether the launcher is in front: Flutter says its window has the focus and, where the
  /// desktop can tell (Windows, X11), the window in front is the launcher's. The controller is
  /// read whichever window is in front, so this is what keeps a game's pad out of the launcher;
  /// Flutter's focus report alone let the presses through on Windows while a game was played.
  bool get launcherInFront {
    // Steam's Game Mode (gamescope) may report no active window at all: with no game running
    // the launcher is what is on screen.
    if (steamLaunch.gameMode && running == null && starting == null) return true;
    return active && (desktop.launcherFocused() ?? true);
  }

  /// A line for the controller's debug log: ANYPS5_PAD_LOG names a file to add them to.
  late final void Function(String line)? _padLog = () {
    final path = (services.environment ?? Platform.environment)['ANYPS5_PAD_LOG'];
    if (path == null || path.isEmpty) return null;
    return (String line) {
      try {
        File(path).writeAsStringSync(
          '${DateTime.now().toIso8601String()} $line (focus ${active ? 'resumed' : 'inactive'}, '
          'desktop ${desktop.launcherFocused()})\n',
          mode: FileMode.append,
        );
      } on FileSystemException {
        // The log is a help, never a reason to stop.
      }
    };
  }();

  /// Reads the controllers: their moves become the same commands as the keys, while the
  /// launcher is in front ([PadGate]).
  void startPads() {
    if (_pads != null) return;
    final source = services.pads?.call();
    if (source == null) return;
    final navigator = PadNavigator(
      padCommand,
      shortcuts: preferences.shortcuts,
      isPlayStation: (pad) => controllers.roster.pad(pad)?.kind.isPlayStation ?? false,
    );
    _navigator = navigator;
    final gate = PadGate(_padEvent, inFront: () => launcherInFront, log: _padLog, passesInGame: navigator.passesInGame);
    _gate = gate;
    final deadzone = DeadzoneStage(gate.handle);
    _deadzone = deadzone;
    _applyPadPreferences();
    _pads = source..start(deadzone.handle);
    controllers.attach(source);
    if (_padLog case final log?) {
      log('pad: reading ${source.description}');
      // For the log, what the desktop says as it changes, controller or not.
      bool? said;
      _focusWatch = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final now = desktop.launcherFocused();
        if (now == said) return;
        said = now;
        log('desktop: launcher ${now == null ? 'cannot tell' : (now ? 'in front' : 'behind')}');
      });
    }
  }

  Timer? _focusWatch;

  /// A controller's event past the gate: to the navigator, or to Settings › Shortcuts while it
  /// waits for buttons.
  void _padEvent(PadEvent event) {
    if (shortcutCapture != null && event is PadButtonEvent) return _capturePad(event);
    _navigator?.handle(event);
  }

  /// What the user moved the launcher with last: the controller's hints or the keys'.
  InputMode inputMode = InputMode.keyboardMouse;

  void _usedInput(InputMode mode) {
    if (inputMode == mode) return;
    inputMode = mode;
    notifyListeners();
  }

  /// Whether the command being handled came from a controller (or the phone's pad), not the
  /// keys or the mouse: the settings' sections and edit mode are for it.
  bool _viaPad = false;

  /// A controller command. With the launcher behind a game (or another window) only PS/Guide
  /// and the in-game shortcuts (the quick menu, Share) count.
  void padCommand(PadCommand command) {
    final inFront = launcherInFront;
    final Command mapped;
    switch (command) {
      case PadCommand.homeHold || PadCommand.quickMenu || PadCommand.screenshot || PadCommand.saveClip:
        _pulses.pad = _navigator?.lastPad;
        // A controller's press, in the game or not: the menus it opens show its buttons.
        _usedInput(InputMode.pad);
        if (inFront) haptics.padInUse = true;
        if (overlay == Layer.controllerTest && inFront) return;
        return switch (command) {
          PadCommand.homeHold => homeHeld(),
          PadCommand.quickMenu => unawaited(openQuickMenu()),
          PadCommand.screenshot => unawaited(takeScreenshot()),
          _ => unawaited(saveClip()),
        };
      case PadCommand.fullscreen:
        if (!inFront || overlay == Layer.controllerTest) return;
        _usedInput(InputMode.pad);
        return unawaited(toggleFullscreen());
      case PadCommand.left:
        mapped = Command.left;
      case PadCommand.right:
        mapped = Command.right;
      case PadCommand.up:
        mapped = Command.up;
      case PadCommand.down:
        mapped = Command.down;
      case PadCommand.select:
        mapped = Command.select;
      case PadCommand.back:
        mapped = Command.back;
      case PadCommand.options:
        mapped = Command.options;
      case PadCommand.menu:
        // Options/Start on Home: Switch Profile, online or offline (Triangle stays the game's).
        mapped = Command.options;
        if (overlay == null && preferences.onboarded && inFront && pairing == null && starting == null) {
          haptics.padInUse = true;
          _usedInput(InputMode.pad);
          return openProfileMenu();
        }
      case PadCommand.previousGame:
        mapped = Command.previousGame;
      case PadCommand.nextGame:
        mapped = Command.nextGame;
      case PadCommand.home:
        mapped = Command.home;
    }
    if (mapped != Command.home && !inFront) return;
    haptics.padInUse = true;
    _pulses.pad = _navigator?.lastPad;
    controllers.used(_navigator?.lastPad);
    _usedInput(InputMode.pad);
    // The controller test takes the pads' buttons: only PS acts (a held Circle leaves it).
    if (overlay == Layer.controllerTest && mapped != Command.home) return;
    if (editingRow != null) return;
    if (capturing != null && mapped != Command.back) return;
    if (overlay == Layer.settings && (mapped == Command.previousGame || mapped == Command.nextGame)) {
      return moveCategory(mapped == Command.nextGame ? 1 : -1);
    }
    _viaPad = true;
    try {
      this.command(mapped, repeat: _navigator?.repeating ?? false);
    } finally {
      _viaPad = false;
    }
  }

  // Shortcuts (Settings › Shortcuts).

  /// The action waiting for a key or controller buttons in Settings › Shortcuts.
  LauncherAction? shortcutCapture;

  /// The buttons held together so far while waiting, the most at once, and whether they were
  /// held long enough to be a long press.
  final Set<PadButton> _captureHeld = {};
  final Set<PadButton> _captureChord = {};
  bool _captureLong = false;
  Timer? _captureTimer;

  void startShortcutCapture(LauncherAction action) {
    shortcutCapture = action;
    _captureHeld.clear();
    _captureChord.clear();
    _captureLong = false;
    // The press that chose the row is let go into the capture: the navigator starts afresh.
    _navigator?.reset();
    sounds.play(Cue.select);
    _changed();
  }

  void cancelShortcutCapture() {
    if (shortcutCapture == null) return;
    shortcutCapture = null;
    _captureTimer?.cancel();
    sounds.play(Cue.back);
    _changed();
  }

  void _capturePad(PadButtonEvent event) {
    final button = _navigator?.normalize(event.pad, event.button) ?? event.button;
    if (event.down) {
      _captureHeld.add(button);
      _captureChord.add(button);
      _captureTimer?.cancel();
      _captureLong = false;
      _captureTimer = Timer(ShortcutTiming.hold, () => _captureLong = true);
      return;
    }
    if (!_captureHeld.remove(button) || _captureHeld.isNotEmpty) return;
    _captureTimer?.cancel();
    final chord = PadChord({..._captureChord}, hold: _captureLong);
    _captureChord.clear();
    _usedInput(InputMode.pad);
    // Circle alone (Cross with Circle confirming) is the way out.
    final cancel = preferences.confirmCircle ? PadButton.south : PadButton.east;
    if (!chord.hold && chord.buttons.length == 1 && chord.buttons.first == cancel) return cancelShortcutCapture();
    // Triangle alone clears the controller's binding.
    if (!chord.hold && chord.buttons.length == 1 && chord.buttons.first == PadButton.north) {
      final action = shortcutCapture!;
      shortcutCapture = null;
      return clearShortcut(action, input: InputMode.pad);
    }
    assignPadShortcut(chord);
  }

  /// A key pressed while a shortcut waits for one.
  void captureShortcutKey(KeyCombo key) {
    if (shortcutCapture == null) return;
    _usedInput(InputMode.keyboardMouse);
    final plain = !key.control && !key.alt && !key.shift;
    if (key.key == KeyIds.escape && plain) return cancelShortcutCapture();
    final action = shortcutCapture!;
    // Backspace (or Delete) alone clears the key.
    if ((key.key == KeyIds.backspace || key.key == KeyIds.delete) && plain) {
      shortcutCapture = null;
      return clearShortcut(action, input: InputMode.keyboardMouse);
    }
    final conflict = preferences.shortcuts.keyConflict(action, key);
    _finishCapture(conflict, () => preferences.shortcuts[action].withKey(key));
  }

  void assignPadShortcut(PadChord chord) {
    final action = shortcutCapture;
    if (action == null) return;
    final conflict = preferences.shortcuts.padConflict(action, chord);
    _finishCapture(conflict, () => preferences.shortcuts[action].withPad(chord));
  }

  void _finishCapture(ShortcutConflict? conflict, ShortcutBinding Function() binding) {
    final action = shortcutCapture!;
    shortcutCapture = null;
    if (conflict != null) {
      vibrate(HapticCue.error);
      sounds.play(Cue.bump);
      show(switch (conflict) {
        TakenBy(:final action) => T.format('shortcutTaken', [shortcutTitle(action)]),
        Reserved() => T.text('shortcutReserved'),
      });
      _changed();
      return;
    }
    preferences.shortcuts = preferences.shortcuts.withBinding(action, binding());
    sounds.play(Cue.move);
    savePreferences();
  }

  /// The shortcut whose row the focus is on in Settings › Shortcuts, if any.
  LauncherAction? get focusedShortcut {
    if (overlay != Layer.settings) return null;
    final rows = _currentRows;
    final id = panelRow < rows.length ? rows[panelRow].id : '';
    return id.startsWith('shortcut-') ? LauncherAction.byName(id.substring('shortcut-'.length)) : null;
  }

  /// △ (or Delete) on a shortcut: the binding of the input in use goes.
  void clearShortcut(LauncherAction action, {InputMode? input}) {
    final binding = preferences.shortcuts[action];
    final next = (input ?? inputMode) == InputMode.pad ? binding.withPad(null) : binding.withKey(null);
    if (next == binding) return _changed();
    preferences.shortcuts = preferences.shortcuts.withBinding(action, next);
    sounds.play(Cue.back);
    savePreferences();
  }

  /// The action a key runs while the launcher has the keyboard, if any.
  LauncherAction? shortcutForKey(KeyCombo key) => preferences.shortcuts.actionForKey(key);

  /// A shortcut's key pressed in the launcher.
  void runKeyShortcut(LauncherAction action) {
    usedKeyboard();
    switch (action) {
      case LauncherAction.home:
        command(Command.home);
      case LauncherAction.quickMenu:
        unawaited(openQuickMenu());
      case LauncherAction.screenshot:
        unawaited(takeScreenshot());
      case LauncherAction.saveClip:
        unawaited(saveClip());
      case LauncherAction.toggleFullscreen:
        unawaited(toggleFullscreen());
      case LauncherAction.previousSection || LauncherAction.nextSection:
        final delta = action == LauncherAction.nextSection ? 1 : -1;
        if (overlay == Layer.settings) return moveCategory(delta);
        command(delta > 0 ? Command.nextGame : Command.previousGame);
    }
  }

  static String shortcutTitle(LauncherAction action) => T.text(switch (action) {
    LauncherAction.home => 'shortcutHome',
    LauncherAction.quickMenu => 'shortcutQuickMenu',
    LauncherAction.screenshot => 'shortcutScreenshot',
    LauncherAction.saveClip => 'shortcutSaveClip',
    LauncherAction.toggleFullscreen => 'shortcutFullscreen',
    LauncherAction.previousSection => 'shortcutPreviousSection',
    LauncherAction.nextSection => 'shortcutNextSection',
  });

  /// The AnyPS5 engine downloaded from upstream: versions, the download, the one in use.
  late final EngineModel engine = EngineModel(this);
  late final LauncherUpdateModel updates = LauncherUpdateModel(this);

  /// The system fonts games get: the folder put together for them, the CJK download.
  late final FontsModel fonts = FontsModel(this);
  late final BrowserPlayModel browserPlay = BrowserPlayModel(this);

  /// AnyPS5 and its games in the Steam library (Settings › Steam).
  late final SteamModel steam = SteamModel(this);

  /// How this launch came from Steam (a shortcut's --steam, SteamGameId, gamescope), and the
  /// controllers Steam Input took over.
  SteamLaunch steamLaunch = const SteamLaunch();

  /// The crash report of a game's last start, and detailed logging.
  late final CrashModel crash = CrashModel(this);

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

  /// Replaced by another profile's when that profile plays (profiles_model.dart).
  Preferences preferences;

  /// Who plays on this computer, and the profile screens' state.
  late final ProfileStore profiles;
  final ProfileFlow profileFlow = ProfileFlow();

  /// The other profiles' sessions in tests and previews, which give the first one's in memory.
  final Map<String, MemoryTokenStore> _memoryStores = {};
  final LauncherServices services;
  final HostSystem system;
  final GameSettingsStore settingsStore;

  /// Whether choices are written to disk (off in previews and tests).
  final bool persist;

  /// Settings › Game Presets of the profile playing, in a file of their own in its folder
  /// ([GamePresetsStore]): every game it starts begins with them. Read again when another
  /// profile plays.
  GamePresets get gamePresets {
    final owner = _presetsOwner;
    if (_presets == null || owner != _cachedPresetsOwner) {
      _presets = persist ? GamePresetsStore(gamePresetsFile(owner)).load() : const GamePresets();
      _cachedPresetsOwner = owner;
    }
    return _presets!;
  }

  GamePresets? _presets;
  String? _cachedPresetsOwner;
  String get _presetsOwner => profiles.book.currentProfile?.id ?? LauncherProfile.legacyId;

  /// Where profile [id]'s presets are kept: beside its other files, under the profiles folder.
  String gamePresetsFile(String id) => p.join(profiles.folder, id, 'GamePresets.json');

  void setGamePresets(GamePresets presets) {
    if (presets == gamePresets) return;
    _presets = presets;
    _cachedPresetsOwner = _presetsOwner;
    if (persist) GamePresetsStore(gamePresetsFile(_presetsOwner)).save(presets);
    _changed();
  }

  List<PanelRow> _presetRows() {
    final presets = gamePresets;
    const difficultyNames = ['presetGameDefault', 'presetEasiest', 'presetEasy', 'presetNormal', 'presetHard', 'presetHardest'];
    const priorityNames = ['presetGameDefault', 'presetPerformance', 'presetResolution'];
    const subtitleNames = ['presetGameDefault', 'presetShow', 'presetHide'];
    const languages = ConsoleLanguage.all;
    final languageIndex = presets.audioLanguage == null
        ? 0
        : languages.indexWhere((language) => language.$1 == presets.audioLanguage) + 1;
    PanelRow toggle(String id, bool value, GamePresets Function(bool) change) =>
        PanelRow(id: id, title: T.text(id), kind: ToggleRow(value, (on) => setGamePresets(change(on))));
    return [
      PanelRow(id: 'presetsIntro', title: T.text('presetsIntroTitle'), kind: InfoRow(T.text('presetsIntro'))),
      PanelRow(
        id: 'presetDifficulty',
        title: T.text('presetDifficulty'),
        kind: ChoiceRow([for (final name in difficultyNames) T.text(name)], presets.difficulty.index, (index) {
          setGamePresets(presets.copyWith(difficulty: PresetDifficulty.values[index]));
        }),
      ),
      PanelRow(
        id: 'presetPriority',
        title: T.text('presetPriority'),
        detail: T.text('presetPriorityDetail'),
        kind: ChoiceRow([for (final name in priorityNames) T.text(name)], presets.priority.index, (index) {
          setGamePresets(presets.copyWith(priority: PresetPriority.values[index]));
        }),
      ),
      toggle('presetInvertVerticalFirst', presets.invertVerticalFirstPerson, (on) => presets.copyWith(invertVerticalFirstPerson: on)),
      toggle('presetInvertHorizontalFirst', presets.invertHorizontalFirstPerson, (on) => presets.copyWith(invertHorizontalFirstPerson: on)),
      toggle('presetInvertVerticalThird', presets.invertVerticalThirdPerson, (on) => presets.copyWith(invertVerticalThirdPerson: on)),
      toggle('presetInvertHorizontalThird', presets.invertHorizontalThirdPerson, (on) => presets.copyWith(invertHorizontalThirdPerson: on)),
      PanelRow(
        id: 'presetSubtitles',
        title: T.text('presetSubtitles'),
        kind: ChoiceRow([for (final name in subtitleNames) T.text(name)], presets.subtitles.index, (index) {
          setGamePresets(presets.copyWith(subtitles: PresetSubtitles.values[index]));
        }),
      ),
      PanelRow(
        id: 'presetAudioLanguage',
        title: T.text('presetAudioLanguage'),
        kind: ChoiceRow(
          [T.text('presetGameDefault'), for (final language in languages) language.$2],
          languageIndex < 0 ? 0 : languageIndex,
          (index) => setGamePresets(presets.copyWith(audioLanguage: () => index == 0 ? null : languages[index - 1].$1)),
        ),
      ),
      if (!presets.isEmpty)
        PanelRow(id: 'presetsReset', title: T.text('presetsReset'), kind: ActionRow(() => setGamePresets(const GamePresets()))),
    ];
  }

  List<Game> games = [];
  int selected = 0;
  int libraryIndex = 0;
  HomeFocus focus = HomeFocus.tiles;
  Layer? overlay;
  bool scanning = false;

  /// The panel row the keyboard is on, and in the settings, the category.
  int panelRow = 0;
  int panelCategory = 0;

  /// With a controller in the settings: the focus is on the sections' column (← from a row),
  /// where ↑ and ↓ change the section and → or ✕ go back into its rows.
  bool panelSections = false;

  /// With a controller: the choice or stepper row whose value ← and → change now (✕ on it);
  /// outside it they never change a value. Null while none is.
  String? editingValue;

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
        if (Screenshots.isClip(galleryShots[galleryIndex.clamp(0, count - 1)])) {
          return openClip(galleryShots[galleryIndex.clamp(0, count - 1)]);
        }
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
    if (Screenshots.isClip(galleryShots[index])) {
      galleryIndex = index;
      return openClip(galleryShots[index]);
    }
    galleryIndex = index;
    galleryViewing = true;
    sounds.play(Cue.select);
    _changed();
  }

  /// A clip from the gallery, in the system's video player.
  void openClip(String path) {
    sounds.play(Cue.select);
    services.openUrl?.call(Uri.file(path));
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

  /// A short message at the bottom of the screen, with a trophy level's badge before it when
  /// it says one was reached.
  String? toast;
  LevelBadge? toastLevel;

  /// A game's icon before the words (a new game).
  String? toastIcon;

  /// A notice on the desktop while the launcher is behind other windows.
  void Function(String title, String body) desktopNotify = (title, body) =>
      DesktopNotice.show(title, body, urgent: false);
  Timer? _toastTimer;

  RemoteServer? remote;
  ServiceAdvertiser? _advertiser;
  AdbTunnel? _adb;
  PairingRequest? pairing;
  String? phoneConnecting;
  double? phoneLatency;
  String? remoteError;
  RemoteMessage? _toldLibrary;

  LookStyle get look => LookStyle.fromIndex(preferences.theme);

  /// Glass gave up its transparency: the GPU took too long to draw it (RasterWatch), this run or
  /// an earlier one (kept as Preferences.glassTooSlow).
  late bool glassFallback = preferences.glassTooSlow;

  /// Glass surfaces drawn solid: asked for, the GPU too slow for the blur, or Glass
  /// Transparency at 0 % on a window that could let the desktop through.
  bool get solidGlass =>
      preferences.reduceTransparency ||
      glassFallback ||
      (backdrop.kind.seeThrough && preferences.glassTransparency == 0);

  WindowBackdrop get backdrop => services.backdrop ?? const NoBackdrop();

  /// Glass's window: see-through to the desktop where the system can, under its tint.
  GlassWindow get glassWindow => GlassWindow.make(
    glass: look == LookStyle.glass,
    solid: solidGlass,
    transparency: preferences.glassTransparency,
    kind: backdrop.kind,
  );

  bool? _backdropApplied;
  Timer? _backdropRetry;

  /// Puts the window's backdrop in step with the look: called after every change. Before the
  /// window first shows it cannot be found, so it is tried again a little later.
  void applyBackdrop() {
    final seeThrough = glassWindow.seeThrough;
    if (_backdropApplied == seeThrough || backdrop.kind == BackdropKind.none) return;
    _backdropRetry?.cancel();
    if (backdrop.apply(seeThrough: seeThrough)) {
      _backdropApplied = seeThrough;
    } else {
      _backdropRetry = Timer(const Duration(milliseconds: 250), applyBackdrop);
    }
  }

  /// The GPU fell behind drawing Glass: its surfaces turn solid, once said in a toast, and stay
  /// solid at the next starts too (picking Glass again in Settings tries once more).
  void glassTooSlow() {
    if (glassFallback || look != LookStyle.glass) return;
    glassFallback = true;
    preferences.glassTooSlow = true;
    if (persist) preferences.save(paths.preferencesFile);
    if (!preferences.reduceTransparency) show(T.text('glassFallback'));
    notifyListeners();
  }

  /// PS/Guide as a toggle between the game and the launcher (one press, one switch).
  final GuideSwitch _guide = GuideSwitch();

  /// Whether the launcher was in front at the last look ([checkFront]): the desktop's word
  /// where it has one (Windows, X11), Flutter's focus otherwise. Not in front, the launcher
  /// rests: no animation, no frame drawn, the GPU left to the game.
  bool get resting => !_shownInFront;
  bool _shownInFront = true;

  /// Looks again whether the launcher's window is in front (the shell asks a few times a
  /// second: Flutter's own focus report does not change on Windows when a game takes over).
  void checkFront() {
    final front = launcherInFront;
    if (front == _shownInFront) return;
    _shownInFront = front;
    if (!front) {
      _gate?.close();
      haptics.launcherInFront = false;
    }
    notifyListeners();
  }

  /// For PS/Guide, which window is in front now: the desktop's answer, which changes the moment
  /// the window does (Flutter's focus can lag behind it, or not change at all on Windows).
  bool get _frontForGuide {
    if (steamLaunch.gameMode && running == null && starting == null) return true;
    return desktop.launcherFocused() ?? active;
  }

  /// The game back in front, the launcher behind it.
  Future<void> _showGame(RunningGame run) async {
    final shown = await desktop.focusGame(run.pid);
    _padLog?.call('PS: game ${shown ? 'in front' : 'could not be brought in front'}');
    checkFront();
  }

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
    _prepareWhenChanged();
  }

  void savePreferences() {
    if (persist) preferences.save(paths.preferencesFile);
    _applyPadPreferences();
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
    if (folder != _scannedFolder) {
      // A new games folder: what its first scan finds is not new.
      _tracker.reset();
      _scannedFolder = folder;
    }
    _takeScan(folder, GameLibrary.survey(folder).games);
  }

  /// The watcher's scans: nothing is read again when the library is the same.
  List<String> _watchedScan(String folder) {
    if (_disposed || root != folder) return const [];
    final survey = GameLibrary.survey(folder);
    if (folder != _scannedFolder || !GameLibrary.sameListing(games, survey.games)) {
      if (folder != _scannedFolder) {
        _tracker.reset();
        _scannedFolder = folder;
      }
      _takeScan(folder, survey.games);
    }
    return survey.incomplete;
  }

  /// A scan's games: the records and trophies read again, the selection kept on the game it
  /// was on, and the games not seen before announced. An unlock going on is left as it is: its
  /// record is written only when it is done.
  void _takeScan(String folder, List<Game> found) {
    final previous = selectedGame?.id;
    final focusedInLibrary = libraryIndex >= 0 && libraryIndex < games.length ? games[libraryIndex].id : null;
    _forgetDiskFacts();
    games = found;
    records.clear();
    trophies.clear();
    for (final game in games) {
      final installed = Installer.installedFolder(game, folder);
      final record = Installer.record(installed, system: system);
      if (record != null) records[game.id] = record;
      _loadTrophies(game);
    }
    final index = games.indexWhere((game) => game.id == previous);
    selected = index >= 0 ? index : selected.clamp(0, games.isEmpty ? 0 : games.length - 1);
    final libraryAt = games.indexWhere((game) => game.id == focusedInLibrary);
    libraryIndex = libraryAt >= 0 ? libraryAt : libraryIndex.clamp(0, games.isEmpty ? 0 : games.length - 1);
    final added = _tracker.update(found);
    if (added.isNotEmpty) _announceNewGames(added);
    _changed();
  }

  /// "New game: [name]" (or "3 new games") with the select sound; the game is selected when the
  /// home screen shows, and the desktop says it too while the launcher is behind other windows.
  void _announceNewGames(List<Game> added) {
    if (!preferences.onboarded) return;
    final name = added.first.nameFor([T.language.code]);
    final prepared = _prepareNewGames(added);
    final text = newGameText(
      added.length == 1 ? [name] : [for (final game in added) game.name],
      preparing: prepared.preparing,
      waiting: prepared.waiting,
      skipped: prepared.skipped,
    );
    if (overlay == null && running == null && starting == null) {
      final index = games.indexOf(added.first);
      if (index >= 0) {
        selected = index;
        focus = HomeFocus.tiles;
        measureSelected();
      }
    }
    show(text, icon: added.length == 1 ? added.first.icon : null);
    sounds.play(Cue.select);
    if (!active) {
      final names = added.take(3).map((game) => game.nameFor([T.language.code])).join(', ');
      desktopNotify(text, added.length == 1 ? T.text('newGameDetail') : (added.length > 3 ? '$names…' : names));
    }
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

  LibraryWatcher? _library;
  String? _watched;
  final LibraryTracker _tracker = LibraryTracker();
  String? _scannedFolder;

  /// Watches the games folder and everything in it (library_watch.dart): a dump copied in, in a
  /// subfolder too, shows up on its own a moment after its copy is far enough along, and one
  /// removed goes. An unlock going on does not hold the scans back.
  void watchGamesFolder() {
    final folder = root;
    if (folder == _watched) return;
    _library?.stop();
    _library = null;
    _watched = folder;
    if (folder == null) return;
    _library = LibraryWatcher(folder, onScan: () => _watchedScan(folder))..start();
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
    if (current != null) {
      return Installing(
        current.$1,
        current.$2,
        preparing: isPreparing(game),
        paused: isPreparing(game) && prepare.paused,
      );
    }
    if (queue.contains(game.id)) return const Queued();
    final failure = failures[game.id];
    if (failure != null) return Failed(failure);
    final record = records[game.id];
    // An update dumped (or removed) since the unlock needs its executable relinked: unlocking
    // again applies it.
    if (record != null && record.update == game.update?.version) {
      final version = toolkitVersion;
      return Installed(outdated: (version != null && version != record.toolkit) || engine.updateAvailable);
    }
    if (game.executable == ExecutableKind.unreadable) return const Unreadable();
    return Locked(waitingToPrepare: prepare.pending.contains(game.id));
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
      case Installing(preparing: true):
        _promotePreparation(game);
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

  /// The game an unlock waits for an answer about, the size of its files that would be copied,
  /// and the room it lacks on the games folder's drive (see [Layer.copyWarning]); [free] is what
  /// the drive has, null when it does not say.
  ({Game game, int bytes, SpaceShortage? shortage, int? needed, int? free})? copyWarning;

  /// The free bytes where a folder is (FreeSpace.of); replaceable in tests.
  int? Function(String folder) freeSpace = FreeSpace.of;

  /// The power now (Power.current); replaceable in tests.
  PowerState Function() power = Power.current;

  /// Copies smaller than this go ahead without asking (homebrew, demos).
  static const copyWarningFrom = 100000000;

  /// Queues [game]'s unlock; when its files would be copied (the games folder cannot link to the
  /// dump) and [copy] does not say so already, asks first.
  void unlock(Game game, {bool copy = false}) {
    final folder = root;
    if (folder == null) return;
    final kit = toolkit;
    if (kit == null) return show(T.text('noToolkit'));
    // Asked for while it is being prepared: it becomes the user's own.
    if (prepare.active == game.id) return _promotePreparation(game);
    prepare.cancel(game.id);
    final waiting = queue.contains(game.id) || progress.containsKey(game.id);
    if (!waiting) {
      InstallPlan? plan;
      try {
        plan = Installer.plan(
          game,
          folder,
          knownSize: sizes[game.id],
          toolkit: kit,
          resolution: currentSettings(game).resolution,
        );
      } on FileSystemException {
        plan = null; // The install says what is wrong.
      }
      // The room first: a drive that is short says so before anything is written, copy or not.
      final free = plan == null ? null : freeSpace(folder);
      final shortage = plan?.space?.shortage(free: free, folder: folder);
      if (plan != null && (shortage != null || (!copy && plan.copies && plan.bytes >= copyWarningFrom))) {
        if (shortage != null && _playAfterInstall == game.id) _playAfterInstall = null;
        copyWarning = (game: game, bytes: plan.bytes, shortage: shortage, needed: plan.space?.needed, free: free);
        open(Layer.copyWarning, cue: shortage == null ? Cue.select : Cue.back);
        return;
      }
    }
    // Unlocked all the same (another glibc may be at hand), but said first.
    if (engine.glibcWarning(kit) case final String warning) show(warning);
    failures.remove(game.id);
    if (!queue.contains(game.id) && !progress.containsKey(game.id)) {
      queue.add(game.id);
      sounds.play(Cue.select);
    }
    _changed();
    _startNext();
    _stepPrepare();
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
    if (prepare.contains(game.id)) {
      if (prepare.cancel(game.id)) _preparer?.cancel();
      sounds.play(Cue.back);
      return _changed();
    }
    if (queue.remove(game.id)) {
      _changed();
      _stepPrepare();
      return;
    }
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
    _installer = _runUnlock(
      game,
      kit,
      folder,
      background: false,
      done: (error) {
        _installer = null;
        switch (error) {
          case null:
            sounds.play(Cue.unlocked);
            show('${game.name} · ${T.text('ready')}');
            if (_playAfterInstall == id) {
              _playAfterInstall = null;
              unawaited(play(game));
            }
            onUnlocked?.call(id, true);
          case InstallCancelled():
            onUnlocked?.call(id, false);
          case final SpaceShortage shortage:
            _tellShortage(game, shortage);
          default:
            failures[id] = error.toString();
            onUnlocked?.call(id, false);
            show('${T.text('unlockFailed')}: ${game.name}');
        }
      },
    );
    _changed();
  }

  /// Starts unlocking [game]: its progress and its log. [done] runs after the log and the record
  /// are written, with the error when it failed (null when it worked); the queues go on after it.
  Installer _runUnlock(
    Game game,
    Toolkit kit,
    String folder, {
    required bool background,
    required void Function(Object? error) done,
  }) {
    final id = game.id;
    progress[id] = (InstallStep.unwrap, 0);
    final unlockLines = <String>[];
    final unlockLog = GameLog.unlockFile(paths.logs, game.titleId);
    final installer = Installer(
      game: game,
      toolkit: kit,
      root: folder,
      resolution: currentSettings(game).resolution,
      freeSpace: freeSpace,
      onProgress: (step, fraction) {
        progress[id] = (step, fraction);
        notifyListeners();
        _publishActivity();
      },
      onLog: (line) {
        unlockLines.add(line);
        _appendLog(game, line);
      },
    )..background = background;
    unawaited(() async {
      Object? failure;
      try {
        final installed = await installer.run();
        GameLog.writeUnlockLog(unlockLog, unlockLines);
        final record = Installer.record(installed, system: system);
        if (record != null) records[id] = record;
      } on InstallCancelled catch (error) {
        failure = error;
      } on SpaceShortage catch (error) {
        failure = error;
      } on Object catch (error) {
        GameLog.writeUnlockLog(unlockLog, unlockLines, failure: error.toString());
        failure = error;
      }
      progress.remove(id);
      if (_disposed) return;
      done(failure);
      _changed();
      _publishActivity();
      _startNext();
      _stepPrepare();
    }());
    return installer;
  }

  /// The unlock of [game] did not start for want of room: the copy panel says how much is needed
  /// and free, and what to do.
  void _tellShortage(Game game, SpaceShortage shortage) {
    if (_playAfterInstall == game.id) _playAfterInstall = null;
    copyWarning = (game: game, bytes: 0, shortage: shortage, needed: shortage.needed, free: shortage.free);
    open(Layer.copyWarning, cue: Cue.back);
  }

  // Preparing new games.

  /// New games prepared in the background (PrepareQueue) and the unlock doing it.
  final PrepareQueue prepare = PrepareQueue();
  Installer? _preparer;
  Timer? _prepareTimer;
  (bool, bool, bool)? _prepareSignature;

  /// The game being prepared in the background, not yet asked for by the user.
  bool isPreparing(Game game) => prepare.active == game.id && !prepare.promoted;

  PrepareConditions get _prepareConditions => PrepareConditions(
    enabled: preferences.prepareNewGames && preferences.onboarded,
    playing: running != null || starting != null,
    unlocking: _installer != null || queue.isNotEmpty,
    power: power(),
  );

  /// After any change: when a game started or ended, an unlock began or finished, or the setting
  /// changed, the queue takes its steps (soon, not in the middle of the change).
  void _prepareWhenChanged() {
    if (prepare.active == null && prepare.pending.isEmpty) {
      _prepareSignature = null;
      return;
    }
    final signature = (
      preferences.prepareNewGames,
      running != null || starting != null,
      _installer != null || queue.isNotEmpty,
    );
    if (signature == _prepareSignature) return;
    _prepareSignature = signature;
    scheduleMicrotask(() {
      if (!_disposed) _stepPrepare();
    });
  }

  /// Takes the queue's steps until it has nothing more to do now; the skips are told unless
  /// [quiet] (the caller tells them), and returned.
  List<(String, PrepareSkip)> _stepPrepare({bool quiet = false}) {
    final folder = root;
    final kit = toolkit;
    final skipped = <(String, PrepareSkip)>[];
    if (folder == null || kit == null || _disposed) return skipped;
    final conditions = _prepareConditions;
    while (true) {
      final action = prepare.step(
        conditions,
        shortage: (id) {
          final game = games.where((game) => game.id == id).firstOrNull;
          if (game == null) return null;
          try {
            final plan = Installer.plan(
              game,
              folder,
              knownSize: sizes[game.id],
              toolkit: kit,
              resolution: currentSettings(game).resolution,
            );
            return plan.space?.shortage(free: freeSpace(folder), folder: folder);
          } on FileSystemException {
            return null;
          }
        },
      );
      switch (action) {
        case PrepareNone():
          _schedulePrepareCheck();
          if (!quiet) {
            for (final (id, reason) in skipped) {
              _tellSkipped(id, reason);
            }
          }
          _prepareSignature = (
            preferences.prepareNewGames,
            running != null || starting != null,
            _installer != null || queue.isNotEmpty,
          );
          return skipped;
        case PrepareStart(:final id):
          _startPreparing(id, kit, folder);
        case PreparePause():
          _preparer?.pause();
          notifyListeners();
        case PrepareResume():
          _preparer?.resume();
          notifyListeners();
        case PrepareSkipped(:final id, :final reason):
          skipped.add((id, reason));
      }
    }
  }

  /// While games wait or one is being prepared, the power is looked at again now and then.
  void _schedulePrepareCheck() {
    final waiting = prepare.pending.isNotEmpty || prepare.active != null;
    if (!waiting) {
      _prepareTimer?.cancel();
      _prepareTimer = null;
      return;
    }
    _prepareTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _stepPrepare());
  }

  void _startPreparing(String id, Toolkit kit, String folder) {
    final game = games.where((game) => game.id == id).firstOrNull;
    if (game == null || stateOf(game) is! Locked) {
      prepare.finished(id);
      return;
    }
    _preparer = _runUnlock(
      game,
      kit,
      folder,
      background: true,
      done: (error) {
        final promoted = prepare.promoted;
        _preparer = null;
        prepare.finished(id);
        switch (error) {
          case null:
            sounds.play(Cue.unlocked);
            final text = T.format('readyToPlay', [game.name]);
            show(text, icon: game.icon);
            if (!active && running == null && starting == null) desktopNotify(text, T.text('readyToPlayDetail'));
            if (promoted && _playAfterInstall == id) {
              _playAfterInstall = null;
              unawaited(play(game));
            }
          case InstallCancelled():
            if (_playAfterInstall == id) _playAfterInstall = null;
          case final SpaceShortage shortage:
            // The room went while it waited.
            promoted ? _tellShortage(game, shortage) : _tellSkipped(id, SpaceShort(shortage));
          default:
            if (_playAfterInstall == id) _playAfterInstall = null;
            failures[id] = error.toString();
            show('${T.text('unlockFailed')}: ${game.name}');
        }
      },
    );
    notifyListeners();
  }

  /// Play on a game being prepared: it no longer waits for the user's other unlocks, runs at
  /// normal priority where the system lets it, and starts when it is ready.
  void _promotePreparation(Game game) {
    prepare.promote(game.id);
    _preparer?.background = false;
    _playAfterInstall = game.id;
    sounds.play(Cue.select);
    show(T.format('startsWhenReady', [game.name]), icon: game.icon);
    _stepPrepare();
    _changed();
  }

  void _tellSkipped(String id, PrepareSkip reason) {
    final game = games.where((game) => game.id == id).firstOrNull;
    if (game == null) return;
    switch (reason) {
      case BatteryLow():
        show(T.format('notPreparedBattery', [game.name]), icon: game.icon);
      case SpaceShort(:final shortage):
        show(
          T.format('notPreparedSpace', [game.name, byteText(shortage.needed), byteText(shortage.free)]),
          icon: game.icon,
        );
    }
  }

  /// New games from a scan: the locked ones go to the background queue, and what happens to the
  /// first is returned for the "New game" notice.
  ({bool preparing, bool waiting, PrepareSkip? skipped}) _prepareNewGames(List<Game> added) {
    const nothing = (preparing: false, waiting: false, skipped: null);
    if (!preferences.prepareNewGames || toolkit == null) return nothing;
    final locked = added.where((game) => stateOf(game) is Locked).toList();
    if (locked.isEmpty) return nothing;
    prepare.add(locked.map((game) => game.id));
    final skips = _stepPrepare(quiet: true);
    final first = locked.first.id;
    for (final (id, reason) in skips) {
      if (id == first) return (preparing: false, waiting: false, skipped: reason);
    }
    return (preparing: prepare.active == first, waiting: prepare.pending.contains(first), skipped: null);
  }

  /// "New game: [name]", with what happens to it when it is prepared in the background.
  static String newGameText(List<String> names, {bool preparing = false, bool waiting = false, PrepareSkip? skipped}) {
    final one = names.length == 1;
    switch (skipped) {
      case BatteryLow():
        return T.format('newGameNotPreparedBattery', [names.first]);
      case SpaceShort():
        return T.format('newGameNotPreparedSpace', [names.first]);
      case null:
        break;
    }
    if (preparing) {
      return one ? T.format('newGamePreparing', [names.first]) : T.format('newGamesPreparing', [names.length]);
    }
    if (waiting) {
      return one ? T.format('newGameWaiting', [names.first]) : T.format('newGamesWaiting', [names.length]);
    }
    return one ? T.format('newGame', [names.first]) : T.format('newGames', [names.length]);
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

  /// Plays [game]; [trace] turns detailed logging on for this start only.
  Future<void> play(Game game, {bool trace = false}) async {
    final folder = root;
    if (folder == null || starting != null || running != null) return;
    // The profile's own saves and trophies in the game's folder before anything reads them.
    activateProfileSaves(game);
    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) || starting != null || running != null) return;
    var settings = currentSettings(game);
    // Settings › Controllers › Stick Dead Zone, for a game that set none of its own.
    if (preferences.stickDeadzone > 0) {
      settings = settings.copyWith(tuning: StickDeadzone.tuning(settings.tuning, preferences.stickDeadzone));
    }
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
    // A game linked to its dump cannot start once the dump moved: said instead of a crash.
    if (await Installer.brokenLink(Installer.installedFolder(game, folder)) != null) {
      starting = null;
      sounds.play(Cue.back);
      show(T.text('dumpMoved'));
      return;
    }
    preferences.lastPlayed[game.id] = DateTime.now().toIso8601String();
    savePreferences();
    final logFile = paths.logFile(game.titleId);
    final traced = crash.traced(settings, once: trace);
    // A log grown too big is set aside before the font watch reads where it ends.
    GameLog.rollForStart(logFile);
    try {
      // A game in Japanese, Korean or Chinese waits for those fonts; every game gets the folder
      // the fonts are put together in.
      final systemFonts = await fonts.prepare(game, settings.language ?? T.language.consoleLanguage);
      // Settings › AnyTogether › Online play: the loopback bridge the engine connects to
      // (ANYPS5_ONLINE, ANYPS5_ONLINE_SECRET) and the title's observation log; nothing when off.
      final online = await together.onlineEnvironment(game);
      final environment = {
        ...settings.environment(
          launcherLanguage: T.language.consoleLanguage,
          inputFile: written ? inputFile : null,
          screenshots: paths.pictures,
          fonts: systemFonts,
          shaderCacheFolder: paths.shaderCache(game.slug),
          trace: traced,
        ),
        ...?remote?.bridgeEnvironment,
        // The update and add-ons dumped beside the game.
        ...game.addonEnvironment,
        // Settings › Game Presets, for the games that ask the console for them.
        ...gamePresets.environment,
        // The engine's online bridge reads the AnyTogether game session there.
        if (together.signedIn) 'ANYPS5_TOGETHER_SESSION': together.hub.games.bridgeFile,
        ...online,
      };
      fonts.watch(game, logFile);
      final run = await GameProcess.start(
        installed: Installer.installedFolder(game, folder),
        environment: environment,
        logFile: logFile,
        system: system,
        traced: traced,
        // The controllers at the start, in the log a crash report reads.
        notes: [for (final line in controllers.reportLines) '[anyps5-launcher] controllers: $line'],
      );
      starting = null;
      running = (game, run);
      _stopped = false;
      unawaited(_startReplay());
      crash.started(game, traced: traced);
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
      unawaited(together.onlineGameEnded());
      fonts.ended();
      together.recordPlay(game, began, DateTime.now(), exit: _stopped ? 'killed' : (code == 0 ? 'normal' : 'crashed'));
      _trophyWatch?.cancel();
      _loadTrophies(game);
      if (running?.$1 == game) running = null;
      unawaited(_stopReplay());
      // The quick menu and the question go with the game.
      if (overlay == Layer.quickMenu || overlay == Layer.closeGame) overlay = null;
      updates.gameEnded();
      together.gameChanged();
      crash.ended(game, code, stopped: _stopped);
      _changed();
      // Started from a Steam shortcut of the game: the launcher goes with it, so Steam sees
      // the game end. A crash keeps it open on its report.
      if (_quitAfterGame == game.id) {
        _quitAfterGame = null;
        if (code == 0 || _stopped) (services.quit ?? exit)(0);
      }
    } on Object catch (error) {
      starting = null;
      fonts.ended();
      unawaited(together.onlineGameEnded());
      vibrate(HapticCue.error);
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
      // Heard over the game too; felt only with the launcher in front.
      sounds.play(Cue.unlocked, overGame: true);
      vibrate(HapticCue.trophy);
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
      final render =
          services.renderTrophyCard ??
          (trophy, scale) => TrophyCard.render(trophy, scale: scale, glass: look == LookStyle.glass);
      final card = await render(trophy, scale);
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

  /// Asks the game playing to close as its window would (a family limit): the launcher closed
  /// it, so no crash report follows.
  Future<void> closeGame() async {
    if (running == null) return;
    _stopped = true;
    await running!.$2.close();
  }

  /// Ends the game playing at once (a family limit after its grace).
  void killGame() {
    if (running != null) _stopped = true;
    running?.$2.kill();
  }

  // Messages.

  void show(String message, {LevelBadge? level, String? icon}) {
    toast = message;
    toastLevel = level;
    toastIcon = icon;
    _toastTimer?.cancel();
    _backdropRetry?.cancel();
    _toastTimer = Timer(Duration(seconds: level == null ? 4 : 5), () {
      toast = null;
      toastLevel = null;
      toastIcon = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // Navigation.

  /// Opens a layer with the select sound, or [cue] (going back to the panel before).
  void open(Layer next, {Cue cue = Cue.select}) {
    sounds.play(cue);
    if (overlay != next) together.askingRow = null;
    overlay = next;
    panelRow = 0;
    panelCategory = 0;
    panelSections = false;
    editingValue = null;
    if (shortcutCapture != null) {
      shortcutCapture = null;
      _captureTimer?.cancel();
    }
    capturing = null;
    if (next == Layer.library) libraryIndex = selected;
    if (next == Layer.gameSettings) _gameFacts.clear();
    if (next == Layer.log) shownLog = selectedGame == null ? '' : logText(selectedGame!);
    if (next == Layer.trophies) {
      trophyIndex = 0;
      revealedTrophies = {};
    }
    if (next == Layer.trophies || next == Layer.gallery) _loadShots();
    // Friends' private picture links run out (6 to 12 hours): the list is read again.
    if ((next == Layer.friends || next == Layer.party || next == Layer.profile) &&
        together.signedIn &&
        together.hub.friends.identities.learnedAt != null &&
        together.hub.friends.identities.stale()) {
      unawaited(together.hub.friends.refresh().catchError((Object _) {}));
    }
    if (next == Layer.gallery) {
      galleryIndex = 0;
      galleryViewing = false;
    }
    _skipToFocusable();
    _changed();
  }

  /// AnyTogether answered client_too_old: Update Required over Home (a toast over a game or
  /// another screen), and a quiet look for the release that replaces this one.
  void showUpdateRequired(ClientTooOld old) {
    unawaited(updates.check(quiet: true));
    if (overlay == null && running == null && starting == null) {
      open(Layer.updateRequired);
      panelRow = 1;
      _changed();
    } else {
      show(T.format('requiredToast', [old.minimum]));
    }
  }

  void closeOverlay() {
    overlay = null;
    panelSections = false;
    editingValue = null;
    shortcutCapture = null;
    together.askingRow = null;
    capturing = null;
    revealedTrophies = {};
    sounds.play(Cue.back);
    _changed();
  }

  /// The game of a Steam shortcut (--play <title ID>), started once the library is read. With
  /// [quitAfter] (Steam started the launcher) it closes when the game ends normally.
  Future<void> playAtLaunch(String titleId, {bool quitAfter = false}) async {
    final wanted = titleId.toUpperCase();
    final index = games.indexWhere((game) => game.titleId.toUpperCase() == wanted);
    if (index < 0) return show(T.format('steamPlayMissing', [titleId]));
    final game = games[index];
    select(index);
    if (!records.containsKey(game.id)) return show(T.format('steamPlayLocked', [game.name]));
    if (quitAfter) _quitAfterGame = game.id;
    await play(game);
    if (running?.$1 != game && _quitAfterGame == game.id) _quitAfterGame = null;
  }

  String? _quitAfterGame;

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
    // At start a profile is picked first: PS waits.
    if (overlay == Layer.profilePicker && profileFlow.atLaunch && command == Command.home) return sounds.play(Cue.bump);
    if (command == Command.home) {
      // PS/Guide: from the game to the launcher and back; behind another window, to the front.
      final run = running?.$2;
      switch (_guide.press(
        now: feelNow,
        gameRunning: run != null,
        launcherInFront: _frontForGuide,
        layerOpen: overlay != null,
      )) {
        case GuideAction.showGame:
          // The quick menu (or Close Game?) goes with the launcher.
          if (overlay == Layer.quickMenu || overlay == Layer.closeGame) {
            overlay = null;
            _changed();
          }
          unawaited(_showGame(run!));
        case GuideAction.showLauncher:
          // From the game: the launcher with the quick menu over it, the game paused first.
          unawaited(run != null ? openQuickMenu() : desktop.raiseLauncher());
        case GuideAction.closeLayer:
          closeOverlay();
        case GuideAction.none:
          break;
      }
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
      case Layer.crashReport:
        crash.command(command);
        return;
      case Layer.browserPlay:
        browserPlay.command(command);
        return;
      case Layer.controllerTest:
        // Only the keyboard and the mouse get here (the pads' buttons are being tried).
        if (command == Command.back) closeControllerTest();
        return;
      case Layer.gallery:
        _galleryCommand(command);
        return;
      case Layer.trophies:
        final count = trophies[selectedGame?.id]?.trophies.length ?? 0;
        switch (command) {
          case Command.up || Command.down:
            final next = (trophyIndex + (command == Command.down ? 1 : -1)).clamp(0, count == 0 ? 0 : count - 1);
            if (next == trophyIndex) return;
            sounds.play(Cue.move);
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
      case Layer.compare:
        together.compareCommand(command);
        return;
      case Layer.quickMenu || Layer.closeGame when command == Command.back || command == Command.options:
        resumeGame();
        return;
      case Layer.profilePicker:
        pickerCommand(command);
        return;
      case Layer.addProfile:
        modeChoiceCommand(command);
        return;
      case Layer.signIn:
        _signInCommand(command);
        return;
      case Layer.friendOptions when command == Command.back || command == Command.options:
        // A question asked in place (together_ask.dart) is answered Cancel first.
        if (!together.cancelAsk()) open(Layer.friends, cue: Cue.back);
        return;
      case Layer.settings ||
          Layer.gameSettings ||
          Layer.confirmUninstall ||
          Layer.copyWarning ||
          Layer.updateChoice ||
          Layer.updateRequired ||
          Layer.friends ||
          Layer.friendOptions ||
          Layer.party ||
          Layer.family ||
          Layer.quickMenu ||
          Layer.closeGame ||
          Layer.homeMenu ||
          Layer.profileMenu:
        _panelCommand(command);
        return;
      case null:
        break;
    }
    final game = selectedGame;
    // With no games the top bar still works: Up reaches it, and Select on the empty shelf picks
    // the games folder.
    if (game == null && (focus.area == 'tiles' || focus.area == 'actions')) {
      if (command == Command.select) unawaited(chooseGamesFolder());
      if (command == Command.up) _moveFocus(const HomeFocus.top(1));
      return;
    }
    // The notice went (Later, or the update went in): its focus goes to the top bar.
    if (focus.isNotice && !updates.showsNotice) focus = const HomeFocus.top(0);
    if (focus == const HomeFocus.notice(1) && updates.restartAfterGame) focus = const HomeFocus.notice(0);
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
        primaryAction(game!);
      case ('top', Command.left) when focus.index == 0 && updates.showsNotice:
        _moveFocus(HomeFocus.notice(updates.restartAfterGame ? 0 : 1));
      case ('top', Command.left):
        _moveFocus(HomeFocus.top((focus.index - 1).clamp(0, topButtons - 1)));
      case ('notice', Command.left):
        _moveFocus(HomeFocus.notice(focus.index > 0 ? focus.index - 1 : 0));
      case ('notice', Command.right):
        _moveFocus(focus.index == 1 || updates.restartAfterGame ? const HomeFocus.top(0) : const HomeFocus.notice(1));
      case ('notice', Command.down) || ('notice', Command.back):
        _moveFocus(HomeFocus.tiles);
      case ('notice', Command.select) when focus.index == 0:
        updates.restartAfterGame ? updates.cancelRestart() : unawaited(updates.restartNow());
      case ('notice', Command.select):
        updates.later();
        _moveFocus(const HomeFocus.top(0));
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
          primaryAction(game!);
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

  /// The sign-in screen: Back gives it up (a question asked in place answers Cancel first).
  void _signInCommand(Command command) {
    if (command == Command.back && editingRow == null) {
      if (!together.cancelAsk()) unawaited(cancelSignIn());
      return;
    }
    _panelCommand(command);
  }

  // PS: the quick menu, Close Game?, the home menu.

  /// The key the game's Options is on (its controls), for pausing it; null when it has none.
  String? optionsKey(Game game) {
    final sources = Controls.sources(PadAction.options, currentSettings(game).controls ?? const {});
    for (final source in sources) {
      if (source.startsWith('KEY:')) return source.substring(4);
    }
    return null;
  }

  /// The quick menu over the game playing: the game's Options pressed first (Settings ›
  /// Behaviour › Pause Game When Opening the Menu) while it is still in front, then the
  /// launcher in front with Resume, Game Settings and Close Game.
  Future<void> openQuickMenu() async {
    final playing = running;
    if (playing == null || !preferences.onboarded) return;
    final (game, run) = playing;
    final front = _frontForGuide;
    quickMenuPaused = false;
    if (!front && preferences.pauseOnMenu) {
      // An engine that takes presses: Options held on player 1's pad through the remote pad
      // bridge, whoever drives it (sent three times, 40 ms apart; the menu ~210 ms after the
      // first). Otherwise the key the game's Options is on, typed into its window.
      final server = remote;
      if (server != null && server.gameTakesPresses) {
        final sent = server.pressButtons(RemotePacket.options);
        await Future<void>.delayed(const Duration(milliseconds: 210));
        quickMenuPaused = await sent;
        _padLog?.call('quick menu: ${quickMenuPaused ? 'Options pressed through the bridge' : 'no bridge took it'}');
      } else {
        final key = optionsKey(game);
        final paused = key != null && await desktop.pressKey(run.pid, key);
        quickMenuPaused = paused;
        _padLog?.call('quick menu: ${paused ? 'pressed $key in the game' : 'could not pause the game'}');
      }
    }
    if (running?.$2 != run) return;
    final index = games.indexOf(game);
    if (index >= 0) selected = index;
    open(Layer.quickMenu);
    if (!front) await desktop.raiseLauncher();
  }

  /// Whether the game under the quick menu was sent its Options (paused, as far as the launcher
  /// can tell).
  bool quickMenuPaused = false;

  /// PS held: Close Game? over a game in front; the home menu in the launcher.
  void homeHeld() {
    if (!preferences.onboarded) return;
    if (overlay == Layer.profilePicker && profileFlow.atLaunch) return;
    final front = _frontForGuide;
    if (running != null && !front) {
      open(Layer.closeGame);
      unawaited(desktop.raiseLauncher());
      return;
    }
    if (overlay == Layer.controllerTest) return;
    open(Layer.homeMenu);
    if (!front) unawaited(desktop.raiseLauncher());
  }

  /// Back to the game from the quick menu (or Close Game?): the game in front again. Its pause
  /// menu, if the Options press opened one, stays for the player.
  void resumeGame() {
    overlay = null;
    sounds.play(Cue.back);
    _changed();
    if (running?.$2 case final RunningGame run) unawaited(_showGame(run));
  }

  /// Close Game from the quick menu or the question.
  void closeRunningGame() {
    overlay = null;
    sounds.play(Cue.select);
    stopGame();
    _changed();
  }

  /// Quit AnyPS5 (the home menu): the game playing closes with it.
  void quitLauncher() {
    stopGame();
    unawaited(_stopReplay());
    (services.quit ?? exit)(0);
  }

  // Captures: Share, the replay buffer, screenshots.

  ReplayBuffer? _replay;

  /// Whether the replay buffer is recording now.
  bool get replayRecording => _replay?.running ?? false;

  ReplayBuffer? _defaultReplay(int seconds) {
    final environment = services.environment ?? Platform.environment;
    final ffmpeg = replayFfmpeg;
    if (ffmpeg == null || !ReplayBuffer.supported(system, environment)) return null;
    return ReplayBuffer(
      ffmpeg: ffmpeg,
      folder: p.join(Directory.systemTemp.path, 'anyps5-replay-$pid'),
      seconds: seconds,
      system: system,
      environment: environment,
    );
  }

  /// ffmpeg for the replay buffer: beside the launcher or on the PATH.
  late final String? replayFfmpeg = ReplayBuffer.locate(
    system: system,
    environment: services.environment ?? Platform.environment,
    launcherFolder: p.dirname(Platform.resolvedExecutable),
  );

  /// Why the replay buffer cannot record here (no ffmpeg, Wayland), or null when it can.
  String? get replayUnavailable {
    if (services.replay != null) return null;
    if (!ReplayBuffer.supported(system, services.environment ?? Platform.environment)) {
      return T.text('replayNoScreen');
    }
    return replayFfmpeg == null ? T.text('replayNoFfmpeg') : null;
  }

  Future<void> _startReplay() async {
    if (!preferences.replayBuffer || _replay != null || running == null) return;
    final buffer = (services.replay ?? _defaultReplay)(preferences.replaySeconds);
    if (buffer == null) return;
    _replay = buffer;
    if (!await buffer.start()) {
      _replay = null;
      show(T.text('replayFailed'));
    }
    notifyListeners();
  }

  Future<void> _stopReplay() async {
    final buffer = _replay;
    _replay = null;
    await buffer?.stop();
  }

  /// A capture said: the toast, and over the game a desktop notice.
  Future<void> _captureSaid(String text) async {
    show(text);
    if (launcherInFront) return;
    if (!await desktop.notify('AnyPS5', text)) desktopNotify('AnyPS5', text);
  }

  /// The game's window now, into its gallery (Share held); the picture's path.
  Future<String?> takeScreenshot() async {
    final playing = running;
    if (playing == null) return null;
    final (game, run) = playing;
    final frame = await desktop.captureGame(run.pid);
    if (frame == null) {
      unawaited(_captureSaid(T.text('screenshotFailed')));
      return null;
    }
    final path = Screenshots.shotPath(paths.pictures, game, DateTime.now());
    try {
      await Isolate.run(() {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(PngEncoder.rgba(frame.width, frame.height, frame.pixels));
      });
    } on Object {
      unawaited(_captureSaid(T.text('screenshotFailed')));
      return null;
    }
    sounds.play(Cue.unlocked);
    unawaited(_captureSaid(T.text('screenshotSaved')));
    return path;
  }

  /// Share: the last seconds from the replay buffer as a clip in the game's gallery; with the
  /// buffer off, a screenshot.
  Future<String?> saveClip() async {
    final playing = running;
    if (playing == null) return null;
    final buffer = _replay;
    if (buffer == null || !buffer.running) return takeScreenshot();
    final saved = await buffer.save(Screenshots.clipPath(paths.pictures, playing.$1, DateTime.now()));
    if (saved != null) sounds.play(Cue.unlocked);
    unawaited(
      _captureSaid(saved == null ? T.text('clipFailed') : T.format('clipSaved', [replayLengthText(buffer.seconds)])),
    );
    return saved;
  }

  static String replayLengthText(int seconds) =>
      seconds < 60 ? T.format('replaySeconds', [seconds]) : T.format('replayMinutes', [seconds ~/ 60]);

  // The launcher's window.

  /// Whether the launcher is full screen (Settings › Appearance › Full Screen; F11).
  bool get launcherFullscreen => preferences.launcherFullscreen ?? true;

  Future<void> toggleFullscreen() => setLauncherFullscreen(!launcherFullscreen);

  Future<void> setLauncherFullscreen(bool on) async {
    preferences.launcherFullscreen = on;
    savePreferences();
    await services.window?.setFullscreen(on);
  }

  /// At launch: full screen the first time, then as the user left it.
  Future<void> applyLauncherWindow() async => services.window?.setFullscreen(launcherFullscreen);

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
      case Layer.copyWarning:
        final warning = copyWarning;
        if (warning == null) return const [];
        return [
          PanelCategory(
            id: 'copy',
            title: warning.shortage == null ? T.text('copyWarningTitle') : T.text('noSpaceTitle'),
            rows: _copyWarningRows(warning),
          ),
        ];
      case Layer.friends:
        return [PanelCategory(id: 'friends', title: T.text('friendsTitle'), rows: together.friendRows())];
      case Layer.party:
        return [PanelCategory(id: 'party', title: T.text('partyTitle'), rows: together.partyRows())];
      case Layer.family:
        return [PanelCategory(id: 'family', title: T.text('familyTitle'), rows: together.family.rows())];
      case Layer.crashReport:
        return [PanelCategory(id: 'report', title: T.text('reportKicker'), rows: crash.rows())];
      case Layer.friendOptions:
        return [
          PanelCategory(
            id: 'friend',
            title: together.chosen?.person.displayName ?? T.text('friendsTitle'),
            rows: together.friendOptionRows(),
          ),
        ];
      case Layer.updateRequired when together.account.tooOld != null:
        return [
          PanelCategory(
            id: 'updateRequired',
            title: T.text('requiredTitle'),
            rows: updates.requiredRows(together.account.tooOld!),
          ),
        ];
      case Layer.quickMenu when running != null:
        return [
          PanelCategory(
            id: 'quickMenu',
            title: running!.$1.name,
            rows: [
              PanelRow(id: 'resume', title: T.text('quickResume'), kind: ActionRow(resumeGame)),
              PanelRow(
                id: 'gameSettings',
                title: T.text('gameSettings'),
                kind: ActionRow(() => open(Layer.gameSettings)),
              ),
              PanelRow(
                id: 'closeGame',
                title: T.text('quickCloseGame'),
                // Asked first, as PS held asks.
                kind: ActionRow(() => open(Layer.closeGame), destructive: true),
              ),
            ],
          ),
        ];
      case Layer.closeGame when running != null:
        return [
          PanelCategory(
            id: 'closeGame',
            title: T.format('closeGameTitle', [running!.$1.name]),
            rows: [
              PanelRow(
                id: 'confirmClose',
                title: T.text('quickCloseGame'),
                detail: T.text('closeGameDetail'),
                kind: ActionRow(closeRunningGame, destructive: true),
              ),
              PanelRow(id: 'cancel', title: T.text('cancel'), kind: ActionRow(resumeGame)),
            ],
          ),
        ];
      case Layer.profileMenu:
        return [
          PanelCategory(
            id: 'profileMenu',
            title: currentProfile?.name ?? T.text('profileMenuTitle'),
            rows: profileMenuRows(),
          ),
        ];
      case Layer.signIn:
        return [
          PanelCategory(
            id: 'signIn',
            title: T.text(switch (profileFlow.origin) {
              ProfileOrigin.firstStart || ProfileOrigin.adding => 'profileSignInNew',
              ProfileOrigin.goingOnline => 'profileSignInOnline',
              ProfileOrigin.signingInAgain => 'profileSignInAgain',
            }),
            rows: together.signInRows(),
          ),
        ];
      case Layer.homeMenu:
        return [
          PanelCategory(
            id: 'homeMenu',
            title: 'AnyPS5',
            rows: [
              PanelRow(
                id: 'switchProfile',
                title: T.text('switchProfile'),
                detail: switch (profiles.book.profiles.length - 1) {
                  0 => T.text('profileAddSomeone'),
                  1 => T.text('profileOthersOne'),
                  final others => T.format('profileOthers', [others]),
                },
                // Not while a game plays: it is closed first.
                kind: ActionRow(() => openProfilePicker()),
              ),
              PanelRow(
                id: 'quit',
                title: T.text('quitLauncher'),
                detail: running == null ? null : T.format('quitLauncherGame', [running!.$1.name]),
                kind: ActionRow(quitLauncher, destructive: true),
              ),
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

  /// The copy panel: the room the unlock lacks (when it does), why the game's files would be
  /// copied (when they would), and the ways out.
  List<PanelRow> _copyWarningRows(({Game game, int bytes, SpaceShortage? shortage, int? needed, int? free}) warning) {
    final windows = system == HostSystem.windows;
    final size = byteText(warning.bytes);
    final shortage = warning.shortage;
    final copying = warning.bytes > 0 && (shortage == null || shortage.copying);
    void dismiss() {
      closeOverlay();
      copyWarning = null;
    }

    return [
      if (shortage != null)
        PanelRow(
          id: 'space',
          title: T.format('noSpaceAmount', [byteText(shortage.needed), byteText(shortage.free)]),
          kind: InfoRow(
            '${T.text('noSpaceNothingWritten')}\n${copying ? T.format('noSpaceCopying', [size]) : T.text('noSpaceWhy')}',
          ),
        ),
      if (copying)
        PanelRow(
          id: 'why',
          title: warning.game.name,
          kind: InfoRow(
            T.format(windows ? 'copyWarningWindows' : 'copyWarningLinux', [size]) +
                (shortage == null && warning.needed != null && warning.free != null
                    ? '\n${T.format('copySpace', [byteText(warning.needed!), byteText(warning.free!)])}'
                    : ''),
          ),
        ),
      if (copying)
        PanelRow(
          id: 'sameDrive',
          title: T.text('copyFixFolder'),
          detail: T.text('copyFixFolderDetail'),
          kind: ActionRow(() {
            dismiss();
            unawaited(chooseGamesFolder());
          }),
        )
      else
        PanelRow(
          id: 'otherDrive',
          title: T.text('noSpaceFolder'),
          detail: T.text('noSpaceFolderDetail'),
          kind: ActionRow(() {
            dismiss();
            unawaited(chooseGamesFolder());
          }),
        ),
      if (windows && copying)
        PanelRow(
          id: 'developerMode',
          title: T.text('copyFixDeveloperMode'),
          detail: T.text('copyFixDeveloperModeDetail'),
          kind: ActionRow(() {
            services.openUrl?.call(Uri.parse('ms-settings:developers'));
            dismiss();
            show(T.text('copyFixDeveloperModeThen'));
          }),
        ),
      if (shortage == null)
        PanelRow(
          id: 'copyAnyway',
          title: T.text('copyAnyway'),
          detail: T.format('copyAnywayDetail', [size]),
          kind: ActionRow(() {
            dismiss();
            unlock(warning.game, copy: true);
          }),
        )
      else
        PanelRow(
          id: 'retry',
          title: T.text('noSpaceRetry'),
          detail: T.text('noSpaceRetryDetail'),
          kind: ActionRow(() {
            dismiss();
            unlock(warning.game, copy: true);
          }),
        ),
      PanelRow(
        id: 'cancel',
        title: T.text('cancel'),
        kind: ActionRow(() {
          dismiss();
          if (_playAfterInstall == warning.game.id) _playAfterInstall = null;
        }),
      ),
    ];
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
            kind: ChoiceRow([for (final style in LookStyle.values) style.title], look.index, (index) {
              preferences
                ..theme = index
                ..accent = null;
              // Glass picked again: its transparency gets another try on this graphics card.
              if (index == LookStyle.glass.index) {
                preferences.glassTooSlow = false;
                glassFallback = false;
              }
              savePreferences();
            }),
          ),
          // Only Glass has transparency to reduce.
          if (look == LookStyle.glass)
            PanelRow(
              id: 'transparency',
              title: T.text('reduceTransparency'),
              detail: T.text('reduceTransparencyDetail'),
              kind: ToggleRow(preferences.reduceTransparency, (value) {
                preferences.reduceTransparency = value;
                savePreferences();
              }),
            ),
          // How much of the desktop shows through Glass's window, where the system can show it.
          if (look == LookStyle.glass && backdrop.kind.seeThrough && !preferences.reduceTransparency)
            PanelRow(
              id: 'glassTransparency',
              title: T.text('glassTransparency'),
              detail: T.text(backdrop.kind.blurs ? 'glassTransparencyDetail' : 'glassTransparencySharp'),
              kind: StepperRow(
                value: preferences.glassTransparency ?? GlassWindow.defaultTransparency,
                min: 0,
                max: 100,
                step: 10,
                format: _percent,
                set: (value) {
                  preferences.glassTransparency = value == GlassWindow.defaultTransparency ? null : value;
                  savePreferences();
                },
              ),
            ),
          PanelRow(
            id: 'accent',
            title: T.text('accent'),
            kind: ChoiceRow([for (final accent in Accent.values) accent.title], accentChoice.index, (index) {
              preferences.accent = Accent.values[index].name;
              savePreferences();
            }),
          ),
          // Over the see-through window the picture is laid only when asked for.
          if (glassWindow.seeThrough)
            PanelRow(
              id: 'glassArtwork',
              title: T.text('glassArtwork'),
              detail: T.text('glassArtworkDetail'),
              kind: ToggleRow(preferences.glassArtwork, (value) {
                preferences.glassArtwork = value;
                savePreferences();
              }),
            )
          else
            PanelRow(
              id: 'artwork',
              title: T.text('gameArtwork'),
              kind: ToggleRow(preferences.gameArtwork, (value) {
                preferences.gameArtwork = value;
                savePreferences();
              }),
            ),
          PanelRow(
            id: 'fullscreen',
            title: T.text('launcherFullscreen'),
            detail: T.format('launcherFullscreenDetail', [
              keyLabel(preferences.shortcuts[LauncherAction.toggleFullscreen].key) ?? '—',
            ]),
            kind: ToggleRow(launcherFullscreen, (value) => unawaited(setLauncherFullscreen(value))),
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
            id: 'prepareNewGames',
            title: T.text('prepareNewGames'),
            detail: T.text('prepareNewGamesDetail'),
            kind: ToggleRow(preferences.prepareNewGames, (value) {
              preferences.prepareNewGames = value;
              savePreferences();
              _stepPrepare();
            }),
          ),
        ],
      ),
      PanelCategory(id: 'engine', title: T.text('engine'), rows: engine.settingsRows()),
      PanelCategory(id: 'fonts', title: T.text('fonts'), rows: fonts.settingsRows()),
      PanelCategory(id: 'profiles', title: T.text('profilesCategory'), rows: profileRows()),
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
          if (preferences.phoneServer) ...browserPlay.settingsRows(),
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
            id: 'vibration',
            title: T.text('controllerVibration'),
            detail: T.text('controllerVibrationDetail'),
            kind: ToggleRow(preferences.controllerVibration, (value) {
              preferences.controllerVibration = value;
              haptics.enabled = value;
              savePreferences();
              // Turned on from the pad: a pulse at once says what it feels like.
              if (value) vibrate(HapticCue.select);
            }),
          ),
          PanelRow(
            id: 'pauseOnMenu',
            title: T.text('pauseOnMenu'),
            detail: T.text('pauseOnMenuDetail'),
            kind: ToggleRow(preferences.pauseOnMenu, (value) {
              preferences.pauseOnMenu = value;
              savePreferences();
            }),
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
      PanelCategory(id: 'steam', title: T.text('steam'), rows: steam.settingsRows()),
      PanelCategory(id: 'controllers', title: T.text('padTitle'), rows: controllers.rows()),
      PanelCategory(id: 'presets', title: T.text('presetsTitle'), rows: _presetRows()),
      PanelCategory(id: 'captures', title: T.text('captures'), rows: _captureRows()),
      PanelCategory(id: 'shortcuts', title: T.text('shortcuts'), rows: _shortcutRows()),
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

  List<PanelRow> _captureRows() {
    final unavailable = replayUnavailable;
    final share = padLabel(preferences.shortcuts[LauncherAction.saveClip].pad) ?? '—';
    final shot = padLabel(preferences.shortcuts[LauncherAction.screenshot].pad) ?? '—';
    return [
      PanelRow(
        id: 'replayBuffer',
        title: T.text('replayBuffer'),
        detail: unavailable ?? T.text('replayBufferDetail'),
        kind: ToggleRow(preferences.replayBuffer && unavailable == null, (value) {
          if (unavailable != null) return show(unavailable);
          preferences.replayBuffer = value;
          savePreferences();
          unawaited(value ? _startReplay() : _stopReplay());
        }),
      ),
      if (preferences.replayBuffer && unavailable == null)
        PanelRow(
          id: 'replayLength',
          title: T.text('replayLength'),
          kind: ChoiceRow(
            [for (final seconds in ReplayBuffer.lengths) replayLengthText(seconds)],
            ReplayBuffer.lengths.indexOf(preferences.replaySeconds).clamp(0, ReplayBuffer.lengths.length - 1),
            (index) {
              preferences.replaySeconds = ReplayBuffer.lengths[index];
              savePreferences();
              // A new length: the buffer starts again with it.
              if (_replay != null) unawaited(_stopReplay().then((_) => _startReplay()));
            },
          ),
        ),
      PanelRow(
        id: 'capturesHow',
        title: T.text('capturesHow'),
        kind: InfoRow(
          T.format(preferences.replayBuffer && unavailable == null ? 'capturesHowClip' : 'capturesHowShot', [
            share,
            shot,
          ]),
        ),
      ),
    ];
  }

  List<PanelRow> _shortcutRows() {
    final map = preferences.shortcuts;
    final conflicted = map.conflicted;
    return [
      for (final action in LauncherAction.values)
        PanelRow(
          id: 'shortcut-${action.name}',
          title: shortcutTitle(action),
          detail: conflicted.contains(action)
              ? T.text('shortcutConflict')
              : shortcutCapture == action
              ? T.text('shortcutWaiting')
              : T.text(action.inGame ? 'shortcutInGame' : 'shortcutInLauncher'),
          kind: ShortcutRow(
            key: keyLabel(map[action].key),
            pad: padLabel(map[action].pad),
            capturing: shortcutCapture == action,
            capture: () => startShortcutCapture(action),
          ),
        ),
      PanelRow(id: 'shortcutsHow', title: T.text('shortcutsHow'), kind: InfoRow(T.text('shortcutsHowDetail'))),
      PanelRow(
        id: 'gameControls',
        title: T.text('shortcutsGameButtons'),
        detail: T.text('shortcutsGameButtonsDetail'),
        kind: ActionRow(() {
          if (selectedGame != null) open(Layer.controls);
        }),
      ),
      PanelRow(
        id: 'shortcutsReset',
        title: T.text('shortcutsReset'),
        kind: ActionRow(() {
          preferences.shortcuts = ShortcutMap();
          savePreferences();
          show(T.text('shortcutsResetDone'));
        }, destructive: true),
      ),
    ];
  }

  /// A key as the launcher writes it: "Ctrl+Alt+F11"; null for none.
  static String? keyLabel(KeyCombo? key) {
    if (key == null) return null;
    final logical = LogicalKeyboardKey.findKeyByKeyId(key.key);
    var name = logical?.keyLabel ?? '';
    if (name.trim().isEmpty) name = logical?.debugName ?? '?';
    if (name.length == 1) name = name.toUpperCase();
    return [if (key.control) 'Ctrl', if (key.alt) 'Alt', if (key.shift) 'Shift', name].join('+');
  }

  /// A controller button as the launcher writes it.
  static String padButtonLabel(PadButton button) => switch (button) {
    PadButton.south => 'Cross',
    PadButton.east => 'Circle',
    PadButton.west => 'Square',
    PadButton.north => 'Triangle',
    PadButton.l1 => 'L1',
    PadButton.r1 => 'R1',
    PadButton.l2 => 'L2',
    PadButton.r2 => 'R2',
    PadButton.l3 => 'L3',
    PadButton.r3 => 'R3',
    PadButton.select => 'View',
    PadButton.start => 'Options',
    PadButton.guide => 'PS',
    PadButton.misc => 'Share',
    PadButton.touchpad => T.text('touchpad'),
    PadButton.dpadUp => '${T.text('dpad')} ↑',
    PadButton.dpadDown => '${T.text('dpad')} ↓',
    PadButton.dpadLeft => '${T.text('dpad')} ←',
    PadButton.dpadRight => '${T.text('dpad')} →',
  };

  /// A chord as the launcher writes it: "View+R1", "Share (hold)"; null for none.
  static String? padLabel(PadChord? chord) {
    if (chord == null) return null;
    final names = [
      for (final button in PadButton.values)
        if (chord.buttons.contains(button)) padButtonLabel(button),
    ].join('+');
    return chord.hold ? T.format('shortcutHeld', [names]) : names;
  }

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
        ..._reportRows(game, settings, change),
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
      ] else ...[
        PanelRow(id: 'log', title: T.text('openLog'), kind: ActionRow(() => open(Layer.log))),
        ..._reportRows(game, settings, change),
      ],
    ];
  }

  /// The last start's crash report, detailed logging, and (installed) one start with it.
  List<PanelRow> _reportRows(Game game, GameSettings settings, void Function(GameSettings) change) => [
    PanelRow(
      id: 'report',
      title: T.text('lastSessionReport'),
      detail: switch (crash.lastSessions[game.titleId]?.diagnosis) {
        final Diagnosis diagnosis => CrashModel.diagnosisText(diagnosis),
        null => T.text('lastSessionReportDetail'),
      },
      kind: ActionRow(() => unawaited(crash.open(game, afterCrash: false))),
    ),
    PanelRow(
      id: 'trace',
      title: T.text('traceTitle'),
      detail: T.text('traceDetail'),
      kind: ToggleRow(settings.trace == true, (value) => change(settings.copyWith(trace: value ? true : null))),
    ),
    if (records.containsKey(game.id))
      PanelRow(
        id: 'playTraced',
        title: T.text('reportPlayTraced'),
        detail: T.text('reportPlayTracedDetail'),
        kind: ActionRow(() {
          closeOverlay();
          unawaited(play(game, trace: true));
        }),
      ),
  ];

  /// Controls › Gyro Aiming, first on a game's Controls page: on or off, and while on its
  /// sensitivity, when it aims, invert and its dead zone (GyroAiming).
  List<PanelRow> _gyroRows(Game game, GameSettings settings) {
    final aim = settings.gyro ?? const GyroAiming();
    void change(GyroAiming changed) =>
        saveSettings(game, settings.copyWith(gyro: changed == const GyroAiming() ? null : changed));
    return [
      PanelRow(
        id: 'gyro',
        title: T.text('gyro'),
        detail: T.text('gyroDetail'),
        kind: ToggleRow(aim.enabled, (value) => change(aim.copyWith(enabled: value))),
      ),
      if (aim.enabled) ...[
        PanelRow(
          id: 'gyroSensitivity',
          title: T.text('gyroSensitivity'),
          detail: T.text('gyroSensitivityDetail'),
          kind: StepperRow(
            value: aim.sensitivity,
            min: GyroAiming.sensitivityMin,
            max: GyroAiming.sensitivityMax,
            step: 1,
            format: (value) => (value / 10).toStringAsFixed(1),
            set: (value) => change(aim.copyWith(sensitivity: value)),
          ),
        ),
        PanelRow(
          id: 'gyroActivation',
          title: T.text('gyroActivation'),
          detail: T.text('gyroActivationDetail'),
          kind: ChoiceRow(
            [for (final activation in GyroActivation.values) T.text('gyro_${activation.name}')],
            aim.activation.index,
            (index) => change(aim.copyWith(activation: GyroActivation.values[index])),
          ),
        ),
        PanelRow(
          id: 'gyroInvert',
          title: T.text('gyroInvert'),
          kind: ChoiceRow(
            [for (final invert in GyroInvert.values) T.text('gyroInvert_${invert.name}')],
            aim.invert.index,
            (index) => change(aim.copyWith(invert: GyroInvert.values[index])),
          ),
        ),
        PanelRow(
          id: 'gyroDeadzone',
          title: T.text('gyroDeadzone'),
          detail: T.text('gyroDeadzoneDetail'),
          kind: StepperRow(
            value: aim.deadzone,
            min: 0,
            max: GyroAiming.deadzoneMax,
            step: 1,
            format: (value) => value == 0 ? T.text('off') : '$value°/s',
            set: (value) => change(aim.copyWith(deadzone: value)),
          ),
        ),
      ],
    ];
  }

  List<PanelRow> _controlRows(Game game) {
    final settings = currentSettings(game);
    final changes = settings.controls ?? const <String, List<String>>{};
    return [
      ..._gyroRows(game, settings),
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

  /// What a command does in the open panel's rows (for panels with their own Back, like the
  /// crash report).
  void panelCommand(Command command) => _panelCommand(command);

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
    if (_viaPad && _padPanelCommand(command, row, categories)) return;
    if (!_viaPad) {
      // The keys and the mouse have no sections' focus and no edit mode.
      panelSections = false;
      editingValue = null;
    }
    if (row?.kind case ShortcutRow(:final capture) when command == Command.select) return capture();
    if (row?.id case final String id when command == Command.options && id.startsWith('shortcut-')) {
      final action = LauncherAction.byName(id.substring('shortcut-'.length));
      if (action != null) return clearShortcut(action);
    }
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
        // A question asked in place (together_ask.dart) is answered Cancel first.
        if (!together.cancelAsk()) closeOverlay();
      default:
        break;
    }
  }

  /// A controller's command in a panel: the sections' column and edit mode (the keys and the
  /// mouse keep the old ways). True when it was handled here.
  bool _padPanelCommand(Command command, PanelRow? row, List<PanelCategory> categories) {
    final sections = overlay == Layer.settings && categories.length > 1;
    if (panelSections && sections) {
      switch (command) {
        case Command.up || Command.down:
          moveCategory(command == Command.down ? 1 : -1);
        case Command.right || Command.select:
          panelSections = false;
          _skipToFocusable();
          sounds.play(Cue.move);
          _changed();
        case Command.back || Command.options:
          closeOverlay();
        default:
          break;
      }
      return true;
    }
    final editable = row?.kind is ChoiceRow || row?.kind is StepperRow;
    if (editingValue != null && (row == null || row.id != editingValue || !editable)) editingValue = null;
    if (editingValue != null) {
      switch (command) {
        case Command.left || Command.right:
          // ← and → change the value: what follows is the keys' way.
          return false;
        case Command.select || Command.back:
          editingValue = null;
          sounds.play(command == Command.select ? Cue.move : Cue.back);
          _changed();
          return true;
        case Command.up || Command.down:
          // Moving on leaves edit mode.
          editingValue = null;
          return false;
        default:
          editingValue = null;
          _changed();
          return true;
      }
    }
    switch (command) {
      case Command.select when editable:
        editingValue = row!.id;
        sounds.play(Cue.select);
        _changed();
        return true;
      case Command.left:
        if (sections) {
          panelSections = true;
          sounds.play(Cue.move);
          _changed();
        }
        return true;
      case Command.right:
        return true;
      default:
        return false;
    }
  }

  /// A click on a row: the focus goes there and the row does what Enter does.
  void activateRow(int index) {
    final rows = _currentRows;
    if (index < 0 || index >= rows.length || !rows[index].focusable) return;
    panelRow = index;
    pointerFocus = true;
    panelSections = false;
    editingValue = null;
    handle(Command.select);
  }

  /// A click on a row's ‹ › or − + : one step back or on, the focus going to the row.
  void stepRow(int index, int delta) {
    final rows = _currentRows;
    if (index < 0 || index >= rows.length || !rows[index].focusable) return;
    pointerFocus = true;
    if (panelRow != index) {
      panelRow = index;
      _changed();
    }
    handle(delta < 0 ? Command.left : Command.right);
  }

  /// The pointer moved over a row: the focus follows it, quietly, and the list stays put.
  void hoverRow(int index) {
    final rows = _currentRows;
    if (index == panelRow || index < 0 || index >= rows.length || !rows[index].focusable) return;
    panelRow = index;
    pointerFocus = true;
    _changed();
  }

  /// The pointer moved over a game in the library.
  void hoverLibrary(int index) {
    if (index == libraryIndex || index < 0 || index >= games.length) return;
    libraryIndex = index;
    pointerFocus = true;
    _changed();
  }

  /// The pointer moved over a trophy.
  void hoverTrophy(int index) {
    if (index == trophyIndex || index < 0) return;
    trophyIndex = index;
    pointerFocus = true;
    _changed();
  }

  void selectCategory(int index) {
    if (index != panelCategory) sounds.play(Cue.move);
    panelCategory = index;
    panelSections = false;
    editingValue = null;
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
    editingValue = null;
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  // Onboarding: language, theme, games folder, toolkit.

  static const onboardingSteps = 5;
  int onboardingStep = 0;
  final Map<int, int> _onboardingChoices = {};

  int get onboardingChoice => _onboardingChoices[onboardingStep] ?? _defaultChoice(onboardingStep);
  set onboardingChoice(int value) => _onboardingChoices[onboardingStep] = value;

  int _defaultChoice(int step) => switch (step) {
    0 => T.language.index,
    1 => look.index,
    2 => preferences.gamesFolder == null ? 0 : 1,
    3 => toolkit == null ? 0 : 2,
    _ => 0,
  };

  int get _onboardingCount => switch (onboardingStep) {
    0 => Language.values.length,
    1 => LookStyle.values.length,
    2 => preferences.gamesFolder == null ? 1 : 2,
    _ => 3,
  };

  void _onboardingCommand(Command command) {
    // The last step: the cards, or the sign-in they lead to.
    if (onboardingStep == 4) {
      overlay == Layer.signIn ? _signInCommand(command) : modeChoiceCommand(command);
      return;
    }
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
      case 3:
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
            profileFlow.modeChoice = 0;
            onboardingStep++;
        }
      default:
        confirmModeChoice();
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
      applyAssist();
      server.togetherServer = together.account.base.toString();
      unawaited(browserPlay.update());
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
    await browserPlay.stop();
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
        if (command == null) return;
        // The phone's pad moves the launcher as a controller does (the sections, edit mode).
        _usedInput(InputMode.pad);
        _viaPad = true;
        try {
          handle(command);
        } finally {
          _viaPad = false;
        }
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
    _library?.stop();
    _trophyWatch?.cancel();
    _toastTimer?.cancel();
    _pulses.stop();
    _pads?.stop();
    _focusWatch?.cancel();
    _captureTimer?.cancel();
    // The replay buffer's segments go with the launcher.
    unawaited(_stopReplay());
    _navigator?.dispose();
    _installer?.cancel();
    _preparer?.cancel();
    _prepareTimer?.cancel();
    engine.cancel();
    fonts.dispose();
    together.dispose();
    updates.dispose();
    music.dispose();
    unawaited(stopPhoneServer());
    super.dispose();
  }
}

/// The motors of whatever controllers are being read now (none before the pads start).
class _PadMotors implements PadRumble {
  _PadMotors(this.app);
  final AppModel app;

  @override
  bool canRumble(String pad) => app._pads?.motors?.canRumble(pad) ?? false;

  @override
  void rumble(String pad, double strong, double weak, Duration length) =>
      app._pads?.motors?.rumble(pad, strong, weak, length);
}
