import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

import '../desktop/desktop.dart';
import '../host.dart';
import '../replay_buffer.dart' show ProcessStarter;
import 'game_sound.dart';
import 'video_encoders.dart';

/// Where a broadcast goes: Twitch's and YouTube's own ingest over TLS, or the user's server.
enum BroadcastService {
  twitch,
  youtube,
  custom;

  /// The ingest Twitch and YouTube publish for encoders; a custom server's URL is the user's.
  String? get ingest => switch (this) {
    twitch => 'rtmps://ingest.global-contribute.live-video.net/app',
    youtube => 'rtmps://a.rtmps.youtube.com/live2',
    custom => null,
  };

  /// Where the user finds the stream key.
  Uri? get keyPage => switch (this) {
    twitch => Uri.parse('https://dashboard.twitch.tv/settings/stream'),
    youtube => Uri.parse('https://www.youtube.com/live_dashboard'),
    custom => null,
  };

  /// The service's own name; the custom server's is a text of the language files.
  String get brand => switch (this) {
    twitch => 'Twitch',
    youtube => 'YouTube',
    custom => 'RTMP',
  };
}

/// The picture's size, frames a second and bit rate, as streaming services suggest them. The
/// macOS launcher's BroadcastSettings.Quality, with the same names in the settings file.
enum BroadcastQuality {
  hd720p60(1280, 720, 60, 3000000),
  hd1080p30(1920, 1080, 30, 4500000),
  hd1080p60(1920, 1080, 60, 6000000);

  const BroadcastQuality(this.width, this.height, this.frameRate, this.bitRate);
  final int width;
  final int height;
  final int frameRate;
  final int bitRate;

  /// "720p60, 3 Mbit/s"
  String get title {
    final rate = bitRate / 1000000;
    final mbit = rate == rate.roundToDouble() ? '${rate.round()}' : rate.toStringAsFixed(1);
    return '${height}p$frameRate, $mbit Mbit/s';
  }
}

/// Where and how the game is broadcast. The stream key is kept apart ([BroadcastKeys]).
class BroadcastSettings {
  BroadcastSettings({
    this.service = BroadcastService.twitch,
    this.customUrl = '',
    this.quality = BroadcastQuality.hd720p60,
    this.viewerLink = '',
  });

  factory BroadcastSettings.fromJson(Map<String, dynamic> json) => BroadcastSettings(
    service: BroadcastService.values.where((service) => service.name == json['service']).firstOrNull ?? BroadcastService.twitch,
    customUrl: json['customURL'] is String ? json['customURL'] as String : '',
    quality: BroadcastQuality.values.where((quality) => quality.name == json['quality']).firstOrNull ?? BroadcastQuality.hd720p60,
    viewerLink: json['viewerLink'] is String ? json['viewerLink'] as String : '',
  );

  BroadcastService service;

  /// The custom server, rtmp:// or rtmps://, with or without the key at its end.
  String customUrl;
  BroadcastQuality quality;

  /// The page viewers watch on (twitch.tv/name), shown and copied while live.
  String viewerLink;

  static const audioBitRate = 160000;

  String get serverUrl => service.ingest ?? customUrl;

  /// The link viewers open: the one given, or none.
  Uri? get viewerUri {
    final text = viewerLink.trim();
    if (text.isEmpty) return null;
    return Uri.tryParse(text.contains('://') ? text : 'https://$text');
  }

  Map<String, Object> toJson() => {
    'service': service.name,
    'customURL': customUrl,
    'quality': quality.name,
    'viewerLink': viewerLink,
  };

  static BroadcastSettings load(String file) {
    try {
      return BroadcastSettings.fromJson(jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>);
    } on Object {
      return BroadcastSettings();
    }
  }

  void save(String file) {
    try {
      File(file)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(toJson()));
    } on FileSystemException {
      // Settings unsaved: they hold until the launcher closes.
    }
  }
}

/// Why a broadcast cannot start with what was set up.
enum EndpointProblem { notRtmp, noHost, noApplication, noKey }

/// The server a broadcast is published to, read from an rtmp:// or rtmps:// URL and a stream key
/// (the macOS launcher's RTMPEndpoint): host, port (1935, or 443 over TLS), the application
/// (live2, app, or app/instance with any query).
class RtmpEndpoint {
  const RtmpEndpoint({required this.tls, required this.host, required this.port, required this.app, required this.streamKey});

