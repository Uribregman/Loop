//
//  CustomAlertMonitor.swift
//  Loop
//
//  User-configurable Loop-side alerts that are NOT provided by the CGM/pump
//  plugins: fast glucose rate-of-change, sustained glucose trend, and multiple
//  pod insulin-remaining thresholds. Each alert type supports MULTIPLE alarms,
//  and every alarm carries its own urgency + sound (incl. bundled Dexcom tones).
//
//  HARD BOUNDARY: this observes read-only signals (CGM glucose + trendRate,
//  pump reservoir units) and only calls AlertManager.issueAlert. It never
//  touches the dosing algorithm, LoopKit data models, or any save path.
//
//  HOW ALERTS REACH THE USER (all three rules are here, not scattered):
//
//   1. ONE ALARM PER DIRECTION. Alarms of the same kind overlap by design — a
//      high at 180 and another at 250 are both "true" at 300. Only the most
//      extreme one that is currently triggered fires; the rest stay silent
//      WITHOUT being marked as fired, so a later, milder excursion still alerts.
//      See `dominantGlucoseAlarms`.
//   2. NOTHING ARRIVES AT ONCE. Everything goes through one queue that releases
//      at most one alert every `minimumSpacing` seconds, most important first
//      (`AlertPriority`). A burst used to be issued in the same run loop turn:
//      several UIAlertControllers presented on top of each other, several tones
//      overlapping, and the acknowledgement of one landing on another.
//   3. ONE LOCK OWNS THE STATE. `processNewGlucose` and `processReservoir` are
//      documented as callable from any queue and mutate shared dictionaries;
//      they were doing so unsynchronised. `lock` guards every mutable property
//      below.
//

import Foundation
import HealthKit
import LoopKit

/// Which glucose direction an alert applies to.
enum TrendDirection: Int, Codable, CaseIterable, Identifiable {
    case rising, falling, both
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .rising: return NSLocalizedString("Rising", comment: "Trend direction: rising")
        case .falling: return NSLocalizedString("Falling", comment: "Trend direction: falling")
        case .both: return NSLocalizedString("Rising or Falling", comment: "Trend direction: both")
        }
    }

    /// True if a signed rate (mg/dL/min) matches this direction.
    func matches(signedRate: Double) -> Bool {
        switch self {
        case .rising: return signedRate > 0
        case .falling: return signedRate < 0
        case .both: return signedRate != 0
        }
    }
}

/// How forcefully an alert interrupts. `critical` needs the critical-alerts
/// entitlement (FeatureFlags.criticalAlertsEnabled) to bypass mute/Focus.
enum AlertUrgency: Int, Codable, CaseIterable, Identifiable {
    case normal, urgent, critical
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .normal: return NSLocalizedString("Normal", comment: "Alert urgency: normal")
        case .urgent: return NSLocalizedString("Urgent (Time-Sensitive)", comment: "Alert urgency: urgent")
        case .critical: return NSLocalizedString("Critical", comment: "Alert urgency: critical")
        }
    }

    var interruptionLevel: Alert.InterruptionLevel {
        switch self {
        case .normal: return .active
        case .urgent: return .timeSensitive
        case .critical: return .critical
        }
    }
}

/// Sound played with an alert: the system default, vibrate-only, or one of the
/// bundled Dexcom-style tones (see `Loop/CustomAlertSounds/*.caf`, exposed to the
/// notification pipeline by `LoopSoundVendor`). The Dexcom audio is bundled only
/// for personal self-built use — see DEXCOM_SOUNDS_LICENSE.md.
enum AlertSoundChoice: String, Codable, CaseIterable, Identifiable {
    case defaultSound
    case vibrate
    case dexHigh
    case dexLow
    case dexRiseRate
    case dexSignalLoss
    case dexUrgentLow
    case dexUrgentLowSoon

    var id: String { rawValue }

