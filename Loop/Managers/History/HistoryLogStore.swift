//
//  HistoryLogStore.swift
//  Loop
//
//  Append-only JSON Lines writer for the durable history log. Opt-in, write-only,
//  and completely independent of dosing — see HistoryRecord.swift for why the log
//  exists at all and what a record looks like.
//
//  Files rotate MONTHLY (`loop-history-YYYY-MM.jsonl`) so no single file grows
//  unbounded and each one syncs cheaply. Appends are O(1): seek to end, write the
//  line. A crash mid-write can only ever corrupt the final line, and a reader can
//  skip that one line and keep going — which is the main reason for JSONL over a
//  single big JSON array.
//

import Foundation
import LoopKit

/// Where the log is written. iCloud Drive is the goal; local Documents is the
/// honest fallback when the iCloud container isn't available (no entitlement yet,
/// user signed out of iCloud, or offline on first run).
enum HistoryLogLocation: String {
    case iCloud
    case local

    var displayName: String {
        switch self {
        case .iCloud: return NSLocalizedString("iCloud Drive", comment: "History log storage location: iCloud Drive")
        case .local:  return NSLocalizedString("On My iPhone", comment: "History log storage location: local documents")
        }
    }
}

final class HistoryLogStore {
    static let shared = HistoryLogStore()

    private let log = DiagnosticLog(category: "HistoryLogStore")

    /// All file work is serialised here. Appends come from the CGM/pump callback
    /// queues, so they must not race each other or interleave half-written lines.
    private let queue = DispatchQueue(label: "com.loopkit.Loop.historyLog", qos: .utility)

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Stable key order makes the file diffable and pleasant to read; it costs
        // nothing here because records are small and flat.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let enabledKey = "com.loopkit.Loop.historyLogEnabled"

    /// Opt-in. Nothing is written until the user turns this on.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: - Location

    /// The iCloud Drive Documents directory, or nil when it isn't usable.
    ///
    /// `url(forUbiquityContainerIdentifier:)` returns nil without the iCloud
    /// entitlement or when the user is signed out — which is exactly why the
    /// whole location decision lives behind this one property. Adding the
    /// entitlement later switches the app over with no other code change.
    ///
    /// It also blocks on first call, hence the private queue.
    private var iCloudDirectory: URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        } catch {
            log.error("Could not create iCloud Documents dir: %{public}@", String(describing: error))
            return nil
        }
    }

    private var localDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Resolved once per process — the answer can't change without an app
    /// relaunch (entitlement) or a sign-in the user must act on anyway.
    private lazy var resolved: (directory: URL?, location: HistoryLogLocation) = {
        if let iCloud = iCloudDirectory { return (iCloud, .iCloud) }
        return (localDirectory, .local)
    }()

    /// Resolve the storage location ahead of time, on the background queue.
    ///
    /// `url(forUbiquityContainerIdentifier:)` does I/O and can take a noticeable
    /// moment on its first call. Warming it here means neither the first append
    /// nor a settings screen reading `location` ever waits on it.
    func prepare() {
        queue.async { _ = self.resolved }
    }

    /// Where the log is actually being written right now.
    ///
    /// `queue.sync` is safe rather than slow because `prepare()` has normally
    /// already resolved it; the sync is just a memory barrier at that point.
    var location: HistoryLogLocation {
        queue.sync { resolved.location }
    }

    /// One month's log file, as the export screen needs it.
    struct LogFile: Identifiable, Equatable {
        let url: URL
        let byteCount: Int64
        var id: URL { url }
        /// e.g. "2026-08" — the month this file covers.
        var month: String {
            url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: HistoryLogStore.filePrefix, with: "")
        }
    }

    /// The log files on disk, newest first.
    ///
    /// Asynchronous on purpose: this is a directory listing plus a stat per file,
    /// and on iCloud that can be slow. The export screen must never block the
    /// main thread on it.
    func loadFiles(completion: @escaping ([LogFile]) -> Void) {
        queue.async {
            guard let directory = self.resolved.directory,
                  let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey]) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let files = contents
                .filter { $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { url in
                    LogFile(url: url,
                            byteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                }
            DispatchQueue.main.async { completion(files) }
        }
    }

    // MARK: - Writing

    private static let filePrefix = "loop-history-"

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        // Fixed locale: a Persian or Buddhist calendar would otherwise rename the
        // files, and the month is a filing detail, not something to localise.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func fileURL(for date: Date) -> URL? {
        resolved.directory?.appendingPathComponent(
            "\(Self.filePrefix)\(Self.monthFormatter.string(from: date)).jsonl")
    }

    /// Append one record. Fire-and-forget: returns immediately, never throws into
    /// the caller, and silently does nothing when logging is off. Callers are
    /// device-data callbacks — none of them can meaningfully handle a disk error,
    /// and none of them may be delayed by one.
    func append<R: Encodable>(_ record: R, at date: Date = Date()) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                var line = try self.encoder.encode(record)
                line.append(0x0A) // newline — the record separator
                try self.write(line, to: date)
            } catch {
                self.log.error("History append failed: %{public}@", String(describing: error))
            }
        }
    }

    /// Seek-to-end append, creating the month's file on first write.
    private func write(_ data: Data, to date: Date) throws {
        guard let url = fileURL(for: date) else { return }
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            // `.completeUntilFirstUserAuthentication` rather than the stricter
            // default: readings arrive in the background while the phone is
            // locked, and a log that can't be written then is worthless.
            try data.write(to: url, options: .init(rawValue: 0))
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
            return
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
