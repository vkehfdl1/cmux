# Memory Leak Fixes — Manual QA Checklist

**Branches under verification:**
- `fix-mem-leaks-p1` (PR1, 7 commits, mechanical bug fixes)
- `fix-mem-leaks-p1-debug-windows` (PR1.7 follow-up, 17 debug window controllers)
- `fix-mem-leaks-p2` (PR2, Workspace + BrowserPanel teardown, **feature-flagged OFF by default**)

**Build command:** `CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag <branch-slug>`

---

## Pre-QA setup

1. Quit any running `cmux DEV.app` instances.
2. Build the branch under test with `reload.sh --tag <branch>`.
3. Cmd-click the printed `App path:` to launch (the build script does NOT launch automatically).
4. Open Activity Monitor → Memory tab. Filter on `cmux DEV`.
5. Open Console.app → filter on `cmuxDebugLog` for debug events.

---

## PR1 — Mechanical bug fixes (`fix-mem-leaks-p1`)

### QA-1.1: CFRunLoopObserver lifecycle (commit 3dc0b1a2)
**What changed:** `CmuxMainRunLoopStallMonitor` and `CmuxMainThreadTurnProfiler` now release their CFRunLoopObservers in `deinit`.

**How to verify:** These are app-singletons; deinit will not fire in practice. The win is correctness, not a measurable leak. **Pass criteria:** App launches normally; no new runtime errors. No need for memory measurement.

### QA-1.2: Socket client handler cleanup (commit 6b1f8fa0)
**What changed:** `clientHandlers` dict replaced with lock-protected `Set<Int32>` that adds on spawn, removes on connection close.

**How to verify:**
1. Open 1 workspace.
2. In a terminal pane, run: `for i in {1..20}; do cmux notify "test $i" & done; wait`
3. Wait 3 seconds for connections to drain.
4. Add this debug breakpoint or temporary log in `TerminalController.spawnClientHandler` end of defer block:
   ```swift
   #if DEBUG
   cmuxDebugLog("clientHandlerSockets.count=\(self.clientHandlerSockets.count)")
   #endif
   ```
   (Not committed by default — wire only if doubt arises.)

**Pass criteria:** No crash. `cmux notify` commands succeed. Set returns to size 0 after connections close.

### QA-1.3: Notification array cap + cooldown eviction (commit 7e86ba66)
**What changed:** `notifications` capped at 1000 entries; cooldown dicts pruned every 60s for entries > 10min old.

**How to verify:**
1. Run the included unit test on CI: `TerminalNotificationStoreMemoryCapTests`.
2. Manual stress: open 1 workspace, run `for i in {1..2000}; do cmux notify "spam-$i"; done` (will take a minute).
3. Open notifications panel (⌘I).

**Pass criteria:** Notification list shows at most 1000 entries (newest). Workspace stays responsive. No memory unbounded growth in Activity Monitor.

### QA-1.4: Workspace.deinit layout observers (commit 4240a960)
**What changed:** `Workspace.deinit` defensively unregisters `layoutFollowUpObservers`.

**How to verify:**
1. Note baseline `cmux DEV` Memory in Activity Monitor.
2. Create 10 workspaces in rapid succession (⌘N × 10).
3. Close all 10 (⌘⇧W × 10).
4. Wait 5 seconds for cleanup.
5. Note Memory again.

**Pass criteria:** Memory returns close to baseline. No "zombie" workspaces in Window menu.

### QA-1.5: TabManager.lastFocusedPanelByTab cleanup (commit 946f452d)
**What changed:** `closeWorkspace()` now removes the closed workspace from `lastFocusedPanelByTab`.

**How to verify:** Same as QA-1.4 — both cleanups happen on workspace close.

### QA-1.6: WeakScriptMessageHandler proxy (commit 850720fb)
**What changed:** ReactGrab and MarkdownWebRenderer script message handlers now wrapped in weak proxy so WKUserContentController cannot keep them alive past WKWebView teardown.

**How to verify:**
1. Open a workspace with a browser pane (⌘⇧L).
2. Navigate to a markdown file or trigger React Grab (depends on workspace setup).
3. Close the browser pane.
4. Activity Monitor: WebContent process count should decrease.

**Pass criteria:** Browser pane closes cleanly. No console error about message handler. Reopening browser pane works.

### QA-1.7: FeedPreviewWindowController content release (commit 075e8baa)
**What changed:** Debug → Debug Windows → Feed Preview now releases SwiftUI content on window close.

**How to verify:**
1. Debug menu → Debug Windows → Feed Preview… (opens window).
2. Click "Inject all into Feed" button (loads ~30 SwiftUI cards).
3. Close the Feed Preview window.
4. Reopen via Debug menu.
5. Memory delta in Activity Monitor: opening + closing should NOT accumulate.

**Pass criteria:** Window reopens with fresh content (no stale state). Memory does not climb on repeated open/close cycles.

---

## PR1.7 follow-up — 17 debug window controllers (`fix-mem-leaks-p1-debug-windows`)

**What changed:** Same FeedPreviewWindowController pattern applied to 17 additional debug window controllers.

**How to verify:**
For EACH of the following debug windows (Debug menu → Debug Windows → …), open + close 5 times. Memory should NOT climb.

