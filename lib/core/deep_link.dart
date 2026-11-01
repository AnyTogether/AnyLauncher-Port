/// An anyps5:// link from a web page, a message or another program: anyps5://game/<title ID>
/// shows the game, anyps5://play/<title ID> does what Play does for it, anyps5://library and
/// anyps5://settings open those screens. The macOS launcher's DeepLink, link for link, so a link
/// copied on one system opens on the other.
sealed class DeepLink {
  const DeepLink();

  static const scheme = 'anyps5';

  /// Title IDs are four letters and five digits (PPSA15065, CUSA00001).
  static final _titleId = RegExp(r'^[A-Z]{4}[0-9]{5}$');

  /// The link in [text], null when it is not one of the launcher's.
  static DeepLink? parse(String text) {
    final Uri url;
    try {
      url = Uri.parse(text.trim());
    } on FormatException {
      return null;
    }
    if (url.scheme.toLowerCase() != scheme || url.host.isEmpty) return null;
    final host = url.host.toLowerCase();
    final parts = url.pathSegments.where((part) => part.isNotEmpty).toList();
    switch ((host, parts.length)) {
      case ('library', 0):
        return const LibraryLink();
      case ('settings', 0):
        return const SettingsLink();
      case ('game' || 'play', 1):
        final id = parts.single.toUpperCase();
        if (!_titleId.hasMatch(id)) return null;
        return host == 'game' ? ShowGameLink(id) : PlayLink(id);
      default:
        return null;
    }
  }

  /// The first argument that is a link of the launcher's: how the system hands one over when it
  /// starts the launcher for it.
  static DeepLink? inArguments(List<String> arguments) {
    for (final argument in arguments) {
      if (!argument.toLowerCase().startsWith('$scheme:')) continue;
      final link = parse(argument);
      if (link != null) return link;
    }
    return null;
  }

  String get url;

  @override
  String toString() => url;

  @override
  bool operator ==(Object other) => other is DeepLink && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Shows the game with this title ID.
class ShowGameLink extends DeepLink {
  const ShowGameLink(this.titleId);
  final String titleId;

  @override
  String get url => '${DeepLink.scheme}://game/$titleId';
}

/// Does what Play does for the game with this title ID.
class PlayLink extends DeepLink {
  const PlayLink(this.titleId);
  final String titleId;

  @override
  String get url => '${DeepLink.scheme}://play/$titleId';
}

class LibraryLink extends DeepLink {
  const LibraryLink();

  @override
  String get url => '${DeepLink.scheme}://library';
}

class SettingsLink extends DeepLink {
  const SettingsLink();

  @override
  String get url => '${DeepLink.scheme}://settings';
}
