local M = {}
local config = require("ai_assistant.config")
local api = require("ai_assistant.api")

local session = nil
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Live activity indicator state. A single timer (see the activity_* helpers
-- below) stays running for the whole request and animates the CURRENT phase, so
-- the header never looks frozen while work is happening. `phase` is one of the
-- PHASES presets; `detail` is an optional live string (reasoning size, streamed
-- length, file/command in flight).
local activity = { timer = nil, frame_idx = 1, start_ns = nil, header = nil, phase = nil, detail = nil }

-- Friendly status phases: a small icon + label, with a fallback hint shown when
-- there's no live detail. Picked by key from both ui call sites and api.lua's
-- on_status events, so the header always says what the assistant is actually
-- doing rather than a single opaque "Streaming".
local PHASES = {
  thinking     = { icon = "🧠", label = "Thinking",           hint = "waiting for the model to respond" },
  reasoning    = { icon = "🧠", label = "Reasoning",          hint = "the model is working through the problem" },
  writing      = { icon = "✍",  label = "Writing reply",      hint = "streaming the answer" },
  working      = { icon = "⟳",  label = "Working",            hint = nil },
  tools        = { icon = "⟳",  label = "Processing results", hint = "handing tool output back to the model" },
  running      = { icon = "⚙",  label = "Running command",    hint = nil },
  reading      = { icon = "📄", label = "Reading file",       hint = nil },
  writing_file = { icon = "✎",  label = "Writing file",       hint = nil },
  remember     = { icon = "💾", label = "Saving memory",      hint = nil },
  delegating   = { icon = "↪",  label = "Delegating",         hint = nil },
}

-- Foldtext for the collapsible "cards" (tool output, diffs, reasoning). Shows the
-- summary line with the open marker stripped, plus a hint and a line count.
function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart) or ""
  line = line:gsub("%s*" .. vim.pesc(api.FOLD_OPEN) .. "%s*$", "")
  local n = vim.v.foldend - vim.v.foldstart - 1
  if n < 0 then n = 0 end
  return string.format("%s  ⏷ %d line%s — za", line, n, n == 1 and "" or "s")
end

-- Make the chat-history window render fold-marker cards collapsed-by-default and
-- conceal the raw markers when a card is expanded.
local function setup_history_folds(win, bufnr)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      vim.wo[win].foldmethod = "marker"
      vim.wo[win].foldmarker = api.FOLD_OPEN .. "," .. api.FOLD_CLOSE
      vim.wo[win].foldtext = "v:lua.require'ai_assistant.ui'.foldtext()"
      vim.wo[win].foldenable = true
      vim.wo[win].foldlevel = 0      -- cards start collapsed
      vim.wo[win].fillchars = "fold: "
      vim.wo[win].conceallevel = 2
      vim.wo[win].concealcursor = "nvic"
    end)
    pcall(vim.api.nvim_win_call, win, function()
      -- Hide the raw markers when a card is expanded (foldtext handles the folded view).
      vim.fn.matchadd("Conceal", api.FOLD_OPEN, 10, -1, { conceal = "" })
      vim.fn.matchadd("Conceal", api.FOLD_CLOSE, 10, -1, { conceal = "" })
    end)
  end
end

