// The launcher's pipeline on the command line: dart run tool/anyps5_tool.dart <command>
// (run without arguments for the commands).
import 'dart:io';

import 'package:anyps5_desktop/core/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
