# vlc-emby-play-sync

VLC Lua extension that syncs current playback position (resume point) to Emby server.

## Architecture

Single-file Lua extension (`emby-play-sync.lua`) using VLC's Lua extension API.

### Key files

| File | Purpose |
|------|---------|
| `emby-play-sync.lua` | Main VLC Lua extension — all logic in one file |
| `install.sh` | Symlinks extension into VLC's extension directory |

### VLC Adapter seam

All `vlc.*` calls live in a single `adapter` table at the top of the file. The rest of the logic calls `adapter.*` methods and never touches `vlc.*` directly. This creates a **seam** — swap `adapter` for a test adapter to run the full extension logic without VLC.

| Adapter method | Wraps | Returns |
|----------------|-------|---------|
| `debug/warn/error` | `vlc.msg.{dbg,warn,err}` | — |
| `config_path` | `vlc.config.userdatadir()` | `path` or nil |
| `read_file` / `write_file` | `vlc.io.open` | data / bool |
| `http_request` | `vlc.net.{connect_tcp,send,recv,poll,close}` | `status, body, header` |
| `get_current_uri` | `vlc.input.item():uri()` | `uri` or nil |
| `get_position_ticks` | `vlc.object.input()` → `vlc.var.get("time")` | ticks (int) |
| `get_playback_status` | `vlc.playlist.status()` + `vlc.var.get("state")` | `"playing"`/`"paused"`/`""` |
| `get_local_path` | `vlc.strings.make_path()` / `decode_uri()` | path or nil |
| `osd_message` | `vlc.osd.message` | — |
| `show_config_dialog` | `vlc.dialog` (takes `cfg`, calls `on_save(new_cfg)`) | — |
| `show_status_dialog` | `vlc.dialog` (takes lines table) | — |

### VLC Lua APIs used

- `descriptor()` / `activate()` / `deactivate()` / `close()` — extension lifecycle
- `input_changed()` — fires when media changes → match file to Emby item
- `playing_changed()` — fires on play/pause/stop → push position to Emby
- `meta_changed()` — required stub (VLC probes for it)
- `menu()` / `trigger_menu()` — "Sync Now", "Configure", "Status"

### Emby Client seam

All Emby REST API protocol lives in the `emby` table (after JSON helpers). It exposes methods that encapsulate URL building, payload encoding, and response parsing. Higher-level functions (session lifecycle, matching, user resolution) call these methods and never touch `emby_request` directly.

| Emby method | Endpoint | Returns |
|-------------|----------|---------|
| `find_item_by_path(path)` | `GET /Items?UserId=&Recursive=true&Path=` | item or nil |
| `search_hints(term)` | `GET /Search/Hints?UserId=&SearchTerm=&Limit=5` | hints or nil |
| `save_position(item_id, ticks)` | `POST /Users/{uid}/Items/{iid}/UserData` | bool |
| `start_session(item_id, pos, sid)` | `POST /Sessions/Playing` | bool |
| `report_progress(item_id, msid, pos, sid, event)` | `POST /Sessions/Playing/Progress` | bool |
| `end_session(item_id, msid, pos, sid)` | `POST /Sessions/Playing/Stopped` | bool |
| `list_users()` | `GET /Users` | users or nil |

Auth: `X-Emby-Token` header with API key (static key from Emby Admin).

### Config fields

| Field | Purpose |
|-------|---------|
| `server_url` | Emby server URL (e.g. `http://host:8096`) |
| `api_key` | Static API key from Emby Admin → Advanced → Security |
| `user_id` | Emby user name or UUID — resolved to UUID at activation |
| `local_path_prefix` | VLC-side path prefix for media files (e.g. `/mnt/nas/`) |
| `emby_path_prefix` | Emby-side path prefix (e.g. `/media/`) |

### Media Matcher seam

All path-to-item matching logic lives in the `matcher` table. It owns prefix translation, exact path search, filename fallback (with S##E## stripping), and the fallback chain policy — all behind `matcher.match(local_path)`.

| Matcher method | Purpose |
|----------------|---------|
| `translate_path(path)` | Map `local_path_prefix` → `emby_path_prefix` |
| `alternate_names(filename)` | Generate search variants (no ext, stripped S##E##) |
| `match(path)` | Try exact path, fallback to filename variants |

`match_and_cache()` calls `matcher.match(path)` and handles side effects (logging, OSD, state update).

### Timing

- Event-driven only (no timers — VLC Lua extension API doesn't support them)
- Emby auto-increments position between reports
- Syncs on: play, pause, resume, stop, VLC close, manual "Sync Now"