local function update_header(header, session_data, status_text)
  if not header or not header.bufnr or not vim.api.nvim_buf_is_valid(header.bufnr) then
    return
  end

  local status = status_text or (session_data.is_thinking and "🧠 Thinking" or (session_data.waiting_for_tool and "⏳ Waiting for your approval" or "Ready"))
  
  -- Resolve active file name
  local active_file_disp = "None"
  local active_file_size = 0
  if session_data.active_file and session_data.active_file ~= "" then
    active_file_disp = session_data.active_file
    if session_data.active_file_content then
      active_file_size = #session_data.active_file_content
    end
  end

  -- Resolve visual selection status
  local has_selection = (session_data.selected_text and session_data.selected_text ~= "") and string.format("Yes (%d chars)", #session_data.selected_text) or "No"

  -- Count exactly the files get_project_context actually loads (single source
  -- of truth), so the header never disagrees with what is sent to the model.
  local context_files_count = #config.list_context_files()

  -- Calculate estimated token usage
  local total_chars = 0
  local settings = config.load_settings()
  local system_parts_len = 0
  local active_agent = session_data.agent or "default"
  if active_agent ~= "default" and settings.agents[active_agent] then
    system_parts_len = system_parts_len + #(settings.agents[active_agent].system_prompt or "")
  else
    system_parts_len = system_parts_len + #("You are a helpful and expert AI coding assistant.")
  end
  if settings.user_context then
    for _, item in ipairs(settings.user_context) do
      system_parts_len = system_parts_len + #item.id + #item.text + 20
    end
  end
  local proj_context = config.get_project_context()
  system_parts_len = system_parts_len + #proj_context
  
  total_chars = total_chars + system_parts_len

  -- History characters (including tool_use inputs and tool_result outputs, which
  -- live outside msg.content and are often the bulk of an agentic conversation)
  local history_chars = 0
  for _, msg in ipairs(session_data.history_data or {}) do
    history_chars = history_chars + #(msg.content or "")
    if msg.tool_results then
      for _, r in ipairs(msg.tool_results) do
        history_chars = history_chars + #(r.output or "")
      end
    end
    if msg.tool_calls then
      for _, c in ipairs(msg.tool_calls) do
        local ok, enc = pcall(vim.fn.json_encode, c.input or {})
        history_chars = history_chars + #(ok and enc or "")
      end
    end
  end
  total_chars = total_chars + history_chars

  -- Selection characters
  if session_data.selected_text then
    total_chars = total_chars + #session_data.selected_text
  end

  -- Active file characters
  if #(session_data.history_data or {}) == 0 then
    total_chars = total_chars + active_file_size
  end

  local est_tokens = math.ceil(total_chars / 4)
  local budget = settings.context_token_budget or 100000

  -- Format the lines
  local line1 = string.format(" Model: %s | Agent: @%s | Status: %s", session_data.model, session_data.agent, status)
  local line2 = string.format(" Context: [Project Files: %d] [Active File: %s (%s)] [Selection: %s]", 
    context_files_count, active_file_disp, active_file_size > 0 and string.format("%.1fKB", active_file_size/1024) or "0B", has_selection)
  
  local usage_str = ""
  if total_chars < 1000 then
    usage_str = string.format("%d chars (~%d tokens)", total_chars, est_tokens)
  else
    usage_str = string.format("%.1fK chars (~%.1fK tokens)", total_chars/1000, est_tokens/1000)
  end
  
  local budget_str = string.format("%dK", math.floor(budget / 1000))
  local line3 = string.format(" Usage: %s / %s tokens | Messages: %d", usage_str, budget_str, #(session_data.history_data or {}))
  if est_tokens > budget then
    line3 = line3 .. " [Trimming Active]"
  end

  vim.api.nvim_buf_set_lines(header.bufnr, 0, -1, false, { line1, line2, line3 })
end

-- ── Activity indicator ──────────────────────────────────────────────────────
-- One timer, always animated while a request is in flight. Call sites set the
-- current phase (activity_begin / activity_phase) or just refresh the live
-- detail cheaply (activity_note, used on every token); the timer renders the
-- animated frame + elapsed clock so it is always obvious the assistant is alive.

local function fmt_size(n)
  if n < 1000 then return string.format("%d chars", n) end
  return string.format("%.1fk chars", n / 1000)
end

local function fmt_elapsed(ns)
  local s = math.floor(ns / 1e9)
  if s < 60 then return s .. "s" end
  return string.format("%dm%02ds", math.floor(s / 60), s % 60)
end

-- Compose the friendly status string for the current phase + live detail + clock.
local function activity_status_text()
  local ph = activity.phase or PHASES.thinking
  local label = (ph.icon ~= "" and (ph.icon .. " ") or "") .. ph.label
  local detail = activity.detail
  if (not detail or detail == "") and ph.hint then detail = ph.hint end
  local status = spinner_frames[activity.frame_idx] .. "  " .. label
  if detail and detail ~= "" then status = status .. " — " .. detail end
  if activity.start_ns then
    status = status .. "  · " .. fmt_elapsed(vim.loop.hrtime() - activity.start_ns)
  end
  return status
end

-- Render the animated status. Runs up to ~8×/s, so it rewrites ONLY the status
-- line (line 1) — the context/usage lines don't change mid-request, and going
-- through update_header would re-read settings from disk and recompute token
-- estimates on every frame. The full 3-line header is refreshed by update_header
-- at the start/end of a turn instead.
local function activity_render()
  local h = activity.header
  if not (h and h.bufnr and vim.api.nvim_buf_is_valid(h.bufnr)) then return end
  local status = activity_status_text()
  if session then
    local line1 = string.format(" Model: %s | Agent: @%s | Status: %s", session.model, session.agent, status)
    pcall(vim.api.nvim_buf_set_lines, h.bufnr, 0, 1, false, { line1 })
  else
    pcall(vim.api.nvim_buf_set_lines, h.bufnr, 0, -1, false, { " Status: " .. status })
  end
end

-- Cheap update used on hot paths (every token): swap phase/detail without an
-- immediate redraw — the running timer picks it up within a frame.
local function activity_note(phase_key, detail)
  if phase_key and PHASES[phase_key] then activity.phase = PHASES[phase_key] end
  if detail ~= nil then activity.detail = detail end
end

local function activity_ensure_timer()
  if activity.timer then return end
  activity.timer = vim.loop.new_timer()
  activity.timer:start(0, 120, vim.schedule_wrap(function()
    activity.frame_idx = (activity.frame_idx % #spinner_frames) + 1
    activity_render()
  end))
end

-- Transition to a new phase with instant feedback (used for infrequent, visible
-- state changes: answer starts streaming, a tool starts running, etc.).
local function activity_phase(phase_key, detail)
  activity_note(phase_key, detail)
  activity_ensure_timer()
  activity_render()
end

-- Begin a fresh activity span: reset the elapsed clock and start animating.
local function activity_begin(header, phase_key)
  activity.header = header
  activity.frame_idx = 1
  activity.detail = nil
  activity.start_ns = vim.loop.hrtime()
  activity.phase = PHASES[phase_key] or PHASES.thinking
  activity_ensure_timer()
  activity_render()
end

-- Settle into a static terminal line (Ready / Error / Cancelled / awaiting the
-- user) and stop the animation — the only points where the spinner should rest.
local function activity_stop(header, final_text)
  if activity.timer then
    activity.timer:stop()
    activity.timer:close()
    activity.timer = nil
  end
  activity.start_ns = nil
  activity.detail = nil
  activity.phase = nil
  local h = header or activity.header
  if not (h and h.bufnr and vim.api.nvim_buf_is_valid(h.bufnr)) then return end
  if session then
    update_header(h, session, final_text or "Ready")
  else
    vim.api.nvim_buf_set_lines(h.bufnr, 0, -1, false, { " Status: " .. (final_text or "Ready") })
  end
end

local function append_to_history(history_popup, text)
  if not history_popup.bufnr or not vim.api.nvim_buf_is_valid(history_popup.bufnr) then
    return
  end
  
  vim.bo[history_popup.bufnr].modifiable = true
  
  local lines = vim.split(text, "\n")
  local line_count = vim.api.nvim_buf_line_count(history_popup.bufnr)
  
  if line_count == 1 and vim.api.nvim_buf_get_lines(history_popup.bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(history_popup.bufnr, 0, 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(history_popup.bufnr, -1, -1, false, lines)
  end
  
  vim.bo[history_popup.bufnr].modifiable = false

  -- Auto-scroll to the bottom of the window (scheduled to avoid treesitter/redraw issues)
  if history_popup.winid and vim.api.nvim_win_is_valid(history_popup.winid) then
    vim.schedule(function()
      if history_popup.winid and vim.api.nvim_win_is_valid(history_popup.winid) then
        local new_line_count = vim.api.nvim_buf_line_count(history_popup.bufnr)
        pcall(vim.api.nvim_win_set_cursor, history_popup.winid, { new_line_count, 0 })
      end
    end)
  end
end

-- Append a streaming chunk, continuing the CURRENT last line (so tokens flow
-- inline rather than landing one-per-line like append_to_history does).
local function stream_append(history_popup, chunk)
  if not history_popup.bufnr or not vim.api.nvim_buf_is_valid(history_popup.bufnr) then
    return
  end
  vim.bo[history_popup.bufnr].modifiable = true
  local last = vim.api.nvim_buf_line_count(history_popup.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(history_popup.bufnr, last - 1, last, false)[1] or ""
  local parts = vim.split(chunk, "\n", { plain = true })
  parts[1] = last_line .. parts[1]
  vim.api.nvim_buf_set_lines(history_popup.bufnr, last - 1, last, false, parts)
  vim.bo[history_popup.bufnr].modifiable = false
  if history_popup.winid and vim.api.nvim_win_is_valid(history_popup.winid) then
    local nl = vim.api.nvim_buf_line_count(history_popup.bufnr)
    pcall(vim.api.nvim_win_set_cursor, history_popup.winid, { nl, 0 })
  end
end

-- Append a collapsible card: a one-line `summary` over a folded `body`.
local function append_fold(history_popup, summary, body)
  if body == nil or body == "" then
    append_to_history(history_popup, "\n" .. summary .. "\n")
  else
    append_to_history(history_popup, "\n" .. summary .. " " .. api.FOLD_OPEN .. "\n" .. body .. "\n" .. api.FOLD_CLOSE .. "\n")
  end
end

-- Open an fzf-lua picker over the project files and insert the chosen path as
-- an @mention into the input buffer at the cursor. `prefix` is prepended to the
-- chosen path (default "@"); pass "" when the caller already inserted the "@".
local function open_file_picker(input, root, prefix)
  prefix = prefix or "@"
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("AI Assistant: fzf-lua not available for @ file picker.", vim.log.levels.WARN)
    return false
  end
  fzf.files({
    cwd = root,
    prompt = "@file> ",
    file_icons = false,
    git_icons = false,
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local path = (selected[1] or ""):gsub("^%s+", "")
        vim.schedule(function()
          if input.winid and vim.api.nvim_win_is_valid(input.winid) then
            vim.fn.win_gotoid(input.winid)
            vim.api.nvim_put({ prefix .. path .. " " }, "c", true, true)
            vim.cmd("startinsert")
          end
        end)
      end,
    },
  })
  return true
end

function M.cancel_active_request()
  if session and session.active_job then
    if type(session.active_job) == "table" then
      if type(session.active_job.shutdown) == "function" then
        pcall(session.active_job.shutdown, session.active_job)
      elseif type(session.active_job.kill) == "function" then
        pcall(session.active_job.kill, session.active_job, 9)
      end
    end
    session.active_job = nil
  end
  if session then
    -- Invalidate all in-flight callbacks for this turn so a response that already
    -- left the wire (or arrives before shutdown lands) cannot re-arm the spinner,
    -- append to the transcript, or mount a stale diff after "■ Cancelled".
    session.gen = (session.gen or 0) + 1
    -- A tool approval pending when we cancel must not be resumable afterwards.
    session.waiting_for_tool = nil
    session.is_thinking = false
    activity_stop(session.header, "■ Cancelled")
    append_to_history(session.history, "\n> **System**: Request cancelled by user.\n")
    update_header(session.header, session, "■ Cancelled")
  end
end

function M.select_model(callback, allow_back)
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local api = require("ai_assistant.api")

  vim.notify("AI Assistant: Fetching available models...", vim.log.levels.INFO)

  api.fetch_available_models(function(models)
    local lines = {}
    if allow_back then
      table.insert(lines, Menu.item("< Back to Settings", { id = "back" }))
      table.insert(lines, Menu.separator("Models"))
    end

    if models and #models > 0 then
      for _, m in ipairs(models) do
        table.insert(lines, Menu.item(m.text, { id = m.id }))
      end
    else
      -- Fallback presets built from the single source of truth (config.MODELS),
      -- so this list never drifts to retired model IDs.
      local presets = {}
      for _, prov in ipairs({ "anthropic", "gemini", "openai", "moonshot" }) do
        for _, m in ipairs((config.MODELS or {})[prov] or {}) do
          table.insert(presets, { text = m, id = m })
        end
      end
      local flagship = (config.MODELS.anthropic or {})[1]
      if flagship then
        table.insert(presets, { text = flagship .. " (High Effort)", id = flagship .. "-high" })
      end
      table.insert(presets, { text = "ollama (Local)", id = "ollama" })
      for _, m in ipairs(presets) do
        table.insert(lines, Menu.item(m.text, { id = m.id }))
      end
    end

    local menu = Menu({
      position = "50%",
      size = { width = 45, height = math.min(15, #lines + 2) },
      border = {
        style = "rounded",
        text = { top = " Select Model ", top_align = "center" }
      },
      buf_options = { modifiable = true, readonly = false },
      win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
    }, {
      lines = lines,
      on_submit = function(item)
        -- A separator/empty line has no .id; ignore it so we never set a nil model.
        if not item or item.id == nil then return end
        if item.id == "back" then
          M.manage_context()
        else
          callback(item.id)
        end
      end
    })

    menu:mount()
    menu:on(event.BufLeave, function()
      menu:unmount()
    end)
  end)
end

function M.select_agent(callback, allow_back)
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local settings = config.load_settings()

  local lines = {}
  if allow_back then
    table.insert(lines, Menu.item("< Back to Settings", { id = "back" }))
    table.insert(lines, Menu.separator("Agents"))
  end

  table.insert(lines, Menu.item("default", { id = "default" }))
  for name, _ in pairs(settings.agents) do
    table.insert(lines, Menu.item("@" .. name, { id = name }))
  end

  local menu = Menu({
    position = "50%",
    size = { width = 45, height = math.min(10, #lines + 2) },
    border = {
      style = "rounded",
      text = { top = " Select Agent ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = lines,
    on_submit = function(item)
      if not item or item.id == nil then return end
      if item.id == "back" then
        M.manage_context()
      else
        callback(item.id)
      end
    end
  })

  menu:mount()
  menu:on(event.BufLeave, function()
    menu:unmount()
  end)
end

local function view_user_context()
  local settings = config.load_settings()
  local Popup = require("nui.popup")
  
  local view_popup = Popup({
    position = "50%",
    size = { width = 65, height = 15 },
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = { top = " Active User Context Items (Press 'q' to go back) ", top_align = "center" }
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  })
  
  view_popup:mount()
  -- Unmount if focus leaves by any route (e.g. <C-w>w), not only the 'q' map,
  -- or the float + its buffer leak.
  view_popup:on(require("nui.utils.autocmd").event.BufLeave, function() view_popup:unmount() end)

  local lines = {}
  for _, item in ipairs(settings.user_context) do
    table.insert(lines, "ID: " .. item.id)
    table.insert(lines, "Content: " .. item.text)
    table.insert(lines, string.rep("-", 45))
  end
  if #lines == 0 then
    table.insert(lines, "No context items saved yet.")
  end
  
  vim.api.nvim_buf_set_lines(view_popup.bufnr, 0, -1, false, lines)
  
  view_popup:map("n", "q", function()
    view_popup:unmount()
    M.manage_context()
  end)
end

local function configure_api_keys()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event

  local menu = Menu({
    position = "50%",
    size = { width = 45, height = 8 },
    border = {
      style = "rounded",
      text = { top = " Select Provider ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = {
      Menu.item("< Back to Settings", { id = "back" }),
      Menu.separator("Providers"),
      Menu.item("Gemini", { id = "gemini" }),
      Menu.item("Anthropic (Claude)", { id = "anthropic" }),
      Menu.item("OpenAI", { id = "openai" }),
      Menu.item("Moonshot (Kimi)", { id = "moonshot" }),
      Menu.item("Ollama (Local)", { id = "ollama" })
    },
    on_submit = function(item)
      if item.id == "back" then
        M.manage_context()
        return
      end
      local key = vim.fn.inputsecret(string.format("Enter API key for %s (masked input): ", item.text))
      if key ~= "" then
        local settings = config.load_settings()
        settings.api_keys[item.id] = key
        config.save_settings(settings)
        vim.notify(string.format("AI Assistant: API Key saved for %s!", item.text), vim.log.levels.INFO)
      else
        vim.notify("AI Assistant: Operation cancelled or empty key provided.", vim.log.levels.WARN)
      end
      M.manage_context()
    end
  })

  menu:mount()
  menu:on(event.BufLeave, function()
    menu:unmount()
  end)
end

local function add_context_item()
  local id = vim.fn.input("Enter context ID (e.g. coding_style): ")
  if id == "" then
    M.manage_context()
    return
  end
  id = id:lower():gsub("%s+", "_")
  local text = vim.fn.input("Enter context text: ")
  if text == "" then
    M.manage_context()
    return
  end

  local settings = config.load_settings()
  local exists = false
  for _, item in ipairs(settings.user_context) do
    if item.id == id then
      item.text = text
      exists = true
      break
    end
  end
  if not exists then
    table.insert(settings.user_context, { id = id, text = text })
  end
  config.save_settings(settings)
  vim.notify("AI Assistant: Context item saved!", vim.log.levels.INFO)
  M.manage_context()
end

local function del_context_item()
  local settings = config.load_settings()
  if #settings.user_context == 0 then
    vim.notify("AI Assistant: No user context items to delete.", vim.log.levels.WARN)
    M.manage_context()
    return
  end

  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local lines = {
    Menu.item("< Back to Settings", { id = "back" }),
    Menu.separator("Context Items")
  }
  for _, item in ipairs(settings.user_context) do
    table.insert(lines, Menu.item(item.id, { id = item.id }))
  end

  local menu = Menu({
    position = "50%",
    size = { width = 45, height = math.min(10, #lines + 2) },
    border = {
      style = "rounded",
      text = { top = " Select Context to Delete ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = lines,
    on_submit = function(item)
      if item.id == "back" then
        M.manage_context()
        return
      end
      local new_ctx = {}
      for _, ctx in ipairs(settings.user_context) do
        if ctx.id ~= item.id then
          table.insert(new_ctx, ctx)
        end
      end
      settings.user_context = new_ctx
      config.save_settings(settings)
      vim.notify(string.format("AI Assistant: Deleted context item '%s'!", item.id), vim.log.levels.INFO)
      M.manage_context()
    end
  })

  menu:mount()
  menu:on(event.BufLeave, function()
    menu:unmount()
  end)
end

local function manage_denylist()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event

  local menu = Menu({
    position = "50%",
    size = { width = 45, height = 7 },
    border = {
      style = "rounded",
      text = { top = " Command Denylist ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = {
      Menu.item("< Back to Settings", { act = "back" }),
      Menu.separator("Actions"),
      Menu.item("1. Add Pattern", { act = "add" }),
      Menu.item("2. Delete Pattern", { act = "del" }),
      Menu.item("3. List Patterns", { act = "list" })
    },
    on_submit = function(item)
      if item.act == "back" then
        M.manage_context()
      elseif item.act == "add" then
        local pat = vim.fn.input("Enter Lua pattern to block: ")
        if pat == "" then
          M.manage_context()
          return
        end
        local settings = config.load_settings()
        table.insert(settings.command_denylist, pat)
        config.save_settings(settings)
        vim.notify(string.format("AI Assistant: Pattern '%s' added to denylist!", pat), vim.log.levels.INFO)
        M.manage_context()
      elseif item.act == "del" then
        local settings = config.load_settings()
        local lines = {
          Menu.item("< Back to Settings", { id = "back" }),
          Menu.separator("Block Patterns")
        }
        for idx, pat in ipairs(settings.command_denylist) do
          table.insert(lines, Menu.item(pat, { id = idx }))
        end
        if #lines <= 2 then
          vim.notify("AI Assistant: Denylist is empty.", vim.log.levels.WARN)
          M.manage_context()
          return
        end

        local del_menu = Menu({
          position = "50%",
          size = { width = 45, height = math.min(10, #lines + 2) },
          border = {
            style = "rounded",
            text = { top = " Select Pattern to Delete ", top_align = "center" }
          },
          buf_options = { modifiable = true, readonly = false },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
        }, {
          lines = lines,
          on_submit = function(del_item)
            if del_item.id == "back" then
              M.manage_context()
              return
            end
            table.remove(settings.command_denylist, del_item.id)
            config.save_settings(settings)
            vim.notify("AI Assistant: Pattern removed from denylist.", vim.log.levels.INFO)
            M.manage_context()
          end
        })
        del_menu:mount()
        del_menu:on(event.BufLeave, function() del_menu:unmount() end)
      elseif item.act == "list" then
        local settings = config.load_settings()
        local Popup = require("nui.popup")
        local list_popup = Popup({
          position = "50%",
          size = { width = 72, height = 18 },
          enter = true,
          focusable = true,
          border = {
            style = "rounded",
            text = { top = " Command Denylist (Press 'q' to go back) ", top_align = "center" }
          },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
        })
        list_popup:mount()
        list_popup:on(event.BufLeave, function() list_popup:unmount() end)

        local pat_lines = {
          " Command Denylist",
          " ================",
          ""
        }
        for _, pat in ipairs(settings.command_denylist) do
          table.insert(pat_lines, "- " .. pat)
        end
        if #settings.command_denylist == 0 then
          table.insert(pat_lines, "Denylist is empty.")
        end
        
        vim.api.nvim_buf_set_lines(list_popup.bufnr, 0, -1, false, pat_lines)
        list_popup:map("n", "q", function()
          list_popup:unmount()
          manage_denylist()
        end)
      end
    end
  })

  menu:mount()
  menu:on(event.BufLeave, function() menu:unmount() end)
end

local function show_help_cheat_sheet()
  local Popup = require("nui.popup")
  local help_popup = Popup({
    position = "50%",
    size = { width = 72, height = 22 },
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = { top = " AI Assistant Help & Keymaps (Press 'q' to go back) ", top_align = "center" }
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  })
  help_popup:mount()
  help_popup:on(require("nui.utils.autocmd").event.BufLeave, function() help_popup:unmount() end)

  local lines = {
    " Neovim AI Assistant Cheat Sheet",
    " ==============================",
    "",
    " MAPPINGS (Normal Mode):",
    "   <leader>cc  - Toggle Chat Popup Window (also works in Visual mode)",
    "   <leader>cx  - Open Context and settings management menu",
    "   <leader>cp  - Initialize project-local context directory (.ai_context/)",
    "",
    " CHAT WINDOW KEYMAPS:",
    "   Ctrl-S / CR - Send the prompt",
    "   Esc / Ctrl-c- Cancel request if active, otherwise close chat",
    "   Ctrl-X      - Open Context and settings management menu directly",
    "   Tab         - Open the Model Selector menu",
    "   Ctrl-A      - Open the Agent Selector menu",
    "   za          - Toggle a collapsed card (tool output / diff / reasoning)",
    "",
    " SLASH COMMANDS (type in the input):",
    "   /model /agent /preset   - switch model / agent / saved preset",
    "   /diff [auto|review]     - toggle whether file writes apply automatically",
    "   /plan                   - require a plan before writes/commands",
    "   /compare /council <q>   - fan a question out to several models",
    "   /clear /sessions /context /help /quit",
    "",
    " SMART CONTEXT TAGS:",
    "   @filename   - fuzzy-match a project file and attach its contents",
    "   @agent_name - route the query to a custom agent (e.g. @refactor)",
    "",
    " MACHINE TOOLS (native tool-calling):",
    "   The assistant runs run_command / read_file / write_file itself.",
    "   - Writes default to REVIEW: a diff opens — press 'a' to accept,",
    "     'r' to reject (or type y/n). '/diff auto' applies writes silently.",
    "   - Commands/out-of-root reads ask for y/n unless auto-approve is on.",
    "   - Tool output, diffs and reasoning collapse into cards (za to expand).",
    ""
  }

  vim.api.nvim_buf_set_lines(help_popup.bufnr, 0, -1, false, lines)
  help_popup:map("n", "q", function()
    help_popup:unmount()
    M.manage_context()
  end)
end

local view_previous_sessions -- forward declare

local function show_session_actions(session_item)
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  
  local action_menu = Menu({
    position = "50%",
    size = { width = 45, height = 6 },
    border = {
      style = "rounded",
      text = { top = " Action: " .. session_item.id:gsub("^chat_", "") .. " ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = {
      Menu.item("< Back to Saved Chats", { act = "back" }),
      Menu.item("1. Resume Chat Session", { act = "resume" }),
      Menu.item("2. Delete Chat Session", { act = "delete" })
    },
    on_submit = function(action_item)
      if action_item.act == "back" then
        view_previous_sessions()
      elseif action_item.act == "resume" then
        local history_data = config.load_chat_session(session_item.id)
        if history_data then
          M.toggle_chat(nil, history_data, session_item.id)
        else
          vim.notify("AI Assistant: Failed to load session.", vim.log.levels.ERROR)
          view_previous_sessions()
        end
      elseif action_item.act == "delete" then
        local confirm = vim.fn.input(string.format("Delete session '%s'? (y/n): ", session_item.id))
        if confirm:lower() == "y" or confirm:lower() == "yes" then
          config.delete_chat_session(session_item.id)
          vim.notify("AI Assistant: Chat session deleted.", vim.log.levels.INFO)
        end
        view_previous_sessions()
      end
    end
  })
  action_menu:mount()
  action_menu:on(event.BufLeave, function()
    action_menu:unmount()
  end)
end

view_previous_sessions = function()
  local sessions = config.list_chat_sessions()
  if #sessions == 0 then
    vim.notify("AI Assistant: No saved chat sessions found.", vim.log.levels.WARN)
    M.manage_context()
    return
  end

  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local lines = {
    Menu.item("< Back to Settings", { id = "back" }),
    Menu.separator("Saved Chats")
  }
  for _, s in ipairs(sessions) do
    table.insert(lines, Menu.item(s.display, { id = s.id }))
  end

  local menu = Menu({
    position = "50%",
    size = { width = 75, height = math.min(12, #lines + 2) },
    border = {
      style = "rounded",
      text = { top = " Resume Previous Chat Session ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = lines,
    on_submit = function(item)
      if item.id == "back" then
        M.manage_context()
        return
      end
      show_session_actions(item)
    end
  })

  menu:mount()
  menu:on(event.BufLeave, function()
    menu:unmount()
  end)
end

local function manage_custom_agents()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event

  local menu = Menu({
    position = "50%",
    size = { width = 45, height = 7 },
    border = {
      style = "rounded",
      text = { top = " Agent Management ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = {
      Menu.item("< Back to Settings", { act = "back" }),
      Menu.separator("Actions"),
      Menu.item("1. Add / Update Agent", { act = "add" }),
      Menu.item("2. Delete Agent", { act = "del" }),
      Menu.item("3. List Configured Agents", { act = "list" })
    },
    on_submit = function(item)
      if item.act == "back" then
        M.manage_context()
      elseif item.act == "add" then
        local name = vim.fn.input("Enter agent name (lowercase, e.g. tester): ")
        if name == "" then
          M.manage_context()
          return
        end
        name = name:lower():gsub("%s+", "_")
        local prompt = vim.fn.input("Enter system prompt: ")
        if prompt == "" then
          M.manage_context()
          return
        end

        M.select_model(function(model)
          local settings = config.load_settings()
          settings.agents[name] = {
            system_prompt = prompt,
            model = model
          }
          config.save_settings(settings)
          vim.notify(string.format("AI Assistant: Agent @%s configured with model %s!", name, model), vim.log.levels.INFO)
          M.manage_context()
        end, true)
      elseif item.act == "del" then
        local settings = config.load_settings()
        local lines = {
          Menu.item("< Back to Settings", { id = "back" }),
          Menu.separator("Custom Agents")
        }
        for k, _ in pairs(settings.agents) do
          table.insert(lines, Menu.item("@" .. k, { id = k }))
        end
        if #lines <= 2 then
          vim.notify("AI Assistant: No custom agents to delete.", vim.log.levels.WARN)
          M.manage_context()
          return
        end

        local del_menu = Menu({
          position = "50%",
          size = { width = 45, height = math.min(10, #lines + 2) },
          border = {
            style = "rounded",
            text = { top = " Select Agent to Delete ", top_align = "center" }
          },
          buf_options = { modifiable = true, readonly = false },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
        }, {
          lines = lines,
          on_submit = function(del_item)
            if del_item.id == "back" then
              M.manage_context()
              return
            end
            settings.agents[del_item.id] = nil
            config.save_settings(settings)
            vim.notify(string.format("AI Assistant: Deleted agent @%s!", del_item.id), vim.log.levels.INFO)
            M.manage_context()
          end
        })
        del_menu:mount()
        del_menu:on(event.BufLeave, function() del_menu:unmount() end)
      elseif item.act == "list" then
        local settings = config.load_settings()
        local Popup = require("nui.popup")
        local list_popup = Popup({
          position = "50%",
          size = { width = 72, height = 18 },
          enter = true,
          focusable = true,
          border = {
            style = "rounded",
            text = { top = " Configured AI Agents (Press 'q' to go back) ", top_align = "center" }
          },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
        })
        list_popup:mount()
        list_popup:on(event.BufLeave, function() list_popup:unmount() end)

        local agent_lines = {
          " Configured AI Agents",
          " ====================",
          ""
        }
        for name, agent in pairs(settings.agents) do
          table.insert(agent_lines, "Agent: @" .. name)
          table.insert(agent_lines, "Model: " .. (agent.model or settings.default_model))
          table.insert(agent_lines, "System Prompt:")
          table.insert(agent_lines, "  " .. (agent.system_prompt or ""))
          table.insert(agent_lines, string.rep("-", 60))
        end
        
        vim.api.nvim_buf_set_lines(list_popup.bufnr, 0, -1, false, agent_lines)
        list_popup:map("n", "q", function()
          list_popup:unmount()
          manage_custom_agents()
        end)
      end
    end
  })

  menu:mount()
  menu:on(event.BufLeave, function() menu:unmount() end)
end

local function manage_presets()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local menu = Menu({
    position = "50%",
    size = { width = 45, height = 7 },
    border = { style = "rounded", text = { top = " Manage Presets ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = {
      Menu.item("< Back to Settings", { act = "back" }),
      Menu.separator("Actions"),
      Menu.item("1. Add Preset", { act = "add" }),
      Menu.item("2. Delete Preset", { act = "del" }),
      Menu.item("3. List Presets", { act = "list" }),
    },
    on_submit = function(item)
      if item.act == "back" then
        M.manage_context()
      elseif item.act == "add" then
        local name = vim.fn.input("Preset name: ")
        if name == "" then M.manage_context() return end
        name = name:gsub("%s+", "_")
        M.select_model(function(model)
          M.select_agent(function(agent)
            local settings = config.load_settings()
            settings.presets[name] = { model = model, agent = agent }
            config.save_settings(settings)
            vim.notify(string.format("AI Assistant: Preset '%s' saved (%s, @%s).", name, model, agent), vim.log.levels.INFO)
            M.manage_context()
          end, true)
        end, true)
      elseif item.act == "del" then
        local settings = config.load_settings()
        local lines = { Menu.item("< Back to Settings", { id = "back" }), Menu.separator("Presets") }
        for n in pairs(settings.presets or {}) do
          table.insert(lines, Menu.item(n, { id = n }))
        end
        if #lines <= 2 then
          vim.notify("AI Assistant: No presets to delete.", vim.log.levels.WARN)
          M.manage_context()
          return
        end
        local dm = Menu({
          position = "50%",
          size = { width = 45, height = math.min(10, #lines + 2) },
          border = { style = "rounded", text = { top = " Delete Preset ", top_align = "center" } },
          buf_options = { modifiable = true, readonly = false },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
        }, {
          lines = lines,
          on_submit = function(di)
            if di.id == "back" then M.manage_context() return end
            settings.presets[di.id] = nil
            config.save_settings(settings)
            vim.notify("AI Assistant: Deleted preset '" .. di.id .. "'.", vim.log.levels.INFO)
            M.manage_context()
          end,
        })
        dm:mount()
        dm:on(event.BufLeave, function() dm:unmount() end)
      elseif item.act == "list" then
        local settings = config.load_settings()
        local Popup = require("nui.popup")
        local lp = Popup({
          position = "50%",
          size = { width = 60, height = 15 },
          enter = true,
          focusable = true,
          border = { style = "rounded", text = { top = " Presets (q to go back) ", top_align = "center" } },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
        })
        lp:mount()
        lp:on(event.BufLeave, function() lp:unmount() end)
        local plines = { " Configured Presets", " ==================", "" }
        for n, p in pairs(settings.presets or {}) do
          table.insert(plines, string.format("%s:  model=%s  agent=@%s", n, p.model or "?", p.agent or "default"))
        end
        if #plines == 3 then table.insert(plines, "(no presets yet)") end
        vim.api.nvim_buf_set_lines(lp.bufnr, 0, -1, false, plines)
        lp:map("n", "q", function()
          lp:unmount()
          manage_presets()
        end)
      end
    end,
  })
  menu:mount()
  menu:on(event.BufLeave, function() menu:unmount() end)
end

function M.handle_context_action(action)
  if action == "keys" then
    configure_api_keys()
  elseif action == "default_model" then
    M.select_model(function(model)
      local settings = config.load_settings()
      settings.default_model = model
      config.save_settings(settings)
      vim.notify("AI Assistant: Default model set to " .. model, vim.log.levels.INFO)
      M.manage_context()
    end, true)
  elseif action == "view_context" then
    view_user_context()
  elseif action == "add_context" then
    add_context_item()
  elseif action == "del_context" then
    del_context_item()
  elseif action == "manage_agents" then
    manage_custom_agents()
  elseif action == "view_history" then
    view_previous_sessions()
  elseif action == "help" then
    show_help_cheat_sheet()
  elseif action == "edit_settings" then
    vim.cmd("split " .. config.get_settings_path())
  elseif action == "toggle_auto_approve" then
    local settings = config.load_settings()
    settings.auto_approve_tools = not settings.auto_approve_tools
    config.save_settings(settings)
    vim.notify("AI Assistant: Auto-Approve Tools set to " .. (settings.auto_approve_tools and "ON" or "OFF"), vim.log.levels.INFO)
    M.manage_context()
  elseif action == "toggle_auto_write" then
    local settings = config.load_settings()
    settings.auto_write_files = not settings.auto_write_files
    config.save_settings(settings)
    if session then session.auto_write = settings.auto_write_files end
    vim.notify("AI Assistant: File writes default to " .. (settings.auto_write_files and "AUTO" or "REVIEW") .. " (toggle live with /diff)", vim.log.levels.INFO)
    M.manage_context()
  elseif action == "manage_denylist" then
    manage_denylist()
  elseif action == "manage_presets" then
    manage_presets()
  end
end

function M.manage_context()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local settings = config.load_settings()

  local menu = Menu({
    position = "50%",
    size = { width = 48, height = 15 },
    border = {
      style = "rounded",
      text = { top = " AI Assistant Context & Settings ", top_align = "center" }
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  }, {
    lines = {
      Menu.item("1. Configure API Keys", { action = "keys" }),
      Menu.item("2. Set Default Model", { action = "default_model" }),
      Menu.item("3. View User Context Items", { action = "view_context" }),
      Menu.item("4. Add User Context Item", { action = "add_context" }),
      Menu.item("5. Delete User Context Item", { action = "del_context" }),
      Menu.item("6. Manage Custom Agents", { action = "manage_agents" }),
      Menu.item("7. View Previous Chat Sessions", { action = "view_history" }),
      Menu.item("8. Help / Available Commands", { action = "help" }),
      Menu.item("9. Edit Settings JSON Directly", { action = "edit_settings" }),
      Menu.item("10. Auto-Approve Tools: " .. (settings.auto_approve_tools and "ON" or "OFF"), { action = "toggle_auto_approve" }),
      Menu.item("11. Auto-Write Files (default): " .. (settings.auto_write_files and "AUTO" or "REVIEW"), { action = "toggle_auto_write" }),
      Menu.item("12. Manage Command Denylist", { action = "manage_denylist" }),
      Menu.item("13. Manage Presets", { action = "manage_presets" })
    },
    on_submit = function(item)
      M.handle_context_action(item.action)
    end
  })

  menu:mount()
  menu:on(event.BufLeave, function()
    menu:unmount()
  end)
end

local function get_timestamp_id()
  return "chat_" .. os.date("%Y-%m-%d_%H%M%S")
end

function M.toggle_chat(selected_text, loaded_history, session_id)
  if session and session.layout then
    -- Close (and save) the currently open chat.
    if activity.timer then
      activity.timer:stop()
      activity.timer:close()
      activity.timer = nil
    end
    if session.history_data and #session.history_data > 0 then
      config.save_chat_session(session.id, session.history_data)
    end
    -- A pending write_file diff is a separate float not in session.layout;
    -- unmount it here too or it orphans when the chat is toggled closed.
    if session.diff_popup then
      pcall(function() session.diff_popup:unmount() end)
      session.diff_popup = nil
    end
    session.layout:unmount()
    session = nil
    -- A plain toggle (<leader>cc) just closes. An explicit resume passes
    -- loaded_history/session_id and must continue to open the resumed chat.
    if not loaded_history then
      return
    end
  end

  -- Detect active file details before mounting (to avoid active buffer being the chat popups)
  local active_buf = vim.api.nvim_get_current_buf()
  local active_file_path = vim.api.nvim_buf_get_name(active_buf)
  local active_file = ""
  local active_file_content = ""
  
  if active_file_path and active_file_path ~= "" then
    local buftype = vim.bo[active_buf].buftype
    if buftype == "" and vim.fn.filereadable(active_file_path) == 1 then
      active_file = vim.fn.fnamemodify(active_file_path, ":.")
      local size = vim.fn.getfsize(active_file_path)
      if size > 0 and size < 150000 then -- limit to 150KB to prevent huge context
        local f = io.open(active_file_path, "r")
        if f then
          active_file_content = f:read("*all")
          f:close()
        end
      end
    end
  end

  local settings = config.load_settings()
  local Popup = require("nui.popup")
  local Layout = require("nui.layout")

  local header = Popup({
    border = { style = "rounded", text = { top = " AI Assistant Info ", top_align = "center" } },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" }
  })

  local history = Popup({
    border = { style = "rounded", text = { top = " Chat History ", top_align = "center" } },
    -- Deliberately NOT filetype="markdown": that is the sole gate render-markdown.nvim
    -- attaches on (its should_attach checks filetype ∈ file_types={'markdown'}). Once
    -- attached, its decoration provider calls env.range / node:range() against this
    -- buffer's CURRENT window on every redraw — and while an answer streams in or a
    -- tool diff/approval popup steals the window, that window goes stale, the call
    -- raises ("range"/nil value), and it re-fires every redraw → error-notification
    -- spam + a chat that looks frozen. We keep plain markdown *syntax* (set after
    -- mount, below) for highlighting instead.
    buf_options = { modifiable = false, readonly = true },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder", wrap = true }
  })

  local input = Popup({
    border = { style = "rounded", text = { top = " Ctrl-S Send | / cmds | @ files | Tab Model | Ctrl-A Agent | Esc Close ", top_align = "center" } },
    buf_options = { modifiable = true },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder", wrap = true }
  })

  session = {
    layout = nil,
    header = header,
    history = history,
    input = input,
    history_data = loaded_history or {},
    agent = "default",
    model = (settings.default_model and settings.default_model ~= "") and settings.default_model or "gemini-2.5-flash",
    selected_text = selected_text,
    active_file = active_file,
    active_file_content = active_file_content,
    active_buf = (active_file ~= "" and active_buf) or nil,
    is_thinking = false,
    id = session_id or get_timestamp_id(),
    waiting_for_tool = nil,
    active_job = nil,
    -- Monotonic per-request token. Bumped when a turn starts and again on cancel,
    -- so any late-firing (vim.schedule'd) callback from a superseded/cancelled
    -- request can detect it is stale and no-op instead of resurrecting the UI.
    gen = 0,
    -- false = review every write (show diff, accept/reject); /diff toggles it.
    auto_write = settings.auto_write_files == true,
    reasoning_text = "",
  }

  local layout = Layout(
    { position = "50%", size = { width = "80%", height = "85%" } },
    Layout.Box({
      Layout.Box(header, { size = 5 }),
      Layout.Box(history, { size = "73%" }),
      Layout.Box(input, { size = "20%" })
    }, { dir = "col" })
  )
  session.layout = layout

  layout:mount()

  -- Plain vim regex markdown syntax for highlighting. This buffer is intentionally
  -- left WITHOUT filetype=markdown (see the history Popup above) so render-markdown.nvim
  -- never attaches to it — its treesitter-driven env.range/node:range() crashes on this
  -- volatile streaming buffer when the window goes stale, which spams errors and freezes
  -- the chat. Setting `syntax` (not `filetype`) gives highlighting without that attach.
  vim.bo[history.bufnr].syntax = "markdown"

  -- Collapsible cards (tool output / diffs / reasoning) for the history window.
  setup_history_folds(history.winid, history.bufnr)

  -- Initialize status text in Header
  update_header(header, session, "Ready")

  -- Load history if resuming a chat. Tool turns (role="tool", or model turns with
  -- tool_calls) have no plain .content, so render them as compact lines instead of
  -- blank "AI Assistant" blocks.
  if loaded_history and #loaded_history > 0 then
    for _, msg in ipairs(loaded_history) do
      if msg.tool_results then
        local names = {}
        for _, r in ipairs(msg.tool_results) do names[#names + 1] = r.name or "tool" end
        append_to_history(history, string.format("\n> ✔ tool result: %s\n", table.concat(names, ", ")))
      elseif msg.tool_calls then
        if msg.content and msg.content ~= "" then
          append_to_history(history, string.format("\n### AI Assistant\n%s\n", msg.content))
        end
        local calls = {}
        for _, c in ipairs(msg.tool_calls) do calls[#calls + 1] = c.name or "tool" end
        append_to_history(history, string.format("> ⚙ ran tool(s): %s\n", table.concat(calls, ", ")))
      elseif msg.content and msg.content ~= "" then
        local speaker = msg.role == "user" and "User" or "AI Assistant"
        append_to_history(history, string.format("\n## %s\n%s\n", speaker, msg.content))
      end
    end
  end

  -- Print selection context if any
  if selected_text and selected_text ~= "" then
    append_to_history(history, string.format("### Context: Selected Code\n```\n%s\n```\n", selected_text))
  end

  -- Focus on prompt input
  vim.fn.win_gotoid(input.winid)

  -- Configure Keymaps
  local close_fn = function()
    if activity.timer then
      activity.timer:stop()
      activity.timer:close()
      activity.timer = nil
    end
    if session and session.history_data and #session.history_data > 0 then
      config.save_chat_session(session.id, session.history_data)
    end
    if session and session.diff_popup then
      pcall(function() session.diff_popup:unmount() end)
      session.diff_popup = nil
    end
    layout:unmount()
    session = nil
  end

  local cancel_or_close = function()
    if session and session.is_thinking then
      M.cancel_active_request()
    else
      close_fn()
    end
  end

  local default_input_top = " Ctrl-S Send | / cmds | @ files | Tab Model | Ctrl-A Agent | Esc Close "

  -- Flush any buffered reasoning for the current round as a collapsed card. Called
  -- before the answer/tool card so reasoning always lands just above what it produced.
  local flush_reasoning = function()
    if session and session.reasoning_text and session.reasoning_text ~= "" then
      append_fold(history, "> 🧠 reasoning", session.reasoning_text)
      session.reasoning_text = ""
    end
  end

  -- Resolve a pending tool approval (from either the diff popup keys or typed y/n).
  local resolve_tool = function(approved)
    if not session or not session.waiting_for_tool then return end
    local cb = approved and session.waiting_for_tool.on_approve or session.waiting_for_tool.on_deny
    session.waiting_for_tool = nil
    if session.diff_popup then
      pcall(function() session.diff_popup:unmount() end)
      session.diff_popup = nil
    end
    input.border:set_text("top", default_input_top)
    append_to_history(history, approved and "\n> ✔ accepted\n" or "\n> ✗ rejected\n")
    session.is_thinking = true
    activity_begin(header, "working")
    if input.winid and vim.api.nvim_win_is_valid(input.winid) then
      vim.fn.win_gotoid(input.winid)
    end
    if cb then cb() end
  end

  input:map("n", "<Esc>", cancel_or_close, { noremap = true })
  input:map("n", "<C-c>", cancel_or_close, { noremap = true })
  input:map("i", "<C-c>", cancel_or_close, { noremap = true })
  -- The user is normally left in insert mode after a Ctrl-S submit, so make Esc
  -- cancel from insert mode too. Gated so an idle Esc still just leaves insert
  -- mode (rather than closing the chat) — only a live request is cancelled.
  input:map("i", "<Esc>", function()
    if session and session.is_thinking then
      M.cancel_active_request()
    else
      vim.cmd("stopinsert")
    end
  end, { noremap = true })

  local settings_fn = function()
    close_fn()
    vim.schedule(M.manage_context)
  end
  input:map("n", "<C-x>", settings_fn, { noremap = true })
  input:map("i", "<C-x>", settings_fn, { noremap = true })

  -- Forward declarations so the slash-command handler (inside submit_fn) can
  -- reach the model/agent menus defined further below.
  local model_menu_fn, agent_menu_fn

  -- /preset : pick a saved {model, agent} bundle and apply it to this session.
  local function open_preset_menu()
    local settings = config.load_settings()
    local names = {}
    for n in pairs(settings.presets or {}) do names[#names + 1] = n end
    if #names == 0 then
      append_to_history(history, "\n> **System**: No presets saved. Add one via Settings (Ctrl-X) → Manage Presets.\n")
      return
    end
    table.sort(names)
    local Menu = require("nui.menu")
    local event = require("nui.utils.autocmd").event
    local lines = {}
    for _, n in ipairs(names) do
      local p = settings.presets[n]
      lines[#lines + 1] = Menu.item(string.format("%s  (model: %s, agent: @%s)", n, p.model or "?", p.agent or "default"), { id = n })
    end
    local menu = Menu({
      position = "50%",
      size = { width = 60, height = math.min(12, #lines + 2) },
      border = { style = "rounded", text = { top = " Apply Preset ", top_align = "center" } },
      buf_options = { modifiable = true, readonly = false },
      win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
    }, {
      lines = lines,
      on_submit = function(item)
        local p = settings.presets[item.id]
        if p and session then
          if p.model then session.model = p.model end
          if p.agent then session.agent = p.agent end
          append_to_history(history, string.format("\n> **System**: Applied preset '%s' (model: %s, agent: @%s).\n", item.id, session.model, session.agent))
          update_header(header, session, "Ready")
          vim.fn.win_gotoid(input.winid)
        end
      end,
    })
    menu:mount()
    menu:on(event.BufLeave, function() menu:unmount() end)
  end

  local submit_fn = function()
    if not session then return end
    if session.is_thinking then
      vim.notify("AI Assistant: Currently thinking. Press <Esc> to cancel.", vim.log.levels.WARN)
      return
    end

    local lines = vim.api.nvim_buf_get_lines(input.bufnr, 0, -1, false)
    local prompt = table.concat(lines, "\n")
    prompt = vim.trim(prompt)

    -- Tool approval interceptor (fallback for typed y/n; the diff popup also
    -- accepts/rejects inline via a/r keys, both routed through resolve_tool).
    if session.waiting_for_tool then
      local choice = prompt:lower()
      vim.api.nvim_buf_set_lines(input.bufnr, 0, -1, false, {})
      if choice == "y" or choice == "yes" then
        resolve_tool(true)
      elseif choice == "n" or choice == "no" then
        resolve_tool(false)
      else
        vim.notify("AI Assistant: Type 'y'/'n' (or press a/r in the diff window).", vim.log.levels.WARN)
      end
      return
    end

    -- Slash commands: intercept /-prefixed input instead of sending it to the model.
    if prompt:match("^/%a") then
      vim.api.nvim_buf_set_lines(input.bufnr, 0, -1, false, {})
      local cmd, rest = prompt:match("^/(%S+)%s*(.*)$")
      cmd = (cmd or ""):lower()
      rest = rest or ""
      if cmd == "model" then
        if model_menu_fn then model_menu_fn() end
      elseif cmd == "agent" then
        if agent_menu_fn then agent_menu_fn() end
      elseif cmd == "clear" then
        session.history_data = {}
        session.selected_text = nil
        append_to_history(history, "\n> **System**: Conversation history cleared.\n")
        update_header(header, session, "Ready")
      elseif cmd == "sessions" then
        view_previous_sessions()
      elseif cmd == "context" or cmd == "settings" then
        settings_fn()
      elseif cmd == "preset" then
        open_preset_menu()
      elseif cmd == "help" then
        show_help_cheat_sheet()
      elseif cmd == "plan" then
        session.plan_mode = not session.plan_mode
        append_to_history(history, string.format("\n> **System**: Plan mode %s.\n", session.plan_mode and "ON — the assistant will propose a plan before writing/running anything" or "OFF"))
        update_header(header, session, "Ready")
      elseif cmd == "diff" then
        local arg = vim.trim(rest):lower()
        if arg == "auto" or arg == "on" then
          session.auto_write = true
        elseif arg == "review" or arg == "off" then
          session.auto_write = false
        else
          session.auto_write = not session.auto_write
        end
        append_to_history(history, string.format("\n> **System**: File writes: %s.\n",
          session.auto_write and "AUTO — applied immediately, shown as a collapsed diff card"
            or "REVIEW — shown as a diff you accept (a) or reject (r) before writing"))
        update_header(header, session, "Ready")
      elseif cmd == "compare" or cmd == "council" then
        if rest == "" then
          append_to_history(history, "\n> **System**: Usage: /" .. cmd .. " <your question>\n")
        else
          local settings = config.load_settings()
          local models = settings.compare_models
          if not models or #models == 0 then
            models = { session.model, settings.default_subagent_model }
          end
          local api = require("ai_assistant.api")
          append_to_history(history, string.format("\n## User\n/%s %s\n", cmd, rest))
          session.is_thinking = true
          activity_begin(header, "thinking")
          activity_phase("thinking", string.format("querying %d model%s in parallel…", #models, #models == 1 and "" or "s"))
          local on_each = function(model, ok, text)
            append_to_history(history, string.format("\n### [%s]%s\n%s\n", model, ok and "" or " (error)", text or ""))
          end
          if cmd == "compare" then
            api.run_compare({ prompt = rest, selected_text = session.selected_text }, models, on_each, function()
              if not session then return end
              session.is_thinking = false
              activity_stop(header, "✓ Ready")
            end)
          else
            api.run_council({ prompt = rest, selected_text = session.selected_text }, models, session.model, on_each, function(judged)
              if not session then return end
              append_to_history(history, "\n### Council Verdict (synthesized)\n" .. (judged or "") .. "\n")
              session.is_thinking = false
              activity_stop(header, "✓ Ready")
            end)
          end
        end
      elseif cmd == "quit" or cmd == "close" then
        close_fn()
      else
        append_to_history(history, "\n> **System**: Unknown command `/" .. cmd .. "`. Available: /model /agent /preset /compare /council /clear /sessions /context /plan /diff /help /quit\n")
      end
      return
    end

    if prompt == "" then
      if session.selected_text and session.selected_text ~= "" then
        prompt = "Analyze the selected code, explain what it does, highlight potential issues, and suggest improvements."
      else
        vim.notify("AI Assistant: Prompt cannot be empty.", vim.log.levels.WARN)
        return
      end
    end

    -- Clear input popup
    vim.api.nvim_buf_set_lines(input.bufnr, 0, -1, false, {})

    -- Print User Prompt in history
    append_to_history(history, "\n## User\n" .. prompt .. "\n")

    -- Start the activity indicator and mark as thinking. Capture this turn's
    -- generation; every callback closure below checks it so a cancelled or
    -- superseded request's late events are ignored.
    session.gen = (session.gen or 0) + 1
    local my_gen = session.gen
    session.is_thinking = true
    activity_begin(header, "thinking")

    -- Refresh active-file content from the live buffer (captures unsaved edits)
    -- so each turn reflects the current state, not the toggle-time snapshot.
    if session.active_file and session.active_file ~= "" and session.active_buf
        and vim.api.nvim_buf_is_valid(session.active_buf) then
      local buf_lines = vim.api.nvim_buf_get_lines(session.active_buf, 0, -1, false)
      local buf_text = table.concat(buf_lines, "\n")
      if #buf_text <= 150000 then
        session.active_file_content = buf_text
      end
    end

    -- Call API (streaming). Reset per-turn streaming state first.
    session.stream_started = false
    session.reasoning_text = ""
    session.stream_chars = 0
    api.send_prompt({
      prompt = prompt,
      history = session.history_data,
      agent = session.agent,
      model = session.model,
      selected_text = session.selected_text,
      active_file = session.active_file,
      active_file_content = session.active_file_content,
      fresh_user_turn = true,
      plan_mode = session.plan_mode,
      auto_write = session.auto_write,
      on_thinking = function(chunk)
        if not session or session.gen ~= my_gen then return end
        -- Buffer summarized reasoning; it's flushed as a collapsed card right
        -- before the answer / tool card it produced. Surface the growing size in
        -- the status so a long, invisible reasoning phase still reads as alive.
        session.reasoning_text = (session.reasoning_text or "") .. chunk
        activity_note("reasoning", fmt_size(#session.reasoning_text))
      end,
      on_response_start = function()
        if not session or session.gen ~= my_gen then return end
        -- First answer token: surface any reasoning, then print the header once.
        flush_reasoning()
        activity_phase("writing")
        session.stream_started = true
        append_to_history(history, "\n### AI Assistant (@" .. session.agent .. ")\n")
      end,
      on_delta = function(chunk)
        if not session or session.gen ~= my_gen then return end
        stream_append(history, chunk)
        session.stream_chars = (session.stream_chars or 0) + #chunk
        activity_note("writing", fmt_size(session.stream_chars))
      end,
      on_status = function(phase_key, detail)
        -- Semantic phase updates emitted by the agentic loop in api.lua (running
        -- a command, reading a file, handing tool output back, delegating…).
        if not session or session.gen ~= my_gen then return end
        activity_phase(phase_key, detail)
      end,
      on_job_started = function(job)
        -- Don't adopt a job spawned by a request we've already cancelled/superseded.
        if session and session.gen == my_gen then
          session.active_job = job
        end
      end,
      notify_fn = function(text)
        if not session or session.gen ~= my_gen then return end
        -- Tool round-trips with no answer text still carry reasoning; flush it
        -- so it appears above the tool card rather than being lost.
        flush_reasoning()
        append_to_history(history, text)
      end,
      request_tool_fn = function(tool_type, tool_arg, on_approve, on_deny)
        if not session or session.gen ~= my_gen then return end
        -- Reasoning that led to this tool should appear above its card.
        flush_reasoning()
        activity_stop(header, "⏳ Waiting for your approval — your turn")

        session.is_thinking = false
        session.waiting_for_tool = { on_approve = on_approve, on_deny = on_deny }

        if tool_type == "write_file" then
          -- Show the proposed change as a focusable diff with inline accept/reject,
          -- and a compact one-line card in the chat.
          local wd = api.compute_write_diff(tool_arg.path, tool_arg.content)
          append_to_history(history, string.format(
            "\n> ✎ review write `%s` (+%d/-%d) — **a** accept · **r** reject\n",
            tostring(tool_arg.path), wd.added, wd.removed))

          local Popup = require("nui.popup")
          local diff_lines = (wd.diff == "") and { "(no textual changes)" } or vim.split(wd.diff, "\n", { plain = true })
          local dpop = Popup({
            position = "50%",
            size = { width = "72%", height = "55%" },
            enter = true,
            focusable = true,
            border = { style = "rounded", text = { top = string.format(" %s %s  (a accept · r reject · q defer) ", wd.kind, tool_arg.path), top_align = "center" } },
            buf_options = { filetype = "diff", modifiable = false },
            win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder", wrap = false },
          })
          dpop:mount()
          vim.bo[dpop.bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(dpop.bufnr, 0, -1, false, diff_lines)
          vim.bo[dpop.bufnr].modifiable = false
          local accept = function()
            -- On accept, leave a collapsed diff card behind so the change stays
            -- reviewable in the transcript without flooding it.
            append_fold(history, string.format("> ✔ wrote `%s` (+%d/-%d)", tostring(tool_arg.path), wd.added, wd.removed),
              wd.diff ~= "" and wd.diff or "(no textual changes)")
            resolve_tool(true)
          end
          dpop:map("n", "a", accept, { noremap = true })
          dpop:map("n", "<CR>", accept, { noremap = true })
          dpop:map("n", "r", function() resolve_tool(false) end, { noremap = true })
          dpop:map("n", "d", function() resolve_tool(false) end, { noremap = true })
          dpop:map("n", "q", function()
            -- Defer: close the diff but keep the request pending (answer y/n in input).
            pcall(function() dpop:unmount() end)
            if session then session.diff_popup = nil end
            if input.winid and vim.api.nvim_win_is_valid(input.winid) then
              vim.fn.win_gotoid(input.winid)
            end
          end, { noremap = true })
          dpop:map("n", "<Esc>", function() resolve_tool(false) end, { noremap = true })
          session.diff_popup = dpop
          input.border:set_text("top", " Accept (a) / Reject (r) in the diff window — or type y/n ")
        else
          local label = (tool_type == "command") and ("run `" .. tostring(tool_arg) .. "`")
            or ("read `" .. tostring(tool_arg) .. "`")
          append_to_history(history, string.format("\n> ⚠ approve %s ? — type **y** / **n**\n", label))
          input.border:set_text("top", " Approve tool? (y / n) ")
          vim.fn.win_gotoid(input.winid)
        end
      end
    }, function(success, response, new_history)
      -- Ignore the completion of a request the user cancelled or superseded:
      -- otherwise it would clear "■ Cancelled", append a stale answer block, and
      -- overwrite history_data captured by the next turn.
      if not session or session.gen ~= my_gen then return end
      session.is_thinking = false
      session.active_job = nil
      local fin = success and "✓ Ready" or "✗ Error"
      activity_stop(header, fin)

      if success then
        flush_reasoning()
        if session.stream_started then
          -- Streamed live already; just close the block.
          append_to_history(history, "\n")
        else
          if response and response ~= "" then
            append_to_history(history, "\n### AI Assistant (@" .. session.agent .. ")\n" .. response .. "\n")
          end
        end
        if new_history then
          session.history_data = new_history
        end
        session.selected_text = nil
      else
        -- Graceful failure: surface whatever was streamed, drop a clear error
        -- card in the transcript, and warn the user (the request is finished and
        -- the spinner is already stopped above — never left hanging).
        flush_reasoning()
        local msg = (response and response ~= "") and response or "Unknown error"
        append_to_history(history, "\n### Error\n" .. msg .. "\n")
        vim.notify("AI Assistant: " .. msg, vim.log.levels.WARN)
      end
      session.stream_started = false
      -- Refresh the resting header now that history (token/message counts) is
      -- updated, keeping the same final status the activity indicator settled on.
      update_header(header, session, fin)
    end)
  end

  input:map("n", "<CR>", submit_fn, { noremap = true })
  input:map("n", "<C-s>", submit_fn, { noremap = true })
  input:map("i", "<C-s>", submit_fn, { noremap = true })

  -- Tab: Model selection
  model_menu_fn = function()
    if session and session.is_thinking then
      vim.notify("AI Assistant: Busy thinking — press <Esc> to cancel first.", vim.log.levels.WARN)
      return
    end
    M.select_model(function(model)
      if session then
        session.model = model
        update_header(header, session, "Ready")
        vim.fn.win_gotoid(input.winid)
      end
    end)
  end
  input:map("n", "<Tab>", model_menu_fn, { noremap = true })
  input:map("i", "<Tab>", model_menu_fn, { noremap = true })

  -- Ctrl-A: Agent selection
  agent_menu_fn = function()
    if session and session.is_thinking then
      vim.notify("AI Assistant: Busy thinking — press <Esc> to cancel first.", vim.log.levels.WARN)
      return
    end
    M.select_agent(function(agent)
      if session then
        session.agent = agent
        update_header(header, session, "Ready")
        vim.fn.win_gotoid(input.winid)
      end
    end)
  end
  input:map("n", "<C-a>", agent_menu_fn, { noremap = true })
  input:map("i", "<C-a>", agent_menu_fn, { noremap = true })

  -- @-mention fuzzy file picker (<C-f> opens it directly and inserts "@path").
  local file_picker_fn = function()
    open_file_picker(input, config.get_project_root())
  end
  -- Typing "@" always inserts a literal "@" first (so "@agent_name" is typable
  -- and cancelling the picker still leaves the "@"), then opens the file picker
  -- when fzf-lua is present — which appends just the path (no double "@").
  local at_fn = function()
    vim.api.nvim_put({ "@" }, "c", true, true)
    if pcall(require, "fzf-lua") then
      vim.schedule(function()
        open_file_picker(input, config.get_project_root(), "")
      end)
    end
  end
  input:map("i", "@", at_fn, { noremap = true })
  input:map("i", "<C-f>", file_picker_fn, { noremap = true })
  input:map("n", "<C-f>", file_picker_fn, { noremap = true })
end

return M
