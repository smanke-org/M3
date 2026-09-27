import Charts
import SwiftUI

/// The menu dropdown's view (totals plus the cards chosen for the menu), and
/// the More Charts flyout's (the cards chosen for it, in one or two columns).
struct MenuChartsView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject var batteryViewModel: BatteryViewModel
    var cards: [MenuCard]
    var showsTotals = true
    var columns = 1

    static let columnWidth: CGFloat = 340
    private static let spacing: CGFloat = 12

    static func width(columns: Int) -> CGFloat {
        CGFloat(columns) * columnWidth - CGFloat(columns - 1) * 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if showsTotals {
                Text(AppInfo.displayName)
                    .font(.system(size: 13, weight: .semibold))
                totals
            }
            if !cards.isEmpty {
                Text(viewModel.chartsScopeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if columns > 1 {
                // Reading order runs down the left column, then the right.
                let split = (cards.count + 1) / 2
                HStack(alignment: .top, spacing: 14) {
                    column(Array(cards.prefix(split)))
                    column(Array(cards.dropFirst(split)))
                }
            } else {
                column(cards)
            }
        }
        .padding(14)
        .frame(width: Self.width(columns: columns))
    }

    private func column(_ cards: [MenuCard]) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(cards) { card($0) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func card(_ card: MenuCard) -> some View {
        switch card {
        case .topApps: TopAppsCard(viewModel: viewModel)
        case .battery: BatteryCard(viewModel: batteryViewModel)
        case .todayByHour: ChartCard(title: card.title, buckets: viewModel.byHour, xAxisStyle: .hour)
        case .byDay: ChartCard(title: card.title, buckets: viewModel.byDay, xAxisStyle: .day)
        case .yearToDate: ChartCard(title: card.title, buckets: viewModel.yearToDate, xAxisStyle: .month)
        }
    }

    private var totals: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("This Mac").foregroundStyle(.secondary)
                Text(viewModel.thisMacText).monospacedDigit()
            }
            GridRow {
                Text("All Macs").foregroundStyle(.secondary)
                Text(viewModel.allMacsText).monospacedDigit()
            }
        }
        .font(.system(size: 13))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
    }
}

private enum XAxisStyle {
    case hour, day, month
}

private struct DisplayPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

private struct ChartCard: View {
    let title: String
    let buckets: [MileageHistoryStore.Bucket]
    let xAxisStyle: XAxisStyle

    private static let calendar = Calendar.current

    // Buckets arrive in miles; switch to feet when the whole chart is under a mile,
    // matching the menu bar's own feet/miles convention.
    private var useFeet: Bool {
        (buckets.map(\.points).max() ?? 0) < 1.0
    }

    private var unitSuffix: String { useFeet ? "ft" : "mi" }

    private var points: [DisplayPoint] {
        buckets.map { bucket in
            let value = useFeet ? bucket.points * 5280 : bucket.points
            return DisplayPoint(date: bucket.start, value: value)
        }
    }

    private var maxValue: Double {
        max(points.map(\.value).max() ?? 0, 0.1)
    }

    private var yTicks: [Double] {
        [0, maxValue / 3, maxValue * 2 / 3, maxValue]
    }

    private var xTicks: [Date] {
        guard let first = points.first?.date, let last = points.last?.date else { return [] }
        switch xAxisStyle {
        case .hour:
            return stride(from: 0, through: 23, by: 3).compactMap {
                Self.calendar.date(byAdding: .hour, value: $0, to: Self.calendar.startOfDay(for: first))
            }
        case .day:
            return points.map(\.date)
        case .month:
            var result: [Date] = []
            var cursor = Self.calendar.date(from: Self.calendar.dateComponents([.year, .month], from: first)) ?? first
            while cursor <= last {
                result.append(cursor)
                guard let next = Self.calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
            }
            return result
        }
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f
    }()

    private func xLabel(for date: Date) -> String {
        switch xAxisStyle {
        case .hour:
            return Self.hourFormatter.string(from: date)
        case .day:
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: date)
        case .month:
            let f = DateFormatter()
            f.dateFormat = "MMM"
            return f.string(from: date)
        }
    }

    /// The "now" marker only makes sense on the hour chart, where the x-axis spans
    /// the whole day even though only hours up to now have data.
    private var nowMarker: Date? {
        xAxisStyle == .hour ? Date() : nil
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ChartContentBuilder
    private var areaContent: some ChartContent {
        ForEach(points) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .interpolationMethod(.stepCenter)
        }
        .foregroundStyle(areaGradient)
    }

    @ChartContentBuilder
    private var lineContent: some ChartContent {
        ForEach(points) { point in
            LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .interpolationMethod(.stepCenter)
        }
        .foregroundStyle(Color.accentColor)
        .lineStyle(StrokeStyle(lineWidth: 2.5))
    }

    @ChartContentBuilder
    private var nowMarkerContent: some ChartContent {
        if let nowMarker {
            RuleMark(x: .value("Now", nowMarker))
                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                .foregroundStyle(Color.red.opacity(0.55))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Chart {
                areaContent
                lineContent
                nowMarkerContent
            }
            .chartYScale(domain: 0...maxValue)
            .chartYAxis {
                AxisMarks(position: .trailing, values: yTicks) { value in
                    AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(MetricsFormatter.tenths(v)) \(unitSuffix)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: xTicks) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.gray.opacity(0.25))
                    AxisValueLabel {
                        if let d = value.as(Date.self) {
                            Text(xLabel(for: d))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 110)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
    }
}
