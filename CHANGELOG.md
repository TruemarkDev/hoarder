# Changelog

All notable changes to this gem are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Engine now ships its own `config/locales/en.yml` with overridable defaults, so a
  host app no longer has to define `engine.hoarder.*` keys for messages to render.
- CSV-too-large validation message resolves lazily per request (was frozen at the
  boot-time locale) and uses the engine-owned `hoarder.errors.csv_too_large` key
  instead of a host-specific one.
- Status messages are resource-agnostic ("records"/"data") instead of referencing
  a specific domain.

### Added
- `MIT-LICENSE` and this changelog so the gem is packageable.

## [0.1.0]

- Initial extraction: resource-agnostic bulk CSV upload pipeline — upload lifecycle
  state machine, transactional/idempotent `#stage` / `#process` / `#process_in_batches`,
  and realtime progress broadcasting via a host-supplied broadcaster.
