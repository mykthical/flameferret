// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

/// Colors and type for Ferret's own screens (lock screen, AdGuard and extension settings),
/// matching the navy, parchment and oxblood of the app icon.
enum FerretStyle {
    static let navy = UIColor(rgb: 0x0E2340)
    static let parchment = UIColor(rgb: 0xF4F1E8)
    static let oxblood = UIColor(rgb: 0x9E2B2B)

    static let accent = dynamic(light: UIColor(rgb: 0x1A365C), dark: UIColor(rgb: 0x93AEDA))
    static let ink = dynamic(light: navy, dark: UIColor(rgb: 0xEDE8DA))
    static let paper = dynamic(light: parchment, dark: UIColor(rgb: 0x0B1626))
    static let band = dynamic(light: navy, dark: UIColor(rgb: 0x16263F))
    static let stripe = dynamic(light: oxblood, dark: UIColor(rgb: 0xC2443A))
    static let critical = dynamic(light: oxblood, dark: UIColor(rgb: 0xE05A4F))
    static let card = dynamic(light: .white, dark: UIColor(rgb: 0x16263F))

    /// Parchment background and navy accents for Ferret's own settings tables.
    @MainActor
    static func styleTable(_ tableView: UITableView) {
        tableView.backgroundColor = paper
        tableView.tintColor = accent
    }

    @MainActor
    static func styleCell(_ cell: UITableViewCell) {
        cell.backgroundColor = card
        cell.tintColor = accent
        (cell.accessoryView as? UISwitch)?.onTintColor = accent
    }

    /// A serif face (New York) at the given text style, optionally in tracked small caps for headings.
    static func serifFont(_ style: UIFont.TextStyle, weight: UIFont.Weight = .semibold) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let weighted = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        let descriptor = weighted.withDesign(.serif) ?? weighted
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    /// Tracked uppercase text, as used on official letterheads.
    static func letterhead(_ text: String, font: UIFont, color: UIColor, tracking: CGFloat = 2.4) -> NSAttributedString {
        return NSAttributedString(string: text.uppercased(),
                                  attributes: [.font: font, .foregroundColor: color, .kern: tracking])
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}
