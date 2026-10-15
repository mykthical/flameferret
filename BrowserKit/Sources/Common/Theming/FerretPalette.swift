// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import UIKit

/// Ferret's color themes. Each restyles the whole app (light, dark and private browsing) and matches
/// one of the app icons.
public enum FerretTheme: String, CaseIterable, Sendable {
    case classic
    case sunflower
    case midnightGold
    case oxblood
    case fieldGreen
    case monochrome

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .sunflower: return "Sunflower"
        case .midnightGold: return "Midnight Gold"
        case .oxblood: return "Oxblood"
        case .fieldGreen: return "Field Green"
        case .monochrome: return "Monochrome"
        }
    }

    public var summary: String {
        switch self {
        case .classic: return "Parchment, navy and oxblood."
        case .sunflower: return "Inspired by Ukraine: flag blue with sunflower yellow."
        case .midnightGold: return "Black and gold, like an embossed passport."
        case .oxblood: return "Deep red with parchment."
        case .fieldGreen: return "Forest green with brass."
        case .monochrome: return "Plain black and white."
        }
    }

    public var palette: FerretPalette {
        switch self {
        case .classic: return .classic
        case .sunflower: return .sunflower
        case .midnightGold: return .midnightGold
        case .oxblood: return .oxblood
        case .fieldGreen: return .fieldGreen
        case .monochrome: return .monochrome
        }
    }
}

/// The colors behind one theme. Each scale runs from lightest (index 0) to darkest; `neutral` has 19 steps
/// (0, 5, 10 … 90) and the others 10 (0, 10 … 90), matching `NovaColors`' naming.
public struct FerretPalette: Sendable {
    /// Colors for Ferret's own screens (lock screen, settings), in light and dark appearance.
    public struct Style: Sendable {
        public let paperLight: UIColor
        public let paperDark: UIColor
        public let inkLight: UIColor
        public let inkDark: UIColor
        public let bandLight: UIColor
        public let bandDark: UIColor
        public let stripeLight: UIColor
        public let stripeDark: UIColor
        public let accentLight: UIColor
        public let accentDark: UIColor
        public let cardDark: UIColor

        init(paperLight: Int, paperDark: Int, inkLight: Int, inkDark: Int, bandLight: Int, bandDark: Int,
             stripeLight: Int, stripeDark: Int, accentLight: Int, accentDark: Int, cardDark: Int) {
            self.paperLight = UIColor(rgb: paperLight)
            self.paperDark = UIColor(rgb: paperDark)
            self.inkLight = UIColor(rgb: inkLight)
            self.inkDark = UIColor(rgb: inkDark)
            self.bandLight = UIColor(rgb: bandLight)
            self.bandDark = UIColor(rgb: bandDark)
            self.stripeLight = UIColor(rgb: stripeLight)
            self.stripeDark = UIColor(rgb: stripeDark)
            self.accentLight = UIColor(rgb: accentLight)
            self.accentDark = UIColor(rgb: accentDark)
            self.cardDark = UIColor(rgb: cardDark)
        }
    }

    public let accent: [UIColor]
    public let ink: [UIColor]
    public let secondary: [UIColor]
    public let neutral: [UIColor]
    public let style: Style

    init(accent: [Int], ink: [Int], secondary: [Int], neutral: [Int], style: Style) {
        precondition(accent.count == 10 && ink.count == 10 && secondary.count == 10 && neutral.count == 19)
        self.accent = accent.map { UIColor(rgb: $0) }
        self.ink = ink.map { UIColor(rgb: $0) }
        self.secondary = secondary.map { UIColor(rgb: $0) }
        self.neutral = neutral.map { UIColor(rgb: $0) }
        self.style = style
    }

    static let classic = FerretPalette(
        accent: [0xedf1f7, 0xd6dfec, 0xb3c3da, 0x93aeda, 0x6582b1, 0x23436f, 0x1a365c, 0x132a4a, 0x0e2340, 0x0a1628],
        ink: [0xf2f1ec, 0xdee2e8, 0xc4cbd6, 0xa6b0c0, 0x8691a4, 0x677387, 0x4c576b, 0x354052, 0x212b3b, 0x0f1a2a],
        secondary: [0xfaf4e4, 0xf1e3ba, 0xe5cd8a, 0xd4b160, 0xbe943e, 0xa07a2c, 0x7e5f21, 0x5c4518, 0x3c2d10, 0x221a09],
        neutral: [
            0xfdfcf8, 0xf6f3ea, 0xeeeadf, 0xe3ded1, 0xd6d1c3, 0xc7c2b5, 0xb7b3a7, 0xa6a397, 0x949186, 0x817f75,
            0x67665e, 0x51514c, 0x3e4049, 0x2e333d, 0x242a35, 0x1b212c, 0x161b25, 0x12171f, 0x0f141b
        ],
        style: .init(paperLight: 0xf4f1e8, paperDark: 0x0b1626,
                     inkLight: 0x0e2340, inkDark: 0xede8da,
                     bandLight: 0x0e2340, bandDark: 0x16263f,
                     stripeLight: 0x9e2b2b, stripeDark: 0xc2443a,
                     accentLight: 0x1a365c, accentDark: 0x93aeda,
                     cardDark: 0x16263f)
    )

