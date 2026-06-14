return {
  {
    "nvim-treesitter/nvim-treesitter",
    -- Pin to the classic `master` branch explicitly. The repo's default branch
    -- is now `main` (a full rewrite that requires the external `tree-sitter`
    -- CLI to compile parsers); `master` compiles parsers with the system C
    -- compiler, so no extra tooling is needed.
    branch = "master",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    dependencies = {
      { "nvim-treesitter/nvim-treesitter-textobjects", branch = "master" },
    },
    config = function()
      require("nvim-treesitter.configs").setup({
        sync_install = false,
        modules = {},
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        ignore_install = { "php" },
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
          "xml",
          "zig",
        },
      })

      -- --------------------------------------------------------------------
      -- Neovim 0.12 compatibility shim for the archived `master` branch.
      --
      -- master's markdown injection query (queries/markdown/injections.scm)
      -- uses the `#set-lang-from-info-string!` directive, registered with the
      -- legacy `{ all = false }` option so its handler expected match[id] to be
      -- a single TSNode. Neovim 0.12 removed `all = false`: directive handlers
      -- now always receive a LIST of nodes, so `node:range()` is nil and opening
      -- any markdown file containing a fenced code block crashes with
      --   "attempt to call method 'range' (a nil value)".
      --
      -- Re-register the directive (force) with a list-aware handler that mirrors
      -- master's own alias resolution (vim.filetype.match + a small fallback).
      -- require() the predicates module first so our override wins (last writer).
      -- --------------------------------------------------------------------
      pcall(require, "nvim-treesitter.query_predicates")

      local aliases = { ex = "elixir", pl = "perl", sh = "bash", uxn = "uxntal", ts = "typescript" }
      local function lang_from_info(alias)
        return vim.filetype.match({ filename = "a." .. alias }) or aliases[alias] or alias
      end

      vim.treesitter.query.add_directive("set-lang-from-info-string!", function(match, _, bufnr, pred, metadata)
        local node = match[pred[2]]
        -- 0.12 passes a node list; older versions a single node.
        if type(node) == "table" then
          node = node[#node]
        end
        if not node then
          return
        end
        local alias = vim.treesitter.get_node_text(node, bufnr):lower()
        metadata["injection.language"] = lang_from_info(alias)
      end, { force = true })
    end,
  },
}
