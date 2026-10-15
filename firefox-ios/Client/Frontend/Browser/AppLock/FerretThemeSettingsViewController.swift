// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

/// Settings → Color Theme: restyles the whole app, and optionally switches the home screen icon to match.
@MainActor
final class FerretThemeSettingsViewController: UITableViewController {
    static let matchIconKey = "ferret.colorTheme.matchIcon"

    private let themeManager: ThemeManager
    private let defaults: UserDefaults

    init(themeManager: ThemeManager = AppContainer.shared.resolve(), defaults: UserDefaults = .standard) {
        self.themeManager = themeManager
        self.defaults = defaults
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whether picking a theme also changes the app icon. On unless turned off.
    static func matchesIcon(_ defaults: UserDefaults) -> Bool {
        return defaults.object(forKey: matchIconKey) as? Bool ?? true
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        FerretStyle.styleCell(cell)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        FerretStyle.styleTable(tableView)
        title = "Color Theme"
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? FerretTheme.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 0
            ? "Changes colors throughout Ferret, in light and dark mode and in private browsing."
            : "iOS will confirm the change. You can also pick any icon under Settings → App Icon."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard indexPath.section == 0 else {
            cell.textLabel?.text = "Change App Icon to Match"
            let toggle = UISwitch()
            toggle.isOn = Self.matchesIcon(defaults)
            toggle.accessibilityLabel = "Change App Icon to Match"
            toggle.addTarget(self, action: #selector(matchToggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
            return cell
        }
        let theme = FerretTheme.allCases[indexPath.row]
        cell.textLabel?.text = theme.displayName
        cell.detailTextLabel?.text = theme.summary
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        cell.imageView?.image = Self.thumbnail(UIImage(named: AppIcon(theme: theme).imageSetAssetName))
        cell.accessoryType = theme == FerretThemeStore.theme ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        apply(FerretTheme.allCases[indexPath.row])
    }

    private func apply(_ theme: FerretTheme) {
        guard theme != FerretThemeStore.theme else { return }
        FerretThemeStore.select(theme, defaults: defaults)
        themeManager.applyThemeUpdatesToWindows()
        FerretStyle.styleTable(tableView)
        tableView.reloadData()

        let icon = AppIcon(theme: theme)
        guard Self.matchesIcon(defaults),
              UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != icon.appIconAssetName else { return }
        UIApplication.shared.setAlternateIconName(icon.appIconAssetName) { _ in }
    }

    @objc
    private func matchToggled(_ sender: UISwitch) {
        defaults.set(sender.isOn, forKey: Self.matchIconKey)
    }

    private static func thumbnail(_ image: UIImage?) -> UIImage? {
        guard let image else { return nil }
        let size = CGSize(width: 40, height: 40)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 9).addClip()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The row in Settings → General that opens the color themes.
final class FerretThemeSetting: Setting {
    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var status: NSAttributedString? {
        return NSAttributedString(string: FerretThemeStore.theme.displayName)
    }

    init(theme: Theme) {
        super.init(title: NSAttributedString(string: "Color Theme",
                                             attributes: [.foregroundColor: theme.colors.textPrimary]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(FerretThemeSettingsViewController(), animated: true)
    }
}
