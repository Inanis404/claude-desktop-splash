// Claude splash launcher for macOS (experimental counterpart of launcher/launch.ps1).
//
// Plays ../splash.html in a borderless window that covers (and follows) the Claude desktop
// window, starts Claude, then fades the splash out to reveal Claude. Claude itself is not
// modified. Build it into an app with make_app.sh; the compiled binary must be the app's own
// executable, otherwise macOS does not treat it as an app.
//
// Where does the splash go?
//   1. Claude saved as full-screen (window-state.json, or the last run) -> the whole screen,
//      see "Full-screen Claude" below
//   2. otherwise -> Claude's saved window position (window-state.json), then where Claude's
//      window was at the end of the last run, then the main screen; as soon as Claude's window
//      shows up the splash moves onto it and follows it
// If Claude is already running there is no splash: Claude is opened, which brings it to the
// front (and shows its window again if it was closed).
//
// Full-screen Claude: macOS slides into a separate space and does not draw other apps' windows
// during that slide, so the splash cannot cover it. Instead the splash plays over the whole
// screen first and Claude is started near the end of the animation, timed so that its slide
// lands where the animation ends; the slide then replaces the fade-out. How long Claude takes
// to slide in is measured on each run and used for the next one.
//
// Skip while playing: click, or Esc / Space / Return / keypad Enter (registered as temporary
// global hot keys, so they work while Claude has focus; no Accessibility permission needed).
// Clicking outside the splash, switching to another app or another space ends it at once.
//
// Settings baked into the app by make_app.sh (Info.plist): SplashRepo, SplashArt, SplashNoSound.
// Switches for testing (command-line arguments, they override the app's settings):
//   -noClaude YES     only play the splash, do not start Claude
//   -fullscreen YES   ignore Claude's window and cover the whole main screen
//   -mute YES         no startup sound
//   -art classic      original artwork
//   -repo PATH        use another copy of this repository
// Stored with `defaults` under the app's bundle id (local.claude-desktop-splash):
//   lastRect, lastFullscreen, lateSlideDelay   remembered between runs
//   lateOffset                                 optional: seconds to move the full-screen slide later (+) or earlier (-)
// Log: launcher.log next to this file (cleared when it grows over 100 KB).

import Cocoa
import WebKit
import Carbon.HIToolbox

let claudeBundleID = "com.anthropic.claudefordesktop"
let defaults = UserDefaults.standard
let info = Bundle.main.infoDictionary ?? [:]

let repoPath: String = {
    if let r = defaults.string(forKey: "repo") { return r }
    if let r = info["SplashRepo"] as? String { return r }
    // app built inside the repository: <repo>/launcher-mac/<name>.app
    return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
}()
// (defaults.bool also reads "-mute YES" given on the command line)
let mute = defaults.object(forKey: "mute") != nil ? defaults.bool(forKey: "mute") : (info["SplashNoSound"] as? Bool ?? false)
let classic = (defaults.string(forKey: "art") ?? info["SplashArt"] as? String) == "classic"
let noClaude = defaults.bool(forKey: "noClaude")
let fullscreen = defaults.bool(forKey: "fullscreen")

let readyTimeout: TimeInterval = 8    // give up on the splash if the page is not ready by then
let maxSplash: TimeInterval = 22      // the splash window stays at most this long
let fadeOut: TimeInterval = 0.8
// Full-screen timing. The page reports DONE ~9.45 s after it starts playing (where a fade-out
// would begin); the picture runs to ~10 s. The space-change notice arrives a little after the
// slide is already visible, so the notice is aimed at 10.4 s. The original artwork's timeline
// is 0.7 s shorter.
let slideTarget: TimeInterval = (classic ? 9.7 : 10.4) + defaults.double(forKey: "lateOffset")

// ---------- log ----------
let logURL = URL(fileURLWithPath: repoPath).appendingPathComponent("launcher-mac/launcher.log")
let started = Date()
let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
func slog(_ s: String) {
    let line = "\(stamp.string(from: Date())) +\(String(format: "%.2f", Date().timeIntervalSince(started)))s \(s)\n"
    let data = line.data(using: .utf8)!
    FileHandle.standardError.write(data)
    if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 100_000 {
        try? FileManager.default.removeItem(at: logURL)
    }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

// ---------- skip keys ----------
// Esc / Return / Space / keypad Enter as global hot keys while the splash is up. A key event
// monitor would not work: Claude takes focus while it starts, and macOS does not let the
// launcher take it back. Released as soon as the splash ends.
enum SkipKeys {
    static var action: (() -> Void)?
    static var refs: [EventHotKeyRef] = []
    static var handler: EventHandlerRef?

    static func register(_ onPress: @escaping () -> Void) {
        action = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let st = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { SkipKeys.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        var result: [String] = []
        for (i, (code, name)) in [(kVK_Escape, "Esc"), (kVK_Return, "Return"), (kVK_Space, "Space"), (kVK_ANSI_KeypadEnter, "Enter")].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x53504C48), id: UInt32(i + 1))   // 'SPLH'
            let r = RegisterEventHotKey(UInt32(code), 0, id, GetApplicationEventTarget(), 0, &ref)
            if r == noErr, let ref = ref { refs.append(ref); result.append(name) } else { result.append("\(name)=err\(r)") }
        }
        slog("skip keys: handler=\(st) \(result.joined(separator: " "))")
    }

    static func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let h = handler { RemoveEventHandler(h); handler = nil }
        action = nil
    }
}

