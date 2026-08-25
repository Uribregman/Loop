//
//  GlucoseRiskMetrics.swift
//  Loop
//
//  The established glycemic-variability and risk indices, computed from the
//  history log. Pure maths on an array of readings — no Loop state, no dosing.
//
//  These are PUBLISHED metrics, implemented to their published definitions
//  rather than invented here. Each carries its source so the numbers can be
//  checked against the literature instead of trusted because an app printed
//  them:
//
//   • LBGI / HBGI — Kovatchev et al., symmetrised risk function on mg/dL.
//   • ADRR        — Kovatchev et al. 2006, average daily risk range.
//   • MAGE        — Service et al. 1970, mean amplitude of glycemic excursions.
//   • CONGA(n)    — McDonnell et al. 2005, continuous overall net glycemic action.
//   • MODD        — Molnar et al. 1972, mean of daily differences.
//   • J-index     — Wojcicki 1995.
//
//  All of them describe what happened. None of them implies a dose.
//

import Foundation

struct GlucoseRiskMetrics {

    /// Readings a day needs before it can contribute a daily risk range.
    /// 72 is six hours at five-minute spacing — the same floor the statistics
    /// use to decide whether a day counts as a day.
    static let minimumReadingsPerADRRDay = 72

    /// Low Blood Glucose Index — weighted burden of hypoglycemia. Weighted rather
    /// than a plain count because the risk function is asymmetric: 50 mg/dL is far
    /// more than "twice as bad" as 65.
    ///
    /// Conventional bands: < 1.1 minimal, 1.1–2.5 low, 2.5–5 moderate, > 5 high.
    var lbgi: Double = 0

    /// High Blood Glucose Index — the same idea for hyperglycemia.
    /// Bands: < 4.5 low, 4.5–9 moderate, > 9 high.
    var hbgi: Double = 0

    /// Average Daily Risk Range — each day's worst low risk plus worst high risk,
    /// averaged over days. Captures days that swing to BOTH extremes, which the
    /// separate indices can miss.
    /// Bands: < 20 low, 20–40 moderate, > 40 high.
    var adrr: Double?

    /// Mean Amplitude of Glycemic Excursions — the average size of the swings
    /// that are big enough to matter (bigger than one standard deviation).
    /// A high MAGE with a decent average means the average is hiding a rollercoaster.
    var mage: Double?

    /// CONGA(2) — the SD of the change over every 2-hour gap. Within-day
    /// instability: how different is now from two hours ago, typically.
    var conga2: Double?

    /// Mean Of Daily Differences — the typical gap between the same clock time on
    /// consecutive days. This is the day-to-day REPRODUCIBILITY number: low MODD
    /// means your days look alike, which is what makes anything predictable.
    var modd: Double?

    /// J-index — combines level and variability into one figure.
    /// Roughly: < 20 good, 20–30 fair, > 30 poor.
    var jIndex: Double?

    /// Glycemia Risk Index (Klonoff et al. 2022) — 0 to 100, lower is better.
    ///
    /// A single composite built from the time-in-range bands, weighting the
    /// dangerous ends harder:
    ///
    ///   hypo  = VLow + 0.8·Low
    ///   hyper = VHigh + 0.5·High
    ///   GRI   = 3.0·hypo + 1.6·hyper      (equivalently
    ///           3.0·VLow + 2.4·Low + 1.6·VHigh + 0.8·High), capped at 100
    ///
    /// Worth having because it tracked experienced clinicians' own ranking of
    /// CGM traces better than time in range did — it is closer to how a
    /// specialist reads a trace at a glance than any single band is.
    var gri: Double?
    /// The two halves, which are more useful than the total: they say WHICH end
    /// is driving the score, and those need opposite responses.
    var griHypoComponent: Double?
    var griHyperComponent: Double?

    // MARK: - Computation

