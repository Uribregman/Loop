//
//  TherapyInsights.swift
//  Loop
//
//  Looks for evidence in the history log about whether basal, insulin
//  sensitivity and carb ratio settings match what actually happened.
//
//  ============================ READ THIS FIRST ============================
//
//  EVERYTHING HERE IS ADVISORY. This file computes numbers to SHOW to a person.
//  It has no reference to any settings-mutation API, it is never called from a
//  dosing path, and nothing it produces is applied automatically — not now and
//  not behind a toggle. Changing therapy settings stays a manual act performed
//  by the user, ideally with their care team. `LoopDataManager.therapySettings`
//  has a setter; this file must never touch it.
//
//  The output is deliberately phrased as a question to take to a clinician, not
//  an instruction. Three safeguards enforce that in code:
//
//   1. DATA HYGIENE. Every analysis uses only windows that are clean for the
//      thing being measured — a basal window with a meal in it measures the
//      meal, not the basal. Contaminated windows are discarded, never adjusted.
//   2. MINIMUM EVIDENCE. Each analysis refuses to report at all below a
//      threshold of clean samples, and always states how many it used.
//   3. CAPPED SUGGESTIONS. A suggested value can never differ from the current
//      setting by more than ±20%, mirroring the limit OpenAPS's autotune places
//      on itself. When the cap bites, that is surfaced rather than hidden.
//
//  Windows are chosen by what each measurement NEEDS, not by the period picker
//  on the statistics screen: basal evidence comes from every clean night in the
//  log, carb-ratio evidence requires at least 30 days of meals. A user changing
//  the on-screen period must not change a therapy suggestion.
//
//  METHOD SOURCES:
//   • Basal: standard fasting basal-rate test — glucose should hold within
//     ±30 mg/dL across a fasting window; ≥4 h clear of food and bolus.
//   • ISF: correction-factor verification — an isolated correction from an
//     elevated, stable start, observed over the insulin's action duration.
//   • Caps/dampening: OpenAPS autotune's own safety limits.
//

import Foundation

struct TherapyInsights {

    /// How much evidence something rests on. Carried alongside every result so
    /// a number can never be shown without its sample size.
    struct Evidence {
        let samples: Int
        let required: Int
        var isSufficient: Bool { samples >= required }
    }

    // MARK: - Basal

    enum Drift {
        case steady
        case rising
        case falling
    }

    /// One block of the fasting night, assessed independently — basal needs can
    /// differ sharply between, say, 00:00–03:00 and 03:00–06:00 (dawn effect).
    struct BasalWindow: Identifiable {
        /// Which half of the fasting window this is: 0 = first, 1 = second.
        let half: Int
        /// Clock hours this half covers. Now that the window is fixed at
        /// 00:00–07:00 these are the same every night (0–3, 3–7).
        let startHour: Int
        let endHour: Int
        /// Median change across the block, mg/dL, over all clean nights.
        let medianDrift: Double
        let cleanNights: Int
        var id: Int { half }

        /// ±30 mg/dL across a fasting window is the conventional "basal looks
        /// right" band. Outside it, the DIRECTION is reported — never a rate.
        var verdict: Drift {
            if medianDrift > 30 { return .rising }
            if medianDrift < -30 { return .falling }
            return .steady
        }
    }

    // MARK: - Sensitivity / ratio

    struct SensitivityObservation {
        /// mg/dL per unit, observed from isolated corrections.
        let observed: Double
        let current: Double?
        let evidence: Evidence
        /// Current setting moved toward the observation, capped at ±20%.
        let suggested: Double?
        /// True when the observation was further away than the cap allows —
        /// meaning the honest answer is "look into this", not "use this number".
        let wasCapped: Bool
    }

    struct RatioObservation {
        /// Median grams-per-unit implied by meals that were bolused for.
        let observed: Double
        let current: Double?
        let evidence: Evidence
        /// Median glucose change from the meal to 5 hours later.
        let medianExcursion: Double
        let daysSpanned: Int
        let suggested: Double?
        let wasCapped: Bool
    }

    /// A stretch of time judged suitable for assessing basal.
    struct FastingWindow {
        let start: Date
        let end: Date
    }

