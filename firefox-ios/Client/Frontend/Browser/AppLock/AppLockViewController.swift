// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

/// The PIN pad used to unlock Flameferret, set a new PIN, and confirm the PIN before changing settings.
@MainActor
final class AppLockViewController: UIViewController {
    enum Mode {
        /// The lock screen over the whole app.
        case unlock
        /// Enter a new PIN twice.
        case create(completion: @MainActor (String?) -> Void)
        /// Check the current PIN before a sensitive change.
        case verify(completion: @MainActor (Bool) -> Void)
    }

    private let mode: Mode
    private weak var manager: AppLockManager?
    private var entered = ""
    private var firstEntry: String?
    private var lockoutTimer: Timer?
    private var lockoutUntil: Date?

    private let stack = UIStackView()
    private let logoView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let dotsStack = UIStackView()
    private let keypad = UIStackView()
    private var biometricButton: UIButton?
    private var keypadButtons: [UIButton] = []

    /// When false the screen only covers the app (for the app switcher) and shows no keypad.
    var showsKeypad = true {
        didSet {
            guard isViewLoaded else { return }
            updateKeypadVisibility()
        }
    }

    init(mode: Mode, manager: AppLockManager) {
        self.mode = mode
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
        resetForStep()
        updateKeypadVisibility()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshLockout()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lockoutTimer?.invalidate()
        lockoutTimer = nil
    }

    // MARK: - Layout

