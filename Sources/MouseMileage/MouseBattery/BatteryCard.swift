import SwiftUI

/// The menu dropdown's mileage-per-charge card: up to two mice.
///
/// Fixed height, like Top Apps: the menu measures its view once when built.
struct BatteryCard: View {
    @ObservedObject var viewModel: BatteryViewModel

    static let maxMice = 2
    private static let rowHeight: CGFloat = 50
    private static let rowSpacing: CGFloat = 8
    private static var rowsHeight: CGFloat {
        CGFloat(maxMice) * rowHeight + CGFloat(maxMice - 1) * rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mileage per Charge")
                .font(.system(size: 12, weight: .semibold))

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(placeholder == nil ? Array(viewModel.mice.prefix(Self.maxMice)) : []) { mouse in
                        row(mouse).frame(height: Self.rowHeight, alignment: .top)
                    }
                }
                if let message = placeholder {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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

    private var placeholder: String? {
        if let message = BatteryViewModel.statusMessage[viewModel.status] { return message }
        return viewModel.mice.isEmpty ? "No supported mouse connected yet.\nLogitech mice and Apple Magic Mouse work." : nil
    }

    private func row(_ mouse: BatteryViewModel.Mouse) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "computermouse")
                    .frame(width: 16)
                Text(mouse.label).lineLimit(1)
                Spacer()
                Image(systemName: BatteryViewModel.batterySymbol(percent: mouse.percent, isCharging: mouse.isCharging))
                    .foregroundStyle(.secondary)
                Text(mouse.percent.map { "\($0)%" } ?? "—")
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .font(.system(size: 12))
            .foregroundStyle(mouse.connected == nil ? .secondary : .primary)

            Group {
                if let charge = mouse.history.current {
                    Text("This charge: \(BatteryViewModel.distance(charge)) · \(BatteryViewModel.used(charge))")
                    Text(perFullLine(charge, average: mouse.history.averageMilesPerFullCharge))
                } else if mouse.isCharging {
                    Text("Charging. A new charge starts when it's unplugged.")
                } else {
                    Text("Waiting for a battery reading.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.leading, 22)
            .lineLimit(1)
        }
    }

    private func perFullLine(_ charge: Charge, average: Double?) -> String {
        let estimate = BatteryViewModel.perFullCharge(charge)
        guard let average else { return estimate }
        return "\(estimate) · avg \(BatteryViewModel.miles(average))"
    }
}
