-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- followSmoothing — PITCH-ONLY rotational smoothing of the camera boom direction.
-- Smooths the boom's elevation (pitch) and preserves its azimuth (world yaw)
-- exactly. Azimuth smoothing was removed: easing the boom yaw desynchronised
-- it from the stock anchor/parity flip (which must stay atomic and invisible)
-- and produced visible flip glitches while reversing.
--
-- Smoothness is a TIME CONSTANT in seconds:
--   0.1  → snappy (~100 ms to reach ~63% of target)
--   0.5  → moderate
--   2.0  → very smooth / lazy
-- Higher = more smoothing = slower response.

local C = {}
C.__index = C

-- Azimuth degeneracy guard (booms pointing straight up/down have no azimuth
-- to preserve; both are dimensionless length thresholds in the same units as
-- the input direction).
local HORIZ_EPS = 1e-9

local function rateFromSmoothness(s)
  if s <= 0 then return 1000 end
  return 1 / s
end

function C:init()
  self.pitchSmooth = 3.5
  self.enabled = true
  local r = rateFromSmoothness(self.pitchSmooth)
  self._pitchSmoother = newTemporalSigmoidSmoothing(r, r, r, r)
  self._initialized = false
end

function C:reset()
  self._pitchSmoother:reset()
  self._initialized = false
end

function C:setPitchSmooth(v)
  self.pitchSmooth = v
  local r = rateFromSmoothness(v)
  self._pitchSmoother = newTemporalSigmoidSmoothing(r, r, r, r)
  self._initialized = false
end

function C:setEnabled(v) self.enabled = v end

-- adopt: snap the smoothed pitch to the current boom pitch (no easing).
-- Called when the stock anchor/parity flip fires: the flip's parity and boom
-- mirror cancel in the same frame ONLY while both stay in lockstep — if the
-- smoother instead chases the flipped pitch over its time constant, the flip
-- becomes a visible pitch/height wobble. Adopting keeps every flip atomic.
function C:adopt(dirX, dirY, dirZ)
  local len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)
  if len < HORIZ_EPS then return end
  local zc = dirZ / len
  if zc > 1 then zc = 1 elseif zc < -1 then zc = -1 end
  self._pitchSmoother:set(math.asin(zc))
  self._initialized = true
end

-- dirX, dirY, dirZ: boom direction (target -> camera), need not be normalised.
-- Returns the smoothed (x, y, z) with the same length and azimuth — only the
-- elevation changes.
function C:update(data, dirX, dirY, dirZ)
  if not self.enabled then
    return dirX, dirY, dirZ
  end

  local len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)
  if len < HORIZ_EPS then
    return dirX, dirY, dirZ
  end

  local zc = dirZ / len
  if zc > 1 then zc = 1 elseif zc < -1 then zc = -1 end
  local targetPitch = math.asin(zc)

  if not self._initialized then
    self._pitchSmoother:set(targetPitch)
    self._initialized = true
    return dirX, dirY, dirZ
  end

  local smoothedPitch = self._pitchSmoother:get(targetPitch, data.dt)

  local horiz = math.sqrt(dirX * dirX + dirY * dirY)
  if horiz < HORIZ_EPS then
    -- Boom points straight up/down: nothing to preserve in the azimuth.
    return 0, 0, math.sin(smoothedPitch) * len
  end

  -- Keep the (x, y) ratio (azimuth) exact and retarget the horizontal
  -- magnitude to the smoothed elevation.
  local scale = (len * math.cos(smoothedPitch)) / horiz
  return dirX * scale, dirY * scale, math.sin(smoothedPitch) * len
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
