import Foundation
import WidgetKit

/// Sends the shown battery report to the widget.
enum WidgetBridge {
    private static var lastSnapshot: BatterySnapshot?
    private static var lastReload = Date.distantPast
    /// Reload the widget at most this often when only the time changes.
    private static let minimumInterval: TimeInterval = 60

    static func publish(_ report: BudsBatteryReport?) {
        let snapshot = report.map(BatterySnapshot.init(report:))
        // Reload at once when a level, the charging state or the connection state changes.
        // Otherwise wait, so that the app does not use up the widget reload budget.
        let levelsChanged = snapshot?.levelsDiffer(from: lastSnapshot) ?? (lastSnapshot != nil)
        guard levelsChanged || Date().timeIntervalSince(lastReload) > minimumInterval else { return }
        guard snapshot != lastSnapshot else { return }

        lastSnapshot = snapshot
        lastReload = Date()
        SharedBatteryStorage.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedBatteryStorage.widgetKind)
    }
}

private extension BatterySnapshot.Part {
    init(_ component: BatteryComponent) {
        self.init(percent: component.percent, isCharging: component.isCharging, asOf: component.asOf)
    }
}

extension BatterySnapshot {
    init(report: BudsBatteryReport) {
        self.init(
            left: Part(report.left),
            right: Part(report.right),
            caseBattery: Part(report.caseBattery),
            overall: report.overall.map(Part.init),
            deviceName: report.deviceName,
            date: report.date,
            isStale: report.isStale
        )
    }

    /// True when anything other than the times is different.
    func levelsDiffer(from other: BatterySnapshot?) -> Bool {
        guard let other else { return true }
        func strip(_ part: Part?) -> Part? { part.map { Part(percent: $0.percent, isCharging: $0.isCharging, asOf: nil) } }
        return strip(left) != strip(other.left)
            || strip(right) != strip(other.right)
            || strip(caseBattery) != strip(other.caseBattery)
            || strip(overall) != strip(other.overall)
            || isStale != other.isStale
            || deviceName != other.deviceName
    }
}
