-- sysmon.lua — non-blocking CPU/GPU/RAM monitor for lualine.
-- Samples system stats on a libuv timer and caches them so statusline
-- reads are O(1) and never block the UI thread.

local M = {}

-- Cached display values (read by lualine components).
M.cpu = ""
M.ram = ""
M.gpu = ""

-- Nerd-font icons (literal UTF-8).
local ICON_CPU = ""
local ICON_RAM = ""
local ICON_GPU = "󰢮"

-- Module-local state.
local prev_total = nil
local prev_busy = nil
local timer = nil
local started = false
local gpu_inflight = false

local uv = vim.uv or vim.loop

-- Sample CPU% from /proc/stat first line, using deltas between calls.
local function sample_cpu()
  local f = io.open("/proc/stat", "r")
  if not f then
    return
  end
  local line = f:read("*l")
  f:close()
  if not line then
    return
  end
  -- cpu  user nice system idle iowait irq softirq steal guest guest_nice
  local total = 0
  local idle_all = 0
  local i = 0
  for num in line:gmatch("%d+") do
    local n = tonumber(num) or 0
    total = total + n
    -- field index 0=user 1=nice 2=system 3=idle 4=iowait ...
    if i == 3 or i == 4 then
      idle_all = idle_all + n
    end
    i = i + 1
  end
  local busy = total - idle_all
  if prev_total and total > prev_total then
    local dt = total - prev_total
    local db = busy - prev_busy
    local pct = math.floor((db / dt) * 100 + 0.5)
    if pct < 0 then
      pct = 0
    elseif pct > 100 then
      pct = 100
    end
    M.cpu = ICON_CPU .. " " .. pct .. "%"
  end
  prev_total = total
  prev_busy = busy
end

-- Sample RAM% from /proc/meminfo (MemTotal/MemAvailable).
local function sample_ram()
  local f = io.open("/proc/meminfo", "r")
  if not f then
    return
  end
  local mem_total, mem_avail
  for line in f:lines() do
    local k, v = line:match("^(%w+):%s+(%d+)")
    if k == "MemTotal" then
      mem_total = tonumber(v)
    elseif k == "MemAvailable" then
      mem_avail = tonumber(v)
    end
    if mem_total and mem_avail then
      break
    end
  end
  f:close()
  if mem_total and mem_avail and mem_total > 0 then
    local used = mem_total - mem_avail
    local pct = math.floor((used / mem_total) * 100 + 0.5)
    if pct < 0 then
      pct = 0
    elseif pct > 100 then
      pct = 100
    end
    M.ram = ICON_RAM .. " " .. pct .. "%"
  end
end

-- Sample GPU% asynchronously via nvidia-smi (never blocks).
local function sample_gpu()
  if not vim.system then
    return -- Neovim < 0.10; skip GPU.
  end
  if gpu_inflight then
    return
  end
  gpu_inflight = true
  local ok = pcall(vim.system, {
    "nvidia-smi",
    "--query-gpu=utilization.gpu",
    "--format=csv,noheader,nounits",
  }, { text = true }, vim.schedule_wrap(function(res)
    gpu_inflight = false
    if not res or res.code ~= 0 or not res.stdout then
      M.gpu = ""
      return
    end
    local pct = res.stdout:match("%d+")
    if pct then
      M.gpu = ICON_GPU .. " " .. pct .. "%"
    else
      M.gpu = ""
    end
  end))
  if not ok then
    gpu_inflight = false
  end
end

-- One sampling tick: cheap synchronous reads + async GPU kick.
local function tick()
  pcall(sample_cpu)
  pcall(sample_ram)
  pcall(sample_gpu)
end

-- Start the repeating timer (idempotent).
function M.setup()
  if started then
    return
  end
  started = true
  if not uv then
    return
  end
  -- Take an immediate first sample so values appear promptly.
  pcall(tick)
  timer = uv.new_timer()
  if not timer then
    return
  end
  timer:start(
    2500,
    2500,
    vim.schedule_wrap(function()
      pcall(tick)
    end)
  )
end

-- Component accessors (start lazily, return cached strings).
function M.cpu_component()
  if not started then
    M.setup()
  end
  return M.cpu
end

function M.ram_component()
  if not started then
    M.setup()
  end
  return M.ram
end

function M.gpu_component()
  if not started then
    M.setup()
  end
  return M.gpu
end

return M
