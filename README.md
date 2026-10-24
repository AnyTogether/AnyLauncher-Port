# AnyPS5 Desktop (private)

Private, local-only port of the AnyPS5 launcher to **Windows** and **Linux**.
It is the owner's backup plan: it is not published anywhere and has no remote.

AnyPS5 runs PS5 game dumps on PCs: the upstream relinker turns a game's executable into a
native Linux ELF or Windows PE, linked against AnyPS5's own implementations of the system
libraries (`libs/*.prx`). This launcher does what the macOS launcher does, for those two
systems: it finds dumps in a games folder, unwraps their SELF executables, runs the relinker
for the host, lays out the game with the system libraries, starts it, and keeps controls,
settings, saves and trophies per game. A phone running the AnyPS5 Remote app can pair with it
and act as a controller (the same protocol the macOS launcher speaks).

## Layout

- `lib/core/` platform-independent logic in pure Dart (no Flutter imports), unit tested:
  library scan, SELF unwrap, install pipeline, settings, controls file, phone server.
- `lib/ui/` the PS5-style interface (Flutter), widget and golden tested.
- `test/` tests; `test/fixtures/` small synthetic fixtures (never real game files).

## Working on it

```sh
flutter pub get
flutter analyze
flutter test                         # unit, widget and golden tests, headless
flutter test --update-goldens        # re-render golden images
flutter build linux                  # on a Linux host (or in Docker)
flutter build windows                # on a Windows host
```

## The toolkit

The launcher needs an AnyPS5 toolkit for the host system, set in Settings (or
`ANYPS5_TOOLKIT`):

```text
toolkit/
    relinker            (relinker.exe on Windows)
    libs/*.prx          system libraries built for the host (plus the mingw DLLs on Windows)
    version.txt         changes when the relinker or libraries change
```
