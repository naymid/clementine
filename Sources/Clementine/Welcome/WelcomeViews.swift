import AppKit
import SwiftUI

// MARK: - Splash

/// Orange stadium-shaped "Welcome to Clementine" splash shown on first launch.
struct WelcomeSplashView: View {
    var onContinue: () -> Void
    var onClose: () -> Void
    @State private var appeared = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 190, style: .continuous)
        ZStack {
            shape
                .fill(RadialGradient(colors: [
                    Color(red: 1.0, green: 0.78, blue: 0.0),
                    Color(red: 1.0, green: 0.58, blue: 0.0),
                    Color(red: 1.0, green: 0.45, blue: 0.0),
                ], center: UnitPoint(x: 0.5, y: 0.98), startRadius: 10, endRadius: 520))
                .overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            VStack(spacing: 0) {
                Text("Welcome to")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(Brand.appName)
                    .font(.system(size: 88, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.white, Color.white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .padding(.top, -6)
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 168, height: 64)
                        .background(Capsule().fill(Color.white))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 34)
            }
            .offset(y: 8)
            VStack {
                HStack(spacing: 9) {
                    Button(action: onClose) { Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)) }
                        .buttonStyle(.plain)
                        .frame(width: 14, height: 14)
                    Circle().fill(Color(red: 1, green: 0.78, blue: 0.1)).frame(width: 14, height: 14)
                    Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1).frame(width: 14, height: 14)
                }
                .padding(.leading, 112)
                .padding(.top, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
        }
        .frame(width: 640, height: 420)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true } }
    }
}

// MARK: - Tour

struct WelcomeTourView: View {
    @ObservedObject var model: WelcomeModel
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    switch model.page {
                    case .holdDragDrop:
                        PracticePage(model: model,
                                     title: "Hold. Drag. Drop.",
                                     subtitle: "Hold \(AppSettings.shared.conversionModifier.names) while dragging a file.\nDrop it on the format you want. Try it below.")
                    case .tools:
                        PracticePage(model: model,
                                     title: "There’s a tool for that.",
                                     subtitle: "Hold \(AppSettings.shared.toolsModifier.names) while dragging a file\nto open the tools wheel instead.")
                    case .saveBeside:
                        SaveBesidePage()
                    case .ready:
                        ReadyPage()
                    }
                }
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                AppIconView(size: 46)
                    .padding(.top, 26)
                    .padding(.trailing, 26)
            }
            Divider().padding(.horizontal, 24)
            HStack {
                if model.page != .holdDragDrop {
                    Button("Back") {
                        model.go(to: WelcomePage(rawValue: model.page.rawValue - 1) ?? .holdDragDrop)
                    }
                    .buttonStyle(PlainTextButtonStyle())
                    .font(.system(size: 15))
                }
                Spacer()
                Button(model.page == .ready ? "Let’s get started" : "Next") {
                    if let next = WelcomePage(rawValue: model.page.rawValue + 1) {
                        model.go(to: next)
                    } else {
                        onFinish()
                    }
                }
                .buttonStyle(FilledOrangeButtonStyle(cornerRadius: 20, horizontalPadding: 22, verticalPadding: 9))
                .font(.system(size: 15, weight: .medium))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 560, height: 570)
        .background(WelcomeBackground())
        .tint(Brand.buttonOrange)
    }
}

struct WelcomeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        LinearGradient(colors: colorScheme == .dark
                       ? [Color(white: 0.17), Color(red: 0.14, green: 0.15, blue: 0.17)]
                       : [Color(white: 0.98), Color(white: 0.93)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.8)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Practice pages

struct PracticePage: View {
    @ObservedObject var model: WelcomeModel
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: subtitle)
            PracticeArea(model: model)
                .frame(height: 270)
            Spacer(minLength: 0)
            HStack {
                Text(model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isDone ? "Try again" : "Show me") {
                    if isDone { model.resetPractice() } else { model.showMe() }
                }
                .buttonStyle(PlainTextButtonStyle())
                .font(.system(size: 15))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private var isDone: Bool {
        if case .done = model.practice { return true }
        return false
    }
}

struct PracticeArea: View {
    @ObservedObject var model: WelcomeModel

    private var fileURL: URL { model.practiceURL }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.practice == .idle {
                HandwrittenHint()
                    .offset(x: 70, y: 30)
                    .transition(.opacity)
            }
            if model.practice == .demoHolding || model.practice == .demoWheel {
                KeycapHint(tools: model.isToolsPage)
                    .offset(x: 48, y: 36)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            // The original practice file. Real drags start here.
            PracticeFileIcon(url: fileURL, selected: model.practice == .idle, dimmed: model.demoFileLifted)
                .offset(x: 40, y: 140)
                .onDrag { NSItemProvider(contentsOf: fileURL) ?? NSItemProvider() }
                .help(model.isToolsPage ? "Practice video. Use Show me to watch the drag demonstration." : "Practice photo. Use Show me to watch the drag demonstration.")
            if model.demoFileLifted {
                PracticeFileIcon(url: fileURL, selected: true, dimmed: false)
                    .offset(x: 40 + model.demoFileOffset.width, y: 140 + model.demoFileOffset.height)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                    .zIndex(3)
            }
            if model.practice == .demoWheel || model.demoWheel.isPresented {
                WheelView(model: model.demoWheel)
                    .scaleEffect(0.62)
                    .frame(width: 210, height: 210)
                    .offset(x: 250, y: 30)
                    .zIndex(2)
            }
            if case .done(let name) = model.practice {
                PracticeResultIcon(source: fileURL, name: name)
                    .offset(x: 380, y: 140)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PracticeFileIcon: View {
    var url: URL
    var selected: Bool
    var dimmed: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: PracticeFiles.thumbnail(for: url))
                .resizable()
                .aspectRatio(contentMode: url.pathExtension == "mp4" ? .fit : .fill)
                .frame(width: url.pathExtension == "mp4" ? 92 : 66, height: url.pathExtension == "mp4" ? 52 : 66)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .center) {
                    if url.pathExtension == "mp4" {
                        Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentBlue : Color.clear))
        }
        .frame(width: 130)
        .opacity(dimmed ? 0.45 : 1)
    }
}

