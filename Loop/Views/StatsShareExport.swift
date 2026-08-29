//
//  StatsShareExport.swift
//  Loop
//
//  Turning the statistics screen into something you can send someone.
//
//  TWO SHAPES, AND THE CHOICE IS NOT COSMETIC:
//
//  • A PICTURE (PNG) for a chapter — Safety, When, Meals and the rest. It is
//    rendered from THE REAL SCREEN, not from a second hand-built layout, so a
//    shared card cannot drift away from what the person was actually looking at.
//    Everything collapsed is forced open first, and every chart prints its own
//    numbers, because a picture cannot be tapped or scrubbed.
//
//  • HTML for anything with SEVERAL VIEWS of the same data. Compare Periods has
//    two bucket sizes and four measures; flattening that to one PNG would throw
//    away seven of its eight views and pretend the one left was the whole story.
//    The full report is HTML for the same reason plus one more: it carries every
//    period, so the READER gets the time filter too.
//
//  ⚠️ SCOPE RULE, AND IT IS THE POINT OF THE FEATURE. A single chapter is
//  exported at THE PERIOD THE EXPORTER WAS LOOKING AT, stamped on the card. The
//  full report carries all six periods and lets the reader switch. A shared
//  number whose window is unstated, or silently different from the one on
//  screen, is a misleading medical number.
//
//  ⚠️ Nothing here reads or writes anything but already-computed statistics. No
//  export path touches the algorithm, the pump, or the log itself.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Rendering

@MainActor
enum StatsShareRenderer {

    /// Width the PNG cards are laid out at, in points.
    ///
    /// Wider than a phone deliberately: at phone width the AGP's 24 hourly labels
    /// collide, and the whole reason for the labels is that the picture cannot be
    /// scrubbed. 900 × scale 3 gives a 2700px card, which stays sharp when a
    /// messaging app re-compresses it.
    static let cardWidth: CGFloat = 900
    static let cardScale: CGFloat = 3

    /// Render one chapter of the live screen as a PNG on disk.
    ///
    /// - Returns: a file URL in the temporary directory, or nil if rendering
    ///   produced nothing (an empty section, or a renderer failure).
    static func image(of section: StatsReportModel.SectionID,
                      viewModel: HistoryStatisticsViewModel) -> URL? {
        let card = HistoryStatisticsView(exporting: section, viewModel: viewModel)
            .frame(width: cardWidth)
            // ⚠️ FORCED LIGHT. A PNG has no dark mode: it cannot adapt to the
            // reader's device, and a dark card dropped into a light conversation
            // reads as a rendering fault. Light also prints, which is where these
            // end up when they go to a clinic. The HTML report, which CAN adapt,
            // follows the reader's own setting instead.
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: card)
        renderer.scale = cardScale
        renderer.isOpaque = true
        guard let image = renderer.uiImage, let data = image.pngData() else { return nil }
        return write(data, named: "loop-\(section.rawValue)", extension: "png")
    }

    static func write(_ data: Data, named name: String, extension ext: String) -> URL? {
        let stamp = fileStampFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(stamp)")
            .appendingPathExtension(ext)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}

// MARK: - What a share produced

/// The result of preparing a share, held in view state until the sheet closes.
///
/// `Identifiable` so it can drive `.sheet(item:)` — the id changes per export, so
/// asking for a second share while the first sheet is up replaces it rather than
/// being swallowed.
struct StatsSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// Plain-text fallback offered alongside the file, for destinations that
    /// cannot take an attachment (a message box, a note).
    let text: String?

    var activityItems: [Any] {
        var items: [Any] = urls
        if let text { items.append(text) }
        return items
    }
}

/// Minimal share-sheet host. Deliberately its own copy rather than a shared
/// helper: the other one in this app is `fileprivate`, and reaching across files
/// to widen it would change behaviour on a screen this change has no business
/// touching.
struct StatsActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - The button

/// The small share control that sits on a section header.
///
/// Icon-only and quiet on purpose: there is one on every chapter, and eight
/// labelled buttons down the screen would compete with the statistics they are
/// attached to.
struct StatsShareButton: View {
    let title: String
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isBusy)
        .accessibilityLabel(Text(String(format: NSLocalizedString("Share %@", comment: "Accessibility label for a section share button"), title)))
    }
}

// MARK: - Tile background that survives being rendered

extension View {
    /// The tile background, swapped for a solid card while exporting.
    ///
    /// 🐛 THIS IS NOT A STYLE CHOICE. `glassEffect` is a live compositing effect:
    /// it samples what is BEHIND it on a real screen. `ImageRenderer` has no
    /// screen and nothing behind it, so glass tiles render as empty holes — the
    /// first PNG cards came out as floating text on a blank field with no cards
    /// at all under it. A solid fill is the only thing that survives the trip.
    ///
    /// The same trap applies to `.ultraThinMaterial` and friends. If a new tile
    /// style is added, it has to come through here too.
    @ViewBuilder
    func loopExportableTileBackground(_ isExporting: Bool) -> some View {
        if isExporting {
            background(
                RoundedRectangle(cornerRadius: loopTileCornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        } else {
            loopTileGlass()
        }
    }
}
