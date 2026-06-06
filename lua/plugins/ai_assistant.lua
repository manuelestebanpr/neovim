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
      { "<leader>cc", "<cmd>AIChatToggle<CR>", mode = { "n", "v" }, desc = "Toggle AI Chat" },
      { "<leader>cx", "<cmd>AIContextManage<CR>", mode = { "n" }, desc = "Manage AI Context" },
      { "<leader>cp", "<cmd>AICreateProjectContext<CR>", mode = { "n" }, desc = "Create Project Context" },
    },
  }
}
