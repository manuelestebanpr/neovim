-- lua/ai_assistant/engram.lua
-- Persistent project memory via engram (Gentleman-Programming/engram) over its
-- local HTTP API (default 127.0.0.1:7437). This is the ONLY memory backend: the
-- plugin searches engram before each message and exposes memory_search /
-- memory_save tools to the model. Scope is PER-PROJECT (git-root basename).
--
-- CONTRACT (mirrors search.lua / api.lua execute_tool): every public entry point
-- calls its callback EXACTLY once, ALWAYS with a value, and NEVER raises. All work
-- is async (plenary.curl) with a SHORT timeout and an on_error so a down server
-- can't strand the spinner; the callback always lands on the main loop. Failures
-- degrade silently to nil/false — memory is best-effort, never load-bearing.

local M = {}
local config = require("ai_assistant.config")

----------------------------------------------------------------------
-- Coercion helpers (same vim.NIL trap as the wire layer: engram is Go and emits
-- json:null for empty fields / on an empty /search, which decodes to vim.NIL —
-- truthy, crashes on concat. Coerce every decoded field before use.)
----------------------------------------------------------------------

local function jstr(v)
  if type(v) == "string" then return v end
  return ""
end

local function decode(body)
  local ok, t = pcall(vim.json.decode, jstr(body))
  if ok and type(t) == "table" then return t end
  return nil
end

local function snippet(s, n)
  s = vim.trim(jstr(s):gsub("%s+", " "))
  n = n or 280
  if #s > n then return s:sub(1, n - 1) .. "…" end
  return s
end

local function ok_status(res)
  return type(res) == "table" and res.status and res.status >= 200 and res.status < 300
end

----------------------------------------------------------------------
-- HTTP wrapper: fire-once, never raises, callback always on the main loop.
-- (Copied from search.lua's http() so engram inherits the same no-stuck-spinner
-- discipline. NOT shared, to keep the modules decoupled.)
----------------------------------------------------------------------

local function http(method, url, req_opts, cb)
  local ok_curl, curl = pcall(require, "plenary.curl")
  if not ok_curl then
    vim.schedule(function() cb(nil, "plenary.curl missing") end)
    return
  end
  local finished = false
  local function finish(res, err)
    if finished then return end
    finished = true
    vim.schedule(function() cb(res, err) end)
  end
  local req = vim.tbl_extend("force", req_opts or {}, {
    timeout = (req_opts and req_opts.timeout) or 3000,
    on_error = function(e)
      finish(nil, (e and (e.message or e.stderr or e.exit)) and tostring(e.message or e.stderr or e.exit) or "connection failed")
    end,
    callback = function(res) finish(res, nil) end,
  })
  local ok, err = pcall(function()
    if method == "POST" then
      curl.post(url, req)
    else
      curl.get(url, req)
    end
  end)
  if not ok then
    finish(nil, tostring(err))
  end
end

-- Common headers: Content-Type + optional bearer token.
local function eheaders(settings)
  local h = { ["Content-Type"] = "application/json" }
  local tok = config.get_engram_token(settings)
  if tok ~= "" then h["Authorization"] = "Bearer " .. tok end
  return h
end

local function base(settings)
  return config.get_engram_url(settings)
end

-- Is engram turned on for this session?
function M.enabled(settings)
  settings = settings or config.load_settings()
  return settings.engram_enabled ~= false
end

----------------------------------------------------------------------
-- Health probe ("check the mcp connection"). cb(ok:boolean, version|nil)
----------------------------------------------------------------------
function M.health(cb)
  cb = cb or function() end
  local settings = config.load_settings()
  http("GET", base(settings) .. "/health", { headers = eheaders(settings), timeout = 1500 }, function(res, err)
    if err or not ok_status(res) then return cb(false, nil) end
    local d = decode(res.body) or {}
    cb(true, jstr(d.version))
  end)
end

