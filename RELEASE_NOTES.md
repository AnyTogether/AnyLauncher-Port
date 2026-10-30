# Release notes

Notes for the next GitHub release, written as changes land; the section is copied into the
release when it is made.

## Next release

- **The launcher no longer freezes while a game is unlocked or updated.** Copying a game's
  files (a games folder on another drive than the dump, without Developer Mode on Windows),
  measuring the dump, unwrapping its executable and removing the old install after an update
  all ran on the launcher's own thread: for seconds or minutes at a time the screen stopped,
  no other game could be picked, opening a game's settings seemed to crash the launcher until
  it came back, and Windows called the window not responding. That work now runs on the
  system's file threads and in a separate isolate, so the library stays usable while a game
  relinks. The old install is renamed aside at once and removed afterwards (a removal cut short
  is cleaned up at the next start).
- **Full screen means full screen, and the close button in full screen no longer crashes.**
  On Windows, the title bar's Maximize (its button, a double click on the title bar, Win+Up
  or dragging the window to the top) used to make a maximized window that kept its dark title
  bar along the top, and Settings still said Window. It now switches to the launcher's own
  full screen, with no bar, and the window buttons and **Settings → Full Screen** follow. On
  Linux, full screen turned on or off by the window manager is followed too. Clicking the red
  close at the top right in full screen used to crash the launcher, and the next start offered
  no report. Quit now closes the window the same way its title bar's close does. If closing
  ever fails, the next start offers a report of a crash while closing. Each full-screen
  change, and how long it took, is now in a report's last seconds.
- **Crash reports you can write in, and Windows 11 called Windows 11.** On the GitHub form
  that **Send Report** opens, the launcher used to fill in the same box you were meant to
  write in (What happened, ending in "What I was doing:"), and what you typed there could be
  wiped out. Now the launcher fills in its own boxes (**What the launcher noticed**, the system,
  the version, the error and the last seconds) and leaves **What you were doing** empty for you.
  The game crash form works the same way, and its **Report file** box is left empty for
  crash_log.txt. The system line read "Windows 10" on Windows 11, because the registry's
  product name still says 10. It now says Windows 11 from build 22000 on, with the version and
  the full build (for example "Windows 11 Home 25H2 (Build 26200.6899)"). On Linux the
  distribution name is read from os-release whichever quotes it uses. When the link has no
  room for every line, the oldest lines are left out, the log says how many, and the whole
  report is put on the clipboard so you can paste it into the issue.

## 0.1.14

- **Update from Git for an engine you build yourself.** **Use My Own Folder** now takes a git
  checkout of the engine's source (AnyPS5 or AnyPS5-ARM) as it is: the relinker and libraries
  are read from its CMake build folder (`build/core/relinker`, `build/core/libs/libs`, plus the
  MinGW runtime DLLs on Windows). **Update from Git** pulls it (`git pull --ff-only`), updates
  its submodules and builds the relinker and libraries, with the step and the last output lines
  shown as it goes; selecting it again stops it. A tree with uncommitted changes, a missing git
  or CMake, or a folder never configured with CMake is said up front (the last one opens the
  build guide), and a failed pull or build shows the end of its output with a way to copy it.
  Afterwards installed games offer **Update and Play**, or **Relink All Installed Games Now**
  does them at once. **Update from Git Before Playing** (off by default) checks the remote
  before a game starts and pulls and builds first when there are new commits; offline it just
  plays. The Upstream choice still downloads release builds and never pulls a clone.
- **Default display settings for every game.** **Settings → Default Display** sets Window or
  Full Screen, the window size and vertical sync once for all games. A game's own choice in its
  Game Settings still wins; there **Display** and **Vertical Sync** now start with
  **Default (…)**, which shows what the default is, the window size reads **Default (75%)**
  until the game picks one, and **Use Default Display** puts a game back on the defaults.
  Choices made before the update stay: a game set to Full Screen, a window size of its own or
  vertical sync off keeps it; values never changed follow the defaults, which start as
  before (Window, 75%, vertical sync on).
- **The stick's up and down on Home are calmer.** With an Xbox pad (or any pad) a push to the
  side could also move up or down and leave the tiles for the top bar or the buttons: the
  thumb's arc on the way out, a light push or a stick snapping back from a diagonal counted as
  up or down. Up and down on the stick now need a firmer, clearly upright push (0.65 instead of
  0.5, letting go below 0.4), a diagonal goes sideways, a held left or right gives way only to
  a clearly vertical push, and held up or down repeats first after 0.55 s instead of 0.40 s.
  Left and right, the D-pad and the keys feel as before.
