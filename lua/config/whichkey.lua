-- =============================================================================
-- which-key.nvim (v3) configuration
-- -----------------------------------------------------------------------------
-- Pops up a cheatsheet of available keybindings whenever you start a key
-- sequence (e.g. press <leader> and wait). which-key reads the `desc` field of
-- every keymap automatically, so the work here is just:
--   1. Tune how/when the popup appears (setup).
--   2. Give human-friendly NAMES to the <leader> prefix GROUPS (spec).
--
-- Buffer-local groups (LSP / JDTLS, e.g. <leader>e) are registered on attach in
-- lua/jdtls/utils.lua so they only show up inside Java buffers.
-- The individual keymaps live in:
--   - lua/config/remap.lua        (global maps + fzf-lua search)
--   - lua/plugins/harpoon.lua     (harpoon navigation)
--   - lua/plugins/ai_assistant.lua(AI chat, via lazy `keys`)
--   - lua/jdtls/utils.lua         (LSP / JDTLS, buffer-local)
-- =============================================================================

local wk = require("which-key")

wk.setup({
  -- "classic" | "modern" | "helix" -- overall look of the popup.
  preset = "modern",

  -- Delay (ms) before the popup shows after pressing a prefix key.
  delay = 200,

  icons = {
    -- Auto-detect an icon per mapping (needs web-devicons / mini.icons).
    mappings = true,
    -- Prefix shown in front of a group's name.
    group = "+",
  },

  win = {
    -- Border is inherited from the global `winborder = 'rounded'` (set.lua).
    padding = { 1, 2 },
    title = true,
    title_pos = "center",
  },

  -- GLOBAL prefix groups. These only NAME the menus; the individual keys under
  -- each prefix are picked up automatically from their own `desc`.
  --
  -- NOTE: Do NOT register a key as a `group` if it is ALSO a direct mapping.
  -- <leader>ps is mapped directly to fzf-lua.live_grep in remap.lua, so it
  -- must NOT be listed here. which-key v3 auto-detects its children (psf, psg,
  -- psb, psr) from the existing keymaps.
  spec = {
    { "<leader>p",  group = "Project / Files" },  -- pv (explorer) + ps* (search)
    { "<leader>c",  group = "Code / AI" },         -- cc/cx/cp (AI) + ca/ca (LSP)
  },
})

-- Show the keymaps that only exist in the CURRENT buffer (handy for inspecting
-- the LSP / JDTLS maps that attach to Java files).
vim.keymap.set("n", "<leader>?", function()
  wk.show({ global = false })
end, { desc = "Which-Key: Buffer Local Keymaps" })

-- =============================================================================
-- Cheat-sheet: surface the custom NON-leader keys inside the <leader> popup.
-- ------------------------------------------------------------------------------
-- Harpoon (<C-...>), the centered half-page scrolls (<C-d>/<C-u>) and the
-- visual-mode line moves don't live under <leader>, so they'd never appear in
-- the popup. These are REFERENCE-ONLY entries (no action) -- the real key is
-- the chord shown in [brackets]; pressing the entry itself does nothing. They
-- just make "what custom keys do I have?" answerable straight from <leader>.
--
-- The sub-keys are sequential (a..j) on purpose: which-key sorts entries
-- alphanumerically, so this keeps the list in a clean, grouped reading order.
-- =============================================================================
-- Build a reference-only cheat-sheet entry: a <Nop> mapping (truly does nothing
-- when pressed) that carries a label + icon. which-key v3 only reads positional
-- [1]=lhs and [2]=rhs; desc/icon MUST be named fields (a table at index [3] is
-- parsed as a child mapping and silently dropped), and the rhs must be a real
-- no-op -- the previous vim.notify rhs ERRORED when the chord was pressed.
local function cheat(lhs, desc)
  return { lhs, "<Nop>", desc = desc, icon = "󰋽 " }
end

wk.add({
  { "<leader>k", group = "Cheat-sheet (custom keys)" },

  -- Harpoon -- quick file jump list (lua/plugins/harpoon.lua)
  cheat("<leader>ka", "[Ctrl-e]  Harpoon: Toggle Quick Menu"),
  cheat("<leader>kb", "[Ctrl-h]  Harpoon: Go to File 1"),
  cheat("<leader>kc", "[Ctrl-t]  Harpoon: Go to File 2"),
  cheat("<leader>kd", "[Ctrl-n]  Harpoon: Go to File 3"),
  cheat("<leader>ke", "[Ctrl-s]  Harpoon: Go to File 4"),

  -- Scrolling -- keeps the cursor centered (lua/config/remap.lua)
  cheat("<leader>kf", "[Ctrl-d]  Scroll Half-Page Down (centered)"),
  cheat("<leader>kg", "[Ctrl-u]  Scroll Half-Page Up (centered)"),

  -- Visual mode line moves (lua/config/remap.lua)
  cheat("<leader>kh", "[J] in visual mode  Move Selection Down"),
  cheat("<leader>ki", "[K] in visual mode  Move Selection Up"),

  -- Pointer to the buffer-local LSP / JDTLS maps (Java files only)
  cheat("<leader>kj", "Java / LSP keys -> press <leader>? inside a .java buffer"),
})
