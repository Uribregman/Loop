//
//  HistoryLogReader.swift
//  Loop
//
//  Reads the JSON Lines history log back for the statistics screen.
//
//  Deliberately TOLERANT rather than strict: one tolerant struct with optional
//  fields decodes every record type. A line written by a newer schema, or one
//  truncated by a crash mid-write, is skipped instead of failing the whole file.
//  That is the main reason the log is JSONL and not one big JSON array — damage
//  is contained to a single line.
//

import Foundation

/// One decoded line. Every field beyond `t`/`at` is optional because it only
/// applies to some record types.
struct HistoryLine: Codable {
    let t: String
    let at: String

    // glucose
    let mgdl: Double?
    let trendRate: Double?

    // meal
    let grams: Double?
    let absorption: Double?
    let eatenAt: String?
    let enteredAt: String?
    let mealName: String?

    /// Written by every glucose/dose/meal record. The key to spotting a repeat —
    /// see `HistoryLineDeduplicator`. Absent on some older records, which is why
    /// the de-duplicator has fallbacks.
    let syncIdentifier: String?

    // dose
    let kind: String?
    let units: Double?
    let unitsPerHour: Double?
    let automatic: Bool?
    /// When delivery finished; absent for an instant dose. For a temp basal that
    /// was replaced early this is the shortened end, in the last record of it.
    let endedAt: String?

    // deleted note: the type of the record it removes (see `DeletedHistoryRecord`)
    let of: String?

    // pod
    let activatedAt: String?
    let hoursRun: Double?
    let totalDelivered: Double?
    let remainingAtStop: Double?
    let stopReason: String?
    let faultCode: String?

    /// Filled in ONCE by `HistoryLogReader.read` and never decoded from JSON —
    /// there is no `parsedDate` key in the file, so it simply arrives nil.
    ///
    /// ⚠️ THIS IS A PERFORMANCE FIX, NOT A CONVENIENCE. `date` used to run an
    /// `ISO8601DateFormatter` on every single access, and every pass over the
    /// log touches it: the period filter, each statistic, the therapy review.
    /// On a couple of months of five-minute data that is hundreds of thousands
    /// of date parses per recompute, which is what made changing the period
    /// freeze the screen for seconds.
    var parsedDate: Date?

    /// Parsed event time, or nil if the timestamp is unreadable.
    var date: Date? { parsedDate ?? HistoryTimestamp.formatter.date(from: at) }
}

enum HistoryLogReader {
    /// Read every record in the given files, oldest first, status records left
    /// out (see `parse`). Malformed lines are skipped silently; a log that refuses
    /// to open because of one bad byte would be worse than useless.
    ///
    /// Through `HistoryArchive`: each line is parsed once and kept, and only what
    /// was added since the last read is parsed now. The result is exactly what
    /// parsing every file from the start gives (see its tests in the harness).
    static func read(files: [URL], progress: ((Double) -> Void)? = nil) -> [HistoryLine] {
        HistoryArchive.shared.lines(in: files, progress: progress)
    }

    /// Records in some JSONL bytes, one per line, in order. The ONE place a line
    /// becomes a `HistoryLine`. Takes a slice of the mapped file as it is: copying
    /// a month's bytes first cost tens of MB.
    ///
    /// ⚠️ STATUS RECORDS ARE SKIPPED BEFORE THEY ARE PARSED. One is written every
    /// loop cycle for Loop Follow's live screen, with its predicted-glucose and
    /// insulin timelines, and together they are 90% of the file (82 of 92 MB on
    /// 60 days). Nothing that reads through here uses them: the statistics never
    /// did, and the follower share fetches the newest status on its own. They are
    /// still written; parsing them was most of the time every open took.
    static func parse(_ data: Data) -> [HistoryLine] {
        let decoder = JSONDecoder()
        var parsed: [HistoryLine] = []
        autoreleasepool {
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if isStatusLine(line) { continue }
                if var decoded = try? decoder.decode(HistoryLine.self, from: Data(line)), decoded.t != "status" {
                    // Parse the timestamp once, here, for every later pass.
                    decoded.parsedDate = HistoryTimestamp.formatter.date(from: decoded.at)
                    parsed.append(decoded)
                }
            }
        }
        return parsed
    }

    private static let statusMarker = Data(#""t":"status""#.utf8)

    /// The log is written with sorted keys, so a status record ENDS with
    /// `"t":"status","v":1}`: a look at the last few bytes is enough. A line
    /// written some other way is simply decoded and dropped afterwards.
    private static func isStatusLine(_ line: Data) -> Bool {
        line.suffix(32).firstRange(of: statusMarker) != nil
    }
}

