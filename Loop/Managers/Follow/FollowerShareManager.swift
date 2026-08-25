//
//  FollowerShareManager.swift
//  Loop
//
//  Owns the CONNECTION to follower devices: the CloudKit shared zone, the
//  CKShare that grants access to it, the list of paired followers, revocation —
//  and, at the bottom of this file, the PUBLISHER that writes the feed into that
//  zone.
//
//  Publishing lives here rather than in its own file only because the Loop
//  project has no file-system-synchronized groups: a new file means hand-editing
//  a 60-format pbxproj, and this repo currently has ~67 uncommitted files and no
//  baseline commit to fall back to. When there is a clean baseline, lift
//  `FollowerPublisher` out into `Managers/Follow/FollowerPublisher.swift`.
//
//  ── HARD BOUNDARY ───────────────────────────────────────────────────────────
//  ONE-WAY, ALWAYS. Data flows Loop → follower and nothing comes back. There is
//  no inbound listener here, no subscription to follower writes, no "request
//  access" path, and participants are granted `.readOnly` so CloudKit itself
//  enforces the same rule underneath the app.
//
//  Do not add a write path from the follower side, even if a future request
//  sounds harmless (an acknowledgement, a "seen" receipt, a reconnect request).
//  The follower becoming able to send anything to this device makes it an attack
//  surface on an insulin pump. See Loop-Follower-App-Plan-2026-08-13.md.
//
//  This file also touches NOTHING to do with dosing. It reads no algorithm
//  state, mutates nothing, and is never on the loop's critical path.
//  ────────────────────────────────────────────────────────────────────────────
//

import CloudKit
import Foundation
import HealthKit
import LoopCore
import LoopKit
import os.log

/// One paired follower, as this device knows them.
///
/// The `name` is the patient's own label ("Mum", "Dad") and is stored LOCALLY,
/// on this device only. It is never written to CloudKit and never travels to any
/// follower — one follower must not learn who the others are.
struct FollowerConnection: Identifiable, Codable, Equatable {
    /// Stable local id. Not a CloudKit identifier.
    let id: UUID
    /// Patient-chosen label. Required — a Revoke button next to an anonymous
    /// participant id is useless in the moment you actually need it.
    var name: String
    var invitedAt: Date
    /// `CKShare.Participant.userIdentity.lookupInfo` encoded, when the invite has
    /// been accepted and CloudKit can tell us who took it. Optional on purpose:
    /// CloudKit may return nothing, and the UI must not depend on it.
    var participantLookupData: Data?

    enum Status: String, Codable {
        case invited     // share created, nobody has accepted yet
        case active      // a participant accepted
        case removed     // revoked by the patient
    }
    var status: Status
}

@MainActor
final class FollowerShareManager: ObservableObject {

    static let shared = FollowerShareManager()

    private let log = OSLog(category: "FollowerShareManager")

    /// ⚠️ A SEPARATE container from the history log's iCloud Drive container
    /// (Step AP, `iCloud.com.uriBregman.loopkit.basal.Loop`). Two reasons: that
    /// one is a ubiquity/file container and this is CloudKit records — Apple does
    /// not support mixing them cleanly — and a bug in follower sync must not be
    /// able to touch the history log the user depends on.
    static let containerIdentifier = "iCloud.com.uriBregman.loopkit.basal.LoopFollowShare"

    /// Sharing requires a CUSTOM zone; the default zone cannot be shared.
    static let zoneName = "FollowerFeed"

    /// Max 3 followers, per the plan. Enforced here rather than only in the UI so
    /// the limit survives a future second entry point.
    static let maximumFollowers = 3

    @Published private(set) var connections: [FollowerConnection] = []
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    // MARK: - Invite draft
    //
    // ⚠️ THE TYPED NAME LIVES HERE, NOT IN THE VIEW'S `@State`.
    //
    // `FollowSettingsView` is the destination of a `NavigationLink` inside the
    // Settings list, and that list re-renders whenever `SettingsViewModel`
    // publishes — which it does constantly, on every loop cycle and device
    // update. SwiftUI re-initialises a destination view when its parent
    // re-renders, and every `@State` the destination owns goes back to its
    // initial value.
    //
    // So the name was being wiped between typing it and tapping "Create
    // Invitation", `makeShare` got an empty string, and the user was told to
    // "give this follower a name" immediately after doing exactly that.
    //
    // This manager is a singleton and outlives the view, so the draft survives
    // the re-render. Do not move these back into the view.

