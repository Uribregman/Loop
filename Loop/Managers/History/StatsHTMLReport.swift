//
//  StatsHTMLReport.swift
//  Loop
//
//  Renders `StatsReportModel` as ONE self-contained HTML file.
//
//  ⚠️ SELF-CONTAINED IS A HARD REQUIREMENT, NOT A PREFERENCE. No script tags
//  pointing at a CDN, no web fonts, no image URLs, no fetch. Every chart is
//  inline SVG generated here in Swift. The file is health data: it must render
//  identically on a phone with no signal, in a clinic with a locked-down
//  network, and in five years when whatever CDN we might have used is gone. It
//  must also never phone home — a report that fetches anything tells a third
//  party when and where the person's medical data was opened.
//
//  The charts are drawn straight (polylines, not splines) on purpose. The screen
//  uses monotone interpolation, which is safe, but hand-rolling a smoothing pass
//  here risks drawing values that were never measured — see the interpolation
//  warning in `hourlyTile`. A straight segment between two measured points can
//  only ever be honest.
//

import Foundation

enum StatsHTMLReport {

    // MARK: - Documents

    /// The whole screen, every period, with a working period filter.
    ///
    /// - Parameter models: one model per period, in picker order. ALL of them are
    ///   embedded — the filter switches between panels that are already in the
    ///   file, so the exported page works with no network and no recomputation.
    /// How a live copy announces itself.
    ///
    /// ⚠️ THE STALENESS LINE IS NOT OPTIONAL. A file that rewrites itself looks
    /// current whether or not it is — if the phone has been off, or iCloud has
    /// not synced, the reader is looking at old numbers in a page that gives
    /// every impression of being live. So a live copy says, in the header, when
    /// it was last written and that it only updates while Loop is running.
    struct LiveInfo {
        /// Seconds between automatic reloads in an open browser tab. Nil to leave
        /// the page static.
        var reloadSeconds: Int?
    }

    static func full(models: [(id: String, title: String, longTitle: String, model: StatsReportModel)],
                     weeklyComparison: [HistoryStatistics.PeriodPoint],
                     monthlyComparison: [HistoryStatistics.PeriodPoint],
                     selected: String,
                     generated: Date,
                     live: LiveInfo? = nil) -> String {

        var panels = ""
        for entry in models {
            let isSelected = entry.id == selected
            panels += """
            <section class="panel\(isSelected ? " is-selected" : "")" data-period="\(escape(entry.id))">
            \(sectionsHTML(entry.model, skipping: [.review]))
            </section>
            """
        }

        let chips = models.map { entry in
            """
            <button class="chip\(entry.id == selected ? " is-selected" : "")" data-period="\(escape(entry.id))">\(escape(entry.title))</button>
            """
        }.joined()

        // The review section is period-independent, so it is rendered ONCE
        // outside the panels rather than six identical times.
        let review = models.first?.model.sections.first { $0.id == .review }
        let reviewHTML = review.map { sectionHTML($0) } ?? ""

        let body = """
        \(headerHTML(title: NSLocalizedString("Loop Statistics", comment: "Report title"),
                     subtitle: models.first(where: { $0.id == selected })?.model.rangeText,
                     generated: generated,
                     live: live))
        <nav class="chips" aria-label="\(escape(NSLocalizedString("Time period", comment: "Filter label")))">
          <span class="chips-label">\(escape(NSLocalizedString("Period", comment: "Filter label")))</span>
          \(chips)
        </nav>
        <p class="scope" id="scope"></p>
        \(panels)
        \(comparisonHTML(weekly: weeklyComparison, monthly: monthlyComparison))
        \(reviewHTML)
        """

        return document(title: NSLocalizedString("Loop Statistics", comment: "Report title"),
                        body: body,
                        script: periodScript(models.map { (id: $0.id, scope: $0.longTitle, range: $0.model.rangeText ?? "") })
                            + (live?.reloadSeconds.map(reloadScript) ?? ""))
    }

    /// Reload an open tab so a live copy does not sit there showing yesterday.
    ///
    /// Plain `location.reload()` on a timer, nothing cleverer: there is no server
    /// to poll and no version to compare against. If the file on disk has not
    /// changed, the reload is a no-op the browser serves from cache.
    private static func reloadScript(_ seconds: Int) -> String {
        """
        (function () { setTimeout(function () { location.reload(); }, \(max(60, seconds)) * 1000); })();
        """
    }

