# Production audit — vishnawat.macmenu

Audited against the first-party reference at `/usr/share/omarchy/shell/plugins/menu/`
(`Menu.qml`, `MenuModel.js`), the harness `/usr/share/omarchy/shell/shell.qml`,
and the shared services the host already owns (`shell/services/AppLibrary.qml`,
`AppSearch.js`). Line numbers below refer to `MacMenu.qml` unless a path is given.

---

## 0. Headline

The plugin re-implements, by hand, three large subsystems the host already
shipped and already injects into every `kind: "menu"` plugin:

1. the menu-tree parse/merge (AppLibrary copies of `MenuModel.js` semantics),
2. the guard (`when:`/`checked:`) batch scanner (`MenuModel.guardScript`),
3. the entire AppLibrary stack (desktop-entry list, hidden-entry scan,
   launcher.hides parse, icon fallback index, `iconSource`, launch).

Because `manifest.json` declares `kinds: ["menu"]`, the host injects a scoped
shell API whose `appLibrary` is already wired
(`shell.qml:601-604` → `pluginAppLibraryFor`, and forwards `appsChanged`
via `shell.qml:1065-1071`). Almost none of that is used: `shell` is declared at
line 19 and never read.

---

## 1. DEAD CODE / CUTS

| # | Location | What | Why it is dead / redundant |
|---|----------|------|----------------------------|
| D1 | 19 | `property var shell: null` | Declared to satisfy the injection contract, never used. Either use it (fix D2 below) or it is a dead property. |
| D2 | 290-293 | `bashQuote()` | Byte-for-byte replaceable by `Util.shellQuote()` (Util.qml:49), which the first-party plugin uses (Menu.qml:130,132,276). Used three times (223, 275, 622). |
| D3 | 61 | `readonly property bool searchVisible: true` | Constant-true. Every consumer is dead generality: 753 (`visible: root.searchVisible` always true), 815 (ternary always takes `Style.space(14)`). Delete the property and the ternary. |
| D4 | 281-288 | `activateEntry(id, fallbackAction)` | Not called from anywhere — the two `grep`able call sites are its own body. The `fallbackAction` branch (283-286) is unreachable. |
| D5 | 254-261 | body of `runCommand` | Lines 259-261 duplicate `cancel()` (108-113) field by field. Should be `root.cancel()` after nothing else — or better, delegate to `root.shell`-level hide. |
| D6 | 170/172-174 | `itemOf` | Trivial alias for `MenuModel.item(items, id)` (MenuModel.js:166-168). Keep the alias if you like, but the point is the whole local tree engine is a fork (see §2). |
| D7 | 94-96 | `ping()` | Fine as contract, but note the host's `callIfLoaded` (shell.qml:1279-1291) already returns `"ok"`-like strings and the menu manifest carries no scenarios that use it. Contract, not dead — kept, but do not add more hand-rolled verbs like `debug()` (98-106) without an IPC surface; no `IpcHandler` targets `debug`, so it can only be reached via `shell call vishnawat.macmenu debug`. |
| D8 | 88-92 | `refresh()` | Divergence from Menu.qml:38-42: upstream calls `defaultMenuFile.reload(); userMenuFile.reload()`. On this copy the two FileViews already have `watchChanges: true`, so by the time the caller invokes `refresh()` the parse has usually been redone — and the wrapper rebuilds from stale text anyway. Either delegate to `reload()` or drop it and rely on the watcher only. |
| D9 | 40-41, 1017-1022 | `tile.inMenu` / `menuEntry` split in the tile | `tile.menuEntry` is computed from `homeMode` only, then `isMenu` re-derives a property that `activateRow` re-derives again (220, 266-278) and `pageRows` a third time (211). Same link/provider resolution logic lives in three places; the `isMenu` gate at 1019-1022 is the only consumer of `menuEntry.provider !== "apps"` and duplicates the test at 222 and 274. Keep single resolver (`resolveToRow(id)`), delete the rest. |

Not dead but worth naming: the dock's route `"home"` and route `"apps"` (lines 63-71, 576-581) both funnel to `goHome()` (576-581) — the "Apps" dock tile never
opens the apps page; it returns to home grid which is already the home grid.
The tile is effectively a labelled duplicate of Home.

