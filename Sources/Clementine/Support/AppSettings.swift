import AppKit
import Combine

/// A set of modifier keys held while dragging files.
struct ModifierCombo: Hashable, Codable, Identifiable {
    var control = false
    var option = false
    var shift = false
    var command = false

    var id: String { symbols }

    static let shiftOnly = ModifierCombo(shift: true)
    static let optionShift = ModifierCombo(option: true, shift: true)

    init(control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    init(flags: NSEvent.ModifierFlags) {
        control = flags.contains(.control)
        option = flags.contains(.option)
        shift = flags.contains(.shift)
        command = flags.contains(.command)
    }

    var isEmpty: Bool { !control && !option && !shift && !command }

    var symbols: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
    }

    var names: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        return parts.joined(separator: " + ")
    }

    var menuTitle: String { "\(symbols)  \(names)" }

    /// Every non-empty combination, in the original app's menu order.
    static let all: [ModifierCombo] = [
        ModifierCombo(command: true),
        ModifierCombo(option: true),
        ModifierCombo(control: true),
        ModifierCombo(shift: true),
        ModifierCombo(option: true, command: true),
        ModifierCombo(control: true, command: true),
        ModifierCombo(control: true, option: true),
        ModifierCombo(shift: true, command: true),
        ModifierCombo(control: true, shift: true),
        ModifierCombo(option: true, shift: true),
        ModifierCombo(control: true, option: true, command: true),
        ModifierCombo(option: true, shift: true, command: true),
        ModifierCombo(control: true, shift: true, command: true),
        ModifierCombo(control: true, option: true, shift: true),
        ModifierCombo(control: true, option: true, shift: true, command: true),
    ]
}

enum WheelStyle: String, Codable, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var title: String { self == .glass ? "Glass" : "Solid" }
}

/// All persisted preferences.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []

    @Published var wheelStyle: WheelStyle
    @Published var soundsAndHaptics: Bool
    @Published var conversionModifier: ModifierCombo
    @Published var toolsModifier: ModifierCombo
    @Published var formatOptions: [FileFormat: FormatOptions]
    @Published var compressionOptions: [FileFormat: CompressionOptions]
    @Published var hasCompletedWelcome: Bool
    @Published var conversionCount: Int

    private init() {
        wheelStyle = WheelStyle(rawValue: defaults.string(forKey: "conversionFanTheme") ?? "") ?? .glass
        soundsAndHaptics = defaults.object(forKey: "soundsAndHapticsEnabled") as? Bool ?? true
        conversionModifier = Self.decode(ModifierCombo.self, "conversionModifier") ?? .shiftOnly
        toolsModifier = Self.decode(ModifierCombo.self, "toolsModifier") ?? .optionShift
        formatOptions = Self.decode([FileFormat: FormatOptions].self, "formatOptions") ?? [:]
        compressionOptions = Self.decode([FileFormat: CompressionOptions].self, "compressionOptions") ?? [:]
        hasCompletedWelcome = defaults.bool(forKey: "hasCompletedWelcome")
        conversionCount = defaults.integer(forKey: "conversionCount")

        $wheelStyle.dropFirst().sink { [defaults] in defaults.set($0.rawValue, forKey: "conversionFanTheme") }.store(in: &cancellables)
        $soundsAndHaptics.dropFirst().sink { [defaults] in defaults.set($0, forKey: "soundsAndHapticsEnabled") }.store(in: &cancellables)
        $conversionModifier.dropFirst().sink { Self.encode($0, "conversionModifier") }.store(in: &cancellables)
        $toolsModifier.dropFirst().sink { Self.encode($0, "toolsModifier") }.store(in: &cancellables)
        $formatOptions.dropFirst().sink { Self.encode($0, "formatOptions") }.store(in: &cancellables)
        $compressionOptions.dropFirst().sink { Self.encode($0, "compressionOptions") }.store(in: &cancellables)
        $hasCompletedWelcome.dropFirst().sink { [defaults] in defaults.set($0, forKey: "hasCompletedWelcome") }.store(in: &cancellables)
        $conversionCount.dropFirst().sink { [defaults] in defaults.set($0, forKey: "conversionCount") }.store(in: &cancellables)
    }

    func options(for format: FileFormat) -> FormatOptions {
        formatOptions[format] ?? .defaults(for: format)
    }

    func setOptions(_ options: FormatOptions, for format: FileFormat) {
        formatOptions[format] = options
    }

    func compression(for format: FileFormat) -> CompressionOptions {
        compressionOptions[format] ?? CompressionOptions()
    }

    func setCompression(_ options: CompressionOptions, for format: FileFormat) {
        compressionOptions[format] = options
    }

    /// Hint shown in the status menu, e.g. "⇧: Convert · ⌥⇧: Tools".
    var gestureHint: String {
        "\(conversionModifier.symbols): Convert · \(toolsModifier.symbols): Tools"
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
