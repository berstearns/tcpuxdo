# Windows / WSL worker — the double-click reconnect button

## One-command live repair from WSL

Paste this once in a WSL terminal and leave that terminal open:

```sh
curl -fsSL https://raw.githubusercontent.com/berstearns/tcpuxdo/master/setup/windows/wsl-watch.sh | bash
```

Every minute, the watcher fetches its latest version and the latest rescue
script from GitHub. Rescue updates the local checkout, checks the relay's
heartbeat for `wsl-`, and restarts the worker when needed. A new GitHub commit
also reloads the worker code. Failures print a reason and retry; the full log
is `~/tcpuxdo-rescue-watch.log`. The loop runs while this WSL session stays up.

When the laptop (m2) worker dies, only something running **on m2** can restart
it — tcpuxdo never pushes to nodes over the network. This folder turns that
restart into a Desktop double-click a non-technical person can run, and a
systemd service that mostly makes the click unnecessary.

## The pieces

| File | Side | Who runs it | Does |
|---|---|---|---|
| `AUTO-worker-bringup.sh` | WSL | the button (indirect) | ensure+verify the worker; prints `BRINGUP_RESULT=<code>` |
| `Reconnect-Worker.vbs` | Windows | **girlfriend** | double-click → hidden bring-up → friendly popup |
| `tcpuxdo-worker.service` | WSL | installer | user systemd unit template (`__REPO__`/`__NAME__`) |
| `Install-Worker-Autostart.sh` | WSL | **Bernardo, once** | install the service + boot-start (one sudo) |
| `Install-On-Windows.cmd` | Windows | **Bernardo, once** | drop the button on the Desktop + logon task |

## One-time setup (Bernardo, while you have access to m2)

1. In **WSL** — durable autostart (one sudo, for linger):
   ```sh
   cd ~/tcpuxdo && bash setup/windows/Install-Worker-Autostart.sh
   ```
   If it says systemd is off: add `[boot]\nsystemd=true` to `/etc/wsl.conf`,
   run `wsl --shutdown` in PowerShell, reopen WSL, re-run.

2. In **Windows** — the button + logon task (double-click):
   ```
   setup\windows\Install-On-Windows.cmd
   ```
   (You reach these files from Windows at
   `\\wsl$\<distro>\home\<user>\tcpuxdo\setup\windows\`, or copy the folder out.)

3. In `Reconnect-Worker.vbs`, if `wsl.exe` opens the wrong Linux, set
   `DISTRO` to the name from `wsl.exe -l -q`.

After this the worker starts on boot and restarts on crash; the button is the
manual override.

## What the girlfriend sees

Double-click **“Reconnect laptop worker”** on the Desktop, wait a few seconds:

- ✅ *Connected. You can close this.* — done.
- ⚠️ *Can't reach the server. Check WiFi / VPN, then click again.* — network.
- ⚠️ *Started the worker; it hasn't reached the server yet…* — wait a minute, click again.
- ❌ *Setup problem … Call Bernardo.* — a real config issue, not her fault.

No console window, no typing, no password.

## Does this fix the outage happening now?

No — nothing on m1 can reach a dead m2. This is the **durable** fix: install
it once while you have access, and the next outage either self-heals at
boot/crash or is one double-click away. It carries no secrets (`.env` already
lives on m2); the `.vbs` is a thin shim over the tracked bash program.

## Want a real .exe with an icon?

The `.vbs` is the button. To make it look like an app, either create a Desktop
shortcut to it and set a custom icon, or wrap it with `ps2exe` (PowerShell) or
a tiny Go/Rust launcher. The logic stays in `AUTO-worker-bringup.sh` either way.
