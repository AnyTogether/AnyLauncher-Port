import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:flutter_test/flutter_test.dart';

/// The party as the API sends it: join codes, the Discord link, requests and the call's deafened
/// people, each one left out by an older server.
void main() {
  Map<String, dynamic> member(String id, String name) => {
    'userId': id,
    'handle': name.toLowerCase(),
    'displayName': name,
    'avatar': null,
  };

  test('a party with a join code, a Discord link, requests and a call', () {
    final party = Party.fromJson({
      'id': 'p-1',
      'leaderId': 'u-me',
      'privacy': 'invite',
      'members': [member('u-me', 'Utku')],
      'invited': <Object>[],
      'joinCode': {
        'code': 'K7QM3XPA',
        'url': 'https://anytogether.kodla.agency/join/K7QM3XPA',
        'expiresAt': '2026-10-26T20:00:00Z',
      },
      'discord': 'https://discord.gg/abc',
      'requests': [member('u-cem', 'Cem')],
      'call': {
        'id': 'call-1',
        'in': ['u-me'],
        'muted': ['u-me'],
        'deafened': ['u-me'],
      },
    });
    expect(party.joinCode!.code, 'K7QM3XPA');
    expect(party.joinCode!.shown, 'K7QM-3XPA');
    expect(party.joinCode!.url.toString(), 'https://anytogether.kodla.agency/join/K7QM3XPA');
    expect(party.joinCode!.expiresAt, DateTime.utc(2026, 10, 26, 20));
    expect(party.discord, 'https://discord.gg/abc');
    expect(party.requests.single.displayName, 'Cem');
    expect(party.deafened, {'u-me'});
    expect(party.muted, {'u-me'});
  });

  test('an older server: no code, no link, no requests, nobody deafened', () {
    final party = Party.fromJson({
      'id': 'p-1',
      'leaderId': 'u-me',
      'members': [member('u-me', 'Utku')],
      'call': {
        'id': 'call-1',
        'in': ['u-me'],
        'muted': <Object>[],
      },
    });
    expect(party.joinCode, isNull);
    expect(party.discord, isNull);
    expect(party.requests, isEmpty);
    expect(party.deafened, isEmpty);
    final nulls = Party.fromJson({'id': 'p-2', 'joinCode': null, 'discord': null, 'requests': null, 'call': null});
    expect(nulls.joinCode, isNull);
    expect(nulls.discord, isNull);
    expect(nulls.requests, isEmpty);
    expect(nulls.deafened, isEmpty);
    expect(
      Party.fromJson({
        'id': 'p-3',
        'joinCode': {'code': ''},
      }).joinCode,
      isNull,
    );
  });

  test('a code as typed or pasted: case, dashes, spaces and the link do not matter', () {
    expect(JoinCode.clean('k7qm-3xpa'), 'K7QM3XPA');
    expect(JoinCode.clean(' K7QM 3XPA '), 'K7QM3XPA');
    expect(JoinCode.clean('https://anytogether.kodla.agency/join/K7QM3XPA'), 'K7QM3XPA');
    expect(JoinCode.clean('anytogether.kodla.agency/join/k7qm-3xpa/'), 'K7QM3XPA');
    expect(JoinCode.clean('K7QM3XP'), isNull, reason: 'too short');
    expect(JoinCode.clean('K7QM3XP0'), isNull, reason: 'no 0 in a code');
    expect(JoinCode.clean('K7QM3XPI'), isNull, reason: 'no I in a code');
    expect(JoinCode.clean(''), isNull);
    expect(JoinCode.show('K7QM3XPA'), 'K7QM-3XPA');
  });

  test('what a code opens, as anyone holding it reads it', () {
    final preview = JoinPreview.fromJson({
      'code': 'K7QM3XPA',
      'kind': 'party',
      'id': 'p-1',
      'host': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana', 'avatar': null},
      'game': {
        'titleId': 'PPSA01001',
        'title': 'Orbit Runner',
        'names': {'tr': 'Yörünge'},
        'iconUrl': null,
      },
      'size': 3,
      'max': 8,
      'expiresAt': '2026-10-26T20:00:00Z',
      'state': 'requested',
    });
    expect(preview.party, isTrue);
    expect(preview.host!.displayName, 'Ana');
    expect(preview.game!.titleId, 'PPSA01001');
    expect(preview.game!.name('tr'), 'Yörünge');
    expect(preview.game!.name('en'), 'Orbit Runner');
    expect((preview.size, preview.max), (3, 8));
    expect(preview.state, 'requested');

    final bare = JoinPreview.fromJson({
      'code': 'K7QM3XPA',
      'kind': 'share_play',
      'id': 's-1',
      'host': {'handle': 'ana', 'displayName': 'Ana', 'avatar': null},
      'game': null,
    });
    expect(bare.party, isFalse);
    expect(bare.host!.handle, 'ana');
    expect(bare.game, isNull);
    expect(bare.state, 'none');
  });
}
