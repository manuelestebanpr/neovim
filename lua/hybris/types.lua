-- =============================================================================
-- Hybris Type System index (the EPAM "Type System" feature, ported to Neovim).
--
-- Parses every *-items.xml across the platform + extensions into an in-memory
-- model of ItemTypes / attributes / EnumTypes / Relations, merged across files and
-- inheritance. This is the data lemminx structurally CANNOT provide: the items.xml
-- XSD types for `extends=`/`type=` are bare xs:string, so ItemType-name and
-- attribute completion must come from a parsed data index, exactly like the
-- IntelliJ plugin builds a merged TSGlobalMetaModel from items.xml only.
--
-- Public API:
--   M.build(root)              -- (re)scan; returns stats. Cheap-ish (~hundreds of files).
--   M.ensure(root)             -- build once, cached; returns the index.
--   M.all_types()              -- array of { code, extends, file, line } (for pickers/completion)
--   M.all_enums()              -- array of { code, file, line }
--   M.get_type(code)           -- merged type entry or nil (case-insensitive)
--   M.attrs_of(code, inherited)-- merged attribute array (optionally walking extends)
--   M.find(code)               -- declaration sites for a type/enum: array of { file, line }
--   M.find_attr(code, qualifier) -- declaration site of an attribute (walks inheritance)
-- =============================================================================

local M = {}

-- index = {
--   types = { [lowercode] = { code, extends, declarations={{file,line}}, attrs={ [lowerq]={qualifier,type,file,line} } } },
--   enums = { [lowercode] = { code, declarations={{file,line}}, values={...} } },
--   built_for = <root>, files = <n>,
-- }
local index = nil

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

