//
//  CGMStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

public final class CGMStatusHUDView: DeviceStatusHUDView, NibLoadable {
    
    private var viewModel: CGMStatusHUDViewModel!
    
    @IBOutlet public weak var glucoseValueHUD: GlucoseValueHUDView!
    
    @IBOutlet public weak var glucoseTrendHUD: GlucoseTrendHUDView!
    
    override public var orderPriority: HUDViewOrderPriority {
        return 1
    }
    
    public var isVisible: Bool {
        get {
            viewModel.isVisible
        }
        set {
            if viewModel.isVisible != newValue {
                viewModel.isVisible = newValue
            }
        }
    }
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    override func setup() {
        super.setup()
        statusHighlightView.setIconPosition(.right)
        viewModel = CGMStatusHUDViewModel(staleGlucoseValueHandler: { [weak self] in
            self?.updateDisplay()
        })
    }
    
    public override func awakeFromNib() {
        super.awakeFromNib()
        // Halve the gap the nib puts between the reading and its trend arrow.
        // With the arrow's enclosing circle gone, the old spacing left it looking
        // detached from the number it belongs to.
        //
        // Done HERE, not in `setup()`: setup runs from `init(coder:)`, before the
        // nib has connected its outlets, so `statusStackView` is still nil there
        // and touching it crashed the app on launch.
        // Tight to the number: the arrow belongs to the reading, so it should
        // sit beside it rather than floating in the pill. Tightened a further
        // third (6 -> 4) by request.
        statusStackView?.spacing = 4
    }

    override public func tintColorDidChange() {
        super.tintColorDidChange()
        
        glucoseValueHUD.tintColor = viewModel.glucoseValueTintColor
        // Fixed yellow by request. NOTE this drops a signal: the trend arrow used
        // to take `viewModel.glucoseTrendTintColor`, which turned it red/amber
        // with the glucose state. The reading itself still carries that colour.
        glucoseTrendHUD.tintColor = Self.trendArrowColor
    }

    /// The trend arrow's fixed colour.
    static let trendArrowColor = UIColor.systemYellow

    override public func presentStatusHighlight(_ statusHighlight: DeviceStatusHighlight?) {
        viewModel.statusHighlight = statusHighlight
        super.presentStatusHighlight(viewModel.statusHighlight)
    }
    
    override func presentStatusHighlight() {
        defer {
            // when the status highlight is updated, the trend icon may also need to be updated
            updateTrendIcon()
            // when the status highlight is updated, the accessibility string is updated
            accessibilityValue = viewModel.accessibilityString
        }
        
        guard statusStackView.arrangedSubviews.contains(glucoseValueHUD),
            statusStackView.arrangedSubviews.contains(glucoseTrendHUD) else
        {
            return
        }
        
        // need to also hide these view, since they will be added back to the stack at some point
        glucoseValueHUD.isHidden = true
        glucoseTrendHUD.isHidden = true
        statusStackView.removeArrangedSubview(glucoseValueHUD)
        statusStackView.removeArrangedSubview(glucoseTrendHUD)
        
        super.presentStatusHighlight()
    }
    
    override public func dismissStatusHighlight() {
        defer {
            // when the status highlight is updated, the trend icon may also need to be updated
            updateTrendIcon()
            // when the status highlight is updated, the accessibility string is updated
            accessibilityValue = viewModel.accessibilityString
        }
        
        guard statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }

        super.dismissStatusHighlight()
        
        statusStackView.addArrangedSubview(glucoseValueHUD)
        statusStackView.addArrangedSubview(glucoseTrendHUD)
        glucoseValueHUD.isHidden = false
        glucoseTrendHUD.isHidden = false
    }
        
    public func setGlucoseQuantity(_ glucoseQuantity: Double,
                                   at glucoseStartDate: Date,
                                   unit: HKUnit,
                                   staleGlucoseAge: TimeInterval,
                                   glucoseDisplay: GlucoseDisplayable?,
                                   wasUserEntered: Bool,
                                   isDisplayOnly: Bool)
    {
        viewModel.setGlucoseQuantity(glucoseQuantity,
                                     at: glucoseStartDate,
                                     unit: unit,
                                     staleGlucoseAge: staleGlucoseAge,
                                     glucoseDisplay: glucoseDisplay,
                                     wasUserEntered: wasUserEntered,
                                     isDisplayOnly: isDisplayOnly)
        
        updateDisplay()
    }

    func updateDisplay() {
        glucoseValueHUD.glucoseLabel.text = viewModel.glucoseValueString
        glucoseValueHUD.unitLabel.text = viewModel.unitsString
        glucoseValueHUD.tintColor = viewModel.glucoseValueTintColor
        presentStatusHighlight(viewModel.statusHighlight)
        
        accessibilityValue = viewModel.accessibilityString
    }
    
    func updateTrendIcon() {
        glucoseTrendHUD.setIcon(viewModel.glucoseTrendIcon)
        // Fixed yellow, NOT `viewModel.glucoseTrendTintColor`. This line runs on
        // every glucose update and was quietly undoing the colour set in
        // `tintColorDidChange`, so the arrow never actually stayed yellow.
        glucoseTrendHUD.tintColor = Self.trendArrowColor
    }
}
