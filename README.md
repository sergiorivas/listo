# Listo

A to-do list that lives as plain Markdown on disk. See the full spec in the
original artifact; this README maps the spec to the code. For design
decisions, bug write-ups, and other background on *why* the code looks the
way it does, see `CLAUDE.md`.

## Structure

```
Sources/ListoEngine/     UI-independent engine (Swift Package), spec §02/§05/§06
  Model.swift            File → Section → Task → Subtask tree + note
                          (two levels: a Task may have a note, a Subtask
                          may not, and can't have subtasks of its own)
  Parser.swift           markdown → tree (2-space/tab indentation rule, §02)
  Serializer.swift       tree → markdown (used for new files and LLM merges)
  Editor.swift            App Mode actions: add/toggle/rename/delete a
                          task or section, note, indent, move — minimal
                          edits + a straight-line log (§03/§05)
  StableID.swift          Deterministic, content-derived UUID — a task's/
                          section's identity survives a reparse as long as
                          its content didn't change
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
  LocalizationTable.swift es/en translations in code, not a String Catalog
  RecentFilesStore.swift  Remembers opened files; reopens the last one on launch

Tests/ListoEngineTests/  43 tests covering the parser, editor, differ, and log
Scripts/version.sh       Derives the version from git tags (no manual input)
Scripts/build_app.sh     Builds an ad-hoc-signed Listo.app into dist/ — no
                         tests, tagging, or publishing; just a local build
Scripts/publish_cask.sh  Runs build_app.sh, uploads the zipped result as
                         a GitHub release asset, tags + pushes the release,
                         then regenerates Casks/listo.rb in the tap — the
                         active distribution path (see "Installing" below)
```

### Versioning

No need to pick or track versions by hand: `Scripts/version.sh` derives one
from the repo's `vX.Y.Z` tags (the next patch after the latest tag, or the
exact tag if `HEAD` is already tagged — `0.1.0` if there isn't one yet).
`publish_cask.sh` uses it automatically when not given an explicit
version, and creates and pushes the tag once its release is out, so the
next run picks up from there on its own.

## Installing

```
brew tap sergiorivas/tap
brew trust --cask sergiorivas/tap/listo
brew install --cask listo
```

`brew trust` is required since this is a non-official (third-party) tap —
Homebrew won't load its casks otherwise.

Downloads a prebuilt, ad-hoc-signed `.app` from the latest GitHub release
(see `Casks/listo.rb` in the
[tap](https://github.com/sergiorivas/homebrew-tap)) straight into
`/Applications`, then strips the download's Gatekeeper quarantine flag
(`xattr -cr`). This is a Cask rather than a Formula because a Formula's
`install` step runs in a sandbox that can't write to `/Applications` —
only a Cask can place a `.app` there.

To publish a new version once changes are committed:

```
Scripts/publish_cask.sh
```

Runs the tests, builds and ad-hoc-signs the `.app`, zips it, tags and
pushes the release, uploads the zip as a GitHub release asset, and
regenerates/commits/pushes `Casks/listo.rb` in the tap. Defaults to a
`../homebrew-tap` checkout alongside this repo; override with
`LISTO_TAP_DIR=/path/to/your/homebrew-tap/checkout`. `LISTO_GITHUB_REPO`
(default `sergiorivas/listo`) overrides which repo the cask points at.

## Development

```
swift build              # builds engine + app
swift test                # runs the engine's tests
swift run ListoApp         # launches the app (unsigned; fine for local dev)
Scripts/build_app.sh      # builds a signed Listo.app into dist/
```

Note on `swift test`/`swift run` on Apple Silicon under a Rosetta shell: if
`xctest`/the binary fails on architecture, run `arch -arm64 swift test`.

## User preferences

Besides the §07 defaults (system language, system appearance), Settings lets
you force a language (es/en/system) and theme (light/dark/system), plus a
base font size the rest of the sizes are relative to — adjustable there or
with ⌘+ / ⌘− / ⌘0 at any time, without relaunching the app. The app also
remembers the last file it had open (reopens it directly on launch instead
of a blank list) and offers "Open Recent" in the File menu, in addition to
macOS's own automatic recents.

## Known limitations

- `outdentTask` doesn't absorb the siblings that followed it as children —
  simplified semantics on purpose, not a bug, but worth keeping in mind if
  you expect Workflowy-style behavior.
- Ad-hoc signed, not notarized by Apple (see "Installing" above).