    /// - Parameter isPodAlert: true only for the "Low Insulin (Pod)" reservoir
    ///   thresholds, where the pod's own hardware beep is the alarm and no phone
    ///   tone is layered on top (see `alertSound(isPodAlert:)`).
    ///
    /// Every label names the actual sound you will hear, rather than an abstract
    /// setting name like "Default" — which told the user nothing.
    func title(isPodAlert: Bool = false) -> String {
        switch self {
        case .defaultSound:
            return isPodAlert
                ? NSLocalizedString("Pump Beep (default)", comment: "Alert sound for a pod-insulin alert: the pod's own hardware beep, no phone sound")
                : NSLocalizedString("iOS Default Tone (default)", comment: "Alert sound: the standard iOS notification tone, pre-selected for rate/sustained-trend alarms")
        case .vibrate:         return NSLocalizedString("Silent — Vibrate Only", comment: "Alert sound: no sound, vibration only")
        case .dexHigh:         return NSLocalizedString("Dexcom High Tone", comment: "Alert sound: Dexcom high")
        case .dexLow:          return NSLocalizedString("Dexcom Low Tone", comment: "Alert sound: Dexcom low")
        case .dexRiseRate:     return NSLocalizedString("Dexcom Rise-Rate Tone", comment: "Alert sound: Dexcom rise rate")
        case .dexSignalLoss:   return NSLocalizedString("Dexcom Signal-Loss Tone", comment: "Alert sound: Dexcom signal loss")
        case .dexUrgentLow:    return NSLocalizedString("Dexcom Urgent-Low Tone", comment: "Alert sound: Dexcom urgent low")
        case .dexUrgentLowSoon: return NSLocalizedString("Dexcom Urgent-Low-Soon Tone", comment: "Alert sound: Dexcom urgent low soon")
        }
    }

    /// Bundled resource base name (no extension), for AVAudioPlayer preview.
    /// nil for the non-file choices (default / vibrate).
    var bundledResourceName: String? {
        switch self {
        case .defaultSound, .vibrate: return nil
        case .dexHigh:          return "high_alert"
        case .dexLow:           return "low_alert"
        case .dexRiseRate:      return "rise_rate"
        case .dexSignalLoss:    return "signal_loss_alert"
        case .dexUrgentLow:     return "urgent_low"
        case .dexUrgentLowSoon: return "urgent_low_soon"
        }
    }

    /// See `title(isPodAlert:)` for why pod alerts get their own mapping: no
    /// phone tone for "Pump Beep", since the pod already beeps on its own.
    func alertSound(isPodAlert: Bool = false) -> Alert.Sound? {
        switch self {
        case .defaultSound: return isPodAlert ? .vibrate : nil   // pod: rely on the pod's own beep; otherwise: system default notification sound
        case .vibrate:      return .vibrate
        default:            return bundledResourceName.map { .sound(name: "\($0).caf") }
        }
    }

    /// All bundled sound filenames (with extension) the sound vendor must expose.
    static var bundledFilenames: [String] {
        allCases.compactMap { $0.bundledResourceName.map { "\($0).caf" } }
    }
}

/// One "glucose rising/falling faster than X" alarm.
struct RateAlarm: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled: Bool = true
    /// Threshold magnitude in mg/dL per minute.
    var threshold: Double = 3
    var direction: TrendDirection = .both
    var urgency: AlertUrgency = .urgent
    var sound: AlertSoundChoice = .defaultSound
}

/// One "glucose trending in one direction for X minutes" alarm.
struct SustainedAlarm: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled: Bool = true
    /// Minutes the trend must persist in one direction.
    var minutes: Double = 30
    var direction: TrendDirection = .both
    var urgency: AlertUrgency = .normal
    var sound: AlertSoundChoice = .defaultSound
}

/// One low-insulin threshold with its own urgency + sound.
struct ReservoirThreshold: Codable, Equatable, Identifiable {
    var id = UUID()
    var units: Double
    var enabled: Bool = true
    var urgency: AlertUrgency = .normal
    var sound: AlertSoundChoice = .defaultSound
}

