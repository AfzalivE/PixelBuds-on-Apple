import CoreBluetooth
import Foundation
import os

/// Reads the standard BLE Battery Service (0x180F, Battery Level 0x2A19) of
/// buds that are already connected to this device. Works on iOS and macOS.
/// All callbacks run on the main queue.
///
/// Not all buds expose this service. When they do, it gives one overall level.
final class GATTBatteryClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onReport: ((UUID, BudsBatteryReport) -> Void)?
    var onDisconnect: ((UUID) -> Void)?
    var onStatus: ((String) -> Void)?

    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelUUID = CBUUID(string: "2A19")
    private static let fastPairServiceUUID = CBUUID(string: FastPair.serviceUUIDString)

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pollTimer: Timer?
    private var wantsRun = false

    func start() {
        wantsRun = true
        if let central {
            if central.state == .poweredOn { beginPolling() }
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        wantsRun = false
        pollTimer?.invalidate()
        pollTimer = nil
        for peripheral in peripherals.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripherals.removeAll()
    }

    private func beginPolling() {
        poll()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Looks for connected peripherals and connects to new ones.
    private func poll() {
        guard let central, central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(
            withServices: [Self.batteryServiceUUID, Self.fastPairServiceUUID]
        )
        for peripheral in connected where peripherals[peripheral.identifier] == nil {
            Log.gatt.info("connected peripheral id=\(peripheral.identifier.uuidString, privacy: .public) name=\(peripheral.name ?? "-", privacy: .public)")
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if wantsRun { beginPolling() }
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            for id in peripherals.keys { onDisconnect?(id) }
            peripherals.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
        onDisconnect?(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.gatt.info("disconnected id=\(peripheral.identifier.uuidString, privacy: .public)")
        peripherals[peripheral.identifier] = nil
        onDisconnect?(peripheral.identifier)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryServiceUUID }) else {
            // Connected, but no Battery Service. Keep the reference so we do not reconnect every poll.
            return
        }
        peripheral.discoverCharacteristics([Self.batteryLevelUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.batteryLevelUUID }) else { return }
        peripheral.readValue(for: characteristic)
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        onStatus?("Reading the battery of \(peripheral.name ?? "connected buds") over BLE.")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Log.gatt.info("2A19 id=\(peripheral.identifier.uuidString, privacy: .public) name=\(peripheral.name ?? "-", privacy: .public) value=\(characteristic.value.map { [UInt8]($0).hex } ?? "nil", privacy: .public) error=\(error?.localizedDescription ?? "-", privacy: .public)")
        guard characteristic.uuid == Self.batteryLevelUUID,
              error == nil,
              let value = characteristic.value,
              let report = BudsBatteryReport(batteryLevelValue: value, deviceName: peripheral.name)
        else { return }
        onReport?(peripheral.identifier, report)
    }
}
