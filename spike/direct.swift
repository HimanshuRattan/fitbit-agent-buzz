// Spike: connect to the Air by its saved macOS identifier, without scanning, while the iPhone
// holds it. Tells us whether the Air accepts a second central even though it isn't advertising.
import CoreBluetooth
import Foundation

// Usage: direct <air-peripheral-id> [timeout-seconds]   (get the ID from ./find-air)
let parsedID = UUID(uuidString: CommandLine.arguments.dropFirst().first ?? "")
if parsedID == nil {
    print("usage: direct <air-peripheral-id> [timeout-seconds]")
    exit(2)
}
let airID = parsedID!
let timeoutSeconds = Double(CommandLine.arguments.dropFirst(2).first ?? "") ?? 60
let gattlinkService = CBUUID(string: "ABBAFF00-E56A-484C-B832-8B17CF6CBFE8")

final class Direct: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var air: CBPeripheral?
    let start = Date()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func log(_ message: String) {
        print(String(format: "[%5.1fs] ", Date().timeIntervalSince(start)) + message)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .poweredOff {
                log("Bluetooth unavailable (state \(central.state.rawValue)).")
                exit(2)
            }
            return
        }
        let known = central.retrievePeripherals(withIdentifiers: [airID])
        guard let peripheral = known.first else {
            log("macOS has no record of \(airID). Run ./gatt once first.")
            exit(1)
        }
        log("macOS knows \(peripheral.name ?? "-") state=\(peripheral.state.rawValue). Connecting without scanning...")
        air = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            self.log("No connection after \(Int(timeoutSeconds))s.")
            central.cancelPeripheralConnection(peripheral)
            exit(1)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("CONNECTED. Discovering Gattlink service...")
        peripheral.discoverServices([gattlinkService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Connect failed: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "clean")")
        exit(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let found = peripheral.services?.contains { $0.uuid == gattlinkService } ?? false
        log("Gattlink service \(found ? "present" : "missing")\(error.map { " (\($0.localizedDescription))" } ?? ""). Disconnecting.")
        central.cancelPeripheralConnection(peripheral)
    }
}

let direct = Direct()
RunLoop.main.run()
