# Changelog

All notable changes to Commander will be documented in this file.

## [Unreleased]
- Nothing yet.

## [0.2.0] - 2025-12-05

### Breaking
- Commands now declare metadata via `commandDescription` (using `CommandDescription` / `MainActorCommandDescription.describe`) instead of the old ArgumentParser-style `configuration`. Update command types and any helpers that read command metadata.

### Added
- Commander-native `CommandDescription` model with support for abstracts, discussions, versions, usage examples, default subcommands, and “show help on empty invocation” behavior.
- Alias support for flag/option names (`CommanderName.aliasLong` / `aliasShort`) so you can keep compatibility spellings (e.g., `--json-output`, `--jsonOutput`) while presenting clean primary names such as `--json` / `-j`.
- Standard runtime flags now include `--log-level <trace|verbose|debug|info|warning|error|critical>` alongside `-v/--verbose` and the new JSON aliases.
- Added a DocC catalog plus multiplatform guide; README refreshed with the current platform story.

### Fixed
- Optional positional arguments no longer trap when accessed before binding; they now surface `nil` as expected for optional types.

### Platform/CI
- CI matrix trimmed to the platforms we actually exercise (macOS, Linux, Apple simulators); Windows/Android legs were removed and badges now match the supported set.

## [0.1.0] - 2025-11-11

### Highlights
- Declarative property-wrapper API (`@Option`, `@Argument`, `@Flag`, `@OptionGroup`) that builds `CommandSignature` metadata for parsing, help, and agent tooling.
- Program router (`Program.resolve`) that walks root/subcommand/default-subcommand hierarchies and returns parsed `CommandInvocation` values.
- Standard runtime flags out of the box (`-v/--verbose`, `--json-output`) with centralized parsing/validation.
- Binder APIs (`CommanderBindableCommand`, `CommanderBindableValues`) so existing command structs can hydrate from parsed values without rewriting runtime logic.
- Concurrency-safe by default with strict concurrency settings enabled across the package.
