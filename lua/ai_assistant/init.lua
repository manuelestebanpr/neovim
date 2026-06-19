local M = {}

function M.setup(opts)
  -- <leader>cc : open the most-recent chat (or toggle it closed); pastes a visual
  -- selection into the chat's pending context when invoked from visual mode.
  vim.api.nvim_create_user_command("AIChatToggle", function()
    local chat = require("ai_assistant.chat")
    local selected = nil
    if vim.fn.mode():match("[vV\22]") then
      selected = require("ai_assistant.config").get_visual_selection()
    end
    chat.open_recent(selected)
  end, { range = true })

  -- <leader>cx : settings menu (API keys, default model, previous chats, the two
  -- toggles, command denylist).
  vim.api.nvim_create_user_command("AIContextManage", function()
    require("ai_assistant.ui").manage_context()
  end, {})

  -- <leader>ci : interrupt the running agent (works whether or not the window is open).
  vim.api.nvim_create_user_command("AIInterrupt", function()
    require("ai_assistant.chat").interrupt_active()
  end, {})
end

return M
