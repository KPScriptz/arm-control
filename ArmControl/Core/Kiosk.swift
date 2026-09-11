import Foundation
import SwiftUI

/// Attendant lock. When locked the app shows ONE screen with ONE button and nothing else —
/// no tabs, no jog, no network fields, no way to reach the PLC login.
///
/// 🔑 **LOCKED IS THE DEFAULT.** A fresh install opens in attendant mode. The settings are the
/// exception you have to unlock into, not the state you have to remember to leave. An app that
/// ships unlocked is one forgotten tap away from an attendant in the network fields.
///
/// Getting out is a deliberate two-step: a **triple tap** on an unmarked corner, then the PIN.
/// Unmarked on purpose — a visible lock icon is something a guest will press, and every press is
/// an attendant walking over.
@MainActor
final class Kiosk: ObservableObject {
    static let shared = Kiosk()

    private static let lockedKey = "armcontrol.kiosk.locked"
    private static let pinKey = "armcontrol.kiosk.pin"
    private static let bgRelockKey = "armcontrol.kiosk.relockOnBackground"
    private static let idleKey = "armcontrol.kiosk.idleMinutes"
    private static let everUnlockedKey = "armcontrol.kiosk.everUnlocked"

    /// False on an iPad where nobody has ever got past the booth screen.
    ///
    /// 🔑 **A fresh install is a dead end without this.** The app opens locked by design, so what a
    /// new tester actually sees is a black screen reading "No connection to the rail" and a button
    /// that will not press — with no indication that a whole application is behind an unmarked
    /// corner. The hidden escape is right for a booth in front of guests and wrong for the five
    /// minutes before anyone has ever configured the thing. So the attendant screen shows the way
    /// in exactly once, on an iPad that has never been unlocked, and never again afterwards.
    @Published private(set) var hasEverUnlocked: Bool

    /// ⚠️ A placeholder, not a booth PIN. This repo is public, so the real number must never be in
    /// source — set it once on the iPad under Setup → Booth flow → PIN. (Until 2026-09-11 this
    /// shipped as the crew's shared PIN; that number is in git history and should be retired.)
    static let defaultPIN = "0000"

    @Published private(set) var locked: Bool

    /// Wrong entries in a row. Three strikes adds a cool-off so a guest mashing the pad gives up.
    @Published private(set) var failedAttempts = 0
    @Published private(set) var lockedOutUntil: Date?

    /// Re-lock whenever the app leaves the foreground. On by default: someone picking up an iPad
    /// that was left on another app should find the booth screen, not the PLC login.
    @Published var relockOnBackground: Bool {
        didSet { UserDefaults.standard.set(relockOnBackground, forKey: Self.bgRelockKey) }
    }

    /// Minutes of no touches before the settings re-lock themselves. 0 = never.
    @Published var idleRelockMinutes: Int {
        didSet {
            UserDefaults.standard.set(idleRelockMinutes, forKey: Self.idleKey)
            restartIdleWatch()
        }
    }

    private var lastActivity = Date()
    private var idleTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        // Absent key means a fresh install → start LOCKED. `defaults.bool` would return false here,
        // which is exactly the wrong way round.
        if defaults.object(forKey: Self.lockedKey) == nil {
            locked = true
            defaults.set(true, forKey: Self.lockedKey)
        } else {
            locked = defaults.bool(forKey: Self.lockedKey)
        }
        relockOnBackground = defaults.object(forKey: Self.bgRelockKey) as? Bool ?? true
        idleRelockMinutes = defaults.object(forKey: Self.idleKey) as? Int ?? 5
        hasEverUnlocked = defaults.bool(forKey: Self.everUnlockedKey)

        // 🐞 The idle watch used to start ONLY from `tryUnlock` and from changing the interval, so
        // an app that LAUNCHED already unlocked — a perfectly ordinary state, since the lock is
        // persisted — never armed it at all. Settings then stayed open indefinitely no matter how
        // long the iPad sat untouched, which is exactly the thing auto-relock exists to prevent.
        restartIdleWatch()
    }

    var pin: String {
        let p = UserDefaults.standard.string(forKey: Self.pinKey) ?? ""
        return p.isEmpty ? Self.defaultPIN : p
    }

    func setPIN(_ new: String) {
        let digits = new.filter(\.isNumber)
        guard digits.count >= 4 else { return }
        UserDefaults.standard.set(digits, forKey: Self.pinKey)
    }

    // MARK: Lock / unlock

    func lock() {
        guard !locked else { return }
        locked = true
        failedAttempts = 0
        lockedOutUntil = nil
        UserDefaults.standard.set(true, forKey: Self.lockedKey)
        stopIdleWatch()
        GlamaticLink.plog("KIOSK LOCKED")
    }

    var isCoolingOff: Bool {
        guard let until = lockedOutUntil else { return false }
        return Date() < until
    }

    var coolOffRemaining: Int {
        guard let until = lockedOutUntil else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
    }

    /// Returns true and unlocks on the right PIN.
    @discardableResult
    func tryUnlock(_ entered: String) -> Bool {
        guard !isCoolingOff else { return false }
        guard entered == pin else {
            failedAttempts += 1
            if failedAttempts >= 3 {
                lockedOutUntil = Date().addingTimeInterval(30)
                failedAttempts = 0
            }
            return false
        }
        locked = false
        failedAttempts = 0
        lockedOutUntil = nil
        hasEverUnlocked = true
        UserDefaults.standard.set(false, forKey: Self.lockedKey)
        UserDefaults.standard.set(true, forKey: Self.everUnlockedKey)
        restartIdleWatch()
        GlamaticLink.plog("KIOSK UNLOCKED")
        return true
    }

    // MARK: Auto re-lock

    func handleScenePhase(_ phase: ScenePhase) {
        guard phase != .active, relockOnBackground, !locked else { return }
        GlamaticLink.plog("KIOSK relock — app left the foreground")
        lock()
    }

    /// Called on any touch in the operator interface.
    func noteActivity() { lastActivity = Date() }

    private func restartIdleWatch() {
        stopIdleWatch()
        guard !locked, idleRelockMinutes > 0 else { return }
        lastActivity = Date()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled, !self.locked else { return }
                let limit = TimeInterval(self.idleRelockMinutes * 60)
                if Date().timeIntervalSince(self.lastActivity) >= limit {
                    GlamaticLink.plog("KIOSK relock — idle \(self.idleRelockMinutes)m")
                    self.lock()
                    return
                }
            }
        }
    }

    private func stopIdleWatch() {
        idleTask?.cancel()
        idleTask = nil
    }
}
