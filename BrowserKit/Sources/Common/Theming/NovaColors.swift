// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

// This class contains Nova colors referenced in
// https://www.figma.com/design/13nzUgAKwSiWeqvyWnp2KY/branch/XrQf2Lqhpi2s5N03lTtJ5h/iOS-Library--2025-?node-id=12098-204
// These should never be called directly; they should only be used from a Nova theme.
final class NovaColors {
    // MARK: - Black & White
    static let Black = UIColor(rgb: 0x000000)
    static let White = UIColor(rgb: 0xffffff)

    // MARK: - Gray (follows the selected Ferret theme)
    static var Gray0: UIColor { FerretThemeStore.palette.neutral[0] }
    static var Gray5: UIColor { FerretThemeStore.palette.neutral[1] }
    static var Gray10: UIColor { FerretThemeStore.palette.neutral[2] }
    static var Gray15: UIColor { FerretThemeStore.palette.neutral[3] }
    static var Gray20: UIColor { FerretThemeStore.palette.neutral[4] }
    static var Gray25: UIColor { FerretThemeStore.palette.neutral[5] }
    static var Gray30: UIColor { FerretThemeStore.palette.neutral[6] }
    static var Gray35: UIColor { FerretThemeStore.palette.neutral[7] }
    static var Gray40: UIColor { FerretThemeStore.palette.neutral[8] }
    static var Gray45: UIColor { FerretThemeStore.palette.neutral[9] }
    static var Gray50: UIColor { FerretThemeStore.palette.neutral[10] }
    static var Gray55: UIColor { FerretThemeStore.palette.neutral[11] }
    static var Gray60: UIColor { FerretThemeStore.palette.neutral[12] }
    static var Gray65: UIColor { FerretThemeStore.palette.neutral[13] }
    static var Gray70: UIColor { FerretThemeStore.palette.neutral[14] }
    static var Gray75: UIColor { FerretThemeStore.palette.neutral[15] }
    static var Gray80: UIColor { FerretThemeStore.palette.neutral[16] }
    static var Gray85: UIColor { FerretThemeStore.palette.neutral[17] }
    static var Gray90: UIColor { FerretThemeStore.palette.neutral[18] }

    // MARK: - Violet Desaturated
    static let VioletDesaturated0 = UIColor(rgb: 0xf2f0f8)
    static let VioletDesaturated10 = UIColor(rgb: 0xe2dcf2)
    static let VioletDesaturated20 = UIColor(rgb: 0xcac1e4)
    static let VioletDesaturated30 = UIColor(rgb: 0xb0a3d2)
    static let VioletDesaturated40 = UIColor(rgb: 0x9484bd)
    static let VioletDesaturated50 = UIColor(rgb: 0x75669f)
    static let VioletDesaturated60 = UIColor(rgb: 0x584a7d)
    static let VioletDesaturated70 = UIColor(rgb: 0x3e315f)
    static let VioletDesaturated80 = UIColor(rgb: 0x281d44)
    static let VioletDesaturated90 = UIColor(rgb: 0x180e30)

    // MARK: - Violet
    static let Violet0 = UIColor(rgb: 0xf5ecff)
    static let Violet10 = UIColor(rgb: 0xe5d6ff)
    static let Violet20 = UIColor(rgb: 0xcdb7ff)
    static let Violet30 = UIColor(rgb: 0xb393ff)
    static let Violet40 = UIColor(rgb: 0x956eff)
    static let Violet50 = UIColor(rgb: 0x764edd)
    static let Violet60 = UIColor(rgb: 0x5939a8)
    static let Violet70 = UIColor(rgb: 0x3e2976)
    static let Violet80 = UIColor(rgb: 0x271c48)
    static let Violet90 = UIColor(rgb: 0x161423)

    // MARK: - Purple
    static let Purple0 = UIColor(rgb: 0xfaebff)
    static let Purple10 = UIColor(rgb: 0xf1d0ff)
    static let Purple20 = UIColor(rgb: 0xe1afff)
    static let Purple30 = UIColor(rgb: 0xcd89fc)
    static let Purple40 = UIColor(rgb: 0xb561eb)
    static let Purple50 = UIColor(rgb: 0x9540c8)
    static let Purple60 = UIColor(rgb: 0x702e98)
    static let Purple70 = UIColor(rgb: 0x4f216b)
    static let Purple80 = UIColor(rgb: 0x311842)
    static let Purple90 = UIColor(rgb: 0x1a1220)

