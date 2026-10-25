// Power Management Suite - Charge Pause Control
// Copyright (C) 2025 <Your Name or Organization>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import AppKit

// Pauses battery charging while the Mac keeps running on the power adapter.
//
// Since macOS 27 the SMC charging keys used by batt are gone, so this uses
// macOS's own Charge Limit (System Settings > Battery) instead: PowerUIAgent
// stops charging at the limit and the Mac runs from the adapter.
//
// - Limits of 80-100% (what System Settings offers) are set through PowerUI
//   without privileges and apply at once. Resuming is always one of those.
// - Lower limits are written to the root-owned preferences, which needs an
//   administrator (sudo with Touch ID when enabled, else a password dialog).
//   PowerUIAgent applies those at its next battery update, within ~30 s;
//   until then the battery keeps charging, never discharging.
//
// The limit must never be below the current charge: macOS would then run the
// Mac from the battery until the charge drops to the limit. Pausing therefore
// sets the limit one percent above the live charge, re-checks it after
// authenticating, and keeps watching for a short while afterwards.
@MainActor
final class ChargeController: ObservableObject {
    // Whether charging is currently paused by this app.
    @Published private(set) var isPaused = false
    // The charge limit (in %) that holds the charge while paused.
    @Published private(set) var holdLimit: Int?
    // True while a change is in progress.
    @Published private(set) var isBusy = false
    // The last error, shown below the toggle.
    @Published private(set) var errorMessage: String?

    private enum Keys {
        static let holdLimit = "chargePause.holdLimit"
        static let savedLimit = "chargePause.savedLimit"
        static let savedEnabled = "chargePause.savedEnabled"
    }

    private static let domain = "com.apple.smartcharging.topoffprotection"
    // Limits PowerUI accepts without privileges.
    private static let unprivilegedLimits = 80...100
    // How long to keep checking that the Mac isn't drawing from the battery after pausing.
    private static let watchDuration: TimeInterval = 120
    private static let watchInterval: TimeInterval = 5
    // How often to re-read the state while the popover is visible.
    private static let refreshInterval: TimeInterval = 5

    private let defaults = UserDefaults.standard
    private var watchTimer: Timer?
    private var watchStart = Date()
    private var lastRefresh = Date.distantPast

    init() {
        refresh()
    }

