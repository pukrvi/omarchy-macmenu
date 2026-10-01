# Mac Menu for Omarchy

**One page. Apps first, everything else below, dock at the bottom.**

A Launchpad-style menu for [Omarchy](https://omarchy.org). It opens on your
app grid, keeps every menu folder on the same scrolling surface underneath,
and puts a dock along the bottom that scrolls to whichever section you tap —
instead of replacing the whole view every time you open a folder.

## Features

| | |
|---|---|
| **One page** | The app grid, then a headed grid per menu folder, all on one surface. The dock scrolls between them; nothing swaps out. |
| **One search field** | Apps and menu entries are matched together, and results stay grouped under the section they came from. |
| **Keyboard first** | Arrows move through rows and skip section headings. `Enter` runs, `PageUp`/`PageDown` jump a screenful, `Home`/`End` go to the ends. `Escape` clears the search, then closes. |
| **Follows your theme** | Colours, fonts, spacing and corner rounding come from the shell. The card edge uses the same border geometry as the built-in menu. |
| **Reads the real menu** | Your `omarchy-menu.jsonc` — the default tree and your own overrides — including `when:`, `checked:`, links and actions. |
| **No duplicate work** | Uses the shell's shared AppLibrary for the app list, icon lookup and launching, rather than running its own copy. |

## Install

From the [Omarchy plugin marketplace](https://plugins.omarchy.org/), or directly:

```bash
omarchy plugin add https://github.com/pukrvi/omarchy-macmenu.git --enable
```

Requires Omarchy 4.0 (Quattro) or newer. No extra dependencies.

## Using it

| | |
|---|---|
| Open | `Super` + `Space`, or click the menu bar button |
| Move | Arrow keys, or the mouse |
| Run | `Enter`, or click |
| Jump to a section | Click a dock item, or scroll |
| Clear the search | `Escape` |
| Close | `Escape` on an empty search, or click outside |

## How the sections are ordered

The page starts with your applications, alphabetically. Below that comes one
section per top-level folder in the menu — Trigger, Setup, Style, Learn,
System — in the order your menu file declares them. A folder whose rows are
all hidden by a `when:` guard does not appear in the dock, so the dock only
ever offers something that has content.

## Notes

This plugin declares `kinds: ["menu"]`, so it replaces the menu that
`Super`+`Space` opens. To go back to the stock menu, disable it:

```bash
omarchy plugin disable vishnawat.macmenu
```

## Removing

```bash
omarchy plugin remove <plugin-id>
```

`omarchy plugin list` shows the id your install uses. On a fresh install
from the repository above it is `io.github.pukrvi.macmenu`; in a checkout
cloned by hand, the folder name is the id.

This deletes the plugin folder and nothing else. The plugin keeps no state
of its own — favourites, settings and the search text all live in the menu
files you already had, and app data is read from the shell's shared
AppLibrary — so removing it leaves nothing behind to clean up by hand.

### Bash-provider submenus

Two submenus in the stock menu — `Style > Font` and `Trigger > Capture` —
enumerate their rows from a shell command rather than from the menu file, so
their contents cannot be known ahead of time. Clicking one hands off to the
classic menu for that submenu and it opens normally. Everything else is
rendered natively in this plugin.

## Development

```bash
./tests/validate.sh     # manifest, QML syntax, model tests
node tests/run.js       # model tests on their own
```

Edits under `~/.config/omarchy/plugins/` reload automatically. The model
tests run the plugin's tree logic directly as JavaScript, without needing a
running Quickshell — which is what makes the parent-cycle test possible: a
regression there hangs your shell rather than failing a build.

## License

MIT. See [LICENSE](LICENSE).
