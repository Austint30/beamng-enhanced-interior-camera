-- Simple per-second section timing profiler for Enhanced Driver Camera
-- Measures wall clock (os.clock) duration between start/stop pairs and logs average ms per call every second.
-- Usage:
--   local profiler = require('core/enhanceddriver/profiler')
--   profiler.start('GForce')
--   ... code ...
--   profiler.stop('GForce')
--   profiler.frame(dt) -- call once per frame (dt in seconds)
-- Minimal overhead: table lookups + os.clock; disable by setting profiler.enabled = false
local M = {}

-- Fallback log if global log is unavailable in lint context
local gLog = rawget(_G, 'log') or function(...) end

-- M.enabled = true
M.enabled = false
local sections = {}
local runActive = false
local runRemaining = 0
local runDuration = 0

local function now()
  return os.clock() -- returns CPU seconds; acceptable for relative measurements
end

function M.start(name)
  if not M.enabled then return end
  local s = sections[name]
  if not s then
    s = { acc = 0, count = 0, open = nil }
    sections[name] = s
  end
  -- Avoid overwriting if already open (nested start); allow only one open per section
  if not s.open then
    s.open = now()
  end
end

function M.stop(name)
  if not M.enabled then return end
  local s = sections[name]
  if not s or not s.open then return end
  local dt = now() - s.open
  s.acc = s.acc + dt
  s.count = s.count + 1
  s.open = nil
end

function M.frame(dt)
  if not M.enabled or not runActive then return end
  runRemaining = runRemaining - dt
  if runRemaining > 0 then return end
  -- Completed run, output summary
  for name, s in pairs(sections) do
    local avgMs = 0
    local callsPerSec = 0
    if s.count > 0 then
      avgMs = (s.acc / s.count) * 1000
      callsPerSec = s.count / runDuration
    end
    gLog("I", "edc.profiler",
      string.format("%s avg: %.3f ms | calls: %d | calls/sec: %.1f", name, avgMs, s.count, callsPerSec))
    -- preserve last results; clear for next run
    s.acc = 0; s.count = 0; s.open = nil
  end
  runActive = false
  gLog("I", "edc.profiler", string.format("Profiling session complete (%.2fs)", runDuration))
end

local function startRun(duration)
  runDuration = duration or 10
  runRemaining = runDuration
  runActive = true
  -- reset accumulators at start
  for _, s in pairs(sections) do
    s.acc = 0; s.count = 0; s.open = nil
  end
  gLog("I", "edc.profiler", string.format("Started profiling for %.2f seconds", runDuration))
end

local function parseTokens(tokens)
  local duration = nil
  for i = 1, #tokens do
    local t = tokens[i]
    if t == '-t' or t == '--time' then
      local nxt = tokens[i + 1]
      if nxt and tonumber(nxt) then duration = tonumber(nxt) end
    end
  end
  return duration
end

-- Public command style entry: edcProfiler('-t', '5') or edcProfiler('-t 5') or edcProfiler()
local function command(...)
  local tokens = {}
  for i = 1, select('#', ...) do
    local arg = select(i, ...)
    if type(arg) == 'string' then
      for tk in string.gmatch(arg, '%S+') do table.insert(tokens, tk) end
    elseif type(arg) == 'number' then
      table.insert(tokens, tostring(arg))
    end
  end
  local dur = parseTokens(tokens) or 10
  startRun(dur)
end

M.command = command
_G.edcProfiler = command

function M.setEnabled(flag)
  M.enabled = not not flag
end

return M
