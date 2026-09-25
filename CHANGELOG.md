# Changelog

## 1.2.1 — 2026-09-25

- Keep menu bar width and icon dimensions stable as allowances reach zero, reset to 100%, become stale, or become unavailable.
- Reopening QuotaBar or choosing Show Usage opens a regular usage window, so the app remains accessible when macOS hides a crowded menu bar item.
- Add regression coverage for zero, full, missing, and stale readings in each menu display mode.

## 1.2.0 — 2026-09-23

- Add Anthropic / Claude subscription usage beside Codex: `O` for OpenAI and `A` for Anthropic.
- Show Claude session, weekly, model-specific weekly windows, and reset times returned by Claude Code.
- Read usage through Claude Code’s experimental control interface using the existing local sign-in, with no model prompts or credential-file reads.
- Refresh each provider independently and clear Claude readings if its account or connection becomes unavailable.
- Add an Anthropic toggle and custom Claude executable path; automatically detect Conductor’s bundled Claude.

## 1.1.0 — 2026-09-16

- Follow changes to the shared local Codex sign-in used by Conductor, checking every five seconds without opening credential files.
- Reload the saved account on every usage refresh, including sign-ins stored in the macOS Keychain.
- Show the account email in the usage panel, hover details, and settings so two accounts are easy to distinguish.
- Clear old usage on a detected account change and discard responses from the previous account if a switch happens during refresh.
- Wait for the specific browser sign-in to finish before refreshing, so a cached account cannot prematurely end reconnection.
- Document account switching, separate Codex homes, and in-memory handling of account email.

## 1.0.1 — 2026-09-10

- Fix usage refresh and reconnect after restarting a Mac when Codex is installed through npm. QuotaBar now supplies interpreter search paths to its Codex subprocess instead of depending on a Terminal environment.
- Preserve the existing Codex sign-in and app preferences when reconnecting.
- Add regression coverage for starting, signing in, and reconnecting with the minimal macOS login environment.

## 1.0.0 — 2026-09-08

First public release of QuotaBar.

- Native macOS menu bar display for the main Codex subscription allowance.
- Remaining/used percentages, reset countdowns, and local reset times.
- Configurable display, refresh interval, warning color, and launch at login.
- ChatGPT sign-in through the installed Codex CLI.
- Visible stale, unavailable, and expired-reset states.
- Universal app download for Apple Silicon and Intel Macs, targeting macOS 14 or later.

This release is ad-hoc signed and not Apple-notarized. It requires Codex CLI and does not show general ChatGPT message limits or OpenAI API spending.
