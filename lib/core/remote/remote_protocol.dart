import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A game as the phone lists it. [art] changes whenever its icon or background does, so the
/// phone asks for the pictures again only then.
class RemoteGame {
  const RemoteGame({
    required this.id,
    required this.name,
    required this.state,
    required this.art,
    this.trophies,
    this.layout,
  });

  factory RemoteGame.fromJson(Map<String, dynamic> json) => RemoteGame(
    id: json['id'] as String,
    name: json['name'] as String,
    state: RemoteGameState.values.firstWhere(
      (state) => state.name == json['state'],
      orElse: () => RemoteGameState.unavailable,
    ),
    trophies: json['trophies'] as String?,
    art: json['art'] as String,
    layout: json['layout'] as String?,
  );

  final String id;
  final String name;
  final RemoteGameState state;
  final String? trophies;
  final String art;

  /// The phone's pad layout saved for this game (the phone's own JSON), null for the default.
  final String? layout;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'state': state.name,
    'trophies': trophies,
    'art': art,
    'layout': layout,
  };

  @override
  bool operator ==(Object other) => other is RemoteGame && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

enum RemoteGameState { installed, update, locked, installing, starting, running, unavailable }

/// The launcher's steps with a game, as the phone names them: waiting for its turn, the
/// installer's five, and starting it.
enum RemotePhase { queued, unwrap, relink, copy, bundle, finish, starting }

/// What text the game asks for, for a phone to type it: the game's keyboard (sceImeOpen) or its
/// text dialog (sceImeDialogInit), from the engine's prompt datagram (APRK).
class RemoteTextPrompt {
  const RemoteTextPrompt({
    required this.id,
    this.kind = 'dialog',
    this.title = '',
    this.placeholder = '',
    this.text = '',
    this.maxLength = 0,
    this.multiline = false,
    this.keyboard = 'text',
    this.enter = 'default',
  });

  factory RemoteTextPrompt.fromJson(Map<String, dynamic> json) => RemoteTextPrompt(
    id: (json['id'] as num).toInt(),
    kind: json['kind'] as String? ?? 'dialog',
    title: json['title'] as String? ?? '',
    placeholder: json['placeholder'] as String? ?? '',
    text: json['text'] as String? ?? '',
    maxLength: (json['maxLength'] as num?)?.toInt() ?? 0,
    multiline: json['multiline'] as bool? ?? false,
    keyboard: json['keyboard'] as String? ?? 'text',
    enter: json['enter'] as String? ?? 'default',
  );

  static const keyboards = ['text', 'latin', 'url', 'mail', 'number'];
  static const enters = ['default', 'send', 'search', 'go'];

  /// The engine's number for this keyboard or dialog; the typed text names it.
  final int id;

  /// keyboard or dialog.
  final String kind;
  final String title;
  final String placeholder;

  /// The text the game starts with.
  final String text;

  /// The most characters the game takes (UTF-16 units, as it counts them).
  final int maxLength;
  final bool multiline;

  /// The keys the console would show: text, latin, url, mail or number.
  final String keyboard;

  /// The Enter key's label: default, send, search or go.
  final String enter;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'placeholder': placeholder,
    'text': text,
    'maxLength': maxLength,
    'multiline': multiline,
    'keyboard': keyboard,
    'enter': enter,
  };

  @override
  bool operator ==(Object other) => other is RemoteTextPrompt && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// What a phone does with the text it typed: send it as the game's text so far, enter it, or
/// cancel the game's keyboard.
enum RemoteTypedAction { update, submit, cancel }

/// What the launcher is doing with a game, for the phone to show.
class RemoteActivity {
  const RemoteActivity({
    required this.id,
    required this.phase,
    required this.updating,
    required this.fraction,
    required this.elapsed,
  });