final class SplashWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SplashWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // a click skips even when Claude has focus
}

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: SplashWindow!
    var web: SplashWebView!
    var titleObs: NSKeyValueObservation?
    var monitors: [Any] = []
    var observers: [NSObjectProtocol] = []
    var followTimer: Timer?
    var state = "LOADING"          // last state the page reported: READY / PLAYING / DONE
    var finishing = false
    var revealed = false
    var startSent = false
    var claudePID: pid_t = 0
    var claudeSeen = false
    var lastTarget: NSRect?        // Claude's window, remembered for the next run

    // full-screen Claude (see the header)
    var fullscreenStart = false
    var playingAt: Date?
    var lateLaunched = false
    var lateOnSchedule = false
    var lateLaunchedAt: Date?
    var lateEnding = false

    var slideDelay: TimeInterval { min(max(defaults.object(forKey: "lateSlideDelay") as? TimeInterval ?? 1.2, 0.3), 4) }
    var lateLaunchAt: TimeInterval { max(0, slideTarget - slideDelay) }

    func applicationDidFinishLaunching(_ n: Notification) {
        slog("--- launcher start (art: \(classic ? "classic" : "new"), sound: \(mute ? "off" : "on"))")
        if !noClaude, !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty {
            slog("Claude is already running: no splash, bringing it to the front")
            openClaude(activate: true) { NSApp.terminate(nil) }
            return
        }
        let page = URL(fileURLWithPath: repoPath).appendingPathComponent("splash.html")
        guard FileManager.default.fileExists(atPath: page.path) else {
            slog("splash.html not found next to launcher-mac; starting Claude only")
            openClaude(activate: true) { NSApp.terminate(nil) }; return
        }

        var q = [URLQueryItem(name: "launcher", value: "")]
        if mute { q.append(URLQueryItem(name: "mute", value: "")) }
        if classic { q.append(URLQueryItem(name: "art", value: "classic")) }
        var comps = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        comps.queryItems = q
        let query = comps.percentEncodedQuery ?? "launcher"

        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []              // video and sound without a click
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        // The page must see ?launcher (it then reports its state in the title and leaves the
        // fade-out to the launcher), even if the file URL loses its query.
        cfg.userContentController.addUserScript(WKUserScript(
            source: "if (!location.search) history.replaceState(null, '', location.pathname + '?\(query)');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Note clicks and keys the page itself receives in the log (they skip the animation there).
        cfg.userContentController.add(self, name: "log")
        cfg.userContentController.addUserScript(WKUserScript(
            source: "addEventListener('click', () => webkit.messageHandlers.log.postMessage('page got a click'), true);"
                  + "addEventListener('keydown', e => webkit.messageHandlers.log.postMessage('page got key ' + e.key), true);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = SplashWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")

        window = SplashWindow(contentRect: initialFrame(), styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = fullscreenStart ? .statusBar : .floating      // full-screen: also over the menu bar and Dock
        window.isOpaque = false
        window.backgroundColor = .black
        window.alphaValue = 0              // invisible until the page is ready
        window.ignoresMouseEvents = true   // and clicks go through meanwhile
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = web

        titleObs = web.observe(\.title, options: [.new]) { [weak self] w, _ in
            guard let t = w.title, t.hasPrefix("CLAUDE_SPLASH_") else { return }
            let s = String(t.dropFirst("CLAUDE_SPLASH_".count).split(separator: "|").first ?? "")
            DispatchQueue.main.async { self?.onState(s) }
        }
        web.loadFileURL(comps.url!, allowingReadAccessTo: URL(fileURLWithPath: repoPath))

        window.orderFrontRegardless()
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        installSkipTriggers()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.launchClaude() }
        DispatchQueue.main.asyncAfter(deadline: .now() + readyTimeout) { [weak self] in
            guard let self = self, self.state == "LOADING" else { return }
            slog("page not ready within \(Int(readyTimeout)) s: no splash"); self.finish(fade: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSplash) { [weak self] in
            guard let self = self, !self.finishing else { return }
            slog("splash still up after \(Int(maxSplash)) s: ending it"); self.finish(fade: 0.3)
        }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.follow() }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        slog("\(m.body)")
    }

    // ---------- page state ----------

    func onState(_ s: String) {
        if finishing { return }
        if s != state { slog("page: \(s)") }
        state = s
        switch s {
        case "READY":
            if fullscreenStart { slog("full-screen Claude: playing over the screen, Claude starts at \(String(format: "%.2f", lateLaunchAt)) s") }
            reveal(); startPlayback()
        case "PLAYING":
            reveal()
            if playingAt == nil { playingAt = Date() }
        case "DONE":
            if fullscreenStart { endFullscreen() } else { finish(fade: fadeOut) }
        default: break
        }
    }

    func reveal() {
        if revealed || finishing { return }
        revealed = true
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; window.animator().alphaValue = 1 }
    }

    // After READY the page waits for the window to stop resizing (or 3.5 s). The window is
    // already in place, so tell it right away.
    func startPlayback() {
        if startSent || finishing || state == "LOADING" { return }
        startSent = true
        web.evaluateJavaScript("dispatchEvent(new Event('resize'))", completionHandler: nil)
    }

    // ---------- skipping ----------

    // Anything that means the user is doing something else ends the splash, so it never stays
    // behind detached from Claude's window.
    func installSkipTriggers() {
        SkipKeys.register { [weak self] in self?.skip("key") }
        // Mouse-only global monitors need no Accessibility permission.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.skip("click outside", quick: true)
        }) { monitors.append(m) }
        // Switching to another app or space; Claude itself does not count (it takes focus while
        // starting, and a full-screen Claude switches space).
        let movedOn: (String) -> Void = { [weak self] what in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self = self, !self.finishing else { return }
                let front = NSWorkspace.shared.frontmostApplication
                if front?.bundleIdentifier == claudeBundleID || front == NSRunningApplication.current { return }
                self.skip("\(what) \(front?.localizedName ?? "another app")", quick: true)
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            slog("space changed")
            if let self = self, self.fullscreenStart, self.lateLaunched, !self.finishing { self.claudeSlidIn(); return }
            movedOn("space changed to")
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            movedOn("switched to")
        })
    }

    // Same path as a click on the page: it fades the sound and reports DONE.
    // quick: the user is already elsewhere (windows may be moving), so close at once.
    func skip(_ why: String, quick: Bool = false) {
        if finishing { return }
        slog("skipped (\(why))")
        if state == "LOADING" { finish(fade: 0); return }
        if quick {
            web.evaluateJavaScript("window.dispatchEvent(new MouseEvent('click'))", completionHandler: nil)
            finish(fade: 0.15); return
        }
        web.evaluateJavaScript("document.body.dispatchEvent(new MouseEvent('click', {bubbles: true}))") { [weak self] _, err in
            if err != nil { self?.finish(fade: 0.5) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in   // the page did not answer
            guard let self = self, !self.lateEnding else { return }                 // (full-screen: waiting for Claude)
            self.finish(fade: 0.5)
        }
    }

    // ---------- full-screen Claude ----------

    func lateLaunch(_ why: String) {
        if lateLaunched || noClaude { return }
        lateLaunched = true; lateLaunchedAt = Date(); lateOnSchedule = why == "on schedule"
        let at = playingAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "?"
        slog("starting Claude (\(why), \(at) s into the animation)")
        openClaude(activate: true) { }
    }

    // Animation over or skipped: keep its last frame until the slide into Claude takes over.
    // If no slide comes (Claude is not full-screen after all), fade out after 4 s.
    func endFullscreen() {
        if lateEnding || finishing { return }
        lateEnding = true
        lateLaunch("animation ended")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, !self.finishing else { return }
            slog("Claude did not slide in within 4 s: fading out")
            defaults.set(false, forKey: "lastFullscreen")
            self.finish(fade: fadeOut)
        }
    }

    func claudeSlidIn() {
        if let l = lateLaunchedAt, lateOnSchedule {
            // Remember how long Claude took. A slower run (e.g. the first start after a restart)
            // moves the estimate only a little and very slow ones are ignored, so that one slow
            // start does not make the next slide come too early.
            let took = Date().timeIntervalSince(l)
            let old = defaults.object(forKey: "lateSlideDelay") as? TimeInterval ?? took
            if took <= 3 { defaults.set(took < old ? (old + took) / 2 : old * 0.8 + took * 0.2, forKey: "lateSlideDelay") }
            let at = playingAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "?"
            slog("Claude slid in \(String(format: "%.2f", took)) s after starting, \(at) s into the animation (target \(slideTarget))")
        }
        defaults.set(true, forKey: "lastFullscreen")
        slog("Claude is full-screen: closing the splash")
        finish(fade: 0)
    }

    // ---------- placing the splash ----------

    func initialFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        if fullscreen || noClaude { return screen.frame }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/window-state.json")
        let j = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if j?["isFullScreen"] as? Bool == true {
            fullscreenStart = true
            slog("window-state.json: Claude is full-screen")
            return screen.frame
        }
        if j?["isFullScreen"] == nil, defaults.bool(forKey: "lastFullscreen") {
            let r = NSRectFromString(defaults.string(forKey: "lastRect") ?? "")
            if let sc = NSScreen.screens.first(where: { $0.frame == r }) ?? (r.isEmpty ? screen : nil) {
                fullscreenStart = true
                slog("Claude was full-screen last time")
                return sc.frame
            }
        }
        if let j = j,
           let x = j["x"] as? Double, let y = j["y"] as? Double,
           let w = j["width"] as? Double, let h = j["height"] as? Double, w > 300, h > 200 {
            let r = cocoaRect(CGRect(x: x, y: y, width: w, height: h))
            if NSScreen.screens.contains(where: { $0.frame.intersects(r) }) {
                slog("placed from Claude's window-state.json"); return r
            }
        }
        let last = NSRectFromString(defaults.string(forKey: "lastRect") ?? "")
        if last.width > 300, NSScreen.screens.contains(where: { $0.frame.intersects(last) }) {
            slog("placed where Claude's window was last time"); return last
        }
        slog("placed on the main screen (no saved window position)")
        return screen.visibleFrame
    }

    // Quartz window coordinates (origin top-left of the primary screen) -> Cocoa (bottom-left).
    func cocoaRect(_ r: CGRect) -> NSRect {
        let primaryH = NSScreen.screens[0].frame.height
        return NSRect(x: r.origin.x, y: primaryH - r.origin.y - r.height, width: r.width, height: r.height)
    }

    // Runs 30 times a second: keeps the splash on Claude's window (window bounds need no
    // permission), or, for a full-screen Claude, starts Claude on time.
    func follow() {
        if fullscreen || noClaude || finishing { return }
        if fullscreenStart {
            if let p = playingAt, !lateLaunched, Date().timeIntervalSince(p) >= lateLaunchAt { lateLaunch("on schedule") }
            return
        }
        if claudePID == 0 {
            claudePID = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first?.processIdentifier ?? 0
            if claudePID == 0 { return }
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var best: CGRect?
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == claudePID,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd),
                  r.width > 300, r.height > 200 else { continue }
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        guard let b = best else { return }
        let target = cocoaRect(b)
        if !claudeSeen {
            claudeSeen = true
            slog("Claude window appeared at \(Int(target.minX)),\(Int(target.minY)) \(Int(target.width))x\(Int(target.height))")
        }
        lastTarget = target
        if window.frame != target { window.setFrame(target, display: true) }
    }

    // ---------- Claude ----------

    func launchClaude() {
        if noClaude || fullscreenStart { return }   // full-screen: started near the end instead
        slog("starting Claude")
        openClaude(activate: false) { }              // the splash stays in front while Claude starts
    }

    // Opening a running app sends it a "reopen", so a window closed to the menu bar comes back too.
    func openClaude(activate: Bool, then: @escaping () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else {
            slog("Claude.app not found (bundle id \(claudeBundleID))"); then(); return
        }
        let c = NSWorkspace.OpenConfiguration()
        c.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: c) { app, err in
            DispatchQueue.main.async {
                if let err = err { slog("could not open Claude: \(err.localizedDescription)") }
                if let app = app { self.claudePID = app.processIdentifier }
                then()
            }
        }
    }

    // ---------- end ----------

    func finish(fade: TimeInterval) {
        if finishing { return }
        finishing = true
        followTimer?.invalidate()
        SkipKeys.unregister()
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        if let t = lastTarget {
            defaults.set(NSStringFromRect(t), forKey: "lastRect")
            defaults.set(false, forKey: "lastFullscreen")
        }
        let done = {
            self.window?.orderOut(nil)
            slog("launcher end")
            if noClaude { NSApp.terminate(nil); return }
            self.openClaude(activate: true) { NSApp.terminate(nil) }
        }
        if fade <= 0 || window == nil { done(); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = fade; self.window.animator().alphaValue = 0 },
                                             completionHandler: done)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon
let delegate = App()
app.delegate = delegate
app.run()
