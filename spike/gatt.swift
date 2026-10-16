// Spike: find the Fitbit Air (advertises 16-bit service FD62), connect, and list its GATT
// services and characteristics. Read-only: it never reads or writes a characteristic, so it
// should not trigger pairing.
import CoreBluetooth
import Foundation

let fitbitService = CBUUID(string: "FD62")
let known: [String: String] = [
    "ABBAFF00-E56A-484C-B832-8B17CF6CBFE8": "Gattlink service",
    "ABBAFF01-E56A-484C-B832-8B17CF6CBFE8": "Gattlink rx",
    "ABBAFF02-E56A-484C-B832-8B17CF6CBFE8": "Gattlink tx",
    "ABBAFD00-E56A-484C-B832-8B17CF6CBFE8": "Link status service",
    "ABBAFC00-E56A-484C-B832-8B17CF6CBFE8": "Link configuration service",
    "AC2F0045-8182-4BE5-91E0-2992E6B40EBB": "Ephemeral pointer service",
]
let timeoutSeconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 30

final class Explorer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var air: CBPeripheral?
    var pendingServices = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            print(self.air == nil ? "Timed out: no FD62 device advertising." : "Timed out before discovery finished.")
            exit(1)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .poweredOff {
                print("Bluetooth unavailable (state \(central.state.rawValue)).")
                exit(2)
            }
            return
        }
        print("Scanning for FD62 for up to \(Int(timeoutSeconds))s...")
        central.scanForPeripherals(withServices: [fitbitService])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard air == nil else { return }
        air = peripheral
        central.stopScan()
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-"
        print("Found \(name) id=\(peripheral.identifier.uuidString) rssi=\(RSSI). Connecting...")
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected. Discovering services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Connect failed: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if let error { print("Service discovery error: \(error.localizedDescription)") }
        pendingServices = services.count
        if services.isEmpty { finish() }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("Service \(service.uuid.uuidString) \(known[service.uuid.uuidString] ?? "")")
        for c in service.characteristics ?? [] {
            print("  char \(c.uuid.uuidString) \(known[c.uuid.uuidString] ?? "") props=\(describe(c.properties))")
        }
        pendingServices -= 1
        if pendingServices == 0 { finish() }
    }

    func finish() {
        if let air { central.cancelPeripheralConnection(air) }
        print("Disconnected.")
        exit(0)
    }

    func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}

let explorer = Explorer()
RunLoop.main.run()