  factory RemoteActivity.fromJson(Map<String, dynamic> json) => RemoteActivity(
    id: json['id'] as String,
    phase: RemotePhase.values.firstWhere((phase) => phase.name == json['phase'], orElse: () => RemotePhase.queued),
    updating: json['updating'] as bool? ?? false,
    fraction: (json['fraction'] as num?)?.toDouble(),
    elapsed: (json['elapsed'] as num?)?.toDouble() ?? 0,
  );

  final String id;
  final RemotePhase phase;

  /// An installed game being made again for a newer engine, rather than unlocked the first time.
  final bool updating;

  /// How much of the whole install is done, 0 to 1; null when how long is not known.
  final double? fraction;

  /// Seconds since the launcher began with the game; the phone keeps counting from it.
  final double elapsed;

  Map<String, Object?> toJson() => {
    'id': id,
    'phase': phase.name,
    'updating': updating,
    'fraction': fraction,
    'elapsed': elapsed,
  };

  /// Whether the phone would show the same: the time it counts itself, and a hundredth of
  /// progress is not worth a message.
  bool looksLike(RemoteActivity other) {
    if (id != other.id || phase != other.phase || updating != other.updating) return false;
    final mine = fraction;
    final theirs = other.fraction;
    if (mine == null || theirs == null) return mine == theirs;
    return (mine - theirs).abs() < 0.01;
  }

  /// Whether the phone, told [told], already shows [now].
  static bool same(RemoteActivity? told, RemoteActivity? now) {
    if (told == null || now == null) return told == now;
    return told.looksLike(now);
  }
}

/// A message on the phone's control channel: one JSON object per WebSocket text frame, told
/// apart by its `type`. Section 12.4 of the AnyTogether platform notes lists them.
sealed class RemoteMessage {
  const RemoteMessage();

  static const protocolVersion = 1;

  /// The message's type, as its JSON names it.
  String get type;

  Map<String, Object?> get fields;

  /// The message as the text of one WebSocket frame.
  String get text => jsonEncode({'type': type, ...fields});

  /// The message in [text], null when it is not one (unknown type, missing field).
  static RemoteMessage? decode(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      return _decode(json);
    } on Object {
      return null;
    }
  }

  static RemoteMessage? _decode(Map<String, dynamic> json) => switch (json['type']) {
    'hello' => RemoteHello(
      protocol: (json['protocol'] as num).toInt(),
      deviceId: json['deviceID'] as String,
      deviceName: json['deviceName'] as String,
      key: json['key'] as String?,
    ),
    'pairing' => RemotePairing(json['code'] as String),
    'welcome' => RemoteWelcome(
      session: BigInt.parse(json['session'] as String),
      udpPort: (json['udpPort'] as num).toInt(),
      macName: json['macName'] as String,
      key: json['key'] as String,
      togetherServer: json['togetherServer'] as String?,
    ),
    'rejected' => RemoteRejected(json['reason'] as String),
    'latency' => RemoteLatency((json['milliseconds'] as num).toDouble()),
    'library' => RemoteLibrary(
      games: [for (final game in json['games'] as List<dynamic>) RemoteGame.fromJson(game as Map<String, dynamic>)],
      selected: json['selected'] as String?,
      running: json['running'] as String?,
      language: json['language'] as String,
    ),
    'art' => RemoteArt(
      id: json['id'] as String,
      icon: json['icon'] as String?,
      background: json['background'] as String?,
    ),
    'wantArt' => RemoteWantArt(json['id'] as String),
    'command' => RemoteCommand(json['name'] as String),
    'select' => RemoteSelect(json['id'] as String),
    'launch' => RemoteLaunch(json['id'] as String),
    'close' => const RemoteClose(),
    'home' => const RemoteHome(),
    'saveLayout' => RemoteSaveLayout(json['id'] as String, json['layout'] as String?),
    'trophy' => RemoteTrophy(
      name: json['name'] as String,
      detail: json['detail'] as String,
      grade: json['grade'] as String,
      icon: json['icon'] as String?,
    ),
    'activity' => RemoteActivityUpdate(
      json['activity'] == null ? null : RemoteActivity.fromJson(json['activity'] as Map<String, dynamic>),
    ),
    'look' => RemoteLook(
      deep: json['deep'] as String,
      middle: json['middle'] as String,
      accent: json['accent'] as String,
    ),
    'stream' => RemoteStream(
      on: json['on'] as bool,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    ),
    'keyFrame' => const RemoteKeyFrame(),
    'streaming' => RemoteStreaming(json['state'] as String),
    'broadcast' => RemoteBroadcast(json['on'] == true),
    'togetherHandoff' => RemoteTogetherHandoff(id: json['id'] as String, deviceName: json['deviceName'] as String),
    'togetherHandoffAnswer' => RemoteTogetherHandoffAnswer(
      id: json['id'] as String,
      approved: json['approved'] as bool,
    ),
    'textInput' => RemoteTextInput(
      json['prompt'] == null ? null : RemoteTextPrompt.fromJson(json['prompt'] as Map<String, dynamic>),
    ),
    'typed' => RemoteTyped(
      prompt: (json['prompt'] as num).toInt(),
      typed: json['text'] as String,
      action: RemoteTypedAction.values.byName(json['action'] as String),
    ),
    _ => null,
  };

  @override
  bool operator ==(Object other) => other is RemoteMessage && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text.length > 200 ? '${text.substring(0, 200)}...' : text;
}

