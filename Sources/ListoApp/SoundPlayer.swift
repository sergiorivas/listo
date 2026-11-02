import AppKit
import AudioToolbox
import ListoEngine

/// Completion/delete feedback sounds, gated by `AppSettings`.
@MainActor
enum SoundPlayer {
    /// Plays `AppSettings.completionSoundEnabled`'s sound when the toggle
    /// just checked the task off (not when it reopened it). Only App Mode
    /// clicks reach here — a completion inferred from a Free Mode edit is
    /// not something the user just did, so it stays silent.
    static func playCompletionIfNeeded(document: ListoDocument, taskID: UUID) {
        guard AppSettings.shared.completionSoundEnabled,
              document.allTasksRecursive.first(where: { $0.id == taskID })?.state == .done
        else { return }
        play(named: "Glass")
    }

    /// Plays `AppSettings.deleteSoundEnabled`'s sound after a task or
    /// subtask was deleted from App Mode (not for deletions inferred from a
    /// Free Mode edit, nor whole sections).
    static func playDeleteIfNeeded() {
        guard AppSettings.shared.deleteSoundEnabled else { return }
        play(named: "Funk")
    }

    /// Through the system sound server, not `NSSound`: `NSSound.play()`
    /// starts the audio device synchronously on the main thread, and an
    /// output that sleeps when idle (a monitor's speakers over DisplayPort/
    /// HDMI) took seconds to wake — a beachball on every check or delete.
    /// `AudioServicesPlaySystemSound` hands the sound to the server and
    /// returns at once; at worst the sound itself is late. Overlapping
    /// plays are fine, so a quick second sound isn't swallowed either.
    private static func play(named name: String) {
        guard let id = soundID(named: name) else { return }
        AudioServicesPlaySystemSound(id)
    }

    /// Registered once per sound and kept for the app's lifetime.
    private static var soundIDs: [String: SystemSoundID] = [:]

    private static func soundID(named name: String) -> SystemSoundID? {
        if let id = soundIDs[name] { return id }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        soundIDs[name] = id
        return id
    }
}