    static let sunflower = FerretPalette(
        accent: [0xe7f1fd, 0xc7dffb, 0x96c3f7, 0x7db3f5, 0x2884ee, 0x0057b7, 0x09386d, 0x072c56, 0x062548, 0x04182e],
        ink: [0xebeef3, 0xdbe2eb, 0xbfcbdb, 0x9eb0c8, 0x7791b3, 0x567398, 0x425875, 0x314156, 0x212c3b, 0x151b24],
        secondary: [0xfffadf, 0xfff1ac, 0xffe770, 0xffd500, 0xfcd200, 0xccaa00, 0x9f8400, 0x746100, 0x4c3f00, 0x2b2400],
        neutral: [
            0xfdfcf8, 0xf7f4e9, 0xf2eedb, 0xebe5c9, 0xe3dcb6, 0xdbd2a1, 0xd3c78b, 0xcabb73, 0xc0af5a, 0xb2a044,
            0x8f8036, 0x72662b, 0x274060, 0x1f334c, 0x1a2a3f, 0x152232, 0x111c2a, 0x0e1723, 0x0c141e
        ],
        style: .init(paperLight: 0xfbf7e6, paperDark: 0x071a33,
                     inkLight: 0x003a7a, inkDark: 0xfff4c2,
                     bandLight: 0x0057b7, bandDark: 0x0b2a52,
                     stripeLight: 0xffd500, stripeDark: 0xffd500,
                     accentLight: 0x0057b7, accentDark: 0x7db3f5,
                     cardDark: 0x0d2747)
    )

    static let midnightGold = FerretPalette(
        accent: [0xf9f5eb, 0xf2e8d0, 0xe6d3a7, 0xd4af5a, 0xcba54b, 0x7f6119, 0x5b481b, 0x483915, 0x3c3012, 0x271e0b],
        ink: [0xeceef2, 0xdee1e8, 0xc4c9d6, 0xa5aec1, 0x828da8, 0x626e8c, 0x4b556c, 0x373f50, 0x262b36, 0x171a22],
        secondary: [0xf9f3e5, 0xeedfbd, 0xe2c98d, 0xd7b25d, 0xca9c32, 0xa37e29, 0x7f6320, 0x5d4817, 0x3d2f0f, 0x221b09],
        neutral: [
            0xfcfbf9, 0xf5f3eb, 0xefebde, 0xe7e0cd, 0xded5bb, 0xd5c9a7, 0xcbbd93, 0xc0af7d, 0xb5a165, 0xa69150,
            0x857440, 0x6a5c33, 0x2f3b58, 0x252f46, 0x1f273a, 0x191f2e, 0x151a26, 0x111620, 0x0f121b
        ],
        style: .init(paperLight: 0xf6f2e7, paperDark: 0x0a0f1c,
                     inkLight: 0x1b1a17, inkDark: 0xe9d9a8,
                     bandLight: 0x141b2c, bandDark: 0x141b2c,
                     stripeLight: 0xb8923e, stripeDark: 0xd4af5a,
                     accentLight: 0x7f6119, accentDark: 0xd4af5a,
                     cardDark: 0x141b2c)
    )

    static let oxblood = FerretPalette(
        accent: [0xfaeaea, 0xf3cfcf, 0xe8a5a5, 0xe58c84, 0xd14545, 0x8e2424, 0x5e1818, 0x4a1313, 0x3e1010, 0x280a0a],
        ink: [0xf1eded, 0xe7dfe0, 0xd4c6c7, 0xbea8aa, 0xa48689, 0x886669, 0x684f51, 0x4d3a3c, 0x342829, 0x201919],
        secondary: [0xfaf4e4, 0xf1e3ba, 0xe5cd8a, 0xd4b160, 0xbe943e, 0xa07a2c, 0x7e5f21, 0x5c4518, 0x3c2d10, 0x221a09],
        neutral: [
            0xfcfbf9, 0xf5f2eb, 0xefe9de, 0xe7decd, 0xded2bb, 0xd5c6a7, 0xcbb893, 0xc0aa7d, 0xb59a65, 0xa68950,
            0x856e40, 0x6a5833, 0x523537, 0x412a2c, 0x362324, 0x2b1c1d, 0x241718, 0x1e1314, 0x1a1011
        ],
        style: .init(paperLight: 0xf4f1e8, paperDark: 0x1a0d0d,
                     inkLight: 0x4a1414, inkDark: 0xede8da,
                     bandLight: 0x7e2222, bandDark: 0x2e1212,
                     stripeLight: 0x0e2340, stripeDark: 0xc9c2b0,
                     accentLight: 0x8e2424, accentDark: 0xe58c84,
                     cardDark: 0x2a1515)
    )

