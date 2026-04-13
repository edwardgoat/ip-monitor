# IPMonitor

`IPMonitor` is a lightweight macOS menu-bar app written in Objective-C++ that checks your public IP address by calling `https://ip.me`. It runs without a Dock icon, remembers the last public IP it saw, and sends a local macOS notification when that IP changes.

## What it does

- Polls `https://ip.me` every 5 minutes.
- Stores the last known public IP in `UserDefaults`.
- Sends a local notification when the public IP changes.
- Runs as a menu-bar app so you can check the current status or quit it manually.
- Uses C++ for the monitoring logic while keeping the macOS UI and notification integration native.

## Build

```bash
chmod +x build.sh install-launch-agent.sh uninstall-launch-agent.sh
./build.sh
```

The built app bundle will be created at:

```text
./build/IPMonitor.app
```

## Run Once

Open the app bundle from Finder, or run:

```bash
open ./build/IPMonitor.app
```

On first launch, macOS should prompt for notification permission. Allow notifications or the app will keep monitoring silently but cannot alert you when the IP changes.

## Install For Background Startup

To keep the app running in the background and restart it automatically at login:

```bash
./install-launch-agent.sh
```

This will:

- Copy the app to `~/Applications/IPMonitor.app`
- Install a per-user `launchd` agent at `~/Library/LaunchAgents/local.ipmonitor.plist`
- Configure it to start at login and stay alive if it exits

## Uninstall

```bash
./uninstall-launch-agent.sh
```
