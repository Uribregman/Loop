//
//  HistoryLogView.swift
//  Loop
//
//  Settings and export for the durable history log (HistoryLogStore).
//
//  The log is opt-in and write-only. Turning it on starts recording from that
//  moment — Loop keeps only ~7 days of history, so there is nothing older to
//  backfill and this screen says so rather than implying otherwise.
//

import SwiftUI
import LoopKitUI
import UniformTypeIdentifiers

final class HistoryLogViewModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { HistoryLogStore.shared.isEnabled = isEnabled }
    }
    @Published private(set) var files: [HistoryLogStore.LogFile] = []
    @Published private(set) var isLoading = true

    /// Resolved once, off the main thread, when the screen appears.
    @Published private(set) var location: HistoryLogLocation = .local

    init() {
        self.isEnabled = HistoryLogStore.shared.isEnabled
    }

    func refresh() {
        isLoading = true
        // `location` reads through the store's queue; hop off main so a cold
        // iCloud lookup can never stall the screen appearing.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let location = HistoryLogStore.shared.location
            DispatchQueue.main.async { self?.location = location }
        }
        HistoryLogStore.shared.loadFiles { [weak self] files in
            self?.files = files
            self?.isLoading = false
        }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    // MARK: Import

    /// What the chosen file would add, waiting for the owner's Continue.
    @Published var importPlan: HistoryImporter.Plan?
    @Published var importSourceName = ""
    @Published var importMessage: String?
    @Published private(set) var isImporting = false

    /// Read the chosen files and work out what the log is missing. Nothing is
    /// written here; `commitImport` does that after the confirmation.
    func prepareImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importSourceName = urls.count == 1
            ? urls[0].lastPathComponent
            : String(format: NSLocalizedString("%d files", comment: "Number of files chosen for import"), urls.count)
        HistoryLogStore.shared.loadFiles { [weak self] files in
            DispatchQueue.global(qos: .userInitiated).async {
                // Files picked in the Files app are security-scoped.
                let chosen: [Data] = urls.compactMap { url in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }
                let existing = HistoryLogReader.read(files: files.map(\.url))
                let plan = HistoryImporter.plan(importing: chosen, existing: existing)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImporting = false
                    if chosen.isEmpty {
                        self.importMessage = NSLocalizedString("That file could not be read.", comment: "Import: unreadable file")
                    } else if plan.count == 0 {
                        self.importMessage = String(format: NSLocalizedString("Nothing to add: all %d records in the file are already in your log.", comment: "Import: nothing missing"),
                                                    plan.alreadyThere)
                    } else {
                        self.importPlan = plan
                    }
                }
            }
        }
    }

    func commitImport() {
        guard let plan = importPlan else { return }
        importPlan = nil
        isImporting = true
        HistoryLogStore.shared.appendEncoded(plan.lines) { [weak self] written in
            guard let self else { return }
            self.isImporting = false
            self.importMessage = written == plan.count
                ? String(format: NSLocalizedString("Added %d records to your history log.", comment: "Import: done"), written)
                : String(format: NSLocalizedString("Added %1$d of %2$d records; the rest could not be written.", comment: "Import: partly done"), written, plan.count)
            self.refresh()
        }
    }

    /// "1,234 records your log is missing (glucose 1,000 · doses 200 · …)".
    var importSummary: String {
        guard let plan = importPlan else { return "" }
        let names: [(String, String)] = [("glucose", NSLocalizedString("glucose", comment: "Import summary: record type")),
                                         ("dose", NSLocalizedString("doses", comment: "Import summary: record type")),
                                         ("meal", NSLocalizedString("meals", comment: "Import summary: record type")),
                                         ("pod", NSLocalizedString("pods", comment: "Import summary: record type")),
                                         ("deleted", NSLocalizedString("deleted notes", comment: "Import summary: record type"))]
        let parts = names.compactMap { key, name in plan.added[key].map { "\(name) \($0)" } }
        return String(format: NSLocalizedString("From %1$@: %2$d records your log is missing (%3$@). %4$d already in your log stay as they are. Nothing in your log is changed or removed, and each added record is marked as added.", comment: "Import confirmation message"),
                      importSourceName, plan.count, parts.joined(separator: " · "), plan.alreadyThere)
    }
}