    /// One chapter, fixed at the period the exporter was looking at.
    ///
    /// ⚠️ NO PERIOD FILTER HERE, DELIBERATELY. A single category is shared as a
    /// statement about a stated window — "my safety numbers over 30 days". Giving
    /// the reader a filter it cannot honour (the other windows were never
    /// computed) would be worse than not offering one.
    static func section(_ id: StatsReportModel.SectionID,
                        model: StatsReportModel,
                        weeklyComparison: [HistoryStatistics.PeriodPoint],
                        monthlyComparison: [HistoryStatistics.PeriodPoint],
                        generated: Date) -> String {
        var body = headerHTML(title: id.title,
                              subtitle: model.rangeText,
                              generated: generated)
        body += """
        <p class="scope">\(escape(id.ignoresPeriod
            ? NSLocalizedString("Computed from all recorded history, not a selected window.", comment: "Scope caption")
            : String(format: NSLocalizedString("Covering the last %@.", comment: "Scope caption"), model.periodLongTitle)))</p>
        """
        if let section = model.sections.first(where: { $0.id == id }) {
            body += sectionHTML(section, showingTitle: false)
        }
        if id == .progress {
            body += comparisonHTML(weekly: weeklyComparison, monthly: monthlyComparison)
        }
        return document(title: id.title, body: body, script: id == .progress ? comparisonScript : "")
    }

    // MARK: - Structure

    private static func sectionsHTML(_ model: StatsReportModel,
                                     skipping: Set<StatsReportModel.SectionID>) -> String {
        model.sections
            .filter { !skipping.contains($0.id) }
            .map { sectionHTML($0) }
            .joined()
    }

    private static func sectionHTML(_ section: StatsReportModel.Section,
                                    showingTitle: Bool = true) -> String {
        var html = ""
        if showingTitle {
            html += """
            <h2 class="section-title">\(escape(section.id.title))\
            \(section.id.ignoresPeriod ? "<span class=\"badge\">\(escape(NSLocalizedString("All history", comment: "Badge")))</span>" : "")</h2>
            """
        }
        html += section.tiles.map(tileHTML).joined()
        return html
    }

    private static func tileHTML(_ tile: StatsReportModel.Tile) -> String {
        var html = "<article class=\"tile\"><h3>\(escape(tile.title))</h3>"
        if let summary = tile.summary {
            html += "<p class=\"summary\">\(escape(summary))</p>"
        }
        if let explanation = tile.explanation {
            html += "<p class=\"explain\">\(escape(explanation))</p>"
        }
        if let chart = tile.chart {
            html += "<div class=\"chart\">\(chartHTML(chart))</div>"
        }
        if !tile.bullets.isEmpty {
            html += "<ul>" + tile.bullets.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
        }
        if !tile.rows.isEmpty {
            html += "<table>"
            if let headings = tile.columnHeadings {
                html += "<thead><tr><th></th><th>\(escape(headings.0))</th><th>\(escape(headings.1))</th></tr></thead>"
            }
            html += "<tbody>"
            for row in tile.rows {
                html += "<tr><th scope=\"row\">\(escape(row.label))</th><td>\(escape(row.value))</td>"
                if tile.columnHeadings != nil {
                    html += "<td class=\"secondary\">\(escape(row.secondValue ?? "—"))</td>"
                }
                html += "</tr>"
            }
            html += "</tbody></table>"
        }
        if let caveat = tile.caveat {
            html += "<p class=\"caveat\">\(escape(caveat))</p>"
        }
        return html + "</article>"
    }

    // MARK: - Compare Periods
    //
    // The one block with SEVERAL views of the same data: two granularities and
    // four metrics. All eight are rendered up front and the selects just reveal
    // one — which is why this chapter is offered as HTML and never as a picture.

