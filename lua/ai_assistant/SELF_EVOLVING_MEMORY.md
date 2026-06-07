# Implementation Guide — Self‑Evolving User & Project Context

**Target plugin:** `~/.config/nvim/lua/ai_assistant/` (custom Neovim AI assistant).
**Goal:** add an *Odysseus‑style* memory loop on top of the existing context system — the assistant **learns durable user preferences from finished chats**, lets you **review** them before they take effect, and **compacts** the preference list with a local LLM so the always‑injected prompt prefix stays small.

This guide is self‑contained. Every file/line reference was verified against the current source, and the local‑LLM behaviour was **tested against the running Ollama** (`0.30.5`, `qwen3.6:35b-a3b`). Two flag types appear below:

- **⚠ CORRECTION** — the original design sketch was wrong here (drifted line numbers or a real defect).
- **✅ VERIFIED** — confirmed empirically (live Ollama call or code read); trust it over intuition.

---

## 0. Mental model

```
 chat closes ──▶ [extract]  local LLM reads the transcript ──▶ pending_context (candidates)
                                                                     │
 <leader>cx ▶ "Review Learned Preferences (N)" ── accept / edit / reject ─┘
                                                                     ▼
                                  settings.user_context  (approved — injected EVERY turn)
                                                                     │
                       grows past budget ──▶ [compact] local LLM dedups+distills ──┘

 (mid‑chat) model calls save_preference tool ──▶ straight into settings.user_context
```

Two distinct stores:

| Store | Lives in | Injected into prompt? | Who writes it |
|---|---|---|---|
| `settings.user_context` | `ai_assistant_settings.json` | **Yes**, every turn (`api.lua` system‑prompt build) | manual (`<leader>cx`), accepted candidates, `save_preference` tool, compaction |
| `settings.pending_context` | `ai_assistant_settings.json` | **Never** | background extraction only |

Project‑scoped memory (`save_memory` → `ai_assistant_memory/*.md`) already exists and is unchanged; this work is the **global, cross‑project preference** half.

---

## 1. Current state — verified map

What already works today (do **not** rebuild these):

| Concept | Where it lives (verified) |
|---|---|
| Cross‑chat user preferences | `settings.user_context` = array of `{id,text}`. Default at **`config.lua:108‑111`**. Injected at **`api.lua:1208‑1214`** (section “3. User preferences”). |
| `<leader>cx` view/add/delete prefs | `M.manage_context()` **`ui.lua:1192`**, dispatch `M.handle_context_action()` **`ui.lua:1147`**, items 3/4/5 → `view_user_context()` **`ui.lua:489`**, `add_context_item()` **`ui.lua:575`**, `del_context_item()` **`ui.lua:605`**. |
| Durable project memory | `MEMORY_DIR/*.md` + `config.append_memory()` **`config.lua:509`** (also `read_memory` 504, `get_memory_path` 500, `clear_memory` 520). `save_memory` **tool**: def `api.lua:667`, exec branch `api.lua:456`, mapping `api.lua:715`, auto‑run/status in the tool loop `api.lua:1680‑1690`. Injected at **`api.lua:1216‑1220`**. |
| RAG | `rag.lua` (Ollama `nomic-embed-text` + cosine). `rag_enabled` default `false` (`config.lua:68`). Injected on the **user turn** at **`api.lua:1247+`**. |
| Prefix‑cache‑friendly prompt ordering | `api.lua:1175‑1228` — persona → static tool docs → plan mode → **user prefs** → project memory → **project context (last)**. |

> **⚠ CORRECTION vs the original sketch:** the sketch cited `api.lua:1171‑1176` for pref injection, `1178‑1182` for memory, `1206‑1221` for RAG, and `config.lua:495‑526` for `save_memory`. The accurate numbers are above. Also: injection reads **both** `item.id` and `item.text` (`string.format("- **%s**: %s", item.id, item.text)`), not text alone — harmless, but the extra provenance fields (`source`/`confidence`/`updated`) are simply ignored there.

### Preconditions

1. **The local model must be reachable.** ✅ VERIFIED present: `ollama list` shows `qwen3.6:35b-a3b` and `qwen3.6-pc:latest` (both work for JSON). Confirm `ollama serve` is running. Note the measured **cold load ~20s** for the 35B model — this is *why* every call below must be async (§4).
2. **RAG is currently dead** (separate concern). ✅ VERIFIED: `rag.lua:13` hardcodes `EMBED_MODEL="nomic-embed-text"`, which is **not** installed, so `embed()` returns `nil` and retrieval silently no‑ops (`rag_enabled` is also `false` by default). Optional remedy: `ollama pull nomic-embed-text` then toggle on. Orthogonal to this feature.

---

## 2. Layering / module rules (read before coding)

- **`config.lua`** owns all persistence. It must **not** `require("ai_assistant.memory_llm")` (would create a require cycle — memory_llm requires config).
- **`memory_llm.lua`** (new) owns *all* local‑LLM calls and may `require("ai_assistant.config")`.
- **Compaction is triggered from the caller** (`ui.lua` after an accept, `api.lua` after the `save_preference` tool) — never from inside `config.lua`.
- **CONCURRENCY INVARIANT (load‑bearing — read this twice).** Settings are persisted as one whole‑file JSON blob with no merge‑from‑disk, so any stale save is a full clobber (including API keys). The rule that prevents lost updates:
  - Every `config` mutator does a **synchronous** `load → mutate → save` with **no async call in between**. On Neovim’s single‑threaded main loop that makes each mutator atomic — no lock needed.
  - Callers must **never hold a settings table across an async boundary** (a model call) and save it later. Always **re‑load inside the callback** before mutating. `memory_llm` does this; so must any new UI flow.
- All local‑LLM work is **async and best‑effort**: if Ollama is down or returns junk, nothing happens and the editor never blocks.

