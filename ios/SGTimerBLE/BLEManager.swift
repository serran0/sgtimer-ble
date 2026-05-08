import Foundation
import CoreBluetooth

private let kServiceUUID    = CBUUID(string: "7520ffff-14d2-4cda-8b6b-697c554c9311")
private let kEventUUID      = CBUUID(string: "75200001-14d2-4cda-8b6b-697c554c9311")
private let kApiVersionUUID = CBUUID(string: "7520fffe-14d2-4cda-8b6b-697c554c9311")
private let kNamePrefix     = "SG-SST"

struct BLEDeviceInfo {
    let name: String
    let address: String
    let model: String

    func toDictionary() -> [String: Any] {
        ["name": name, "address": address, "model": model]
    }
}

class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onEvent: (([String: Any]) -> Void)?

    private var central: CBCentralManager!
    private let bleQueue = DispatchQueue(label: "ble.queue")

    private var discovered: [CBPeripheral] = []
    private var scanCompletion: (([BLEDeviceInfo]) -> Void)?

    private var peripheral: CBPeripheral?
    private var devAddr = ""
    private var devName = ""
    private var devModel = ""
    private var apiVersion = "?"
    private var lastShotTime: Double?

    private var watchdogTimer: Timer?
    private var stopWatchdog = false

    // Readable status dict for /status endpoint
    var statusDict: [String: Any] {
        var devices: [[String: Any]] = []
        if let p = peripheral, p.state == .connected {
            devices = [[
                "address":     devAddr,
                "name":        devName,
                "model":       devModel,
                "api_version": apiVersion,
                "connected":   true
            ]]
        }
        return ["connected": !devices.isEmpty, "devices": devices]
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - Public

    func scan(duration: TimeInterval, completion: @escaping ([BLEDeviceInfo]) -> Void) {
        bleQueue.async { [weak self] in
            guard let self else { completion([]); return }
            guard self.central.state == .poweredOn else { completion([]); return }

            self.discovered = []
            self.scanCompletion = completion
            self.central.scanForPeripherals(withServices: nil,
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

            self.bleQueue.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self else { return }
                self.central.stopScan()
                let results = self.discovered
                    .filter { $0.name?.hasPrefix(kNamePrefix) == true }
                    .map { p -> BLEDeviceInfo in
                        let n = p.name ?? "Unknown"
                        return BLEDeviceInfo(name: n, address: p.identifier.uuidString, model: Self.model(from: n))
                    }
                let cb = self.scanCompletion
                self.scanCompletion = nil
                cb?(results)
            }
        }
    }

    func connect(address: String, name: String) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.devAddr  = address
            self.devName  = name
            self.devModel = Self.model(from: name)

            if let p = self.discovered.first(where: { $0.identifier.uuidString == address }) {
                self.peripheral = p
                p.delegate = self
                self.central.connect(p, options: nil)
                return
            }
            // Peripheral not in current scan – try retrieve by UUID
            if let uuid = UUID(uuidString: address) {
                let retrieved = self.central.retrievePeripherals(withIdentifiers: [uuid])
                if let p = retrieved.first {
                    self.peripheral = p
                    p.delegate = self
                    self.central.connect(p, options: nil)
                }
            }
        }
    }

    func disconnect(address: String) {
        bleQueue.async { [weak self] in
            guard let self, let p = self.peripheral,
                  p.identifier.uuidString == address else { return }
            self.stopWatchdog = true
            DispatchQueue.main.async { self.watchdogTimer?.invalidate() }
            self.central.cancelPeripheralConnection(p)
        }
    }

    // MARK: - Helpers

    private static func model(from name: String) -> String {
        guard name.count > 7 else { return "Unknown Model" }
        let code = String(name[name.index(name.startIndex, offsetBy: 7)]).uppercased()
        switch code {
        case "A": return "SG Timer Sport"
        case "B": return "SG Timer GO"
        default:  return "Unknown Model"
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard peripheral.name?.hasPrefix(kNamePrefix) == true else { return }
        if !discovered.contains(where: { $0.identifier == peripheral.identifier }) {
            discovered.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        onEvent?(["type": "ERROR",
                  "message": "connect failed: \(error?.localizedDescription ?? "unknown")"])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier.uuidString == devAddr else { return }

        onEvent?([
            "type": "DEVICE_DISCONNECTED",
            "addr": devAddr, "name": devName,
            "model": devModel, "api_version": apiVersion
        ])

        if !stopWatchdog {
            scheduleWatchdog()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else { return }
        peripheral.discoverCharacteristics([kEventUUID, kApiVersionUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == kApiVersionUUID {
                peripheral.readValue(for: char)
            } else if char.uuid == kEventUUID {
                // 0.5 s delay mirrors the Python asyncio.sleep(0.5)
                bleQueue.asyncAfter(deadline: .now() + 0.5) { [weak peripheral] in
                    peripheral?.setNotifyValue(true, for: char)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let bytes = [UInt8](data)

        if characteristic.uuid == kApiVersionUUID {
            apiVersion = String(bytes: bytes.filter { $0 >= 32 && $0 <= 126 },
                                encoding: .ascii) ?? "Unknown"
            onEvent?([
                "type": "DEVICE_CONNECTED",
                "addr": devAddr, "name": devName,
                "model": devModel, "api_version": apiVersion
            ])
            scheduleWatchdog()
        } else if characteristic.uuid == kEventUUID {
            parseEvent(bytes)
        }
    }

    // MARK: - BLE Event Parsing

    private func parseEvent(_ b: [UInt8]) {
        guard b.count >= 2 else { return }

        func u16(_ o: Int) -> Int { guard b.count > o + 1 else { return 0 }; return (Int(b[o]) << 8) | Int(b[o+1]) }
        func u32(_ o: Int) -> Int { guard b.count > o + 3 else { return 0 }; return (Int(b[o]) << 24) | (Int(b[o+1]) << 16) | (Int(b[o+2]) << 8) | Int(b[o+3]) }

        var msg: [String: Any] = ["addr": devAddr]

        switch b[1] {
        case 0x00:
            let id = u32(2)
            msg["type"] = "SESSION_STARTED"
            msg["sess_id"] = id > 0 ? id : Int(Date().timeIntervalSince1970)
            lastShotTime = nil

        case 0x01:
            msg["type"] = "SESSION_SUSPENDED"

        case 0x02:
            msg["type"] = "SESSION_RESUMED"

        case 0x03:
            msg["type"] = "SESSION_STOPPED"
            lastShotTime = nil

        case 0x04:
            let shotNum  = u16(6) + 1
            let shotMs   = u32(8)
            let shotTime = Double(shotMs) / 1000.0
            msg["type"] = "SHOT_DETECTED"
            msg["num"]  = shotNum
            msg["time"] = shotTime
            if let prev = lastShotTime { msg["split"] = shotTime - prev }
            lastShotTime = shotTime

        case 0x05:
            msg["type"] = "SESSION_SET_BEGIN"

        default:
            return
        }

        onEvent?(msg)
    }

    // MARK: - Watchdog

    private func scheduleWatchdog() {
        stopWatchdog = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchdogTimer?.invalidate()
            self.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.bleQueue.async { self?.checkConnection() }
            }
        }
    }

    private func checkConnection() {
        guard !stopWatchdog, let p = peripheral else { return }
        if p.state != .connected {
            onEvent?([
                "type": "WATCHDOG", "status": "disconnected",
                "addr": devAddr, "name": devName,
                "model": devModel, "api_version": apiVersion
            ])
            central.connect(p, options: nil)
        }
    }
}
