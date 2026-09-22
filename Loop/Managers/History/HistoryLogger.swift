//
//  HistoryLogger.swift
//  Loop
//
//  Translates the device-data callbacks Loop already has into history records and
//  hands them to HistoryLogStore. This is the ONLY file that knows about both
//  LoopKit types and the log format, so the record schema and the app stay
//  decoupled.
//
//  HARD BOUNDARY: every method here is called from an existing observation seam
//  and does nothing but record. No dosing, no LoopKit save paths, no mutation of
//  anything Loop reads back.
//

import Foundation
import HealthKit
import LoopKit

final class HistoryLogger {
    /// Shared because the recording seams live in two different managers —
    /// DeviceDataManager (glucose, doses, reservoir) and LoopDataManager (carbs) —
    /// and the reservoir level tracked by one is needed by the other.
    static let shared = HistoryLogger()

    private let store: HistoryLogStore

    /// Anything that costs more than building a struct runs here, so no recording
    /// work ever lands on a caller's queue — several of these seams are on
    /// DeviceDataManager's and LoopDataManager's own queues.
    private let work = DispatchQueue(label: "com.loopkit.Loop.historyLogger", qos: .utility)

    init(store: HistoryLogStore = .shared) {
        self.store = store
        // Warm the storage-location lookup off the main thread now, so neither the
        // first append nor the settings screen has to wait on it later.
        store.prepare()
    }

    var isEnabled: Bool {
        get { store.isEnabled }
        set { store.isEnabled = newValue }
    }

    // MARK: - Glucose

    func record(glucose samples: [NewGlucoseSample]) {
        guard store.isEnabled, !samples.isEmpty else { return }
        let trendUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
        // Display-only and manually entered values are deliberately kept:
        // "what did I actually see" matters for reviewing an excursion later.
        store.append(contentsOf: samples.map { sample in
            (record: GlucoseHistoryRecord(
                at: HistoryTimestamp.string(from: sample.date),
                mgdl: sample.quantity.doubleValue(for: .milligramsPerDeciliter),
                trend: sample.trend.map { String(describing: $0) },
                trendRate: sample.trendRate?.doubleValue(for: trendUnit),
                source: sample.device?.name,
                syncIdentifier: sample.syncIdentifier
            ), date: sample.date)
        })
    }

    // MARK: - Doses

    func record(pumpEvents events: [NewPumpEvent]) {
        guard store.isEnabled else { return }
        store.append(contentsOf: events.compactMap { event in
            event.dose.map { (record: doseRecord($0), date: $0.startDate) }
        })
    }

    private func doseRecord(_ dose: DoseEntry) -> DoseHistoryRecord {
        // A dose's `value` means different things per unit, so read the two
        // meanings explicitly rather than writing an ambiguous number.
        let units: Double?
        let unitsPerHour: Double?
        switch dose.unit {
        case .units:
            units = dose.deliveredUnits ?? dose.programmedUnits
            unitsPerHour = nil
        case .unitsPerHour:
            // `deliveredUnits` is nil on most temp basals — it is only filled in
            // once the pump reconciles. Falling back to `programmedUnits`
            // (rate x duration) matters: without it every temp basal recorded
            // NO units at all, which silently emptied the basal side of total
            // daily dose and pushed the bolus share towards 100%.
            units = dose.deliveredUnits ?? dose.programmedUnits
            unitsPerHour = dose.unitsPerHour
        }
        return DoseHistoryRecord(
            at: HistoryTimestamp.string(from: dose.startDate),
            kind: String(describing: dose.type),
            units: units,
            unitsPerHour: unitsPerHour,
            endedAt: dose.endDate == dose.startDate ? nil : HistoryTimestamp.string(from: dose.endDate),
            automatic: dose.automatic,
            syncIdentifier: dose.syncIdentifier
        )
    }

    // MARK: - Pod sessions

    private static let lastPodKey = "com.loopkit.Loop.historyLastRecordedPod"

