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

    /// Loop's delivery against the programmed basal over a block.
    enum LoopLeaning {
        case more
        case about
        case less
    }

    /// What a block of the night shows, with Loop's part taken into account.
    enum Finding {
        /// Held steady on about the programmed basal.
        case steady
        /// Held steady, but only with Loop giving clearly more than programmed.
        case steadyWithMore
        /// Held steady, but only with Loop giving clearly less than programmed.
        case steadyWithLess
        /// Rose, and not because Loop was holding back.
        case rising
        /// Fell, and not because Loop was adding.
        case falling
        /// Moved in the direction Loop was pushing it: says nothing about basal.
        case unclear
    }

    /// One block of the fasting night, assessed independently — basal needs can
    /// differ sharply between, say, 00:00–03:00 and 03:00–06:00 (dawn effect).
    struct BasalWindow: Identifiable {
        /// Which part of the night this is: 0 = 00:00–03:00, 1 = 03:00–07:00.
        let half: Int
        /// Clock hours this part covers, the same every night (0–3, 3–7).
        let startHour: Int
        let endHour: Int
        /// Median change across the block, mg/dL, over all clean nights.
        let medianDrift: Double
        let cleanNights: Int
        /// What Loop delivered over those blocks (basal plus its automatic
        /// boluses) as a fraction of the programmed basal for the same time; nil
        /// when no basal schedule was given.
        ///
        /// ⚠️ THE OTHER HALF OF THE EVIDENCE. Loop corrects a drift as it starts,
        /// so "glucose held steady" says little on its own: steady while Loop
        /// gave 130% of the programmed basal is a different finding from steady
        /// at 100%.
        let loopShare: Double?
        var id: Int { half }

        /// ±30 mg/dL across a fasting window is the conventional "basal looks
        /// right" band. Outside it, the DIRECTION is reported — never a rate.
        var verdict: Drift {
            if medianDrift > 30 { return .rising }
            if medianDrift < -30 { return .falling }
            return .steady
        }

        /// What Loop was doing meanwhile, when that is known and clear-cut:
        /// giving noticeably more than the programmed basal, or noticeably less.
        var loopLeaning: LoopLeaning? {
            guard let loopShare else { return nil }
            if loopShare >= 1 + Self.loopLeaningMargin { return .more }
            if loopShare <= 1 - Self.loopLeaningMargin { return .less }
            return .about
        }
        static let loopLeaningMargin = 0.15

        /// The direction and Loop's part in it, read together.
        ///
        /// ⚠️ THE DRIFT ALONE CAN POINT THE WRONG WAY. Glucose that falls while
        /// Loop is giving MORE than the programmed basal is Loop correcting, not
        /// basal set too high; glucose that rises while Loop holds back is Loop
        /// recovering from something, not basal set too low. Only a drift that
        /// happens DESPITE what Loop did, or a steady line that needed Loop to
        /// lean hard one way, says something about the basal setting.
        var finding: Finding {
            switch (verdict, loopLeaning) {
            case (.steady, .more?):   return .steadyWithMore
            case (.steady, .less?):   return .steadyWithLess
            case (.steady, _):        return .steady
            case (.rising, .less?):   return .unclear
            case (.rising, _):        return .rising
            case (.falling, .more?):  return .unclear
            case (.falling, _):       return .falling
            }
        }
    }

    // MARK: - Sensitivity / ratio

    struct SensitivityObservation {
        /// mg/dL per unit, observed from isolated corrections: the fall over
        /// four hours divided by the bolus plus what Loop added or held back.
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
        /// Median grams-per-unit implied by meals that were bolused for. Nil
        /// when no sensitivity setting was given: the leftover excursion cannot
        /// be turned into insulin without one, and the current setting must
        /// never be shown back as an "observation".
        let observed: Double?
        let current: Double?
        let evidence: Evidence
        /// Median glucose change from the meal to the end of its window (when
        /// it has finished absorbing: 4 hours at least).
        let medianExcursion: Double
        let daysSpanned: Int
        /// Different calendar days the meals fall on.
        let distinctDays: Int
        let suggested: Double?
        let wasCapped: Bool
    }

    var basalWindows: [BasalWindow] = []
    var sensitivity: SensitivityObservation?
    var carbRatio: RatioObservation?

    /// Nights that were clean enough to assess basal at all. Reported because a
    /// low number is itself the finding: it means the data can't answer yet.
    var cleanNightCount = 0
    /// Clean blocks of each part of the night, whether or not there are enough
    /// of them to report: the "so far" in "needs at least five".
    var cleanEarlyNightCount = 0
    var cleanLateNightCount = 0
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
    /// ...and on at least this many different days: two meals a month apart
    /// would otherwise satisfy "30 days" on their own.
    static let minimumDistinctMealDays = 10
    /// Where the night is split. Each part is judged on its own.
    static let nightSplitHour = 3
    /// Boluses of the user's own this close to a meal are the bolus for it: one
    /// given a little early, the rest once the plate is seen.
    static let mealBolusLead: TimeInterval = 30 * 60
    static let mealBolusLag: TimeInterval = 45 * 60
    /// Carb entries this close to a meal's first entry are part of that meal.
    static let mealMergeWindow: TimeInterval = 30 * 60
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
                        basalSchedule: [BasalDelivery.ScheduleEntry] = [],
                        calendar: Calendar = .current) -> TherapyInsights {
        // Same de-duplication the statistics use: the log repeats events the
        // pump re-reports, and here a repeat is worse than a wrong total — a
        // duplicated bolus looks like a SECOND bolus, which disqualifies the
        // very windows this file exists to find. See `HistoryLineDeduplicator`.
        let lines = HistoryLineDeduplicator.deduplicated(rawLines)
        var insights = TherapyInsights()

        var glucose: [(date: Date, value: Double)] = []
        var entries: [(eaten: Date, grams: Double, clearsAt: Date)] = []
        var boluses: [(date: Date, units: Double)] = []
        var automatic: [(date: Date, units: Double)] = []

        for line in lines {
            guard let date = line.date else { continue }
            switch line.t {
            case "glucose":
                if let mgdl = line.mgdl { glucose.append((date, mgdl)) }
            case "meal":
                let eaten = line.eatenAt.flatMap { HistoryTimestamp.formatter.date(from: $0) } ?? date
                if let grams = line.grams, grams > 0 {
                    entries.append((eaten, grams, mealClearsAt(eaten: eaten, absorption: line.absorption)))
                }
            case "dose":
                // ⚠️ MANUAL boluses are the EVENTS; automatic ones are not.
                //
                // On Automatic Bolus dosing the loop delivers one every five
                // minutes around the clock. Every rule below is phrased as "no
                // insulin near this window", so with automatic boluses in that
                // list EVERY night was contaminated, EVERY correction had
                // another bolus stacked on it, and EVERY meal failed the
                // one-bolus test. The screen was not short of data; it was
                // disqualifying all of it.
                //
                // Automatic dosing is a constant background presence, not an
                // event that spoils a window, so it does not disqualify one. It
                // is still INSULIN, though, and it is counted wherever a figure
                // divides by insulin — see `Loop.extraUnits`.
                guard line.kind == "bolus", let units = line.units, units > 0 else { continue }
                if line.automatic == true { automatic.append((date, units)) } else { boluses.append((date, units)) }
            default:
                continue
            }
        }

        glucose.sort { $0.date < $1.date }
        boluses.sort { $0.date < $1.date }
        automatic.sort { $0.date < $1.date }
        guard glucose.count > 10 else { return insights }

        // Entries a few minutes apart are one meal — see `mealMergeWindow`.
        var meals: [(eaten: Date, grams: Double, clearsAt: Date)] = []
        for entry in entries.sorted(by: { $0.eaten < $1.eaten }) {
            if let last = meals.indices.last, entry.eaten.timeIntervalSince(meals[last].eaten) <= mealMergeWindow {
                meals[last].grams += entry.grams
                meals[last].clearsAt = max(meals[last].clearsAt, entry.clearsAt)
            } else {
                meals.append(entry)
            }
        }

        let loop = Loop(automatic: automatic,
                        delivery: basalSchedule.isEmpty ? nil : BasalDelivery(lines: lines, schedule: basalSchedule, calendar: calendar))

        let nights = cleanNightBlocks(glucose: glucose, meals: meals, boluses: boluses, calendar: calendar)
        insights.cleanEarlyNightCount = nights.filter { $0.part == 0 }.count
        insights.cleanLateNightCount = nights.filter { $0.part == 1 }.count
        insights.cleanNightCount = Set(nights.map(\.day)).count
        insights.basalWindows = basalWindows(from: nights, loop: loop)

        insights.sensitivity = sensitivityObservation(glucose: glucose, meals: meals,
                                                      boluses: boluses, loop: loop, current: currentISF)
        insights.carbRatio = ratioObservation(glucose: glucose, meals: meals, boluses: boluses, loop: loop,
                                              currentISF: currentISF,
                                              currentRatio: currentCarbRatio,
                                              calendar: calendar)
        insights.cleanMealCount = insights.carbRatio?.evidence.samples ?? 0
        return insights
    }

    /// What Loop did by itself over a stretch of time.
    ///
    /// ⚠️ WHY THE SETTINGS FIGURES NEED THIS. "Glucose fell 90 after a 2 U
    /// correction" is 45 per unit only if 2 U is all the insulin there was. In
    /// one real log Loop added 4 U of automatic bolus to two such corrections and
    /// held back 4 U of basal on another, and the 17 clean meals carried 39% more
    /// insulin than the user's own bolus. Dividing by the manual bolus alone made
    /// every "observed" figure wrong, in a direction that depends on what Loop
    /// happened to do.
    struct Loop {
        let automatic: [(date: Date, units: Double)]
        /// Nil without a basal schedule: only the automatic boluses are known.
        let delivery: BasalDelivery?

        func automaticUnits(from start: Date, to end: Date) -> Double {
            automatic.reduce(0) { $1.date >= start && $1.date <= end ? $0 + $1.units : $0 }
        }

        /// Automatic boluses, plus basal delivered above (or, negative, below)
        /// the programmed schedule.
        func extraUnits(from start: Date, to end: Date) -> Double {
            automaticUnits(from: start, to: end) + (delivery?.basalAgainstSchedule(from: start, to: end) ?? 0)
        }
    }

    // MARK: - Basal, from clean fasting blocks of the night only

    /// One clean block of one night.
    struct NightBlock {
        let day: Date
        /// 0 = 00:00 to `nightSplitHour`, 1 = from there to 07:00.
        let part: Int
        let start: Date
        let end: Date
        /// Glucose at the end less glucose at the start.
        let drift: Double
    }

    /// The blocks of each night that are suitable for judging basal.
    ///
    /// ⚠️ EACH PART OF THE NIGHT IS JUDGED ON ITS OWN. The whole 00:00–07:00
    /// window used to have to be clean, with no bolus of the user's from 20:00
    /// on — so an ordinary dinner bolus at 20:30 threw away the whole night, and
    /// 60 days of data produced three nights. The hours after 03:00 are clean
    /// far more often than the hours after midnight, and they are judged
    /// separately anyway.
    ///
    /// A block is DISCARDED, never corrected, if any of these hold — each means
    /// the curve is measuring something other than basal:
    ///   • a meal still absorbing into it (its own absorption time, so slow
    ///     carbs are respected — see `mealClearsAt`)
    ///   • a MANUAL bolus in the 4 h before it or during it
    ///   • fewer than two thirds of its readings, or a CGM gap over 30 minutes
    ///   • glucose outside 70–180 when it opens
    private static func cleanNightBlocks(glucose: [(date: Date, value: Double)],
                                         meals: [(eaten: Date, grams: Double, clearsAt: Date)],
                                         boluses: [(date: Date, units: Double)],
                                         calendar: Calendar) -> [NightBlock] {
        var days = Set<Date>()
        for sample in glucose { days.insert(calendar.startOfDay(for: sample.date)) }

        var blocks: [NightBlock] = []
        for day in days.sorted() {
            let hours = [nightStartHour, nightSplitHour, nightEndHour]
            for part in 0..<2 {
                guard let start = calendar.date(bySettingHour: hours[part], minute: 0, second: 0, of: day),
                      let end = calendar.date(bySettingHour: hours[part + 1], minute: 0, second: 0, of: day) else { continue }

                // A meal contaminates if it is still absorbing when the block opens.
                if meals.contains(where: { $0.clearsAt > start && $0.eaten <= end }) { continue }
                let quietFrom = start.addingTimeInterval(-4 * 3600)
                if boluses.contains(where: { $0.date >= quietFrom && $0.date <= end }) { continue }

                let inside = glucose.filter { $0.date >= start && $0.date <= end }
                let expected = end.timeIntervalSince(start) / 300
                guard Double(inside.count) >= expected * 2 / 3 else { continue }
                let largestGap = zip(inside, inside.dropFirst()).map { $1.date.timeIntervalSince($0.date) }.max() ?? 0
                guard largestGap <= 30 * 60,
                      let first = nearestReading(to: start, in: glucose, tolerance: 15 * 60),
                      let last = nearestReading(to: end, in: glucose, tolerance: 15 * 60) else { continue }
                // A basal test starts IN RANGE. A block that opens high is Loop
                // bringing a high down, and one that opens low is a low being
                // recovered from; neither says anything about basal.
                guard first >= 70 && first <= 180 else { continue }
                blocks.append(NightBlock(day: day, part: part, start: start, end: end, drift: last - first))
            }
        }
        return blocks
    }

    private static func basalWindows(from blocks: [NightBlock], loop: Loop) -> [BasalWindow] {
        let hours = [nightStartHour, nightSplitHour, nightEndHour]
        return (0..<2).compactMap { part in
            let matching = blocks.filter { $0.part == part }
            guard matching.count >= minimumNights else { return nil }
            var loopShare: Double?
            if let delivery = loop.delivery {
                var delivered = 0.0
                var programmed = 0.0
                for block in matching {
                    programmed += delivery.scheduledUnits(from: block.start, to: block.end)
                    delivered += delivery.tempBasalUnits(from: block.start, to: block.end)
                        + delivery.scheduledUnitsDelivered(from: block.start, to: block.end)
                        + loop.automaticUnits(from: block.start, to: block.end)
                }
                if programmed > 0 { loopShare = delivered / programmed }
            }
            return BasalWindow(half: part,
                               startHour: hours[part], endHour: hours[part + 1],
                               medianDrift: median(matching.map(\.drift)) ?? 0,
                               cleanNights: matching.count,
                               loopShare: loopShare)
        }
    }

    // MARK: - ISF, from isolated corrections only

    /// A correction is usable only if it is genuinely isolated: no carbs either
    /// side of it, an elevated and therefore measurable starting point, and no
    /// other insulin of the user's or food for four hours before or after.
    private static func sensitivityObservation(glucose: [(date: Date, value: Double)],
                                               meals: [(eaten: Date, grams: Double, clearsAt: Date)],
                                               boluses: [(date: Date, units: Double)],
                                               loop: Loop,
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
            // No other MANUAL bolus stacking on top — and none still acting
            // from before, which this used not to check: the fall then belongs
            // to two boluses and was credited to one.
            let windowStart = bolus.date.addingTimeInterval(-4 * 3600)
            let otherBolus = boluses.contains {
                $0.date != bolus.date && $0.date >= windowStart && $0.date <= windowEnd
            }
            if otherBolus { continue }

            guard let start = nearestReading(to: bolus.date, in: glucose, tolerance: 10 * 60),
                  start >= 150,
                  let end = nearestReading(to: windowEnd, in: glucose, tolerance: 20 * 60) else { continue }

            // ALL the insulin that acted: the bolus, and what Loop added or
            // held back. See `Loop`.
            let insulin = bolus.units + loop.extraUnits(from: bolus.date, to: windowEnd)
            let drop = start - end
            guard drop > 0, insulin > 0.1 else { continue }
            observations.append(drop / insulin)
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
                                         loop: Loop,
                                         currentISF: Double?,
                                         currentRatio: Double?,
                                         calendar: Calendar) -> RatioObservation? {
        var impliedRatios: [Double] = []
        var excursions: [Double] = []
        var firstMeal: Date?
        var lastMeal: Date?
        var mealDays = Set<Date>()

        for meal in meals where meal.grams >= 20 {
            // Watch the meal until it has finished absorbing: its own
            // absorption time plus an hour, four hours at the least.
            let windowEnd = meal.clearsAt

            // ⚠️ THE BOLUS FOR A MEAL IS OFTEN GIVEN IN PARTS. "Exactly one bolus
            // within 20 minutes" threw out every meal bolused for in two goes;
            // the parts given from half an hour before to 45 minutes after are
            // one bolus, added up. Anything of the user's AFTER that is a
            // correction, and the meal is left out.
            let pairedFrom = meal.eaten.addingTimeInterval(-mealBolusLead)
            let pairedUntil = meal.eaten.addingTimeInterval(mealBolusLag)
            let paired = boluses.filter { $0.date >= pairedFrom && $0.date <= pairedUntil }
            let bolusUnits = paired.reduce(0) { $0 + $1.units }
            guard bolusUnits > 0 else { continue }
            let laterBolus = boluses.contains { $0.date > pairedUntil && $0.date <= windowEnd }
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
            mealDays.insert(calendar.startOfDay(for: meal.eaten))

            // Convert the leftover excursion into the insulin that would have
            // neutralised it, and from there to the ratio the meal implies.
            // Needs an ISF to translate mg/dL into units; without one we can
            // still report the excursion, just not a ratio.
            if let isf = currentISF, isf > 0 {
                // The user's bolus AND what Loop added or held back — see `Loop`.
                let given = bolusUnits + loop.extraUnits(from: meal.eaten, to: windowEnd)
                let impliedUnits = given + excursion / isf
                if impliedUnits > 0.1 {
                    impliedRatios.append(meal.grams / impliedUnits)
                }
            }
        }

        guard !excursions.isEmpty, let first = firstMeal, let last = lastMeal else { return nil }
        let daysSpanned = Int(last.timeIntervalSince(first) / 86400)
        let evidence = Evidence(samples: excursions.count, required: minimumMeals)

        // ALL the gates must pass: enough meals, enough calendar time, and
        // enough different days. Fifteen meals inside one week is not 15 meals'
        // worth of evidence about a setting that has to hold across a month of
        // ordinary life.
        let hasEnoughData = evidence.isSufficient && daysSpanned >= minimumMealDays
            && mealDays.count >= minimumDistinctMealDays
        let observed = median(impliedRatios)
        let capped = hasEnoughData && observed != nil
            ? cap(observed ?? 0, toward: currentRatio)
            : (value: nil as Double?, wasCapped: false)

        return RatioObservation(observed: observed,
                                current: currentRatio,
                                evidence: evidence,
                                medianExcursion: median(excursions) ?? 0,
                                daysSpanned: daysSpanned,
                                distinctDays: mealDays.count,
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
