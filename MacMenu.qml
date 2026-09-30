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
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property var desktopHiddenIds: ({})
  property var defaultHiddenIds: ({})
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
    root.filterText = ""
    root.activePage = ""
    root.navStack = []
    root.rebuildApps()
    root.rebuildMenu()
    if (!iconIndexScan.running && Object.keys(root.iconIndex).length === 0) iconIndexScan.running = true
    root.opened = true
    Qt.callLater(function() { search.forceActiveFocus() })
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    root.rebuildApps()
    root.rebuildMenu()
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
  readonly property string guardScriptText: {
    var helpers =
      'omarchy-pkg-present() { local p; for p in "$@"; do pacman -Q "$p" &>/dev/null || return 1; done; return 0; }\n' +
      'omarchy-pkg-missing() { local p; for p in "$@"; do pacman -Q "$p" &>/dev/null && return 1; done; return 0; }\n' +
      'omarchy-cmd-present() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 1; done; return 0; }\n' +
      'omarchy-cmd-missing() { local c; for c in "$@"; do command -v "$c" &>/dev/null && return 1; done; return 0; }\n'
    var guards = ""
    var sources = [root.defaultMenuRaw, root.userMenuRaw]
    for (var s = 0; s < sources.length; s++) {
      var parsed
      try {
        parsed = JSON.parse(root.stripJsonc(sources[s]))
      } catch (e) {
        parsed = null
      }
      if (!parsed || typeof parsed !== "object") continue
      for (var id in parsed) {
        var value = parsed[id]
        if (!value || typeof value !== "object" || Array.isArray(value)) continue
        if (value.when) guards += "if { " + value.when + "; } >/dev/null 2>&1; then echo " + id + ":w:1; else echo " + id + ":w:0; fi\n"
        if (value.checked) guards += "if { " + value.checked + "; } >/dev/null 2>&1; then echo " + id + ":c:1; else echo " + id + ":c:0; fi\n"
      }
    }
    return guards.length > 0 ? helpers + guards : ""
  }

  property string defaultMenuRaw: ""
  property string userMenuRaw: ""
  property string defaultMenuText: ""
  property string userMenuText: ""

  FileView {
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
      root.defaultMenuRaw = ""
      root.defaultMenuText = ""
      root.rebuildMenu()
    }
  }

  FileView {
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
      root.userMenuRaw = ""
      root.userMenuText = ""
      root.rebuildMenu()
    }
  }

  Process {
    id: guardScan
    property var splitWhen: ({})
    property var splitChecked: ({})
    command: ["bash", "-lc", root.guardScriptText]
    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text.length === 0) return
        var idEnd = text.indexOf(":")
        var tagEnd = text.indexOf(":", idEnd + 1)
        if (idEnd < 0 || tagEnd < 0) return
        var id = text.slice(0, idEnd)
        var tag = text.slice(idEnd + 1, tagEnd)
        var value = text.slice(tagEnd + 1) === "1"
        if (tag === "w") guardScan.splitWhen[id] = value
        else guardScan.splitChecked[id] = value
      }
    }
    onExited: {
      root.whenResults = splitWhen
      root.checkedResults = splitChecked
    }
    onStarted: {
      splitWhen = ({})
      splitChecked = ({})
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
    interval: 100
    onTriggered: guardScan.running = true
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

  function loadHides(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = String(lines[i] || "").trim()
      if (id.length === 0) continue
      if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
      next[id] = true
    }
    return next
  }

  function rebuildApps() {
    var values = typeof DesktopEntries !== "undefined" && DesktopEntries.applications ? (DesktopEntries.applications.values || []) : []
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry || entry.noDisplay) continue
      var appId = String(entry.id || "")
      if (!appId) continue
      if (root.desktopHiddenIds[appId] === true || root.defaultHiddenIds[appId] === true) continue
      rows.push({
        appId: appId,
        name: String(entry.name || appId),
        subtext: String(entry.genericName || ""),
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
        var ancestor = entry.parent
        while (ancestor && root.itemOf(ancestor) && root.itemOf(ancestor).parent !== "root" && root.itemOf(ancestor).parent) {
          ancestor = root.itemOf(ancestor).parent
        }
        var top = root.itemOf(ancestor)
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

  function hiddenEntryScanCommand() {
    var desktop = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"), Quickshell.env("DESKTOP_SESSION")].filter(function(v) { return String(v || "").length > 0 }).join(":")
    return Util.shellQuote(omarchyPath + "/shell/services/hidden-entries.sh") + " " + Util.shellQuote(desktop)
  }

  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root.pendingIconIndex[name] === undefined)
      root.pendingIconIndex[name] = value
  }

  Component.onCompleted: {
    hiddenEntryScan.running = true
    iconIndexScan.running = true
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      hiddenEntryScan.running = true
      iconIndexDebounce.restart()
      root.rebuildApps()
    }
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.defaultHiddenIds = root.loadHides(text())
      root.rebuildApps()
    }
    onFileChanged: reload()
    onLoadFailed: {
      root.defaultHiddenIds = ({})
      root.rebuildApps()
    }
  }

  QtObject {
    id: hiddenEntryOutput
    property string text: ""
  }

  Process {
    id: hiddenEntryScan
    command: ["bash", "-c", root.hiddenEntryScanCommand()]
    stdout: SplitParser {
      onRead: function(line) { hiddenEntryOutput.text += line + "\n" }
    }
    onStarted: hiddenEntryOutput.text = ""
    onExited: {
      root.desktopHiddenIds = root.loadHides(hiddenEntryOutput.text)
      root.rebuildApps()
    }
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser {
      onRead: function(line) { root.indexIconLine(line) }
    }
    onStarted: root.pendingIconIndex = ({})
    onExited: root.iconIndex = root.pendingIconIndex
  }

  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: if (!iconIndexScan.running) iconIndexScan.running = true
  }

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