  final bool tls;
  final String host;
  final int port;
  final String app;
  final String streamKey;

  /// The URL ffmpeg publishes to, the key at its end.
  String get publishUrl {
    final defaultPort = tls ? 443 : 1935;
    final authority = host.contains(':') ? '[$host]' : host;
    return '${tls ? 'rtmps' : 'rtmp'}://$authority${port == defaultPort ? '' : ':$port'}/$app/$streamKey';
  }

  /// [url] with [key]; with no key, a URL of more than one path part ends in it
  /// (rtmp://host/app/key), as some services hand out the whole thing.
  static RtmpEndpoint parse(String url, String key) {
    final text = url.trim();
    var streamKey = key.trim();
    final lower = text.toLowerCase();
    final bool tls;
    if (lower.startsWith('rtmps://')) {
      tls = true;
    } else if (lower.startsWith('rtmp://')) {
      tls = false;
    } else {
      throw EndpointProblem.notRtmp;
    }
    final rest = text.substring(tls ? 8 : 7);
    final slash = rest.indexOf('/');
    final authority = slash < 0 ? rest : rest.substring(0, slash);
    var path = slash < 0 ? '' : rest.substring(slash + 1);
    var host = authority;
    var port = tls ? 443 : 1935;
    final colon = authority.lastIndexOf(':');
    if (colon >= 0 && !authority.endsWith(']')) {
      host = authority.substring(0, colon);
      port = int.tryParse(authority.substring(colon + 1)) ?? port;
    }
    host = host.replaceAll('[', '').replaceAll(']', '');
    if (host.isEmpty) throw EndpointProblem.noHost;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (streamKey.isEmpty && path.split('/').where((part) => part.isNotEmpty).length > 1) {
      final last = path.lastIndexOf('/');
      streamKey = path.substring(last + 1);
      path = path.substring(0, last);
    }
    if (path.isEmpty) throw EndpointProblem.noApplication;
    if (streamKey.isEmpty) throw EndpointProblem.noKey;
    return RtmpEndpoint(tls: tls, host: host, port: port, app: path, streamKey: streamKey);
  }
}

/// The stream keys, one a service, in a file only the user can read (0600 on Linux; under the
/// user's own AppData on Windows).
class BroadcastKeys {
  BroadcastKeys(this.file, {this.system = HostSystem.linux});

  final String file;
  final HostSystem system;

  Map<String, String> _all() {
    try {
      return (jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, '$value'),
      );
    } on Object {
      return {};
    }
  }

  String keyFor(BroadcastService service) => _all()[service.name] ?? '';

  void setKey(BroadcastService service, String key) {
    final keys = _all();
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      keys.remove(service.name);
    } else {
      keys[service.name] = trimmed;
    }
    try {
      final target = File(file)..parent.createSync(recursive: true);
      target.writeAsStringSync(jsonEncode(keys));
      if (system != HostSystem.windows) Process.runSync('chmod', ['600', target.path]);
    } on Object {
      // Unsaved: asked again next time.
    }
  }

  /// Every key kept, for a report to take out wherever one appears.
  List<String> get secrets => _all().values.toList();

  /// "••••••3f9a": enough to tell which key it is.
  static String masked(String key) {
    if (key.length <= 4) return '•' * key.length;
    return '${'•' * min(10, key.length - 4)}${key.substring(key.length - 4)}';
  }
}

/// How a broadcast is going.
sealed class BroadcastPhase {
  const BroadcastPhase();
  bool get active => this is BroadcastStarting || this is BroadcastLive || this is BroadcastReconnecting;
}

class BroadcastOff extends BroadcastPhase {
  const BroadcastOff();
}

class BroadcastStarting extends BroadcastPhase {
  const BroadcastStarting();
}

class BroadcastLive extends BroadcastPhase {
  const BroadcastLive();
}

class BroadcastReconnecting extends BroadcastPhase {
  const BroadcastReconnecting(this.attempt, this.delay);
  final int attempt;
  final Duration delay;
}

class BroadcastFailed extends BroadcastPhase {
  const BroadcastFailed(this.reason);
  final String reason;
}