-- Build a fast offset->line mapper for a file's content. Naively recomputing the
-- line for every itemtype/attribute via s:sub(1,off):gsub("\n") is O(n^2) over a
-- big items.xml (it copies the whole prefix each time) -- that was ~7s across 398
-- files. Precompute newline offsets once (O(n)), then binary-search per lookup.
local function line_mapper(s)
  local nl, i = {}, 0
  while true do
    i = s:find("\n", i + 1, true)
    if not i then break end
    nl[#nl + 1] = i
  end
  return function(off)
    local lo, hi, cnt = 1, #nl, 0
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      if nl[mid] < off then cnt = mid; lo = mid + 1 else hi = mid - 1 end
    end
    return cnt + 1
  end
end

local function attr(str, name)
  -- name = "value" or name = 'value'
  return str:match(name .. '%s*=%s*"([^"]*)"') or str:match(name .. "%s*=%s*'([^']*)'")
end

local function ensure_type(code)
  local key = code:lower()
  local t = index.types[key]
  if not t then
    t = { code = code, declarations = {}, attrs = {} }
    index.types[key] = t
  end
  return t
end

local function ensure_enum(code)
  local key = code:lower()
  local e = index.enums[key]
  if not e then
    e = { code = code, declarations = {}, values = {} }
    index.enums[key] = e
  end
  return e
end

-- Register one attribute on a type (first declaration wins for the jump target;
-- later redeclarations are ignored for location but the qualifier stays unique).
local function add_attr(typecode, qualifier, atype, file, line)
  if not typecode or not qualifier then return end
  local t = ensure_type(typecode)
  local k = qualifier:lower()
  if not t.attrs[k] then
    t.attrs[k] = { qualifier = qualifier, type = atype, file = file, line = line }
  end
end

local function parse_itemtypes(content, file, lf)
  local pos = 1
  while true do
    local s, e, tag = content:find("<itemtype%s+([^>]-)/?>", pos)
    if not s then break end
    pos = e + 1
    local code = attr(tag, "code")
    if code then
      local extends = attr(tag, "extends")
      local t = ensure_type(code)
      if extends and not t.extends then t.extends = extends end
      table.insert(t.declarations, { file = file, line = lf(s) })

      -- Attributes live between this <itemtype ...> and its </itemtype> (itemtypes
      -- are never nested). Slice that block and scan <attribute ...> inside it.
      local close = content:find("</itemtype>", e) or #content
      local apos = e
      while true do
        local as, ae, atag = content:find("<attribute%s+([^>]-)/?>", apos)
        if not as or as > close then break end
        apos = ae + 1
        add_attr(code, attr(atag, "qualifier"), attr(atag, "type"), file, lf(as))
      end
      pos = math.max(pos, close)
    end
  end
end

local function parse_enumtypes(content, file, lf)
  local pos = 1
  while true do
    local s, e, tag = content:find("<enumtype%s+([^>]-)/?>", pos)
    if not s then break end
    pos = e + 1
    local code = attr(tag, "code")
    if code then
      local en = ensure_enum(code)
      table.insert(en.declarations, { file = file, line = lf(s) })
      local close = content:find("</enumtype>", e) or #content
      local vpos = e
      while true do
        local vs, ve, vtag = content:find("<value%s+([^>]-)/?>", vpos)
        if not vs or vs > close then break end
        vpos = ve + 1
        local vcode = attr(vtag, "code")
        if vcode then table.insert(en.values, vcode) end
      end
      pos = math.max(pos, close)
    end
  end
end

-- Relations add a navigable qualifier to each end's item type (each side exposes
-- the OTHER end's qualifier), so they must appear in attribute completion.
local function parse_relations(content, file, lf)
  local pos = 1
  while true do
    local s, e = content:find("<relation%s+[^>]->", pos)
    if not s then break end
    pos = e + 1
    local close = content:find("</relation>", e) or #content
    local block = content:sub(e, close)
    local src = block:match("<sourceElement%s+([^>]->)") or block:match("<sourceElement%s+([^>]-/>)")
    local tgt = block:match("<targetElement%s+([^>]->)") or block:match("<targetElement%s+([^>]-/>)")
    local sline = lf(s)
    if src and tgt then
      local sq, st = attr(src, "qualifier"), attr(src, "type")
      local tq, tt = attr(tgt, "qualifier"), attr(tgt, "type")
      -- source type gets the target qualifier; target type gets the source qualifier.
      if st and tq then add_attr(st, tq, tt, file, sline) end
      if tt and sq then add_attr(tt, sq, st, file, sline) end
    end
    pos = math.max(pos, close)
  end
end

-- Find every *-items.xml under <root>/bin (follows the bin/custom symlink). Uses
-- fd when available; falls back to vim.fs.find.
local function find_items_xml(root)
  local bin = root .. "/bin"
  if vim.fn.executable("fd") == 1 then
    local r = vim.fn.systemlist({ "fd", "-L", "-t", "f", "-a", "--", "items\\.xml$", bin })
    if vim.v.shell_error == 0 and #r > 0 then return r end
  end
  return vim.fs.find(function(name) return name:match("items%.xml$") end,
    { path = bin, type = "file", limit = math.huge })
end

local function parse_one(path)
  local content = read_file(path)
  if not content then return end
  content = content:gsub("<!%-%-.-%-%->", "") -- strip comments (avoid commented-out types)
  local lf = line_mapper(content)
  parse_itemtypes(content, path, lf)
  parse_enumtypes(content, path, lf)
  parse_relations(content, path, lf)
end

local function stats()
  return { files = index.files, types = vim.tbl_count(index.types), enums = vim.tbl_count(index.enums) }
end

-- ---- disk cache (instant reload across sessions) --------------------------
local function cache_path(root)
  local dir = vim.fn.stdpath("cache") .. "/hybris-types"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. vim.fn.sha256(root):sub(1, 16) .. ".json"
end

local function save_cache(root)
  local ok, encoded = pcall(vim.json.encode, { types = index.types, enums = index.enums, files = index.files })
  if ok then pcall(vim.fn.writefile, { encoded }, cache_path(root)) end
end

local function load_cache(root)
  local path = cache_path(root)
  if vim.fn.filereadable(path) == 0 then return false end
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
  if not ok or type(data) ~= "table" or not data.types then return false end
  index = { types = data.types, enums = data.enums or {}, built_for = root, files = data.files or 0 }
  return true
end

-- Synchronous build (used by tests / forced reindex). Writes the disk cache.
function M.build(root)
  index = { types = {}, enums = {}, built_for = root, files = 0 }
  local files = find_items_xml(root)
  for _, path in ipairs(files) do parse_one(path) end
  index.files = #files
  save_cache(root)
  return stats()
end

-- Chunked async build: parse ~20 files per scheduled tick so the UI never freezes
-- during the ~2.5s scan. on_done(stats) fires when complete.
function M.build_async(root, on_done)
  index = { types = {}, enums = {}, built_for = root, files = 0, building = true }
  local files = find_items_xml(root)
  local i = 0
  local function step()
    local stop = math.min(i + 20, #files)
    while i < stop do i = i + 1; parse_one(files[i]) end
    if i < #files then
      vim.schedule(step)
    else
      index.files = #files
      index.building = false
      save_cache(root)
      if on_done then on_done(stats()) end
    end
  end
  vim.schedule(step)
end

-- Make the index available. Order: in-memory -> disk cache (instant) -> async build.
-- on_ready(stats|nil) fires once usable. force=true bypasses cache and rebuilds.
function M.ensure(root, on_ready, force)
  if not force and index and index.built_for == root and not index.building then
    if on_ready then on_ready(stats()) end
    return index
  end
  if not force and (not index or index.built_for ~= root) and load_cache(root) then
    if on_ready then on_ready(stats()) end
    return index
  end
  if index and index.building then return index end -- a build is already in flight
  M.build_async(root, on_ready)
  return index
end

function M.is_built() return index ~= nil and not index.building end

function M.all_types()
  local out = {}
  if not index then return out end
  for _, t in pairs(index.types) do
    local d = t.declarations[1]
    out[#out + 1] = { code = t.code, extends = t.extends, file = d and d.file, line = d and d.line }
  end
  table.sort(out, function(a, b) return a.code < b.code end)
  return out
end

function M.all_enums()
  local out = {}
  if not index then return out end
  for _, e in pairs(index.enums) do
    local d = e.declarations[1]
    out[#out + 1] = { code = e.code, file = d and d.file, line = d and d.line, values = e.values }
  end
  table.sort(out, function(a, b) return a.code < b.code end)
  return out
end

function M.get_type(code)
  if not index or not code then return nil end
  return index.types[code:lower()]
end

-- Merged attribute list. With `inherited`, walks the extends chain (default parent
-- GenericItem) and unions parent attributes, child wins on qualifier collisions.
function M.attrs_of(code, inherited)
  if not index or not code then return {} end
  local seen, out = {}, {}
  local cur, guard = code, 0
  while cur and guard < 50 do
    guard = guard + 1
    local t = index.types[cur:lower()]
    if not t then break end
    for k, a in pairs(t.attrs) do
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = a
      end
    end
    if not inherited then break end
    cur = t.extends -- walk up; `Item` (the root) has no extends, so the loop ends
  end
  table.sort(out, function(a, b) return a.qualifier < b.qualifier end)
  return out
end

-- Declaration sites (multi) for a type OR enum code.
function M.find(code)
  if not index or not code then return {} end
  local t = index.types[code:lower()]
  if t then return t.declarations end
  local e = index.enums[code:lower()]
  if e then return e.declarations end
  return {}
end

-- Declaration site of an attribute on `code` (walks inheritance). Returns {file,line} or nil.
function M.find_attr(code, qualifier)
  if not index or not code or not qualifier then return nil end
  local cur, guard = code, 0
  while cur and guard < 50 do
    guard = guard + 1
    local t = index.types[cur:lower()]
    if not t then return nil end
    local a = t.attrs[qualifier:lower()]
    if a then return { file = a.file, line = a.line } end
    cur = t.extends
  end
  return nil
end

return M
