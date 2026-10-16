// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared

/// Privacy-first settings for a new install: no usage data, crash reports or studies sent to Mozilla,
/// strict tracking protection, and no search-as-you-type suggestions sent to the search engine.
/// Applied once, so anything changed afterwards in Settings stays changed.
enum SecureDefaults {
    static let appliedKey = "ferret.secureDefaultsApplied"

    static let disabledPrefs = [
        AppConstants.prefSendUsageData,
        AppConstants.prefSendCrashReports,
        AppConstants.prefSendDailyUsagePing,
        AppConstants.prefStudiesToggle,
        PrefsKeys.SearchSettings.showSearchSuggestions,
        PrefsKeys.SearchSettings.showFirefoxSponsoredSuggestions
    ]

    static func apply(to prefs: Prefs) {
        guard prefs.boolForKey(appliedKey) != true else { return }
        for key in disabledPrefs {
            prefs.setBool(false, forKey: key)
        }
        prefs.setBool(true, forKey: ContentBlockingConfig.Prefs.EnabledKey)
        prefs.setString(BlockingStrength.strict.rawValue, forKey: ContentBlockingConfig.Prefs.StrengthKey)
        prefs.setBool(true, forKey: appliedKey)
    }
}
