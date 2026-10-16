// Spike: watch for the Fitbit Air (service FD62) advertising over a long window and log when
// it is visible, to learn whether it ever advertises while the iPhone is connected.
import CoreBluetooth
import Foundation

let fitbitService = CBUUID(string: "FD62")
let watchSeconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 300
let gapSeconds = 5.0 // a new "window" starts if the Air was unseen for this long

final class Watcher: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    let start = Date()
    var windowStart: Date?
    var lastSeen: Date?
    var sightings = 0
    let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .poweredOff {
                print("Bluetooth unavailable (state \(central.state.rawValue)).")
                exit(2)
            }
            return
        }
        print("\(clock.string(from: Date())) watching for FD62 for \(Int(watchSeconds))s")
        central.scanForPeripherals(withServices: [fitbitService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.tick() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let now = Date()
        sightings += 1
        if windowStart == nil {
            windowStart = now
            print("\(clock.string(from: now)) Air visible (rssi \(RSSI))")
        }
        lastSeen = now
    }

    func tick() {
        let now = Date()
        if let seen = lastSeen, let opened = windowStart, now.timeIntervalSince(seen) > gapSeconds {
            print("\(clock.string(from: seen)) Air gone, visible for \(Int(seen.timeIntervalSince(opened)) + 1)s")
            windowStart = nil
            lastSeen = nil
        }
        if now.timeIntervalSince(start) >= watchSeconds {
            if let opened = windowStart {
                print("\(clock.string(from: now)) still visible at end, for \(Int(now.timeIntervalSince(opened)))s")
            }
            print("Done. \(sightings) advertisements seen.")
            exit(0)
        }
    }
}

let watcher = Watcher()
RunLoop.main.run()
