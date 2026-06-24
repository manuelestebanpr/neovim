-- =============================================================================
-- nvim-cmp source backed by the Hybris Type System index (hybris.types).
--
-- Provides the data-driven completion lemminx structurally cannot (the items.xml
-- XSD makes extends=/type= bare xs:string). Active on:
--   * items.xml (ft=xml, *items.xml buffers): ItemType/Enum names inside
--     extends=, type=, elementtype=, sourcetype=, targettype=, argumenttype=,
--     returntype= attribute values.
--   * ImpEx (ft=impex): ItemType in the header type slot; attribute qualifiers of
--     the header type in the following `;`-separated columns.
-- =============================================================================

local T = require('hybris.types')

local M = {}

local function root()
  local ok, utils = pcall(require, 'jdtls.utils')
  return ok and utils.get_platform_root() or nil
end

-- attribute-value contexts in items.xml where a type/enum name is expected
local TYPE_ATTRS = {
  extends = true, type = true, elementtype = true, sourcetype = true,
  targettype = true, argumenttype = true, returntype = true, metatype = true,
}

local function kind(k) return require('cmp').lsp.CompletionItemKind[k] end

local function type_items(include_enums)
  local items = {}
  for _, t in ipairs(T.all_types()) do
    items[#items + 1] = {
      label = t.code,
      kind = kind('Class'),
      detail = t.extends and ('extends ' .. t.extends) or nil,
      documentation = { kind = 'markdown', value = ('**%s**%s'):format(t.code,
        t.extends and ('\n\nextends `' .. t.extends .. '`') or '') },
    }
  end
  if include_enums then
    for _, e in ipairs(T.all_enums()) do
      items[#items + 1] = {
        label = e.code,
        kind = kind('Enum'),
        detail = 'enum',
        documentation = { kind = 'markdown',
          value = ('**%s** (enum)\n\n%s'):format(e.code, table.concat(e.values or {}, ', ')) },
      }
    end
  end
  return items
end

local function attr_items(typecode)
  local items = {}
  for _, a in ipairs(T.attrs_of(typecode, true)) do
    items[#items + 1] = {
      label = a.qualifier,
      kind = kind('Field'),
      detail = a.type,
      documentation = { kind = 'markdown',
        value = ('**%s**\n\ntype `%s`'):format(a.qualifier, a.type or '?') },
    }
  end
  return items
end

-- ---- context detection ----------------------------------------------------

-- items.xml: is the cursor inside an attribute value whose name expects a type?
-- Returns the attribute name, or nil. Looks at the text before the cursor on the
-- line for `<attrname>="...<cursor>`.
local function xml_type_context(before)
  -- last `word="..."` opened before the cursor with no closing quote yet
  local name = before:match('([%w_]+)%s*=%s*"[^"]*$')
  if name and TYPE_ATTRS[name:lower()] then return name:lower() end
  return nil
end

-- ImpEx: classify the cursor on a header line. Returns 'type' | typecode (for an
-- attribute slot) | nil.
local OPS = { INSERT = true, UPDATE = true, INSERT_UPDATE = true, REMOVE = true }
local function impex_context(line, before)
  local op, rest = line:match('^%s*([%u_]+)%s+(.*)$')
  if not op or not OPS[op] then return nil end
  -- header type is the first token of `rest`, up to ';' or '['
  local typecode = rest:match('^([%w_]+)')
  -- before the first ';' => completing the type itself
  local before_body = before:match('^%s*[%u_]+%s+([^;]*)$')
  if before_body ~= nil and not before_body:find(';') then
    return 'type'
  end
  -- otherwise we are in a `;`-separated column => attribute of the header type
  if typecode then return typecode end
  return nil
end

-- ---- cmp source object ----------------------------------------------------

function M.new() return setmetatable({}, { __index = M }) end

function M:get_debug_name() return 'hybris_types' end

function M:is_available()
  local ft = vim.bo.filetype
  if ft == 'impex' then
    if not T.is_built() then local r = root(); if r then T.ensure(r) end end
    return true
  end
  if ft == 'xml' then
    local ok = vim.api.nvim_buf_get_name(0):match('items%.xml$') ~= nil
    if ok and not T.is_built() then local r = root(); if r then T.ensure(r) end end
    return ok
  end
  return false
end

-- Only purposeful triggers: `"` opens an items.xml attribute value, `;` starts a
-- new ImpEx column. cmp also auto-triggers as you type word chars, so we omit
-- space/comma to avoid noisy popups mid-line.
function M:get_trigger_characters() return { '"', ';' } end

function M:complete(params, callback)
  if not T.is_built() then return callback({ items = {}, isIncomplete = true }) end
  local ft = vim.bo.filetype
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local before = line:sub(1, col)

  local items
  if ft == 'xml' then
    local ctx = xml_type_context(before)
    if not ctx then return callback({ items = {} }) end
    -- `extends` => item types only; `type`/elementtype/etc => types + enums.
    items = type_items(ctx ~= 'extends')
  elseif ft == 'impex' then
    local ctx = impex_context(line, before)
    if not ctx then return callback({ items = {} }) end
    if ctx == 'type' then
      items = type_items(true)
    else
      items = attr_items(ctx)
    end
  else
    return callback({ items = {} })
  end

  callback({ items = items, isIncomplete = false })
end

return M
