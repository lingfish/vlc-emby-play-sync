-- Emby Play Sync — VLC Lua extension
-- Syncs current playback position to Emby server as a resume point.

local EXT_TITLE = "Emby Play Sync"
local EXT_VERSION = "1.0"

local cfg = {
  server_url = "",
  api_key = "",
  user_id = ""
}

local state = {
  playing = false,
  item_id = nil,
  media_source_id = nil,
  play_session_id = nil,
  item_matched = false,
  last_sync = 0,
  last_status = ""
}

local function dmsg(...)
  vlc.msg.dbg("[" .. EXT_TITLE .. "] " .. string.format(...))
end

local function dwarn(...)
  vlc.msg.warn("[" .. EXT_TITLE .. "] " .. string.format(...))
end

local function derr(...)
  vlc.msg.err("[" .. EXT_TITLE .. "] " .. string.format(...))
end

-- URL encoding (VLC doesn't provide encode_uri_component)
local function url_encode(s)
  if not s then return "" end
  return s:gsub("([^%w_%-%.%~])", function(c)
    return string.format("%%%02X", c:byte())
  end)
end

-- JSON helpers

local function json_decode(s)
  local idx, len = 1, #s
  local function peek() return s:sub(idx, idx) end
  local function adv()
    local c = s:sub(idx, idx)
    idx = idx + 1
    return c
  end
  local function skip()
    while idx <= len and s:sub(idx, idx):match("%s") do idx = idx + 1 end
  end
  local function parse_str()
    adv()
    local res = ""
    while idx <= len do
      local c = adv()
      if c == '"' then return res end
      if c == '\\' then
        local n = adv()
        if n == '"' then res = res .. '"'
        elseif n == '\\' then res = res .. '\\'
        elseif n == '/' then res = res .. '/'
        elseif n == 'n' then res = res .. '\n'
        elseif n == 't' then res = res .. '\t'
        elseif n == 'r' then res = res .. '\r'
        elseif n == 'u' then
          local hex = s:sub(idx, idx + 3)
          idx = idx + 4
          local cp = tonumber(hex, 16)
          if cp then
            if cp < 128 then
              res = res .. string.char(cp)
            elseif cp < 2048 then
              res = res .. string.char(192 + cp / 64, 128 + cp % 64)
            else
              res = res .. string.char(224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64)
            end
          else
            res = res .. '?'
          end
        else
          res = res .. n
        end
      else
        res = res .. c
      end
    end
    error("unterminated string")
  end
  local function parse_num()
    local start = idx
    if peek() == '-' then idx = idx + 1 end
    while idx <= len and s:sub(idx, idx):match("%d") do idx = idx + 1 end
    if peek() == '.' then
      idx = idx + 1
      while idx <= len and s:sub(idx, idx):match("%d") do idx = idx + 1 end
    end
    if s:sub(idx, idx):match("[eE]") then
      idx = idx + 1
      if s:sub(idx, idx):match("[+-]") then idx = idx + 1 end
      while idx <= len and s:sub(idx, idx):match("%d") do idx = idx + 1 end
    end
    return tonumber(s:sub(start, idx - 1))
  end
  local function parse_val()
    skip()
    local c = peek()
    if c == '"' then return parse_str()
    elseif c == '{' then
      idx = idx + 1
      local o = {}
      skip()
      if peek() == '}' then idx = idx + 1; return o end
      while idx <= len do
        skip()
        local k = parse_str()
        skip()
        assert(adv() == ':')
        o[k] = parse_val()
        skip()
        c = adv()
        if c == '}' then return o end
        assert(c == ',')
      end
      error("unterminated object")
    elseif c == '[' then
      idx = idx + 1
      local a = {}
      skip()
      if peek() == ']' then idx = idx + 1; return a end
      while idx <= len do
        a[#a + 1] = parse_val()
        skip()
        c = adv()
        if c == ']' then return a end
        assert(c == ',')
      end
      error("unterminated array")
    elseif s:sub(idx, idx + 3) == 'true' then idx = idx + 4; return true
    elseif s:sub(idx, idx + 4) == 'false' then idx = idx + 5; return false
    elseif s:sub(idx, idx + 3) == 'null' then idx = idx + 4; return nil
    else return parse_num() end
  end
  local res = parse_val()
  skip()
  return res
end

local function json_encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then return tostring(v)
  elseif t == "string" then
    return '"' .. v:gsub('[%z\1-\31"\\]', function(c)
      if c == '"' then return '\\"'
      elseif c == '\\' then return '\\\\'
      elseif c == '\b' then return '\\b'
      elseif c == '\f' then return '\\f'
      elseif c == '\n' then return '\\n'
      elseif c == '\r' then return '\\r'
      elseif c == '\t' then return '\\t'
      else return string.format('\\u%04x', c:byte()) end
    end) .. '"'
  elseif t == "table" then
    local max, is_arr = 0, true
    for k in pairs(v) do
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then is_arr = false; break end
      if k > max then max = k end
    end
    if is_arr then
      local parts = {}
      for i = 1, max do parts[i] = json_encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = json_encode(tostring(k)) .. ':' .. json_encode(val)
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  else
    return '"' .. tostring(v) .. '"'
  end
end

-- Config persistence via file in VLC config dir
local function config_path()
  local userdata = vlc.config.userdatadir()
  if not userdata then return nil end
  return userdata .. "/emby_play_sync.json"
end

local function load_config()
  local path = config_path()
  if not path then
    dmsg("no user data dir, cannot load config")
    return
  end
  local f = vlc.io.open(path, "rb")
  if not f then
    dmsg("no config file at %s", path)
    return
  end
  local data = f:read("*all")
  f:close()
  if data and data ~= "" then
    local ok, parsed = pcall(json_decode, data)
    if ok and parsed then
      cfg.server_url = parsed.server_url or ""
      cfg.api_key = parsed.api_key or ""
      cfg.user_id = parsed.user_id or ""
      dmsg("config loaded from %s", path)
      return
    end
  end
  dmsg("empty or invalid config file")
end

local function save_config()
  local path = config_path()
  if not path then
    derr("no user data dir, cannot save config")
    return
  end
  local ok, encoded = pcall(json_encode, cfg)
  if not ok then
    derr("failed to encode config")
    return
  end
  local f = vlc.io.open(path, "wb")
  if not f then
    derr("cannot write config to %s", path)
    return
  end
  f:write(encoded)
  f:close()
  dmsg("config saved to %s", path)
end

-- HTTP client via vlc.net

local function build_emby_url(path)
  local base = cfg.server_url:gsub("/+$", "")
  return base .. path
end

local function parse_url(url)
  local parsed = vlc.strings.url_parse(url)
  return parsed["host"], parsed["port"] or "8096", parsed["path"]
end

local function emby_request(method, spath, body)
  if cfg.server_url == "" or cfg.api_key == "" then
    dwarn("emby not configured yet")
    return nil
  end

  local url = build_emby_url(spath)
  local host, port, req_path = parse_url(url)
  if not host then
    derr("invalid emby server URL: %s", cfg.server_url)
    return nil
  end

  port = tonumber(port) or 8096

  local header_lines = {
    method .. " " .. req_path .. " HTTP/1.0",
    "Host: " .. host .. ":" .. port,
    "X-Emby-Token: " .. cfg.api_key,
    "X-Emby-Authorization: MediaBrowser Client=\"VLC Play Sync\", Device=\"VLC\", Version=\"" .. EXT_VERSION .. "\"",
    "Content-Type: application/json",
    "Accept: application/json",
  }
  if body then
    header_lines[#header_lines + 1] = "Content-Length: " .. #body
  end
  header_lines[#header_lines + 1] = ""
  header_lines[#header_lines + 1] = ""

  local request_str = table.concat(header_lines, "\r\n") .. (body or "")

  local fd = vlc.net.connect_tcp(host, port)
  if not fd then
    derr("failed to connect to %s:%s", host, tostring(port))
    return nil
  end

  vlc.net.send(fd, request_str)

  local pollfds = {}
  pollfds[fd] = vlc.net.POLLIN
  vlc.net.poll(pollfds)

  local raw = ""
  local chunk = vlc.net.recv(fd, 4096)
  while chunk do
    raw = raw .. chunk
    vlc.net.poll(pollfds)
    chunk = vlc.net.recv(fd, 4096)
  end
  vlc.net.close(fd)

  local header_end = raw:find("\r\n\r\n")
  local body_start
  if header_end then
    body_start = header_end + 4
  else
    header_end, body_start = raw:find("\n\n")
    if not header_end then
      return nil
    end
    body_start = body_start + 1
  end

  local header_part = raw:sub(1, header_end - 1)
  local body_part = raw:sub(body_start)

  local status_line = header_part:match("HTTP/%d%.%d (%d+)")
  local status_code = tonumber(status_line)

  if not status_code then
    return nil
  end

  -- follow redirect
  if status_code == 301 or status_code == 302 or status_code == 307 then
    local location = header_part:match("Location: ([^\r\n]+)")
    if location then
      local l_host, l_port, l_path = parse_url(location)
      if l_host then
        host, port, req_path = l_host, l_port or 8096, l_path
        cfg.server_url = "http://" .. host .. ":" .. port
        header_lines[1] = method .. " " .. req_path .. " HTTP/1.0"
        header_lines[2] = "Host: " .. host .. ":" .. port
        request_str = table.concat(header_lines, "\r\n") .. (body or "")
        if fd then vlc.net.close(fd) end
        fd = vlc.net.connect_tcp(host, port)
        if not fd then return nil end
        vlc.net.send(fd, request_str)
        pollfds, raw = {}, ""
        pollfds[fd] = vlc.net.POLLIN
        vlc.net.poll(pollfds)
        chunk = vlc.net.recv(fd, 4096)
        while chunk do
          raw = raw .. chunk
          vlc.net.poll(pollfds)
          chunk = vlc.net.recv(fd, 4096)
        end
        vlc.net.close(fd)
        header_end = raw:find("\r\n\r\n")
        if header_end then
          body_start = header_end + 4
        else
          header_end, body_start = raw:find("\n\n")
          if not header_end then return nil end
          body_start = body_start + 1
        end
        header_part = raw:sub(1, header_end - 1)
        body_part = raw:sub(body_start)
        status_line = header_part:match("HTTP/%d%.%d (%d+)")
        status_code = tonumber(status_line)
      end
    end
  end

  dmsg("emby %s %s -> %d (%d bytes)", method, spath, status_code or 0, #body_part)
  return status_code, body_part
end

-- Emby API helpers

local function emby_find_item(filepath)
  if cfg.user_id == "" then
    dwarn("no user_id configured, cannot search for items")
    return nil
  end

  -- try exact path match
  local encoded = url_encode(filepath)
  local spath = "/emby/Users/" .. cfg.user_id .. "/Items?Recursive=true&Filters=IsNotFolder&Path=" .. encoded
  local code, resp = emby_request("GET", spath, nil)
  if code and code >= 200 and code < 300 and resp then
    local ok, data = pcall(json_decode, resp)
    if ok and data and data.Items and #data.Items > 0 then
      dmsg("matched item by path: %s (%s)", data.Items[1].Name, data.Items[1].Id)
      return data.Items[1]
    end
  end

  -- fallback: filename search
  local filename = filepath:match("[^/\\]+$")
  if filename then
    local encoded_name = url_encode(filename)
    spath = "/emby/Users/" .. cfg.user_id .. "/Items?Recursive=true&Filters=IsNotFolder&SearchTerm=" .. encoded_name
    code, resp = emby_request("GET", spath, nil)
    if code and code >= 200 and code < 300 and resp then
      local ok, data = pcall(json_decode, resp)
      if ok and data and data.Items and #data.Items > 0 then
        dmsg("matched item by filename: %s (%s)", data.Items[1].Name, data.Items[1].Id)
        return data.Items[1]
      end
    end
  end

  dwarn("no emby item found for: %s", filepath)
  return nil
end

local function generate_session_id()
  local t = tostring(vlc.misc.mdate() or os.time() * 1000000)
  return "vlc-" .. t .. "-" .. tostring(math.random(10000, 99999))
end

local function get_position_ticks()
  local time_ms = 0
  if vlc.player and vlc.player.time then
    time_ms = vlc.player.time()
  elseif vlc.input and vlc.input.time then
    time_ms = vlc.input.time()
  end
  return math.floor(time_ms * 10000)
end

local function get_current_uri()
  local item = nil
  if vlc.player and vlc.player.item then
    item = vlc.player.item()
  elseif vlc.input and vlc.input.item then
    item = vlc.input.item()
  end
  if item then
    return item:uri()
  end
  return nil
end

local function get_playback_status()
  if vlc.playlist and vlc.playlist.status then
    return vlc.playlist.status() or ""
  elseif vlc.player and vlc.player.is_playing then
    return vlc.player.is_playing() and "playing" or "paused"
  end
  return ""
end

local function is_playing()
  local st = get_playback_status()
  return st == "playing"
end

local function get_local_path(uri)
  if not uri then return nil end
  -- only try to match local files
  if uri:sub(1, 7) ~= "file://" then
    return nil
  end
  local path = vlc.strings.make_path(uri)
  if path and path ~= "" then
    return path
  end
  return vlc.strings.decode_uri(uri:match("^file://(.+)$") or uri)
end

-- Emby session lifecycle

local function emby_play_start(item)
  if not item then return end
  local ticks = get_position_ticks()
  if not state.play_session_id then
    state.play_session_id = generate_session_id()
  end
  local payload = {
    ItemId = item.Id,
    MediaSourceId = item.Id,
    PositionTicks = ticks,
    CanSeek = true,
    IsPaused = false,
    IsMuted = false,
    PlayMethod = "DirectPlay",
    PlaySessionId = state.play_session_id
  }
  local code, _ = emby_request("POST", "/emby/Sessions/Playing", json_encode(payload))
  if code and code >= 200 and code < 300 then
    state.playing = true
    state.last_sync = os.time()
    dmsg("playback started: %s (%d ticks)", item.Name, ticks)
  else
    dwarn("play start failed: %s", tostring(code))
  end
end

local function emby_play_progress(event_name)
  if not state.item_id then
    dwarn("no item matched, skipping progress")
    return
  end
  local ticks = get_position_ticks()
  local payload = {
    ItemId = state.item_id,
    MediaSourceId = state.media_source_id or state.item_id,
    PositionTicks = ticks,
    CanSeek = true,
    IsPaused = not state.playing,
    IsMuted = false,
    PlayMethod = "DirectPlay",
    PlaySessionId = state.play_session_id,
    EventName = event_name
  }
  local code, _ = emby_request("POST", "/emby/Sessions/Playing/Progress", json_encode(payload))
  if code and code >= 200 and code < 300 then
    state.last_sync = os.time()
    dmsg("progress: %s -> %d ticks", event_name, ticks)
  else
    dwarn("progress failed: %s", tostring(code))
  end
end

local function emby_play_stop()
  if not state.item_id then return end
  local ticks = get_position_ticks()
  local payload = {
    ItemId = state.item_id,
    MediaSourceId = state.media_source_id or state.item_id,
    PositionTicks = ticks,
    PlaySessionId = state.play_session_id
  }
  local code, _ = emby_request("POST", "/emby/Sessions/Playing/Stopped", json_encode(payload))
  if code and code >= 200 and code < 300 then
    dmsg("playback stopped at %d ticks", ticks)
  else
    dwarn("stop failed: %s", tostring(code))
  end
  state.playing = false
  state.play_session_id = nil
end

local function match_and_cache()
  local uri = get_current_uri()
  if not uri or uri == "" then
    state.item_matched = false
    return false
  end

  if uri:sub(1, 7) ~= "file://" then
    dmsg("not a local file, skipping emby match: %s", uri)
    state.item_matched = false
    return false
  end

  local path = get_local_path(uri)
  if not path then
    dwarn("could not get local path from URI: %s", uri)
    state.item_matched = false
    return false
  end

  dmsg("attempting to match: %s", path)
  local item = emby_find_item(path)
  if item then
    state.item_id = item.Id
    state.media_source_id = item.Id
    state.item_matched = true
    return true
  end

  state.item_matched = false
  state.item_id = nil
  state.media_source_id = nil
  return false
end

local function clear_state()
  state.item_id = nil
  state.media_source_id = nil
  state.play_session_id = nil
  state.item_matched = false
  state.playing = false
  state.last_sync = 0
  state.last_status = ""
end

-- Extension lifecycle

function descriptor()
  return {
    title = EXT_TITLE,
    version = EXT_VERSION,
    author = "jason",
    shortdesc = "Sync VLC playback position to Emby",
    description = "Automatically syncs current playback position to Emby server as a resume point.",
    capabilities = { "menu", "input-listener", "playing-listener" }
  }
end

function activate()
  dmsg("activating extension v%s", EXT_VERSION)
  math.randomseed(os.time())
  load_config()
  if cfg.server_url ~= "" then
    dmsg("configured for: %s", cfg.server_url)
  else
    dwarn("no configuration found — use Configure menu to set up Emby server")
  end

  local uri = get_current_uri()
  if uri then
    match_and_cache()
    if is_playing() and state.item_matched then
      emby_play_start({ Id = state.item_id, Name = uri:match("[^/\\]+$") or uri })
    end
  end
end

function deactivate()
  dmsg("deactivating")
  if state.playing then
    emby_play_stop()
  end
  clear_state()
end

function close()
  dmsg("VLC closing")
  if state.playing and state.item_matched then
    emby_play_stop()
  end
  clear_state()
end

function input_changed()
  local uri = get_current_uri()
  if not uri then
    if state.playing then
      emby_play_stop()
    end
    clear_state()
    return
  end

  clear_state()
  match_and_cache()

  if is_playing() and state.item_matched then
    emby_play_start({ Id = state.item_id, Name = uri:match("[^/\\]+$") or uri })
  end
end

function playing_changed()
  local st = get_playback_status()
  dmsg("status changed: %s -> %s", state.last_status, st)

  if st == "playing" then
    if state.last_status == "paused" and state.item_matched then
      emby_play_progress("Unpause")
    elseif not state.playing and state.item_matched then
      emby_play_start({ Id = state.item_id, Name = (get_current_uri() or ""):match("[^/\\]+$") or "unknown" })
    end
    state.playing = true

  elseif st == "paused" then
    if state.playing and state.item_matched then
      emby_play_progress("Pause")
    end
    state.playing = false

  elseif st == "stopped" or st == "" then
    if state.playing and state.item_matched then
      emby_play_stop()
    end
    state.playing = false
  end

  state.last_status = st
end

-- Menu and dialog

function menu()
  return { "Sync Now", "Configure...", "Status" }
end

function trigger_menu(id)
  if id == 1 then
    if state.item_matched and state.play_session_id then
      emby_play_progress("TimeUpdate")
      dmsg("manual sync triggered")
    else
      dwarn("manual sync skipped — no active session")
    end
  elseif id == 2 then
    show_config_dialog()
  elseif id == 3 then
    show_status()
  end
end

local dialog

local function close_dialog()
  if dialog then
    dialog:delete()
    dialog = nil
  end
end

function show_config_dialog()
  close_dialog()
  dialog = vlc.dialog(EXT_TITLE .. " — Configuration")

  dialog:add_label("Emby Server URL:", 1, 1, 1, 1)
  local url_input = dialog:add_text_input(cfg.server_url, 2, 1, 3, 1)

  dialog:add_label("API Key:", 1, 2, 1, 1)
  local key_input = dialog:add_password(cfg.api_key, 2, 2, 3, 1)

  dialog:add_label("User ID:", 1, 3, 1, 1)
  local uid_input = dialog:add_text_input(cfg.user_id, 2, 3, 3, 1)

  dialog:add_label("", 1, 4, 4, 1)
  local function save()
    cfg.server_url = url_input:get_text()
    cfg.api_key = key_input:get_text()
    cfg.user_id = uid_input:get_text()
    save_config()
    close_dialog()
    dmsg("configuration saved and applied")
  end

  local function cancel()
    close_dialog()
  end

  dialog:add_button("Save", save, 2, 5, 1, 1)
  dialog:add_button("Cancel", cancel, 3, 5, 1, 1)
  dialog:show()
end

function show_status()
  close_dialog()
  dialog = vlc.dialog(EXT_TITLE .. " — Status")

  local lines = {}
  lines[#lines + 1] = "Server: " .. (cfg.server_url ~= "" and cfg.server_url or "not configured")
  lines[#lines + 1] = "API Key: " .. (cfg.api_key ~= "" and "****" or "not set")
  lines[#lines + 1] = "User ID: " .. (cfg.user_id ~= "" and cfg.user_id or "not set")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Item matched: " .. tostring(state.item_matched)
  if state.item_id then
    lines[#lines + 1] = "Emby ItemId: " .. state.item_id
  end
  lines[#lines + 1] = "Playing: " .. tostring(state.playing)
  lines[#lines + 1] = "Last status: " .. state.last_status
  lines[#lines + 1] = "Position ticks: " .. tostring(get_position_ticks())

  for idx, line in ipairs(lines) do
    dialog:add_label(line, 1, idx, 4, 1)
  end

  local function ok()
    close_dialog()
  end
  dialog:add_button("OK", ok, 2, #lines + 1, 1, 1)
  dialog:show()
end
