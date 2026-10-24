import 'account.dart';
import 'friends.dart';
import 'notifier.dart';
import 'socket.dart';

/// AnyTogether's live side: the gateway socket, open while someone is signed in, and what it
/// keeps up to date. Signing in or out starts and clears everything.
class TogetherHub with Notifier {
  TogetherHub({required this.account, TogetherSocket? socket}) : socket = socket ?? TogetherSocket(account: account) {
    this.socket.addListener(notifyListeners);
    friends = Friends(account: account, socket: this.socket)..addListener(notifyListeners);
    account.addListener(_accountChanged);
    _accountChanged();
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final Friends friends;
  String? _user;

  /// Who is signed in, by id.
  String? get me => account.user?.id;

  /// What waits for an answer: friend requests.
  int get badge => friends.incoming.length;

  void _accountChanged() {
    final user = account.user?.id;
    if (user == _user) return;
    _user = user;
    socket.stop();
    friends.clear();
    if (user != null) socket.start();
    notifyListeners();
  }

  void dispose() {
    account.removeListener(_accountChanged);
    friends.dispose();
    socket.dispose();
  }
}
