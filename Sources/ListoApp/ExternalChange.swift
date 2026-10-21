import Foundation

/// What to do when the file on disk may have been edited by something other
/// than this window (an editor, git, a sync client).
///
/// Three texts decide it: `disk` (what the file holds now), `baseline` (what
/// it held when this window last read or saved it) and `local` (what the
/// window has in memory now — App Mode saves after every action, so this only
/// differs from `baseline` while a save is pending or Free Mode has unsaved
/// typing).
enum ExternalChange {
    enum Resolution: Equatable {
        /// The file is as we left it.
        case none
        /// Our own pending save landed; just move the baseline up.
        case ownSave
        /// Only the file changed: load it.
        case adoptDisk
        /// Both sides changed: the user decides.
        case conflict
    }

    static func resolve(disk: String, baseline: String, local: String) -> Resolution {
        if disk == baseline { return .none }
        if disk == local { return .ownSave }
        if local == baseline { return .adoptDisk }
        return .conflict
    }
}
