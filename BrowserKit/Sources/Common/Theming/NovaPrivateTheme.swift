// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

public struct NovaPrivateTheme: Theme {
    public var type: ThemeType = .privateMode
    private let palette = NovaPrivateColourPalette()
    public var colors: ThemeColourPalette { palette }
    public var isNova = true

    public init() {}
}

private struct NovaPrivateColourPalette: ThemeColourPalette {
    // MARK: - Layer

    var layer1: UIColor = NovaColors.Slate90
    var layer2: UIColor = NovaColors.Slate60
    var layer3: UIColor = NovaColors.Slate70
    var layer4: UIColor = NovaColors.Slate80
    var layer5Hover: UIColor = NovaColors.Slate70
    var layerSurfaceLow = NovaColors.Slate90
    var layerSurfaceMedium = NovaColors.Slate80
    var layerSurfaceMediumAlt: UIColor = NovaColors.Slate70
    var layerSurfaceMediumAltGlass = NovaColors.Slate80
    var layerSurfaceMediumAlpha = NovaColors.Slate80.withAlphaComponent(0.4)
    var layerAccentSubtle: UIColor = NovaColors.Navy70
    var layerInverse: UIColor = NovaColors.Gray30
    var layerWarning: UIColor = NovaColors.Yellow70
    var layerSuccess: UIColor = NovaColors.Green70
    var layerCritical: UIColor = NovaColors.Red70
    var layerInformation: UIColor = NovaColors.Blue70
    var layerSepia: UIColor = NovaColors.Yellow0
    var layerAutofillText: UIColor = NovaColors.Slate30.withAlphaComponent(0.55)
    var layerSelectedText: UIColor = NovaColors.Slate30.withAlphaComponent(0.55)
    var layerGlassTintNova: UIColor = .clear
    var layerGlassSelectedFill: UIColor = NovaColors.Slate90
    var layerAccentPrivateNonOpaque: UIColor { layerAccentSubtle }
    var layerToolbarGlass: UIColor = NovaColors.Slate60

    // MARK: - Action

    var actionPrimary: UIColor = NovaColors.Navy30
    var actionPrimaryHover: UIColor = NovaColors.Navy40
    var actionPrimaryDisabled: UIColor = NovaColors.Navy30.withAlphaComponent(0.4)
    var actionSecondary: UIColor = NovaColors.Gray55
    var actionSecondaryHover: UIColor = NovaColors.Gray60
    var actionSecondaryDisabled: UIColor = NovaColors.Gray55.withAlphaComponent(0.5)
    var actionWarning: UIColor = NovaColors.Yellow30
    var actionSuccess: UIColor = NovaColors.Green30
    var actionCritical: UIColor = NovaColors.Red30
    var actionInformation: UIColor = NovaColors.Blue30
    var formKnob: UIColor = NovaColors.White
    var formSurfaceOff: UIColor = NovaColors.Gray55
    var actionTabActive: UIColor = NovaColors.Slate80
    var actionTabInactive: UIColor = NovaColors.Slate90
    var actionCloseButton: UIColor = NovaColors.Slate80

    // MARK: - Text

    var textPrimary: UIColor = NovaColors.Slate0
    var textSecondary: UIColor = NovaColors.Slate0.withAlphaComponent(0.7)
    var textDisabled: UIColor = NovaColors.Slate0.withAlphaComponent(0.4)
    var textAccent: UIColor = NovaColors.Navy30
    var textCritical: UIColor = NovaColors.Red30
    var textInverted: UIColor = NovaColors.Slate90
    var textInvertedDisabled: UIColor = NovaColors.Slate90.withAlphaComponent(0.4)
    var textOnDark: UIColor = NovaColors.Slate0
    var textOnLight: UIColor = NovaColors.Slate90
    var textColorPrimary: UIColor = NovaColors.Slate0
    var textToast: UIColor = NovaColors.Navy70

    // MARK: - Icon

    var iconPrimary: UIColor = NovaColors.Slate0
    var iconSecondary: UIColor = NovaColors.Slate0.withAlphaComponent(0.7)
    var iconDisabled: UIColor = NovaColors.Slate0.withAlphaComponent(0.4)
    var iconAccent: UIColor = NovaColors.Navy30
    var iconCritical: UIColor = NovaColors.Red30
    var iconInverted: UIColor = NovaColors.Slate90
    var iconOnColor: UIColor = NovaColors.Slate0
    var iconOnColorDisabled: UIColor = NovaColors.Slate0.withAlphaComponent(0.4)
    var iconSpinner: UIColor = NovaColors.Gray40
    var iconPrivate: UIColor = NovaColors.Navy50

    // MARK: - Border

    var borderPrimary: UIColor = NovaColors.Slate70
    var borderStrong: UIColor = NovaColors.Slate60
    var borderInverted: UIColor = NovaColors.Gray15
    var borderAccentToast: UIColor = NovaColors.Navy70
    var borderRadioButtonDefault: UIColor = NovaColors.Gray45

