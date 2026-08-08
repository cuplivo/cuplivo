# Android jniLibs (Cuplivo sandbox)

Bundled native libraries used by the Cuplivo Linux sandbox on Android:

- `libproot_exec.so` — PRoot user-space chroot helper
- `libproot_loader.so` — PRoot loader companion

## Supported ABIs

- `arm64-v8a`
- `x86_64`

## License

PRoot is free software under the GNU General Public License version 2 or later
(GPL-2.0-or-later). See upstream PRoot project documentation for full terms.

These binaries are used only for optional local sandbox convenience isolation
inside the app; they are not a security boundary.
