# cmux Memory Leak Fixes - Master Plan

**Status**: Diagnosis complete. PR1 ready to start. PR2-PR5 sequenced below.

**Context**: User reports RAM growing unbounded with 10+ workspaces × browsers + opencode + Ghostty terminals, even on 64GB. Comprehensive 9-task analysis found confirmed leaks + architectural memory pressure.

**Approach (user-approved)**: Sequential PR rollout, fix true bugs first, then architectural improvements.

---

## ⚠️ User Decisions Made

- ✅ "Full diagnosis + fix all leaks + swap-to-disk if needed" (not just analysis)
- ✅ "Code analysis only" (no Instruments data)
- ✅ "Sequential PR1 → PR2 → PR3..." (not one mega-PR)

## ⚠️ Decisions PENDING (ask user when reaching that PR)

- PR4 (browser hibernation):
  - Idle threshold: 5min? 10min? Configurable?
  - Feature flag default: ON or OFF on first ship?
  - Exclude conditions: media playback, downloads, unsaved forms, dev tools open?
- PR5 (Ghostty scrollback truncation): ship it or skip? Risk: scrollback loss is user-visible.

---

## PR1 — Mechanical Bug Fixes (LOW RISK)

**Goal**: Fix 7 deterministic bugs. Each as separate commit. All should be visible memory reduction with no behavior change.

**Tag**: `fix-mem-leaks-p1`

**Commits** (one per item):

### Commit 1.1: `fix(runloop): remove CFRunLoopObserver in stall monitor/profiler`

**Files**: `Sources/AppDelegate.swift`

**Lines**: 283-322 (`CmuxMainRunLoopStallMonitor`), 369-422 (`CmuxMainThreadTurnProfiler`)

**Action**:
- Add `deinit` to both classes that calls `CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)` then `observer = nil`.
- These are app-singletons so won't fire in practice, but eliminates wrong pattern that may be copied. Mark with comment.

**QA**: Build with `./scripts/reload.sh --tag fix-mem-leaks-p1`. Verify diagnostics clean.

---

### Commit 1.2: `fix(socket): track and clean up client handler threads`

**Files**: `Sources/TerminalController.swift`

**Lines**: 61 (`clientHandlers` dict), `spawnClientHandler()` (search for it), `handleClient()` (line ~1957)

**Action**:
- In `spawnClientHandler()`: store the spawned `Thread` in `clientHandlers[clientSocket] = thread` (must be on `@MainActor` since dict is main-actor-bound, OR change dict to use lock).
- In `handleClient()` exit path (when socket closes): post back to main and `clientHandlers.removeValue(forKey: clientSocket)`.
- ALTERNATIVE if simpler: change `clientHandlers` to be just `Set<Int32>` for tracking, remove the unused `Thread` mapping entirely.

**Verify**: Open many socket connections (run several `cmux notify` etc), close them, confirm `clientHandlers` returns to empty via debug log.

**QA**: 
- `cmux-debug-cli.sh send` to bring up socket
- Open 20 socket connections, close them
- Add `#if DEBUG cmuxDebugLog("clientHandlers count=\(clientHandlers.count)")` in cleanup path
- Confirm returns to 0

---

### Commit 1.3: `fix(notifications): cap notifications array and evict old cooldown keys`

**Files**: `Sources/TerminalNotificationStore.swift`

**Lines**: 701 (`notifications`), 765 (`lastNotificationDateByCooldownKey`), 766 (`lastNotificationHookFailureDateByKey`)

**Action**:
- Add `private static let maxNotifications = 1000` (or 500).
- In setter for `notifications`, if `notifications.count > maxNotifications`, trim oldest: `notifications = Array(notifications.suffix(maxNotifications))`. CAREFUL: don't break the `didSet` invariants — wrap the cap logic in a helper that's called from the mutation site.
- For cooldown dicts: after every insert, prune entries older than `notificationHookFailureThrottle * 2` (10min). Use `Date().addingTimeInterval(-600)` as cutoff.

**Test**: Add `cmuxTests/TerminalNotificationStoreTests.swift` test that inserts 2000 notifications and asserts `.count == 1000`. Test cooldown eviction by inserting old-dated keys then triggering prune.

**QA**: Run unit test.

---

### Commit 1.4: `fix(workspace): clean up layoutFollowUpObservers in deinit`

**Files**: `Sources/Workspace.swift`

**Lines**: ~12439-12520 (setupLayoutFollowUp / clearLayoutFollowUp); deinit at line ~7905

