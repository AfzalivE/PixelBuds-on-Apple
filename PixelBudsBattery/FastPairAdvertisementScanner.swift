import CoreBluetooth
import Foundation

/// Scans for Fast Pair BLE advertisements (service data 0xFE2C) and reads the
/// battery field. Works on iOS and macOS. All callbacks run on the main queue.
///
/// Note: the buds put the battery field in the advertisement only at some times
/// (for example, when you open the case lid). At other times you get no data.
final class FastPairAdvertisementScanner: NSObject, CBCentralManagerDelegate {
    var onReport: ((UUID, BudsBatteryReport) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Called for every Fast Pair advertisement, with or without battery. Gives the RSSI.
    var onFastPairAdvertisement: ((Int) -> Void)?

    private var central: CBCentralManager?
    private let serviceUUID = CBUUID(string: FastPair.serviceUUIDString)
    private var wantsScan = false
    private var lastPayload: [UUID: Data] = [:]

    func start() {
        wantsScan = true
        if let central {
            if central.state == .poweredOn { beginScan() }
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        wantsScan = false
        central?.stopScan()
    }

    private func beginScan() {
        // Scan without a service filter and match 0xFE2C service data below.
        // A filter only matches UUIDs in the advertised service list, which the
        // "not discoverable" Fast Pair advertisement may not include.
        central?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        onStatus?("Scanning for Fast Pair advertisements. Open the case lid near this device.")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsScan { beginScan() }
        case .poweredOff:
            onStatus?("Bluetooth is off.")
        case .unauthorized:
            onStatus?("Bluetooth access is not allowed. Allow it in Settings.")
        case .unsupported:
            onStatus?("This device does not support Bluetooth LE.")
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
            let data = serviceData[serviceUUID]
        else { return }

        onFastPairAdvertisement?(RSSI.intValue)

        let id = peripheral.identifier
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let parsed = FastPair.batteryBytes(fromServiceData: data)
        if lastPayload[id] != data {
            lastPayload[id] = data
            let uuids = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(\.uuidString).joined(separator: ",")
            Log.advertisement.debug("FE2C id=\(id.uuidString, privacy: .public) name=\(name ?? "-", privacy: .public) rssi=\(RSSI.intValue) uuids=[\(uuids, privacy: .public)] data=\([UInt8](data).hex, privacy: .public) battery=\(parsed?.hex ?? "none", privacy: .public)")
        }

        guard
            let bytes = parsed,
            let report = BudsBatteryReport(
                fastPairBytes: bytes,
                source: .advertisement,
                deviceName: name,
                rssi: RSSI.intValue
            )
        else { return }

        onReport?(peripheral.identifier, report)
    }
}
