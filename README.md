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
    (links through FFI: `link(2)` / `CreateHardLinkW` / `CreateSymbolicLinkW`), carry saves
    over, start
  - `toolkit_download.dart` the AnyPS5 engine from upstream's GitHub releases: resumable,
    checksum-checked downloads, safe unpacking, one toolkit folder per version
  - `game_settings.dart`, `controls.dart` per-game choices, the game environment and
    `anyps5-input.ini`
  - `game_log.dart`, `crash_report.dart` capped per-game logs, detailed logging (the engine's
    trace switches), the crash report of a game's last start with personal details taken out,
    and the pre-filled GitHub issue for it
  - `remote/` the phone server (WebSocket 47700, pairing, UDP pad relay, cable frames), an
    mDNS responder for `_anyps5-remote._tcp`, the adb cable tunnel
  - `trophies.dart`, `save_backup.dart`, `screenshots.dart` (a game's F12 and trophy pictures,
    a small PNG encoder)
  - `gamepad/` controllers as launcher commands (`pad_navigation.dart`: the mapping, repeat on
    hold, several pads), read with XInput and winmm on Windows (`windows_pads.dart`) and evdev
    on Linux (`linux_pads.dart`), through FFI
  - `desktop/` the game's window and the trophy card over it: Win32 through FFI on Windows
    (foreground, F11 and window size for upstream's engine, the window's picture, a layered
    click-through topmost card), Xlib on Linux X11 (override-redirect card, XGetImage), a
    desktop notification on Wayland
  - `audio/` the interface sounds (the macOS launcher's tones, synthesized sample for sample),
    a game's theme song (`snd0.at9` decoded with LibAtrac9 through FFI) and the music's fades
- `native/atrac9/` LibAtrac9 (MIT), built by `hook/build.dart` into a small shared library
  beside the launcher (MSVC on Windows, the system compiler on Linux and for `flutter test`)
- `lib/ui/` the PS5-style interface: home row, hero, library grid, settings panels, controls,
  trophies, onboarding, pairing card; `shaders/background.frag` is the macOS launcher's Metal
  background shader in GLSL (cosmic, aurora, sunset); `soloud_audio.dart` plays the sounds
  through `flutter_soloud` (miniaudio: WASAPI on Windows, PulseAudio or ALSA on Linux).
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
dart run tool/anyps5_tool.dart engine --folder ~/toolkits   # upstream's latest toolkit for this system
ANYPS5_TOOLKIT=~/toolkit dart run tool/anyps5_tool.dart install ~/Games/PPSA01234 ~/Games
dart run tool/anyps5_tool.dart remote --allow-all   # a phone server until Ctrl-C
```

The SELF test compares the Dart unwrapper with upstream's Python script on 300 random
containers when `python3` and the script are present (`ANYPS5_UNWRAP_SELF_PY` points at it).

## The toolkit

The launcher needs an AnyPS5 toolkit (the "AnyPS5 engine") built for the host. **It downloads
itself on first start:** the onboarding's last step offers *Download the AnyPS5 engine*, which
reads [boykopovar/AnyPS5](https://github.com/boykopovar/AnyPS5/releases)'s latest release from
GitHub's API and takes the two files for this system:

| System  | Relinker              | System libraries                                   |
| ------- | --------------------- | -------------------------------------------------- |
| Windows | `relinker-v<ver>.exe` | `prx-windows-v<ver>.zip` (the `.tar.gz` if missing) |
| Linux   | `relinker-v<ver>`     | `prx-linux-v<ver>.tar.gz` (the `.zip` if missing)   |

Downloads go into `.part` files that carry on after a dropped connection or a restart; each
file's size and the sha256 digest GitHub publishes for it are checked (a file without a digest
is only used after the user agrees). The archive is unpacked without letting any name or link
leave its folder, the folder holding the `.prx` files becomes `libs/` (0.1.0 had them at the
archive's top, later releases in `libs/`), the relinker is renamed and made executable, and
`version.txt` says `upstream-v<ver>`. Toolkits live in `%LOCALAPPDATA%\AnyPS5\Toolkits\<ver>`
(Windows) or `$XDG_DATA_HOME/AnyPS5/Toolkits/<ver>` (`~/.local/share/...`, Linux).

Settings → AnyPS5 Engine shows the engine in use, checks for updates, lists the versions
GitHub has and the downloaded ones (switch to one, or download an older one), deletes the
others, or takes a folder of your own. The launcher keeps the engine in use, the two newest
and the ones installed games were made with, and deletes the rest after a download. At start
it looks for a newer engine; when one is out, installed games show the usual update offer, and
*Update and Play* downloads the engine first, then unlocks the game again.

A toolkit of your own (a fork's build, say) is chosen with *I have my own folder* in the
onboarding or *Use my own folder* in Settings, or given with `ANYPS5_TOOLKIT`:

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
`ANYPS5_REMOTE_PAD*`); with upstream's libraries they are ignored. For full screen and window
size the launcher stands in: with upstream's engine (which opens at 60% of the screen and
switches with F11) it sizes the game's window once it opens, or presses F11 for it.

Settings → AnyPS5 Engine → *Engine* switches to the **AnyPS5-ARM engine**: the fork's toolkit,
built for Windows (and Linux, when published) and attached to
[AnyPS5-ARM's releases](https://github.com/utkuhalis/AnyPS5-ARM/releases) as one archive,
`AnyPS5-toolkit-<windows|linux>-<commit>.zip` (relinker, `libs/`, `version.txt`). The launcher
takes it from the newest release that has one, checks it against the release's signed
`SHA256SUMS`, and keeps it as `Toolkits/arm-<commit>` with `version.txt` `arm-<commit>`. That
engine reads the variables above itself, including the phone controller's bridge.

On Linux the launcher reads the glibc version the engine's libraries ask for (their ELF version
needs) and compares it with the system's: upstream v0.1.3's Linux libraries need glibc 2.38
(Ubuntu 24.04, Debian 13), so on Ubuntu 22.04 (2.35) Settings › AnyPS5 Engine, the download and
every unlock say "Games need glibc 2.38 or newer; this system has 2.35". Games are still
unlocked; they would not start there.

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

The trophy level (from all trophy points, bronze to platinum in its hexagon) is beside the
user's name on the home screen, in the friends panel and on their profile with the way to the
next level; each friend's row shows theirs when they let the user see their trophies. A level
reached comes as a toast with the trophy sound (the gateway's `level.up`). A friend's profile
shows their showcase (pinned trophies and favourite games) and **Compare trophies** (also in
their options): the games either has trophies in, both-play first, then one game's trophies
side by side with when each earned them. **Show me as → Appear offline** (Settings →
AnyTogether) hides the user from everyone else (`PATCH /me/presence`, followed on the user's
other devices through `presence.mode`); the socket, messages, parties and cloud saves go on as
ever.

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
(the dump's files as hard links where the volume allows, symbolic links otherwise, on Windows
with Developer Mode on or the launcher elevated; copies only where neither works, which the
launcher says before unlocking, with the relinked modules copied over), `anyps5-install.json` and
`launch.sh`/`launch.cmd`. The game runs there, so its saves (`_sd`), trophies (`_trophy`) and
data stay with it and move into a new install.

Settings and paired phones: `~/.config/AnyPS5` (Linux), `%APPDATA%\AnyPS5` (Windows).
Logs: `~/.local/state/AnyPS5/logs`, `%LOCALAPPDATA%\AnyPS5\Logs`: `<TITLE>.log` per game (set
aside as `<TITLE>.previous.log` past 32 MB before a start, started again past 256 MB while the
game runs, the earlier part in `<TITLE>.earlier.log`) and `<TITLE>-unlock.log`, the last
unlock's output. A game that stops on an error offers its crash report (also in the game's
options: **Last Session's Report**): **Save crash_log.txt**, **Copy Report** and **Open an
Issue**, which shows what it shares, then opens the engine's bug form (boykopovar/AnyPS5, or
AnyPS5-ARM for its engine) or this launcher's crash form pre-filled. **Detailed Logging** in a
game's options, **Play with Detailed Logging**, `AnyPS5 --trace` (every start of that run) and
`anyps5_tool play <game> <games> --trace` start the engine with its trace switches
(`APS5_LOG_SYNC`, `APS5_TRACE_EXIT`, `APS5_TRACE_MEMORY`, … see `TraceMode`).
Downloaded engines: `~/.local/share/AnyPS5/Toolkits`, `%LOCALAPPDATA%\AnyPS5\Toolkits`.

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

GPL-2.0, as the AnyPS5-ARM launcher it is ported from (see `LICENSE`). LibAtrac9 in
`native/atrac9` is MIT (`native/atrac9/LICENSE`), as is `flutter_soloud`. The Noto fonts in
`assets/system-fonts` and the Noto Sans CJK fonts the launcher downloads are under the SIL Open
Font License 1.1 (`assets/system-fonts/OFL.txt`; the CJK licence is saved beside them).
