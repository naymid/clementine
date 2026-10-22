import SwiftUI

struct FormatsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selected: FileFormat = .jpg
    @State private var search = ""

    private var filtered: [FileFormat] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return FileFormat.settingsOrder }
        return FileFormat.settingsOrder.filter { $0.rawValue.contains(query) || $0.family.title.lowercased().contains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Conversion formats")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filtered) { format in
                            Button {
                                selected = format
                            } label: {
                                Text(format.label)
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(selected == format ? Brand.buttonOrange.opacity(0.22) : Color.clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(8)
            .frame(width: 118)
            Divider()
            ScrollView {
                FormatDetailView(format: selected)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .padding(12)
    }
}

struct FormatDetailView: View {
    let format: FileFormat
    @ObservedObject private var settings = AppSettings.shared

    private var layout: FormatSettingsLayout { .layout(for: format) }

    private var options: Binding<FormatOptions> {
        Binding(get: { settings.options(for: format) }, set: { settings.setOptions($0, for: format) })
    }

    private var compression: Binding<CompressionOptions> {
        Binding(get: { settings.compression(for: format) }, set: { settings.setCompression($0, for: format) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(format.label) Defaults")
                .font(.system(size: 15, weight: .bold))
            if layout.hasConversionSettings {
                Text("Conversion Settings").font(.system(size: 13, weight: .semibold))
                conversionControls
                HStack {
                    Spacer()
                    Button("Restore Defaults") { options.wrappedValue = .defaults(for: format) }
                        .buttonStyle(TintedButtonStyle())
                }
            }
            if layout.imageCompression || layout.videoCompression {
                if layout.hasConversionSettings { Divider() }
                Text(layout.imageCompression ? "Image Compression" : "Compression Settings")
                    .font(.system(size: 13, weight: .semibold))
                compressionControls
                HStack {
                    Spacer()
                    Button("Restore Compression Defaults") { compression.wrappedValue = CompressionOptions() }
                        .buttonStyle(TintedButtonStyle())
                }
            }
            if !layout.hasConversionSettings && !layout.imageCompression && !layout.videoCompression {
                Text("This format has no adjustable conversion settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .id(format)
    }

    @ViewBuilder
    private var conversionControls: some View {
        if layout.quality {
            labeledPicker("Quality", selection: options.quality) {
                ForEach(ConversionQuality.allCases) { Text($0.title).tag($0) }
            }
        }
        if layout.audioBitrate {
            labeledPicker("Audio bitrate", selection: options.audioBitrate) {
                ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
        }
        if layout.compressionSpeed {
            labeledPicker("Compression", selection: options.compressionSpeed) {
                ForEach(CompressionSpeed.allCases) { Text($0.title).tag($0) }
            }
        }
        if layout.videoHeight {
            labeledPicker("Maximum video height", selection: options.maxVideoHeight) {
                Text("Original").tag(0)
                ForEach([2160, 1080, 720, 480], id: \.self) { Text("\($0)p").tag($0) }
            }
        }
        if layout.gif {
            labeledPicker("Frame rate", selection: options.gifFrameRate) {
                ForEach([10, 15, 24], id: \.self) { Text("\($0) fps").tag($0) }
            }
            labeledPicker("Maximum width", selection: options.gifMaxWidth) {
                ForEach([480, 960, 1280], id: \.self) { Text("\($0) px").tag($0) }
            }
        }
        if layout.preserveMetadata {
            Toggle("Preserve metadata", isOn: options.preserveMetadata)
                .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private var compressionControls: some View {
        HStack {
            Text("Compression")
            Picker("Compression", selection: compression.strength) {
                ForEach(CompressionStrength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if layout.imageCompression {
            labeledPicker("Image size", selection: compression.sizeLimit) {
                ForEach(ImageSizeLimit.allCases) { Text($0.title).tag($0) }
            }
        } else {
            Text(compression.wrappedValue.strength.videoDescription())
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func labeledPicker<Value: Hashable, Content: View>(_ title: String, selection: Binding<Value>,
                                                              @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .fixedSize()
        }
    }
}
