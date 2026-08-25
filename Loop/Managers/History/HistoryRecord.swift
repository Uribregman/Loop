//
//  HistoryRecord.swift
//  Loop
//
//  The record types written to the durable history log (see HistoryLogStore).
//
//  WHY THIS EXISTS: Loop keeps only ~7 days. `LOOP_LOCAL_CACHE_DURATION_DAYS = 7`
//  in Loop.xcconfig feeds every store's `cacheLength`, and DoseStore actively
//  purges older pump events. Past pod sessions are worse — OmniPumpManagerState
//  keeps `podState` plus exactly ONE `previousPodState`, so each pod change
//  overwrites the one before it. Anything not written down here is gone for good.
//
//  FORMAT: JSON Lines — one self-describing object per line, appended, never
//  rewritten. Chosen over CSV (can't express a pod's nested stop reason without
//  awkward flattening) and SQLite (binary; you couldn't open it in a text editor).
//  Every record starts with the same three fields:
//
//      {"v":1,"t":"<type>","at":"<ISO8601>", …type-specific fields… }
//
//  `v` is the schema version: bump it, never repurpose a field, so old lines stay
//  readable forever. The plain-language guide is docs/HISTORY_FORMAT.md.
//
//  HARD BOUNDARY: everything here is write-only observation. No dosing, no
//  LoopKit data models, no save paths.
//

import Foundation

/// Shared ISO-8601 formatting. Local time zone offset is kept (rather than
/// normalising to UTC) so a human reading the file sees the wall-clock time the
/// event actually happened at, while the offset keeps it machine-unambiguous.
enum HistoryTimestamp {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}

/// Current schema version, stamped onto every record as `v`.
let historySchemaVersion = 1

/// One CGM reading.
struct GlucoseHistoryRecord: Encodable {
    let v = historySchemaVersion
    let t = "glucose"
    let at: String
    /// Always mg/dL, whatever the user displays — one unit in the file means no
    /// ambiguity later. Convert on read if you want mmol/L.
    let mgdl: Double
    /// CGM trend arrow, e.g. "flat", "upDouble". Absent if the CGM didn't say.
    let trend: String?
    /// mg/dL per minute, signed. Absent if the CGM didn't report a rate.
    let trendRate: Double?
    let source: String?
    /// The CGM's own identifier for this reading — lets a re-import de-duplicate.
    let syncIdentifier: String?
}

/// One carb entry, joined to this fork's own meal metadata (name/emoji/photo)
/// where it exists. NOTE: MealMetadataStore is capped at 300 entries FIFO, so
/// meal names are ALREADY being silently dropped over time — this log is what
/// stops that happening from now on.
struct MealHistoryRecord: Encodable {
    let v = historySchemaVersion
    let t = "meal"
    /// ABSORPTION START — the moment these carbs begin counting. In this fork a
    /// meal component can be offset from the meal itself, so this is NOT
    /// necessarily when you ate; see `eatenAt`.
    let at: String
    /// EATING TIME — when the meal was actually eaten, from the meal metadata.
    /// Absent for carbs logged outside the meal screen, which have no meal time.
    let eatenAt: String?
    /// ENTRY TIME — when you saved it into the app. Differs from `eatenAt`
    /// whenever a meal is logged late, which is exactly when the distinction
    /// matters for reviewing a excursion afterwards.
    let enteredAt: String?
    /// Only present when the entry was edited after being saved.
    let updatedAt: String?
    let grams: Double
    /// ABSORPTION TIME — how long these carbs were expected to take, in seconds.
    let absorption: Double?
    /// The food-type emoji or text carried on the carb entry itself.
    let foodType: String?
    /// Meal name from MealMetadataStore, when this entry belongs to a named meal.
    let mealName: String?
    /// Meal-level emoji from MealMetadataStore.
    let mealEmoji: String?
    let syncIdentifier: String?
}

/// One insulin dose (bolus, temp basal, suspend, …).
struct DoseHistoryRecord: Encodable {
    let v = historySchemaVersion
    let t = "dose"
    let at: String
    /// LoopKit dose type: "bolus", "tempBasal", "basal", "suspend", "resume".
    let kind: String
    let units: Double?
    /// Units per hour, for basal-rate doses.
    let unitsPerHour: Double?
    /// ISO-8601 end of the delivery window; equals `at` for an instantaneous dose.
    let endedAt: String?
    /// True when Loop delivered this itself rather than the user asking for it.
    let automatic: Bool?
    let syncIdentifier: String?
}

/// One pod session, written when the pod STOPS. This is the record that cannot
/// be reconstructed later: `prepForNewPod()` overwrites the only saved previous
/// pod state, so a session not captured at the transition is gone.
struct PodHistoryRecord: Encodable {
    let v = historySchemaVersion
    let t = "pod"
    /// The moment delivery stopped — the event this record describes.
    let at: String
    let activatedAt: String?
    /// Whole hours the pod ran, for quick longevity stats.
    let hoursRun: Double?
    let lotNo: String?
    let lotSeq: String?
    let podType: String?
    let firmwareVersion: String?
    /// Total units delivered over the session.
    let totalDelivered: Double?
    /// Units left in the reservoir when it stopped — i.e. insulin thrown away.
    let remainingAtStop: Double?
    /// Why it ended: "fault", "reservoirEmpty", "expired", "deactivated", "unknown".
    let stopReason: String
    /// Pod fault code as hex (e.g. "0x1C"), whenever the pod reported one.
    /// Left as the raw code deliberately: the human-readable text lives in
    /// OmnipodKit, which the Loop app target does not link.
    let faultCode: String?
}

