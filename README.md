# AnyPS5 Desktop (private)

Private, local-only port of the AnyPS5 launcher to **Windows** and **Linux**.
It is the owner's backup plan: it is not published anywhere and has no remote.

AnyPS5 runs PS5 game dumps on PCs: the upstream relinker turns a game's executable into a
native Linux ELF or Windows PE, linked against AnyPS5's own implementations of the system
libraries (`libs/*.prx`). This launcher does what the macOS launcher does, for those two
systems: it finds dumps in a games folder, unwraps their SELF executables, runs the relinker
for the host, lays out the game with the system libraries, starts it, and keeps controls,
settings, saves and trophies per game. A phone running the AnyPS5 Remote app pairs with it and
works as a controller (the protocol of section 12.4 of the AnyTogether platform notes).

## Layout

- `lib/core/` platform-independent logic in pure Dart (no Flutter), unit tested:
  - `game_library.dart` dumps in a games folder (param.json names per language, version,
    icon0/pic0/snd0, executable kind)
  - `self_unwrap.dart` SELF/fSELF to ELF, byte-identical to upstream `tools/unwrap_self.py`
  - `installer.dart`, `toolkit.dart`, `file_links.dart`, `host.dart` unwrap, relink, lay out
    (hard links through FFI: `link(2)` / `CreateHardLinkW`), carry saves over, start
  - `game_settings.dart`, `controls.dart` per-game choices, the game environment and
    `anyps5-input.ini`
  - `remote/` the phone server (WebSocket 47700, pairing, UDP pad relay, cable frames), an
    mDNS responder for `_anyps5-remote._tcp`, the adb cable tunnel
  - `trophies.dart`, `save_backup.dart`
- `lib/ui/` the PS5-style interface: home row, hero, library grid, settings panels, controls,
  trophies, onboarding, pairing card; `shaders/background.frag` is the macOS launcher's Metal
  background shader in GLSL (cosmic, aurora, sunset).
- `test/` unit, widget and golden tests; `test/support/` synthetic fixtures (made-up dumps,
  SELF containers, PNGs, trophy packages, a fake relinker and adb, and the phone app's own
  protocol code as the fake phone). No real game files.
- `tool/anyps5_tool.dart` the pipeline on the command line (unwrap, scan, install, play, a
  headless phone server) for checks on a Windows or Linux machine without the interface;
  `tool/docker/linux-build.Dockerfile` a headless Linux build check.

## Working on it

```sh
flutter pub get
flutter analyze
flutter test                         # everything, headless (about 35 s)
flutter test --update-goldens        # re-render the golden images in test/ui/goldens
flutter build linux                  # on a Linux host (or the Docker check below)
flutter build windows                # on a Windows host
dart run tool/anyps5_tool.dart unwrap eboot.bin eboot.elf
ANYPS5_TOOLKIT=~/toolkit dart run tool/anyps5_tool.dart install ~/Games/PPSA01234 ~/Games
dart run tool/anyps5_tool.dart remote --allow-all   # a phone server until Ctrl-C
```

The SELF test compares the Dart unwrapper with upstream's Python script on 300 random
containers when `python3` and the script are present (`ANYPS5_UNWRAP_SELF_PY` points at it).

## The toolkit

The launcher needs an AnyPS5 toolkit built for the host, chosen at the first start or in
Settings (or given with `ANYPS5_TOOLKIT`):

```text
toolkit/
    relinker            (relinker.exe on Windows)
    libs/*.prx          system libraries built for the host (plus the mingw DLLs on Windows)
    version.txt         changes when the relinker or libraries change; games made with an
                        older one are offered an update
    patches/<TITLE>.toml   optional relinker patch files; entries named width and height make
                        the per-game resolution choice
```

Some environment variables the launcher passes exist only in the fork's engine
(`ANYPS5_FULLSCREEN`, `ANYPS5_WINDOW_SIZE`, `ANYPS5_OVERLAY_STYLE`, `ANYPS5_FRAME_GEN`,
`ANYPS5_REMOTE_PAD*`); with upstream's libraries they are ignored. The phone controller needs
the fork's `ANYPS5_REMOTE_PAD` bridge, which is POSIX-only today (Linux works, Windows needs a
Winsock port of `RemotePad.cpp`).

## Installed games

`<games folder>/.AnyPS5/Games/<TITLE>-<hash>/` holds `app.elf`/`app.exe`, `libs/`, `app0/`
(the dump's files as hard links where the volume allows, symbolic links on Linux otherwise,
copies on Windows otherwise, with the relinked modules copied over), `anyps5-install.json` and
`launch.sh`/`launch.cmd`. The game runs there, so its saves (`_sd`), trophies (`_trophy`) and
data stay with it and move into a new install.

Settings and paired phones: `~/.config/AnyPS5` (Linux), `%APPDATA%\AnyPS5` (Windows).
Logs: `~/.local/state/AnyPS5/logs`, `%LOCALAPPDATA%\AnyPS5\Logs`.
