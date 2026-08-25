//
//  BasalRateHUDView.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 5/1/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit
import LoopKitUI

public final class BasalRateHUDView: BaseHUDView {
    
    override public var orderPriority: HUDViewOrderPriority {
        return 3
    }

    @IBOutlet private weak var basalStateView: BasalStateView!

    @IBOutlet private weak var basalRateLabel: UILabel! {
        didSet {
            basalRateLabel?.text = String(format: basalRateFormatString, "–")
            basalRateLabel?.textColor = .secondaryLabel
            stabilizeBasalRateLabelWidth()

            accessibilityValue = LocalizedString("Unknown", comment: "Accessibility value for an unknown value")
        }
    }

    /// Pins the label to a constant width and monospaced digits.
    ///
    /// The rate formatter emits "+0.0", "+0.05", "+0.15" … so the text width
    /// changed with the delivered amount, which resized this view — and with it
    /// the whole pump capsule in the status bar, making the top row visibly
    /// jump every time delivery changed.
    private func stabilizeBasalRateLabelWidth() {
        guard let label = basalRateLabel, let font = label.font else { return }

        // Equal-width digits, keeping the label's existing face and size.
        let monospacedDescriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]]
        ])
        let monospaced = UIFont(descriptor: monospacedDescriptor, size: 0)
        label.font = monospaced
        label.textAlignment = .center

        // Sized for the widest rate the formatter can produce ("+0.0##").
        let widest = String(format: basalRateFormatString, "+00.000")
        let width = ceil((widest as NSString).size(withAttributes: [.font: monospaced]).width)

        let constraint = label.widthAnchor.constraint(equalToConstant: width)
        // Below required, so an extreme accessibility text size can still break
        // it rather than producing an unsatisfiable layout.
        constraint.priority = .required - 1
        constraint.isActive = true
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()
    }

    private lazy var basalRateFormatString = LocalizedString("%@ U", comment: "The format string describing the basal rate.")

    public func setNetBasalRate(_ rate: Double, percent: Double, at date: Date) {
        let time = timeFormatter.string(from: date)
        caption?.text = time

        if let rateString = decimalFormatter.string(from: rate) {
            basalRateLabel?.text = String(format: basalRateFormatString, rateString)
            accessibilityValue = String(format: LocalizedString("%1$@ units per hour at %2$@", comment: "Accessibility format string describing the basal rate. (1: localized basal rate value)(2: last updated time)"), rateString, time)
        } else {
            basalRateLabel?.text = nil
            accessibilityValue = nil
        }

        basalStateView.netBasalPercent = percent
    }

    private lazy var decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.minimumIntegerDigits = 1
        formatter.positiveFormat = "+0.0##"
        formatter.negativeFormat = "-0.0##"

        return formatter
    }()

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        return formatter
    }()

}
