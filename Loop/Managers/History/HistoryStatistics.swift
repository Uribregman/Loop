//
//  HistoryStatistics.swift
//  Loop
//
//  Turns the history log into summary numbers for the statistics screen.
//
//  Pure computation: it takes decoded lines in and hands values back. It reads
//  nothing from Loop and writes nothing anywhere, so it cannot affect dosing.
//
//  DESIGN RULE for anything built on this: surface the evidence, never compute a
//  dose. Nothing here suggests a basal rate, carb ratio or correction factor, and
//  nothing here should ever start doing so — this is an insulin-dosing app, and a
//  number that looks like a recommendation will eventually be treated as one.
//

import Foundation

struct HistoryStatistics {

    // MARK: - Glucose

    struct Glucose {
        var count = 0
        /// mg/dL.
        var mean: Double = 0
        var standardDeviation: Double = 0
        /// Coefficient of variation, as a percentage. Above ~36% is generally
        /// described as high variability.
        var coefficientOfVariation: Double = 0
        /// Glucose Management Indicator, an estimated A1c in percent.
        var gmi: Double = 0

        /// Fractions of readings, 0...1.
        var veryLow: Double = 0    // < 54
        var low: Double = 0        // 54–69
        var inRange: Double = 0    // 70–180
        var high: Double = 0       // 181–250
        var veryHigh: Double = 0   // > 250

        /// Mean split by time of day — the cheapest way to see an overnight
        /// pattern without asking the user to read a chart.
        var overnightMean: Double?  // 00:00–06:00
        var daytimeMean: Double?

        /// Time in the tighter 80–140 band. A harder target than 70–180, and
        /// deliberately floored at 80 rather than 70 — it is meant to describe
        /// good control, and readings in the 70s are closer to a low than to it.
        var inTightRange: Double = 0
    }

    /// How complete the CGM data is: readings received against the ~288/day a
    /// 5-minute sensor should produce.
    ///
    /// Shown because it qualifies everything else. Time in range computed from
    /// half the expected readings is not wrong exactly, but it is far less
    /// trustworthy, and hiding that would be misleading.
    struct Coverage {
        var expected = 0
        var received = 0
        var fraction: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
    }

    /// Hypoglycemic EVENTS, per the international CGM consensus (Battelino et
    /// al.), not "share of readings that were low".
    ///
    /// An event starts only after glucose is under the threshold for >=15
    /// CONSECUTIVE minutes, and ends after >=15 consecutive minutes at or above
    /// it. That 15-minute rule matters: without it a sensor wobbling across 69
    /// for one reading counts as a hypo, and the number becomes meaningless.
    /// (My first version had exactly that bug.)
    ///
    /// "Six lows this month, averaging 25 minutes" is something you can picture
    /// and act on; "1.2% of readings below 70" is not.
    struct LowEvents {
        /// Events below 70 mg/dL (consensus level 1 or 2).
        var count = 0
        /// The subset below 54 mg/dL — level 2, the clinically serious ones.
        var level2Count = 0
        var averageDuration: TimeInterval?
        var perWeek: Double = 0
    }

    /// Hyperglycemic events above 250 mg/dL, same >=15-minute rule.
    struct HighEvents {
        var count = 0
        var averageDuration: TimeInterval?
        var perWeek: Double = 0
    }

    /// Per-day results, which is what makes goals and streaks possible.
    struct Days {
        var counted = 0
        /// Days at or above 70% time in range.
        var meetingGoal = 0
        /// Longest run of consecutive days meeting the goal.
        var bestStreak = 0
        /// ⚠️ NIL UNLESS THERE ARE ENOUGH DAYS OF THAT KIND. A weekend average
        /// built from ONE Saturday is not "your weekends", and the sentence this
        /// feeds says "tend to go better" — a habit, which needs several of each
        /// to claim. See `minimumDaysPerWeekPart`.
        var weekdayInRange: Double?
        var weekendInRange: Double?
        /// How many days each average is actually made of, so the screen can
        /// show its evidence instead of asking to be trusted.
        var weekdayCount = 0
        var weekendCount = 0
    }

    /// Average change from 03:00 to 08:00 — the dawn phenomenon, quantified.
    /// Positive means glucose climbs through the early morning.
    struct Dawn {
        var averageRise: Double?
        var daysMeasured = 0
    }

    // MARK: - Insulin

    struct Insulin {
        /// Everything delivered: boluses and basal.
        var totalUnits: Double = 0
        /// Every bolus, the user's own and Loop's.
        var bolusUnits: Double = 0
        /// Boluses the user asked for.
        var manualBolusUnits: Double = 0
        /// Boluses Loop gave by itself.
        var automaticBolusUnits: Double = 0
        /// Basal actually delivered: temp basals as recorded, plus the programmed
        /// schedule for the time no temp basal or suspension was in force.
        ///
        /// ⚠️ THE SCHEDULED PART IS NOT IN THE LOG. The pump reports temp basals,
        /// boluses, suspends and resumes; the schedule it runs the rest of the
        /// time is never written. Summing dose records alone therefore missed
        /// about 16 U a day in one real log, so "insulin per day" read 65 against
        /// the 84 the pods themselves reported, and "given as bolus" read 96%.
        /// It is rebuilt here from the schedule (`BasalDelivery`), which matched
        /// the pods' own totals to 0.1%. Without a schedule it cannot be, and
        /// `includesScheduledBasal` is false.
        var basalUnits: Double = 0
        /// The part of `basalUnits` that came from recorded temp basals.
        var tempBasalUnits: Double = 0
        /// False when no basal schedule was available: `basalUnits` is then temp
        /// basals only and every total is short by the scheduled basal.
        var includesScheduledBasal = false
        var dailyAverage: Double = 0
        /// Shares of the total, 0...1. The three add up to 1.
        var manualBolusShare: Double { totalUnits > 0 ? manualBolusUnits / totalUnits : 0 }
        var automaticBolusShare: Double { totalUnits > 0 ? automaticBolusUnits / totalUnits : 0 }
        var basalShare: Double { totalUnits > 0 ? basalUnits / totalUnits : 0 }
        /// Bolus as a fraction of total, 0...1.
        var bolusShare: Double { totalUnits > 0 ? bolusUnits / totalUnits : 0 }
    }

    // MARK: - Meals

    struct Meals {
        var entryCount = 0
        var totalGrams: Double = 0
        var dailyAverageGrams: Double = 0
        /// How long after eating the meal was logged, averaged. A consistently
        /// large number explains a lot of post-meal highs on its own.
        var medianLoggingDelay: TimeInterval?
    }

    // MARK: - Pods

    struct Pods {
        var count = 0
        var meanHours: Double = 0
        /// Sessions that ended in a fault, as a fraction of all sessions.
        var faultRate: Double = 0
        /// Units left in pods when they stopped — insulin thrown away. Only the
        /// pods that reported an amount: see `overfullCount`.
        var wastedUnits: Double = 0
        /// How many pods `wastedUnits` is the total of.
        var measuredCount = 0
        /// Units left in a pod when it stopped, on average over the pods that
        /// reported an amount. Nil when none did.
        var wastedUnitsPerPod: Double? {
            measuredCount > 0 ? wastedUnits / Double(measuredCount) : nil
        }
        /// Pods that stopped with MORE THAN 50 U left. A pod cannot measure its
        /// reservoir above 50 U and reports a fixed marker (51.15) instead, which
        /// used to be added to the discarded total as if it were an amount.
        var overfullCount = 0
        /// Stop reason → how many times, most common first.
        var stopReasons: [(reason: String, count: Int)] = []
    }

    // MARK: - Patterns

    /// One hour of the day, with its spread as well as its middle.
    ///
    /// The percentiles are what make this an AGP-style profile rather than just a
    /// line: a median of 150 at 3pm means something quite different when the
    /// 10th–90th spread is 140–160 versus 70–260. The first is a level to look
    /// at; the second is unpredictability, and they need different responses.
    ///
    /// ⚠️ ONE VALUE PER DAY, NOT ONE PER READING. Each day contributes that
    /// day's MEDIAN for this hour, and the percentiles are taken across those
    /// day-values. Pooling every reading instead — which is what this used to do
    /// — mixes two different things: how much an hour moves WITHIN a day, and
    /// how much it differs BETWEEN days. The caption on the chart promises the
    /// second one. Pooling also silently weights days by how many readings the
    /// CGM happened to return, so a day with a sensor gap counted for less, and
    /// it made the bands change shape with the selected period even when the
    /// underlying days had not changed. One value per day fixes all three: `n`
    /// is the number of DAYS, whatever period is selected.
    struct HourlyPoint: Identifiable {
        let hour: Int
        let mean: Double
        /// Readings behind this hour, across all days. Reported, not used for
        /// the percentiles.
        let count: Int
        /// Days contributing to this hour — the `n` the percentiles are over.
        let days: Int
        let p10: Double
        let p25: Double
        let median: Double
        let p75: Double
        let p90: Double
        var id: Int { hour }
        /// Interquartile spread — the usual day-to-day scatter at this hour.
        var iqr: Double { p75 - p25 }
        /// With only a handful of days, p10/p90 collapse onto the extremes and
        /// stop meaning "typical range". Below this the outer band is not drawn.
        var hasOuterBand: Bool { days >= HistoryStatistics.minimumDaysForOuterBand }
    }

    /// Post-meal response split by which meal it was.
    ///
    /// Worth separating because breakfast very often behaves differently from the
    /// rest of the day, and an all-meals average hides exactly that.
    struct MealWindow: Identifiable {
        let name: String
        let averageRise: Double
        let count: Int
        var id: String { name }
    }

    /// What happens around the edges of an excursion — the recovery behaviour
    /// that a simple time-in-range number says nothing about.
    struct Recovery {
        /// Share of low events followed by a climb above 180 within 2 hours.
        /// A high number is the classic signature of over-treating lows.
        var lowsFollowedByHigh: Double?
        var lowsAnalysed = 0
        /// Median minutes from crossing 250 to getting back under 180.
        var medianHighRecovery: TimeInterval?
        var highExcursions = 0
    }

    /// What happens to glucose after a logged meal.
    ///
    /// This is only computable because meal records carry a real EATING time
    /// separate from the entry time. It is the one place the log links a
    /// behaviour to its outcome, which is what makes it worth showing.
    struct PostMeal {
        var mealsAnalysed = 0
        /// Average peak rise, in mg/dL, within 3 hours of eating.
        var averageRise: Double?
        /// Same, split by whether the meal was logged promptly (within 15 min).
        var promptRise: Double?
        var lateRise: Double?
        var promptCount = 0
        var lateCount = 0
        /// Median time from eating until glucose is back under 180.
        /// Meals that never came back inside the window are excluded rather
        /// than counted as "instant", which would flatter the number.
        var medianTimeToReturn: TimeInterval?
        /// Median time from eating to the peak.
        ///
        /// Descriptive, and useful for understanding your own curve — but note it
        /// is NOT a pre-bolus recommendation, and must never be presented as one.
        var medianTimeToPeak: TimeInterval?
    }

    /// Time in range for each weekday, Sunday-first to match `Calendar`.
    /// Reveals a routine effect that a weekday/weekend split is too coarse to see.
    struct WeekdayPoint: Identifiable {
        /// 1 = Sunday, per `Calendar.component(.weekday:)`.
        let weekday: Int
        let inRange: Double
        let days: Int
        var id: Int { weekday }
    }

    /// Time in range week by week — the progress view.
    ///
    /// A single period number tells you where you are; this tells you which way
    /// you are going, which is the thing that actually sustains effort.
    struct WeekPoint: Identifiable {
        let weekStart: Date
        let inRange: Double
        let days: Int
        var id: Date { weekStart }
    }

    /// Bucket size for the period-by-period comparison. The user's choice.
    enum PeriodGranularity: String, CaseIterable, Identifiable {
        case week, month
        var id: String { rawValue }

