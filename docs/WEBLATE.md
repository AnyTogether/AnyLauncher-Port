# Setting up Weblate (maintainers)

The language files of all three apps are monolingual JSON with English as the source, so each app
is one Weblate component and setup is the same form three times. Create a project **AnyPS5**
(source language English), then add the components below with **File format: JSON file** (the
simple key/value one, *not* "JSON nested structure file": keys such as `activity.unlocking`
contain dots and must stay flat), **Template for new translations** left empty, **Language code
style: BCP style using hyphen as a separator** (new files come out as `pt-BR.json`, the names the
apps and checks expect), **Translation flags** `objc-format` (Weblate then checks `%@`, `%d`,
`%1$@` and `%%` the way `check_translations` does), and **File format parameters** with an
indentation of 2 spaces and non-ASCII characters kept as they are, so the files stay readable in
diffs. Use **Version control system: GitHub** (pull requests, as `main` is PR-only; the token
needs contents and pull-request write access) and push to a `weblate` branch: every Weblate push
becomes a pull request that the language check runs on, merged like any other. Add the
**Cleanup translation files** add-on so keys removed from English leave the other files too, and
give the `languageName` string the explanation "Your language's name in itself, as Settings lists
it (Deutsch, not German)". Nothing in the files names a console language: the apps derive it
from the file name.

| Component | Repository, branch | File mask | Monolingual base language file |
|---|---|---|---|
| Windows/Linux launcher | `https://github.com/AnyTogether/AnyLauncher-Port.git`, `main` | `assets/l10n/*.json` | `assets/l10n/en.json` |
| Mac launcher | `https://github.com/AnyTogether/AnyPS5-ARM.git`, `main` | `tools/macos/launcher/l10n/*.json` | `tools/macos/launcher/l10n/en.json` |
| Phone app | `weblate://anyps5/mac-launcher` (the Mac component's checkout), `main` | `mobile/assets/l10n/*.json` | `mobile/assets/l10n/en.json` |

The three files share key names wherever the text is the same, so Weblate's translation memory
(on by default, shared within the project) suggests a string translated in one component for the
same English in the others. Keep [TRANSLATING.md](../TRANSLATING.md) as the translators' guide
and link the Weblate project from its first section once it exists.
