import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../together/token_store.dart';

/// Offline: no account, trophies and progress stay on this computer. Online: an AnyTogether
/// account (signed in, or to sign in again).
enum ProfileMode { offline, online }

/// The account an online profile signed in with, to show while it is signed out.
class ProfileAccount {
  const ProfileAccount({required this.userId, required this.handle});

  factory ProfileAccount.fromJson(Map<String, dynamic> json) =>
      ProfileAccount(userId: json['userId'] as String, handle: json['handle'] as String);

  final String userId;
  final String handle;

  Map<String, Object?> toJson() => {'userId': userId, 'handle': handle};
}

/// Someone who plays on this computer: a name and a colour, offline or with an AnyTogether
/// account, their own settings, saves and trophies. The macOS launcher's LauncherProfile.
class LauncherProfile {
  LauncherProfile({
    required this.id,
    required String name,
    required this.color,
    required this.mode,
    this.account,
    DateTime? createdAt,
    this.settings,
    this.picture,
  }) : name = clean(name),
       createdAt = createdAt ?? DateTime.now();

  factory LauncherProfile.fromJson(Map<String, dynamic> json) => LauncherProfile(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Player',
    color: (json['color'] as num? ?? 0).toInt(),
    mode: json['mode'] == 'online' ? ProfileMode.online : ProfileMode.offline,
    account: json['account'] is Map<String, dynamic>
        ? ProfileAccount.fromJson(json['account'] as Map<String, dynamic>)
        : null,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    settings: json['settings'] is Map<String, dynamic> ? json['settings'] as Map<String, dynamic> : null,
    picture: json['picture'] is String ? json['picture'] as String : null,
  );

  /// The profile made from the launcher's setup before there were profiles.
  static const legacyId = 'default';
  static const maxName = 24;
  static const paletteSize = 8;

  final String id;
  String name;
  int color;
  ProfileMode mode;
  ProfileAccount? account;
  final DateTime createdAt;

  /// The profile's own settings (theme, sounds, …) as the launcher writes them; null until it
  /// first switches away from the profile, and then the launcher's defaults apply.
  Map<String, dynamic>? settings;

  /// The file of the profile's own picture in the store's Pictures folder ([ProfileStore.pictureOf]);
  /// null for the initial on its colour. A new picture is a new file, so nothing shows the old one.
  String? picture;

  /// Trimmed and at most [maxName] characters; "Player" when nothing is left (the store gives an
  /// empty name the language's word before it comes here).
  static String clean(String name) {
    var trimmed = name.trim();
    if (trimmed.length > maxName) trimmed = trimmed.substring(0, maxName).trim();
    return trimmed.isEmpty ? 'Player' : trimmed;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'mode': mode.name,
    if (account != null) 'account': account!.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (settings != null) 'settings': settings,
    if (picture != null) 'picture': picture,
  };
}

/// Every profile on this computer and which one plays.
class ProfileBook {
  ProfileBook();

  factory ProfileBook.fromJson(Map<String, dynamic> json) => ProfileBook()
    ..profiles = [
      for (final entry in json['profiles'] as List<dynamic>? ?? const [])
        if (entry is Map<String, dynamic>) LauncherProfile.fromJson(entry),
    ]
    ..current = json['current'] as String?
    ..askEveryTime = json['askEveryTime'] == true
    ..legacyOwner = json['legacyOwner'] as String?;

  List<LauncherProfile> profiles = [];
  String? current;

  /// The picker shows at every start, one profile or more.
  bool askEveryTime = false;

  /// Whose saves are in an installed game's folder that has no profile mark: the first
  /// profile's (the saves from before profiles).
  String? legacyOwner;

