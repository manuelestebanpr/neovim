return {
  {
    "nvim-treesitter/nvim-treesitter",
    version = false,
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter-textobjects",
    },
    config = function()
      require("nvim-treesitter.configs").setup({
        ignore_install = {"TSConfig"},
        sync_install = false,
        modules = {},
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        indent = { enable = true },
        auto_install = false,
        ensure_installed = {
          "bash",
          "c",
          "css",
          "html",
          "javascript",
          "json",
          "lua",
          "luadoc",
          "luap",
          "markdown",
          "markdown_inline",
          "query",
          "regex",
          "tsx",
          "typescript",
          "vim",
          "vimdoc",
          "yaml",
          "rust",
          "go",
          "gomod",
          "gowork",
          "gosum",
          "svelte",
          "java",
          "zig",

        },
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = "<leader>vv",
            node_incremental = "+",
            scope_incremental = false,
            node_decremental = "_",
          },
        },
      })
    end,
  },
}