- **Every text is in the language files, ready for Weblate.** The accent colour names, the
  mouse button, wheel and key labels, the controls' button names and the number formats were
  still in the code; they are in `assets/l10n` now, so a translation covers them too. Turkish
  sizes and percentages read `52,5 GB` and `%75`. The files are flat JSON objects with the
  language's name as the text `languageName`, the format Weblate reads; a file in the old
  format in the `Languages` folder still loads. **TRANSLATING.md** is now the guide for the
  Mac launcher, this launcher and the phone app.

## 0.1.13

- **More than one games folder.** **Settings → Game Library** lists each folder with its game
  count, takes one out of the library (nothing on its drive is deleted) and has **Add Folder**,
  with the keys and a controller as well as the mouse; Select on the empty shelf adds one too.
  The library is all the folders together; a game in more than one shows once, from the folder
  listed first. A folder whose drive is unplugged stays in the list as **Not connected** and its
  games come back when the drive does. Each game is unlocked into the folder it was found in,
  so its files are linked on their own drive instead of copied to another; games unlocked
  before stay where they are. The saved single folder carries over as the first.
- **A controller reaches the top bar with no games.** With an empty library the home screen
  answered only Select, so an Xbox pad (or any pad) could not get to Settings. Up from the
  empty shelf now moves to the top bar, as it does with games.
- **Languages are JSON files.** Every text is in `assets/l10n/en.json` and `tr.json`; a new
  language is one more file there and shows in **Settings → Language** and on the first start.
  A file in the `Languages` folder beside the settings (`%APPDATA%\AnyPS5\Languages`,
  `~/.config/AnyPS5/Languages`) comes first, so a translation can be tried in a released
  launcher. **TRANSLATING.md** is the guide for translators; CI checks every language file.
- **Mouse side buttons.** Back does what Circle does everywhere (closes a panel, goes back a
  step); Forward opens again the screen Back just closed. A keyboard's Browser Back / Forward
  keys do the same.
- **Escape on the home screen asks "Quit AnyPS5?"**, with **Cancel** first. Everywhere else
  Escape keeps its meaning.
- **Window buttons in full screen.** The pointer at the top edge brings down **Minimize**,
  **Leave Full Screen** and **Quit AnyPS5**. **Settings → Appearance → Window Buttons at the
  Top Edge** turns them off.
- **No stalls on fast input.** A game's size was measured by walking its folder on the
  interface thread for every game passed, which froze the launcher for seconds while a
  direction was held; it now runs in the background, for the game the selection rests on.
  Switching back before a fade ended put two items with one key on screen, a likely cause of
  the rare crashes; that is fixed too.
- **Engine settings say where each engine comes from.** Upstream and AnyPS5-ARM are release
  downloads, and your own folder is used as it is (nothing is pulled or built). A folder you
  rebuild in place now makes installed games offer **Update and Play**, as a new engine does.
- **Reports for the launcher's own crashes and stalls.** After a crash or a freeze of 5 seconds
  or more, the next start offers **Send Report**: a GitHub issue filled in with the version, the
  system and the last seconds, without your paths or names. Nothing is sent by itself.

## 0.1.12

- **AnyTogether moved to anytogether.net.** The default server and the join links use the new
  address; the old one keeps working.
- **AppImage updates are staged beside the AppImage.** The new AppImage was written to a file
  literally named `$appImage.new` in the current folder and renamed from there, which fails
  across file systems; it now goes next to the AppImage it replaces.
- **New engine.** AnyPS5-ARM 0.2.26's Windows and Linux engine brings about 3,500 upstream
  commits (**Settings → AnyPS5 Engine**).

## 0.1.11

- **Gyro aiming for every game.** Each game's **Controls** page starts with **Aim with the
  Gyro**: a DualSense, DualShock 4, Switch Pro Controller or a phone aims in any game that aims
  with the right stick, on top of the stick itself. Set the sensitivity, when it aims (always,
  while L2 is held, while touching the touchpad), invert and the dead zone. Needs AnyPS5-ARM
  0.2.25's engine (`ANYPS5_GYRO_AIM`); other engines ignore it.
- **Type on your phone.** When a game opens its text dialog or keyboard, the phones get a
  typing sheet with their own keyboard (and one that connects later gets it at once), and the
  browser pad page a text card; the text goes back to the game, then Enter or cancel.
- **Assist Player 1.** **Settings → Controllers → Assist Player 1** picks who plays player 1
  together with its holder: the computer's other controllers, or one phone or browser pad. Its
  buttons, sticks and touch join player 1's; a change is said to the engine at once.