/// The phone introduces itself; [key] is the one a previous pairing gave it.
class RemoteHello extends RemoteMessage {
  const RemoteHello({required this.protocol, required this.deviceId, required this.deviceName, this.key});
  final int protocol;
  final String deviceId;
  final String deviceName;
  final String? key;
  @override
  String get type => 'hello';
  @override
  Map<String, Object?> get fields => {'protocol': protocol, 'deviceID': deviceId, 'deviceName': deviceName, 'key': key};
}

/// The launcher is asking its user to allow the phone; both show [code].
class RemotePairing extends RemoteMessage {
  const RemotePairing(this.code);
  final String code;
  @override
  String get type => 'pairing';
  @override
  Map<String, Object?> get fields => {'code': code};
}

/// The phone may send pad packets with [session] to [udpPort]; [key] lets it in next time.
class RemoteWelcome extends RemoteMessage {
  const RemoteWelcome({
    required this.session,
    required this.udpPort,
    required this.macName,
    required this.key,
    this.togetherServer,
  });
  final BigInt session;
  final int udpPort;

  /// The computer's name (the field keeps the macOS launcher's name).
  final String macName;
  final String key;

  /// The AnyTogether server the launcher uses, so the phone can say when it uses another.
  final String? togetherServer;
  @override
  String get type => 'welcome';
  @override
  Map<String, Object?> get fields => {
    'session': session.toString(),
    'udpPort': udpPort,
    'macName': macName,
    'key': key,
    'togetherServer': ?togetherServer,
  };
}

/// denied, busy or protocol.
class RemoteRejected extends RemoteMessage {
  const RemoteRejected(this.reason);
  final String reason;
  @override
  String get type => 'rejected';
  @override
  Map<String, Object?> get fields => {'reason': reason};
}

/// The phone's measured latency, every two seconds.
class RemoteLatency extends RemoteMessage {
  const RemoteLatency(this.milliseconds);
  final double milliseconds;
  @override
  String get type => 'latency';
  @override
  Map<String, Object?> get fields => {'milliseconds': milliseconds};
}

/// The launcher's games as it shows them, with the one selected, the one playing and the
/// language, sent again whenever any of it changes.
class RemoteLibrary extends RemoteMessage {
  const RemoteLibrary({required this.games, this.selected, this.running, required this.language});
  final List<RemoteGame> games;
  final String? selected;
  final String? running;
  final String language;
  @override
  String get type => 'library';
  @override
  Map<String, Object?> get fields => {
    'games': [for (final game in games) game.toJson()],
    'selected': selected,
    'running': running,
    'language': language,
  };
}

