import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/friends.dart';
import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

/// The launcher's AnyTogether client in the cross-client scenarios that the server's repository
/// runs (AnyTogether's e2e/): with ANYTOGETHER_E2E_BUS and ANYTOGETHER_E2E_URL set, this test takes
/// commands from the scenario script and runs each with the launcher's real account, socket,
/// friends, messages, parties and game sessions against the local stack, while the Mac, the phone
/// and the website do the same. Without them it is skipped.
void main() {
  final environment = Platform.environment;
  final bus = environment['ANYTOGETHER_E2E_BUS'];
  final base = environment['ANYTOGETHER_E2E_URL'];

  test(
    'drives the launcher from the cross-client scenarios',
    () async {
      final folder = await Directory.systemTemp.createTemp('together-e2e');
      try {
        await _Driver(
          Uri.parse(base!),
          folder.path,
        ).run(Uri.parse(bus!), environment['ANYTOGETHER_E2E_ROLE'] ?? 'desk');
      } finally {
        await folder.delete(recursive: true);
      }
    },
    skip: bus == null || base == null ? 'no cross-client run' : false,
    timeout: Timeout.none,
  );
}

/// One launcher: its account, socket and the lists it keeps, and what the socket said.
class _Launcher {
  _Launcher(this.account, String bridgeFile) : socket = TogetherSocket(account: account) {
    friends = Friends(account: account, socket: socket);
    messages = Messages(account: account, socket: socket);
    parties = Parties(account: account, socket: socket);
    games = GameSessions(account: account, socket: socket, bridgeFile: bridgeFile);
    socket.events.listen(events.add);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final Friends friends;
  late final Messages messages;
  late final Parties parties;
  late final GameSessions games;
  final events = <TogetherEvent>[];
  Future<TogetherUser>? website;
  Uri? websitePage;
}

class _Driver {
  _Driver(this.base, this.folder);

  final Uri base;
  final String folder;
  final _launchers = <String, _Launcher>{};
  final _http = HttpClient();

  _Launcher launcher(String name) => _launchers[name] ??= _Launcher(
    TogetherAccount(
      base: base,
      store: MemoryTokenStore(),
      clientName: 'launcher-linux/e2e (Linux)',
      pollEvery: const Duration(milliseconds: 500),
    ),
    '$folder/$name/game-session.json',
  );

  Future<void> run(Uri bus, String role) async {
    await _post(bus.resolve('/hello'), {'role': role});
    var done = false;
    while (!done) {
      final request = await _http.getUrl(bus.resolve('/next?role=$role'));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      if (response.statusCode != 200) continue;
      final command = jsonDecode(text) as Map<String, dynamic>;
      final id = command['id'] as String;
      final name = command['cmd'] as String;
      final args = (command['args'] as Map<String, dynamic>?) ?? const {};
      if (name == 'done') {
        done = true;
        await _post(bus.resolve('/result'), {'id': id, 'ok': true});
        continue;
      }
      unawaited(() async {
        Map<String, dynamic> answer;
        try {
          answer = {'id': id, 'ok': true, 'value': await handle(name, args)};
        } on TogetherProblem catch (problem) {
          answer = {
            'id': id,
            'ok': false,
            'error': {'status': problem.status, 'code': problem.code, 'message': problem.title},
          };
        } on Object catch (error) {
          answer = {
            'id': id,
            'ok': false,
            'error': {'message': '$error'},
          };
        }
        await _post(bus.resolve('/result'), answer);
      }());
    }
    for (final launcher in _launchers.values) {
      launcher.socket.stop();
    }
  }

  Future<void> _post(Uri url, Map<String, dynamic> body) async {
    final request = await _http.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    await (await request.close()).drain<void>();
  }