- **New engine.** Gyro aiming, typing on the phone and Assist Player 1 need AnyPS5-ARM 0.2.25's
  Windows and Linux engine (**Settings → AnyPS5 Engine**).

## 0.1.10

- **Profiles.** The first start asks **How do you want to play?**: **Play Offline** (no
  account; trophies and progress stay on this PC, nothing is synced or shared) or **Play
  Online** (create an AnyTogether account or sign in with an email code, the website or your
  phone). Add more people with **Add Profile**; with more than one, **Who's playing?** greets
  you at start (**Ask Who's Playing at Every Start** makes it ask always). Each profile keeps
  its own AnyTogether session, settings, saves, trophies and Game Presets; its saves are put in
  place when it plays. **Switch Profile** is in the PS button's long-press menu and in the
  **Options** menu (Options/Start on a pad, or right-click on Home), which also has **Go
  Online** / **Go Offline** and the other profiles. Switching, or going online or offline, is
  refused while a game runs (**Close <game> first**) or while saves sync. **Settings →
  Profiles** sets the name, picture and tile colour, and switches to or deletes a profile (its
  saves and trophies are backed up first). An existing install becomes the first profile by
  itself, with its account, saves and settings.
- **Friends-only name and picture.** **Settings → AnyTogether → Friends-Only Name and Picture**
  sets a name (your real name, say, up to 40 characters) and a picture that only your accepted
  friends see, always next to your @handle, in friends, party, Play Together and profiles, in
  the launchers and in the phone app; everyone else sees your public ones.
- **DLC and game updates from your own dumps.** Put them beside the game, as shadPS4 does:
  `<game>-UPDATE` (or `-patch`), `<game>-DLC/<label or content ID>`, or an add-on named by its
  content ID next to the game (the game's folder name or title ID, any case). They are no longer
  listed as games. The game page shows **DLC (n)** and **Update vX applied**; an update dumped
  after the unlock says **unlock to apply** (saves and trophies stay). Each start passes
  `ANYPS5_UPDATE_DIR` and `ANYPS5_ADDCONT_DIRS`: the engine reads the update's files in place of
  the game's and mounts the add-ons the game asks for. Only what is on your disk is reported to
  the game; nothing contacts Sony.
- **Game Presets per profile.** **Settings → Game Presets** sets what the PS5 keeps under that
  name, once for every game: difficulty, Performance Mode or Resolution Mode, inverted
  vertical and horizontal view (first and third person), subtitles and the audio language,
  passed as `ANYPS5_GAME_PRESETS`. Games that read the console's presets start with them.
  Performance Mode is seen to work in games; the other values follow the console's menus and are
  **experimental** (not checked against a console).
- **New engine.** DLC, updates and Game Presets need AnyPS5-ARM 0.2.24's Windows and Linux
  engine from ce334c86b (**Settings → AnyPS5 Engine**); with an older one they are ignored.

## 0.1.9

- **Full screen.** The launcher starts full screen the first time, then as you left it. **F11**
  (it can be rebound) or **Settings → Appearance → Full Screen** switch it (Windows: a
  borderless window over the monitor and back; Linux: GTK's full screen).
- **Settings with a controller.** The sections' column takes the focus with left; up and down
  change the section, right or ✕ go back into the rows; L1/R1 as before. Option rows (theme,
  window mode, ...) no longer change by just moving over them: **✕** enters edit mode (an
  accent ring and its arrows), **←/→** change the value, **✕** or **○** leave it. Keyboard and
  mouse work as before.
- **Hints follow your input, live.** After a pad button the hints show only the pad's buttons,
  and the Back pill, the step arrows and the gallery's arrows hide outside edit mode; a key or
  the mouse brings the keyboard's hints back.
- **PS button.** Held in the launcher: **Quit AnyPS5** (Switch Profile is coming). In a game:
  the game is paused first, then a **quick menu** (Resume, Game Settings, Close Game) that says
  Paused or Still running over the game's name. Held in a game: **Close game?** at once. PS now
  acts when let go (held 500 ms it is the long press). The pause works even with a controller
  on player 1: with an engine that takes presses (AnyPS5-ARM's Windows and Linux engine from
  a29698606, below), the launcher sends one press packet through the remote pad bridge that
  holds Options 160 ms on player 1's pad, whoever drives it; an older or upstream engine keeps
  the fallback, the Options key typed into the game's window. **Settings → Behaviour → Pause
  Game When Opening the Menu** turns the pause off.
- **Share / Create button: clips and screenshots.** With **Settings → Captures → Replay Buffer**
  on (off by default, about one CPU core; needs **ffmpeg**), the last 30 s to 5 min are kept,
  and a short press saves them as a clip in the game's gallery; a long press (or a press with the
  buffer off) takes a screenshot. Clips show in the gallery with a play badge and open in the
  system's player.
- **Settings → Shortcuts.** Put Home, Quick Menu, Screenshot, Save Clip, Full Screen and the
  Settings sections on a key (with modifiers) and on a pad button or chord, pressed or held.
  Conflicts, and the launcher's own keys and buttons, are refused and said; **Reset to
  Defaults**; the game's own buttons link to Game Settings → Controls.
- **Play from a browser.** **Settings → Phones → Play from a browser** shows a QR code with a
  one-time link: a phone that scans it becomes a DualSense in its browser, with no app, as
  player 2 to 4. It pairs with the same pairing code as the phone app, works on your LAN only
  (one-time token, session cookie, origin, host and LAN checks, rate limits) and the server runs
  only while it is wanted; **Keep browser play on** keeps it up. Each browser is a phone on the
  phone server's own channel, so seats, the pairing card and the pad path are the same.
- **Credits.** The README credits AnyPlay's bridge spec and the ideas we followed.

## 0.1.8

- **Online play (experimental), as on the Mac.** **Settings → AnyTogether → Online play
  (experimental)**, off by default, starts games with the launcher's online bridge: a loopback
  service on 127.0.0.1 the engine connects to with a fresh secret every start (both sides prove
  it, the secret never crosses the socket). Games see you signed in as your AnyTogether handle,
  with your AnyTogether friends, their profiles and presence, an empty block list and no
  communication restriction; Player Sessions (`sessionManager`) are kept by the launcher for the
  game run, with push events to the game when someone joins or leaves. Game packets ride WebRTC
  data channels to the other players of the AnyTogether game session, signalled through
  AnyTogether's gateway with its STUN and TURN, each player at the same virtual address on every
  computer, broadcasts and LAN-style discovery included; Windows, Linux and Mac launchers play
  together. Nothing ever goes to Sony; groups the launcher does not know answer "not offered",
  as offline. What each game asks for is written to its online log (Windows
  `%LOCALAPPDATA%\AnyPS5\Logs\Online\<TitleID>.jsonl`, Linux `~/.local/state/AnyPS5/online/`),
  opened from **Open online log**; a crash report carries the last lines of it. Needs an engine
  with the online bridge (AnyPS5-ARM's engine, once its Windows and Linux toolkits carry it);
  with an engine without it the setting changes nothing.
- **Play Together, as on the Mac.** In a party, **Play Together: <game>** starts the game picked
  on Home for the party, with online play on for that game only (the setting stays as you left
  it). Everyone else in the party hears "<host> started <game> — Join"; **Join** checks you have
  the same game, version and AnyPS5 engine (or offers **Unlock and Play** / **Update and Play**,
  or says who should update), then starts it in the host's session so the games find each other
  on the virtual LAN. The party panel shows who plays and whether each connection is up; the
  host can hand out a join code for someone outside the party, and it ends for everyone when the
  host's game exits. Friends see "Playing <game> together (2/8)".
- **Human Fall Flat online: Host Public and Join work.** Player Sessions answer as the platform
  does (201 for every request that makes something, with Content-Type and Content-Length), so
  hosting a public game no longer crashes it; a join into a session made on the host's machine
  is taken, and the session fetch after the join is answered from its session IDs header, so
  Join gets into the host's game.
- **Games that stream between players play online too.** Stream P2P sockets (TCP between
  players) ride the bridge and a second, reliable data channel next to the game's packets,
  byte for byte as the Mac launcher carries them, so a PC and a Mac stream to each other. A
  stream a game or player closed stays closed; one left open when a game or player goes is
  reset on the other side. A Mac that restarted its answer is met with a fresh connection.
- **Try Anyway in Play Together.** When only the game version keeps you out (never the engine),
  Join offers **Try Anyway**, and the party sees who tried anyway.
- **Asks first.** Leaving the party, removing someone from it, ending or leaving Play Together
  and removing a friend ask first, with Cancel focused; Back answers Cancel.
- **Update Required.** When AnyTogether retires this version, the launcher says so once, with
  its own download and restart, or the downloads page.
- **The newest engine is offered.** When a release keeps an older AnyPS5-ARM engine beside a
  newer one, the newest upload is the one offered.

## 0.1.7

- **Play from Steam and the Steam Deck.** **Settings → Steam → Add to Steam** puts AnyPS5 in
  your Steam library as a non-Steam game, with artwork in the Cosmic look (cover, wide capsule,
  hero, logo and icon), tagged **AnyPS5**, so Big Picture, Steam Input and the Steam Deck's Game
  Mode start it like any other game. **Add My Games Too** gives every unlocked game its own
  entry with its own art that starts straight into the game; the launcher closes when the game
  ends so Steam sees it end. Steam has to be closed while its shortcuts are written: the
  launcher offers **Close Steam and Add**, keeps a backup (`shortcuts.vdf.anyps5-backup`) and
  never touches anyone else's shortcuts; **Remove from Steam** takes out only AnyPS5's entries
  and pictures. On a Steam Deck, add it from Desktop Mode. `--fullscreen` opens the launcher
  over the whole screen; `--play <title ID>` starts a game at once.

- **Controllers that just work, and a screen for them.** Controllers are read through SDL2,
  shipped with the launcher: DualSense and DualShock 4 over USB and Bluetooth (and now they
  vibrate on Windows too), Xbox, Switch Pro, 8BitDo and more, plugged in or paired at any time,
  several at once; the one used last is Player 1. **Settings → Controllers** lists them with
  USB or Bluetooth and their battery, tests every button and stick live and the vibration, sets
  the light bar's colour, lets Circle confirm (Japanese layout) and sets a stick dead zone for
  the launcher and your games. Its **troubleshooter** finds what keeps a pad away: Steam's
  PlayStation support, DS4Windows, DualSenseX, HidHide, Linux input permissions (with the
  command to copy), and gives the Bluetooth and cable tips. Started from Steam, Steam's virtual
  pad is used and the real one left to Steam. Crash reports now list the controllers.

- **No unlock without the room, and new games prepared in the background.** Unlock (and Update
  and Play) first works out what it will write and checks the games folder's drive; when it is
  short nothing starts, and the panel says how much is needed and how much is free, why the
  game's files would be copied when they would, and the ways out (a games folder on the dump's
  drive or one with more room, Developer Mode on Windows, try again). **Settings → Game Library →
  Prepare New Games Automatically** (on by default): a new, complete game found in the games
  folder is unlocked in the background, one at a time and at the lowest priority; it waits for
  your own unlocks and for a game you play, pauses where it is when one starts, and never runs on
  a battery below 30 % or a drive without the room (it says so). The **New game** notice says
  **Preparing…**, then **Ready to play**; Play on a game being prepared finishes it at full speed
  and starts it. Unlocking again is faster too: the relinker's output is kept, and the same
  game, engine and modules skip the unwrap and relink.

- **More in Messages.** Pick a message (↑ from the field, or click it) for its menu: react with
  👍 ❤️ 😂 😮 😢 🔥 or GG, reply (the answer quotes it), edit your own for 15 minutes, or unsend
  it for everyone after a confirmation; unsent ones read "Message removed". Reactions show as chips
  under the message, yours lit, and clicking one adds or takes back yours. Under your newest
  message: Sent, Delivered or Read, and "Seen by" in groups. △ on a conversation pins it to the
  top (up to five) or mutes it, with a mark in the list; muted ones come in without a notice.
  **Settings → AnyTogether → Send read receipts** turns read receipts off both ways. Unread counts
  are now the server's own.

- **Smooth on laptops and integrated graphics, and nothing drawn behind your game.** On Windows
  the launcher now draws with Skia instead of Impeller's OpenGL ES backend, which needed dozens
  of offscreen passes a frame for the launcher's glass and panels (on a Ryzen 7 3700U with Vega
  graphics a Glass settings panel drew at 3 to 13 frames a second; now it scrolls at 60, a frame
  drawn in about 4 ms). Glass draws each card, button and row once and reuses the picture, its
  frost is a small repeated tile, it no longer blurs behind every surface (only a full-screen
  layer is blurred, once; on the see-through window the home screen fades out under it instead),
  and its text plates are drawn in one step. The themes' animated backgrounds move at 30 steps a
  second (Glass 20) at half the window's resolution, which you cannot tell apart from before and
  costs a fraction. While a game is in front, or the launcher is behind any other window, the
  launcher draws nothing at all: every animation stops and the GPU is the game's (before, the
  background kept drawing behind the game and took a quarter of the GPU from it). If the
  graphics card still falls behind with Glass, it turns solid by itself after a few seconds and
  stays solid at the next starts; picking Glass again in **Settings → Appearance** tries once
  more. New installs start in Cosmic; Glass is yours to pick.