    /// - Parameter glucose: readings in mg/dL, sorted ascending by date.
    static func compute(from glucose: [(date: Date, value: Double)],
                        mean: Double,
                        standardDeviation: Double,
                        calendar: Calendar = .current) -> GlucoseRiskMetrics {
        var metrics = GlucoseRiskMetrics()
        guard glucose.count >= 2 else { return metrics }

        // MARK: LBGI / HBGI / ADRR
        var lowRisks: [Double] = []
        var highRisks: [Double] = []
        var dailyLowPeak: [Date: Double] = [:]
        var dailyHighPeak: [Date: Double] = [:]

        var readingsPerDay: [Date: Int] = [:]

        for sample in glucose {
            // The risk function is only defined for plausible readings; a
            // non-positive value would blow up the logarithm.
            guard sample.value > 0 else { continue }
            let (low, high) = riskComponents(sample.value)
            lowRisks.append(low)
            highRisks.append(high)

            let day = calendar.startOfDay(for: sample.date)
            readingsPerDay[day, default: 0] += 1
            dailyLowPeak[day] = max(dailyLowPeak[day] ?? 0, low)
            dailyHighPeak[day] = max(dailyHighPeak[day] ?? 0, high)
        }

        if !lowRisks.isEmpty {
            metrics.lbgi = lowRisks.reduce(0, +) / Double(lowRisks.count)
            metrics.hbgi = highRisks.reduce(0, +) / Double(highRisks.count)
        }

        // ADRR needs whole days to be meaningful — it is an average of DAILY
        // risk ranges, so a day with a handful of readings is not a data point,
        // it is a day that pulls the average down. (A single stray reading on
        // an otherwise empty day was doing exactly that.)
        let adrrDays = dailyLowPeak.keys.filter {
            dailyHighPeak[$0] != nil && (readingsPerDay[$0] ?? 0) >= minimumReadingsPerADRRDay
        }
        if adrrDays.count >= 3 {
            let total = adrrDays.reduce(0.0) { sum, day in
                sum + (dailyLowPeak[day] ?? 0) + (dailyHighPeak[day] ?? 0)
            }
            metrics.adrr = total / Double(adrrDays.count)
        }

        metrics.mage = meanAmplitudeOfExcursions(glucose.map(\.value),
                                                 standardDeviation: standardDeviation)
        metrics.conga2 = conga(glucose, hours: 2)
        metrics.modd = meanOfDailyDifferences(glucose, calendar: calendar)

        if mean > 0 {
            // J-index is defined on mmol/L in some papers and mg/dL in others;
            // this is the mg/dL form.
            metrics.jIndex = 0.001 * pow(mean + standardDeviation, 2)
        }

        return metrics
    }

    /// GRI from the band fractions (0...1 each, as `HistoryStatistics.Glucose`
    /// stores them). Returns nil when there are no readings to speak of.
    static func glycemiaRiskIndex(veryLow: Double, low: Double,
                                  high: Double, veryHigh: Double)
    -> (gri: Double, hypo: Double, hyper: Double) {
        // The published coefficients are defined on PERCENTAGES, not fractions.
        let vLow = veryLow * 100
        let l = low * 100
        let h = high * 100
        let vHigh = veryHigh * 100

        let hypo = vLow + 0.8 * l
        let hyper = vHigh + 0.5 * h
        let gri = min(100, 3.0 * hypo + 1.6 * hyper)
        return (gri, hypo, hyper)
    }

    /// Kovatchev's symmetrising transform, then the risk value, split into its
    /// low and high halves. Only one of the two is ever non-zero for a reading.
    private static func riskComponents(_ mgdl: Double) -> (low: Double, high: Double) {
        // Clamped to the range the transform was defined over; outside it the
        // curve stops being meaningful and starts producing nonsense.
        let clamped = min(max(mgdl, 20), 600)
        let f = 1.509 * (pow(log(clamped), 1.084) - 5.381)
        let risk = 10 * f * f
        return f < 0 ? (risk, 0) : (0, risk)
    }

