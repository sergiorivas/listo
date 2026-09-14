# Listo

A to-do list that lives as plain Markdown on disk. See the full spec in the
original artifact; this README just maps the spec to the code.

## Structure

```
Sources/ListoEngine/     UI-independent engine (Swift Package), spec §02/§05/§06
  Model.swift            File → Section → Task → Subtask tree + note.
                          Deliberately two levels: a Task (optional note)
                          and its Subtasks (no note, no subtasks of their
                          own) — see "Two-level model" below.
  Parser.swift           markdown → tree (2-space/tab indentation rule, §02)
  Serializer.swift       tree → markdown (used for new files and LLM merges)
  Editor.swift            App Mode actions: add/toggle/rename/delete a
                          task or section, note, indent, move — minimal
                          edits + a straight-line log (§03/§05)
  StableID.swift          Deterministic, content-derived UUID — a task's/
                          section's identity survives a reparse as long as
                          its content didn't change (see "Stable IDs" below)
  Differ.swift            Free Mode diff heuristic + ambiguity detection (§05)
  LogEvent.swift          Exact JSONL schema from §05
  LogWriter.swift         Log persistence + human-readable formatting
  LLMClient.swift         Interpreting ambiguous diffs + conflict merges (§03/§05)
  KeychainStore.swift     User's API key in the Keychain (§09 "bring your own LLM")

Sources/ListoApp/        SwiftUI app (macOS executable), ADR-001
  ListoApp.swift          @main, DocumentGroup (native tabs per document)
  ListoFileDocument.swift ReferenceFileDocument — raw text, round-trips
                          with SwiftUI; `onWillSave` triggers the Free Mode
                          diff
  DocumentController.swift Wires the engine to the UI: modes, diff on save,
                          log
  ContentView.swift       Toolbar (App/Free Mode, Kanban/Outline, Save, history)
  KanbanView.swift        Board view (§04)
  OutlineBoardView.swift  Document view with real typographic hierarchy (§04)
  FreeEditView.swift      Wrapped NSTextView, syntax highlighting (ADR-001)
  SettingsView.swift      API key (§09) + language, theme, and font size
  LogPanelView.swift      Interpreted history + export (.jsonl or text)
  Localization.swift      AppSettings (language/theme/font size) + L(key, value)
  LocalizationTable.swift es/en translations in code (`swift build` doesn't
                          compile `.xcstrings` outside Xcode, so
                          NSLocalizedString against the original String
                          Catalog was a no-op)
  RecentFilesStore.swift  Remembers opened files; reopens the last one on launch

Tests/ListoEngineTests/  43 tests covering the parser, editor, differ, and log
Scripts/version.sh       Derives the version from git tags (no manual input)
Scripts/release.sh       build → codesign → notarytool → staple (§08)
Scripts/publish_cask.sh  release.sh + updates the cask's sha256/version +
                         publishes the GitHub release + tags and pushes the
                         version + (optionally) pushes to the tap
Casks/listo.rb           Homebrew Cask template (§08)
```

### Versioning

No need to pick or track versions by hand: `Scripts/version.sh` derives one
from the repo's `vX.Y.Z` tags (the next patch after the latest tag, or the
exact tag if `HEAD` is already tagged — `0.1.0` if there isn't one yet).
`release.sh` and `publish_cask.sh` use it automatically when not given an
explicit version, and `publish_cask.sh` creates and pushes the tag once the
release is out, so the next run picks up from there on its own.

## Development

```
swift build              # builds engine + app
swift test                # runs the engine's tests
swift run ListoApp         # launches the app (unsigned; fine for local dev)
```

Note on `swift test`/`swift run` on Apple Silicon under a Rosetta shell: if
`xctest`/the binary fails on architecture, run `arch -arm64 swift test`.

## User preferences

Besides the §07 defaults (system language, system appearance), Settings now
lets you force a language (es/en/system) and theme (light/dark/system), plus
a base font size the rest of the sizes are relative to — adjustable there or
with ⌘+ / ⌘− / ⌘0 at any time, without relaunching the app. The app also
remembers the last file it had open (reopens it directly on launch instead
of a blank list) and offers "Open Recent" in the File menu, in addition to
macOS's own automatic recents.

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

## Free Mode without a watcher

The FSEvents watcher (active while editing in Free Mode, comparing the file
before/after each write) was removed entirely — it was the source of the
race conditions above, and it wasn't needed: Free Mode is now only
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

## Other features added

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

**This also explains the "can't edit a subtask's note" bug that used to
exist:** each subtask row had its own `.popover(item:)` *nested inside* the
parent `TaskChip`/`OutlineTaskRow`'s popover — nesting popovers is a known
SwiftUI weak spot, and the inner one could simply fail to appear. There's
now a single popover per top-level card/row (in `TaskChip`/
`OutlineTaskRow`), and each subtask row bubbles its note-edit request up
via a closure (`onEditNote`) instead of opening its own. (Since then,
subtasks lost note support entirely — see "Two-level model" above — but the
single-popover-per-top-level-row structure it left behind is still how the
note editor works today.)

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

## Note indentation growing on every save

`ListoTask.note` used to store the line *raw, exactly as it was in the
file*, structural indentation included (e.g. `"  See the thread on
GitHub"`). The edit popover was seeded with that value (the full
`task.note`, indentation already baked in), and `ListoEditor.setNote` adds
its own indentation on save — so reopening a note and saving it unchanged
added one extra indent unit (2 spaces) every time.

`ListoParser.finalizeNote` now stores the note *dedented*: it strips
exactly the one structural unit that marks it as "this task's note"
(preserving any extra indentation the user put inside it, e.g. a nested
list within the note), and `Serializer`/`ListoEditor.setNote` re-add it when
writing. `task.note` is now clean logical content; the file still has the
real indentation. Covered by tests that force several save cycles with no
changes and verify the file's indentation doesn't grow.

## Logs always stay in English

`LogFormatter.describe` (engine) and the source/interpretation labels in
`LogPanelView` (app) used to generate Spanish text depending on the UI
language. The log is a stable record meant for grep/external tools, not
part of the localized UI — for now it stays fixed in English regardless of
the language chosen in Settings. The user's own task content (`text`,
titles) is never translated, as §07 already established for the rest of
the app.

## What's missing for a real release

- An Apple Developer account (~$99/year) to sign and notarize (§08) — the
  script is already written, it just needs to run with a real identity.
- A real GitHub repo and (optionally) a Homebrew tap of your own for
  `Scripts/publish_cask.sh` — set `LISTO_GITHUB_REPO` and `LISTO_TAP_DIR`
  before running it; today they point at placeholders (`yourname/listo`).
- An app icon (`Assets.xcassets` / `.icns`) — not included.
- `outdentTask` doesn't absorb the siblings that followed it as children
  (see above) — simplified semantics on purpose, not a bug, but worth
  keeping in mind if you expect Workflowy-style behavior.
