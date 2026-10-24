import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'game_library.dart';
import 'game_process.dart';
import 'game_settings.dart';
import 'host.dart';
import 'installer.dart';
import 'remote/mdns.dart';
import 'remote/paired_devices.dart';
import 'remote/remote_protocol.dart';
import 'remote/remote_server.dart';
import 'self_unwrap.dart';
import 'toolkit.dart';
import 'toolkit_download.dart';

const usage = '''usage: anyps5_tool <command>
  unwrap <self> <elf>                      a decrypted SELF container as a clean ELF
  scan <games folder>                      the dumps found, one per line
  engine [<version>] [--folder <dir>]      download upstream's toolkit for this system (the latest
                                           release unless a version is given) into the launcher's
                                           toolkits folder, or <dir>; prints the toolkit's folder
  install <game folder> <games folder>     unwrap, relink and lay out (ANYPS5_TOOLKIT names the toolkit)
  play <game folder> <games folder>        start an installed game with its saved settings
  remote [--allow-all] [--hidden] [--port <port>] [--devices <file>] [--games <folder>]
                                           the phone server until stopped''';

/// The launcher's pipeline on the command line, for scripted checks on a Windows or Linux
/// machine without the interface: the same code the launcher runs.
Future<int> runCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
  HostSystem? system,
  Future<void>? until,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final env = environment ?? Platform.environment;
  final host = system ?? HostSystem.current;
  int fail(String message) {
    errors.writeln(message);
    return 2;
  }

  if (arguments.isEmpty) return fail(usage);
  switch (arguments.first) {
    case 'unwrap' when arguments.length == 3:
      try {
        final size = SelfUnwrap.unwrapFile(arguments[1], arguments[2]);
        output.writeln('wrote ${arguments[2]}, $size bytes');
        return 0;
      } on SelfRefused catch (error) {
        return fail('FAIL: ${arguments[1]}: ${error.reason}');
      } on FileSystemException catch (error) {
        return fail('FAIL: ${arguments[1]}: ${error.message}');
      }
    case 'scan' when arguments.length == 2:
      final root = arguments[1];
      for (final game in GameLibrary.scan(root)) {
        final installed = Installer.record(Installer.installedFolder(game, root), system: host) != null;
        output.writeln(
          [game.titleId, game.name, game.executable.name, installed ? 'installed' : 'locked', game.folder].join('\t'),
        );
      }
      return 0;
    case 'engine':
      return _engine(arguments.skip(1).toList(), output, errors, env, host);
    case 'install' when arguments.length == 3:
      final toolkit = Toolkit.locate(const [], system: host, environment: env);
      if (toolkit == null) return fail('no toolkit: set ANYPS5_TOOLKIT');
      final game = GameLibrary.inspect(arguments[1]);
      if (game == null) return fail('not a game folder: ${arguments[1]}');
      final paths = AppPaths.forSystem(host, environment: env);
      final settings = GameSettingsStore(paths.gameSettingsFolder).load(game.slug);
      final started = DateTime.now();
      final lastShown = <InstallStep, int>{};
      final installer = Installer(
        game: game,
        toolkit: toolkit,
        root: arguments[2],
        resolution: settings.resolution,
        onProgress: (step, fraction) {
          final percent = (fraction * 100).round();
          if (lastShown[step] == percent) return;
          lastShown[step] = percent;
          if (percent % 10 == 0) output.writeln('[${step.name} ${percent.toString().padLeft(3)}%]');
        },
        onLog: output.writeln,
      );
      try {
        final installed = await installer.run();
        final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
        output.writeln('installed $installed in ${seconds.toStringAsFixed(1)} s');
        return 0;
      } on Object catch (error) {
        return fail('FAIL: $error');
      }
    case 'play' when arguments.length == 3:
      final game = GameLibrary.inspect(arguments[1]);
      if (game == null) return fail('not a game folder: ${arguments[1]}');
      final installed = Installer.installedFolder(game, arguments[2]);
      if (Installer.record(installed, system: host) == null) return fail('not installed: ${game.titleId}');
      final paths = AppPaths.forSystem(host, environment: env);
      final settings = GameSettingsStore(paths.gameSettingsFolder).load(game.slug);
      final inputFile = p.join(paths.inputFilesFolder, '${game.slug}.ini');
      settings.writeInputFile(inputFile);
      final running = await GameProcess.start(
        installed: installed,
        system: host,
        environment: settings.environment(
          launcherLanguage: 1,
          inputFile: inputFile,
          screenshots: paths.pictures,
          shaderCacheFolder: paths.shaderCache(game.slug),
        ),
        logFile: paths.logFile(game.titleId),
      );
      output.writeln('started ${game.titleId} (pid ${running.pid}), log ${paths.logFile(game.titleId)}');
      final code = await running.exitCode;
      output.writeln('exit $code');
      return code;
    case 'remote':
      return _remote(arguments.skip(1).toList(), output, errors, env, host, until);
    default:
      return fail(usage);
  }
}

