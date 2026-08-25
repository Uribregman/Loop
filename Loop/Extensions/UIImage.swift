//
//  UIImage.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 5/7/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit


extension UIImage {
    private static func imageSuffixForLevel(_ level: Double?) -> String {
        let suffix: String

        switch level {
        case 0?:
            suffix = "0"
        case let x? where x <= 0.25:
            suffix = "25"
        case let x? where x <= 0.5:
            suffix = "50"
        case let x? where x <= 0.75:
            suffix = "75"
        case let x? where x <= 1:
            suffix = "100"
        default:
            suffix = "unknown"
        }

        return suffix
    }

    static func preMealImage(selected: Bool) -> UIImage? {
        return UIImage(named: selected ? "Pre-Meal Selected" : "Pre-Meal")
    }

    static func workoutImage(selected: Bool) -> UIImage? {
        return UIImage(named: selected ? "workout-selected" : "workout")
    }

    /// Redraws the image `factor` times bigger, keeping its aspect ratio and
    /// rendering mode (so template icons still take the bar's tint).
    ///
    /// This is how the bottom bar is enlarged: a `UIBarButtonItem` sizes itself
    /// to its image, and on iOS 26 the shared Liquid Glass capsule sizes itself
    /// to its items — so a bigger image grows the whole bar, with no appearance
    /// override and no custom-view items. See DESIGN_SYSTEM.md: change a bar
    /// button's *image*, never its class.
    ///
    /// Every toolbar icon except `settings` is a vector PDF with vector data
    /// preserved, so it re-renders from the vector and stays sharp at any size.
    func scaled(by factor: CGFloat) -> UIImage {
        guard factor != 1, size != .zero else { return self }
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.withRenderingMode(renderingMode)
    }
}

private class FrameworkBundle {
    static let main = Bundle(for: FrameworkBundle.self)
}

extension UIImage {
    convenience init?(frameworkImage name: String) {
        self.init(named: name, in: FrameworkBundle.main, with: nil)
    }
}
