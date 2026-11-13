import Foundation
import Observation
import os

/// Collects battery reports from all sources and picks the best one to show.
/// All updates happen on the main thread (CoreBluetooth and IOBluetooth
/// deliver callbacks there).
@Observable
final class BatteryStore {
    private(set) var report: BudsBatteryReport?
    private(set) var status = "Starting..."

    /// An advertisement report older than this is not shown.
    private let advertisementLifetime: TimeInterval = 10 * 60

    private let scanner = FastPairAdvertisementScanner()
    private let gattClient = GATTBatteryClient()
    private var advertisementReports: [UUID: BudsBatteryReport] = [:]
    private var gattReports: [UUID: BudsBatteryReport] = [:]
    private var streamReport: BudsBatteryReport?
    /// The last Message Stream report, kept after the buds disconnect.
    private var lastStreamReport: BudsBatteryReport?
    /// How long the last known Message Stream levels are shown after a disconnect.
    private let lastKnownLifetime: TimeInterval = 6 * 60 * 60

    /// Last known level of each part, from any live report, with when it was measured.
    /// Used to fill in parts that a later report says are unknown (the case often is).
    private var lastKnown: [Part: (component: BatteryComponent, date: Date)] = [:]
    private enum Part { case left, right, caseBattery }
    private var started = false

    #if os(macOS)
    private let streamClient = MessageStreamClient()
    private var retryTimer: Timer?

    private static let autoConnectKey = "readBatteryWhenCaseOpens"
    /// Briefly connect to nearby buds to read the battery ("Read battery when the case opens").
    var autoConnectEnabled: Bool = UserDefaults.standard.object(forKey: BatteryStore.autoConnectKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnectEnabled, forKey: Self.autoConnectKey) }
    }
    /// Only advertisements stronger than this start an auto-connection.
    private let autoConnectMinRSSI = -75
    #endif

    func start() {
        guard !started else { return }
        started = true

        scanner.onStatus = { [weak self] text in self?.setStatus(text, from: .advertisement) }
        scanner.onReport = { [weak self] id, report in
            self?.advertisementReports[id] = report
            self?.refreshReport()
        }
        #if os(macOS)
        scanner.onFastPairAdvertisement = { [weak self] rssi in
            guard let self, self.autoConnectEnabled, rssi > self.autoConnectMinRSSI else { return }
            self.streamClient.autoConnectIfNeeded(rssi: rssi)
        }
        #endif
        scanner.start()

        gattClient.onStatus = { [weak self] text in self?.setStatus(text, from: .gattBatteryService) }
        gattClient.onReport = { [weak self] id, report in
            self?.gattReports[id] = report
            self?.refreshReport()
        }
        gattClient.onDisconnect = { [weak self] id in
            self?.gattReports[id] = nil
            self?.refreshReport()
        }
        gattClient.start()

        #if os(macOS)
        streamClient.onStatus = { [weak self] text in self?.setStatus(text, from: .messageStream) }
        streamClient.onReport = { [weak self] report in
            self?.streamReport = report
            self?.lastStreamReport = report
            self?.refreshReport()
        }
        streamClient.onMaestroReport = { [weak self] report in
            self?.remember(report)
            self?.refreshReport()
        }
        streamClient.onDisconnect = { [weak self] in
            self?.streamReport = nil
            self?.refreshReport()
        }
        streamClient.connect()
        // Try again when the buds connect later or the channel closes.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.streamClient.connect()
            self?.refreshReport()
        }
        #endif
    }

    /// Restarts the scan and the stream connection.
    func refresh() {
        scanner.stop()
        scanner.start()
        gattClient.stop()
        gattReports.removeAll()
        gattClient.start()
        #if os(macOS)
        streamClient.disconnect()
        streamReport = nil
        streamClient.connect()
        #endif
        refreshReport()
    }

    /// Short text for the macOS menu bar, for example "L 80 · R 75 · C 40".
    var menuBarTitle: String {
        guard let report, !report.isStale else { return "Buds --" }
        if let overall = report.overall {
            return "Buds \(overall.percent.map(String.init) ?? "--")"
        }
        func text(_ component: BatteryComponent) -> String {
            component.percent.map(String.init) ?? "--"
        }
        return "L \(text(report.left)) · R \(text(report.right)) · C \(text(report.caseBattery))"
    }

    private func setStatus(_ text: String, from source: BatterySource) {
        // Keep the status of the best live source in front:
        // message stream, then GATT, then advertisements.
        #if os(macOS)
        if source != .messageStream, streamClient.isConnected { return }
        #endif
        if source == .advertisement, !gattReports.isEmpty { return }
        status = text
    }

    private func refreshReport() {
        let previous = report
        pickReport()
        if let current = report {
            if !current.isStale { remember(current) }
            report = fillUnknownParts(of: current)
        }
        if report != previous {
            Log.store.info("showing \(self.report.map { "\($0)" } ?? "nothing", privacy: .public) (stream=\(self.streamReport != nil) gatt=\(self.gattReports.count) ads=\(self.advertisementReports.count))")
        }
    }

    /// Stores every known part of a live report.
    private func remember(_ report: BudsBatteryReport) {
        guard report.overall == nil else { return }
        let parts: [(Part, BatteryComponent)] = [(.left, report.left), (.right, report.right), (.caseBattery, report.caseBattery)]
        for (part, component) in parts where component.percent != nil {
            var stored = component
            stored.asOf = nil
            // Keep the newest value. Two sources can report at the same time.
            if let existing = lastKnown[part], existing.date > report.date { continue }
            lastKnown[part] = (stored, report.date)
        }
    }

    /// Replaces "unknown" parts with the last known level, marked with its age.
    private func fillUnknownParts(of report: BudsBatteryReport) -> BudsBatteryReport {
        guard report.overall == nil else { return report }
        var filled = report
        let now = Date()
        func fill(_ component: inout BatteryComponent, _ part: Part) {
            guard let known = lastKnown[part], now.timeIntervalSince(known.date) < lastKnownLifetime else { return }
            if component.percent == nil {
                let charging = component.isCharging
                component = known.component
                component.asOf = known.date
                // The current report still knows whether the part is charging.
                if report.source == .messageStream { component.isCharging = charging }
            } else if report.isStale {
                component.asOf = report.date
            }
        }
        fill(&filled.left, .left)
        fill(&filled.right, .right)
        fill(&filled.caseBattery, .caseBattery)
        return filled
    }

    private func pickReport() {
        if let streamReport {
            report = streamReport
            return
        }
        if let gattReport = gattReports.values.max(by: { $0.date < $1.date }) {
            report = gattReport
            return
        }
        let now = Date()
        advertisementReports = advertisementReports.filter { now.timeIntervalSince($0.value.date) < advertisementLifetime }
        // Recent reports first, then the strongest signal (the buds nearest to you).
        report = advertisementReports.values.max { a, b in
            let aRecent = now.timeIntervalSince(a.date) < 30
            let bRecent = now.timeIntervalSince(b.date) < 30
            if aRecent != bRecent { return !aRecent }
            return (a.rssi ?? -127) < (b.rssi ?? -127)
        }
        if report != nil { return }

        // Nothing live. Show the last levels the buds sent, marked as old.
        if var last = lastStreamReport, now.timeIntervalSince(last.date) < lastKnownLifetime {
            last.isStale = true
            report = last
        }
    }
}
