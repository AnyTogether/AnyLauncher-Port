import 'dart:async';

import 'account.dart';
import 'friends.dart';
import 'messages.dart';
import 'notifier.dart';
import 'parties.dart';
import 'socket.dart';
import 'voice.dart';
import 'voice_mesh.dart';

/// AnyTogether's live side: the gateway socket, open while someone is signed in, and what it
/// keeps up to date: the friends, the messages, the party and its voice. Signing in or out starts
/// and clears everything.
class TogetherHub with Notifier {
  TogetherHub({required this.account, required VoiceEngine Function() voiceEngine, TogetherSocket? socket})
    : socket = socket ?? TogetherSocket(account: account) {
    this.socket.addListener(notifyListeners);
    friends = Friends(account: account, socket: this.socket)..addListener(notifyListeners);
    messages = Messages(account: account, socket: this.socket)..addListener(notifyListeners);
    parties = Parties(account: account, socket: this.socket)..addListener(notifyListeners);
    voice = Voice(account: account, socket: this.socket, parties: parties, engine: voiceEngine)
      ..addListener(notifyListeners);
    account.addListener(_accountChanged);
    _accountChanged();
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final Friends friends;
  late final Messages messages;
  late final Parties parties;
  late final Voice voice;
  String? _user;

  /// Who is signed in, by id.
  String? get me => account.user?.id;

  /// What waits for an answer: friend requests.
  int get badge => friends.incoming.length;

  void _accountChanged() {
    final user = account.user?.id;
    if (user == _user) return;
    _user = user;
    unawaited(voice.leave(tell: false));
    socket.stop();
    friends.clear();
    messages.clear();
    parties.clear();
    if (user != null) socket.start();
    notifyListeners();
  }

  void dispose() {
    account.removeListener(_accountChanged);
    friends.dispose();
    messages.dispose();
    voice.dispose();
    parties.dispose();
    socket.dispose();
  }
}
