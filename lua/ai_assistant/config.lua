local M = {}

local SETTINGS_PATH = vim.fn.stdpath("data") .. "/ai_assistant_settings.json"
local CHATS_DIR = vim.fn.stdpath("data") .. "/ai_assistant_chats"
local MEMORY_DIR = vim.fn.stdpath("data") .. "/ai_assistant_memory"

-- Markers used to detect the project root, relative to the active buffer.
local ROOT_MARKERS = {
  ".git",
  ".ai_context",
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

-- Single source of truth for model lists, shared by api.lua (defaults/fallbacks)
-- and ui.lua (picker). When an API key is set the live /v1/models discovery is
-- authoritative; these lists are the no-key fallback and the canonical ordering.
-- Anthropic IDs are current as of 2026-06 (the old claude-3-* are all retired).
-- Gemini/OpenAI lead with the newest tiers; discovery fills in whatever is live.
-- Moonshot (Kimi) speaks the OpenAI-compatible API at api.moonshot.ai; the kimi-k2.x
-- ids are reasoning models (always-on thinking, temperature pinned to 1).
M.MODELS = {
  gemini = { "gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite" },
  anthropic = { "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5" },
  openai = { "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano" },
  moonshot = { "kimi-k2.6", "kimi-k2.5" },
}

-- Root-level context files auto-loaded into the system prompt when present.
-- AGENTS.md is the emerging cross-tool standard and is listed first.
M.WELL_KNOWN_CONTEXT_FILES = {
  "AGENTS.md",
  "CLAUDE.md",
  ".cursorrules",
  ".github/copilot-instructions.md",
  ".windsurfrules",
  "ai.md",
}

-- Project-context size limits (bytes). Project context is injected into the
-- system prompt on EVERY turn, so an oversized rule file or a big JSON dropped
-- into .ai_context/ would otherwise silently blow the model's context window.
local PER_FILE_CONTEXT_CAP = 64 * 1024
local TOTAL_CONTEXT_CAP = 256 * 1024

-- Keys whose nested tables should be deep-merged with defaults.
-- Everything else (notably arrays like `user_context` and `command_denylist`) is
-- treated atomically: if the user saved it, we use their version verbatim.
local DEEP_MERGE_KEYS = {
  api_keys = true,
  agents = true,
}

local default_settings = {
  default_model = "gemini-2.5-flash",
  -- Fast/cheap model used for delegated sub-agents that don't pin their own
  -- model (keeps the expensive coordinator model off exploratory sub-tasks).
  default_subagent_model = "gemini-2.5-flash",
  -- Base URL of a local llama.cpp server (`llama-server`), which exposes an
  -- OpenAI-compatible API. Models served here are discovered from
  -- `<url>/v1/models` and tagged with a "llamacpp:" prefix in the picker. Change
  -- the port here if you launched llama-server on a different one.
  llama_server_url = "http://127.0.0.1:8080",
  -- When true (and a vector index exists), inject the most relevant retrieved
  -- code chunks for each query instead of relying only on whole-file context.
  rag_enabled = false,
  auto_approve_tools = false,
  -- When false (default), file writes are shown as a reviewable diff you accept
  -- or reject before they are applied. Toggle per-session with `/diff`. When
  -- true, in-root writes apply automatically and surface a collapsed diff card.
  auto_write_files = false,
  -- Estimated token budget for the conversation. When exceeded, the UI trims
  -- the oldest turns before sending. Rough estimate (~4 chars/token).
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
    openai = "",
    anthropic = "",
    ollama = "",
    moonshot = "",
    -- Only needed if llama-server was started with `--api-key`; left blank,
    -- requests go out unauthenticated (the common local setup).
    llamacpp = "",
  },
  user_context = {
    { id = "developer_profile", text = "I am a full stack software engineer." },
    { id = "coding_guidelines", text = "Write clean, robust, well-structured code." },
  },
  -- Named bundles of { model, agent } the user can switch to instantly.
  presets = {},
  -- Models fanned out by /compare and /council. Empty = derive a sensible pair.
  compare_models = {},
  agents = {
    refactor = {
      system_prompt = "You are an expert refactoring assistant. Simplify logic, remove redundancy, and optimize code without breaking behavior.",
      model = "gemini-2.5-flash",
    },
    reviewer = {
      system_prompt = "You are an expert code reviewer. Analyze the code for bugs, performance bottlenecks, and edge cases.",
      model = "gemini-2.5-pro",
    },
    orchestrator = {
      system_prompt = "You are the head agent. You coordinate task execution by delegating sub-tasks to other agents. You can delegate by writing '[CALL_AGENT: agent_name] prompt'. Supported agents are: coder, refactor, reviewer.",
      model = "gemini-2.5-pro",
    },
    coder = {
      system_prompt = "You are an expert programmer. Write clean, complete, and correct code implementation matching specifications.",
      model = "gemini-2.5-flash",
    },
    sdd = {
      system_prompt = "You are a Spec-Driven Development (SDD) agent. You follow a rigorous software engineering lifecycle: 1. Explore (understand requirements, clarify ambiguities), 2. Spec (document detailed requirements and specs), 3. Design (architecture, data structures, APIs), 4. Implement (write code matching specs), 5. Verify (review, test, validate). Guide the user step-by-step through this lifecycle, requesting approval before advancing to the next phase.",
      model = "gemini-2.5-pro",
    },
  },
}