- **PS/Guide switches between the game and the launcher, both ways.** In the game, PS brings the
  launcher in front; in the launcher, PS takes you back to the game (on Windows the game window
  could refuse to come back; it is now brought in front reliably, with the launcher right behind
  it). One press is one switch, and the press that switched does nothing on the other side.
- **The game leaves the controller alone while the launcher is in front.** Games read the pad
  only while their own window is in front (SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=0 in the game's
  environment), so moving through the launcher over a running game no longer also plays the game.
- For testers: `ANYPS5_FRAME_LOG=<file>` writes how many frames the launcher drew each second and
  how long they took; `ANYPS5_RENDERER=impeller` brings Impeller back on Windows.

- **Glass, a new theme.** The launcher's window turns see-through: your desktop and the
  windows behind it show through, blurred under a light tint so the wallpaper's colors glow,
  like a Windows 11 Acrylic window; the text sits on soft dark plates and panes of glass, so it
  reads over any wallpaper. Every card, button and panel on it is a pane of
  frosted glass with a rim of light, and the focused one turns into a bright ice chip with a
  glint that runs across it (not with reduced animations). It comes with a new **Ice** accent.
  Pick it in **Settings → Appearance → Theme** or on the first start. **Glass Transparency**
  there sets how much shows through (0 % is solid) and **Show Game Art Behind** lays the
  selected game's picture over the desktop; **Reduce Transparency** draws everything solid, and
  a graphics card too slow for Glass gets the solid look by itself. On Windows 11 22H2 and later
  the backdrop is the system's Acrylic (shown while the window is active, as for every app);
  Windows 10 and earlier Windows 11 get the older acrylic blur. On Linux the window is
  see-through wherever the desktop composites, blurred on KDE Plasma (X11), unblurred with more
  tint elsewhere (GNOME, Wayland); without a compositor Glass draws its own frosted background.
