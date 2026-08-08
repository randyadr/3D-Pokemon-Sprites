-- Pokemon Stadium Overworld Models - Stage 1 battle performances
--
-- This module augments Dramatic Shape's Stadium battle actors without
-- replacing BattleState or the battle renderer.  It is intentionally a
-- compatibility layer: newer Dramatic Shape builds already know how to ask a
-- Stadium model for its per-move animation, while older builds only stand the
-- model on the field.  We let the installed build run first, inspect the live
-- Stadium session, and only supply whatever request it did not already make.
--
-- Stage 1 covers:
--   * exact per-species/per-move Stadium attack animation when the pack has it
--   * generic Stadium attack fallback when a move has no table entry
--   * send-out / entrance performance
--   * faint / collapse performance, delayed until the HP bar reaches zero
--   * a short whole-body recoil when damage lands (the Stadium model set has
--     no true universal hit/flinch skeletal animation; see StadiumMon.lua)
--
-- No Nintendo assets are bundled.  Everything is read from the user's
-- already-imported Dramatic Shape Stadium packs.
local V = ...
local M = {}

local function safeLog(level, fmt, ...)
  local log = V and V.mod and V.mod.log
  local fn = log and log[level]
  if type(fn) == "function" then pcall(fn, log, fmt, ...) end
end

local function findUpvalue(fn, wanted)
  if type(fn) ~= "function" or not (debug and debug.getupvalue) then return nil end
  for i = 1, 80 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then
      return function()
        local _, now = debug.getupvalue(fn, i)
        return now
      end
    end
  end
  return nil
end

local function installSessionGetter(Stadium)
  -- Stadium.update is the best candidate on current Dramatic Shape.  Fall back
  -- to any public function known to close over the same local session.
  for _, fn in ipairs({ Stadium.update, Stadium.animOf, Stadium.showing,
                        Stadium.draw, Stadium.cast, Stadium.active }) do
    local getter = findUpvalue(fn, "session")
    if getter then return getter end
  end
  return nil
end

local function sideOf(battle, battler)
  if not (battle and battler) then return nil end
  if battler == battle.player then return "player" end
  if battler == battle.enemy then return "enemy" end
  return nil
end

local function moveIndex(battle, moveInst)
  if not battle then return nil end
  if type(battle.moveDef) == "function" then
    local ok, def = pcall(battle.moveDef, battle, moveInst)
    if ok and type(def) == "table" then
      local n = tonumber(def.index)
      if n and n >= 1 then return n end
    end
  end
  if type(moveInst) == "table" then
    local n = tonumber(moveInst.index or moveInst.id)
    if n and n >= 1 then return n end
  end
  return nil
end

local function requestAttack(mon, index)
  if not (mon and mon.rig) then return false end
  if mon.state == "faint" then return false end
  if index and type(mon.attack) == "function" then
    local ok, played = pcall(mon.attack, mon, index)
    if ok and played then return true end
  end
  if type(mon.request) == "function" then
    local ok, played = pcall(mon.request, mon, "attack")
    return ok and played and true or false
  end
  if type(mon.play) == "function" then
    local ok, played = pcall(mon.play, mon, "attack")
    return ok and played and true or false
  end
  return false
end

local function requestState(mon, state)
  if not (mon and mon.rig) then return false end
  if type(mon.request) == "function" then
    local ok, played = pcall(mon.request, mon, state)
    return ok and played and true or false
  end
  if type(mon.play) == "function" then
    local ok, played = pcall(mon.play, mon, state)
    return ok and played and true or false
  end
  return false
end

local function battlerHP(battler)
  if not battler then return nil end
  local mon = battler.mon
  local hp = type(mon) == "table" and tonumber(mon.hp) or nil
  if hp == nil then hp = tonumber(battler.hp) end
  return hp
end

local function barAtZero(battler)
  if not battler then return true end
  if battler.shownHP == nil then return true end
  return tonumber(battler.shownHP) and tonumber(battler.shownHP) <= 0 or false
end

local function battlerIsFainted(battler)
  if not battler then return false end
  if battler.fainted then return true end
  local hp = battlerHP(battler)
  return hp ~= nil and hp <= 0
end