/// One "glucose above/below X" alarm — the classic high/low alert Loop itself
/// has never had. Unlike the rate/sustained alarms, this condition PERSISTS, so
/// the repeat interval is a user-facing per-alarm snooze rather than the fixed
/// 15-minute cooldown the other types share.
struct GlucoseAlarm: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled: Bool = true
    /// Threshold glucose, always STORED in mg/dL whatever the display unit is.
    var threshold: Double = 180
    /// true = alert at or above `threshold`; false = at or below.
    var isAbove: Bool = true
    var urgency: AlertUrgency = .urgent
    var sound: AlertSoundChoice = .defaultSound
    /// Minutes to stay quiet after firing while the condition still holds.
    var snoozeMinutes: Double = 30
}

/// When a set is allowed to fire, as a time-of-day window.
///
/// Stored as minutes from midnight rather than `Date` so it means the same thing
/// every day and survives time-zone changes. A window whose end is at or before
/// its start WRAPS past midnight — that is what makes a "Night" set (22:00–07:00)
/// expressible at all.
struct AlertSchedule: Codable, Equatable {
    /// false = the set is active all day (the window is ignored but remembered).
    var enabled: Bool = false
    var startMinutes: Int = 22 * 60
    var endMinutes: Int = 7 * 60

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinutes == endMinutes { return true }          // full 24h
        if startMinutes < endMinutes {                          // same-day window
            return now >= startMinutes && now < endMinutes
        }
        return now >= startMinutes || now < endMinutes          // wraps midnight
    }
}

/// A named group of alarms that can be enabled, disabled, or limited to a
/// time-of-day window as a unit — "Night", "Day", "Exercise", etc.
///
/// Alarms live INSIDE a set rather than alongside it, so switching a set off at
/// 07:00 silences everything it contains without touching the individual alarms.
struct AlertSet: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String = NSLocalizedString("New Set", comment: "Default name for a new alert set")
    var enabled: Bool = true
    var schedule = AlertSchedule()

    var glucoseAlarms: [GlucoseAlarm] = []
    var rateAlarms: [RateAlarm] = []
    var sustainedAlarms: [SustainedAlarm] = []
    var reservoirThresholds: [ReservoirThreshold] = []

    /// True when this set is switched on AND inside its window (if it has one).
    func isActive(at date: Date) -> Bool { enabled && schedule.contains(date) }

    var alarmCount: Int {
        glucoseAlarms.count + rateAlarms.count + sustainedAlarms.count + reservoirThresholds.count
    }

    static let defaultReservoirThresholds = [
        ReservoirThreshold(units: 20),
        ReservoirThreshold(units: 10, urgency: .urgent)
    ]

    /// The set a fresh install starts with, and the one a pre-sets settings blob
    /// migrates into: always on, no window, carrying the old low-insulin defaults.
    static var allDay: AlertSet {
        AlertSet(name: NSLocalizedString("All Day", comment: "Name of the default always-on alert set"),
                 reservoirThresholds: defaultReservoirThresholds)
    }

}

/// All user-configurable custom-alert settings, persisted as one JSON blob.
///
/// Everything hangs off `sets`. The "active" accessors take a date because a set
/// may be scheduled, so what is armed depends on when you ask.
struct CustomAlertSettings: Codable, Equatable {
    var sets: [AlertSet] = [.allDay]

    init() {}

    func activeSets(at date: Date) -> [AlertSet] { sets.filter { $0.isActive(at: date) } }

