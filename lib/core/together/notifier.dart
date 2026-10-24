/// A change notifier for the pure-Dart core, which cannot use Flutter's: the interface listens
/// and redraws, the tests count.
mixin class Notifier {
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}