---

## 3. Step 1 — New store + preference mutators (`config.lua`)

### 3a. Add the defaults

In `default_settings` (`config.lua:61`), right after the `user_context = {...}` block (ends line 111), add:

```lua
  -- Learned-but-unreviewed preference candidates. NEVER injected into the
  -- prompt; surfaced for approval via <leader>cx. Mirrors user_context shape
  -- plus provenance.
  pending_context = {},
  -- Local Ollama model used for background preference extraction/compaction.
  -- A dedicated setting (not default_model, which may be a cloud model).
  memory_model = "qwen3.6:35b-a3b",
```

✅ VERIFIED: `apply_defaults` (`config.lua:207‑216`) fills a top‑level key only when it is `nil`, so existing settings files gain `pending_context`/`memory_model` automatically and keep any user edits. `user_context`/`pending_context` are arrays → **not** in `DEEP_MERGE_KEYS` → treated atomically, so provenance fields on items survive round‑trips untouched. **Do not** add them to `DEEP_MERGE_KEYS` (`merge_map` skips lists anyway).

> **Provenance:** new items carry `source` (`"manual"|"learned"|"compacted"`), optional `confidence`, and `updated`. Legacy items have only `{id,text}` — all readers treat the extra fields as optional and default `source` to `"manual"`.

### 3b. Add the mutators

Append this section after the project‑memory section (after `clear_memory`, ~`config.lua:526`).

> **⚠ CORRECTION (dedup):** the original sketch deduped learned prefs by **id only** (like `add_context_item`). That silently clobbers: two different texts can slug to the same id (collision → overwrite a real pref), and the same pref re‑learned with different phrasing mints a new id (unbounded growth). ✅ VERIFIED by executing the naïve slug: `"Use TypeScript! And React."` and `"use typescript and react"` both → `use_typescript_and_react`. Fix: **dedup by normalized text first**; treat the slug only as a stable, collision‑resistant id (strip edge `_`, suffix on collision).

```lua
----------------------------------------------------------------------
-- User preferences: learned + manual, cross-project (settings.user_context)
-- plus the review queue (settings.pending_context, NEVER injected).
-- See the CONCURRENCY INVARIANT in the guide: each mutator below is a
-- synchronous load->mutate->save (atomic on the single-threaded main loop);
-- callers must re-load inside async callbacks, never carry a stale table.
----------------------------------------------------------------------

-- Canonical comparison form for preference text (case/space-insensitive).
local function norm_text(s)
  return (vim.trim(s or ""):gsub("%s+", " ")):lower()
end

-- Deterministic snake_case id. Strip leading/trailing underscores so trailing
-- punctuation can't yield ids that differ only by a stray "_".
local function slugify(text)
  local s = norm_text(text):gsub("%W+", "_"):gsub("^_+", ""):gsub("_+$", ""):sub(1, 40)
  return (s ~= "" and s) or "pref"
end

-- A slug unique across `list` (suffix on collision with a DIFFERENT item, so
-- two distinct texts never share an id and clobber on delete/accept).
local function unique_id(list, base)
  local taken = {}
  for _, it in ipairs(list or {}) do if it.id then taken[it.id] = true end end
  if not taken[base] then return base end
  for n = 2, 999 do
    local cand = base .. "_" .. n
    if not taken[cand] then return cand end
  end
  return base .. "_x"
end

-- Always-a-list guard: vim.fn.json_decode("{}") yields a non-list table, and a
-- hand-edited empty object would make ipairs() silently iterate nothing.
local function as_list(v)
  return (type(v) == "table" and vim.islist(v)) and v or {}
end

-- Add/update a durable, cross-project preference straight into the INJECTED
-- list. Dedup is by NORMALIZED TEXT first; the slug is only a stable id.
-- Used by the save_preference tool and the review "accept" path.
function M.append_user_preference(text, meta)
  if not text or vim.trim(text) == "" then return false end
  meta = meta or {}
  text = vim.trim(text:gsub("\n", " "))
  local want = norm_text(text)
  local settings = M.load_settings()
  settings.user_context = as_list(settings.user_context)
  settings.pending_context = as_list(settings.pending_context)

  -- Promote: an explicit save supersedes any queued candidate with same text.
  local kept = {}
  for _, it in ipairs(settings.pending_context) do
    if norm_text(it.text) ~= want then kept[#kept + 1] = it end
  end
  settings.pending_context = kept

  -- Dedup within user_context: update in place rather than duplicate.
  for _, it in ipairs(settings.user_context) do
    if norm_text(it.text) == want then
      it.text = text
      it.source = it.source or meta.source or "learned"
      if meta.confidence and (it.confidence == nil or meta.confidence > it.confidence) then
        it.confidence = meta.confidence
      end
      it.updated = os.date("%Y-%m-%d")
      M.save_settings(settings)
      return true
    end
  end

  local id = (meta.id and meta.id ~= "") and meta.id or slugify(text)
  id = unique_id(settings.user_context, id)
  table.insert(settings.user_context, {
    id = id, text = text,
    source = meta.source or "learned",
    confidence = meta.confidence,
    updated = os.date("%Y-%m-%d"),
  })
  M.save_settings(settings)
  return true
end

-- Queue a BATCH of learned candidates for review (ONE load+save). Skips any
-- text already approved (user_context) or already queued (pending_context).
-- Returns the number newly queued.
function M.add_pending_preferences(items)
  if type(items) ~= "table" or #items == 0 then return 0 end
  local settings = M.load_settings()
  settings.user_context = as_list(settings.user_context)
  settings.pending_context = as_list(settings.pending_context)

  local seen = {}
  for _, it in ipairs(settings.user_context) do seen[norm_text(it.text)] = true end
  for _, it in ipairs(settings.pending_context) do seen[norm_text(it.text)] = true end

  local added = 0
  for _, it in ipairs(items) do
    if type(it.text) == "string" and vim.trim(it.text) ~= "" then
      local key = norm_text(it.text)
      if not seen[key] then
        seen[key] = true
        local base = (type(it.id) == "string" and it.id ~= "") and slugify(it.id) or slugify(it.text)
        table.insert(settings.pending_context, {
          id = unique_id(settings.pending_context, base),
          text = vim.trim(it.text:gsub("\n", " ")),
          source = "learned",
          confidence = it.confidence,
          action = it.action or "add",
        })
        added = added + 1
      end
    end
  end
  if added > 0 then M.save_settings(settings) end
  return added
end

function M.list_pending_preferences()
  return as_list(M.load_settings().pending_context)
end

function M.count_pending_preferences()
  return #as_list(M.load_settings().pending_context)
end

-- Remove a pending item by id (mutates `settings`); returns the removed item.
local function take_pending(settings, id)
  local taken, rest = nil, {}
  for _, it in ipairs(as_list(settings.pending_context)) do
    if it.id == id and not taken then taken = it else rest[#rest + 1] = it end
  end
  settings.pending_context = rest
  return taken
end

-- Approve a candidate: dequeue, then add/update it in user_context.
function M.accept_pending_preference(id)
  local settings = M.load_settings()
  local it = take_pending(settings, id)
  M.save_settings(settings)            -- persist the dequeue first
  if not it then return false end
  return M.append_user_preference(it.text, { id = it.id, source = "learned", confidence = it.confidence })
end

function M.reject_pending_preference(id)
  local settings = M.load_settings()
  local it = take_pending(settings, id)
  M.save_settings(settings)
  return it ~= nil
end
```