    private static func comparisonHTML(weekly: [HistoryStatistics.PeriodPoint],
                                       monthly: [HistoryStatistics.PeriodPoint]) -> String {
        guard weekly.count >= 2 || monthly.count >= 2 else { return "" }

        var charts = ""
        for (granularity, points) in [("week", weekly), ("month", monthly)] {
            for metric in StatsReportModel.ComparisonMetric.allCases {
                let chart = StatsReportModel.comparisonColumns(points, metric: metric)
                let content: String
                if points.count < 2 {
                    // Honest empty state, same wording as the screen: say WHICH
                    // floor was not met rather than showing a lone bar and
                    // calling it a comparison.
                    let empty = granularity == "week"
                        ? NSLocalizedString("Not enough history yet. A week needs at least 3 days with a full day of readings, and comparing needs 2 such weeks.", comment: "Comparison empty state")
                        : NSLocalizedString("Not enough history yet. A month needs at least 10 days with a full day of readings, and comparing needs 2 such months.", comment: "Comparison empty state")
                    content = "<p class=\"explain\">\(escape(empty))</p>"
                } else {
                    content = svgColumns(chart) + comparisonTable(points)
                }
                charts += """
                <div class="cmp" data-granularity="\(granularity)" data-metric="\(metric.rawValue)">\(content)</div>
                """
            }
        }

        let metricOptions = StatsReportModel.ComparisonMetric.allCases.map {
            "<option value=\"\($0.rawValue)\">\(escape($0.title))</option>"
        }.joined()

        return """
        <h2 class="section-title">\(escape(NSLocalizedString("Compare Periods", comment: "Tile title")))<span class="badge">\(escape(NSLocalizedString("All history", comment: "Badge")))</span></h2>
        <article class="tile">
          <p class="explain">\(escape(NSLocalizedString("Week by week, or month by month, across all recorded history. Pick the bucket and the measure.", comment: "Comparison explanation")))</p>
          <div class="controls">
            <label>\(escape(NSLocalizedString("Bucket", comment: "Control label")))
              <select id="granularity">
                <option value="week">\(escape(NSLocalizedString("Weekly", comment: "Granularity")))</option>
                <option value="month">\(escape(NSLocalizedString("Monthly", comment: "Granularity")))</option>
              </select>
            </label>
            <label>\(escape(NSLocalizedString("Measure", comment: "Control label")))
              <select id="metric">\(metricOptions)</select>
            </label>
          </div>
          \(charts)
          <p class="caveat">\(escape(NSLocalizedString("A bucket appears only once it has enough days of data to mean anything: 3 days for a week, 10 for a month.", comment: "Comparison caveat")))</p>
        </article>
        """
    }

    private static func comparisonTable(_ points: [HistoryStatistics.PeriodPoint]) -> String {
        var html = """
        <table><thead><tr>
        <th>\(escape(NSLocalizedString("Period", comment: "Column")))</th>
        <th>\(escape(NSLocalizedString("In range", comment: "Column")))</th>
        <th>\(escape(NSLocalizedString("Average", comment: "Column")))</th>
        <th>\(escape(NSLocalizedString("CV", comment: "Column")))</th>
        <th>\(escape(NSLocalizedString("Below 70", comment: "Column")))</th>
        <th>\(escape(NSLocalizedString("Days", comment: "Column")))</th>
        </tr></thead><tbody>
        """
        for point in points.reversed() {
            html += """
            <tr><th scope="row">\(escape(StatsReportModel.comparisonLabel(point)))</th>
            <td>\(String(format: "%.0f%%", point.inRange * 100))</td>
            <td>\(String(format: "%.0f", point.mean))</td>
            <td>\(String(format: "%.0f%%", point.coefficientOfVariation))</td>
            <td>\(String(format: "%.1f%%", point.below * 100))</td>
            <td>\(point.days)</td></tr>
            """
        }
        return html + "</tbody></table>"
    }

    // MARK: - Charts
    //
    // ⚠️ EVERY CHART PRINTS ITS OWN NUMBERS. There is no scrubbing in an exported
    // file — no finger, no hover on a phone, and the reader may be looking at a
    // printout. A chart whose values can only be reached by touching it is
    // decoration once it leaves the app, so each column carries its value above
    // it and each chart is followed by, or paired with, a table of the same
    // figures. Do not "clean up" the labels to make the charts prettier.

    private static func chartHTML(_ chart: StatsReportModel.Chart) -> String {
        switch chart {
        case .bands(let bands):   return svgBands(bands)
        case .columns(let c):     return svgColumns(c)
        case .rows(let c):        return svgRows(c)
        case .profile(let p):     return svgProfile(p)
        }
    }

