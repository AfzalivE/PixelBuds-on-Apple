import Foundation

/// The battery levels that the app shares with the widget.
/// The app writes it to the App Group defaults. The widget reads it.
struct BatterySnapshot: Codable, Equatable {
    struct Part: Codable, Equatable {
        /// 0...100, or nil when unknown.
        var percent: Int?
        var isCharging: Bool
        /// Set when this level is older than the snapshot (a last known value).
        var asOf: Date?
    }

    var left: Part
    var right: Part
    var caseBattery: Part
    /// One overall level, set only when the source gives no left/right/case split.
    var overall: Part?
    var deviceName: String?
    /// When the levels were measured.
    var date: Date
    /// True when the buds are not connected and these are the last known levels.
    var isStale: Bool

    static let placeholder = BatterySnapshot(
        left: Part(percent: 80, isCharging: false),
        right: Part(percent: 75, isCharging: false),
        caseBattery: Part(percent: 45, isCharging: true),
        overall: nil,
        deviceName: "Pixel Buds",
        date: Date(),
        isStale: false
    )
}

/// Storage that the app and the widget share.
///
/// The App Group must be in the entitlements of the app and of the widget.
/// If you change the ID here, change it in all the .entitlements files too.
enum SharedBatteryStorage {
    static let appGroupID = "group.com.example.PixelBudsBattery"
    static let widgetKind = "PixelBudsBatteryWidget"
    private static let key = "batterySnapshot"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func load() -> BatterySnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BatterySnapshot.self, from: data)
    }

    static func save(_ snapshot: BatterySnapshot?) {
        guard let defaults else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