    var basalWindows: [BasalWindow] = []
    var sensitivity: SensitivityObservation?
    var carbRatio: RatioObservation?

    /// Nights that were clean enough to assess basal at all. Reported because a
    /// low number is itself the finding: it means the data can't answer yet.
    var cleanNightCount = 0
    /// Meals eligible for carb-ratio assessment.
    var cleanMealCount = 0

    // MARK: - Thresholds

    /// THE NIGHT, as a fixed clock window: 00:00 to 07:00, the user's own
    /// definition.
    ///
    /// It used to prefer whatever HealthKit said the user was actually asleep
    /// for, falling back to the clock. That made the window a different length
    /// every night, made the reported hours meaningless, and made the whole
    /// review silently depend on a Health permission. One fixed window is
    /// comparable night to night, which is the entire point of the comparison.
    static let nightStartHour = 0
    static let nightEndHour = 7

    /// Minimum clean fasting nights before any basal statement is made.
    static let minimumNights = 5
    /// Minimum isolated corrections before an ISF observation is made.
    static let minimumCorrections = 8
    /// Minimum clean meals before a carb-ratio observation is made.
    static let minimumMeals = 15
    /// Carb ratio additionally requires this much calendar coverage — the user's
    /// own requirement, and a sound one: meals vary enormously week to week.
    static let minimumMealDays = 30
    /// Hard cap on how far a suggestion may sit from the current setting.
    static let maximumRelativeChange = 0.20

    // MARK: - Entry point

    /// - Parameters:
    ///   - currentISF: mg/dL per unit, from the therapy settings, if known.
    ///   - currentCarbRatio: grams per unit, if known.
    /// When a meal stops interfering.
    ///
    /// A long-absorption meal is still acting hours after a normal one has
    /// finished — pizza set to 6 hours is not clear at 4. Using a flat 4 h for
    /// everything would quietly let slow carbs contaminate exactly the windows
    /// this file exists to keep clean, so the entry's own absorption time wins
    /// whenever it is longer, plus an hour of margin.
    static func mealClearsAt(eaten: Date, absorption: Double?) -> Date {
        let minimum: TimeInterval = 4 * 3600
        let declared = (absorption ?? 0) + 3600
        return eaten.addingTimeInterval(max(minimum, declared))
    }

    static func compute(from rawLines: [HistoryLine],
                        currentISF: Double? = nil,
                        currentCarbRatio: Double? = nil,
                        calendar: Calendar = .current) -> TherapyInsights {
        // Same de-duplication the statistics use: the log repeats events the
        // pump re-reports, and here a repeat is worse than a wrong total — a
        // duplicated bolus looks like a SECOND bolus, which disqualifies the
        // very windows this file exists to find. See `HistoryLineDeduplicator`.
        let lines = HistoryLineDeduplicator.deduplicated(rawLines)
        var insights = TherapyInsights()

        var glucose: [(date: Date, value: Double)] = []
        var meals: [(eaten: Date, grams: Double, clearsAt: Date)] = []
        var boluses: [(date: Date, units: Double)] = []

        for line in lines {
            guard let date = line.date else { continue }
            switch line.t {
            case "glucose":
                if let mgdl = line.mgdl { glucose.append((date, mgdl)) }
            case "meal":
                let eaten = line.eatenAt.flatMap { HistoryTimestamp.formatter.date(from: $0) } ?? date
                if let grams = line.grams, grams > 0 {
                    meals.append((eaten, grams, mealClearsAt(eaten: eaten, absorption: line.absorption)))
                }
            case "dose":
                // ⚠️ MANUAL boluses ONLY — this is why the whole review used to
                // report nothing at all.
                //
                // Temp basals were already excluded, but AUTOMATIC boluses were
                // not, and on Automatic Bolus dosing the loop delivers one every
                // five minutes around the clock. Every rule below is phrased as
                // "no insulin near this window", so with automatic boluses in
                // the list EVERY night was contaminated, EVERY correction had
                // another bolus stacked on it, and EVERY meal failed the
                // exactly-one-bolus test. The screen was not short of data; it
                // was disqualifying all of it.
                //
                // Automatic dosing is a constant background presence, not an
                // event that spoils a window, so it is not treated as
                // contamination. What it does do is damp the drift the basal
                // check measures — the loop corrects some of it — which is why
                // that check reports a DIRECTION, never a rate.
                if line.kind == "bolus", line.automatic != true,
                   let units = line.units, units > 0 {
                    boluses.append((date, units))
                }
            default:
                continue
            }
        }

        glucose.sort { $0.date < $1.date }
        meals.sort { $0.eaten < $1.eaten }
        boluses.sort { $0.date < $1.date }
        guard glucose.count > 10 else { return insights }

        let nights = cleanFastingNights(glucose: glucose, meals: meals,
                                        boluses: boluses, calendar: calendar)
        insights.cleanNightCount = nights.count
        insights.basalWindows = basalWindows(from: nights, glucose: glucose)

        insights.sensitivity = sensitivityObservation(glucose: glucose, meals: meals,
                                                      boluses: boluses, current: currentISF)
        insights.carbRatio = ratioObservation(glucose: glucose, meals: meals, boluses: boluses,
                                              currentISF: currentISF,
                                              currentRatio: currentCarbRatio,
                                              calendar: calendar)
        return insights
    }

