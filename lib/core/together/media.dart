import 'account.dart';

/// The optional media server (an SFU, LiveKit) AnyTogether may have for groups bigger than a
/// peer-to-peer mesh holds: a share play with more than four viewers, a party call with more than
/// eight voices. Without one (production today) everything stays on the mesh, as before.
/// AnyTogether's packages/shared/src/media.ts.

/// How a share play or a call carries its media. Once "sfu", it stays so until it ends.
enum MediaRoute {
  mesh,
  sfu;

  /// "sfu", or the mesh for anything else: an older server says nothing.
  static MediaRoute parse(Object? value) => value == 'sfu' ? sfu : mesh;
}

/// The host's published tracks in a share play's room.
const sfuTrackNames = (video: 'game', audio: 'game-audio');

/// What to connect to the media server with: LiveKit's URL and a token for one room. The token
/// works for joining for ten minutes; a connected client keeps its place.
class SfuAccess {
  const SfuAccess({required this.url, required this.token, required this.room, required this.identity, this.expiresAt});

  /// The room from an answer; null on the mesh (or without a URL and token).
  static SfuAccess? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['url'];
    final token = json['token'];
    if (url is! String || token is! String || url.isEmpty || token.isEmpty) return null;
    return SfuAccess(
      url: url,
      token: token,
      room: json['room'] as String? ?? '',
      identity: json['identity'] as String? ?? '',
      expiresAt: json['expiresAt'] is String ? DateTime.tryParse(json['expiresAt'] as String) : null,
    );
  }

  final String url;
  final String token;

  /// `share-<share play ID>` or `call-<call ID>`.
  final String room;

  /// This person in the room: their user ID.
  final String identity;
  final DateTime? expiresAt;

  /// Whether the token still lets its holder in.
  bool fresh([DateTime? now]) => expiresAt == null || (now ?? DateTime.now()).isBefore(expiresAt!);
}

/// What the server holds (GET /media-server): without a media server, the mesh's four viewers and
/// eight in a party.
class MediaLimits {
  const MediaLimits({this.sfu = false, this.maxShareViewers = 4, this.maxPartySize = 8});

  factory MediaLimits.fromJson(Map<String, dynamic> json) => MediaLimits(
    sfu: json['sfu'] == true,
    maxShareViewers: (json['maxShareViewers'] as num?)?.toInt() ?? 4,
    maxPartySize: (json['maxPartySize'] as num?)?.toInt() ?? 8,
  );

  final bool sfu;
  final int maxShareViewers;
  final int maxPartySize;
}

/// The server's media server calls.
class MediaServerClient {
  const MediaServerClient(this.account);
  final TogetherAccount account;

  /// What the server holds; the mesh limits when it cannot say (an older server, offline).
  Future<MediaLimits> limits() async {
    try {
      return MediaLimits.fromJson(await account.call('GET', 'media-server'));
    } on Object {
      return const MediaLimits();
    }
  }

  /// A fresh room token for a share play the user hosts or watches (409 on the mesh).
  Future<SfuAccess> sharePlay(String id) async => _access(await account.call('GET', 'share-plays/$id/sfu'));

  /// A fresh room token for a call the user is in (409 on the mesh).
  Future<SfuAccess> call(String id) async => _access(await account.call('GET', 'calls/$id/sfu'));

  static SfuAccess _access(Map<String, dynamic> json) =>
      SfuAccess.fromJson(json) ?? (throw const FormatException('No media server room in the answer'));
}

/// One media server room as share play and party voice use it; LiveKit in the launcher
/// (lib/ui/livekit_room.dart), fakes in tests. People are named by their identity (user ID).
abstract class SfuRoom {
  /// Joins the room, subscribing to everything published in it.
  Future<void> connect(SfuAccess access);

  bool get connected;

  /// Party voice: publishes the microphone, sending or not.
  Future<void> publishMicrophone({required bool enabled});

  /// The published microphone sends, or is muted.
  Future<void> setMicrophone(bool enabled);

  /// Everyone else in the room.
  Set<String> get participants;

  /// Who speaks now (this person too), from the media server's active speakers.
  Set<String> get speaking;

  /// The tracks subscribed from someone, by name ("game", "game-audio").
  Set<String> tracksOf(String identity);

  /// Someone came or went, a track came or went, the speakers changed.
  set onChange(void Function()? handler);

  Future<void> leave();
}
