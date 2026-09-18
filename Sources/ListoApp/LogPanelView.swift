import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ListoEngine

/// The interpreted history for the open document (spec §05), with an export
/// action to save the JSONL log to a location of the user's choosing.
struct LogPanelView: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 520, height: 440)
        .alert(
            L("log.export.error", "No se pudo exportar"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text(L("log.title", "Historial"))
                .font(AppSettings.shared.font(.headline))
            Spacer()
            Toggle(isOn: $showRaw) {
                Text("JSON")
            }
            .toggleStyle(.button)
            .help(L("log.raw.help", "Ver como JSONL crudo"))

            Menu {
                Button {
                    exportLog(asRawJSONL: true)
                } label: {
                    Label(L("log.export.jsonl", "Exportar como .jsonl"), systemImage: "doc.text")
                }
                Button {
                    exportLog(asRawJSONL: false)
                } label: {
                    Label(L("log.export.text", "Exportar como texto legible"), systemImage: "doc.plaintext")
                }
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.logFileURL])
                } label: {
                    Label(L("log.revealInFinder", "Mostrar en Finder"), systemImage: "folder")
                }
            } label: {
                Label(L("log.export", "Exportar…"), systemImage: "square.and.arrow.up")
            }

            Button(L("common.close", "Cerrar")) { dismiss() }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if controller.logEvents.isEmpty {
            Spacer()
            Text(L("log.empty", "Todavía no hay eventos."))
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            List {
                ForEach(dayGroups, id: \.dayStart) { group in
                    Section {
                        ForEach(group.rows, id: \.index) { entry in
                            row(for: entry.event, previousText: entry.previousText)
                        }
                    } header: {
                        // Always English, like the rest of this panel (see
                        // LogFormatter.describe) — the log is a stable
                        // record, not part of the localized UI.
                        Text(Self.dayLabel(for: group.dayStart))
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private struct DayGroup {
        let dayStart: Date
        let rows: [(index: Int, event: LogEvent, previousText: String?)]
    }

    /// `controller.logEvents` newest-last, grouped by the calendar day
    /// each event's `ts` falls on — newest day first, newest event first
    /// within a day, mirroring the flat list's previous newest-first order.
    /// `previousText` for `LogFormatter.describe`'s "edited: old → new"
    /// still comes from the immediately preceding event in the *original*
    /// chronological array, not from within the day group, so splitting an
    /// edit's context across a day boundary (the edit is today, the
    /// previous text was set yesterday) still reads correctly.
    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        let indexed = controller.logEvents.enumerated().map { index, event in
            (index: index, event: event, previousText: index > 0 ? controller.logEvents[index - 1].text : nil)
        }
        let grouped = Dictionary(grouping: indexed) { calendar.startOfDay(for: $0.event.ts) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(dayStart: day, rows: grouped[day]!.sorted { $0.index > $1.index })
        }
    }

    /// "Today"/"Yesterday"/"N days ago" up through six days back, then a
    /// plain full date — an unbounded "47 days ago" stops being readable at
    /// a human glance, which is the whole point of grouping by day.
    private static func dayLabel(for dayStart: Date) -> String {
        let calendar = Calendar.current
        let daysAgo = calendar.dateComponents([.day], from: dayStart, to: calendar.startOfDay(for: Date())).day ?? 0
        switch daysAgo {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "\(daysAgo) days ago"
        default: return dayHeaderFormatter.string(from: dayStart)
        }
    }

    private static let dayHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    @ViewBuilder
    private func row(for event: LogEvent, previousText: String?) -> some View {
        if showRaw {
            Text(rawJSONLine(event))
                .font(AppSettings.shared.font(.caption, design: .monospaced))
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(LogFormatter.describe(event, previousText: previousText))
                    .font(AppSettings.shared.font(.body))
                HStack(spacing: 6) {
                    Text(Self.timestampFormatter.string(from: event.ts))
                    Text("· \(sourceLabel(event.source)) · \(interpretedLabel(event.interpretedBy))")
                }
                .font(AppSettings.shared.font(.caption))
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func rawJSONLine(_ event: LogEvent) -> String {
        guard let data = try? JSONEncoder().encode(event), let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    private func exportLog(asRawJSONL: Bool) {
        let panel = NSSavePanel()
        let base = controller.logFileURL.deletingPathExtension().lastPathComponent
        if asRawJSONL {
            panel.nameFieldStringValue = "\(base).jsonl"
            panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        } else {
            panel.nameFieldStringValue = "\(base).txt"
            panel.allowedContentTypes = [.plainText]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let contents = asRawJSONL ? controller.exportLogText() : readableExport()
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func readableExport() -> String {
        var lines: [String] = []
        for (i, event) in controller.logEvents.enumerated() {
            let previous = i > 0 ? controller.logEvents[i - 1] : nil
            let ts = ISO8601DateFormatter().string(from: event.ts)
            lines.append("\(ts) — \(LogFormatter.describe(event, previousText: previous?.text))")
        }
        return lines.joined(separator: "\n")
    }

    // Always English, like LogFormatter.describe — the log is a stable,
    // greppable record, not part of the localized UI (for now).
    /// `event.ts` already stores the full date (spec §05's ISO8601
    /// timestamp), but `Text(_:style:.time)` only ever renders the
    /// time-of-day — dropping the date even for an event from a previous
    /// day. Fixed en_US_POSIX formatting matches the rest of this panel
    /// (`sourceLabel`/`interpretedLabel` below): always English, not tied
    /// to `AppSettings.language`, since the log is a stable record for
    /// grep/external tools, not part of the localized UI.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func sourceLabel(_ s: LogEvent.Source) -> String {
        s == .app ? "App Mode" : "Free Mode"
    }

    private func interpretedLabel(_ i: LogEvent.InterpretedBy) -> String {
        switch i {
        case .userAction: return "direct action"
        case .heuristic: return "heuristic"
        case .llm: return "LLM"
        }
    }
}
