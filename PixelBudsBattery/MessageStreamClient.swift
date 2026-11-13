#if os(macOS)
import Foundation
import IOBluetooth
import os

/// Connects to the Fast Pair Message Stream (RFCOMM) of paired buds that are
/// connected to this Mac. The buds send a "battery updated" message
/// (group 0x03, code 0x03) when the stream opens and each time a level changes.
///
/// macOS only: iOS does not let apps open RFCOMM channels to non-MFi accessories.
final class MessageStreamClient: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var onReport: ((BudsBatteryReport) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    /// Battery from the Maestro channel, opened next to the Fast Pair stream.
    var onMaestroReport: ((BudsBatteryReport) -> Void)?

    private lazy var maestro: MaestroClient = {
        let client = MaestroClient()
        client.onReport = { [weak self] report in
            self?.onMaestroReport?(report)
            self?.scheduleAutoSettle()
        }
        return client
    }()

    private(set) var isConnected = false
    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var parser = MessageStreamParser()
    private var lastReport: BudsBatteryReport?
    private var isOpening = false

    // Auto-connect state. See autoConnectIfNeeded().
    /// The device whose baseband connection this app opened. Nil when not auto-connecting.
    private var autoDevice: IOBluetoothDevice?
    private var lastAutoAttempt: Date?
    private var autoFinishedAt: Date?
    private var autoSettleWork: DispatchWorkItem?
    private var autoTimeoutWork: DispatchWorkItem?
    /// Minimum time between two auto-connect attempts.
    private let autoCooldown: TimeInterval = 2 * 60
    /// Longest time an auto-connection stays open.
    private let autoMaxDuration: TimeInterval = 30
    /// Time to wait after the last battery message before closing.
    private let autoSettleTime: TimeInterval = 2
    /// Page timeout in 0.625 ms slots (8000 = 5 s).
    private let autoPageTimeout: BluetoothHCIPageTimeout = 8000

    private static let sdpUUID: IOBluetoothSDPUUID = {
        var uuid = FastPair.messageStreamUUID.uuid
        return withUnsafeBytes(of: &uuid) { raw in
            IOBluetoothSDPUUID(bytes: raw.baseAddress!, length: 16)
        }
    }()

    /// Tries to open the stream. Safe to call again while connected.
    func connect() {
        guard channel == nil, !isOpening, autoDevice == nil else { return }
        // Right after an auto-connection closes, the baseband link can still look
        // connected for a moment. Do not reopen the stream on it.
        if let autoFinishedAt, Date().timeIntervalSince(autoFinishedAt) < 10 { return }

        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let connected = paired.filter { $0.isConnected() }
        guard !connected.isEmpty else {
            onStatus?("No paired Bluetooth device is connected to this Mac.")
            return
        }

        // First use the SDP records that macOS has in its cache.
        for candidate in connected {
            if let record = candidate.getServiceRecord(for: Self.sdpUUID) {
                open(record: record, on: candidate)
                return
            }
        }

        // No cached record. Ask the likely devices for their services again.
        let likely = connected.filter { ($0.name ?? "").localizedCaseInsensitiveContains("buds") }
        for candidate in (likely.isEmpty ? connected : likely) {
            candidate.performSDPQuery(self, uuids: [Self.sdpUUID])
        }
        onStatus?("Looking for the Fast Pair service on connected devices.")
    }

    func disconnect() {
        maestro.close()
        if autoDevice != nil {
            finishAutoConnect(reason: "refresh")
            return
        }
        channel?.close()
        channel = nil
        device = nil
        isConnected = false
        isOpening = false
    }

    // MARK: Auto-connect

    /// When paired buds are near but not connected to this Mac (for example the
    /// case lid just opened), opens a baseband connection to them, reads the
    /// battery over the Message Stream, then closes the connection again so the
    /// buds can go back to the phone. Only the RFCOMM channel is opened, no audio.
    func autoConnectIfNeeded(rssi: Int) {
        guard channel == nil, !isOpening, autoDevice == nil else { return }
        if let lastAutoAttempt, Date().timeIntervalSince(lastAutoAttempt) < autoCooldown { return }

        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let candidates = paired.filter(isFastPairCandidate)
        // Connected normally: connect() reads them, nothing to do here.
        guard !candidates.contains(where: { $0.isConnected() }) else { return }
        // The advertisement uses a random address, so we cannot tell which buds
        // sent it. Only try when there is exactly one possible target.
        guard candidates.count == 1, let target = candidates.first else {
            lastAutoAttempt = Date()
            Log.stream.info("auto-connect skipped: \(candidates.count) paired Fast Pair devices")
            return
        }

        lastAutoAttempt = Date()
        autoDevice = target
        isOpening = true
        Log.stream.info("auto-connect: ad rssi=\(rssi), paging \(target.name ?? "-", privacy: .public)")
        onStatus?("Buds nearby. Connecting to \(target.name ?? "buds") to read the battery...")
        let result = target.openConnection(self, withPageTimeout: autoPageTimeout, authenticationRequired: false)
        if result != kIOReturnSuccess {
            Log.stream.error("auto-connect: openConnection failed \(result)")
            isOpening = false
            autoDevice = nil
            return
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finishAutoConnect(reason: "timeout") }
        autoTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + autoMaxDuration, execute: timeout)
        pollAutoConnection(target)
    }

    /// Backup for connectionComplete(_:status:): checks once a second whether the
    /// baseband link came up, and opens the stream if so.
    private func pollAutoConnection(_ target: IOBluetoothDevice) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.autoDevice == target, self.isOpening else { return }
            if target.isConnected() {
                Log.stream.info("auto-connect: link is up (seen by polling)")
                self.connectionComplete(target, status: kIOReturnSuccess)
            } else {
                self.pollAutoConnection(target)
            }
        }
    }

    private func isFastPairCandidate(_ device: IOBluetoothDevice) -> Bool {
        device.getServiceRecord(for: Self.sdpUUID) != nil
            || (device.name ?? "").localizedCaseInsensitiveContains("Pixel Buds")
    }

    // Called by IOBluetooth after openConnection(_:withPageTimeout:authenticationRequired:).
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        // Polling and IOBluetooth can both report the link. Handle it once.
        guard let device, device == autoDevice, channel == nil, isOpening else { return }
        isOpening = false
        Log.stream.info("auto-connect: baseband status=\(status)")
        guard status == kIOReturnSuccess else {
            finishAutoConnect(reason: "page failed (\(status))")
            return
        }
        if let record = device.getServiceRecord(for: Self.sdpUUID) {
            open(record: record, on: device)
        } else {
            device.performSDPQuery(self, uuids: [Self.sdpUUID])
        }
    }

    /// Closes the channel and the baseband connection that auto-connect opened.
    private func finishAutoConnect(reason: String) {
        guard let autoDevice else { return }
        Log.stream.info("auto-connect: closing (\(reason, privacy: .public))")
        autoSettleWork?.cancel()
        autoTimeoutWork?.cancel()
        autoSettleWork = nil
        autoTimeoutWork = nil
        self.autoDevice = nil
        autoFinishedAt = Date()
        let hadChannel = channel != nil
        maestro.close()
        channel?.close()
        channel = nil
        device = nil
        isConnected = false
        isOpening = false
        autoDevice.closeConnection()
        if hadChannel { onDisconnect?() }
    }

    /// After a battery message during auto-connect, wait for more, then close.
    private func scheduleAutoSettle() {
        guard autoDevice != nil else { return }
        autoSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Give the Maestro channel time to send the case level.
            if self.maestro.isPending {
                self.scheduleAutoSettle()
            } else {
                self.finishAutoConnect(reason: "battery read")
            }
        }
        autoSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoSettleTime, execute: work)
    }

    // Called by IOBluetooth after performSDPQuery(_:uuids:).
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard status == kIOReturnSuccess, channel == nil, !isOpening,
              let device, let record = device.getServiceRecord(for: Self.sdpUUID)
        else { return }
        open(record: record, on: device)
    }

    private func open(record: IOBluetoothSDPServiceRecord, on device: IOBluetoothDevice) {
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            onStatus?("\(device.name ?? "Device") has the Fast Pair service, but no RFCOMM channel.")
            return
        }

        var newChannel: IOBluetoothRFCOMMChannel?
        isOpening = true
        let result = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
        guard result == kIOReturnSuccess, let newChannel else {
            isOpening = false
            onStatus?("Could not open the Fast Pair channel (error \(result)).")
            return
        }
        self.channel = newChannel
        self.device = device
        parser.reset()
        onStatus?("Connecting to \(device.name ?? "device")...")
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        isOpening = false
        Log.stream.info("channel open status=\(error) device=\(self.device?.name ?? "-", privacy: .public)")
        if error == kIOReturnSuccess {
            isConnected = true
            if let device { maestro.open(on: device) }
            onStatus?("Connected to \(device?.name ?? "device"). Waiting for battery data.")
        } else {
            onStatus?("Could not open the Fast Pair channel (error \(error)).")
            channel = nil
            device = nil
            onDisconnect?()
            finishAutoConnect(reason: "channel open failed")
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
        for message in parser.append(bytes) {
            handle(message)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Log.stream.info("channel closed")
        maestro.close()
        channel = nil
        isConnected = false
        isOpening = false
        onStatus?("The Fast Pair channel closed.")
        onDisconnect?()
        finishAutoConnect(reason: "channel closed by buds")
    }

    private func handle(_ message: MessageStreamParser.Message) {
        Log.stream.debug("message group=\(String(format: "%02x", message.group), privacy: .public) code=\(String(format: "%02x", message.code), privacy: .public) payload=\(message.payload.hex, privacy: .public)")
        guard message.group == MessageStreamParser.Group.deviceInformation else { return }

        switch message.code {
        case MessageStreamParser.DeviceInformationCode.batteryUpdated:
            guard var report = BudsBatteryReport(
                fastPairBytes: Array(message.payload.prefix(3)),
                source: .messageStream,
                deviceName: device?.name
            ) else { return }
            report.remainingMinutes = lastReport?.remainingMinutes
            lastReport = report
            onReport?(report)
            scheduleAutoSettle()

        case MessageStreamParser.DeviceInformationCode.remainingBatteryTime:
            let minutes = message.payload.reduce(0) { ($0 << 8) | Int($1) }
            if var report = lastReport {
                report.remainingMinutes = minutes
                report.date = Date()
                lastReport = report
                onReport?(report)
                scheduleAutoSettle()
            }

        default:
            break
        }
    }
}
#endif
