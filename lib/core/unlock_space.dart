/// What an unlock will write on the games folder's drive, worked out before it starts, so a full
/// drive is said up front instead of after gigabytes were written and thrown away.
///
/// The figure is a safe estimate, not exact: the unwrapped executable and modules can each be up
/// to twice the dump's files (a SELF holds its segments compressed or sparse), the relinker's
/// output as much again, and the installed game's copy of that output once more where it cannot
/// be hard linked. Then what is copied rather than linked (the toolkit's libraries from another
/// drive, the game's files where no link works), and a margin for the small files and the system.
class UnlockSpace {
  const UnlockSpace({
    required this.executables,
    this.libraries = 0,
    this.copied = 0,
    required this.linksOutput,
    this.keptRelink,
  });

  /// Room left over beyond the estimate.
  static const margin = 512 << 20;

  /// The dump's eboot.bin and modules, as they are in the dump.
  final int executables;

  /// The toolkit's libraries the installed game gets as copies (0 when they are hard linked).
  final int libraries;

  /// The game's files copied into the installed game (0 when they are linked).
  final int copied;

  /// The store hard links the relinker's output into the installed game, so it is not written
  /// twice.
  final bool linksOutput;

  /// The size of the relinker's kept output this unlock reuses, null when it relinks.
  final int? keptRelink;

  /// Part of the room is the game's files, copied.
  bool get copies => copied > 0;

  /// The bytes the drive must have free.
  int get needed {
    final int binaries;
    final kept = keptRelink;
    if (kept != null) {
      binaries = linksOutput ? 0 : kept;
    } else {
      final unwrapped = executables * 2;
      final relinked = executables * 2;
      binaries = unwrapped + relinked + (linksOutput ? 0 : relinked);
    }
    return binaries + libraries + copied + margin;
  }

  /// What stops the unlock, null when [free] is enough or not known: a drive that does not say
  /// never blocks, the unlock then reports a full disk itself as before.
  SpaceShortage? shortage({required int? free, required String folder}) {
    if (free == null || free >= needed) return null;
    return SpaceShortage(needed: needed, free: free, folder: folder, copying: copies);
  }
}

/// An unlock that was not started for want of room.
class SpaceShortage implements Exception {
  const SpaceShortage({required this.needed, required this.free, required this.folder, required this.copying});

  final int needed;
  final int free;

  /// The games folder whose drive is short.
  final String folder;

  /// Part of the room is the game's files, which must be copied.
  final bool copying;

  int get missing => needed > free ? needed - free : 0;

  @override
  bool operator ==(Object other) =>
      other is SpaceShortage &&
      other.needed == needed &&
      other.free == free &&
      other.folder == folder &&
      other.copying == copying;

  @override
  int get hashCode => Object.hash(needed, free, folder, copying);

  @override
  String toString() =>
      'not enough space for $folder: the unlock needs ${_gb(needed)}, ${_gb(free)} is free'
      '${copying ? " (the game's files must be copied)" : ''}';

  static String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';
}