// MARK: - Follower feed records (Stage F2)
//
// Added for the follower app — §3 of Loop-Follower-App-Plan-2026-08-13.md.
// Additive to the same `v`/`t` schema, so an older reader skips them and keeps
// going; docs/HISTORY_FORMAT.md documents how to add a type without breaking
// old readers.
//
// ── WHY THESE EXIST AT ALL ──────────────────────────────────────────────────
// Everything else in this file is a MEASUREMENT. These two are DERIVED values —
// loop status, the predicted curve, IOB and COB as the algorithm computed them,
// plus a read-only copy of the therapy settings.
//
// They are written down rather than recomputed by the follower on purpose:
// recomputing them there would mean shipping the dosing algorithm into the
// follower app, which is exactly what that project exists to avoid. A follower's
// IOB quietly disagreeing with the patient's would be worse than no IOB.
//
// ── STILL WRITE-ONLY OBSERVATION ────────────────────────────────────────────
// Same hard boundary as the rest of this file. These are built from a
// `StoredDosingDecision` the loop has ALREADY finished with. Nothing here reads
// live algorithm state, mutates anything, or can influence a dose.
//
// ⚠️ NOTHING DEVICE-IDENTIFYING. §3.1 is an ALLOW-LIST: a field is here because
// someone could say why a follower needs it. No pump or transmitter serial, no
// pod address, lot number or firmware version, no `syncIdentifier`, no service
// credentials, no container ids. Device identity travels as a LABEL only —
// "Omnipod DASH", "Dexcom G7" — which says what is on the body without
// authenticating to anything.

/// One loop cycle's derived state.
struct StatusHistoryRecord: Encodable {
    let v = historySchemaVersion
    let t = "status"
    /// When the loop cycle that produced this finished.
    let at: String

    let glucoseMgdl: Double?
    let glucoseAt: String?
    /// CGM trend arrow, e.g. "flat", "upDouble". Absent if the CGM didn't say.
    let glucoseTrend: String?
    let glucoseTrendRate: Double?

    /// "green" / "yellow" / "red" — the three states the status pill shows. A
    /// string rather than an enum so an unknown future value degrades to
    /// "unknown" in a reader instead of failing the whole decode.
    let loopStatus: String?
    let lastLoopAt: String?

    /// The predicted curve as the algorithm produced it, oldest first.
    let predictedGlucose: [PredictedPoint]?

    let activeInsulin: Double?
    let activeCarbs: Double?
    /// IOB and COB over time. The charts on the follower's home screen draw
    /// these directly — see the note above on why they are not recomputed there.
    let iobTimeline: [TimelinePoint]?
    let cobTimeline: [TimelinePoint]?

    let basalRate: Double?
    let isBasalTemporary: Bool?
    let isDeliverySuspended: Bool?

    let overrideName: String?
    let overrideSymbol: String?
    let overrideEndsAt: String?

    let reservoirUnits: Double?
    let pumpBatteryPercent: Double?
    let podActivatedAt: String?
    let podExpiresAt: String?

    let sensorSessionStart: String?
    let sensorExpiresAt: String?

    struct PredictedPoint: Encodable {
        let at: String
        let mgdl: Double
    }

    /// One point on a derived curve — units for IOB, grams for COB.
    struct TimelinePoint: Encodable {
        let at: String
        let value: Double
    }
}

/// A read-only copy of the therapy settings, for the follower's settings viewer.
///
/// The field list is dictated by §1's table in the plan — write the table first,
/// then this record. Anything the table says the follower "keeps as a value" has
/// to be here; anything it says is deleted must NOT be.
struct SettingsHistoryRecord: Encodable {
    let v = historySchemaVersion
    let t = "settings"
    let at: String

    /// What the follower app calls this person. Patient-chosen, optional, and
    /// deliberately NOT defaulted from an Apple ID name or a device name — the
    /// patient chooses what a second household's phone displays about them.
    let patientLabel: String?

    let closedLoopEnabled: Bool?
    let dosingStrategy: String?
    let appVersion: String?
    /// "mg/dL" or "mmol/L" — how this app displays glucose, so the two screens
    /// always agree.
    let glucoseUnit: String?

    let basalSchedule: [ScheduleEntry]?
    let insulinSensitivitySchedule: [ScheduleEntry]?
    let carbRatioSchedule: [ScheduleEntry]?
    let correctionRangeSchedule: [RangeEntry]?
    let preMealTargetRange: RangeEntry?

    let suspendThresholdMgdl: Double?
    let maximumBolus: Double?
    let maximumBasalRate: Double?
    let insulinModel: String?
    let carbAbsorptionModel: String?

    /// LABELS, never identifiers. See the §3.1 note above.
    let pumpLabel: String?
    let cgmLabel: String?

    struct ScheduleEntry: Encodable {
        /// Seconds after midnight, in THIS device's time zone.
        let startSeconds: Double
        let value: Double
    }

    struct RangeEntry: Encodable {
        let startSeconds: Double
        let minMgdl: Double
        let maxMgdl: Double
    }
}
