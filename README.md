# vlc-emby-play-sync

![VLC 3.x](https://img.shields.io/badge/VLC-3.x-orange)
![Lua 5.1](https://img.shields.io/badge/Lua-5.1-blue)
![Emby 4.x](https://img.shields.io/badge/Emby-4.x-green)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-donate-ffdd00?logo=buymeacoffee)](https://buymeacoffee.com/lingfish)

VLC Lua extension that syncs playback position to Emby as a resume point.

## Installation

```bash
git clone https://github.com/lingfish/vlc-emby-play-sync
cd vlc-emby-play-sync
./install.sh
```

Restart VLC, then enable the extension via **View → Extension Manager** or the **Extensions** menu.

## Configuration

Open **View → Extension Manager → Emby Play Sync → Configure** and fill in:

| Field | Required | Description |
|-------|----------|-------------|
| **Emby Server URL** | Yes | `http://host:8096` |
| **API Key** | Yes | From Emby Admin → Advanced → Security |
| **User ID** | Yes | Emby username or UUID |
| **Local path prefix** | No | VLC-side mount path (e.g. `/mnt/nas/`) |
| **Emby path prefix** | No | Emby-side library path (e.g. `/shared/`) |

Path prefixes let VLC find the right Emby item when the file path differs (e.g. NFS mount vs Emby's internal path).

## How it works

1. When a file starts playing, VLC fires `input_changed()` → match file path to an Emby item via `GET /Items?Path=`
2. Plays, pauses, and stops push position ticks to Emby via the standard `/Sessions/Playing` endpoints
3. On stop, position is also written directly to Emby's `POST /Users/{UserId}/Items/{ItemId}/UserData` API for reliable resume-point storage

## Requirements

- VLC 3.x
- Emby Server 4.x

## Files

| File | Purpose |
|------|---------|
| `emby-play-sync.lua` | VLC Lua extension (single file) |
| `install.sh` | Symlinks extension into `~/.local/share/vlc/lua/extensions/` |
| `AGENTS.md` | Architecture notes for AI coding assistants |

## Support

If this extension helps you, consider buying me a coffee:

[![Buy Me a Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/lingfish)
