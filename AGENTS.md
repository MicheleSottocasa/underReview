# Repository Guidelines

## Project Structure & Module Organization

ReviewDesk is a Swift package for a macOS 14+ app. See `README.md` for what each part does.

- `Sources/ReviewDeskCore/`: UI-free core, one file per concern (`Shell`, `Store`, `GitHub`, `Stacks`, `Diff`, `ReviewSync`, `Updates`, `AIContext`, `AIReviewer`). All external tools (`gh`, `claude`, `codex`, `ollama`) run through `CommandRunner`; never call `Process` or the network directly elsewhere.
- `Sources/ReviewDesk/`: the SwiftUI app. `AppModel` holds state, the `AppModel+*.swift` extensions hold feature actions, and there is one view file per area.
- `Tests/ReviewDeskCoreTests/`: one test file per core file.
- `assets/`: bundle resources (`Info.plist`).

`ReviewDesk.app` and `.build/` are generated and ignored.

## Build, Test, and Development Commands

- `make test`: runs the core tests.
- `make app`: builds and ad hoc signs `ReviewDesk.app`.
- `make run`: builds the app and opens it.
- `swift build` / `swift run ReviewDesk`: debug build and launch, without notifications.

These work with only the Command Line Tools installed. The Makefile passes the Swift Testing plugin path, and the app uses `@ViewState`, an alias of SwiftUI's `State` property wrapper, because the `@State` macro plugin ships only with Xcode.

## Coding Style & Naming Conventions

Follow the Swift API Design Guidelines with 4-space indentation. No formatter config is committed yet. Swift 6 language mode with strict concurrency is on: keep core types `Sendable` and the app model `@MainActor`. Prefer the standard library and platform APIs over new dependencies; the package has none. Mark deliberate shortcuts with a `ponytail:` comment that names the limit.

## Testing Guidelines

Tests use Swift Testing (`@Test`, `#expect`). Stub CLIs with `FakeRunner` and canned `gh` JSON; tests must not hit GitHub or AI providers. Add a regression test with every bug fix. The app target has no automated UI tests yet.

## Commit & Pull Request Guidelines

Use one scope per commit, with a concise imperative subject (`Add diff parser and comment anchors`). Never bundle unrelated changes into one macro commit. Pull requests should explain the change, list the validation performed, and include screenshots for visible UI changes. State explicitly when tests could not be run.

## Security & Configuration

Never commit credentials. `.envrc` and `.env` are ignored. GitHub auth belongs to `gh`. The AI CLIs must use their subscription login: never pass API keys to them, and keep `ProcessRunner.strippedEnvironment` up to date.
