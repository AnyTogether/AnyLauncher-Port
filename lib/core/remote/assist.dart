/// Who helps the first player (assist, as PS5's second controller for assistance or Xbox
/// Copilot): no one, the computer's controllers after the first player's, or one phone or
/// browser pad. A helper's buttons and sticks join the first player's, and it takes no player of
/// its own. AssistTarget in the macOS launcher is the same.
sealed class AssistTarget {
  const AssistTarget();

  static const controllersValue = 'controllers';

  /// The target kept in the settings: null off, "controllers", or a device ID.
  factory AssistTarget.stored(String? value) => switch (value) {
    null || '' => const AssistOff(),
    controllersValue => const AssistControllers(),
    final id => AssistDevice(id),
  };

  String? get stored => switch (this) {
    AssistOff() => null,
    AssistControllers() => controllersValue,
    AssistDevice(:final id) => id,
  };

  /// The phones and browser pads that help, for the phone server.
  Set<String> get devices => switch (this) {
    AssistDevice(:final id) => {id},
    _ => const {},
  };

  /// Whether the computer's other controllers help (the engine's assist datagram).
  bool get controllers => this is AssistControllers;

  /// The choices a settings row offers, in order: off, the other controllers, then each device
  /// (connected ones, and the chosen one when it is not), with their names.
  static List<(AssistTarget, String?)> choices(
    List<(String, String)> devices,
    AssistTarget chosen,
    Map<String, String> names,
  ) {
    final list = <(AssistTarget, String?)>[(const AssistOff(), null), (const AssistControllers(), null)];
    final seen = <String>{};
    for (final (id, name) in devices) {
      if (seen.add(id)) list.add((AssistDevice(id), name));
    }
    if (chosen case AssistDevice(:final id) when !seen.contains(id)) list.add((chosen, names[id] ?? id));
    return list;
  }

  @override
  bool operator ==(Object other) => other is AssistTarget && other.stored == stored;

  @override
  int get hashCode => stored.hashCode;
}

class AssistOff extends AssistTarget {
  const AssistOff();
}

class AssistControllers extends AssistTarget {
  const AssistControllers();
}

class AssistDevice extends AssistTarget {
  const AssistDevice(this.id);
  final String id;
}
