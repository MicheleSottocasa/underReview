# Repository Guidelines

## Project Structure & Module Organization

This directory currently contains no application code, tests, assets, or build configuration. No Git repository is initialized. Update this guide when the project stack and layout are established.

For initial development, prefer `src/` for application code, `tests/` for automated tests, `assets/` for static resources, and `docs/` for supporting documentation. Group related functionality into focused modules and keep generated artifacts separate from source files.

## Build, Test, and Development Commands

No build, test, or local development commands are configured yet. When adding tooling, document the exact installation, development, build, lint, and test commands in `README.md`. Use scripts or task targets so contributors can repeat these operations consistently. Do not document commands as available until their configuration exists.

## Coding Style & Naming Conventions

No language-specific style or formatter is configured. Once a language is selected, adopt its standard formatter and linter, and commit their configuration. Follow those tools’ indentation rules. Use descriptive names, consistent file naming within each module, and small functions with clear responsibilities. Avoid unrelated formatting changes.

## Testing Guidelines

No testing framework or coverage threshold is established. Add tests alongside new behavior and regression tests for bug fixes. Mirror source modules under `tests/`, following the selected framework’s discovery conventions. Keep tests deterministic and independent of live services where practical.

## Commit & Pull Request Guidelines

There is no Git history from which to infer commit conventions. Use concise, imperative commit subjects, such as `Add initial project configuration`. Keep commits focused. Pull requests should explain the change, link relevant issues, list validation performed, and include screenshots for visible UI changes. State explicitly when tests could not be run.

## Security & Configuration

Never commit credentials or secrets. When introducing environment configuration, provide a sanitized example file and ignore local secrets and generated outputs.
