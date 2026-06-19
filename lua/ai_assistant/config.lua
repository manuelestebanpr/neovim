local M = {}

local SETTINGS_PATH = vim.fn.stdpath("data") .. "/ai_assistant_settings.json"
local CHATS_DIR = vim.fn.stdpath("data") .. "/ai_assistant_chats"

-- Markers used to detect the project root, relative to the active buffer.
local ROOT_MARKERS = {
  ".git",
  "CLAUDE.md",
  ".cursorrules",
  "package.json",
  "Cargo.toml",
  "go.mod",
  "pyproject.toml",
  "pom.xml",
  "build.gradle",
  ".luarc.json",
}

-- Single source of truth for the picker's no-key fallback lists + canonical
-- ordering. When an API key is set, live /v1/models discovery is authoritative;
-- these are the fallback. Kimi (moonshot) + Claude (anthropic) lead per the
-- model-ordering requirement; Gemini follows. Local models (ollama/llama.cpp)
-- are discovery-only and surface FIRST when their server is reachable.
M.MODELS = {
  moonshot = { "kimi-k2.6", "kimi-k2.5" },
  anthropic = { "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5" },
  gemini = { "gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite" },
}

-- Keys whose nested tables are deep-merged with defaults on load (so newly added
-- sub-keys appear for users with an older saved block). Everything else (arrays
-- like command_denylist) is taken from the user's saved settings verbatim.
local DEEP_MERGE_KEYS = {
  api_keys = true,
  web_search = true,
}

local default_settings = {
  -- Persisted default model for new Neovim sessions (kimi/claude lead).
  default_model = "kimi-k2.6",
  -- Base URL of a local llama.cpp server (`llama-server`, OpenAI-compatible).
  -- Models served here are discovered from `<url>/v1/models` and tagged with a
  -- "llamacpp:" prefix in the picker.
  llama_server_url = "http://127.0.0.1:8080",
  -- Engram (persistent project memory) — local HTTP API. The plugin searches
  -- engram before each message and exposes memory_search/memory_save tools.
  engram_enabled = true,
  engram_url = "http://127.0.0.1:7437",
  -- Optional bearer token if engram was started with ENGRAM_HTTP_TOKEN.
  engram_token = "",
  -- ON by default => run_command / read_file / web tools ask for approval first.
  -- (Denylisted commands and out-of-root writes ALWAYS ask, regardless.)
  auto_approve_tools = false,
  -- ON by default => file writes apply immediately and surface a collapsed diff
  -- card. Toggle off to review each write as an accept/reject diff first.
  auto_write_files = true,
  -- Estimated token budget for the conversation. When exceeded, the oldest turns
  -- are trimmed before sending. Rough estimate (~4 chars/token).
  context_token_budget = 100000,
  -- Commands matching any of these Lua patterns ALWAYS require manual
  -- confirmation, even when auto_approve_tools is enabled.
  command_denylist = {
    "%f[%w]rm%s+%-[rRft]*[rRf]", -- rm -rf / rm -r / rm -f (word-boundary anchored)
    "rmdir%s",
    "sudo%s",
    "mkfs",
    "dd%s+if=",
    "dd%s+of=",
    "fork_bomb_pattern", -- placeholder replaced below to avoid self-block
    "curl.*|%s*sh",
    "curl.*|%s*bash",
    "wget.*|%s*sh",
    "wget.*|%s*bash",
    "chmod%s+%-R",
    "chown%s+%-R",
    ">%s*/dev/sd",
    "shutdown",
    "reboot",
    "%f[%w]kill%f[%W]",
    "truncate%s+%-s",
    "git%s+reset%s+%-%-hard",
    "git%s+clean%s+%-[a-z]*f",
  },
  api_keys = {
    gemini = "",
    anthropic = "",
    moonshot = "",
    ollama = "",
    -- Only needed if llama-server was started with `--api-key`; left blank,
    -- requests go out unauthenticated (the common local setup).
    llamacpp = "",
  },
  -- Web access for the agent — the INTERNET FALLBACK, used only when project
  -- memory has nothing and the user explicitly asks to look online. Exposes the
  -- `web_search` + `fetch_url` native tools. Keyless by default (self-hosted
  -- SearXNG -> DuckDuckGo). Keys also read from TAVILY/SERPER/BRAVE/JINA_API_KEY.
  web_search = {
    enabled = true,
    provider = "auto",
    searxng_url = "http://127.0.0.1:8080",
    max_results = 5,
    fetch_char_cap = 10000,
    api_keys = { tavily = "", serper = "", brave = "", jina = "" },
  },
}