    /// Watch the pump's persisted state for a finished pod session.
    ///
    /// This is the record that CANNOT be reconstructed later:
    /// `OmniPumpManager.prepForNewPod()` copies the current pod state into the
    /// single `previousPodState` slot and OVERWRITES whatever was there. So each
    /// pod change destroys the session before last — miss it and it is gone.
    ///
    /// Read out of the raw state DICTIONARY rather than by importing OmnipodKit:
    /// pump managers are dynamically loaded plugins and the Loop app target does
    /// not link OmnipodKit at all, so importing it would mean a new framework
    /// dependency. The keys below are OmniPumpManagerState/PodState's own raw
    /// encoding. A non-Omnipod pump simply has no `previousPodState` and no pod
    /// records are written — which is correct.
    ///
    /// Called on every state update, so it is also the launch-time safety net:
    /// a pod change that happened while the app was dead is still picked up on
    /// the first state update after relaunch, because the dedupe below is keyed
    /// on the pod's identity rather than on having seen the transition live.
    func observePumpState(_ rawValue: [String: Any]) {
        guard store.isEnabled,
              let state = rawValue["state"] as? [String: Any],
              let pod = state["previousPodState"] as? [String: Any] else { return }

        let identity = podIdentity(pod)
        let defaults = UserDefaults.standard
        guard identity != defaults.string(forKey: Self.lastPodKey) else { return }
        defaults.set(identity, forKey: Self.lastPodKey)

        let record = podRecord(pod)
        store.append(record, at: pod["deliveryStoppedAt"] as? Date ?? Date())
    }

    /// Stable per-pod key, so the same finished session is never written twice —
    /// including across relaunches, where we can't remember having seen it.
    private func podIdentity(_ pod: [String: Any]) -> String {
        let lot = pod["lotNo"] as? UInt32 ?? pod["lot"] as? UInt32 ?? 0
        let seq = pod["lotSeq"] as? UInt32 ?? pod["tid"] as? UInt32 ?? 0
        let address = pod["address"] as? UInt32 ?? 0
        let activated = (pod["activatedAt"] as? Date).map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        return "\(lot)-\(seq)-\(address)-\(activated)"
    }

    private func podRecord(_ pod: [String: Any]) -> PodHistoryRecord {
        let activatedAt = pod["activatedAt"] as? Date
        let stoppedAt = pod["deliveryStoppedAt"] as? Date ?? Date()
        let expiresAt = pod["expiresAt"] as? Date

        let insulin = pod["lastInsulinMeasurements"] as? [String: Any]
        let delivered = insulin?["delivered"] as? Double
        let reservoir = insulin?["reservoirLevel"] as? Double

        // DetailedStatus encodes itself as raw bytes; the fault event code is
        // byte 8 (see DetailedStatus.init, `FaultEventCode(rawValue: data[8])`).
        var faultCode: UInt8?
        if let fault = pod["fault"] as? Data, fault.count > 8 {
            let code = fault[fault.startIndex + 8]
            if code != 0 { faultCode = code }
        }

        return PodHistoryRecord(
            at: HistoryTimestamp.string(from: stoppedAt),
            activatedAt: activatedAt.map(HistoryTimestamp.string(from:)),
            hoursRun: activatedAt.map { stoppedAt.timeIntervalSince($0) / 3600 },
            lotNo: (pod["lotNo"] as? UInt32 ?? pod["lot"] as? UInt32).map(String.init),
            lotSeq: (pod["lotSeq"] as? UInt32 ?? pod["tid"] as? UInt32).map(String.init),
            podType: (pod["podType"] as? UInt8).map(String.init),
            firmwareVersion: pod["firmwareVersion"] as? String ?? pod["pmVersion"] as? String,
            totalDelivered: delivered,
            remainingAtStop: reservoir,
            stopReason: stopReason(faultCode: faultCode, reservoir: reservoir,
                                   stoppedAt: stoppedAt, expiresAt: expiresAt),
            faultCode: faultCode.map { String(format: "0x%02X", $0) }
        )
    }

    /// Two fault codes are really outcomes rather than failures, so they are
    /// reported as what actually happened: 0x18 is "reservoir empty" and 0x1C is
    /// the 80-hour maximum pod life being exceeded.
    private func stopReason(faultCode: UInt8?, reservoir: Double?,
                            stoppedAt: Date, expiresAt: Date?) -> String {
        if let faultCode {
            switch faultCode {
            case 0x18: return "reservoirEmpty"
            case 0x1C: return "expired"
            default:   return "fault"
            }
        }
        if let reservoir, reservoir <= 0 { return "reservoirEmpty" }
        if let expiresAt, stoppedAt >= expiresAt { return "expired" }
        return "deactivated"
    }

