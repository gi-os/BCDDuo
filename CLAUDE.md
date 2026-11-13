# BCDDuo

Re-signs [BCD](https://github.com/thebcd69/bcd-games), a fork of Madeira that runs Windows games on iPhone
with no PC, for Giovanni's iPhone Duo. Personal sideload only, same shape as LiquidTok: not a kit app (no
`ci/app.env`), commits go straight to main.

- `scripts/patch.sh`   job `ipa`, no secrets: fetches the pinned release (`TAG` + `SHA256`), raises the app's
  linked SDK to 27.1 so it fills the inner display, swaps the bundle IDs to `com.gios.bcd*`, bumps
  `CFBundleVersion` per run. To update BCD, change `TAG` and `SHA256`.
- `bridge/JoyCon2Bridge.m` + `scripts/add_dylib.py`   branch `joycon2` (works on the Duo as of
  2026-11-13; not merged to `main` yet): a library `patch.sh` builds and makes BCD load, which connects Joy-Con 2 over Bluetooth LE and shows
  BCD one virtual controller. Build it with `gh workflow run build.yml --ref joycon2`. `main` stays plain BCD.
  To connect a Joy-Con, hold its sync button; it writes nothing to the Joy-Con, so it stays paired to the
  Switch 2. Its log lines start `[joycon2]`.
- `fastlane/Fastfile` + `scripts/sign.sh`   job `sign`: registers the three App IDs, makes development
  profiles (match, gi-os/ios-certs) and signs. Development because JIT needs `get-task-allow`. It runs no
  third-party code. Apple's API can't enable Increased Memory Limit or Extended Virtual Addressing: they're
  set by hand on App ID `com.gios.bcd`, then `gh workflow run build.yml -f force_profiles=true` remakes the
  profiles. Without them the app installs but Memory+ stays off, and `sign` logs a warning.
- `scripts/install_link.sh [run-id] [minutes]`   on the Mac mini: decrypts a run's `BCD-development` artifact
  and serves a tap-to-install link. Serve from a renamed copy, because other sessions `pkill -f install_link.sh`.

Developer Mode must be on for a development-signed app to open (Settings > Privacy & Security). After a
fresh install, in BCD: set up JIT (in-app pairing on iOS 27, uses LocalDevVPN), then Settings > Graphics >
Foldable iPhone support.

Never commit IPAs or signing material. The repo is public, so the signed IPA goes up encrypted.
