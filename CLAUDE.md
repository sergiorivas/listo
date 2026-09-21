# Listo — decisions and history

Background on *why* the code looks the way it does: design decisions, bugs
fixed and their root causes, and rejected alternatives. See `README.md` for
the current structure, install/build/dev instructions, and known
limitations — this file is deliberately not needed to just use or build the
app.

## Two-level model: Task + Subtask

Listo's tree is deliberately just two levels: a **Task**, which may carry an
optional note, and its **Subtasks**, which may not — and which can't have
subtasks of their own. This is a simplification from an earlier version
that allowed arbitrarily nested subtasks (up to three levels) and notes at
any depth; in practice two flat levels cover the real use cases, and cut
out a category of UI/engine complexity (recursive indent math, notes
scattered at every depth) for no real benefit.

- `ListoEditor.maxSubtaskDepth = 1` — a top-level task can gain subtasks via
  ⇥/Tab, but a subtask can't be indented further; `indentTask` throws
  `maxDepthReached` if you try.
- `ListoEditor.setNote` throws `subtaskNoteNotSupported` if called on
  anything but a top-level task, and the note UI (the "add note" icon, the
  inline note preview, the context-menu entry) only ever appears on
  top-level rows in both Kanban and Outline.
- The engine's parser/model/serializer stay structurally generic (a task's
  `subtasks: [ListoTask]` is still a recursive array, and `note` is still a
  plain optional on any task) so a hand-edited Free Mode file with deeper
  nesting or a subtask note still parses and round-trips without losing
  content — the two-level rule is enforced at the App Mode action layer
  (`ListoEditor`) and in the UI, not by silently rewriting whatever is
  already on disk.

## Bugs fixed

- **Infinite loop / spinner on open or save**: `ListoApp` observes
  `RecentFilesStore` (for the Recent menu), and `ContentView.init` was
  calling `recordOpened` unconditionally — SwiftUI rebuilds `init` on every
  parent rerender, so as soon as a document had a real URL (on open, or on
  first save) this fed back on itself endlessly. `recordOpened` is now a
  no-op if the URL is already the most recent one, and the call moved to
  `.onAppear`/`.onChange` (tied to the view's stable identity, not to every
  rebuild).
- **Font size wasn't reflected**: nested views (`TaskChip`, `KanbanColumn`,
  `OutlineSection`, etc.) read `AppSettings.shared.font(...)` without
  declaring their own `@ObservedObject` over `AppSettings` — SwiftUI doesn't
  redraw a child view just because its parent re-rendered; it needs its own
  declared dependency. Every view using a relative font now observes
  `AppSettings.shared` directly.
- **Pasting a task in Free Mode got reverted**: the FSEvents watcher saw
  Cocoa's own autosave as an "external change" against a stale baseline and
  adopted an old version of the text on top of what had just been pasted.
  Instead of patching that race further, the watcher was removed entirely —
  see "Free Mode without a watcher" below.
- **Note indentation growing on every save**: `ListoTask.note` used to store
  the line *raw, exactly as it was in the file*, structural indentation
  included (e.g. `"  See the thread on GitHub"`). The edit popover was
  seeded with that value (the full `task.note`, indentation already baked
  in), and `ListoEditor.setNote` adds its own indentation on save — so
  reopening a note and saving it unchanged added one extra indent unit (2
  spaces) every time. `ListoParser.finalizeNote` now stores the note
  *dedented*: it strips exactly the one structural unit that marks it as
  "this task's note" (preserving any extra indentation the user put inside
  it, e.g. a nested list within the note), and `Serializer`/
  `ListoEditor.setNote` re-add it when writing. `task.note` is now clean
  logical content; the file still has the real indentation. Covered by
  tests that force several save cycles with no changes and verify the
  file's indentation doesn't grow.
- **Can't edit a subtask's note** (historical, before subtasks lost note
  support entirely — see "Two-level model" above): each subtask row had its
  own `.popover(item:)` *nested inside* the parent `TaskChip`/
  `OutlineTaskRow`'s popover — nesting popovers is a known SwiftUI weak
  spot, and the inner one could simply fail to appear. Fixed by moving to a
  single popover per top-level card/row, with each subtask row bubbling its
  note-edit request up via a closure (`onEditNote`) instead of opening its
  own — see "Things-style row selection" below for how that structure is
  still used today.

## Priority (`!`, `!!`, `!!!`)

