import 'dart:ffi';
import 'dart:io';

/// A running tool's priority, and stopping it where it is: what a background unlock needs so a
/// game or the user's own work comes first.
///
/// Windows: SetPriorityClass (idle class in the background, normal again), NtSuspendProcess and
/// NtResumeProcess. POSIX: setpriority(2) (nice 19; going back needs privileges the launcher does
/// not have, so a promoted unlock keeps its nice value there), SIGSTOP and SIGCONT.
abstract final class ProcessControl {
  /// Puts [pid] in the background band; false when the system refused.
  static bool lower(int pid) {
    try {
      return Platform.isWindows ? _windowsPriority(pid, _idlePriorityClass) : _setPriority(pid, 19);
    } on Object {
      return false;
    }
  }

  /// Back to normal priority; false when the system refused (POSIX, unprivileged).
  static bool normal(int pid) {
    try {
      return Platform.isWindows ? _windowsPriority(pid, _normalPriorityClass) : _setPriority(pid, 0);
    } on Object {
      return false;
    }
  }

  /// The nice value of [pid] (POSIX), null where it cannot be read.
  static int? niceness(int pid) {
    if (Platform.isWindows) return null;
    try {
      final get = DynamicLibrary.process().lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'getpriority',
      );
      return get(_prioProcess, pid);
    } on Object {
      return null;
    }
  }

  /// Stops [pid] where it is.
  static bool suspend(int pid) {
    try {
      return Platform.isWindows
          ? _windowsSuspend(pid, 'NtSuspendProcess')
          : Process.killPid(pid, ProcessSignal.sigstop);
    } on Object {
      return false;
    }
  }

  /// Lets a stopped [pid] go on.
  static bool resume(int pid) {
    try {
      return Platform.isWindows ? _windowsSuspend(pid, 'NtResumeProcess') : Process.killPid(pid, ProcessSignal.sigcont);
    } on Object {
      return false;
    }
  }

  static const _prioProcess = 0;
  static const _idlePriorityClass = 0x40;
  static const _normalPriorityClass = 0x20;
  static const _processSetInformation = 0x0200;
  static const _processSuspendResume = 0x0800;

  static bool _setPriority(int pid, int value) {
    final set = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Int32, Uint32, Int32), int Function(int, int, int)>('setpriority');
    return set(_prioProcess, pid, value) == 0;
  }

  static int _open(int access, int pid) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final open = kernel.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>(
      'OpenProcess',
    );
    return open(access, 0, pid);
  }

  static void _close(int handle) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle')(handle);
  }

  static bool _windowsPriority(int pid, int priorityClass) {
    final handle = _open(_processSetInformation, pid);
    if (handle == 0) return false;
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final set = kernel.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('SetPriorityClass');
      return set(handle, priorityClass) != 0;
    } finally {
      _close(handle);
    }
  }

  static bool _windowsSuspend(int pid, String call) {
    final handle = _open(_processSuspendResume, pid);
    if (handle == 0) return false;
    try {
      final ntdll = DynamicLibrary.open('ntdll.dll');
      final function = ntdll.lookupFunction<Int32 Function(IntPtr), int Function(int)>(call);
      return function(handle) == 0;
    } finally {
      _close(handle);
    }
  }
}
