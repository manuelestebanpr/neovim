-- lua/ai_assistant/chat.lua
-- The chat RUNTIME (model), decoupled from any window. A Chat owns everything that
-- must outlive the view: a PERSISTENT scratch buffer holding the full rendered
-- transcript, the running job + its generation token, streaming/activity state,
-- and the conversation history. The agent's callbacks write to THIS buffer and
-- update Chat status REGARDLESS of whether a window is showing it — so closing the
-- window keeps the agent running and reopening shows everything as if never closed.
--
-- ui.lua is the VIEW: it mounts a layout, points its history window at chat.bufnr,
-- and subscribes via chat.view. Closing = detach the view (job survives). The
-- registry + the req-4 most-recent/new-chat state machine live here too.

local M = {}
local config = require("ai_assistant.config")
local api = require("ai_assistant.api")
local engram = require("ai_assistant.engram")

-- Registry of live chats (survive window close) + the "open/recent" id (req 4).
local Chats = {}
local current_id = nil
local seq = 0
local health_notified = false

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Friendly status phases (icon + label + fallback hint). Keys match api.lua's
-- on_status events so the header narrates what the agent is actually doing.
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
  searching    = { icon = "🌐", label = "Searching",          hint = nil },
  fetching     = { icon = "🌐", label = "Fetching page",      hint = nil },
}

local function fmt_size(n)
  if n < 1000 then return string.format("%d chars", n) end
  return string.format("%.1fk chars", n / 1000)
end

local function fmt_elapsed(ns)
  local s = math.floor(ns / 1e9)
  if s < 60 then return s .. "s" end
  return string.format("%dm%02ds", math.floor(s / 60), s % 60)
end

----------------------------------------------------------------------
-- Chat object
----------------------------------------------------------------------

local Chat = {}
Chat.__index = Chat

local function new_buffer()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide" -- closing the window keeps the buffer alive
  vim.bo[b].swapfile = false
  -- Plain markdown SYNTAX (not filetype): filetype=markdown is the sole gate
  -- render-markdown.nvim attaches on, and its treesitter decoration provider
  -- crashes against a stale window while streaming / when a diff popup steals the
  -- window. syntax gives highlighting without that attach. Set once, persists.
  vim.bo[b].syntax = "markdown"
  vim.bo[b].modifiable = false
  return b
end

function Chat.new(id, history_data)
  local settings = config.load_settings()
  local self = setmetatable({}, Chat)
  self.id = id
  self.bufnr = new_buffer()
  self.history_data = history_data or {}
  self.model = (type(settings.default_model) == "string" and settings.default_model ~= "") and settings.default_model or "kimi-k2.6"
  self.auto_write = settings.auto_write_files == true
  self.selected_text = nil
  self.active_file = ""
  self.active_file_content = ""
  self.active_buf = nil
  self.gen = 0
  self.active_job = nil
  self.is_thinking = false
  self.waiting_for_tool = nil
  self.reasoning_text = ""
  self.stream_started = false
  self.stream_chars = 0
  -- activity state (the timer animates the header line1 while a request is live)
  self.phase = nil
  self.detail = nil
  self.frame_idx = 1
  self.start_ns = nil
  self.timer = nil
  self.final_text = "Ready"
  self.view = nil       -- { header=<nui popup>, input=<nui popup>, history_win=<winid> }
  self.engram_ok = nil  -- nil unknown, true reachable, false down
  self.autosaved = false
  self.selection_shown = nil
  if #self.history_data > 0 then self:hydrate() end
  return self
end

function Chat:is_empty()
  return #self.history_data == 0
end

-- ── buffer writers (always write to chat.bufnr; scroll only when attached) ──

function Chat:_after_write()
  local v = self.view
  if v and v.history_win and vim.api.nvim_win_is_valid(v.history_win) then
    vim.schedule(function()
      if self.view and self.view.history_win and vim.api.nvim_win_is_valid(self.view.history_win)
          and vim.api.nvim_buf_is_valid(self.bufnr) then
        local n = vim.api.nvim_buf_line_count(self.bufnr)
        pcall(vim.api.nvim_win_set_cursor, self.view.history_win, { n, 0 })
      end
    end)
  end
