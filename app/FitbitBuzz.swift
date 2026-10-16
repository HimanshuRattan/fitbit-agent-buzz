// Fitbit Buzz: menu bar app that hands the Fitbit Air between the iPhone and this Mac.
//
// "Mac" scans for the Air (service FD62; its ID changes when it rotates its Bluetooth
// address), then runs Golden Gate's gg-stack-tool to hold a Gattlink/DTLS session.
// While held, bin/fitbit-buzz sends CoAP requests through the stack's top port (5683).
// "iPhone" stops the stack; Google Health on the iPhone reconnects by itself.
// Google Health must be force-quit on the iPhone before the Mac can connect.
import AppKit
import CoreBluetooth
import SwiftUI

enum Link: Equatable {
    case onPhone, searching, connecting, onMac
}

// MARK: - Panel UI

struct PanelView: View {
    @ObservedObject var app: AppDelegate

    var statusColor: Color {
        switch app.link {
        case .onMac: .green
        case .searching, .connecting: .orange
        case .onPhone: .secondary
        }
    }

    var statusText: String {
        switch app.link {
        case .onPhone: "Band is on your iPhone"
        case .searching: "Looking for your band"
        case .connecting: "Connecting"
        case .onMac: "Connected, buzzes on"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 4) {
                segment("iPhone", icon: "iphone", selected: !app.wantMac) { app.releaseToPhone() }
                segment("Mac", icon: "laptopcomputer", selected: app.wantMac) { app.connectToMac() }
            }
            .padding(3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .animation(.easeOut(duration: 0.15), value: app.wantMac)

            // Fixed height so switching states never resizes the panel
            hint.frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .leading)
            Divider()
            vibrations
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
    }

    /// One half of the iPhone | Mac toggle; tapping the selected half does nothing.
    func segment(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { if !selected { action() } } label: {
            Label(title, systemImage: icon)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.accentColor : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(statusColor.opacity(0.16))
                Image(systemName: app.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Fitbit Buzz").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder var hint: some View {
        switch app.link {
        case .searching, .connecting:
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small)
                Text(app.link == .searching
                     ? "Force-quit Google Health on your iPhone. The band connects by itself."
                     : "Opening a secure session with the band.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        case .onMac:
            Text("You can reopen Google Health now. Switch back to iPhone when you're done so it syncs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .onPhone:
            Text("Switch to Mac to get buzzes while you work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var vibrations: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vibrations").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(app.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { n in
                    Capsule()
                        .fill(n <= app.count ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { app.setCount(n) }
                        .help("\(n) vibration\(n == 1 ? "" : "s")")
                }
            }
            .animation(.easeOut(duration: 0.15), value: app.count)
            Text("Each vibration is a strong tap, then a soft one. Waiting prompts play it twice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            Button { app.testBuzz() } label: {
                Label("Test buzz", systemImage: "waveform")
            }
            .disabled(app.link != .onMac)
            Spacer()
            Button { app.openLog() } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Open connection log")
            Button("Quit") { app.quit() }
                .buttonStyle(.borderless)
                .help("Quit and release the band to your iPhone")
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, CBCentralManagerDelegate {
    let fitbitService = CBUUID(string: "FD62")
    let bootstrapKey = "BOOTSTRAP:810654E336ADCAB0A03C60F74AA0B6FB"
    let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/notify-fitbit")
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/notify-fitbit-stack.log")

    @Published var link = Link.onPhone
    @Published var wantMac = false
    @Published var count = 1

    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var central: CBCentralManager!
    var stack: Process?
    var reconnectTimer: Timer?

    var symbol: String {
        switch link {
        case .onPhone: "applewatch.slash"
        case .searching: "magnifyingglass"
        case .connecting: "ellipsis"
        case .onMac: "applewatch.radiowaves.left.and.right"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        killLeftoverStacks()
        writeState(connected: false)
        loadSettings()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        let host = NSHostingController(rootView: PanelView(app: self))
        host.sizingOptions = [] // keep one fixed size instead of following content changes
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        central = CBCentralManager(delegate: self, queue: nil)
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStack()
    }

    @objc func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func render() {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fitbit Buzz")
        statusItem.button?.image?.isTemplate = true
    }

    // MARK: Buzz settings (read by bin/fitbit-buzz)

    func setCount(_ value: Int) {
        count = value
        saveSettings()
        if link == .onMac { buzz("single") } // preview
    }

    func loadSettings() {
        let url = stateDir.appendingPathComponent("settings")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "count", let value = Int(parts[1]), (1...5).contains(value) {
                count = value
            }
        }
    }

    func saveSettings() {
        let url = stateDir.appendingPathComponent("settings")
        try? "count=\(count)\n".write(to: url, atomically: true, encoding: .utf8)
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

    func connectToMac() {
        wantMac = true
        startSearch()
    }

    func releaseToPhone() {
        wantMac = false
        central.stopScan()
        stopStack()
        setLink(.onPhone)
        render()
    }

    func testBuzz() { buzz("single") }

    func openLog() { NSWorkspace.shared.open(logURL) }

    func quit() {
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
        guard let script = Bundle.main.url(forResource: "fitbit-buzz", withExtension: nil) else { return }
        let process = Process()
        process.executableURL = script
        process.arguments = [pattern]
        try? process.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