- **No more full copies across drives.** A game whose dump is on another drive than the games
  folder now links to the dump's files with symbolic links instead of copying tens of GB (on
  Windows this needs Developer Mode, or the launcher run as administrator). Where no link can be
  made, the launcher says before unlocking how many GB would be copied and why, with the two
  fixes: a games folder on the dump's drive, or Developer Mode (**Settings → System → For
  developers**, one button away), or **Copy Anyway**. A linked game whose dump moved says so
  instead of crashing.
- **New games show up by themselves.** A game copied into the games folder, in a subfolder too,
  appears as soon as its copy is far enough along (a big copy that started before its
  eboot.bin and param.json were there no longer goes unnoticed, and an unlock going on no longer
  holds it back), with **New game: <name>** and its icon (or **3 new games**), the select sound,
  and the game selected on the home screen; a desktop notice says it too while the launcher is
  behind other windows. On Linux every folder down to the scan's depth is watched, and a games
  folder on a drive that is not plugged in yet is found when it is.
- **Controller vibration.** Soft, short pulses in the controller for select, back, errors,
  trophies, invitations and the end of a row (**Settings → Behaviour → Controller Vibration**, on
  by default). Only while the launcher is in front and the controller is what you are using; the
  motors stop the moment a game comes in front. Xbox and other XInput pads on Windows, pads with
  force feedback on Linux; a pad without motors (or a PlayStation pad read through winmm) stays
  still.
