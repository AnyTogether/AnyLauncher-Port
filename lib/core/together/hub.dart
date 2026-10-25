import 'dart:async';

import 'account.dart';
import 'friends.dart';
import 'game_sessions.dart';
import 'messages.dart';
import 'notifier.dart';
import 'parties.dart';
import 'profiles.dart';
import 'self.dart';
import 'socket.dart';
import 'voice.dart';
import 'voice_mesh.dart';

/// AnyTogether's live side: the gateway socket, open while someone is signed in, and what it
/// keeps up to date: the friends, the messages, the party and its voice. Signing in or out starts
/// and clears everything.
class TogetherHub with Notifier {
  TogetherHub({
    required this.account,
    required VoiceEngine Function() voiceEngine,
    required String bridgeFile,
    TogetherSocket? socket,
  }) : socket = socket ?? TogetherSocket(account: account),
       profiles = Profiles(account) {
    this.socket.addListener(notifyListeners);
    friends = Friends(account: account, socket: this.socket)..addListener(notifyListeners);
    self = SelfProfile(account: account, socket: this.socket)..addListener(notifyListeners);
    messages = Messages(account: account, socket: this.socket)..addListener(notifyListeners);
    parties = Parties(account: account, socket: this.socket)..addListener(notifyListeners);
    games = GameSessions(account: account, socket: this.socket, bridgeFile: bridgeFile)..addListener(notifyListeners);
    voice = Voice(account: account, socket: this.socket, parties: parties, engine: voiceEngine)
      ..addListener(notifyListeners);
    account.addListener(_accountChanged);
    _accountChanged();
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final Friends friends;

  /// The user's own trophy level and whether they appear offline.
  late final SelfProfile self;
  late final Messages messages;
  late final Parties parties;
  late final Voice voice;
  late final GameSessions games;
  final Profiles profiles;
  String? _user;

  /// Who is signed in, by id.
  String? get me => account.user?.id;

  /// What waits for an answer: friend requests and invites to friends' games.
  int get badge => friends.incoming.length + games.invites.length;

  void _accountChanged() {
    final user = account.user?.id;
    if (user == _user) return;
    _user = user;
    unawaited(voice.leave(tell: false));
    socket.stop();
    friends.clear();
    self.clear();
    messages.clear();
    parties.clear();
    games.clear();
    if (user != null) socket.start();
    notifyListeners();
  }

  void dispose() {
    account.removeListener(_accountChanged);
    friends.dispose();
    self.dispose();
    messages.dispose();
    voice.dispose();
    parties.dispose();
    games.dispose();
    socket.dispose();
  }
}