        var component: Calendar.Component {
            switch self {
            case .week: return .weekOfYear
            case .month: return .month
            }
        }

        /// Days of usable data before a bucket is worth showing at all.
        ///
        /// A month judged on two days is not a month. These floors are the same
        /// idea as `weeklySummary`'s three-day rule — below them the number
        /// swings on a couple of days and reads as a trend that isn't there.
        var minimumDays: Int {
            switch self {
            case .week: return 3
            case .month: return 10
            }
        }
    }

    /// One week or one month of glucose, summarised for comparison against its
    /// neighbours.
    ///
    /// Metrics are computed from the raw readings of usable days, so they match
    /// the headline figures on the screen. NOTE this differs from the older
    /// `weeklyTrend`, which averages each day's in-range fraction — that one
    /// weights every day equally regardless of how many readings it has. Both are
    /// defensible; they are not identical, and a period here can differ from the
    /// same week in `weeklyTrend` by a point or two.
    struct PeriodPoint: Identifiable {
        let start: Date
        let granularity: PeriodGranularity
        /// Days that cleared the per-day reading floor.
        let days: Int
        let readings: Int
        let mean: Double
        let standardDeviation: Double
        /// Percent, matching `Glucose.coefficientOfVariation`.
        let coefficientOfVariation: Double
        let gmi: Double
        /// Fractions 0–1, matching `Glucose.inRange` and friends.
        let inRange: Double
        let below: Double     // < 70
        let veryLow: Double   // < 54
        let above: Double     // > 180
        var id: Date { start }
    }

    /// Overnight outcome grouped by the glucose you went to bed on.
    ///
    /// Purely descriptive — it reports what happened on your own nights. It does
    /// NOT prescribe a bedtime number, and must never be presented as doing so.
    struct BedtimeOutcome: Identifiable {
        let label: String
        /// Share of those nights that had a reading below 70.
        let lowRate: Double
        let nights: Int
        var id: String { label }
    }

    /// Post-meal rise grouped by how big the meal was.
    struct MealSizeOutcome: Identifiable {
        let label: String
        let averageRise: Double
        let count: Int
        var id: String { label }
    }

    /// Time in range split by day and night, rather than only the MEANS.
    ///
    /// Two periods can share an average and be completely different problems:
    /// overnight lows and daytime spikes need opposite responses.
    struct DayNightRange {
        var overnightInRange: Double?   // 00:00–06:00
        var daytimeInRange: Double?
        var overnightBelow: Double?
        var daytimeBelow: Double?
        var overnightAbove: Double?
        var daytimeAbove: Double?
        var overnightMean: Double?
        var daytimeMean: Double?
        /// Variability within each period. A calm night with a chaotic day is a
        /// different problem from the reverse, and the means alone hide it.
        var overnightCV: Double?
        var daytimeCV: Double?
        /// Typical daily extremes, each AVERAGED over the days in the period —
        /// not the single worst reading ever seen. One frightening night should
        /// not become the number that describes every night.
        var overnightMinimum: Double?
        var overnightMaximum: Double?
        var daytimeMinimum: Double?
        var daytimeMaximum: Double?
    }

    /// How much the loop is intervening, which is an indirect read on how well
    /// the underlying settings are tuned: a well-tuned profile needs less
    /// correcting, so a high rate is worth noticing even when outcomes are fine.
    struct LoopActivity {
        /// Automatic boluses a day (a count).
        var automaticDosesPerDay: Double = 0
        var manualBolusesPerDay: Double = 0
        /// Basal units actually delivered per day — see `Insulin.basalUnits`.
        var deliveredBasalPerDay: Double = 0
        /// Units a day Loop gave as automatic boluses.
        var automaticBolusUnitsPerDay: Double = 0
        /// The programmed schedule's daily total, when known.
        var scheduledBasalPerDay: Double?
        /// False when the delivered basal is temp basals only — see
        /// `Insulin.includesScheduledBasal`. The ratios below are then nil.
        var includesScheduledBasal = false
        /// Basal delivered ÷ programmed.
        ///
        /// On automatic-bolus dosing Loop can only CUT basal, so this is at most
        /// 1 by construction; what it adds, it adds as automatic boluses. Read it
        /// together with `loopRatio`.
        var basalRatio: Double? {
            guard includesScheduledBasal, let scheduled = scheduledBasalPerDay, scheduled > 0 else { return nil }
            return deliveredBasalPerDay / scheduled
        }
        /// (Basal delivered + automatic boluses) ÷ programmed basal: everything
        /// Loop decided, against what the profile alone would have given. Above 1
        /// means Loop is consistently giving more than the profile asks for.
        var loopRatio: Double? {
            guard includesScheduledBasal, let scheduled = scheduledBasalPerDay, scheduled > 0 else { return nil }
            return (deliveredBasalPerDay + automaticBolusUnitsPerDay) / scheduled
        }
    }

    /// Meal-sized rises with no bolus recorded near them.
    ///
    /// Flags the two things that most corrupt every other number here: a meal
    /// that was eaten but not logged, or logged but not bolused for.
    struct MissedBolus {
        var count = 0
        var perWeek: Double = 0
    }

    /// Breaks in the CGM data. Separate from `Coverage` because a single
    /// three-day outage and a sensor that drops one reading an hour produce the
    /// same coverage percentage but mean completely different things.
    struct SensorGaps {
        var count = 0
        var longest: TimeInterval?
        var totalMissing: TimeInterval = 0
    }

    /// Overnight safety, counted in NIGHTS rather than readings — "3 of 30 nights
    /// had a low" lands differently from "0.4% of readings were low", and nights
    /// are what people actually worry about.
    struct Nights {
        var total = 0
        var withLow = 0
    }

    var glucose = Glucose()
    var insulin = Insulin()
    var meals = Meals()
    var pods = Pods()
    var hourlyProfile: [HourlyPoint] = []
    var postMeal = PostMeal()
    var nights = Nights()
    var coverage = Coverage()
    var lowEvents = LowEvents()
    var highEvents = HighEvents()
    var days = Days()
    var dawn = Dawn()
    var risk = GlucoseRiskMetrics()
    var mealWindows: [MealWindow] = []
    var recovery = Recovery()
    var dayNight = DayNightRange()
    var loopActivity = LoopActivity()
    var missedBolus = MissedBolus()
    var weekdayProfile: [WeekdayPoint] = []
    var weeklyTrend: [WeekPoint] = []
    var bedtimeOutcomes: [BedtimeOutcome] = []
    var mealSizeOutcomes: [MealSizeOutcome] = []
    var sensorGaps = SensorGaps()

    /// Average number of carb entries a day.
    var mealsPerDay: Double = 0
    /// Average grams per entry.
    var gramsPerMeal: Double = 0

    /// Hour of day that sits highest, when there is enough data to mean it.
    ///
    /// Compared on the MEDIAN, because the median is what the profile chart
    /// draws: ranking by the mean could name an hour that is visibly not the
    /// highest line on the chart it captions, which is how a caption ends up
    /// contradicting its own graph. (`hourlyProfile` has already applied the
    /// per-hour evidence floors; the extra `count` check is belt and braces.)
    var worstHour: HourlyPoint? {
        hourlyProfile.filter { $0.count >= Self.minimumReadingsPerHour }.max { $0.median < $1.median }
    }

    /// Floors for the hourly (AGP) profile. An hour below EITHER is omitted.
    ///
    /// Five readings is roughly half an hour of CGM data; three days is the
    /// minimum at which "how it varies between days" means anything. Both are
    /// judgement calls, but the previous floor — one single reading — was not a
    /// judgement call, it was an oversight.
    ///
    /// These are DELIBERATELY absolute rather than a fraction of the selected
    /// period: three days of evidence is three days of evidence whether the
    /// picker says 7 days or 90. What changes with the period is how many hours
    /// clear the bar, and an hour that doesn't is left out — see
    /// `hourlyProfile`.
    static let minimumReadingsPerHour = 5
    static let minimumDaysPerHour = 3
    /// Days needed before the 10th–90th band is drawn at all. Under five, p10
    /// and p90 ARE the minimum and maximum day, which reads as a confident
    /// "usual range" while being nothing of the sort.
    static let minimumDaysForOuterBand = 5
    /// Days of a given weekday needed before that weekday is reported at all.
    static let minimumDaysPerWeekday = 2
    /// CGM readings a day needs before it counts as a day for per-day averages,
    /// when nothing else happened on it. 72 is six hours at five-minute spacing.
    static let minimumReadingsForCountedDay = 72
    /// Days needed on EACH side before weekday-vs-weekend is reported at all.
    /// Three of each is the least that can be called a pattern rather than a
    /// coincidence — and on a 7-day period it means the split stays silent.
    static let minimumDaysPerWeekPart = 3
    /// Which days are the weekend, as `Calendar` weekday numbers (1 = Sunday).
    /// 6 = Friday, 7 = Saturday.
    ///
    /// ⚠️ DELIBERATELY FIXED, NOT `Calendar.isDateInWeekend`. That answers from
    /// the device's Region setting, which is a setting about FORMATTING, not
    /// about the user's week — a phone set to United States calls Sunday a
    /// weekend day and Friday a working one, and the split then compares two
    /// groups that mean nothing to the person reading it. This fork's user
    /// keeps a Friday–Saturday weekend, so that is what the split uses,
    /// regardless of what region the phone is set to.
    static let weekendWeekdayNumbers: Set<Int> = [6, 7]
    /// Readings inside 00:00–06:00 before a night counts. 24 is two hours.
    static let minimumReadingsPerNight = 24
    /// CGM readings a day needs before it is judged AS A DAY: goal days, the
    /// streak, weekday averages and the weekly trend. 202 is 70% of the 288 a
    /// 5-minute sensor produces.
    ///
    /// ⚠️ HIGHER THAN `minimumReadingsForCountedDay` ON PURPOSE. Six hours of
    /// readings prove the app ran that day; they do not describe the day. With
    /// the lower floor, today became a "day that met the goal" from six in the
    /// morning on, judged on the night alone, which is usually the best part of
    /// it, and each of these figures gave that morning the weight of a full day.
    static let minimumReadingsForJudgedDay = 202
    /// Carb entries this close to a meal's first entry are part of that meal.
    static let mealMergeWindow: TimeInterval = 30 * 60
    /// Meals with a recorded eating time needed before a logging delay is shown.
    static let minimumMealsForLoggingDelay = 10
    /// The post-meal rise is the peak within this long after eating.
    static let postMealWindow: TimeInterval = 3 * 3600
    /// Two readings further apart than this are either side of a sensor gap:
    /// nothing is known about the time between them.
    static let sensorGapThreshold: TimeInterval = 30 * 60

    /// Span actually covered by the data.
    var firstDate: Date?
    var lastDate: Date?

    /// Calendar days that contain at least one record.
    ///
    /// ⚠️ THIS, NOT THE ELAPSED SPAN, IS THE DENOMINATOR FOR "PER DAY".
    /// `dayCount` used to be `last - first`, which counts every day the app did
    /// not run — a phone left off, a week without the app open, a log that only
    /// starts halfway through the selected period — as a day on which you took
    /// no insulin and ate nothing. Averaging over those days quietly drags every
    /// daily figure down, and it is why the per-day numbers did not match what
    /// the user knew they had actually taken.
    var daysWithData: Int = 0

    /// `daysWithData` as a length of time: the first and last of those days count
    /// for the part of them the records cover.
    ///
    /// ⚠️ TODAY IS NOT A WHOLE DAY UNTIL IT IS OVER. The period ends now, so its
    /// last day is as long as the time since midnight. Counting it as a full day
    /// divided two days of insulin by three at a quarter past midnight (the
    /// 3-day "insulin per day" read a third low and climbed back through the
    /// day), and every other "per day" and "per week" figure with it. The same
    /// goes for the day the log began.
    var dayEquivalents: Double = 0

