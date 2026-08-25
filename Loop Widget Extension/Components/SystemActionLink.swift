//
//  SystemActionLink.swift
//  Loop Widget Extension
//
//  Created by Cameron Ingham on 6/26/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI

@available(iOS 16.1, *)
struct SystemActionLink: View {
    
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    
    enum Destination: String, CaseIterable {
        case carbEntry = "carb-entry"
        case bolus = "manual-bolus"
        case preMeal = "pre-meal-preset"
        case customPreset = "custom-presets"
        case aiMeal = "ai-meal"

        var deeplink: URL {
            URL(string: "loop://\(rawValue)")!
        }
    }
    
    let destination: Destination
    let active: Bool
    
    init(to destination: Destination, active: Bool = false) {
        self.destination = destination
        self.active = active
    }
    
    private func foregroundColor(active: Bool) -> Color {
        switch destination {
        case .carbEntry:
            return Color("fresh")
        case .bolus:
            return Color("insulin")
        case .preMeal:
            return active ? Color("WidgetBackground") : Color("fresh")
        case .customPreset:
            return active ? Color("WidgetBackground") : Color("glucose")
        case .aiMeal:
            return Color("fresh")
        }
    }
    
    private func backgroundColor(active: Bool) -> Color {
        if widgetRenderingMode == .accented {
            Color(UIColor.systemBackground).opacity(active ? 0.45 : 0.15)
        } else {
            switch destination {
            case .carbEntry:
                active ? Color("fresh") : Color("WidgetSecondaryBackground")
            case .bolus:
                active ? Color("insulin") : Color("WidgetSecondaryBackground")
            case .preMeal:
                active ? Color("fresh") : Color("WidgetSecondaryBackground")
            case .customPreset:
                active ? Color("glucose") : Color("WidgetSecondaryBackground")
            case .aiMeal:
                Color("WidgetSecondaryBackground")
            }
        }
    }
    
    private var icon: Image {
        switch destination {
        case .carbEntry:
            return Image("carbs")
        case .bolus:
            return Image("bolus")
        case .preMeal:
            return Image("premeal")
        case .customPreset:
            return Image("workout")
        case .aiMeal:
            return Image(systemName: "sparkles")
        }
    }

    var body: some View {
        Link(destination: destination.deeplink) {
            icon
                // SF Symbol (aiMeal) needs a font to size up like the asset icons.
                .font(destination == .aiMeal ? .title2 : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .foregroundColor(foregroundColor(active: active))
                .background(backgroundColor(active: active))
                .clipShape(ContainerRelativeShape())
        }
    }
}
