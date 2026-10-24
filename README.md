# AnyPS5 Desktop

The [AnyPS5-ARM](https://github.com/utkuhalis/AnyPS5-ARM) launcher, ported to **Windows** and
**Linux** with Flutter: the same PS5-style home screen, library, unlocking, controls, trophies,
saves and phone controller, for the PCs [AnyPS5](https://github.com/boykopovar/AnyPS5) runs on.

**Status:** in development. The logic and the interface are tested headlessly (unit, widget and
golden tests); native Windows and Linux builds and a real game run are being checked now.

AnyPS5 runs PS5 game dumps on PCs: the upstream relinker turns a game's executable into a
native Linux ELF or Windows PE, linked against AnyPS5's own implementations of the system
libraries (`libs/*.prx`). This launcher does what the macOS launcher does, for those two
systems: it finds dumps in a games folder, unwraps their SELF executables, runs the relinker
for the host, lays out the game with the system libraries, starts it, and keeps controls,
settings, saves and trophies per game. A phone running the AnyPS5 Remote app pairs with it and
works as a controller (the protocol in section 12.4 of the
[AnyTogether platform notes](https://github.com/utkuhalis/AnyPS5-ARM/blob/anytogether/docs/en/12-platforms.md)).

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

## AnyTogether

The launcher signs in to [AnyTogether](https://github.com/utkuhalis/AnyTogether), the AnyPS5
online layer (Settings → AnyTogether): with a code sent by email, with a code approved on the
website (it opens in the browser; passkeys and the website's other sign-ins work there), or with
the paired phone, which approves the launcher with one tap when it is signed in (the phone
protocol's `togetherHandoff` / `togetherHandoffAnswer`, both ways). Another server can be chosen
there; `ANYTOGETHER_URL` overrides the choice. Code: `lib/core/together/`.

Signed in, the launcher is online for friends (in a game, with its title ID, while one runs),
and each play session and every trophy earned goes to AnyTogether through an outbox on disk
(`Together/outbox.json` in the config folder): playing offline loses nothing and nothing counts
twice. Rules as the macOS launcher's: this computer is registered first (`windows`/`linux`),
then the game's name, its trophy set (keyed by a hash of its trophies and grades, a trophy's ID
being the package's service label × 1000 plus its number), the sessions (more than 5 s), the
earned trophies.

The top bar's friends, messages and party buttons open the friends panel (requests, adding by
handle, what each friend plays), the messages (conversations and friends on the left, the thread
on the right with quick replies a controller can send and a field to type in, typing shown both
ways) and the party (start one, invite, walk into a friend's open party, its voice). Voice is the
website's protocol: the call from `/calls` with its relays, offers and candidates through the
gateway, a mesh of peer connections with Opus tuned for voice, through `flutter_webrtc` (its
Windows and Linux builds fetch Google's prebuilt libwebrtc at build time). The talk key (V by
default, chosen in the party panel) turns the microphone on and off, or with push-to-talk is
held to talk; it is read from the whole desktop, a game in front included: `GetAsyncKeyState` on
Windows, `XQueryKeymap` on X11 (on Wayland only while an X11 window such as the game is in
front, else only while the launcher has the keyboard).

Profiles (the user's own from Settings or the friends panel, a friend's from their options) show
the games with play time and trophy progress and the recent trophies with their rarity, each part
as private as its owner keeps it. While a game runs, the launcher opens an AnyTogether game
session for it (unless "Let friends join my game" is off), so friends see it as joinable; a
friend's Join (from their presence or an invite) checks the game is here and unlocked, that the
game version and the engine build (the toolkit the game was installed with) match the host's,
joins and starts it. The session, with the players' own properties, is written for the engine's
online bridge at `Together/game-session.json` in the config folder (`ANYPS5_TOGETHER_SESSION`
points at it), which does the playing together.

The session (an access token and a refresh token) is kept per system:

- **Windows**: `%APPDATA%\AnyPS5\Together\session.bin`, sealed with DPAPI
  (`CryptProtectData`, for the current Windows user, with the launcher's own entropy): another
  account or another computer cannot open it.
- **Linux**: the Secret Service (GNOME Keyring, KWallet) through `secret-tool` when it is
  installed (`libsecret-tools` / `libsecret`) and a keyring answers. Without one (no
  `secret-tool`, a headless session, a desktop with no keyring) it is
  `~/.config/AnyPS5/Together/session.json` with mode 0600 in a 0700 folder, as the macOS
  launcher keeps it: readable only by this user, which is what an unlocked keyring gives too.
  Calling libsecret through FFI would tie the launcher to GLib and D-Bus at start; the command
  keeps it optional.

## Installed games

`<games folder>/.AnyPS5/Games/<TITLE>-<hash>/` holds `app.elf`/`app.exe`, `libs/`, `app0/`
(the dump's files as hard links where the volume allows, symbolic links on Linux otherwise,
copies on Windows otherwise, with the relinked modules copied over), `anyps5-install.json` and
`launch.sh`/`launch.cmd`. The game runs there, so its saves (`_sd`), trophies (`_trophy`) and
data stay with it and move into a new install.

Settings and paired phones: `~/.config/AnyPS5` (Linux), `%APPDATA%\AnyPS5` (Windows).
Logs: `~/.local/state/AnyPS5/logs`, `%LOCALAPPDATA%\AnyPS5\Logs`.

## Packages

- Windows: `packaging/windows/build-installer.ps1` builds the release and an Inno Setup 6
  installer, `build/installer/AnyPS5-Desktop-Setup-<version>-x64.exe`: a per-user install in
  `%LOCALAPPDATA%\Programs\AnyPS5 Desktop` by default (all users on request), Start menu and
  optional desktop shortcuts, an uninstaller; a running launcher is closed before an upgrade.
- Linux: `packaging/linux/build-appimage.sh` and `packaging/linux/build-deb.sh` write
  `build/packages/AnyPS5-Desktop-<version>-x86_64.AppImage` and
  `anyps5-desktop_<version>_amd64.deb` (`/opt/anyps5-desktop`, `/usr/bin/anyps5-desktop`).
  Build them on Ubuntu 22.04 so they run on glibc 2.34 and newer; GTK 3 comes from the system.

## License

GPL-2.0, as the AnyPS5-ARM launcher it is ported from (see `LICENSE`).