    // MARK: - Shadow

    var shadowSubtle: UIColor = NovaColors.Gray80.withAlphaComponent(0.10)
    var shadowDefault: UIColor = NovaColors.Gray80.withAlphaComponent(0.12)
    var shadowStrong: UIColor = NovaColors.Gray80.withAlphaComponent(0.16)
    var shadowBorder: UIColor = NovaColors.Gray65.withAlphaComponent(0.50)

    // MARK: - Gradients

    var gradient = Gradient(colors: [NovaColors.Navy60, NovaColors.Navy50])
    var gradientAccent = Gradient(colors: [NovaColors.Navy30, NovaColors.Navy50])
    var gradientAccentSubtle = Gradient(colors: [
        NovaColors.Slate90,
        NovaColors.Slate90
    ])
    var gradientAIStrong = Gradient(colors: [
        NovaColors.Navy50,
        NovaColors.Oxblood40,
        NovaColors.Brass30
    ])
    var gradientBorder = Gradient(colors: [NovaColors.Navy30, NovaColors.Navy50])
    var gradientPrivacy = Gradient(colors: [
        NovaColors.Navy40,
        NovaColors.Navy20
    ])
    var gradientPrivacyMask = Gradient(colors: [NovaColors.White, NovaColors.Navy20])
    var gradientWidgetSurface = Gradient(colors: [.clear]) // widgets don't have private mode
    var gradientWidgetSurfaceStandard = Gradient(colors: [.clear]) // widgets don't have private mode
    var gradientWidgetSurfacePrivate = Gradient(colors: [.clear]) // widgets don't have private mode
    var gradientAIStrongStop1: UIColor = NovaColors.Navy50
    var gradientAIStrongStop2: UIColor = NovaColors.Oxblood40
    var gradientAIStrongStop3: UIColor = NovaColors.Brass30

    // Default values from PrivateModeTheme
    var layerGradient: Gradient = PrivateModeTheme().colors.layerGradient
    var layerGradientURL: Gradient = PrivateModeTheme().colors.layerGradientURL
    var layerGradientSummary: Gradient = PrivateModeTheme().colors.layerGradientSummary
    var layerScrim: UIColor = PrivateModeTheme().colors.layerScrim
    var layerCriticalSubdued: UIColor = PrivateModeTheme().colors.layerCriticalSubdued
    var layerEmphasis: UIColor = PrivateModeTheme().colors.layerEmphasis
    var indicatorActive: UIColor = PrivateModeTheme().colors.indicatorActive
    var indicatorInactive: UIColor = PrivateModeTheme().colors.indicatorInactive
    var iconAccentViolet: UIColor = PrivateModeTheme().colors.iconAccentViolet
    var iconAccentBlue: UIColor = PrivateModeTheme().colors.iconAccentBlue
    var iconAccentPink: UIColor = PrivateModeTheme().colors.iconAccentPink
    var iconAccentGreen: UIColor = PrivateModeTheme().colors.iconAccentGreen
    var iconAccentYellow: UIColor = PrivateModeTheme().colors.iconAccentYellow

    // MARK: - Deprecated
    var layer5: UIColor { layerSurfaceMedium }
    var layerGradientOverlay: Gradient = PrivateModeTheme().colors.layerGradientOverlay
    var layerHomepage: Gradient = PrivateModeTheme().colors.layerHomepage
    var layerAccentNonOpaque: UIColor = PrivateModeTheme().colors.layerAccentNonOpaque
    var layerAccentPrivate: UIColor = PrivateModeTheme().colors.layerAccentPrivate
    var gradientOnboardingStop1: UIColor = PrivateModeTheme().colors.gradientOnboardingStop1
    var gradientOnboardingStop2: UIColor = PrivateModeTheme().colors.gradientOnboardingStop2
    var gradientOnboardingStop3: UIColor = PrivateModeTheme().colors.gradientOnboardingStop3
    var gradientOnboardingStop4: UIColor = PrivateModeTheme().colors.gradientOnboardingStop4
    var iconRatingNeutral: UIColor = PrivateModeTheme().colors.iconRatingNeutral
    var borderSecondary: UIColor = PrivateModeTheme().colors.borderSecondary
    var borderAccent: UIColor = PrivateModeTheme().colors.borderAccent
    var borderAccentNonOpaque: UIColor = PrivateModeTheme().colors.borderAccentNonOpaque
    var borderAccentPrivate: UIColor = PrivateModeTheme().colors.borderAccentPrivate
    var borderToolbarDivider: UIColor = PrivateModeTheme().colors.borderToolbarDivider

    var faviconLetterColorSet: FaviconLetterColorSet = NovaFaviconColorSet()
}