/// The engine download the first start and Settings make, on the command line.
Future<int> _engine(
  List<String> options,
  StringSink output,
  StringSink errors,
  Map<String, String> env,
  HostSystem host,
) async {
  final at = options.indexOf('--folder');
  final folder = at >= 0 && at + 1 < options.length
      ? options[at + 1]
      : AppPaths.forSystem(host, environment: env).toolkits;
  final rest = [
    for (var i = 0; i < options.length; i++)
      if (i != at && i != at + 1) options[i],
  ];
  if (rest.length > 1) {
    errors.writeln(usage);
    return 2;
  }
  try {
    final github = GitHubReleases();
    final wanted = rest.isEmpty ? null : (rest.first.startsWith('v') ? rest.first.substring(1) : rest.first);
    final release = wanted == null
        ? await github.latest()
        : (await github.all()).where((release) => release.version == wanted).firstOrNull;
    if (release == null) {
      errors.writeln('no upstream release $wanted');
      return 2;
    }
    final package = release.packageFor(host);
    if (package == null) {
      errors.writeln('upstream ${release.tag} has nothing for ${host.name}');
      return 2;
    }
    output.writeln(
      'upstream ${release.tag}: ${package.relinker.name} + ${package.libraries.name}, '
      '${(package.size / 1048576).toStringAsFixed(1)} MB, ${package.verified ? 'sha256 from GitHub' : 'no checksum'}',
    );
    var shown = -1;
    final started = DateTime.now();
    final toolkit = await ToolkitStore(folder, system: host).install(
      package,
      onProgress: (progress) {
        final percent = (progress.fraction * 100).floor();
        if (progress.phase == ToolkitPhase.download && percent ~/ 10 != shown ~/ 10) {
          shown = percent;
          output.writeln('[download ${percent.toString().padLeft(3)}%]');
        } else if (progress.phase != ToolkitPhase.download) {
          output.writeln('[${progress.phase.name}]');
        }
      },
    );
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    output.writeln(
      'toolkit ${toolkit.version}: ${toolkit.libraryFiles.length} libraries in ${seconds.toStringAsFixed(1)} s',
    );
    output.writeln(toolkit.root);
    return 0;
  } on ToolkitFailure catch (error) {
    errors.writeln('FAIL: ${error.message}');
    return 2;
  } on IOException catch (error) {
    errors.writeln('FAIL: $error');
    return 2;
  }
}

Future<int> _remote(
  List<String> options,
  StringSink output,
  StringSink errors,
  Map<String, String> env,
  HostSystem host,
  Future<void>? until,
) async {
  String? value(String name) {
    final at = options.indexOf(name);
    return at >= 0 && at + 1 < options.length ? options[at + 1] : null;
  }

  final allowAll = options.contains('--allow-all');
  final hidden = options.contains('--hidden');
  final port = int.tryParse(value('--port') ?? '') ?? RemoteServer.preferredPort;
  final devices = PairedDevices(value('--devices') ?? AppPaths.forSystem(host, environment: env).pairedDevicesFile);
  final gamesFolder = value('--games');
  final games = gamesFolder == null ? const <Game>[] : GameLibrary.scan(gamesFolder);
  late final RemoteServer server;
  void publishLibrary() => server.publish(
    RemoteLibrary(
      games: [
        for (final game in games)
          RemoteGame(id: game.id, name: game.name, state: RemoteGameState.installed, art: game.titleId),
      ],
      selected: games.isEmpty ? null : games.first.id,
      language: 'en',
    ),
  );
  server = RemoteServer(
    name: Platform.localHostname,
    devices: devices,
    controlPort: port,
    events: RemoteEvents(
      pairing: (request) {
        output.writeln('pairing ${request.deviceName} code ${request.code}');
        if (allowAll) server.respond(request.id, allow: true);
      },
      connected: (name) {
        output.writeln('connected $name');
        publishLibrary();
      },
      disconnected: () => output.writeln('disconnected'),
      request: (message, device) => output.writeln('from $device: ${message.text}'),
      players: () => output.writeln('players ${server.phonePlayers}'),
    ),
  );
  try {
    await server.start();
  } on SocketException catch (error) {
    errors.writeln('the phone server did not start: ${error.message}');
    return 2;
  }
  ServiceAdvertiser? advertiser;
  if (!hidden) {
    advertiser = MdnsResponder(
      instance: Platform.localHostname,
      serviceType: RemoteServer.serviceType,
      port: server.port!,
    );
    try {
      await advertiser.start();
    } on Object catch (error) {
      errors.writeln('not advertised: $error');
      advertiser = null;
    }
  }
  output.writeln('listening on ${server.port}, pad on udp ${server.udpPort}, bridges ${server.bridgeEnvironment}');
  await (until ?? ProcessSignal.sigint.watch().first);
  await advertiser?.stop();
  await server.stop();
  return 0;
}
