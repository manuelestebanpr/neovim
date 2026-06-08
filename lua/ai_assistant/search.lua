-- lua/ai_assistant/search.lua
-- Client-side web search + single-page fetch for the AI assistant. Exposes the
-- backing logic for two native tools that are handed to EVERY provider (including
-- the local llama.cpp model): `web_search` and `fetch_url`.
--
-- Design follows PewDiePie's open-source "Odysseus" workspace and the common 2026
-- local-agent pattern: a keyless, self-hosted SearXNG default with a DuckDuckGo
-- no-key last-resort fallback, plus optional key-based backends (Tavily / Serper /
-- Brave). `fetch_url` reads a page via Jina's keyless reader (clean markdown) and
-- falls back to a raw fetch + tag strip.
--
-- CONTRACT (mirrors api.lua's execute_tool): every public entry point calls its
-- callback EXACTLY once with a single STRING and NEVER raises. All network work is
-- async (plenary.curl) and the callback always lands on the main loop, so the
-- caller can safely touch buffers from it. Errors come back as "Error: ..." /
-- explanatory strings so the model can recover instead of the turn stalling.

local M = {}
local config = require("ai_assistant.config")

----------------------------------------------------------------------
-- Coercion + text helpers
----------------------------------------------------------------------

-- Coerce any decoded-JSON value (which may be vim.NIL / number / table) to a real
-- string. Same trap api.lua documents: vim.NIL is truthy and crashes on concat.
local function jstr(v)
  if type(v) == "string" then return v end
  return ""
end

local function clamp_int(v, default, lo, hi)
  local n = tonumber(v)
  if not n then return default end
  n = math.floor(n)
  if n < lo then n = lo elseif n > hi then n = hi end
  return n
end

-- Collapse whitespace and cap a snippet so one result can't flood a small model.
local function snippet(s, n)
  s = jstr(s):gsub("%s+", " ")
  s = vim.trim(s)
  n = n or 250
  if #s > n then return s:sub(1, n - 1) .. "…" end
  return s
end

local function url_encode(s)
  return (jstr(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function url_decode(s)
  s = jstr(s):gsub("+", " "):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return s
end

-- Minimal HTML -> text fallback for fetch_url when the reader API is unavailable.
-- Best-effort only (the primary path returns clean markdown); good enough to give
-- the model the readable body of a page.
local function strip_html(html)
  html = jstr(html)
  html = html:gsub("<![^>]*>", " ")           -- doctype / comments-ish
  html = html:gsub("<%s*[sS][cC][rR][iI][pP][tT].-</%s*[sS][cC][rR][iI][pP][tT]%s*>", " ")
  html = html:gsub("<%s*[sS][tT][yY][lL][eE].-</%s*[sS][tT][yY][lL][eE]%s*>", " ")
  -- Unterminated <script>/<style> (no closing tag): drop to end-of-string so the
  -- raw JS/CSS body doesn't leak into the extracted text.
  html = html:gsub("<%s*[sS][cC][rR][iI][pP][tT][%s>].*$", " ")
  html = html:gsub("<%s*[sS][tT][yY][lL][eE][%s>].*$", " ")
  html = html:gsub("<[^>]+>", " ")            -- remaining tags
  html = html:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
             :gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#0?39;", "'")
             :gsub("&#x27;", "'"):gsub("&#x2F;", "/")
  html = html:gsub("[ \t\r]+", " ")
  html = html:gsub("%s*\n%s*", "\n")
  html = html:gsub("\n\n\n+", "\n\n")
  return vim.trim(html)
end

local function decode(body)
  local ok, t = pcall(vim.json.decode, jstr(body))
  if ok and type(t) == "table" then return t end
  return nil
end

----------------------------------------------------------------------
-- Tiny in-memory TTL cache (avoids hammering rate-limited backends during a
-- multi-step turn). Keyed by query/url; survives only for the editor session.
----------------------------------------------------------------------

local cache = {}
local CACHE_TTL = 900 -- 15 minutes

local function cache_get(k)
  local e = cache[k]
  if e and (os.time() - e.t) < CACHE_TTL then return e.v end
  cache[k] = nil
  return nil
end

local function cache_set(k, v)
  cache[k] = { t = os.time(), v = v }
end

----------------------------------------------------------------------
-- HTTP wrapper: fire-once, never raises, callback always on the main loop.
----------------------------------------------------------------------

local function http(method, url, req_opts, cb)
  local curl = require("plenary.curl")
  local finished = false
  local function finish(res, err)
    if finished then return end
    finished = true
    -- Re-enter the main loop so callers can safely build the next request and the
    -- downstream tool result can touch buffers.
    vim.schedule(function() cb(res, err) end)
  end
  local req = vim.tbl_extend("force", req_opts or {}, {
    timeout = (req_opts and req_opts.timeout) or 12000,
    on_error = function(e)
      finish(nil, (e and (e.message or e.stderr or e.exit)) and tostring(e.message or e.stderr or e.exit) or "connection failed")
    end,
    callback = function(res) finish(res, nil) end,
  })
  local ok, err = pcall(function()
    if method == "POST" then
      curl.post(url, req)
    else
      curl.get(url, req)
    end
  end)
  if not ok then
    finish(nil, tostring(err))
  end
end

-- Wrap a backend's response parser. The http() callback runs later under
-- vim.schedule, OUTSIDE execute_tool's pcall, so a raise there (e.g. a malformed
-- response whose results array holds non-table elements) would escape every guard
-- and strand the turn -> stuck spinner. This funnels err / a missing response /
-- any parser raise into a single cb(errstring) so the fallback chain still
-- advances and the turn always resolves.
local function guarded(name, cb, parse)
  return function(res, err)
    if err then return cb(name .. " request failed: " .. err) end
    if type(res) ~= "table" then return cb(name .. ": no response") end
    local ok, e = pcall(parse, res)
    if not ok then cb(name .. " handler error: " .. tostring(e)) end
  end
end

----------------------------------------------------------------------
-- Search backends. Each: backend(query, n, settings, cb) -> cb(err, results, answer)
-- where results = { {title=, url=, snippet=}, ... }. On any failure cb(errstring).
----------------------------------------------------------------------

local function searxng(query, n, settings, cb)
  local ws = settings.web_search or {}
  local base = (jstr(ws.searxng_url) ~= "" and ws.searxng_url) or "http://127.0.0.1:8080"
  base = (base:gsub("/+$", ""))
  http("GET", base .. "/search", {
    query = { q = query, format = "json", safesearch = 1 },
    -- SearXNG's bot limiter rejects requests without a browser-ish UA.
    headers = { ["User-Agent"] = "Mozilla/5.0 (ai_assistant.nvim web_search)" },
  }, guarded("SearXNG", cb, function(res)
    if res.status == 403 then
      return cb("SearXNG returned 403. Enable JSON output in its settings.yml (search: { formats: [html, json] }) and restart the server.")
    end
    if res.status ~= 200 then return cb("SearXNG HTTP " .. tostring(res.status)) end
    local d = decode(res.body)
    if not d or type(d.results) ~= "table" then return cb("SearXNG returned no parseable results") end
    local out = {}
    for _, r in ipairs(d.results) do
      if type(r) == "table" then
        out[#out + 1] = { title = jstr(r.title), url = jstr(r.url), snippet = jstr(r.content) }
      end
      if #out >= n then break end
    end
    local answer
    if type(d.answers) == "table" and d.answers[1] then
      local a = d.answers[1]
      answer = jstr(type(a) == "table" and a.answer or a)
    end
    cb(nil, out, answer ~= "" and answer or nil)
  end))
end

local function tavily(query, n, settings, cb)
  local key = config.get_search_key(settings, "tavily")
  if key == "" then return cb("Tavily API key not set") end
  local body = vim.fn.json_encode({
    query = query, max_results = n, search_depth = "basic",
    include_answer = true, topic = "general",
  })
  http("POST", "https://api.tavily.com/search", {
    headers = { ["Authorization"] = "Bearer " .. key, ["Content-Type"] = "application/json" },
    body = body,
  }, guarded("Tavily", cb, function(res)
    if res.status ~= 200 then return cb("Tavily HTTP " .. tostring(res.status) .. ": " .. snippet(res.body, 200)) end
    local d = decode(res.body)
    if not d or type(d.results) ~= "table" then return cb("Tavily returned no results") end
    local out = {}
    for _, r in ipairs(d.results) do
      if type(r) == "table" then
        out[#out + 1] = { title = jstr(r.title), url = jstr(r.url), snippet = jstr(r.content) }
      end
      if #out >= n then break end
    end
    local answer = jstr(d.answer)
    cb(nil, out, answer ~= "" and answer or nil)
  end))
end

local function serper(query, n, settings, cb)
  local key = config.get_search_key(settings, "serper")
  if key == "" then return cb("Serper API key not set") end
  local body = vim.fn.json_encode({ q = query, num = n, gl = "us", hl = "en" })
  http("POST", "https://google.serper.dev/search", {
    headers = { ["X-API-KEY"] = key, ["Content-Type"] = "application/json" },
    body = body,
  }, guarded("Serper", cb, function(res)
    if res.status ~= 200 then return cb("Serper HTTP " .. tostring(res.status)) end
    local d = decode(res.body)
    if not d or type(d.organic) ~= "table" then return cb("Serper returned no results") end
    local out = {}
    for _, r in ipairs(d.organic) do
      if type(r) == "table" then
        out[#out + 1] = { title = jstr(r.title), url = jstr(r.link), snippet = jstr(r.snippet) }
      end
      if #out >= n then break end
    end
    local answer
    if type(d.answerBox) == "table" then
      answer = jstr(d.answerBox.answer)
      if answer == "" then answer = jstr(d.answerBox.snippet) end
    end
    cb(nil, out, answer ~= "" and answer or nil)
  end))
end

local function brave(query, n, settings, cb)
  local key = config.get_search_key(settings, "brave")
  if key == "" then return cb("Brave API key not set") end
  http("GET", "https://api.search.brave.com/res/v1/web/search", {
    query = { q = query, count = n },
    headers = { ["X-Subscription-Token"] = key, ["Accept"] = "application/json" },
  }, guarded("Brave", cb, function(res)
    if res.status ~= 200 then return cb("Brave HTTP " .. tostring(res.status)) end
    local d = decode(res.body)
    if not d or type(d.web) ~= "table" or type(d.web.results) ~= "table" then
      return cb("Brave returned no results")
    end
    local out = {}
    for _, r in ipairs(d.web.results) do
      if type(r) == "table" then
        out[#out + 1] = { title = jstr(r.title), url = jstr(r.url), snippet = strip_html(jstr(r.description)) }
      end
      if #out >= n then break end
    end
    cb(nil, out)
  end))
end

-- Resolve DuckDuckGo's /l/?uddg= redirect wrapper to the real destination URL.
local function ddg_href(href)
  href = jstr(href)
  local uddg = href:match("[?&]uddg=([^&]+)")
  if uddg then return url_decode(uddg) end
  if href:match("^//") then return "https:" .. href end
  return href
end

local function duckduckgo(query, n, settings, cb)
  http("POST", "https://html.duckduckgo.com/html/", {
    body = "q=" .. url_encode(query),
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    },
  }, guarded("DuckDuckGo", cb, function(res)
    local body = jstr(res.body)
    if res.status == 202 or body:find("anomaly%-modal") then
      return cb("DuckDuckGo is rate-limiting (CAPTCHA challenge). Configure SearXNG or set a Tavily API key for reliable search.")
    end
    if res.status ~= 200 then return cb("DuckDuckGo HTTP " .. tostring(res.status)) end
    local out = {}
    for href, title in body:gmatch('<a[^>]-class="result__a"[^>]-href="(.-)"[^>]*>(.-)</a>') do
      local url = ddg_href(href)
      if url ~= "" and not url:find("duckduckgo%.com/y%.js") then
        out[#out + 1] = { title = strip_html(title), url = url, snippet = "" }
      end
      if #out >= n then break end
    end
    if #out == 0 then return cb("DuckDuckGo returned no results") end
    cb(nil, out)
  end))
end

local BACKENDS = {
  searxng = searxng,
  tavily = tavily,
  serper = serper,
  brave = brave,
  duckduckgo = duckduckgo,
}

----------------------------------------------------------------------
-- Result formatting for the model
----------------------------------------------------------------------

local function format_results(query, results, answer, backend)
  local parts = {}
  if answer and answer ~= "" then
    parts[#parts + 1] = string.format("[%s answer] %s\n", backend, snippet(answer, 600))
  end
  parts[#parts + 1] = string.format('Web search results for "%s" (via %s):', query, backend)
  for i, r in ipairs(results) do
    parts[#parts + 1] = string.format("[%d] %s\n    %s", i, r.title ~= "" and r.title or "(untitled)", r.url)
    if r.snippet and r.snippet ~= "" then
      parts[#parts + 1] = "    " .. snippet(r.snippet, 250)
    end
  end
  parts[#parts + 1] = "\nCite these source URLs in your answer. Call fetch_url on the most relevant result to read its full page before relying on it."
  return table.concat(parts, "\n")
end

----------------------------------------------------------------------
-- Public: web_search
----------------------------------------------------------------------

function M.search(query, opts, cb)
  opts = opts or {}
  local settings = config.load_settings()
  local ws = settings.web_search or {}
  query = vim.trim(jstr(query))

  local fired = false
  local function done(s)
    if fired then return end
    fired = true
    cb(s) -- http() already re-entered the main loop; sync paths are on it too.
  end

  if query == "" then return done("Error: web_search requires a non-empty query.") end
  if ws.enabled == false or ws.provider == "disabled" then
    return done("Error: web search is disabled in the AI assistant settings.")
  end

  local n = clamp_int(opts.max_results or ws.max_results, ws.max_results or 5, 1, 10)

  -- Provider order. A specific provider => just that one. "auto" (default) builds
  -- a fallback chain: key-based backends first (only if their key is present),
  -- then SearXNG, then DuckDuckGo as a keyless last resort.
  local provider = jstr(ws.provider) ~= "" and ws.provider or "auto"
  local chain
  if provider ~= "auto" and BACKENDS[provider] then
    chain = { provider }
  else
    chain = {}
    if config.get_search_key(settings, "tavily") ~= "" then chain[#chain + 1] = "tavily" end
    if config.get_search_key(settings, "serper") ~= "" then chain[#chain + 1] = "serper" end
    if config.get_search_key(settings, "brave") ~= "" then chain[#chain + 1] = "brave" end
    chain[#chain + 1] = "searxng"
    chain[#chain + 1] = "duckduckgo"
  end

  local cache_key = string.format("s:%s:%d:%s", provider, n, query)
  local cached = cache_get(cache_key)
  if cached then return done(cached) end

  local errors = {}
  local function try(idx)
    local name = chain[idx]
    if not name then
      local msg = "No web results."
      if #errors > 0 then msg = msg .. " Backends tried:\n" .. table.concat(errors, "\n") end
      return done(msg)
    end
    BACKENDS[name](query, n, settings, function(err, results, answer)
      if err or not results or #results == 0 then
        errors[#errors + 1] = string.format("- %s: %s", name, err or "no results")
        return try(idx + 1)
      end
      local out = format_results(query, results, answer, name)
      cache_set(cache_key, out)
      done(out)
    end)
  end
  try(1)
end

----------------------------------------------------------------------
-- Public: fetch_url
----------------------------------------------------------------------

-- Reject private / internal / loopback hosts (SSRF guard) before fetching a
-- model-supplied URL. Mirrors the Odysseus / Claude Code fetch guard. NOTE: this
-- is a string-level check on the URL's authority; it does NOT resolve DNS, so a
-- public name that resolves to a private IP (DNS rebinding) is not caught — an
-- inherent limit of a client-side guard. Covers: userinfo stripping, :port,
-- trailing dot, IPv6 (brackets/loopback/ULA/link-local/mapped-v4), and numeric
-- IPv4 encodings (bare-integer / hex / octal) that bypass dotted-quad parsing.
local function is_blocked_host(host)
  host = jstr(host):lower()
  host = host:gsub("^.*@", "")          -- strip any userinfo (user:pass@host)
  -- IPv6 literal is bracketed in a URL: validate the inner address, drop the port.
  local v6 = host:match("^%[(.-)%]")
  if v6 then
    host = v6
  else
    host = host:gsub(":%d+$", "")        -- strip :port for hostname / IPv4
  end
  host = host:gsub("%.$", "")           -- strip a single trailing dot (localhost.)
  if host == "" then return true end

  -- IPv6 forms.
  if host:find(":") then
    if host == "::1" or host == "::" then return true end       -- loopback / unspecified
    if host:match("^f[cd]") then return true end                -- fc00::/7 ULA
    if host:match("^fe[89ab]") then return true end             -- fe80::/10 link-local
    local mapped = host:match("::ffff:(%d+%.%d+%.%d+%.%d+)$")    -- IPv4-mapped IPv6
    if mapped then
      host = mapped                                              -- fall through to v4 checks
    else
      return false                                              -- otherwise treat as public v6
    end
  end

  -- Name-based internal hosts.
  if host == "localhost" or host:match("%.localhost$") then return true end
  if host == "0.0.0.0" then return true end
  if host:match("%.local$") or host:match("%.internal$") then return true end

  -- Numeric IPv4 encodings that evade dotted-quad parsing.
  if host:match("^%d+$") then return true end      -- bare integer (e.g. 2130706433 = 127.0.0.1)
  if host:match("^0[xX]") then return true end     -- hex (0x7f000001)

  -- IPv4 dotted quad.
  local a, b = host:match("^(%d+)%.(%d+)%.")
  a, b = tonumber(a), tonumber(b)
  if a then
    if host:match("^0%d") then return true end          -- octal-form octet (0177.x = 127.x)
    if a == 127 or a == 10 or a == 0 then return true end
    if a == 169 and b == 254 then return true end       -- link-local / cloud metadata
    if a == 192 and b == 168 then return true end
    if a == 172 and b and b >= 16 and b <= 31 then return true end
    if a == 100 and b and b >= 64 and b <= 127 then return true end -- CGNAT
  end
  return false
end

function M.fetch(url, cb)
  local settings = config.load_settings()
  local ws = settings.web_search or {}
  url = vim.trim(jstr(url))

  local fired = false
  local function done(s)
    if fired then return end
    fired = true
    cb(s)
  end

  if url == "" then return done("Error: fetch_url requires a URL.") end
  local scheme, host = url:match("^(%a[%w+.%-]*)://([^/]+)")
  if not scheme or (scheme:lower() ~= "http" and scheme:lower() ~= "https") then
    return done("Error: refusing to fetch a non-http(s) URL: " .. url)
  end
  if is_blocked_host(host) then
    return done("Error: refusing to fetch a private/internal/loopback address: " .. host)
  end

  local cap = clamp_int(ws.fetch_char_cap, 10000, 500, 200000)
  local cache_key = "f:" .. url
  local cached = cache_get(cache_key)
  if cached then return done(cached) end

  local function finalize(text, note)
    text = jstr(text)
    if #text > cap then text = text:sub(1, cap) .. "\n\n…[content truncated]…" end
    local out = "Source: " .. url .. (note and ("  (" .. note .. ")") or "") .. "\n\n" .. text
    cache_set(cache_key, out)
    done(out)
  end

  -- Primary: Jina reader. Keyless reader still works in 2026 and returns clean
  -- markdown; a Jina key (if set) lifts rate limits.
  local jheaders = { ["Accept"] = "application/json", ["X-Return-Format"] = "markdown" }
  local jkey = config.get_search_key(settings, "jina")
  if jkey ~= "" then jheaders["Authorization"] = "Bearer " .. jkey end

  -- Fallback: fetch the raw page and strip tags. pcall-guarded so a parser raise
  -- in this scheduled callback resolves the turn instead of stranding it.
  local function raw_fetch()
    http("GET", url, {
      headers = { ["User-Agent"] = "Mozilla/5.0 (ai_assistant.nvim fetch_url)" },
      timeout = 20000,
    }, function(res2, err2)
      local ok, e = pcall(function()
        if err2 then return done("Error: fetch_url failed: " .. err2) end
        if type(res2) ~= "table" or res2.status ~= 200 then
          return done("Error: fetch_url got HTTP " .. tostring(type(res2) == "table" and res2.status) .. " for " .. url)
        end
        local text = strip_html(res2.body)
        if text == "" then return done("Error: fetch_url retrieved no readable text from " .. url) end
        finalize(text, "raw + stripped")
      end)
      if not ok then done("Error: fetch_url handler error: " .. tostring(e)) end
    end)
  end

  -- Primary: Jina reader. Keyless reader still works in 2026 and returns clean
  -- markdown; a Jina key (if set) lifts rate limits.
  http("GET", "https://r.jina.ai/" .. url, { headers = jheaders, timeout = 20000 }, function(res, err)
    local ok, e = pcall(function()
      if not err and type(res) == "table" and res.status == 200 then
        local d = decode(res.body)
        -- type-guard the sub-table: a JSON `data: null` decodes to vim.NIL, which
        -- is truthy and would raise on `.content` — fall through to raw_fetch.
        local data = (type(d) == "table" and type(d.data) == "table") and d.data or nil
        local content = data and jstr(data.content) or ""
        if content ~= "" then
          local title = data and jstr(data.title) or ""
          return finalize((title ~= "" and ("# " .. title .. "\n\n") or "") .. content, "via r.jina.ai")
        end
      end
      raw_fetch()
    end)
    if not ok then
      -- Don't strand the turn if the Jina-branch parse raises; try the raw page.
      local ok2 = pcall(raw_fetch)
      if not ok2 then done("Error: fetch_url handler error: " .. tostring(e)) end
    end
  end)
end

return M