    /// Days used for per-day averages: the time the days with records cover.
    var dayCount: Double {
        // At least one, so a few hours of data are not scaled up to a "day".
        max(1, dayEquivalents)
    }

    /// Elapsed span of the window, in days. Used where the question really is
    /// "out of the whole period" — sensor coverage, for instance, where a day
    /// with no data is a day of MISSING data, not a day to exclude.
    var spanDays: Double {
        guard let firstDate, let lastDate else { return 0 }
        return max(1, lastDate.timeIntervalSince(firstDate) / 86400)
    }

    // MARK: - Building

    static func compute(from rawLines: [HistoryLine],
                        scheduledBasalPerDay: Double? = nil,
                        basalSchedule: [BasalDelivery.ScheduleEntry] = [],
                        calendar: Calendar = .current) -> HistoryStatistics {
        // ⚠️ FIRST, ALWAYS. The log is append-only and repeats events the pump
        // re-reports; counting the repeats inflated every insulin total (a third
        // of dose records in one real container). See `HistoryLineDeduplicator`.
        let lines = HistoryLineDeduplicator.deduplicated(rawLines)
        var stats = HistoryStatistics()

        /// Per-day evidence, used to decide which calendar days count as a day.
        /// See `daysWithData` on the result for why the denominator matters.
        var glucosePerDay: [Date: Int] = [:]
        var eventDays = Set<Date>()

        var glucoseValues: [Double] = []
        var overnight: [Double] = []
        var daytime: [Double] = []
        var loggingDelays: [TimeInterval] = []
        // (date, mg/dL) kept sorted later, for the post-meal pass.
        var glucoseSeries: [(date: Date, value: Double)] = []
        // eating time + how late it was logged, for the post-meal pass.
        var mealEntries: [(eaten: Date, grams: Double, delay: TimeInterval?)] = []
        var mealSpans: [(eaten: Date, absorbedBy: Date)] = []
        var manualBolusTimes: [Date] = []
        var hourSums = [Double](repeating: 0, count: 24)
        var hourCounts = [Int](repeating: 0, count: 24)
        var hourValues = [[Double]](repeating: [], count: 24)
        /// Readings per (hour, day), so each DAY can contribute exactly one
        /// value to that hour's distribution — see `HourlyPoint`.
        var hourDayValues = [[Date: [Double]]](repeating: [:], count: 24)
        /// Readings per night (00:00–06:00). A night needs enough of them to be
        /// called a night at all — see `minimumReadingsPerNight`.
        var nightReadings: [Date: Int] = [:]
        var nightsWithLow = Set<Date>()
        var overnightInRange = 0, overnightTotal = 0, overnightBelow = 0
        var daytimeInRange = 0, daytimeTotal = 0, daytimeBelow = 0
        var overnightAbove = 0, daytimeAbove = 0
        var overnightValues: [Double] = [], daytimeValues: [Double] = []
        // Per-day extremes, so the reported figure is an average of daily lows
        // and highs rather than the single most extreme reading in the window.
        var nightExtremes: [Date: (low: Double, high: Double)] = [:]
        var dayExtremes: [Date: (low: Double, high: Double)] = [:]
        var automaticDoses = 0, manualBoluses = 0
        var stopReasonCounts: [String: Int] = [:]
        var faultCount = 0
        var podHours: [Double] = []
        var earliest: Date?
        var latest: Date?
        var activeFrom: Date?
        var activeTo: Date?

        for line in lines {
            guard let date = line.date else { continue }
            if earliest == nil || date < earliest! { earliest = date }
            if latest == nil || date > latest! { latest = date }

            let day = calendar.startOfDay(for: date)
            switch line.t {
            case "glucose": glucosePerDay[day, default: 0] += 1
            case "dose", "meal": eventDays.insert(day)
            default: break
            }
            // The stretch the app was actually recording: readings, doses and
            // meals. A pod record is written when a pod STOPS and describes a
            // session that may have begun days before the log did, so it does
            // not mark when recording started.
            if line.t == "glucose" || line.t == "dose" || line.t == "meal" {
                if activeFrom == nil || date < activeFrom! { activeFrom = date }
                if activeTo == nil || date > activeTo! { activeTo = date }
            }

            switch line.t {
            case "glucose":
                guard let mgdl = line.mgdl else { continue }
                glucoseValues.append(mgdl)
                glucoseSeries.append((date, mgdl))
                let hour = calendar.component(.hour, from: date)
                hourSums[hour] += mgdl
                hourCounts[hour] += 1
                hourValues[hour].append(mgdl)
                hourDayValues[hour][calendar.startOfDay(for: date), default: []].append(mgdl)
                if mgdl >= 70 && mgdl <= 180 {
                    if hour < 6 { overnightInRange += 1 } else { daytimeInRange += 1 }
                }
                if mgdl < 70 {
                    if hour < 6 { overnightBelow += 1 } else { daytimeBelow += 1 }
                }
                if mgdl > 180 {
                    if hour < 6 { overnightAbove += 1 } else { daytimeAbove += 1 }
                }
                let day = calendar.startOfDay(for: date)
                if hour < 6 {
                    overnightTotal += 1
                    overnightValues.append(mgdl)
                    var entry = nightExtremes[day] ?? (mgdl, mgdl)
                    entry.low = min(entry.low, mgdl)
                    entry.high = max(entry.high, mgdl)
                    nightExtremes[day] = entry
                } else {
                    daytimeTotal += 1
                    daytimeValues.append(mgdl)
                    var entry = dayExtremes[day] ?? (mgdl, mgdl)
                    entry.low = min(entry.low, mgdl)
                    entry.high = max(entry.high, mgdl)
                    dayExtremes[day] = entry
                }

                if hour < 6 {
                    overnight.append(mgdl)
                    // Readings before 06:00 belong to the night that started the
                    // previous evening, so key them on the calendar day itself —
                    // all we need is a stable per-night bucket.
                    let night = calendar.startOfDay(for: date)
                    nightReadings[night, default: 0] += 1
                } else {
                    daytime.append(mgdl)
                }

            case "dose":
                // Only units actually delivered count. A temp basal reports a
                // RATE as well; adding both would double-count the same insulin.
                if let units = line.units {
                    if line.kind == "bolus" {
                        stats.insulin.bolusUnits += units
                        if line.automatic == true {
                            automaticDoses += 1
                            stats.insulin.automaticBolusUnits += units
                        } else {
                            manualBoluses += 1
                            stats.insulin.manualBolusUnits += units
                            manualBolusTimes.append(date)
                        }
                    } else {
                        // Temp basals (suspends and resumes carry 0). The
                        // scheduled basal is added after the loop.
                        stats.insulin.tempBasalUnits += units
                    }
                }

            case "meal":
                stats.meals.entryCount += 1
                stats.meals.totalGrams += line.grams ?? 0
                // ⚠️ `eatenAt` IS ONLY WRITTEN BY THE MEAL SCREEN. An ordinary carb
                // entry has no such field, and its own time (`at`, the time set
                // in the carb entry) IS when it was eaten. Requiring `eatenAt`
                // left every post-meal figure standing on the handful of meals
                // that came through the meal screen: 8 of 209 in one real log.
                let recordedEatingTime = line.eatenAt.flatMap { HistoryTimestamp.formatter.date(from: $0) }
                let eaten = recordedEatingTime ?? date
                let entered = line.enteredAt.flatMap { HistoryTimestamp.formatter.date(from: $0) }
                var delay: TimeInterval?
                // A logging delay only exists where the eating time was recorded
                // SEPARATELY from the entry. For an ordinary entry `at` is simply
                // when it was saved, give or take seconds, and calling that
                // "logged promptly" would be reading a habit into a default.
                if let recordedEatingTime, let entered {
                    let gap = entered.timeIntervalSince(recordedEatingTime)
                    // Negative means logged in advance, which is a different
                    // habit entirely — don't average the two together.
                    if gap >= 0 {
                        delay = gap
                        loggingDelays.append(gap)
                    }
                }
                mealEntries.append((eaten, line.grams ?? 0, delay))
                // A meal explains a rise for as long as it is absorbing, and for
                // two hours at the least.
                mealSpans.append((eaten, eaten.addingTimeInterval(max(2 * 3600, line.absorption ?? 0))))

            case "pod":
                stats.pods.count += 1
                if let hours = line.hoursRun { podHours.append(hours) }
                if let remaining = line.remainingAtStop {
                    if remaining > BasalDelivery.podReservoirReadingLimit {
                        stats.pods.overfullCount += 1
                    } else {
                        stats.pods.wastedUnits += remaining
                        stats.pods.measuredCount += 1
                    }
                }
                let reason = line.stopReason ?? "unknown"
                stopReasonCounts[reason, default: 0] += 1
                if reason == "fault" { faultCount += 1 }

            default:
                continue
            }
        }

        // ⚠️ THE SPAN IS THE RECORDING, NOT THE OLDEST DATE MENTIONED. The first
        // pod record of a log is dated when that pod stopped, a day or more
        // before the first reading, and using it stretched the span: "sensor
        // data" was measured against a day the log did not cover, and the day the
        // log began at 22:47 counted as a whole day of insulin.
        stats.firstDate = activeFrom ?? earliest
        stats.lastDate = activeTo ?? latest

        stats.glucose = glucoseSummary(glucoseValues, overnight: overnight, daytime: daytime)

        // ⚠️ AN HOUR MUST EARN ITS BAND. The old floor was `> 0`: a single reading
        // produced a full HourlyPoint whose p10/p25/median/p75/p90 were all that
        // one number, drawn as a "typical value" with a zero-width spread. Two or
        // three readings gave percentiles that are noise wearing the costume of a
        // distribution. That is invented information, and the tile's own caption
        // makes it worse — it says the band shows "how much it varies BETWEEN
        // DAYS", so an hour whose readings all come from one day has no
        // between-day variation to show at all, however many readings it has.
        //
        // Floor is therefore BOTH: enough readings, and enough distinct DAYS —
        // and since each day now contributes exactly one value, "enough days" is
        // literally the sample size behind the band. An hour that fails is
        // omitted entirely rather than drawn thin — a gap in the profile is
        // honest, a fabricated band is not.
        stats.hourlyProfile = (0..<24).compactMap { hour in
            guard hourCounts[hour] >= Self.minimumReadingsPerHour else { return nil }
            // ONE VALUE PER DAY: that day's median for this hour. See the note
            // on `HourlyPoint` for why this is not pooled across readings.
            let dayMedians = hourDayValues[hour].values
                .map { percentile($0.sorted(), 0.50) }
                .sorted()
            guard dayMedians.count >= Self.minimumDaysPerHour else { return nil }
            return HourlyPoint(hour: hour,
                               mean: hourSums[hour] / Double(hourCounts[hour]),
                               count: hourCounts[hour],
                               days: dayMedians.count,
                               p10: percentile(dayMedians, 0.10),
                               p25: percentile(dayMedians, 0.25),
                               median: percentile(dayMedians, 0.50),
                               p75: percentile(dayMedians, 0.75),
                               p90: percentile(dayMedians, 0.90))
        }
        // ⚠️ A NIGHT WITH A COUPLE OF READINGS IS NOT A NIGHT. Counting it made
        // "nights with a low" read as "14 of 15" when there were only fourteen
        // nights of data — the fifteenth was a stray reading — and it dilutes
        // every overnight percentage the same way a partial day dilutes a daily
        // average.
        let countedNights = Set(nightReadings.filter { $0.value >= Self.minimumReadingsPerNight }.keys)

        let sortedGlucose = glucoseSeries.sorted { $0.date < $1.date }
        // ⚠️ ONE DEFINITION OF "A LOW" FOR THE WHOLE SCREEN: the consensus event
        // (15 minutes or more under 70). Nights with a low, lows followed by a
        // high and the bedtime outcomes each used to count any single reading
        // under 70, next to a Low Events tile that did not, so the same screen
        // reported 74 lows in one place and 32 in another.
        let lowIntervals = excursions(sortedGlucose, threshold: 70, below: true)
        for low in lowIntervals {
            // A low belongs to a night when any of it falls inside 00:00–06:00.
            for moment in [low.start, low.end] {
                let night = calendar.startOfDay(for: moment)
                guard let nightEnd = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: night) else { continue }
                if low.start < nightEnd && low.end >= night { nightsWithLow.insert(night) }
            }
        }
        stats.nights = Nights(total: countedNights.count,
                              withLow: nightsWithLow.intersection(countedNights).count)
        // ⚠️ ENTRIES ARE NOT MEALS. One meal is often logged as two or three
        // entries a few minutes apart (the main dish, then the dessert); each
        // used to be measured as a meal of its own, so one glucose rise was
        // counted two or three times, once per entry. Entries within half an
        // hour of a meal's first entry are that meal: grams add up, the time is
        // the first one. Entry COUNTS ("meals per day") still count entries.
        var mealEvents: [(eaten: Date, delay: TimeInterval?)] = []
        var mealSizes: [(eaten: Date, grams: Double)] = []
        for entry in mealEntries.sorted(by: { $0.eaten < $1.eaten }) {
            if let last = mealEvents.indices.last,
               entry.eaten.timeIntervalSince(mealEvents[last].eaten) <= mealMergeWindow {
                mealSizes[last].grams += entry.grams
                if mealEvents[last].delay == nil { mealEvents[last].delay = entry.delay }
            } else {
                mealEvents.append((entry.eaten, entry.delay))
                mealSizes.append((entry.eaten, entry.grams))
            }
        }
        mealSizes.removeAll { $0.grams <= 0 }
        let mealEntryTimes = mealEntries.map(\.eaten)
        stats.postMeal = postMealSummary(meals: mealEvents, glucose: sortedGlucose)

