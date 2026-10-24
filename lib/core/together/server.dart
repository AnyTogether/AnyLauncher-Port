/// Which AnyTogether the launcher talks to. AnyTogether is open source and can be hosted by
/// anyone: the user may pick another server, and ANYTOGETHER_URL overrides both (staging, a
/// local one).
abstract final class TogetherServer {
  static final standard = Uri.parse('https://anytogether.kodla.agency');

  /// The server ANYTOGETHER_URL forces, when it is set to an address.
  static Uri? forced(Map<String, String> environment) {
    final value = environment['ANYTOGETHER_URL'];
    if (value == null || value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim().replaceAll(RegExp(r'/+$'), ''));
    return uri != null && uri.host.isNotEmpty ? uri : null;
  }

  /// ANYTOGETHER_URL, then the user's choice, then AnyTogether's own server.
  static Uri base(Map<String, String> environment, String? chosen) =>
      forced(environment) ?? address(chosen ?? '') ?? standard;

  /// A server address as typed: https with a host, or http to this computer or the home network
  /// (localhost, 10.x, 172.16-31.x, 192.168.x, a .local name); no user, query or fragment;
  /// without the trailing slash. null when it is not one.
  static Uri? address(String text) {
    final trimmed = text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') return uri;
    return scheme == 'http' && _homeNetwork(uri.host.toLowerCase()) ? uri : null;
  }

  static bool _homeNetwork(String host) {
    if (host == 'localhost' || host == '::1' || host == '[::1]' || host.endsWith('.local')) return true;
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final [a!, b!, _, _] = parts;
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }
}