A task or subtask line may end with a priority marker: `- [ ] Pay rent !!!`
(`!` low, `!!` medium, `!!!` high). It is a *task-line* feature, not a note
one — subtasks have no notes, and the sort is over tasks.

- **Parsed off the title.** `TaskPriority.split` strips the marker into
  `ListoTask.priority`; `text` stays clean, so ids (`StableID`), the differ
  and every view see the plain title, and Kanban/Outline show a `PriorityBadge`
  (SF Symbol `exclamationmark`/`.2`/`.3`, coloured blue/orange/red) instead of
  the `!`s. Only Free Mode shows the raw marker (highlighted in
  `FreeEditView`). It must be the last whitespace-separated token and exactly
  1–3 `!`: `Call mom!`, `Wow !!!!` and `Hey !! there` stay plain text.
- **Sorting is display-only.** The file keeps the user's own order;
  `ListoSection.displayTasks` / `ListoTask.displaySubtasks` are a stable sort
  by priority (highest first) that the views iterate. Physically reordering
  the file on every priority change was rejected: Free Mode edits would leave
  it unsorted anyway, so the views need the display sort regardless, and it
  would rewrite the user's file order behind their back.
- **Custom order = order within a priority.** ⌘↑/⌘↓ (`reorderTask`) moves
  among the *displayed* siblings and only swaps with one of the same
  priority (otherwise `noSiblingInDirection`, a silent no-op); crossing
  priorities is what the context menu's Priority submenu is for. Indent uses
  the sibling above *on screen*, and ↑/↓ navigation follows display order
  (`allTasksInDisplayOrder`).
- **Writers must preserve the marker.** `toggle` now edits only the
  checkbox (keeps the rest of the line verbatim); `renameTask` keeps the
  existing priority since the edit field shows the clean title — unless the
  new text itself ends in a marker, which sets it (type `Buy milk !!` into
  the title field). Line building goes through `ListoSerializer.taskLine`.
- **Log.** New `priority_changed` event kind. Its `text` is the task text
  with the new marker appended, or bare if the priority was cleared
  (`LogFormatter` tells them apart by that trailing token, which a task's
  own text can never end with). Free Mode changes are detected by the
  differ; the LLM prompt knows the kind too.

## Free Mode without a watcher

The FSEvents watcher (active while editing in Free Mode, comparing the file
before/after each write) was removed entirely — it was the source of the
paste-revert race above, and it wasn't needed: Free Mode is now only
interpreted **on save**. The text is edited freely with nothing diffing it
in between; only when the user saves (⌘S, the "Save" button that appears in
the toolbar in Free Mode, or macOS's autosave) does
`ListoFileDocument.onWillSave` trigger `DocumentController.handleSave`,
which compares against the text from the last time it was interpreted and
logs the result — heuristically if it's simple, via LLM if it's ambiguous,
`unresolved` if no key is configured. It's also interpreted when leaving
Free Mode without having saved, so Kanban/Outline reflect the latest text.
`Sources/ListoEngine/FileWatcher.swift` was removed from the engine.

## Stable IDs across reparses

Every App Mode action reparses the whole document
(`ListoEditor.commit()`), and until now every `ListoTask`/`ListoSection` got
a random `UUID()` on every parse. That broke SwiftUI's view identity:
`ForEach(id: \.id)` saw "everything deleted, everything inserted" on *every*
action, no matter how small the change — so a row's `@State` (an open note
popover, an in-progress rename) was lost as soon as *anything else* in the
document changed. That explained, for instance, why a just-saved note would
appear empty on reopen: by the time it reopened, the row had already been
destroyed and recreated by some other action in between.

`Sources/ListoEngine/StableID.swift` replaces that with a deterministic
UUID (truncated SHA-256) derived from content: section → `level + title +
parent`; task → `section + text` (or `parent task + text` for a subtask),
with a counter to disambiguate exact duplicates. As long as a task's
content and relative position don't change, its id stays the same across
reparses — even if some other task elsewhere in the document was just
edited. This stays purely in-memory (spec §09: never written to the file).

## Other decisions

- Renaming a section/column title (Kanban and Outline) — previously only
  tasks could be renamed. `ListoEditor.renameSection` rewrites just the
  heading line, preserving its level (`#`/`##`/`###`).
- Adding/editing a note in Outline (it used to only exist in Kanban) — same
  popover with a `TextEditor`, same indicator when a task already has a
  note.
