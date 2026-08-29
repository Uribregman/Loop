//
//  StatsReportModel.swift
//  Loop
//
//  A neutral, presentation-free description of the statistics screen, built once
//  from `HistoryStatistics` and rendered by the exporters.
//
//  WHY THIS EXISTS. There are three renderings of the same numbers now: the live
//  SwiftUI screen, the PNG cards, and the HTML report. The PNG cards render the
//  REAL SCREEN (see `StatsShareRenderer`) precisely so a picture cannot drift
//  from what the user was looking at. HTML cannot do that — it is a different
//  medium with no SwiftUI in it — so it renders from THIS, and this file is the
//  single place where "what the report says" is decided.
//
//  ⚠️ THE RULE OF THIS SCREEN APPLIES HERE UNCHANGED: surface the evidence,
//  never compute a dose. Every row carries the number behind it. Nothing here
//  suggests a basal rate, carb ratio or correction factor. An export leaves the
//  phone and gets read by people who were not there when it was made — which
//  makes the caveats MORE load-bearing in this file, not less.
//

import Foundation

struct StatsReportModel {

    /// The chapters of the screen, in screen order.
    ///
    /// `id` is used as the HTML anchor and the PNG file name, so it is stable and
    /// URL-safe on purpose.
    enum SectionID: String, CaseIterable, Identifiable {
        case overview, progress, when, meals, safety, deeper, supplies, review
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return NSLocalizedString("Overview", comment: "Report section")
            case .progress: return NSLocalizedString("Progress", comment: "Report section")
            case .when:     return NSLocalizedString("When", comment: "Report section")
            case .meals:    return NSLocalizedString("Meals", comment: "Report section")
            case .safety:   return NSLocalizedString("Safety", comment: "Report section")
            case .deeper:   return NSLocalizedString("Going Deeper", comment: "Report section")
            case .supplies: return NSLocalizedString("Insulin & Supplies", comment: "Report section")
            case .review:   return NSLocalizedString("Settings Review", comment: "Report section")
            }
        }

        /// True for the chapters that deliberately span ALL history whatever the
        /// period picker says — therapy evidence must not move because someone
        /// tapped "7d".
        ///
        /// ⚠️ PROGRESS IS **NOT** ONE OF THEM, despite containing Compare
        /// Periods, which is. Week By Week and Day By Day do follow the picker,
        /// so badging the whole chapter "all history" would have mislabelled two
        /// tiles out of three. Compare Periods carries its own badge instead —
        /// the badge belongs to the tile that earns it, not to its neighbours.
        var ignoresPeriod: Bool { self == .review }

        /// True when the chapter contains a control with SEVERAL options —
        /// Compare Periods has a granularity and a metric, so a single flat
        /// picture would silently throw away seven of its eight views.
        ///
        /// These export as HTML, where the controls still work. This is the whole
        /// reason the share menu has two shapes rather than one.
        var needsInteractivity: Bool { self == .progress }
    }

    struct Row: Identifiable {
        let label: String
        let value: String
        /// Second value, for the two-column night/day table.
        var secondValue: String?
        var id: String { label + value + (secondValue ?? "") }
    }

    /// A band of the time-in-range distribution.
    struct Band: Identifiable {
        let id: String
        let name: String
        let range: String
        let fraction: Double
        /// Light-mode and dark-mode hex, matching `GlucoseBandColor` exactly.
        let lightHex: String
        let darkHex: String
    }

    /// One plotted column, carrying its own printed value.
    ///
    /// ⚠️ `display` IS NOT DECORATION. An exported chart cannot be scrubbed —
    /// there is no finger to put on a PNG or a saved web page — so every column
    /// prints its own number above it. A chart whose values can only be read by
    /// touching it becomes unreadable the moment it is shared, and a glucose
    /// chart nobody can read the numbers off is worse than a table.
    struct Column: Identifiable {
        let label: String
        let value: Double
        let display: String
        var detail: String?
        var id: String { label }
    }

    struct ColumnChart {
        let columns: [Column]
        /// Axis top. Nil means "take it from the data".
        var maximum: Double?
        /// Dashed reference line, e.g. the 70% goal.
        var goal: Double?
        var lightHex: String
        var darkHex: String
        var axisSuffix: String = ""
    }

    /// The hourly profile, carried whole so the renderer can draw the bands.
    struct Profile {
        let points: [HistoryStatistics.HourlyPoint]
        let lowTarget: Double
        let highTarget: Double
    }

    enum Chart {
        case bands([Band])
        case columns(ColumnChart)
        case profile(Profile)
        /// Horizontal magnitude bars — the post-meal comparison rows.
        case rows(ColumnChart)
    }

    struct Tile: Identifiable {
        let title: String
        var summary: String?
        var explanation: String?
        var rows: [Row] = []
        var bullets: [String] = []
        var chart: Chart?
        /// Small print that must travel with the numbers.
        var caveat: String?
        /// Column headings for a two-value table.
        var columnHeadings: (String, String)?
        var id: String { title }
    }

    struct Section: Identifiable {
        let id: SectionID
        var tiles: [Tile]
    }

    let periodTitle: String
    let periodLongTitle: String
    let rangeText: String?
    var sections: [Section]

    /// Every period the report can be filtered to, for the HTML picker.
    static let disclaimer = NSLocalizedString(
        "These are descriptions of data already recorded. They are not medical advice, they do not suggest settings, and no part of this report was produced by the dosing algorithm. Discuss any change with your care team.",
        comment: "Report disclaimer")
}

