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
struct HistoryLine: Decodable {
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
    /// Read every record in the given files, oldest first.
    ///
    /// One file is held in memory at a time — that is a month, a few MB — rather
    /// than the whole history. Malformed lines are skipped silently; a log that
    /// refuses to open because of one bad byte would be worse than useless.
    static func read(files: [URL], progress: ((Double) -> Void)? = nil) -> [HistoryLine] {
        var results: [HistoryLine] = []
        let ordered = files.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for (index, url) in ordered.enumerated() {
            results.append(contentsOf: lines(in: url))
            progress?(Double(index + 1) / Double(max(ordered.count, 1)))
        }
        return results
    }

    /// Parsed lines of one monthly file, reused while the file is unchanged.
    ///
    /// The statistics screen and the live report both re-read every month on each
    /// open/refresh, but only the current month ever grows — past months were being
    /// parsed again for nothing. Keyed on size + modification date, so an append is
    /// always picked up. `NSCache` lets iOS drop it under memory pressure.
    private final class ParsedFile {
        let size: Int
        let modified: Date
        let lines: [HistoryLine]
        init(size: Int, modified: Date, lines: [HistoryLine]) {
            self.size = size
            self.modified = modified
            self.lines = lines
        }
    }

    private static let cache: NSCache<NSURL, ParsedFile> = {
        let cache = NSCache<NSURL, ParsedFile>()
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()

    private static func lines(in url: URL) -> [HistoryLine] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate ?? .distantPast
        if let hit = cache.object(forKey: url as NSURL), hit.size == size, hit.modified == modified {
            return hit.lines
        }

        let decoder = JSONDecoder()
        var parsed: [HistoryLine] = []
        autoreleasepool {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                // ⚠️ STATUS RECORDS ARE SKIPPED BEFORE THEY ARE PARSED. One is
                // written every loop cycle for Loop Follow's live screen, with
                // its predicted-glucose and insulin timelines, and together they
                // are 90% of the file (82 of 92 MB on 60 days). Nothing that
                // reads through here uses them: the statistics never did, and the
                // follower share fetches the newest status on its own. Parsing
                // them was most of the time and memory every open took.
                if Self.isStatusLine(line) { continue }
                if var decoded = try? decoder.decode(HistoryLine.self, from: Data(line)), decoded.t != "status" {
                    // Parse the timestamp once, here, for every later pass.
                    decoded.parsedDate = HistoryTimestamp.formatter.date(from: decoded.at)
                    parsed.append(decoded)
                }
            }
        }
        if size >= 0 {
            cache.setObject(ParsedFile(size: size, modified: modified, lines: parsed), forKey: url as NSURL,
                            cost: parsed.count * MemoryLayout<HistoryLine>.stride)
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