**Action**:
- In `Workspace.deinit`, defensively call `clearLayoutFollowUp()` (which is idempotent if no observers).
- Verify `clearLayoutFollowUp()` properly removes all 7 observers via `NotificationCenter.default.removeObserver(token)` for each in `layoutFollowUpObservers`.

**QA**: Add `#if DEBUG cmuxDebugLog("workspace.deinit observerCount=\(layoutFollowUpObservers.count)")`. Open 10 workspaces, close them. Confirm log shows 0 each time.

---

### Commit 1.5: `fix(tabmanager): clean up git/PR probe state per workspace on close`

**Files**: `Sources/TabManager.swift`

**Lines**: ~1058-1065 (probe state dicts), `closeWorkspace()` method (search)

**Action**:
- In `closeWorkspace(_ workspace:)`, before removing from `tabs` array:
  - Find the `WorkspaceGitProbeKey` for this workspace ID.
  - `workspaceGitProbeStateByKey.removeValue(forKey: key)`
  - `workspaceGitProbeTimersByKey[key]?.forEach { $0.cancel() }; workspaceGitProbeTimersByKey.removeValue(forKey: key)`
  - `workspacePullRequestProbeStateByKey.removeValue(forKey: key)`
  - Note: `workspacePullRequestRepoCacheBySlug` is repo-keyed (not workspace) so keep — but consider TTL eviction in a separate commit.

**Test**: Add `cmuxTests/TabManagerMemoryLeakTests.swift`: create 10 workspaces, close all, assert all probe dicts are empty.

---

### Commit 1.6: `fix(webview): wrap script handlers with weak proxy`

**Files**: `Sources/Panels/CmuxWebView.swift`, new file `Sources/Panels/WeakScriptMessageHandler.swift`

**Action**:
- Create `WeakScriptMessageHandler` proxy class (pattern from NetNewsWire — see librarian results):
  ```swift
  final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
      private weak var delegate: WKScriptMessageHandler?
      init(delegate: WKScriptMessageHandler) { self.delegate = delegate; super.init() }
      func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
          delegate?.userContentController(c, didReceive: m)
      }
  }
  ```
- Modify call sites that `controller.add(handler, name: ...)` to wrap in `WeakScriptMessageHandler(delegate: handler)`.
- Audit ALL call sites: `CmuxWebView.swift:300-318`, `BrowserPanel.swift` (search for `userContentController.add`), `ReactGrab.swift`, `BrowserWebAuthnSupport.swift`, `MarkdownWebRenderer.swift`.

**Caveat**: For `PasteAsPlainTextFocusMessageHandler` which is intentionally a shared static singleton — leaving as-is is OK since it's app-lifetime. Document this with a comment.

---

### Commit 1.7: `fix(debug-windows): release SwiftUI content on windowWillClose`

**Files**: All debug window controllers (15+ files). Search for `isReleasedWhenClosed = false`.

**Action**: For each `static let shared` NSWindowController with `isReleasedWhenClosed = false`:
- Make the controller conform to `NSWindowDelegate` if not already.
- Set `window.delegate = self` in init.
- Implement:
  ```swift
  func windowWillClose(_ notification: Notification) {
      window?.contentViewController = nil  // releases SwiftUI tree
      // OR if using contentView:
      // window?.contentView = NSView()
  }
  ```
- On next show, lazily recreate `contentViewController = NSHostingController(rootView: ...)`.

**Files to fix** (per explore agent findings):
- `Sources/cmuxApp.swift` (15+ instances at lines 1457, 1676, 1927, 1964, 2328, 2361, 2492, 2526, 2883, 3053, 3127, 3767, 3918)
- `Sources/TaskManagerWindowController.swift`
- `Sources/Feed/FeedPreviewWindowController.swift`
- `Sources/Feed/FeedButtonStyleDebugWindowController.swift`
- `Sources/Feed/FeedTextEditorDebugWindowController.swift`
- `Sources/Panels/PDFPreviewChromeDebugWindowController.swift`
- `Sources/BonsplitTabBarDebug.swift`

**QA**: Open + close each debug window. Add `#if DEBUG deinit { cmuxDebugLog("\(Self.self).deinit") }` to a few SwiftUI ObservableObject models hosted in these windows — confirm logs fire on close.

---

### PR1 Validation (before merge)

1. `./scripts/reload.sh --tag fix-mem-leaks-p1` — clean build
2. `xcodebuild -scheme cmux-unit ... test` — unit tests pass
3. Manual QA: Open app, create 10 workspaces × 3 panes, close them all. Memory should be substantially lower than today.
4. Manual QA: Open + close debug windows repeatedly. Activity Monitor should not climb.
5. Confirm no new warnings in `lsp_diagnostics`.

