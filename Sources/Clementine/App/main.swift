import AppKit

/// Command-line entry points used by the build script and tests.
enum CommandLineMode {
    static func handle(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        switch arguments[1] {
        case "--render-iconset" where arguments.count > 2:
            do {
                try Brand.writeIconset(to: URL(fileURLWithPath: arguments[2]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        case "--convert" where arguments.count > 3:
            guard let target = FileFormat(rawValue: arguments[3].lowercased()) else {
                print("Unknown format \(arguments[3])")
                exit(2)
            }
            let source = URL(fileURLWithPath: arguments[2])
            Task {
                do {
                    let outputs = try await ConversionEngine.convert(source, to: target, context: JobContext())
                    outputs.forEach { print($0.path) }
                    exit(0)
                } catch {
                    print("error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        case "--snapshot":
            MainActor.assumeIsolated { Snapshot.run(arguments) }
            return true
        case "--tool-test":
            MainActor.assumeIsolated { ToolTestRegistry.run(arguments) }
            dispatchMain()
        case "--matrix":
            print("conversions: \(FormatCompatibility.totalConversions)")
            for format in FileFormat.allCases {
                let targets = FormatCompatibility.targets(for: format)
                if !targets.isEmpty { print("\(format.label) → \(targets.map(\.label).joined(separator: " "))") }
            }
            exit(0)
        default:
            return false
        }
        return false
    }
}

if !CommandLineMode.handle(CommandLine.arguments) {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
