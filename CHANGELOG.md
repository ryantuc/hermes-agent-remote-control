# Changelog

## Unreleased

- New app icon.
- Renaming, pinning, archiving or deleting a conversation now says so, naming the conversation, when the backend refuses, and puts the list back, instead of failing silently. On hermes-agent 0.22.1 and later these requests carry the revision check the backend asks for, and a change made somewhere else in the meantime is reported rather than overwritten.
- Editing an earlier message keeps working on Hermes backends that ask the app to confirm the later messages it removes. When such a backend refuses a Retry or an edit, the app says why in plain words.
- Browser actions on newer Hermes backends show the browser icon instead of the terminal icon, and their card shows the code the agent ran as Input. Retry after a browser step that ran code still asks before repeating it.
- The demo's Retry no longer warns that the turn changed files on your machine.
- The first-run screen and the local network permission prompt say "private network" instead of "VPN".
- Developer documentation and code comments are brought up to date for hermes-agent 0.22.5, and the build-number self-check runs on a stock Mac.

## 1.0.0 (2026-10-13)

Initial public release, submitted to the App Store as build 3.
