// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

/// Settings → NordVPN Proxy.
@MainActor
final class NordProxySettingsViewController: UITableViewController, UITextFieldDelegate {
    private enum Row {
        case toggle
        case username
        case password
        case country
        case region
        case city
        case server
        case switchServer
        case check
    }

    private let manager: NordProxyManager
    private var sections: [[Row]] = []
    private var isBusy = false
    private let usernameField = UITextField()
    private let passwordField = UITextField()

    init(manager: NordProxyManager = .shared) {
        self.manager = manager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "NordVPN Proxy"
        configureField(usernameField, placeholder: "Service username", secure: false)
        configureField(passwordField, placeholder: "Service password", secure: true)
        usernameField.text = manager.store.username
        passwordField.text = manager.store.password
        rebuild()
    }

    private func configureField(_ field: UITextField, placeholder: String, secure: Bool) {
        field.placeholder = placeholder
        field.isSecureTextEntry = secure
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.textContentType = secure ? .password : .username
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    private func rebuild() {
        sections = [[.toggle]]
        if NordProxyManager.isSupported {
            sections.append([.username, .password])
            let location: [Row] = manager.store.country == nil ? [.country] : [.country, .region, .city]
            sections.append(location + [.server, .switchServer])
            sections.append([.check])
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 1: return "Service Credentials"
        case 2: return "Server"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return toggleFooter
        case 1:
            return "These are not your NordVPN email and password. Find them at my.nordaccount.com → NordVPN → "
                + "Set up NordVPN manually → Service credentials."
        case 2:
            return "Ferret picks the least busy of NordVPN's encrypted HTTPS proxy servers in the location you "
                + "choose. Only places with proxy servers are listed. Reload open pages after switching."
        default:
            return "Asks NordVPN which IP address your browsing traffic comes from."
        }
    }

    private var toggleFooter: String {
        guard NordProxyManager.isSupported else {
            return "Requires iOS 17 or later."
        }
        if manager.route == .blocked {
            return "Pages won't load until your service credentials and a server are set, so nothing leaks "
                + "outside the proxy."
        }
        return "Routes Ferret's tabs, including private tabs, through NordVPN without turning on a VPN "
            + "for the rest of your iPhone."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch sections[indexPath.section][indexPath.row] {
        case .toggle:
            cell.textLabel?.text = "Use NordVPN Proxy"
            let toggle = UISwitch()
            toggle.isOn = manager.store.isEnabled
            toggle.isEnabled = NordProxyManager.isSupported && !isBusy
            toggle.accessibilityLabel = "Use NordVPN Proxy"
            toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .username:
            embed(usernameField, in: cell)
        case .password:
            embed(passwordField, in: cell)
        case .country:
            cell.textLabel?.text = "Country"
            cell.detailTextLabel?.text = manager.store.country?.name ?? "Fastest Available"
            cell.accessoryType = .disclosureIndicator
        case .region:
            cell.textLabel?.text = "Region"
            cell.detailTextLabel?.text = manager.store.region?.name ?? "Any Region"
            cell.accessoryType = .disclosureIndicator
        case .city:
            cell.textLabel?.text = "City"
            cell.detailTextLabel?.text = manager.store.city?.name ?? "Any City"
            cell.accessoryType = .disclosureIndicator
        case .server:
            cell.textLabel?.text = "Server"
            cell.detailTextLabel?.text = isBusy ? "Finding…" : (manager.store.hostname ?? "None")
            cell.selectionStyle = .none
        case .switchServer:
            cell.textLabel?.text = "Find Another Server"
            cell.textLabel?.textColor = isBusy ? .secondaryLabel : FerretStyle.accent
        case .check:
            cell.textLabel?.text = "Check Connection"
            cell.textLabel?.textColor = isBusy ? .secondaryLabel : FerretStyle.accent
        }
        return cell
    }

    private func embed(_ field: UITextField, in cell: UITableViewCell) {
        cell.selectionStyle = .none
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isBusy else { return }
        switch sections[indexPath.section][indexPath.row] {
        case .country:
            showPicker(.country)
        case .region:
            showPicker(.region)
        case .city:
            showPicker(.city)
        case .switchServer:
            run { try await $0.refreshServer() }
        case .check:
            checkConnection()
        default:
            break
        }
    }

    // MARK: - UITextFieldDelegate

    func textFieldDidEndEditing(_ textField: UITextField) {
        manager.setCredentials(username: usernameField.text ?? "", password: passwordField.text ?? "")
        rebuild()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === usernameField {
            passwordField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    // MARK: - Actions

    @objc
    private func toggled(_ sender: UISwitch) {
        view.endEditing(true)
        let enabled = sender.isOn
        run { try await $0.setEnabled(enabled) }
    }

    private func showPicker(_ level: NordPlacePickerViewController.Level) {
        let manager = self.manager
        let picker: NordPlacePickerViewController
        switch level {
        case .country:
            picker = NordPlacePickerViewController(level: level, selected: manager.store.country,
                                                   load: { try await manager.loadCountries() },
                                                   onPick: { [weak self] in self?.pick($0, level: level) })
        case .region:
            picker = NordPlacePickerViewController(level: level, selected: manager.store.region,
                                                   load: { try await manager.loadRegions() },
                                                   onPick: { [weak self] in self?.pick($0, level: level) })
        case .city:
            picker = NordPlacePickerViewController(level: level, selected: manager.store.city,
                                                   load: { try await manager.loadCities() },
                                                   onPick: { [weak self] in self?.pick($0, level: level) })
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func pick(_ place: NordPlace?, level: NordPlacePickerViewController.Level) {
        run { manager in
            switch level {
            case .country: try await manager.setCountry(place)
            case .region: try await manager.setRegion(place)
            case .city: try await manager.setCity(place)
            }
        }
    }

    private func checkConnection() {
        isBusy = true
        rebuild()
        Task {
            let message: String
            do {
                let insight = try await manager.checkConnection()
                let place = [insight.city, insight.country].compactMap { $0 }.joined(separator: ", ")
                message = (insight.protected ? "Protected by NordVPN." : "Not protected by NordVPN.")
                    + "\nIP address: \(insight.ip)" + (place.isEmpty ? "" : "\n\(place)")
            } catch {
                message = "Couldn't reach NordVPN through the proxy. Check your service credentials or "
                    + "find another server."
            }
            isBusy = false
            rebuild()
            showAlert(title: "Connection", message: message)
        }
    }

    private func run(_ action: @escaping @MainActor (NordProxyManager) async throws -> Void) {
        isBusy = true
        rebuild()
        Task {
            do {
                try await action(manager)
            } catch {
                showAlert(title: "NordVPN Proxy", message: error.localizedDescription)
            }
            isBusy = false
            rebuild()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Picks a country, region or city, with an "any" choice at the top.
@MainActor
final class NordPlacePickerViewController: UITableViewController, UISearchResultsUpdating {
    enum Level {
        case country
        case region
        case city

        var title: String {
            switch self {
            case .country: return "Country"
            case .region: return "Region"
            case .city: return "City"
            }
        }

        var anyTitle: String {
            switch self {
            case .country: return "Fastest Available"
            case .region: return "Any Region"
            case .city: return "Any City"
            }
        }

        var emptyMessage: String {
            switch self {
            case .country: return "Couldn't load NordVPN's countries."
            case .region: return "NordVPN doesn't list regions with proxy servers here. Choose a city instead."
            case .city: return "Couldn't find cities with NordVPN proxy servers here."
            }
        }
    }

    private let level: Level
    private let selectedID: Int?
    private let load: @MainActor () async throws -> [NordPlace]
    private let onPick: @MainActor (NordPlace?) -> Void
    private var places: [NordPlace] = []
    private var filtered: [NordPlace] = []
    private var isLoading = true
    private let searchController = UISearchController(searchResultsController: nil)

    init(level: Level,
         selected: NordPlace?,
         load: @escaping @MainActor () async throws -> [NordPlace],
         onPick: @escaping @MainActor (NordPlace?) -> Void) {
        self.level = level
        self.selectedID = selected?.id
        self.load = load
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = level.title
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        Task {
            places = (try? await load()) ?? []
            filtered = places
            isLoading = false
            tableView.reloadData()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        filtered = query.isEmpty ? places : places.filter { $0.name.localizedCaseInsensitiveContains(query) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? 1 : filtered.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1, places.isEmpty else { return nil }
        return isLoading ? "Loading NordVPN locations…" : level.emptyMessage
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if indexPath.section == 0 {
            cell.textLabel?.text = level.anyTitle
            cell.accessoryType = selectedID == nil ? .checkmark : .none
        } else {
            let place = filtered[indexPath.row]
            cell.textLabel?.text = place.name
            cell.accessoryType = selectedID == place.id ? .checkmark : .none
        }
        cell.tintColor = FerretStyle.accent
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onPick(indexPath.section == 0 ? nil : filtered[indexPath.row])
        navigationController?.popViewController(animated: true)
    }
}

/// The row in Settings → Privacy that opens the proxy settings.
final class NordProxySetting: Setting {
    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var status: NSAttributedString? {
        return NSAttributedString(string: NordProxyManager.shared.store.isEnabled ? "On" : "Off")
    }

    init(theme: Theme) {
        super.init(title: NSAttributedString(string: "NordVPN Proxy",
                                             attributes: [.foregroundColor: theme.colors.textPrimary]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(NordProxySettingsViewController(), animated: true)
    }
}
