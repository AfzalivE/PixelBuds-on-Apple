#if os(macOS)
import Foundation
import IOBluetooth
import os

/// Minimal client for Google's proprietary "Maestro" protocol on Pixel Buds,
/// used only to read battery levels (including the case, which the Fast Pair
/// Message Stream often reports as unknown).
///
/// Protocol (from the open-source pbpctrl project, github.com/qzed/pbpctrl):
/// - RFCOMM service UUID 25e97ff7-24ce-4c4c-8951-f764a708f7b5.
/// - HDLC U-frames: 0x7E flag, varint address, control 0x03, data, CRC-32 (LE), 0x7E flag.
///   0x7D/0x7E in the body are escaped as 0x7D, byte ^ 0x20.
/// - The data is a pigweed RPC packet (protobuf). We call the server-streaming
///   method maestro_pw.Maestro/SubscribeRuntimeInfo. Its RuntimeInfo message
///   has battery_info (field 6) with case (1), left (2), right (3), each
///   { level (1), state (2): 1 = not charging, 2 = charging }.
/// - The case level is known only while at least one bud is in the case.
final class MaestroClient: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var onReport: ((BudsBatteryReport) -> Void)?

    /// True from open() until a battery report arrives or the attempt gives up.
    private(set) var isPending = false

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var buffer: [UInt8] = []
    private var giveUpWork: DispatchWorkItem?

    static let serviceUUID = UUID(uuidString: "25E97FF7-24CE-4C4C-8951-F764A708F7B5")!

    private static let sdpUUID: IOBluetoothSDPUUID = {
        var uuid = MaestroClient.serviceUUID.uuid
        return withUnsafeBytes(of: &uuid) { raw in
            IOBluetoothSDPUUID(bytes: raw.baseAddress!, length: 16)
        }
    }()

    /// RPC channels to try. The buds answer on the one that matches their role
    /// (MaestroA/B talking to the case or a bud), see pbpctrl protocol/addr.rs.
    private static let candidateChannels: [UInt32] = [18, 19, 21, 23, 24, 26]
    private static let serviceID = pwHash("maestro_pw.Maestro")
    private static let subscribeRuntimeInfoID = pwHash("SubscribeRuntimeInfo")
    private static let callID: UInt32 = 1

    /// Opens the Maestro channel on a device that already has a baseband connection.
    func open(on device: IOBluetoothDevice) {
        guard channel == nil else { return }
        guard let record = device.getServiceRecord(for: Self.sdpUUID) else {
            Log.maestro.info("no cached Maestro SDP record on \(device.name ?? "-", privacy: .public); querying")
            isPending = true
            device.performSDPQuery(self, uuids: [Self.sdpUUID])
            scheduleGiveUp()
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            Log.maestro.info("Maestro record has no RFCOMM channel")
            return
        }
        var newChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
        guard result == kIOReturnSuccess, let newChannel else {
            Log.maestro.error("could not open Maestro channel: \(result)")
            return
        }
        Log.maestro.info("opening Maestro channel \(channelID) on \(device.name ?? "-", privacy: .public)")
        self.channel = newChannel
        self.device = device
        buffer.removeAll()
        isPending = true
        scheduleGiveUp()
    }

    func close() {
        giveUpWork?.cancel()
        giveUpWork = nil
        isPending = false
        channel?.close()
        channel = nil
        device = nil
    }

    private func scheduleGiveUp() {
        giveUpWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPending else { return }
            Log.maestro.info("no Maestro battery info in time; giving up")
            self.isPending = false
        }
        giveUpWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let device, channel == nil, device.getServiceRecord(for: Self.sdpUUID) != nil else {
            Log.maestro.info("Maestro SDP query found nothing (status \(status))")
            isPending = false
            return
        }
        open(on: device)
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        Log.maestro.info("Maestro channel open status=\(error)")
        guard error == kIOReturnSuccess, let rfcommChannel else {
            channel = nil
            isPending = false
            return
        }
        for rpcChannel in Self.candidateChannels {
            var frame = Self.frame(for: Self.subscribeRequest(rpcChannel: rpcChannel), rpcChannel: rpcChannel)
            let result = frame.withUnsafeMutableBytes { raw in
                rfcommChannel.writeAsync(raw.baseAddress, length: UInt16(raw.count), refcon: nil)
            }
            if result != kIOReturnSuccess {
                Log.maestro.error("write to RPC channel \(rpcChannel) failed: \(result)")
            }
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        buffer.append(contentsOf: UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        while let frame = Self.nextFrame(from: &buffer) {
            handle(frame: frame)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Log.maestro.info("Maestro channel closed")
        channel = nil
        isPending = false
    }

    private func handle(frame: [UInt8]) {
        // frame = varint address, control, data (CRC already checked and removed).
        guard let (_, addressLength) = Self.decodeHDLCVarint(frame), frame.count > addressLength,
              frame[addressLength] == 0x03 else { return }
        let packet = Array(frame[(addressLength + 1)...])
        let fields = Protobuf.fields(packet)
        let type = fields.varint(1) ?? 0
        let status = fields.varint(6) ?? 0
        let rpcChannel = fields.varint(2) ?? 0
        Log.maestro.debug("rpc packet type=\(type) channel=\(rpcChannel) status=\(status) payload=\(fields.bytes(5)?.hex ?? "-", privacy: .public)")

        // 7 = SERVER_STREAM, 1 = RESPONSE.
        guard type == 7 || type == 1, status == 0, let payload = fields.bytes(5) else { return }
        guard let batteryInfo = Protobuf.fields(payload).bytes(6) else { return }
        let battery = Protobuf.fields(batteryInfo)

        func component(_ field: Int) -> BatteryComponent {
            guard let data = battery.bytes(field) else { return .unknown }
            let info = Protobuf.fields(data)
            let level = Int(info.varint(1) ?? 0)
            let state = info.varint(2) ?? 0
            guard state != 0, (0...100).contains(level) else { return .unknown }
            return BatteryComponent(percent: level, isCharging: state == 2)
        }

        var report = BudsBatteryReport(maestroLeft: component(2), right: component(3), case: component(1), deviceName: device?.name)
        report.date = Date()
        Log.maestro.info("battery from Maestro: \(report.description, privacy: .public)")
        isPending = false
        giveUpWork?.cancel()
        onReport?(report)
    }

    // MARK: Encoding

    /// pigweed RPC packet: REQUEST for SubscribeRuntimeInfo with an empty payload.
    static func subscribeRequest(rpcChannel: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        Protobuf.appendVarint(field: 1, value: 0, to: &out)            // type = REQUEST
        Protobuf.appendVarint(field: 2, value: UInt64(rpcChannel), to: &out)
        Protobuf.appendFixed32(field: 3, value: serviceID, to: &out)
        Protobuf.appendFixed32(field: 4, value: subscribeRuntimeInfoID, to: &out)
        Protobuf.appendVarint(field: 7, value: UInt64(callID), to: &out)
        return out
    }

    /// Address for an RPC channel: source peer << 6 | target peer << 10 (pbpctrl addr.rs).
    private static func address(rpcChannel: UInt32) -> UInt32 {
        let (source, target): (UInt32, UInt32)
        switch rpcChannel {
        case 18: (source, target) = (10, 2)
        case 19: (source, target) = (10, 3)
        case 21: (source, target) = (10, 4)
        case 23: (source, target) = (13, 2)
        case 24: (source, target) = (13, 3)
        default: (source, target) = (13, 4) // 26
        }
        return (source & 0xF) << 6 | (target & 0xF) << 10
    }

    static func frame(for packet: [UInt8], rpcChannel: UInt32) -> [UInt8] {
        var body: [UInt8] = []
        // HDLC address varint: 7 bits per byte, shifted left by 1; the last byte has bit 0 set.
        var value = address(rpcChannel: rpcChannel)
        while value >> 7 != 0 {
            body.append(UInt8(value & 0x7F) << 1)
            value >>= 7
        }
        body.append(UInt8(value & 0x7F) << 1 | 1)
        body.append(0x03)
        body.append(contentsOf: packet)
        let crc = crc32(body)
        body.append(contentsOf: [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)])

        var out: [UInt8] = [0x7E]
        for byte in body {
            if byte == 0x7E || byte == 0x7D {
                out.append(0x7D)
                out.append(byte ^ 0x20)
            } else {
                out.append(byte)
            }
        }
        out.append(0x7E)
        return out
    }

    // MARK: Decoding

    /// Takes the next complete HDLC frame out of the buffer, unescaped and with
    /// a valid CRC, without the CRC bytes. Drops frames with a bad CRC.
    static func nextFrame(from buffer: inout [UInt8]) -> [UInt8]? {
        while true {
            guard let start = buffer.firstIndex(of: 0x7E) else { buffer.removeAll(); return nil }
            if start > 0 { buffer.removeFirst(start) }
            guard let end = buffer.dropFirst().firstIndex(of: 0x7E) else { return nil }
            let raw = buffer[1..<end]
            buffer.removeFirst(end) // Keep the closing flag; it can open the next frame.
            if raw.isEmpty { continue }

            var frame: [UInt8] = []
            var escape = false
            for byte in raw {
                if escape { frame.append(byte ^ 0x20); escape = false }
                else if byte == 0x7D { escape = true }
                else { frame.append(byte) }
            }
            guard frame.count > 4 else { continue }
            let body = Array(frame.dropLast(4))
            let tail = frame.suffix(4).map(UInt32.init)
            let received = tail[0] | tail[1] << 8 | tail[2] << 16 | tail[3] << 24
            guard crc32(body) == received else {
                Log.maestro.debug("dropping HDLC frame with bad CRC")
                continue
            }
            return body
        }
    }

    private static func decodeHDLCVarint(_ bytes: [UInt8]) -> (UInt32, Int)? {
        var value: UInt64 = 0
        for (i, b) in bytes.prefix(5).enumerated() {
            value |= UInt64(b >> 1) << (7 * UInt64(i))
            if b & 1 == 1 { return (UInt32(truncatingIfNeeded: value), i + 1) }
        }
        return nil
    }

    // MARK: Hashes

    /// pigweed's 65599 string hash for service and method names.
    static func pwHash(_ name: String) -> UInt32 {
        var hash = UInt32(truncatingIfNeeded: name.unicodeScalars.count)
        var coef: UInt32 = 65599
        for scalar in name.unicodeScalars {
            hash = hash &+ coef &* scalar.value
            coef = coef &* 65599
        }
        return hash
    }

    /// Standard CRC-32 (IEEE, reflected, init and final XOR 0xFFFFFFFF).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

/// Just enough protobuf to read and write the few fields above.
enum Protobuf {
    struct Fields {
        var varints: [Int: UInt64] = [:]
        var blobs: [Int: [UInt8]] = [:]
        func varint(_ field: Int) -> UInt64? { varints[field] }
        func bytes(_ field: Int) -> [UInt8]? { blobs[field] }
    }

    static func fields(_ bytes: [UInt8]) -> Fields {
        var result = Fields()
        var i = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let b = bytes[i]; i += 1
                value |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let key = readVarint() else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return result }
                result.varints[field] = v
            case 1:
                guard i + 8 <= bytes.count else { return result }
                i += 8
            case 2:
                guard let len = readVarint(), i + Int(len) <= bytes.count else { return result }
                result.blobs[field] = Array(bytes[i..<(i + Int(len))])
                i += Int(len)
            case 5:
                guard i + 4 <= bytes.count else { return result }
                let v = UInt64(bytes[i]) | UInt64(bytes[i + 1]) << 8 | UInt64(bytes[i + 2]) << 16 | UInt64(bytes[i + 3]) << 24
                result.varints[field] = v
                i += 4
            default:
                return result
            }
        }
        return result
    }

    static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    static func appendVarint(field: Int, value: UInt64, to out: inout [UInt8]) {
        appendVarint(UInt64(field << 3), to: &out)
        appendVarint(value, to: &out)
    }

    static func appendFixed32(field: Int, value: UInt32, to out: inout [UInt8]) {
        appendVarint(UInt64(field << 3 | 5), to: &out)
        out.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}
#endif