| Debug Window | File |
|---|---|
| About Titlebar Debug | cmuxApp.swift:1440 |
| Debug Window Controls | cmuxApp.swift |
| Browser Import Hint Debug | cmuxApp.swift |
| Browser Profile Popover Debug | cmuxApp.swift |
| About cmux | cmuxApp.swift (not a debug window) |
| Acknowledgments | cmuxApp.swift (not a debug window) |
| File Explorer Style Debug | cmuxApp.swift |
| Sidebar Debug | cmuxApp.swift |
| Menu Bar Extra Debug | cmuxApp.swift |
| Split Button Layout Debug | cmuxApp.swift |
| Tab Bar Backdrop Lab | cmuxApp.swift |
| Background Debug | cmuxApp.swift |
| Startup Appearance Debug | cmuxApp.swift |
| Task Manager | ⌘⌥⎋ |
| Bonsplit Tab Bar Debug | BonsplitTabBarDebug.swift |
| Feed Button Style Debug | FeedButtonStyleDebugWindowController.swift |
| PDF Preview Chrome Debug | PDFPreviewChromeDebugWindowController.swift |

**Pass criteria for each:** Window opens fresh after close, no SwiftUI binding errors in Console, Memory does not climb across 5 cycles.

---

## PR2 — Workspace + BrowserPanel teardown (`fix-mem-leaks-p2`)

⚠️ **PR2 ships with `Workspace.aggressiveCleanupOnTeardown` feature flag DEFAULT OFF.** With the flag off, behavior should be identical to main. You must explicitly enable the flag to test the new cleanup path.

### Enable the flag

In `~/.config/cmux/cmux.json`:
```json
{
  "experimental": {
    "aggressiveCleanupOnTeardown": true
  }
}
```

Restart cmux to pick up the flag.

### QA-2.1: Workspace state dict cleanup (with flag ON)

**How to verify:**
1. With flag ON, note baseline memory.
2. Create 10 workspaces, each with 3 panes (split right twice per workspace).
3. Wait for each to settle (agents started, status entries populated).
4. Close all 10 workspaces.
5. Wait 10 seconds for SwiftUI debounce + cleanup.
6. Memory delta.

**Pass criteria:** Memory delta significantly lower than the same test without the flag. No SwiftUI body-recompute crashes. No "ghost" status entries in any UI.

**Regression test:** Run all existing unit tests in cmuxTests/ via CI. None should fail. Specifically: `WorkspaceManualUnreadTests`, `TabManagerUnitTests`, `WorkspaceCloseTabsContextMenuTests`.

### QA-2.2: BrowserPanel WKWebView full teardown

**How to verify:**
1. Open a workspace.
2. Open browser pane (⌘⇧L). Navigate to a heavy site (e.g. https://github.com).
3. Activity Monitor: note `com.apple.WebKit.WebContent` process count.
4. Close the browser pane.
5. Wait 5 seconds.
6. WebContent count should DECREASE by 1.

**Pass criteria:** WebContent process count returns to baseline. No leftover script message handler errors in Console.

### QA-2.3: Workspace lifecycle test (automated)

Run on CI: `WorkspaceMemoryLeakTests.testWorkspaceCloseReleasesAllState`.

This uses `weak var weakWs: Workspace?` and asserts `XCTAssertNil(weakWs)` after teardown.

**Pass criteria:** Test passes on CI.

---

## Comprehensive end-to-end memory test

**Reproduces the original user report:** "RAM growing unbounded with 10+ workspaces × browsers + opencode + Ghostty terminals on 64GB."

### Setup
1. Build `fix-mem-leaks-p2` with feature flag ON.
2. Quit any prior cmux instances.
3. Activity Monitor open, Memory tab, filtering `cmux DEV`.

### Steps (record memory at each step)
| Step | Action | Expected memory delta |
|---|---|---|
| 0 | Launch fresh cmux | ~200-300MB baseline |
| 1 | Open 10 workspaces | +50MB per workspace ≈ +500MB |
| 2 | Add 1 browser pane to each (10 total) | +100MB per WebContent ≈ +1GB |
| 3 | Start opencode in each terminal (10 total) | +30MB per opencode ≈ +300MB |
| 4 | Let agents idle 5 minutes | Should NOT grow |
| 5 | Close all 10 workspaces | Should drop back near baseline (<500MB) |
| 6 | Wait 30s for SwiftUI debounce | Stable |
| 7 | Repeat steps 1-6 three times | Memory should NOT trend upward across iterations |

### Pass criteria (overall)
- Step 4: no unbounded growth during idle (was: continuous growth pre-fix)
- Step 5: memory drops back to <500MB above baseline (was: stayed elevated pre-fix)
- Step 7: no upward trend across iterations (was: each iteration added baseline pre-fix)

---

## What to do if QA fails

For each failing QA item:
1. Capture `cmuxDebugLog` output from `/tmp/cmux-debug-fix-mem-leaks-*.log`.
2. Note exact step that failed + observed vs expected memory.
3. Open issue on PR with reproduction steps.
4. Revert the specific commit, NOT the whole PR (commits are atomic by design).

## Notes on test infrastructure

Per AGENTS.md: "Never run tests locally" — unit tests run on CI via `gh workflow run test-e2e.yml`. The unit tests added in PR1/PR2 will execute there. The MANUAL QA above is what you do yourself, on your own machine, with your own workflow patterns.