    // Re-reads the pause state at most every few seconds, for periodic callers.
    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) >= Self.refreshInterval {
            refresh()
        }
    }

    // Re-reads the pause state. If the limit was changed elsewhere (System
    // Settings), the pause is considered over.
    func refresh() {
        lastRefresh = Date()
        guard !isBusy else { return }
        guard let hold = defaults.object(forKey: Keys.holdLimit) as? Int else {
            isPaused = false
            holdLimit = nil
            return
        }
        let limit = Int(getChargeLimit())
        let enabled = Int(isChargeLimitEnabled())
        // Right after pausing PowerUI may still report the old limit.
        if watchTimer == nil, limit >= 0, enabled >= 0, enabled == 0 || limit != hold {
            clearSavedState()
            isPaused = false
            holdLimit = nil
            return
        }
        isPaused = true
        holdLimit = hold
    }

    func setChargingAllowed(_ allowed: Bool) {
        guard !isBusy else { return }
        errorMessage = nil
        isBusy = true
        Task {
            if allowed {
                await resume()
            } else {
                await pause()
            }
            isBusy = false
        }
    }

    // MARK: - Pause / Resume

    private func pause() async {
        let previousLimit = Int(getChargeLimit())
        let previousEnabled = Int(isChargeLimitEnabled())
        guard previousLimit >= 0, previousEnabled >= 0, var target = Self.holdLimit(above: Int(getBatteryUIPercent())) else {
            errorMessage = NSLocalizedString("charging.state.unreadable", comment: "Charge limit or battery level could not be read")
            return
        }
        if defaults.object(forKey: Keys.holdLimit) == nil {
            defaults.set(previousLimit, forKey: Keys.savedLimit)
            defaults.set(previousEnabled == 1, forKey: Keys.savedEnabled)
        }

        do {
            try await applyHoldLimit(target)
        } catch {
            if !isPaused { clearSavedState() }
            report(error)
            return
        }
        isPaused = true
        setHoldLimit(target)

        // The battery may have kept charging while authenticating. Raise the
        // limit until it is above the live charge again.
        while let raised = Self.holdLimit(above: Int(getBatteryUIPercent())), raised > target {
            target = raised
            do {
                try await applyHoldLimit(target)
            } catch {
                report(error)
                break
            }
            setHoldLimit(target)
        }
        startWatching()
    }

    private func resume() async {
        stopWatching()
        let limit = defaults.object(forKey: Keys.savedLimit) as? Int ?? 100
        let enabled = defaults.object(forKey: Keys.savedEnabled) as? Bool ?? false
        let restored: Bool
        if Self.unprivilegedLimits.contains(limit) {
            // No password needed, and PowerUIAgent resumes charging immediately.
            // The limit is already enabled while paused, so only disabling is needed.
            restored = setChargeLimit(Int32(limit)) && getChargeLimit() == limit
                && (enabled || setChargeLimitEnabled(false))
        } else {
            restored = false
        }
        if !restored {
            do {
                try await writeChargeLimitAsRoot(limit, enabled: enabled, prompt: NSLocalizedString("charging.resume.prompt", comment: "Password prompt when resuming charging"))
            } catch {
                report(error)
                if isPaused { startWatching() }
                return
            }
        }
        clearSavedState()
        isPaused = false
        holdLimit = nil
    }

    // Sets the limit that holds the charge, without privileges when possible.
    private func applyHoldLimit(_ limit: Int) async throws {
        if Self.unprivilegedLimits.contains(limit) {
            // Set the limit before enabling: enabling restores the limit last
            // set, and a stale one could be below the charge.
            if setChargeLimit(Int32(limit)),
               isChargeLimitEnabled() == 1 || setChargeLimitEnabled(true),
               getChargeLimit() == limit {
                return
            }
        }
        try await writeChargeLimitAsRoot(limit, enabled: true, prompt: NSLocalizedString("charging.pause.prompt", comment: "Password prompt when pausing charging"))
    }

    // The lowest limit that is safely above the given live charge, or nil if
    // the charge is unknown.
    private static func holdLimit(above percent: Int) -> Int? {
        guard percent >= 0 else { return nil }
        return min(percent + 1, 100)
    }

    private func setHoldLimit(_ limit: Int) {
        holdLimit = limit
        defaults.set(limit, forKey: Keys.holdLimit)
    }

    private func clearSavedState() {
        defaults.removeObject(forKey: Keys.holdLimit)
        defaults.removeObject(forKey: Keys.savedLimit)
        defaults.removeObject(forKey: Keys.savedEnabled)
    }

    // MARK: - Battery draw watch

    // For a short while after pausing, make sure the Mac is running on the
    // adapter. The admin authorization is still cached then, so a correction
    // doesn't ask again.
    private func startWatching() {
        stopWatching()
        watchStart = Date()
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBatteryDraw() }
        }
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func checkBatteryDraw() {
        guard !isBusy else { return }
        guard isPaused, let hold = holdLimit, Date().timeIntervalSince(watchStart) < Self.watchDuration else {
            if isPaused, let hold = holdLimit, Int(getChargeLimit()) != hold {
                errorMessage = NSLocalizedString("charging.limit.not.applied", comment: "macOS did not apply the new charge limit")
            }
            stopWatching()
            return
        }
        let adapterConnected = getAdapterVoltage() > 5
        let drawingFromBattery = getBatteryAmperage() < -0.1
        guard adapterConnected, drawingFromBattery,
              let target = Self.holdLimit(above: Int(getBatteryUIPercent())), target > hold else { return }
        isBusy = true
        Task {
            do {
                try await applyHoldLimit(target)
                setHoldLimit(target)
            } catch {
                report(error)
                stopWatching()
            }
            isBusy = false
        }
    }

    // MARK: - Privileged write

    private struct CommandError: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
        // AppleScript's "User canceled."
        var isUserCancel: Bool { code == -128 }
    }

    // Writes macOS's Charge Limit preference as root and tells PowerUIAgent to
    // reload it. Uses sudo when Touch ID is enabled for it, falling back to
    // the administrator password dialog.
    private func writeChargeLimitAsRoot(_ limit: Int, enabled: Bool, prompt: String) async throws {
        let d = Self.domain
        let command = "/usr/bin/defaults write \(d) MCLFeatureState -int \(enabled ? 1 : 0)"
            + " && /usr/bin/defaults write \(d) mclLimitValue -int \(limit)"
            + " && /usr/bin/notifyutil -p com.apple.smartcharging.defaultschanged"
        if Self.isTouchIDEnabledForSudo, (try? await Self.runWithSudo(command)) != nil {
            return
        }
        try Self.runWithAdministratorPrompt(command, prompt: prompt)
    }

    // Touch ID for sudo is enabled by an uncommented pam_tid line in
    // /etc/pam.d/sudo_local (see /etc/pam.d/sudo_local.template).
    private static var isTouchIDEnabledForSudo: Bool {
        guard let config = try? String(contentsOfFile: "/etc/pam.d/sudo_local", encoding: .utf8) else { return false }
        return config.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.contains("pam_tid.so")
        }
    }

    // Runs the command with sudo. Without a terminal, sudo can only
    // authenticate with Touch ID (or a cached authentication) and fails otherwise.
    private static func runWithSudo(_ command: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["/bin/sh", "-c", command]
        process.standardInput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        if status != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CommandError(code: Int(status), message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // Runs the command as root after an administrator password dialog. Runs
    // in-process so the authorization is cached for follow-up writes.
    private static func runWithAdministratorPrompt(_ command: String, prompt: String) throws {
        let escapedPrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(command)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw CommandError(code: errorInfo[NSAppleScript.errorNumber] as? Int ?? 0,
                               message: errorInfo[NSAppleScript.errorMessage] as? String ?? "")
        }
    }

    private func report(_ error: Error) {
        if let commandError = error as? CommandError, commandError.isUserCancel { return }
        errorMessage = String(format: NSLocalizedString("charging.change.failed", comment: "Charge limit could not be changed"), error.localizedDescription)
    }
}
