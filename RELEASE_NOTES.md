# Release notes

Notes for the next GitHub release, written as changes land; the section is copied into the
release when it is made.

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
