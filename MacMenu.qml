// Apple-style visual OS menu (Launchpad app grid + a mac-front-end dock).
//
// Unlike the classic list menu, this plugin renders the Omarchy menu tree
// itself: the default and user JSONC definitions are parsed into the same
// id/parent tree, top-level pages open as native rows inside this card, and
// leaf actions run without ever touching `omarchy-menu`. Only the two
// bash-provider submenus (e.g. Style > Font) fall back to the classic menu,
// because their row data comes from a shell enumeration the plugin does not
// reimplement.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool opened: false
  property string filterText: ""
  // Index into sectionRows, the flat list of every row on the page. -1
  // means nothing is selected, which is the resting state after a dock
  // scroll so the keyboard starts from the section the user just jumped to.
  property int selectedIndex: -1
  property var appRows: []
  property var items: ({})
  property var itemOrder: []
  // Icon index fallback, used only when the shared AppLibrary is not
  // injected (a preview harness); the library owns this in the real shell.
  property var iconIndex: ({})
  property var whenResults: ({})
  property var checkedResults: ({})

  readonly property int appleRadius: Math.max(Style.cornerRadius, 18)
  readonly property real tileW: Style.space(104)
  readonly property real tileH: Style.space(104)

  readonly property bool searchMode: root.filterText.length > 0
  readonly property var searchGroups: root.searchMode ? root.filteredMenuEntries() : []
  // ------------------------------------------------------------ sections
  //
  // One scrolling surface, not a page per folder. The card is an ordered
  // list of sections — apps first, then one per top-level menu folder —
  // and the dock at the bottom scrolls to a section instead of swapping
  // the whole view. Rows still activate and launch exactly as before; the
  // flat row list only exists so the keyboard has one index space.

  // Top-level folders the dock offers, in menu order, skipping any whose
  // guard hides every descendant.
  readonly property var sectionItems: {
    var out = []
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.items[root.itemOrder[i]]
      if (!entry || entry.id === "root") continue
      if (entry.parent !== "root" && entry.parent !== "") continue
      if (root.whenResults[entry.id] === false) continue
      if (!root.hasVisibleChildren(entry.id, 0)) continue
      out.push(entry)
    }
    return out
  }

  // Dock model: apps and menu are scroll targets, then one per section.
  readonly property var dockItems: [
    { icon: "󰄻", iconFont: "", label: "Apps", section: "apps" },
    { icon: "", iconFont: "omarchy", label: "Menu", section: "menu" }
  ].concat(root.sectionItems.map(function(entry) {
    return {
      icon: entry.icon || "󰃜",
      iconFont: entry.iconFont || "",
      label: entry.title || entry.label || entry.id,
      section: entry.id
    }
  }))

  // Flat render model for the single page. In search mode each section
  // contributes only the rows that matched, so sections with no match drop
  // out entirely rather than rendering an empty header.
  readonly property var sectionRows: {
    var out = []
    if (!root.searchMode) {
      var apps = root.filteredApps()
      out.push({ kind: "header", title: "Apps", section: "apps" })
      for (var a = 0; a < apps.length; a++) out.push({ kind: "app", app: apps[a] })
    }
    for (var s = 0; s < root.sectionItems.length; s++) {
      var section = root.sectionItems[s]
      var rows = []
      if (root.searchMode) {
        for (var g = 0; g < root.searchGroups.length; g++) {
          if (root.searchGroups[g].section !== section.id) continue
          rows = root.searchGroups[g].items
          break
        }
      } else {
        rows = root.childrenOf(section.id)
      }
      if (rows.length === 0) continue
      out.push({ kind: "header", title: section.title || section.label || section.id, section: section.id })
      for (var r = 0; r < rows.length; r++) out.push({ kind: "menu", entry: rows[r] })
    }
    return out
  }

  // The run of activatable rows that follows a section's header. Rows are
  // flat in sectionRows, so a section's tiles are the entries between its
  // header and the next header.
  function sectionRowsFor(headerIndex) {
    var out = []
    for (var i = headerIndex + 1; i < root.sectionRows.length; i++) {
      if (root.sectionRows[i].kind === "header") break
      out.push(root.sectionRows[i])
    }
    return out
  }

  function open(payloadJson) {
    // The host may summon a specific section, as the first-party menu does.
    // Ignoring the argument meant `shell summon vishnawat.macmenu
    // '{"initialMenu":"system"}'` silently landed at the top.
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.filterText = ""
    root.selectedIndex = 0
    root.rebuildApps()
    root.rebuildMenu()

    // Packages from the first install may only have just placed their icons;
    // ask the shared library to resweep so they appear on first open.
    if (root.appLibrary) root.appLibrary.refreshIcons()

    root.opened = true

    var initial = payload.initialMenu || payload.menu
    if (initial && initial !== "home" && initial !== "root" && initial !== "apps") {
      // The section has to be laid out before it can be scrolled to, so
      // this lands a turn after the surface is up.
      Qt.callLater(function() {
        var entry = root.itemOf(initial)
        if (entry && entry.kind === "link" && entry.target) entry = root.itemOf(entry.target)
        if (entry) root.scrollToSection(entry.id)
      })
    } else {
      Qt.callLater(function() { search.forceActiveFocus() })
    }
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    root.rebuildApps()
    return "ok"
  }

  function ping() {
    return "ok"
  }

  function debug() {
    return JSON.stringify({
      appRows: root.appRows.length,
      menuItems: root.itemOrder.length,
      sections: root.sectionItems.length,
      rows: root.sectionRows.length,
      opened: root.opened
    })
  }

  function cancel() {
    root.opened = false
    root.filterText = ""
  }

  // ------------------------------------------------------------ menu tree

  function stripJsonc(raw) {
    return String(raw || "")
      .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
      .replace(/,(\s*[}\]])/g, "$1")
  }

  function mergeInto(items, order, id, value) {
    if (!items[id]) order.push(id)
    var prior = items[id] || {}
    var merged = {}
    for (var k in prior) merged[k] = prior[k]
    for (var k2 in value) merged[k2] = value[k2]
    merged.id = id
    merged.parent = merged.parent === undefined
      ? (id.indexOf(".") >= 0 ? id.split(".").slice(0, -1).join(".") : "root")
      : merged.parent
    merged.kind = merged.action ? "action" : (merged.target ? "link" : "menu")
    merged.checked = merged.checked || ""
    merged.when = merged.when || ""
    merged.description = merged.description || ""
    merged.iconFont = merged.iconFont || ""
    merged.title = merged.title || ""
    merged.target = merged.target || ""
    merged.aliases = merged.aliases || []
    merged.provider = merged.provider || ""
    items[id] = merged
  }

  function parseMenuJsonc(raw, items, order) {
    var parsed
    try {
      parsed = JSON.parse(root.stripJsonc(raw))
    } catch (e) {
      return
    }
    if (!parsed || typeof parsed !== "object") return
    for (var id in parsed) {
      var value = parsed[id]
      if (!value || typeof value !== "object" || Array.isArray(value)) continue
      root.mergeInto(items, order, id, value)
    }
  }

  function rebuildMenu() {
    var nextItems = {}
    var nextOrder = []
    root.parseMenuJsonc(root.defaultMenuText, nextItems, nextOrder)
    root.parseMenuJsonc(root.userMenuText, nextItems, nextOrder)
    nextItems["root"] = { id: "root", parent: "", kind: "menu", label: "Go" }
    nextOrder.unshift("root")
    for (var i = 0; i < nextOrder.length; i++) nextItems[nextOrder[i]].order = i
    root.items = nextItems
    root.itemOrder = nextOrder
  }

  function itemOf(id) {
    return root.items[id] || null
  }

  function hasVisibleChildren(id, guard) {
    if ((guard || 0) >= 16) return false
    for (var i = 0; i < root.itemOrder.length; i++) {
      var child = root.items[root.itemOrder[i]]
      if (!child || child.parent !== id) continue
      if (root.whenResults[child.id] === false) continue
      if (child.action || child.target || child.provider) return true
      if (root.hasVisibleChildren(child.id, (guard || 0) + 1)) return true
    }
    return false
  }

  function rowVisible(entry) {
    if (!entry) return false
    if (root.whenResults[entry.id] === false) return false
    if (entry.action || entry.target || entry.provider) return true
    return root.hasVisibleChildren(entry.id, 0)
  }

  function childrenOf(id) {
    var rows = []
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.items[root.itemOrder[i]]
      if (!entry || entry.parent !== id || entry.id === "root") continue
      if (!root.rowVisible(entry)) continue
      rows.push(entry)
    }
    return rows
  }

  // ------------------------------------------------------------ activation

  function runCommand(command) {
    var value = String(command || "")
    if (!value.length) return
    root.cancel()
    Util.execDetached(value)
  }

  // A leaf action runs; a submenu scrolls the single page to its section; a
  // link drills into its target; a provider page is not enumerated natively
  // and falls back to the classic menu.
  function activateRow(entry) {
    if (!entry) return
    var id = entry.kind === "link" && entry.target ? entry.target : entry.id
    var resolved = root.itemOf(id) || entry
    if (resolved.action) {
      root.runCommand(resolved.action)
      return
    }
    if (resolved.provider && resolved.provider !== "apps" && !(resolved.action || resolved.target)) {
      root.runCommand("omarchy-menu toggle " + root.bashQuote(resolved.id))
      return
    }
    root.scrollToSection(resolved.id)
  }

  function bashQuote(value) {
    var text = String(value || "")
    return "'" + text.replace(/'/g, "'\\''") + "'"
  }

  // ------------------------------------------------------------ guards

  // One bash run answers every `when:`/`checked:` in both menu files; rows
  // render with the previous answers and update when the run lands.
  //
  // The script comes from the shared MenuModel, which is byte-identical to
  // the first-party menu's copy. The version this replaces built its own:
  // that forked `pacman -Q` once per argument per guard and re-ran every
  // `$(omarchy-default-browser)`-style reader serially inside each guard it
  // appeared in. The shared engine answers package presence from one
  // captured set and substitutes those readers eagerly, once per batch.
  //
  // A guard run that starts before the menu changes would publish answers
  // for the old tree; defer that run rather than lose it.
  property bool guardsPending: false

  function evaluateGuards() {
    if (guardScan.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = root.guardScriptText
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    guardScan.collected = ""
    guardScan.command = ["bash", "-lc", script]
    guardScan.running = true
  }
  readonly property string guardScriptText: MenuModel.guardScript(root.items)

  property string defaultMenuRaw: ""
  property string userMenuRaw: ""
  property string defaultMenuText: ""
  property string userMenuText: ""

  FileView {
    id: defaultMenuFile
    path: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.defaultMenuRaw = text()
      root.defaultMenuText = root.defaultMenuRaw
      root.rebuildMenu()
    }
    onFileChanged: reload()
    onLoadFailed: {
      // The default tree lives under /usr/share, so a transient unit-mount
      // blip can take it away. Keep the last good copy rather than rebuild
      // a menu that has lost every built-in row.
      if (root.defaultMenuRaw.length === 0) {
        root.defaultMenuRaw = ""
        root.defaultMenuText = ""
        root.rebuildMenu()
      }
    }
  }

  FileView {
    id: userMenuFile
    path: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.userMenuRaw = text()
      root.userMenuText = root.userMenuRaw
      root.rebuildMenu()
    }
    onFileChanged: reload()
    onLoadFailed: {
      // A user file that was never there is normal, so only the first-load
      // failure clears it. One that was read and has since gone unreadable
      // keeps its last good copy.
      if (root.userMenuRaw.length === 0) {
        root.userMenuRaw = ""
        root.userMenuText = ""
        root.rebuildMenu()
      }
    }
  }

  Process {
    id: guardScan
    property string collected: ""
    command: ["bash", "-lc", ""]
    stdout: SplitParser {
      onRead: function(line) { guardScan.collected += line + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      // A batch that was killed rather than finished has only told us about
      // the rows it reached, and a row whose `when:` went unanswered reads
      // as "show". Publishing that partial set would delete rows on a
      // transient failure, which is the opposite of what a `when:` means.
      // Keep the last complete set instead.
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var lines = guardScan.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      // Run the evaluation that had to stand aside, deferred a turn so the
      // process is settled before its command is set again.
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }

  // The guard text arrives only after the menu files load, so a plain
  // `running = true` at parse time would start an empty run. Restart the
  // scan whenever either source lands or changes on disk.
  onGuardScriptTextChanged: {
    if (root.guardScriptText.length === 0) return
    guardScanTimer.restart()
  }

  Timer {
    id: guardScanTimer
    interval: 200
    onTriggered: root.evaluateGuards()
  }

  function hasCheck(entry) {
    if (!entry.checked) return false
    return root.checkedResults[entry.id] === true
  }

  function rowLabel(entry) {
    if (!entry) return ""
    var label = entry.label || entry.id
    return root.hasCheck(entry) ? label + " ✓" : label
  }

  // ------------------------------------------------------------ apps

  // The application list, icon lookup and launch all belong to the shared
  // AppLibrary the host already runs in this same process, and already
  // injects here because the manifest declares kind "menu". The version
  // this replaces was a line-for-line copy of it, which meant the shell ran
  // two hidden-entry scans and two icon-index sweeps at every startup, and
  // two more on every desktop-entry change.
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  function rebuildApps() {
    var library = root.appLibrary
    if (!library) return
    var values = library.sortedEntries("")
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry) continue
      var appId = String(entry.id || "")
      if (!appId) continue
      rows.push({
        appId: appId,
        name: String(library.entryName(entry) || appId),
        subtext: String(library.entrySubtext(entry) || ""),
        icon: String(entry.icon || ""),
        keywords: entry.keywords && typeof entry.keywords.join === "function" ? entry.keywords.join(" ").toLowerCase() : ""
      })
    }
    rows.sort(function(a, b) {
      var an = a.name.toLowerCase()
      var bn = b.name.toLowerCase()
      if (an < bn) return -1
      if (an > bn) return 1
      return 0
    })
    root.appRows = rows
  }

  function filteredApps() {
    var terms = root.filterTerms()
    var out = []
    for (var i = 0; i < root.appRows.length; i++) {
      var row = root.appRows[i]
      if (terms.length === 0) {
        out.push(row)
        continue
      }
      var haystack = (row.name + " " + row.subtext + " " + row.keywords + " " + row.appId).toLowerCase()
      if (root.matchesAll(terms, haystack)) out.push(row)
    }
    return out
  }


  // -------------------------------------------------- global grouped search

  function filterTerms() {
    return root.filterText.toLowerCase().split(/\s+/).filter(function(t) { return t.length > 0 })
  }

  function matchesAll(terms, haystack) {
    for (var t = 0; t < terms.length; t++)
      if (haystack.indexOf(terms[t]) < 0) return false
    return true
  }

  // A menu-tree ancestor chain, "Setup > Style", for one entry.
  function breadcrumbOf(id) {
    var chain = []
    var guard = 0
    var cursor = root.itemOf(id)
    while (cursor && guard++ < 16 && cursor.parent && cursor.parent !== "root") {
      var parentItem = root.itemOf(cursor.parent)
      if (!parentItem) break
      chain.unshift(parentItem.title || parentItem.label || cursor.parent)
      cursor = parentItem
    }
    return chain.join(" > ")
  }

  // Every visible menu leaf/submenu across the whole tree, each tagged with
  // the top-level folder it lives under (or "Top level" for root children).
  function globalMenuResults(terms) {
    var groups = {}
    var groupOrder = []
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.items[root.itemOrder[i]]
      if (!entry || entry.id === "root" || !entry.parent) continue
      if (root.whenResults[entry.id] === false) continue
      if (!root.rowVisible(entry)) continue
      if (terms.length > 0) {
        var haystack = (entry.label + " " + entry.title + " " + entry.description + " " + entry.id).toLowerCase()
        if (!root.matchesAll(terms, haystack)) continue
      } else {
        continue
      }
      // Tag each hit with the top-level section it lives under, so search
      // feeds the same single-page model as browsing instead of a separate
      // grouped layout. The climb is bounded: a user JSONC that declares a
      // parent cycle (A.parent="B", B.parent="A") is a valid object graph,
      // and an unbounded walk here is an infinite loop inside the
      // searchGroups binding — one search character would pin the shell at
      // 100% CPU. Every other tree walk here carries the same cap
      // (hasVisibleChildren, breadcrumbOf); this one had none.
      var sectionId = entry.parent === "root" ? entry.id : entry.parent
      if (entry.parent !== "root") {
        var ancestor = entry.parent
        var hops = 0
        while (ancestor && hops++ < 32) {
          var step = root.itemOf(ancestor)
          if (!step) break
          sectionId = step.id
          if (step.parent === "root" || !step.parent) break
          ancestor = step.parent
        }
      }
      if (groups[sectionId] === undefined) {
        groups[sectionId] = []
        groupOrder.push(sectionId)
      }
      groups[sectionId].push(entry)
    }
    var out = []
    for (var g = 0; g < groupOrder.length; g++) {
      out.push({ section: groupOrder[g], items: groups[groupOrder[g]] })
    }
    return out
  }

  // When the search text is non-empty, every page returns groups of matching
  // menu entries across all folders, in folder order.
  function filteredMenuEntries() {
    var terms = root.filterTerms()
    if (terms.length === 0) return []
    return root.globalMenuResults(terms)
  }

  function iconSource(icon) {
    // Same ladder the shared library uses, including its preference for the
    // context-limited app/device index: an unconstrained themed lookup can
    // resolve an app name like "zoom" to an action icon instead.
    if (root.appLibrary) return root.appLibrary.iconSource(icon)
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var found = root.iconIndex[value]
    if (found) return Util.fileUrl(found)
    var themed = Quickshell.iconPath(value, true)
    if (themed.length > 0) return themed
    return Quickshell.iconPath("application-x-executable", true)
  }

  function launchApp(row) {
    root.cancel()
    // The library wraps this in the same scope (app-graphical.slice) and
    // drives the launch OSD, so the icon does not vanish silently.
    if (root.appLibrary) {
      root.appLibrary.launch(String(row.appId), String(row.name))
      return
    }
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(String(row.appId) + ".desktop"))
  }

  // The dock scrolls the single page to a section rather than swapping the
  // view. "apps" is the grid at the top; "menu" is the first menu section.
  function scrollToSection(section) {
    if (root.searchMode) return
    var target = root.sectionAnchors[section]
    if (target === undefined) target = 0
    flick.contentY = Math.max(0, Math.min(target, Math.max(0, flick.contentHeight - flick.height)))
    root.selectFirstRowIn(section)
  }

  // Section top offsets, recorded by each header as it lays out, so the
  // dock can scroll to a y without re-walking the tree to measure it.
  // Rebuilt as a fresh object: an in-place write into a QML `var` property
  // is occasionally dropped, which would leave a stale anchor.
  property var sectionAnchors: ({})

  function recordSectionAnchor(section, y) {
    var next = {}
    for (var k in root.sectionAnchors) next[k] = root.sectionAnchors[k]
    next[section] = y
    root.sectionAnchors = next
  }

  function selectFirstRowIn(section) {
    var rows = root.sectionRows
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].section === section && rows[i].kind !== "header") {
        root.selectedIndex = i
        root.ensureVisible(i)
        return
      }
    }
    root.selectedIndex = -1
  }

  function activateDock(item) {
    if (item.section === "apps") {
      root.filterText = ""
      flick.contentY = 0
      root.selectFirstRowIn("apps")
      return
    }
    root.scrollToSection(item.section)
  }

  onSectionRowsChanged: {
    if (root.selectedIndex >= root.sectionRows.length)
      root.selectedIndex = root.sectionRows.length > 0 ? 0 : -1
  }

  // Activate whatever the flat row list points at.
  function launchIndex(index) {
    if (index < 0 || index >= root.sectionRows.length) return
    var row = root.sectionRows[index]
    if (!row || row.kind === "header") return
    if (row.kind === "app") launchApp(row.app)
    else activateRow(row.entry)
  }

  // How many rows a PageUp/PageDown should move: about a screenful of the
  // grid, in tiles rather than rows.
  function pageStride() {
    var perScreen = Math.max(1, Math.floor(flick.height / (tileH + Style.space(8))))
    return perScreen * 6
  }

  function firstRowIndex() {
    for (var i = 0; i < root.sectionRows.length; i++)
      if (root.sectionRows[i].kind !== "header") return i
    return -1
  }

  function lastRowIndex() {
    for (var i = root.sectionRows.length - 1; i >= 0; i--)
      if (root.sectionRows[i].kind !== "header") return i
    return -1
  }

  function moveSelection(delta) {
    // Selection walks only activatable rows, skipping headers, so the
    // keyboard does not have to arrow through section titles.
    var rows = root.sectionRows
    if (rows.length === 0) {
      root.selectedIndex = -1
      return
    }
    var next = root.selectedIndex
    for (var i = 0; i < rows.length; i++) {
      next += delta
      if (next < 0) next = rows.length - 1
      if (next >= rows.length) next = 0
      if (rows[next].kind !== "header") {
        root.selectedIndex = next
        return
      }
    }
  }

  // Scrolls the selected row into view using its real position, which the
  // tile records as it lays out. The old version computed y from a tile
  // height and a column count, which is only right for a single flat grid
  // — it scrolled the wrong distance as soon as rows came from a different
  // section.
  function ensureVisible(index) {
    var tile = flick.rowAt(index)
    if (!tile) return
    var y = flick.contentY + tile.mapToItem(flick, 0, 0).y
    var h = tile.height
    if (y < flick.contentY) flick.contentY = y
    else if (y + h > flick.contentY + flick.height) flick.contentY = y + h - flick.height
  }

  // One listener on the shared library's change signal, which the host
  // fires after a single rescan. The plugin previously subscribed to
  // DesktopEntries.applications directly *as well as* running its own copy
  // of the scan, so every desktop-entry change rebuilt the list twice and
  // started two extra processes.
  Connections {
    target: root.appLibrary
    function onAppsChanged() { root.rebuildApps() }
  }

  Component.onCompleted: root.rebuildApps()

  PanelWindow {
    id: panel
    // Stay mapped for the length of the close animation instead of
    // disappearing the instant `opened` flips, which is what made the
    // previous build feel like a hard cut.
    visible: root.opened || card.opacity > 0.01
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-macmenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The scrim fades with the card so the surface does not snap on.
    Rectangle {
      id: scrim
      anchors.fill: parent
      color: Color.menu.scrim
      opacity: root.opened ? 1 : 0
      Behavior on opacity {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      // 20% under the previous 1000x720 cap: the grid fits the same number
      // of columns at a smaller tile, so the card reads denser and stops
      // filling the screen the way it did.
      width: Math.min(panel.width - Style.space(80), Style.space(800))
      height: Math.min(panel.height - Style.space(80), Style.space(576))
      radius: root.appleRadius
      color: Color.menu.background
      // The shared surface spec, so the card's edge picks up the theme's
      // border geometry instead of a flat 1px stroke that does not match.
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      anchors.centerIn: parent

      // Open/close: a short scale-and-fade, fast enough to feel immediate
      // and settle before the user starts aiming at a tile.
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.94
      transformOrigin: Item.Center
      Behavior on opacity {
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: search.forceActiveFocus()
      }

      Rectangle {
        id: searchField
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: Style.space(20) }
        height: Style.space(40)
        radius: height / 2
        color: Color.menu.background
        border.color: Color.menu.border
        border.width: 1
        opacity: 0.98

        Text {
          id: searchIcon
          text: "󰍉"
          color: Color.menu.text
          opacity: 0.55
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          anchors.left: search.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Search apps and menu"
          color: Color.menu.text
          opacity: 0.4
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          visible: root.filterText.length === 0
        }

        TextInput {
          id: search
          text: root.filterText
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: searchIcon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(16)
          selectByMouse: true
          clip: true

          onTextChanged: root.filterText = text

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              // First Escape clears a search, second closes. There is no
              // page to go back to any more: the whole menu is one surface.
              if (root.filterText.length > 0) {
                root.filterText = ""
              } else {
                root.cancel()
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.launchIndex(root.selectedIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              root.moveSelection(1)
              root.ensureVisible(root.selectedIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              root.moveSelection(-1)
              root.ensureVisible(root.selectedIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_PageDown) {
              root.moveSelection(root.pageStride())
              root.ensureVisible(root.selectedIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_PageUp) {
              root.moveSelection(-root.pageStride())
              root.ensureVisible(root.selectedIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Home) {
              root.selectedIndex = root.firstRowIndex()
              root.ensureVisible(root.selectedIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_End) {
              root.selectedIndex = root.lastRowIndex()
              root.ensureVisible(root.selectedIndex)
              event.accepted = true
            }
          }
        }
      }

      // One scrolling surface. The dock scrolls to a section instead of
      // swapping the view, so the whole menu lives in a single column:
      // the app grid first, then one headed grid per top-level folder.
      Flickable {
        id: flick
        anchors {
          left: parent.left
          right: parent.right
          leftMargin: Style.space(20)
          rightMargin: Style.space(20)
          top: searchField.bottom
          topMargin: Style.space(14)
          bottom: divider.top
          bottomMargin: Style.space(14)
        }
        clip: true
        contentWidth: width
        contentHeight: sectionColumn.height
        boundsBehavior: Flickable.StopAtBounds

        // ensureVisible() needs the tile behind a flat row index. Collecting
        // them as the grids lay out avoids assuming a single grid's geometry.
        property var collectedTiles: ({})

        function rowAt(index) {
          return collectedTiles[index] !== undefined ? collectedTiles[index] : null
        }

        Text {
          anchors.centerIn: parent
          visible: root.sectionRows.length === 0
          text: root.searchMode ? "No matches" : "No apps"
          color: Color.menu.text
          opacity: 0.55
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
        }

        Column {
          id: sectionColumn
          width: parent.width
          spacing: Style.space(18)

          Repeater {
            model: root.sectionRows

            // Headers and tiles share one flat index space with the
            // keyboard, so a row's own index is what selection compares
            // against. Headers are not activatable and moveSelection()
            // skips them.
            Loader {
              id: sectionRow
              required property int index
              required property var modelData

              readonly property bool isHeader: modelData.kind === "header"
              width: sectionColumn.width
              sourceComponent: isHeader ? headerComponent : tileComponent

              Component {
                id: headerComponent

                Item {
                  width: sectionColumn.width
                  height: Style.space(30)

                  Text {
                    id: headerText
                    text: sectionRow.modelData.title
                    color: Color.menu.text
                    opacity: 0.55
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.bodySmall
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.1
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                  }

                  Rectangle {
                    anchors {
                      left: headerText.right
                      right: parent.right
                      leftMargin: Style.space(12)
                      verticalCenter: headerText.verticalCenter
                    }
                    height: 1
                    color: Color.menu.border
                    opacity: 0.5
                  }

                  // The dock reads these to scroll to a section and to put
                  // the selection on its first row.
                  Component.onCompleted: Qt.callLater(function() {
                    root.recordSectionAnchor(sectionRow.modelData.section, sectionRow.mapToItem(flick, 0, 0).y)
                  })
                }
              }

              Component {
                id: tileComponent

                Grid {
                  id: sectionGrid
                  width: sectionColumn.width
                  columns: Math.max(3, Math.floor(width / root.tileW))
                  spacing: Style.space(8)

                  // Record this tile under its flat row index so the
                  // keyboard can scroll to the real position rather than
                  // recomputing one from a tile height and a column count.
                  Component.onCompleted: Qt.callLater(function() {
                    var next = {}
                    for (var k in flick.collectedTiles) next[k] = flick.collectedTiles[k]
                    next[sectionRow.index] = sectionGrid
                    flick.collectedTiles = next
                  })

                  Repeater {
                    model: root.sectionRowsFor(sectionRow.index)

                    Item {
                      id: tile
                      required property int index
                      required property var modelData

                      readonly property int flatIndex: sectionRow.index + 1 + index
                      readonly property var menuEntry: tile.modelData.kind === "menu" ? tile.modelData.entry : null
                      readonly property bool inMenu: menuEntry !== null
                      readonly property bool selected: flatIndex === root.selectedIndex

                      width: root.tileW
                      height: root.tileH

                      // Staggered entrance, in reading order, capped at
                      // ~150ms total so a long grid does not visibly take
                      // longer to settle than a short one. Runs whenever the
                      // card opens, which is when the grids are rebuilt.
                      opacity: root.opened ? 1 : 0
                      transformOrigin: Item.Center
                      readonly property int staggerIndex: Math.min(index, 11)
                      scale: root.opened ? 1 : 0.86
                      Behavior on opacity {
                        NumberAnimation {
                          duration: 130
                          delay: root.opened ? 30 + tile.staggerIndex * 9 : 0
                          easing.type: Easing.OutCubic
                        }
                      }
                      Behavior on scale {
                        NumberAnimation {
                          duration: 160
                          delay: root.opened ? 30 + tile.staggerIndex * 9 : 0
                          easing.type: Easing.OutCubic
                        }
                      }

                      Rectangle {
                        anchors.fill: parent
                        radius: root.appleRadius
                        color: tileMouse.containsMouse || tile.selected ? Color.menu.selectedBackground : "transparent"
                        border.color: tile.selected ? Color.menu.selectedText : "transparent"
                        border.width: tile.selected ? 2 : 0
                        Behavior on color { ColorAnimation { duration: 90 } }
                      }

                      MouseArea {
                        id: tileMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.launchIndex(tile.flatIndex)
                      }

                      Image {
                        visible: !tile.inMenu
                        width: Style.space(52)
                        height: Style.space(52)
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: width * Screen.devicePixelRatio
                        sourceSize.height: height * Screen.devicePixelRatio
                        source: root.iconSource(tile.modelData.app.icon)
                        asynchronous: true
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: Style.space(12)
                      }

                      Text {
                        id: glyphText
                        visible: tile.inMenu
                        text: tile.menuEntry.icon || "󰃜"
                        color: tile.selected ? Color.menu.selectedText : Color.menu.text
                        font.family: tile.inMenu && tile.menuEntry.iconFont.length > 0 ? tile.menuEntry.iconFont : Style.font.menuFamily
                        font.pixelSize: Style.font.iconLarge
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: Style.space(14)
                      }

                      Text {
                        text: tile.inMenu ? root.rowLabel(tile.menuEntry) : tile.modelData.app.name
                        width: tile.width - Style.space(8)
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WordWrap
                        color: tile.selected ? Color.menu.selectedText : Color.menu.text
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.bodySmall
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: tile.inMenu ? glyphText.bottom : parent.top
                        anchors.topMargin: tile.inMenu ? Style.space(6) : Style.space(70)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }


      Rectangle {
        id: divider
        anchors {
          left: parent.left
          right: parent.right
          leftMargin: Style.space(20)
          rightMargin: Style.space(20)
          bottom: dockRow.top
          bottomMargin: Style.space(12)
        }
        height: 1
        color: Color.menu.border
        opacity: 0.35
      }

      Row {
        id: dockRow
        anchors {
          left: parent.left
          right: parent.right
          bottom: parent.bottom
          leftMargin: Style.space(20)
          rightMargin: Style.space(20)
          bottomMargin: Style.space(14)
        }
        height: Style.space(58)
        spacing: Style.space(6)

        Repeater {
          model: root.dockItems

          Item {
            id: dockItem
            required property int index
            required property var modelData

            width: (dockRow.width - Style.space(6) * (root.dockItems.length - 1)) / root.dockItems.length
            height: dockRow.height

            Rectangle {
              anchors.fill: parent
              radius: 12
              color: dockMouse.containsMouse ? Color.menu.selectedBackground : "transparent"
              Behavior on color { ColorAnimation { duration: 80 } }
            }

            MouseArea {
              id: dockMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.activateDock(dockItem.modelData)
            }

            Column {
              anchors.centerIn: parent
              spacing: 2

              Text {
                text: dockItem.modelData.icon
                anchors.horizontalCenter: parent.horizontalCenter
                color: Color.menu.text
                font.family: (dockItem.modelData.iconFont || "").length > 0 ? dockItem.modelData.iconFont : Style.font.menuFamily
                font.pixelSize: Style.font.iconLarge
              }

              Text {
                text: dockItem.modelData.label
                anchors.horizontalCenter: parent.horizontalCenter
                color: Color.menu.text
                opacity: 0.75
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }
}