    /// The name being typed for a new follower.
    @Published var draftName: String = ""

    /// Whether the name field is showing.
    @Published var isNamingFollower = false

    /// Clears the draft. Called on cancel and after a successful invite.
    func clearDraft() {
        draftName = ""
        isNamingFollower = false
    }

    /// §14.4 — the patient's own display label, shown at the top of every
    /// follower's screen. Optional; blank means the follower shows "Loop".
    ///
    /// Backed by `UserDefaults` because the publisher reads it from a background
    /// queue, and `@Published` here so the settings field updates live.
    @Published var patientLabel: String = UserDefaults.standard
        .string(forKey: FollowerPublisher.patientLabelKey) ?? "" {
        didSet {
            UserDefaults.standard.set(patientLabel, forKey: FollowerPublisher.patientLabelKey)
        }
    }

    private let container: CKContainer
    private var privateDB: CKDatabase { container.privateCloudDatabase }

    private static let storageKey = "com.loopkit.Loop.followerConnections"

    private init() {
        container = CKContainer(identifier: Self.containerIdentifier)
        connections = Self.loadConnections()
    }

    // MARK: - Local persistence
    //
    // Names live in UserDefaults on THIS device only. Deliberately not in the
    // shared zone: see the type's own comment.

    private static func loadConnections() -> [FollowerConnection] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FollowerConnection].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    var canAddFollower: Bool {
        connections.filter { $0.status != .removed }.count < Self.maximumFollowers
    }

    // MARK: - Zone

    /// Creates the shared zone if it isn't there yet. Idempotent.
    private func ensureZone() async throws -> CKRecordZone {
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        do {
            return try await privateDB.recordZone(for: zoneID)
        } catch {
            // Not found is the expected first-run path; anything else is real.
            let zone = CKRecordZone(zoneID: zoneID)
            return try await privateDB.save(zone)
        }
    }

    // MARK: - Inviting

    /// Creates (or reuses) the share for the follower feed and returns it ready to
    /// hand to `UICloudSharingController`.
    ///
    /// The connection is ALWAYS created here, on the patient's device. There is no
    /// follower-initiated pairing anywhere in this project — a follower asking to
    /// be added would be an inbound message, which is exactly what the one-way
    /// rule forbids.
    func makeShare(forFollowerNamed name: String) async throws -> (CKShare, CKContainer) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FollowerShareError.nameRequired }
        guard canAddFollower else { throw FollowerShareError.tooManyFollowers }

        isBusy = true
        defer { isBusy = false }

        let zone = try await ensureZone()
        // Written out rather than with `??`: the right-hand side is an async call
        // and `??` takes an autoclosure, which cannot be async.
        let share: CKShare
        if let existing = try await existingShare(for: zone.zoneID) {
            share = existing
        } else {
            share = try await makeNewShare(for: zone.zoneID)
        }

        // Named for the humans involved, but deliberately NOT the patient's name
        // or anything identifying — this string can appear in a share sheet, a
        // notification and a screenshot.
        share[CKShare.SystemFieldKey.title] = "Loop Follower Feed" as CKRecordValue

        var connection = FollowerConnection(id: UUID(),
                                            name: trimmed,
                                            invitedAt: Date(),
                                            participantLookupData: nil,
                                            status: .invited)
        connection.status = .invited
        connections.append(connection)
        persist()

        return (share, container)
    }

    private func existingShare(for zoneID: CKRecordZone.ID) async throws -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            return try await privateDB.record(for: shareID) as? CKShare
        } catch {
            return nil
        }
    }

    private func makeNewShare(for zoneID: CKRecordZone.ID) async throws -> CKShare {
        let share = CKShare(recordZoneID: zoneID)

        // ⚠️ READ ONLY. This is CloudKit's own enforcement of the one-way rule,
        // sitting underneath the app-level guarantee that the follower app links
        // no code capable of writing. Two independent layers, on purpose.
        //
        // ⚠️ THIS WAS A LIE UNTIL 2026-08-16. The comment above has always said
        // participants are read-only; the code only ever set `publicPermission`,
        // which governs people who are NOT participants. Every invited follower
        // was being granted CloudKit's default `.readWrite`. The app-level
        // guarantee still held — the follower target links no write path — but
        // the second, independent layer did not exist, and the comment stopped
        // anyone looking. Do not remove either line.
        share.publicPermission = .none
        for participant in share.participants where participant.role != .owner {
            participant.permission = .readOnly
        }

        let saved = try await privateDB.save(share)
        guard let typed = saved as? CKShare else { throw FollowerShareError.shareCreationFailed }
        return typed
    }

    // MARK: - Refreshing status

    /// Reconciles local connections against CloudKit's participant list.
    ///
    /// ⚠️ Only ACCEPTANCE state is available here. CloudKit does NOT reliably tell
    /// the owner when a participant last READ anything, so this deliberately does
    /// not attempt a "last seen" — inventing one would be exactly the kind of
    /// confident-looking fiction this project keeps having to remove.
    func refreshStatus() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
            guard let share = try await existingShare(for: zoneID) else { return }

            // Pin every non-owner to read-only on every refresh. A participant
            // added through `UICloudSharingController` after the share was
            // created does not inherit what was set above, and §12.3 says to
            // READ the granted permission back rather than trust the UI flow.
            var needsSave = false
            for participant in share.participants where participant.role != .owner {
                if participant.permission != .readOnly {
                    participant.permission = .readOnly
                    needsSave = true
                }
            }
            if needsSave { _ = try await privateDB.save(share) }

            let accepted = share.participants.filter {
                $0.acceptanceStatus == .accepted && $0.role != .owner
            }

            // Mark as many invited connections active as there are accepted
            // participants. Names are ours, participants are CloudKit's, and the
            // two cannot be matched reliably — so this is intentionally coarse
            // rather than pretending to a precision it does not have.
            var remainingAccepted = accepted.count
            for index in connections.indices where connections[index].status != .removed {
                if remainingAccepted > 0 {
                    connections[index].status = .active
                    remainingAccepted -= 1
                } else {
                    connections[index].status = .invited
                }
            }
            persist()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            os_log("Follower status refresh failed: %{public}@", log: log, type: .error,
                   String(describing: error))
        }
    }

    // MARK: - Revoking

    /// Removes a follower's access.
    ///
    /// ⚠️ CloudKit ACL changes are not always instant. Do not tell the user access
    /// is gone the moment this returns — the UI says "removing…" and the plan
    /// requires verifying the access loss actually takes effect on the follower.
    func revoke(_ connection: FollowerConnection) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
            if let share = try await existingShare(for: zoneID) {
                let others = share.participants.filter { $0.role != .owner }
                // With names held locally and participants held by CloudKit there
                // is no reliable mapping between them. When this is the last
                // follower, remove every participant — unambiguous. Otherwise
                // removal is left to the share sheet, which shows CloudKit's own
                // identities and can target one person correctly.
                let activeCount = connections.filter { $0.status != .removed }.count
                if activeCount <= 1 {
                    for participant in others {
                        share.removeParticipant(participant)
                    }
                    _ = try await privateDB.save(share)
                }
            }
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[index].status = .removed
                persist()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            os_log("Revoke failed: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    /// Forgets a removed follower entirely, taking the local label with it.
    func forget(_ connection: FollowerConnection) {
        connections.removeAll { $0.id == connection.id }
        persist()
    }
}