// MARK: - Building the model

extension StatsReportModel {

    /// Assemble the report for one period.
    ///
    /// - Parameters:
    ///   - comparison: period-by-period points for BOTH granularities. They span
    ///     all history and are deliberately independent of `period`.
    ///   - insights: the settings review, also all-history.
    static func build(stats: HistoryStatistics,
                      insights: TherapyInsights,
                      weeklyComparison: [HistoryStatistics.PeriodPoint],
                      monthlyComparison: [HistoryStatistics.PeriodPoint],
                      observations: [String],
                      periodTitle: String,
                      periodLongTitle: String) -> StatsReportModel {

        var sections: [Section] = []
        sections.append(Section(id: .overview, tiles: overviewTiles(stats, observations: observations)))
        let progress = progressTiles(stats, weekly: weeklyComparison, monthly: monthlyComparison)
        if !progress.isEmpty { sections.append(Section(id: .progress, tiles: progress)) }
        let when = whenTiles(stats)
        if !when.isEmpty { sections.append(Section(id: .when, tiles: when)) }
        let meals = mealTiles(stats)
        if !meals.isEmpty { sections.append(Section(id: .meals, tiles: meals)) }
        let safety = safetyTiles(stats)
        if !safety.isEmpty { sections.append(Section(id: .safety, tiles: safety)) }
        if stats.glucose.count >= 200 {
            sections.append(Section(id: .deeper, tiles: deeperTiles(stats)))
        }
        sections.append(Section(id: .supplies, tiles: supplyTiles(stats)))
        sections.append(Section(id: .review, tiles: reviewTiles(insights)))

        return StatsReportModel(periodTitle: periodTitle,
                                periodLongTitle: periodLongTitle,
                                rangeText: rangeText(stats),
                                sections: sections)
    }

    private static func rangeText(_ stats: HistoryStatistics) -> String? {
        guard let first = stats.firstDate, let last = stats.lastDate else { return nil }
        return "\(dayFormatter.string(from: first)) – \(dayFormatter.string(from: last))"
    }

    // MARK: Overview

    private static func overviewTiles(_ stats: HistoryStatistics, observations: [String]) -> [Tile] {
        let g = stats.glucose
        var tiles: [Tile] = []

        var headline = Tile(title: NSLocalizedString("Time In Range", comment: "Tile title"))
        headline.summary = String(format: NSLocalizedString("%1$@ in range over %2$d readings.", comment: "Overview summary"),
                                  percent(g.inRange), g.count)
        headline.chart = .bands(bands(g))
        headline.rows = bands(g).map {
            Row(label: "\($0.name) (\($0.range))", value: percent($0.fraction))
        }
        headline.caveat = String(format: NSLocalizedString("Sensor data covers %@ of the readings a 5-minute CGM would have produced over this period. Everything above is computed from what was actually received.", comment: "Coverage caveat"),
                                 percent(stats.coverage.fraction))
        tiles.append(headline)

        if !observations.isEmpty {
            var worth = Tile(title: NSLocalizedString("Worth Noticing", comment: "Tile title"))
            worth.bullets = observations
            worth.caveat = NSLocalizedString("These describe patterns in the data over the period shown. They are not medical advice and do not suggest settings.", comment: "Observations caveat")
            tiles.append(worth)
        }

        var key = Tile(title: NSLocalizedString("Key Numbers", comment: "Tile title"))
        key.rows = [
            Row(label: NSLocalizedString("Average glucose", comment: "Stat"), value: String(format: "%.0f mg/dL", g.mean)),
            Row(label: NSLocalizedString("Estimated A1c (GMI)", comment: "Stat"), value: String(format: "%.1f%%", g.gmi)),
            Row(label: NSLocalizedString("Variability (CV)", comment: "Stat"), value: String(format: "%.0f%% · goal under 36%%", g.coefficientOfVariation)),
            Row(label: NSLocalizedString("Tight range (80–140)", comment: "Stat"), value: percent(g.inTightRange)),
            Row(label: NSLocalizedString("Sensor data received", comment: "Stat"), value: percent(stats.coverage.fraction))
        ]
        if let rise = stats.dawn.averageRise, stats.dawn.daysMeasured >= 5 {
            key.rows.append(Row(label: NSLocalizedString("Dawn rise (3am → 8am)", comment: "Stat"),
                                value: String(format: "%@%.0f mg/dL", rise >= 0 ? "+" : "", rise)))
        }
        tiles.append(key)
        return tiles
    }

