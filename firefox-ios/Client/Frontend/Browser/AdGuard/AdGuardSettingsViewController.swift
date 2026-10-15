// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

/// Menu → Extensions → AdGuard Ad Blocking.
@MainActor
final class AdGuardSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case main
        case currentSite
        case ads
        case privacy
        case annoyances
        case custom
        case advanced
    }

    private let manager: AdGuardManager
    private let currentSiteURL: URL?

    init(manager: AdGuardManager = .shared, currentSiteURL: URL?) {
        self.manager = manager
        self.currentSiteURL = currentSiteURL
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AdGuard Ad Blocking"
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reload),
                                               name: .adGuardStateDidChange,
                                               object: nil)
        manager.startIfNeeded()
    }

    @objc
    private func reload() {
        tableView.reloadData()
    }

    private var settings: AdGuardSettings { manager.settings }

    private var currentHost: String? {
        guard let url = currentSiteURL, ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return AdGuardRuleBuilder.hostname(from: url.absoluteString)
    }

    private func filters(in section: Section) -> [AdGuardFilter] {
        switch section {
        case .ads: return settings.allFilters.filter { $0.group == .ads }
        case .privacy: return settings.allFilters.filter { $0.group == .privacy }
        case .annoyances: return settings.allFilters.filter { $0.group == .annoyances }
        case .custom: return settings.customFilters
        default: return []
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .main: return settings.isEnabled ? 2 : 1
        case .currentSite: return settings.isEnabled && currentHost != nil ? 1 : 0
        case .ads, .privacy, .annoyances: return settings.isEnabled ? filters(in: section).count : 0
        case .custom: return settings.isEnabled ? settings.customFilters.count + 1 : 0
        case .advanced: return settings.isEnabled ? 2 : 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard settings.isEnabled, let section = Section(rawValue: section) else { return nil }
        switch section {
        case .main: return nil
        case .currentSite: return currentHost == nil ? nil : "This Site"
        case .ads: return AdGuardFilter.Group.ads.title
        case .privacy: return AdGuardFilter.Group.privacy.title
        case .annoyances: return AdGuardFilter.Group.annoyances.title
        case .custom: return AdGuardFilter.Group.custom.title
        case .advanced: return "Your Rules"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .main:
            return statusText()
        case .custom:
            return settings.isEnabled ? "Add any filter list in AdGuard or Adblock Plus format by its URL." : nil
        case .advanced:
            return settings.isEnabled
                ? "Filtering by AdGuard's open-source filter lists and SafariConverterLib. Rules WebKit can't run "
                    + "(such as $redirect, $removeparam and header changes) are skipped."
                : nil
        default:
            return nil
        }
    }

    private func statusText() -> String {
        guard settings.isEnabled else { return "Ads and trackers aren't being blocked." }
        if manager.isUpdating { return "Updating filters…" }
        var lines: [String] = []
        if let state = manager.compiledState {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let blocking = formatter.string(from: NSNumber(value: state.safariRuleCount)) ?? "\(state.safariRuleCount)"
            let advanced = formatter.string(from: NSNumber(value: state.advancedRuleCount)) ?? "\(state.advancedRuleCount)"
            lines.append("\(blocking) blocking rules and \(advanced) page rules active.")
        } else {
            lines.append("Filters haven't been downloaded yet.")
        }
        if let updated = settings.lastUpdated {
            let relative = RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: Date())
            lines.append("Updated \(relative).")
        }
        if let error = settings.lastUpdateError {
            lines.append(error)
        }
        return lines.joined(separator: " ")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .main:
            if indexPath.row == 0 {
                cell.textLabel?.text = "Block Ads and Trackers"
                cell.accessoryView = makeSwitch(isOn: settings.isEnabled, tag: -1,
                                                label: "Block Ads and Trackers")
                cell.selectionStyle = .none
            } else {
                cell.textLabel?.text = manager.isUpdating ? "Updating…" : "Update Filters Now"
                cell.textLabel?.textColor = manager.isUpdating ? .secondaryLabel : FerretStyle.accent
            }
        case .currentSite:
            let host = currentHost ?? ""
            let allowed = settings.allowlist.contains(host)
            cell.textLabel?.text = allowed ? "Turn Blocking Back On for \(host)" : "Don't Block on \(host)"
            cell.textLabel?.textColor = FerretStyle.accent
            cell.detailTextLabel?.text = "Reload the page afterwards."
        case .ads, .privacy, .annoyances:
            let filter = filters(in: section)[indexPath.row]
            configureFilterCell(cell, filter: filter, tag: indexPath.section * 1000 + indexPath.row)
        case .custom:
            if indexPath.row < settings.customFilters.count {
                let filter = settings.customFilters[indexPath.row]
                configureFilterCell(cell, filter: filter, tag: indexPath.section * 1000 + indexPath.row)
            } else {
                cell.textLabel?.text = "Add Filter List…"
                cell.textLabel?.textColor = FerretStyle.accent
            }
        case .advanced:
            if indexPath.row == 0 {
                let count = AdGuardRuleBuilder.userRuleLines(settings.userRules).count
                cell.textLabel?.text = "Custom Rules"
                cell.detailTextLabel?.text = count == 0 ? "None" : "\(count) rule\(count == 1 ? "" : "s")"
            } else {
                cell.textLabel?.text = "Sites Not Blocked"
                cell.detailTextLabel?.text = settings.allowlist.isEmpty ? "None" : settings.allowlist.joined(separator: ", ")
            }
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    private func configureFilterCell(_ cell: UITableViewCell, filter: AdGuardFilter, tag: Int) {
        cell.textLabel?.text = filter.name
        cell.detailTextLabel?.text = filter.summary
        cell.accessoryView = makeSwitch(isOn: settings.enabledFilterIDs.contains(filter.id), tag: tag, label: filter.name)
        cell.selectionStyle = .none
    }

    private func makeSwitch(isOn: Bool, tag: Int, label: String) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.tag = tag
        toggle.accessibilityLabel = label
        toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
        return toggle
    }

    @objc
    private func switchChanged(_ sender: UISwitch) {
        if sender.tag == -1 {
            manager.updateSettings(recompile: false) { $0.isEnabled = sender.isOn }
            tableView.reloadData()
            return
        }
        guard let section = Section(rawValue: sender.tag / 1000) else { return }
        let list = section == .custom ? settings.customFilters : filters(in: section)
        let row = sender.tag % 1000
        guard row < list.count else { return }
        let id = list[row].id
        let needsDownload = sender.isOn && manager.store.cachedFilterText(for: list[row]) == nil
        manager.updateSettings(recompile: !needsDownload) { settings in
            if sender.isOn {
                settings.enabledFilterIDs.insert(id)
            } else {
                settings.enabledFilterIDs.remove(id)
            }
        }
        if needsDownload {
            Task { await manager.updateFilters(downloading: true) }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .main where indexPath.row == 1 && !manager.isUpdating:
            Task { await manager.updateFilters(downloading: true) }
        case .currentSite:
            guard let host = currentHost else { return }
            manager.setAllowlisted(!settings.allowlist.contains(host), host: host)
        case .custom where indexPath.row == settings.customFilters.count:
            promptForCustomFilter()
        case .advanced:
            let editor: UIViewController = indexPath.row == 0
                ? AdGuardRulesEditorViewController(manager: manager)
                : AdGuardAllowlistViewController(manager: manager)
            navigationController?.pushViewController(editor, animated: true)
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .custom, indexPath.row < settings.customFilters.count else {
            return nil
        }
        let filter = settings.customFilters[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            self?.manager.updateSettings(recompile: true) { settings in
                settings.customFilters.removeAll { $0.id == filter.id }
                settings.enabledFilterIDs.remove(filter.id)
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    private func promptForCustomFilter() {
        let alert = UIAlertController(title: "Add Filter List",
                                      message: "Enter the URL of a filter list.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com/filter.txt"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else { return }
            let filter = AdGuardFilterCatalog.customFilter(url: url)
            self.manager.updateSettings(recompile: false) { settings in
                guard !settings.customFilters.contains(where: { $0.id == filter.id }) else { return }
                settings.customFilters.append(filter)
                settings.enabledFilterIDs.insert(filter.id)
            }
            Task { await self.manager.updateFilters(downloading: true) }
        })
        present(alert, animated: true)
    }
}

/// Edits the person's own AdGuard rules.
@MainActor
final class AdGuardRulesEditorViewController: UIViewController {
    private let manager: AdGuardManager
    private let textView = UITextView()

    init(manager: AdGuardManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Custom Rules"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save,
                                                            target: self,
                                                            action: #selector(save))
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.text = manager.settings.userRules.isEmpty
            ? "! One rule per line, in AdGuard syntax. For example:\n! ||ads.example.com^\n! example.com##.banner\n"
            : manager.settings.userRules
        textView.accessibilityLabel = "Custom rules"
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
    }

    @objc
    private func save() {
        let text = textView.text ?? ""
        manager.updateSettings(recompile: true) { $0.userRules = text }
        navigationController?.popViewController(animated: true)
    }
}

/// Lists sites where blocking is off.
@MainActor
final class AdGuardAllowlistViewController: UITableViewController {
    private let manager: AdGuardManager

    init(manager: AdGuardManager) {
        self.manager = manager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sites Not Blocked"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                            target: self,
                                                            action: #selector(addSite))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(manager.settings.allowlist.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "Ads and trackers aren't blocked on these sites or their subdomains."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let list = manager.settings.allowlist
        if list.isEmpty {
            cell.textLabel?.text = "No sites"
            cell.textLabel?.textColor = .secondaryLabel
        } else {
            cell.textLabel?.text = list[indexPath.row]
        }
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let list = manager.settings.allowlist
        guard indexPath.row < list.count else { return nil }
        let host = list[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            self?.manager.setAllowlisted(false, host: host)
            self?.tableView.reloadData()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    @objc
    private func addSite() {
        let alert = UIAlertController(title: "Don't Block on a Site", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "example.com"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self, let host = AdGuardRuleBuilder.hostname(from: alert?.textFields?.first?.text ?? "") else {
                return
            }
            self.manager.setAllowlisted(true, host: host)
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }
}