enum FollowerShareError: LocalizedError {
    case nameRequired
    case tooManyFollowers
    case shareCreationFailed

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return NSLocalizedString("Give this follower a name first.",
                                     comment: "Error when inviting a follower without a name")
        case .tooManyFollowers:
            return NSLocalizedString("You can have up to 3 followers.",
                                     comment: "Error when exceeding the follower limit")
        case .shareCreationFailed:
            return NSLocalizedString("Could not create the invitation. Check that you are signed in to iCloud.",
                                     comment: "Error when CloudKit share creation fails")
        }
    }
}

// MARK: - The publisher (Stage F2/F4)

/// Turns the history log into the one CloudKit record the follower reads.
///
/// ── SHAPE OF THE FEED ───────────────────────────────────────────────────────
/// ONE record, `recordName: "current"`, overwritten on every publish, holding a
/// JSON payload. Not one record per cycle: those would accumulate forever in the
/// shared zone, and the follower already keeps its own durable log and
/// de-duplicates what it receives. A rolling window is bounded and idempotent.
///
/// ⚠️ CONSEQUENCE TO KNOW: this publishes a WINDOW, not full history. §10.4 of
/// the plan wants the follower to eventually receive everything ("the exact
/// thing that main Loop sees"), and a first-sync backfill of ~35 MB/year is a
/// separate job that does not belong on the loop's heels. What a new follower
/// gets today is the recent window, filling out as it keeps reading.
///
/// ── OFF THE CRITICAL PATH ───────────────────────────────────────────────────
/// §15.2 rule 1. Everything here runs on its own queue, is fire-and-forget, and
/// swallows its own errors. Publishing is a background CONSEQUENCE of new data,
/// never something the loop waits on. If iCloud is slow or down — and it will
/// be, regularly — the loop must not notice.
///
/// ⛔ Nothing here reads anything back from a follower. No subscription to
/// follower writes, no acknowledgement, no inbound path. See the banner at the
/// top of this file.
@MainActor
final class FollowerPublisher: ObservableObject {