struct HistoryLogView: View {
    @StateObject private var viewModel = HistoryLogViewModel()
    @Environment(\.dismiss) private var dismiss

    /// ⚠️ TWO QUESTIONS BEFORE RECORDING STOPS. Days not recorded can never be
    /// recovered (Loop keeps about 7), so switching this off must not be one
    /// stray tap. The owner asked for at least two confirmations. Switching it
    /// off never deletes anything already recorded; both questions say so.
    @State private var isAskingFirst = false
    @State private var isAskingSecond = false
    @State private var isPickingImport = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// "2026-08" → "August 2026", falling back to the raw string.
    private static let monthParser: DateFormatter = {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM"
        parser.locale = Locale(identifier: "en_US_POSIX")
        return parser
    }()

    private static let monthDisplay: DateFormatter = {
        let display = DateFormatter()
        display.dateFormat = "LLLL yyyy"
        return display
    }()

    private static func monthTitle(_ raw: String) -> String {
        guard let date = monthParser.date(from: raw) else { return raw }
        return monthDisplay.string(from: date)
    }

    var body: some View {
        List {
            recordingSection
            if viewModel.isEnabled {
                storageSection
            }
            filesSection
            importSection
            aboutSection
        }
        .insetGroupedListStyle()
        .navigationTitle(Text("History Log", comment: "Title of the history log screen"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Text("Done", comment: "Done button in history log").fontWeight(.semibold)
                }
            }
        }
        .onAppear { viewModel.refresh() }
    }

    private var recordingSection: some View {
        Section {
            Toggle(NSLocalizedString("Record History", comment: "Toggle enabling the history log"),
                   isOn: Binding(
                    get: { viewModel.isEnabled },
                    set: { turnOn in
                        if turnOn {
                            viewModel.isEnabled = true
                        } else {
                            // Stays on until both questions are answered.
                            isAskingFirst = true
                        }
                    }))
            .alert(Text("Turn off Record History?", comment: "First confirmation title for turning off the history log"),
                   isPresented: $isAskingFirst) {
                Button(role: .cancel) {} label: {
                    Text("Cancel", comment: "Keep recording history")
                }
                Button {
                    // The second alert cannot open while the first is still
                    // closing; a moment later it can.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isAskingSecond = true }
                } label: {
                    Text("Continue", comment: "Go on to turning off the history log")
                }
            } message: {
                Text("Loop will stop adding to your history log. Everything already recorded stays where it is; nothing is deleted.", comment: "First confirmation message for turning off the history log")
            }
            .alert(Text("Are you sure?", comment: "Second confirmation title for turning off the history log"),
                   isPresented: $isAskingSecond) {
                Button(role: .cancel) {} label: {
                    Text("Cancel", comment: "Keep recording history")
                }
                Button(role: .destructive) {
                    viewModel.isEnabled = false
                } label: {
                    Text("Continue", comment: "Turn off the history log")
                }
            } message: {
                Text("While it is off, nothing new is recorded: statistics, the backup and Loop Follow get no new data, and those days cannot be recovered later because Loop itself keeps only about 7 days. Your existing log files are kept.", comment: "Second confirmation message for turning off the history log")
            }
        } footer: {
            Text("Keeps a permanent copy of your glucose readings, meals, insulin doses and pod sessions. Loop itself only keeps about 7 days, so recording starts from the moment you switch this on — earlier data cannot be recovered.", comment: "Footer explaining the history log")
        }
    }

    /// Bring in records the log is missing, from a history file — the SSD
    /// backup, an export, another phone's log. Add-only; see `HistoryImporter`.
    private var importSection: some View {
        Section {
            Button {
                isPickingImport = true
            } label: {
                HStack {
                    Label(NSLocalizedString("Import History File", comment: "Button importing a history log file"),
                          systemImage: "square.and.arrow.down")
                    if viewModel.isImporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isImporting)
        } footer: {
            Text("Adds the records a history file has and your log is missing, for example from a backup. Nothing already in your log is changed or removed. Each added record is marked as added.", comment: "Footer explaining history import")
        }
        .fileImporter(isPresented: $isPickingImport, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { viewModel.prepareImport(urls) }
        }
        .alert(Text("Add Missing Records?", comment: "Import confirmation title"),
               isPresented: Binding(get: { viewModel.importPlan != nil },
                                    set: { if !$0 { viewModel.importPlan = nil } })) {
            Button(role: .cancel) { viewModel.importPlan = nil } label: {
                Text("Cancel", comment: "Do not import")
            }
            Button { viewModel.commitImport() } label: {
                Text("Continue", comment: "Import the missing records")
            }
        } message: {
            Text(viewModel.importSummary)
        }
        .alert(Text("History Import", comment: "Import result title"),
               isPresented: Binding(get: { viewModel.importMessage != nil },
                                    set: { if !$0 { viewModel.importMessage = nil } })) {
            Button(role: .cancel) { viewModel.importMessage = nil } label: {
                Text("OK", comment: "Dismiss the import result")
            }
        } message: {
            Text(viewModel.importMessage ?? "")
        }
    }

    private var storageSection: some View {
        Section {
            HStack {
                Text("Saving To", comment: "Label for where the history log is written")
                Spacer()
                Text(viewModel.location.displayName).foregroundStyle(.secondary)
            }
        } footer: {
            switch viewModel.location {
            case .iCloud:
                Text("Your history is in iCloud Drive, so it is backed up and readable on your other devices. Find it in the Files app.", comment: "Footer when the log is in iCloud")
            case .local:
                Text("iCloud Drive isn't available, so history is being saved on this iPhone. Find it in the Files app, under On My iPhone. Export it regularly — it is not backed up anywhere else.", comment: "Footer when the log is stored locally")
            }
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        Section {
            if viewModel.isLoading {
                HStack {
                    ProgressView()
                    Text("Loading…", comment: "Placeholder while history files load")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            } else if viewModel.files.isEmpty {
                Text(viewModel.isEnabled
                     ? NSLocalizedString("Nothing recorded yet. The first file appears once new data arrives.", comment: "Empty history, recording on")
                     : NSLocalizedString("Nothing recorded yet.", comment: "Empty history, recording off"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.files) { file in
                    ShareLink(item: file.url) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.monthTitle(file.month))
                                Text(Self.byteFormatter.string(fromByteCount: file.byteCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } header: {
            Text("Files", comment: "Header for the list of history files")
        } footer: {
            if !viewModel.files.isEmpty {
                Text(String(format: NSLocalizedString("One file per month, %@ in total. Tap a month to share or save a copy.", comment: "Footer for the history files list (total size)"),
                            Self.byteFormatter.string(fromByteCount: viewModel.totalBytes)))
            }
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                HistoryStatisticsView()
            } label: {
                Label(NSLocalizedString("Statistics", comment: "Row opening the statistics screen"),
                      systemImage: "chart.bar")
            }
            NavigationLink {
                HistoryFormatView()
            } label: {
                Text("What's In The File", comment: "Row opening the history format explanation")
            }
        }
    }
}

/// Plain-language summary of the file format, so the log is explicable from
/// inside the app. The full guide, with worked examples per record type, is
/// `docs/HISTORY_FORMAT.md` in the source tree.
struct HistoryFormatView: View {
    var body: some View {
        List {
            Section {
                Text("The file is plain text. Each line is one event, written as it happens and never changed afterwards. You can open it in any text editor.", comment: "History format intro")
            } footer: {
                Text("Every line starts with the same three fields: v (format version), t (the kind of event) and at (when it happened, including your time zone).", comment: "History format shared fields")
            }

            recordSection(
                title: NSLocalizedString("glucose", comment: "History record type: glucose"),
                summary: NSLocalizedString("One CGM reading.", comment: "Glucose record summary"),
                fields: [
                    (NSLocalizedString("mgdl", comment: "field"), NSLocalizedString("The reading, always in mg/dL. Divide by 18 for mmol/L.", comment: "field meaning")),
                    (NSLocalizedString("trend", comment: "field"), NSLocalizedString("The arrow the CGM reported.", comment: "field meaning")),
                    (NSLocalizedString("trendRate", comment: "field"), NSLocalizedString("Speed in mg/dL per minute; negative means falling.", comment: "field meaning"))
                ])

            recordSection(
                title: NSLocalizedString("meal", comment: "History record type: meal"),
                summary: NSLocalizedString("One carb entry, with three separate times: when you ate, when the carbs start counting, and when you logged it. A meal with several parts writes one line per part, sharing a meal name.", comment: "Meal record summary"),
                fields: [
                    (NSLocalizedString("eatenAt", comment: "field"), NSLocalizedString("Eating time — when you actually ate.", comment: "field meaning")),
                    (NSLocalizedString("at", comment: "field"), NSLocalizedString("Absorption start — when these carbs begin counting. Often later than eating time, if the part was offset.", comment: "field meaning")),
                    (NSLocalizedString("absorption", comment: "field"), NSLocalizedString("Absorption time — how long the carbs were expected to take, in seconds.", comment: "field meaning")),
                    (NSLocalizedString("enteredAt", comment: "field"), NSLocalizedString("Entry time — when you saved it into the app. Differs when you log a meal late.", comment: "field meaning")),
                    (NSLocalizedString("grams", comment: "field"), NSLocalizedString("Carbs in grams.", comment: "field meaning")),
                    (NSLocalizedString("mealName", comment: "field"), NSLocalizedString("The name you gave the meal, if any.", comment: "field meaning"))
                ])

            recordSection(
                title: NSLocalizedString("dose", comment: "History record type: dose"),
                summary: NSLocalizedString("One delivery of insulin.", comment: "Dose record summary"),
                fields: [
                    (NSLocalizedString("kind", comment: "field"), NSLocalizedString("bolus, basal, tempBasal, suspend or resume.", comment: "field meaning")),
                    (NSLocalizedString("units", comment: "field"), NSLocalizedString("Units delivered.", comment: "field meaning")),
                    (NSLocalizedString("automatic", comment: "field"), NSLocalizedString("true when Loop decided it, false when you asked for it.", comment: "field meaning"))
                ])

            recordSection(
                title: NSLocalizedString("pod", comment: "History record type: pod"),
                summary: NSLocalizedString("One finished pod session, written when the pod stops. This is the record that cannot be recreated later — Loop only ever remembers one previous pod.", comment: "Pod record summary"),
                fields: [
                    (NSLocalizedString("hoursRun", comment: "field"), NSLocalizedString("How long the pod lasted.", comment: "field meaning")),
                    (NSLocalizedString("remainingAtStop", comment: "field"), NSLocalizedString("Units still inside when it stopped — insulin thrown away.", comment: "field meaning")),
                    (NSLocalizedString("stopReason", comment: "field"), NSLocalizedString("expired, reservoirEmpty, fault, or deactivated.", comment: "field meaning"))
                ])

            Section {
                Text("This file is a record, not medical advice. It shows what happened; any decision about your settings belongs with your care team.", comment: "History format caution")
                    .foregroundStyle(.secondary)
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(Text("What's In The File", comment: "Title of the history format screen"))
        .navigationBarTitleDisplayMode(.inline)
        .loopSoftTopEdge()
    }

    private func recordSection(title: String, summary: String,
                               fields: [(String, String)]) -> some View {
        Section {
            Text(summary)
            ForEach(fields, id: \.0) { name, meaning in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline.monospaced())
                    Text(meaning).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title).font(.subheadline.monospaced())
        }
    }
}
