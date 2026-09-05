# Vendored Termux Android libraries

The following source modules are vendored from
[`termux/termux-app`](https://github.com/termux/termux-app):

- `terminal-emulator`
- `terminal-view`
- `termux-shared`

Pinned upstream commit:
`30ebb2dee381d292ade0f2868cfde0f9f20b89fe`.

The Java, C, resources, manifests, and upstream Gradle files in those module
directories are copied without source changes. Cuplivo only connects the
modules from its Android Gradle settings and implements its workspace-specific
service and Flutter adapters outside these directories.

See `NOTICE.md`, `LICENSE.md`, `termux-shared/LICENSE.md`, `licenses/`, and the
repository root `THIRD_PARTY_LICENSES.md` for licensing details.
