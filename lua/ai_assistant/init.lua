local M = {}

function M.setup(opts)
  -- Register User Commands
  vim.api.nvim_create_user_command("AIChatToggle", function()
    local config = require("ai_assistant.config")
    local ui = require("ai_assistant.ui")
    
    -- Extract visual selection if visual mode was active
    local selected = config.get_visual_selection()
    
    -- Launch or hide the Chat Layout
    ui.toggle_chat(selected)
  end, { range = true })

  vim.api.nvim_create_user_command("AIContextManage", function()
    local ui = require("ai_assistant.ui")
    ui.manage_context()
  end, {})

  vim.api.nvim_create_user_command("AICreateProjectContext", function()
    local config = require("ai_assistant.config")
    config.init_project_context()
  end, {})

  -- Build the local semantic (RAG) index for the current project.
  vim.api.nvim_create_user_command("AIIndexProject", function()
    require("ai_assistant.rag").build_index()
  end, {})

  -- Toggle semantic retrieval on/off.
  vim.api.nvim_create_user_command("AIRagToggle", function()
    local config = require("ai_assistant.config")
    local settings = config.load_settings()
    settings.rag_enabled = not settings.rag_enabled
    config.save_settings(settings)
    vim.notify("AI Assistant: semantic retrieval (RAG) " .. (settings.rag_enabled and "ENABLED" or "DISABLED"), vim.log.levels.INFO)
  end, {})
end

return M