        // ⚠️ A DAY HAS TO EARN ITS PLACE IN THE DENOMINATOR. Counting any day
        // with a single stray record — the app opened for a moment, one reading
        // arriving — as a whole day divides the totals by more days than were
        // really lived, and every "per day" figure comes out low. A day counts
        // when it has a meaningful stretch of CGM data OR at least one thing
        // actually happened on it (a dose or a meal).
        let countedDays = Set(glucosePerDay.filter { $0.value >= Self.minimumReadingsForCountedDay }.keys)
            .union(eventDays)
        stats.daysWithData = countedDays.count
        stats.dayEquivalents = dayEquivalents(of: countedDays, from: activeFrom, to: activeTo, calendar: calendar)
        let days = stats.dayCount

        // Basal: temp basals as recorded, plus the schedule for the rest of the
        // time — over the days that count, so it has the same days as the
        // denominator it is divided by.
        stats.insulin.basalUnits = stats.insulin.tempBasalUnits
        var programmedPerDay = basalSchedule.isEmpty ? scheduledBasalPerDay : BasalDelivery.dailyTotal(of: basalSchedule)
        if !basalSchedule.isEmpty, let earliest = activeFrom, let latest = activeTo {
            let delivery = BasalDelivery(lines: lines, schedule: basalSchedule, calendar: calendar)
            programmedPerDay = delivery.programmedPerDay(from: earliest, to: latest)
            var scheduled = 0.0
            for day in countedDays {
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                scheduled += delivery.scheduledUnitsDelivered(from: max(day, earliest), to: min(dayEnd, latest))
            }
            stats.insulin.basalUnits += scheduled
            stats.insulin.includesScheduledBasal = true
        }
        stats.insulin.totalUnits = stats.insulin.bolusUnits + stats.insulin.basalUnits
        // Events per week are per week of SENSOR time: a day the sensor was off
        // is not a day without a low.
        let sensorDays = max(1, Double(sortedGlucose.count) / 288)
        stats.lowEvents = lowEventSummary(sortedGlucose, lows: lowIntervals, days: sensorDays)
        stats.highEvents = highEventSummary(sortedGlucose, days: sensorDays)
        stats.days = daySummary(sortedGlucose, calendar: calendar)
        stats.dawn = dawnSummary(sortedGlucose,
                                 meals: mealEntryTimes,
                                 manualBoluses: manualBolusTimes,
                                 calendar: calendar)
        // A 5-minute sensor yields ~288 readings a day. Measured against the
        // SPAN, deliberately: a day with no readings at all is exactly what this
        // number is supposed to notice.
        stats.coverage = Coverage(expected: Int(stats.spanDays * 288), received: glucoseValues.count)
        let griParts = GlucoseRiskMetrics.glycemiaRiskIndex(veryLow: stats.glucose.veryLow,
                                                            low: stats.glucose.low,
                                                            high: stats.glucose.high,
                                                            veryHigh: stats.glucose.veryHigh)
        stats.risk = GlucoseRiskMetrics.compute(from: sortedGlucose,
                                                mean: stats.glucose.mean,
                                                standardDeviation: stats.glucose.standardDeviation,
                                                calendar: calendar)
        if stats.glucose.count > 0 {
            stats.risk.gri = griParts.gri
            stats.risk.griHypoComponent = griParts.hypo
            stats.risk.griHyperComponent = griParts.hyper
        }
        stats.mealWindows = mealWindowSummary(meals: mealEvents, glucose: sortedGlucose, calendar: calendar)
        stats.recovery = recoverySummary(sortedGlucose, lows: lowIntervals)
        stats.weekdayProfile = weekdaySummary(sortedGlucose, calendar: calendar)
        stats.weeklyTrend = weeklySummary(sortedGlucose, calendar: calendar)
        stats.bedtimeOutcomes = bedtimeSummary(sortedGlucose, lows: lowIntervals, calendar: calendar)
        stats.mealSizeOutcomes = mealSizeSummary(meals: mealSizes, glucose: sortedGlucose)
        stats.sensorGaps = sensorGapSummary(sortedGlucose)
        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        func spread(_ values: [Double]) -> Double? {
            guard values.count > 1 else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            guard mean > 0 else { return nil }
            let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
            return sqrt(variance) / mean * 100
        }

        stats.dayNight = DayNightRange(
            overnightInRange: overnightTotal > 0 ? Double(overnightInRange) / Double(overnightTotal) : nil,
            daytimeInRange: daytimeTotal > 0 ? Double(daytimeInRange) / Double(daytimeTotal) : nil,
            overnightBelow: overnightTotal > 0 ? Double(overnightBelow) / Double(overnightTotal) : nil,
            daytimeBelow: daytimeTotal > 0 ? Double(daytimeBelow) / Double(daytimeTotal) : nil,
            overnightAbove: overnightTotal > 0 ? Double(overnightAbove) / Double(overnightTotal) : nil,
            daytimeAbove: daytimeTotal > 0 ? Double(daytimeAbove) / Double(daytimeTotal) : nil,
            overnightMean: overnightValues.isEmpty ? nil : overnightValues.reduce(0, +) / Double(overnightValues.count),
            daytimeMean: daytimeValues.isEmpty ? nil : daytimeValues.reduce(0, +) / Double(daytimeValues.count),
            overnightCV: spread(overnightValues),
            daytimeCV: spread(daytimeValues),
            overnightMinimum: average(nightExtremes.values.map(\.low)),
            overnightMaximum: average(nightExtremes.values.map(\.high)),
            daytimeMinimum: average(dayExtremes.values.map(\.low)),
            daytimeMaximum: average(dayExtremes.values.map(\.high)))

        stats.loopActivity = LoopActivity(
            automaticDosesPerDay: days > 0 ? Double(automaticDoses) / days : 0,
            manualBolusesPerDay: days > 0 ? Double(manualBoluses) / days : 0,
            deliveredBasalPerDay: days > 0 ? stats.insulin.basalUnits / days : 0,
            automaticBolusUnitsPerDay: days > 0 ? stats.insulin.automaticBolusUnits / days : 0,
            scheduledBasalPerDay: programmedPerDay,
            includesScheduledBasal: stats.insulin.includesScheduledBasal)

        // ⚠️ THE USER'S OWN BOLUSES ONLY. Loop gives an automatic bolus every few
        // minutes, so with those in the list there was "a bolus nearby" for
        // almost every rise and the count sat near zero whatever happened: 3 in
        // 58 days, where 21 rises had neither carbs nor a bolus of the user's.
        stats.missedBolus = missedBolusSummary(sortedGlucose, meals: mealSpans,
                                               boluses: manualBolusTimes, days: sensorDays)
        stats.mealsPerDay = days > 0 ? Double(stats.meals.entryCount) / days : 0
        stats.gramsPerMeal = stats.meals.entryCount > 0
            ? stats.meals.totalGrams / Double(stats.meals.entryCount)
            : 0

        stats.insulin.dailyAverage = days > 0 ? stats.insulin.totalUnits / days : 0
        stats.meals.dailyAverageGrams = days > 0 ? stats.meals.totalGrams / days : 0
        // A median of a handful of entries is not "typical" anything.
        stats.meals.medianLoggingDelay = loggingDelays.count >= minimumMealsForLoggingDelay ? median(loggingDelays) : nil

        if stats.pods.count > 0 {
            stats.pods.meanHours = podHours.isEmpty ? 0 : podHours.reduce(0, +) / Double(podHours.count)
            stats.pods.faultRate = Double(faultCount) / Double(stats.pods.count)
            stats.pods.stopReasons = stopReasonCounts
                .map { (reason: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }
        }

        return stats
    }

