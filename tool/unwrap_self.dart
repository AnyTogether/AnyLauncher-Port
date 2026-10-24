// Unwraps a decrypted SELF container into a clean ELF, as upstream's tools/unwrap_self.py does:
// dart run tool/unwrap_self.dart <input.self> <output.elf>
import 'dart:io';

import 'package:anyps5_desktop/core/self_unwrap.dart';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('usage: unwrap_self.dart <input.self> <output.elf>');
    exitCode = 64;
    return;
  }
  try {
    final size = SelfUnwrap.unwrapFile(arguments[0], arguments[1]);
    stdout.writeln('wrote ${arguments[1]}, $size bytes');
  } on SelfRefused catch (error) {
    stderr.writeln('FAIL: ${arguments[0]}: ${error.reason}');
    exitCode = 2;
  } on FileSystemException catch (error) {
    stderr.writeln('FAIL: ${arguments[0]}: ${error.message}');
    exitCode = 2;
  }
}
