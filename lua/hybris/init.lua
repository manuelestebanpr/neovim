-- =============================================================================
-- Hybris Type System integration for Neovim (EPAM-plugin parity, the portable
-- subset). Wires the items.xml index (hybris.types) into:
--   * a custom nvim-cmp source for items.xml + ImpEx (ItemType / attribute names)
--   * ImpEx filetype detection (+ syntax/impex.vim highlighting)
--   * a fuzzy "Type System" picker (:HybrisTypes / <leader>ht)
--   * go-to-definition for the type/enum under the cursor (<leader>hd)
--   * :HybrisReindexTypes to force a rebuild
-- The index loads from a disk cache instantly after the first session; the first
-- build is chunked async so it never freezes the UI.
-- =============================================================================

local M = {}
local T = require('hybris.types')

local function root()
  local ok, utils = pcall(require, 'jdtls.utils')
  return ok and utils.get_platform_root() or nil
end

local function in_hybris()
  local r = root()
  return r and vim.fn.isdirectory(r .. '/bin/platform') == 1 and r or nil
end

-- ---- go-to-definition + picker --------------------------------------------

local function jump(file, line)
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { line or 1, 0 })
  vim.cmd('normal! zz')
end

function M.goto_def()
  local r = in_hybris(); if not r then return end
  T.ensure(r)
  local word = vim.fn.expand('<cword>')
  if word == '' then return end
  local decls = T.find(word)
  if #decls == 0 then
    vim.notify('Hybris: no type/enum named "' .. word .. '"', vim.log.levels.INFO)
    return
  end
  jump(decls[1].file, decls[1].line)
  if #decls > 1 then
    vim.notify(('Hybris: "%s" declared/extended in %d files (jumped to first)'):format(word, #decls),
      vim.log.levels.INFO)
  end
end

function M.pick_types()
  local r = in_hybris(); if not r then return end
  T.ensure(r, function()
    local ok, fzf = pcall(require, 'fzf-lua')
    local types = T.all_types()
    if not ok then
      vim.notify('fzf-lua not available', vim.log.levels.WARN); return
    end
    local entries, map = {}, {}
    for _, t in ipairs(types) do
      local rel = t.file and t.file:gsub('.*/bin/', 'bin/') or '?'
      local disp = string.format('%-40s %s', t.code, t.extends and ('⊂ ' .. t.extends) or '')
      entries[#entries + 1] = disp
      map[disp] = t
    end
    fzf.fzf_exec(entries, {
      prompt = 'ItemTypes> ',
      actions = {
        ['default'] = function(sel)
          local t = sel and sel[1] and map[sel[1]]
          if t and t.file then jump(t.file, t.line) end
        end,
      },
    })
  end)
end

-- ---- setup ----------------------------------------------------------------

-- Register the nvim-cmp source + scope it to xml/impex. Called from config/cmp.lua
-- when cmp actually loads (InsertEnter), so we never force cmp to load at startup.
function M.setup_cmp()
  local ok, cmp = pcall(require, 'cmp')
  if not ok then return end
  pcall(function()
    cmp.register_source('hybris_types', require('hybris.cmp_source').new())
  end)
  -- items.xml: data source + lemminx (schema) + buffer.
  cmp.setup.filetype('xml', {
    sources = cmp.config.sources(
      { { name = 'hybris_types' }, { name = 'nvim_lsp' } },
      { { name = 'buffer' } }),
  })
  -- impex: data source + buffer/path (no LSP for impex).
  cmp.setup.filetype('impex', {
    sources = cmp.config.sources(
      { { name = 'hybris_types' } },
      { { name = 'buffer' }, { name = 'path' } }),
  })
end

function M.setup()
  -- ImpEx filetype (.impex is not in nvim's builtin filetype table).
  vim.filetype.add({ extension = { impex = 'impex' } })

  -- Commands.
  vim.api.nvim_create_user_command('HybrisTypes', M.pick_types,
    { desc = 'Fuzzy-find a Hybris ItemType (Type System view)' })
  vim.api.nvim_create_user_command('HybrisReindexTypes', function()
    local r = in_hybris(); if not r then return end
    T.ensure(r, function(s)
      vim.notify(('Hybris type system rebuilt: %d types, %d enums (%d files).')
        :format(s.types, s.enums, s.files), vim.log.levels.INFO)
    end, true)
  end, { desc = 'Rebuild the Hybris type-system index from *-items.xml' })

  -- Global picker keymap.
  vim.keymap.set('n', '<leader>ht', M.pick_types, { desc = 'Hybris: find ItemType' })

  local grp = vim.api.nvim_create_augroup('hybris_types', { clear = true })

  -- Build/load the index lazily when an items.xml or impex buffer opens, and bind
  -- the per-buffer go-to-definition key there.
  vim.api.nvim_create_autocmd('FileType', {
    group = grp,
    pattern = { 'xml', 'impex' },
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      local is_items = name:match('items%.xml$') ~= nil
      if vim.bo[args.buf].filetype == 'impex' or is_items then
        local r = in_hybris()
        if r then T.ensure(r) end
        vim.keymap.set('n', '<leader>hd', M.goto_def,
          { buffer = args.buf, desc = 'Hybris: go to type/enum definition' })
      end
    end,
  })

  -- Rebuild after editing any *-items.xml (keeps completion fresh in-session).
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = grp,
    pattern = { '*items.xml' },
    callback = function()
      local r = in_hybris()
      if r then T.ensure(r, nil, true) end
    end,
  })

  -- Warm the index at startup when nvim opens inside a Hybris tree, so it's ready
  -- (or already loaded from cache) by the time you touch an items.xml / impex file.
  vim.api.nvim_create_autocmd('VimEnter', {
    group = grp,
    callback = function()
      vim.schedule(function()
        local r = in_hybris()
        if r then T.ensure(r) end
      end)
    end,
  })
end

return M