    // MARK: - Basal, from clean fasting nights only

    /// Fasting windows suitable for judging basal.
    ///
    /// One window per day, always 00:00–07:00 (`nightStartHour`/`nightEndHour`).
    /// A window is DISCARDED, never corrected, if any of these hold — each means
    /// the curve is measuring something other than basal:
    ///   • a meal still absorbing into the window (its own absorption time, so
    ///     slow carbs are respected — see `mealClearsAt`)
    ///   • a MANUAL bolus in the 4 h before the window or during it (automatic
    ///     dosing is not contamination — see the note in `compute`)
    ///   • a CGM gap over 30 minutes
    private static func cleanFastingNights(glucose: [(date: Date, value: Double)],
                                           meals: [(eaten: Date, grams: Double, clearsAt: Date)],
                                           boluses: [(date: Date, units: Double)],
                                           calendar: Calendar) -> [FastingWindow] {
        var candidates: [FastingWindow] = []

        var days = Set<Date>()
        for sample in glucose { days.insert(calendar.startOfDay(for: sample.date)) }
        for day in days {
            guard let start = calendar.date(byAdding: .hour, value: nightStartHour, to: day),
                  let end = calendar.date(byAdding: .hour, value: nightEndHour, to: day) else { continue }
            candidates.append(FastingWindow(start: start, end: end))
        }

        return candidates.sorted { $0.start < $1.start }.filter { window in
            // A meal contaminates if it is still absorbing when the window opens.
            let mealActive = meals.contains { $0.clearsAt > window.start && $0.eaten <= window.end }
            if mealActive { return false }

            let quietFrom = window.start.addingTimeInterval(-4 * 3600)
            let bolusNear = boluses.contains { $0.date >= quietFrom && $0.date <= window.end }
            if bolusNear { return false }

            let inWindow = glucose.filter { $0.date >= window.start && $0.date <= window.end }
            // ~4 h of 5-minute data inside the 7-hour window: a night that only
            // half-reported is still usable, a night that barely reported is not.
            guard inWindow.count >= 48 else { return false }
            let largestGap = zip(inWindow, inWindow.dropFirst())
                .map { $1.date.timeIntervalSince($0.date) }
                .max() ?? 0
            return largestGap <= 30 * 60
        }
    }