    /// Vertical columns, each labelled with its own value.
    private static func svgColumns(_ chart: StatsReportModel.ColumnChart) -> String {
        let columns = chart.columns
        guard !columns.isEmpty else { return "" }

        let width = 760.0, height = 300.0
        let padL = 46.0, padR = 14.0, padT = 30.0, padB = 62.0
        let plotW = width - padL - padR
        let plotH = height - padT - padB
        let dataMax = columns.map(\.value).max() ?? 1
        let top = max(chart.maximum ?? (dataMax * 1.18), 1)
        func y(_ value: Double) -> Double { padT + plotH * (1 - min(value, top) / top) }

        let slot = plotW / Double(columns.count)
        let barW = min(64, slot * 0.62)
        // Past a dozen columns the labels collide, so they lie down instead of
        // being dropped. Dropping them would hide which bar is which period.
        let rotate = columns.count > 9

        var svg = "<svg viewBox=\"0 0 \(fmt(width)) \(fmt(height))\" class=\"svg-chart\" role=\"img\" \(seriesStyle(chart))>"

        // Axis ticks: bottom, middle, top. Three is enough to read a bar against
        // and few enough not to become a grid the eye has to filter out.
        for fraction in [0.0, 0.5, 1.0] {
            let value = top * fraction
            let ty = y(value)
            svg += "<line x1=\"\(fmt(padL))\" y1=\"\(fmt(ty))\" x2=\"\(fmt(width - padR))\" y2=\"\(fmt(ty))\" class=\"grid\"/>"
            svg += "<text x=\"\(fmt(padL - 8))\" y=\"\(fmt(ty + 4))\" class=\"axis\" text-anchor=\"end\">\(escape(String(format: "%.0f", value)))</text>"
        }
        if let goal = chart.goal, goal < top {
            svg += "<line x1=\"\(fmt(padL))\" y1=\"\(fmt(y(goal)))\" x2=\"\(fmt(width - padR))\" y2=\"\(fmt(y(goal)))\" class=\"goal\"/>"
            svg += "<text x=\"\(fmt(width - padR))\" y=\"\(fmt(y(goal) - 5))\" class=\"axis\" text-anchor=\"end\">\(escape(String(format: NSLocalizedString("goal %.0f", comment: "Goal line label"), goal)))</text>"
        }

        for (index, column) in columns.enumerated() {
            let cx = padL + slot * (Double(index) + 0.5)
            let barTop = y(column.value)
            let barHeight = max(1, padT + plotH - barTop)
            svg += """
            <rect x="\(fmt(cx - barW / 2))" y="\(fmt(barTop))" width="\(fmt(barW))" height="\(fmt(barHeight))" rx="4" fill="var(--series)"/>
            <text x="\(fmt(cx))" y="\(fmt(barTop - 8))" class="value" text-anchor="middle">\(escape(column.display))</text>
            """
            let labelY = padT + plotH + 16
            if rotate {
                svg += "<text x=\"\(fmt(cx))\" y=\"\(fmt(labelY))\" class=\"axis\" text-anchor=\"end\" transform=\"rotate(-45 \(fmt(cx)) \(fmt(labelY)))\">\(escape(column.label))</text>"
            } else {
                svg += "<text x=\"\(fmt(cx))\" y=\"\(fmt(labelY))\" class=\"axis\" text-anchor=\"middle\">\(escape(column.label))</text>"
                if let detail = column.detail {
                    svg += "<text x=\"\(fmt(cx))\" y=\"\(fmt(labelY + 15))\" class=\"axis dim\" text-anchor=\"middle\">\(escape(detail))</text>"
                }
            }
        }
        svg += "<line x1=\"\(fmt(padL))\" y1=\"\(fmt(padT + plotH))\" x2=\"\(fmt(width - padR))\" y2=\"\(fmt(padT + plotH))\" class=\"axisline\"/>"
        return svg + "</svg>"
    }