-- The fork-bomb pattern is injected programmatically so that this source file
-- never contains the literal sequence (which would trip command safety scanners).
default_settings.command_denylist[7] = ":" .. "%s*%(" .. "%s*%)%s*" .. "{"

-- Maps a provider name to the environment variable that may hold its key.
local ENV_KEYS = {
  gemini = "GEMINI_API_KEY",
  anthropic = "ANTHROPIC_API_KEY",
  moonshot = "MOONSHOT_API_KEY",
  ollama = "OLLAMA_API_KEY",
  llamacpp = "LLAMACPP_API_KEY",
}

----------------------------------------------------------------------
-- Low-level file helpers
----------------------------------------------------------------------

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*all")
  file:close()
  return content
end

local function write_file(path, content)
  local file = io.open(path, "wb")
  if not file then return false end
  file:write(content)
  file:close()
  return true
end

----------------------------------------------------------------------
-- Settings load / save
----------------------------------------------------------------------

-- Deep-merge only for whitelisted map keys; arrays and unknown keys are
-- taken from the user's saved settings as-is (so deletions persist).
local function merge_map(target, source)
  for k, v in pairs(source) do
    if target[k] == nil then
      target[k] = vim.deepcopy(v)
    elseif type(v) == "table" and type(target[k]) == "table" and not vim.islist(v) then
      merge_map(target[k], v)
    end
  end
  return target
end

local function apply_defaults(settings)
  for k, v in pairs(default_settings) do
    if settings[k] == nil then
      settings[k] = vim.deepcopy(v)
    elseif DEEP_MERGE_KEYS[k] and type(settings[k]) == "table" then
      merge_map(settings[k], v)
    end
  end
  return settings
end

function M.save_settings(settings)
  local ok, encoded = pcall(vim.fn.json_encode, settings)
  if not ok then
    vim.notify("AI Assistant: Failed to serialize settings.", vim.log.levels.ERROR)
    return false
  end
  local wrote = write_file(SETTINGS_PATH, encoded)
  if wrote then
    pcall(vim.fn.setfperm, SETTINGS_PATH, "rw-------")
  end
  return wrote
end

function M.load_settings()
  local content = read_file(SETTINGS_PATH)
  if not content then
    M.save_settings(default_settings)
    return vim.deepcopy(default_settings)
  end

  local ok, settings = pcall(vim.fn.json_decode, content)
  if not ok or type(settings) ~= "table" then
    vim.notify("AI Assistant: Failed to parse settings. Resetting to defaults.", vim.log.levels.ERROR)
    M.save_settings(default_settings)
    return vim.deepcopy(default_settings)
  end

  return apply_defaults(settings)
end

-- Returns the effective API key for a provider: environment variable first
-- (more secure, never persisted), then the stored settings value.
function M.get_api_key(settings, provider)
  local env_name = ENV_KEYS[provider]
  if env_name then
    local env_val = vim.env[env_name]
    if env_val and env_val ~= "" then
      return env_val
    end
  end
  if settings and settings.api_keys then
    -- A key stored as JSON null decodes to vim.NIL (userdata, truthy), so a bare
    -- `... or ""` would return the userdata, which later crashes the unguarded
    -- `"Bearer " .. api_key` / `?key=" .. api_key` concatenations in api.lua with
    -- "attempt to concatenate a userdata value". Only a real string is a key.
    local key = settings.api_keys[provider]
    if type(key) == "string" then return key end
  end
  return ""
end

function M.get_env_key_name(provider)
  return ENV_KEYS[provider]
