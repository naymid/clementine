import AppKit
import SwiftUI

/// Standard tool window layout: compact header, content, footer.
struct ToolScaffold<Content: View, Footer: View>: View {
    @ObservedObject var session: ToolSession
    var subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(session: ToolSession, subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.session = session
        self.subtitle = subtitle
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            CompactToolHeader(session: session, subtitle: subtitle ?? session.subtitle)
            Divider().opacity(0.5)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            footer()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(ToolPanelBackground())
        .tint(Brand.buttonOrange)
    }
}

struct ToolPanelBackground: View {
    var body: some View {
        VisualEffectBlur(material: .windowBackground, blending: .behindWindow)
            .ignoresSafeArea()
    }
}

/// Icon, title, file name and a close button. Dragging it moves the window.
struct CompactToolHeader: View {
    @ObservedObject var session: ToolSession
    var subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Brand.highlightTop, Brand.highlightBottom], startPoint: .top, endPoint: .bottom))
                Image(systemName: session.tool.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.tool.title)
                    .font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                session.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(WindowDragArea())
    }
}

/// Lets the user move the window by dragging this view.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Footer with an optional leading view, Cancel, and an orange primary action.
struct ToolFooter<Leading: View>: View {
    @ObservedObject var session: ToolSession
    var primaryTitle: String?
    var primaryEnabled = true
    var primaryAction: () -> Void
    @ViewBuilder var leading: () -> Leading

    init(session: ToolSession, primaryTitle: String?, primaryEnabled: Bool = true,
         action: @escaping () -> Void, @ViewBuilder leading: @escaping () -> Leading) {
        self.session = session
        self.primaryTitle = primaryTitle
        self.primaryEnabled = primaryEnabled
        self.primaryAction = action
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 8)
            Button("Cancel") { session.close() }
                .buttonStyle(PlainTextButtonStyle())
            if let primaryTitle {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(FilledOrangeButtonStyle(cornerRadius: 14, horizontalPadding: 16, verticalPadding: 6))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!primaryEnabled)
                    .opacity(primaryEnabled ? 1 : 0.45)
            }
        }
    }
}

extension ToolFooter where Leading == EmptyView {
    init(session: ToolSession, primaryTitle: String?, primaryEnabled: Bool = true, action: @escaping () -> Void) {
        self.init(session: session, primaryTitle: primaryTitle, primaryEnabled: primaryEnabled, action: action) { EmptyView() }
    }
}

struct PlainTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.5 : 0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }
}

/// A titled group of settings rows, styled like the original's grouped cards.
struct ToolSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// "Label ........ control" row used inside ToolSection.
struct ToolSettingRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            control()
        }
    }
}

/// Labeled slider with a value readout.
struct ToolSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(width: 104, alignment: .leading)
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(format(value))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// Centered icon + message, for empty, loading and error states.
struct ToolMessageView: View {
    var symbol: String
    var message: String
    var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Segmented control styled with the orange accent.
struct ToolSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(Value, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
