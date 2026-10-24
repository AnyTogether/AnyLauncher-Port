# Release notes

Notes for the next GitHub release, written as changes land; the section is copied into the
release when it is made.

## Next release

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
