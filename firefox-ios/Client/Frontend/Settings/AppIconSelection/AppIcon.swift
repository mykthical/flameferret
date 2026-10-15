// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import UIKit

/// Ferret's home screen icons. Each has light, dark and tinted versions and a matching `FerretTheme`.
enum AppIcon: String, CaseIterable {
    /// The default icon: parchment, navy and oxblood.
    case regular
    /// Ukraine-inspired: flag blue and yellow, with a sunflower around the globe.
    case sunflower
    /// Black and gold.
    case midnightGold
    /// Deep red with a parchment globe.
    case oxblood
    /// Forest green with a brass rule.
    case fieldGreen
    /// Plain black and white.
    case monochrome

    /// The name of the asset to display in the app selection.
    var displayName: String {
        return theme.displayName
    }

    var telemetryName: String {
        return self.rawValue
    }

    /// The color theme that matches this icon.
    var theme: FerretTheme {
        switch self {
        case .regular: return .classic
        case .sunflower: return .sunflower
        case .midnightGold: return .midnightGold
        case .oxblood: return .oxblood
        case .fieldGreen: return .fieldGreen
        case .monochrome: return .monochrome
        }
    }

    init(theme: FerretTheme) {
        switch theme {
        case .classic: self = .regular
        case .sunflower: self = .sunflower
        case .midnightGold: self = .midnightGold
        case .oxblood: self = .oxblood
        case .fieldGreen: self = .fieldGreen
        case .monochrome: self = .monochrome
        }
    }

    /// The name of the image set asset type. `UIImage`s can only be rendered from image sets, not app icon sets.
    var imageSetAssetName: String {
        switch self {
        case .regular: return "appIconAlternate_ferret_classic"
        case .sunflower: return "appIconAlternate_ferret_sunflower"
        case .midnightGold: return "appIconAlternate_ferret_midnightGold"
        case .oxblood: return "appIconAlternate_ferret_oxblood"
        case .fieldGreen: return "appIconAlternate_ferret_fieldGreen"
        case .monochrome: return "appIconAlternate_ferret_monochrome"
        }
    }

    /// The name of the App Icon asset type. `UIImage`s can only be rendered from image sets, not app icon sets.
    var appIconAssetName: String? {
        switch self {
        case .regular: return nil // Setting the alternative app icon to nil will restore the default app icon asset
        case .sunflower: return "AppIcon_Alt_Ferret_Sunflower"
        case .midnightGold: return "AppIcon_Alt_Ferret_MidnightGold"
        case .oxblood: return "AppIcon_Alt_Ferret_Oxblood"
        case .fieldGreen: return "AppIcon_Alt_Ferret_FieldGreen"
        case .monochrome: return "AppIcon_Alt_Ferret_Monochrome"
        }
    }

    /// Initialize an `AppIcon` from the current `UIApplication.shared.alternateIconName` setting. If the icon cannot be
    /// identified, returns `nil`. This might happen if an old asset is renamed or removed from the asset catalog.
    @MainActor
    static func initFromSystem() -> AppIcon? {
        if let currentAlternativeIcon = UIApplication.shared.alternateIconName {
            let matchingAppIcons = AppIcon.allCases.filter({ $0.appIconAssetName == currentAlternativeIcon })
            guard let alternateAppIcon = matchingAppIcons.first else {
                return nil
            }

            return alternateAppIcon
        } else {
            return .regular
        }
    }
}
