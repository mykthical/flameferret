// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import UniformTypeIdentifiers

/// Menu → Extensions: run extension buttons, open options, enable/disable, install and remove.
@MainActor
final class WebExtensionsHubViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Section: Int, CaseIterable {
        case adBlocking
        case installed
        case add
    }

    private enum AddRow: Int, CaseIterable {
        case fromFile
        case fromLink
        case browseAMO
    }

    private let manager: WebExtensionManager
    private var extensions: [WebExtension] = []

    static func present(from presenter: UIViewController?) {
        let hub = WebExtensionsHubViewController(manager: .shared)
        let navigation = UINavigationController(rootViewController: hub)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        (presenter ?? WebExtensionManager.shared.topViewController())?.present(navigation, animated: true)
    }

    init(manager: WebExtensionManager) {
        self.manager = manager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Extensions"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(close))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reload),
                                               name: .webExtensionsDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reload),
                                               name: .adGuardStateDidChange,
                                               object: nil)
        manager.startIfNeeded()
        reload()
    }

    @objc
    private func reload() {
        extensions = manager.extensions.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        tableView.reloadData()
    }

    @objc
    private func close() {
        dismiss(animated: true)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .adBlocking: return 1
        case .installed: return max(extensions.count, 1)
        case .add: return AddRow.allCases.count
        case .none: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .adBlocking: return "Built In"
        case .installed: return "Installed"
        case .add: return "Add Extensions"
        case .none: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .add else { return nil }
        return "Tap an extension to use its button, open its settings or remove it. "
            + "Extensions run on WebKit, so add-ons that need full request interception or Firefox-only "
            + "internals may not work fully."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        switch Section(rawValue: indexPath.section) {
        case .adBlocking:
            let adGuard = AdGuardManager.shared
            cell.textLabel?.text = "AdGuard Ad Blocking"
            cell.detailTextLabel?.text = adGuard.settings.isEnabled ? "On" : "Off"
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.imageView?.image = UIImage(systemName: "shield.lefthalf.filled")
            cell.accessoryType = .disclosureIndicator
        case .installed:
            configureInstalledCell(cell, row: indexPath.row)
        case .add:
            configureAddCell(cell, row: AddRow(rawValue: indexPath.row))
        case .none:
            break
        }
        return cell
    }

    private func configureInstalledCell(_ cell: UITableViewCell, row: Int) {
        guard row < extensions.count else {
            cell.textLabel?.text = "No extensions yet"
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return
        }
        let webExtension = extensions[row]
        var name = webExtension.displayName
        if let badge = manager.actionStates[webExtension.uuid]?.badgeText, !badge.isEmpty {
            name += "  [\(badge)]"
        }
        cell.textLabel?.text = name
        cell.textLabel?.textColor = webExtension.isEnabled ? .label : .secondaryLabel
        cell.detailTextLabel?.text = "Version \(webExtension.manifest.version)"
            + (webExtension.hasPopup && webExtension.isEnabled ? " · Tap to open" : "")
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = (webExtension.icon(preferredSize: 64) ?? UIImage(systemName: "puzzlepiece.extension"))
            .flatMap { resized($0, to: 32) }
        let toggle = UISwitch()
        toggle.isOn = webExtension.isEnabled
        toggle.tag = row
        toggle.accessibilityLabel = "Enable \(webExtension.displayName)"
        toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
    }

    private func configureAddCell(_ cell: UITableViewCell, row: AddRow?) {
        cell.textLabel?.textColor = .systemBlue
        switch row {
        case .fromFile:
            cell.textLabel?.text = "Install from File…"
            cell.detailTextLabel?.text = ".xpi, .zip or .crx from Files"
            cell.imageView?.image = UIImage(systemName: "doc.badge.plus")
        case .fromLink:
            cell.textLabel?.text = "Install from Link…"
            cell.detailTextLabel?.text = "addons.mozilla.org, Chrome Web Store or a direct link"
            cell.imageView?.image = UIImage(systemName: "link.badge.plus")
        case .browseAMO:
            cell.textLabel?.text = "Browse Firefox Add-ons"
            cell.detailTextLabel?.text = "Tap \"Download file\" on any add-on page to install it"
            cell.imageView?.image = UIImage(systemName: "safari")
        case .none:
            break
        }
        cell.detailTextLabel?.textColor = .secondaryLabel
    }

    private func resized(_ image: UIImage, to side: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .adBlocking:
            let siteURL = manager.selectedTab().flatMap { $0.webView?.url ?? $0.url }
            navigationController?.pushViewController(AdGuardSettingsViewController(currentSiteURL: siteURL), animated: true)
        case .installed:
            guard indexPath.row < extensions.count else { return }
            showActions(for: extensions[indexPath.row], sourceView: tableView.cellForRow(at: indexPath))
        case .add:
            handleAdd(AddRow(rawValue: indexPath.row))
        case .none:
            break
        }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .installed, indexPath.row < extensions.count else { return nil }
        let webExtension = extensions[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            self?.confirmRemove(webExtension)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    @objc
    private func toggleChanged(_ sender: UISwitch) {
        guard sender.tag < extensions.count else { return }
        manager.setEnabled(sender.isOn, for: extensions[sender.tag])
    }

    // MARK: - Actions

    private func showActions(for webExtension: WebExtension, sourceView: UIView?) {
        let sheet = UIAlertController(title: webExtension.displayName,
                                      message: webExtension.displayDescription,
                                      preferredStyle: .actionSheet)
        if webExtension.isEnabled && webExtension.hasAction {
            let title = manager.actionStates[webExtension.uuid]?.title
                ?? webExtension.manifest.action?.defaultTitle ?? "Open"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.dismiss(animated: true) { WebExtensionManager.shared.openPopup(for: webExtension) }
            })
        }
        if webExtension.isEnabled && webExtension.hasOptions {
            sheet.addAction(UIAlertAction(title: "Settings", style: .default) { [weak self] _ in
                self?.dismiss(animated: true) { WebExtensionManager.shared.openOptions(for: webExtension) }
            })
        }
        sheet.addAction(UIAlertAction(title: "Details", style: .default) { [weak self] _ in
            self?.showDetails(webExtension)
        })
        sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.confirmRemove(webExtension)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView ?? view
        present(sheet, animated: true)
    }

    private func showDetails(_ webExtension: WebExtension) {
        let manifest = webExtension.manifest
        var lines = ["ID: \(webExtension.id)", "Version: \(manifest.version)", "Manifest V\(manifest.manifestVersion)"]
        let permissions = WebExtensionInstaller.shared.describePermissions(manifest)
        if !permissions.isEmpty {
            lines.append("\nPermissions:\n• " + permissions.joined(separator: "\n• "))
        }
        let unsupported = manifest.permissions.filter {
            ["webRequestBlocking", "nativeMessaging", "proxy", "debugger", "devtools"].contains($0)
        }
        if !unsupported.isEmpty {
            lines.append("\nLimited on iOS: " + unsupported.joined(separator: ", "))
        }
        let alert = UIAlertController(title: webExtension.displayName,
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func confirmRemove(_ webExtension: WebExtension) {
        let alert = UIAlertController(title: "Remove \(webExtension.displayName)?",
                                      message: "Its settings and data will be deleted.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.manager.uninstall(webExtension)
        })
        present(alert, animated: true)
    }

    private func handleAdd(_ row: AddRow?) {
        switch row {
        case .fromFile:
            var types: [UTType] = [.zip]
            types += ["xpi", "crx"].compactMap { UTType(filenameExtension: $0) }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types + [.data], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
        case .fromLink:
            promptForLink()
        case .browseAMO:
            dismiss(animated: true) {
                if let url = URL(string: "https://addons.mozilla.org/firefox/extensions/") {
                    _ = WebExtensionManager.shared.openTab(url: url, active: true, from: nil)
                }
            }
        case .none:
            break
        }
    }

    private func promptForLink() {
        let alert = UIAlertController(title: "Install from Link",
                                      message: "Paste an add-on page from addons.mozilla.org or the Chrome Web Store, "
                                        + "or a link to an .xpi or .crx file.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://addons.mozilla.org/firefox/addon/…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = UIPasteboard.general.hasURLs ? UIPasteboard.general.url?.absoluteString : nil
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Install", style: .default) { [weak alert] _ in
            guard let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
            WebExtensionInstaller.shared.installFromLink(text, presenter: nil)
        })
        present(alert, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        WebExtensionInstaller.shared.confirmAndInstall(data, suggestedName: url.deletingPathExtension().lastPathComponent,
                                                       presenter: self)
    }
}
