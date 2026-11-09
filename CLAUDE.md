# BCDDuo

Re-signs [BCD](https://github.com/thebcd69/bcd-games), a fork of Madeira that runs Windows games on iPhone
with no PC, for Giovanni's iPhone Duo. Personal sideload only, same shape as LiquidTok: not a kit app (no
`ci/app.env`), commits go straight to main.

- `scripts/patch.sh`   job `ipa`, no secrets: fetches the pinned release (`TAG` + `SHA256`), raises the app's
  linked SDK to 27.1 so it fills the inner display, swaps the bundle IDs to `com.gios.bcd*`, bumps
  `CFBundleVersion` per run. To update BCD, change `TAG` and `SHA256`.
- `fastlane/Fastfile` + `scripts/sign.sh`   job `sign`: registers the three App IDs, enables the memory
  capabilities, makes development profiles (match, gi-os/ios-certs) and signs. Development because JIT needs
  `get-task-allow`. It runs no third-party code.
- `scripts/install_link.sh [run-id] [minutes]`   on the Mac mini: decrypts a run's `BCD-development` artifact
  and serves a tap-to-install link. Serve from a renamed copy, because other sessions `pkill -f install_link.sh`.

Developer Mode must be on for a development-signed app to open (Settings > Privacy & Security). After a
fresh install, in BCD: set up JIT (in-app pairing on iOS 27, uses LocalDevVPN), then Settings > Graphics >
Foldable iPhone support.

Never commit IPAs or signing material. The repo is public, so the signed IPA goes up encrypted.