struct PracticeResultIcon: View {
    var source: URL
    var name: String

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: PracticeFiles.thumbnail(for: source))
                .resizable()
                .aspectRatio(contentMode: source.pathExtension == "mp4" ? .fit : .fill)
                .frame(width: source.pathExtension == "mp4" ? 92 : 66, height: source.pathExtension == "mp4" ? 52 : 66)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(6)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentBlue))
                .frame(maxWidth: 124)
        }
        .frame(width: 130)
    }
}

extension Color {
    /// Finder's selection blue for practice file labels.
    static let accentBlue = Color(red: 0.16, green: 0.42, blue: 0.86)
}

/// "Drag this file" in handwriting with a curved arrow toward the file.
struct HandwrittenHint: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("Drag this file")
                .font(.custom("Bradley Hand", size: 24).weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-4))
                .offset(x: 18, y: 0)
            Path { path in
                path.move(to: CGPoint(x: 150, y: 40))
                path.addCurve(to: CGPoint(x: 28, y: 112), control1: CGPoint(x: 160, y: 80), control2: CGPoint(x: 70, y: 92))
            }
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            Path { path in
                path.move(to: CGPoint(x: 26, y: 92))
                path.addLine(to: CGPoint(x: 24, y: 114))
                path.addLine(to: CGPoint(x: 46, y: 112))
            }
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 220, height: 130, alignment: .topLeading)
    }
}

/// "Hold Shift" with key caps, shown during the demonstration.
struct KeycapHint: View {
    var tools: Bool

    var body: some View {
        let combo = tools ? AppSettings.shared.toolsModifier : AppSettings.shared.conversionModifier
        VStack(spacing: 8) {
            Text("Hold \(combo.names)")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                if combo.control { Keycap(symbol: "⌃", name: "control") }
                if combo.option { Keycap(symbol: "⌥", name: "option") }
                if combo.shift { Keycap(symbol: "⇧", name: "shift") }
                if combo.command { Keycap(symbol: "⌘", name: "command") }
            }
        }
    }
}

struct Keycap: View {
    var symbol: String
    var name: String

    var body: some View {
        VStack(spacing: 4) {
            Text(symbol).font(.system(size: 17, weight: .medium))
            Text(name).font(.system(size: 9))
        }
        .frame(width: 52, height: 48)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 0, y: 1.5)
    }
}

// MARK: Save beside

struct SaveBesidePage: View {
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Save beside your files.",
                       subtitle: "Results are saved next to the originals.\nThe original file is never changed.")
            Spacer()
            ZStack {
                Circle().fill(Brand.buttonOrange).frame(width: 110, height: 110)
                Image(systemName: "checkmark")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("\(Brand.appName) can save beside your files.")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 26)
            Spacer()
            Text("\(Brand.appName) runs outside the App Store sandbox, so macOS won’t ask\nfor permission for each folder. Change defaults anytime in Settings → Formats.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 22)
        }
    }
}

// MARK: Ready

struct ReadyPage: View {
    @StateObject private var loginItem = LoginItemModel()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Ready when you are.",
                       subtitle: "\(Brand.appName) lives in your menu bar.\nClick its little icon for settings or to take this tour again.")
            VStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: 26) {
                        Spacer()
                        Image(systemName: "wifi").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                        Image(nsImage: Brand.menuBarImage())
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.buttonOrange.opacity(0.22)))
                            .accessibilityLabel("Find the \(Brand.appName) icon near the clock in your menu bar")
                        Text("9:41").font(.system(size: 17, weight: .semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 22)
                    .frame(height: 60)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.buttonOrange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 112)
                    .padding(.top, -6)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch at login").font(.system(size: 15, weight: .semibold))
                        Text("Ready whenever you turn on your Mac.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.large)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Everything’s included").font(.system(size: 15, weight: .semibold))
                        Text("No free-use limit. \(FormatCompatibility.totalConversions) conversions and \(FileTool.allCases.count) tools, all on this Mac.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "infinity")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Brand.buttonOrange)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            Spacer()
        }
    }
}