    static func bands(_ g: HistoryStatistics.Glucose) -> [Band] {
        [
            Band(id: "veryLow", name: NSLocalizedString("Very Low", comment: "TIR band"),
                 range: NSLocalizedString("< 54", comment: "TIR band range"),
                 fraction: g.veryLow, lightHex: "#7B4DD8", darkHex: "#9B6BFF"),
            Band(id: "low", name: NSLocalizedString("Low", comment: "TIR band"),
                 range: NSLocalizedString("54–69", comment: "TIR band range"),
                 fraction: g.low, lightHex: "#B01B2E", darkHex: "#D93A50"),
            Band(id: "inRange", name: NSLocalizedString("In Range", comment: "TIR band"),
                 range: NSLocalizedString("70–180", comment: "TIR band range"),
                 fraction: g.inRange, lightHex: "#2FA84F", darkHex: "#34C759"),
            Band(id: "high", name: NSLocalizedString("High", comment: "TIR band"),
                 range: NSLocalizedString("181–250", comment: "TIR band range"),
                 fraction: g.high, lightHex: "#FFD426", darkHex: "#FFDA47"),
            Band(id: "veryHigh", name: NSLocalizedString("Very High", comment: "TIR band"),
                 range: NSLocalizedString("> 250", comment: "TIR band range"),
                 fraction: g.veryHigh, lightHex: "#F07B20", darkHex: "#FF8A2B")
        ]
    }

    // MARK: Progress

    private static func progressTiles(_ stats: HistoryStatistics,
                                      weekly: [HistoryStatistics.PeriodPoint],
                                      monthly: [HistoryStatistics.PeriodPoint]) -> [Tile] {
        var tiles: [Tile] = []

        if stats.weeklyTrend.count >= 2 {
            var tile = Tile(title: NSLocalizedString("Week By Week", comment: "Tile title"))
            tile.explanation = NSLocalizedString("Time in range for each week. A single number tells you where you are; this tells you which way you are going.", comment: "Weekly trend explanation")
            tile.chart = .columns(ColumnChart(
                columns: stats.weeklyTrend.map {
                    Column(label: weekFormatter.string(from: $0.weekStart),
                           value: $0.inRange * 100,
                           display: percent($0.inRange),
                           detail: String(format: NSLocalizedString("%d days", comment: "Day count"), $0.days))
                },
                maximum: 100, goal: 70,
                lightHex: "#2FA84F", darkHex: "#34C759", axisSuffix: "%"))
            tiles.append(tile)
        }

        if stats.days.counted >= 3 {
            var tile = Tile(title: NSLocalizedString("Day By Day", comment: "Tile title"))
            tile.summary = String(format: NSLocalizedString("%1$d of %2$d days hit 70%% in range.", comment: "Days meeting goal"),
                                  stats.days.meetingGoal, stats.days.counted)
            if stats.days.bestStreak >= 2 {
                tile.rows.append(Row(label: NSLocalizedString("Best streak", comment: "Stat"),
                                     value: String(format: NSLocalizedString("%d days", comment: "Day count"), stats.days.bestStreak)))
            }
            // ⚠️ Both or neither. Each is nil below three days of that kind, and
            // showing one side alone invites the reader to supply the comparison
            // themselves from a number that was withheld for being too thin.
            if let weekday = stats.days.weekdayInRange, let weekend = stats.days.weekendInRange {
                tile.rows.append(Row(label: NSLocalizedString("Weekdays (Sun–Thu)", comment: "Stat"),
                                     value: String(format: NSLocalizedString("%1$@ · %2$d days", comment: "Stat with day count"),
                                                   percent(weekday), stats.days.weekdayCount)))
                tile.rows.append(Row(label: NSLocalizedString("Weekends (Fri–Sat)", comment: "Stat"),
                                     value: String(format: NSLocalizedString("%1$@ · %2$d days", comment: "Stat with day count"),
                                                   percent(weekend), stats.days.weekendCount)))
            }
            tile.caveat = NSLocalizedString("Only days with a reasonable amount of sensor data are counted.", comment: "Days caveat")
            tiles.append(tile)
        }
        return tiles
    }

    /// Columns for the Compare Periods chart, for ONE granularity and metric.
    ///
    /// Exposed because the HTML report builds all eight combinations up front:
    /// the picker in the exported page switches between pre-rendered charts
    /// rather than recomputing anything, so a saved page keeps working with no
    /// data and no network.
    static func comparisonColumns(_ points: [HistoryStatistics.PeriodPoint],
                                  metric: ComparisonMetric) -> ColumnChart {
        ColumnChart(columns: points.map { point in
            Column(label: comparisonLabel(point),
                   value: metric.value(point),
                   display: metric.formatted(point),
                   detail: String(format: NSLocalizedString("%1$d days · %2$d readings", comment: "Period evidence"),
                                  point.days, point.readings))
        },
                    maximum: metric.axisMaximum,
                    goal: metric == .timeInRange ? 70 : nil,
                    lightHex: metric.lightHex, darkHex: metric.darkHex,
                    axisSuffix: metric.axisSuffix)
    }