/// A game's pictures as base64 JPEG, after the phone asked with [RemoteWantArt].
class RemoteArt extends RemoteMessage {
  const RemoteArt({required this.id, this.icon, this.background});
  final String id;
  final String? icon;
  final String? background;
  @override
  String get type => 'art';
  @override
  Map<String, Object?> get fields => {'id': id, 'icon': icon, 'background': background};
}

class RemoteWantArt extends RemoteMessage {
  const RemoteWantArt(this.id);
  final String id;
  @override
  String get type => 'wantArt';
  @override
  Map<String, Object?> get fields => {'id': id};
}

/// A move on the launcher's screen: left, right, up, down, select, back, options, l1, r1, capture.
class RemoteCommand extends RemoteMessage {
  const RemoteCommand(this.name);
  final String name;
  @override
  String get type => 'command';
  @override
  Map<String, Object?> get fields => {'name': name};
}

class RemoteSelect extends RemoteMessage {
  const RemoteSelect(this.id);
  final String id;
  @override
  String get type => 'select';
  @override
  Map<String, Object?> get fields => {'id': id};
}

/// What Play does for the game; another game playing is stopped first.
class RemoteLaunch extends RemoteMessage {
  const RemoteLaunch(this.id);
  final String id;
  @override
  String get type => 'launch';
  @override
  Map<String, Object?> get fields => {'id': id};
}

/// Stops the game playing.
class RemoteClose extends RemoteMessage {
  const RemoteClose();
  @override
  String get type => 'close';
  @override
  Map<String, Object?> get fields => const {};
}

/// The PS button: the launcher comes in front of the game.
class RemoteHome extends RemoteMessage {
  const RemoteHome();
  @override
  String get type => 'home';
  @override
  Map<String, Object?> get fields => const {};
}

/// The phone's pad layout for a game, kept with the game's settings; null goes back to the default.
class RemoteSaveLayout extends RemoteMessage {
  const RemoteSaveLayout(this.id, this.layout);
  final String id;
  final String? layout;
  @override
  String get type => 'saveLayout';
  @override
  Map<String, Object?> get fields => {'id': id, 'layout': layout};
}

/// A trophy just earned in the game playing.
class RemoteTrophy extends RemoteMessage {
  const RemoteTrophy({required this.name, required this.detail, required this.grade, this.icon});
  final String name;
  final String detail;

  /// platinum, gold, silver or bronze.
  final String grade;
  final String? icon;
  @override
  String get type => 'trophy';
  @override
  Map<String, Object?> get fields => {'name': name, 'detail': detail, 'grade': grade, 'icon': icon};
}

/// What the launcher is doing with a game, sent as it changes; null once it is done.
class RemoteActivityUpdate extends RemoteMessage {
  const RemoteActivityUpdate(this.activity);
  final RemoteActivity? activity;
  @override
  String get type => 'activity';
  @override
  Map<String, Object?> get fields => {'activity': activity?.toJson()};
}

/// The launcher's theme for the phone to wear: its deep and middle tones and its accent, #RRGGBB.
class RemoteLook extends RemoteMessage {
  const RemoteLook({required this.deep, required this.middle, required this.accent});
  final String deep;
  final String middle;
  final String accent;
  @override
  String get type => 'look';
  @override
  Map<String, Object?> get fields => {'deep': deep, 'middle': middle, 'accent': accent};
}

/// Remote Play: the phone wants the game's picture and sound at about this size, or no more.
class RemoteStream extends RemoteMessage {
  const RemoteStream({required this.on, this.width = 0, this.height = 0});
  final bool on;
  final int width;
  final int height;
  @override
  String get type => 'stream';
  @override
  Map<String, Object?> get fields => {'on': on, 'width': width, 'height': height};
}

/// The phone lost part of the picture and waits for a key frame.
class RemoteKeyFrame extends RemoteMessage {
  const RemoteKeyFrame();
  @override
  String get type => 'keyFrame';
  @override
  Map<String, Object?> get fields => const {};
}

