import AppKit
import SwiftUI

/// Metadata: lists readable fields by section, removes or edits them one by one,
/// or removes everything ("Remove All") for every file in the drop.
struct MetadataEditorView: View {
    @ObservedObject var session: ToolSession

    @State private var selected = 0
    @State private var reports: [URL: MetadataReport] = [:]
    @State private var failures: [URL: String] = [:]
    @State private var changes: [URL: MetadataChanges] = [:]

    /// Snapshot hook: pre-marks fields as removed or edited.
    var initialChanges: MetadataChanges?

    private var url: URL { session.urls[min(selected, session.urls.count - 1)] }
    private var report: MetadataReport? { reports[url] }
    private var current: MetadataChanges { changes[url] ?? MetadataChanges() }
    private var pendingFiles: [URL] { session.urls.filter { !(changes[$0]?.isEmpty ?? true) } }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(spacing: 0) {
                if session.urls.count > 1 { filePicker }
                content
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Edited Copy", primaryEnabled: !pendingFiles.isEmpty, action: saveEdits) {
                if !current.isEmpty {
                    Button("Reset") { changes[url] = MetadataChanges() }
                        .buttonStyle(PlainTextButtonStyle())
                        .help("Undo the removals and edits for this file")
                }
            }
        }
        .task { await load() }
    }

    // MARK: Sections

    private var filePicker: some View {
        HStack(spacing: 8) {
            Picker("File", selection: $selected) {
                ForEach(Array(session.urls.enumerated()), id: \.offset) { index, url in
                    Text(url.lastPathComponent).tag(index)
                }
            }
            .labelsHidden()
            .fixedSize()
            Text("\(selected + 1) of \(session.urls.count)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = failures[url] {
            VStack(spacing: 0) {
                ToolMessageView(symbol: "exclamationmark.triangle", message: failure)
                removeAllCard.padding(16)
            }
        } else if let report {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    removeAllCard
                    if report.isEmpty {
                        Label(MetadataText.empty, systemImage: "checkmark.seal")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        privacySummary(report)
                        ForEach(report.sections) { section in
                            sectionView(section)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ToolMessageView(symbol: "tag", message: "Loading file details", isLoading: true)
        }
    }

    private var removeAllCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "eraser.line.dashed")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Brand.buttonOrange)
                .frame(width: 28)
            Text(MetadataText.note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(session.urls.count > 1 ? "Remove All (\(session.urls.count))" : "Remove All", action: removeAll)
                .buttonStyle(TintedButtonStyle())
                .fixedSize()
                .help(session.urls.count > 1 ? "Remove metadata from all \(session.urls.count) files" : "Remove all metadata")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.buttonOrange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.buttonOrange.opacity(0.18)))
    }

    @ViewBuilder
    private func privacySummary(_ report: MetadataReport) -> some View {
        let sensitive = report.fields.filter { $0.sensitive && !current.removed.contains($0.id) }
        if !sensitive.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text(sensitive.count == 1 ? "1 privacy-sensitive field" : "\(sensitive.count) privacy-sensitive fields")
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.privacyKinds(sensitive))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                let removable = sensitive.filter(\.removable)
                if !removable.isEmpty {
                    Button("Remove These") {
                        var updated = current
                        updated.removed.formUnion(removable.map(\.id))
                        changes[url] = updated
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.buttonOrange)
                }
            }
        }
    }

    static func privacyKinds(_ fields: [MetadataField]) -> String {
        var kinds: [String] = []
        func add(_ kind: String) { if !kinds.contains(kind) { kinds.append(kind) } }
        for field in fields {
            let text = (field.id + " " + field.label).lowercased()
            if field.section == "GPS Location" || text.contains("location") || text.contains("city") || text.contains("country") { add("location") }
            else if text.contains("serial") { add("camera serial") }
            else if text.contains("software") || text.contains("creatortool") || text.contains("encoder") || text.contains("producer")
                        || text.contains("created with") { add("software") }
            else if text.contains("owner") || text.contains("creator") || text.contains("artist") || text.contains("author") { add("owner") }
            else if text.contains("make") || text.contains("model") { add("device") }
            else { add("personal notes") }
        }
        return kinds.joined(separator: ", ")
    }

    private func sectionView(_ section: MetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(section.title, systemImage: section.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(section.fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { Divider().opacity(0.4).padding(.leading, 12) }
                    MetadataFieldRow(field: field,
                                     isRemoved: current.removed.contains(field.id),
                                     editedValue: binding(for: field),
                                     toggleRemoved: { toggle(field) })
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    // MARK: State

    private func binding(for field: MetadataField) -> Binding<String> {
        Binding {
            changes[url]?.edits[field.id] ?? field.value
        } set: { newValue in
            var updated = changes[url] ?? MetadataChanges()
            updated.edits[field.id] = newValue == field.value ? nil : newValue
            changes[url] = updated
        }
    }

    private func toggle(_ field: MetadataField) {
        var updated = current
        if updated.removed.contains(field.id) { updated.removed.remove(field.id) } else { updated.removed.insert(field.id) }
        changes[url] = updated
    }

    private func load() async {
        for url in session.urls where reports[url] == nil && failures[url] == nil {
            do {
                reports[url] = try await MetadataStore.read(url)
            } catch {
                failures[url] = error.localizedDescription
            }
        }
        if let initialChanges, changes.isEmpty { changes[session.primaryURL] = initialChanges }
    }

    // MARK: Actions

    private func removeAll() {
        session.runPerItem(title: "Removing metadata", successTitle: { outputs in
            outputs.count == 1 ? "Metadata Removed" : "Metadata removed from \(outputs.count) files"
        }) { url, context in
            [try await MetadataStore.removeAll(url, context: context)]
        }
    }

    private func saveEdits() {
        let pending = changes.filter { !$0.value.isEmpty }
        guard !pending.isEmpty else { return }
        session.runBatch(title: "Saving metadata", successTitle: { outputs in
            outputs.count == 1 ? "Saved Edited Copy" : "Saved \(outputs.count) edited copies"
        }) { urls, context in
            // Only files with changes get an edited copy.
            let files = urls.filter { pending[$0] != nil }
            var outputs: [URL] = []
            for url in files {
                try context.checkCancelled()
                outputs.append(try await MetadataStore.apply(pending[url] ?? MetadataChanges(), to: url, context: context))
            }
            return outputs
        }
    }
}

/// One field: label, value (editable inline for text fields) and a remove/undo button.
struct MetadataFieldRow: View {
    var field: MetadataField
    var isRemoved: Bool
    @Binding var editedValue: String
    var toggleRemoved: () -> Void

    @State private var hovering = false

    private var isEdited: Bool { editedValue != field.value }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: field.sensitive ? "exclamationmark.shield.fill" : "circle.fill")
                .font(.system(size: field.sensitive ? 10.5 : 4))
                .foregroundStyle(field.sensitive ? Color.orange : Color.secondary.opacity(0.5))
                .frame(width: 12)
                .help(field.sensitive ? "Privacy-sensitive" : "")
            Text(field.label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
                .lineLimit(2)
            Group {
                if field.editable && !isRemoved {
                    TextField(field.label, text: $editedValue)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(hovering || isEdited ? 0.07 : 0.035)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(isEdited ? Brand.buttonOrange.opacity(0.6) : Color.clear))
                        .accessibilityLabel(field.label)
                } else {
                    Text(field.value)
                        .font(.system(size: 12.5))
                        .strikethrough(isRemoved)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isEdited && !isRemoved {
                Text("Edited")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.buttonOrange)
            }
            if field.removable {
                Button(action: toggleRemoved) {
                    Image(systemName: isRemoved ? "arrow.uturn.backward.circle" : "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isRemoved ? Brand.buttonOrange : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isRemoved ? "Keep \(field.label)" : "Remove \(field.label)")
                .accessibilityLabel(isRemoved ? "Keep \(field.label)" : "Remove \(field.label)")
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Removed only with Remove All")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .opacity(isRemoved ? 0.5 : 1)
        .background(field.sensitive && !isRemoved ? Color.orange.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
    }
}
