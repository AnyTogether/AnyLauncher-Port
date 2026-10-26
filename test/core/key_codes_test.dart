import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:test/test.dart';

/// The game's Options key, typed into its window before the quick menu: the controls' key names
/// as Windows virtual keys and X11 keysyms.
void main() {
  test('the default Options key, letters, digits, F keys and the arrows', () {
    expect(Controls.layout[PadAction.options], ['KEY:Escape']);
    expect(KeyCodes.windowsVirtualKey('Escape'), 0x1B);
    expect(KeyCodes.windowsVirtualKey('Return'), 0x0D);
    expect(KeyCodes.windowsVirtualKey('P'), 0x50);
    expect(KeyCodes.windowsVirtualKey('7'), 0x37);
    expect(KeyCodes.windowsVirtualKey('F1'), 0x70);
    expect(KeyCodes.windowsVirtualKey('F12'), 0x7B);
    expect(KeyCodes.windowsVirtualKey('Left'), 0x25);
    expect(KeyCodes.windowsVirtualKey('Keypad 5'), isNull);

    expect(KeyCodes.x11Keysym('Escape'), 'Escape');
    expect(KeyCodes.x11Keysym('P'), 'p');
    expect(KeyCodes.x11Keysym('Backspace'), 'BackSpace');
    expect(KeyCodes.x11Keysym('Space'), 'space');
    expect(KeyCodes.x11Keysym('PageUp'), 'Prior');
    expect(KeyCodes.x11Keysym('F13'), isNull);
  });

  test('a desktop that cannot type a key says so', () async {
    expect(await const NoDesktop().pressKey(1, 'Escape'), isFalse);
  });
}
