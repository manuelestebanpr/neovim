-- Disable netrw entirely (must run before plugins are sourced). mini.files is the
-- file explorer and is set up as the default directory handler -- see
-- lua/plugins/minifiles.lua (use_as_default_explorer).
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

require("config")