/// How Remote Play is going for the phone: on, off, noPermission or noGame.
class RemoteStreaming extends RemoteMessage {
  const RemoteStreaming(this.state);
  final String state;
  @override
  String get type => 'streaming';
  @override
  Map<String, Object?> get fields => {'state': state};
}

/// Whether the game is being broadcast (Twitch, YouTube, RTMP), for the phone's Go Live button;
/// the phone starts and stops it with the commands broadcastStart and broadcastStop.
class RemoteBroadcast extends RemoteMessage {
  const RemoteBroadcast(this.on);
  final bool on;
  @override
  String get type => 'broadcast';
  @override
  Map<String, Object?> get fields => {'on': on};
}

/// A sign-in to AnyTogether for the other side to approve, both ways: the launcher asks its
/// phone, signed in, to approve the launcher's hand-off [id]; or the phone asks the launcher to
/// approve the phone's. [deviceName] is who asks.
class RemoteTogetherHandoff extends RemoteMessage {
  const RemoteTogetherHandoff({required this.id, required this.deviceName});
  final String id;
  final String deviceName;
  @override
  String get type => 'togetherHandoff';
  @override
  Map<String, Object?> get fields => {'id': id, 'deviceName': deviceName};
}

/// The answer to a [RemoteTogetherHandoff]: approved on the server, or turned down.
class RemoteTogetherHandoffAnswer extends RemoteMessage {
  const RemoteTogetherHandoffAnswer({required this.id, required this.approved});
  final String id;
  final bool approved;
  @override
  String get type => 'togetherHandoffAnswer';
  @override
  Map<String, Object?> get fields => {'id': id, 'approved': approved};
}

/// The game asks for text, or (null) no longer does: the phone shows its own keyboard with the
/// game's prompt. A phone that does not know this message ignores it.
class RemoteTextInput extends RemoteMessage {
  const RemoteTextInput(this.prompt);
  final RemoteTextPrompt? prompt;
  @override
  String get type => 'textInput';
  @override
  Map<String, Object?> get fields => {'prompt': prompt?.toJson()};
}

/// The text a phone typed for a prompt (its id), replacing the game's, and what to do with it.
/// ([typed] is the JSON's `text`: the message's own [text] is its JSON.)
class RemoteTyped extends RemoteMessage {
  const RemoteTyped({required this.prompt, required this.typed, required this.action});
  final int prompt;
  final String typed;
  final RemoteTypedAction action;
  @override
  String get type => 'typed';
  @override
  Map<String, Object?> get fields => {'prompt': prompt, 'text': typed, 'action': action.name};
}

/// The pad datagrams the launcher relays between the phone and the game, the engine's RemotePad
/// wire format: little-endian, with a magic, a version and a size up front.
abstract final class RemotePacket {
  static const inputMagic = 0x49525041;
  static const outputMagic = 0x4F525041;
  static const helloMagic = 0x48525041;
  static const pressMagic = 0x50525041;
  static const promptMagic = 0x4B525041;
  static const textMagic = 0x54525041;
  static const assistMagic = 0x41525041;
  static const assistSize = 16;

  /// Byte 13 of an input: 1 marks a device that helps the first player (assist).
  static const seatByte = 13;
  static const assistSeat = 1;
  static const version = 1;
  static const promptHeaderSize = 24;
  static const textHeaderSize = 20;

  /// The largest prompt or text datagram (the engine's LargestTextDatagram).
  static const largestText = 8192;
  static const inputSize = 80;
  static const outputSize = 32;
  static const helloSize = 16;
  static const pressSize = 24;

  /// The input packet's Options bit (offset 32), which a press holds to pause a game.
  static const options = 0x0008;

  /// The session of a well-formed input packet (its 64 bits as a Dart int), null for anything else.
  static int? inputSession(List<int> data) {
    if (!_header(data, inputMagic, inputSize)) return null;
    return ByteData.sublistView(Uint8List.fromList(data)).getUint64(24, Endian.little);
  }

  static bool isOutput(List<int> data) => _header(data, outputMagic, outputSize);

