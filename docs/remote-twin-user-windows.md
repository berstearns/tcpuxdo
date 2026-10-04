# User windows in remote twins

Every generated `remote-<profile>` local tmux session has a `user-<profile>` window. Its agent and setup shell open a separate copy under `~/runs/<profile>-user-checkout`. A published Git remote is cloned when available; if the source has no published remote, the tool makes a separate clone of committed local history and says so. LinkedIn's annotation project is currently untracked in its parent Git repo, so its user window uses `~/runs/linkedin-user-annotation-snapshot` and reports that no published SHA exists. The developer working tree is never the user agent's working directory. Existing copies are reused so a user's notes and work survive launcher re-entry. The role instruction is `config/user-workflows/<profile>.md`, with `default.md` as fallback.

Android profiles also have a `ui-<profile>` window. It starts at the known Maestro runner for app7, app11, or app303. App9 has no verified runner in its checkout; the window says so and opens a shell. These windows show commands and leave execution to the owner. The `user-setup` pane lists the build and install path. By default, the installer downloads the newest APK from `hetzner:apps/<app>/release/`, transfers it to this laptop, and installs/launches it on the sole connected USB phone. Use an explicit artifact and serial for an emulator:

```sh
adb devices -l
/home/b/p/tcpuxdo/scripts/AUTO-download-install-and-launch-user-apk.sh app303-get-my-audio-android
/home/b/p/tcpuxdo/scripts/AUTO-download-install-and-launch-user-apk.sh app303-get-my-audio-android hetzner:apps/app303/release/FILE.apk emulator-SERIAL
```

The install helper prints the downloaded APK hash and uses the selected device serial. It needs `aapt` or `apkanalyzer` to discover the installed package for launching it. App303's user checkout is its nested `auto-app` repository, where the optional build is `scripts/AUTO-android-build.sh debug` and the UI runner is `scripts/AUTO-maestro-run.sh`. App7 uses `./run.sh flows/NAME.yaml [data/FILE.tsv]`; app11 uses its Maestro `run-all.sh`. App9 needs a verified automation runner before automated UI results can be claimed.

The LinkedIn user snapshot opens `linkedin-scraping/` to annotate feed and job posts, collect both, and read the resulting rows from remote Turso. The remote developer's keyboard prototype remains a separate codebase. The Gen-GEC-ERRANT user chooses model family and size × fine-tuned/native × L1/CEFR head/no head × one shard; `run.py` covers the base shard cells, and a head-enabled result requires the separate L1-CEFR conditioning artifact.

Re-run `scripts/AUTO-tcx-remote-pair-gen.sh` after adding profiles or changing generator logic. Reopening the i3minator launcher adds a missing user/UI window to an existing tmux session. Existing wedding and Duolingo user windows are preserved.
