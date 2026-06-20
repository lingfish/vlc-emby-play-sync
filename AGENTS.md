# vlc-play-sync

VLC Lua extension that syncs current playback position (resume point) to Emby server.

## Architecture

Single-file Lua extension (`emby-play-sync.lua`) using VLC's Lua extension API.

### Key files

| File | Purpose |
|------|---------|
| `emby-play-sync.lua` | Main VLC Lua extension — all logic in one file |
| `install.sh` | Symlinks extension into VLC's extension directory |

### VLC Lua APIs used

- `descriptor()` / `activate()` / `deactivate()` / `close()` — extension lifecycle
- `input_changed()` — fires when media changes → match file to Emby item
- `status_changed()` — fires on play/pause/stop → push position to Emby
- `menu()` / `trigger_menu()` — "Sync Now", "Configure", "Status"
- `vlc.net` — raw TCP HTTP requests to Emby REST API
- `vlc.dialog` — configuration UI
- `vlc.input` / `vlc.player` — get current position and media URI

### Emby API calls

| Trigger | Endpoint | Purpose |
|---------|----------|---------|
| Play starts | `POST /Sessions/Playing` | Start playback session |
| Pause/resume | `POST /Sessions/Playing/Progress` | Report position + event name |
| Stop / VLC close | `POST /Sessions/Playing/Stopped` | End playback session |
| Media matched | `GET /Items` (via user library) | Find ItemId by file path |

Auth: `X-Emby-Token` header with API key (static key from Emby Admin).

### Media matching

1. Extract file URI from `vlc.input.item():uri()`
2. Convert to local path via `vlc.strings.make_path()`
3. Query Emby: `GET /Users/{UserId}/Items?Recursive=true&Filters=IsNotFolder&Path={path}`
4. Fallback: search by filename only
5. Cache ItemId and MediaSourceId for the session

### Timing

- Event-driven only (no timers — VLC Lua extension API doesn't support them)
- Emby auto-increments position between reports
- Syncs on: play, pause, resume, stop, VLC close, manual "Sync Now"
