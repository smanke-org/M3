import SwiftUI

/// One app's mileage as a row: icon, name, a bar scaled against the leader, distance.
struct AppMileageRow: View {
    let icon: NSImage?
    let name: String
    let points: Double
    let maxPoints: Double
    var nameWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)

            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: nameWidth, alignment: .leading)

            GeometryReader { geometry in
                let fraction = maxPoints > 0 ? min(points / maxPoints, 1) : 0
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 2 : 0), height: 8)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)

            Text(MetricsStore.distanceText(forPoints: points))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 12))
    }
}

/// The menu dropdown's ranking of apps by mileage.
///
/// Always the same height: the menu's hosting view is measured once when the
/// menu is built, so a card that grew with the number of apps would be clipped.
struct TopAppsCard: View {
    @ObservedObject var viewModel: HistoryViewModel

    private static let rowHeight: CGFloat = 18
    private static let rowSpacing: CGFloat = 4
    /// Top apps plus the "N others" row.
    private static var slots: Int { HistoryViewModel.topAppCount + 1 }
    private static var rowsHeight: CGFloat {
        CGFloat(slots) * rowHeight + CGFloat(slots - 1) * rowSpacing
    }

    private var maxPoints: Double {
        max(viewModel.topApps.first?.usage.points ?? 0, viewModel.otherAppsUsage.points)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Apps")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Range", selection: $viewModel.appRange) {
                    ForEach(AppUsageRange.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(viewModel.topApps) { app in
                        AppMileageRow(icon: AppIcons.icon(for: app.id), name: app.name,
                                      points: app.usage.points, maxPoints: maxPoints)
                            .frame(height: Self.rowHeight)
                            .help(app.name)
                    }
                    if viewModel.otherAppsCount > 0 {
                        AppMileageRow(icon: nil, name: otherAppsLabel,
                                      points: viewModel.otherAppsUsage.points, maxPoints: maxPoints)
                            .foregroundStyle(.secondary)
                            .frame(height: Self.rowHeight)
                    }
                }
                if viewModel.topApps.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: Self.rowsHeight, alignment: .top)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private var otherAppsLabel: String {
        viewModel.otherAppsCount == 1 ? "1 other" : "\(viewModel.otherAppsCount) others"
    }

    private var emptyText: String {
        switch viewModel.appRange {
        case .today: return "No mouse movement recorded today yet"
        case .sevenDays: return "No mouse movement recorded this week yet"
        case .allTime: return "No app data yet"
        }
    }
}
