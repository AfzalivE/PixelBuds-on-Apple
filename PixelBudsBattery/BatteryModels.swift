import Foundation
import os

/// Diagnostic logging. Read with:
/// log stream --predicate 'subsystem == "com.example.PixelBudsBattery"' --level debug  (raw packets are debug level)
enum Log {
    static let subsystem = "com.example.PixelBudsBattery"
    static let advertisement = Logger(subsystem: subsystem, category: "advertisement")
    static let stream = Logger(subsystem: subsystem, category: "stream")
    static let gatt = Logger(subsystem: subsystem, category: "gatt")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let maestro = Logger(subsystem: subsystem, category: "maestro")
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

extension BatteryComponent: CustomStringConvertible {
    var description: String {
        (percent.map { "\($0)%" } ?? "?") + (isCharging ? "+" : "")
    }
}

extension BudsBatteryReport: CustomStringConvertible {
    var description: String {
        if let overall { return "\(source) overall=\(overall) name=\(deviceName ?? "-")" }
        return "\(source) L=\(left) R=\(right) C=\(caseBattery) mins=\(remainingMinutes.map(String.init) ?? "-") name=\(deviceName ?? "-") rssi=\(rssi.map(String.init) ?? "-")"
    }
}

/// The battery state of one component (left bud, right bud, or case).
struct BatteryComponent: Equatable, Sendable {
    /// Battery level from 0 to 100. `nil` means the device reports "unknown"
    /// (for example, a bud that is not in the case or is out of range).
    var percent: Int?
    var isCharging: Bool
    /// When this level was measured, if it is an older value kept from an earlier
    /// report (the current report said "unknown"). Nil means current.
    var asOf: Date?

    static let unknown = BatteryComponent(percent: nil, isCharging: false)

    init(percent: Int?, isCharging: Bool) {
        self.percent = percent
        self.isCharging = isCharging
    }

    /// Decodes one Fast Pair battery byte: `0bSVVVVVVV`.
    /// S = 1 when charging. V = level 0...100, or 0x7F when unknown.
    init(fastPairByte byte: UInt8) {
        let value = Int(byte & 0x7F)
        self.percent = (value == 0x7F || value > 100) ? nil : value
        self.isCharging = (byte & 0x80) != 0
    }
}

enum BatterySource: Sendable {
    /// Fast Pair Message Stream over a Bluetooth Classic RFCOMM channel (macOS only).
    case messageStream
    /// Standard BLE Battery Service (0x180F) of buds already connected to this device (iOS and macOS).
    /// Gives one overall level, not left/right/case.
    case gattBatteryService
    /// Battery field inside the Fast Pair BLE advertisement (iOS and macOS).
    case advertisement
    /// Google's proprietary Maestro protocol over RFCOMM (macOS only). Gives the case level.
    case maestro

    var label: String {
        switch self {
        case .messageStream: return "Fast Pair Message Stream"
        case .gattBatteryService: return "BLE Battery Service"
        case .advertisement: return "Fast Pair BLE advertisement"
        case .maestro: return "Maestro"
        }
    }
}

struct BudsBatteryReport: Equatable, Sendable {
    var left: BatteryComponent
    var right: BatteryComponent
    var caseBattery: BatteryComponent
    /// One overall level, set only when the source gives no left/right/case split
    /// (the BLE Battery Service). When set, show it instead of left/right/case.
    var overall: BatteryComponent?
    /// Remaining listening time in minutes, if the buds send it.
    var remainingMinutes: Int?
    var source: BatterySource
    var deviceName: String?
    var rssi: Int?
    var date: Date
    /// True when the buds are no longer connected and this is the last report
    /// they sent. The UI shows it as "last known", with its age.
    var isStale = false

    /// Builds a report from 1 to 3 Fast Pair battery bytes (left, right, case).
    init?(fastPairBytes bytes: [UInt8], source: BatterySource, deviceName: String? = nil, rssi: Int? = nil, date: Date = Date()) {
        guard !bytes.isEmpty else { return nil }
        let values = bytes.map(BatteryComponent.init(fastPairByte:))
        self.left = values[0]
        self.right = values.count > 1 ? values[1] : .unknown
        self.caseBattery = values.count > 2 ? values[2] : .unknown
        self.overall = nil
        self.remainingMinutes = nil
        self.source = source
        self.deviceName = deviceName
        self.rssi = rssi
        self.date = date
    }

