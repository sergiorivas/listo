import AppKit
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

    /// Restart rather than let a quick second sound be swallowed by the
    /// still-playing first one (`play()` is a no-op while playing).
    private static func play(named name: String) {
        let sound = NSSound(named: name)
        sound?.stop()
        sound?.play()
    }
}
