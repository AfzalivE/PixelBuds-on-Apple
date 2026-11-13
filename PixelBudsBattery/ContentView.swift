import SwiftUI

struct ContentView: View {
    let store: BatteryStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    BatteryPanel(store: store)
                    LimitsNote()
                }
                .padding()
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Buds Battery")
            .toolbar {
                ToolbarItem {
                    Button {
                        store.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }
}

/// The three battery rows plus the source and status. Also used in the macOS menu bar.
struct BatteryPanel: View {
    let store: BatteryStore

    #if os(macOS)
    private static let emptyStateText = "Connect your buds to this Mac."
    #else
    private static let emptyStateText = "Open the case lid near this phone. iOS cannot read connected buds directly."
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let report = store.report {
                if let name = report.deviceName {
                    Text(name).font(.headline)
                }
                if report.isStale {
                    Text("Not connected. Last known levels:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Group {
                    if let overall = report.overall {
                        BatteryRow(title: "Buds", systemImage: "earbuds", component: overall)
                    } else {
                        BatteryRow(title: "Left bud", systemImage: "earbuds", component: report.left)
                        BatteryRow(title: "Right bud", systemImage: "earbuds", component: report.right)
                        BatteryRow(title: "Case", systemImage: "earbuds.case", component: report.caseBattery)
                    }
                }
                .opacity(report.isStale ? 0.5 : 1)

                if let minutes = report.remainingMinutes, !report.isStale {
                    Text("About \(minutes / 60) h \(minutes % 60) min of listening time left")
                        .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Source: \(report.source.label)")
                    Text("Updated \(report.date, style: .relative) ago")
                    if let rssi = report.rssi {
                        Text("Signal: \(rssi) dBm")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No battery data yet",
                    systemImage: "earbuds.case",
                    description: Text(Self.emptyStateText)
                )
            }

            Text(store.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            #if os(macOS)
            Toggle("Read battery when the case opens", isOn: Binding(
                get: { store.autoConnectEnabled },
                set: { store.autoConnectEnabled = $0 }
            ))
            .font(.caption)
            .help("When the buds are near but not connected, connect to them for a few seconds to read the battery, then disconnect.")
            #endif
        }
    }
}

struct BatteryRow: View {
    let title: String
    let systemImage: String
    let component: BatteryComponent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer()
                    if component.isCharging {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Charging")
                    }
                    Text(component.percent.map { "\($0)%" } ?? "Unknown")
                        .monospacedDigit()
                        .foregroundStyle(component.percent == nil ? .secondary : .primary)
                    if let asOf = component.asOf, Date().timeIntervalSince(asOf) >= 60 {
                        Text("· \(asOf, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: Double(component.percent ?? 0), total: 100)
                    .tint(tint)
                    .opacity(component.percent == nil ? 0.3 : 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        guard let percent = component.percent else { return .gray }
        if percent <= 15 { return .red }
        if percent <= 30 { return .orange }
        return .green
    }
}

private struct LimitsNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How this app gets data").font(.headline)
            #if os(macOS)
            Text("When the buds are connected to this Mac, the app reads live levels from the Fast Pair Message Stream. When they are not, it can only read the battery field in Fast Pair advertisements. Some buds, like Pixel Buds Pro 2, encrypt that field, so the app then shows the last known levels.")
            #else
            Text("iOS does not let apps talk to the buds over Bluetooth Classic. The app can only read the battery field that the buds put in Fast Pair advertisements, usually when you open the case lid. Some buds, like Pixel Buds Pro 2, encrypt that field, so the app cannot read them on iOS.")
            #endif
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