---

## PR2 — Workspace & Browser Panel Teardown (HIGHER RISK)

**Goal**: Fix item 4 + item 7 together. The biggest single memory wins.

**Tag**: `fix-mem-leaks-p2`

### Commit 2.1: `fix(workspace): clear all state dicts in teardownAllPanels`

**Files**: `Sources/Workspace.swift`

**Action**: In `Workspace.teardownAllPanels()` (search for it), AFTER current cleanup, add:
```swift
panels.removeAll()
panelSubscriptions.values.forEach { $0.cancel() }  // verify cancel is the right API
panelSubscriptions.removeAll()
statusEntries.removeAll()
metadataBlocks.removeAll()
logEntries.removeAll()
panelDirectories.removeAll()
panelTitles.removeAll()
panelCustomTitles.removeAll()  // if exists
panelGitBranches.removeAll()
panelPullRequests.removeAll()
surfaceListeningPorts.removeAll()
agentPIDs.removeAll()
agentPIDPanelIdsByKey.removeAll()
agentPIDKeysByPanelId.removeAll()
restoredTerminalScrollbackByPanelId.removeAll()  // verify not already cleared
restoredAgentSnapshotsByPanelId.removeAll()
restoredAgentResumeStatesByPanelId.removeAll()
pendingTerminalInputObserversByPanelId.removeAll()
```

**⚠️ DANGER**: These are `@Published`. Clearing them WILL trigger SwiftUI body recomputes. Verify no observer downstream crashes on empty state.

**Approach**: Add a feature flag `Workspace.aggressiveCleanupOnTeardown = false` initially. Test with flag ON in dogfood for a day. Flip to default ON when stable. Remove flag in next release.

**Test**: Write `WorkspaceMemoryLeakTests.swift`:
```swift
func testWorkspaceCloseReleasesAllState() {
    weak var weakWs: Workspace?
    autoreleasepool {
        let ws = Workspace(...)
        weakWs = ws
        // populate with mock panels
        ws.teardownAllPanels()
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertNil(weakWs, "Workspace leaked after teardown")
}
```

---

### Commit 2.2: `fix(browser): complete WKWebView teardown in BrowserPanel.close()`

**Files**: `Sources/Panels/BrowserPanel.swift`

**Lines**: ~3940 (current close method)

**Action**: Expand close() to:
```swift
func close() {
    // existing cleanup ...
    
    // NEW: Remove ALL script message handlers
    let ctrl = webView.configuration.userContentController
    if #available(macOS 11.0, *) {
        ctrl.removeAllScriptMessageHandlers()
    } else {
        // Manually remove known handler names
        for name in knownHandlerNames {
            ctrl.removeScriptMessageHandler(forName: name)
        }
    }
    ctrl.removeAllUserScripts()
    
    // NEW: Uninstall coordinators
    webAuthnCoordinator?.uninstall(from: webView)
    reactGrabMessageHandler = nil
    
    // NEW: Stop loading & blank out content
    webView.stopLoading()
    webView.loadHTMLString("", baseURL: nil)  // forces WebContent process to discard
    
    // NEW: Remove from view hierarchy
    BrowserWindowPortalRegistry.detach(webView: webView)
    webView.removeFromSuperview()
}
```

**Test**: `BrowserPanelMemoryLeakTests.swift`: create + close 10 BrowserPanels, assert WebContent process count returns to baseline via Activity Monitor (manual).

---

## PR3 — Memory Pressure Infrastructure

**Tag**: `fix-mem-pressure-p3`

### Create `Sources/CmuxMemoryPressureMonitor.swift`

```swift
import Foundation
import Dispatch

@MainActor
final class CmuxMemoryPressureMonitor {
    static let shared = CmuxMemoryPressureMonitor()
    
    enum Level { case normal, warning, critical }
    
    private var source: DispatchSourceMemoryPressure?
    private var subscribers: [UUID: (Level) -> Void] = [:]
    
    private init() {}
    
    func start() {
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: .main
        )
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let event = s.data
            let level: Level = event.contains(.critical) ? .critical
                : event.contains(.warning) ? .warning : .normal
            cmuxDebugLog("mem.pressure level=\(level)")
            self.subscribers.values.forEach { $0(level) }
        }
        s.activate()
        self.source = s
    }
    
    @discardableResult
    func subscribe(_ handler: @escaping (Level) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }
    
    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
```

