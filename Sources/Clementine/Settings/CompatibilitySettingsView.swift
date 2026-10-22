import SwiftUI

struct CompatibilitySettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Format Compatibility", systemImage: "tablecells")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.leading, 4)
                ForEach(FormatCompatibility.tables) { table in
                    CompatibilityTableView(table: table)
                }
            }
            .padding(14)
        }
    }
}

struct CompatibilityTableView: View {
    let table: FormatCompatibility.Table
    @State private var hovered: (row: Int, column: Int)?

    private let sourceColumnWidth: CGFloat = 54
    private let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(table.family.title, systemImage: table.family.symbol)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 6)
            GeometryReader { proxy in
                let columnWidth = (proxy.size.width - sourceColumnWidth) / CGFloat(table.targets.count)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: sourceColumnWidth, height: rowHeight)
                        ForEach(Array(table.targets.enumerated()), id: \.offset) { column, target in
                            headerCell(target.label, highlighted: hovered?.column == column)
                                .frame(width: columnWidth, height: rowHeight)
                                .overlay(alignment: .leading) { gridLine(vertical: true) }
                        }
                    }
                    ForEach(Array(table.sources.enumerated()), id: \.offset) { row, source in
                        HStack(spacing: 0) {
                            headerCell(source.label, highlighted: hovered?.row == row)
                                .frame(width: sourceColumnWidth, height: rowHeight)
                            ForEach(Array(table.targets.enumerated()), id: \.offset) { column, target in
                                cell(supported: FormatCompatibility.isSupported(source, target))
                                    .frame(width: columnWidth, height: rowHeight)
                                    .overlay(alignment: .leading) { gridLine(vertical: true) }
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside { hovered = (row, column) } else if hovered?.row == row && hovered?.column == column { hovered = nil }
                                    }
                            }
                        }
                        .overlay(alignment: .top) { gridLine(vertical: false) }
                    }
                }
            }
            .frame(height: rowHeight * CGFloat(table.sources.count + 1))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        }
    }

    private func headerCell(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(highlighted ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(highlighted ? Brand.buttonOrange.opacity(0.18) : Color.clear)
    }

    private func cell(supported: Bool) -> some View {
        Group {
            if supported {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("–").foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gridLine(vertical: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