    /// Mirrors `HistoryStatisticsView.ComparisonMetric` so the HTML report can be
    /// built without the view. Kept deliberately small: four metrics, each one
    /// already computed on `PeriodPoint`.
    enum ComparisonMetric: String, CaseIterable, Identifiable {
        case timeInRange, average, variability, belowRange
        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeInRange: return NSLocalizedString("In Range", comment: "Comparison metric")
            case .average:     return NSLocalizedString("Average", comment: "Comparison metric")
            case .variability: return NSLocalizedString("Variability", comment: "Comparison metric")
            case .belowRange:  return NSLocalizedString("Below Range", comment: "Comparison metric")
            }
        }

        func value(_ p: HistoryStatistics.PeriodPoint) -> Double {
            switch self {
            case .timeInRange: return p.inRange * 100
            case .average:     return p.mean
            case .variability: return p.coefficientOfVariation
            case .belowRange:  return p.below * 100
            }
        }

        func formatted(_ p: HistoryStatistics.PeriodPoint) -> String {
            switch self {
            case .average: return String(format: "%.0f mg/dL", value(p))
            default:       return String(format: "%.0f%%", value(p))
            }
        }

        var axisSuffix: String { self == .average ? " mg/dL" : "%" }
        var axisMaximum: Double? { self == .timeInRange ? 100 : nil }
        var lightHex: String {
            switch self {
            case .timeInRange: return "#2FA84F"
            case .average:     return "#3A7BD5"
            case .variability: return "#F07B20"
            case .belowRange:  return "#B01B2E"
            }
        }
        var darkHex: String {
            switch self {
            case .timeInRange: return "#34C759"
            case .average:     return "#5E9BEA"
            case .variability: return "#FF8A2B"
            case .belowRange:  return "#D93A50"
            }
        }
    }

    static func comparisonLabel(_ point: HistoryStatistics.PeriodPoint) -> String {
        switch point.granularity {
        case .week:  return weekFormatter.string(from: point.start)
        case .month: return monthFormatter.string(from: point.start)
        }
    }

    // MARK: When

    private static func whenTiles(_ stats: HistoryStatistics) -> [Tile] {
        var tiles: [Tile] = []

        if stats.hourlyProfile.count >= 6 {
            var tile = Tile(title: NSLocalizedString("Through The Day", comment: "Tile title"))
            if let worst = stats.worstHour {
                tile.summary = String(format: NSLocalizedString("Highest around %1$@, typically %2$.0f mg/dL.", comment: "Hourly summary"),
                                      hourLabel(worst.hour), worst.median)
            }
            tile.explanation = NSLocalizedString("The line is the typical glucose at each hour, and each day counts once: the bands show how much that hour varies BETWEEN days over this period. A narrow band is predictable; a wide one means the hour is a coin toss. Hours with fewer than three days of data are left out rather than guessed at.", comment: "AGP explanation")
            tile.chart = .profile(Profile(points: stats.hourlyProfile.sorted { $0.hour < $1.hour },
                                          lowTarget: 70, highTarget: 180))
            tiles.append(tile)
        }

        if stats.weekdayProfile.count >= 4 {
            var tile = Tile(title: NSLocalizedString("Day Of The Week", comment: "Tile title"))
            tile.explanation = NSLocalizedString("Time in range by weekday. Routine shows up here — a day that repeatedly goes worse is usually about what happens on that day.", comment: "Weekday explanation")
            tile.chart = .columns(ColumnChart(
                columns: stats.weekdayProfile.map {
                    Column(label: weekdayName($0.weekday),
                           value: $0.inRange * 100,
                           display: percent($0.inRange),
                           detail: String(format: NSLocalizedString("%d days", comment: "Day count"), $0.days))
                },
                maximum: 100, goal: 70,
                lightHex: "#2FA84F", darkHex: "#34C759", axisSuffix: "%"))
            tiles.append(tile)
        }

        let dn = stats.dayNight
        if dn.overnightMean != nil || dn.daytimeMean != nil {
            var tile = Tile(title: NSLocalizedString("Day vs Night", comment: "Tile title"))
            tile.explanation = NSLocalizedString("Every figure here is averaged across all the nights and days in the period shown — not a single day. Two periods can share an average and still be different problems.", comment: "Day vs night explanation")
            tile.columnHeadings = (NSLocalizedString("Night", comment: "Column header"),
                                   NSLocalizedString("Day", comment: "Column header"))
            func row(_ label: String, _ night: String?, _ day: String?) -> Row {
                Row(label: label, value: night ?? "—", secondValue: day ?? "—")
            }
            tile.rows = [
                row(NSLocalizedString("In range", comment: "Stat"), dn.overnightInRange.map(percent), dn.daytimeInRange.map(percent)),
                row(NSLocalizedString("Below 70", comment: "Stat"), dn.overnightBelow.map(percent), dn.daytimeBelow.map(percent)),
                row(NSLocalizedString("Above 180", comment: "Stat"), dn.overnightAbove.map(percent), dn.daytimeAbove.map(percent)),
                row(NSLocalizedString("Average", comment: "Stat"), dn.overnightMean.map { String(format: "%.0f", $0) }, dn.daytimeMean.map { String(format: "%.0f", $0) }),
                row(NSLocalizedString("Variability", comment: "Stat"), dn.overnightCV.map { String(format: "%.0f%%", $0) }, dn.daytimeCV.map { String(format: "%.0f%%", $0) }),
                row(NSLocalizedString("Typical low point", comment: "Stat"), dn.overnightMinimum.map { String(format: "%.0f", $0) }, dn.daytimeMinimum.map { String(format: "%.0f", $0) }),
                row(NSLocalizedString("Typical high point", comment: "Stat"), dn.overnightMaximum.map { String(format: "%.0f", $0) }, dn.daytimeMaximum.map { String(format: "%.0f", $0) })
            ]
            tile.caveat = NSLocalizedString("The last two rows average each day's own lowest and highest reading across the period — not the single most extreme value ever recorded.", comment: "Extremes note")
            tiles.append(tile)
        }
        return tiles
    }

    // MARK: Meals

    private static func mealTiles(_ stats: HistoryStatistics) -> [Tile] {
        var tiles: [Tile] = []
        let pm = stats.postMeal

        if pm.mealsAnalysed >= 3 {
            var tile = Tile(title: NSLocalizedString("After Meals", comment: "Tile title"))
            if let rise = pm.averageRise {
                tile.summary = String(format: NSLocalizedString("Typical peak rise +%1$.0f mg/dL in the 3 hours after eating, across %2$d meals.", comment: "Post-meal summary"),
                                      rise, pm.mealsAnalysed)
            }
            if let peak = pm.medianTimeToPeak {
                tile.rows.append(Row(label: NSLocalizedString("Typically peaks after", comment: "Stat"), value: minutes(peak)))
            }
            if let back = pm.medianTimeToReturn {
                tile.rows.append(Row(label: NSLocalizedString("Back under 180 after", comment: "Stat"), value: minutes(back)))
            }
            if let prompt = pm.promptRise, let late = pm.lateRise {
                tile.chart = .rows(ColumnChart(columns: [
                    Column(label: NSLocalizedString("Logged within 15 min", comment: "Prompt meals"),
                           value: prompt, display: String(format: "+%.0f mg/dL", prompt),
                           detail: String(format: NSLocalizedString("%d meals", comment: "Meal count"), pm.promptCount)),
                    Column(label: NSLocalizedString("Logged later than that", comment: "Late meals"),
                           value: late, display: String(format: "+%.0f mg/dL", late),
                           detail: String(format: NSLocalizedString("%d meals", comment: "Meal count"), pm.lateCount))
                ], maximum: nil, goal: nil, lightHex: "#3A7BD5", darkHex: "#5E9BEA", axisSuffix: " mg/dL"))
                tile.caveat = NSLocalizedString("Both are the same meals — the difference is only when they were logged.", comment: "Prompt vs late caveat")
            }
            tiles.append(tile)
        }

        if !stats.mealSizeOutcomes.isEmpty {
            var tile = Tile(title: NSLocalizedString("By Meal Size", comment: "Tile title"))
            tile.chart = .rows(ColumnChart(columns: stats.mealSizeOutcomes.map {
                Column(label: $0.label, value: $0.averageRise,
                       display: String(format: "+%.0f mg/dL", $0.averageRise),
                       detail: String(format: NSLocalizedString("%d meals", comment: "Meal count"), $0.count))
            }, maximum: nil, goal: nil, lightHex: "#3A7BD5", darkHex: "#5E9BEA", axisSuffix: " mg/dL"))
            tiles.append(tile)
        }

        if !stats.mealWindows.isEmpty {
            var tile = Tile(title: NSLocalizedString("Which Meal", comment: "Tile title"))
            tile.explanation = NSLocalizedString("Average rise after each meal of the day. Breakfast often behaves differently from the rest — an all-meals average hides exactly that.", comment: "Meal windows explanation")
            tile.chart = .rows(ColumnChart(columns: stats.mealWindows.map {
                Column(label: $0.name, value: $0.averageRise,
                       display: String(format: "+%.0f mg/dL", $0.averageRise),
                       detail: String(format: NSLocalizedString("%d meals", comment: "Meal count"), $0.count))
            }, maximum: nil, goal: nil, lightHex: "#3A7BD5", darkHex: "#5E9BEA", axisSuffix: " mg/dL"))
            tiles.append(tile)
        }
        return tiles
    }

    // MARK: Safety

    private static func safetyTiles(_ stats: HistoryStatistics) -> [Tile] {
        guard stats.lowEvents.count > 0 || stats.nights.total > 0 else { return [] }
        var tiles: [Tile] = []

        var tile = Tile(title: NSLocalizedString("Lows", comment: "Tile title"))
        tile.summary = String(format: NSLocalizedString("%d low events.", comment: "Low events summary"), stats.lowEvents.count)
        if stats.lowEvents.level2Count > 0 {
            tile.rows.append(Row(label: NSLocalizedString("Serious (under 54)", comment: "Stat"), value: "\(stats.lowEvents.level2Count)"))
        }
        if let duration = stats.lowEvents.averageDuration {
            tile.rows.append(Row(label: NSLocalizedString("Typical length", comment: "Stat"), value: minutes(duration)))
        }
        if stats.lowEvents.perWeek > 0 {
            tile.rows.append(Row(label: NSLocalizedString("Per week", comment: "Stat"), value: String(format: "%.1f", stats.lowEvents.perWeek)))
        }
        if stats.nights.total > 0 {
            tile.rows.append(Row(label: NSLocalizedString("Nights with a low", comment: "Stat"),
                                 value: String(format: NSLocalizedString("%1$d of %2$d", comment: "x of y"), stats.nights.withLow, stats.nights.total)))
        }
        if stats.highEvents.count > 0 {
            tile.rows.append(Row(label: NSLocalizedString("Highs over 250", comment: "Stat"), value: "\(stats.highEvents.count)"))
            if let duration = stats.highEvents.averageDuration {
                tile.rows.append(Row(label: NSLocalizedString("Typical length of a high", comment: "Stat"), value: minutes(duration)))
            }
        }
        tile.caveat = NSLocalizedString("Counted the way the CGM consensus defines an event: at least 15 minutes past the threshold to start one, and 15 minutes back to end it — so a single stray reading is not a low.", comment: "Event definition")
        tiles.append(tile)

        if !stats.bedtimeOutcomes.isEmpty {
            var bedtime = Tile(title: NSLocalizedString("Bedtime & Overnight", comment: "Tile title"))
            bedtime.explanation = NSLocalizedString("How often a night went low, grouped by the glucose you went to bed on.", comment: "Bedtime explanation")
            bedtime.rows = stats.bedtimeOutcomes.map {
                Row(label: $0.label,
                    value: String(format: NSLocalizedString("%1$@ of %2$d nights", comment: "Low rate and night count"),
                                  percent($0.lowRate), $0.nights))
            }
            bedtime.caveat = NSLocalizedString("This describes nights already recorded. It is not a target to aim for — that conversation belongs with your care team.", comment: "Bedtime caveat")
            tiles.append(bedtime)
        }
        return tiles
    }

    // MARK: Going deeper

    private static func deeperTiles(_ stats: HistoryStatistics) -> [Tile] {
        var tiles: [Tile] = []
        let risk = stats.risk

        var tile = Tile(title: NSLocalizedString("Risk Indices", comment: "Tile title"))
        tile.explanation = NSLocalizedString("Published measures that weight readings by how dangerous they are, rather than counting them equally — 50 mg/dL is far worse than twice as bad as 65.", comment: "Risk explanation")
        if let gri = risk.gri {
            tile.summary = String(format: NSLocalizedString("GRI %1$.0f — %2$@.", comment: "GRI summary"), gri, griZone(gri))
            if let hypo = risk.griHypoComponent, let hyper = risk.griHyperComponent {
                tile.rows.append(Row(label: NSLocalizedString("Driven by", comment: "Stat"),
                                     value: String(format: NSLocalizedString("lows %1$.0f · highs %2$.0f", comment: "GRI components"), hypo, hyper)))
            }
        }
        tile.rows.append(Row(label: NSLocalizedString("Low risk (LBGI)", comment: "Stat"),
                             value: String(format: "%.1f · %@", risk.lbgi,
                                           band(risk.lbgi, [(1.1, "minimal"), (2.5, "low"), (5.0, "moderate")], "high"))))
        tile.rows.append(Row(label: NSLocalizedString("High risk (HBGI)", comment: "Stat"),
                             value: String(format: "%.1f · %@", risk.hbgi,
                                           band(risk.hbgi, [(4.5, "low"), (9.0, "moderate")], "high"))))
        if let adrr = risk.adrr {
            tile.rows.append(Row(label: NSLocalizedString("Daily swing (ADRR)", comment: "Stat"),
                                 value: String(format: "%.1f · %@", adrr,
                                               band(adrr, [(20, "low"), (40, "moderate")], "high"))))
        }
        tile.caveat = NSLocalizedString("Categories are the conventional published bands, not a judgement about you.", comment: "Risk caveat")
        tiles.append(tile)

        var stability = Tile(title: NSLocalizedString("Stability", comment: "Tile title"))
        if let modd = risk.modd {
            stability.rows.append(Row(label: NSLocalizedString("Day-to-day repeatability (MODD)", comment: "Stat"), value: String(format: "%.0f mg/dL", modd)))
        }
        if let mage = risk.mage {
            stability.rows.append(Row(label: NSLocalizedString("Swing size (MAGE)", comment: "Stat"), value: String(format: "%.0f mg/dL", mage)))
        }
        if let conga = risk.conga2 {
            stability.rows.append(Row(label: NSLocalizedString("2-hour instability (CONGA)", comment: "Stat"), value: String(format: "%.0f mg/dL", conga)))
        }
        if let rebound = stats.recovery.lowsFollowedByHigh {
            stability.rows.append(Row(label: String(format: NSLocalizedString("Lows chased by a high (of %d)", comment: "Stat"), stats.recovery.lowsAnalysed),
                                      value: percent(rebound)))
        }
        if let recoveryTime = stats.recovery.medianHighRecovery {
            stability.rows.append(Row(label: String(format: NSLocalizedString("Recovery from a high (of %d)", comment: "Stat"), stats.recovery.highExcursions),
                                      value: minutes(recoveryTime)))
        }
        if !stability.rows.isEmpty { tiles.append(stability) }
        return tiles
    }

    private static func band(_ value: Double, _ bands: [(Double, String)], _ above: String) -> String {
        bands.first { value < $0.0 }?.1 ?? above
    }

    static func griZone(_ gri: Double) -> String {
        switch gri {
        case ..<20:  return NSLocalizedString("best zone", comment: "GRI zone")
        case ..<40:  return NSLocalizedString("2nd zone", comment: "GRI zone")
        case ..<60:  return NSLocalizedString("3rd zone", comment: "GRI zone")
        case ..<80:  return NSLocalizedString("4th zone", comment: "GRI zone")
        default:     return NSLocalizedString("worst zone", comment: "GRI zone")
        }
    }

    // MARK: Supplies

    private static func supplyTiles(_ stats: HistoryStatistics) -> [Tile] {
        var tiles: [Tile] = []

        var activity = Tile(title: NSLocalizedString("How Hard Loop Is Working", comment: "Tile title"))
        activity.explanation = NSLocalizedString("How often the algorithm steps in, and how far it moves from the programmed basal.", comment: "Loop activity explanation")
        activity.rows = [
            Row(label: NSLocalizedString("Automatic doses per day", comment: "Stat"), value: String(format: "%.1f", stats.loopActivity.automaticDosesPerDay)),
            Row(label: NSLocalizedString("Your own boluses per day", comment: "Stat"), value: String(format: "%.1f", stats.loopActivity.manualBolusesPerDay)),
            Row(label: NSLocalizedString("Basal delivered per day", comment: "Stat"), value: String(format: "%.1f U", stats.loopActivity.deliveredBasalPerDay))
        ]
        if let scheduled = stats.loopActivity.scheduledBasalPerDay {
            activity.rows.append(Row(label: NSLocalizedString("Programmed basal", comment: "Stat"), value: String(format: "%.1f U", scheduled)))
            if let ratio = stats.loopActivity.basalRatio {
                activity.rows.append(Row(label: NSLocalizedString("Delivered vs programmed", comment: "Stat"), value: String(format: "%.0f%%", ratio * 100)))
            }
        }
        if stats.missedBolus.count > 0 {
            activity.rows.append(Row(label: NSLocalizedString("Unexplained rises", comment: "Stat"), value: "\(stats.missedBolus.count)"))
            activity.caveat = NSLocalizedString("Climbs of 60 mg/dL or more within 90 minutes with no carbs or bolus logged nearby — usually a meal that was not recorded.", comment: "Missed bolus explanation")
        }
        tiles.append(activity)

        var supply = Tile(title: NSLocalizedString("Insulin, Carbs & Supplies", comment: "Tile title"))
        supply.rows = [
            Row(label: NSLocalizedString("Insulin per day", comment: "Stat"), value: String(format: "%.1f U", stats.insulin.dailyAverage)),
            Row(label: NSLocalizedString("Given as bolus", comment: "Stat"), value: String(format: "%.0f%%", stats.insulin.bolusShare * 100)),
            Row(label: NSLocalizedString("Insulin Loop gave itself", comment: "Stat"),
                value: String(format: "%.0f%%", stats.insulin.totalUnits > 0 ? stats.insulin.automaticUnits / stats.insulin.totalUnits * 100 : 0)),
            Row(label: NSLocalizedString("Carbs per day", comment: "Stat"), value: String(format: "%.0f g", stats.meals.dailyAverageGrams)),
            Row(label: NSLocalizedString("Meals per day", comment: "Stat"), value: String(format: "%.1f", stats.mealsPerDay)),
            Row(label: NSLocalizedString("Carbs per meal", comment: "Stat"), value: String(format: "%.0f g", stats.gramsPerMeal))
        ]
        if let delay = stats.meals.medianLoggingDelay {
            supply.rows.append(Row(label: NSLocalizedString("Typical logging delay", comment: "Stat"), value: minutes(delay)))
        }
        if stats.sensorGaps.count > 0 {
            supply.rows.append(Row(label: NSLocalizedString("Sensor gaps", comment: "Stat"), value: "\(stats.sensorGaps.count)"))
            if let longest = stats.sensorGaps.longest {
                supply.rows.append(Row(label: NSLocalizedString("Longest gap", comment: "Stat"), value: minutes(longest)))
            }
        }
        if stats.pods.count > 0 {
            supply.rows.append(Row(label: NSLocalizedString("Pod sessions", comment: "Stat"), value: "\(stats.pods.count)"))
            supply.rows.append(Row(label: NSLocalizedString("Average pod life", comment: "Stat"), value: String(format: "%.0f h", stats.pods.meanHours)))
            supply.rows.append(Row(label: NSLocalizedString("Insulin discarded", comment: "Stat"), value: String(format: "%.0f U", stats.pods.wastedUnits)))
        }
        tiles.append(supply)
        return tiles
    }

    // MARK: Settings review

    private static func reviewTiles(_ insights: TherapyInsights) -> [Tile] {
        var tile = Tile(title: NSLocalizedString("Settings Review", comment: "Tile title"))
        tile.explanation = String(format: NSLocalizedString("Computed from ALL history, not the selected period — evidence about therapy settings must not move because a shorter window was picked. Based on %1$d clean fasting nights and %2$d eligible meals.", comment: "Review explanation"),
                                  insights.cleanNightCount, insights.cleanMealCount)

        for window in insights.basalWindows {
            let verdict: String
            switch window.verdict {
            case .steady:  verdict = NSLocalizedString("steady", comment: "Basal verdict")
            case .rising:  verdict = NSLocalizedString("rising", comment: "Basal verdict")
            case .falling: verdict = NSLocalizedString("falling", comment: "Basal verdict")
            }
            tile.rows.append(Row(
                label: String(format: NSLocalizedString("Overnight %1$02d:00–%2$02d:00", comment: "Basal window"),
                              window.startHour, window.endHour),
                value: String(format: NSLocalizedString("%1$@ · median %2$@%3$.0f mg/dL over %4$d nights", comment: "Basal window value"),
                              verdict, window.medianDrift >= 0 ? "+" : "", window.medianDrift, window.cleanNights)))
        }

        if let sensitivity = insights.sensitivity {
            var value = String(format: NSLocalizedString("observed %.0f mg/dL per unit", comment: "ISF observed"), sensitivity.observed)
            if let current = sensitivity.current {
                value += String(format: NSLocalizedString(" · currently set to %.0f", comment: "ISF current"), current)
            }
            value += String(format: NSLocalizedString(" · %d corrections", comment: "Evidence"), sensitivity.evidence.samples)
            tile.rows.append(Row(label: NSLocalizedString("Correction factor", comment: "Stat"), value: value))
        }

        if let ratio = insights.carbRatio {
            var value = String(format: NSLocalizedString("observed %.1f g per unit", comment: "Ratio observed"), ratio.observed)
            if let current = ratio.current {
                value += String(format: NSLocalizedString(" · currently set to %.1f", comment: "Ratio current"), current)
            }
            value += String(format: NSLocalizedString(" · %1$d meals over %2$d days", comment: "Evidence"),
                            ratio.evidence.samples, ratio.daysSpanned)
            tile.rows.append(Row(label: NSLocalizedString("Carb ratio", comment: "Stat"), value: value))
        }

        if tile.rows.isEmpty {
            tile.summary = NSLocalizedString("Not enough clean evidence yet to say anything about settings.", comment: "Review empty state")
        }
        // ⚠️ NOT OPTIONAL, AND NOT SOFTENED. This section is the one that most
        // looks like a recommendation, so it is the one that most needs saying
        // plainly that it is not.
        tile.caveat = NSLocalizedString("These are observations of what already happened, not settings to enter. Nothing here was produced by the dosing algorithm, and no number here should be typed into therapy settings without your care team.", comment: "Review caveat")
        return [tile]
    }

    // MARK: Formatting

    static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }

    static func minutes(_ interval: TimeInterval) -> String {
        let total = Int(interval / 60)
        if total < 60 { return String(format: NSLocalizedString("%d min", comment: "Minutes"), total) }
        return String(format: NSLocalizedString("%1$d h %2$d min", comment: "Hours and minutes"), total / 60, total % 60)
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        guard let date = Calendar.current.date(from: components) else { return "\(hour):00" }
        return formatter.string(from: date).lowercased()
    }

    static func weekdayName(_ weekday: Int) -> String {
        let symbols = DateFormatter().shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return symbols[max(0, min(symbols.count - 1, weekday - 1))]
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    static let weekFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f
    }()

    static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM yyyy"); return f
    }()
}
