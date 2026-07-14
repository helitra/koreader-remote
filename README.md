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
- Open the next detected footnote on the current EPUB page
- Browse bookmarks, highlights, and notes from the currently open book
- Jump the Kindle directly to a selected annotation from the phone
- Write and edit selected-text notes from the phone
- Pull an existing KOReader note into the phone editor and push changes back
- Use an optional pure-black OLED mode with inactivity dimming
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

### Pairing, reliability, and updates

- Manual update checks from the KOReader plugin menu
- Confirmed download and installation of newer stable GitHub releases
- SHA-256, archive-structure, and Lua-syntax checks before installation
- Previous-version backup until the updated plugin starts successfully
- Automatic local IPv4 detection
- Full connection URL
- QR-code pairing
- Configurable server port
- Optional server autostart
- Wi-Fi retry after standby or resume
- Automatic browser reconnect when the reader becomes reachable again
- URL and QR payload change only after a real IP or port change
- Compact connection diagnostics inside KOReader

### Reading presets

Open **Device settings → Reading presets** in the phone browser to apply or edit the built-in **Day**, **Night**, and **Large text** profiles. Each profile stores brightness, warmth, night mode, font size, top margin, bottom margin, and font weight on the reader.

## 🔖 Current-book bookmarks

The `🔖` toolbar button opens a separate list for the book that is currently open in KOReader.

The list contains KOReader's three annotation types:

- page bookmarks
- text highlights
- highlights with notes

Each entry shows its type, page or book position, chapter when available, highlighted text, and attached note. Plain page bookmarks are shown in italics so they are easier to distinguish from highlights and notes.

The phone view can:

- filter by **All**, **Bookmarks**, **Highlights**, or **Notes**
- search chapter names, selected text, notes, page labels, and annotation types
- sort in book order, newest first, oldest first, or by the most recently edited annotation
- open an annotation on the Kindle
- open a compact `...` menu on every entry
- add or edit a highlight note through the synchronized note editor
- remove only the note text while preserving the underlying highlight
- delete the complete bookmark, including its highlight and attached note

The first annotation jump captures the current reading position only once. You can then inspect any number of bookmarks and use **Return to reading position** to go directly back to where the excursion started. The return point remains available until it is used or the book is closed.

The overflow trigger is drawn as three separate dots with no border, background, button frame, emoji, or font glyph. Its touch target remains large enough for Safari, while only the three dots are visible in the top-right corner. The menu itself expands inside its annotation card so it cannot drift outside the card on narrow phone screens.

A note entry contains **Edit Note**, **Delete Note**, and **Delete Bookmark**. **Delete Note** clears only the note text and keeps the highlight; **Delete Bookmark** removes the complete annotation.

The list is refreshed when the tab opens or when the refresh button is pressed. Up to 300 entries are returned at once to keep the local web interface responsive.

## ✍️ Notes on Kindle and phone

The phone editor stays behind the small pencil icon in the toolbar.

To create a note:

```text
Select text on the reader
→ Write note on phone
→ the Kindle note dialog opens
→ type on Kindle, on the phone, or switch between both
```

To edit an existing note or highlight, open its highlight menu and choose:

```text
Edit note on phone
```

The Kindle dialog stays open during the remote-note session. Text that has not been saved yet can move in either direction:

- **Pull from Kindle** loads the current open Kindle draft into the phone editor.
- **Push to Kindle** places the phone text into the open Kindle dialog without saving it.
- **Save note** stores the current draft permanently in KOReader and closes the Kindle dialog.
- The normal **Save** button on the Kindle dialog stores the same shared draft.

This makes it possible to begin a note with the Kindle keyboard, continue it on the phone, push it back for review, and then save from either device.

A revision check prevents one device from silently overwriting a draft that changed on the other device. Only one note session can be active at a time, and it expires after 30 minutes. Cancelling a newly created remote note removes the temporary highlight, matching KOReader's regular new-note behavior.

## ¹ Footnote automation

The `¹` toolbar button asks KOReader to open the next link on the current page that passes KOReader's own footnote-popup detection.

This feature is intended for reflowable documents such as EPUB. Footnote detection depends on how the publisher built the book, so some books may have no detectable footnote, incomplete footnote content, or links that are not recognized as footnotes.

## 🌑 OLED mode

The `◐` toolbar button enables an optional OLED-oriented display mode:

- pure black page and panel backgrounds
- darker borders and controls
- reduced static brightness
- automatic dimming after 30 seconds without interaction
- the preference is stored only in the current browser

OLED mode reduces persistent bright pixels, but it cannot guarantee that display burn-in will never occur. Safari's browser chrome remains partly controlled by iOS unless the page is opened as a Home Screen web app.

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
GET /api/v1/note-session
GET /api/v1/bookmarks
```

### Reading and note actions

```http
POST /api/v1/bookmarks/open?id=...
POST /api/v1/bookmarks/return
POST /api/v1/bookmarks/edit-note?id=...
POST /api/v1/bookmarks/delete-note?id=...
POST /api/v1/bookmarks/delete?id=...
POST /api/v1/footnote/open
POST /api/v1/note-session/push
POST /api/v1/note-session/save
POST /api/v1/note-session/cancel
```

The note push endpoint uses bounded Base64-encoded UTF-8 text in request headers because KOReader's bundled simple HTTP server reads request headers but does not read an HTTP request body. Pushing updates only the open Kindle draft; the separate save endpoint commits that draft to the annotation.

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

## 🔄 Plugin updates

Open:

```text
Tools → KOReader Remote → Check for updates
```

The updater runs only after you select it. It does not check GitHub in the background.

When a newer stable release is available, KOReader Remote shows the installed and available versions and asks for confirmation. After confirmation it:

1. downloads the matching plugin ZIP and SHA-256 file from the GitHub release
2. verifies the checksum
3. checks every archive path and rejects links or files outside the plugin folder
4. compiles every downloaded Lua file without executing it
5. stops the remote server
6. keeps the existing plugin as a backup
7. installs the new version
8. asks KOReader to restart

The backup is removed only after the updated plugin starts successfully. Draft releases and pre-releases are ignored.

A checksum downloaded from the same GitHub release detects damaged or mismatched downloads. It does not protect against a compromised project account.

## 🔐 Security notes

- Use KOReader Remote only on a trusted local network.
- This version does not use authentication or an access token.
- Anyone who can reach the reader IP and port can use the available controls, browse annotations from the open book, navigate to them, edit notes, delete annotations, and submit text to an active remote-note session.
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