---

## 2. DUPLICATION vs upstream — replace with first-party shares

### 2.1 The entire apps pipeline is a copy of `AppLibrary.qml` (worst offender)

MacMenu re-implements, verbatim, code the host already runs **in the same
process** through the injected `shell.appLibrary`:

| MacMenu.qml | AppLibrary.qml | Contents |
|---|---|---|
| 420-430 `loadHides` | 100-109 `loadConfiguredHides` (+111-120 desktop variant) | launcher.hides line parser (incl. `.desktop` suffix trim) |
| 620-623 `hiddenEntryScanCommand` | 150-154 | exact same env-var gather + script path + arg quote |
| 663-676 launcher.hides `FileView` | 220-227 | identical path, `watchChanges`, `onLoaded/onFileChanged/onLoadFailed` |
| 678-694 `hiddenEntryScan` Process | 185-199 | identical QtObject accumulator + SplitParser + onExited parse |
| 625-636 `iconIndexScanCommand` | 122-137 | line-for-line identical bash |
| 638-647 `indexIconLine` | 139-148 | identical |
| 696-704 `iconIndexScan` Process | 202-210 | identical |
| 706-710 `iconIndexDebounce` | 214-218 | identical 750 ms timer |
| 559-569 `iconSource` | 57-69 | identical lookup ladder (file://, absolute, index, themed, exec fallback) |
| 119-143 `mergeInto` | 13-39 `normalizeItem` + 65-95 `mergeMenuSources` | same normalisation and merge-on-per-key semantics, re-derived |
| 432-457 `rebuildApps` | 52-55 `sortedEntries` + Menu.qml 287-328 `mergeAppRows` | same filter-noDisplay, same keyword haystack, same alphabetical sort |

That is roughly 170 lines of duplicated Bash-launching, FileView-watching
infrastructure. Worse, since `keepLoaded: true`, both copies run **at shell
startup**: two concurrent `hidden-entries.sh` processes and two concurrent
`find` icon-index sweeps (one from the host singleton, one from this plugin),
plus one more set each time `DesktopEntries.applications.values` changes —
AppLibrary fires it (AppLibrary.qml:255-262) and this plugin fires a second
listener (654-661).

**Concrete fix:** delete lines 418-710 down to the three functions that remain
plugin-specific, and rebuild the row list from the injected proxy:

```qml
Connections {
  target: root.shell.appLibrary   // PluginAppLibraryApi emits appsChanged()
  function onAppsChanged() { root.rebuildApps() }
}
```

Use `appLibrary.sortedEntries("")` for rows, `appLibrary.iconSource()` (see
`_iconSource` in `shell.qml:430`), and drop the plugin's own Process/FileView
pair entirely (`hiddenEntryScan`, `iconIndexScan`, the launcher.hides FileView
at 663-676, `iconIndexDebounce`, `pendingIconIndex`, `desktopHiddenIds`,
`defaultHiddenIds`).

### 2.2 The guard scanner re-derives `MenuModel.guardScript`

Lines 299-323 build the same `id:w:c:1/0` batch pipeline that exists
upstream as `MenuModel.guardScript(items)` + `guardPrelude` (MenuModel.js:431-478)
plus `guardLine` with reader substitution (MenuModel.js:450-459). Three concrete
high-quality properties are lost in the re-derivation:

- **Package set** (MenuModel.js:410-423): upstream builds one `pacman -Qq`
  capture plus a `-Qi` provides parse; the local helpers (301-304) fork
  `pacman -Q` per argument per guard. On a menu with 30 `omarchy-pkg-*`
  conditions that is the difference between one fork and ~90.
- **Reader substitution** (MenuModel.js:383-391, 431-455): upstream captures
  `omarchy-default-editor`, `omarchy-default-browser` etc. **eagerly** so seven
  sibling rows keyed on the same command read one evaluation. Here every
  guard row that contains `$(omarchy-default-editor)` runs that command itself,
  serially.
- **Guard cycle guard** (`if (guardProc.running)` + `guardsPending`,
  Menu.qml:959-1014): upstream defers an evaluation that ran while the batch
  was already in flight. MacMenu has no equivalent (see §3).
- **Parseable parse outcome**: upstream parses the raw JSONC once into
  normalized items and reuses them; here the raw text is re-stripped and
  re-parsed inside the property binding (309-314) — a second full JSONC pass
  per file per recomputation, both in QML evaluator and at process spawn.

**Concrete fix:** import the shared engine. `MenuModel.js` is a plain JS file;
it can be imported from a third-party plugin by absolute URL:

```qml
import "file:///usr/share/omarchy/shell/plugins/menu/MenuModel.js" as MenuModel
```

(If pinning to the installed copy is unacceptable, keep a local `MenuModel.js`
mirror but use `guardScript`/`guardPrelude` from it verbatim instead of
re-writing the helpers at 300-304 — the code comment block at MenuModel.js:380-409
documents four subtle Linux behaviours the rewritten helpers got wrong:
provides resolution, COLUMNS-wrapped `-Qi` output, version constraints, and
errexit safe readers.)

### 2.3 Search scoring / matching re-derivation

`filteredApps` (459-472), `filteredPageRows` (474-485) and
`globalMenuResults` (515-549) summarise substrings from
`name + subtext + keywords + appId` the same way `matchesQuery`,
`nameSearchText`, `searchableToken`, `termInSearchWords`,
`descriptionTextMatches`, `searchScore` do upstream
(MenuModel.js:279-352). The first-party one keeps word-boundary discipline,
term scoring and the "app exact word beats menu" ranking. At minimum reuse
`matchesQuery` and `searchScore` so searching behaves the same across menus.

---

## 3. FUNDAMENTALS ISSUES (correctness, data structure, guards, errors)

### F1 (HIGH) Guard script can update while a scan is running — update is lost
Lines 396-405 + 383-391.

```qml
onGuardScriptTextChanged: {
  if (root.guardScriptText.length === 0) return
  guardScanTimer.restart()
}
```

If `guardScriptText` recomputes **while `guardScan.running` is true**, the
timer fires, sets `guardScan.running = true` on an already-running process
(no-op under Quickshell), and the new script value never runs. Worse, the
`command:` is a *binding* (368) — changing the script while running means the
exiting process's `onExited` (383) publishes results from the **old** script,
with no pending re-run. Menu.qml solves exactly this with
`if (guardProc.running) root.guardsPending = true; return` and a deferred
re-evaluation in `onExited` (Menu.qml:959-1014, and the whole reasoning in the
comment at 956-958). Mirror that pattern.

### F2 (HIGH) Guard `onExited` ignores exit status — a killed run can hide rows
Line 383-386.

```qml
onExited: { root.whenResults = splitWhen; root.checkedResults = splitChecked }
```

A scan killed mid-run (or a bash `set -e` abort in some body) publishes the
partial maps. Menu.qml:982-990 explicitly guards:
`if (exitCode !== 0 || exitStatus !== 0) … return` with the comment "a batch
that was killed rather than finished has only told us about the rows it
reached… Keep the last complete set". MacMenu flips silent row deletion on
transient failure — the exact failure mode upstream coded against. Reuse the
upstream exit-status check, or copy a local `MenuModel.js` and its `guardScript`
and consumer shape.

### F3 (HIGH) Parent lookup in `globalMenuResults` has no recursion guard → can hang the shell
Lines 530-537.

```qml
var ancestor = entry.parent
while (ancestor && root.itemOf(ancestor).parent !== "root" && root.itemOf(ancestor).parent) {
  ancestor = root.itemOf(ancestor).parent
}
```

A malformed user JSONC that declares `A.parent: "B"` and `B.parent: "A"` is a
valid object graph — the parse loop (145-158) does not detect cycles — and the
`while` becomes an infinite loop inside the `searchGroups` binding, so typing a
single search character pins the quickshell process at 100% CPU. Everything
else in the tree walk has an explicit guard: `hasVisibleChildren` (16, line 177),
`breadcrumbOf` (line 504 `guard++ < 16`), MenuModel `depthFor`/`pathFor`/
`isDescendantOf` (`guard < 32`). Reuse `MenuModel.isDescendantOf`/`depthFor`
instead of hand-walking (and cap with a guard counter at the least).

### F4 (HIGH) In-place writes into a QML `var` property
Lines 145-158 `mergeInto` writes `items[id] = merged` on the caller-passed
`nextItems` object; 638-647 `indexIconLine` mutates `root.pendingIconIndex` in
place. First-party explicitly warns against both:
MenuModel.js:97-103:

> "They must never write into the maps they are handed: those live in QML `var`
> properties, and an in-place write into such an object is occasionally dropped
> by the engine — the key lands with an undefined value. A lost write used to
> leave an id in itemOrder with no item behind it…"

`rebuildMenu` already returns fresh maps (161-169) which sidesteps mergeInto's
problems, but `indexIconLine` writing to `root.pendingIconIndex`, guarded only
by `=== undefined`, is the exact lost-write risk: a dropped key in a
first-name-wins index makes the themed fallback pick up a wrong or missing
icon silently. `AppLibrary.qml:139-148` has the same pattern — copy the
upstream stop keeping the duplicate, do not try to fix another copy of it.

### F5 (MEDIUM) Home-page search silently drops app results
Lines 58-60 + 515-557.

When `filterText` is non-empty, `displayRows` switches to `searchRows` which is
built **only** from `globalMenuResults(terms)` (553-557). `filteredApps` is
only reachable in `homeMode` — but `searchMode` and `homeMode` are mutually
exclusive, so `filteredApps` filtered-by-search is dead. Net effect: launchpad
search finds menu entries only, and typing on the home page replaces the app
grid entirely with nothing-but-menus (tiles at 888-900 show "No apps match"
way less often than it shows "No matches"). Upstream searches the apps and
scoring ranks menu+apps together (Menu.qml:584-628 — "Keep the Apps menu
alphabetical…"). Decide intentionally, then document and fix `visible`
messaging; either add `appRows` matches to `searchRows` or name the limitation
in the manifest description.

### F6 (MEDIUM) Server-side arrow key navigation ignores pageHeader's height math
Lines 613-618 `ensureVisible` vs 1121-1181.

```qml
var rowHeight = tileH + Style.space(8)
var y = Math.floor(index / itemGrid.columns) * rowHeight
```

Search mode rows are laid out by `searchColumn` (904-1000) inside **nested
`Grid`s with different column counts** (`searchGroup.columns` at 920, i.e.
dependent on grid width, not necessarily `itemGrid.columns`) with group
headers between them. `ensureVisible` computes `y` as if the set were
`itemGrid`-laid — so once you type, `Down`/`Up` scroll the wrong distance and
leave the selected tile off-screen. Fix by storing the real y of each tile on
the tile delegate (`groupTile.mapToItem(flick, 0, 0).y`) and using that in
`ensureVisible`, or search entries into a single flat grid.

### F7 (MEDIUM) Escape/Enter/arrow surface is a subset of the convention
Lines 784-806 vs Menu.qml:1075-1117. Upstream supports: delete (with confirm
dialog), Escape→back, Backspace-to-go-back, PageUp/PageDown, Right-to-open
folder, first-typed-character-to-filter, and `Keys.priority: Keys.BeforeItem`
with typed-character handling catching `event.text` (Menu.qml:1113-1115).
MacMenu handles only Esc/Enter/Up/Down and relies on the `TextInput` for
text entry — acceptable, but a macmenu user cannot PageDown a long app grid or
disconnect from a drilldown with the keyboard. Document the delta or align.

### F8 (MEDIUM) `selectedIndex` carried across page-level model change without reset
Lines 584-587 only clamp on `displayRows` change. Opening via
`runCommand → opened=false → opened=true` (lines 255-260, 73-82) leaves
`filterText = ""` + `selectedIndex` from the previous session's row index.
Not fatal, but you also need to reset on `open()` since `open()` does not reset
`selectedIndex` (73-82, only `navPage`/`goHome`/`goBack` do at 229/237/250).

### F9 (LOW) `parseMenuJsonc` swallows errors with no warning
Lines 147-151 — `catch (e) { return }`. Upstream also swallows
(MenuModel.js:47-50) but pairs it with `printErrors: false` on the FileView.
At least `console.warn("omarchy-menu.jsonc parse failed:", e)` so a corrupt
user file does not produce an empty tabs row with no diagnostic. Same for the
`Guard scriptText` parse (309-314).

### F10 (LOW) `onLoadFailed` on the default menu file wipes the tree
Lines 340-345 — sets `defaultMenuText = ""` then rebuilds the whole tree from
just the user file. The default file is under `/usr/share`; its failure path
(unit-mount transient, helper substitution path) destroys the menu instead of
leaving the last good copy (`FileView` retains the previously loaded `text()`
as long as it is not reloaded). Prefer "keep the last good" behavior when the
file was previously loaded.

### F11 (LOW) Missing completion feedback for icon/guard scans
All four `Process`es have no `onErrored` / timeout handling. A tool that hangs
(`find` can take long on NFS mounts) is a permanently running process holding
the `iconIndex` fresh flag; `Menu.qml` at least models the reader-capture.
Add `onErrored` + a max wall clock, or at least `property bool scanning`
gating UI affordances.

### F12 (LOW) `hasVisibleChildren` recomputes per parent per render
Lines 176-193 called from `rowVisible` (188-193) called from `childrenOf`
(195-204) called from `pageRows` (206-214), which is a `readonly` binding
property (46). Every `items`/`itemOrder`/`whenResults` change re-runs
O(children × itemOrder) scans; with the shipped 100+ item menu and nested
folders that is O(N²) per recompute, then repeated for every row of every
page render. Upstream `isVisible` (MenuModel.js:254-271) has the same shape but
with a 32-deep cap. If you keep the engine, memoise per-build
(`property var _visibilityMap`), especially after #F1 lands.

---

## 4. OMARCHY BEST-FIT EXPECTATIONS

| Convention | Reference | vishnawat.macmenu | Verdict |
|---|---|---|---|
| `schemaVersion`, `id`, `name`, `version`, `author`, `description`, `kinds`, `entryPoints.menu` | manifest.json:1-15 | verbatim shape | ok |
| `keepLoaded` true and panels surviving hot reload + plugin reload cycle | manifest `"keepLoaded": true`; shell.qml `panelEntries` (929-966) & `unloadPanels` (945) | same | ok |
| Layer namespace namespaced to plugin id | `"omarchy-menu"` (Menu.qml:1022) | `"omarchy-macmenu"` (717) | ok — distinct, follows `<prefix>-<role>` shape |
| `WlrLayer.Overlay` + `WlrKeyboardFocus.Exclusive` + `exclusionMode Ignore` | Menu.qml:1023-1025 | 718-720 | ok |
| IPC surface: `open(payloadJson)`, `close()`, `refresh()`, `ping()` | Menu.qml:21-45 | 73-106 present (plus `debug`) | contract kept by *shape*, but **`payloadJson` is not parsed** — see below |
| Payload semantics: `mode: "select"|"input"`, `initialMenu`/`menu`, `fontFamily` | Menu.qml:22-32, 819-839 | `open(payloadJson)` ignores the argument entirely (73-82) | **deviation** |
| `openable`/`dismissable` correctness | upstream `cancel()` does not clear `requestActive` for dmenu because the surface differs | no-op there | ok |
| `shell.appLibrary` reuse | `root.appLibrary: root.shell ? root.shell.appLibrary : null` (Menu.qml:80) | never read `shell` | **deviation**, the big one (§2.1) |
| Reviewing icon refresh on open | `appLibrary.refreshIcons()` (Menu.qml:814) | triggers its own `iconIndexScan` instead (79) | fixed by 2.1 |
| Apps provider native rows | Upstream provider `apps` merges via `mergeAppRows()` (Menu.qml:287-328); `providers` table with `volatile`, `actionFor`, menuId-scoped batch swap (Menu.qml:269-328) | providers are not supported; every provider but `apps` hard-forks out to `omarchy-menu toggle` (222-225, 274-277) | **largest functional gap.** Once `shell` is used, `providers`/`providerProc` semantics are a copy away |

**Payload contract fix:** parse the payload and honour the fields upstream
accepts so `omarchy-shell shell summon vishnawat.macmenu '{"initialMenu":"system"}'`
behaves sanely:

```qml
function open(payloadJson) {
  var payload = ({}); try { payload = JSON.parse(payloadJson || "{}") } catch (e) { }
  root.rebuildApps(); root.rebuildMenu()
  root.navPage(payload.initialMenu || payload.menu || "home", false)
  …
}
```

Also: plugin manifest declaring only `"menu"` means the bar has no menu widget
to offer; users who enable this plugin still need the first-party
`omarchy.menu` bar widget to expose it through the standard dock. Either add
`kinds: ["menu", "bar-widget"]` + a `barWidget` entry point (looks like
Menu.qml's pattern: manifest `"barWidget"` block + `BarWidget.qml`) or say so
in the plugin description.

---

## 5. PERF

Ordered by wall-clock / CPU impact:

1. **Duplicate scans at startup** — see §2.1. Two concurrent
   `hidden-entries.sh` + two icon `find` sweeps on every shell start, and
   again per `DesktopEntries.values` burst. Fix: drop plugin-owned scans;
   consume `shell.appLibrary`.
2. **`pacman -Q` per argument, per guard** — lines 301-304 vs upstream
   package-set implementation (MenuModel.js:410-423). Directly comment-documented
   upstream as the rewrite driver: "Package and command presence account for
   most of what the guards ask, and asked one at a time they are almost all
   fork". Fix = keep `MenuModel.guardScript`. Measure with
   `time bash -lc <paste guardScriptText produced by MacMenu>` vs the same for
   the MenuModel version.
3. **Guard runs fire twice per menu edit** — one per `FileView.onLoaded` (334-360)
   since `guardScriptText` recomputes on each of `defaultMenuRaw` and
   `userMenuRaw` landing, and `guardScanTimer` (100 ms) coalesces them only
   when they land within 100 ms. Make `guardScanTimer` 200-250 ms, or
   set a single `property bool _menuDirty` and start the scan from one
   explicit `rebuildMenu()` site like upstream does (`evaluateGuards` called
   from `rebuildItemsFromSources` only, Menu.qml:246-262).
4. **`hasVisibleChildren` unbounded sweep per row per render** — see F12.
   When `whenResults` changes, every visible-row recomputation walks the
   whole `itemOrder` list per parent (`childrenOf` at 195-204 is
   O(itemOrder)), and each folder's own `rowVisible` walks recursively —
   top-level page render does 7 full sweeps, each of which per-parent walks
   the full order again for sub-menus. Memoize.
5. **`searchRows` binding walk re-runs full `globalMenuResults` per keystroke**
   (47-57 + 515-557). Even the 100 ms guardScanTimer debounce is not applied
   here: `filterText` decides display rows instantly. Cheap fix that matches
   upstream intent (Menu.qml:400-409 comment — "Search doesn't invalidate, or
   every keystroke would restart the same enumeration"): debounce with a
   40-60 ms Timer, or at minimum reuse `matchesQuery`'s early-exits rather
   than the haystack `indexOf` per term per entry.
6. **`rebuildApps` re-sorts + recomputes haystack strings on every
   `DesktopEntries.applications.values` change** (432-457 → 654-661); it
   rebuilds even when only the *icon index* changed and row set did not.
   AppLibrary's `onValuesChanged` triggers *one* scan + `appsChanged` (255-262);
   the plugin's extra Connections (654-661) means every launch feedback or
   package event triggers two full list rebuilds plugin-side plus a
   rescan-batch process. Wire to `appsChanged` of the injected `appLibrary`
   and drop the double.
7. **`dockItems` is a `readonly property var` literal containing 7 glyph
   strings, reset per load — fine. Minor.** No fix needed. But the
   `searchGroups` header `searchGroup.columns` at 920 recomputes
   `Math.floor(width / root.tileW)` per group per row-count change of
   `searchGroups`, and each group width's row height is also
   `groupTitle.height + groupGrid.height + 4` (919) — this is the binding
   forcing relayout on each keystroke's 7-60 group repeat. Cache the column
   count; when a group count changes, only the top-level Repeaters need
   binding updates.
8. **`selectedIndex` hover-writes per row**: `onEntered: root.selectedIndex = …`
   (967, 1039) fires also when the pointer merely passes; combined with
   `ensureVisible` (613-618) that means contentY changes while the user drags
   the pointer — the classic pointer-vs-keyboard race that upstream fixed
   with `PointerMoveGate` (Menu.qml:907-910, 871-879). Adopt that component.

---

## 6. Ordered summary

### Must-fix
1. **§2.1 / F12**: Stop duplicating the AppLibrary stack. Consume
   `shell.appLibrary` (injected because the manifest names `kind: "menu"`).
   Delete MacMenu.qml 418-710 except `rebuildApps`-only replacements, or cache
   and dedupe scans. Today the shell runs the hidden-entry + icon scans twice
   every start and every app-set change.
2. **F3**: Add a guard to the ancestor `while` loop at 530-537 (or reuse
   `MenuModel.isDescendantOf`); today a curated parent cycle in the user
   JSONC freezes the shell's search binding.
3. **F1 + F2**: Port Menu.qml's `guardsPending` / exit-status protection
   (959-1014) into the `guardScan` Process (383-405). A script update a
   moment after a scan begins must run again (currently lost), and a
   non-zero exit status must not publish partial results (currently does).
4. **§2.2**: Replace the hand-built guard script with `MenuModel.guardScript`
   (or at minimum its `guardHelpers()` + eager-reader substitution you ship
   alongside) so `pacman -Q`-per-guard and the reader-capture bug are removed.

### Should-fix
5. **F5**: Decide and document why keyboard search over the home grid can
   never match apps.
6. **F6**: Fix `ensureVisible` per-mode geometry (or swap search to a flat
   grid) so keyboard navigation in search mode scrolls correctly.
7. **F7** Keyboard surface delta (PageUp/PageDown/Backspace/Right) — align or
   document.
8. **§4**: Honour `open(payloadJson)` — at minimum `initialMenu`; otherwise
   `omarchy-shell shell summon vishnawat.macmenu '{"initialMenu":"system"}'`
   silently lands at Home.
9. **§4**: Add `bar-widget` + `barWidget` entry point, or note the plugin
   has no bar entry in the description — users still require `omarchy.menu`
   bar widget to summon it by mouse.
10. **D5**: Replace `runCommand`'s four resets with `cancel()`.
11. **D8**: Make `refresh()` call both `FileView.reload()`s like upstream.

### Nice-to-have
12. **D3**: Delete constant `searchVisible` and its ternary at 815.
13. **D2**: Replace `bashQuote` with `Util.shellQuote` and drop 290-293.
14. **D4**: Remove `activateEntry` (281-288), unreachable + unused.
15. **F9/F10**: `console.warn` on JSONC parse failure; keep-last-good on
    default-file load failure.
16. **F11/§5.6**: add `onErrored`/wall-clock guard on the four Processes; add
    `PointerMoveGate` for hover-vs-keyboard.
17. **§5.3/§5.5**: debounce `searchGroups` recompute; single
    `_menuDirty` coalescer for the guard scan.
18. **F12**: memoise `hasVisibleChildren`/`rowVisible` results in one pass
    keyed by id.
19. **Style**: follow upstream's `BorderSurface`/`ConfirmDialog`/`PanelWindow`
    shared components where they exist (`Menu.qml:1055`,
    `Menu.qml:1119-1136`) rather than plain `Rectangle`s — free theming and
    HiDPI correctness for free.
20. **F8**: reset `selectedIndex` in `open()` as well as `navPage/goHome`.

---

*Generated while auditing
`/home/vishnawat/.config/omarchy/plugins/vishnawat.macmenu/MacMenu.qml` and
`manifest.json` against the first-party reference; no behaviour change applied.*