end

function Chat:append(text)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  vim.bo[self.bufnr].modifiable = true
  local lines = vim.split(text, "\n")
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  if line_count == 1 and vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(self.bufnr, 0, 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
  end
  vim.bo[self.bufnr].modifiable = false
  self:_after_write()
end

-- Continue the CURRENT last line (so streamed tokens flow inline).
function Chat:stream(chunk)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  vim.bo[self.bufnr].modifiable = true
  local last = vim.api.nvim_buf_line_count(self.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(self.bufnr, last - 1, last, false)[1] or ""
  local parts = vim.split(chunk, "\n", { plain = true })
  parts[1] = last_line .. parts[1]
  vim.api.nvim_buf_set_lines(self.bufnr, last - 1, last, false, parts)
  vim.bo[self.bufnr].modifiable = false
  self:_after_write()
end

-- A collapsible card: a one-line summary over a folded body.
function Chat:append_fold(summary, body)
  if body == nil or body == "" then
    self:append("\n" .. summary .. "\n")
  else
    self:append("\n" .. summary .. " " .. api.FOLD_OPEN .. "\n" .. body .. "\n" .. api.FOLD_CLOSE .. "\n")
  end
end

function Chat:flush_reasoning()
  if self.reasoning_text and self.reasoning_text ~= "" then
    self:append_fold("> 🧠 reasoning", self.reasoning_text)
    self.reasoning_text = ""
  end
end

-- Replay persisted history into the buffer (resume / open-recent). Type-guards
-- every field: a reloaded chat may contain JSON null (vim.NIL), truthy yet raises
-- under ipairs/# and the .. operator.
function Chat:hydrate()
  for _, msg in ipairs(self.history_data) do
    if type(msg.tool_results) == "table" then
      local names = {}
      for _, r in ipairs(msg.tool_results) do names[#names + 1] = r.name or "tool" end
      self:append(string.format("\n> ✔ tool result: %s\n", table.concat(names, ", ")))
    elseif type(msg.tool_calls) == "table" then
      if type(msg.content) == "string" and msg.content ~= "" then
        self:append(string.format("\n### AI Assistant\n%s\n", msg.content))
      end
      local calls = {}
      for _, c in ipairs(msg.tool_calls) do calls[#calls + 1] = c.name or "tool" end
      self:append(string.format("> ⚙ ran tool(s): %s\n", table.concat(calls, ", ")))
    elseif type(msg.content) == "string" and msg.content ~= "" then
      local speaker = msg.role == "user" and "User" or "AI Assistant"
      self:append(string.format("\n## %s\n%s\n", speaker, msg.content))
    end
  end
end

-- ── activity / header ──────────────────────────────────────────────────────

local function mem_indicator(self, settings)
  if settings.engram_enabled == false then return "off" end
  if self.engram_ok == true then return "✓" end
  if self.engram_ok == false then return "✗ down" end
  return "…"
end

-- Estimate context size (history + selection + active file). Project context and
-- the self-evolving prefs are gone, so this is just the conversation.
local function estimate_chars(self)
  local total = #("You are a helpful and expert AI coding assistant.")
  for _, msg in ipairs(self.history_data or {}) do
    if type(msg.content) == "string" then total = total + #msg.content end
    if type(msg.tool_results) == "table" then
      for _, r in ipairs(msg.tool_results) do
        if type(r.output) == "string" then total = total + #r.output end
      end
    end
    if type(msg.tool_calls) == "table" then
      for _, c in ipairs(msg.tool_calls) do
        local ok, enc = pcall(vim.fn.json_encode, c.input or {})
        total = total + #(ok and enc or "")
      end
    end
  end
  if type(self.selected_text) == "string" then total = total + #self.selected_text end
  if #(self.history_data or {}) == 0 and type(self.active_file_content) == "string" then
    total = total + #self.active_file_content
  end
  return total
end

function Chat:status_text()
  local ph = self.phase or PHASES.thinking
  local label = (ph.icon ~= "" and (ph.icon .. " ") or "") .. ph.label
  local detail = self.detail
  if (not detail or detail == "") and ph.hint then detail = ph.hint end
  local status = spinner_frames[self.frame_idx] .. "  " .. label
  if detail and detail ~= "" then status = status .. " — " .. detail end
  if self.start_ns then
    status = status .. "  · " .. fmt_elapsed(vim.loop.hrtime() - self.start_ns)
  end
  return status
end

function Chat:line1(status)
  local settings = config.load_settings()
  return string.format(" Model: %s | Status: %s | Mem: %s", self.model, status, mem_indicator(self, settings))
end

-- Render only the animated status line (line1). Runs ~8×/s, so it must not
-- recompute the full header. No-op when detached.
function Chat:render_status()
  local v = self.view
  if not (v and v.header and v.header.bufnr and vim.api.nvim_buf_is_valid(v.header.bufnr)) then return end
  pcall(vim.api.nvim_buf_set_lines, v.header.bufnr, 0, 1, false, { self:line1(self:status_text()) })
end

-- Render the full 3-line header (called at turn start/end and on attach). No-op
-- when detached; the state lives on the chat so a re-attach reconstructs it.
function Chat:render_header(status_text)
  local v = self.view
  if not (v and v.header and v.header.bufnr and vim.api.nvim_buf_is_valid(v.header.bufnr)) then return end
  local status = status_text
    or (self.is_thinking and "🧠 Thinking" or (self.waiting_for_tool and "⏳ Waiting for your approval" or self.final_text or "Ready"))

  local af = (self.active_file and self.active_file ~= "") and self.active_file or "None"
  local af_size = (type(self.active_file_content) == "string") and #self.active_file_content or 0
  local sel = (type(self.selected_text) == "string" and self.selected_text ~= "")
    and string.format("Yes (%d chars)", #self.selected_text) or "No"

  local total = estimate_chars(self)
  local est = math.ceil(total / 4)
  local settings = config.load_settings()
  local budget = settings.context_token_budget or 100000

  local usage = (total < 1000) and string.format("%d chars (~%d tokens)", total, est)
    or string.format("%.1fK chars (~%.1fK tokens)", total / 1000, est / 1000)

  local line1 = self:line1(status)
  local line2 = string.format(" Context: [Active File: %s (%s)] [Selection: %s]",
    af, af_size > 0 and string.format("%.1fKB", af_size / 1024) or "0B", sel)
  local line3 = string.format(" Usage: %s / %dK tokens | Messages: %d", usage, math.floor(budget / 1000), #(self.history_data or {}))
  if est > budget then line3 = line3 .. " [Trimming Active]" end
  pcall(vim.api.nvim_buf_set_lines, v.header.bufnr, 0, -1, false, { line1, line2, line3 })
end

function Chat:_ensure_timer()
  if self.timer then return end
  self.timer = vim.loop.new_timer()
  self.timer:start(0, 120, vim.schedule_wrap(function()
    self.frame_idx = (self.frame_idx % #spinner_frames) + 1
    self:render_status()
  end))
end

function Chat:_stop_timer()
  if self.timer then
    pcall(function() self.timer:stop() end)
    pcall(function() self.timer:close() end)
    self.timer = nil
  end
end

-- Cheap hot-path update (every token): swap phase/detail; the timer redraws.
function Chat:activity_note(phase_key, detail)
  if phase_key and PHASES[phase_key] then self.phase = PHASES[phase_key] end
  if detail ~= nil then self.detail = detail end
end

-- Visible phase change with instant feedback.
function Chat:activity_phase(phase_key, detail)
  self:activity_note(phase_key, detail)
  self:_ensure_timer()
  self:render_status()
end

-- Begin a fresh activity span: reset the clock, start animating.
function Chat:activity_begin(phase_key)
  self.frame_idx = 1
  self.detail = nil
  self.start_ns = vim.loop.hrtime()
  self.phase = PHASES[phase_key] or PHASES.thinking
  self:_ensure_timer()
  self:render_status()
end

-- Settle into a static terminal line and stop animating (the ONLY resting point).
function Chat:activity_stop(final_text)
  self:_stop_timer()
  self.start_ns = nil
  self.detail = nil
  self.phase = nil
  self.final_text = final_text or "Ready"
  self:render_header(self.final_text)
end

-- Called by the view when it (re)attaches so the spinner resumes exactly where it
-- was. The timer + state already live on the chat; just re-render and ensure the
-- timer is running iff a request is still in flight.
function Chat:on_attach()
  if self.is_thinking then
    self:_ensure_timer()
    self:render_status()
  else
    self:render_header(self.final_text)
  end
end

-- Called by the view on detach: stop the (now invisible) animation; keep state.
function Chat:on_detach()
  self:_stop_timer()
end

-- ── interrupt ──────────────────────────────────────────────────────────────

function Chat:cancel()
  if self.active_job then
    local job = self.active_job
    if type(job) == "table" then
      if type(job.shutdown) == "function" then
        pcall(job.shutdown, job)
      elseif type(job.kill) == "function" then
        pcall(job.kill, job, 9)
      end
    end
    self.active_job = nil
  end
  -- Invalidate in-flight callbacks so a late response can't re-arm the spinner,
  -- append stale output, or resume a parked approval after "■ Cancelled".
  self.gen = (self.gen or 0) + 1
  self.waiting_for_tool = nil
  self.is_thinking = false
  self:activity_stop("■ Cancelled")
  self:append("\n> **System**: Request cancelled by user.\n")
end

-- ── tool approval resolution (called from the view's approval keys / typed y/n) ──

function Chat:resolve_tool(approved)
  if not self.waiting_for_tool then return end
  local wt = self.waiting_for_tool
  self.waiting_for_tool = nil
  local v = self.view
  if v and v.dismiss_approval then v.dismiss_approval() end
  self:append(approved and "\n> ✔ accepted\n" or "\n> ✗ rejected\n")
  self.is_thinking = true
  self:activity_begin("working")
  local cb = approved and wt.on_approve or wt.on_deny
  if cb then cb() end
end

-- ── send a turn ────────────────────────────────────────────────────────────

-- Refresh active-file content from the live buffer (captures unsaved edits).
function Chat:refresh_active_file()
  if self.active_file and self.active_file ~= "" and self.active_buf
      and vim.api.nvim_buf_is_valid(self.active_buf) then
    local buf_text = table.concat(vim.api.nvim_buf_get_lines(self.active_buf, 0, -1, false), "\n")
    if #buf_text <= 150000 then self.active_file_content = buf_text end
  end
end

function Chat:send(prompt)
  self:append("\n## User\n" .. prompt .. "\n")
  self.gen = (self.gen or 0) + 1
  local my_gen = self.gen
  self.is_thinking = true
  self:activity_begin("thinking")
  self:refresh_active_file()
  self.stream_started = false
  self.reasoning_text = ""
  self.stream_chars = 0

  local self_ref = self
  local function fresh() return self_ref.gen == my_gen end

  local function proceed(memory_context)
    api.send_prompt({
      prompt = prompt,
      history = self.history_data,
      model = self.model,
      selected_text = self.selected_text,
      active_file = self.active_file,
      active_file_content = self.active_file_content,
      fresh_user_turn = true,
      auto_write = self.auto_write,
      memory_context = memory_context,
      on_thinking = function(chunk)
        if not fresh() then return end
        self.reasoning_text = (self.reasoning_text or "") .. chunk
        self:activity_note("reasoning", fmt_size(#self.reasoning_text))
      end,
      on_response_start = function()
        if not fresh() then return end
        self:flush_reasoning()
        self:activity_phase("writing")
        self.stream_started = true
        self:append("\n### AI Assistant\n")
      end,
      on_delta = function(chunk)
        if not fresh() then return end
        self:stream(chunk)
        self.stream_chars = (self.stream_chars or 0) + #chunk
        self:activity_note("writing", fmt_size(self.stream_chars))
      end,
      on_status = function(phase_key, detail)
        if not fresh() then return end
        self:activity_phase(phase_key, detail)
      end,
      on_job_started = function(job)
        if fresh() then self.active_job = job end
      end,
      notify_fn = function(text)
        if not fresh() then return end
        self:flush_reasoning()
        self:append(text)
      end,
      request_tool_fn = function(tool_type, tool_arg, on_approve, on_deny)
        if not fresh() then return end
        self:flush_reasoning()
        self:activity_stop("⏳ Waiting for your approval — your turn")
        self.is_thinking = false
        local wt = { tool_type = tool_type, tool_arg = tool_arg, on_approve = on_approve, on_deny = on_deny }
        if tool_type == "write_file" then
          wt.write_diff = api.compute_write_diff(tool_arg.path, tool_arg.content)
        end
        self.waiting_for_tool = wt
        -- Show the approval UI now if a view is attached; otherwise it is parked
        -- and re-shown on the next attach (ui.open detects waiting_for_tool).
        if self.view and self.view.show_approval then
          self.view.show_approval()
        else
          self:append("\n> ⏳ tool approval pending — reopen the chat to approve.\n")
        end
      end,
    }, function(success, response, new_history)
      if not fresh() then return end
      self.is_thinking = false
      self.active_job = nil
      local fin = success and "✓ Ready" or "✗ Error"
      self:activity_stop(fin)
      if success then
        self:flush_reasoning()
        if self.stream_started then
          self:append("\n")
        elseif response and response ~= "" then
          self:append("\n### AI Assistant\n" .. response .. "\n")
        end
        if new_history then self.history_data = new_history end
        self.selected_text = nil
        M.persist(self)
      else
        self:flush_reasoning()
        local msg = (response and response ~= "") and response or "Unknown error"
        self:append("\n### Error\n" .. msg .. "\n")
        vim.notify("AI Assistant: " .. msg, vim.log.levels.WARN)
      end
      self.stream_started = false
      self:render_header(fin)
    end)
  end

  -- Pre-search engram (req: search memory FIRST), inject on the user turn. Bounded
  -- async: engram.search has a 1.5s timeout, plus a 2s belt-and-suspenders so a
  -- hung server can never stall the send. The spinner already shows "thinking".
  local settings = config.load_settings()
  if engram.enabled(settings) then
    local fired = false
    local function go(mc) if fired then return end; fired = true; if fresh() then proceed(mc) end end
    vim.defer_fn(function() go(nil) end, 2000)
    engram.search(prompt, { limit = 6 }, function(block) go(block) end)
  else
    proceed(nil)
  end
end

-- Best-effort engram auto-save when a chat is closed (once per chat per run).
function Chat:autosave_engram()
  if self.autosaved or self:is_empty() then return end
  local settings = config.load_settings()
  if not engram.enabled(settings) then return end
  self.autosaved = true
  local first_user, last_model = nil, nil
  for _, m in ipairs(self.history_data) do
    if m.role == "user" and type(m.content) == "string" and m.content ~= "" and not first_user then
      first_user = m.content
    end
    if m.role == "model" and type(m.content) == "string" and m.content ~= "" then
      last_model = m.content
    end
  end
  if not first_user then return end
  local title = "Session: " .. first_user:gsub("\n", " "):sub(1, 70)
  local content = string.format("Chat %s.\nUser asked: %s\nAssistant concluded: %s",
    self.id, first_user:sub(1, 600), (last_model or ""):sub(1, 600))
  engram.observe({ type = "discovery", title = title, content = content, topic_key = "session-" .. self.id }, function() end)
end

----------------------------------------------------------------------
-- Registry + req-4 state machine
----------------------------------------------------------------------

function M.persist(chat)
  if chat and chat.history_data and #chat.history_data > 0 then
    config.save_chat_session(chat.id, chat.history_data)
  end
end

local function new_id()
  seq = seq + 1
  return string.format("chat_%s_%03d", os.date("%Y-%m-%d_%H%M%S"), seq)
end

-- Capture the file in the current buffer (before any chat window is mounted).
local function capture_active_file()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path and path ~= "" and vim.bo[buf].buftype == "" and vim.fn.filereadable(path) == 1 then
    local size = vim.fn.getfsize(path)
    local content = ""
    if size > 0 and size < 150000 then
      local f = io.open(path, "r")
      if f then content = f:read("*all"); f:close() end
    end
    return vim.fn.fnamemodify(path, ":."), content, buf
  end
  return "", "", nil
end

-- Create a new chat, honoring "an empty chat still counts" + "no two empty chats":
-- if the current chat is already empty, reuse it instead of minting a second.
function M.new_chat()
  local cur = current_id and Chats[current_id]
  if cur and cur:is_empty() then
    current_id = cur.id
    return cur
  end
  if cur then M.persist(cur) end
  local id = new_id()
  local chat = Chat.new(id, {})
  Chats[id] = chat
  current_id = id
  return chat
end

-- The chat <leader>cc should land on: the in-memory current chat, else the most
-- recent on disk (hydrated), else a fresh empty one.
local function most_recent_or_new()
  if current_id and Chats[current_id] then return Chats[current_id] end
  local sessions = config.list_chat_sessions()
  if #sessions > 0 then
    local id = sessions[1].id
    if Chats[id] then current_id = id; return Chats[id] end
    local hist = config.load_chat_session(id)
    if hist then
      local chat = Chat.new(id, hist)
      Chats[id] = chat
      current_id = id
      return chat
    end
  end
  return M.new_chat()
end

-- Add a visual selection to a chat (req 3): set it as pending context and show it.
function M.add_selection(chat, text)
  if not text or text == "" then return end
  chat.selected_text = text
  if chat.selection_shown ~= text then
    chat.selection_shown = text
    chat:append(string.format("\n### Context: Selected Code\n```\n%s\n```\n", text))
  end
end

-- One-time-ish engram liveness check on open ("check the mcp connection").
local function check_health(chat)
  if config.load_settings().engram_enabled == false then return end
  engram.health(function(ok)
    chat.engram_ok = ok
    chat:render_header()
    if not ok and not health_notified then
      health_notified = true
      vim.notify(
        "AI Assistant: engram memory server not reachable on 127.0.0.1:7437 — memory disabled this session. Start it with `systemctl --user start engram`.",
        vim.log.levels.WARN)
    end
  end)
end

-- <leader>cc entry. Opens the most-recent chat; toggles closed if already open
-- (the running agent survives); pastes a visual selection if one was passed.
function M.open_recent(selected_text)
  local ui = require("ai_assistant.ui")
  local chat = current_id and Chats[current_id]
  if chat and chat.view then
    if selected_text and selected_text ~= "" then
      M.add_selection(chat, selected_text)
      ui.focus_input(chat)
    else
      ui.close(chat)
    end
    return
  end
  chat = most_recent_or_new()
  chat.active_file, chat.active_file_content, chat.active_buf = capture_active_file()
  ui.open(chat)
  check_health(chat)
  if selected_text and selected_text ~= "" then
    M.add_selection(chat, selected_text)
  end
end

-- Open a specific chat by id (from "View Previous Chats" → resume). Reuses the
-- in-memory object if present (don't drop a running job by reloading from disk).
function M.open_id(id)
  local ui = require("ai_assistant.ui")
  local chat = Chats[id]
  if not chat then
    local hist = config.load_chat_session(id)
    chat = Chat.new(id, hist or {})
    Chats[id] = chat
  end
  current_id = id
  chat.active_file, chat.active_file_content, chat.active_buf = capture_active_file()
  ui.open(chat)
  check_health(chat)
end

-- "➕ New Chat" from the history screen: create (or reuse an empty) chat and open.
function M.new_and_open()
  local ui = require("ai_assistant.ui")
  local chat = M.new_chat()
  chat.active_file, chat.active_file_content, chat.active_buf = capture_active_file()
  ui.open(chat)
  check_health(chat)
end

-- <leader>ci / <C-c>: interrupt the running agent (focused chat first).
function M.interrupt_active()
  local chat = current_id and Chats[current_id]
  if not (chat and chat.is_thinking) then
    chat = nil
    for _, c in pairs(Chats) do
      if c.is_thinking then chat = c; break end
    end
  end
  if chat and chat.is_thinking then
    chat:cancel()
  else
    vim.notify("AI Assistant: no running agent to interrupt.", vim.log.levels.INFO)
  end
end

M.PHASES = PHASES

return M