    /// MAGE: average amplitude of the peak-to-nadir swings larger than 1 SD.
    ///
    /// Turning points are found first, then only the excursions that exceed one
    /// standard deviation are averaged — that threshold is the whole point of the
    /// metric, separating real swings from sensor noise.
    private static func meanAmplitudeOfExcursions(_ values: [Double],
                                                  standardDeviation: Double) -> Double? {
        guard values.count >= 3, standardDeviation > 0 else { return nil }

        // Local minima and maxima, keeping the series' direction changes only.
        var turningPoints: [Double] = [values[0]]
        for i in 1..<(values.count - 1) {
            let previous = values[i - 1]
            let current = values[i]
            let next = values[i + 1]
            if (current > previous && current >= next) || (current < previous && current <= next) {
                turningPoints.append(current)
            }
        }
        turningPoints.append(values[values.count - 1])
        guard turningPoints.count >= 2 else { return nil }

        let amplitudes = zip(turningPoints, turningPoints.dropFirst())
            .map { abs($1 - $0) }
            .filter { $0 > standardDeviation }
        guard !amplitudes.isEmpty else { return nil }
        return amplitudes.reduce(0, +) / Double(amplitudes.count)
    }

    /// CONGA(n): standard deviation of the differences between readings exactly
    /// `hours` apart. Pairs are matched within ±10 minutes; gaps in the data are
    /// skipped rather than bridged, which would invent a change that never
    /// happened.
    private static func conga(_ glucose: [(date: Date, value: Double)], hours: Int) -> Double? {
        guard glucose.count >= 4 else { return nil }
        let target = Double(hours) * 3600
        let tolerance: TimeInterval = 10 * 60
        let dates = glucose.map(\.date)
        var differences: [Double] = []

        for (index, sample) in glucose.enumerated() {
            let wanted = sample.date.addingTimeInterval(target)
            let candidate = lowerBound(dates, wanted)
            var best: Int?
            var bestGap = TimeInterval.greatestFiniteMagnitude
            for probe in [candidate - 1, candidate] where probe > index && probe < glucose.count {
                let gap = abs(glucose[probe].date.timeIntervalSince(wanted))
                if gap <= tolerance && gap < bestGap {
                    bestGap = gap
                    best = probe
                }
            }
            if let best { differences.append(glucose[best].value - sample.value) }
        }

        guard differences.count >= 3 else { return nil }
        let mean = differences.reduce(0, +) / Double(differences.count)
        let variance = differences.reduce(0) { $0 + pow($1 - mean, 2) } / Double(differences.count)
        return sqrt(variance)
    }

    /// MODD: mean absolute difference between readings 24 hours apart.
    ///
    /// Bucketed into 5-minute slots by clock time so "the same time yesterday" is
    /// well defined even though readings never land on exactly the same second.
    private static func meanOfDailyDifferences(_ glucose: [(date: Date, value: Double)],
                                               calendar: Calendar) -> Double? {
        guard glucose.count >= 10 else { return nil }

        // (day, slot-of-day) → mean reading in that slot.
        var slots: [Date: [Int: Double]] = [:]
        for sample in glucose {
            let day = calendar.startOfDay(for: sample.date)
            let secondsIntoDay = sample.date.timeIntervalSince(day)
            let slot = Int(secondsIntoDay / 300)
            slots[day, default: [:]][slot] = sample.value
        }

        var differences: [Double] = []
        for (day, readings) in slots {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  let tomorrow = slots[nextDay] else { continue }
            for (slot, value) in readings {
                if let other = tomorrow[slot] { differences.append(abs(other - value)) }
            }
        }
        guard differences.count >= 10 else { return nil }
        return differences.reduce(0, +) / Double(differences.count)
    }

    private static func lowerBound(_ dates: [Date], _ target: Date) -> Int {
        var low = 0
        var high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