- A note's content is now always shown on the card/row (Kanban and
  Outline), no click needed — tapping it opens the popover to edit it. This
  replaces the original spec §04 decision ("just an indicator, no
  preview"), at explicit request.
- Deleting a whole section (with its tasks and subsections) from its
  heading's "..." menu, with confirmation — `ListoEditor.deleteSection`.
- Deleting a single subtask via the context menu (previously it could only
  be toggled from the card; `ListoEditor.deleteTask` already supported
  subtasks, the UI entry was just missing).
- The "..." button for deleting a section was a `Menu` with a single
  option — macOS adds its own disclosure indicator on top of the chosen
  icon, so it showed two icons (dots + chevron) for one action. Replaced
  with a plain trash button with a direct confirmation.
- The note editor moved from `.popover(isPresented:)` plus a separately
  managed text `@State` to `.popover(item:)` (`NoteEditTarget`,
  `NoteEditorPopover` in `NoteEditor.swift`): the popover's content is built
  fresh every time it opens, instead of reusing an instance that could be
  left with stale text.
- Reopening the last file on launch is now more robust: besides the
  standard hook (`applicationShouldOpenUntitledFile`),
  `applicationDidFinishLaunching` checks whether the only open window is a
  blank, unedited document and, if so, replaces it with the real file — in
  case `DocumentGroup`'s lifecycle doesn't always go through the first
  hook.
- `LocalizationTable.swift` hardcodes es/en translations in code instead of
  a `.xcstrings` String Catalog, because `swift build` doesn't compile
  `.xcstrings` outside Xcode — `NSLocalizedString` against the original
  String Catalog was a silent no-op.
- Logs always stay in English: `LogFormatter.describe` (engine) and the
  source/interpretation labels in `LogPanelView` (app) used to generate
  Spanish text depending on the UI language. The log is a stable record
  meant for grep/external tools, not part of the localized UI — it stays
  fixed in English regardless of the language chosen in Settings. The
  user's own task content (`text`, titles) is never translated, as §07
  already established for the rest of the app.
- Release distribution is ad-hoc signed + `xattr -cr`, not notarized:
  getting a real Developer ID would mean a paid Apple Developer account
  (~$99/year). Ad-hoc signing plus stripping the download's Gatekeeper
  quarantine flag is enough for the app to open, without that cost — see
  `Scripts/publish_cask.sh`. If a Developer ID is ever set up, this is
  the path to swap for a signed/notarized one.

## Subtask log text and Delete-on-empty

- **Log text carries the parent.** Any logged action on a subtask writes
  `text` as `<task> > <subtask>` (`ListoDocument.logText(for:)`, also used by
  `ListoDiffer` for Free Mode), so a log line like `completed: "Buy milk"`
  doesn't lose *which* task's "Buy milk" it was. Top-level tasks log plain
  text, as before. Indent/outdent (`reindented`) log under whichever parent
  is involved — the new one on indent, the one it just left on outdent — so
  the line always names the relationship. The LLM interpretation prompt asks
  for the same format. The wire schema is unchanged; it's just the `text`
  value.
- **Delete/Backspace on an empty task or subtask deletes it**, in both
  Kanban and Outline, whether the row is being edited (empty field) or
  merely selected (empty title) — `DocumentController.deleteEmpty`. Focus
  moves to the previous task (or the next, if it was first) and stays in
  edit mode if it was editing. Two guards: it ignores key *repeats* (holding
  Backspace to clear a title must not carry on and delete the task), and it
  refuses when the task has a note or subtasks (`deleteTask` removes the
  whole block, and an empty title isn't evidence the user wants that
  content gone).

## Reordering with ⌘↑ / ⌘↓

With a task or subtask selected, ⌘↑/⌘↓ swap it with its previous/next
sibling (`ListoEditor.reorderTask`, moving the whole block — note and
subtasks included). A subtask never leaves its parent and a top-level task
never leaves its section; first/last is a silent no-op
(`noSiblingInDirection`, silenced in `DocumentController.reorder`) — moving
across sections stays the job of "Move to…" / drag & drop.

- Wired as Task-menu commands in `TaskCommands`, like indent/outdent, and
  disabled while the selected row's title is a live text field: there ⌘↑/⌘↓
  are the text field's own "jump to start/end" and must not reorder.
- Logged as a new `reordered` event kind rather than reusing `reindented`
  (which the log formatter renders as "changed indentation level"). Free Mode
  doesn't detect pure reorders — the Differ/LLM prompt are unchanged.

## Things-style row selection

`DocumentController.selectedTaskID` (shared between Kanban and Outline, so
it survives switching views). With a row selected, ⇥/⇧⇥ indent or outdent
without touching the mouse; right-click opens the context menu (including
the note option) for whichever row is clicked, and selects it too.

The first version of this relied almost entirely on a
`.simultaneousGesture(TapGesture())` on the row to mark the selection:

- Marking the selection doesn't depend on a single gesture: the checkbox
  button and the note icon already set it directly in their own action
  (guaranteed, since they're real buttons), and the text field has its own
  `@FocusState` (`isTextFieldFocused`) that sets it via `.onChange` as soon
  as it gains focus — covering "click to edit the text" without depending
  on a gesture competing with the `TextField`'s own native
  click-to-place-cursor. `.simultaneousGesture` + `.focusable()`/
  `@FocusState` (`isRowFocused`) is still there as a fallback for clicking
  empty space in the row.
- The selection is a plain background highlight
  (`.background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)`)
  — no border/stroke. An earlier version added an
  `.overlay(RoundedRectangle().stroke(...))` on top of the highlight to
  make selection read more clearly, similar to a Finder/Things list, but
  the background change alone reads clearly enough on its own and a
  stroked border around every row felt visually noisy, so the overlay was
  removed.
- `.contentShape(Rectangle())` was added so the whole row area (padding
  included, not just where there's text/icons) responds to clicks.

## Window: adjusted initial width and centered columns

The window now opens exactly wide enough to show every Kanban column
without scrolling (`KanbanView.idealContentWidth`, capped at 1400pt),
instead of an arbitrary fixed size. If it's maximized or grown beyond what
the columns need, they center (`GeometryReader` +
`.frame(minWidth:alignment:.center)`) instead of staying pinned to the left
with all the free space on the right; once there are more columns than fit,
it scrolls normally again with no centering effect.

## Native focus ring on the title field

Clicking a task's/section's title `TextField` showed macOS's native blue
focus ring *in addition to* the app's own selection border — two
indicators competing. `.focusEffectDisabled()` was added to every `.plain`
`TextField` (task title, section title) and to each row's `.focusable()`
container, so the background highlight described above is the only visible
selection indicator.

## Homebrew distribution: Formula → Cask

`brew install sergiorivas/tap/listo` failed on a clean machine with
`Errno::ENOENT: No such file or directory - Listo.app`, even though the
release zip genuinely contained it. Two independent bugs, the first
masking the second:

- The release zip (`ditto -c -k --keepParent Listo.app foo.zip`) had
  exactly one top-level entry: `Listo.app` itself, a directory. Homebrew's
  stage step auto-cd's into an archive's sole top-level directory before
  running `install` — a heuristic for tarballs like `mypkg-1.2.3/` that
  wrap the real payload — so it unwrapped `Listo.app` and ran `install`
  from *inside* it, where the formula's `prefix.install "Listo.app"` line
  found nothing by that name. Fixed (while this was still a Formula) by
  staging the app alongside a second top-level file before zipping, so
  the single-top-level-directory heuristic never triggers.
- With that fixed, `install` got further and hit a second, previously
  hidden failure: `ln -sf ... /Applications/Listo.app` — `Operation not
  permitted`. A Formula's `install` (and `post_install`) runs inside a
  sandbox that only allows writes under `HOMEBREW_PREFIX` and a handful
  of Homebrew-owned paths; there is no formula-level opt-in to extend
  that allowlist to `/Applications`, by design. No amount of patching the
  `install` method can make a Formula write there.

Rather than punting the `/Applications` step to a manual caveat, this
moved the whole distribution off Formula and onto a Cask
(`Casks/listo.rb` in the tap, generated by `Scripts/publish_cask.sh`,
replacing `Scripts/publish_formula.sh`) — the mechanism Homebrew actually
provides for placing a `.app` in `/Applications`, and not subject to the
Formula sandbox. The `app "Listo.app"` stanza handles the move; a
`postflight do ... end` block runs `xattr -cr` on the installed app
(equivalent to the old formula's `xattr -cr .` before `prefix.install`,
just performed after the cask's own install phase instead of before it).
Users now run `brew install --cask` and `brew trust --cask` instead of
the bare/`--formula` forms.