// MARK: - Aging

/// The log, parsed once and kept: the AGING of the history.
///
/// The log only ever grows at the end (records are appended, never edited), so a
/// line once parsed never needs parsing again. This keeps, for each month file,
/// the records parsed so far and how many bytes they came from; a read parses
/// only the bytes added since, and returns the very array it already holds when
/// nothing changed (no copy). Finished months are also saved, already parsed,
/// to the app's Caches folder, so a relaunch does not parse them either: loading
/// that is about 20 times faster than parsing the JSONL.
///
/// ⚠️ THE RESULT MUST BE EXACTLY WHAT PARSING EVERY FILE FROM THE START GIVES.
/// So: a file that no longer begins with the bytes that were parsed (replaced, cut
/// short, rewritten) is parsed again from the start; a last line without its line
/// break yet is parsed on every read and never kept, as a full read would treat
/// it; a saved month is used only if made by this exact record layout
/// (`schema`). The statistics themselves are still computed from these records
/// by the same code as before: what is aged is the reading, which was most of the
/// time, so no figure can come out differently.
final class HistoryArchive {
    /// On the phone, saved in the app's Caches folder (iOS may empty it; it is
    /// rebuilt). Elsewhere (the Mac tools that compile this file) nothing is
    /// saved: no copies of the log are left lying around.
    static let shared: HistoryArchive = {
        #if os(iOS)
        return HistoryArchive(cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HistoryArchive", isDirectory: true))
        #else
        return HistoryArchive(cacheDirectory: nil)
        #endif
    }()

    /// One month as saved to the Caches folder.
    struct Month: Codable {
        var schema: String
        /// Bytes the records came from: up to and including the last line break.
        var size: Int
        /// The first and the last few KB of those bytes, and samples across the
        /// middle, to notice a file that was replaced or edited rather than added to.
        var head: Data
        var tail: Data
        var samples: [Data]
        var lines: [HistoryLine]
    }

    /// What `combined` holds of one month.
    private struct Span {
        var size: Int
        var head: Data
        var tail: Data
        var samples: [Data]
        var count: Int
    }

    /// The field names of `HistoryLine`. A saved month made with different ones
    /// would lack a field, or carry one that no longer exists, so it is not used.
    static let schema: String = {
        let probe = try? JSONDecoder().decode(HistoryLine.self, from: Data(#"{"t":"","at":""}"#.utf8))
        return probe.map { Mirror(reflecting: $0).children.compactMap(\.label).joined(separator: ",") } ?? "?"
    }()

    private static let checkLength = 4096
    /// The newest month grows every few minutes; saving it each time would be
    /// writing a few MB for a few lines. Finished months are saved when they change.
    private static let newestSaveInterval: TimeInterval = 15 * 60

    private let cacheDirectory: URL?
    private let lock = NSLock()
    /// Every record held, month after month in name order: `names[0]`'s first.
    private var names: [String] = []
    private var spans: [String: Span] = [:]
    private var combined: [HistoryLine] = []
    private var lastSaved: [String: Date] = [:]
    private var memoryPressure: DispatchSourceMemoryPressure?

    init(cacheDirectory: URL?) {
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        // Under memory pressure, let go of what is held in memory; the saved
        // months make the next read cheap.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.forgetHeldRecords() }
        source.resume()
        memoryPressure = source
    }

    func forgetHeldRecords() {
        lock.lock()
        names = []
        spans = [:]
        combined = []
        lock.unlock()
    }

    func lines(in files: [URL], progress: ((Double) -> Void)? = nil) -> [HistoryLine] {
        lock.lock()
        defer { lock.unlock() }

        // Each file as it is now, and how far its complete lines reach.
        var reads: [Read] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
            reads.append(Read(name: url.lastPathComponent, data: data,
                              complete: data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0))
        }
        let requested = reads.map(\.name)

        var resultLines: [HistoryLine]
        var resultSpans: [String: Span]
        if requested == names, !names.isEmpty, reads.allSatisfy({ isHeldUnchanged($0) }) {
            // Nothing new: the very array already held.
            resultLines = combined
            resultSpans = spans
        } else if requested == names, !names.isEmpty, let newest = reads.last,
                  reads.dropLast().allSatisfy({ isHeldUnchanged($0) }), let span = spans[newest.name],
                  Self.continues(span.size, head: span.head, tail: span.tail, samples: span.samples, in: newest.data), newest.complete > span.size {
            // The usual case: lines added at the end of the newest month. Only they are parsed.
            let added = HistoryLogReader.parse(newest.data[span.size..<newest.complete])
            combined.append(contentsOf: added)
            spans[newest.name] = Self.span(of: newest, count: span.count + added.count)
            saveHeld(newest.name, isNewest: true)
            resultLines = combined
            resultSpans = spans
        } else {
            let built = build(from: reads)
            if names.isEmpty || Set(requested).isSuperset(of: names) {
                names = requested
                spans = built.spans
                combined = built.lines
            }
            // A smaller request (the follower share reads the newest months only)
            // is answered without dropping the months the statistics keep.
            resultLines = built.lines
            resultSpans = built.spans
        }

        // A last line with no line break yet is still being written: read it as a
        // full read would, every time, and never keep it.
        var start = 0
        for (index, read) in reads.enumerated() {
            start += resultSpans[read.name]?.count ?? 0
            if read.complete < read.data.count {
                let fragment = HistoryLogReader.parse(read.data[read.complete..<read.data.count])
                resultLines.insert(contentsOf: fragment, at: start)
                start += fragment.count
            }
            progress?(Double(index + 1) / Double(max(reads.count, 1)))
        }
        return resultLines
    }

    private struct Read {
        let name: String
        let data: Data
        /// Bytes up to and including the last line break.
        let complete: Int
    }

    private func isHeldUnchanged(_ read: Read) -> Bool {
        guard let span = spans[read.name] else { return false }
        return span.size == read.complete && Self.continues(span.size, head: span.head, tail: span.tail, samples: span.samples, in: read.data)
    }

    private static func span(of read: Read, count: Int) -> Span {
        Span(size: read.complete,
             head: read.data.subdata(in: 0..<min(checkLength, read.complete)),
             tail: read.data.subdata(in: max(0, read.complete - checkLength)..<read.complete),
             samples: samples(of: read.data, size: read.complete),
             count: count)
    }

    /// Where `name`'s records start in `combined`.
    private func heldStart(of name: String) -> Int? {
        var start = 0
        for other in names {
            if other == name { return start }
            start += spans[other]?.count ?? 0
        }
        return nil
    }

    /// The records of `reads`, reusing what is held and what was saved wherever
    /// the file still begins with the bytes they came from, and parsing the rest.
    private func build(from reads: [Read]) -> (lines: [HistoryLine], spans: [String: Span]) {
        var lines: [HistoryLine] = []
        var builtSpans: [String: Span] = [:]
        for (index, read) in reads.enumerated() {
            var month: [HistoryLine] = []
            var parsedUpTo = 0
            // Whether the saved copy already matches what `month` will be.
            var savedIsCurrent = false
            if let span = spans[read.name], let start = heldStart(of: read.name),
               Self.continues(span.size, head: span.head, tail: span.tail, samples: span.samples, in: read.data) {
                month = Array(combined[start..<(start + span.count)])
                parsedUpTo = span.size
                // A held month was saved when it changed, unless it was the newest
                // (saved at most every 15 minutes): save that one again.
                savedIsCurrent = names.last != read.name
            } else if let saved = loadSaved(read.name),
                      Self.continues(saved.size, head: saved.head, tail: saved.tail, samples: saved.samples, in: read.data) {
                month = saved.lines
                parsedUpTo = saved.size
                savedIsCurrent = true
            }
            if read.complete > parsedUpTo {
                month.append(contentsOf: HistoryLogReader.parse(read.data[parsedUpTo..<read.complete]))
                savedIsCurrent = false
            }
            let span = Self.span(of: read, count: month.count)
            builtSpans[read.name] = span
            if !savedIsCurrent {
                saveMonth(read.name, Month(schema: Self.schema, size: span.size, head: span.head, tail: span.tail, samples: span.samples, lines: month),
                          isNewest: index == reads.count - 1)
            }
            lines.append(contentsOf: month)
        }
        return (lines, builtSpans)
    }

    /// True when `data` still begins with the `size` bytes recorded by `head`,
    /// `tail` and `samples`.
    ///
    /// ⚠️ A CHECK, NOT A PROOF. Loop only ever appends to the log and the SSD
    /// backup refuses anything else, so this catches a file that was replaced,
    /// cut short or edited near its ends or at a sample. An edit by hand that
    /// touches none of those would go unnoticed: after editing a log file by hand,
    /// delete the app's Caches/HistoryArchive folder (or reinstall).
    private static func continues(_ size: Int, head: Data, tail: Data, samples: [Data], in data: Data) -> Bool {
        guard size >= 0, data.count >= size, head.count <= size, tail.count <= size,
              samples.count == sampleOffsets(size).count else { return false }
        guard data.subdata(in: 0..<head.count) == head,
              data.subdata(in: (size - tail.count)..<size) == tail else { return false }
        for (offset, sample) in zip(sampleOffsets(size), samples)
            where data.subdata(in: offset..<min(size, offset + sampleLength)) != sample {
            return false
        }
        return true
    }

    private static let sampleLength = 512

    /// Eight places spread across the first `size` bytes.
    private static func sampleOffsets(_ size: Int) -> [Int] {
        guard size > 2 * checkLength else { return [] }
        return (1...8).map { size * $0 / 9 }
    }

    private static func samples(of data: Data, size: Int) -> [Data] {
        sampleOffsets(size).map { data.subdata(in: $0..<min(size, $0 + sampleLength)) }
    }

    // MARK: Saved months

    private func cacheURL(_ name: String) -> URL? {
        cacheDirectory?.appendingPathComponent(name + ".parsed")
    }

    /// Save a held month (its records are a stretch of `combined`).
    private func saveHeld(_ name: String, isNewest: Bool) {
        guard let span = spans[name], let start = heldStart(of: name) else { return }
        if isNewest, let last = lastSaved[name], Date().timeIntervalSince(last) < Self.newestSaveInterval { return }
        saveMonth(name, Month(schema: Self.schema, size: span.size, head: span.head, tail: span.tail,
                              samples: span.samples, lines: Array(combined[start..<(start + span.count)])),
                  isNewest: isNewest)
    }

    private func saveMonth(_ name: String, _ month: Month, isNewest: Bool) {
        guard let url = cacheURL(name) else { return }
        if isNewest, let last = lastSaved[name], Date().timeIntervalSince(last) < Self.newestSaveInterval { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(month) else { return }
        #if os(iOS)
        // Health data: as protected as the log itself, and like it readable by
        // the background report while the phone is locked.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
        lastSaved[name] = Date()
    }

    private func loadSaved(_ name: String) -> Month? {
        guard let url = cacheURL(name),
              let data = try? Data(contentsOf: url),
              let month = try? PropertyListDecoder().decode(Month.self, from: data),
              month.schema == Self.schema else { return nil }
        return month
    }
}

// MARK: - De-duplication

/// The log is APPEND-ONLY and legitimately contains the same event more than
/// once. Anything that COUNTS records has to collapse those repeats first.
///
/// ⚠️ THIS IS WHY "INSULIN PER DAY" READ TOO HIGH. `DeviceDataManager` records
/// every batch of pump events as it arrives, and LoopKit re-reports events it
/// has already sent whenever the pump reconciles them (`replacePendingEvents`
/// tells the DoseStore to REPLACE them — the log has no such mechanism and keeps
/// both). In one real container a third of all dose records were repeats, so
/// every insulin total was inflated by roughly that much. Editing a carb entry
/// does the same for meals: the edit runs through the same chokepoint and
/// appends a second record for the same meal.
///
/// Keeping the log append-only is deliberate — it is what makes a crash cost at
/// most one line — so the fix belongs HERE, on the read side.
enum HistoryLineDeduplicator {

    /// Collapse repeated records, keeping the LAST occurrence of each.
    ///
    /// Last, not first: a re-reported dose is the reconciled one (delivered
    /// units filled in), and an edited meal record is the corrected one.
    ///
    /// A DELETED NOTE shares the key of the record it deletes, so when it comes
    /// last the record is dropped and only the note (`t == "deleted"`, which no
    /// statistic reads) remains. A record re-added after the note comes back.
    /// ⚠️ So filter by type AFTER this, or keep "deleted" lines in the filter.
    static func deduplicated(_ lines: [HistoryLine]) -> [HistoryLine] {
        var lastIndexForKey: [String: Int] = [:]
        var keyForIndex: [Int: String] = [:]

        for (index, line) in lines.enumerated() {
            guard let key = line.duplicateKey else { continue }
            keyForIndex[index] = key
            lastIndexForKey[key] = index
        }
        guard !lastIndexForKey.isEmpty else { return lines }

        var result: [HistoryLine] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if let key = keyForIndex[index], lastIndexForKey[key] != index { continue }
            result.append(line)
        }
        return result
    }
}

extension HistoryLine {
    /// Identity used to spot a repeat, or nil for records that must never be
    /// collapsed.
    ///
    /// `syncIdentifier` is the reliable key and is preferred wherever the record
    /// carries one. The fallbacks are chosen to be safe rather than thorough:
    ///
    /// • DOSE — same kind, same instant, same amount. A pump cannot deliver two
    ///   different boluses at the same second, so this can only be the same one.
    /// • GLUCOSE — same instant, same value. Backfill re-delivers readings the
    ///   log has already seen; counting them twice skews time-in-range and makes
    ///   sensor coverage read above 100%.
    /// • MEAL — syncIdentifier ONLY, deliberately no fallback. One meal can be
    ///   saved as several components sharing a start time, and two of them can
    ///   legitimately be the same size; collapsing those would DELETE carbs the
    ///   user really ate. Over-counting an edited meal is the lesser error.
    /// • STATUS/POD — never collapsed here (`status` is the follower feed, and a
    ///   pod record is written once per session by construction).
    var duplicateKey: String? {
        switch t {
        case "dose":
            if let syncIdentifier, !syncIdentifier.isEmpty { return "dose|\(syncIdentifier)" }
            return "dose|\(kind ?? "?")|\(at)|\(units ?? -1)|\(unitsPerHour ?? -1)"
        case "glucose":
            if let syncIdentifier, !syncIdentifier.isEmpty { return "glucose|\(syncIdentifier)" }
            return "glucose|\(at)|\(mgdl ?? -1)"
        case "meal":
            guard let syncIdentifier, !syncIdentifier.isEmpty else { return nil }
            return "meal|\(syncIdentifier)"
        case "deleted":
            guard let of, let syncIdentifier, !syncIdentifier.isEmpty else { return nil }
            return "\(of)|\(syncIdentifier)"
        default:
            return nil
        }
    }
}

// MARK: - Import

/// Works out which records of an imported history file the log is missing.
///
/// ⚠️ ADD-ONLY. An import never changes or removes anything already in the log:
/// a record the log already has (the same identity the de-duplicator uses) is
/// skipped, and each record it lacks is appended, carrying the ADDED NOTE
/// (`addedAt`, `addedVia: "import"`). Not imported: status records (they only
/// feed Loop Follow's live screen), anything dated in the future, and lines that
/// do not read as a record.
enum HistoryImporter {
    struct Plan {
        /// Encoded lines to append, each with the date that picks its month file.
        var lines: [(data: Data, date: Date)] = []
        /// How many of `lines` are of each type ("glucose", "dose", …).
        var added: [String: Int] = [:]
        /// Records the log already has, left as they are.
        var alreadyThere = 0
        /// Lines that are unreadable, in the future, or of a type not imported.
        var skipped = 0
        var count: Int { lines.count }
    }

    static let importedTypes: Set<String> = ["glucose", "dose", "meal", "pod", "deleted"]

    static func plan(importing files: [Data], existing: [HistoryLine], now: Date = Date()) -> Plan {
        var known = Set(existing.compactMap(identity))
        var plan = Plan()
        let stamp = HistoryTimestamp.string(from: now)
        let decoder = JSONDecoder()
        for data in files {
            for raw in data.split(separator: 0x0A) where !raw.isEmpty {
                let lineData = Data(raw)
                guard let line = try? decoder.decode(HistoryLine.self, from: lineData),
                      importedTypes.contains(line.t),
                      let date = HistoryTimestamp.formatter.date(from: line.at),
                      date <= now.addingTimeInterval(3600),
                      let key = identity(line),
                      var object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                else {
                    plan.skipped += 1
                    continue
                }
                guard !known.contains(key) else {
                    plan.alreadyThere += 1
                    continue
                }
                known.insert(key)
                object["addedAt"] = stamp
                object["addedVia"] = "import"
                guard var encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                    plan.skipped += 1
                    continue
                }
                encoded.append(0x0A)
                plan.lines.append((encoded, date))
                plan.added[line.t, default: 0] += 1
            }
        }
        return plan
    }

    /// What a record is matched on: the de-duplicator's key; for a pod session,
    /// which has none, its start and end; for a deleted note, what it deletes.
    static func identity(_ line: HistoryLine) -> String? {
        switch line.t {
        case "pod":
            return "pod|\(line.activatedAt ?? "?")|\(line.at)"
        case "deleted":
            return line.duplicateKey.map { "deleted|\($0)" }
        default:
            return line.duplicateKey
        }
    }
}