    static let shared = FollowerPublisher()

    // MARK: - Visible state
    //
    // Publishing is otherwise completely invisible: it happens on a background
    // queue, swallows its own errors by design, and the only evidence is a log
    // line. That is fine in normal use and useless when you are trying to work
    // out whether the feature works at all. These three drive a status line in
    // Settings → Follow.

    @Published private(set) var lastPublishedAt: Date?
    @Published private(set) var lastPublishError: String?
    @Published private(set) var lastPayloadBytes: Int?

    private let log = OSLog(category: "FollowerPublisher")

    /// Serialises publishing, and keeps every byte of it off the caller's queue.
    private let queue = DispatchQueue(label: "com.loopkit.Loop.followerPublisher", qos: .utility)

    private let container = CKContainer(identifier: FollowerShareManager.containerIdentifier)
    private var privateDB: CKDatabase { container.privateCloudDatabase }

    /// How much history each publish carries. A day covers the follower's charts
    /// and its 24-hour detail lists; anything older it already has.
    private let window: TimeInterval = .hours(24)

    /// Don't republish more often than this. The loop runs every five minutes and
    /// the CGM produces a reading every five minutes; there is nothing to gain
    /// from going faster, and a failed publish must not become a retry storm.
    private let minimumInterval: TimeInterval = .minutes(4)
    private var lastAttempt: Date?

    private init() {}