    private func buildLayout() {
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        logoView.image = UIImage(named: "fxHomeHeaderLogoBall")
        logoView.contentMode = .scaleAspectFit
        logoView.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 72),
            logoView.heightAnchor.constraint(equalToConstant: 72)
        ])

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        dotsStack.axis = .horizontal
        dotsStack.spacing = 16
        for _ in 0..<AppLockStore.pinLength {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 7
            dot.layer.borderWidth = 1.5
            dot.layer.borderColor = UIColor.label.cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 14),
                dot.heightAnchor.constraint(equalToConstant: 14)
            ])
            dotsStack.addArrangedSubview(dot)
        }
        dotsStack.isAccessibilityElement = true

        keypad.axis = .vertical
        keypad.spacing = 14
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["bio", "0", "del"]]
        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 24
            for key in row {
                rowStack.addArrangedSubview(makeKey(key))
            }
            keypad.addArrangedSubview(rowStack)
        }

        stack.addArrangedSubview(logoView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(dotsStack)
        stack.addArrangedSubview(messageLabel)
        stack.setCustomSpacing(36, after: messageLabel)
        stack.addArrangedSubview(keypad)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])

        if !isUnlockMode {
            let cancel = UIButton(type: .system)
            cancel.setTitle("Cancel", for: .normal)
            cancel.titleLabel?.font = .preferredFont(forTextStyle: .body)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            view.addSubview(cancel)
            NSLayoutConstraint.activate([
                cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                cancel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
            ])
        }
    }

    private func makeKey(_ key: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 76),
            button.heightAnchor.constraint(equalToConstant: 76)
        ])
        button.layer.cornerRadius = 38
        button.tintColor = .label
        switch key {
        case "del":
            button.setImage(UIImage(systemName: "delete.left"), for: .normal)
            button.accessibilityLabel = "Delete"
            button.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        case "bio":
            let name = manager?.biometryName
            let available = name != nil && (manager?.usesBiometrics ?? false) && isUnlockMode
            button.setImage(UIImage(systemName: name == "Touch ID" ? "touchid" : "faceid"), for: .normal)
            button.accessibilityLabel = name.map { "Use \($0)" }
            button.isHidden = !available
            button.addTarget(self, action: #selector(biometricsTapped), for: .touchUpInside)
            biometricButton = button
        default:
            button.setTitle(key, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 32, weight: .regular)
            button.backgroundColor = .secondarySystemFill
            button.accessibilityLabel = key
            button.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
            keypadButtons.append(button)
        }
        return button
    }

    private var isUnlockMode: Bool {
        if case .unlock = mode { return true }
        return false
    }

    private func updateKeypadVisibility() {
        titleLabel.isHidden = !showsKeypad
        dotsStack.isHidden = !showsKeypad
        messageLabel.isHidden = !showsKeypad
        keypad.isHidden = !showsKeypad
        if showsKeypad {
            entered = ""
            updateDots()
            refreshLockout()
        }
    }

    // MARK: - Steps

    private func resetForStep() {
        entered = ""
        messageLabel.textColor = .secondaryLabel
        switch mode {
        case .unlock:
            titleLabel.text = "Enter PIN"
            messageLabel.text = "Flameferret is locked."
        case .create:
            titleLabel.text = firstEntry == nil ? "Choose a 6-Digit PIN" : "Confirm PIN"
            messageLabel.text = firstEntry == nil
                ? "You'll need it to open Flameferret. If you forget it, the only way back in is to reinstall the app."
                : "Enter the same PIN again."
        case .verify:
            titleLabel.text = "Enter Current PIN"
            messageLabel.text = nil
        }
        updateDots()
    }

    private func updateDots() {
        for (index, dot) in dotsStack.arrangedSubviews.enumerated() {
            dot.backgroundColor = index < entered.count ? .label : .clear
        }
        dotsStack.accessibilityLabel = "\(entered.count) of \(AppLockStore.pinLength) digits entered"
    }

    @objc
    private func digitTapped(_ sender: UIButton) {
        guard let digit = sender.currentTitle, entered.count < AppLockStore.pinLength else { return }
        entered.append(digit)
        updateDots()
        if entered.count == AppLockStore.pinLength {
            let pin = entered
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.submit(pin)
            }
        }
    }

    @objc
    private func deleteTapped() {
        guard !entered.isEmpty else { return }
        entered.removeLast()
        updateDots()
    }

    @objc
    private func biometricsTapped() {
        requestBiometricsIfAvailable()
    }

    @objc
    private func cancelTapped() {
        switch mode {
        case .create(let completion): dismiss(animated: true) { completion(nil) }
        case .verify(let completion): dismiss(animated: true) { completion(false) }
        case .unlock: break
        }
    }

    func requestBiometricsIfAvailable() {
        guard isUnlockMode, let manager, biometricButton?.isHidden == false else { return }
        manager.authenticateWithBiometrics { [weak self] success in
            if success { self?.manager?.didUnlock() }
        }
    }

    private func submit(_ pin: String) {
        guard let manager else { return }
        switch mode {
        case .create(let completion):
            if let first = firstEntry {
                if first == pin {
                    dismiss(animated: true) { completion(pin) }
                } else {
                    firstEntry = nil
                    resetForStep()
                    showError("The PINs didn't match. Try again.")
                }
            } else {
                firstEntry = pin
                resetForStep()
            }
        case .unlock, .verify:
            let result = manager.store.verify(pin)
            switch result {
            case .success:
                if case .verify(let completion) = mode {
                    dismiss(animated: true) { completion(true) }
                } else {
                    manager.didUnlock()
                }
            case .wrong(let remaining):
                entered = ""
                updateDots()
                let suffix = remaining.map { $0 == 1 ? " 1 try left before a wait." : " \($0) tries left before a wait." }
                showError("Wrong PIN." + (suffix ?? ""))
            case .lockedOut:
                entered = ""
                updateDots()
                refreshLockout()
            }
        }
    }

    private func showError(_ message: String) {
        messageLabel.text = message
        messageLabel.textColor = .systemRed
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [-12, 12, -8, 8, -4, 4, 0]
        shake.duration = 0.4
        dotsStack.layer.add(shake, forKey: "shake")
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func refreshLockout() {
        lockoutTimer?.invalidate()
        lockoutTimer = nil
        lockoutUntil = manager?.store.lockedOutUntil
        let isLockedOut = lockoutUntil != nil
        keypadButtons.forEach { $0.isEnabled = !isLockedOut }
        guard isLockedOut else { return }
        tickLockout()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLockout() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockoutTimer = timer
    }

    private func tickLockout() {
        guard let until = lockoutUntil else { return }
        let seconds = Int(until.timeIntervalSinceNow.rounded(.up))
        guard seconds > 0 else {
            messageLabel.textColor = .secondaryLabel
            messageLabel.text = "Enter your PIN."
            refreshLockout()
            return
        }
        let wait = seconds >= 60 ? "\(Int((Double(seconds) / 60).rounded(.up))) min" : "\(seconds) sec"
        messageLabel.textColor = .systemRed
        messageLabel.text = "Too many wrong PINs. Try again in \(wait)."
    }
}
