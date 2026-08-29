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
        var totalUnits: Double = 0
        var bolusUnits: Double = 0
        var basalUnits: Double = 0
        var automaticUnits: Double = 0
        var dailyAverage: Double = 0
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
        /// Units left in pods when they stopped — insulin thrown away.
        var wastedUnits: Double = 0
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
        var automaticDosesPerDay: Double = 0
        var manualBolusesPerDay: Double = 0
        /// Basal units actually delivered per day.
        var deliveredBasalPerDay: Double = 0
        /// The programmed schedule's daily total, when known.
        var scheduledBasalPerDay: Double?
        /// Delivered ÷ scheduled. Above 1 means the algorithm is consistently
        /// giving more than the profile asks for.
        var basalRatio: Double? {
            guard let scheduled = scheduledBasalPerDay, scheduled > 0 else { return nil }
            return deliveredBasalPerDay / scheduled
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

    /// Days used for per-day averages: days that actually have records.
    var dayCount: Double {
        // At least one, so a single day of data doesn't divide by ~0 and report
        // absurd daily averages.
        max(1, Double(daysWithData))
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
        var mealEvents: [(eaten: Date, delay: TimeInterval?)] = []
        var mealSizes: [(eaten: Date, grams: Double)] = []
        var bolusTimes: [Date] = []
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
        var deliveredBasalUnits = 0.0
        var stopReasonCounts: [String: Int] = [:]
        var faultCount = 0
        var podHours: [Double] = []
        var earliest: Date?
        var latest: Date?

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
                    if mgdl < 70 { nightsWithLow.insert(night) }
                } else {
                    daytime.append(mgdl)
                }

            case "dose":
                // Only units actually delivered count. A temp basal reports a
                // RATE as well; adding both would double-count the same insulin.
                if let units = line.units {
                    stats.insulin.totalUnits += units
                    if line.kind == "bolus" {
                        stats.insulin.bolusUnits += units
                        if line.automatic == true { automaticDoses += 1 } else { manualBoluses += 1 }
                        bolusTimes.append(date)
                    } else {
                        stats.insulin.basalUnits += units
                        deliveredBasalUnits += units
                    }
                    if line.automatic == true { stats.insulin.automaticUnits += units }
                }

            case "meal":
                stats.meals.entryCount += 1
                stats.meals.totalGrams += line.grams ?? 0
                let eaten = line.eatenAt.flatMap { HistoryTimestamp.formatter.date(from: $0) }
                let entered = line.enteredAt.flatMap { HistoryTimestamp.formatter.date(from: $0) }
                var delay: TimeInterval?
                if let eaten, let entered {
                    let gap = entered.timeIntervalSince(eaten)
                    // Negative means logged in advance, which is a different
                    // habit entirely — don't average the two together.
                    if gap >= 0 {
                        delay = gap
                        loggingDelays.append(gap)
                    }
                }
                if let eaten {
                    mealEvents.append((eaten, delay))
                    if let grams = line.grams, grams > 0 { mealSizes.append((eaten, grams)) }
                }

            case "pod":
                stats.pods.count += 1
                if let hours = line.hoursRun { podHours.append(hours) }
                stats.pods.wastedUnits += line.remainingAtStop ?? 0
                let reason = line.stopReason ?? "unknown"
                stopReasonCounts[reason, default: 0] += 1
                if reason == "fault" { faultCount += 1 }

            default:
                continue
            }
        }

        stats.firstDate = earliest
        stats.lastDate = latest

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
        stats.nights = Nights(total: countedNights.count,
                              withLow: nightsWithLow.intersection(countedNights).count)

        let sortedGlucose = glucoseSeries.sorted { $0.date < $1.date }
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
        let days = stats.dayCount
        stats.lowEvents = lowEventSummary(sortedGlucose, days: days)
        stats.highEvents = highEventSummary(sortedGlucose, days: days)
        stats.days = daySummary(sortedGlucose, calendar: calendar)
        stats.dawn = dawnSummary(sortedGlucose, calendar: calendar)
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
        stats.recovery = recoverySummary(sortedGlucose)
        stats.weekdayProfile = weekdaySummary(sortedGlucose, calendar: calendar)
        stats.weeklyTrend = weeklySummary(sortedGlucose, calendar: calendar)
        stats.bedtimeOutcomes = bedtimeSummary(sortedGlucose, calendar: calendar)
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
            deliveredBasalPerDay: days > 0 ? deliveredBasalUnits / days : 0,
            scheduledBasalPerDay: scheduledBasalPerDay)

        stats.missedBolus = missedBolusSummary(sortedGlucose, meals: mealEvents,
                                               boluses: bolusTimes, days: days)
        stats.mealsPerDay = days > 0 ? Double(stats.meals.entryCount) / days : 0
        stats.gramsPerMeal = stats.meals.entryCount > 0
            ? stats.meals.totalGrams / Double(stats.meals.entryCount)
            : 0

        stats.insulin.dailyAverage = days > 0 ? stats.insulin.totalUnits / days : 0
        stats.meals.dailyAverageGrams = days > 0 ? stats.meals.totalGrams / days : 0
        stats.meals.medianLoggingDelay = median(loggingDelays)

        if stats.pods.count > 0 {
            stats.pods.meanHours = podHours.isEmpty ? 0 : podHours.reduce(0, +) / Double(podHours.count)
            stats.pods.faultRate = Double(faultCount) / Double(stats.pods.count)
            stats.pods.stopReasons = stopReasonCounts
                .map { (reason: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }
        }

        return stats
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
            guard let baseline else { continue }

            let windowEnd = meal.eaten.addingTimeInterval(5 * 3600)
            var peak: Double?
            var peakDate: Date?
            var returnedAt: Date?
            var sawPeak = false
            while index < sorted.count && sorted[index].date <= windowEnd {
                if peak == nil || sorted[index].value > peak! {
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
                                        days: Double) -> LowEvents {
        var events = LowEvents()
        let level1 = excursions(glucose, threshold: 70, below: true)
        events.count = level1.count
        events.level2Count = excursions(glucose, threshold: 54, below: true).count
        if !level1.isEmpty {
            events.averageDuration = level1.reduce(0, +) / Double(level1.count)
        }
        events.perWeek = days > 0 ? Double(level1.count) / days * 7 : 0
        return events
    }

    private static func highEventSummary(_ glucose: [(date: Date, value: Double)],
                                         days: Double) -> HighEvents {
        var events = HighEvents()
        let durations = excursions(glucose, threshold: 250, below: false)
        events.count = durations.count
        if !durations.isEmpty {
            events.averageDuration = durations.reduce(0, +) / Double(durations.count)
        }
        events.perWeek = days > 0 ? Double(durations.count) / days * 7 : 0
        return events
    }

    /// Durations of every excursion past `threshold`, using the consensus rule:
    /// at least 15 consecutive minutes beyond it to START an event, and at least
    /// 15 consecutive minutes back to END one.
    private static func excursions(_ glucose: [(date: Date, value: Double)],
                                   threshold: Double,
                                   below: Bool) -> [TimeInterval] {
        guard glucose.count >= 2 else { return [] }
        let minimum: TimeInterval = 15 * 60

        var durations: [TimeInterval] = []
        var runStart: Date?       // start of the current beyond-threshold run
        var runEnd: Date?         // last sample still beyond it
        var recoveredAt: Date?    // first sample back inside
        var inEvent = false

        func beyond(_ value: Double) -> Bool { below ? value < threshold : value > threshold }

        for sample in glucose {
            if beyond(sample.value) {
                recoveredAt = nil
                if runStart == nil { runStart = sample.date }
                runEnd = sample.date
                // Promote the run to a real event once it has lasted long enough.
                if !inEvent, let start = runStart,
                   sample.date.timeIntervalSince(start) >= minimum {
                    inEvent = true
                }
            } else {
                if recoveredAt == nil { recoveredAt = sample.date }
                // Only close the event after a sustained return, so one stray
                // in-range reading mid-low doesn't split it into two events.
                if inEvent, let recovered = recoveredAt,
                   sample.date.timeIntervalSince(recovered) >= minimum,
                   let start = runStart, let end = runEnd {
                    durations.append(end.timeIntervalSince(start))
                    inEvent = false
                    runStart = nil
                    runEnd = nil
                } else if !inEvent, let recovered = recoveredAt,
                          sample.date.timeIntervalSince(recovered) >= minimum {
                    // The run never qualified; discard it.
                    runStart = nil
                    runEnd = nil
                }
            }
        }
        // An event still open at the end of the window still counts.
        if inEvent, let start = runStart, let end = runEnd {
            durations.append(end.timeIntervalSince(start))
        }
        return durations
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

        // Days with very few readings would otherwise score 100% off three
        // lucky samples, so require a quarter of a day's worth.
        let usable = inRangeByDay.filter { $0.value.total >= 72 }
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

        // Longest consecutive run of goal days.
        var streak = 0
        var best = 0
        for day in usable.keys.sorted() {
            if goalDays.contains(day) {
                streak += 1
                best = max(best, streak)
            } else {
                streak = 0
            }
        }
        summary.bestStreak = best
        return summary
    }

    /// Dawn phenomenon: the 03:00 → 08:00 change, averaged over days that have a
    /// reading near both times.
    private static func dawnSummary(_ glucose: [(date: Date, value: Double)],
                                    calendar: Calendar) -> Dawn {
        var dawn = Dawn()
        guard !glucose.isEmpty else { return dawn }

        var byDay: [Date: (early: Double?, earlyGap: TimeInterval, late: Double?, lateGap: TimeInterval)] = [:]
        for sample in glucose {
            let day = calendar.startOfDay(for: sample.date)
            guard let threeAM = calendar.date(byAdding: .hour, value: 3, to: day),
                  let eightAM = calendar.date(byAdding: .hour, value: 8, to: day) else { continue }
            var entry = byDay[day] ?? (nil, .greatestFiniteMagnitude, nil, .greatestFiniteMagnitude)

            let earlyGap = abs(sample.date.timeIntervalSince(threeAM))
            if earlyGap <= 30 * 60 && earlyGap < entry.earlyGap {
                entry.early = sample.value
                entry.earlyGap = earlyGap
            }
            let lateGap = abs(sample.date.timeIntervalSince(eightAM))
            if lateGap <= 30 * 60 && lateGap < entry.lateGap {
                entry.late = sample.value
                entry.lateGap = lateGap
            }
            byDay[day] = entry
        }

        let rises = byDay.values.compactMap { entry -> Double? in
            guard let early = entry.early, let late = entry.late else { return nil }
            return late - early
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
        guard let baseline else { return nil }

        let windowEnd = time.addingTimeInterval(3 * 3600)
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
    private static func recoverySummary(_ glucose: [(date: Date, value: Double)]) -> Recovery {
        var recovery = Recovery()
        guard glucose.count >= 3 else { return recovery }

        // Low events → did a high follow?
        var index = 0
        var reboundCount = 0
        var lowCount = 0
        while index < glucose.count {
            guard glucose[index].value < 70 else { index += 1; continue }
            // Walk to the end of this low run.
            var end = index
            while end + 1 < glucose.count && glucose[end + 1].value < 70 { end += 1 }
            lowCount += 1
            let deadline = glucose[end].date.addingTimeInterval(2 * 3600)
            var probe = end + 1
            var rebounded = false
            while probe < glucose.count && glucose[probe].date <= deadline {
                if glucose[probe].value > 180 { rebounded = true; break }
                probe += 1
            }
            if rebounded { reboundCount += 1 }
            index = end + 1
        }
        recovery.lowsAnalysed = lowCount
        if lowCount >= 3 {
            recovery.lowsFollowedByHigh = Double(reboundCount) / Double(lowCount)
        }

        // High excursions → how long back under 180?
        var durations: [TimeInterval] = []
        index = 0
        while index < glucose.count {
            guard glucose[index].value > 250 else { index += 1; continue }
            let start = glucose[index].date
            var probe = index + 1
            var recovered: Date?
            while probe < glucose.count {
                if glucose[probe].value < 180 { recovered = glucose[probe].date; break }
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
        for (day, counts) in byDay where counts.total >= 72 {
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

        var byWeek: [Date: [Double]] = [:]
        for (day, counts) in byDay where counts.total >= 72 {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { continue }
            byWeek[week, default: []].append(Double(counts.inRange) / Double(counts.total))
        }

        // Three days is the floor for calling something a week; below that the
        // point swings wildly and reads as a trend that isn't there.
        return byWeek
            .filter { $0.value.count >= 3 }
            .map { WeekPoint(weekStart: $0.key,
                             inRange: $0.value.reduce(0, +) / Double($0.value.count),
                             days: $0.value.count) }
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
    static func periodSummary(from lines: [HistoryLine],
                              granularity: PeriodGranularity,
                              calendar: Calendar = .current) -> [PeriodPoint] {
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
                                       calendar: Calendar) -> [BedtimeOutcome] {
        guard glucose.count >= 100 else { return [] }

        // night key -> (bedtime reading, whether a low followed before 06:00,
        // and how many readings there were AFTER midnight — see the floor below)
        var nights: [Date: (bedtime: Double?, gap: TimeInterval, low: Bool, afterMidnight: Int)] = [:]

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

            var entry = nights[nightStart] ?? (nil, .greatestFiniteMagnitude, false, 0)
            if hour < 6 { entry.afterMidnight += 1 }
            if hour >= 22 || hour < 1 {
                guard let elevenPM = calendar.date(byAdding: .hour, value: 23, to: nightStart) else { continue }
                let gap = abs(sample.date.timeIntervalSince(elevenPM))
                if gap <= 60 * 60 && gap < entry.gap {
                    entry.bedtime = sample.value
                    entry.gap = gap
                }
            }
            if sample.value < 70 { entry.low = true }
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
            let matching = nights.values.filter { entry in
                guard let bedtime = entry.bedtime,
                      entry.afterMidnight >= minimumReadingsPerNight else { return false }
                return bucket.range.contains(bedtime)
            }
            guard matching.count >= 5 else { return nil }
            let lows = matching.filter(\.low).count
            return BedtimeOutcome(label: bucket.label,
                                  lowRate: Double(lows) / Double(matching.count),
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
            default:     label = NSLocalizedString("Over 60 g", comment: "Meal size bucket")
            }
            guard let rise = riseAfter(meal.eaten, glucose: glucose, dates: dates) else { continue }
            buckets[label, default: []].append(rise)
        }

        return [NSLocalizedString("Under 30 g", comment: "Meal size bucket"),
                NSLocalizedString("30–60 g", comment: "Meal size bucket"),
                NSLocalizedString("Over 60 g", comment: "Meal size bucket")]
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
                                           meals: [(eaten: Date, delay: TimeInterval?)],
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
                let explained = meals.contains { $0.eaten >= quietFrom && $0.eaten <= deadline }
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