    /// Each fasting window is split into a first and second half and assessed
    /// separately: needs commonly differ between early night and the pre-dawn
    /// hours, and averaging the two hides exactly that difference.
    private static func basalWindows(from nights: [FastingWindow],
                                     glucose: [(date: Date, value: Double)]) -> [BasalWindow] {
        guard nights.count >= minimumNights else { return [] }

        var firstHalf: [Double] = []
        var secondHalf: [Double] = []
        var firstStarts: [Int] = []
        var midHours: [Int] = []
        var endHours: [Int] = []
        let calendar = Calendar.current

        for night in nights {
            let midpoint = night.start.addingTimeInterval(night.end.timeIntervalSince(night.start) / 2)
            if let a = nearestReading(to: night.start, in: glucose, tolerance: 15 * 60),
               let b = nearestReading(to: midpoint, in: glucose, tolerance: 15 * 60) {
                firstHalf.append(b - a)
            }
            if let b = nearestReading(to: midpoint, in: glucose, tolerance: 15 * 60),
               let c = nearestReading(to: night.end, in: glucose, tolerance: 15 * 60) {
                secondHalf.append(c - b)
            }
            // Collected across ALL nights so the label is a typical hour, not
            // whichever night happened to be processed last.
            firstStarts.append(calendar.component(.hour, from: night.start))
            midHours.append(calendar.component(.hour, from: midpoint))
            endHours.append(calendar.component(.hour, from: night.end))
        }

        func typical(_ hours: [Int]) -> Int {
            guard !hours.isEmpty else { return 0 }
            return Int((median(hours.map(Double.init)) ?? 0).rounded())
        }

        var results: [BasalWindow] = []
        if firstHalf.count >= minimumNights {
            results.append(BasalWindow(half: 0,
                                       startHour: typical(firstStarts), endHour: typical(midHours),
                                       medianDrift: median(firstHalf) ?? 0,
                                       cleanNights: firstHalf.count))
        }
        if secondHalf.count >= minimumNights {
            results.append(BasalWindow(half: 1,
                                       startHour: typical(midHours), endHour: typical(endHours),
                                       medianDrift: median(secondHalf) ?? 0,
                                       cleanNights: secondHalf.count))
        }
        return results
    }

    // MARK: - ISF, from isolated corrections only

    /// A correction is usable only if it is genuinely isolated: no carbs either
    /// side of it, an elevated and therefore measurable starting point, and no
    /// further insulin or food during the observation window.
    private static func sensitivityObservation(glucose: [(date: Date, value: Double)],
                                               meals: [(eaten: Date, grams: Double, clearsAt: Date)],
                                               boluses: [(date: Date, units: Double)],
                                               current: Double?) -> SensitivityObservation? {
        var observations: [Double] = []

        for bolus in boluses {
            let windowEnd = bolus.date.addingTimeInterval(4 * 3600)

            // No carbs within an hour before, or at any point during.
            // Long carbs count: a meal is "near" if it is still absorbing.
            let carbsNear = meals.contains {
                $0.clearsAt > bolus.date && $0.eaten <= windowEnd
            }
            if carbsNear { continue }
            // No second MANUAL bolus stacking on top.
            let otherBolus = boluses.contains {
                $0.date > bolus.date && $0.date <= windowEnd
            }
            if otherBolus { continue }

            guard let start = nearestReading(to: bolus.date, in: glucose, tolerance: 10 * 60),
                  start >= 150,
                  let end = nearestReading(to: windowEnd, in: glucose, tolerance: 20 * 60) else { continue }

            let drop = start - end
            guard drop > 0 else { continue }
            observations.append(drop / bolus.units)
        }

        let evidence = Evidence(samples: observations.count, required: minimumCorrections)
        guard evidence.isSufficient, let observed = median(observations) else {
            return observations.isEmpty ? nil
                : SensitivityObservation(observed: median(observations) ?? 0,
                                         current: current, evidence: evidence,
                                         suggested: nil, wasCapped: false)
        }

        let capped = cap(observed, toward: current)
        return SensitivityObservation(observed: observed,
                                      current: current,
                                      evidence: evidence,
                                      suggested: capped.value,
                                      wasCapped: capped.wasCapped)
    }

    // MARK: - Carb ratio, from at least 30 days of bolused meals

