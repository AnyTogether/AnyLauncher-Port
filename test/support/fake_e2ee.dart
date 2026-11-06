import 'dart:convert';

import 'package:anyps5_desktop/core/together/e2ee.dart';

import 'fake_together.dart';

/// AnyTogether's end-to-end encryption routes on the fake server, as AnyTogether's docs/e2ee.md
/// has them: device keys per session (checked as the server checks them), the device lists,
/// sealed messages that must name exactly the active devices of both people (409 e2ee_devices),
/// no plain message once both have a device (409 e2ee_required), sealed media and reports.
class FakeE2ee {
  FakeE2ee(this.server) {
    server.handlers.add(_handle);
  }

  final FakeTogether server;

  /// Active devices by user (E2eeDeviceView), and removed ones.
  final Map<String, List<Map<String, dynamic>>> devices = {};
  final Map<String, List<Map<String, dynamic>>> removed = {};

  /// The launcher's registered device (null until it PUTs one).
  Map<String, dynamic>? session;

  /// Sealed media by ID, and the reports that came in.
  final Map<String, List<int>> media = {};
  final Map<String, List<int>> posters = {};
  final List<Map<String, dynamic>> reports = [];

  /// Turned on: the next sealed message is refused once as if the devices had changed.
  bool refuseNextSeal = false;

  String get me => server.me['id'] as String;

  /// Someone's device, listed (and so sealed for) from now on.
  Future<DeviceSecrets> addDevice(String userId, {String name = 'Phone', DeviceSecrets? secrets}) async {
    final device = secrets ?? await DeviceSecrets.generate();
    final listed = await publicDevice(device, userId);
    (devices[userId] ??= []).add(_view(listed, name));
    return device;
  }

  void removeDevice(String userId, String deviceId) {
    final list = devices[userId] ?? [];
    final gone = list.where((d) => d['id'] == deviceId).toList();
    list.removeWhere((d) => d['id'] == deviceId);
    (removed[userId] ??= []).addAll([
      for (final d in gone) {...d, 'removedAt': '2026-11-06T00:00:00Z'},
    ]);
  }

  static Map<String, dynamic> _view(PublicDevice d, String name) => {
    'id': d.id,
    'signKey': d.signKey,
    'boxKey': d.boxKey,
    'sig': d.sig,
    'name': name,
    'createdAt': '2026-11-06T00:00:00Z',
    'removedAt': null,
  };

  Set<String> _activeIds(Iterable<String> users) => {
    for (final user in users) ...[for (final d in devices[user] ?? const <Map<String, dynamic>>[]) d['id'] as String],
  };

  /// A message as the server keeps and sends a sealed one.
  Map<String, dynamic> sealedMessage(
    String conversation,
    int seq,
    String author,
    SealedMessage sealed, {
    required String id,
    int? replyTo,
    String? mediaId,
  }) => {
    'id': id,
    'conversationId': conversation,
    'seq': seq,
    'authorId': author,
    'kind': mediaId == null ? 'text' : 'image',
    'text': '[encrypted message]',
    'caption': null,
    'attachments': [
      if (mediaId != null)
        {
          'id': mediaId,
          'kind': 'image',
          'contentType': 'application/octet-stream',
          'size': media[mediaId]?.length ?? 0,
          'width': null,
          'height': null,
          'durationMs': null,
          // Signed links are absolute, as the server's are.
          'url': '${server.base}/files/$mediaId',
          'thumb': null,
          'poster': posters.containsKey(mediaId) ? '${server.base}/files/$mediaId/poster' : null,
          'sealed': true,
          'createdAt': '2026-11-06T00:00:00Z',
        },
    ],
    'replyTo': replyTo,
    'editedAt': null,
    'editCount': 0,
    'reactions': <Map<String, dynamic>>[],
    'deletedAt': null,
    'createdAt': server.messageTime(seq),
    'sealed': sealed.toJson(),
  };

  /// Someone else's sealed message, as the gateway brings it.
  void receive(String conversation, String author, SealedMessage sealed, {required String id}) {
    final thread = server.threads[conversation]!;
    final message = sealedMessage(conversation, thread.length + 1, author, sealed, id: id);
    thread.add(message);
    server.conversations[conversation]!
      ..['lastSeq'] = thread.length
      ..['lastMessage'] = message
      ..['encrypted'] = true;
    server.push('message.created', message);
  }

  String? _partner(String conversation) {
    final members = server.conversations[conversation]?['members'] as List<dynamic>? ?? const [];
    if (server.conversations[conversation]?['kind'] != 'direct') return null;
    return members.map((m) => (m as Map)['userId'] as String).where((id) => id != me).firstOrNull;
  }