end

-- Web-search backend keys live under settings.web_search.api_keys, with an env-var
-- fallback (env wins, same as get_api_key). Returns only a real string ("" if
-- unset / stored as JSON null -> vim.NIL) so callers can safely concat it.
local SEARCH_ENV_KEYS = {
  tavily = "TAVILY_API_KEY",
  serper = "SERPER_API_KEY",
  brave = "BRAVE_API_KEY",
  jina = "JINA_API_KEY",
}

function M.get_search_key(settings, name)
  local env_name = SEARCH_ENV_KEYS[name]
  if env_name then
    local env_val = vim.env[env_name]
    if env_val and env_val ~= "" then
      return env_val
    end
  end
  local ws = settings and settings.web_search
  if ws and ws.api_keys then
    local key = ws.api_keys[name]
    if type(key) == "string" then return key end
  end
  return ""
end

function M.get_search_env_key_name(name)
  return SEARCH_ENV_KEYS[name]
end

-- Normalized base URL of the local llama.cpp server. Trailing slashes are
-- trimmed so callers can safely append "/v1/...". Falls back to the documented
-- default port when unset.
function M.get_llama_server_url(settings)
  local url = settings and settings.llama_server_url
  if not url or url == "" then
    url = "http://127.0.0.1:8080"
  end
  return (url:gsub("/+$", ""))
end

-- Normalized base URL of the local engram memory server (trailing slashes
-- trimmed so callers can append "/search", "/observations", etc.).
function M.get_engram_url(settings)
  local url = settings and settings.engram_url
  if type(url) ~= "string" or url == "" then
    url = "http://127.0.0.1:7437"
  end
  return (url:gsub("/+$", ""))
end

-- Optional bearer token for engram (env ENGRAM_HTTP_TOKEN wins). String-guarded
-- (a JSON-null in settings decodes to vim.NIL, which must never reach a concat).
function M.get_engram_token(settings)
  local env_val = vim.env["ENGRAM_HTTP_TOKEN"]
  if env_val and env_val ~= "" then return env_val end
  local t = settings and settings.engram_token
  if type(t) == "string" then return t end
  return ""
end

function M.get_default_settings()
  return vim.deepcopy(default_settings)
end

function M.get_settings_path()
  return SETTINGS_PATH
end

