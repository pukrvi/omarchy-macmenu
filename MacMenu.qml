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
import "MenuModel.js" as MenuModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // "" is the home grid (apps); otherwise an id of the menu tree.
  property string activePage: ""
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property var appRows: []
  property var items: ({})
  property var itemOrder: []
  // Icon index fallback, used only when the shared AppLibrary is not
  // injected (a preview harness); the library owns this in the real shell.
  property var iconIndex: ({})
  property var whenResults: ({})
  property var checkedResults: ({})
  property var navStack: []

  readonly property int appleRadius: Math.max(Style.cornerRadius, 18)
  readonly property real tileW: Style.space(112)
  readonly property real tileH: Style.space(112)

  readonly property bool homeMode: root.activePage.length === 0
  readonly property bool searchMode: root.filterText.length > 0
  readonly property string pageTitle: root.homeMode ? "" : (root.items[root.activePage] ? (root.items[root.activePage].title || root.items[root.activePage].label) : "")
  readonly property var pageRowList: root.pageRows()
  readonly property var searchGroups: root.searchMode ? root.filteredMenuEntries() : []
  // Search groups produce a flat render model: folder header + its entries.
  readonly property var searchRows: {
    var out = []
    for (var g = 0; g < root.searchGroups.length; g++) {
      out.push({ kind: "header", title: root.searchGroups[g].header })
      for (var i = 0; i < root.searchGroups[g].items.length; i++)
        out.push({ kind: "item", entry: root.searchGroups[g].items[i] })
    }
    return out
  }
  readonly property var displayRows: root.searchMode
    ? root.searchRows
    : (root.homeMode ? root.filteredApps() : root.filteredPageRows())
  readonly property bool searchVisible: true

  readonly property var dockItems: [
    { icon: "", iconFont: "omarchy", label: "Home", route: "home" },
    { icon: "󰀻", iconFont: "", label: "Apps", route: "apps" },
    { icon: "󰥱", iconFont: "", label: "Trigger", route: "trigger" },
    { icon: "", iconFont: "", label: "Setup", route: "setup" },
    { icon: "", iconFont: "", label: "Style", route: "style" },
    { icon: "󰇅", iconFont: "", label: "Learn", route: "learn" },
    { icon: "", iconFont: "", label: "System", route: "system" }
  ]

  function open(payloadJson) {
    // The host may summon a specific page, as the first-party menu does.
    // Ignoring the argument meant `shell summon vishnawat.macmenu
    // '{"initialMenu":"system"}'` silently landed on Home.
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.filterText = ""
    root.navStack = []
    root.selectedIndex = 0
    root.rebuildApps()
    root.rebuildMenu()

    // Packages from the first install may only have just placed their icons;
    // ask the shared library to resweep so they appear on first open.
    if (root.appLibrary) root.appLibrary.refreshIcons()

    var initial = payload.initialMenu || payload.menu
    root.activePage = ""
    if (initial && initial !== "home" && initial !== "root") {
      var entry = root.itemOf(initial)
      if (entry && entry.kind === "link" && entry.target) entry = root.itemOf(entry.target)
      if (entry) root.activePage = entry.id
    }

    root.opened = true
    Qt.callLater(function() { search.forceActiveFocus() })
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
      activePage: root.activePage,
      pageRows: root.pageRowList.length,
      opened: root.opened
    })
  }

  function cancel() {
    root.opened = false
    root.filterText = ""
    root.activePage = ""
    root.navStack = []
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

  function pageRows() {
    if (root.homeMode) return []
    // A link drills into its target's children; a provider page is not
    // enumerated natively and falls back to the classic menu on activate.
    var entry = root.itemOf(root.activePage)
    if (entry && entry.kind === "link" && entry.target) entry = root.itemOf(entry.target)
    if (!entry) return []
    return root.childrenOf(entry.id)
  }

  // ------------------------------------------------------------ activation

  function navPage(id, pushHistory) {
    var entry = root.itemOf(id)
    if (entry && entry.kind === "link" && entry.target) entry = root.itemOf(entry.target)
    if (!entry) return
    if (entry.provider && entry.provider !== "apps" && !(entry.action || entry.target)) {
      root.runCommand("omarchy-menu toggle " + root.bashQuote(entry.id))
      return
    }
    if (pushHistory !== false && root.activePage.length > 0) root.navStack = root.navStack.concat([root.activePage])
    root.activePage = entry ? entry.id : ""
    root.filterText = ""
    root.selectedIndex = 0
    Qt.callLater(function() { search.forceActiveFocus() })
  }

  function goHome() {
    root.activePage = ""
    root.navStack = []
    root.filterText = ""
    root.selectedIndex = 0
    Qt.callLater(function() { search.forceActiveFocus() })
  }

  function goBack() {
    if (root.homeMode) {
      root.cancel()
      return
    }
    var previous = root.navStack.length > 0 ? root.navStack[root.navStack.length - 1] : ""
    if (root.navStack.length > 0) root.navStack = root.navStack.slice(0, root.navStack.length - 1)
    root.activePage = previous
    root.filterText = ""
    root.selectedIndex = 0
    Qt.callLater(function() { search.forceActiveFocus() })
  }

  function runCommand(command) {
    var value = String(command || "")
    if (!value.length) return
    root.opened = false
    root.filterText = ""
    root.activePage = ""
    root.navStack = []
    Util.execDetached(value)
  }

  // A leaf action runs; a link drills into its target; a submenu opens as a
  // page; keeper submenus of a provider fall back to the classic menu.
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
    root.navPage(resolved.id, true)
  }

  function activateEntry(id, fallbackAction) {
    var entry = root.itemOf(id)
    if (fallbackAction && !entry) {
      root.runCommand(fallbackAction)
      return
    }
    root.activateRow(entry)
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

  function filteredPageRows() {
    var terms = root.filterTerms()
    var rows = root.pageRowList
    if (terms.length === 0) return rows
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var haystack = (row.label + " " + row.description + " " + row.id).toLowerCase()
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
      var folder = "Top level"
      if (entry.parent !== "root") {
        // Climb to the top-level ancestor, but bounded: a user JSONC that
        // declares a parent cycle (A.parent="B", B.parent="A") is a valid
        // object graph, and an unbounded walk here is an infinite loop
        // inside the searchGroups binding — one search character would pin
        // the shell at 100% CPU. Every other tree walk here carries the same
        // cap (hasVisibleChildren, breadcrumbOf); this one had none.
        var ancestor = entry.parent
        var hops = 0
        var climbed = null
        while (ancestor && hops++ < 32) {
          var step = root.itemOf(ancestor)
          if (!step) break
          climbed = step
          if (step.parent === "root" || !step.parent) break
          ancestor = step.parent
        }
        var top = climbed
        folder = top ? (top.title || top.label || ancestor) : "Top level"
      }
      if (groups[folder] === undefined) {
        groups[folder] = []
        groupOrder.push(folder)
      }
      groups[folder].push(entry)
    }
    var out = []
    for (var g = 0; g < groupOrder.length; g++) {
      out.push({ header: groupOrder[g], items: groups[groupOrder[g]] })
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

  function runDock(item) {
    if (item.route === "apps" || item.route === "home") {
      root.goHome()
      return
    }
    root.navPage(item.route, true)
  }

  onDisplayRowsChanged: {
    if (root.selectedIndex >= root.displayRows.length)
      root.selectedIndex = root.displayRows.length > 0 ? 0 : -1
  }

  function launchIndex(index) {
    if (index < 0) return
    if (root.searchMode) {
      var row = root.searchRows[index]
      if (row && row.kind === "item") root.activateRow(row.entry)
      return
    }
    if (index >= root.displayRows.length) return
    if (root.homeMode) launchApp(root.displayRows[index])
    else activateRow(root.displayRows[index])
  }

  function moveSelection(delta) {
    var count = root.displayRows.length
    if (count === 0) {
      root.selectedIndex = -1
      return
    }
    var next = root.selectedIndex + delta
    if (next < 0) next = count - 1
    if (next >= count) next = 0
    root.selectedIndex = next
  }

  function ensureVisible(index) {
    var rowHeight = tileH + Style.space(8)
    var y = Math.floor(index / itemGrid.columns) * rowHeight
    if (y < flick.contentY) flick.contentY = y
    else if (y + rowHeight > flick.contentY + flick.height) flick.contentY = y + rowHeight - flick.height
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
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-macmenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    Rectangle {
      id: card
      width: Math.min(panel.width - Style.space(40), Style.space(1000))
      height: Math.min(panel.height - Style.space(40), Style.space(720))
      radius: root.appleRadius
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: 1
      anchors.centerIn: parent

      MouseArea {
        anchors.fill: parent
        onClicked: search.forceActiveFocus()
      }

      Rectangle {
        id: searchField
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: Style.space(20) }
        height: Style.space(42)
        radius: height / 2
        color: Color.menu.selectedBackground
        visible: root.searchVisible

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
              if (root.filterText.length > 0) {
                root.filterText = ""
              } else if (root.homeMode) {
                root.cancel()
              } else {
                root.goBack()
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
            }
          }
        }
      }

      // Page header with a back button, only inside a menu page.
      Item {
        id: pageHeader
        anchors {
          top: searchField.bottom
          topMargin: root.searchVisible ? Style.space(14) : Style.space(20)
          left: parent.left
          right: parent.right
        }
        height: root.homeMode ? 0 : Style.space(40)
        visible: !root.homeMode

        Rectangle {
          id: backButton
          width: Style.space(96)
          height: parent.height
          radius: 12
          color: backMouse.containsMouse ? Color.menu.selectedBackground : "transparent"
          anchors { left: parent.left; leftMargin: Style.space(20); verticalCenter: parent.verticalCenter }

          MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.goBack()
          }

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              text: "󰁯"
              color: Color.menu.text
              opacity: 0.75
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.subtitle
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: "Back"
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        Text {
          text: root.pageTitle
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
        }
      }

      Flickable {
        id: flick
        anchors {
          left: parent.left
          right: parent.right
          leftMargin: Style.space(20)
          rightMargin: Style.space(20)
          top: root.homeMode ? searchField.bottom : pageHeader.bottom
          topMargin: Style.space(14)
          bottom: divider.top
          bottomMargin: Style.space(14)
        }
        clip: true
        contentWidth: width
        contentHeight: root.searchMode ? searchColumn.height : itemGrid.height
        boundsBehavior: Flickable.StopAtBounds

        Text {
          anchors.centerIn: parent
          visible: root.displayRows.length === 0
          text: root.searchMode
            ? "No matches"
            : root.homeMode
              ? (root.filterText.length > 0 ? "No apps match" : "Loading apps")
              : "Empty"
          color: Color.menu.text
          opacity: 0.55
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
        }

        // Search mode: all matching menu entries across every folder, each
        // folder rendered as its own headed Launchpad section.
        Column {
          id: searchColumn
          visible: root.searchMode
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.searchGroups

            Item {
              id: searchGroup
              required property int index
              required property var modelData

              width: parent.width
              height: groupTitle.height + groupGrid.height + Style.space(4)
              readonly property int columns: Math.max(3, Math.floor(width / root.tileW))

              Text {
                id: groupTitle
                text: searchGroup.modelData.header
                color: Color.menu.text
                opacity: 0.6
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                anchors { left: parent.left; top: parent.top }
              }

              Grid {
                id: groupGrid
                columns: searchGroup.columns
                spacing: Style.space(8)
                anchors { left: parent.left; right: parent.right; top: groupTitle.bottom; topMargin: Style.space(6) }

                Repeater {
                  model: searchGroup.modelData.items

                  Item {
                    id: groupTile
                    required property int index
                    required property var modelData

                    readonly property int flatIndex: {
                      var n = 0
                      for (var g = 0; g < searchGroup.index; g++) n += root.searchGroups[g].items.length + 1
                      return n + groupTile.index + 1
                    }

                    width: root.tileW
                    height: root.tileH
                    readonly property bool isSelected: root.selectedIndex === flatIndex

                    Rectangle {
                      anchors.fill: parent
                      radius: 12
                      color: groupTileMouse.containsMouse || groupTile.isSelected ? Color.menu.selectedBackground : "transparent"
                      Behavior on color { ColorAnimation { duration: 80 } }
                    }

                    MouseArea {
                      id: groupTileMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      onEntered: root.selectedIndex = groupTile.flatIndex
                      onClicked: root.activateRow(groupTile.modelData)
                    }

                    Text {
                      text: (groupTile.modelData.icon || "󰋜")
                      color: groupTile.isSelected ? Color.menu.selectedText : Color.menu.text
                      font.family: groupTile.modelData.iconFont.length > 0 ? groupTile.modelData.iconFont : Style.font.menuFamily
                      font.pixelSize: Style.font.iconLarge
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(14)
                    }

                    Text {
                      text: root.rowLabel(groupTile.modelData)
                      width: groupTile.width - Style.space(8)
                      horizontalAlignment: Text.AlignHCenter
                      elide: Text.ElideRight
                      maximumLineCount: 2
                      wrapMode: Text.WordWrap
                      color: groupTile.isSelected ? Color.menu.selectedText : Color.menu.text
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(64)
                    }
                  }
                }
              }
            }
          }
        }

        // Normal browsing: one Launchpad-style tile grid — apps and menu folders.
        Grid {
          id: itemGrid
          width: parent.width
          columns: Math.max(3, Math.floor(width / root.tileW))
          spacing: Style.space(8)

          Repeater {
            model: root.displayRows

            Item {
              id: tile
              required property int index
              required property var modelData

              readonly property var menuEntry: root.homeMode ? null : modelData
              readonly property bool inMenu: menuEntry !== null && menuEntry !== undefined
              readonly property bool isMenu: inMenu
                ? (menuEntry.kind === "menu" || menuEntry.kind === "link")
                  && !(menuEntry.provider && menuEntry.provider !== "apps")
                : false

              width: root.tileW
              height: root.tileH
              readonly property bool selected: index === root.selectedIndex

              Rectangle {
                anchors.fill: parent
                radius: 12
                color: tileMouse.containsMouse || tile.selected ? Color.menu.selectedBackground : "transparent"
                Behavior on color { ColorAnimation { duration: 80 } }
              }

              MouseArea {
                id: tileMouse
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.selectedIndex = tile.index
                onClicked: root.homeMode ? root.launchApp(tile.modelData) : root.activateRow(tile.modelData)
              }

              // Apps use desktop-entry icons; menu entries use font glyphs.
              Image {
                visible: root.homeMode
                width: Style.space(52)
                height: Style.space(52)
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: root.iconSource(tile.modelData.icon)
                asynchronous: true
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Style.space(12)
              }

              Text {
                id: iconGlyph
                text: (tile.inMenu ? (tile.menuEntry.icon || "󰋜") : "")
                visible: tile.inMenu
                color: tile.selected ? Color.menu.selectedText : Color.menu.text
                font.family: tile.inMenu && tile.menuEntry.iconFont.length > 0 ? tile.menuEntry.iconFont : Style.font.menuFamily
                font.pixelSize: Style.font.iconLarge
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Style.space(14)
              }

              Text {
                visible: root.homeMode
                text: tile.modelData.name
                width: tile.width - Style.space(8)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                color: tile.selected ? Color.menu.selectedText : Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Style.space(70)
              }

              Text {
                visible: tile.inMenu
                text: root.rowLabel(tile.menuEntry)
                width: tile.width - Style.space(8)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                color: tile.selected ? Color.menu.selectedText : Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: iconGlyph.bottom
                anchors.topMargin: Style.space(6)
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
              onClicked: root.runDock(dockItem.modelData)
            }

            Column {
              anchors.centerIn: parent
              spacing: 2

              Text {
                text: dockItem.modelData.icon
                anchors.horizontalCenter: parent.horizontalCenter
                color: Color.menu.text
                font.family: dockItem.modelData.iconFont.length > 0 ? dockItem.modelData.iconFont : Style.font.menuFamily
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
