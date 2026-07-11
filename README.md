# KOReader Remote v0.1.0

A minimal KOReader plugin that serves a local phone-friendly remote control.

## Features

- Start/stop from KOReader's "More tools" menu
- Fixed port: 8081
- Previous page
- Next page
- Local status endpoint
- Stops on standby, suspend, KOReader exit, or UI close
- Opens/removes Kindle firewall rules while running

## Installation

1. Stop the existing KOReader HTTP Inspector or leave it on port 8080.
2. Copy the complete folder `koreaderremote.koplugin` into:
   `koreader/plugins/`
3. Restart KOReader completely.
4. Open a book.
5. Go to:
   `Tools -> More tools -> KOReader Remote -> Start remote server`
6. On a phone in the same Wi-Fi network, open:
   `http://KINDLE-IP:8081/`

## Test endpoints

- `http://KINDLE-IP:8081/api/ping`
- `http://KINDLE-IP:8081/api/next`
- `http://KINDLE-IP:8081/api/previous`

## Notes

- This is version 0.1. It has no authentication.
- Use it only on a trusted local network.
- A sleeping Kindle cannot be awakened through this server.
- The server stops when KOReader enters standby/suspend or closes the current UI.
- complete AI slop, because i am to dumb to code myself =)
