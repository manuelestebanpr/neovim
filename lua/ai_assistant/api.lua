local M = {}
local config = require("ai_assistant.config")

-- Fold-marker convention shared with ui.lua: a "card" is a summary line ending
-- in FOLD_OPEN followed by body lines and a closing FOLD_CLOSE line. The chat
-- window is set up with foldmethod=marker / foldmarker=FOLD_OPEN,FOLD_CLOSE so
-- these render as a single collapsed line (expand with `za`). Keeping the
-- markers in one place means api.lua and ui.lua never drift.
M.FOLD_OPEN = "\u{2039}\u{2039}\u{2039}"  -- ‹‹‹
M.FOLD_CLOSE = "\u{203a}\u{203a}\u{203a}" -- ›››

-- Wrap `body` in a collapsible card under `summary` (a single chat line).
local function fold_card(summary, body)
  body = body or ""
  if body == "" then return "\n" .. summary .. "\n" end
  return "\n" .. summary .. " " .. M.FOLD_OPEN .. "\n" .. body .. "\n" .. M.FOLD_CLOSE .. "\n"
end

----------------------------------------------------------------------
-- Provider Routing & Defaults
----------------------------------------------------------------------

-- Returns: provider, base temperature, normalized model id
function M.get_provider_details(model_name)
  local name = model_name or ""
  local temperature = 0.7
  if name:match("%-high$") then
    temperature = 1.0
    name = name:gsub("%-high$", "")
  elseif name:match("%-low$") then
    temperature = 0.2
    name = name:gsub("%-low$", "")
  end
  local lower = name:lower()
  local provider
  if lower:match("^gemini") or lower:match("^gemma") then
    provider = "gemini"
  elseif lower:match("^claude") then
    provider = "anthropic"
  elseif lower:match("^gpt") or lower:match("^o%d") then
    provider = "openai"
  elseif lower:match("^kimi") or lower:match("^moonshot") then
    provider = "moonshot"
  else
    provider = "ollama"
  end
  return provider, temperature, name
end

-- Moonshot (Kimi) is OpenAI Chat Completions compatible, so the message
-- builders, streaming parser, and response parser all reuse the "openai" code
-- paths. This maps a transport provider to the wire format its payload speaks;
-- the raw provider is still used for the endpoint URL, auth header, and API key.
local function wire_provider(provider)
  if provider == "moonshot" then return "openai" end
  return provider
end

-- Fallback lists used only when live /v1/models discovery returns nothing
-- (no API key / offline). Sourced from config.MODELS (single source of truth);
-- deep-copied because fetch_available_models sorts these in place.
local DEFAULT_MODELS = {
  gemini = vim.deepcopy(config.MODELS.gemini),
  openai = vim.deepcopy(config.MODELS.openai),
  anthropic = vim.deepcopy(config.MODELS.anthropic),
  moonshot = vim.deepcopy(config.MODELS.moonshot),
}

function M.get_default_models()
  local combined = {}
  for _, list in pairs({ DEFAULT_MODELS.gemini, DEFAULT_MODELS.anthropic, DEFAULT_MODELS.openai, DEFAULT_MODELS.moonshot }) do
    for _, m in ipairs(list) do
      table.insert(combined, m)
    end
  end
  return combined
end

----------------------------------------------------------------------
-- Model Discovery
----------------------------------------------------------------------

function M.fetch_available_models(callback)
  local settings = config.load_settings()
  local curl = require("plenary.curl")
  local results = { gemini = {}, anthropic = {}, openai = {}, moonshot = {}, ollama = {} }
  local pending = 0
  local done = false

  local function finalize()
    if done then return end
    done = true
    local seen, ordered = {}, {}
    for _, provider in ipairs({ "gemini", "anthropic", "openai", "moonshot", "ollama" }) do
      local list = results[provider]
      if #list == 0 and DEFAULT_MODELS[provider] then
        list = DEFAULT_MODELS[provider]
      end
      table.sort(list)
      for _, m in ipairs(list) do
        -- Also add low/medium/high presets for key models
        if not seen[m] then
          seen[m] = true
          if m:match("^gemini") or m:match("^claude") or m:match("^kimi") then
            -- The suffix controls reasoning EFFORT (Anthropic adaptive thinking /
            -- Gemini thinkingLevel / Moonshot reasoning_effort), not sampling
            -- temperature — label it as such.
            table.insert(ordered, { id = m .. "-low", text = m .. " (Low Effort)" })
            table.insert(ordered, { id = m .. "-medium", text = m .. " (Medium Effort)" })
            table.insert(ordered, { id = m .. "-high", text = m .. " (High Effort)" })
          else
            table.insert(ordered, { id = m, text = m })
          end
        end
      end
    end
    vim.schedule(function() callback(ordered) end)
  end

  local function request(opts)
    pending = pending + 1
    -- Run exactly once per request, whether it succeeds, returns non-200, or the
    -- curl process fails (e.g. Ollama not running -> connection refused). Without
    -- this, a failed request would leave `pending` stuck and the menu would never
    -- open; and without on_error, plenary RAISES on a non-zero curl exit, which
    -- crashed the whole "fetch models" action.
    local finished = false
    local function finish()
      if finished then return end
      finished = true
      pending = pending - 1
      if pending == 0 then finalize() end
    end
    local ok = pcall(curl.get, opts.url, {
      headers = opts.headers,
      timeout = 5000,
      on_error = function() finish() end,
      callback = function(res)
        if res and res.status == 200 and res.body then
          -- vim.json.decode is safe in plenary's async (fast-event) callback
          -- context; vim.fn.json_decode is not.
          local okd, decoded = pcall(vim.json.decode, res.body)
          if okd and decoded then
            pcall(opts.parse, decoded, results)
          end
        end
        finish()
      end,
    })
    if not ok then
      finish()
    end
  end

  local gemini_key = config.get_api_key(settings, "gemini")
  if gemini_key ~= "" then
    request({
      url = "https://generativelanguage.googleapis.com/v1beta/models?key=" .. gemini_key,
      parse = function(decoded, out)
        if decoded.models then
          for _, m in ipairs(decoded.models) do
            local id = (m.name or ""):gsub("^models/", "")
            local supports_gen = false
            for _, method in ipairs(m.supportedGenerationMethods or {}) do
              if method == "generateContent" then
                supports_gen = true
                break
              end
            end
            if supports_gen and (id:match("^gemini") or id:match("^gemma")) then
              table.insert(out.gemini, id)
            end
          end
        end
      end,
    })
  end

  local openai_key = config.get_api_key(settings, "openai")
  if openai_key ~= "" then
    request({
      url = "https://api.openai.com/v1/models",
      headers = { Authorization = "Bearer " .. openai_key },
      parse = function(decoded, out)
        if decoded.data then
          for _, m in ipairs(decoded.data) do
            local id = m.id or ""
            if id:match("^gpt") or id:match("^o[134]") then
              table.insert(out.openai, id)
            end
          end
        end
      end,
    })
  end

  local anthropic_key = config.get_api_key(settings, "anthropic")
  if anthropic_key ~= "" then
    request({
      url = "https://api.anthropic.com/v1/models",
      headers = {
        ["x-api-key"] = anthropic_key,
        ["anthropic-version"] = "2023-06-01",
      },
      parse = function(decoded, out)
        if decoded.data then
          for _, m in ipairs(decoded.data) do
            if m.id then table.insert(out.anthropic, m.id) end
          end
        end
      end,
    })
  end

  -- Moonshot (Kimi) discovery — OpenAI-compatible /v1/models. Filtered to the
  -- kimi-* reasoning models so the picker isn't flooded with legacy moonshot-v1-*.
  local moonshot_key = config.get_api_key(settings, "moonshot")
  if moonshot_key ~= "" then
    request({
      url = "https://api.moonshot.ai/v1/models",
      headers = { Authorization = "Bearer " .. moonshot_key },
      parse = function(decoded, out)
        if decoded.data then
          for _, m in ipairs(decoded.data) do
            local id = m.id or ""
            if id:match("^kimi") then
              table.insert(out.moonshot, id)
            end
          end
        end
      end,
    })
  end

  -- Ollama local discovery
  request({
    url = "http://localhost:11434/api/tags",
    parse = function(decoded, out)
      if decoded.models then
        for _, m in ipairs(decoded.models) do
          if m.name then table.insert(out.ollama, m.name) end
        end
      end
    end,
  })

  if pending == 0 then
    finalize()
  end
end

----------------------------------------------------------------------
-- Sandboxing & Denylist
----------------------------------------------------------------------

local function normalize_path(p)
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(p)
  end
  return p
end