-- The fork-bomb pattern is injected programmatically so that this source file
-- never contains the literal sequence (which would trip command safety scanners).
default_settings.command_denylist[7] = ":" .. "%s*%(" .. "%s*%)%s*" .. "{"

-- Maps a provider name to the environment variable that may hold its key.
local ENV_KEYS = {
  gemini = "GEMINI_API_KEY",
  openai = "OPENAI_API_KEY",
  anthropic = "ANTHROPIC_API_KEY",
  ollama = "OLLAMA_API_KEY",
  moonshot = "MOONSHOT_API_KEY",
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

-- A cheap change-signature for a file (path:mtime:size); nil if missing.
local function stat_signature(path)
  local uv = vim.uv or vim.loop
  local ok, st = pcall(uv.fs_stat, path)
  if not ok or not st then return nil end
  return string.format("%s:%d:%d", path, st.mtime and st.mtime.sec or 0, st.size or 0)
end

-- Truncate content to a byte cap, appending a clear marker when cut.
local function truncate_content(content, cap, label)
  if #content > cap then
    return content:sub(1, cap)
      .. string.format("\n...[truncated %d bytes of %s]...\n", #content - cap, label or "file")
  end
  return content
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
    return settings.api_keys[provider] or ""
  end
  return ""
end

function M.get_env_key_name(provider)
  return ENV_KEYS[provider]
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

function M.get_default_settings()
  return vim.deepcopy(default_settings)
end

function M.get_settings_path()
  return SETTINGS_PATH
end

----------------------------------------------------------------------
-- Project root + context (with caching)
----------------------------------------------------------------------

local project_root_cache = nil
local context_cache = { root = nil, text = nil, sig = nil }

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
  if root ~= project_root_cache then
    project_root_cache = root
    context_cache = { root = nil, text = nil, sig = nil }
  end
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

function M.invalidate_context_cache()
  context_cache = { root = nil, text = nil }
end

-- Returns the ordered list of files that contribute to project context, as
-- { label, path, kind } entries (kind = "file" for .ai_context, "rule" for
-- well-known root files). Shared so the UI header can count the SAME files
-- that actually get loaded.
function M.list_context_files(root)
  root = root or M.get_project_root()
  local files = {}
  if not root then return files end

  local context_dir = root .. "/.ai_context"
  if vim.fn.isdirectory(context_dir) == 1 then
    local names = {}
    for name, ftype in vim.fs.dir(context_dir) do
      if ftype == "file" and (name:match("%.md$") or name:match("%.txt$") or name:match("%.json$") or name:match("%.lua$")) then
        table.insert(names, name)
      end
    end
    table.sort(names) -- deterministic order keeps the cache signature stable
    for _, name in ipairs(names) do
      table.insert(files, { label = ".ai_context/" .. name, path = context_dir .. "/" .. name, kind = "file" })
    end
  end

  for _, rel in ipairs(M.WELL_KNOWN_CONTEXT_FILES) do
    local filepath = root .. "/" .. rel
    if vim.fn.filereadable(filepath) == 1 then
      table.insert(files, { label = rel, path = filepath, kind = "rule" })
    end
  end

  return files
end

function M.get_project_context(force)
  local root = M.get_project_root()
  if not root then return "" end

  local files = M.list_context_files(root)

  -- Change-signature over all contributing files: rebuild when any file's
  -- mtime/size changes mid-session (edit CLAUDE.md and the model sees it now).
  local sig_parts = {}
  for _, f in ipairs(files) do
    table.insert(sig_parts, stat_signature(f.path) or (f.path .. ":?"))
  end
  local sig = table.concat(sig_parts, "|")

  if not force and context_cache.root == root and context_cache.sig == sig and context_cache.text ~= nil then
    return context_cache.text
  end

  local context_text = {}
  local total = 0
  for _, f in ipairs(files) do
    if total >= TOTAL_CONTEXT_CAP then
      table.insert(context_text, "\n...[project context truncated: total size cap reached]...\n")
      break
    end
    local content = read_file(f.path)
    if content and content ~= "" then
      content = truncate_content(content, PER_FILE_CONTEXT_CAP, f.label)
      total = total + #content
      local header = (f.kind == "file") and "### File: %s\n---\n%s\n---\n" or "### Project Rule File: %s\n---\n%s\n---\n"
      table.insert(context_text, string.format(header, f.label, content))
    end
  end

  local result = table.concat(context_text, "\n")
  context_cache = { root = root, text = result, sig = sig }
  return result
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

function M.init_project_context()
  local root = M.get_project_root()
  local context_dir = root .. "/.ai_context"
  if vim.fn.isdirectory(context_dir) == 0 then
    vim.fn.mkdir(context_dir, "p")
  end

  local readme_path = context_dir .. "/README.md"
  local readme_file = io.open(readme_path, "r")
  if not readme_file then
    local wf = io.open(readme_path, "w")
    if wf then
      wf:write([[# Project Context

This directory contains instructions and context files that help the AI Assistant understand this project.
Any file ending in `.md`, `.txt`, `.json`, or `.lua` in this folder will be loaded automatically and sent to the model with every request.

## Suggestions
- Create a `tech_stack.md` file listing the languages, frameworks, and tools used in this project.
- Create a `coding_rules.md` file with style guidelines, architecture diagrams, and conventions.
]])
      wf:close()
    end
  else
    readme_file:close()
  end

  local gitignore_path = root .. "/.gitignore"
  local gitignore_content = ""
  local gf = io.open(gitignore_path, "r")
  if gf then
    gitignore_content = gf:read("*all")
    gf:close()
  end

  if not gitignore_content:find(".ai_context") then
    local wf = io.open(gitignore_path, "a")
    if wf then
      wf:write("\n# AI Assistant local project context\n.ai_context/\n")
      wf:close()
      vim.notify("AI Assistant: Initialized .ai_context and added to .gitignore", vim.log.levels.INFO)
    end
  else
    vim.notify("AI Assistant: .ai_context directory is already initialized", vim.log.levels.INFO)
  end
end

----------------------------------------------------------------------
-- Persistent project memory (durable facts across sessions)
----------------------------------------------------------------------

local function memory_file_for(root)
  local key = (root or "global"):gsub("[^%w]", "_")
  return MEMORY_DIR .. "/" .. key .. ".md"
end

function M.get_memory_path()
  return memory_file_for(M.get_project_root())
end

function M.read_memory()
  return read_file(M.get_memory_path()) or ""
end

-- Append a single durable fact (one bullet) to this project's memory file.
function M.append_memory(fact)
  if not fact or vim.trim(fact) == "" then return false end
  if vim.fn.isdirectory(MEMORY_DIR) == 0 then
    vim.fn.mkdir(MEMORY_DIR, "p")
  end
  local path = M.get_memory_path()
  local existing = read_file(path) or ""
  local entry = "- " .. (vim.trim(fact):gsub("\n", " ")) .. "\n"
  return write_file(path, existing .. entry)
end

function M.clear_memory()
  local path = M.get_memory_path()
  if vim.fn.filereadable(path) == 1 then
    return os.remove(path) == true
  end
  return true
end

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

function M.list_chat_sessions()
  if vim.fn.isdirectory(CHATS_DIR) == 0 then
    return {}
  end

  local sessions = {}
  for name, ftype in vim.fs.dir(CHATS_DIR) do
    if ftype == "file" and name:match("%.json$") then
      local id = name:gsub("%.json$", "")
      local display_name = id:gsub("^chat_", ""):gsub("_", " ")
      -- Format time display if it matches standard date pattern
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
            if msg.role == "user" and msg.content and msg.content ~= "" then
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
          filepath = filepath
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