- **Input feel.** A held direction repeats at the same pace on the controller and the arrow keys
  (0.4 s, then 0.08 s, a little faster after six); the stick engages at half and lets go only
  below a third, so a resting stick no longer jitters; a direction with nowhere to go answers
  with a quiet knock (once per press). A soft tick plays when the mouse arrives on a tile, row or
  button.
- **Updates while it stays open.** The launcher looks for a new version every six hours and when
  it comes back to the front after half an hour, downloads it in the background (signature
  checked as before), then shows a quiet notice beside the top bar: **Restart Now** or **Later**
  (it goes in at the next launch, and the notice does not come back). Restart Now with a game
  running waits for the game. On Windows the installer runs silently and opens the launcher
  again; an AppImage is swapped for the new one; with the archive, **Show File**. About shows
  checking, up to date, downloading with its percent, or ready.
- **Hidden trophies.** Checked: a hidden trophy you earned always shows its name; only unearned
  hidden ones are masked.
- **Controller presses no longer reach the launcher while you play.** The controller is read
  whichever window is in front, and on Windows the launcher could believe it was still in front
  behind the game, so Cross in the game also pressed what the launcher had focused. Now, while a
  game (or any other program) is in front, the launcher takes nothing from the controller but
  the PS/Guide button, which brings it in front as before; no vibration either. Back in front, a
  button still held from the game does nothing until you let go of it and press it again, and a
  stick still pushed moves nothing until it comes back to the middle.
