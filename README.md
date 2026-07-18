<div align="center">

# KOReader Remote

**Turn pages and control KOReader from your phone browser.**

[![Latest release](https://img.shields.io/github/v/release/helitra/koreader-remote?style=for-the-badge)](https://github.com/helitra/koreader-remote/releases/latest)
[![License](https://img.shields.io/github/license/helitra/koreader-remote?style=for-the-badge)](LICENSE)
![KOReader plugin](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![No phone app](https://img.shields.io/badge/Phone_App-Not_Required-2ea44f?style=for-the-badge)

⭐ **If this plugin is useful to you, starring the repository helps a lot.** ⭐

[https://github.com/user-attachments/assets/5f46e15f-ffde-4b26-80c3-23264d424e81](https://github.com/user-attachments/assets/e6ffbf5f-6218-4887-b6f7-f912cd8d8683)

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

## ✅ Requirements

- KOReader installed
- A device that permits KOReader plugins
- Reader and phone on the same local network
- Direct device-to-device communication on that network
- Jailbreak access where required by the platform

Guest Wi-Fi networks often block local device-to-device traffic.

## 🚀 Start here

1. Download the latest `koreaderremote-v*.zip` from
   [Releases](https://github.com/helitra/koreader-remote/releases/latest).
2. Extract the ZIP and copy the complete `koreaderremote.koplugin` folder to:

   ```text
   Kindle: koreader/plugins/
   Kobo:   .adds/koreader/plugins/
   ```

3. Restart KOReader and open a book.
4. Select **Tools -> KOReader Remote -> Start remote server**.
5. Select **Show QR code** and scan it with your phone.

The QR code opens a local address such as `http://192.168.1.42:8081/`.

## ✨ Features

- Turn pages with large touch controls.
- Use keyboard arrow keys when available.
- Browse, search, sort, and open bookmarks, highlights, and notes.
- Open detected EPUB footnotes.
- Edit and sync the active KOReader note draft.
- Control supported frontlight, brightness, warmth, and night mode settings.
- Trigger a full-screen refresh on supported E-Ink devices.
- Use OLED mode for a pure-black interface.
- Recover the connection after standby and Wi-Fi reconnects.
- Start the server automatically with KOReader.
- No phone app, account, cloud service, or background GitHub polling.

## 🛠️ Troubleshooting

### “Remote UI missing”

The plugin cannot find `web/index.html`. Make sure the complete plugin folder
was copied and that the file exists at:

```text
Kindle: koreader/plugins/koreaderremote.koplugin/web/index.html
Kobo:   .adds/koreader/plugins/koreaderremote.koplugin/web/index.html
```

Download the ZIP again if the file is missing. Also check that the folder is
not nested twice, for example:
`koreaderremote.koplugin/koreaderremote.koplugin/`.

### The phone cannot connect

- Confirm that the reader and phone are on the same Wi-Fi network.
- Avoid guest networks that isolate connected devices.
- Restart the remote server after changing Wi-Fi networks.
- Show and scan the QR code again if the reader received a new IP address.

### The server does not return after standby

- Wait a few seconds for Wi-Fi to reconnect after waking the reader.
- Manually started sessions are restored after short sleep periods.
- Enable **Auto start remote server** to restore the server after longer sleep.
- The remote cannot wake a sleeping reader.

If the problem continues, include the device model, KOReader version, plugin
version, steps to reproduce, and a screenshot in a GitHub issue.

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