    // MARK: - Pink
    static let Pink0 = UIColor(rgb: 0xffeaf5)
    static let Pink10 = UIColor(rgb: 0xffcbea)
    static let Pink20 = UIColor(rgb: 0xffa5dc)
    static let Pink30 = UIColor(rgb: 0xf07dcd)
    static let Pink40 = UIColor(rgb: 0xd851bc)
    static let Pink50 = UIColor(rgb: 0xb32e9f)
    static let Pink60 = UIColor(rgb: 0x882078)
    static let Pink70 = UIColor(rgb: 0x5f1854)
    static let Pink80 = UIColor(rgb: 0x3c1334)
    static let Pink90 = UIColor(rgb: 0x1e111b)

    // MARK: - Red
    static let Red0 = UIColor(rgb: 0xffebe6)
    static let Red10 = UIColor(rgb: 0xffd0d7)
    static let Red20 = UIColor(rgb: 0xffa9b5)
    static let Red30 = UIColor(rgb: 0xff8090)
    static let Red40 = UIColor(rgb: 0xeb526b)
    static let Red50 = UIColor(rgb: 0xc52d4f)
    static let Red60 = UIColor(rgb: 0x961e3d)
    static let Red70 = UIColor(rgb: 0x69172d)
    static let Red80 = UIColor(rgb: 0x42121f)
    static let Red90 = UIColor(rgb: 0x211014)

    // MARK: - Orange
    static let Orange0 = UIColor(rgb: 0xffede0)
    static let Orange10 = UIColor(rgb: 0xffd4b7)
    static let Orange20 = UIColor(rgb: 0xfeb48c)
    static let Orange30 = UIColor(rgb: 0xff8f5d)
    static let Orange40 = UIColor(rgb: 0xf5672b)
    static let Orange50 = UIColor(rgb: 0xd24300)
    static let Orange60 = UIColor(rgb: 0xa02d02)
    static let Orange70 = UIColor(rgb: 0x711d08)
    static let Orange80 = UIColor(rgb: 0x47130a)
    static let Orange90 = UIColor(rgb: 0x250e0b)

    // MARK: - Yellow
    static let Yellow0 = UIColor(rgb: 0xfff9e2)
    static let Yellow10 = UIColor(rgb: 0xfae2a7)
    static let Yellow20 = UIColor(rgb: 0xf6c465)
    static let Yellow30 = UIColor(rgb: 0xf0a000)
    static let Yellow40 = UIColor(rgb: 0xd7800e)
    static let Yellow50 = UIColor(rgb: 0xb26100)
    static let Yellow60 = UIColor(rgb: 0x854800)
    static let Yellow70 = UIColor(rgb: 0x5f3100)
    static let Yellow80 = UIColor(rgb: 0x3e1d00)
    static let Yellow90 = UIColor(rgb: 0x270f00)

    // MARK: - Green
    static let Green0 = UIColor(rgb: 0xe8f7e5)
    static let Green10 = UIColor(rgb: 0xb8eed9)
    static let Green20 = UIColor(rgb: 0x7fddbd)
    static let Green30 = UIColor(rgb: 0x2dc79e)
    static let Green40 = UIColor(rgb: 0x00ab81)
    static let Green50 = UIColor(rgb: 0x008865)
    static let Green60 = UIColor(rgb: 0x06674b)
    static let Green70 = UIColor(rgb: 0x004933)
    static let Green80 = UIColor(rgb: 0x003020)
    static let Green90 = UIColor(rgb: 0x001e12)

    // MARK: - Cyan
    static let Cyan0 = UIColor(rgb: 0xe7f5f7)
    static let Cyan10 = UIColor(rgb: 0xbae9f3)
    static let Cyan20 = UIColor(rgb: 0x85d6e9)
    static let Cyan30 = UIColor(rgb: 0x41bdda)
    static let Cyan40 = UIColor(rgb: 0x00a1c7)
    static let Cyan50 = UIColor(rgb: 0x0a809f)
    static let Cyan60 = UIColor(rgb: 0x066077)
    static let Cyan70 = UIColor(rgb: 0x034554)
    static let Cyan80 = UIColor(rgb: 0x002d38)
    static let Cyan90 = UIColor(rgb: 0x011c23)