  static bool isHello(List<int> data) => _header(data, helloMagic, helloSize);

  /// The player a game's hello says its bridge's phone is, from 1; null while it is none.
  static int? helloPlayer(List<int> data) {
    if (!isHello(data)) return null;
    return data[8] == 0 ? null : data[8];
  }

  /// Whether a game's hello says its engine takes presses ([press]): bit 0 of byte 9. An engine
  /// without it drops them unread.
  static bool helloTakesPresses(List<int> data) => isHello(data) && data[9] & 1 != 0;

  /// Whether a game's hello says its engine tells what text the game asks for and takes the
  /// text typed for it ([text]): bit 1 of byte 9.
  static bool helloTakesText(List<int> data) => isHello(data) && data[9] & 2 != 0;

  /// Whether a game's hello says its engine takes assist (bit 2 of byte 9): the assist datagram
  /// and inputs marked as helping the first player.
  static bool helloTakesAssist(List<int> data) => isHello(data) && data[9] & 4 != 0;

  /// The assist datagram (APRA): whether the computer's controllers after the first player's
  /// help the first player instead of being players of their own.
  static Uint8List assist({required bool controllers}) {
    final bytes = Uint8List(assistSize);
    ByteData.sublistView(bytes)
      ..setUint32(0, assistMagic, Endian.little)
      ..setUint16(4, version, Endian.little)
      ..setUint16(6, assistSize, Endian.little)
      ..setUint32(8, controllers ? 1 : 0, Endian.little);
    return bytes;
  }

  /// An input packet marked as helping the first player (byte 13 = 1); anything else unchanged.
  static Uint8List helping(List<int> data) {
    final copy = Uint8List.fromList(data);
    if (inputSession(data) == null) return copy;
    copy[seatByte] = assistSeat;
    return copy;
  }