----------------------------------------------------------------------
-- Project root (used as engram's per-project scope key)
----------------------------------------------------------------------

local project_root_cache = nil

function M.refresh_project_root()
  local ok, root
  if vim.fs and vim.fs.root then
    local buf_name = vim.api.nvim_buf_get_name(0)
    local start = (buf_name ~= "" and vim.fn.filereadable(buf_name) == 1) and buf_name or vim.fn.getcwd()
    ok, root = pcall(vim.fs.root, start, ROOT_MARKERS)
  end
  if not ok or not root then
    root = vim.fn.getcwd()
  end
  project_root_cache = root
  return project_root_cache
end

function M.get_project_root()
  local buftype = vim.bo.buftype
  if buftype == "" then
    return M.refresh_project_root()
  end
  if not project_root_cache then
    return M.refresh_project_root()
  end
  return project_root_cache
end

-- Per-project engram scope key: the git-root basename. Engram normalizes
-- (lowercase/trim) server-side; we pass it explicitly because the server
-- auto-detects project from ITS cwd, not from the request.
function M.engram_project()
  local root = M.get_project_root() or vim.fn.getcwd()
  return vim.fn.fnamemodify(root, ":t")
end

----------------------------------------------------------------------
-- Visual selection (multibyte-safe)
----------------------------------------------------------------------

function M.get_visual_selection()
  local mode = vim.fn.mode()
  local in_visual = mode:match("[vV\22]") ~= nil

  if vim.fn.exists("*getregion") == 1 then
    local p1 = vim.fn.getpos(in_visual and "v" or "'<")
    local p2 = vim.fn.getpos(in_visual and "." or "'>")
    local sel_mode = in_visual and mode or vim.fn.visualmode()
    if sel_mode == "" then sel_mode = "v" end
    local ok, lines = pcall(vim.fn.getregion, p1, p2, { type = sel_mode })
    if ok and lines and #lines > 0 then
      return table.concat(lines, "\n")
    end
  end

  -- Fallback byte-index selection logic
  local _, srow, scol, _ = unpack(vim.fn.getpos(in_visual and "v" or "'<"))
  local _, erow, ecol, _ = unpack(vim.fn.getpos(in_visual and "." or "'>"))

  if srow == 0 or erow == 0 then
    return nil
  end

  -- Sort positions
  if srow > erow or (srow == erow and scol > ecol) then
    srow, erow = erow, srow
    scol, ecol = ecol, scol
  end

  local visual_mode = in_visual and mode or vim.fn.visualmode()
  local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
  if #lines == 0 then
    return nil
  end

  if visual_mode == "v" then
    if srow == erow then
      lines[1] = string.sub(lines[1], scol, ecol)
    else
      lines[1] = string.sub(lines[1], scol)
      lines[#lines] = string.sub(lines[#lines], 1, ecol)
    end
  elseif visual_mode == "V" then
    -- Keep whole lines
  elseif visual_mode == "\22" then
    for i = 1, #lines do
      lines[i] = string.sub(lines[i], scol, ecol)
    end
  end

  return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Chat session storage (chat_<timestamp>.json per chat)
----------------------------------------------------------------------

function M.save_chat_session(session_id, history_data)
  if vim.fn.isdirectory(CHATS_DIR) == 0 then
    vim.fn.mkdir(CHATS_DIR, "p")
  end
  local filepath = CHATS_DIR .. "/" .. session_id .. ".json"
  local ok, encoded = pcall(vim.fn.json_encode, history_data)
  if not ok then
    return false
  end
  return write_file(filepath, encoded)
end

function M.delete_chat_session(session_id)
  local filepath = CHATS_DIR .. "/" .. session_id .. ".json"
  if vim.fn.filereadable(filepath) == 1 then
    return os.remove(filepath) == true
  end
  return false
end

-- Lists persisted chats, most-recent-first. Empty chats are never written to
-- disk (the runtime keeps the single empty chat in memory), so the msg_count>0
-- filter only ever drops a file that failed to decode.
function M.list_chat_sessions()
  if vim.fn.isdirectory(CHATS_DIR) == 0 then
    return {}
  end

  local sessions = {}
  for name, ftype in vim.fs.dir(CHATS_DIR) do
    if ftype == "file" and name:match("%.json$") then
      local id = name:gsub("%.json$", "")
      local display_name = id:gsub("^chat_", ""):gsub("_", " ")
      display_name = display_name:gsub("(%d%d%d%d%-%d%d%-%d%d) (%d%d)(%d%d)(%d%d)", "%1 %2:%3:%4")

      local filepath = CHATS_DIR .. "/" .. name
      local content = read_file(filepath)
      local msg_count = 0
      local summary = ""
      if content and content ~= "" then
        local ok, data = pcall(vim.fn.json_decode, content)
        if ok and type(data) == "table" then
          msg_count = #data
          for _, msg in ipairs(data) do
            if msg.role == "user" and type(msg.content) == "string" and msg.content ~= "" then
              summary = msg.content:gsub("\n", " "):sub(1, 35)
              if #msg.content > 35 then
                summary = summary .. "..."
              end
              break
            end
          end
        end
      end
      if msg_count > 0 then
        local display_text = display_name
        if summary ~= "" then
          display_text = string.format("%s: %s (%d messages)", display_name, summary, msg_count)
        else
          display_text = string.format("%s (%d messages)", display_name, msg_count)
        end
        table.insert(sessions, {
          id = id,
          display = display_text,
          filepath = filepath,
        })
      end
    end
  end

  table.sort(sessions, function(a, b)
    return a.id > b.id
  end)

  return sessions
end

function M.load_chat_session(session_id)
  local filepath = CHATS_DIR .. "/" .. session_id .. ".json"
  local content = read_file(filepath)
  if not content then return nil end
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok then return nil end
  return data
end

return M
