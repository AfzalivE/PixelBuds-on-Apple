import SwiftUI
import WidgetKit

struct BatteryEntry: TimelineEntry {
    let date: Date
    let snapshot: BatterySnapshot?
}

struct BatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        let snapshot = context.isPreview ? (SharedBatteryStorage.load() ?? .placeholder) : SharedBatteryStorage.load()
        completion(BatteryEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        // The app reloads the widget when the levels change. A widget cannot use
        // Bluetooth itself, so it only shows what the app saved last.
        let entry = BatteryEntry(date: Date(), snapshot: SharedBatteryStorage.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

@main
struct PixelBudsBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedBatteryStorage.widgetKind, provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Buds Battery")
        .description("Shows the battery of the left bud, the right bud and the case.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        return [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline]
        #else
        return [.systemSmall, .systemMedium]
        #endif
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BatteryEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            #if os(iOS)
            case .accessoryInline:
                Text(inlineText(snapshot))
            case .accessoryRectangular:
                RectangularView(snapshot: snapshot)
            #endif
            case .systemMedium:
                MediumView(snapshot: snapshot)
            default:
                SmallView(snapshot: snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "earbuds.case")
                    .font(.title2)
                Text("Open Buds Battery")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func inlineText(_ snapshot: BatterySnapshot) -> String {
        if let overall = snapshot.overall { return "Buds \(overall.percent.map { "\($0)%" } ?? "--")" }
        func t(_ part: BatterySnapshot.Part) -> String { part.percent.map(String.init) ?? "--" }
        return "L \(t(snapshot.left)) R \(t(snapshot.right)) C \(t(snapshot.caseBattery))"
    }
}

private struct WidgetRow: Identifiable {
    let title: String
    let systemImage: String
    let part: BatterySnapshot.Part
    var id: String { title }
}

/// The rows to show: one "Buds" row for an overall level, else left, right and case.
private func rows(_ snapshot: BatterySnapshot) -> [WidgetRow] {
    if let overall = snapshot.overall {
        return [WidgetRow(title: "Buds", systemImage: "earbuds", part: overall)]
    }
    return [
        WidgetRow(title: "L", systemImage: "earbuds", part: snapshot.left),
        WidgetRow(title: "R", systemImage: "earbuds", part: snapshot.right),
        WidgetRow(title: "Case", systemImage: "earbuds.case", part: snapshot.caseBattery),
    ]
}

private struct SmallView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows(snapshot)) { row in
                PartRow(title: row.title, part: row.part)
            }
            Spacer(minLength: 0)
            AgeText(snapshot: snapshot)
        }
    }
}

private struct MediumView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snapshot.deviceName ?? "Buds")
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 12) {
                ForEach(rows(snapshot)) { row in
                    PartGauge(title: row.title, systemImage: row.systemImage, part: row.part)
                        .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
            AgeText(snapshot: snapshot)
        }
    }
}

#if os(iOS)
private struct RectangularView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows(snapshot)) { row in
                HStack {
                    Text(row.title)
                    Spacer()
                    if row.part.isCharging { Image(systemName: "bolt.fill") }
                    Text(percentText(row.part))
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .widgetAccentable()
    }
}
#endif

private struct PartRow: View {
    let title: String
    let part: BatterySnapshot.Part

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.caption).bold()
                Spacer(minLength: 0)
                if part.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Text(percentText(part))
                    .font(.caption)
                    .monospacedDigit()
            }
            ProgressView(value: Double(part.percent ?? 0), total: 100)
                .tint(tintColor(part))
        }
        .opacity(part.percent == nil || part.asOf != nil ? 0.5 : 1)
    }
}

private struct PartGauge: View {
    let title: String
    let systemImage: String
    let part: BatterySnapshot.Part

    var body: some View {
        VStack(spacing: 4) {
            Gauge(value: Double(part.percent ?? 0), in: 0...100) {
                Image(systemName: systemImage)
            } currentValueLabel: {
                Text(part.percent.map(String.init) ?? "--")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tintColor(part))
            HStack(spacing: 2) {
                if part.isCharging {
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                }
                Text(title)
            }
            .font(.caption2)
        }
        .opacity(part.percent == nil || part.asOf != nil ? 0.5 : 1)
    }
}

private struct AgeText: View {
    let snapshot: BatterySnapshot

    var body: some View {
        Group {
            if snapshot.isStale {
                Text("Last known, \(snapshot.date, style: .relative) ago")
            } else {
                Text("Updated \(snapshot.date, style: .relative) ago")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private func percentText(_ part: BatterySnapshot.Part) -> String {
    part.percent.map { "\($0)%" } ?? "--"
}

private func tintColor(_ part: BatterySnapshot.Part) -> Color {
    guard let percent = part.percent else { return .gray }
    if percent <= 15 { return .red }
    if percent <= 30 { return .orange }
    return .green
}
