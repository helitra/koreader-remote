<div align="center">

# KOReader Remote

**Turn pages and control KOReader from your phone browser.**

[![Latest release](https://img.shields.io/github/v/release/helitra/koreader-remote?style=for-the-badge)](https://github.com/helitra/koreader-remote/releases/latest)
[![License](https://img.shields.io/github/license/helitra/koreader-remote?style=for-the-badge)](LICENSE)
![KOReader plugin](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![No phone app](https://img.shields.io/badge/Phone_App-Not_Required-2ea44f?style=for-the-badge)

⭐ **If this plugin is useful to you, starring the repository helps a lot.** ⭐

https://github.com/user-attachments/assets/f81e5089-8f5f-4a0a-93cc-433873eff57c

</div>

KOReader Remote turns your phone browser into a local remote for KOReader.
Turn pages, adjust supported device settings, and manage bookmarks and notes --
without an app, account, or cloud service.

## 🛏️ Why I made this

I made this plugin because I often put my Kindle somewhere on top of the
blanket while reading in bed.

Sometimes I end up lying there like a folded protein, and reaching for the
Kindle for every single page gets annoying. My phone is usually already in my
hand, or somewhere next to my face, so using it as a remote just made sense.

The whole project was mostly vibe-coded -- okay, basically all of it. It
started as a tiny page-turn experiment and slowly became a real KOReader
plugin. =)

## 🚀 Start here

### What you need

- KOReader and a device that permits external KOReader plugins
- Your reader and phone on the same local network
- A network that allows devices to communicate directly
- A jailbroken device where the platform requires one

Guest Wi-Fi networks often block local device-to-device traffic.

### Install and pair

1. Download and extract `koreaderremote-v*.zip` from the
   [latest release](https://github.com/helitra/koreader-remote/releases/latest).
2. Copy `koreaderremote.koplugin` into KOReader's plugin directory:

   ```text
   Kindle: koreader/plugins/
   Kobo:   .adds/koreader/plugins/
   ```

3. Restart KOReader, open a book, then select:

   ```text
   Tools -> KOReader Remote -> Start remote server
   ```

4. Select **Show QR code** and scan the code with your phone.

The QR code opens a local address such as `http://192.168.1.42:8081/`.

## ✨ What it does

### Read comfortably

- Large thumb-friendly previous/next page controls and keyboard arrow keys
- Open the next detected EPUB footnote from the current page
- Browse, search, sort, and jump to bookmarks, highlights, and notes
- Return to the reading position after inspecting annotations
- Optional pure-black OLED mode

### Control supported devices

- Front light, brightness, warmth, night mode, and full-screen refresh
- Presets plus precise one-percent adjustment with gentle hold-to-repeat
- Controls appear only when KOReader reports support for the device

### Work with notes

- Create a selected-text note from the phone
- Pull the open KOReader draft to the phone, or let changes sync automatically;
  save the note from either device
- Edit a highlight note, remove its text while retaining the highlight, or
  delete the complete annotation

Only one remote-note session is active at a time. It expires after 30 minutes
and prevents either device from silently overwriting a newer draft.

### Stay connected

- QR-code sharing and configurable server port
- Optional automatic start with KOReader
- Wi-Fi recovery after standby and browser reconnection when the reader returns
- The server remains available while changing books or visiting the file manager

## 📖 Everyday use

**Bookmarks and notes.** Use the `🔖` toolbar button for annotations in the
currently open book. The `✎` button opens the phone note editor. To edit an
existing note, use its annotation menu and choose **Edit note on phone**.

**Footnotes.** The `¹` button asks KOReader to open the next link on the page
that KOReader recognises as a footnote. Detection depends on the EPUB, so it
will not work for every book.

**Display.** Device settings start collapsed at the top of the phone page.
The `◐` button enables OLED mode. It reduces persistent bright pixels, but
cannot guarantee against burn-in; Safari controls its own browser chrome.

**Autostart and standby.** A manually started server survives book and UI
changes, and is restored after a short sleep (up to five minutes). With
**Auto start remote server** enabled, it also returns after longer sleeps once
Wi-Fi is ready. A sleeping reader cannot be woken through the remote website.

If the reader receives a new IP address after wake-up, show and scan the QR
code again. With the same address, the browser reconnects on its own.

## ✅ Compatibility

| Platform | Status |
|---|---|
| Kindle | Primary test platform |
| Kobo | Expected to work; real-device feedback is welcome |
| Other KOReader devices | Available controls depend on KOReader support |

## 🔄 Updates

Select:

```text
Tools -> KOReader Remote -> Check for updates
```

Updates are manual: the plugin never polls GitHub in the background. In
**Update channel**, choose **Stable** for tested releases or **Dev** for
builds from the `dev` branch. Before an update replaces the plugin, it
verifies the release checksum, archive layout, build metadata, and Lua syntax,
then keeps the previous version as a backup until the new one has started
successfully. Dev builds show their release number, build ID, and commit SHA.

Stable releases are published from `main`. Dev updates are fetched directly
from the exact commit at the tip of the `dev` branch; they do not create
GitHub Releases or a second artifact branch. The updater downloads the GitHub
commit ZIP, verifies its plugin layout and build identity, and installs it as
a Dev build. Switch back to Stable when you want the regular release stream.

## 🔐 Security

KOReader Remote is for trusted local networks. It has no authentication or
access token: anyone who can reach the reader's IP and port can use its remote
controls and access the annotations of the open book. Do not expose it to the
internet. Keeping Wi-Fi active can increase battery use.

## 🔌 API

The local HTTP API is deliberately limited; it does not expose arbitrary
KOReader events.

```http
GET  /api/ping
GET  /api/next
GET  /api/previous
GET  /api/v1/capabilities
GET  /api/v1/device-state
GET  /api/v1/note-session
GET  /api/v1/bookmarks
POST /api/v1/bookmarks/open?id=...
POST /api/v1/bookmarks/return
POST /api/v1/bookmarks/edit-note?id=...
POST /api/v1/bookmarks/delete-note?id=...
POST /api/v1/bookmarks/delete?id=...
POST /api/v1/footnote/open
POST /api/v1/note-session/push
POST /api/v1/note-session/save
POST /api/v1/note-session/cancel
POST /api/v1/frontlight/toggle
POST /api/v1/frontlight?enabled=true
POST /api/v1/brightness?value=65
POST /api/v1/warmth?value=40
POST /api/v1/night-mode?enabled=true
POST /api/v1/night-mode/toggle
POST /api/v1/full-refresh
```

Brightness and warmth use percentages and are translated to the device's
native range. Note text is sent as bounded Base64-encoded UTF-8 request
headers because KOReader's bundled HTTP server does not read request bodies.
The status responses also include `channel`, `source`, `release_version`,
`build_id`, and `commit` so Dev testers can identify the exact build.

## 🐛 Help and contributing

For a problem, check [Issues](https://github.com/helitra/koreader-remote/issues)
and include steps to reproduce, device model, KOReader and plugin versions,
plus relevant logs or screenshots.

Small, focused pull requests are welcome. Please test on a real KOReader device
when possible and explain the behaviour change clearly.

## 📜 License

KOReader Remote is licensed under the [GNU General Public License v3.0](LICENSE).
