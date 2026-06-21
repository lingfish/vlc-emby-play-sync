-- Emby Play Sync — VLC Lua extension
-- Syncs current playback position to Emby server as a resume point.

local EXT_TITLE = "Emby Play Sync"
local EXT_VERSION = "1.0"

local cfg = {
  server_url = "",
  api_key = "",
  user_id = "",
  local_path_prefix = "",
  emby_path_prefix = ""
}

local state = {
  item_id = nil,
  media_source_id = nil,
  item_matched = false,
  last_status = ""
}

-- [[ VLC Adapter — wraps all vlc.* calls behind a narrow seam ]]

local adapter = {}

function adapter.debug(...)
  vlc.msg.dbg("[" .. EXT_TITLE .. "] " .. string.format(...))
end

function adapter.warn(...)
  vlc.msg.warn("[" .. EXT_TITLE .. "] " .. string.format(...))
end

function adapter.error(...)
  vlc.msg.err("[" .. EXT_TITLE .. "] " .. string.format(...))
end

function adapter.config_path()
  local userdata = vlc.config.userdatadir()
  if not userdata then return nil end
  return userdata .. "/emby_play_sync.json"
end

function adapter.read_file(path)
  local f = vlc.io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*all")
  f:close()
  return data
end

function adapter.write_file(path, data)
  local f = vlc.io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