  LauncherProfile? get currentProfile {
    for (final profile in profiles) {
      if (profile.id == current) return profile;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  /// The picker's tiles: the profile in use first, then the others as they were made.
  List<LauncherProfile> get pickerOrder {
    final first = currentProfile;
    if (first == null) return profiles;
    return [first, ...profiles.where((profile) => profile.id != first.id)];
  }

  Map<String, Object?> toJson() => {
    'profiles': [for (final profile in profiles) profile.toJson()],
    'current': current,
    'askEveryTime': askEveryTime,
    'legacyOwner': legacyOwner,
  };
}

/// What the launcher knew before profiles, for the one-time migration.
class ExistingSetup {
  const ExistingSetup({required this.onboarded, required this.name});

  final bool onboarded;
  final String name;
}

/// What the launcher shows at start.
class LaunchScreen {
  const LaunchScreen.welcome() : kind = 'welcome', profile = null;
  const LaunchScreen.picker() : kind = 'picker', profile = null;
  const LaunchScreen.home(String this.profile) : kind = 'home';

  final String kind;
  final String? profile;

  @override
  bool operator ==(Object other) => other is LaunchScreen && other.kind == kind && other.profile == profile;

  @override
  int get hashCode => Object.hash(kind, profile);

  @override
  String toString() => profile == null ? kind : '$kind($profile)';
}

/// Why a profile cannot be switched to, deleted or changed now.
enum ProfileRefusal {
  /// A game plays or starts: it is closed first.
  gameRunning,

  /// A game's saves are being synced.
  syncing,
  alreadyCurrent,
  unknown,
  onlyProfile,
  inUse,
}

/// The profiles kept in the config folder's Profiles/profiles.json.
class ProfileStore {
  /// Reads the book; with none kept, a launcher set up before profiles becomes its first
  /// profile at once (offline until [adoptLegacySession] finds its session), and a new one
  /// waits for the welcome.
  ProfileStore(
    this.folder, {
    required ExistingSetup existing,
    this.persist = true,
    String Function(int number)? defaultName,
  }) : defaultName = defaultName ?? _englishName {
    try {
      final json = jsonDecode(File(file).readAsStringSync());
      if (json is Map<String, dynamic>) {
        final kept = ProfileBook.fromJson(json);
        if (kept.profiles.isNotEmpty) {
          book = kept;
          return;
        }
      }
    } on Object {
      // No book yet, or one that cannot be read.
    }
    if (existing.onboarded) {
      final profile = LauncherProfile(
        id: LauncherProfile.legacyId,
        name: _nameOr(existing.name),
        color: 0,
        mode: ProfileMode.offline,
      );
      book
        ..profiles = [profile]
        ..current = profile.id
        ..legacyOwner = profile.id;
      migrated = true;
      save();
    }
  }

  final String folder;
  final bool persist;
  ProfileBook book = ProfileBook();

  /// The name a profile left without one gets, in the launcher's language: 1 for the word
  /// itself ("Player"), 2 and on for the next ones ("Player 2").
  final String Function(int number) defaultName;

  static String _englishName(int number) => number == 1 ? 'Player' : 'Player $number';

  /// [name] cleaned, or the first default name no other profile than [except] has.
  String _nameOr(String name, {String? except}) {
    if (name.trim().isNotEmpty) return LauncherProfile.clean(name);
    final taken = {
      for (final profile in book.profiles)
        if (profile.id != except) profile.name.toLowerCase(),
    };
    for (var number = 1; ; number++) {
      final candidate = LauncherProfile.clean(defaultName(number));
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  /// The book was made from the setup before profiles in this run.
  bool migrated = false;

  String get file => p.join(folder, 'profiles.json');

  /// Where the profiles' pictures are kept: Profiles/Pictures in the launcher's data folder.
  String get pictures => p.join(folder, 'Pictures');

  /// The file of [profile]'s picture, when it has one that is there.
  String? pictureOf(LauncherProfile? profile) {
    final name = profile?.picture;
    if (name == null) return null;
    final path = p.join(pictures, name);
    return File(path).existsSync() ? path : null;
  }

  /// [png] (already cut to a square) is [id]'s picture from now on, the one before deleted.
  void setPicture(String id, List<int> png) {
    final found = profile(id);
    if (found == null) return;
    final name = '$id-${DateTime.now().microsecondsSinceEpoch}.png';
    Directory(pictures).createSync(recursive: true);
    File(p.join(pictures, name)).writeAsBytesSync(png, flush: true);
    _deletePicture(found);
    found.picture = name;
    save();
  }

  /// [id] shows its initial again.
  void removePicture(String id) {
    final found = profile(id);
    if (found == null || found.picture == null) return;
    _deletePicture(found);
    found.picture = null;
    save();
  }

  void _deletePicture(LauncherProfile profile) {
    final name = profile.picture;
    if (name == null) return;
    try {
      File(p.join(pictures, p.basename(name))).deleteSync();
    } on FileSystemException {
      // Gone already.
    }
  }

  LaunchScreen get launchScreen {
    final current = book.currentProfile;
    if (current == null) return const LaunchScreen.welcome();
    return book.profiles.length > 1 || book.askEveryTime ? const LaunchScreen.picker() : LaunchScreen.home(current.id);
  }

  LauncherProfile? profile(String id) {
    for (final profile in book.profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// The session kept from before profiles belongs to the profile just migrated: it is online,
  /// named as the account.
  void adoptLegacySession(TogetherUser user) {
    if (!migrated) return;
    final profile = this.profile(LauncherProfile.legacyId);
    if (profile == null) return;
    profile
      ..mode = ProfileMode.online
      ..account = ProfileAccount(userId: user.id, handle: user.handle)
      ..name = LauncherProfile.clean(user.displayName);
    migrated = false;
    save();
  }

  /// A new profile; the first one also owns the saves already in the games' folders. [id] is
  /// the one a profile signing in was given before it was made.
  LauncherProfile add({required String name, required ProfileMode mode, ProfileAccount? account, String? id}) {
    final used = {for (final profile in book.profiles) profile.color};
    var color = book.profiles.length % LauncherProfile.paletteSize;
    for (var candidate = 0; candidate < LauncherProfile.paletteSize; candidate++) {
      if (!used.contains(candidate)) {
        color = candidate;
        break;
      }
    }
    final first = book.profiles.isEmpty;
    final made = id != null && profile(id) == null
        ? id
        : first && book.legacyOwner == null
        ? LauncherProfile.legacyId
        : newId();
    final added = LauncherProfile(id: made, name: _nameOr(name), color: color, mode: mode, account: account);
    book.profiles.add(added);
    if (first) {
      book.current = added.id;
      book.legacyOwner ??= added.id;
    }
    save();
    return added;
  }

  static String newId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  void rename(String id, String name) => _change(id, (profile) => profile.name = _nameOr(name, except: id));
  void setMode(String id, ProfileMode mode) => _change(id, (profile) => profile.mode = mode);
  void setAccount(String id, ProfileAccount? account) => _change(id, (profile) => profile.account = account);
  void setColor(String id, int color) => _change(id, (profile) => profile.color = color % LauncherProfile.paletteSize);
  void setSettings(String id, Map<String, dynamic>? settings) => _change(id, (profile) => profile.settings = settings);

  void select(String id) {
    if (profile(id) == null || book.current == id) return;
    book.current = id;
    save();
  }

  void setAskEveryTime(bool value) {
    if (book.askEveryTime == value) return;
    book.askEveryTime = value;
    save();
  }

  /// Takes a profile away; the one in use and the last one stay.
  void remove(String id) {
    if (profile(id) == null) throw ProfileRefusal.unknown;
    if (book.profiles.length < 2) throw ProfileRefusal.onlyProfile;
    if (book.currentProfile?.id == id) throw ProfileRefusal.inUse;
    _deletePicture(profile(id)!);
    book.profiles.removeWhere((profile) => profile.id == id);
    save();
  }

  void _change(String id, void Function(LauncherProfile profile) body) {
    final found = profile(id);
    if (found == null) return;
    body(found);
    save();
  }

  void save() {
    if (!persist) return;
    try {
      Directory(folder).createSync(recursive: true);
      final temporary = File('$file.tmp')..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(book.toJson()));
      temporary.renameSync(file);
    } on FileSystemException {
      // Kept in memory for this run.
    }
  }
}

/// Whether the launcher may change who plays now: never with a game open or starting.
abstract final class ProfileSwitch {
  static ProfileRefusal? check(
    String target,
    ProfileBook book, {
    String? running,
    String? starting,
    bool syncing = false,
  }) {
    if (!book.profiles.any((profile) => profile.id == target)) return ProfileRefusal.unknown;
    if (running != null || starting != null) return ProfileRefusal.gameRunning;
    if (syncing) return ProfileRefusal.syncing;
    if (book.currentProfile?.id == target) return ProfileRefusal.alreadyCurrent;
    return null;
  }

  /// Going online or offline, adding or deleting a profile: not while a game plays either.
  static ProfileRefusal? checkModeChange({String? running, String? starting}) =>
      running != null || starting != null ? ProfileRefusal.gameRunning : null;
}

/// The settings that belong to a profile, taken out of and put back into the launcher's
/// settings JSON by key.
abstract final class ProfileSettings {
  static Map<String, dynamic> pick(Set<String> keys, Map<String, dynamic> settings) => {
    for (final entry in settings.entries)
      if (keys.contains(entry.key) && entry.value != null) entry.key: entry.value,
  };

  /// [settings] with the profile's [values] for [keys]; a key the profile has no value for is
  /// left out, so the launcher's default applies.
  static Map<String, dynamic> merge(Map<String, dynamic> values, Set<String> keys, Map<String, dynamic> settings) {
    final merged = Map<String, dynamic>.of(settings);
    for (final key in keys) {
      if (values.containsKey(key)) {
        merged[key] = values[key];
      } else {
        merged.remove(key);
      }
    }
    return merged;
  }
}