    static let fieldGreen = FerretPalette(
        accent: [0xecf8f3, 0xd3eee3, 0xade0cb, 0x8cc7a8, 0x57bf94, 0x1f5a43, 0x20563f, 0x1a4332, 0x15392a, 0x0e241b],
        ink: [0xedf1ef, 0xe0e6e3, 0xc7d3cd, 0xaabcb3, 0x88a295, 0x698577, 0x51665c, 0x3b4c44, 0x28342e, 0x19201c],
        secondary: [0xfaf4e4, 0xf1e3ba, 0xe5cd8a, 0xd4b160, 0xbe943e, 0xa07a2c, 0x7e5f21, 0x5c4518, 0x3c2d10, 0x221a09],
        neutral: [
            0xfbfcf9, 0xf2f4ec, 0xebede0, 0xe0e3d1, 0xd5d9c0, 0xc9ceae, 0xbcc39b, 0xafb786, 0xa0aa70, 0x8f9a5c,
            0x737b4a, 0x5c623b, 0x335444, 0x284336, 0x21382d, 0x1b2c24, 0x16251e, 0x121f18, 0x101a15
        ],
        style: .init(paperLight: 0xf1efe4, paperDark: 0x0c1a14,
                     inkLight: 0x13261d, inkDark: 0xece6d2,
                     bandLight: 0x1f3a2e, bandDark: 0x13261d,
                     stripeLight: 0xb8923e, stripeDark: 0xb8923e,
                     accentLight: 0x1f5a43, accentDark: 0x8cc7a8,
                     cardDark: 0x15281f)
    )

    static let monochrome = FerretPalette(
        accent: [0xf2f2f2, 0xe1e1e1, 0xc6c6c6, 0xd0d0d0, 0x8b8b8b, 0x1a1a1a, 0x3b3b3b, 0x2f2f2f, 0x272727, 0x191919],
        ink: [0xefefef, 0xe3e3e3, 0xcdcdcd, 0xb3b3b3, 0x959595, 0x777777, 0x5c5c5c, 0x444444, 0x2e2e2e, 0x1c1c1c],
        secondary: [0xefefef, 0xd5d5d5, 0xb8b8b8, 0x9a9a9a, 0x7e7e7e, 0x666666, 0x505050, 0x3a3a3a, 0x262626, 0x161616],
        neutral: [
            0xfbfbfb, 0xf0f0f0, 0xe6e6e6, 0xdadada, 0xcccccc, 0xbebebe, 0xafafaf, 0x9e9e9e, 0x8d8d8d, 0x7b7b7b,
            0x626262, 0x4e4e4e, 0x444444, 0x363636, 0x2c2c2c, 0x242424, 0x1e1e1e, 0x181818, 0x151515
        ],
        style: .init(paperLight: 0xffffff, paperDark: 0x000000,
                     inkLight: 0x111111, inkDark: 0xf2f2f2,
                     bandLight: 0x111111, bandDark: 0x1c1c1c,
                     stripeLight: 0x111111, stripeDark: 0xf2f2f2,
                     accentLight: 0x1a1a1a, accentDark: 0xd0d0d0,
                     cardDark: 0x1c1c1e)
    )
}

/// Remembers the chosen theme. Read it anywhere; change it with `select(_:)` and then refresh the UI
/// (`ThemeManager.applyThemeUpdatesToWindows()`).
public enum FerretThemeStore {
    public static let defaultsKey = "ferret.colorTheme"
    public static let didChange = Notification.Name("FerretThemeDidChange")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedTheme = FerretTheme.classic

    public static var theme: FerretTheme {
        lock.lock()
        defer { lock.unlock() }
        return storedTheme
    }

    public static var palette: FerretPalette {
        return theme.palette
    }

    /// Restores the saved theme. Call once at launch, before any UI is themed.
    public static func load(from defaults: UserDefaults = .standard) {
        let saved = defaults.string(forKey: defaultsKey).flatMap(FerretTheme.init(rawValue:)) ?? .classic
        set(saved)
    }

    public static func select(_ theme: FerretTheme, defaults: UserDefaults = .standard) {
        set(theme)
        defaults.set(theme.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func set(_ theme: FerretTheme) {
        lock.lock()
        storedTheme = theme
        lock.unlock()
    }
}