- **Lists no longer follow the mouse; scroll with the wheel or drag.** Moving the mouse over a
  row still highlights it, but the list no longer scrolls to it (it used to slide away under the
  pointer). Scroll with the wheel or the touchpad, or hold the left button and drag, as on a
  phone or an Android emulator: lists, the library and the game tiles on the home screen follow
  the pointer and glide on when you let go fast; a drag never clicks what it started on, and a
  click that moves a few pixels is still a click. The arrow keys and the controller scroll the
  focused row into view as before.

## 0.1.6

Pre-release, superseded by 0.1.7.

## 0.1.5

### Trophy levels, showcases and comparing trophies

Your trophy level (all your trophy points, bronze up to platinum, in a hexagon that grows a
frame every 100 levels) is beside your name on the home screen and in the friends panel, and on
your profile with how far the next level is. Friends' rows show their levels. Reaching a level
says so with the trophy sound. A friend's profile shows their showcase, their pinned trophies
and favourite games, and **Compare trophies**: the games either of you has trophies in, the
ones you both play first, then a game's trophies side by side, who earned what and when. A
friend who keeps their trophies private is said so.

### Appear offline

**Settings → AnyTogether → Show me as** has **Online** and **Appear offline**: friends see you
as offline, while messages, parties and cloud saves keep working. Your other devices follow the
choice, and your name says "Appearing offline" while it is on.

## 0.1.4

### Crash reports and detailed logging

