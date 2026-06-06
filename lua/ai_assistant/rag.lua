-- Local, privacy-first RAG over project files using Ollama embeddings.
-- Chunks tracked source files, embeds each chunk via the local Ollama
-- embeddings endpoint, stores vectors on disk, and retrieves the top-k most
-- relevant chunks for a query so only the relevant code is injected into the
-- system prompt instead of whole files. Everything is best-effort and guarded:
-- if Ollama is unreachable, retrieve() returns nil and the caller falls back to
-- the normal whole-file project context.

local M = {}
local config = require("ai_assistant.config")

local INDEX_DIR = vim.fn.stdpath("data") .. "/ai_assistant_rag"
local EMBED_MODEL = "nomic-embed-text"
local EMBED_URL = "http://localhost:11434/api/embeddings"
local CHUNK_LINES = 60
local CHUNK_OVERLAP = 12
local MAX_FILE_BYTES = 200 * 1024
local MAX_CHUNKS = 2000 -- safety cap to bound indexing time

local function index_path(root)
  local key = (root or "global"):gsub("[^%w]", "_")
  return INDEX_DIR .. "/" .. key .. ".json"
end

-- Synchronous single-text embedding via Ollama. Returns a vector or nil.
local function embed(text)
  local ok, curl = pcall(require, "plenary.curl")
  if not ok then return nil end
  -- on_error keeps plenary from raising on connection-refused (Ollama down);
  -- the pcall is a belt-and-suspenders fallback.
  local ok2, res = pcall(curl.post, EMBED_URL, {
    body = vim.fn.json_encode({ model = EMBED_MODEL, prompt = text }),
    headers = { ["Content-Type"] = "application/json" },
    timeout = 20000,
    on_error = function() end,
  })
  if not ok2 or not res or res.status ~= 200 or not res.body then return nil end
  local okd, data = pcall(vim.fn.json_decode, res.body)
  if not okd or type(data) ~= "table" or type(data.embedding) ~= "table" then return nil end
  return data.embedding
end

function M.available()
  return embed("ping") ~= nil
end

local function cosine(a, b)
  if not a or not b or #a ~= #b then return -1 end
  local dot, na, nb = 0, 0, 0
  for i = 1, #a do
    dot = dot + a[i] * b[i]
    na = na + a[i] * a[i]
    nb = nb + b[i] * b[i]
  end
  if na == 0 or nb == 0 then return -1 end
  return dot / (math.sqrt(na) * math.sqrt(nb))
end

-- List candidate files, preferring `git ls-files` (respects .gitignore).
local function collect_files(root)
  local files = {}
  local out = vim.fn.systemlist({ "git", "-C", root, "ls-files" })
  if vim.v.shell_error == 0 and #out > 0 then
    for _, rel in ipairs(out) do
      files[#files + 1] = rel
    end
    return files
  end
  -- Fallback: walk for common source/text extensions.
  local exts = { lua = true, py = true, js = true, ts = true, tsx = true, jsx = true, go = true,
    rs = true, java = true, c = true, h = true, cpp = true, hpp = true, rb = true, php = true,
    cs = true, sh = true, md = true, txt = true, json = true, yaml = true, yml = true, toml = true,
    html = true, css = true, vim = true, sql = true }
  local function walk(dir, prefix)
    for name, ftype in vim.fs.dir(dir) do
      if name ~= ".git" and name ~= "node_modules" and name ~= ".ai_context" then
        local rel = (prefix == "" and name) or (prefix .. "/" .. name)
        if ftype == "directory" then
          walk(dir .. "/" .. name, rel)
        elseif ftype == "file" then
          local ext = name:match("%.([^%.]+)$")
          if ext and exts[ext:lower()] then
            files[#files + 1] = rel
          end
        end
      end
    end
  end
  pcall(walk, root, "")
  return files
end

-- Build (or rebuild) the on-disk vector index for the current project.
function M.build_index()
  local root = config.get_project_root()
  if not M.available() then
    vim.notify(
      "AI RAG: Ollama embeddings unreachable. Start Ollama and `ollama pull " .. EMBED_MODEL .. "`.",
      vim.log.levels.ERROR
    )
    return
  end

  local files = collect_files(root)
  local entries = {}
  local indexed_files = 0
  local uv = vim.uv or vim.loop

  for _, rel in ipairs(files) do
    if #entries >= MAX_CHUNKS then
      vim.notify(string.format("AI RAG: hit chunk cap (%d); index is partial.", MAX_CHUNKS), vim.log.levels.WARN)
      break
    end
    local path = root .. "/" .. rel
    local st = uv.fs_stat(path)
    if st and st.type == "file" and (st.size or 0) <= MAX_FILE_BYTES and (st.size or 0) > 0 then
      local fh = io.open(path, "r")
      if fh then
        local content = fh:read("*all")
        fh:close()
        local lines = vim.split(content or "", "\n", { plain = true })
        local i = 1
        local file_had_chunk = false
        while i <= #lines and #entries < MAX_CHUNKS do
          local last = math.min(i + CHUNK_LINES - 1, #lines)
          local chunk = table.concat(vim.list_slice(lines, i, last), "\n")
          if vim.trim(chunk) ~= "" then
            local vec = embed(chunk)
            if vec then
              entries[#entries + 1] = { path = rel, line = i, text = chunk, emb = vec }
              file_had_chunk = true
            end
          end
          i = i + (CHUNK_LINES - CHUNK_OVERLAP)
        end
        if file_had_chunk then indexed_files = indexed_files + 1 end
      end
    end
  end

  if vim.fn.isdirectory(INDEX_DIR) == 0 then
    vim.fn.mkdir(INDEX_DIR, "p")
  end
  local fh = io.open(index_path(root), "w")
  if fh then
    fh:write(vim.fn.json_encode({ model = EMBED_MODEL, entries = entries }))
    fh:close()
  end
  vim.notify(string.format("AI RAG: indexed %d chunks from %d files.", #entries, indexed_files), vim.log.levels.INFO)
end

function M.has_index()
  return vim.fn.filereadable(index_path(config.get_project_root())) == 1
end

-- Return the top-k most relevant chunks for a query, or nil on any failure.
function M.retrieve(query, k)
  k = k or 6
  if not query or vim.trim(query) == "" then return nil end
  local root = config.get_project_root()
  local fh = io.open(index_path(root), "r")
  if not fh then return nil end
  local content = fh:read("*all")
  fh:close()
  local okd, idx = pcall(vim.fn.json_decode, content)
  if not okd or type(idx) ~= "table" or type(idx.entries) ~= "table" then return nil end

  local qv = embed(query)
  if not qv then return nil end

  local scored = {}
  for _, e in ipairs(idx.entries) do
    scored[#scored + 1] = { e = e, s = cosine(qv, e.emb) }
  end
  table.sort(scored, function(a, b) return a.s > b.s end)

  local out = {}
  for i = 1, math.min(k, #scored) do
    local hit = scored[i]
    out[#out + 1] = { path = hit.e.path, line = hit.e.line, text = hit.e.text, score = hit.s }
  end
  return out
end

return M