    func activeGlucoseAlarms(at date: Date) -> [GlucoseAlarm] {
        activeSets(at: date).flatMap { $0.glucoseAlarms.filter(\.enabled) }
    }
    func activeRateAlarms(at date: Date) -> [RateAlarm] {
        activeSets(at: date).flatMap { $0.rateAlarms.filter(\.enabled) }
    }
    func activeSustainedAlarms(at date: Date) -> [SustainedAlarm] {
        activeSets(at: date).flatMap { $0.sustainedAlarms.filter(\.enabled) }
    }
    func activeReservoirThresholds(at date: Date) -> [ReservoirThreshold] {
        activeSets(at: date).flatMap { $0.reservoirThresholds.filter(\.enabled) }
    }

    // MARK: Persistence (+ one-time migration from the pre-sets layout)

    private enum CodingKeys: String, CodingKey {
        case sets
        // Pre-sets keys. Read only, never written again — see `init(from:)`.
        case glucoseAlarms, rateAlarms, sustainedAlarms, reservoirThresholds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let sets = try container.decodeIfPresent([AlertSet].self, forKey: .sets) {
            self.sets = sets
            return
        }
        // A blob saved before sets existed: fold the flat arrays into one always-on
        // set so nobody silently loses alarms they had configured.
        var migrated = AlertSet.allDay
        migrated.glucoseAlarms = try container.decodeIfPresent([GlucoseAlarm].self, forKey: .glucoseAlarms) ?? []
        migrated.rateAlarms = try container.decodeIfPresent([RateAlarm].self, forKey: .rateAlarms) ?? []
        migrated.sustainedAlarms = try container.decodeIfPresent([SustainedAlarm].self, forKey: .sustainedAlarms) ?? []
        migrated.reservoirThresholds = try container.decodeIfPresent([ReservoirThreshold].self, forKey: .reservoirThresholds)
            ?? AlertSet.defaultReservoirThresholds
        self.sets = [migrated]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sets, forKey: .sets)
    }

    private static let key = "com.loopkit.Loop.customAlertSettings"

    static func load() -> CustomAlertSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CustomAlertSettings.self, from: data) else {
            return CustomAlertSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Tapping OK on one of these alerts SNOOZES it.
///
/// Without this the cooldown was stamped only when an alert fired, so
/// acknowledging one did nothing — a persistent condition (a glucose level, a
/// reservoir still low) could re-alert as soon as the window elapsed no matter
/// how recently the user had dismissed it. `AlertResponder` is how Loop routes
/// an acknowledgement back to whoever raised the alert.
extension CustomAlertMonitor: AlertResponder {
    func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        // The identifier IS the per-alarm cooldown key, so re-stamping it here
        // restarts that alarm's own snooze from the moment of acknowledgement.
        snooze(alertIdentifier)
        completion(nil)
    }
}

/// Order in which alerts leave the queue when more than one is waiting.
///
/// Lower fires first. Urgency dominates — a critical alarm goes ahead of an
/// urgent one whatever it is about — and within one urgency the ranking is by
/// how fast the situation can hurt you: a low first, then a high, then the
/// rate/trend warnings that say something is heading somewhere, then supplies.
private enum AlertPriority {
    static func rank(urgency: AlertUrgency, kind: Kind) -> Int {
        let urgencyRank: Int
        switch urgency {
        case .critical: urgencyRank = 0
        case .urgent:   urgencyRank = 1
        case .normal:   urgencyRank = 2
        }
        return urgencyRank * 10 + kind.rawValue
    }

    enum Kind: Int {
        case glucoseLow = 0
        case glucoseHigh = 1
        case rate = 2
        case sustained = 3
        case reservoir = 4
    }
}

final class CustomAlertMonitor {
    static let managerIdentifier = "Loop"

    /// Don't re-fire the same alarm more often than this.
    private let cooldown: TimeInterval = .minutes(15)

    /// Minimum gap between two alerts reaching the user.
    static let minimumSpacing: TimeInterval = 5
    /// A queued alert older than this is DROPPED rather than fired late. Five
    /// glucose readings on, "your glucose is 65" may no longer be true, and a
    /// stale alarm is worse than a missed one.
    private static let maximumQueueAge: TimeInterval = .minutes(5)