When a game stops on an error (not when you close it), the launcher shows its crash report:
why it stopped (the engine's crash report, a signal or exception, an abort, the exit code), the
system, the engine, the GPU and the end of the log. From there:

- **Save crash_log.txt** asks where to save the report with the whole log of that start and
  the last unlock's output.
- **Copy Report** puts the report and the last 200 log lines on the clipboard, for Discord.
- **Open an Issue** first shows exactly what will be shared, then opens a pre-filled bug report
  on the engine's GitHub (boykopovar/AnyPS5, or AnyPS5-ARM when its engine is in use), or
  **Report a Launcher Bug** on AnyPS5-Desktop. Your home folder, user and computer names,
  e-mail addresses and AnyTogether tokens are taken out of everything, and the link stays
  within GitHub's length.

The same report is in a game's options as **Last Session's Report**. **Detailed Logging
(Trace)** in a game's options starts it with the engine's trace switches every time; **Play
with Detailed Logging** does it once; starting the launcher with `--trace` does it for every
game until it closes. Game logs no longer grow without end: a log over 32 MB is set aside
before a start, and one passing 256 MB while the game runs starts again.

## 0.1.3

### System fonts for every game

Games that ask for the console's system fonts get them without anything to set up: Noto Sans,
Noto Sans Mono, Thai and Arabic come with the launcher (5.5 MB), and Japanese, Chinese and
Korean (Noto Sans CJK, 100 MB) download the first time a game needs them. A game started in
Japanese, Korean or Chinese waits for them, with the download in a toast; a game seen asking
for them in its log gets them in the background, and its next start waits for them. (Some
games, Astro's Playroom among them, stop at start-up without system fonts.)
**Settings → Fonts** shows which font each script gets and from where, downloads or removes
the CJK fonts, and takes a folder of your own (the console's fonts, say): its files come first
and the launcher's fill in what it lacks. The Noto fonts are under the SIL Open Font License
1.1, shipped beside them.

### Hidden trophies

In the trophy list, △ / Y (or O, or a click on **Show**) shows a hidden trophy's name,
description and icon until the list closes; △ again hides it. **Settings → Behaviour → Always
Show Hidden Trophies** shows them all.

### Party join codes and a Discord link

A party's leader can make a join code (**Party → Make a join code**), shown as XXXX-XXXX, and
copy it or its link for people who are not friends yet. Whoever has it asks to join; the
leader lets them in or turns them down, and a yes is an invite they answer. **New code** and
**Stop the code** replace or end it. **Party → Join with a code** shows whose party a code opens
and asks to join it. The leader can also set the party's Discord link; everyone in the party
gets **Open in Discord**.

### Controllers in the launcher

A controller moves through the launcher as on the console, on Windows and Linux: the D-pad or
the left stick moves (held, it repeats), Cross/A selects, Circle/B goes back, Triangle/Y or
Options opens a game's options, L1 and R1 go to the game before or after, and **PS/Guide**
brings the launcher in front of the game and takes you back to it. Xbox and other XInput pads
and PlayStation pads (DualSense, DualShock 4) work on Windows; any pad the kernel gives a
joystick on Linux. Several at once, and pads plugged in later, are picked up by themselves.

### Trophies while you play

- A PS5-style card drops in at the top of the screen when the game earns a trophy, with the
  trophy sound, above the game and without taking its keyboard, mouse or controller. On Linux
  under X11 it is a card too; under Wayland it is a desktop notification.
- At that moment the launcher keeps a picture of the game in `Pictures/AnyPS5/<game>/`. The
  trophy list shows it beside the trophy, and **Game settings → Screenshots** shows every
  picture of the game, F12 ones included. (Wayland lets no program read another's window: no
  picture there.)

### Full screen and window size work with upstream's engine

Upstream's engine reads neither choice: it opens at 60% of the screen and switches with F11.
The launcher now does it for it: once the game's window opens it sizes it, or presses F11 for
full screen; the setting says so. **Settings → AnyPS5 Engine → Engine** also offers the
**AnyPS5-ARM engine**, which opens at your size or full screen by itself and takes the phone
controller. It downloads from AnyPS5-ARM's signed GitHub releases and is checked against their
signed checksums.

### The mouse and the keyboard

- Every panel has a **Close/Back** button, closes when you click beside it, and the right mouse
  button is Back everywhere, as Esc is.
- The **‹ ›** of a choice and the **− +** of a number are buttons of their own; **←** now always
  goes to the option before (it went to the next one on rows of two). Rows, tabs, tiles and
  buttons light up under the pointer, and the focus follows the pointer without fighting the
  keys.
- The key hints at the bottom are buttons: click **Enter**, **Esc**, **O**, **Q** or **E**.
- A click on a game selects it at once (it used to wait to see whether a second click came);
  a double click plays or unlocks it, in the library too. The wheel moves between games on the
  home screen.
- Smoother screens: layers open and close within 200 ms, the background holds still under them
  (the blur is no longer worked out again on every frame), pictures load away from the
  interface, and nothing reads the disk while a screen is drawn.

### Game music

Games with a theme song (`sce_sys/snd0.at9`, as Hollow Knight: Silksong's dump has it) play it
on the home screen; games without one stay quiet.

### Sounds

The launcher was silent; it now sounds like the macOS launcher.

- **Interface sounds:** soft ticks for moving between games, buttons, the top bar, rows and
  tabs, a rising pair for selecting and opening, a falling one for going back, and a brighter
  three-note sound when a game finishes unlocking, the engine finishes downloading or a trophy
  pops. They are the Mac launcher's own tones, made on the spot.
- **Game music:** rest on a game and, after a moment, its theme song (the dump's
  `sce_sys/snd0.at9`) fades in and repeats from its loop point, as on the PS5. It fades out
  when you move on, switch to another window, or start a game.
- **Settings → Behaviour:** **Interface Sounds** and **Game Music** volumes (Off at 0).
- While a game is in front, the launcher stays quiet.

### The toolkit downloads itself on first start

No more downloading upstream files by hand, renaming the relinker and arranging `libs/`. The
first start's last step offers **Download the AnyPS5 engine (recommended)**: the launcher reads
the latest [boykopovar/AnyPS5](https://github.com/boykopovar/AnyPS5/releases/latest) release,
shows its version and size, downloads the relinker and system libraries for your system with a
progress bar, checks them against GitHub's checksums and sets them up. A folder of your own
still works: choose **I have my own folder**.

- **Settings → AnyPS5 Engine:** the engine in use, **Check for engine updates**, every version
  GitHub lists (switch to a downloaded one or download another), **Delete other versions**,
  **Use my own folder**.
- **Engine updates:** at start the launcher looks for a newer engine. When one is out, your
  installed games offer **Update and Play**, which downloads the new engine and unlocks the game
  again; saves and trophies stay.
- An interrupted download carries on where it stopped. A file GitHub has no checksum for is
  only used if you choose it a second time.
- Engines are kept in `%LOCALAPPDATA%\AnyPS5\Toolkits` (Windows) and
  `~/.local/share/AnyPS5/Toolkits` (Linux).

### Install

1. Install AnyPS5 Desktop as before (Windows installer or portable zip; Linux AppImage, .deb or
   tar.gz).
2. Start it, pick a language, a theme and your games folder, then choose **Download the AnyPS5
   engine**. That's all.
