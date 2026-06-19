-- lua/ai_assistant/ui.lua
-- The chat VIEW. A view is a mounted nui Layout (header + input) whose history
-- window displays the Chat's PERSISTENT buffer (chat.bufnr, owned by chat.lua).
-- Opening = mount + point the history window at chat.bufnr; closing = unmount the
-- windows only (the Chat + its running agent survive). All durable state lives on
-- the Chat; this module just renders it and wires the four controls (send, @, model,
-- close) + interrupt + tool approval, plus the trimmed <leader>cx settings menu.

local M = {}
local config = require("ai_assistant.config")
local api = require("ai_assistant.api")
local Chat = require("ai_assistant.chat")

-- Foldtext for the collapsible cards (tool output, diffs, reasoning). Referenced
-- by the window's foldtext option string, so it must live on this module.
function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart) or ""
  line = line:gsub("%s*" .. vim.pesc(api.FOLD_OPEN) .. "%s*$", "")
  local n = vim.v.foldend - vim.v.foldstart - 1
  if n < 0 then n = 0 end
  return string.format("%s  ⏷ %d line%s — za", line, n, n == 1 and "" or "s")
end

-- Make a window render fold-marker cards collapsed-by-default and conceal markers.
-- Window-scoped, so it must run on every attach.
local function setup_history_folds(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  pcall(function()
    vim.wo[win].foldmethod = "marker"
    vim.wo[win].foldmarker = api.FOLD_OPEN .. "," .. api.FOLD_CLOSE
    vim.wo[win].foldtext = "v:lua.require'ai_assistant.ui'.foldtext()"
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 0
    vim.wo[win].fillchars = "fold: "
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nvic"
    vim.wo[win].wrap = true
  end)
  pcall(vim.api.nvim_win_call, win, function()
    vim.fn.matchadd("Conceal", api.FOLD_OPEN, 10, -1, { conceal = "" })
    vim.fn.matchadd("Conceal", api.FOLD_CLOSE, 10, -1, { conceal = "" })
  end)
end

----------------------------------------------------------------------
-- Model picker
----------------------------------------------------------------------

function M.select_model(callback, allow_back)
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event

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
      -- Fallback presets from config.MODELS (kimi + claude lead, then gemini).
      local presets = {}
      for _, prov in ipairs({ "moonshot", "anthropic", "gemini" }) do
        for _, m in ipairs((config.MODELS or {})[prov] or {}) do
          table.insert(presets, { text = m, id = m })
        end
      end
      local flagship = (config.MODELS.anthropic or {})[1]
      if flagship then
        table.insert(presets, { text = flagship .. " (High Effort)", id = flagship .. "-high" })
      end
      table.insert(presets, { text = "ollama (Local)", id = "ollama" })
      table.insert(presets, { text = "llama-server (Local)", id = "llamacpp:local-model" })
      for _, m in ipairs(presets) do
        table.insert(lines, Menu.item(m.text, { id = m.id }))
      end
    end

    local menu = Menu({
      position = "50%",
      size = { width = 48, height = math.min(18, #lines + 2) },
      border = { style = "rounded", text = { top = " Select Model ", top_align = "center" } },
      buf_options = { modifiable = true, readonly = false },
      win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
    }, {
      lines = lines,
      on_submit = function(item)
        if not item or item.id == nil then return end
        if item.id == "back" then
          M.manage_context()
        else
          callback(item.id)
        end
      end,
    })
    menu:mount()
    menu:on(event.BufLeave, function() menu:unmount() end)
  end)
end

----------------------------------------------------------------------
-- @ picker (files + skills)
----------------------------------------------------------------------

-- Enumerate available skills: <root>/.claude/skills/<name>/SKILL.md (project) and
-- ~/.claude/skills/<name>/SKILL.md (user). Tolerates missing dirs.
local function list_skills(root)
  local out, seen = {}, {}
  for _, d in ipairs({ root .. "/.claude/skills", vim.fn.expand("~/.claude/skills") }) do
    if vim.fn.isdirectory(d) == 1 then
      for name, ftype in vim.fs.dir(d) do
        if ftype == "directory" and not seen[name]
            and vim.fn.filereadable(d .. "/" .. name .. "/SKILL.md") == 1 then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    end
  end
  table.sort(out)
  return out
end

-- Open an fzf-lua picker over project files AND skills; insert the chosen mention
-- into the input. `prefix` is prepended to the inserted token (default "@"); pass
-- "" when the caller already inserted a literal "@".
local function open_at_picker(chat, prefix)
  prefix = prefix or "@"
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("AI Assistant: fzf-lua not available for the @ picker.", vim.log.levels.WARN)
    return false
  end
  local root = config.get_project_root()
  local entries = {}
  for _, s in ipairs(list_skills(root)) do entries[#entries + 1] = "skill: " .. s end
  local files = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard" })
  if vim.v.shell_error ~= 0 or #files == 0 then
    files = vim.fn.systemlist({ "rg", "--files", root })
    for i, f in ipairs(files) do files[i] = f:gsub("^" .. vim.pesc(root) .. "/", "") end
  end
  for _, f in ipairs(files) do entries[#entries + 1] = f end

  fzf.fzf_exec(entries, {
    prompt = "@file/skill> ",
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local pick = (selected[1] or ""):gsub("^%s+", "")
        local sk = pick:match("^skill:%s*(.+)$")
        local insert = sk and (prefix .. "skill:" .. sk) or (prefix .. pick)
        vim.schedule(function()
          local v = chat.view
          if v and v.input and v.input.winid and vim.api.nvim_win_is_valid(v.input.winid) then
            vim.fn.win_gotoid(v.input.winid)
            vim.api.nvim_put({ insert .. " " }, "c", true, true)
            vim.cmd("startinsert")
          end
        end)
      end,
    },
  })
  return true
end

----------------------------------------------------------------------
-- <leader>cx settings menu (trimmed to the six kept items)
----------------------------------------------------------------------

local function configure_api_keys()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local lines = {
    Menu.item("< Back to Settings", { id = "back" }),
    Menu.separator("Providers"),
    Menu.item("Gemini", { id = "gemini" }),
    Menu.item("Anthropic (Claude)", { id = "anthropic" }),
    Menu.item("Moonshot (Kimi)", { id = "moonshot" }),
    Menu.item("Ollama (Local)", { id = "ollama" }),
    Menu.item("llama.cpp (llama-server)", { id = "llamacpp" }),
  }
  local menu = Menu({
    position = "50%",
    size = { width = 45, height = math.min(12, #lines + 2) },
    border = { style = "rounded", text = { top = " Configure API Keys ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = lines,
    on_submit = function(item)
      if not item or item.id == nil then return end
      if item.id == "back" then M.manage_context(); return end
      if item.id == "llamacpp" then
        local settings = config.load_settings()
        local url = vim.fn.input("llama-server URL: ", config.get_llama_server_url(settings))
        if url ~= "" then settings.llama_server_url = url end
        local key = vim.fn.inputsecret("llama-server API key (blank = keep current): ")
        if key ~= "" then settings.api_keys.llamacpp = key end
        config.save_settings(settings)
        vim.notify("AI Assistant: llama-server set to " .. config.get_llama_server_url(settings), vim.log.levels.INFO)
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
    end,
  })
  menu:mount()
  menu:on(event.BufLeave, function() menu:unmount() end)
end

local function manage_denylist()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local menu = Menu({
    position = "50%",
    size = { width = 45, height = 7 },
    border = { style = "rounded", text = { top = " Command Denylist ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = {
      Menu.item("< Back to Settings", { act = "back" }),
      Menu.separator("Actions"),
      Menu.item("1. Add Pattern", { act = "add" }),
      Menu.item("2. Delete Pattern", { act = "del" }),
      Menu.item("3. List Patterns", { act = "list" }),
    },
    on_submit = function(item)
      if item.act == "back" then
        M.manage_context()
      elseif item.act == "add" then
        local pat = vim.fn.input("Enter Lua pattern to block: ")
        if pat == "" then M.manage_context(); return end
        local settings = config.load_settings()
        table.insert(settings.command_denylist, pat)
        config.save_settings(settings)
        vim.notify(string.format("AI Assistant: Pattern '%s' added to denylist!", pat), vim.log.levels.INFO)
        M.manage_context()
      elseif item.act == "del" then
        local settings = config.load_settings()
        local lines = { Menu.item("< Back to Settings", { id = "back" }), Menu.separator("Block Patterns") }
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
          size = { width = 45, height = math.min(12, #lines + 2) },
          border = { style = "rounded", text = { top = " Select Pattern to Delete ", top_align = "center" } },
          buf_options = { modifiable = true, readonly = false },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
        }, {
          lines = lines,
          on_submit = function(del_item)
            if del_item.id == "back" then M.manage_context(); return end
            table.remove(settings.command_denylist, del_item.id)
            config.save_settings(settings)
            vim.notify("AI Assistant: Pattern removed from denylist.", vim.log.levels.INFO)
            M.manage_context()
          end,
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
          border = { style = "rounded", text = { top = " Command Denylist (Press 'q' to go back) ", top_align = "center" } },
          win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
        })
        list_popup:mount()
        list_popup:on(event.BufLeave, function() list_popup:unmount() end)
        local pat_lines = { " Command Denylist", " ================", "" }
        for _, pat in ipairs(settings.command_denylist) do
          table.insert(pat_lines, "- " .. pat)
        end
        if #settings.command_denylist == 0 then table.insert(pat_lines, "Denylist is empty.") end
        vim.api.nvim_buf_set_lines(list_popup.bufnr, 0, -1, false, pat_lines)
        list_popup:map("n", "q", function()
          list_popup:unmount()
          manage_denylist()
        end)
      end
    end,
  })
  menu:mount()
  menu:on(event.BufLeave, function() menu:unmount() end)
end

local view_previous_chats -- forward declare

local function show_session_actions(session_item)
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local action_menu = Menu({
    position = "50%",
    size = { width = 45, height = 6 },
    border = { style = "rounded", text = { top = " Action: " .. session_item.id:gsub("^chat_", "") .. " ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = {
      Menu.item("< Back to Saved Chats", { act = "back" }),
      Menu.item("1. Resume Chat", { act = "resume" }),
      Menu.item("2. Delete Chat", { act = "delete" }),
    },
    on_submit = function(action_item)
      if action_item.act == "back" then
        view_previous_chats()
      elseif action_item.act == "resume" then
        Chat.open_id(session_item.id)
      elseif action_item.act == "delete" then
        local confirm = vim.fn.input(string.format("Delete chat '%s'? (y/n): ", session_item.id))
        if confirm:lower() == "y" or confirm:lower() == "yes" then
          config.delete_chat_session(session_item.id)
          vim.notify("AI Assistant: Chat deleted.", vim.log.levels.INFO)
        end
        view_previous_chats()
      end
    end,
  })
  action_menu:mount()
  action_menu:on(event.BufLeave, function() action_menu:unmount() end)
end

view_previous_chats = function()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local sessions = config.list_chat_sessions()
  local lines = {
    Menu.item("➕ New Chat", { id = "__new__" }),
    Menu.separator("Recent Chats"),
  }
  for _, s in ipairs(sessions) do
    table.insert(lines, Menu.item(s.display, { id = s.id }))
  end
  if #sessions == 0 then
    table.insert(lines, Menu.item("(no saved chats yet)", { id = nil }))
  end
  local menu = Menu({
    position = "50%",
    size = { width = 78, height = math.min(16, #lines + 2) },
    border = { style = "rounded", text = { top = " View Previous Chats ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = lines,
    on_submit = function(item)
      if not item or item.id == nil then return end
      if item.id == "__new__" then
        Chat.new_and_open()
        return
      end
      show_session_actions(item)
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
  elseif action == "view_history" then
    view_previous_chats()
  elseif action == "toggle_auto_approve" then
    local settings = config.load_settings()
    settings.auto_approve_tools = not settings.auto_approve_tools
    config.save_settings(settings)
    vim.notify("AI Assistant: Tool approval " .. (settings.auto_approve_tools and "OFF (tools auto-run)" or "ON (you approve tools)"), vim.log.levels.INFO)
    M.manage_context()
  elseif action == "toggle_auto_write" then
    local settings = config.load_settings()
    settings.auto_write_files = not settings.auto_write_files
    config.save_settings(settings)
    vim.notify("AI Assistant: File writes default to " .. (settings.auto_write_files and "AUTO" or "REVIEW (diff)"), vim.log.levels.INFO)
    M.manage_context()
  elseif action == "manage_denylist" then
    manage_denylist()
  end
end

function M.manage_context()
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local settings = config.load_settings()
  local menu = Menu({
    position = "50%",
    size = { width = 52, height = 10 },
    border = { style = "rounded", text = { top = " AI Assistant Settings ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = {
      Menu.item("1. Configure API Keys", { action = "keys" }),
      Menu.item("2. Set Default Model (" .. (settings.default_model or "?") .. ")", { action = "default_model" }),
      Menu.item("3. View Previous Chats", { action = "view_history" }),
      Menu.item("4. Tool Approval: " .. (settings.auto_approve_tools and "OFF (auto-run)" or "ON (ask first)"), { action = "toggle_auto_approve" }),
      Menu.item("5. Auto-Write Files: " .. (settings.auto_write_files and "ON (apply)" or "OFF (review diff)"), { action = "toggle_auto_write" }),
      Menu.item("6. Manage Command Denylist", { action = "manage_denylist" }),
    },
    on_submit = function(item)
      M.handle_context_action(item.action)
    end,
  })
  menu:mount()
  menu:on(event.BufLeave, function() menu:unmount() end)
end

----------------------------------------------------------------------
-- The view: open / close / focus
----------------------------------------------------------------------

function M.focus_input(chat)
  local v = chat.view
  if v and v.input and v.input.winid and vim.api.nvim_win_is_valid(v.input.winid) then
    vim.fn.win_gotoid(v.input.winid)
  end
end

function M.close(chat)
  local v = chat.view
  if not v then return end
  chat:on_detach()
  if chat.diff_popup then
    pcall(function() chat.diff_popup:unmount() end)
    chat.diff_popup = nil
  end
  pcall(function() v.layout:unmount() end)
  chat.view = nil
  Chat.persist(chat)
  chat:autosave_engram()
end

local DEFAULT_INPUT_TOP = " Ctrl-S/CR Send · @ files/skills · Tab Model · Esc Close · <leader>ci Interrupt "

function M.open(chat)
  -- Already attached: just focus.
  if chat.view then
    M.focus_input(chat)
    return
  end

  local Popup = require("nui.popup")
  local Layout = require("nui.layout")

  local header = Popup({
    border = { style = "rounded", text = { top = " AI Assistant ", top_align = "center" } },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  })
  local history = Popup({
    border = { style = "rounded", text = { top = " Chat History ", top_align = "center" } },
    buf_options = { modifiable = false, readonly = true },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder", wrap = true },
  })
  local input = Popup({
    border = { style = "rounded", text = { top = DEFAULT_INPUT_TOP, top_align = "center" } },
    buf_options = { modifiable = true },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder", wrap = true },
  })

  local layout = Layout(
    { position = "50%", size = { width = "80%", height = "85%" } },
    Layout.Box({
      Layout.Box(header, { size = 5 }),
      Layout.Box(history, { size = "73%" }),
      Layout.Box(input, { size = "20%" }),
    }, { dir = "col" })
  )
  layout:mount()

  -- Point the history window at the Chat's PERSISTENT buffer. nui owns the throwaway
  -- buffer it created for `history` (deleted on unmount); chat.bufnr is bufhidden=hide
  -- so closing the window just hides it — the transcript + in-flight stream survive.
  pcall(vim.api.nvim_win_set_buf, history.winid, chat.bufnr)
  setup_history_folds(history.winid)

  chat.view = { header = header, input = input, history_win = history.winid, layout = layout }

  -- Approval UI (built from chat.waiting_for_tool; reused on first request AND on
  -- re-attach when an approval was parked while the window was closed).
  local function show_approval()
    local wt = chat.waiting_for_tool
    if not wt then return end
    if wt.tool_type == "write_file" then
      local wd = wt.write_diff or api.compute_write_diff(wt.tool_arg.path, wt.tool_arg.content)
      chat:append(string.format("\n> ✎ review write `%s` (+%d/-%d) — **a** accept · **r** reject\n",
        tostring(wt.tool_arg.path), wd.added, wd.removed))
      local diff_lines = (wd.diff == "") and { "(no textual changes)" } or vim.split(wd.diff, "\n", { plain = true })
      local dpop = Popup({
        position = "50%",
        size = { width = "72%", height = "55%" },
        enter = true,
        focusable = true,
        border = { style = "rounded", text = { top = string.format(" %s %s  (a accept · r reject · q defer) ", wd.kind, tostring(wt.tool_arg.path)), top_align = "center" } },
        buf_options = { filetype = "diff", modifiable = false },
        win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder", wrap = false },
      })
      dpop:mount()
      vim.bo[dpop.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(dpop.bufnr, 0, -1, false, diff_lines)
      vim.bo[dpop.bufnr].modifiable = false
      local accept = function()
        chat:append_fold(string.format("> ✔ wrote `%s` (+%d/-%d)", tostring(wt.tool_arg.path), wd.added, wd.removed),
          wd.diff ~= "" and wd.diff or "(no textual changes)")
        chat:resolve_tool(true)
      end
      dpop:map("n", "a", accept, { noremap = true })
      dpop:map("n", "<CR>", accept, { noremap = true })
      dpop:map("n", "r", function() chat:resolve_tool(false) end, { noremap = true })
      dpop:map("n", "d", function() chat:resolve_tool(false) end, { noremap = true })
      dpop:map("n", "<Esc>", function() chat:resolve_tool(false) end, { noremap = true })
      dpop:map("n", "q", function()
        pcall(function() dpop:unmount() end)
        chat.diff_popup = nil
        M.focus_input(chat)
      end, { noremap = true })
      chat.diff_popup = dpop
      pcall(function() input.border:set_text("top", " Accept (a) / Reject (r) in the diff — or type y/n ") end)
    else
      local label = (wt.tool_type == "command") and ("run `" .. tostring(wt.tool_arg) .. "`")
        or ("read `" .. tostring(wt.tool_arg) .. "`")
      chat:append(string.format("\n> ⚠ approve %s ? — type **y** / **n**\n", label))
      pcall(function() input.border:set_text("top", " Approve tool? (y / n) ") end)
      M.focus_input(chat)
    end
  end

  local function dismiss_approval()
    if chat.diff_popup then
      pcall(function() chat.diff_popup:unmount() end)
      chat.diff_popup = nil
    end
    pcall(function() input.border:set_text("top", DEFAULT_INPUT_TOP) end)
    M.focus_input(chat)
  end

  chat.view.show_approval = show_approval
  chat.view.dismiss_approval = dismiss_approval

  -- Render current state + resume the spinner if a request is still in flight.
  chat:render_header(chat.is_thinking and nil or chat.final_text)
  chat:on_attach()

  -- Scroll to bottom + recompute folds (scheduled to dodge the treesitter race).
  vim.schedule(function()
    if chat.view and vim.api.nvim_win_is_valid(history.winid) and vim.api.nvim_buf_is_valid(chat.bufnr) then
      pcall(vim.api.nvim_win_call, history.winid, function() vim.cmd("silent! normal! zx") end)
      pcall(vim.api.nvim_win_set_cursor, history.winid, { vim.api.nvim_buf_line_count(chat.bufnr), 0 })
    end
  end)

  -- Re-show a tool approval that was parked while the window was closed.
  if chat.waiting_for_tool then
    vim.schedule(show_approval)
  end

  M.focus_input(chat)

  -- ── controls ──────────────────────────────────────────────────────────────
  local function cancel_or_close()
    if chat.is_thinking then chat:cancel() else M.close(chat) end
  end

  local function submit_fn()
    if chat.is_thinking then
      vim.notify("AI Assistant: working — press <Esc> or <leader>ci to interrupt.", vim.log.levels.WARN)
      return
    end
    local prompt = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input.bufnr, 0, -1, false), "\n"))

    -- Typed y/n fallback for a pending tool approval (diff popup also takes a/r).
    if chat.waiting_for_tool then
      local choice = prompt:lower()
      vim.api.nvim_buf_set_lines(input.bufnr, 0, -1, false, {})
      if choice == "y" or choice == "yes" then
        chat:resolve_tool(true)
      elseif choice == "n" or choice == "no" then
        chat:resolve_tool(false)
      else
        vim.notify("AI Assistant: type 'y'/'n' (or press a/r in the diff window).", vim.log.levels.WARN)
      end
      return
    end

    if prompt == "" then
      if chat.selected_text and chat.selected_text ~= "" then
        prompt = "Analyze the selected code, explain what it does, highlight potential issues, and suggest improvements."
      else
        vim.notify("AI Assistant: prompt cannot be empty.", vim.log.levels.WARN)
        return
      end
    end
    vim.api.nvim_buf_set_lines(input.bufnr, 0, -1, false, {})
    chat:send(prompt)
  end

  local function model_menu_fn()
    if chat.is_thinking then
      vim.notify("AI Assistant: working — interrupt first (<leader>ci).", vim.log.levels.WARN)
      return
    end
    M.select_model(function(model)
      chat.model = model
      chat:render_header(chat.final_text)
      M.focus_input(chat)
    end)
  end

  local function file_picker_fn() open_at_picker(chat, "@") end
  local function at_fn()
    vim.api.nvim_put({ "@" }, "c", true, true)
    if pcall(require, "fzf-lua") then
      vim.schedule(function() open_at_picker(chat, "") end)
    end
  end

  -- Input keymaps (the four controls + interrupt).
  input:map("n", "<CR>", submit_fn, { noremap = true })
  input:map("n", "<C-s>", submit_fn, { noremap = true })
  input:map("i", "<C-s>", submit_fn, { noremap = true })
  input:map("n", "<Tab>", model_menu_fn, { noremap = true })
  input:map("i", "<Tab>", model_menu_fn, { noremap = true })
  input:map("i", "@", at_fn, { noremap = true })
  input:map("i", "<C-f>", file_picker_fn, { noremap = true })
  input:map("n", "<C-f>", file_picker_fn, { noremap = true })
  input:map("n", "<Esc>", cancel_or_close, { noremap = true })
  input:map("n", "<C-c>", cancel_or_close, { noremap = true })
  input:map("i", "<C-c>", cancel_or_close, { noremap = true })
  input:map("i", "<Esc>", function()
    if chat.is_thinking then chat:cancel() else vim.cmd("stopinsert") end
  end, { noremap = true })

  -- Esc / Ctrl-c also work when focus is on the output (history) window.
  vim.keymap.set("n", "<Esc>", cancel_or_close, { buffer = chat.bufnr, noremap = true })
  vim.keymap.set("n", "<C-c>", cancel_or_close, { buffer = chat.bufnr, noremap = true })
end

return M