----------------------------------------------------------------------
-- Search. cb(context_string|nil). nil => nothing usable (caller may fall back).
-- opts = { limit=6, type=nil, scope="project" }
----------------------------------------------------------------------
local function format_memories(rows, limit)
  local lines, n = {}, 0
  for _, r in ipairs(rows) do
    if type(r) == "table" then
      local title, content = jstr(r.title), jstr(r.content)
      if title ~= "" or content ~= "" then
        local typ = jstr(r.type)
        typ = (typ ~= "" and ("[" .. typ .. "] ")) or ""
        local body = snippet(content)
        local line = "- " .. typ .. (title ~= "" and ("**" .. title .. "**") or "")
        if body ~= "" then line = line .. (title ~= "" and " — " or "") .. body end
        lines[#lines + 1] = line
        n = n + 1
        if n >= (limit or 6) then break end
      end
    end
  end
  if #lines == 0 then return nil end
  return "### Project Memory (engram) — relevant to this message:\n" .. table.concat(lines, "\n")
end

function M.search(query, opts, cb)
  cb = cb or function() end
  opts = opts or {}
  if type(query) ~= "string" or vim.trim(query) == "" then return cb(nil) end
  local settings = config.load_settings()
  if not M.enabled(settings) then return cb(nil) end
  local q = {
    q = query,
    project = config.engram_project(),
    scope = opts.scope or "project",
    limit = opts.limit or 6,
  }
  if opts.type and opts.type ~= "" then q.type = opts.type end
  http("GET", base(settings) .. "/search", { headers = eheaders(settings), query = q, timeout = 1500 }, function(res, err)
    if err or not ok_status(res) then return cb(nil) end
    -- /search returns a bare JSON array of observations, or null when empty.
    local d = decode(res.body)
    local rows
    if type(d) == "table" then
      if vim.islist(d) then
        rows = d
      elseif type(d.results) == "table" then
        rows = d.results
      end
    end
    if type(rows) ~= "table" or #rows == 0 then return cb(nil) end
    local ok, block = pcall(format_memories, rows, opts.limit or 6)
    cb(ok and block or nil)
  end)
end

----------------------------------------------------------------------
-- Session management (internal). Engram requires every observation to reference
-- an EXISTING session, so we lazily create ONE session per project per editor
-- run and reuse it. If engram restarts (the cached session vanishes), a write
-- 404s and we transparently recreate + retry once.
----------------------------------------------------------------------
local ensured = {}     -- project -> session_id created this editor run
local session_seq = 0

-- cb(session_id|nil). force=true ignores the cache (used after a 404).
local function ensure_session(settings, force, cb)
  local proj = config.engram_project()
  if not force and type(ensured[proj]) == "string" then return cb(ensured[proj]) end
  session_seq = session_seq + 1
  local id = string.format("nvim-%s-%d-%d", proj, os.time(), session_seq)
  local ok_enc, encoded = pcall(vim.fn.json_encode, {
    id = id, project = proj, directory = config.get_project_root(),
  })
  if not ok_enc then return cb(nil) end
  http("POST", base(settings) .. "/sessions", { headers = eheaders(settings), body = encoded, timeout = 3000 }, function(res, err)
    if err or not ok_status(res) then return cb(nil) end
    ensured[proj] = id
    cb(id)
  end)
end

local function post_observation(settings, sid, obs, cb)
  local body = {
    session_id = sid,
    type = (type(obs.type) == "string" and obs.type ~= "") and obs.type or "learning",
    title = obs.title,
    content = type(obs.content) == "string" and obs.content or "",
    project = config.engram_project(),
    scope = "project",
  }
  if type(obs.tool_name) == "string" and obs.tool_name ~= "" then body.tool_name = obs.tool_name end
  if type(obs.topic_key) == "string" and obs.topic_key ~= "" then body.topic_key = obs.topic_key end
  local ok_enc, encoded = pcall(vim.fn.json_encode, body)
  if not ok_enc then return cb(false, "encode failed", nil) end
  http("POST", base(settings) .. "/observations", { headers = eheaders(settings), body = encoded, timeout = 3000 }, function(res, err)
    if err or type(res) ~= "table" or not res.status then
      return cb(false, err or "no response", nil)
    end
    if res.status == 404 then return cb(false, "session not found", 404) end
    if not ok_status(res) then return cb(false, "HTTP " .. tostring(res.status), res.status) end
    local d = decode(res.body) or {}
    cb(true, d.id, res.status)
  end)
end

----------------------------------------------------------------------
-- Save one durable observation. obs = { type, title, content, tool_name?,
-- topic_key? }. project/scope/session_id are filled in. cb(ok:boolean, id_or_err)
----------------------------------------------------------------------
function M.observe(obs, cb)
  cb = cb or function() end
  obs = obs or {}
  local settings = config.load_settings()
  if not M.enabled(settings) then return cb(false, "engram disabled") end
  if type(obs.title) ~= "string" or vim.trim(obs.title) == "" then
    return cb(false, "missing title")
  end
  ensure_session(settings, false, function(sid)
    if not sid then return cb(false, "engram unreachable") end
    post_observation(settings, sid, obs, function(ok, idOrErr, status)
      if ok then return cb(true, idOrErr) end
      if status == 404 then
        ensure_session(settings, true, function(sid2)
          if not sid2 then return cb(false, "engram unreachable") end
          post_observation(settings, sid2, obs, function(ok2, idOrErr2) cb(ok2, idOrErr2) end)
        end)
      else
        cb(false, idOrErr)
      end
    end)
  end)
end

return M