/// The numbers a live broadcast shows.
class BroadcastStats {
  Duration duration = Duration.zero;
  int bitRate = 0;
  int frames = 0;
  int dropped = 0;

  double get droppedPercent => frames == 0 ? 0 : dropped * 100 / frames;
}

/// Broadcasting the game playing: ffmpeg records the game's area of the screen, takes the game's
/// sound on its standard input (made steady, [SteadyPcm]), encodes both (the graphics card's
/// H.264 encoder when one works, AAC for the sound) and publishes FLV to the RTMP or RTMPS
/// server. ffmpeg's progress lines give the numbers. A dropped connection is tried again a few
/// times, waiting longer each time.
class Broadcaster {
  Broadcaster({
    required this.ffmpeg,
    required this.system,
    required this.encoders,
    required this.areaOf,
    required this.soundOf,
    required this.changed,
    this.environment = const {},
    ProcessStarter? start,
    this.retryDelays = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10), Duration(seconds: 20), Duration(seconds: 30)],
    this.log,
  }) : _start = start ?? ((executable, arguments) => Process.start(executable, arguments));

  final String ffmpeg;
  final HostSystem system;
  final Map<String, String> environment;
  final EncoderChoice encoders;
  final ScreenArea? Function(int pid) areaOf;
  final GameSound Function(int pid) soundOf;

  /// The phase or the numbers changed.
  final void Function() changed;
  final List<Duration> retryDelays;
  final ProcessStarter _start;
  final void Function(String line)? log;

  /// The failure when ffmpeg has no H.264 encoder that works on this computer.
  static const noEncoder = 'no-encoder';

  BroadcastPhase phase = const BroadcastOff();
  final stats = BroadcastStats();

  /// The game broadcast, while one is.
  int? pid;
  RtmpEndpoint? _endpoint;
  BroadcastQuality _quality = BroadcastQuality.hd720p60;
  VideoEncoder? _encoder;
  Process? _process;
  GameSound? _sound;
  SteadyPcm? _steady;
  Timer? _tick;
  Timer? _retry;
  int _attempt = 0;
  final _live = Stopwatch();
  ScreenArea? _area;

  /// ffmpeg's arguments to publish the game in [area] to [endpoint].
  List<String> arguments(VideoEncoder encoder, ScreenArea? area, RtmpEndpoint endpoint, BroadcastQuality quality) {
    final width = quality.width;
    final height = quality.height;
    return [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      ...encoder.deviceArguments,
      ...ScreenGrab.input(system: system, environment: environment, framesPerSecond: quality.frameRate, area: area),
      '-thread_queue_size',
      '1024',
      '-f',
      's16le',
      '-ar',
      '48000',
      '-ac',
      '2',
      '-i',
      'pipe:0',
      '-map',
      '0:v',
      '-map',
      '1:a',
      // One size whatever shape the window has: letterboxed, so the stream never changes size.
      '-vf',
      'scale=$width:$height:force_original_aspect_ratio=decrease:flags=bicubic,'
          'pad=$width:$height:(ow-iw)/2:(oh-ih)/2,fps=${quality.frameRate},${encoder.filterTail}',
      ...encoder.arguments(use: EncodeUse.broadcast, bitRate: quality.bitRate, keyEvery: quality.frameRate * 2),
      '-af',
      'aresample=async=1',
      '-c:a',
      'aac',
      '-b:a',
      '${BroadcastSettings.audioBitRate}',
      '-ar',
      '48000',
      '-progress',
      'pipe:1',
      '-f',
      'flv',
      endpoint.publishUrl,
    ];
  }

  /// Broadcasts the game with process [pid] to [endpoint].
  Future<void> start({required int pid, required RtmpEndpoint endpoint, required BroadcastQuality quality}) async {
    if (phase.active) return;
    this.pid = pid;
    _endpoint = endpoint;
    _quality = quality;
    _attempt = 0;
    _set(const BroadcastStarting());
    final encoder = await encoders.encoder;
    if (!phase.active) return;
    if (encoder == null) {
      log?.call('broadcast: no encoder works (${encoders.tried.join(', ')})');
      return _fail(noEncoder);
    }
    _encoder = encoder;
    final sound = soundOf(pid);
    _sound = sound;
    await sound.start((samples) => _steady?.add(samples));
    // Runs until ffmpeg ends; the phase says how it goes.
    unawaited(_run());
  }

  Future<void> _run() async {
    final encoder = _encoder;
    final endpoint = _endpoint;
    final pid = this.pid;
    if (encoder == null || endpoint == null || pid == null || !phase.active) return;
    final area = areaOf(pid);
    _area = area;
    final Process process;
    try {
      process = await _start(ffmpeg, arguments(encoder, area, endpoint, _quality));
    } on Object catch (error) {
      return _fail('$error');
    }
    if (!phase.active) {
      process.kill();
      return;
    }
    _process = process;
    final steady = SteadyPcm((samples) {
      try {
        process.stdin.add(samples);
      } on Object {
        // ffmpeg is ending: its exit says why.
      }
    });
    _steady = steady;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 20), (_) {
      steady.tick();
      // The window changed (full screen and back): published again from where it is now.
      final now = areaOf(pid);
      if (now != null && _area != null && now != _area && phase is BroadcastLive) {
        _area = now;
        process.kill();
      }
    });
    unawaited(process.stdin.done.catchError((_) {}));
    final progress = <String, String>{};
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final equals = line.indexOf('=');
      if (equals < 0) return;
      progress[line.substring(0, equals).trim()] = line.substring(equals + 1).trim();
      if (line.startsWith('progress=')) _progress(progress);
    }, onError: (_) {});
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen((text) {
      if (errors.length < 4000) errors.write(text);
    }, onError: (_) {});
    final code = await process.exitCode;
    if (_process != process) return;
    _process = null;
    _tick?.cancel();
    _steady = null;
    if (!phase.active) return;
    final reason = _reason(errors.toString(), code);
    log?.call('broadcast: ffmpeg ended ($code): ${_scrub(errors.toString().trim())}');
    if (phase is BroadcastStarting && _attempt == 0 && !_wentLive) return _fail(reason);
    if (_attempt >= retryDelays.length) return _fail(reason);
    final delay = retryDelays[_attempt++];
    _set(BroadcastReconnecting(_attempt, delay));
    _retry = Timer(delay, () => unawaited(_run()));
  }

  bool _wentLive = false;

  void _progress(Map<String, String> progress) {
    final frames = int.tryParse(progress['frame'] ?? '') ?? 0;
    final dropped = int.tryParse(progress['drop_frames'] ?? '') ?? 0;
    final rate = RegExp(r'([\d.]+)kbits/s').firstMatch(progress['bitrate'] ?? '');
    if (frames > 0 && phase is! BroadcastLive) {
      if (!_wentLive) {
        _live
          ..reset()
          ..start();
      }
      _wentLive = true;
      _attempt = 0;
      _set(const BroadcastLive());
    }
    stats
      ..frames = frames
      ..dropped = dropped
      ..bitRate = rate == null ? stats.bitRate : (double.parse(rate.group(1)!) * 1000).round()
      ..duration = _live.elapsed;
    changed();
  }

  /// What ffmpeg's error says, in short.
  static String _reason(String errors, int code) {
    final lines = errors.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
    if (lines.isEmpty) return 'ffmpeg ended ($code)';
    final last = _scrub(lines.last);
    return last.length > 160 ? '${last.substring(0, 160)}…' : last;
  }

  /// A line with the stream key taken out (ffmpeg names the URL it failed on).
  static String _scrub(String text) => text.replaceAll(RegExp(r'rtmps?://\S+'), 'rtmp://…');

  void _fail(String reason) {
    _cleanUp();
    _set(BroadcastFailed(reason));
  }

  void _set(BroadcastPhase next) {
    phase = next;
    changed();
  }

  void _cleanUp() {
    _retry?.cancel();
    _retry = null;
    _tick?.cancel();
    _tick = null;
    _steady = null;
    final process = _process;
    _process = null;
    process?.kill();
    final sound = _sound;
    _sound = null;
    unawaited(sound?.stop());
    _live.stop();
    _wentLive = false;
    pid = null;
  }

  void stop() {
    if (!phase.active) return;
    _cleanUp();
    _set(const BroadcastOff());
  }

  /// The settings folder's files for broadcasting.
  static String settingsFile(String config) => p.join(config, 'Broadcast', 'settings.json');
  static String keysFile(String config) => p.join(config, 'Broadcast', 'keys.json');
}