    // MARK: - Meals

    /// Called once per saved carb entry, from the single chokepoint every carb
    /// path funnels through (`LoopDataManager.addCarbEntry`) — the meal screen,
    /// the bolus screen, simple bolus, the Watch and remote entry all land there.
    /// Hooking the UI instead would have missed some of them.
    ///
    /// Meal name and emoji come from this fork's own `MealMetadataStore`, which
    /// `StoredCarbEntry` has no room for. The join is safe at this point because
    /// `MealEntryViewModel` writes its metadata BEFORE it saves any carb entry.
    /// That store is also capped at 300 entries FIFO, so it is already losing old
    /// meal names — copying the name into the log is what stops that.
    func record(carbEntry entry: StoredCarbEntry) {
        guard store.isEnabled else { return }
        // Hop off the caller's queue FIRST. This runs on LoopDataManager's
        // dataAccessQueue — the algorithm's own queue — and the metadata lookup
        // below decodes up to 300 saved meals out of UserDefaults. Doing that
        // inline would put that work on the dosing path.
        work.async { [weak self] in
            self?.appendMealRecord(for: entry)
        }
    }

    private func appendMealRecord(for entry: StoredCarbEntry) {
        let metadata = MealMetadataStore.match(entries: [entry])
        // An edit only counts as one if it actually moved: LoopKit stamps
        // userUpdatedDate on creation too in some paths.
        let updated = entry.userUpdatedDate.flatMap {
            $0 == entry.userCreatedDate ? nil : $0
        }
        store.append(MealHistoryRecord(
            at: HistoryTimestamp.string(from: entry.startDate),
            eatenAt: metadata.map { HistoryTimestamp.string(from: $0.mealTime) },
            enteredAt: entry.userCreatedDate.map(HistoryTimestamp.string(from:)),
            updatedAt: updated.map(HistoryTimestamp.string(from:)),
            grams: entry.quantity.doubleValue(for: .gram()),
            absorption: entry.absorptionTime,
            foodType: entry.foodType,
            mealName: metadata?.name,
            mealEmoji: metadata?.emoji,
            syncIdentifier: entry.syncIdentifier
        ), at: entry.startDate)
    }

    // MARK: - Follower feed (Stage F2)

    /// Master switch for the whole follower feed — §15.2 rule 4 of the follower
    /// plan: "a single switch that disables publishing entirely, so if anything
    /// about it ever looks wrong the fix is one toggle, not an emergency
    /// rebuild".
    ///
    /// ⚠️ DEFAULTS OFF. No follower record is written until this is turned on,
    /// and the main app must work perfectly with it off — that is the normal
    /// state for most of this project's life (§15.2 rule 5).
    private static let followerFeedKey = "com.loopkit.Loop.followerFeedEnabled"