function M.resolve_tool_path(arg)
  local uv = vim.uv or vim.loop
  local root = normalize_path(config.get_project_root())
  -- Realpath the root too, so the containment compare is symlink-for-symlink.
  local real_root = uv.fs_realpath(root) or root
  local raw = vim.trim(arg or "")
  local abs
  if raw:match("^/") or raw:match("^%a:[/\\]") then
    abs = normalize_path(raw)
  else
    abs = normalize_path(root .. "/" .. raw)
  end
  -- vim.fs.normalize is purely lexical: it collapses "." / ".." but does NOT
  -- resolve symlinks. A link inside the project that points outside (e.g. an
  -- attacker-planted "logs" -> "/etc" in a cloned repo) would otherwise be
  -- classified in_root and read/written with no confirmation under auto-approve.
  -- Resolve symlinks before the containment check. For a path that doesn't exist
  -- yet (a fresh create/write), realpath the deepest existing ancestor and
  -- re-append the unresolved tail so a create-through-symlink is still caught.
  local real = uv.fs_realpath(abs)
  if not real then
    local probe, tail = abs, ""
    while probe and probe ~= "" and probe ~= "/" and not uv.fs_realpath(probe) do
      tail = "/" .. vim.fs.basename(probe) .. tail
      probe = vim.fs.dirname(probe)
    end
    local base = uv.fs_realpath(probe) or probe
    real = normalize_path(base .. tail)
  end
  -- Keep abs = real so execute_tool's io.open / mkdir operate on exactly the
  -- resolved path the containment check validated.
  local in_root = (real == real_root) or (real:sub(1, #real_root + 1) == real_root .. "/")
  return { abs = real, in_root = in_root, root = real_root }
end

function M.is_command_denied(command, settings)
  local list = settings and settings.command_denylist or {}
  for _, pat in ipairs(list) do
    local ok, matched = pcall(string.find, command, pat)
    if ok and matched then
      return true, pat
    end
  end
  return false
end

----------------------------------------------------------------------
-- Tool-Call Parsing (Ignoring Fences)
----------------------------------------------------------------------

function M.parse_tool_call(text)
  if not text then return nil end

  -- 1. WRITE_FILE block (multi-line). Markers must appear unfenced.
  do
    local path, content = text:match("%[WRITE_FILE:%s*([^%]]+)%]\n(.-)\n%[END_WRITE%]")
    if path and content then
      local idx = text:find("%[WRITE_FILE:", 1, false)
      if idx then
        local prefix = text:sub(1, idx - 1)
        local _, fences = prefix:gsub("```", "")
        if fences % 2 == 0 then
          return { type = "write_file", path = vim.trim(path), content = content }
        end
      end
    end
  end

  -- 2. Single-line directives (RUN_COMMAND / READ_FILE), skipping fences.
  local in_fence = false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      local cmd = line:match("^%s*%[RUN_COMMAND%]%s*(.+)$")
      if cmd and vim.trim(cmd) ~= "" then
        return { type = "command", arg = vim.trim(cmd) }
      end
      local rf = line:match("^%s*%[READ_FILE%]%s*(.+)$")
      if rf and vim.trim(rf) ~= "" then
        return { type = "read_file", arg = vim.trim(rf) }
      end
    end
  end

  return nil
end

----------------------------------------------------------------------
-- Write diff (shared by the auto-write card and the review popup)
----------------------------------------------------------------------

-- Returns { diff = unified-diff string, added, removed, kind = "create"|"modify" }
-- for a proposed write of `content` to `path`, comparing against the file on disk.
function M.compute_write_diff(path, content)
  local res = M.resolve_tool_path(path)
  local old_content = ""
  local ef = io.open(res.abs, "r")
  if ef then old_content = ef:read("*all") or ""; ef:close() end
  local diff = vim.diff(old_content, content or "", { result_type = "unified", ctxlen = 3 }) or ""
  local added, removed = 0, 0
  for line in diff:gmatch("[^\n]+") do
    if line:match("^%+") and not line:match("^%+%+%+") then
      added = added + 1
    elseif line:match("^%-") and not line:match("^%-%-%-") then
      removed = removed + 1
    end
  end
  return { diff = diff, added = added, removed = removed, kind = (old_content == "") and "create" or "modify" }
end

----------------------------------------------------------------------
-- Async Machine Tool Execution
----------------------------------------------------------------------

function M.execute_tool(tool_type, tool_arg, on_complete, opts)
  -- Fire the completion callback EXACTLY once. If a branch raises, the loop must
  -- still advance (with an error result the model can see) rather than stall and
  -- leave the spinner spinning.
  local done = false
  local function complete(output)
    if done then return end
    done = true
    on_complete(output)
  end

  if tool_type == "command" then
    local shell = vim.o.shell or "sh"
    local ok, job = pcall(vim.system, { shell, "-c", tool_arg }, { text = true }, function(obj)
      vim.schedule(function()
        local output = obj.stdout or ""
        if obj.stderr and obj.stderr ~= "" then
          output = output .. "\nStderr:\n" .. obj.stderr
        end
        -- Many commands signal failure purely via exit status with no stderr
        -- (false, test, grep/diff returning 1). Surface it so the model doesn't
        -- read empty output as success. Signal is set when the job is killed
        -- (e.g. Esc-cancellation), so report that too.
        if obj.code and obj.code ~= 0 then
          output = output .. string.format("\n[exit code: %d]", obj.code)
        end
        if obj.signal and obj.signal ~= 0 then
          output = output .. string.format("\n[terminated by signal: %d]", obj.signal)
        end
        if output == "" then
          output = "[command produced no output; exit code 0]"
        end
        complete(output)
      end)
    end)
    if not ok then
      complete("Error: failed to spawn command: " .. tostring(job))
      return
    end
    if opts and opts.on_job_started then
      opts.on_job_started(job)
    end
    return
  end

  -- Synchronous tools (read/write/memory). Wrap so a raised IO/filesystem error
  -- becomes a graceful "Error: ..." tool result the model is told about.
  local ok, err = pcall(function()
    if tool_type == "read_file" then
      local res = M.resolve_tool_path(tool_arg)
      local f = io.open(res.abs, "rb")
      if not f then
        complete("Error: File not found: " .. tostring(tool_arg))
        return
      end
      local content = f:read("*all")
      f:close()
      complete(content)
    elseif tool_type == "write_file" then
      -- Refuse before touching disk: a nil/non-string content would otherwise be
      -- written as an empty file, silently truncating an existing file.
      if type(tool_arg.content) ~= "string" then
        complete("Error: write_file requires a 'content' string; refusing to write to avoid truncating the file.")
        return
      end
      local res = M.resolve_tool_path(tool_arg.path)
      local dir = vim.fs.dirname(res.abs)
      if dir and vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
      end
      local f = io.open(res.abs, "wb")
      if not f then
        complete("Error: Cannot write to path: " .. tostring(tool_arg.path))
        return
      end
      f:write(tool_arg.content)
      f:close()
      complete("File written successfully: " .. tostring(tool_arg.path))
    elseif tool_type == "save_memory" then
      local saved = config.append_memory(tool_arg)
      complete(saved and ("Saved to project memory: " .. tostring(tool_arg)) or "Error: could not save to memory.")
    else
      complete("Error: Unknown tool type.")
    end
  end)
  if not ok then
    complete("Error: tool execution failed: " .. tostring(err))
  end
end

----------------------------------------------------------------------
-- Context Budget Trimming
----------------------------------------------------------------------

local function estimate_tokens(text)
  return math.ceil(#(text or "") / 4)
end

local function get_history_tokens(history_data)
  local t = 0
  for _, msg in ipairs(history_data) do
    t = t + estimate_tokens(msg.content)
    -- Tool turns carry their payload in tool_results[*].output / tool_calls[*].input,
    -- not in .content. These are often the largest part of an agentic conversation,
    -- so count them or the budget is blind exactly where it matters.
    if msg.tool_results then
      for _, r in ipairs(msg.tool_results) do
        t = t + estimate_tokens(r.output)
      end
    end
    if msg.tool_calls then
      for _, c in ipairs(msg.tool_calls) do
        local ok, enc = pcall(vim.fn.json_encode, c.input or {})
        t = t + estimate_tokens(ok and enc or "")
      end
    end
  end
  return t
end

local function trim_history_to_budget(history, budget, system_prompt, processed_prompt, opts)
  local other_tokens = estimate_tokens(system_prompt) + estimate_tokens(processed_prompt)
  local available = budget - other_tokens
  local trimmed = vim.deepcopy(history or {})
  local trimmed_count = 0

  while #trimmed > 0 and get_history_tokens(trimmed) > available do
    if #trimmed >= 2 then
      table.remove(trimmed, 1) -- Remove user turn
      table.remove(trimmed, 1) -- Remove assistant response
      trimmed_count = trimmed_count + 1
    else
      table.remove(trimmed, 1)
    end
  end

  -- Trimming two-at-a-time assumes strict user/assistant alternation, but a tool
  -- round-trip is a 3-turn group ({user}, {model+tool_calls}, {tool+tool_results}).
  -- A cut can therefore strand a tool_use turn without its tool_result (or vice
  -- versa), which every provider rejects with a 400. Reconcile to a fixed point:
  -- drop any tool_results turn not immediately preceded by its tool_calls turn,
  -- and any tool_calls turn not immediately followed by its tool_results turn.
  local function is_tool_results(m) return m and m.tool_results ~= nil end
  local function is_tool_calls(m) return m and m.tool_calls ~= nil end
  local changed = true
  while changed do
    changed = false
    for i = #trimmed, 1, -1 do
      if is_tool_results(trimmed[i]) and not (i > 1 and is_tool_calls(trimmed[i - 1])) then
        table.remove(trimmed, i); changed = true
      end
    end
    for i = #trimmed, 1, -1 do
      if is_tool_calls(trimmed[i]) and not is_tool_results(trimmed[i + 1]) then
        table.remove(trimmed, i); changed = true
      end
    end
  end

  if trimmed_count > 0 and opts.notify_fn then
    opts.notify_fn(string.format("\n> **System**: Context budget exceeded. Trimmed %d older turns to fit budget.\n", trimmed_count))
  end
  return trimmed
end

----------------------------------------------------------------------
-- File Mention Processor
----------------------------------------------------------------------

local function process_file_mentions(prompt, project_root)
  local mentions = {}
  for filename in prompt:gmatch("@([%w_%-%.%/]+)") do
    local filepath = project_root .. "/" .. filename
    if vim.fn.filereadable(filepath) == 1 then
      local f = io.open(filepath, "r")
      if f then
        local content = f:read("*all")
        f:close()
        local ext = filename:match("%.([^%.]+)$") or ""
        table.insert(mentions, string.format("\n### Context File: %s\n```%s\n%s\n```\n", filename, ext, content))
      end
    end
  end
  if #mentions > 0 then
    return prompt .. "\n" .. table.concat(mentions, "\n")
  end
  return prompt
end

-- Parses the -low/-medium/-high preset suffix into (clean_model, temperature, effort).
-- Temperature is used by providers that accept it; effort is used by reasoning
-- models (Anthropic adaptive thinking, OpenAI reasoning_effort, Gemini thinkingLevel).
local function get_model_and_temp_override(model_name)
  if not model_name or model_name == "" then
    return "gemini-2.5-flash", nil, nil
  end
  local name = model_name:lower()
  local temp, effort = nil, nil
  -- The picker appends a hyphen-delimited "-low"/"-medium"/"-high" preset, so
  -- detection is anchored to that exact suffix. An unanchored search would
  -- mis-flag real model ids that merely end in those letters (e.g. "marlow", a
  -- local Ollama tag ending in "-med", or "...-flash-lite").
  if name:match("%-high$") then
    temp, effort = 1.0, "high"
  elseif name:match("%-medium$") then
    temp, effort = 0.7, "medium"
  elseif name:match("%-low$") then
    temp, effort = 0.2, "low"
  end
  local clean = model_name:gsub("%-high$", ""):gsub("%-medium$", ""):gsub("%-low$", "")
                          :gsub("%s+%(.*%)$", "")
  return clean, temp, effort
end

-- Anthropic Opus 4.7/4.8 (and any opus-4-1x) removed sampling params: sending
-- temperature/top_p/top_k returns 400. Opus 4.6 / Sonnet 4.6 / Haiku 4.5 accept them.
local function anthropic_rejects_sampling(model)
  local m = (model or ""):lower()
  return m:match("opus%-4%-[789]") ~= nil or m:match("opus%-4%-1%d") ~= nil
end

-- Anthropic models that support adaptive thinking + the effort knob.
local function anthropic_supports_effort(model)
  local m = (model or ""):lower()
  return m:match("opus%-4%-[6789]") ~= nil or m:match("opus%-4%-1%d") ~= nil or m:match("sonnet%-4%-6") ~= nil
end

-- OpenAI reasoning models (o-series and gpt-5.x): reject temperature/top_p and
-- require max_completion_tokens instead of max_tokens.
local function openai_is_reasoning(model)
  local m = (model or ""):lower()
  return m:match("^o%d") ~= nil or m:match("^gpt%-5") ~= nil
end

-- Pulls the incremental text out of one parsed streaming chunk, per provider.
local function extract_stream_delta(provider, obj)
  if provider == "anthropic" then
    if obj.type == "content_block_delta" and obj.delta and obj.delta.type == "text_delta" then
      return obj.delta.text
    end
  elseif provider == "openai" then
    local ch = obj.choices and obj.choices[1]
    return ch and ch.delta and ch.delta.content or nil
  elseif provider == "gemini" then
    local cand = obj.candidates and obj.candidates[1]
    local part = cand and cand.content and cand.content.parts and cand.content.parts[1]
    return part and part.text or nil
  elseif provider == "ollama" then
    return obj.message and obj.message.content or nil
  end
  return nil
end

----------------------------------------------------------------------
-- Native Tool Calling (tools / tool_use / tool_result)
----------------------------------------------------------------------

-- Canonical tool definitions, converted to each provider's wire format below.
local TOOL_DEFS = {
  {
    name = "run_command",
    description = "Run a shell command on the user's machine and return its stdout/stderr. Use for git, tests, builds, listing files, etc.",
    properties = { command = { type = "string", description = "The exact shell command to execute" } },
    required = { "command" },
  },
  {
    name = "read_file",
    description = "Read the full contents of a file. Path may be relative to the project root or absolute.",
    properties = { path = { type = "string", description = "File path to read" } },
    required = { "path" },
  },
  {
    name = "write_file",
    description = "Create or overwrite a file with the given content. The user is shown a diff and asked to approve unless auto-approve is on.",
    properties = {
      path = { type = "string", description = "File path to write" },
      content = { type = "string", description = "The complete new file content" },
    },
    required = { "path", "content" },
  },
  {
    name = "save_memory",
    description = "Save one durable fact about this project to long-term memory that persists across sessions (e.g. 'this repo uses Gradle, not Maven', preferred libraries, conventions). Saved silently without approval.",
    properties = { fact = { type = "string", description = "The single fact to remember" } },
    required = { "fact" },
  },
}

local function anthropic_tools()
  local out = {}
  for _, d in ipairs(TOOL_DEFS) do
    out[#out + 1] = { name = d.name, description = d.description, input_schema = { type = "object", properties = d.properties, required = d.required } }
  end
  return out
end

-- OpenAI + Ollama share the function-tool shape.
local function openai_tools()
  local out = {}
  for _, d in ipairs(TOOL_DEFS) do
    out[#out + 1] = { type = "function", ["function"] = { name = d.name, description = d.description, parameters = { type = "object", properties = d.properties, required = d.required } } }
  end
  return out
end

local function gemini_tools()
  local fd = {}
  for _, d in ipairs(TOOL_DEFS) do
    fd[#fd + 1] = { name = d.name, description = d.description, parameters = { type = "object", properties = d.properties, required = d.required } }
  end
  return { { functionDeclarations = fd } }
end

-- Maps a native tool call (name + parsed input) to execute_tool's (type, arg).
function M.tool_call_to_exec(name, input)
  input = input or {}
  -- Coerce a provider-supplied field to a string; a malformed call (number,
  -- bool, nested table) must never reach vim.system / io:write as a non-string.
  local function s(v) return type(v) == "string" and v or "" end
  if name == "run_command" then
    return "command", s(input.command)
  elseif name == "read_file" then
    return "read_file", s(input.path)
  elseif name == "write_file" then
    -- content is intentionally left RAW (not coerced to ""): a missing or
    -- non-string content must be REJECTED rather than silently written as an
    -- empty file (which would truncate an existing file). The type-check guards
    -- in execute_tool and the tool loop enforce this.
    return "write_file", { path = s(input.path), content = input.content }
  elseif name == "save_memory" then
    return "save_memory", s(input.fact)
  end
  return nil, nil
end

local function nonempty_obj(t)
  if type(t) ~= "table" or next(t) == nil then return vim.empty_dict() end
  return t
end

-- ---- Per-provider message builders from the neutral history -----------------
-- History entries: { role, content, thought_signature? }, or { role="model", content,
-- tool_calls={{id,name,input,thought_signature?}},
-- thinking_blocks={{type,thinking,signature}|{type="redacted_thinking",data}},
-- reasoning_content? }, or { role="tool", tool_results={{id,name,output}} }.
-- reasoning_content is the Moonshot/Kimi analog: the raw chain-of-thought string
-- captured from an OpenAI-compatible reasoning response. It is replayed only by
-- the OpenAI builder, and only on the assistant turn that carries tool_calls,
-- where Moonshot requires it (other providers never set it).
-- thinking_blocks are captured only for Anthropic and replayed only by the
-- Anthropic builder (the API requires them on the assistant turn that carries
-- tool_use when thinking is enabled; other providers ignore them).
-- thought_signature is the Gemini analog: an encrypted reasoning token Gemini 3
-- attaches to a part. It is captured only for Gemini and replayed only by the
-- Gemini builder. On a functionCall part (tool_calls[*].thought_signature) the
-- API REQUIRES it on the model turn carrying the call, or the tool continuation
-- 400s. On a plain model turn (entry-level thought_signature, from a pure-thinking
-- turn with no tool calls) echoing it back is recommended for reasoning continuity
-- but is not required to avoid the 400.

local function build_anthropic_messages(history, processed_prompt, append_user)
  local messages = {}
  for _, msg in ipairs(history) do
    if msg.tool_results then
      local content = {}
      for _, r in ipairs(msg.tool_results) do
        content[#content + 1] = { type = "tool_result", tool_use_id = r.id, content = r.output or "" }
      end
      messages[#messages + 1] = { role = "user", content = content }
    elseif msg.tool_calls then
      local content = {}
      -- Anthropic requires the assistant turn carrying tool_use to BEGIN with the
      -- thinking block(s) from that turn (signatures preserved verbatim) whenever
      -- thinking is enabled, or the tool-result continuation 400s.
      -- All-or-nothing: emitting a PARTIAL set of thinking blocks (e.g. keeping a
      -- redacted block while dropping a signature-less "thinking" block) produces
      -- an assistant turn whose leading thinking is incomplete, which the API
      -- rejects. Only replay the blocks if EVERY one is emittable; otherwise emit
      -- none (a tool_use turn with no leading thinking block is itself valid).
      local tbs = msg.thinking_blocks or {}
      local all_emittable = true
      for _, tb in ipairs(tbs) do
        local ok = (tb.type == "redacted_thinking" and tb.data)
          or (tb.signature and tb.signature ~= "")
        if not ok then all_emittable = false break end
      end
      if all_emittable then
        for _, tb in ipairs(tbs) do
          if tb.type == "redacted_thinking" then
            content[#content + 1] = { type = "redacted_thinking", data = tb.data }
          else
            content[#content + 1] = { type = "thinking", thinking = tb.thinking or "", signature = tb.signature }
          end
        end
      end
      if msg.content and msg.content ~= "" then content[#content + 1] = { type = "text", text = msg.content } end
      for _, c in ipairs(msg.tool_calls) do
        content[#content + 1] = { type = "tool_use", id = c.id, name = c.name, input = nonempty_obj(c.input) }
      end
      messages[#messages + 1] = { role = "assistant", content = content }
    else
      messages[#messages + 1] = { role = (msg.role == "model" or msg.role == "assistant") and "assistant" or "user", content = msg.content or "" }
    end
  end
  if append_user then
    messages[#messages + 1] = { role = "user", content = processed_prompt }
  end
  while #messages > 0 and messages[1].role ~= "user" do table.remove(messages, 1) end
  return messages
end

local function build_openai_messages(history, system_prompt, processed_prompt, append_user, reasoning_mode)
  local messages = { { role = "system", content = system_prompt } }
  for _, msg in ipairs(history) do
    if msg.tool_results then
      for _, r in ipairs(msg.tool_results) do
        messages[#messages + 1] = { role = "tool", tool_call_id = r.id, content = r.output or "" }
      end
    elseif msg.tool_calls then
      local tcs = {}
      for _, c in ipairs(msg.tool_calls) do
        tcs[#tcs + 1] = { id = c.id, type = "function", ["function"] = { name = c.name, arguments = vim.fn.json_encode(nonempty_obj(c.input)) } }
      end
      local entry = { role = "assistant", content = msg.content or "", tool_calls = tcs }
      -- Moonshot/Kimi reasoning models REQUIRE the chain-of-thought that produced
      -- a tool call to be echoed back on that assistant turn, or the tool-result
      -- continuation 400s ("reasoning_content is missing in assistant tool call
      -- message at index N"). In reasoning_mode the key is ALWAYS serialized on a
      -- tool_call turn (empty string when none was captured) — omitting it on null
      -- is what triggers the 400. Plain OpenAI never sets it, so it stays absent.
      if reasoning_mode then
        entry.reasoning_content = msg.reasoning_content or ""
      elseif msg.reasoning_content and msg.reasoning_content ~= "" then
        entry.reasoning_content = msg.reasoning_content
      end
      messages[#messages + 1] = entry
    else
      messages[#messages + 1] = { role = (msg.role == "model" or msg.role == "assistant") and "assistant" or "user", content = msg.content or "" }
    end
  end
  if append_user then
    messages[#messages + 1] = { role = "user", content = processed_prompt }
  end
  return messages
end

local function build_ollama_messages(history, system_prompt, processed_prompt, append_user)
  local messages = { { role = "system", content = system_prompt } }
  for _, msg in ipairs(history) do
    if msg.tool_results then
      for _, r in ipairs(msg.tool_results) do
        messages[#messages + 1] = { role = "tool", content = r.output or "" }
      end
    elseif msg.tool_calls then
      local tcs = {}
      for _, c in ipairs(msg.tool_calls) do
        tcs[#tcs + 1] = { type = "function", ["function"] = { name = c.name, arguments = nonempty_obj(c.input) } }
      end
      messages[#messages + 1] = { role = "assistant", content = msg.content or "", tool_calls = tcs }
    else
      messages[#messages + 1] = { role = (msg.role == "model" or msg.role == "assistant") and "assistant" or "user", content = msg.content or "" }
    end
  end
  if append_user then
    messages[#messages + 1] = { role = "user", content = processed_prompt }
  end
  return messages
end

local function build_gemini_contents(history, processed_prompt, append_user)
  local turns = {}
  for _, msg in ipairs(history) do
    if msg.tool_results then
      local parts = {}
      for _, r in ipairs(msg.tool_results) do
        parts[#parts + 1] = { functionResponse = { name = r.name, response = { result = r.output or "" } } }
      end
      turns[#turns + 1] = { role = "user", parts = parts }
    elseif msg.tool_calls then
      local parts = {}
      if msg.content and msg.content ~= "" then parts[#parts + 1] = { text = msg.content } end
      for _, c in ipairs(msg.tool_calls) do
        local part = { functionCall = { name = c.name, args = nonempty_obj(c.input) } }
        -- Replay the captured thoughtSignature on the exact part it arrived on.
        -- Gemini 3 requires it on the functionCall part to continue a tool turn;
        -- for non-first parallel calls and non-thinking models it stays nil (and
        -- must remain absent — fabricating one would be rejected).
        if c.thought_signature and c.thought_signature ~= "" then
          part.thoughtSignature = c.thought_signature
        end
        parts[#parts + 1] = part
      end
      turns[#turns + 1] = { role = "model", parts = parts }
    else
      local role = (msg.role == "model" or msg.role == "assistant") and "model" or "user"
      local part = { text = msg.content or "" }
      -- Echo back a signature captured from a pure-thinking (non-functionCall)
      -- model turn on its text part — recommended to keep Gemini's reasoning
      -- continuity. Only ever set on model turns; user turns never carry one.
      if role == "model" and msg.thought_signature and msg.thought_signature ~= "" then
        part.thoughtSignature = msg.thought_signature
      end
      turns[#turns + 1] = { role = role, parts = { part } }
    end
  end
  if append_user then
    turns[#turns + 1] = { role = "user", parts = { { text = processed_prompt } } }
  end
  -- Merge consecutive same-role turns (concatenating their parts) so Gemini's
  -- strict alternation holds even across tool round-trips.
  local merged = {}
  for _, t in ipairs(turns) do
    if #merged > 0 and merged[#merged].role == t.role then
      for _, p in ipairs(t.parts) do table.insert(merged[#merged].parts, p) end
    else
      merged[#merged + 1] = t
    end
  end
  return merged
end

-- ---- Non-streaming response -> { text, tool_calls } -------------------------
-- 4th return is a Gemini-only standalone thoughtSignature from a pure-thinking
-- (non-functionCall) turn; nil for every other provider/case. 5th return is the
-- Moonshot/Kimi reasoning_content string (nil for non-reasoning OpenAI responses).
local function parse_response_tools(provider, data)
  local text, tools, thinking, gemini_sig, reasoning = "", {}, {}, nil, nil
  if provider == "anthropic" then
    if type(data.content) == "table" then
      for _, block in ipairs(data.content) do
        if block.type == "text" and block.text then
          text = text .. block.text
        elseif block.type == "thinking" then
          thinking[#thinking + 1] = { type = "thinking", thinking = block.thinking or "", signature = block.signature }
        elseif block.type == "redacted_thinking" then
          thinking[#thinking + 1] = { type = "redacted_thinking", data = block.data }
        elseif block.type == "tool_use" then
          tools[#tools + 1] = { id = block.id, name = block.name, input = block.input or {} }
        end
      end
    end
  elseif provider == "openai" then
    local msg = data.choices and data.choices[1] and data.choices[1].message
    if msg then
      text = msg.content or ""
      -- Moonshot/Kimi reasoning models return the chain-of-thought here; captured
      -- so it can be replayed on the tool-call turn (build_openai_messages).
      if msg.reasoning_content and msg.reasoning_content ~= "" then
        reasoning = msg.reasoning_content
      end
      for _, tc in ipairs(msg.tool_calls or {}) do
        local fn = tc["function"] or {}
        local ok, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
        tools[#tools + 1] = { id = tc.id, name = fn.name, input = (ok and type(args) == "table") and args or {} }
      end
    end
  elseif provider == "gemini" then
    local cand = data.candidates and data.candidates[1]
    local parts = cand and cand.content and cand.content.parts or {}
    local i = 0
    for _, p in ipairs(parts) do
      if p.text then text = text .. p.text end
      if p.functionCall then
        i = i + 1
        -- Capture the thoughtSignature riding on this functionCall part so it can
        -- be echoed back verbatim on the next request (see build_gemini_contents).
        -- Omitting it on replay 400s with "missing a thought_signature". For
        -- parallel calls only the first part carries one; the rest stay nil.
        tools[#tools + 1] = {
          id = "call_" .. i .. "_" .. (p.functionCall.name or ""),
          name = p.functionCall.name,
          input = p.functionCall.args or {},
          thought_signature = p.thoughtSignature,
        }
      elseif p.thoughtSignature and p.thoughtSignature ~= "" then
        -- A signature on a non-functionCall (thinking/text) part. Kept so a
        -- pure-thinking turn can echo it back on its model turn (recommended to
        -- preserve reasoning continuity; not required to avoid the tool-call 400).
        gemini_sig = p.thoughtSignature
      end
    end
  elseif provider == "ollama" then
    local msg = data.message or {}
    text = msg.content or ""
    local i = 0
    for _, tc in ipairs(msg.tool_calls or {}) do
      local fn = tc["function"] or {}
      i = i + 1
      local input = fn.arguments
      if type(input) == "string" then
        local ok, parsed = pcall(vim.fn.json_decode, input)
        input = (ok and type(parsed) == "table") and parsed or {}
      end
      tools[#tools + 1] = { id = "call_" .. i .. "_" .. (fn.name or ""), name = fn.name, input = input or {} }
    end
  end
  return text, tools, thinking, gemini_sig, reasoning
end

-- ---- Streaming accumulation: update state per chunk, return text delta ------
-- state = { tool_blocks = { [index] = {id,name,json} }, tool_list = {},
--          think_blocks = { [index] = {type,thinking,signature} }, think_list = {} }
local function stream_update(provider, obj, state, emit, emit_thinking)
  if provider == "anthropic" then
    if obj.type == "content_block_start" and obj.content_block then
      if obj.content_block.type == "tool_use" then
        state.tool_blocks[obj.index] = { id = obj.content_block.id, name = obj.content_block.name, json = "" }
      elseif obj.content_block.type == "thinking" then
        state.think_blocks[obj.index] = { type = "thinking", thinking = "", signature = "" }
      elseif obj.content_block.type == "redacted_thinking" then
        state.think_blocks[obj.index] = { type = "redacted_thinking", data = obj.content_block.data or "" }
      end
    elseif obj.type == "content_block_delta" and obj.delta then
      if obj.delta.type == "text_delta" and obj.delta.text then
        emit(obj.delta.text)
      elseif obj.delta.type == "thinking_delta" and state.think_blocks[obj.index] then
        state.think_blocks[obj.index].thinking = state.think_blocks[obj.index].thinking .. (obj.delta.thinking or "")
        if emit_thinking then emit_thinking(obj.delta.thinking or "") end
      elseif obj.delta.type == "signature_delta" and state.think_blocks[obj.index] then
        state.think_blocks[obj.index].signature = (state.think_blocks[obj.index].signature or "") .. (obj.delta.signature or "")
      elseif obj.delta.type == "input_json_delta" and state.tool_blocks[obj.index] then
        state.tool_blocks[obj.index].json = state.tool_blocks[obj.index].json .. (obj.delta.partial_json or "")
      end
    elseif obj.type == "content_block_stop" then
      if state.tool_blocks[obj.index] then
        local b = state.tool_blocks[obj.index]
        local ok, input = pcall(vim.fn.json_decode, (b.json ~= "" and b.json) or "{}")
        state.tool_list[#state.tool_list + 1] = { id = b.id, name = b.name, input = (ok and type(input) == "table") and input or {} }
      elseif state.think_blocks[obj.index] then
        state.think_list[#state.think_list + 1] = state.think_blocks[obj.index]
      end
    end
  elseif provider == "openai" then
    local ch = obj.choices and obj.choices[1]
    local delta = ch and ch.delta
    if delta then
      -- Moonshot/Kimi reasoning models stream chain-of-thought on a separate
      -- delta.reasoning_content channel (before the answer's delta.content).
      -- Accumulate it for replay on a tool-call turn and surface it live as
      -- thinking. Plain OpenAI chat completions never send this field.
      if delta.reasoning_content and delta.reasoning_content ~= "" then
        state.reasoning = (state.reasoning or "") .. delta.reasoning_content
        emit_thinking(delta.reasoning_content)
      end
      if delta.content then emit(delta.content) end
      for _, tc in ipairs(delta.tool_calls or {}) do
        local idx = tc.index or 0
        state.tool_blocks[idx] = state.tool_blocks[idx] or { id = nil, name = nil, json = "" }
        local slot = state.tool_blocks[idx]
        if tc.id then slot.id = tc.id end
        local fn = tc["function"]
        if fn then
          if fn.name then slot.name = fn.name end
          if fn.arguments then slot.json = slot.json .. fn.arguments end
        end
      end
    end
  elseif provider == "gemini" then
    local cand = obj.candidates and obj.candidates[1]
    local parts = cand and cand.content and cand.content.parts or {}
    for _, p in ipairs(parts) do
      if p.text then emit(p.text) end
      if p.functionCall then
        state.tool_list[#state.tool_list + 1] = {
          id = "call_" .. (#state.tool_list + 1) .. "_" .. (p.functionCall.name or ""),
          name = p.functionCall.name,
          input = p.functionCall.args or {},
          thought_signature = p.thoughtSignature,
        }
      elseif p.thoughtSignature and p.thoughtSignature ~= "" then
        -- A streaming response may deliver the signature on a standalone part
        -- (empty-text) rather than on the functionCall part. Stash the first one
        -- as a fallback, grafted onto the first tool in finalize_stream_tools.
        state.gemini_pending_sig = state.gemini_pending_sig or p.thoughtSignature
      end
    end
  elseif provider == "ollama" then
    local msg = obj.message
    if msg then
      if msg.content and msg.content ~= "" then emit(msg.content) end
      for _, tc in ipairs(msg.tool_calls or {}) do
        local fn = tc["function"] or {}
        local input = fn.arguments
        if type(input) == "string" then
          local ok, parsed = pcall(vim.fn.json_decode, input)
          input = (ok and type(parsed) == "table") and parsed or {}
        end
        state.tool_list[#state.tool_list + 1] = { id = "call_" .. (#state.tool_list + 1) .. "_" .. (fn.name or ""), name = fn.name, input = input or {} }
      end
    end
  end
end

-- Collect OpenAI tool blocks (accumulated by index) into the final tool list.
local function finalize_stream_tools(provider, state)
  if provider == "openai" then
    local idxs = {}
    for k in pairs(state.tool_blocks) do idxs[#idxs + 1] = k end
    table.sort(idxs)
    for _, k in ipairs(idxs) do
      local b = state.tool_blocks[k]
      local ok, input = pcall(vim.fn.json_decode, (b.json ~= "" and b.json) or "{}")
      state.tool_list[#state.tool_list + 1] = { id = b.id, name = b.name, input = (ok and type(input) == "table") and input or {} }
    end
  elseif provider == "gemini" then
    -- If the signature streamed in on a standalone part rather than on the
    -- functionCall part, graft it onto the first tool call — the one Gemini
    -- requires to carry a thoughtSignature when the turn is replayed.
    if state.gemini_pending_sig and state.tool_list[1] and not state.tool_list[1].thought_signature then
      state.tool_list[1].thought_signature = state.gemini_pending_sig
    end
  end
  return state.tool_list
end

----------------------------------------------------------------------
-- API Sender (Internal)
----------------------------------------------------------------------

function M.send_prompt_internal(opts, callback)
  -- Terminal callback must fire EXACTLY once and ALWAYS: a request that errors
  -- (curl process failure, malformed stream, encode error) must still resolve so
  -- the UI spinner is stopped instead of hanging in "processing" forever. Every
  -- terminal path below goes through respond(); on_error/pcall guards cover the
  -- failure paths; the fire-once guard prevents a double callback (e.g. on_error
  -- AND completion both firing).
  local responded = false
  local function respond(...)
    if responded then return end
    responded = true
    callback(...)
  end

  local settings = config.load_settings()
  local model_raw = opts.model or settings.default_model
  local model, temperature, effort = get_model_and_temp_override(model_raw)
  local provider, wire_temp, clean_model = M.get_provider_details(model)
  -- Moonshot/Kimi speaks the OpenAI wire format; `wire` selects the message
  -- builder / streaming parser / response parser, while `provider` still selects
  -- the endpoint URL, auth header, and API key.
  local wire = wire_provider(provider)
  -- Gemini 3.x is tuned for temperature 1.0; other providers default to 0.7.
  local final_temp = temperature or (provider == "gemini" and 1.0 or wire_temp)
  local api_key = config.get_api_key(settings, provider)

  -- Construct endpoint URL
  local url
  if provider == "gemini" then
    url = "https://generativelanguage.googleapis.com/v1beta/models/" .. clean_model .. ":generateContent?key=" .. api_key
  elseif provider == "anthropic" then
    url = "https://api.anthropic.com/v1/messages"
  elseif provider == "openai" then
    url = "https://api.openai.com/v1/chat/completions"
  elseif provider == "moonshot" then
    url = "https://api.moonshot.ai/v1/chat/completions"
  else
    url = "http://localhost:11434/api/chat"
  end

  -- System prompt compilation. Order matters for prefix caching: stable content
  -- first (persona, static tool docs), semi-stable next (user prefs), and the
  -- most-likely-to-change content (project context) LAST.
  local system_parts = {}

  -- 1. Persona (stable within a session/agent)
  if opts.agent_prompt and opts.agent_prompt ~= "" then
    table.insert(system_parts, opts.agent_prompt)
  else
    table.insert(system_parts, "You are a helpful and expert AI coding assistant.")
  end

  -- 2. Tool instructions (fully static -> highest in the cacheable prefix)
  table.insert(system_parts, [[

## Machine Tools
You have native tool access to the user's machine via tool/function calls:
- `run_command` — run a shell command and get its stdout/stderr (git, tests, builds, ls, etc.)
- `read_file` — read a file (path relative to the project root, or absolute)
- `write_file` — create or overwrite a file with new content

Call these tools using your native tool-calling capability — do NOT print the calls as plain text or markup. You may request several tools in a single turn. Briefly tell the user what you intend to do before calling a tool. The user is asked to approve commands and writes (writes show a diff) unless auto-approve is enabled; file paths outside the project root always require manual approval.
]])

  -- 2b. Plan mode (toggled with /plan): require a plan before any mutation.
  if opts.plan_mode then
    table.insert(system_parts, [[

## Plan Mode is ON
Before using `run_command` or `write_file`, FIRST present a concise numbered plan describing what you will do and why, then stop and let the user approve. Only call those tools after the user has approved the plan. Using `read_file` and answering questions is allowed without a plan.
]])
  end

  -- 3. User preferences (stable across the session)
  if settings.user_context and #settings.user_context > 0 then
    table.insert(system_parts, "\n## User Preferences & Profile")
    for _, item in ipairs(settings.user_context) do
      table.insert(system_parts, string.format("- **%s**: %s", item.id, item.text))
    end
  end

  -- 3b. Project memory: durable facts the assistant saved in earlier sessions.
  local memory = config.read_memory()
  if memory and memory ~= "" then
    table.insert(system_parts, "\n## Project Memory (durable facts you saved earlier)\n" .. memory)
  end

  -- 4. Project context LAST (most volatile; mtime-invalidated upstream)
  local proj_context = config.get_project_context()
  if proj_context and proj_context ~= "" then
    table.insert(system_parts, "\n## Project Context Information\n" .. proj_context)
  end

  local system_prompt = table.concat(system_parts, "\n")
  local project_root = config.get_project_root()
  local processed_prompt = process_file_mentions(opts.prompt, project_root)

  if opts.selected_text and opts.selected_text ~= "" then
    processed_prompt = string.format("### Context: Selected Code\n```\n%s\n```\n\n### User Prompt\n%s", opts.selected_text, processed_prompt)
  end

  -- Re-attach the active file on every real user turn (not on tool-loop
  -- continuations) so the model always sees the current buffer, not just turn 1.
  -- It rides only on this turn's message and is not persisted into history.
  if opts.fresh_user_turn and opts.active_file and opts.active_file ~= "" and opts.active_file_content and opts.active_file_content ~= "" then
    local ext = opts.active_file:match("%.([^%.]+)$") or ""
    processed_prompt = string.format("### Context: Active File (%s)\n```%s\n%s\n```\n\n%s", opts.active_file, ext, opts.active_file_content, processed_prompt)
  end

  -- Optional semantic retrieval (RAG): append the most relevant project code
  -- chunks for this query to the USER turn (keeps the system prefix cacheable).
  -- Opt-in and best-effort: silently skipped if Ollama/index is unavailable.
  if settings.rag_enabled and opts.fresh_user_turn then
    local ok_rag, rag = pcall(require, "ai_assistant.rag")
    if ok_rag and rag.has_index() then
      local hits = rag.retrieve(opts.prompt, 6)
      if hits and #hits > 0 then
        local parts = { processed_prompt, "\n### Relevant Project Code (semantic retrieval):" }
        for _, h in ipairs(hits) do
          parts[#parts + 1] = string.format("\n-- %s (line %d) --\n```\n%s\n```", h.path, h.line, h.text)
        end
        processed_prompt = table.concat(parts, "\n")
      end
    end
  end

  -- Apply context budget truncation
  local budget = settings.context_token_budget or 100000
  local pruned_history = trim_history_to_budget(opts.history, budget, system_prompt, processed_prompt, opts)

  -- Build payload & headers. Native tools are attached for every provider; the
  -- neutral history (which may carry tool_calls/tool_results) is converted to
  -- each provider's wire format by the builders above. On a tool continuation
  -- there is no new user prompt (the last history turn carries tool results).
  local headers = { ["Content-Type"] = "application/json" }
  local payload = {}
  local append_user = not opts.is_tool_continuation

  if provider == "gemini" then
    local gen_config = { temperature = final_temp }
    if effort then
      gen_config.thinkingConfig = { thinkingLevel = effort }
    end
    payload = {
      contents = build_gemini_contents(pruned_history, processed_prompt, append_user),
      systemInstruction = { parts = { { text = system_prompt } } },
      generationConfig = gen_config,
      tools = gemini_tools(),
    }
  elseif provider == "openai" then
    headers["Authorization"] = "Bearer " .. api_key
    payload = {
      model = clean_model,
      messages = build_openai_messages(pruned_history, system_prompt, processed_prompt, append_user),
      tools = openai_tools(),
    }
    if openai_is_reasoning(clean_model) then
      payload.max_completion_tokens = 16384
      if effort then payload.reasoning_effort = effort end
    else
      payload.temperature = final_temp
    end
  elseif provider == "moonshot" then
    -- Moonshot (Kimi) — OpenAI Chat Completions compatible, reasoning always on.
    headers["Authorization"] = "Bearer " .. api_key
    payload = {
      model = clean_model,
      -- max_tokens caps reasoning_content + content COMBINED; keep it generous so
      -- the chain-of-thought doesn't crowd out the answer (docs default 32768).
      max_tokens = 32768,
      -- Thinking mode pins temperature to 1; any other value is rejected with
      -- "invalid temperature: only 1 is allowed for this model".
      temperature = 1,
      messages = build_openai_messages(pruned_history, system_prompt, processed_prompt, append_user, true),
      tools = openai_tools(),
    }
    -- The -low/-medium/-high picker suffix maps to reasoning_effort. Accepted
    -- values are minimal/low/medium/high; reasoning cannot be disabled this way.
    if effort then payload.reasoning_effort = effort end
  elseif provider == "anthropic" then
    headers["x-api-key"] = api_key
    headers["anthropic-version"] = "2023-06-01"
    payload = {
      model = clean_model,
      max_tokens = 8192,
      -- System as a content block with a prompt-cache breakpoint (stable prefix).
      system = { { type = "text", text = system_prompt, cache_control = { type = "ephemeral" } } },
      messages = build_anthropic_messages(pruned_history, processed_prompt, append_user),
      tools = anthropic_tools(),
    }
    if effort and anthropic_supports_effort(clean_model) then
      -- display="summarized" surfaces reasoning text (default "omitted" streams
      -- empty thinking text). Signatures arrive either way and are captured for
      -- replay across tool calls by build_anthropic_messages.
      payload.thinking = { type = "adaptive", display = "summarized" }
      payload.output_config = { effort = effort }
    end
    if not anthropic_rejects_sampling(clean_model) then
      payload.temperature = final_temp
    end
  elseif provider == "ollama" then
    payload = {
      model = clean_model,
      messages = build_ollama_messages(pruned_history, system_prompt, processed_prompt, append_user),
      tools = openai_tools(),
      stream = false,
      options = { temperature = final_temp },
    }
  end

  -- Compare/council fan-outs ask for plain answers, no tool execution.
  if opts.no_tools then payload.tools = nil end

  local curl = require("plenary.curl")

  -- Streaming path: emit live token deltas through opts.on_delta while still
  -- delivering the full accumulated text via callback, so tool-call parsing,
  -- history, and the orchestrator downstream are all unchanged.
  if opts.on_delta then
    local stream_url = url
    if provider == "gemini" then
      stream_url = url:gsub(":generateContent%?key=", ":streamGenerateContent?alt=sse&key=")
    else
      payload.stream = true
    end

    local started = false
    local acc = {}
    local sstate = { tool_blocks = {}, tool_list = {}, think_blocks = {}, think_list = {} }
    local function emit(text)
      if not text or text == "" then return end
      if not started then
        started = true
        if opts.on_response_start then opts.on_response_start() end
      end
      table.insert(acc, text)
      if opts.on_delta then opts.on_delta(text) end
    end
    local function emit_thinking(text)
      if not text or text == "" then return end
      if opts.on_thinking then opts.on_thinking(text) end
    end
    local function on_line(_, line)
      if not line or line == "" then return end
      local json_str = line
      if provider ~= "ollama" then
        local d = line:match("^data:%s?(.+)$")
        if not d or d == "[DONE]" then return end
        json_str = d
      end
      local ok, obj = pcall(vim.fn.json_decode, json_str)
      if not ok or type(obj) ~= "table" then return end
      -- A single malformed/unexpected chunk must never throw out of the stream
      -- handler (which would stall the request and leave the spinner spinning).
      pcall(stream_update, wire, obj, sstate, emit, emit_thinking)
    end

    -- Encode the body up front so an encode failure is reported gracefully
    -- instead of raising as an unhandled argument-evaluation error.
    local ok_body, body = pcall(vim.fn.json_encode, payload)
    if not ok_body then
      respond(false, "Failed to encode request: " .. tostring(body))
      return
    end
    local ok_post, job = pcall(curl.post, stream_url, {
      headers = headers,
      body = body,
      stream = vim.schedule_wrap(on_line),
      -- curl PROCESS failure (connection refused, DNS, timeout). Without this,
      -- plenary raises on a non-zero curl exit and the completion callback never
      -- runs — which is exactly what leaves the spinner stuck on a dead request.
      on_error = function(err)
        vim.schedule(function()
          local m = "Network error"
          if type(err) == "table" then
            m = m .. ": " .. (err.message or err.stderr or ("curl exit " .. tostring(err.exit or err.code)))
          elseif err then
            m = m .. ": " .. tostring(err)
          end
          respond(false, m)
        end)
      end,
      callback = function(response)
        vim.schedule(function()
          local ok_fin, err = pcall(function()
            local full = table.concat(acc)
            local tool_calls = finalize_stream_tools(wire, sstate)
            local thinking_blocks = sstate.think_list
            -- Standalone signature from a pure-thinking (non-functionCall) turn,
            -- only meaningful when no tool calls fired; consumed by M.send_prompt.
            local gemini_sig = sstate.gemini_pending_sig
            -- Moonshot/Kimi chain-of-thought accumulated across the stream; replayed
            -- on the tool-call turn (build_openai_messages). nil for other providers.
            local reasoning_content = sstate.reasoning
            if full ~= "" or (tool_calls and #tool_calls > 0) then
              respond(true, full, tool_calls, thinking_blocks, gemini_sig, reasoning_content)
              return
            end
            if response and response.status and response.status >= 200 and response.status < 300 then
              respond(true, "", {}, thinking_blocks, gemini_sig, reasoning_content)
              return
            end
            local emsg = "API Error"
            if response and response.status then
              emsg = emsg .. " (Status " .. response.status .. ")"
            end
            if response and response.body and response.body ~= "" then
              local okb, parsed = pcall(vim.fn.json_decode, response.body)
              if okb and type(parsed) == "table" and type(parsed.error) == "table" and parsed.error.message then
                emsg = emsg .. ": " .. parsed.error.message
              elseif okb and type(parsed) == "table" and type(parsed.error) == "string" then
                emsg = emsg .. ": " .. parsed.error
              else
                emsg = emsg .. ": " .. response.body:sub(1, 300)
              end
            end
            respond(false, emsg)
          end)
          -- Finalizing the stream (tool-call assembly, signature plumbing) must
          -- never strand the request: any error there still resolves the turn.
          if not ok_fin then
            respond(false, "Stream finalize error: " .. tostring(err))
          end
        end)
      end,
    })
    if not ok_post then
      respond(false, "Failed to start request: " .. tostring(job))
      return
    end
    if opts.on_job_started then opts.on_job_started(job) end
    return job
  end

  local ok_body, body = pcall(vim.fn.json_encode, payload)
  if not ok_body then
    respond(false, "Failed to encode request: " .. tostring(body))
    return
  end
  local ok_post, job = pcall(curl.post, url, {
    headers = headers,
    body = body,
    on_error = function(err)
      vim.schedule(function()
        local m = "Network error"
        if type(err) == "table" then
          m = m .. ": " .. (err.message or err.stderr or ("curl exit " .. tostring(err.exit or err.code)))
        elseif err then
          m = m .. ": " .. tostring(err)
        end
        respond(false, m)
      end)
    end,
    callback = function(response)
      vim.schedule(function()
        local ok_fin, err = pcall(function()
          if not response or not response.status or response.status < 200 or response.status >= 300 then
            local err_msg = "API Error"
            if response then
              if response.status == 0 then
                err_msg = err_msg .. " (Connection Failed/Timeout)"
              else
                local success_body, err_parsed = pcall(vim.fn.json_decode, response.body)
                if success_body and err_parsed then
                  if type(err_parsed.error) == "table" and err_parsed.error.message then
                    err_msg = err_msg .. ": " .. err_parsed.error.message
                  elseif type(err_parsed.error) == "string" then
                    err_msg = err_msg .. ": " .. err_parsed.error
                  elseif err_parsed.message then
                    err_msg = err_msg .. ": " .. err_parsed.message
                  else
                    err_msg = err_msg .. " (Status " .. response.status .. "): " .. (response.body or "")
                  end
                else
                  err_msg = err_msg .. " (Status " .. response.status .. "): " .. (response.body or "")
                end
              end
            else
              err_msg = err_msg .. " (No response from server)"
            end
            respond(false, err_msg)
            return
          end

          local ok, data = pcall(vim.fn.json_decode, response.body)
          if not ok or not data then
            respond(false, "JSON Parsing Error: " .. tostring(response.body or "empty body"))
            return
          end

          local response_text, tool_calls, thinking_blocks, gemini_sig, reasoning_content = parse_response_tools(wire, data)
          respond(true, response_text, tool_calls, thinking_blocks, gemini_sig, reasoning_content)
        end)
        if not ok_fin then
          respond(false, "Response parse error: " .. tostring(err))
        end
      end)
    end
  })
  if not ok_post then
    respond(false, "Failed to start request: " .. tostring(job))
    return
  end

  if opts.on_job_started then
    opts.on_job_started(job)
  end
  return job
end


----------------------------------------------------------------------
-- Main Send Prompt Router (With Async Tools & Deepcopy History)
----------------------------------------------------------------------

-- Trim a command/path to a short single-line label for the status header.
local function status_label(s, n)
  s = tostring(s or ""):gsub("%s+", " ")
  n = n or 48
  if #s > n then return s:sub(1, n - 1) .. "…" end
  return s
end

-- Notify the UI of the current agentic phase (running a command, reading a file,
-- delegating…). No-op when the caller didn't wire an on_status handler.
local function emit_status(opts, phase_key, detail)
  if opts and opts.on_status then opts.on_status(phase_key, detail) end
end

function M.send_prompt(opts, callback)
  local settings = config.load_settings()
  local active_agent = opts.agent or "default"
  local agent_prompt = ""
  local agent_model = opts.model

  if active_agent ~= "default" and settings.agents[active_agent] then
    agent_prompt = settings.agents[active_agent].system_prompt or ""
    if not agent_model then
      agent_model = settings.agents[active_agent].model
    end
  end

  opts.agent_prompt = agent_prompt
  opts.model = agent_model or settings.default_model

  -- Ensure we operate on a deepcopy of history to prevent reference mutation
  if not opts._history_cloned then
    opts.history = vim.deepcopy(opts.history or {})
    opts._history_cloned = true
  end

  M.send_prompt_internal(opts, function(success, response_text, tool_calls, thinking_blocks, gemini_sig, reasoning_content)
    if not success then
      callback(false, response_text, opts.history)
      return
    end

    -- Native tool calls: execute each (denylist + project-root + approval/diff),
    -- record the results, append the tool_use + tool_result turns to history, and
    -- continue so the model can use the outputs. Tools run sequentially because
    -- each may require async approval and async execution.
    if tool_calls and #tool_calls > 0 then
      if opts.notify_fn and not opts.on_delta and response_text and response_text ~= "" then
        opts.notify_fn(string.format("\n### AI Assistant (@%s)\n%s\n", active_agent, response_text))
      end

      local results = {}
      -- Forward declaration so process_impl can call the wrapped `process`.
      local process
      -- Guards the loop terminal so it resolves the turn exactly once, even if an
      -- error path also tries to finish it.
      local loop_done = false

      local function finish_tools()
        if loop_done then return end
        loop_done = true
        local ok_ft, ft_err = pcall(function()
          if not opts.is_tool_continuation then
            table.insert(opts.history, { role = "user", content = opts.prompt })
          end
          table.insert(opts.history, { role = "model", content = response_text, tool_calls = tool_calls, thinking_blocks = thinking_blocks, reasoning_content = reasoning_content })
          table.insert(opts.history, { role = "tool", tool_results = results })
          -- Tools done; the model now digests their output. Surface that gap so the
          -- header isn't frozen between tool execution and the next streamed token.
          emit_status(opts, "tools")
          local next_opts = vim.deepcopy(opts)
          next_opts.prompt = ""
          next_opts.is_tool_continuation = true
          next_opts.fresh_user_turn = false
          M.send_prompt(next_opts, callback)
        end)
        -- If kicking off the continuation itself fails, end the turn gracefully so
        -- the spinner stops rather than hanging on a half-finished tool round-trip.
        if not ok_ft then
          callback(false, "Failed to continue after tools: " .. tostring(ft_err), opts.history)
        end
      end

      local function process_impl(i)
        if i > #tool_calls then
          return finish_tools()
        end
        local tc = tool_calls[i]
        local tool_type, tool_arg = M.tool_call_to_exec(tc.name, tc.input)
        if not tool_type then
          table.insert(results, { id = tc.id, name = tc.name, output = "Error: unknown tool '" .. tostring(tc.name) .. "'" })
          return process(i + 1)
        end

        -- Memory writes go to our own data dir and always auto-run (no approval).
        if tool_type == "save_memory" then
          emit_status(opts, "remember", status_label(tool_arg, 40))
          if opts.notify_fn then
            opts.notify_fn(string.format("\n> **System**: Remembering: %s\n", tostring(tool_arg)))
          end
          M.execute_tool(tool_type, tool_arg, function(output)
            table.insert(results, { id = tc.id, name = tc.name, output = output })
            process(i + 1)
          end, opts)
          return
        end

        local details
        local write_diff
        if tool_type == "command" then
          details = "Run Command: `" .. tostring(tool_arg) .. "`"
          local denied, pattern = M.is_command_denied(tool_arg, settings)
          if denied then
            local reason = "Command matched blocked pattern: " .. pattern
            if opts.notify_fn then
              opts.notify_fn(string.format("\n> **System**: Tool execution BLOCKED.\n> **Reason**: %s\n", reason))
            end
            table.insert(results, { id = tc.id, name = tc.name, output = "Error: " .. reason })
            return process(i + 1)
          end
        elseif tool_type == "read_file" then
          details = "Read File: `" .. tostring(tool_arg) .. "`"
        elseif tool_type == "write_file" then
          -- Hand the model a correctable error instead of overwriting the file
          -- with empty content and falsely reporting success.
          if type(tool_arg.content) ~= "string" then
            table.insert(results, { id = tc.id, name = tc.name, output = "Error: write_file call missing required 'content' string." })
            return process(i + 1)
          end
          write_diff = M.compute_write_diff(tool_arg.path, tool_arg.content)
          details = string.format("Write File (%s): `%s`  (+%d/-%d)",
            write_diff.kind, tostring(tool_arg.path), write_diff.added, write_diff.removed)
        end

        local in_root = true
        if tool_type == "read_file" or tool_type == "write_file" then
          local target = (tool_type == "read_file") and tool_arg or tool_arg.path
          in_root = M.resolve_tool_path(target).in_root
        end

        local function run_and_record()
          -- Announce the in-flight tool so the header narrates the whole loop
          -- (covers both the auto-approved and the just-approved paths).
          if tool_type == "command" then
            emit_status(opts, "running", status_label(tool_arg))
          elseif tool_type == "read_file" then
            emit_status(opts, "reading", status_label(tool_arg))
          elseif tool_type == "write_file" then
            emit_status(opts, "writing_file", status_label(tool_arg.path))
          end
          M.execute_tool(tool_type, tool_arg, function(output)
            -- The full output always reaches the model via `results`; the chat
            -- only gets a compact, collapsible card so it doesn't flood.
            if opts.notify_fn then
              if tool_type == "write_file" then
                -- The diff card is rendered on the auto / review path; stay quiet.
              elseif tool_type == "read_file" then
                opts.notify_fn(fold_card(string.format("> 📄 read `%s` (%d bytes)", tostring(tool_arg), #(output or "")), output))
              else
                opts.notify_fn(fold_card(string.format("> ⚙ ran `%s`", tostring(tool_arg)), output))
              end
            end
            table.insert(results, { id = tc.id, name = tc.name, output = output })
            process(i + 1)
          end, opts)
        end

        -- write_file gates on the review/auto-write toggle (default = review);
        -- other tools gate on auto_approve_tools. Out-of-root ops never auto-run.
        local needs_confirm
        if tool_type == "write_file" then
          needs_confirm = not (opts.auto_write and in_root)
        else
          needs_confirm = not (settings.auto_approve_tools and in_root)
        end
        -- Plan mode forces confirmation for mutating tools regardless of auto-approve.
        if opts.plan_mode and (tool_type == "command" or tool_type == "write_file") then
          needs_confirm = true
        end

        if not needs_confirm then
          if opts.notify_fn then
            if tool_type == "write_file" and write_diff then
              opts.notify_fn(fold_card(string.format("> ✎ wrote `%s` (+%d/-%d)",
                tostring(tool_arg.path), write_diff.added, write_diff.removed),
                write_diff.diff ~= "" and write_diff.diff or "(no textual changes)"))
            else
              opts.notify_fn(string.format("\n> **System**: Auto-approved: **%s**\n", details))
            end
          end
          run_and_record()
        elseif opts.request_tool_fn then
          if not in_root and opts.notify_fn then
            opts.notify_fn("\n> **System**: Path is outside the project root; manual confirmation required.\n")
          end
          opts.request_tool_fn(tool_type, tool_arg, function()
            run_and_record()
          end, function()
            table.insert(results, { id = tc.id, name = tc.name, output = "User denied execution of this tool." })
            process(i + 1)
          end)
        else
          table.insert(results, { id = tc.id, name = tc.name, output = "Tool not executed (no approval handler available)." })
          process(i + 1)
        end
      end

      -- Wrap each step: an unexpected raise (building the diff, an emit, a UI
      -- callback) records an error result the model can see and still advances
      -- the loop to its terminal, instead of stalling with the spinner stuck.
      process = function(i)
        local ok_p, p_err = pcall(process_impl, i)
        if not ok_p then
          if opts.notify_fn then
            pcall(opts.notify_fn, "\n> **System**: Tool step error: " .. tostring(p_err) .. "\n")
          end
          local tc = tool_calls[i]
          table.insert(results, { id = tc and tc.id, name = (tc and tc.name) or "tool", output = "Error: tool step raised: " .. tostring(p_err) })
          finish_tools()
        end
      end

      process(1)
      return
    end

    -- No tool calls.
    if active_agent == "orchestrator" then
      M.handle_orchestration(response_text, opts, callback, 1)
    else
      if not opts.is_tool_continuation then
        table.insert(opts.history, { role = "user", content = opts.prompt })
      end
      -- Carry Gemini's pure-thinking-turn signature (nil for other providers) so
      -- build_gemini_contents can echo it back on the next turn.
      table.insert(opts.history, { role = "model", content = response_text, thought_signature = gemini_sig })
      callback(true, response_text, opts.history)
    end
  end)
end

----------------------------------------------------------------------
-- Orchestrator Handler
----------------------------------------------------------------------

function M.handle_orchestration(initial_response, original_opts, callback, depth)
  local settings = config.load_settings()
  depth = depth or 1

  if depth > 5 then
    if original_opts.notify_fn then
      original_opts.notify_fn("\n\n> **System**: Orchestration depth limit reached. Halting recursion.")
    end
    -- On a tool-loop continuation finish_tools() already recorded the real user
    -- turn (and original_opts.prompt is "" here), so don't insert it again.
    if not original_opts.is_tool_continuation then
      table.insert(original_opts.history, { role = "user", content = original_opts.prompt })
    end
    table.insert(original_opts.history, { role = "model", content = initial_response })
    callback(true, initial_response, original_opts.history)
    return
  end

  local agent_name, sub_prompt = initial_response:match("%[CALL_AGENT:%s*([%w_%-]+)%]%s*(.*)")
  if not agent_name or not sub_prompt or sub_prompt == "" then
    -- On a tool-loop continuation finish_tools() already recorded the real user
    -- turn (and original_opts.prompt is "" here), so don't insert it again.
    if not original_opts.is_tool_continuation then
      table.insert(original_opts.history, { role = "user", content = original_opts.prompt })
    end
    table.insert(original_opts.history, { role = "model", content = initial_response })
    callback(true, initial_response, original_opts.history)
    return
  end

  agent_name = agent_name:lower()
  if not settings.agents[agent_name] and agent_name ~= "default" then
    if original_opts.notify_fn then
      original_opts.notify_fn(string.format("\n\n> **System**: Agent `@%s` requested by orchestrator does not exist.", agent_name))
    end
    -- On a tool-loop continuation finish_tools() already recorded the real user
    -- turn (and original_opts.prompt is "" here), so don't insert it again.
    if not original_opts.is_tool_continuation then
      table.insert(original_opts.history, { role = "user", content = original_opts.prompt })
    end
    table.insert(original_opts.history, { role = "model", content = initial_response })
    callback(true, initial_response, original_opts.history)
    return
  end

  emit_status(original_opts, "delegating", "@" .. agent_name)
  if original_opts.notify_fn then
    if not original_opts.on_delta then
      original_opts.notify_fn(string.format("\n### AI Assistant (@orchestrator)\n%s\n", initial_response))
    end
    original_opts.notify_fn(string.format("\n\n> **Orchestrator**: Delegating task to **@%s**...\n> *Prompt: %s*\n", agent_name, sub_prompt))
  end

  local sub_agent_prompt = settings.agents[agent_name] and settings.agents[agent_name].system_prompt or ""
  -- Sub-agents use their own pinned model, else the cheap sub-agent default,
  -- so the expensive coordinator model isn't spent on exploratory delegation.
  local sub_agent_model = (settings.agents[agent_name] and settings.agents[agent_name].model)
    or settings.default_subagent_model or settings.default_model

  local sub_opts = {
    prompt = sub_prompt,
    history = {}, -- Sub-agents run with fresh context
    agent = agent_name,
    agent_prompt = sub_agent_prompt,
    model = sub_agent_model,
    selected_text = original_opts.selected_text,
    notify_fn = original_opts.notify_fn,
    request_tool_fn = original_opts.request_tool_fn,
    on_job_started = original_opts.on_job_started,
    on_status = original_opts.on_status,
  }

  M.send_prompt(sub_opts, function(sub_success, sub_response, _)
    if not sub_success then
      if original_opts.notify_fn then
        original_opts.notify_fn("\n\n> **System**: Sub-agent delegation failed: " .. sub_response)
      end
      callback(false, "Orchestration failed at @" .. agent_name .. " step.", original_opts.history)
      return
    end

    if original_opts.notify_fn then
      original_opts.notify_fn(string.format("\n### Response from @%s:\n%s\n", agent_name, sub_response))
    end

    local next_prompt = string.format("Agent @%s has responded to the task '%s' with:\n%s\n\nAnalyze this output and provide the next step or final integrated answer.", agent_name, sub_prompt, sub_response)
    
    -- On a tool-loop continuation finish_tools() already recorded the real user
    -- turn (and original_opts.prompt is "" here), so don't insert it again.
    if not original_opts.is_tool_continuation then
      table.insert(original_opts.history, { role = "user", content = original_opts.prompt })
    end
    table.insert(original_opts.history, { role = "model", content = initial_response })

    local orch_next_opts = {
      prompt = next_prompt,
      history = original_opts.history,
      agent = "orchestrator",
      agent_prompt = settings.agents.orchestrator.system_prompt,
      model = settings.agents.orchestrator.model or settings.default_model,
      selected_text = original_opts.selected_text,
      notify_fn = original_opts.notify_fn,
      request_tool_fn = original_opts.request_tool_fn,
      on_job_started = original_opts.on_job_started,
      on_delta = original_opts.on_delta,
      on_response_start = original_opts.on_response_start,
      on_status = original_opts.on_status,
    }

    M.send_prompt_internal(orch_next_opts, function(orch_success, orch_next_response)
      if not orch_success then
        callback(false, "Orchestrator failed: " .. orch_next_response, orch_next_opts.history)
        return
      end

      M.handle_orchestration(orch_next_response, orch_next_opts, callback, depth + 1)
    end)
  end)
end

----------------------------------------------------------------------
-- Council / Compare (multi-model fan-out)
----------------------------------------------------------------------

-- Fan one prompt out to several models in parallel (plain answers, no tools).
-- on_each(model, success, text) fires as each returns; on_done(results) fires
-- once all have completed. results[i] = { model, success, text }.
function M.run_compare(opts, models, on_each, on_done)
  local pending = #models
  if pending == 0 then
    if on_done then on_done({}) end
    return
  end
  local results = {}
  for idx, model in ipairs(models) do
    local sub = {
      prompt = opts.prompt,
      history = {},
      agent = "default",
      agent_prompt = "",
      model = model,
      fresh_user_turn = true,
      no_tools = true,
      selected_text = opts.selected_text,
    }
    M.send_prompt_internal(sub, function(success, text)
      results[idx] = { model = model, success = success, text = text }
      if on_each then on_each(model, success, text) end
      pending = pending - 1
      if pending == 0 and on_done then on_done(results) end
    end)
  end
end

-- Council = compare + a judge model that synthesizes the single best answer.
function M.run_council(opts, models, judge_model, on_each, on_done)
  M.run_compare(opts, models, on_each, function(results)
    local parts = {
      "You are an expert judge. The user asked:\n\n" .. (opts.prompt or "") ..
      "\n\nBelow are candidate answers from different models. Produce the single best answer: correct any errors, and combine the strongest parts. Answer directly — do not mention the candidates, the models, or that you are judging.\n",
    }
    for _, r in ipairs(results) do
      parts[#parts + 1] = string.format("\n--- Candidate (%s) ---\n%s", r.model, (r.text and r.text ~= "") and r.text or "(no answer)")
    end
    local judge_opts = {
      prompt = table.concat(parts, "\n"),
      history = {},
      agent = "default",
      agent_prompt = "",
      model = judge_model,
      fresh_user_turn = true,
      no_tools = true,
    }
    M.send_prompt_internal(judge_opts, function(success, text)
      if on_done then on_done(text, results) end
    end)
  end)
end

return M
