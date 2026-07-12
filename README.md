<div align="center">

# KOReader Remote

**Turn pages and control KOReader from your phone browser.**

[![Latest release](https://img.shields.io/github/v/release/helitra/koreader-remote?style=for-the-badge)](https://github.com/helitra/koreader-remote/releases/latest)
[![License](https://img.shields.io/github/license/helitra/koreader-remote?style=for-the-badge)](LICENSE)
![KOReader plugin](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![No phone app](https://img.shields.io/badge/Phone_App-Not_Required-2ea44f?style=for-the-badge)

⭐ **If this plugin is useful to you, starring the repository helps a lot.** ⭐

---

### 👇 Demo

https://github.com/user-attachments/assets/f81e5089-8f5f-4a0a-93cc-433873eff57c

</div>

## 💡 Overview

KOReader Remote is a small plugin that lets you control KOReader from another device on the same local network.

Start the server, scan the QR code, and open the remote in your phone browser. There is no separate phone app, no account, and no cloud service in between.

The main controls stay large and close to your thumb. Device settings sit above them and can be collapsed when you do not need them.

## 🛏️ Why i made this

I made this plugin because i often put my Kindle somewhere on top of the blanket while reading in bed.

Sometimes i end up lying there like a folded protein, and reaching for the Kindle every single page gets annoying. My phone is usually already in my hand or somewhere next to my face, so using it as a remote just made sense.

The whole project was mostly vibe-coded — okay, basically all of it. It started as a tiny page-turn experiment and slowly became a real KOReader plugin. =)

## ✨ Features

### Remote reading

- Turn one page forward or backward
- Use two large, thumb-friendly page controls
- Use the left and right arrow keys with a keyboard
- Keep the same browser page after a normal reconnect
- Keep the server running while changing books or opening the file manager
- Show a clear message when no book is currently open

### Device controls

Controls appear only when KOReader reports that the current device supports them.

- Front light on or off
- Brightness presets and precise `−1 / +1` adjustment
- Gentle hold-to-repeat adjustment without large jumps
- Warm-light presets and precise adjustment
- KOReader night mode
- Full-screen refresh

### Pairing and reliability

- Automatic local IPv4 detection
- Full connection URL
- QR-code pairing
- Configurable server port
- Optional server autostart
- Wi-Fi retry after standby or resume
- Automatic browser reconnect when the reader becomes reachable again
- URL and QR payload change only after a real IP or port change
- Compact connection diagnostics inside KOReader

## 📱 Phone layout

The remote website is in English.

**Device settings** appear at the top and start collapsed whenever the remote website is opened.

Brightness presets:

```text
1% · 10% · 25% · 50% · 75% · 100%
```

Warmth presets:

```text
0% · 25% · 50% · 75% · 100%
```

A normal minus or plus tap changes exactly one percentage point. Holding the button starts a gentle repeat after a short delay. Every repeated step still remains exactly one percentage point. On readers with fewer native light levels, KOReader Remote keeps the selected percentage stable while the hardware uses the nearest supported level.

The remaining screen is split into two large touch areas:

```text
Previous page                 Next page
```

The next-page side stays close to the lower-right thumb position.

## ✅ Compatibility

| Platform | Status |
|---|---|
| Kindle | Primary test platform |
| Kobo | Expected to work; more real-device feedback is welcome |
| Other KOReader devices | Controls appear only when KOReader reports support |

When reporting a compatibility result, please include:

- device model
- KOReader version
- KOReader Remote version
- which controls worked or did not work

## 📦 Requirements

- KOReader installed
- A device that allows external KOReader plugins
- Reader and phone connected to the same local network
- A network that allows devices to communicate directly
- A jailbroken device when the platform requires it

Guest Wi-Fi networks sometimes block communication between local devices.

## 🛠️ Installation

1. Open the [latest release](https://github.com/helitra/koreader-remote/releases/latest).
2. Download `koreaderremote-v*.zip`.
3. Extract the ZIP file.
4. Stop KOReader Remote when an older version is currently running.
5. Copy the extracted folder:

   ```text
   koreaderremote.koplugin
   ```

   into the KOReader plugin directory:

   ```text
   Kindle: koreader/plugins/
   Kobo:   .adds/koreader/plugins/
   ```

6. Replace the previous plugin folder when upgrading.
7. Restart KOReader completely.
8. Open a book.
9. Go to:

   ```text
   Tools → KOReader Remote
   ```

10. Select:

   ```text
   Start remote server
   ```

## 🔗 Pairing

After the server starts, KOReader Remote shows an address similar to:

```text
http://192.168.1.42:8081/
```

Select:

```text
Show QR code
```

Scan the code with your phone camera. The remote should open directly in the browser.

You can show it again from:

```text
Tools → KOReader Remote → Pair phone / show QR code
```

The existing URL and QR payload stay unchanged when the reader wakes with the same IP address and port.

Pairing only opens the correct local address. It is not an authentication system.

## 💤 Manual sessions and autostart

Selecting **Start remote server** creates a manual session for the current KOReader run.

With autostart disabled:

- closing a book does not stop the server
- opening the file manager does not stop the server
- opening another book keeps the same server and browser page
- a short sleep of up to five minutes restores the manual session
- a longer sleep leaves it stopped after wake-up
- closing KOReader stops the server
- restarting KOReader does not start it again

Enable autostart here:

```text
Tools → KOReader Remote → Auto start remote server
```

With autostart enabled:

- the server starts with KOReader
- it returns after short or long sleep
- it waits for Wi-Fi before restarting

The server socket and Kindle firewall rule are removed while the reader is sleeping. A sleeping reader cannot be woken through the remote website.

## 🔄 Reconnect behavior

After wake-up, KOReader Remote:

- waits for a real network connection
- retries after 2, 5, 10, 20, and 30 seconds
- reacts to KOReader's `NetworkConnected` event
- starts once a usable local IPv4 address exists
- keeps the old URL when the same IP returns
- updates the URL and QR payload only after a real IP or port change

The phone website reloads the current device state after reconnecting.

When the IP address stays the same, the existing browser page should reconnect on its own. When the address changes, scan the current QR code again.

## 🔌 API

KOReader Remote exposes a small, restricted local HTTP API. It does not provide arbitrary access to KOReader events.

### Page control

```http
GET /api/ping
GET /api/next
GET /api/previous
```

### Device information

```http
GET /api/v1/capabilities
GET /api/v1/device-state
```

### Device actions

```http
POST /api/v1/frontlight/toggle
POST /api/v1/frontlight?enabled=true
POST /api/v1/brightness?value=65
POST /api/v1/warmth?value=40
POST /api/v1/night-mode?enabled=true
POST /api/v1/night-mode/toggle
POST /api/v1/full-refresh
```

Brightness and warmth use a simple percentage scale. The plugin translates those values to the current device's native range.

## 🔐 Security notes

- Use KOReader Remote only on a trusted local network.
- This version does not use authentication or an access token.
- Anyone who can reach the reader IP and port can use the available controls.
- Guest networks may block local device-to-device traffic.
- A sleeping reader cannot be woken through the remote server.
- Keeping Wi-Fi active may increase battery use.

## 🐛 Issues

Found a problem? Check the [Issues](https://github.com/helitra/koreader-remote/issues) page first. When opening a new issue, please include:

- a clear description
- steps to reproduce the problem
- device model
- KOReader version
- plugin version
- relevant logs or screenshots

## 🤝 Contributing

Small, focused pull requests are welcome.

1. Fork the repository.
2. Create a branch for the change.
3. Test it on a real KOReader device when possible.
4. Keep the plugin and repository small.
5. Open a pull request with a clear explanation of the change.

## 📜 License

KOReader Remote is licensed under the [GNU General Public License v3.0](LICENSE).