    /// Horizontal magnitude bars — the post-meal style comparison.
    private static func svgRows(_ chart: StatsReportModel.ColumnChart) -> String {
        let columns = chart.columns
        guard !columns.isEmpty else { return "" }
        let width = 760.0
        let rowHeight = 52.0
        let height = rowHeight * Double(columns.count)
        let maximum = max(chart.maximum ?? (columns.map(\.value).max() ?? 1), 0.0001)

        var svg = "<svg viewBox=\"0 0 \(fmt(width)) \(fmt(height))\" class=\"svg-chart\" role=\"img\" \(seriesStyle(chart))>"
        for (index, column) in columns.enumerated() {
            let top = rowHeight * Double(index)
            let barWidth = max(4, width * (column.value / maximum) * 0.98)
            let detail = column.detail.map { " · \($0)" } ?? ""
            svg += """
            <text x="0" y="\(fmt(top + 14))" class="axis">\(escape(column.label))</text>
            <text x="\(fmt(width))" y="\(fmt(top + 14))" class="value" text-anchor="end">\(escape(column.display + detail))</text>
            <rect x="0" y="\(fmt(top + 24))" width="\(fmt(width))" height="10" rx="5" class="track"/>
            <rect x="0" y="\(fmt(top + 24))" width="\(fmt(barWidth))" height="10" rx="5" fill="var(--series)"/>
            """
        }
        return svg + "</svg>"
    }

    /// The time-in-range distribution as one segmented bar plus its numbers.
    private static func svgBands(_ bands: [StatsReportModel.Band]) -> String {
        // Bands under half a point are dropped from the BAR (they cannot be drawn
        // legibly) but never from the table above it — a very-low share of 0.4%
        // is exactly the kind of number that must not vanish because it is small.
        let visible = bands.filter { ($0.fraction * 100).rounded() >= 1 }
        let total = visible.reduce(0) { $0 + $1.fraction }
        guard total > 0 else { return "" }

        let width = 760.0, height = 54.0
        var svg = "<svg viewBox=\"0 0 \(fmt(width)) \(fmt(height))\" class=\"svg-chart\" role=\"img\">"
        var x = 0.0
        for band in visible {
            let segment = width * (band.fraction / total)
            svg += "<rect x=\"\(fmt(x))\" y=\"0\" width=\"\(fmt(segment))\" height=\"26\" fill=\"\(band.lightHex)\" class=\"band band-\(band.id)\"/>"
            // Only label a segment wide enough to hold the text without it
            // spilling over its neighbours.
            if segment > 46 {
                svg += "<text x=\"\(fmt(x + segment / 2))\" y=\"\(fmt(18))\" class=\"onband\" text-anchor=\"middle\">\(escape(StatsReportModel.percent(band.fraction)))</text>"
            }
            if segment > 70 {
                svg += "<text x=\"\(fmt(x + segment / 2))\" y=\"\(fmt(44))\" class=\"axis\" text-anchor=\"middle\">\(escape(band.name))</text>"
            }
            x += segment
        }
        return svg + "</svg>"
    }

