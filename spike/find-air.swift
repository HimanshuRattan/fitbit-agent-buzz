// Prints the Fitbit Air's current macOS peripheral ID (it changes when the Air rotates its
// Bluetooth address). Scans for service FD62 and exits on the first hit, or exits 1 on timeout.
import CoreBluetooth
import Foundation

let fitbitService = CBUUID(string: "FD62")
let timeoutSeconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 60

final class Finder: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { exit(1) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [fitbitService])
        } else if central.state == .unauthorized || central.state == .poweredOff {
            exit(2)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        print(peripheral.identifier.uuidString)
        exit(0)
    }
}

let finder = Finder()
RunLoop.main.run()