    var isFollowerFeedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.followerFeedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.followerFeedKey) }
    }

    /// Write one `status` record from a finished loop cycle.
    ///
    /// ── THE HIGHEST-RISK SEAM IN THE FOLLOWER PROJECT ───────────────────────
    /// §15.1 item 2. This is called from `LoopDataManager.loopDidComplete`,
    /// which runs on the algorithm's own queue. Everything about it is shaped so
    /// the loop cannot notice:
    ///
    ///  • it takes a `StoredDosingDecision` the cycle has ALREADY finished with,
    ///    so it reads no live state and cannot influence a dose;
    ///  • it hops onto `work` before doing anything at all, exactly as
    ///    `record(carbEntry:)` does — no formatting, no encoding, no disk on the
    ///    caller's queue;
    ///  • it cannot throw into the caller, and `HistoryLogStore.append` is
    ///    fire-and-forget and swallows its own errors;
    ///  • it returns immediately when either switch is off.
    ///
    /// If publishing is ever slow or failing — and it will be, regularly,
    /// because networks — the loop must not care. Keep it that way.
    func record(status decision: StoredDosingDecision, loopCompletedAt date: Date) {
        guard store.isEnabled, isFollowerFeedEnabled else { return }
        work.async { [weak self] in
            self?.appendStatusRecord(decision, at: date)
            // Publishing is a background CONSEQUENCE of the record being
            // written, never something the caller waits on — and it is kicked
            // off from HERE, on the logger's own queue, not from the loop.
            // `publish()` returns immediately and rate-limits itself.
            FollowerPublisher.shared.publish()
        }
    }

    private func appendStatusRecord(_ decision: StoredDosingDecision, at date: Date) {
        let mgdlUnit = HKUnit.milligramsPerDeciliter

        // The most recent glucose the decision was made on. Historical glucose
        // is oldest-first, so the last one is the newest.
        let latest = decision.historicalGlucose?.last

        let predicted = decision.predictedGlucose?.map {
            StatusHistoryRecord.PredictedPoint(
                at: HistoryTimestamp.string(from: $0.startDate),
                mgdl: $0.quantity.doubleValue(for: mgdlUnit))
        }

        // ⚠️ Only the CURRENT IOB/COB are on a dosing decision, not a series.
        // A single point is still worth sending — the follower's charts draw
        // whatever they are given — but a real curve needs the effect timelines,
        // which are not on `StoredDosingDecision`. Noted rather than faked: a
        // one-point "timeline" is honest, an interpolated one would not be.
        let iob = decision.insulinOnBoard.map {
            [StatusHistoryRecord.TimelinePoint(
                at: HistoryTimestamp.string(from: $0.startDate), value: $0.value)]
        }
        let cob = decision.carbsOnBoard.map {
            [StatusHistoryRecord.TimelinePoint(
                at: HistoryTimestamp.string(from: $0.startDate),
                value: $0.quantity.doubleValue(for: .gram()))]
        }

        let pump = decision.pumpManagerStatus

        // `BasalDeliveryState` is an enum, not a struct of flags: the running
        // rate only exists in the `.tempBasal` case, carried on a `DoseEntry`.
        var basalRate: Double?
        var isTemporary = false
        if case .tempBasal(let dose) = pump?.basalDeliveryState {
            basalRate = dose.unitsPerHour
            isTemporary = true
        }

        var overridePreset: TemporaryScheduleOverridePreset?
        if case .preset(let preset) = decision.scheduleOverride?.context {
            overridePreset = preset
        }

        store.append(StatusHistoryRecord(
            at: HistoryTimestamp.string(from: date),
            glucoseMgdl: latest?.quantity.doubleValue(for: mgdlUnit),
            glucoseAt: latest.map { HistoryTimestamp.string(from: $0.startDate) },
            // The dosing decision carries no trend arrow; the follower falls
            // back to the glucose records in the log, which do.
            glucoseTrend: nil,
            glucoseTrendRate: nil,
            loopStatus: "green",   // written only from loopDidComplete
            lastLoopAt: HistoryTimestamp.string(from: date),
            predictedGlucose: predicted,
            activeInsulin: decision.insulinOnBoard?.value,
            activeCarbs: decision.carbsOnBoard?.quantity.doubleValue(for: .gram()),
            iobTimeline: iob,
            cobTimeline: cob,
            basalRate: basalRate,
            isBasalTemporary: isTemporary,
            isDeliverySuspended: pump?.basalDeliveryState?.isSuspended,
            // Only a PRESET override has a name and symbol — `.preMeal`,
            // `.legacyWorkout` and `.custom` carry neither, so they stay nil
            // rather than being given an invented label.
            overrideName: overridePreset?.name,
            overrideSymbol: overridePreset?.symbol,
            overrideEndsAt: decision.scheduleOverride.map {
                HistoryTimestamp.string(from: $0.activeInterval.end)
            },
            reservoirUnits: decision.lastReservoirValue?.unitVolume,
            pumpBatteryPercent: pump?.pumpBatteryChargeRemaining,
            // Pod lifecycle and sensor session are not on a dosing decision.
            // They come from the pump/CGM manager state, which this seam
            // deliberately does not reach into — see the pod records above,
            // which already capture a session when it ENDS.
            podActivatedAt: nil,
            podExpiresAt: nil,
            sensorSessionStart: nil,
            sensorExpiresAt: nil
        ), at: date)
    }
}
