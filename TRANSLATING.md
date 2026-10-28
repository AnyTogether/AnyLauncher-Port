# Translating AnyPS5 Desktop

Every text the launcher shows lives in one file per language in
[`assets/l10n`](assets/l10n): `en.json` is English, `tr.json` is Turkish. To add a language
you add one file there. No programming is needed, and nothing else has to change: the launcher
finds the file and lists the language in **Settings › Language** and on the first start.

## Add a language

1. Copy `en.json` and name the copy after your language's code: `de.json` for German,
   `fr.json` for French, `pt-BR.json` for Brazilian Portuguese. Use the two-letter
   [ISO 639-1 code](https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes), with a region
   after a dash only when you need one.
2. Fill in the `"@meta"` part at the top:

   ```json
   "@meta": {
     "name": "Deutsch",
     "consoleLanguage": 4
   },
   ```

   - `name` is the language's name in the language itself (`Deutsch`, not `German`). This is
     how it appears in Settings.
   - `consoleLanguage` is the language a game starts in when its own language setting follows
     the launcher. Pick the number from the table below.
3. Translate the text after each colon. Leave the part before the colon (the key) exactly as it
   is.

   ```json
   "back": "Zurück",
   "gamesFound": "%d Spiele gefunden",
   ```

You do not have to translate everything at once. A text you leave out (delete its line) or
have not reached yet is shown in English, so a half-done file already works.

### Console language numbers

| Number | Language | Number | Language |
|---|---|---|---|
| 0 | Japanese | 11 | Chinese (Simplified) |
| 1 | English (US) | 12 | Finnish |
| 2 | French | 13 | Swedish |
| 3 | Spanish (Spain) | 14 | Danish |
| 4 | German | 15 | Norwegian |
| 5 | Italian | 16 | Polish |
| 6 | Dutch | 17 | Portuguese (Brazil) |
| 7 | Portuguese (Portugal) | 18 | English (UK) |
| 8 | Russian | 19 | Turkish |
| 9 | Korean | 20 | Spanish (Latin America) |
| 10 | Chinese (Traditional) | 21 | Arabic |

If your language is not in the table, use 1 (English): games then start in English.

## Rules for the texts

- **Keep the keys.** Only the text on the right of the colon is yours to change. A key the
  English file does not have (often a typo) is an error.
- **Keep the placeholders.** They are filled in by the launcher:
  - `%@` is a word or a name (a game, a version, a person),
  - `%d` is a number,
  - `%%` is a percent sign.

  Each text needs the same placeholders as its English text, no more and no fewer. Where your
  sentence needs them in another order, number them: `%1$@` is the first one, `%2$@` the
  second. English `"Starting %2$@ with %1$@"` becomes Turkish `"%1$@ ile %2$@ başlıyor"`.
- **Keep the JSON.** Every text is in double quotes and every line but the last ends with a
  comma. A double quote inside a text is written `\"`. Many editors (and GitHub, see below)
  point out a missing quote or comma.
- Words such as AnyPS5, AnyTogether, DualSense, Steam, GitHub and file names stay as they are.

## Try it

**In a released launcher**, with no building: put your file in the launcher's `Languages`
folder (create it if it is not there) and start the launcher again.

- Windows: `%APPDATA%\AnyPS5\Languages` (type it into the File Explorer address bar)
- Linux: `~/.config/AnyPS5/Languages`

Open **Settings › Language** and choose your language. A file there comes before the built-in
one of the same code, so you can try a changed `tr.json` the same way. If your language does
not appear, the file is not valid JSON: the check below says where.

**From the source**, if you build the launcher yourself: put the file in `assets/l10n`, run
`flutter run`, then Settings › Language. `dart run tool/check_translations.dart` runs the same
check as GitHub does and shows how much of each language is translated.

## Send it in

Without git, in the browser:

1. Open [`assets/l10n`](assets/l10n) on GitHub and choose **Add file › Create new file** (or
   **Upload files** to drop in the file you made). GitHub offers to make a copy of the project
   (a fork) for you; accept it.
2. Name the file (`de.json`), paste or upload its contents, and choose **Commit changes**,
   then **Propose changes** and **Create pull request**.
3. The checks run on the pull request. If the language check fails, open its details: each
   problem names the key, and what is wrong with it. Fix it in the same file on your fork (the
   pencil icon) and the checks run again.

With git, the usual way: a branch with your file, pushed to your fork, and a pull request.

## When new texts appear

New launcher features bring new keys in `en.json`. Until they are translated they show in
English, and the check's log lists how much of each language is done, for example
`de: 92.4 % translated (1174 of 1270, 96 shown in English)`.

To catch up, compare your file with `en.json` (GitHub's **History** of `en.json` shows what was
added), copy the new lines into your file and translate them. The order of the lines does not
matter. A key removed from English has to go from your file too: the check names it.