  Future<Object?> handle(String name, Map<String, dynamic> args) async {
    final who = launcher(args['as'] as String? ?? 'main');
    final account = who.account;
    String text(String key) => args[key] as String;
    switch (name) {
      // Signing in
      case 'emailStart':
        await account.startEmail(text('email'));
        return null;
      case 'emailVerify':
        return (await account.verifyEmail(text('code'))).toJson();
      case 'websiteStart':
        // The launcher's own flow: a code for the website, then waiting for it to be approved.
        final shown = Completer<Uri>();
        who.website = account.signInWithWebsite(text('deviceName'), show: shown.complete);
        who.website!.ignore();
        final page = await shown.future;
        who.websitePage = page;
        return {'page': page.toString(), 'userCode': page.queryParameters['code']};
      case 'websiteWait':
        return (await who.website!).toJson();
      case 'handoffStart':
        final handoff = await account.startHandoff(text('deviceName'), 'phone');
        return {'handoffId': handoff.id, 'secret': handoff.secret};
      case 'handoffWait':
        return (await account.waitForPhone(Handoff(text('handoffId'), text('secret')))).toJson();
      case 'handoffApprove':
        await account.approveHandoff(text('id'));
        return null;
      case 'user':
        return account.user?.toJson();
      case 'signOut':
        who.socket.stop();
        await account.signOut();
        return null;

      // The socket
      case 'socketStart':
        who.socket.start();
        return null;
      case 'socketStatus':
        return {'status': who.socket.status.name, 'session': who.socket.session};
      case 'presence':
        who.socket.presence = args['state'] == 'in_game'
            ? PresenceInGame(text('titleId'), DateTime.now())
            : const PresenceOnline();
        return null;
      case 'events':
        final since = (args['since'] as num? ?? 0).toInt();
        return {
          'next': who.events.length,
          'events': [
            for (final event in who.events.skip(since)) {'type': event.type, 'data': event.data},
          ],
        };
      case 'frame':
        return who.socket.send(args['frame'] as Map<String, dynamic>);

      // Friends, as the launcher's friends list keeps them
      case 'friends':
        final friends = who.friends;
        return {
          'friends': [
            for (final friend in friends.friends)
              {
                ..._person(friend.person),
                'state': friend.presence.state.name,
                'titleId': friend.presence.titleId,
                'partyId': friend.presence.party?.id,
                'game': friend.presence.game == null
                    ? null
                    : {
                        'sessionId': friend.presence.game!.sessionId,
                        'titleId': friend.presence.game!.titleId,
                        'joinable': friend.presence.game!.joinable,
                        'players': friend.presence.game!.players,
                        'capacity': friend.presence.game!.capacity,
                      },
              },
          ],
          'incoming': friends.incoming.map(_person).toList(),
          'outgoing': friends.outgoing.map(_person).toList(),
        };
      case 'friendsRefresh':
        await who.friends.refresh();
        return null;
      case 'addFriend':
        return who.friends.add(text('handle'));
      case 'answerFriend':
        await who.friends.answer(text('userId'), accept: args['accept'] == true);
        return null;
      case 'removeFriend':
        await who.friends.remove(text('userId'));
        return null;

      // Messages, as the launcher's messages keep them
      case 'messages':
        final messages = who.messages;
        return {
          'unread': messages.unread,
          'openId': messages.openId,
          'typing': messages.typingIn(messages.openId),
          'conversations': [
            for (final c in messages.conversations)
              {
                'id': c.id,
                'group': c.group,
                'title': c.title,
                'unread': c.unread,
                'lastSeq': c.lastSeq,
                'readSeq': c.readSeq,
                'last': c.lastMessage?.text,
                'members': c.members.map((p) => p.id).toList(),
              },
          ],
          'thread': [
            for (final m in messages.thread)
              {'seq': m.seq, 'authorId': m.authorId, 'text': m.text, 'pending': m.pending, 'failed': m.failed},
          ],
        };
      case 'messagesRefresh':
        await who.messages.refresh();
        return null;
      case 'withFriend':
        await who.messages.withFriend(text('userId'));
        return who.messages.openId;
      case 'show':
        await who.messages.show(text('id'));
        return null;
      case 'hide':
        who.messages.hide();
        return null;
      case 'sendMessage':
        await who.messages.send(text('text'));
        return null;
      case 'typing':
        who.messages.typing();
        return null;

      // Parties
      case 'parties':
        final party = who.parties.party;
        return {
          'kicked': who.parties.kicked,
          'party': party == null
              ? null
              : {
                  'id': party.id,
                  'leaderId': party.leaderId,
                  'open': party.open,
                  'members': party.members.map((p) => p.id).toList(),
                  'invited': party.invited.map((p) => p.id).toList(),
                  'callId': party.callId,
                  'inCall': party.inCall.toList(),
                  'muted': party.muted.toList(),
                },
          'invites': [
            for (final invite in who.parties.invites) {'partyId': invite.partyId, 'from': invite.from?.id},
          ],
        };
      case 'partiesRefresh':
        await who.parties.refresh();
        return null;
      case 'createParty':
        await who.parties.create(open: args['open'] == true);
        return who.parties.party?.id;
      case 'joinParty':
        await who.parties.join(text('partyId'));
        return null;
      case 'leaveParty':
        await who.parties.leave();
        return null;
      case 'kick':
        await who.parties.kick(text('userId'));
        return null;

      // Game sessions, as the launcher keeps them (and writes them for the engine)
      case 'games':
        final session = who.games.session;
        final bridge = File('$folder/${args['as'] ?? 'main'}/game-session.json');
        return {
          'session': session?.json,
          'hosting': who.games.hosting,
          'invites': [
            for (final invite in who.games.invites)
              {'sessionId': invite.sessionId, 'titleId': invite.titleId, 'gameVersion': invite.gameVersion},
          ],
          'bridge': bridge.existsSync() ? jsonDecode(bridge.readAsStringSync()) : null,
        };
      case 'getGame':
        return (await who.games.get(text('id'))).json;
      case 'mismatch':
        final session = await who.games.get(text('id'));
        return session.mismatch(gameVersion: text('gameVersion'), engineBuild: text('engineBuild'))?.name;
      case 'joinGame':
        return (await who.games.join(
          text('id'),
          gameVersion: text('gameVersion'),
          engineBuild: text('engineBuild'),
        )).json;
      case 'closeGame':
        await who.games.close();
        return null;

      // Anything else the API has, with the launcher's session
      case 'api':
        return account.call(text('method'), text('path'), args['body'] as Map<String, dynamic>?);
      default:
        throw StateError('unknown command $name');
    }
  }

  static Map<String, dynamic> _person(Person person) => {
    'userId': person.id,
    'handle': person.handle,
    'displayName': person.displayName,
  };
}