function adapter.http_request(method, url, headers, body)
  local parsed = vlc.strings.url_parse(url)
  local host = parsed["host"]
  local port = tonumber(parsed["port"] or "8096")
  local req_path = parsed["path"] or "/"
  if parsed["option"] and parsed["option"] ~= "" then
    req_path = req_path .. "?" .. parsed["option"]
  end
  if not host then return nil, "invalid URL" end

  local function send(h, p, rp)
    local lines = {
      method .. " " .. rp .. " HTTP/1.0",
      "Host: " .. h .. ":" .. p,
    }
    for _, hdr in ipairs(headers or {}) do
      lines[#lines + 1] = hdr
    end
    if body then
      lines[#lines + 1] = "Content-Length: " .. #body
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""

    local req = table.concat(lines, "\r\n") .. (body or "")
    local fd = vlc.net.connect_tcp(h, p)
    if not fd then return nil end
    vlc.net.send(fd, req)
    local pfds = { [fd] = vlc.net.POLLIN }
    vlc.net.poll(pfds)
    local raw = ""
    local chunk = vlc.net.recv(fd, 4096)
    while chunk do
      raw = raw .. chunk
      vlc.net.poll(pfds)
      chunk = vlc.net.recv(fd, 4096)
    end
    vlc.net.close(fd)
    return raw
  end

  local raw = send(host, port, req_path)
  if not raw then return nil, "connection failed" end

  local crlf = raw:find("\r\n\r\n")
  local hdr_end, body_start
  if crlf then
    hdr_end, body_start = crlf, crlf + 4
  else
    local lf = raw:find("\n\n")
    if not lf then return nil, "malformed response" end
    hdr_end, body_start = lf, lf + 2
  end

  local hdr_part = raw:sub(1, hdr_end - 1)
  local body_part = raw:sub(body_start)
  local status_line = hdr_part:match("HTTP/%d%.%d (%d+)")
  local status_code = tonumber(status_line)
  if not status_code then return nil, "no status line" end

  if status_code == 301 or status_code == 302 or status_code == 307 then
    local location = hdr_part:match("Location: ([^\r\n]+)")
    if location then
      local lp = vlc.strings.url_parse(location)
      local lh = lp["host"]
      local lport = tonumber(lp["port"] or "8096")
      local lrp = lp["path"] or "/"
      if lp["option"] and lp["option"] ~= "" then
        lrp = lrp .. "?" .. lp["option"]
      end
      if lh then
        raw = send(lh, lport, lrp)
        if not raw then return nil, "redirect failed" end
        crlf = raw:find("\r\n\r\n")
        if crlf then
          hdr_end, body_start = crlf, crlf + 4
        else
          local lf2 = raw:find("\n\n")
          if not lf2 then return nil, "redirect malformed" end
          hdr_end, body_start = lf2, lf2 + 2
        end
        hdr_part = raw:sub(1, hdr_end - 1)
        body_part = raw:sub(body_start)
        status_line = hdr_part:match("HTTP/%d%.%d (%d+)")
        status_code = tonumber(status_line)
      end
    end
  end

  return status_code, body_part, hdr_part
end

function adapter.get_current_uri()
  if vlc.input and vlc.input.item then
    local item = vlc.input.item()
    if item then return item:uri() end
  end
  return nil
end

function adapter.get_position_ticks()
  if vlc.object and vlc.object.input then
    local input_obj = vlc.object.input()
    if input_obj then
      local time_us = vlc.var.get(input_obj, "time")
      if time_us and time_us > 0 then
        return math.floor(time_us * 10)
      end
    end
  end
  return 0
end

function adapter.get_playback_status()
  if vlc.playlist and vlc.playlist.status then
    local st = vlc.playlist.status()
    if st and st ~= "" then return st end
  end
  if vlc.object and vlc.object.input then
    local input_obj = vlc.object.input()
    if input_obj then
      local st = vlc.var.get(input_obj, "state")
      if st == 3 then return "playing"
      elseif st == 4 then return "paused" end
    end
  end
  return ""
end

function adapter.get_local_path(uri)
  if not uri then return nil end
  if uri:sub(1, 7) ~= "file://" then return nil end
  local path = vlc.strings.make_path(uri)
  if path and path ~= "" then return path end
  return vlc.strings.decode_uri(uri:match("^file://(.+)$") or uri)
end

function adapter.osd_message(msg)
  pcall(vlc.osd.message, msg)
end

function adapter.show_config_dialog(current, on_save)
  local d = vlc.dialog(EXT_TITLE .. " — Configuration")
  d:add_label("Emby Server URL:", 1, 1, 1, 1)
  local url_input = d:add_text_input(current.server_url, 2, 1, 3, 1)
  d:add_label("API Key:", 1, 2, 1, 1)
  local key_input = d:add_password(current.api_key, 2, 2, 3, 1)
  d:add_label("User ID (name or UUID):", 1, 3, 1, 1)
  local uid_input = d:add_text_input(current.user_id, 2, 3, 3, 1)
  d:add_label("Local path prefix:", 1, 4, 1, 1)
  local local_pref = d:add_text_input(current.local_path_prefix, 2, 4, 3, 1)
  d:add_label("Emby path prefix:", 1, 5, 1, 1)
  local emby_pref = d:add_text_input(current.emby_path_prefix, 2, 5, 3, 1)
  d:add_label("", 1, 6, 4, 1)
  local function save()
    on_save({
      server_url = url_input:get_text(),
      api_key = key_input:get_text(),
      user_id = uid_input:get_text(),
      local_path_prefix = local_pref:get_text(),
      emby_path_prefix = emby_pref:get_text()
    })
    d:delete()
  end
  local function cancel() d:delete() end
  d:add_button("Save", save, 2, 7, 1, 1)
  d:add_button("Cancel", cancel, 3, 7, 1, 1)
  d:show()
end

function adapter.show_status_dialog(lines)
  local d = vlc.dialog(EXT_TITLE .. " — Status")
  for idx, line in ipairs(lines) do
    d:add_label(line, 1, idx, 4, 1)
  end
  local function ok() d:delete() end
  d:add_button("OK", ok, 2, #lines + 1, 1, 1)
  d:show()
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

-- Emby Client — Emby REST API calls behind a focused interface

local emby = {}

local function emby_build_url(path)
  local base = cfg.server_url:gsub("/+$", "")
  return base .. path
end

local function emby_request(method, spath, body)
  if cfg.server_url == "" or cfg.api_key == "" then
    adapter.warn("emby not configured yet")
    return nil
  end
  local url = emby_build_url(spath)
  local headers = {
    "X-Emby-Token: " .. cfg.api_key,
    "X-Emby-Authorization: MediaBrowser Client=\"VLC Play Sync\", Device=\"VLC\", Version=\"" .. EXT_VERSION .. "\"",
    "Content-Type: application/json",
    "Accept: application/json",
  }
  local code, resp = adapter.http_request(method, url, headers, body)
  if not code then
    adapter.error("emby request failed: %s", tostring(resp))
    return nil
  end
  if code >= 400 then
    adapter.error("emby error %s %s -> %d: %s", method, spath, code, tostring(resp))
  end
  adapter.debug("emby %s %s -> %d (%d bytes)", method, spath, code, #(resp or ""))
  return code, resp
end

function emby.find_item_by_path(search_path)
  local spath = "/emby/Items?UserId=" .. url_encode(cfg.user_id) .. "&Recursive=true&Path=" .. url_encode(search_path)
  local code, resp = emby_request("GET", spath, nil)
  if code and code >= 200 and code < 300 and resp then
    local ok, data = pcall(json_decode, resp)
    if ok and data and data.Items and #data.Items > 0 then
      return data.Items[1]
    end
  end
  return nil
end

function emby.search_hints(term)
  local spath = "/emby/Search/Hints?UserId=" .. url_encode(cfg.user_id) .. "&SearchTerm=" .. url_encode(term) .. "&Limit=5&IncludeMedia=true"
  local code, resp = emby_request("GET", spath, nil)
  if code and code >= 200 and code < 300 and resp then
    local ok, data = pcall(json_decode, resp)
    if ok and data and data.SearchHints and #data.SearchHints > 0 then
      return data.SearchHints
    end
  end
  return nil
end

function emby.save_position(item_id, ticks)
  local payload = json_encode({
    PlaybackPositionTicks = ticks,
    Played = false
  })
  local spath = "/emby/Users/" .. url_encode(cfg.user_id) .. "/Items/" .. url_encode(item_id) .. "/UserData"
  local code = emby_request("POST", spath, payload)
  return code and code >= 200 and code < 300
end

function emby.start_session(item_id, position, session_id)
  local payload = json_encode({
    ItemId = item_id,
    MediaSourceId = item_id,
    PositionTicks = position,
    CanSeek = true,
    IsPaused = false,
    IsMuted = false,
    PlayMethod = "DirectPlay",
    PlaySessionId = session_id
  })
  local spath = "/emby/Sessions/Playing?userId=" .. url_encode(cfg.user_id)
  local code = emby_request("POST", spath, payload)
  return code and code >= 200 and code < 300
end

function emby.report_progress(item_id, media_source_id, position, session_id, event_name)
  local payload = json_encode({
    ItemId = item_id,
    MediaSourceId = media_source_id,
    PositionTicks = position,
    CanSeek = true,
    IsPaused = event_name == "Pause",
    IsMuted = false,
    PlayMethod = "DirectPlay",
    PlaySessionId = session_id,
    EventName = event_name
  })
  local spath = "/emby/Sessions/Playing/Progress?userId=" .. url_encode(cfg.user_id)
  local code = emby_request("POST", spath, payload)
  return code and code >= 200 and code < 300
end

function emby.end_session(item_id, media_source_id, position, session_id)
  local payload = json_encode({
    ItemId = item_id,
    MediaSourceId = media_source_id,
    PositionTicks = position,
    PlaySessionId = session_id,
    Failed = false
  })
  local spath = "/emby/Sessions/Playing/Stopped?userId=" .. url_encode(cfg.user_id)
  local code = emby_request("POST", spath, payload)
  return code and code >= 200 and code < 300
end

function emby.list_users()
  local code, resp = emby_request("GET", "/emby/Users", nil)
  if code and code >= 200 and code < 300 and resp then
    local ok, users = pcall(json_decode, resp)
    if ok and type(users) == "table" then
      return users
    end
  end
  return nil
end

-- Media Matcher — matches file paths to Emby items

local matcher = {}

function matcher.translate_path(filepath)
  if cfg.local_path_prefix ~= "" and cfg.emby_path_prefix ~= "" then
    local start = filepath:find(cfg.local_path_prefix, 1, true)
    if start == 1 then
      local suffix = filepath:sub(#cfg.local_path_prefix + 1)
      local translated = cfg.emby_path_prefix .. suffix
      adapter.debug("translated path: %s -> %s", filepath, translated)
      return translated
    end
  end
  return filepath
end

function matcher.alternate_names(filename)
  local names = { filename }
  local no_ext = filename:gsub("%.[^%.]+$", "")
  if no_ext ~= filename then names[#names + 1] = no_ext end
  local clean = no_ext:gsub("[%s_%.]*[Ss]%d+[Ee]%d+", ""):gsub("^[%s%-_%.]+", ""):gsub("[%s%-_%.]+$", "")
  if clean ~= no_ext and clean ~= "" then names[#names + 1] = clean end
  return names
end

function matcher.match(filepath)
  if cfg.user_id == "" then return nil end

  local item = emby.find_item_by_path(matcher.translate_path(filepath))
  if item then return item end

  local filename = filepath:match("[^/\\]+$")
  if filename then
    for _, name in ipairs(matcher.alternate_names(filename)) do
      local hints = emby.search_hints(name)
      if hints and #hints > 0 then
        return { Id = hints[1].ItemId, Name = hints[1].Name }
      end
    end
  end

  return nil
end

-- Playback Session — manages Emby session lifecycle

local playback = {}

local play_session_id = nil
local play_active = false
local play_item_id = nil
local play_media_source_id = nil

function playback.start(item_id, item_name)
  if not item_id then return false end
  play_item_id = item_id
  play_media_source_id = item_id
  local position = adapter.get_position_ticks()
  if not play_session_id then
    play_session_id = math.floor(os.time() * 1000000)
    play_session_id = string.format("vlc-%d-%d", play_session_id, math.random(10000, 99999))
  end
  if emby.start_session(item_id, position, play_session_id) then
    play_active = true
    adapter.debug("playback started: %s (%d ticks)", item_name, position)
    return true
  end
  adapter.warn("play start failed")
  return false
end

function playback.progress(event_name)
  if not play_item_id then
    adapter.warn("no item, skipping progress")
    return
  end
  local position = adapter.get_position_ticks()
  if emby.report_progress(play_item_id, play_media_source_id, position, play_session_id, event_name) then
    adapter.debug("progress: %s -> %d ticks", event_name, position)
    if event_name == "Pause" or event_name == "TimeUpdate" then
      playback.save_position()
    end
  else
    adapter.warn("progress failed: %s", event_name)
  end
end

function playback.stop()
  if not play_item_id then return end
  local position = adapter.get_position_ticks()
  if emby.end_session(play_item_id, play_media_source_id, position, play_session_id) then
    adapter.debug("playback stopped at %d ticks", position)
    playback.save_position()
  else
    adapter.warn("stop failed")
  end
  play_active = false
  play_session_id = nil
  play_item_id = nil
  play_media_source_id = nil
end

function playback.save_position()
  if not play_item_id then return end
  local position = adapter.get_position_ticks()
  if emby.save_position(play_item_id, position) then
    adapter.debug("position saved: %d ticks", position)
  else
    adapter.warn("position save failed")
  end
end

function playback.is_active()
  return play_active
end

function playback.clear()
  play_active = false
  play_session_id = nil
  play_item_id = nil
  play_media_source_id = nil
end

-- Config persistence

local function load_config()
  local path = adapter.config_path()
  if not path then
    adapter.debug("no user data dir, cannot load config")
    return
  end
  local data = adapter.read_file(path)
  if data == nil then
    adapter.debug("no config file at %s", path)
    return
  end
  if data == "" then
    adapter.debug("empty config file, using defaults")
    return
  end
  local ok, parsed = pcall(json_decode, data)
  if ok and parsed then
    cfg.server_url = parsed.server_url or ""
    cfg.api_key = parsed.api_key or ""
    cfg.user_id = parsed.user_id or ""
    cfg.local_path_prefix = parsed.local_path_prefix or ""
    cfg.emby_path_prefix = parsed.emby_path_prefix or ""
    adapter.debug("config loaded from %s", path)
  else
    adapter.debug("invalid config file, using defaults")
  end
end

local function save_config()
  local path = adapter.config_path()
  if not path then
    adapter.error("no user data dir, cannot save config")
    return
  end
  local ok, encoded = pcall(json_encode, cfg)
  if not ok then
    adapter.error("failed to encode config")
    return
  end
  if not adapter.write_file(path, encoded) then
    adapter.error("cannot write config to %s", path)
    return
  end
  adapter.debug("config saved to %s", path)
end



-- Item matching

local function match_and_cache()
  local uri = adapter.get_current_uri()
  if not uri or uri == "" then
    state.item_matched = false
    return false
  end

  if uri:sub(1, 7) ~= "file://" then
    adapter.debug("not a local file, skipping emby match: %s", uri)
    state.item_matched = false
    return false
  end

  local path = adapter.get_local_path(uri)
  if not path then
    adapter.warn("could not get local path from URI: %s", uri)
    state.item_matched = false
    return false
  end

  adapter.debug("attempting to match: %s", path)
  local item = matcher.match(path)
  if item then
    adapter.debug("matched item: %s (%s)", item.Name, item.Id)
    adapter.osd_message("Emby: matched " .. item.Name)
    state.item_id = item.Id
    state.media_source_id = item.Id
    state.item_matched = true
    return true
  end

  adapter.warn("no emby item found for: %s", path)
  adapter.osd_message("Emby: no match for this file")
  state.item_matched = false
  state.item_id = nil
  state.media_source_id = nil
  return false
end

local function clear_state()
  state.item_id = nil
  state.media_source_id = nil
  state.item_matched = false
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

local function resolve_user_id()
  if cfg.user_id == "" then return end
  if cfg.user_id:match("^[%x%-]+$") and (#cfg.user_id == 32 or #cfg.user_id == 36) then
    return
  end
  adapter.debug("resolving username '%s' to UUID via /Users", cfg.user_id)
  local users = emby.list_users()
  if users then
    for _, user in ipairs(users) do
      if user.Name == cfg.user_id then
        cfg.user_id = user.Id
        save_config()
        adapter.debug("resolved user '%s' to UUID: %s", user.Name, user.Id)
        return
      end
    end
    adapter.warn("no user found with name '%s'", cfg.user_id)
  else
    adapter.warn("failed to fetch users, cannot resolve username")
  end
end

function activate()
  adapter.debug("activating extension v%s", EXT_VERSION)
  math.randomseed(os.time())
  load_config()

  if cfg.server_url ~= "" then
    adapter.debug("configured for: %s", cfg.server_url)
    resolve_user_id()
  else
    adapter.warn("no configuration found — use Configure menu to set up Emby server")
  end

  if adapter.get_current_uri() then
    match_and_cache()
  end
end

function deactivate()
  adapter.debug("deactivating")
  if playback.is_active() then playback.stop() end
  playback.clear()
  clear_state()
end

function close()
  adapter.debug("VLC closing")
  if playback.is_active() and state.item_matched then playback.stop() end
  playback.clear()
  clear_state()
end

function input_changed()
  local uri = adapter.get_current_uri()
  if not uri then
    if playback.is_active() then playback.stop() end
    playback.clear()
    clear_state()
    return
  end

  playback.clear()
  clear_state()
  match_and_cache()
end

function meta_changed() end

function playing_changed()
  local st = adapter.get_playback_status()
  adapter.debug("status changed: %s -> %s", state.last_status, st)

  if st == "playing" then
    if state.last_status == "paused" and state.item_matched then
      playback.progress("Unpause")
    elseif not playback.is_active() and state.item_matched then
      playback.start(state.item_id, (adapter.get_current_uri() or ""):match("[^/\\]+$") or "unknown")
    end

  elseif st == "paused" then
    if playback.is_active() then
      playback.progress("Pause")
    end

  elseif st == "stopped" or st == "" then
    if playback.is_active() then
      playback.stop()
    end
  end

  state.last_status = st
end

-- Menu and dialog

function menu()
  return { "Sync Now", "Configure...", "Status" }
end

function trigger_menu(id)
  if id == 1 then
    if state.item_matched and playback.is_active() then
      playback.progress("TimeUpdate")
      adapter.debug("manual sync triggered")
    else
      adapter.warn("manual sync skipped — no active session")
    end
  elseif id == 2 then
    adapter.show_config_dialog(cfg, function(new_cfg)
      cfg.server_url = new_cfg.server_url
      cfg.api_key = new_cfg.api_key
      cfg.user_id = new_cfg.user_id
      cfg.local_path_prefix = new_cfg.local_path_prefix
      cfg.emby_path_prefix = new_cfg.emby_path_prefix
      save_config()
      resolve_user_id()
      adapter.debug("configuration saved and applied")
    end)
  elseif id == 3 then
    local lines = {}
    lines[#lines + 1] = "Server: " .. (cfg.server_url ~= "" and cfg.server_url or "not configured")
    lines[#lines + 1] = "API Key: " .. (cfg.api_key ~= "" and "****" or "not set")
    lines[#lines + 1] = "User ID: " .. (cfg.user_id ~= "" and cfg.user_id or "not set")
    if cfg.local_path_prefix ~= "" then
      lines[#lines + 1] = "Local prefix: " .. cfg.local_path_prefix
      lines[#lines + 1] = "Emby prefix: " .. cfg.emby_path_prefix
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Item matched: " .. tostring(state.item_matched)
    if state.item_id then
      lines[#lines + 1] = "Emby ItemId: " .. state.item_id
    end
    lines[#lines + 1] = "Playing: " .. tostring(playback.is_active())
    lines[#lines + 1] = "Last status: " .. state.last_status
    lines[#lines + 1] = "Position ticks: " .. tostring(adapter.get_position_ticks())
    adapter.show_status_dialog(lines)
  end
end