    /// The hourly (AGP) profile: outer band, inner band, median line, and the
    /// median printed above every hour.
    private static func svgProfile(_ profile: StatsReportModel.Profile) -> String {
        let points = profile.points
        guard points.count >= 2 else { return "" }

        let width = 760.0, height = 320.0
        let padL = 46.0, padR = 16.0, padT = 34.0, padB = 40.0
        let plotW = width - padL - padR
        let plotH = height - padT - padB

        let lows = points.map(\.p10), highs = points.map(\.p90)
        let yMin = min(60, (lows.min() ?? 70) - 10)
        let yMax = max(200, (highs.max() ?? 180) + 20)
        func x(_ hour: Int) -> Double { padL + plotW * (Double(hour) / 23.0) }
        func y(_ value: Double) -> Double {
            padT + plotH * (1 - (min(max(value, yMin), yMax) - yMin) / (yMax - yMin))
        }

        // ⚠️ RUNS OF CONSECUTIVE HOURS, exactly as the screen does it. An hour
        // that failed the evidence floor is absent from the profile, and drawing
        // one continuous path would interpolate straight across the hole —
        // inventing a level for an hour that was explicitly judged unmeasurable.
        var runs: [[HistoryStatistics.HourlyPoint]] = []
        for point in points {
            if let last = runs.last?.last, point.hour == last.hour + 1 {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }

        var svg = "<svg viewBox=\"0 0 \(fmt(width)) \(fmt(height))\" class=\"svg-chart\" role=\"img\">"
        // Target band behind everything.
        svg += "<rect x=\"\(fmt(padL))\" y=\"\(fmt(y(profile.highTarget)))\" width=\"\(fmt(plotW))\" height=\"\(fmt(y(profile.lowTarget) - y(profile.highTarget)))\" class=\"target\"/>"
        for value in [profile.lowTarget, profile.highTarget] {
            svg += "<line x1=\"\(fmt(padL))\" y1=\"\(fmt(y(value)))\" x2=\"\(fmt(width - padR))\" y2=\"\(fmt(y(value)))\" class=\"grid\"/>"
            svg += "<text x=\"\(fmt(padL - 8))\" y=\"\(fmt(y(value) + 4))\" class=\"axis\" text-anchor=\"end\">\(whole(value))</text>"
        }

        for run in runs {
            if run.count >= 2 {
                let outer = run.filter(\.hasOuterBand)
                if outer.count >= 2 { svg += area(outer, lower: \.p10, upper: \.p90, className: "outer", x: x, y: y) }
                svg += area(run, lower: \.p25, upper: \.p75, className: "inner", x: x, y: y)
                let line = run.map { "\(fmt(x($0.hour))),\(fmt(y($0.median)))" }.joined(separator: " ")
                svg += "<polyline points=\"\(line)\" class=\"median\"/>"
            } else if let only = run.first {
                svg += "<circle cx=\"\(fmt(x(only.hour)))\" cy=\"\(fmt(y(only.median)))\" r=\"3.5\" class=\"dot\"/>"
            }
        }

        // The median of every hour, printed. Alternating heights keep 24 labels
        // from colliding at this width.
        for point in points {
            let labelY = y(point.median) - (point.hour % 2 == 0 ? 10 : 20)
            svg += "<text x=\"\(fmt(x(point.hour)))\" y=\"\(fmt(max(12, labelY)))\" class=\"value small\" text-anchor=\"middle\">\(whole(point.median))</text>"
        }
        for hour in [0, 6, 12, 18, 23] {
            svg += "<text x=\"\(fmt(x(hour)))\" y=\"\(fmt(height - 14))\" class=\"axis\" text-anchor=\"middle\">\(escape(StatsReportModel.hourLabel(hour)))</text>"
        }
        svg += "<line x1=\"\(fmt(padL))\" y1=\"\(fmt(padT + plotH))\" x2=\"\(fmt(width - padR))\" y2=\"\(fmt(padT + plotH))\" class=\"axisline\"/>"
        return svg + "</svg>"
    }

    /// The chart's own colour, as a light/dark pair.
    ///
    /// ⚠️ TWO VALUES, NOT ONE. An inline `fill` cannot answer a media query, so a
    /// single colour baked into the attribute would have made every chart green
    /// in dark mode — which is how the Variability chart first came out green
    /// while claiming to be orange. The CSS picks between these two.
    private static func seriesStyle(_ chart: StatsReportModel.ColumnChart) -> String {
        "style=\"--series-light:\(chart.lightHex);--series-dark:\(chart.darkHex)\""
    }

    private static func area(_ run: [HistoryStatistics.HourlyPoint],
                             lower: KeyPath<HistoryStatistics.HourlyPoint, Double>,
                             upper: KeyPath<HistoryStatistics.HourlyPoint, Double>,
                             className: String,
                             x: (Int) -> Double,
                             y: (Double) -> Double) -> String {
        let top = run.map { "\(fmt(x($0.hour))),\(fmt(y($0[keyPath: upper])))" }
        let bottom = run.reversed().map { "\(fmt(x($0.hour))),\(fmt(y($0[keyPath: lower])))" }
        return "<polygon points=\"\((top + bottom).joined(separator: " "))\" class=\"\(className)\"/>"
    }

    // MARK: - Document shell

    private static func headerHTML(title: String, subtitle: String?, generated: Date,
                                   live: LiveInfo? = nil) -> String {
        let stamp = live == nil
            ? String(format: NSLocalizedString("Exported %@ from Loop.", comment: "Export stamp"),
                     timestampFormatter.string(from: generated))
            : String(format: NSLocalizedString("Live copy — last written %@.", comment: "Live stamp"),
                     timestampFormatter.string(from: generated))
        return """
        <header>
          <h1>\(escape(title))</h1>
          \(subtitle.map { "<p class=\"range\">\(escape($0))</p>" } ?? "")
          <p class="generated">\(escape(stamp))</p>
          \(live == nil ? "" : "<p class=\"generated warn\">\(escape(NSLocalizedString("This page is rewritten by Loop on the patient's phone. It only updates while that phone is running Loop and connected to iCloud — if the time above is old, so are the numbers.", comment: "Live staleness warning")))</p>")
        </header>
        """
    }

    private static func document(title: String, body: String, script: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(escape(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <main>
        \(body)
        <footer><p>\(escape(StatsReportModel.disclaimer))</p></footer>
        </main>
        \(script.isEmpty ? "" : "<script>\(script)</script>")
        </body>
        </html>
        """
    }

    /// Light and dark are both defined, and dark is chosen by the READER's
    /// system setting rather than by whatever the exporter happened to be using.
    /// A report is read on someone else's device.
    private static let css = """
    :root {
      --bg: #f2f2f7; --card: #ffffff; --ink: #1c1c1e; --dim: #6c6c70; --faint: #8e8e93;
      --line: rgba(0,0,0,0.10); --series: #2FA84F; --accent: #3A7BD5;
      --target: rgba(47,168,79,0.12); --track: rgba(0,0,0,0.08);
      --chip: rgba(0,0,0,0.06); --chip-on: #1c1c1e; --chip-on-ink: #ffffff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d0d0d; --card: #1c1c1e; --ink: #f2f2f7; --dim: #a1a1a6; --faint: #8e8e93;
        --line: rgba(255,255,255,0.14); --series: #34C759; --accent: #5E9BEA;
        --target: rgba(52,199,89,0.16); --track: rgba(255,255,255,0.14);
        --chip: rgba(255,255,255,0.10); --chip-on: #f2f2f7; --chip-on-ink: #0d0d0d;
      }
      .band-veryLow { fill: #9B6BFF; } .band-low { fill: #D93A50; }
      .band-inRange { fill: #34C759; } .band-high { fill: #FFDA47; } .band-veryHigh { fill: #FF8A2B; }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 20px 16px 48px; background: var(--bg); color: var(--ink);
      font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      -webkit-text-size-adjust: 100%;
    }
    main { max-width: 820px; margin: 0 auto; }
    header { margin-bottom: 18px; }
    h1 { font-size: 28px; margin: 0 0 4px; letter-spacing: -0.02em; }
    .range { margin: 0; color: var(--dim); }
    .generated { margin: 2px 0 0; color: var(--faint); font-size: 13px; }
    .generated.warn { max-width: 60ch; margin-top: 6px; }
    .section-title {
      font-size: 21px; margin: 30px 0 10px; letter-spacing: -0.01em;
      display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap;
    }
    .badge {
      font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em;
      color: var(--dim); background: var(--chip); padding: 3px 8px; border-radius: 999px;
    }
    .tile {
      background: var(--card); border-radius: 18px; padding: 18px; margin: 0 0 14px;
      box-shadow: 0 1px 2px rgba(0,0,0,0.05);
    }
    .tile h3 { font-size: 15px; margin: 0 0 8px; color: var(--dim); font-weight: 600; }
    .summary { margin: 0 0 8px; font-size: 19px; font-weight: 600; letter-spacing: -0.01em; }
    .explain { margin: 0 0 10px; font-size: 13.5px; color: var(--dim); }
    .caveat { margin: 10px 0 0; font-size: 12.5px; color: var(--faint); }
    ul { margin: 6px 0 0; padding-left: 20px; }
    li { margin-bottom: 6px; }
    table { width: 100%; border-collapse: collapse; margin-top: 10px; font-variant-numeric: tabular-nums; }
    th, td { text-align: right; padding: 7px 4px; border-bottom: 1px solid var(--line); font-size: 14.5px; }
    th[scope="row"], thead th:first-child { text-align: left; font-weight: 400; }
    thead th { color: var(--dim); font-size: 12px; font-weight: 600; }
    tbody tr:last-child th, tbody tr:last-child td { border-bottom: 0; }
    td.secondary { color: var(--dim); }
    .chart { margin: 10px 0 4px; overflow-x: auto; }
    .svg-chart { width: 100%; height: auto; display: block; --series: var(--series-light, #2FA84F); }
    @media (prefers-color-scheme: dark) { .svg-chart { --series: var(--series-dark, #34C759); } }
    .svg-chart .axis { font-size: 11px; fill: var(--dim); }
    .svg-chart .axis.dim { fill: var(--faint); font-size: 10px; }
    .svg-chart .value { font-size: 12px; font-weight: 600; fill: var(--ink); }
    .svg-chart .value.small { font-size: 9.5px; font-weight: 500; fill: var(--dim); }
    .svg-chart .onband { font-size: 12px; font-weight: 700; fill: #fff; }
    .svg-chart .grid { stroke: var(--line); stroke-width: 1; }
    .svg-chart .axisline { stroke: var(--line); stroke-width: 1; }
    .svg-chart .goal { stroke: var(--faint); stroke-width: 1; stroke-dasharray: 4 3; }
    .svg-chart .track { fill: var(--track); }
    .svg-chart .target { fill: var(--target); }
    .svg-chart .outer { fill: var(--accent); opacity: 0.14; }
    .svg-chart .inner { fill: var(--accent); opacity: 0.28; }
    .svg-chart .median { fill: none; stroke: var(--accent); stroke-width: 2.2; stroke-linejoin: round; }
    .svg-chart .dot { fill: var(--accent); }
    .chips { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 6px; }
    .chips-label { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--faint); }
    .chip {
      font: inherit; font-size: 14px; font-weight: 600; padding: 7px 14px; border: 0;
      border-radius: 999px; background: var(--chip); color: var(--ink); cursor: pointer;
    }
    .chip.is-selected { background: var(--chip-on); color: var(--chip-on-ink); }
    .scope { color: var(--dim); font-size: 13.5px; margin: 4px 0 8px; }
    .panel { display: none; }
    .panel.is-selected { display: block; }
    .controls { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 8px; }
    .controls label { font-size: 12.5px; color: var(--dim); display: flex; gap: 6px; align-items: center; }
    .controls select {
      font: inherit; font-size: 14px; padding: 5px 8px; border-radius: 9px;
      border: 1px solid var(--line); background: var(--card); color: var(--ink);
    }
    .cmp { display: none; }
    .cmp.is-selected { display: block; }
    footer { margin-top: 32px; color: var(--faint); font-size: 12.5px; border-top: 1px solid var(--line); padding-top: 12px; }
    @media print {
      body { background: #fff; }
      .tile { break-inside: avoid; box-shadow: none; border: 1px solid var(--line); }
      .chips { display: none; }
      .panel { display: block !important; }
    }
    """

    /// Period filter. Deliberately tiny and dependency-free: the exported file
    /// has to keep working forever, offline, in whatever browser opens it.
    private static func periodScript(_ periods: [(id: String, scope: String, range: String)]) -> String {
        let entries = periods.map { "\"\($0.id)\":{s:\"\(jsEscape($0.scope))\",r:\"\(jsEscape($0.range))\"}" }
            .joined(separator: ",")
        return """
        (function () {
          var meta = {\(entries)};
          var scope = document.getElementById('scope');
          function select(id) {
            document.querySelectorAll('.chip').forEach(function (c) {
              c.classList.toggle('is-selected', c.dataset.period === id);
            });
            document.querySelectorAll('.panel').forEach(function (p) {
              p.classList.toggle('is-selected', p.dataset.period === id);
            });
            var m = meta[id];
            if (m && scope) { scope.textContent = m.r ? m.s + ' \\u2014 ' + m.r : m.s; }
          }
          document.querySelectorAll('.chip').forEach(function (c) {
            c.addEventListener('click', function () { select(c.dataset.period); });
          });
          var initial = document.querySelector('.chip.is-selected');
          if (initial) { select(initial.dataset.period); }
          \(comparisonScript)
        })();
        """
    }

    private static let comparisonScript = """
    (function () {
      var g = document.getElementById('granularity'), m = document.getElementById('metric');
      if (!g || !m) { return; }
      function apply() {
        document.querySelectorAll('.cmp').forEach(function (c) {
          c.classList.toggle('is-selected', c.dataset.granularity === g.value && c.dataset.metric === m.value);
        });
      }
      g.addEventListener('change', apply);
      m.addEventListener('change', apply);
      apply();
    })();
    """

    // MARK: - Escaping

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    private static func jsEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<", with: "\\u003C")
    }

    /// A glucose value as printed to the reader: whole mg/dL, never a decimal.
    /// `fmt` is for GEOMETRY and keeps a decimal for smooth positioning — using
    /// it on a reading printed "163.5 mg/dL", a precision the CGM does not have.
    private static func whole(_ value: Double) -> String { String(format: "%.0f", value) }

    /// Compact number for SVG geometry — one decimal, no trailing zero.
    private static func fmt(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}
