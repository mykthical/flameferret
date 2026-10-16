// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

/// Colors and type for Ferret's own screens (lock screen, AdGuard and extension settings),
/// following the selected `FerretTheme` (navy, parchment and oxblood in Classic).
enum FerretStyle {
    private static var style: FerretPalette.Style { FerretThemeStore.palette.style }

    /// Light-appearance colors of the current theme (navy, parchment and oxblood in Classic).
    static var navy: UIColor { style.bandLight }
    static var parchment: UIColor { style.paperLight }
    static var oxblood: UIColor { style.stripeLight }

    static var accent: UIColor { dynamic { $0.accentLight } dark: { $0.accentDark } }
    static var ink: UIColor { dynamic { $0.inkLight } dark: { $0.inkDark } }
    static var paper: UIColor { dynamic { $0.paperLight } dark: { $0.paperDark } }
    static var band: UIColor { dynamic { $0.bandLight } dark: { $0.bandDark } }
    static var stripe: UIColor { dynamic { $0.stripeLight } dark: { $0.stripeDark } }
    static var critical: UIColor { dynamic(light: UIColor(rgb: 0x9E2B2B), dark: UIColor(rgb: 0xE05A4F)) }
    static var card: UIColor { dynamic { _ in .white } dark: { $0.cardDark } }
    /// Text drawn on `band`.
    static var onBand: UIColor { dynamic { $0.paperLight } dark: { $0.inkDark } }

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

    /// A color that follows both the appearance and the selected theme at the moment it's drawn.
    private static func dynamic(_ light: @escaping @Sendable (FerretPalette.Style) -> UIColor,
                                dark: @escaping @Sendable (FerretPalette.Style) -> UIColor) -> UIColor {
        return UIColor { traits in
            let style = FerretThemeStore.palette.style
            return traits.userInterfaceStyle == .dark ? dark(style) : light(style)
        }
    }
}