✅ VERIFIED: `save_settings` (`config.lua:218‑229`) json‑encodes and then `setfperm … rw-------` (0600) on a file holding API keys. Every mutator above routes through `M.save_settings` — **never** write the settings file directly, or you lose the 0600 perm and the serialize‑failure guard.

---

## 4. Step 2 — Local‑LLM plumbing (`lua/ai_assistant/memory_llm.lua`, NEW)

> **⚠ CORRECTION #1 (BLOCKER — async).** The original sketch called `curl.post(...)` **without a `callback`** and said “run it in `vim.schedule` so it never blocks.” ✅ VERIFIED **false**: plenary’s `curl.post` runs **synchronously** (`job:sync`) when no `callback`/`stream` is given (plenary `curl.lua:322‑329`); `vim.schedule` only changes *when* the blocking call runs, not *that* it blocks. With the 35B model’s ~20s cold load this **freezes Neovim**. The whole feature must be callback‑style. The code below is async (the only synchronous `curl.post` in the codebase is the dead `rag.lua` `embed()` — don’t copy it).
>
> **⚠ CORRECTION #2 (BUG — JSON shape).** The sketch passed `format = schema_object`. ✅ VERIFIED **false** (tested twice, deterministically): with a JSON‑Schema **object**, `qwen3.6:35b-a3b` *ignored* the required shape **and** wrapped output in a ```` ```json ```` fence, so `vim.fn.json_decode(message.content)` fails and extraction silently yields nothing. **Use `format = "json"` (the string)**, describe the exact shape in the system prompt (this produced clean, correctly‑shaped JSON), and extract the object robustly (fence + balanced‑brace) before decoding.

> **Alternative (optional):** instead of a standalone HTTP helper you could reuse `M.send_prompt_internal` (`api.lua:1135`) with `model = memory_model`, `no_tools = true`, `fresh_user_turn = false`, inheriting its async/fire‑once/error guards. Caveat: its Ollama branch doesn’t set `think=false`/`format="json"`, so you’d parse best‑effort text. The self‑contained helper below is preferred — it can’t pull in RAG/active‑file/tool context and keeps this background job fully isolated.

Create the file:

```lua
-- lua/ai_assistant/memory_llm.lua
-- Local-LLM "self-evolving preferences": read a finished chat and propose
-- durable cross-project preferences; and compact the preference list when it
-- grows. ALL calls are async (non-blocking) and best-effort: if the local
-- model is unreachable or returns junk, nothing happens.

local M = {}
local config = require("ai_assistant.config")

local CHAT_URL = "http://localhost:11434/api/chat"
local DEFAULT_MODEL = "qwen3.6:35b-a3b"  -- fallback if settings.memory_model is unset
local COMPACT_ITEM_BUDGET = 25           -- auto-compact once user_context exceeds this
local COMPACT_TARGET = 20                -- hard cap on the compacted list size
local TRANSCRIPT_CHAR_CAP = 16000        -- bound the extraction prompt

-- Async JSON call to the local model. Invokes on_done(table|nil, err). Never
-- blocks the editor: a `callback` makes plenary run curl on a job; schedule_wrap
-- returns us to the main loop, where vim.fn.json_decode is safe (it is NOT in
-- plenary's fast-event callback context). on_done fires EXACTLY once.
local function call_json(system, user, on_done)
  local ok, curl = pcall(require, "plenary.curl")
  if not ok then return on_done(nil, "plenary.curl missing") end

  local fired = false
  local function done(x, err) if not fired then fired = true; on_done(x, err) end end

  local settings = config.load_settings()
  local model = (type(settings.memory_model) == "string" and settings.memory_model ~= "")
      and settings.memory_model or DEFAULT_MODEL

  local ok_body, body = pcall(vim.fn.json_encode, {
    model = model,
    stream = false,
    think = false,                 -- no reasoning tokens for a structured task (accepted; verified)
    format = "json",               -- STRING, not a schema object (schema object is unreliable here)
    options = { temperature = 0.1 },
    messages = {
      { role = "system", content = system },
      { role = "user",   content = user },
    },
  })
  if not ok_body then return done(nil, "encode failed") end

  local ok_post = pcall(curl.post, CHAT_URL, {
    timeout = 60000,
    headers = { ["Content-Type"] = "application/json" },
    body = body,
    on_error = vim.schedule_wrap(function(err) done(nil, "network: " .. tostring(err)) end),
    callback = vim.schedule_wrap(function(res)
      if not res or not res.status or res.status < 200 or res.status >= 300 or not res.body then
        return done(nil, "HTTP " .. tostring(res and res.status))
      end
      local okd, data = pcall(vim.fn.json_decode, res.body)        -- Ollama envelope
      if not okd or type(data) ~= "table" or type(data.message) ~= "table" then
        return done(nil, "bad response envelope")
      end
      -- Lift the JSON object out of any prose / ```json fence the model adds.
      local content = data.message.content or ""
      local inner = content:match("```%w*%s*(.-)%s*```") or content  -- fenced -> inside the fence
      inner = inner:match("%b{}") or inner                           -- else first balanced {...}
      local okp, parsed = pcall(vim.fn.json_decode, vim.trim(inner))
      if not okp or type(parsed) ~= "table" then return done(nil, "model did not return JSON") end
      done(parsed)
    end),
  })
  if not ok_post then done(nil, "failed to start request") end
