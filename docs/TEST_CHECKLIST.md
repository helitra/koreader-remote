# Manual compatibility test checklist

Copy this checklist into a GitHub compatibility issue.

## Environment

- Platform:
- Exact device model:
- Firmware:
- KOReader version:
- KOReader Remote version:
- Installation method:
- Network type:

## Installation and loading

- [ ] Plugin folder is in the correct KOReader `plugins` directory
- [ ] Plugin appears in Plugin Manager
- [ ] `Tools → KOReader Remote` appears
- [ ] KOReader starts without a plugin-loading error

## Basic remote control

- [ ] Server starts
- [ ] Correct IP address is detected
- [ ] Full connection URL is shown
- [ ] QR code is displayed
- [ ] Phone opens the URL
- [ ] `/api/ping` responds
- [ ] Previous page works
- [ ] Next page works
- [ ] Server stops cleanly

## Settings

- [ ] Autostart can be enabled
- [ ] Autostart setting survives a KOReader restart
- [ ] Custom port can be saved
- [ ] Server restarts on the new port
- [ ] Old port is no longer reachable

## Standby and networking

- [ ] Server stops during standby or suspend
- [ ] Device wakes normally
- [ ] Wi-Fi reconnects
- [ ] Server becomes reachable again with autostart enabled
- [ ] Pairing screen shows the current IP after reconnect
- [ ] Changing Wi-Fi produces a new correct URL

## Problems

Describe every failed item and attach relevant `crash.log` lines.