function M.install()
  local okS, Stadium = pcall(V.require, "Stadium")
  local okM, StadiumMon = pcall(V.require, "StadiumMon")
  if not (okS and type(Stadium) == "table" and okM and type(StadiumMon) == "table") then
    return false, "Dramatic Shape Stadium modules unavailable"
  end
  if Stadium._stadiumOverworldStage1Installed then return true end

  -- IMPORTANT: newer Dramatic Shape builds already install the complete
  -- Stadium battle state machine themselves (per-move attack animation,
  -- entrance/grow and delayed faint).  Detect that BEFORE looking inside the
  -- Stadium session or wrapping BattleState. v0.1.18 did this check too late,
  -- so on those builds it double-wrapped startGrowIn/performMove and could
  -- crash exactly when the player's Pokemon was sent out.
  local okB, BattleState = pcall(require, "src.battle.BattleState")
  if not (okB and type(BattleState) == "table") then
    return false, "BattleState unavailable"
  end
  if BattleState.dramaticShapeStadiumHook then
    Stadium._stadiumOverworldStage1Installed = true
    Stadium._stadiumOverworldStage1Native = true
    safeLog("info", "Pokemon Stadium Stage 1: using Dramatic Shape native battle animation hooks")
    return true
  end

  -- Older builds may have Stadium models but no battle animation hooks. Only
  -- those builds receive the compatibility wrappers below.
  local getSession = installSessionGetter(Stadium)
  if not getSession then
    return false, "could not access live Dramatic Shape Stadium session"
  end

  local pendingFaint = setmetatable({}, { __mode = "k" })
  local lastHP = setmetatable({}, { __mode = "k" })

  -- Whole-body damage recoil.  Stadium's extracted model set does not expose a
  -- universal victim/flinch clip, so this is deliberately a transform motion,
  -- not a fake mapping to the generic ATTACK slot.
  if type(StadiumMon.matrix) == "function" and not StadiumMon._stage1RecoilMatrix then
    local innerMatrix = StadiumMon.matrix
    StadiumMon.matrix = function(self, x, groundY, z, faceX, faceZ, ...)
      local recoil = tonumber(self._stage1Recoil) or 0
      if recoil > 0 and faceX and faceZ then
        local len = math.sqrt(faceX * faceX + faceZ * faceZ)
        if len > 0.0001 then
          -- Move away from the opponent by at most ~1.2 world pixels.
          local push = math.sin(math.min(1, recoil) * math.pi) * 1.20
          x = x - (faceX / len) * push
          z = z - (faceZ / len) * push
        end
      end
      return innerMatrix(self, x, groundY, z, faceX, faceZ, ...)
    end
    StadiumMon._stage1RecoilMatrix = true
  end

  -- Let the installed Dramatic Shape performMove wrapper run first.  If it
  -- already selected an attack animation, mon.state will be "attack" and this
  -- becomes a no-op.  Otherwise we supply the exact move animation ourselves.
  if type(BattleState.performMove) == "function" and not BattleState._stadiumStage1Move then
    local innerMove = BattleState.performMove
    BattleState.performMove = function(self, user, target, moveInst, isCalled)
      local out = { innerMove(self, user, target, moveInst, isCalled) }
      local session = getSession()
      local side = sideOf(self, user)
      local mon = session and side and session[side]
      if mon and mon.rig and mon.state ~= "attack" and mon.state ~= "faint" then
        requestAttack(mon, moveIndex(self, moveInst))
      end
      return table.unpack(out)
    end
    BattleState._stadiumStage1Move = true
  end

  -- Entrance/send-out is intentionally NOT wrapped on legacy builds.
  -- The Stadium model may not exist yet when BattleState.startGrowIn fires,
  -- and forcing a request at that seam is what caused the v0.1.18 summon
  -- crash. Modern Dramatic Shape handles entrance natively; legacy builds
  -- safely keep their normal send-out rather than risking the battle.

  -- Record the faint, but do not collapse until the displayed HP bar has
  -- reached zero. This matches the visual moment the battle says the Pokemon
  -- is actually down instead of falling while its bar is still draining.
  if type(BattleState.onFaint) == "function" and not BattleState._stadiumStage1Faint then
    local innerFaint = BattleState.onFaint
    BattleState.onFaint = function(self, battler, ...)
      local session = getSession()
      local side = sideOf(self, battler)
      if session and side then pendingFaint[self] = pendingFaint[self] or {}; pendingFaint[self][side] = true end
      return innerFaint(self, battler, ...)
    end
    BattleState._stadiumStage1Faint = true
  end

  -- Stadium.update runs every staged battle frame.  It is a convenient,
  -- renderer-independent place to handle damage recoil and delayed fainting.
  if type(Stadium.update) == "function" and not Stadium._stage1UpdateWrapped then
    local innerUpdate = Stadium.update
    Stadium.update = function(dt, battle, groundY, ...)
      local out = { innerUpdate(dt, battle, groundY, ...) }
      local session = getSession()
      if session and battle then
        for _, side in ipairs({ "player", "enemy" }) do
          local battler = side == "player" and battle.player or battle.enemy
          local mon = session[side]
          local hp = battlerHP(battler)
          local prev = lastHP[battler]
          if hp ~= nil then
            if prev ~= nil and hp < prev and hp > 0 and mon and mon.rig then
              mon._stage1Recoil = 1
            end
            lastHP[battler] = hp
          end

          if mon and mon._stage1Recoil then
            local t = tonumber(mon._stage1Recoil) or 0
            -- Normalized countdown; around 0.18 s total at any framerate.
            t = t - (tonumber(dt) or 0) / 0.18
            if t <= 0 then t = nil end
            mon._stage1Recoil = t
          end

          local due = pendingFaint[battle] and pendingFaint[battle][side]
          if due then
            if not battlerIsFainted(battler) then
              pendingFaint[battle][side] = nil
            elseif barAtZero(battler) then
              pendingFaint[battle][side] = nil
              if mon and mon.rig and mon.state ~= "faint" then requestState(mon, "faint") end
            end
          end
        end
      end
      return table.unpack(out)
    end
    Stadium._stage1UpdateWrapped = true
  end

  Stadium._stadiumOverworldStage1Installed = true
  safeLog("info", "Pokemon Stadium Stage 1 battle animations installed")
  return true
end

return M
