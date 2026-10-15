// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

/// Settings → Passcode & Data Protection.
@MainActor
final class AppLockSettingsViewController: UITableViewController {
    private enum Row {
        case pinToggle
        case changePIN
        case biometrics(String)
        case autoLock
        case lockNow
        case dataProtection
    }

    private let manager: AppLockManager
    private var sections: [[Row]] = []

    init(manager: AppLockManager = .shared) {
        self.manager = manager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Passcode & Data Protection"
        rebuild()
    }

    private func rebuild() {
        var lock: [Row] = [.pinToggle]
        if manager.isEnabled {
            lock.append(.changePIN)
            if let name = manager.biometryName { lock.append(.biometrics(name)) }
            lock.append(.autoLock)
            lock.append(.lockNow)
        }
        sections = [lock, [.dataProtection]]
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "PIN Lock" : "Encryption"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return manager.isEnabled
                ? "Ferret asks for your PIN when it opens and hides your tabs in the app switcher. "
                    + "After 5 wrong PINs you'll have to wait before trying again."
                : "Require a 6-digit PIN to open Ferret."
        }
        return "Encrypts history, tabs, cookies, website data, saved passwords, extensions and ad-blocking data "
            + "with a key that only exists while your iPhone is unlocked. Downloads and pages that are already "
            + "open keep working in the background."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch sections[indexPath.section][indexPath.row] {
        case .pinToggle:
            cell.textLabel?.text = "Require PIN"
            cell.accessoryView = makeSwitch(isOn: manager.isEnabled,
                                            action: #selector(pinToggled(_:)),
                                            label: "Require PIN")
            cell.selectionStyle = .none
        case .changePIN:
            cell.textLabel?.text = "Change PIN"
            cell.textLabel?.textColor = .systemOrange
        case .biometrics(let name):
            cell.textLabel?.text = "Unlock with \(name)"
            cell.accessoryView = makeSwitch(isOn: manager.usesBiometrics,
                                            action: #selector(biometricsToggled(_:)),
                                            label: "Unlock with \(name)")
            cell.selectionStyle = .none
        case .autoLock:
            cell.textLabel?.text = "Require PIN"
            cell.detailTextLabel?.text = manager.autoLock.title
            cell.accessoryType = .disclosureIndicator
        case .lockNow:
            cell.textLabel?.text = "Lock Now"
            cell.textLabel?.textColor = .systemOrange
        case .dataProtection:
            cell.textLabel?.text = "Protect Data While Locked"
            cell.accessoryView = makeSwitch(isOn: DataProtectionManager.isEnabled,
                                            action: #selector(dataProtectionToggled(_:)),
                                            label: "Protect Data While Locked")
            cell.selectionStyle = .none
        }
        return cell
    }

    private func makeSwitch(isOn: Bool, action: Selector, label: String) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.accessibilityLabel = label
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .changePIN:
            verifyThen { [weak self] in self?.createPIN() }
        case .autoLock:
            showAutoLockChoices(from: tableView.cellForRow(at: indexPath))
        case .lockNow:
            manager.lockNow()
        default:
            break
        }
    }

    // MARK: - Actions

    @objc
    private func pinToggled(_ sender: UISwitch) {
        if sender.isOn {
            createPIN()
        } else {
            verifyThen { [weak self] in
                self?.manager.disable()
                self?.rebuild()
            }
        }
        rebuild()
    }

    @objc
    private func biometricsToggled(_ sender: UISwitch) {
        manager.usesBiometrics = sender.isOn
    }

    @objc
    private func dataProtectionToggled(_ sender: UISwitch) {
        DataProtectionManager.setEnabled(sender.isOn)
    }

    private func createPIN() {
        let controller = AppLockViewController(mode: .create { [weak self] pin in
            if let pin { self?.manager.enable(pin: pin) }
            self?.rebuild()
        }, manager: manager)
        present(controller, animated: true)
    }

    private func verifyThen(_ action: @escaping @MainActor () -> Void) {
        let controller = AppLockViewController(mode: .verify { [weak self] verified in
            if verified { action() }
            self?.rebuild()
        }, manager: manager)
        present(controller, animated: true)
    }

    private func showAutoLockChoices(from sourceView: UIView?) {
        let sheet = UIAlertController(title: "Require PIN", message: nil, preferredStyle: .actionSheet)
        for option in AppLockManager.AutoLock.allCases {
            let title = option == manager.autoLock ? "✓ " + option.title : option.title
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.manager.autoLock = option
                self?.rebuild()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView ?? view
        present(sheet, animated: true)
    }
}

/// The row in Settings → Privacy that opens the lock settings.
final class AppLockSetting: Setting {
    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var status: NSAttributedString? {
        let text = AppLockManager.shared.isEnabled ? "PIN on" : "PIN off"
        return NSAttributedString(string: text)
    }

    init(theme: Theme) {
        super.init(title: NSAttributedString(string: "Passcode & Data Protection",
                                             attributes: [.foregroundColor: theme.colors.textPrimary]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(AppLockSettingsViewController(), animated: true)
    }
}