    /// Builds a report from Maestro battery info.
    init(maestroLeft left: BatteryComponent, right: BatteryComponent, case caseBattery: BatteryComponent, deviceName: String?, date: Date = Date()) {
        self.left = left
        self.right = right
        self.caseBattery = caseBattery
        self.overall = nil
        self.remainingMinutes = nil
        self.source = .maestro
        self.deviceName = deviceName
        self.rssi = nil
        self.date = date
    }

    /// Builds a report from a GATT Battery Level (0x2A19) value: one byte, 0...100.
    init?(batteryLevelValue data: Data, deviceName: String?, date: Date = Date()) {
        guard let byte = data.first, byte <= 100 else { return nil }
        self.left = .unknown
        self.right = .unknown
        self.caseBattery = .unknown
        self.overall = BatteryComponent(percent: Int(byte), isCharging: false)
        self.remainingMinutes = nil
        self.source = .gattBatteryService
        self.deviceName = deviceName
        self.rssi = nil
        self.date = date
    }
}

/// Constants and parsers for the Google Fast Pair Service (GFPS).
/// Spec: https://developers.google.com/nearby/fast-pair/specifications/extensions/batterynotification
enum FastPair {
    /// 16-bit service UUID used for Fast Pair service data in BLE advertisements.
    static let serviceUUIDString = "FE2C"

    /// RFCOMM service UUID of the Fast Pair Message Stream.
    static let messageStreamUUID = UUID(uuidString: "DF21FE2C-2515-4FDB-8886-F12C4D67927C")!

    /// Field types in the "not discoverable" advertisement (low nibble of 0bLLLLTTTT).
    enum FieldType: UInt8 {
        case accountKeyFilterShowUI = 0x0
        case salt = 0x1
        case accountKeyFilterHideUI = 0x2
        case batteryShowUI = 0x3
        case batteryHideUI = 0x4
    }

    /// Returns the raw battery bytes (left, right, case) from 0xFE2C service data,
    /// or `nil` when the advertisement does not carry a battery field.
    ///
    /// Layout when not discoverable:
    ///   [0]        version and flags (0x00)
    ///   [1]        0bLLLLTTTT account key filter header, then L bytes
    ///   [..]       0b00100001 salt header, then 2 bytes (optional)
    ///   [..]       0bLLLLTTTT battery header (T = 3 or 4), then L battery bytes
    /// When discoverable, the service data is only the 3-byte model ID, without battery.
    ///
    /// The parse is strict: every field must have a known type and the fields must
    /// use up the payload exactly. Some buds (for example Pixel Buds Pro 2) add
    /// encrypted fields after the salt. Walking into those bytes as if they were
    /// headers can find a random "battery" header and give wrong levels.
    static func batteryBytes(fromServiceData data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count > 3 else { return nil }

        var battery: [UInt8]?
        var index = 1 // Skip the version and flags byte.
        while index < bytes.count {
            let header = bytes[index]
            let length = Int(header >> 4)
            let start = index + 1
            let end = start + length
            guard end <= bytes.count, let type = FieldType(rawValue: header & 0x0F) else { return nil }

            switch type {
            case .batteryShowUI, .batteryHideUI:
                guard (1...3).contains(length), battery == nil else { return nil }
                let values = Array(bytes[start..<end])
                // Each value is 0...100 or 0x7F (unknown), plus the charging bit.
                guard values.allSatisfy({ ($0 & 0x7F) <= 100 || ($0 & 0x7F) == 0x7F }) else { return nil }
                battery = values
            case .accountKeyFilterShowUI, .accountKeyFilterHideUI, .salt:
                break
            }
            index = end
        }
        return battery
    }
}

/// Splits the Message Stream byte stream into messages.
/// Header: group (1 byte), code (1 byte), payload length (2 bytes, big endian), then the payload.
struct MessageStreamParser {
    struct Message: Equatable {
        let group: UInt8
        let code: UInt8
        let payload: [UInt8]
    }

    enum Group {
        static let deviceInformation: UInt8 = 0x03
    }

    enum DeviceInformationCode {
        static let modelID: UInt8 = 0x01
        static let batteryUpdated: UInt8 = 0x03
        static let remainingBatteryTime: UInt8 = 0x04
    }

    private var buffer: [UInt8] = []

    mutating func reset() { buffer.removeAll() }

    mutating func append<S: Sequence>(_ data: S) -> [Message] where S.Element == UInt8 {
        buffer.append(contentsOf: data)
        var messages: [Message] = []
        while buffer.count >= 4 {
            let length = Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 4 + length else { break }
            messages.append(Message(group: buffer[0], code: buffer[1], payload: Array(buffer[4..<(4 + length)])))
            buffer.removeFirst(4 + length)
        }
        return messages
    }
}
