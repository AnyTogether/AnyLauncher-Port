import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/private_identity.dart';
import 'package:anyps5_desktop/core/together/self.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// The friends-only name and picture: shown when there, the public ones when not, the handle always.
void main() {
  Person card(Map<String, dynamic> extra) => Person.fromJson({
    'userId': 'u2',
    'handle': 'selin',
    'displayName': 'Night Owl',
    'avatar': 'https://x/pub.jpg',
    ...extra,
  });
  Friend friend(Map<String, dynamic> extra) => Friend(card(extra), const Presence());

  test('a friend\'s private name and picture are shown with the handle', () {
    final shown = ShownIdentity.of(
      card({'privateName': 'Selin Kaya', 'privateAvatar': 'https://x/api/v1/avatars/private/h.jpg?e=1&s=2'}),
      IdentityBook(),
    );
    expect(shown.name, 'Selin Kaya');
    expect(shown.avatar, 'https://x/api/v1/avatars/private/h.jpg?e=1&s=2');
    expect(shown.handle, 'selin');
    expect(shown.isPrivate, isTrue);
    expect(shown.publicName, 'Night Owl');
  });

  test('without them, the public name and picture', () {
    final unset = ShownIdentity.of(card({'privateName': null, 'privateAvatar': null}), IdentityBook());
    expect(unset.name, 'Night Owl', reason: 'null: not set');
    expect(unset.avatar, 'https://x/pub.jpg');
    expect(unset.isPrivate, isFalse);
    final stranger = ShownIdentity.of(card({}), IdentityBook());
    expect(stranger.name, 'Night Owl', reason: 'left out: may not see');
    expect(ShownIdentity.of(card({'privateName': '   '}), IdentityBook()).name, 'Night Owl', reason: 'blank is none');
  });

  test('a card from a realtime event keeps what the friends list said', () {
    final book = IdentityBook()
      ..learn([
        friend({'privateName': 'Selin Kaya', 'privateAvatar': 'https://x/p.jpg'}),
      ]);
    final shown = ShownIdentity.of(card({}), book);
    expect(shown.name, 'Selin Kaya');
    expect(shown.avatar, 'https://x/p.jpg');
  });

  test('an ended friendship, or names cleared, are forgotten with the next list', () {
    final book = IdentityBook()
      ..learn([
        friend({'privateName': 'Selin Kaya'}),
      ]);
    book.learn([]);
    expect(ShownIdentity.of(card({}), book).name, 'Night Owl');
    book
      ..learn([
        friend({'privateName': 'Selin Kaya'}),
      ])
      ..learn([
        friend({'privateName': null}),
      ]);
    expect(ShownIdentity.of(card({}), book).name, 'Night Owl');
  });

  test('the card\'s own values win over the book', () {
    final book = IdentityBook()
      ..learn([
        friend({'privateName': 'Old Name'}),
      ]);
    expect(ShownIdentity.of(card({'privateName': 'New Name'}), book).name, 'New Name');
  });

  test('a picture link that may have run out asks for the list again', () {
    final book = IdentityBook();
    expect(book.stale(), isTrue);
    book.learn([], at: DateTime(2026, 10, 26, 8));
    expect(book.stale(now: DateTime(2026, 10, 26, 9)), isFalse);
    expect(book.stale(now: DateTime(2026, 10, 26, 14)), isTrue);
  });

  test('the private fields go with the card when it is kept', () {
    final kept = Person.fromJson(card({'privateName': 'Selin Kaya'}).toJson());
    expect(kept.privateName, 'Selin Kaya');
    expect(card({}).toJson().containsKey('privateName'), isFalse);
  });

  group('the user\'s own', () {
    late FakeTogether server;
    late TogetherAccount account;
    late SelfProfile self;

    setUp(() async {
      server = await FakeTogether.start();
      account = TogetherAccount(
        base: server.base,
        store: MemoryTokenStore(),
        clientName: 'launcher-linux/test',
        pollEvery: const Duration(milliseconds: 10),
      );
      await account.startEmail('utku@example.com');
      await account.verifyEmail(server.emailCode);
      self = SelfProfile(
        account: account,
        socket: TogetherSocket(account: account),
      );
    });

    tearDown(() async {
      account.close();
      await server.close();
    });

    test('read from /me, set, cleared', () async {
      server.answers['GET me'] = (
        200,
        {
          'account': {'id': 'u-me'},
          'profile': {'handle': 'utku', 'displayName': 'Utku', 'privateName': 'Utku Halis', 'privateAvatar': null},
        },
      );
      await self.refresh();
      expect(self.privateName, 'Utku Halis');
      expect(self.privateAvatar, isNull);

      server.answers['PATCH me/profile'] = (200, {'handle': 'utku', 'displayName': 'Utku', 'privateName': null});
      await self.setPrivateName('  ');
      expect(server.calls.last.body, {'privateName': null}, reason: 'blank clears it');
      expect(self.privateName, isNull);
    });

    test('the private picture goes up as the picture itself and is removed', () async {
      server.answers['PUT me/avatar/private'] = (
        200,
        {'privateAvatar': 'https://x/api/v1/avatars/private/h.jpg?e=1&s=2'},
      );
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(64, 0)];
      await self.uploadPrivateAvatar(png);
      expect(self.privateAvatar, startsWith('https://x/api/v1/avatars/private/'));
      expect(server.calls.last.headers.contentType?.mimeType, 'image/png');
      server.answers['DELETE me/avatar/private'] = (204, null);
      await self.removePrivateAvatar();
      expect(server.calls.last.method, 'DELETE');
      expect(self.privateAvatar, isNull);
    });
  });
}
