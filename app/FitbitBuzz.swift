// Fitbit Buzz: menu bar app that hands the Fitbit Air between the iPhone and this Mac.
//
// "Connect to Mac" scans for the Air (service FD62; its ID changes when it rotates its
// Bluetooth address), then runs Golden Gate's gg-stack-tool to hold a Gattlink/DTLS session.
// While held, bin/fitbit-buzz sends CoAP requests through the stack's top port (5683).
// "Release to iPhone" stops the stack; Google Health on the iPhone reconnects by itself.
// Google Health must be force-quit on the iPhone before the Mac can connect.
import AppKit
import CoreBluetooth

enum Link: Equatable {
    case onPhone, searching, connecting, onMac
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate {
    let fitbitService = CBUUID(string: "FD62")
    let bootstrapKey = "BOOTSTRAP:810654E336ADCAB0A03C60F74AA0B6FB"
    let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/notify-fitbit")
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/notify-fitbit-stack.log")

    var statusItem: NSStatusItem!
    var central: CBCentralManager!
    var stack: Process?
    var link = Link.onPhone
    var wantMac = false
    var reconnectTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        killLeftoverStacks()
        writeState(connected: false)
        loadSettings()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        central = CBCentralManager(delegate: self, queue: nil)
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStack()
    }

    // MARK: Menu

    var statusText: String {
        switch link {
        case .onPhone: "Fitbit on iPhone"
        case .searching: "Looking for Fitbit (force-quit Google Health on iPhone)"
        case .connecting: "Connecting to Fitbit..."
        case .onMac: "Fitbit on Mac: buzzes on"
        }
    }