    /// Publish the current window. Safe to call from anywhere, including a
    /// device-manager callback — it returns immediately.
    ///
    /// - Parameter force: skip the rate limit. Only for the manual "Publish Now"
    ///   button; the automatic path must stay rate-limited so a failing publish
    ///   cannot become a retry storm.
    nonisolated func publish(force: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if !force, let last = self.lastAttempt,
                   Date().timeIntervalSince(last) < self.minimumInterval { return }
                self.lastAttempt = Date()
                await self.performPublish()
            }
        }
    }

    private func performPublish() async {
        do {
            let payload = try await buildPayload()

            // §3.1's denied-key scan, at the PUBLISHER — the only place it can do
            // any good. A secret that reaches the follower is already exposed: it
            // is in memory, in the cache and in the device backup, whether or not
            // the UI draws it. Refusing to send is the whole control.
            try FollowerPayloadAudit.check(payload)

            let zoneID = CKRecordZone.ID(zoneName: FollowerShareManager.zoneName,
                                         ownerName: CKCurrentUserDefaultName)
            let recordID = CKRecord.ID(recordName: "current", zoneID: zoneID)

            // Fetch-then-update so CloudKit's change tag is respected. A missing
            // record on first run is the expected path, not an error.
            let record: CKRecord
            if let existing = try? await privateDB.record(for: recordID) {
                record = existing
            } else {
                record = CKRecord(recordType: "FollowerFeed", recordID: recordID)
            }
            record["payload"] = payload as CKRecordValue
            record["publishedAt"] = Date() as CKRecordValue

            _ = try await privateDB.save(record)
            os_log("Published follower feed (%d bytes)", log: log, type: .default, payload.count)

            lastPublishedAt = Date()
            lastPayloadBytes = payload.count
            lastPublishError = nil
        } catch {
            // Still swallowed as far as the LOOP is concerned — nothing upstream
            // waits on this or can do anything useful with a failure. It is only
            // surfaced in Settings → Follow, where someone is deliberately
            // looking.
            os_log("Follower publish failed: %{public}@", log: log, type: .error,
                   String(describing: error))
            lastPublishError = error.localizedDescription
        }
    }

    // MARK: - Building the payload
    //
    // ⚠️ ALLOW-LIST, DENY BY DEFAULT (§3.1). A field is here because someone could
    // say why a follower needs it.
    //
    // ⚠️ THE OBVIOUS IMPLEMENTATION IS THE WRONG ONE. The history log is already
    // tidy JSONL, so forwarding those lines verbatim is tempting. DO NOT. That log
    // carries `syncIdentifier` on every glucose/meal/dose record and
    // `lotNo`/`lotSeq`/`podType`/`firmwareVersion` on every pod record. A pump
    // identifier is a radio command credential and a transmitter id is a pairing
    // secret. Each line is rebuilt below, field by chosen field.

    private func buildPayload() async throws -> Data {
        let files = await withCheckedContinuation { continuation in
            HistoryLogStore.shared.loadFiles { continuation.resume(returning: $0) }
        }
        // The newest one or two monthly files can hold a 24-hour window.
        let urls = Array(files.prefix(2)).map(\.url)
        let lines = HistoryLogReader.read(files: urls)
        let cutoff = Date().addingTimeInterval(-window)

        var records: [[String: Any]] = []
        for line in lines {
            guard let date = line.date, date >= cutoff else { continue }
            var record: [String: Any?] = ["v": 1, "t": line.t, "at": line.at]

            switch line.t {
            case "glucose":
                record["mgdl"] = line.mgdl
                record["trendRate"] = line.trendRate
                // `source` is dropped: on some CGMs it names the transmitter.
            case "meal":
                record["grams"] = line.grams
                record["absorption"] = line.absorption
                record["eatenAt"] = line.eatenAt
                record["enteredAt"] = line.enteredAt
                record["mealName"] = line.mealName
            case "dose":
                record["kind"] = line.kind
                record["units"] = line.units
                record["unitsPerHour"] = line.unitsPerHour
                record["automatic"] = line.automatic
            case "pod":
                // A LABEL, never an identifier: no lotNo, lotSeq, podType or
                // firmwareVersion.
                record["activatedAt"] = line.activatedAt
                record["hoursRun"] = line.hoursRun
                record["totalDelivered"] = line.totalDelivered
                record["remainingAtStop"] = line.remainingAtStop
                record["stopReason"] = line.stopReason
                record["faultCode"] = line.faultCode
            default:
                // `status` and `settings` are carried separately, from the
                // newest of each. Unknown future types are skipped rather than
                // forwarded blind.
                continue
            }
            records.append(record.compactMapValues { $0 })
        }

        var payload: [String: Any] = [
            "v": 1,
            "publishedAt": HistoryTimestamp.string(from: Date()),
            "anchor": HistoryTimestamp.string(from: Date()),
            "records": records
        ]
        if let status = newestRawRecord(named: "status", in: urls) {
            payload["status"] = status
        }
        payload["settings"] = await buildSettings()

        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// The newest `status` line, read back as raw JSON.
    ///
    /// `HistoryLine` is the tolerant READER and has no status fields, so the raw
    /// object is re-read rather than re-modelled. `HistoryLogger` already writes
    /// that record from an allow-list, and `FollowerPayloadAudit` checks the
    /// result regardless.
    private func newestRawRecord(named type: String, in urls: [URL]) -> [String: Any]? {
        for url in urls {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            // Newest line wins, so scan from the end.
            for raw in data.split(separator: 0x0A).reversed() where !raw.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                      object["t"] as? String == type else { continue }
                return object
            }
        }
        return nil
    }

    /// The therapy settings snapshot, read OUTSIDE the loop cycle.
    ///
    /// This runs on the publisher's own queue, long after any dose decision, so
    /// reading settings here cannot influence one.
    /// Supplies the current therapy settings.
    ///
    /// A closure rather than a direct reference because `SettingsManager` is
    /// INJECTED into `DeviceDataManager`, not a singleton — and reaching for one
    /// from here would mean either inventing a global or holding a strong
    /// reference to a device manager from a publisher, both worse. Wired once in
    /// `DeviceDataManager`, alongside the history logger.
    ///
    /// Nil until that wiring runs; the settings snapshot is simply omitted until
    /// then, which is the honest behaviour — better an absent settings record
    /// than a half-built one.
    var settingsProvider: (() -> LoopSettings?)?

    @MainActor
    private func buildSettings() -> [String: Any] {
        let settings = settingsProvider?()
        let mgdl = HKUnit.milligramsPerDeciliter

        var record: [String: Any?] = [
            "v": 1,
            "t": "settings",
            "at": HistoryTimestamp.string(from: Date()),
            "glucoseUnit": "mg/dL"
        ]
        record["patientLabel"] = UserDefaults.standard.string(forKey: Self.patientLabelKey)
        record["appVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        record["basalSchedule"] = settings?.basalRateSchedule?.items.map {
            ["startSeconds": $0.startTime, "value": $0.value]
        }
        record["insulinSensitivitySchedule"] = settings?.insulinSensitivitySchedule?.items.map {
            ["startSeconds": $0.startTime, "value": $0.value]
        }
        record["carbRatioSchedule"] = settings?.carbRatioSchedule?.items.map {
            ["startSeconds": $0.startTime, "value": $0.value]
        }
        record["correctionRangeSchedule"] = settings?.glucoseTargetRangeSchedule?.items.map {
            ["startSeconds": $0.startTime,
             "minMgdl": $0.value.minValue,
             "maxMgdl": $0.value.maxValue]
        }
        record["suspendThresholdMgdl"] = settings?.suspendThreshold?.quantity.doubleValue(for: mgdl)
        record["maximumBolus"] = settings?.maximumBolus
        record["maximumBasalRate"] = settings?.maximumBasalRatePerHour
        return record.compactMapValues { $0 }
    }

    /// §14.4 — the patient's own display label, chosen by them, travelling one
    /// way. Deliberately NOT defaulted from an Apple ID name or a device name.
    static let patientLabelKey = "com.loopkit.Loop.followerPatientLabel"
}