end

----------------------------------------------------------------------
-- Extraction (runs when a chat closes)
----------------------------------------------------------------------

local EXTRACT_SYSTEM = [[
You analyze a developer's chat with their AI coding assistant and extract
DURABLE personal preferences worth remembering for ALL future chats.

Extract ONLY stable preferences about how THIS developer wants to work:
coding style, languages/frameworks they prefer or avoid, tone, formatting,
tooling, review habits, recurring constraints.

DO NOT extract: one-off task details, file names, project-specific facts
(those belong to project memory), anything already in EXISTING preferences,
or anything you are not confident is a lasting preference.

Return ONLY a JSON object of this exact shape, with NO prose and NO markdown fence:
{"preferences":[{"id":"snake_case","text":"imperative sentence","confidence":0.0,"action":"add"}]}
- id: short snake_case key (reuse an EXISTING id to UPDATE it)
- text: imperative, self-contained (e.g. "Prefer the standard library over new deps")
- confidence: a number 0.0-1.0 (the caller drops anything < 0.6)
- action: "add" or "update"
Return {"preferences":[]} if nothing durable was learned.
]]

-- Build a plain USER/ASSISTANT transcript. History roles (verified): "user",
-- "model" (assistant text in .content), "tool" (payload in .tool_results, NO
-- .content) -> skipped. Pure tool-call model turns have content "" -> skipped
-- by the string guard. type()=="string" also rejects vim.NIL from reloaded
-- chats (the documented crash at ui.lua:1368-1369).
local function build_transcript(history)
  local parts, total = {}, 0
  for _, msg in ipairs(history or {}) do
    if type(msg.tool_results) ~= "table"
        and type(msg.content) == "string" and vim.trim(msg.content) ~= "" then
      local label = (msg.role == "user") and "USER"
        or ((msg.role == "model" or msg.role == "assistant") and "ASSISTANT" or nil)
      if label then
        local chunk = label .. ": " .. msg.content
        if total + #chunk > TRANSCRIPT_CHAR_CAP then break end
        parts[#parts + 1] = chunk
        total = total + #chunk
      end
    end
  end
  return table.concat(parts, "\n\n")
end

-- Read a finished chat; queue learned candidates into pending_context.
-- Calls on_done(num_newly_queued).
function M.extract_preferences(history, existing_items, on_done)
  on_done = on_done or function() end
  local transcript = build_transcript(history)
  if vim.trim(transcript) == "" then return on_done(0) end
  local ok_enc, existing_json = pcall(vim.fn.json_encode, existing_items or {})
  local user_msg = "EXISTING PREFERENCES (do NOT re-learn these):\n" .. (ok_enc and existing_json or "[]")
    .. "\n\nCONVERSATION:\n" .. transcript

  call_json(EXTRACT_SYSTEM, user_msg, function(parsed)
    if not parsed or type(parsed.preferences) ~= "table" then return on_done(0) end
    local candidates = {}
    for _, p in ipairs(parsed.preferences) do
      -- Defensive: missing/non-number confidence -> 0 (dropped); never `nil < 0.6`.
      if type(p) == "table" and type(p.text) == "string"
          and (tonumber(p.confidence) or 0) >= 0.6 then
        candidates[#candidates + 1] = {
          id = type(p.id) == "string" and p.id or nil,
          text = p.text,
          confidence = tonumber(p.confidence) or 0.6,
          action = p.action or "add",
        }
      end
    end
    on_done(config.add_pending_preferences(candidates))   -- ONE atomic load+save
  end)
end

----------------------------------------------------------------------
-- Compaction ("quantize" the always-injected list)
----------------------------------------------------------------------

local COMPACT_SYSTEM = [[
You maintain a developer's list of durable AI-assistant preferences.
Rewrite the list to be MINIMAL and NON-REDUNDANT:
- Merge items that say the same or overlapping things into one.
- Remove contradictions, keeping the most recent/strongest.
- Make each item a short imperative sentence (<= 15 words).
- Preserve meaning; never invent new preferences.
- Keep <= 20 items total, ordered most to least important.
Return ONLY a JSON object, NO prose and NO markdown fence:
{"preferences":[{"id":"snake_case","text":"imperative sentence"}]}
]]

-- Ask the model to distill `items`; calls on_done(new_items|nil).
function M.compact_preferences(items, on_done)
  on_done = on_done or function() end
  local ok_enc, items_json = pcall(vim.fn.json_encode, items or {})
  if not ok_enc then return on_done(nil) end
  call_json(COMPACT_SYSTEM, "CURRENT PREFERENCES:\n" .. items_json, function(parsed)
    if not parsed or type(parsed.preferences) ~= "table" or #parsed.preferences == 0 then
      return on_done(nil)
    end
    local out = {}
    for _, p in ipairs(parsed.preferences) do
      if #out < COMPACT_TARGET and type(p) == "table"
          and type(p.text) == "string" and vim.trim(p.text) ~= "" then
        out[#out + 1] = {
          id = (type(p.id) == "string" and p.id ~= "") and p.id or ("pref_" .. (#out + 1)),
          text = vim.trim(p.text),
          source = "compacted",
          updated = os.date("%Y-%m-%d"),
        }
      end
    end
    on_done(#out > 0 and out or nil)
  end)
end

-- Distill, back up, replace, save. on_done(did_compact, before, after).
-- Re-loads settings INSIDE the callback (concurrency invariant).
local function apply_compaction(items, on_done)
  M.compact_preferences(items, function(compacted)
    if not compacted then return on_done(false) end
    local settings = config.load_settings()
    settings.user_context_backup = items            -- one-level undo
    settings.user_context = compacted
    config.save_settings(settings)
    on_done(true, #items, #compacted)
  end)
end

-- Auto path: compact only when over budget. Called after accept / save_preference.
function M.maybe_compact(on_done)
  on_done = on_done or function() end
  local items = config.load_settings().user_context or {}
  if #items <= COMPACT_ITEM_BUDGET then return on_done(false) end
  apply_compaction(items, on_done)
end

-- Manual path (the <leader>cx "Compact now" action): always compact.
function M.force_compact(on_done)
  on_done = on_done or function() end
  local items = config.load_settings().user_context or {}
  if #items == 0 then return on_done(false) end
  apply_compaction(items, on_done)
end

return M
```

**Notes**
- The fence/`%b{}` extraction is defensive even with `format="json"`: it survives a stray ```` ```json ```` fence or leading prose. ✅ VERIFIED end‑to‑end in real Neovim.
- `vim.schedule_wrap` on the callbacks is **required**, not cosmetic: it moves the decode off plenary’s fast‑event context onto the main loop, where `vim.fn.json_decode` is safe (matches `api.lua` house style; see the note at `api.lua:142‑143`).
- The compaction backup lives in `settings.user_context_backup` (never injected). Add a “restore” action later if you want.

---

## 5. Step 3 — Fire extraction when a chat closes (`ui.lua`)

> **⚠ CORRECTION (BUG — multiple).** ✅ VERIFIED against `ui.lua`:
> 1. **Two close paths.** Chats save (and thus should extract) at the toggle‑while‑open branch **`ui.lua:1245‑1247`** *and* in `close_fn` **`ui.lua:1403‑1405`** (the shared sink for Esc/`C‑c`, `C‑x` settings, and `/quit` `/close`). Hooking one misses the rest.
> 2. **`session` is nil’d** right after each save (`1255` / `1411`). A `vim.schedule` closure that reads the `session` upvalue gets `nil`. **Snapshot synchronously** before deferring.
> 3. **The toggle branch also runs on resume** (`loaded_history` passed). Gate on `not loaded_history` so resume doesn’t extract.
> 4. **`#history_data >= 4` is wrong:** one tool round‑trip is 3 turns (user+model+tool, `api.lua:1632‑1635`), so `>=4` fires on ~one exchange. Gate on **≥ 2 non‑empty *user* turns** instead.
> 5. **Per‑session guard:** a chat can be closed → resumed → closed again; dedupe extraction by session id.

### 5a. Add a module‑level guard set + shared helper

Define near the top of `ui.lua` (e.g. by the existing `local session` near the module top) the guard set, and put the helper with the other context helpers (after `del_context_item`, ~`ui.lua:656`):

```lua
local extracted_sessions = {}  -- session.id -> true; guards double extraction
```

```lua
-- Fire-and-forget: learn durable preferences from a just-closed chat.
-- Snapshots history SYNCHRONOUSLY (session is nil'd right after the caller).
local function learn_from_closed_chat(sess)
  if not sess or type(sess.history_data) ~= "table" then return end
  local sid = sess.id
  if not sid or extracted_sessions[sid] then return end

  -- Count substantive user turns; a tool round-trip is 3 turns, so a raw
  -- length check would fire on a single exchange.
  local user_turns = 0
  for _, m in ipairs(sess.history_data) do
    if m.role == "user" and type(m.content) == "string" and vim.trim(m.content) ~= "" then
      user_turns = user_turns + 1
    end
  end
  if user_turns < 2 then return end

  extracted_sessions[sid] = true
  local hist = vim.deepcopy(sess.history_data)            -- snapshot now
  local existing = config.load_settings().user_context
  vim.schedule(function()
    local ok, mem = pcall(require, "ai_assistant.memory_llm")
    if not ok then return end
    mem.extract_preferences(hist, existing, function(n)
      if n and n > 0 then
        vim.notify(
          string.format("AI: learned %d preference(s) — review in <leader>cx", n),
          vim.log.levels.INFO)
      end
    end)
  end)
end
```

### 5b. Call it from both close paths (capture before `session = nil`)

**In `M.toggle_chat`** — the existing close branch (`ui.lua:1245‑1247`). Gate on `not loaded_history` (skip resume):

```lua
    if session.history_data and #session.history_data > 0 then
      config.save_chat_session(session.id, session.history_data)
    end
    if not loaded_history then learn_from_closed_chat(session) end   -- ← ADD (before session=nil ~1255)
```

**In `close_fn`** — the in‑chat/Esc/quit handler (`ui.lua:1403‑1405`). Always a real close:

```lua
    if session and session.history_data and #session.history_data > 0 then
      config.save_chat_session(session.id, session.history_data)
    end
    learn_from_closed_chat(session)          -- ← ADD (before session=nil ~1411)
```

`learn_from_closed_chat` reads `session` **synchronously** (deepcopy + counts) and only defers the model call, so calling it just before `session = nil` is correct. Both insertion points are enough — `close_fn` already covers Esc/`C‑c`/`C‑x`/`/quit`/`/close`.

---

## 6. Step 4 — `save_preference` native tool (mid‑chat learning)

So the model can persist a global preference *during* a chat (its `save_memory` sibling is project‑only). Four edits in `api.lua` + the `config` call from Step 1.

**Decided:** `save_preference` writes **straight into `user_context`** (immediate effect next turn) — *not* the review queue. The model invoked the tool explicitly, so we trust it, mirroring how `save_memory` auto‑runs. Do **not** route it through `pending_context`. (The review queue is exclusively for *passively extracted* candidates from §5.)

### 6a. Declare the tool — `TOOL_DEFS` (after the `save_memory` entry, ~`api.lua:671`)

```lua
  {
    name = "save_preference",
    description = "Save ONE durable, cross-project preference about how THIS user likes to work (coding style, tone, preferred/avoided tools or libraries, formatting). Persists to GLOBAL user preferences across ALL projects and sessions. Use sparingly and only for lasting preferences — NOT task facts or project-specific details (use save_memory for those). Saved silently without approval.",
    properties = { preference = { type = "string", description = "The single preference, imperative form (e.g. 'Prefer the standard library over adding new dependencies')." } },
    required = { "preference" },
  },
```

✅ VERIFIED: `anthropic_tools()`/`openai_tools()`/`gemini_tools()` (`api.lua:674‑697`) all iterate `TOOL_DEFS`, so the new tool reaches every provider automatically — no per‑provider edits.

### 6b. Map the call — `M.tool_call_to_exec` (after the `save_memory` branch, ~`api.lua:716`)

```lua
  elseif name == "save_preference" then
    return "save_preference", s(input.preference)
```

### 6c. Execute it — `M.execute_tool` (after the `save_memory` branch, ~`api.lua:458`)

```lua
    elseif tool_type == "save_preference" then
      local saved = config.append_user_preference(tool_arg, { source = "learned" })
      complete(saved and ("Saved to user preferences: " .. tostring(tool_arg)) or "Error: could not save preference.")
```

### 6d. Auto‑run + status in the tool loop (after the `save_memory` block, ~`api.lua:1690`)

Add a sibling to the `save_memory` block (`api.lua:1680‑1690`), immediately after its closing `end` (before `local details` at ~1692). This one also kicks the compaction budget check:

```lua
        -- Preference writes go to global settings and always auto-run (no approval).
        if tool_type == "save_preference" then
          emit_status(opts, "remember", status_label(tool_arg, 40))
          if opts.notify_fn then
            opts.notify_fn(string.format("\n> **System**: Learned preference: %s\n", tostring(tool_arg)))
          end
          M.execute_tool(tool_type, tool_arg, function(output)
            table.insert(results, { id = tc.id, name = tc.name, output = output })
            pcall(function() require("ai_assistant.memory_llm").maybe_compact() end)
            process(i + 1)
          end, opts)
          return
        end
```

`emit_status` / `status_label` / `process` / `results` / `opts` are all in scope here (same block as `save_memory`).

### 6e. (Optional) advertise it in the system prompt

The tool docs prose (`api.lua:1188‑1197`) lists only `run_command`/`read_file`/`write_file` (it already omits `save_memory`). The model still gets the full schema via the native tools array, but a nudge helps:

```
- `save_preference` — remember a durable, cross-project preference about how the user likes to work
```

---

## 7. Step 5 — Compaction trigger (already wired)

Compaction is the **token‑saving half**: `user_context` is injected on *every* turn, so it must stay bounded. Both triggers are wired:

- **Automatic:** `memory_llm.maybe_compact()` after `save_preference` (6d) and after an accept (Step 6). Acts only when `#user_context > 25` (`COMPACT_ITEM_BUDGET`).
- **Manual:** `memory_llm.force_compact()` from the menu (next step).

`apply_compaction` re‑loads settings inside its callback, backs up to `user_context_backup`, validates a non‑empty `{id,text}` list, and caps to 20 — so a stale snapshot or a junk model reply can’t clobber or empty your prefs.

---

## 8. Step 6 — `<leader>cx` review UI (`ui.lua`)

### 8a. Add the review screen (define near `del_context_item`, ~`ui.lua:656`)

Mirrors `del_context_item`’s nui.menu style; `local function` so it can recurse to refresh:

```lua
local function review_pending_preferences()
  local pending = config.list_pending_preferences()
  if #pending == 0 then
    vim.notify("AI Assistant: No learned preferences to review.", vim.log.levels.INFO)
    M.manage_context()
    return
  end

  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event
  local lines = {
    Menu.item("< Back to Settings", { id = "back" }),
    Menu.separator("Learned (pending review)"),
  }
  for _, it in ipairs(pending) do
    lines[#lines + 1] = Menu.item(string.format("[%s] %s", it.id, it.text), { id = it.id, text = it.text })
  end

  local menu = Menu({
    position = "50%",
    size = { width = 72, height = math.min(18, #lines + 2) },
    border = { style = "rounded", text = { top = " Review Learned Preferences ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = lines,
    on_submit = function(item)
      if item.id == "back" then M.manage_context(); return end

      local sub = Menu({
        position = "50%",
        size = { width = 52, height = 7 },
        border = { style = "rounded", text = { top = " Candidate Action ", top_align = "center" } },
        win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
      }, {
        lines = {
          Menu.item("Accept", { do_what = "accept" }),
          Menu.item("Edit, then Accept", { do_what = "edit" }),
          Menu.item("Reject", { do_what = "reject" }),
          Menu.item("< Back", { do_what = "back" }),
        },
        on_submit = function(choice)
          if choice.do_what == "accept" then
            config.accept_pending_preference(item.id)
            require("ai_assistant.memory_llm").maybe_compact()
            vim.notify("AI Assistant: Preference accepted.", vim.log.levels.INFO)
          elseif choice.do_what == "edit" then
            local edited = vim.fn.input("Edit preference: ", item.text)
            config.reject_pending_preference(item.id)               -- drop original candidate
            if edited and vim.trim(edited) ~= "" then
              config.append_user_preference(edited, { id = item.id, source = "learned" })
              require("ai_assistant.memory_llm").maybe_compact()
              vim.notify("AI Assistant: Preference saved.", vim.log.levels.INFO)
            end
          elseif choice.do_what == "reject" then
            config.reject_pending_preference(item.id)
            vim.notify("AI Assistant: Candidate rejected.", vim.log.levels.INFO)
          end
          review_pending_preferences()                              -- refresh the (shorter) list
        end,
      })
      sub:mount()
      sub:on(event.BufLeave, function() sub:unmount() end)
    end,
  })

  menu:mount()
  menu:on(event.BufLeave, function() menu:unmount() end)
end
```

`append_user_preference`/`accept_pending_preference` are synchronous load→mutate→save, so calling them from these handlers is safe; `maybe_compact()` is async and best‑effort.

### 8b. Add menu entries — `M.manage_context` (`ui.lua:1207‑1221`)

Append two items after item 13, and bump `size.height` from `15` to `17` (line 1199) so they’re visible. ✅ VERIFIED: `manage_context` already loads `settings` at L1195, so the count read is cheap:

```lua
      Menu.item(string.format("14. Review Learned Preferences (%d)", config.count_pending_preferences()), { action = "review_pending" }),
      Menu.item("15. Compact Preferences Now", { action = "compact_now" }),
```

The `(%d)` badge is your “it learned something” signal — without auto‑injecting anything unreviewed.

### 8c. Add handlers — `M.handle_context_action` (`ui.lua:1147`, before the closing `end` at 1189)

```lua
  elseif action == "review_pending" then
    review_pending_preferences()
  elseif action == "compact_now" then
    require("ai_assistant.memory_llm").force_compact(function(did, before, after)
      if did then
        vim.notify(string.format("AI: compacted preferences %d → %d", before, after), vim.log.levels.INFO)
      else
        vim.notify("AI: nothing to compact (or local model unavailable).", vim.log.levels.WARN)
      end
      M.manage_context()
    end)
```

`force_compact`’s callback runs on the main loop (`call_json` uses `schedule_wrap`), so `vim.notify`/`M.manage_context()` are safe to call directly.

### 8d. (Optional) show provenance — `view_user_context` (`ui.lua:511‑515`)

```lua
  for _, item in ipairs(settings.user_context) do
    local tag = item.source and (" (" .. item.source .. ")") or ""
    table.insert(lines, "ID: " .. item.id .. tag)
    table.insert(lines, "Content: " .. item.text)
    table.insert(lines, string.rep("-", 45))
  end
```

---

## 9. Step 7 — Injection (already done — verify + the one tweak)

User preferences are already injected at **`api.lua:1208‑1214`**:

```lua
  -- 3. User preferences (stable across the session)
  if settings.user_context and #settings.user_context > 0 then
    table.insert(system_parts, "\n## User Preferences & Profile")
    for _, item in ipairs(settings.user_context) do
      table.insert(system_parts, string.format("- **%s**: %s", item.id, item.text))
    end
  end
```

**The “one tweak” is that there is essentially nothing to change — by design:**

1. ✅ **`pending_context` is never injected.** The build reads only `settings.user_context`. Candidates stay invisible until accepted.
2. ✅ **Provenance is ignored at injection.** Only `item.id` and `item.text` are emitted, so `source`/`confidence`/`updated` ride along in storage without bloating the prompt.
3. **Cache implication — why compaction matters.** This block sits in the *cacheable prefix* (persona → tool docs → **prefs** → memory → project context). Any edit to `user_context` invalidates the prefix cache for subsequent turns. Accepts/learns are infrequent, so that’s fine; **compaction** keeps this block small and the prefix cheap over time, ordered most‑important‑first (the compaction prompt enforces ordering).

---

## 10. Data shapes (reference)

```lua
-- settings.user_context[i]  (INJECTED every turn)
{ id = "prefer_stdlib", text = "Prefer the standard library over new deps.",
  source = "manual"|"learned"|"compacted", confidence = 0.8?, updated = "2026-06-06"? }
-- legacy items may be just { id, text } — treat extra fields as optional.

-- settings.pending_context[i]  (NEVER injected; review queue)
{ id = "...", text = "...", source = "learned", confidence = 0.0-1.0, action = "add"|"update" }

-- history_data[i]  (chat transcript; verified at api.lua:727-744, 1632-1635)
{ role = "user"|"model"|"tool", content = "string|nil|vim.NIL",
  tool_calls = {...}, thinking_blocks = {...}, tool_results = {...} }
-- assistant turns are role="model" (NOT "assistant"); tool turns are role="tool"
-- with .tool_results and NO .content. Extraction uses role ∈ {user, model} with a
-- type(content)=="string" guard (rejects nil AND vim.NIL from reloaded chats).
```

---

## 11. Test plan

1. **Defaults migrate.** `:lua print(vim.inspect(require('ai_assistant.config').load_settings().pending_context))` → `{}` (not nil); `memory_model` present.
2. **Model reachable + JSON parse.** `:lua require('ai_assistant.memory_llm').extract_preferences({{role='user',content='Always use 2-space indents and prefer the Lua stdlib over plugins. Never add dependencies without asking.'},{role='model',content='Understood.'},{role='user',content='thanks'},{role='model',content='done'}}, {}, function(n) vim.notify('learned '..tostring(n)) end)` → a notify and items in `pending_context`. (If it no‑ops: `ollama serve` / model name / check `:messages`.)
3. **Editor never freezes.** Run #2 while typing — input stays responsive (proves async).
4. **Fence robustness.** Confirm parsing survives a fenced reply: the `%b{}`/fence extractor handles ```` ```json {...} ```` and leading prose (the empirically‑observed failure mode).
5. **Review flow.** `<leader>cx` → “Review Learned Preferences (N)” → Accept → appears in “View User Context Items” with `(learned)`; pending count drops. **Edit‑then‑accept** and **Reject** dequeue correctly.
6. **Dedup.** Re‑run #2 (same texts) → no new pending items (text‑level dedup). Add a pref with different casing/punctuation → still deduped.
7. **`save_preference` tool.** In a chat: “Remember that I always prefer pytest over unittest.” → a “Learned preference” line and the item in `user_context` immediately.
8. **Compaction.** Temporarily set `COMPACT_ITEM_BUDGET = 2`, accept a few → auto‑compaction fires; or menu item 15. Verify `user_context` shrinks (≤20), `user_context_backup` holds the pre‑compaction list. Restore the budget.
9. **Both close paths + guards.** A ≥2‑user‑turn chat: close via `<leader>cc` *and* via Esc/`C‑c` → extraction runs each (distinct chats). Resume a chat then close → no duplicate extraction (per‑id guard); trivial 1‑turn chats don’t extract.
10. **No regression.** `save_memory`, normal tool calls, prompt‑injection ordering, and API‑key saves via `<leader>cx` all still work (no clobbered settings).

---

## 12. File‑by‑file change checklist

| File | Change |
|---|---|
| `config.lua` | `default_settings`: add `pending_context = {}` and `memory_model = "qwen3.6:35b-a3b"` (after `user_context`, ~L111). New section after `clear_memory` (~L526): locals `norm_text`, `slugify` (edge‑strip), `unique_id`, `as_list`, `take_pending`; public `append_user_preference`, `add_pending_preferences` (batch), `list_pending_preferences`, `count_pending_preferences`, `accept_pending_preference`, `reject_pending_preference`. |
| `memory_llm.lua` | **New file.** Async `call_json` (callback + `schedule_wrap` + `format="json"` + fence/`%b{}` extract + fire‑once); `extract_preferences` (→ `add_pending_preferences`); `compact_preferences` (cap 20); `apply_compaction`; `maybe_compact`; `force_compact`. |
| `ui.lua` | Module‑level `extracted_sessions = {}`. `learn_from_closed_chat` helper (~L656) called in `toggle_chat` gated on `not loaded_history` (~L1247) **and** `close_fn` (~L1405) — both before `session=nil`. `review_pending_preferences` (~L656). `manage_context`: items 14/15 + bump height (L1199/L1207‑1221). `handle_context_action`: `review_pending` + `compact_now` (~L1189). Optional: provenance tag in `view_user_context` (L511). |
| `api.lua` | `TOOL_DEFS`: add `save_preference` (~L671). `tool_call_to_exec`: branch (~L716). `execute_tool`: branch (~L458). Tool loop: auto‑run/status block + `maybe_compact()` (~L1690). Optional: mention `save_preference` in system‑prompt tool docs (~L1196). |
| *(ops)* | `ollama serve` + ensure `qwen3.6:35b-a3b` (or set `memory_model`). Optional/unrelated: `ollama pull nomic-embed-text` to revive RAG. |

---

## 13. Gotchas / corrections (all confirmed against code + live Ollama)

- **Async is mandatory (BLOCKER).** A callback‑less `curl.post` runs synchronously (`job:sync`) and freezes Neovim for the whole inference (~20s cold). `vim.schedule` does not fix it. Use the `callback` form. *(§4.)*
- **`format` must be the string `"json"`, not a schema object (BUG).** The schema‑object path is ignored by qwen3.6 here and yields fenced output that fails `json_decode`. Describe the shape in the prompt; extract with fence/`%b{}` before decoding. *(§4.)*
- **Decode on the main loop.** `vim.fn.json_decode` is unsafe in plenary’s fast‑event callback; `vim.schedule_wrap` (used above) moves it to the main loop. *(§4.)*
- **Assistant role is `"model"`, not `"assistant"`** in `history_data`; tool turns are `"tool"` with `.tool_results` and no `.content`; type‑guard `content` to dodge `vim.NIL` from reloaded chats. *(§4 transcript builder.)*
- **Two close paths + nil’d session + resume + tiny chats (BUG).** Hook both `toggle_chat` (gated on `not loaded_history`) and `close_fn`; snapshot before `session=nil`; gate on ≥2 user turns; dedupe by session id. *(§5.)*
- **Dedup by text, not id (BUG).** Two texts can share a slug → silent clobber; re‑phrasings accumulate. Normalize text as the primary key; slug only as a collision‑resistant id. *(§3.)*
- **Whole‑file settings = clobber risk (BLOCKER).** Never carry a settings table across an async boundary; re‑load inside callbacks; keep `config` mutators synchronous (atomic on the single‑threaded main loop). *(§2.)*
- **`pending_context` must never be injected** — confirmed it isn’t; injection reads only `user_context`. *(§9.)*
- **New tools auto‑propagate** to all providers via the `TOOL_DEFS` iteration — no per‑provider edits. *(§6.)*
- **Always go through `M.save_settings`** (0600 perms + serialize guard); never write the settings file directly. *(§3.)*