### Wire subscribers
- `BrowserHistoryStore`: on `.warning`, halve max entries; on `.critical`, evict to 100.
- `SessionIndexStore`: on `.warning`, clear directorySnapshotCache; on `.critical`, clear ClaudeMetadataCache.
- `FileExplorerStore`: on `.warning`, evict half of `nodesByPath`; on `.critical`, clear all but currently expanded paths.
- `CmuxTopSnapshotScopeCache`: on `.warning`, prune all.

### Init in `AppDelegate.applicationDidFinishLaunching`:
```swift
CmuxMemoryPressureMonitor.shared.start()
```

---

## PR4 — Browser Panel Hibernation (USER DECISION NEEDED)

**REQUIRES USER APPROVAL OF UX TRADE-OFFS FIRST**

Will produce a brief flash/loading when revisiting hibernated tab. Some users will dislike it. Should default OFF, opt-in via setting.

**Pattern**: nuance-dev/Web `TabHibernationManager.swift`

**Detection**: idle timer per panel + memory-pressure trigger

**Hibernate steps**:
1. `webView.takeSnapshot(...)` → store NSImage
2. Capture state: URL, scroll position, back/forward list, zoom
3. Display snapshot as NSImageView in panel's view slot
4. Call BrowserPanel teardown (above)
5. Mark panel as `.hibernated`

**Wake steps**:
1. On focus/visibility: create new WKWebView with SAME `WKWebsiteDataStore` instance (preserves cookies/localStorage)
2. Load stored URL (or restore back-forward list via private API if available)
3. Restore scroll/zoom after didFinish
4. Replace snapshot with live webview

**Exclude conditions** (don't hibernate if):
- Audio/video playing (`webView.isPlayingAudio` if available, else heuristic)
- Active download in panel
- Developer tools open
- URL is `about:blank` or empty
- Less than X minutes since last interaction

---

## PR5 — Ghostty Scrollback Trim (OPTIONAL — USER DECISION)

Risk: scrollback loss is user-visible. Probably ship as "under critical pressure only" + setting to disable.

**Investigate first**: does Ghostty have `ghostty_surface_set_scrollback_limit` or runtime config? Check via librarian against ghostty submodule.

---

## Reference Materials

### Findings sources
- Background task `bg_d216ce85` — Ghostty terminal memory
- Background task `bg_a4541c01` — Browser panel WKWebView
- Background task `bg_471ac111` — Workspace/session lifecycle
- Background task `bg_3b5dbb4f` — Stores and global state
- Background task `bg_6ee7e5be` — SwiftUI view hierarchy
- Background task `bg_788a8bb8` — Retain cycle patterns
- Background task `bg_5992d52f` — Socket/IPC subscription leaks
- Background task `bg_b8c52392` — WKWebView memory best practices (librarian)
- Background task `bg_0aca8bfa` — Swift memory leak detection patterns (librarian)

### External references (from librarian)
- nuance-dev/Web `TabHibernationManager.swift` (lines 139-179, 268-324) — production hibernation pattern
- NetNewsWire `WrapperScriptMessageHandler.swift` (lines 12-23) — weak proxy pattern
- Nuke `Cache.swift` (lines 73-82) — memory pressure source pattern
- VirtualBuddy `HostingWindowController.swift` (lines 58-64) — contentViewController = nil on close
- Apple `DispatchSource.makeMemoryPressureSource` docs

### cmux project conventions
- ALWAYS use `./scripts/reload.sh --tag <branch-slug>` to build/test
- NEVER bare `xcodebuild` or `open` untagged DerivedData app
- Run unit tests via CI (`gh workflow run test-e2e.yml`) per AGENTS.md
- Use `cmuxDebugLog("...")` for debug instrumentation; wrap in `#if DEBUG`
- Localize ALL user-facing strings via `String(localized: ..., defaultValue: ...)`

### Regression test commit policy (from AGENTS.md)
For each bug fix, **TWO commits**:
1. Add failing test (CI red)
2. Add fix (CI green)
This proves the test catches the bug.

---

## Next Session Boot-up

When resuming work on this:
1. `git checkout -b fix-mem-leaks-p1` (or continue branch)
2. Read this file
3. Start with Commit 1.1
4. Use `task(category="deep", load_skills=[], ...)` to delegate each commit
5. Verify each with `./scripts/reload.sh --tag fix-mem-leaks-p1` + manual QA
6. When PR1 done, get user signoff before starting PR2
