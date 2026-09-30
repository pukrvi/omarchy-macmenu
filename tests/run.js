#!/usr/bin/env node
// Model tests for MacMenu.qml.
//
// The QML property bindings in this plugin are plain JavaScript, so the
// interesting logic — the menu tree walk, the guard grouping, the flat row
// model — can be exercised without a running Quickshell or a display. That
// matters for the cycle test below: a regression there does not fail a
// build, it hangs the user's shell.
//
// Run: node tests/run.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const QML = path.join(__dirname, "..", "MacMenu.qml");
const source = fs.readFileSync(QML, "utf8");

// Pull a top-level `function name(...) { ... }` out of the QML, braces and
// all, so it can be bound to a stub `root` the way QML would bind it.
function grab(name) {
  const match = new RegExp("^  function " + name + "\\([^)]*\\) \\{", "m").exec(source);
  if (!match) throw new Error("MacMenu.qml has no function " + name);
  const start = match.index + match[0].length;
  let depth = 1;
  let i = start;
  while (depth > 0) {
    const c = source[i];
    if (c === "{") depth++;
    else if (c === "}") depth--;
    i++;
  }
  return source.slice(start, i - 1);
}

// A stub root with the members the extracted functions touch. `with(root)`
// makes the body's bare `items` / `whenResults` / helper calls resolve
// against it, matching how QML scopes an Item's members.
function makeRoot(overrides = {}) {
  const root = Object.assign({
    items: {},
    itemOrder: [],
    whenResults: {},
    checkedResults: {},
    appRows: [],
    filterText: "",
    iconIndex: {},
  }, overrides);

  root.itemOf = overrides.itemOf || function (id) { return this.items[id] || null; };
  root.rowVisible = overrides.rowVisible || function () { return true; };
  root.filterTerms = overrides.filterTerms || function () { return []; };
  root.matchesAll = overrides.matchesAll || function (terms, hay) {
    for (const t of terms) if (hay.indexOf(t) < 0) return false;
    return true;
  };
  return root;
}

function signature(name) {
  const match = new RegExp("^  function " + name + "\\(([^)]*)\\) \\{", "m").exec(source);
  if (!match) throw new Error("MacMenu.qml has no function " + name);
  return match[1];
}

// Compile the extracted body so its bare references to items / whenResults /
// sibling helpers resolve against `root` the way QML resolves an Item's own
// members. `with` is avoided: it would shadow the function's own parameters.
function bind(root, name) {
  const params = signature(name).split(",").map((p) => p.trim()).filter(Boolean);
  const body = grab(name);
  const factory = new vm.Script(
    "(function (root, args) {\n" +
    "  return function (" + params.join(", ") + ") {\n" +
    "    var items = root.items, itemOrder = root.itemOrder;\n" +
    "    var whenResults = root.whenResults, checkedResults = root.checkedResults;\n" +
    "    var appRows = root.appRows, filterText = root.filterText, iconIndex = root.iconIndex;\n" +
    "    var itemOf = root.itemOf, rowVisible = root.rowVisible;\n" +
    "    var filterTerms = root.filterTerms, matchesAll = root.matchesAll;\n" +
    "    var hasVisibleChildren = root.hasVisibleChildren, childrenOf = root.childrenOf;\n" +
    "    var filteredApps = root.filteredApps, sectionItems = root.sectionItems;\n" +
    "    var searchGroups = root.searchGroups, sectionRowsFor = root.sectionRowsFor;\n" +
    body + "\n  };\n})"
  );
  root[name] = factory.runInNewContext({})(root, null);
  return root[name];
}

let passed = 0;
let failed = 0;

function check(label, fn) {
  try {
    fn();
    passed++;
    console.log("  ok   " + label);
  } catch (e) {
    failed++;
    console.log("  FAIL " + label + "\n         " + e.message);
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

console.log("MacMenu model tests");

// ---------------------------------------------------------------------------
// F3 regression: a parent cycle in a user menu JSONC must not hang the shell.
//
// A.parent="B" and B.parent="A" is a valid object graph, and the parse loop
// does not detect it. The ancestor walk behind search grouping used to climb
// until it ran out of parents, so a single search character pinned Quickshell
// at 100% CPU until the session was restarted. The walk is now depth-capped;
// this asserts it returns at all, and quickly.
check("search grouping terminates on a parent cycle", () => {
  const root = makeRoot({
    filterTerms: function () { return ["alpha"]; },
    items: {
      a: { id: "a", parent: "b", kind: "menu", label: "Alpha", description: "" },
      b: { id: "b", parent: "a", kind: "menu", label: "Beta", description: "alpha-ish" },
      c: { id: "c", parent: "root", kind: "action", label: "Gamma", description: "alpha", action: "true" },
    },
    itemOrder: ["a", "b", "c"],
  });
  bind(root, "globalMenuResults");

  const started = Date.now();
  const groups = root.globalMenuResults(["alpha"]);
  const elapsed = Date.now() - started;

  assert(elapsed < 1000, "took " + elapsed + "ms — the cycle guard is not bounding the walk");
  assert(groups.length === 3, "expected 3 sections, got " + groups.length);
  for (const g of groups) {
    assert(typeof g.section === "string" && g.section.length > 0,
      "group is tagged by section id, got " + JSON.stringify(g.section));
  }
});

check("search grouping skips hidden rows", () => {
  const root = makeRoot({
    filterTerms: function () { return ["x"]; },
    whenResults: { b: false },
    items: {
      a: { id: "a", parent: "root", kind: "action", label: "Xray", description: "x", action: "true" },
      b: { id: "b", parent: "root", kind: "action", label: "Xylophone", description: "x", action: "true" },
    },
    itemOrder: ["a", "b"],
  });
  bind(root, "globalMenuResults");
  const groups = root.globalMenuResults(["x"]);
  const ids = groups.flatMap((g) => g.items.map((i) => i.id));
  assert(ids.indexOf("b") === -1, "a row whose when: evaluated false must not appear");
  assert(ids.indexOf("a") !== -1, "a row with no false guard must appear");
});

check("filterTerms splits on whitespace and drops blanks", () => {
  const root = makeRoot({ filterText: "  lo fi   beats  " });
  bind(root, "filterTerms");
  const terms = root.filterTerms();
  assert(terms.length === 3, "expected 3 terms, got " + terms.length);
  assert(terms[0] === "lo" && terms[1] === "fi" && terms[2] === "beats",
    "got " + JSON.stringify(terms));
});

check("filterTerms is empty for an empty search", () => {
  const root = makeRoot({ filterText: "" });
  bind(root, "filterTerms");
  assert(root.filterTerms().length === 0, "an empty search yields no terms");
});

check("matchesAll requires every term to be present", () => {
  const root = makeRoot();
  bind(root, "matchesAll");
  assert(root.matchesAll(["lo", "fi"], "lofi beats") === true, "both terms present");
  assert(root.matchesAll(["lo", "zz"], "lofi beats") === false, "a missing term must not match");
  assert(root.matchesAll([], "anything") === true, "no terms matches everything");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
