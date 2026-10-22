import SwiftUI

enum WheelMode: Equatable {
    case convert
    case tools
}

struct WheelItem: Identifiable, Equatable {
    enum Action: Equatable {
        case convert(FileFormat)
        case tool(FileTool)
    }

    var id: String
    var label: String
    var symbol: String?
    var action: Action

    static func format(_ format: FileFormat) -> WheelItem {
        WheelItem(id: "f-\(format.rawValue)", label: format.label, symbol: nil, action: .convert(format))
    }

    static func tool(_ tool: FileTool) -> WheelItem {
        WheelItem(id: "t-\(tool.rawValue)", label: tool.petalLabel.uppercased(), symbol: tool.symbol, action: .tool(tool))
    }
}

/// State shared between the drop view (AppKit) and the wheel (SwiftUI).
final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var items: [WheelItem] = []
    @Published var hovered: Int?
    @Published var centerHovered = false
    @Published var summaryTitle = ""
    @Published var summarySize = ""
    @Published var emptyMessage: String?
    @Published var isPresented = false
    @Published var style: WheelStyle = .glass
    @Published var dropFlash: Int?

    var geometry: WheelGeometry {
        WheelGeometry(count: items.count, diameter: WheelGeometry.diameter(for: items.count))
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        let geometry = model.geometry
        ZStack {
            disk(geometry)
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                petal(item, index: index, geometry: geometry)
            }
            centerHub(geometry)
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .scaleEffect(model.isPresented ? 1 : 0.42)
        .opacity(model.isPresented ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.74), value: model.isPresented)
        .animation(.easeOut(duration: 0.12), value: model.hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.items)
    }

    // MARK: Disk

    @ViewBuilder
    private func disk(_ geometry: WheelGeometry) -> some View {
        let circle = Circle()
        if model.style == .glass {
            if #available(macOS 26.0, *) {
                circle
                    .fill(Color.clear)
                    .glassEffect(.regular, in: circle)
                    .overlay(circle.strokeBorder(rimColor, lineWidth: 1))
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 22, y: 8)
            } else {
                VisualEffectBlur(material: .hudWindow)
                    .clipShape(circle)
                    .overlay(circle.strokeBorder(rimColor, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 22, y: 8)
            }
        } else {
            circle
                .fill(dark ? Color(white: 0.115) : Color(white: 0.86))
                .overlay(circle.strokeBorder(rimColor, lineWidth: 1))
                .shadow(color: .black.opacity(dark ? 0.5 : 0.2), radius: 22, y: 8)
        }
    }

    private var rimColor: Color {
        dark ? Color.white.opacity(0.14) : Color.white.opacity(0.7)
    }

    // MARK: Petals

    private func petalFill(highlighted: Bool) -> AnyShapeStyle {
        if highlighted {
            return AnyShapeStyle(LinearGradient(colors: [Brand.highlightTop, Brand.highlightBottom], startPoint: .top, endPoint: .bottom))
        }
        switch (model.style, dark) {
        case (.glass, true): return AnyShapeStyle(Color.white.opacity(0.07))
        case (.glass, false): return AnyShapeStyle(Color.white.opacity(0.55))
        case (.solid, true): return AnyShapeStyle(Color(white: 0.15))
        case (.solid, false): return AnyShapeStyle(Color(white: 0.955))
        }
    }

    @ViewBuilder
    private func petal(_ item: WheelItem, index: Int, geometry: WheelGeometry) -> some View {
        let highlighted = model.hovered == index
        let shape = PetalShape(geometry: geometry, index: index)
        let size = geometry.diameter
        let position = geometry.labelPosition(of: index, center: CGPoint(x: size / 2, y: size / 2))
        ZStack {
            shape
                .fill(petalFill(highlighted: highlighted))
                .overlay(
                    shape.stroke(highlighted ? Color.white.opacity(0.18) : (dark ? Color.white.opacity(0.09) : Color.white.opacity(0.95)), lineWidth: 1)
                )
                .shadow(color: highlighted ? Brand.accent.opacity(0.45) : .black.opacity(dark ? 0 : 0.06),
                        radius: highlighted ? 10 : 1.5, y: highlighted ? 2 : 0.5)
            petalLabel(item, highlighted: highlighted, geometry: geometry)
                .position(position)
        }
        .frame(width: size, height: size)
        .scaleEffect(highlighted ? 1.035 : 1, anchor: UnitPoint(x: 0.5 + (position.x - size / 2) / size * 0.0, y: 0.5))
    }

    @ViewBuilder
    private func petalLabel(_ item: WheelItem, highlighted: Bool, geometry: WheelGeometry) -> some View {
        let color: Color = highlighted ? .white : (dark ? Color.white.opacity(0.93) : Color.black.opacity(0.88))
        if let symbol = item.symbol {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: geometry.diameter * 0.05, weight: .semibold))
                Text(item.label)
                    .font(.system(size: geometry.diameter * 0.028, weight: .bold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(color)
            .frame(width: geometry.diameter * 0.22)
        } else {
            Text(item.label)
                .font(.system(size: geometry.diameter * 0.053, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: geometry.diameter * 0.22)
        }
    }

    // MARK: Center

    @ViewBuilder
    private func centerHub(_ geometry: WheelGeometry) -> some View {
        let ring = Circle()
        let capsule = RoundedRectangle(cornerRadius: geometry.capsuleSize.height / 2, style: .continuous)
        ZStack {
            ring
                .fill(model.style == .glass ? AnyShapeStyle(Color.white.opacity(dark ? 0.04 : 0.35)) : AnyShapeStyle(dark ? Color(white: 0.135) : Color(white: 0.9)))
                .overlay(ring.strokeBorder(dark ? Color.white.opacity(0.12) : Color.white.opacity(0.9), lineWidth: 1))
                .frame(width: geometry.centerRadius * 2, height: geometry.centerRadius * 2)
            capsule
                .fill(dark ? Color.black.opacity(0.32) : Color.white.opacity(0.8))
                .overlay(capsule.strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06), lineWidth: 1))
                .frame(width: geometry.capsuleSize.width, height: geometry.capsuleSize.height)
            centerText(geometry)
                .frame(width: geometry.capsuleSize.width - 10)
        }
    }

    @ViewBuilder
    private func centerText(_ geometry: WheelGeometry) -> some View {
        let color: Color = dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85)
        if let hovered = model.hovered, model.items.indices.contains(hovered) {
            let item = model.items[hovered]
            Text(item.label)
                .font(.system(size: geometry.diameter * (item.symbol == nil ? 0.045 : 0.032), weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .transition(.opacity)
        } else if let message = model.emptyMessage {
            Text(message)
                .font(.system(size: geometry.diameter * 0.03, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
        } else {
            VStack(spacing: 1) {
                if !model.summaryTitle.isEmpty {
                    Text(model.summaryTitle)
                        .font(.system(size: geometry.diameter * 0.033, weight: .bold))
                        .tracking(0.3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(model.summarySize)
                    .font(.system(size: geometry.diameter * 0.036, weight: .semibold))
                    .opacity(model.summaryTitle.isEmpty ? 1 : 0.85)
            }
            .foregroundStyle(color)
        }
    }
}

/// NSVisualEffectView wrapper for pre-macOS 26 blur.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
