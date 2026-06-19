return {
  {
    "ai_assistant",
    dir = vim.fn.stdpath("config"),
    dependencies = {
      "MunifTanjim/nui.nvim",
      "nvim-lua/plenary.nvim",
    },
    config = function()
      require("ai_assistant").setup()
    end,
    keys = {
      { "<leader>cc", "<cmd>AIChatToggle<CR>", mode = { "n", "v" }, desc = "AI Chat (most recent / toggle)" },
      { "<leader>cx", "<cmd>AIContextManage<CR>", mode = { "n" }, desc = "AI Settings" },
      { "<leader>ci", "<cmd>AIInterrupt<CR>", mode = { "n" }, desc = "AI Interrupt agent" },
    },
  },
}