  /// A game's prompt (APRK): a record whose prompt is null when the game no longer asks for
  /// text; null for anything that is not a well-formed prompt.
  static ({RemoteTextPrompt? prompt})? prompt(List<int> data) {
    if (data.length < promptHeaderSize || data.length > largestText) return null;
    final bytes = Uint8List.fromList(data);
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(0, Endian.little) != promptMagic ||
        view.getUint16(4, Endian.little) != version ||
        view.getUint16(6, Endian.little) != data.length ||
        bytes[12] > 2) {
      return null;
    }
    final lengths = [
      for (final at in [18, 20, 22]) view.getUint16(at, Endian.little),
    ];
    if (promptHeaderSize + lengths[0] + lengths[1] + lengths[2] != data.length) return null;
    final id = view.getUint32(8, Endian.little);
    if (id == 0 || bytes[12] == 0) return (prompt: null);
    final strings = <String>[];
    var at = promptHeaderSize;
    for (final length in lengths) {
      strings.add(utf8.decode(bytes.sublist(at, at + length), allowMalformed: true));
      at += length;
    }
    return (
      prompt: RemoteTextPrompt(
        id: id,
        kind: bytes[12] == 1 ? 'keyboard' : 'dialog',
        title: strings[0],
        placeholder: strings[1],
        text: strings[2],
        maxLength: view.getUint16(16, Endian.little),
        multiline: bytes[13] & 1 != 0,
        keyboard: bytes[14] < RemoteTextPrompt.keyboards.length ? RemoteTextPrompt.keyboards[bytes[14]] : 'text',
        enter: bytes[15] < RemoteTextPrompt.enters.length ? RemoteTextPrompt.enters[bytes[15]] : 'default',
      ),
    );
  }

  /// A prompt as the engine sends it, null for none (a stand-in game in the tests).
  static Uint8List promptPacket(RemoteTextPrompt? prompt) {
    final parts = [
      for (final part in [prompt?.title ?? '', prompt?.placeholder ?? '', prompt?.text ?? '']) utf8.encode(part),
    ];
    final size = promptHeaderSize + parts.fold<int>(0, (sum, part) => sum + part.length);
    final bytes = Uint8List(size);
    final view = ByteData.sublistView(bytes)
      ..setUint32(0, promptMagic, Endian.little)
      ..setUint16(4, version, Endian.little)
      ..setUint16(6, size, Endian.little)
      ..setUint32(8, prompt?.id ?? 0, Endian.little);
    if (prompt != null) {
      bytes[12] = prompt.kind == 'keyboard' ? 1 : 2;
      bytes[13] = prompt.multiline ? 1 : 0;
      bytes[14] = max(0, RemoteTextPrompt.keyboards.indexOf(prompt.keyboard));
      bytes[15] = max(0, RemoteTextPrompt.enters.indexOf(prompt.enter));
      view.setUint16(16, prompt.maxLength.clamp(0, 0xFFFF), Endian.little);
    }
    var at = promptHeaderSize;
    for (var index = 0; index < 3; index++) {
      view.setUint16(18 + index * 2, parts[index].length, Endian.little);
      bytes.setRange(at, at + parts[index].length, parts[index]);
      at += parts[index].length;
    }
    return bytes;
  }

  /// The text a phone typed (APRT), for the engine: the whole text, replacing the game's, then
  /// the action. [id] tells copies apart; the text is cut on a character to fit one datagram.
  static Uint8List text({
    required int prompt,
    required int id,
    required RemoteTypedAction action,
    required String text,
  }) {
    final utf = <int>[];
    for (final rune in text.runes) {
      final encoded = utf8.encode(String.fromCharCode(rune));
      if (textHeaderSize + utf.length + encoded.length > largestText) break;
      utf.addAll(encoded);
    }
    final bytes = Uint8List(textHeaderSize + utf.length);
    ByteData.sublistView(bytes)
      ..setUint32(0, textMagic, Endian.little)
      ..setUint16(4, version, Endian.little)
      ..setUint16(6, bytes.length, Endian.little)
      ..setUint32(8, prompt & 0xFFFFFFFF, Endian.little)
      ..setUint32(12, id & 0xFFFFFFFF, Endian.little)
      ..setUint16(18, utf.length, Endian.little);
    bytes[16] = action.index;
    bytes.setRange(textHeaderSize, bytes.length, utf);
    return bytes;
  }

  /// A game hello, as the engine's bridge sends it (for tests and tools).
  static Uint8List hello({
    int player = 0,
    bool takesPresses = false,
    bool takesText = false,
    bool takesAssist = false,
  }) {
    final bytes = Uint8List(helloSize);
    ByteData.sublistView(bytes)
      ..setUint32(0, helloMagic, Endian.little)
      ..setUint16(4, version, Endian.little)
      ..setUint16(6, helloSize, Endian.little);
    bytes[8] = player;
    bytes[9] = (takesPresses ? 1 : 0) | (takesText ? 2 : 0) | (takesAssist ? 4 : 0);
    return bytes;
  }

  /// A press (APRP): [buttons] (the input packet's bits) held [holdMs] on the game's first
  /// player's pad without taking a player. The engine drops a copy with the same [id], so a press
  /// is sent a few times against loss and the next one gets another id.
  static Uint8List press({required int id, required int buttons, int holdMs = 160}) {
    final bytes = Uint8List(pressSize);
    ByteData.sublistView(bytes)
      ..setUint32(0, pressMagic, Endian.little)
      ..setUint16(4, version, Endian.little)
      ..setUint16(6, pressSize, Endian.little)
      ..setUint32(8, id & 0xFFFFFFFF, Endian.little)
      ..setUint32(12, buttons, Endian.little)
      ..setUint16(16, holdMs.clamp(50, 2000), Endian.little);
    return bytes;
  }

  static bool _header(List<int> data, int magic, int size) {
    if (data.length != size) return false;
    final view = ByteData.sublistView(Uint8List.fromList(data.sublist(0, 8)));
    return view.getUint32(0, Endian.little) == magic &&
        view.getUint16(4, Endian.little) == version &&
        view.getUint16(6, Endian.little) == size;
  }
}
