import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

@main
struct ScreenSenseApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var session: GazeSession?
    private var hotKey: EventHotKeyRef?
    private var swapItem: NSMenuItem!
    private var edgesItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private let defaults = UserDefaults.standard
    private var swapLeftRight: Bool {
        get { defaults.bool(forKey: "swapLR") }
        set { defaults.set(newValue, forKey: "swapLR") }
    }
    private var alignEdges: Bool {
        get { defaults.bool(forKey: "autoEdges") }
        set { defaults.set(newValue, forKey: "autoEdges") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        showStatus("display.2")
        statusItem.menu = buildMenu()
        registerHotKey()

        if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            showHelp()
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        _ = add("Arrange Displays  (⌃⌥⌘M)", #selector(arrange))
        _ = add("Test Without Changing", #selector(test))
        menu.addItem(placeMenu())
        menu.addItem(.separator())

        swapItem = add("Swap Left/Right", #selector(toggleSwap))
        swapItem.state = swapLeftRight ? .on : .off
        edgesItem = add("Auto-Align Edges", #selector(toggleEdges))
        edgesItem.state = alignEdges ? .on : .off
        loginItem = add("Open at Login", #selector(toggleLogin))
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
        _ = add("How to Use…", #selector(showHelp))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenSense",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func placeMenu() -> NSMenuItem {
        let groups: [(Side, [(String, String)])] = [
            (.above, [("Top-Left", "left"), ("Top-Center", "center"), ("Top-Right", "right"),
                      ("Top, Left Edges Aligned", "left edges aligned"),
                      ("Top, Right Edges Aligned", "right edges aligned")]),
            (.left, [("Left-Top", "top"), ("Left-Middle", "middle"), ("Left-Bottom", "bottom"),
                     ("Left, Top Edges Aligned", "top edges aligned"),
                     ("Left, Bottom Edges Aligned", "bottom edges aligned")]),
            (.right, [("Right-Top", "top"), ("Right-Middle", "middle"), ("Right-Bottom", "bottom"),
                      ("Right, Top Edges Aligned", "top edges aligned"),
                      ("Right, Bottom Edges Aligned", "bottom edges aligned")]),
        ]
        let sub = NSMenu()
        for (i, (side, spots)) in groups.enumerated() {
            if i > 0 { sub.addItem(.separator()) }
            for (title, name) in spots {
                let item = NSMenuItem(title: title, action: #selector(placeManually(_:)), keyEquivalent: "")
                item.representedObject = [side.rawValue, name]
                item.target = self
                sub.addItem(item)
            }
        }
        let root = NSMenuItem(title: "Place Monitor", action: nil, keyEquivalent: "")
        root.submenu = sub
        return root
    }

    @objc private func arrange() { begin(testOnly: false) }
    @objc private func test() { begin(testOnly: true) }

    @objc private func toggleSwap() {
        swapLeftRight.toggle()
        swapItem.state = swapLeftRight ? .on : .off
    }

    @objc private func toggleEdges() {
        alignEdges.toggle()
        edgesItem.state = alignEdges ? .on : .off
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn't change login setting",
                      "Move ScreenSense to your Applications folder and try again.")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func showHelp() {
        showAlert("ScreenSense", """
            Moved your monitor? Press ⌃⌥⌘M or choose Arrange Displays.

            1. Tink: turn your head around the monitor's four corners.
            2. Pop: look at the middle of your laptop screen.
            3. Glass: done.

            Turn your head, not just your eyes. You can also pick a layout \
            directly from Place Monitor.
            """)
    }

    @objc private func placeManually(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], info.count == 2,
              let side = Side(rawValue: info[0]) else { return }
        do {
            let displays = try DisplayPair.current()
            guard let target = Layout.targets(side, displays.sizes).first(where: { $0.name == info[1] }) else {
                throw AppError("That layout doesn't fit these two screen sizes.")
            }
            try apply(Placement(side: side, frac: target.frac, spot: target.name), to: displays)
        } catch {
            fail(error)
        }
    }

    // MARK: Status bar

    private func showStatus(_ symbol: String, _ text: String = "") {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenSense")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
        button.title = text.isEmpty ? "" : " " + text
    }

    private func flashStatus(_ symbol: String, _ text: String = "", for seconds: Double = 4) {
        showStatus(symbol, text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if let self = self, self.session == nil { self.showStatus("display.2") }
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func fail(_ error: Error) {
        NSSound(named: "Basso")?.play()
        flashStatus("exclamationmark.triangle")
        let message = (error as? AppError)?.message ?? error.localizedDescription
        showAlert("Display layout unchanged", message)
    }

    // MARK: Hotkey

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in AppDelegate.shared?.begin(testOnly: false) }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5353_4E53), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey | controlKey),
                            id, GetApplicationEventTarget(), 0, &hotKey)
    }

    // MARK: Arranging

    func begin(testOnly: Bool) {
        guard session == nil else { return }
        let displays: DisplayPair
        do { displays = try DisplayPair.current() } catch { return fail(error) }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in if granted { AppDelegate.shared?.begin(testOnly: testOnly) } }
            }
            return
        default:
            showAlert("Camera access needed",
                      "Turn on ScreenSense in System Settings → Privacy & Security → Camera.")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        showStatus("eye", "Starting…")
        let gaze = GazeSession(mirrored: swapLeftRight, onCue: { [weak self] cue in
            if cue == "start" {
                NSSound(named: "Tink")?.play()
                self?.showStatus("eye", "Look around the monitor")
            } else {
                NSSound(named: "Pop")?.play()
                self?.showStatus("laptopcomputer", "Look at your laptop")
            }
        }, onDone: { [weak self] result in
            self?.finish(result, displays: displays, testOnly: testOnly)
        })
        session = gaze
        do {
            try gaze.start()
        } catch {
            session = nil
            return fail(error)
        }

        Task { @MainActor [weak gaze] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            gaze?.cancel("The camera stopped responding. Try again.")
        }
    }

    private func finish(_ result: Result<GazeSession.Readings, AppError>, displays: DisplayPair, testOnly: Bool) {
        session = nil
        do {
            let readings = try result.get()
            let box = try Gaze.box(sweep: readings.sweep, laptop: readings.laptop)
            let placement = Layout.placement(box: box, sizes: displays.sizes, edges: alignEdges)
            if testOnly {
                NSSound(named: "Glass")?.play()
                flashStatus("checkmark.circle", "Test: \(placement.label)", for: 6)
            } else {
                try apply(placement, to: displays)
            }
        } catch {
            fail(error)
        }
    }

    private func apply(_ placement: Placement, to displays: DisplayPair) throws {
        try displays.arrange(monitorAt: Layout.origin(placement, displays.sizes))
        NSSound(named: "Glass")?.play()
        flashStatus("checkmark.circle", "Monitor: \(placement.label)")
    }
}