    private static func ratioObservation(glucose: [(date: Date, value: Double)],
                                         meals: [(eaten: Date, grams: Double, clearsAt: Date)],
                                         boluses: [(date: Date, units: Double)],
                                         currentISF: Double?,
                                         currentRatio: Double?,
                                         calendar: Calendar) -> RatioObservation? {
        var impliedRatios: [Double] = []
        var excursions: [Double] = []
        var firstMeal: Date?
        var lastMeal: Date?

        for meal in meals where meal.grams >= 20 {
            // Watch a slow meal for as long as it is actually absorbing, not a
            // flat 5 hours that would cut a 6-hour pizza off mid-curve.
            let windowEnd = max(meal.eaten.addingTimeInterval(5 * 3600), meal.clearsAt)

            // Exactly one MANUAL bolus, close to the meal, and nothing else
            // for 5 h. (Automatic boluses are excluded upstream; requiring
            // exactly one of THOSE would never match on closed loop.)
            let paired = boluses.filter {
                abs($0.date.timeIntervalSince(meal.eaten)) <= 20 * 60
            }
            guard paired.count == 1, let bolus = paired.first, bolus.units > 0 else { continue }
            let laterBolus = boluses.contains {
                $0.date > bolus.date.addingTimeInterval(20 * 60) && $0.date <= windowEnd
            }
            if laterBolus { continue }
            let laterMeal = meals.contains {
                $0.eaten > meal.eaten && $0.eaten <= windowEnd
            }
            if laterMeal { continue }

            guard let start = nearestReading(to: meal.eaten, in: glucose, tolerance: 15 * 60),
                  let end = nearestReading(to: windowEnd, in: glucose, tolerance: 20 * 60) else { continue }

            let excursion = end - start
            excursions.append(excursion)
            firstMeal = firstMeal.map { min($0, meal.eaten) } ?? meal.eaten
            lastMeal = lastMeal.map { max($0, meal.eaten) } ?? meal.eaten

            // Convert the leftover excursion into the insulin that would have
            // neutralised it, and from there to the ratio the meal implies.
            // Needs an ISF to translate mg/dL into units; without one we can
            // still report the excursion, just not a ratio.
            if let isf = currentISF, isf > 0 {
                let extraUnits = excursion / isf
                let impliedUnits = bolus.units + extraUnits
                if impliedUnits > 0.1 {
                    impliedRatios.append(meal.grams / impliedUnits)
                }
            }
        }

        guard !excursions.isEmpty, let first = firstMeal, let last = lastMeal else { return nil }
        let daysSpanned = Int(last.timeIntervalSince(first) / 86400)
        let evidence = Evidence(samples: excursions.count, required: minimumMeals)

        // BOTH gates must pass: enough meals AND enough calendar time. Fifteen
        // meals inside one week is not 15 meals' worth of evidence about a
        // setting that has to hold across a month of ordinary life.
        let hasEnoughData = evidence.isSufficient && daysSpanned >= minimumMealDays
        let observed = median(impliedRatios) ?? currentRatio ?? 0
        let capped = hasEnoughData && !impliedRatios.isEmpty
            ? cap(observed, toward: currentRatio)
            : (value: nil as Double?, wasCapped: false)

        return RatioObservation(observed: observed,
                                current: currentRatio,
                                evidence: evidence,
                                medianExcursion: median(excursions) ?? 0,
                                daysSpanned: daysSpanned,
                                suggested: capped.value,
                                wasCapped: capped.wasCapped)
    }

    // MARK: - Helpers

    /// Clamp an observation to within ±20% of the current setting.
    ///
    /// When the observation lands outside that, the capped value is returned AND
    /// flagged — a gap that large is a reason to talk to a clinician, not a
    /// number to type in.
    private static func cap(_ observed: Double, toward current: Double?)
    -> (value: Double?, wasCapped: Bool) {
        guard let current, current > 0 else { return (nil, false) }
        let lower = current * (1 - maximumRelativeChange)
        let upper = current * (1 + maximumRelativeChange)
        if observed < lower { return (lower, true) }
        if observed > upper { return (upper, true) }
        return (observed, false)
    }

    private static func nearestReading(to date: Date,
                                       in glucose: [(date: Date, value: Double)],
                                       tolerance: TimeInterval) -> Double? {
        var best: Double?
        var bestGap = TimeInterval.greatestFiniteMagnitude
        // Linear scan is fine: these are called a handful of times per night or
        // meal, not per reading.
        for sample in glucose {
            let gap = abs(sample.date.timeIntervalSince(date))
            if gap <= tolerance && gap < bestGap {
                bestGap = gap
                best = sample.value
            }
            if sample.date > date.addingTimeInterval(tolerance) { break }
        }
        return best
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