  Future<(int, Object?)?> _handle(FakeCall call) async {
    switch ((call.method, call.path)) {
      case ('GET', 'me/e2ee/device'):
        return session == null ? FakeTogether.problem(404, 'not_found') : (200, session);
      case ('PUT', 'me/e2ee/device'):
        final body = call.body;
        final listed = PublicDevice(
          id: await deviceIdOf(fromBase64(body['signKey'], 32)),
          signKey: body['signKey'] as String,
          boxKey: body['boxKey'] as String,
          sig: body['sig'] as String,
        );
        // As the server: the signature over the user ID and the X25519 key must hold.
        if (!await verifyDevice(me, listed)) return FakeTogether.problem(400, 'bad_request');
        final fresh = session?['id'] != listed.id;
        if (session != null && fresh) removeDevice(me, session!['id'] as String);
        session = _view(listed, body['name'] as String? ?? '');
        if (fresh) (devices[me] ??= []).add(session!);
        return (fresh ? 201 : 200, session);
    }
    if (call.method == 'GET' && call.path.startsWith('e2ee/devices?users=')) {
      final users = Uri.decodeQueryComponent(call.path.substring('e2ee/devices?users='.length)).split(',');
      return (
        200,
        {
          'users': [
            for (final user in users)
              {'userId': user, 'devices': devices[user] ?? const [], 'removed': removed[user] ?? const []},
          ],
        },
      );
    }
    final upload = RegExp(r'^me/media/sealed\?kind=(image|clip|voice)$').firstMatch(call.path);
    if (upload != null && call.method == 'POST') {
      final id = '0190f1a2-0000-7000-8000-${(media.length + 1).toString().padLeft(12, '0')}';
      media[id] = call.bytes;
      server.files['/files/$id'] = call.bytes;
      // As the server answers: the media and the account's storage use.
      return (
        201,
        {
          'media': {'id': id, 'kind': upload.group(1), 'sealed': true, 'url': '${server.base}/files/$id'},
          'usage': {'used': call.bytes.length, 'limit': 104857600, 'saves': 0, 'media': call.bytes.length},
        },
      );
    }
    final poster = RegExp(r'^me/media/([^/]+)/poster$').firstMatch(call.path);
    if (poster != null && call.method == 'PUT') {
      posters[poster.group(1)!] = call.bytes;
      server.files['/files/${poster.group(1)}/poster'] = call.bytes;
      return (200, {'id': poster.group(1)});
    }
    if (call.method == 'POST' && call.path == 'reports') {
      reports.add(call.body);
      return (201, {'id': 'r-${reports.length}'});
    }
    final post = RegExp(r'^conversations/([^/]+)/messages$').firstMatch(call.path);
    if (post != null && call.method == 'POST') {
      final id = post.group(1)!;
      final other = _partner(id);
      final sealedJson = call.body['sealed'];
      if (sealedJson == null) {
        final bothHave = other != null && (devices[me]?.isNotEmpty ?? false) && (devices[other]?.isNotEmpty ?? false);
        if (bothHave || server.conversations[id]?['encrypted'] == true) {
          return FakeTogether.problem(409, 'e2ee_required');
        }
        return null;
      }
      if (other == null) return FakeTogether.problem(400, 'bad_request');
      final sealed = SealedMessage.fromJson(sealedJson)!;
      final wanted = _activeIds([me, other]);
      if (refuseNextSeal ||
          sealed.keys.keys.toSet().difference(wanted).isNotEmpty ||
          wanted.difference(sealed.keys.keys.toSet()).isNotEmpty) {
        refuseNextSeal = false;
        return (
          409,
          {
            'type': 'about:blank',
            'status': 409,
            'code': 'e2ee_devices',
            'title': 'e2ee_devices',
            'devices': {
              me: [for (final d in devices[me] ?? const <Map<String, dynamic>>[]) d['id']],
              other: [for (final d in devices[other] ?? const <Map<String, dynamic>>[]) d['id']],
            },
          },
        );
      }
      if (call.body.containsKey('text')) return FakeTogether.problem(400, 'bad_request');
      final thread = server.threads[id]!;
      final attachments = call.body['attachments'] as List<dynamic>?;
      final message = sealedMessage(
        id,
        thread.length + 1,
        me,
        sealed,
        id: call.body['clientId'] as String,
        replyTo: call.body['replyTo'] as int?,
        mediaId: attachments == null ? null : (attachments.first as Map)['mediaId'] as String,
      );
      thread.add(message);
      server.conversations[id]!
        ..['lastSeq'] = thread.length
        ..['readSeq'] = thread.length
        ..['lastMessage'] = message
        ..['encrypted'] = true;
      return (201, message);
    }
    final edit = RegExp(r'^conversations/([^/]+)/messages/(\d+)$').firstMatch(call.path);
    if (edit != null && call.method == 'PATCH' && call.body['sealed'] != null) {
      final message = server.threads[edit.group(1)]?.where((m) => m['seq'] == int.parse(edit.group(2)!)).firstOrNull;
      if (message == null) return FakeTogether.problem(404, 'not_found');
      message
        ..['sealed'] = jsonDecode(jsonEncode(call.body['sealed']))
        ..['editedAt'] = '2026-11-06T01:00:00Z'
        ..['editCount'] = (message['editCount'] as int) + 1;
      return (200, message);
    }
    return null;
  }
}