    /// Guards every mutable property below. The processing entry points are
    /// documented as callable from any queue, so this is not optional.
    private let lock = NSRecursiveLock()

    // In-memory state (resets on relaunch — intentional; avoids stale alerts).
    private var lastGlucose: (value: Double, date: Date)?
    private var runStart: Date?
    private var runDirection: TrendDirection?
    private var lastReservoirUnits: Double?
    /// Per-alarm last-fired timestamps, keyed by a stable identifier.
    private var lastFired: [String: Date] = [:]

    /// One alert waiting its turn.
    private struct PendingAlert {
        let alert: Alert
        let priority: Int
        let queuedAt: Date
        weak var issuer: AlertIssuer?
    }

    private var pending: [PendingAlert] = []
    private var lastIssuedAt: Date?
    private var drainScheduled = false

    private let unit = HKUnit.milligramsPerDeciliter
    private let ratePerMinuteUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())

    // MARK: - Glucose

    /// Feed newly received CGM samples. Safe to call from any queue.
    ///
    /// - Parameter displayUnit: the user's display unit, used ONLY to phrase the
    ///   alert body. All thresholds and comparisons stay in mg/dL.
    func processNewGlucose(_ samples: [NewGlucoseSample], issuer: AlertIssuer?,
                           displayUnit: HKUnit = .milligramsPerDeciliter) {
        guard let issuer else { return }
        let settings = CustomAlertSettings.load()
        guard !settings.sets.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        for sample in samples.sorted(by: { $0.date < $1.date }) {
            let value = sample.quantity.doubleValue(for: unit)
            defer { lastGlucose = (value, sample.date) }

            // Resolved per sample, not once up front: a set can be scheduled, so
            // which alarms are armed depends on the sample's own timestamp.
            let glucoseAlarms = settings.activeGlucoseAlarms(at: sample.date)
            let rateAlarms = settings.activeRateAlarms(at: sample.date)
            let sustainedAlarms = settings.activeSustainedAlarms(at: sample.date)
            if glucoseAlarms.isEmpty && rateAlarms.isEmpty && sustainedAlarms.isEmpty { continue }

            for alarm in dominantGlucoseAlarms(from: glucoseAlarms, value: value) {
                checkGlucoseLevel(value, alarm: alarm, displayUnit: displayUnit, issuer: issuer)
            }

            // Signed rate: prefer the CGM's own trendRate, else derive from the
            // previous sample.
            var signedRate: Double?
            if let trend = sample.trendRate {
                signedRate = trend.doubleValue(for: ratePerMinuteUnit)
            } else if let prev = lastGlucose {
                let dtMin = sample.date.timeIntervalSince(prev.date) / 60
                if dtMin > 0.5 { signedRate = (value - prev.value) / dtMin }
            }

            if let rate = signedRate {
                for alarm in rateAlarms {
                    checkRate(rate, alarm: alarm, issuer: issuer)
                }
            }
            if !sustainedAlarms.isEmpty {
                updateRun(value: value, date: sample.date)
                for alarm in sustainedAlarms {
                    checkSustained(alarm: alarm, now: sample.date, issuer: issuer)
                }
            }
        }
    }

    /// Of the alarms currently triggered, the ONE that matters in each
    /// direction: the highest tripped high, and the lowest tripped low.
    ///
    /// With highs at 180 and 250 and a glucose of 300, both are true — but being
    /// told twice, once for each, is noise that buries the number that actually
    /// changes what you do. Only the most extreme is returned.
    ///
    /// Alarms that are NOT triggered have their snooze stamp cleared, exactly as
    /// before, so the next excursion alerts immediately. Alarms that ARE
    /// triggered but lose to a more extreme one are left completely untouched —
    /// no stamp, no clear. That is what lets the 180 alarm speak up later, on
    /// its own terms, once glucose falls back past 250.
    private func dominantGlucoseAlarms(from alarms: [GlucoseAlarm], value: Double) -> [GlucoseAlarm] {
        var triggeredHigh: [GlucoseAlarm] = []
        var triggeredLow: [GlucoseAlarm] = []

        for alarm in alarms {
            let triggered = alarm.isAbove ? value >= alarm.threshold : value <= alarm.threshold
            if !triggered {
                lastFired.removeValue(forKey: Self.key(for: alarm))
            } else if alarm.isAbove {
                triggeredHigh.append(alarm)
            } else {
                triggeredLow.append(alarm)
            }
        }

        // Highest tripped high, lowest tripped low.
        return [triggeredHigh.max { $0.threshold < $1.threshold },
                triggeredLow.min { $0.threshold < $1.threshold }].compactMap { $0 }
    }

    /// The cooldown key for a glucose alarm. Also the alert identifier, which is
    /// what makes acknowledging one snooze that same alarm (see `AlertResponder`).
    private static func key(for alarm: GlucoseAlarm) -> String {
        "glucoseLevel-\(alarm.id.uuidString)"
    }

    /// High/low threshold check. Re-fires while the condition HOLDS, gated by the
    /// alarm's own snooze — that repetition is what makes it behave like a CGM
    /// high/low alert rather than a one-shot crossing notice.
    private func checkGlucoseLevel(_ value: Double, alarm: GlucoseAlarm,
                                   displayUnit: HKUnit, issuer: AlertIssuer) {
        // Only ever called for an alarm `dominantGlucoseAlarms` has already
        // confirmed is triggered and is the extreme one in its direction; that
        // is also where the stamp of an untriggered alarm gets cleared.
        let key = Self.key(for: alarm)
        guard cooldownPassed(key, interval: .minutes(alarm.snoozeMinutes)) else { return }

        let title = alarm.isAbove
            ? NSLocalizedString("High Glucose", comment: "High glucose alert title")
            : NSLocalizedString("Low Glucose", comment: "Low glucose alert title")
        let body = String(
            format: alarm.isAbove
                ? NSLocalizedString("Your glucose is %1$@, at or above your %2$@ alert level.", comment: "High glucose alert body (1: current glucose, 2: threshold)")
                : NSLocalizedString("Your glucose is %1$@, at or below your %2$@ alert level.", comment: "Low glucose alert body (1: current glucose, 2: threshold)"),
            glucoseString(value, in: displayUnit),
            glucoseString(alarm.threshold, in: displayUnit)
        )
        issue(identifier: key, title: title, body: body,
              urgency: alarm.urgency, sound: alarm.sound,
              kind: alarm.isAbove ? .glucoseHigh : .glucoseLow, issuer: issuer)
    }

    private func checkRate(_ signedRate: Double, alarm: RateAlarm, issuer: AlertIssuer) {
        guard alarm.direction.matches(signedRate: signedRate),
              abs(signedRate) >= alarm.threshold else { return }
        let key = "glucoseRateFast-\(alarm.id.uuidString)"
        guard cooldownPassed(key) else { return }

        let rising = signedRate > 0
        let title = rising
            ? NSLocalizedString("Glucose Rising Fast", comment: "Fast-rise alert title")
            : NSLocalizedString("Glucose Falling Fast", comment: "Fast-fall alert title")
        let body = String(
            format: NSLocalizedString("Your glucose is %1$@ faster than %2$@ mg/dL per minute.", comment: "Fast rate alert body (1: rising/falling, 2: threshold)"),
            rising ? NSLocalizedString("rising", comment: "rising") : NSLocalizedString("falling", comment: "falling"),
            formatted(alarm.threshold)
        )
        issue(identifier: key, title: title, body: body,
              urgency: alarm.urgency, sound: alarm.sound, kind: .rate, issuer: issuer)
    }

    /// Track the current monotonic run of glucose movement (shared by all sustained alarms).
    private func updateRun(value: Double, date: Date) {
        guard let prev = lastGlucose else { return }
        let delta = value - prev.value
        let direction: TrendDirection? = delta > 0 ? .rising : (delta < 0 ? .falling : nil)

        if let direction, direction == runDirection {
            // same direction — keep runStart
        } else if let direction {
            runDirection = direction
            runStart = prev.date
        } else {
            // flat reading breaks the run
            runDirection = nil
            runStart = nil
        }
    }

    private func checkSustained(alarm: SustainedAlarm, now: Date, issuer: AlertIssuer) {
        guard let runStart, let runDirection,
              alarm.direction == .both || alarm.direction == runDirection else { return }

        let elapsedMin = now.timeIntervalSince(runStart) / 60
        guard elapsedMin >= alarm.minutes else { return }
        let key = "glucoseSustainedTrend-\(alarm.id.uuidString)"
        guard cooldownPassed(key) else { return }

        let rising = runDirection == .rising
        let title = rising
            ? NSLocalizedString("Glucose Rising", comment: "Sustained-rise alert title")
            : NSLocalizedString("Glucose Falling", comment: "Sustained-fall alert title")
        let body = String(
            format: NSLocalizedString("Your glucose has been %1$@ for over %2$@ minutes.", comment: "Sustained trend alert body (1: rising/falling, 2: minutes)"),
            rising ? NSLocalizedString("rising", comment: "rising") : NSLocalizedString("falling", comment: "falling"),
            formatted(alarm.minutes)
        )
        issue(identifier: key, title: title, body: body,
              urgency: alarm.urgency, sound: alarm.sound, kind: .sustained, issuer: issuer)
    }

    // MARK: - Reservoir

    /// Feed a new reservoir reading (units remaining). Safe from any queue.
    func processReservoir(units: Double, issuer: AlertIssuer?) {
        guard let issuer else { return }
        let settings = CustomAlertSettings.load()
        lock.lock()
        defer { lock.unlock() }
        defer { lastReservoirUnits = units }
        let thresholds = settings.activeReservoirThresholds(at: Date())
        guard !thresholds.isEmpty, let previous = lastReservoirUnits else { return }

        // Fire once per threshold as the reservoir crosses DOWN through it.
        for threshold in thresholds.sorted(by: { $0.units > $1.units })
            where previous > threshold.units && units <= threshold.units {
            let title = NSLocalizedString("Low Insulin", comment: "Low reservoir alert title")
            let body = String(
                format: NSLocalizedString("Pod insulin remaining is below %1$@ units (%2$@ U left).", comment: "Low reservoir alert body (1: threshold, 2: remaining)"),
                formatted(threshold.units), formatted(units)
            )
            // Distinct identifier per threshold so each crossing is its own alert.
            //
            // Sound is hardcoded to `.defaultSound` rather than `threshold.sound`:
            // low-insulin is signalled by the pod's own beep, exactly as it was
            // before this custom-alert feature existed, and that is the ONLY
            // option here (the UI shows it as a fixed row, not a picker). Passing
            // it explicitly also ignores any other value left in previously
            // saved settings.
            issue(identifier: "reservoirBelow-\(threshold.id.uuidString)", title: title, body: body,
                  urgency: threshold.urgency, sound: .defaultSound, kind: .reservoir,
                  issuer: issuer, isPodAlert: true)
        }
    }

    // MARK: - Helpers

    /// Restart an alarm's quiet period, as though it had just fired.
    func snooze(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        lastFired[key] = Date()
    }

    /// True if this alarm key hasn't fired within `interval`; stamps it when true.
    /// `interval` defaults to the shared 15-minute cooldown used by the rate and
    /// sustained-trend alarms; high/low alarms pass their own snooze instead.
    private func cooldownPassed(_ key: String, interval: TimeInterval? = nil) -> Bool {
        let window = interval ?? cooldown
        if let last = lastFired[key], Date().timeIntervalSince(last) < window { return false }
        lastFired[key] = Date()
        return true
    }

    /// Phrases a mg/dL value in the user's display unit (mmol/L gets one decimal).
    private func glucoseString(_ mgdl: Double, in displayUnit: HKUnit) -> String {
        let converted = HKQuantity(unit: unit, doubleValue: mgdl).doubleValue(for: displayUnit)
        let digits = displayUnit == .millimolesPerLiter ? 1 : 0
        return String(format: "%.\(digits)f %@", converted, displayUnit.shortLocalizedUnitString())
    }

    private func issue(identifier: String, title: String, body: String,
                       urgency: AlertUrgency, sound: AlertSoundChoice,
                       kind: AlertPriority.Kind, issuer: AlertIssuer,
                       isPodAlert: Bool = false) {
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: NSLocalizedString("OK", comment: "Alert acknowledge button")
        )
        // Critical interruption is only honored if the app has the critical-alerts
        // entitlement; otherwise fall back to time-sensitive so the alert still shows.
        let level: Alert.InterruptionLevel = (urgency == .critical && !FeatureFlags.criticalAlertsEnabled)
            ? .timeSensitive
            : urgency.interruptionLevel
        let alert = Alert(
            identifier: Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: identifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: level,
            sound: sound.alertSound(isPodAlert: isPodAlert)
        )
        enqueue(PendingAlert(alert: alert,
                             priority: AlertPriority.rank(urgency: urgency, kind: kind),
                             queuedAt: Date(),
                             issuer: issuer))
    }

    // MARK: - The queue

    /// Add an alert to the queue and make sure something is going to drain it.
    /// Caller already holds `lock`.
    private func enqueue(_ item: PendingAlert) {
        pending.append(item)
        scheduleDrain()
    }

    /// Arrange for `drain()` to run once the spacing has elapsed.
    /// Caller already holds `lock`.
    private func scheduleDrain() {
        guard !drainScheduled else { return }
        let wait = lastIssuedAt.map { max(0, Self.minimumSpacing - Date().timeIntervalSince($0)) } ?? 0
        drainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.drain()
        }
    }

    /// Release AT MOST ONE alert, then re-arm if more are waiting.
    ///
    /// Always on the main queue: issuing presents UI. One at a time and one
    /// timer at a time is what keeps a burst from stacking dialogs and tones on
    /// top of each other.
    private func drain() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        drainScheduled = false

        let now = Date()
        // Dropping a stale alert must also UNDO its snooze. The cooldown stamp
        // is written when the alarm is checked, i.e. when it joins the queue —
        // so an alert dropped here would otherwise count as "already fired" and
        // stay silent for the rest of its snooze despite never having reached
        // the user. Clearing the stamp lets the next reading raise it again.
        for item in pending where now.timeIntervalSince(item.queuedAt) > Self.maximumQueueAge {
            lastFired.removeValue(forKey: item.alert.identifier.alertIdentifier)
        }
        pending.removeAll { now.timeIntervalSince($0.queuedAt) > Self.maximumQueueAge }
        guard !pending.isEmpty else {
            lock.unlock()
            return
        }
        if let last = lastIssuedAt, now.timeIntervalSince(last) < Self.minimumSpacing {
            // Woke early (something else queued in the meantime). Wait it out.
            scheduleDrain()
            lock.unlock()
            return
        }

        // Most important first; ties go to whichever has waited longest.
        let index = pending.indices.min {
            (pending[$0].priority, pending[$0].queuedAt) < (pending[$1].priority, pending[$1].queuedAt)
        }!
        let next = pending.remove(at: index)
        lastIssuedAt = now
        if !pending.isEmpty { scheduleDrain() }
        lock.unlock()

        // OUTSIDE the lock: issuing runs arbitrary presentation code.
        next.issuer?.issueAlert(next.alert)
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