    // MARK: - Blue
    static let Blue0 = UIColor(rgb: 0xe1f5ff)
    static let Blue10 = UIColor(rgb: 0xbae5ff)
    static let Blue20 = UIColor(rgb: 0x95cbfe)
    static let Blue30 = UIColor(rgb: 0x70abff)
    static let Blue40 = UIColor(rgb: 0x5583ff)
    static let Blue50 = UIColor(rgb: 0x455fe7)
    static let Blue60 = UIColor(rgb: 0x3246b0)
    static let Blue70 = UIColor(rgb: 0x23327b)
    static let Blue80 = UIColor(rgb: 0x17214c)
    static let Blue90 = UIColor(rgb: 0x111524)

    // MARK: - Navy (follows the selected Ferret theme)
    static var Navy0: UIColor { FerretThemeStore.palette.accent[0] }
    static var Navy10: UIColor { FerretThemeStore.palette.accent[1] }
    static var Navy20: UIColor { FerretThemeStore.palette.accent[2] }
    static var Navy30: UIColor { FerretThemeStore.palette.accent[3] }
    static var Navy40: UIColor { FerretThemeStore.palette.accent[4] }
    static var Navy50: UIColor { FerretThemeStore.palette.accent[5] }
    static var Navy60: UIColor { FerretThemeStore.palette.accent[6] }
    static var Navy70: UIColor { FerretThemeStore.palette.accent[7] }
    static var Navy80: UIColor { FerretThemeStore.palette.accent[8] }
    static var Navy90: UIColor { FerretThemeStore.palette.accent[9] }

    // MARK: - Slate (follows the selected Ferret theme)
    static var Slate0: UIColor { FerretThemeStore.palette.ink[0] }
    static var Slate10: UIColor { FerretThemeStore.palette.ink[1] }
    static var Slate20: UIColor { FerretThemeStore.palette.ink[2] }
    static var Slate30: UIColor { FerretThemeStore.palette.ink[3] }
    static var Slate40: UIColor { FerretThemeStore.palette.ink[4] }
    static var Slate50: UIColor { FerretThemeStore.palette.ink[5] }
    static var Slate60: UIColor { FerretThemeStore.palette.ink[6] }
    static var Slate70: UIColor { FerretThemeStore.palette.ink[7] }
    static var Slate80: UIColor { FerretThemeStore.palette.ink[8] }
    static var Slate90: UIColor { FerretThemeStore.palette.ink[9] }

    // MARK: - Oxblood
    static let Oxblood0 = UIColor(rgb: 0xf8eceb)
    static let Oxblood10 = UIColor(rgb: 0xefd0ce)
    static let Oxblood20 = UIColor(rgb: 0xe0a9a6)
    static let Oxblood30 = UIColor(rgb: 0xce7f7b)
    static let Oxblood40 = UIColor(rgb: 0xb85651)
    static let Oxblood50 = UIColor(rgb: 0x9e2b2b)
    static let Oxblood60 = UIColor(rgb: 0x7e2222)
    static let Oxblood70 = UIColor(rgb: 0x5e1a1a)
    static let Oxblood80 = UIColor(rgb: 0x3f1313)
    static let Oxblood90 = UIColor(rgb: 0x220c0c)

    // MARK: - Brass (follows the selected Ferret theme)
    static var Brass0: UIColor { FerretThemeStore.palette.secondary[0] }
    static var Brass10: UIColor { FerretThemeStore.palette.secondary[1] }
    static var Brass20: UIColor { FerretThemeStore.palette.secondary[2] }
    static var Brass30: UIColor { FerretThemeStore.palette.secondary[3] }
    static var Brass40: UIColor { FerretThemeStore.palette.secondary[4] }
    static var Brass50: UIColor { FerretThemeStore.palette.secondary[5] }
    static var Brass60: UIColor { FerretThemeStore.palette.secondary[6] }
    static var Brass70: UIColor { FerretThemeStore.palette.secondary[7] }
    static var Brass80: UIColor { FerretThemeStore.palette.secondary[8] }
    static var Brass90: UIColor { FerretThemeStore.palette.secondary[9] }
}