    /// The counted days as a length of time: whole days, except that the first
    /// and the last count only from the first record and up to the last one.
    private static func dayEquivalents(of countedDays: Set<Date>,
                                       from earliest: Date?,
                                       to latest: Date?,
                                       calendar: Calendar) -> Double {
        var total = Double(countedDays.count)
        guard let earliest, let latest, latest > earliest else { return total }
        let firstDay = calendar.startOfDay(for: earliest)
        let lastDay = calendar.startOfDay(for: latest)
        func length(of day: Date) -> TimeInterval {
            (calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)).timeIntervalSince(day)
        }
        if firstDay == lastDay {
            return countedDays.contains(firstDay) ? latest.timeIntervalSince(earliest) / length(of: firstDay) : total
        }
        if countedDays.contains(firstDay) {
            total -= min(1, max(0, earliest.timeIntervalSince(firstDay) / length(of: firstDay)))
        }
        if countedDays.contains(lastDay) {
            total -= 1 - min(1, max(0, latest.timeIntervalSince(lastDay) / length(of: lastDay)))
        }
        return total
    }

    private static func glucoseSummary(_ values: [Double],
                                       overnight: [Double],
                                       daytime: [Double]) -> Glucose {
        var glucose = Glucose()
        guard !values.isEmpty else { return glucose }

        let count = Double(values.count)
        glucose.count = values.count
        glucose.mean = values.reduce(0, +) / count

        let variance = values.reduce(0) { $0 + pow($1 - glucose.mean, 2) } / count
        glucose.standardDeviation = sqrt(variance)
        glucose.coefficientOfVariation = glucose.mean > 0
            ? glucose.standardDeviation / glucose.mean * 100
            : 0

        // Standard GMI formula (Bergenstal et al.), mg/dL form.
        glucose.gmi = 3.31 + 0.02392 * glucose.mean

        glucose.inTightRange = Double(values.filter { $0 >= 80 && $0 <= 140 }.count) / count
        glucose.veryLow  = Double(values.filter { $0 < 54 }.count) / count
        glucose.low      = Double(values.filter { $0 >= 54 && $0 < 70 }.count) / count
        glucose.inRange  = Double(values.filter { $0 >= 70 && $0 <= 180 }.count) / count
        glucose.high     = Double(values.filter { $0 > 180 && $0 <= 250 }.count) / count
        glucose.veryHigh = Double(values.filter { $0 > 250 }.count) / count

        if !overnight.isEmpty { glucose.overnightMean = overnight.reduce(0, +) / Double(overnight.count) }
        if !daytime.isEmpty { glucose.daytimeMean = daytime.reduce(0, +) / Double(daytime.count) }

        return glucose
    }

    /// Peak glucose rise in the 3 hours after each logged meal.
    ///
    /// Baseline is the reading closest to the eating time (within ±20 min); the
    /// peak is the highest reading in the 3 hours after. A meal without both is
    /// skipped rather than guessed at — a fabricated baseline would quietly bias
    /// every number built on it.
    ///
    /// This is descriptive only. It says what happened after meals; it does not
    /// and must not imply what to dose.
    private static func postMealSummary(meals: [(eaten: Date, delay: TimeInterval?)],
                                        glucose: [(date: Date, value: Double)]) -> PostMeal {
        var summary = PostMeal()
        guard !meals.isEmpty, glucose.count > 1 else { return summary }

        let sorted = glucose.sorted { $0.date < $1.date }
        let dates = sorted.map(\.date)
        var rises: [Double] = []
        var promptRises: [Double] = []
        var lateRises: [Double] = []
        var timesToPeak: [TimeInterval] = []
        var timesToReturn: [TimeInterval] = []

        for meal in meals {
            // First reading at or after the meal; the baseline candidate is that
            // one or the one just before it, whichever is nearer.
            var index = lowerBound(dates, meal.eaten)

            var baseline: Double?
            var bestGap = TimeInterval.greatestFiniteMagnitude
            for candidate in [index - 1, index] where candidate >= 0 && candidate < sorted.count {
                let gap = abs(sorted[candidate].date.timeIntervalSince(meal.eaten))
                if gap <= 20 * 60 && gap < bestGap {
                    bestGap = gap
                    baseline = sorted[candidate].value
                }
            }
            // Carbs eaten while low are a treatment, and the rise after them is
            // the treatment working — not a post-meal spike.
            guard let baseline, baseline >= 70 else { continue }

            // ⚠️ THE PEAK IS LOOKED FOR IN THE 3 HOURS THE SCREEN SAYS, and the
            // return under 180 for up to 5. The peak used to be searched for the
            // whole 5 hours under a caption that said 3, so "typically peaks
            // after" could read 4 h, and usually belonged to the NEXT meal.
            let peakEnd = meal.eaten.addingTimeInterval(postMealWindow)
            let windowEnd = meal.eaten.addingTimeInterval(5 * 3600)
            var peak: Double?
            var peakDate: Date?
            var returnedAt: Date?
            var sawPeak = false
            while index < sorted.count && sorted[index].date <= windowEnd {
                if sorted[index].date <= peakEnd, peak == nil || sorted[index].value > peak! {
                    peak = sorted[index].value
                    peakDate = sorted[index].date
                }
                if sorted[index].value > 180 { sawPeak = true }
                if sawPeak, returnedAt == nil, sorted[index].value <= 180 {
                    returnedAt = sorted[index].date
                }
                index += 1
            }
            if let returnedAt {
                timesToReturn.append(returnedAt.timeIntervalSince(meal.eaten))
            }
            guard let peak else { continue }
            if let peakDate, peak > baseline {
                timesToPeak.append(peakDate.timeIntervalSince(meal.eaten))
            }

            // Clamp at zero: a meal followed by a fall is a 0 rise, not a
            // negative one that would cancel out someone else's spike.
            let rise = max(0, peak - baseline)
            rises.append(rise)
            summary.mealsAnalysed += 1

            if let delay = meal.delay {
                if delay <= 15 * 60 {
                    promptRises.append(rise)
                } else {
                    lateRises.append(rise)
                }
            }
        }

        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        summary.averageRise = mean(rises)
        // Only report the split when BOTH sides have enough meals to say
        // anything; three prompt meals against forty late ones is noise.
        if promptRises.count >= 5 && lateRises.count >= 5 {
            summary.promptRise = mean(promptRises)
            summary.lateRise = mean(lateRises)
        }
        summary.promptCount = promptRises.count
        summary.lateCount = lateRises.count
        summary.medianTimeToPeak = median(timesToPeak)
        summary.medianTimeToReturn = median(timesToReturn)
        return summary
    }

    /// Hypoglycemic events per the consensus definition — see `LowEvents`.
    private static func lowEventSummary(_ glucose: [(date: Date, value: Double)],
                                        lows: [Excursion],
                                        days: Double) -> LowEvents {
        var events = LowEvents()
        events.count = lows.count
        events.level2Count = excursions(glucose, threshold: 54, below: true).count
        if !lows.isEmpty {
            events.averageDuration = lows.reduce(0) { $0 + $1.duration } / Double(lows.count)
        }
        events.perWeek = days > 0 ? Double(lows.count) / days * 7 : 0
        return events
    }

    private static func highEventSummary(_ glucose: [(date: Date, value: Double)],
                                         days: Double) -> HighEvents {
        var events = HighEvents()
        let highs = excursions(glucose, threshold: 250, below: false)
        events.count = highs.count
        if !highs.isEmpty {
            events.averageDuration = highs.reduce(0) { $0 + $1.duration } / Double(highs.count)
        }
        events.perWeek = days > 0 ? Double(highs.count) / days * 7 : 0
        return events
    }

    /// One excursion past a threshold: its first and its last reading beyond it.
    struct Excursion {
        let start: Date
        let end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Every excursion past `threshold`, using the consensus rule: at least 15
    /// CONSECUTIVE minutes beyond it to start an event, and at least 15
    /// consecutive minutes back to end one.
    ///
    /// ⚠️ THREE THINGS THIS USED TO GET WRONG, each found on real data:
    ///  • "Consecutive" was not enforced. A run that had not yet lasted 15
    ///    minutes kept its start time through a short recovery, so two separate
    ///    low readings 25 minutes apart (67, 78, 82, 84, 69, 64) became a
    ///    25-minute event. A run now ends the moment glucose is back, unless it
    ///    had already become an event.
    ///  • Readings are five minutes apart give or take a few seconds, so four in
    ///    a row can span 899 seconds and fail a 900-second test. A minute of
    ///    tolerance is allowed.
    ///  • A sensor gap was bridged: sparse readings either side of a 55-minute
    ///    hole were one four-hour low. A gap now ends whatever was open.
    static func excursions(_ glucose: [(date: Date, value: Double)],
                           threshold: Double,
                           below: Bool) -> [Excursion] {
        guard glucose.count >= 2 else { return [] }
        let minimum: TimeInterval = 15 * 60 - 60

        var events: [Excursion] = []
        var runStart: Date?       // start of the current beyond-threshold run
        var runEnd: Date?         // last sample still beyond it
        var recoveredAt: Date?    // first sample back inside
        var inEvent = false
        var previous: Date?

        func beyond(_ value: Double) -> Bool { below ? value < threshold : value > threshold }
        func close() {
            if inEvent, let start = runStart, let end = runEnd { events.append(Excursion(start: start, end: end)) }
            inEvent = false
            runStart = nil
            runEnd = nil
            recoveredAt = nil
        }

        for sample in glucose {
            if let previous, sample.date.timeIntervalSince(previous) > sensorGapThreshold { close() }
            previous = sample.date

            if beyond(sample.value) {
                recoveredAt = nil
                if runStart == nil { runStart = sample.date }
                runEnd = sample.date
                // Promote the run to a real event once it has lasted long enough.
                if !inEvent, let start = runStart, sample.date.timeIntervalSince(start) >= minimum {
                    inEvent = true
                }
            } else if inEvent {
                // Only close the event after a sustained return, so one stray
                // in-range reading mid-low doesn't split it into two events.
                if recoveredAt == nil { recoveredAt = sample.date }
                if let recovered = recoveredAt, sample.date.timeIntervalSince(recovered) >= minimum { close() }
            } else {
                // The run never qualified, and it is over.
                runStart = nil
                runEnd = nil
            }
        }
        // An event still open at the end of the window still counts.
        close()
        return events
    }

    /// Per-day time in range, and what follows from it: days meeting the 70%
    /// goal, the best run of them, and weekday vs weekend.
    private static func daySummary(_ glucose: [(date: Date, value: Double)],
                                   calendar: Calendar) -> Days {
        var summary = Days()
        guard !glucose.isEmpty else { return summary }

        var inRangeByDay: [Date: (inRange: Int, total: Int)] = [:]
        for sample in glucose {
            let day = calendar.startOfDay(for: sample.date)
            var entry = inRangeByDay[day] ?? (0, 0)
            entry.total += 1
            if sample.value >= 70 && sample.value <= 180 { entry.inRange += 1 }
            inRangeByDay[day] = entry
        }

        // A day is judged on most of itself — see `minimumReadingsForJudgedDay`.
        let usable = inRangeByDay.filter { $0.value.total >= minimumReadingsForJudgedDay }
        summary.counted = usable.count
        guard !usable.isEmpty else { return summary }

        var weekday: [Double] = []
        var weekend: [Double] = []
        var goalDays = Set<Date>()

        for (day, counts) in usable {
            let fraction = Double(counts.inRange) / Double(counts.total)
            if fraction >= 0.7 { goalDays.insert(day) }
            if Self.weekendWeekdayNumbers.contains(calendar.component(.weekday, from: day)) {
                weekend.append(fraction)
            } else {
                weekday.append(fraction)
            }
        }
        summary.meetingGoal = goalDays.count
        summary.weekdayCount = weekday.count
        summary.weekendCount = weekend.count
        // ⚠️ A FLOOR ON EACH SIDE, NOT JUST "not empty". With `!isEmpty` a single
        // weekend day became "your weekends", and any gap of 8 points then
        // printed "weekends tend to go worse" as a finding. Which days count as
        // the weekend is `weekendWeekdayNumbers` — Friday and Saturday, fixed,
        // and NOT taken from the device region.
        //
        // ⚠️ `minimumDaysPerWeekPart` is 3, and a Fri–Sat weekend supplies only
        // 2 weekend days per calendar week. So the split needs at least a
        // fortnight of data: silent on 7 days, and on 14 days only if both
        // weekends were worn.
        if weekday.count >= minimumDaysPerWeekPart {
            summary.weekdayInRange = weekday.reduce(0, +) / Double(weekday.count)
        }
        if weekend.count >= minimumDaysPerWeekPart {
            summary.weekendInRange = weekend.reduce(0, +) / Double(weekend.count)
        }

        // Longest run of goal days IN A ROW. A day with no usable data between
        // two goal days breaks the run: Monday and Wednesday are not two days
        // in a row because Tuesday's sensor was off.
        var streak = 0
        var best = 0
        var previousDay: Date?
        for day in usable.keys.sorted() {
            let isNextDay = previousDay.map { calendar.dateComponents([.day], from: $0, to: day).day == 1 } ?? false
            if goalDays.contains(day) {
                streak = isNextDay ? streak + 1 : 1
                best = max(best, streak)
            } else {
                streak = 0
            }
            previousDay = day
        }
        summary.bestStreak = best
        return summary
    }

    /// Dawn phenomenon: the change from 03:00 to 08:00, averaged over the days
    /// that can show it.
    ///
    /// ⚠️ EACH END IS THE MEDIAN OF THE HOUR AROUND IT (02:30–03:30, 07:30–08:30),
    /// not the single nearest reading, which put one sensor wobble at each end
    /// straight into the figure. And a morning with food or a bolus of the user's
    /// own between 02:00 and 08:00 is left out: what that morning shows is the
    /// breakfast or the correction, not the dawn.
    private static func dawnSummary(_ glucose: [(date: Date, value: Double)],
                                    meals: [Date],
                                    manualBoluses: [Date],
                                    calendar: Calendar) -> Dawn {
        var dawn = Dawn()
        guard !glucose.isEmpty else { return dawn }

        var early: [Date: [Double]] = [:]
        var late: [Date: [Double]] = [:]
        for sample in glucose {
            let parts = calendar.dateComponents([.hour, .minute], from: sample.date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let day = calendar.startOfDay(for: sample.date)
            if minutes >= 150 && minutes < 210 { early[day, default: []].append(sample.value) }
            if minutes >= 450 && minutes < 510 { late[day, default: []].append(sample.value) }
        }

        var disturbed = Set<Date>()
        for moment in meals + manualBoluses {
            let hour = calendar.component(.hour, from: moment)
            if hour >= 2 && hour < 8 { disturbed.insert(calendar.startOfDay(for: moment)) }
        }

        var rises: [Double] = []
        for (day, before) in early where !disturbed.contains(day) {
            // Half of each hour at least, so neither end rests on a stray reading.
            guard before.count >= 6, let after = late[day], after.count >= 6 else { continue }
            rises.append(percentile(after.sorted(), 0.5) - percentile(before.sorted(), 0.5))
        }
        guard !rises.isEmpty else { return dawn }
        dawn.daysMeasured = rises.count
        dawn.averageRise = rises.reduce(0, +) / Double(rises.count)
        return dawn
    }


    /// Linear-interpolated percentile of an already-sorted array.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Post-meal rise split into breakfast / lunch / dinner, by the hour the meal
    /// was EATEN (not logged). Windows are deliberately wide and gaps are left
    /// unassigned rather than forced into the nearest bucket.
    private static func mealWindowSummary(meals: [(eaten: Date, delay: TimeInterval?)],
                                          glucose: [(date: Date, value: Double)],
                                          calendar: Calendar) -> [MealWindow] {
        guard !meals.isEmpty, glucose.count > 1 else { return [] }

        var buckets: [String: [Double]] = [:]
        let dates = glucose.map(\.date)

        for meal in meals {
            let hour = calendar.component(.hour, from: meal.eaten)
            let name: String
            switch hour {
            case 4...10:  name = NSLocalizedString("Breakfast", comment: "Meal window")
            case 11...15: name = NSLocalizedString("Lunch", comment: "Meal window")
            case 16...22: name = NSLocalizedString("Dinner", comment: "Meal window")
            default:      continue   // late-night eating is its own thing; don't blend it in
            }
            guard let rise = riseAfter(meal.eaten, glucose: glucose, dates: dates) else { continue }
            buckets[name, default: []].append(rise)
        }

        // Keep the published order rather than sorting by size — the point is to
        // compare the same three meals, and a reordering list is hard to read.
        return [NSLocalizedString("Breakfast", comment: "Meal window"),
                NSLocalizedString("Lunch", comment: "Meal window"),
                NSLocalizedString("Dinner", comment: "Meal window")]
            .compactMap { name in
                guard let values = buckets[name], values.count >= 3 else { return nil }
                return MealWindow(name: name,
                                  averageRise: values.reduce(0, +) / Double(values.count),
                                  count: values.count)
            }
    }

    /// Peak rise in the 3 hours after `time`, or nil when there is no usable
    /// baseline or no reading in the window.
    private static func riseAfter(_ time: Date,
                                  glucose: [(date: Date, value: Double)],
                                  dates: [Date]) -> Double? {
        var index = lowerBound(dates, time)
        var baseline: Double?
        var bestGap = TimeInterval.greatestFiniteMagnitude
        for candidate in [index - 1, index] where candidate >= 0 && candidate < glucose.count {
            let gap = abs(glucose[candidate].date.timeIntervalSince(time))
            if gap <= 20 * 60 && gap < bestGap {
                bestGap = gap
                baseline = glucose[candidate].value
            }
        }
        // Same rule as `postMealSummary`: carbs eaten while low are a treatment.
        guard let baseline, baseline >= 70 else { return nil }

        let windowEnd = time.addingTimeInterval(postMealWindow)
        var peak: Double?
        while index < glucose.count && glucose[index].date <= windowEnd {
            if peak == nil || glucose[index].value > peak! { peak = glucose[index].value }
            index += 1
        }
        guard let peak else { return nil }
        return max(0, peak - baseline)
    }

    /// Recovery behaviour around excursions.
    ///
    /// `lowsFollowedByHigh` is the over-treatment signal: a low chased above 180
    /// within two hours usually means it was over-corrected, and that is a
    /// pattern worth seeing because time-in-range alone reports it as two
    /// separate problems rather than one cause.
    private static func recoverySummary(_ glucose: [(date: Date, value: Double)],
                                        lows: [Excursion]) -> Recovery {
        var recovery = Recovery()
        guard glucose.count >= 3 else { return recovery }

        // Low events → did a high follow within two hours of the low ending?
        let dates = glucose.map(\.date)
        var reboundCount = 0
        for low in lows {
            let deadline = low.end.addingTimeInterval(2 * 3600)
            var probe = lowerBound(dates, low.end) + 1
            while probe < glucose.count && glucose[probe].date <= deadline {
                if glucose[probe].value > 180 { reboundCount += 1; break }
                probe += 1
            }
        }
        recovery.lowsAnalysed = lows.count
        if lows.count >= 3 {
            recovery.lowsFollowedByHigh = Double(reboundCount) / Double(lows.count)
        }

        var index = 0
        // High excursions → how long back under 180?
        var durations: [TimeInterval] = []
        while index < glucose.count {
            guard glucose[index].value > 250 else { index += 1; continue }
            let start = glucose[index].date
            var probe = index + 1
            var recovered: Date?
            while probe < glucose.count {
                // 180 itself is in range everywhere else on the screen, so it is
                // "back in range" here too.
                if glucose[probe].value <= 180 { recovered = glucose[probe].date; break }
                probe += 1
            }
            if let recovered {
                // Ignore absurd spans: a sensor gap across a day is not a
                // twenty-hour recovery.
                let span = recovered.timeIntervalSince(start)
                if span <= 12 * 3600 { durations.append(span) }
            }
            index = probe + 1
        }
        recovery.highExcursions = durations.count
        if durations.count >= 3 {
            recovery.medianHighRecovery = median(durations)
        }
        return recovery
    }

    /// Time in range per weekday, averaged across the days of each kind.
    ///
    /// Averaged per DAY rather than pooling every reading, so a weekday with more
    /// sensor data doesn't quietly outvote the others.
    private static func weekdaySummary(_ glucose: [(date: Date, value: Double)],
                                       calendar: Calendar) -> [WeekdayPoint] {
        guard !glucose.isEmpty else { return [] }

        var byDay: [Date: (inRange: Int, total: Int)] = [:]
        for sample in glucose {
            let day = calendar.startOfDay(for: sample.date)
            var entry = byDay[day] ?? (0, 0)
            entry.total += 1
            if sample.value >= 70 && sample.value <= 180 { entry.inRange += 1 }
            byDay[day] = entry
        }

        var byWeekday: [Int: [Double]] = [:]
        for (day, counts) in byDay where counts.total >= minimumReadingsForJudgedDay {
            let weekday = calendar.component(.weekday, from: day)
            byWeekday[weekday, default: []].append(Double(counts.inRange) / Double(counts.total))
        }

        // ⚠️ TWO of that weekday at minimum. One Friday is a Friday, not "your
        // Fridays" — and on a 7-day period every weekday has exactly one, which
        // is how "Fri is your weakest day" got printed from a single day's data.
        // Below the floor the weekday is dropped, and with too few weekdays left
        // the whole tile hides (see `whenSection`).
        return (1...7).compactMap { weekday in
            guard let values = byWeekday[weekday], values.count >= minimumDaysPerWeekday else { return nil }
            return WeekdayPoint(weekday: weekday,
                                inRange: values.reduce(0, +) / Double(values.count),
                                days: values.count)
        }
    }

    /// Gaps longer than 30 minutes between consecutive readings.
    ///
    /// The 6-hour ceiling on `totalMissing` keeps a period boundary or a phone
    /// left off for a week from swamping the number — those are not sensor gaps
    /// in any useful sense.
    private static func sensorGapSummary(_ glucose: [(date: Date, value: Double)]) -> SensorGaps {
        var gaps = SensorGaps()
        guard glucose.count >= 2 else { return gaps }

        for (previous, next) in zip(glucose, glucose.dropFirst()) {
            let interval = next.date.timeIntervalSince(previous.date)
            guard interval > 30 * 60 else { continue }
            gaps.count += 1
            gaps.totalMissing += min(interval, 6 * 3600)
            if gaps.longest == nil || interval > gaps.longest! { gaps.longest = interval }
        }
        return gaps
    }

    /// Time in range for each calendar week that has at least three usable days.
    /// Week By Week for a period that starts at `start`: whole calendar weeks,
    /// from the one holding `start` to the latest.
    ///
    /// ⚠️ WHOLE WEEKS, NOT THE PART OF A WEEK INSIDE THE PERIOD. The tile used
    /// the period's own readings, so its first week was cut at the period's
    /// start: in the 7-day view "4–10 Oct" was really 8–10 Oct and read 86%,
    /// while the 14-day view, and Compare Periods, gave the same week 78%. A
    /// week now has one number wherever it appears. The week still going
    /// counts the days so far.
    static func wholeWeeks(from rawLines: [HistoryLine], overlapping start: Date,
                           calendar: Calendar = .current) -> [WeekPoint] {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        let recent = rawLines.filter { $0.t == "glucose" && ($0.date.map { $0 >= weekStart } ?? false) }
        let glucose = HistoryLineDeduplicator.deduplicated(recent).compactMap { line -> (date: Date, value: Double)? in
            guard let date = line.date, let mgdl = line.mgdl else { return nil }
            return (date, mgdl)
        }
        return weeklySummary(glucose, calendar: calendar)
    }

    private static func weeklySummary(_ glucose: [(date: Date, value: Double)],
                                      calendar: Calendar) -> [WeekPoint] {
        guard !glucose.isEmpty else { return [] }

        var byDay: [Date: (inRange: Int, total: Int)] = [:]
        for sample in glucose {
            let day = calendar.startOfDay(for: sample.date)
            var entry = byDay[day] ?? (0, 0)
            entry.total += 1
            if sample.value >= 70 && sample.value <= 180 { entry.inRange += 1 }
            byDay[day] = entry
        }

        // ⚠️ POOLED READINGS, THE SAME WAY "COMPARE PERIODS" DOES IT, and the same
        // per-day floor. This used to average each day's percentage instead, so
        // the two tiles showed the same week as 71% and 69% on one screen.
        var byWeek: [Date: (inRange: Int, total: Int, days: Int)] = [:]
        for (day, counts) in byDay where counts.total >= minimumReadingsForCountedDay {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { continue }
            var entry = byWeek[week] ?? (0, 0, 0)
            entry.inRange += counts.inRange
            entry.total += counts.total
            entry.days += 1
            byWeek[week] = entry
        }

        // Three days is the floor for calling something a week; below that the
        // point swings wildly and reads as a trend that isn't there.
        return byWeek
            .filter { $0.value.days >= 3 }
            .map { WeekPoint(weekStart: $0.key,
                             inRange: Double($0.value.inRange) / Double($0.value.total),
                             days: $0.value.days) }
            .sorted { $0.weekStart < $1.weekStart }
    }


    /// Glucose summarised per week or per month, for the comparison tile.
    ///
    /// Deliberately standalone and driven straight off the log lines: the caller
    /// feeds it EVERY line rather than the selected 30/90-day window. A
    /// month-by-month comparison restricted to the last 30 days would have one
    /// bar in it, which is not a comparison.
    ///
    /// Read-only, like everything else on this screen.
    static func periodSummary(from rawLines: [HistoryLine],
                              granularity: PeriodGranularity,
                              calendar: Calendar = .current) -> [PeriodPoint] {
        // ⚠️ SAME DE-DUPLICATION AS `compute`, WHICH THIS USED TO SKIP. The log
        // repeats readings, unevenly, so a month here did not match the same
        // month's headline: September read 76.3% in range from 8,899 readings
        // against 77.1% from the 8,191 that are really there.
        let lines = HistoryLineDeduplicator.deduplicated(rawLines)
        // Same per-day floor as `weeklySummary`: 72 readings is six hours at the
        // usual five-minute cadence. A day with a handful of readings is not a
        // day you can average.
        var samplesByDay: [Date: [Double]] = [:]
        for line in lines where line.t == "glucose" {
            guard let date = line.date, let mgdl = line.mgdl else { continue }
            samplesByDay[calendar.startOfDay(for: date), default: []].append(mgdl)
        }

        var byPeriod: [Date: (values: [Double], days: Int)] = [:]
        for (day, values) in samplesByDay where values.count >= 72 {
            guard let start = calendar.dateInterval(of: granularity.component, for: day)?.start else { continue }
            var entry = byPeriod[start] ?? ([], 0)
            entry.values.append(contentsOf: values)
            entry.days += 1
            byPeriod[start] = entry
        }

        return byPeriod
            .filter { $0.value.days >= granularity.minimumDays }
            .map { start, entry in
                let values = entry.values
                let count = Double(values.count)
                let mean = values.reduce(0, +) / count
                let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / count
                let sd = sqrt(variance)
                return PeriodPoint(
                    start: start,
                    granularity: granularity,
                    days: entry.days,
                    readings: values.count,
                    mean: mean,
                    standardDeviation: sd,
                    coefficientOfVariation: mean > 0 ? sd / mean * 100 : 0,
                    // Same Bergenstal GMI as `glucoseSummary`.
                    gmi: 3.31 + 0.02392 * mean,
                    inRange: Double(values.filter { $0 >= 70 && $0 <= 180 }.count) / count,
                    below: Double(values.filter { $0 < 70 }.count) / count,
                    veryLow: Double(values.filter { $0 < 54 }.count) / count,
                    above: Double(values.filter { $0 > 180 }.count) / count
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Did the night go low, grouped by the glucose at bedtime (taken as 23:00)?
    ///
    /// Buckets are wide and only reported when each has enough nights to mean
    /// something. Descriptive only — see `BedtimeOutcome`.
    private static func bedtimeSummary(_ glucose: [(date: Date, value: Double)],
                                       lows: [Excursion],
                                       calendar: Calendar) -> [BedtimeOutcome] {
        guard glucose.count >= 100 else { return [] }

        // night key -> (bedtime reading, whether a low followed before 06:00,
        // and how many readings there were AFTER midnight — see the floor below)
        var nights: [Date: (bedtime: Double?, gap: TimeInterval, bedtimeAt: Date?, afterMidnight: Int)] = [:]

        for sample in glucose {
            let hour = calendar.component(.hour, from: sample.date)
            // A night is keyed on the DAY IT STARTED, so 23:00 and the 02:00 that
            // follows it belong to the same night rather than to two.
            let nightStart: Date
            if hour >= 22 {
                nightStart = calendar.startOfDay(for: sample.date)
            } else if hour < 6 {
                guard let previous = calendar.date(byAdding: .day, value: -1, to: sample.date) else { continue }
                nightStart = calendar.startOfDay(for: previous)
            } else {
                continue
            }

            var entry = nights[nightStart] ?? (nil, .greatestFiniteMagnitude, nil, 0)
            if hour < 6 { entry.afterMidnight += 1 }
            if hour >= 22 || hour < 1 {
                guard let elevenPM = calendar.date(byAdding: .hour, value: 23, to: nightStart) else { continue }
                let gap = abs(sample.date.timeIntervalSince(elevenPM))
                if gap <= 60 * 60 && gap < entry.gap {
                    entry.bedtime = sample.value
                    entry.gap = gap
                    entry.bedtimeAt = sample.date
                }
            }
            nights[nightStart] = entry
        }

        var buckets: [(label: String, range: Range<Double>)] = [
            (NSLocalizedString("Under 120", comment: "Bedtime bucket"), 0..<120),
            (NSLocalizedString("120–160", comment: "Bedtime bucket"), 120..<160),
            (NSLocalizedString("Over 160", comment: "Bedtime bucket"), 160..<1000)
        ]

        return buckets.compactMap { bucket in
            // ⚠️ A NIGHT ONLY COUNTS IF ITS OUTCOME IS KNOWN. The last evening in
            // any window has a bedtime reading but no morning after it yet;
            // counting it as a night that did NOT go low quietly improves every
            // rate here. It needs real post-midnight coverage to be judged.
            let matching = nights.filter { _, entry in
                guard let bedtime = entry.bedtime,
                      entry.afterMidnight >= minimumReadingsPerNight else { return false }
                return bucket.range.contains(bedtime)
            }
            guard matching.count >= 5 else { return nil }
            // A low counts when it BEGINS after the bedtime reading and before
            // 06:00: one already under way at bedtime is not what followed it.
            let withLow = matching.filter { nightStart, entry in
                guard let bedtimeAt = entry.bedtimeAt,
                      let morning = calendar.date(byAdding: .hour, value: 30, to: nightStart) else { return false }
                return lows.contains { $0.start > bedtimeAt && $0.start < morning }
            }.count
            return BedtimeOutcome(label: bucket.label,
                                  lowRate: Double(withLow) / Double(matching.count),
                                  nights: matching.count)
        }
    }

    /// Post-meal rise grouped by carb amount.
    private static func mealSizeSummary(meals: [(eaten: Date, grams: Double)],
                                        glucose: [(date: Date, value: Double)]) -> [MealSizeOutcome] {
        guard !meals.isEmpty, glucose.count > 1 else { return [] }
        let dates = glucose.map(\.date)

        var buckets: [String: [Double]] = [:]
        for meal in meals {
            let label: String
            switch meal.grams {
            case ..<30:  label = NSLocalizedString("Under 30 g", comment: "Meal size bucket")
            case 30..<60: label = NSLocalizedString("30–60 g", comment: "Meal size bucket")
            default:     label = NSLocalizedString("60 g or more", comment: "Meal size bucket")
            }
            guard let rise = riseAfter(meal.eaten, glucose: glucose, dates: dates) else { continue }
            buckets[label, default: []].append(rise)
        }

        return [NSLocalizedString("Under 30 g", comment: "Meal size bucket"),
                NSLocalizedString("30–60 g", comment: "Meal size bucket"),
                NSLocalizedString("60 g or more", comment: "Meal size bucket")]
            .compactMap { label in
                guard let values = buckets[label], values.count >= 3 else { return nil }
                return MealSizeOutcome(label: label,
                                       averageRise: values.reduce(0, +) / Double(values.count),
                                       count: values.count)
            }
    }

    /// Meal-sized rises with nothing logged to explain them.
    ///
    /// Looks for a climb of 60 mg/dL or more inside 90 minutes with no carb
    /// entry and no bolus in the 2 hours before it. Both thresholds are
    /// deliberately conservative: a false "you forgot" is worse than a miss,
    /// because it teaches the user to distrust the number.
    private static func missedBolusSummary(_ glucose: [(date: Date, value: Double)],
                                           meals: [(eaten: Date, absorbedBy: Date)],
                                           boluses: [Date],
                                           days: Double) -> MissedBolus {
        var result = MissedBolus()
        guard glucose.count > 20 else { return result }

        var index = 0
        var lastFlagged: Date?
        while index < glucose.count {
            let start = glucose[index]
            let deadline = start.date.addingTimeInterval(90 * 60)
            var peak = start.value
            var probe = index + 1
            while probe < glucose.count && glucose[probe].date <= deadline {
                peak = max(peak, glucose[probe].value)
                probe += 1
            }

            if peak - start.value >= 60 {
                let quietFrom = start.date.addingTimeInterval(-2 * 3600)
                // A slow meal is still the explanation three or four hours on;
                // the flat two hours this used to allow called its late rise
                // "unexplained".
                let explained = meals.contains { $0.eaten <= deadline && $0.absorbedBy >= start.date }
                    || boluses.contains { $0 >= quietFrom && $0 <= deadline }
                // One rise per 4 hours at most, so a long climb isn't counted
                // once per reading along the way.
                let recentlyFlagged = lastFlagged.map { start.date.timeIntervalSince($0) < 4 * 3600 } ?? false
                if !explained && !recentlyFlagged {
                    result.count += 1
                    lastFlagged = start.date
                }
            }
            index += 1
        }
        result.perWeek = days > 0 ? Double(result.count) / days * 7 : 0
        return result
    }

    /// Index of the first date >= `target`, by binary search.
    private static func lowerBound(_ dates: [Date], _ target: Date) -> Int {
        var low = 0
        var high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

// MARK: - Best time in range

extension HistoryStatistics {
    /// The highest time in range the period on screen has ever shown.
    struct BestTimeInRange: Equatable {
        let fraction: Double
        /// First and last calendar day of the period when it stood at this value.
        let firstDay: Date
        let lastDay: Date
        /// The moment it stood at this value: the time of the reading that took
        /// it there (or now, for the period on screen).
        let achievedAt: Date
        /// True when this IS the period on screen now.
        let isCurrent: Bool
    }

    /// A period only counts with at least 70% of the readings a 5-minute sensor
    /// would have produced over the time it covers, the usual minimum for a CGM
    /// report, so a stretch with the sensor off cannot score well off the few
    /// readings it has.
    static let bestTimeInRangeMinimumCoverage = 0.7
    /// Seconds between the readings of the sensor the coverage is measured against.
    static let expectedReadingInterval: TimeInterval = 300

    /// Best time in range for each period length in `windowDays`, from every line.
    ///
    /// ⚠️ THE BEST OF WHAT THE SCREEN SHOWS, AT EVERY MOMENT IT COULD HAVE SHOWN IT.
    /// The period on screen is the last N calendar days with today included, so
    /// its value moves with every reading. This replays that same period as it
    /// stood at the time of every reading in the log (and as it stands now), and
    /// keeps the highest. It used to compare whole calendar days only, and to
    /// demand 70% of N FULL days of readings, which had two consequences the
    /// owner saw: a period that briefly stood above the "best" was forgotten by
    /// the next day, and just after midnight the 3-day period (two days and a few
    /// minutes old, sensor data 98%) was refused as "not enough sensor data"
    /// while standing four points above the best. Now the best can never be
    /// below a period on screen that has enough sensor data, and a value once
    /// reached stays reached.
    ///
    /// Same 70–180 mg/dL rule and the same de-duplication as `compute`. Coverage
    /// is measured over the time the period covered at that moment (see
    /// `bestTimeInRangeMinimumCoverage`), which is what the Sensor Data tile
    /// reports for a period that has data from its first day.
    static func bestTimeInRange(from rawLines: [HistoryLine],
                                windowDays: [Int],
                                now: Date = Date(),
                                calendar: Calendar = .current) -> [Int: BestTimeInRange] {
        var readings: [(date: Date, inRange: Bool)] = []
        for line in HistoryLineDeduplicator.deduplicated(rawLines) {
            guard line.t == "glucose", let mgdl = line.mgdl, let date = line.date, date <= now else { continue }
            readings.append((date, mgdl >= 70 && mgdl <= 180))
        }
        guard !readings.isEmpty else { return [:] }
        readings.sort { $0.date < $1.date }

        // In-range readings among the first k, so any stretch is one subtraction.
        var inRangeBefore = [Int](repeating: 0, count: readings.count + 1)
        for (index, reading) in readings.enumerated() {
            inRangeBefore[index + 1] = inRangeBefore[index] + (reading.inRange ? 1 : 0)
        }

        // Every calendar day from the first reading to today, and the index of the
        // first reading on or after each day's start.
        var dayStarts: [Date] = []
        let today = calendar.startOfDay(for: now)
        var day = calendar.startOfDay(for: readings[0].date)
        while day <= today {
            dayStarts.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        var firstIndexOfDay = [Int](repeating: readings.count, count: dayStarts.count)
        var dayOfReading = [Int](repeating: 0, count: readings.count)
        var dayIndex = 0
        for (index, reading) in readings.enumerated() {
            while dayIndex + 1 < dayStarts.count && dayStarts[dayIndex + 1] <= reading.date { dayIndex += 1 }
            dayOfReading[index] = dayIndex
            if firstIndexOfDay[dayIndex] == readings.count { firstIndexOfDay[dayIndex] = index }
        }
        // A day with no readings starts where the next day with readings does.
        for index in stride(from: dayStarts.count - 2, through: 0, by: -1) where firstIndexOfDay[index] == readings.count {
            firstIndexOfDay[index] = firstIndexOfDay[index + 1]
        }

        var result: [Int: BestTimeInRange] = [:]
        for window in Set(windowDays) where window > 0 {
            /// The period of `window` calendar days ending on day `lastDayIndex`:
            /// when it starts, and the first reading inside it.
            func opening(_ lastDayIndex: Int) -> (start: Date, firstIndex: Int)? {
                let firstDayIndex = lastDayIndex - (window - 1)
                if firstDayIndex >= 0 { return (dayStarts[firstDayIndex], firstIndexOfDay[firstDayIndex]) }
                // It opens before the log does: every reading so far is inside it.
                guard let start = calendar.date(byAdding: .day, value: -(window - 1), to: dayStarts[lastDayIndex]) else { return nil }
                return (start, 0)
            }

            var best: (fraction: Double, inRange: Int, total: Int, start: Date, lastDayIndex: Int, at: Date)?
            /// The period as it stood at `moment`, holding the readings up to
            /// (not including) `endIndex`.
            func consider(lastDayIndex: Int, endIndex: Int, moment: Date) {
                guard let opening = opening(lastDayIndex) else { return }
                let total = endIndex - opening.firstIndex
                let elapsed = moment.timeIntervalSince(opening.start)
                guard total > 0, elapsed > 0 else { return }
                let expected = elapsed / expectedReadingInterval
                guard Double(total) >= bestTimeInRangeMinimumCoverage * expected else { return }
                let inRange = inRangeBefore[endIndex] - inRangeBefore[opening.firstIndex]
                let fraction = Double(inRange) / Double(total)
                // `>=`, so a tie goes to the more recent moment.
                if fraction >= (best?.fraction ?? -1) {
                    best = (fraction, inRange, total, opening.start, lastDayIndex, moment)
                }
            }

            for index in readings.indices {
                consider(lastDayIndex: dayOfReading[index], endIndex: index + 1, moment: readings[index].date)
            }
            // The period on screen right now. Last, so that it wins a tie.
            let todayIndex = dayStarts.count - 1
            consider(lastDayIndex: todayIndex, endIndex: readings.count, moment: now)

            guard let best else { continue }
            // It is the period on screen when it holds exactly today's readings so
            // far, whether it was reached now or at the latest reading.
            var isCurrent = false
            if best.lastDayIndex == todayIndex, let current = opening(todayIndex) {
                isCurrent = best.total == readings.count - current.firstIndex
                    && best.inRange == inRangeBefore[readings.count] - inRangeBefore[current.firstIndex]
            }
            result[window] = BestTimeInRange(fraction: best.fraction,
                                             firstDay: max(best.start, dayStarts[0]),
                                             lastDay: dayStarts[best.lastDayIndex],
                                             achievedAt: best.at,
                                             isCurrent: isCurrent)
        }
        return result
    }
}

// MARK: - Basal delivered

/// What the pump delivered as basal, rebuilt from the log and a basal schedule.
///
/// The log holds temp basals (with the units each delivered), suspends and
/// resumes. It does not hold the programmed schedule the pump runs the rest of
/// the time, so that part is the schedule's rate over every stretch that is
/// neither under a temp basal nor suspended.
///
/// Checked against 21 pod sessions' own delivered totals (3,597 U): boluses plus
/// this came to +0.1%; boluses plus temp basals alone, to -19.5%.
///
/// A schedule is used from the moment it is known to have come into force
/// (`ScheduleEntry.since`); the oldest one known also stands for all the time
/// before it. The log does not record a schedule change, so "known" is when the
/// statistics screen was next opened with the new schedule.
struct BasalDelivery {
    /// The rate from `startOffset` seconds after local midnight until the next entry.
    struct ScheduleEntry: Equatable {
        let startOffset: TimeInterval
        let unitsPerHour: Double
        /// When the schedule this entry belongs to came into force; nil for the
        /// oldest schedule known. Entries with the same `since` are one schedule.
        var since: Date? = nil
    }

    /// A pod reports its reservoir only up to this many units; above it, it
    /// reports a fixed marker instead of an amount.
    static let podReservoirReadingLimit = 50.0

    /// Every schedule that has been in force, oldest first, each from `since`
    /// until the next one's.
    private let versions: [(since: Date, entries: [ScheduleEntry])]
    private let calendar: Calendar
    /// Stretches the schedule was NOT running (a temp basal or a suspension),
    /// merged and in time order.
    private let offSchedule: [(start: Date, end: Date)]
    /// Every temp basal with the units it delivered.
    private let tempBasals: [(start: Date, end: Date, units: Double)]

    /// - Parameter lines: de-duplicated, in file order.
    init(lines: [HistoryLine], schedule: [ScheduleEntry], calendar: Calendar = .current) {
        self.versions = Self.versions(of: schedule)
        self.calendar = calendar

        var stretches: [(start: Date, end: Date)] = []
        var temps: [(start: Date, end: Date, units: Double)] = []
        var suspendedSince: Date?
        var lastDate: Date?
        for line in lines where line.t == "dose" {
            guard let date = line.date else { continue }
            lastDate = max(lastDate ?? date, date)
            switch line.kind {
            case "tempBasal":
                if let end = line.endedAt.flatMap({ HistoryTimestamp.formatter.date(from: $0) }), end > date {
                    stretches.append((date, end))
                    temps.append((date, end, line.units ?? 0))
                }
            // ⚠️ PAIRED IN FILE ORDER. A suspend and its resume often carry the
            // same second (every pod change writes one of each), so sorting them
            // by time can put the resume first and leave the pump "suspended"
            // until the next pod.
            case "suspend":
                if suspendedSince == nil { suspendedSince = date }
            case "resume":
                if let since = suspendedSince, date > since { stretches.append((since, date)) }
                suspendedSince = nil
            default:
                break
            }
        }
        // Still suspended at the end of the log: suspended until its last dose.
        if let since = suspendedSince, let lastDate, lastDate > since { stretches.append((since, lastDate)) }

        stretches.sort { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for stretch in stretches {
            if let last = merged.indices.last, stretch.start <= merged[last].end {
                merged[last].end = max(merged[last].end, stretch.end)
            } else {
                merged.append(stretch)
            }
        }
        offSchedule = merged
        tempBasals = temps.sorted { $0.start < $1.start }
    }

    /// Units delivered by temp basals from `start` to `end`; one that straddles
    /// an edge counts for the part of it inside.
    func tempBasalUnits(from start: Date, to end: Date) -> Double {
        var total = 0.0
        for temp in tempBasals {
            if temp.end <= start { continue }
            if temp.start >= end { break }
            let inside = min(temp.end, end).timeIntervalSince(max(temp.start, start))
            total += temp.units * inside / temp.end.timeIntervalSince(temp.start)
        }
        return total
    }

    /// Basal delivered from `start` to `end`, less what the schedule alone would
    /// have given: negative when Loop held basal back.
    func basalAgainstSchedule(from start: Date, to end: Date) -> Double {
        tempBasalUnits(from: start, to: end) + scheduledUnitsDelivered(from: start, to: end) - scheduledUnits(from: start, to: end)
    }

    /// The schedules in `schedule`, oldest first. The oldest starts at the
    /// beginning of time whatever its own `since`: there is nothing better to
    /// use for the time before it.
    static func versions(of schedule: [ScheduleEntry]) -> [(since: Date, entries: [ScheduleEntry])] {
        var versions = Dictionary(grouping: schedule) { $0.since ?? .distantPast }
            .map { (since: $0.key, entries: $0.value.sorted { $0.startOffset < $1.startOffset }) }
            .sorted { $0.since < $1.since }
        if !versions.isEmpty { versions[0].since = .distantPast }
        return versions
    }

    /// The schedule in force now: the newest one in `schedule`.
    static func current(of schedule: [ScheduleEntry]) -> [ScheduleEntry] {
        versions(of: schedule).last?.entries ?? []
    }

    /// A day of the schedule in force now, in units.
    static func dailyTotal(of schedule: [ScheduleEntry]) -> Double {
        dailyTotal(ofOne: current(of: schedule))
    }

    /// A day of the programmed basal averaged over `start` to `end`: a schedule
    /// that changed part-way counts for the part of the time it was in force.
    func programmedPerDay(from start: Date, to end: Date) -> Double {
        guard end > start else { return Self.dailyTotal(ofOne: versions.last?.entries ?? []) }
        var total = 0.0
        for (index, version) in versions.enumerated() {
            let versionEnd = index + 1 < versions.count ? versions[index + 1].since : Date.distantFuture
            let inside = min(end, versionEnd).timeIntervalSince(max(start, version.since))
            if inside > 0 { total += Self.dailyTotal(ofOne: version.entries) * inside }
        }
        return total / end.timeIntervalSince(start)
    }

    private static func dailyTotal(ofOne schedule: [ScheduleEntry]) -> Double {
        let sorted = schedule.sorted { $0.startOffset < $1.startOffset }
        var total = 0.0
        for (index, entry) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].startOffset : 86400
            total += entry.unitsPerHour * max(0, end - entry.startOffset) / 3600
        }
        return total
    }

    /// What the schedule alone would deliver from `start` to `end`, each
    /// stretch at the schedule in force at the time.
    func scheduledUnits(from start: Date, to end: Date) -> Double {
        guard end > start else { return 0 }
        var total = 0.0
        for (index, version) in versions.enumerated() {
            let versionEnd = index + 1 < versions.count ? versions[index + 1].since : Date.distantFuture
            let from = max(start, version.since)
            let to = min(end, versionEnd)
            if to > from { total += units(of: version.entries, from: from, to: to) }
        }
        return total
    }

    /// What one schedule would deliver from `start` to `end`.
    private func units(of schedule: [ScheduleEntry], from start: Date, to end: Date) -> Double {
        guard !schedule.isEmpty, end > start else { return 0 }
        var total = 0.0
        var moment = start
        while moment < end {
            let day = calendar.startOfDay(for: moment)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
            let offset = moment.timeIntervalSince(day)
            // The entry in force at `moment` (the last one of the day before the first entry starts).
            let index = schedule.lastIndex { $0.startOffset <= offset } ?? schedule.count - 1
            var segmentEnd = nextDay
            if let later = schedule.first(where: { $0.startOffset > offset }) {
                segmentEnd = min(nextDay, day.addingTimeInterval(later.startOffset))
            }
            segmentEnd = min(segmentEnd, end)
            guard segmentEnd > moment else { break }
            total += schedule[index].unitsPerHour * segmentEnd.timeIntervalSince(moment) / 3600
            moment = segmentEnd
        }
        return total
    }

    /// Scheduled basal actually delivered from `start` to `end`: the schedule,
    /// less the stretches a temp basal or a suspension replaced it.
    func scheduledUnitsDelivered(from start: Date, to end: Date) -> Double {
        guard end > start else { return 0 }
        var total = 0.0
        var moment = start
        for stretch in offSchedule {
            if stretch.end <= moment { continue }
            if stretch.start >= end { break }
            if stretch.start > moment { total += scheduledUnits(from: moment, to: stretch.start) }
            moment = max(moment, stretch.end)
            if moment >= end { break }
        }
        if moment < end { total += scheduledUnits(from: moment, to: end) }
        return total
    }
}