// MARK: - §3.1 enforcement, publisher side

/// The crude check that catches the exact mistake that matters: a device
/// identifier or credential added as a FIELD.
///
/// Keys, not values — scanning values would fire on a meal called "shallots".
/// Identifiers leak by being ADDED AS A FIELD, and that is what this catches.
enum FollowerPayloadAudit {

    static let deniedKeySubstrings = [
        "serial", "lot", "transmitter", "apikey", "api_key", "secret",
        "token", "syncidentifier", "firmware", "container", "uuid",
        "identifier", "address", "podtype"
    ]

    struct Violation: Error, CustomStringConvertible {
        let key: String
        let matched: String
        var description: String {
            "Follower payload key \"\(key)\" matches denied substring \"\(matched)\" — a device identifier or credential is leaking. See §3.1."
        }
    }

    /// Throws on the first denied key found, at any depth.
    ///
    /// ⚠️ Not a substitute for the §8 audit: capture a REAL payload and read it
    /// by eye, in full, at least once per stage. Only a human reading an actual
    /// payload catches "we added a helpful debug field".
    static func check(_ payload: Data) throws {
        let object = try JSONSerialization.jsonObject(with: payload)
        var keys: Set<String> = []
        collect(object, into: &keys)
        for key in keys {
            let lowered = key.lowercased()
            if let matched = deniedKeySubstrings.first(where: { lowered.contains($0) }) {
                throw Violation(key: key, matched: matched)
            }
        }
    }

    private static func collect(_ value: Any, into found: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                found.insert(key)
                collect(nested, into: &found)
            }
        } else if let array = value as? [Any] {
            for element in array { collect(element, into: &found) }
        }
    }
}
