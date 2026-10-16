// Spike: can this Mac see the Fitbit Air over BLE while the iPhone is paired?
// Lists every advertising peripheral for a few seconds and flags likely Fitbit devices.
import CoreBluetooth
import Foundation

let gattlinkService = CBUUID(string: "ABBAFF00-E56A-484C-B832-8B17CF6CBFE8")
let scanSeconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 15

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen: [UUID: String] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth on, scanning for \(Int(scanSeconds))s...")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            let connected = central.retrieveConnectedPeripherals(withServices: [gattlinkService])
            if !connected.isEmpty {
                print("Already connected to this Mac with Gattlink: \(connected.map { $0.name ?? $0.identifier.uuidString })")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + scanSeconds) {
                print("Done. \(self.seen.count) devices seen.")
                exit(0)
            }
        case .unauthorized:
            print("Bluetooth permission denied. Allow your terminal in System Settings > Privacy & Security > Bluetooth.")
            exit(2)
        case .poweredOff:
            print("Bluetooth is off.")
            exit(2)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard seen[peripheral.identifier] == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { $0.map { String(format: "%02X", $0) }.joined() } ?? ""
        seen[peripheral.identifier] = name

        let lowered = name.lowercased()
        let likely = lowered.contains("fitbit") || lowered.contains("air") || services.contains(gattlinkService)
        let flag = likely ? "  <== likely Fitbit" : ""
        print("[\(RSSI) dBm] \(name) id=\(peripheral.identifier.uuidString.prefix(8)) services=\(services.map(\.uuidString)) serviceData=\(serviceData.keys.map(\.uuidString)) mfg=\(mfg.prefix(16))\(flag)")
    }
}

let scanner = Scanner()
RunLoop.main.run()