    func render() {
        let symbol = switch link {
        case .onPhone: "applewatch.slash"
        case .searching: "magnifyingglass"
        case .connecting: "ellipsis"
        case .onMac: "applewatch.radiowaves.left.and.right"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        statusItem.button?.image?.isTemplate = true
    }

    /// Rebuild the menu each time it opens, so controls never carry stale state between opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let statusLine = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        if wantMac {
            menu.addItem(item("Release to iPhone", #selector(releaseToPhone)))
        } else {
            menu.addItem(item("Connect to Mac", #selector(connectToMac)))
        }
        let test = item("Test buzz", #selector(testBuzz))
        test.isEnabled = link == .onMac
        menu.addItem(test)
        menu.addItem(.separator())
        menu.addItem(sliderItem(title: strengthTitle(), maxValue: Double(strengths.count - 1),
                                value: Double(strengths.firstIndex(of: strength) ?? 1),
                                action: #selector(strengthChanged(_:))))
        menu.addItem(sliderItem(title: countTitle(), maxValue: 4, value: Double(count - 1),
                                action: #selector(countChanged(_:))))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit (releases Fitbit)", #selector(quit)))
    }

    // MARK: Buzz settings (read by bin/fitbit-buzz)

    let strengths = ["gentle", "mixed", "strong"]
    var strength = "mixed"
    var count = 1

    func strengthTitle() -> String { "Strength: \(strength.capitalized)" }
    func countTitle() -> String { "Vibrations: \(count)" }

    /// A labelled slider with tick stops, embedded in the menu.
    func sliderItem(title: String, maxValue: Double, value: Double, action: Selector) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 20, y: 24, width: 200, height: 16)
        label.font = .menuFont(ofSize: 0)
        let slider = NSSlider(value: value, minValue: 0, maxValue: maxValue, target: self, action: action)
        slider.frame = NSRect(x: 18, y: 2, width: 204, height: 22)
        slider.numberOfTickMarks = Int(maxValue) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = false // act once, on release
        view.addSubview(label)
        view.addSubview(slider)
        let menuItem = NSMenuItem()
        menuItem.view = view
        return menuItem
    }

    func updateLabel(of slider: NSSlider, to text: String) {
        (slider.superview?.subviews.first { $0 is NSTextField } as? NSTextField)?.stringValue = text
    }

    func preview() {
        if link == .onMac { buzz("single") }
    }

    @objc func strengthChanged(_ slider: NSSlider) {
        strength = strengths[slider.integerValue]
        updateLabel(of: slider, to: strengthTitle())
        saveSettings()
        preview()
    }

    @objc func countChanged(_ slider: NSSlider) {
        count = slider.integerValue + 1
        updateLabel(of: slider, to: countTitle())
        saveSettings()
        preview()
    }

    func loadSettings() {
        let url = stateDir.appendingPathComponent("settings")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "strength", strengths.contains(parts[1]) { strength = parts[1] }
            if parts[0] == "count", let value = Int(parts[1]), (1...5).contains(value) { count = value }
        }
    }

    func saveSettings() {
        let url = stateDir.appendingPathComponent("settings")
        try? "strength=\(strength)\ncount=\(count)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    func setLink(_ next: Link) {
        guard next != link else { return }
        let wasOnMac = link == .onMac
        link = next
        writeState(connected: next == .onMac)
        render()
        if next == .onMac && !wasOnMac {
            buzz("single") // physical confirmation that the Mac holds the band
        }
    }

    @objc func connectToMac() {
        wantMac = true
        startSearch()
    }

    @objc func releaseToPhone() {
        wantMac = false
        central.stopScan()
        stopStack()
        setLink(.onPhone)
        render()
    }

    @objc func testBuzz() { buzz("single") }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    @objc func quit() {
        stopStack()
        NSApp.terminate(nil)
    }

    // MARK: Bluetooth discovery

    func startSearch() {
        stopStack()
        setLink(.searching)
        render()
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [fitbitService])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && wantMac && link == .searching {
            central.scanForPeripherals(withServices: [fitbitService])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wantMac, stack == nil else { return }
        central.stopScan()
        startStack(airID: peripheral.identifier.uuidString)
    }

    // MARK: Golden Gate stack

    func startStack(airID: String) {
        setLink(.connecting)
        let process = Process()
        process.executableURL = Bundle.main.url(forResource: "gg-stack-tool", withExtension: nil)
        process.arguments = ["--top", "coap", "127.0.0.1", "0", "5683",
                             "--bottom", "bluetooth", airID,
                             "--dtls-key", bootstrapKey, "hub", "DSNG"]
        process.environment = ["GG_LOG_CONFIG": "plist:.level=INFO"]
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var pending = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil // EOF
                return
            }
            logHandle?.write(data)
            // Hand over whole lines only, so markers split across reads are still seen
            pending += String(decoding: data, as: UTF8.self)
            guard let lastNewline = pending.lastIndex(of: "\n") else { return }
            let lines = String(pending[...lastNewline])
            pending = String(pending[pending.index(after: lastNewline)...])
            DispatchQueue.main.async { self?.onStackOutput(lines) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.onStackExit(finished) }
        }
        do {
            try process.run()
            stack = process
        } catch {
            NSLog("Fitbit Buzz: failed to start gg-stack-tool: \(error)")
            scheduleRestart()
        }
    }

    func onStackOutput(_ text: String) {
        if text.contains("DTLS State: SESSION") {
            reconnectTimer?.invalidate()
            setLink(.onMac)
        } else if text.contains("disconnected!") {
            setLink(.connecting)
            // The stack tool rescans for the same ID, but the Air may come back under a new
            // one after rotating its address, so start over if it hasn't returned soon.
            reconnectTimer?.invalidate()
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                guard let self, self.wantMac, self.link != .onMac else { return }
                self.startSearch()
            }
        }
    }

    func onStackExit(_ finished: Process) {
        guard finished === stack else { return }
        stack = nil
        if wantMac { scheduleRestart() } else { setLink(.onPhone) }
    }

    func scheduleRestart() {
        setLink(.searching)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wantMac, self.stack == nil else { return }
            self.startSearch()
        }
    }

    func stopStack() {
        reconnectTimer?.invalidate()
        guard let process = stack else { return }
        stack = nil
        writeState(connected: false)
        process.terminate()
        process.waitUntilExit()
    }

    /// A crash would orphan the stack tool, which keeps holding the Air.
    func killLeftoverStacks() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "gg-stack-tool --top coap 127.0.0.1 0 5683"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    // MARK: Shared state and buzzing

    func writeState(connected: Bool) {
        let url = stateDir.appendingPathComponent("state")
        try? (connected ? "connected" : "released").write(to: url, atomically: true, encoding: .utf8)
    }

    func buzz(_ pattern: String) {
        guard let script = Bundle.main.object(forInfoDictionaryKey: "FitbitBuzzScript") as? String else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        process.arguments = [pattern]
        try? process.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
