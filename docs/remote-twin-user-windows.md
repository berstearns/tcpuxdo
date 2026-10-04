# User windows in remote twins

Every generated `remote-<profile>` local tmux session has a `user-<profile>` window. Its agent and setup shell open a separate checkout under `~/runs/<profile>-user-checkout`. A published Git remote is cloned when available; if the source has no published remote, the tool makes a separate clone of committed local history and says so. The developer working tree is never the user agent's working directory. Existing checkouts are reused so a user's notes and work survive launcher re-entry. The role instruction is `config/user-workflows/<profile>.md`, with `default.md` as fallback.

Android profiles also have a `ui-<profile>` window. It starts at the known Maestro runner for app7, app11, or app303. App9 has no verified runner in its checkout; the window says so and opens a shell. These windows show commands and leave execution to the owner. The `user-setup` pane lists the build and install path. To install a published or locally built APK on a specific USB phone or emulator:

```sh
adb devices -l
/home/b/p/tcpuxdo/scripts/AUTO-download-install-and-launch-user-apk.sh app303-get-my-audio-android APK_URL_OR_FILE DEVICE_SERIAL
```

The install helper prints the APK hash and uses the selected device serial. It needs `aapt` or `apkanalyzer` to discover the installed package for launching it. App303's user checkout is its nested `auto-app` repository, where the optional build is `scripts/AUTO-android-build.sh debug` and the UI runner is `scripts/AUTO-maestro-run.sh`. App7 and app11 show their existing Maestro `run-all.sh` in the `ui` pane. App9 needs a verified automation runner before automated UI results can be claimed.

Re-run `scripts/AUTO-tcx-remote-pair-gen.sh` after adding profiles or changing generator logic. Reopening the i3minator launcher adds a missing user/UI window to an existing tmux session. Existing wedding and Duolingo user windows are preserved.
