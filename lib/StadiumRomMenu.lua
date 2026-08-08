-- Pokemon Stadium ROM menu bridge
--
-- v0.1.14: primary UI is this mod's own Mod Manager -> Options screen.
-- Gen1Recomp's standard option schema has toggles/choices/numbers/text but no
-- native "action" row, so we register a supported placeholder choice and then
-- replace only that generated row with a file-picker activate callback.
-- The older general OPTIONS hook is retained solely as a compatibility fallback.
--
-- Preferred path: delegate to Dramatic Shape's own StadiumRomPick module when
-- it exists.  Android: always use gen1recomp's native document picker before any Dramatic Shape helper.  The
-- Android bridge delivers a chosen file as picked_rom.gb regardless of the
-- source extension. We validate the N64 byte-order magic, normalize the data
-- to z64 byte order when needed, then stage the exact path Dramatic Shape asks
-- for: baseroms/baserom.z64.
local V = ...
local M = {}

local PICKED_ROM = "picked_rom.gb"
local PENDING_FLAG = "stadium_overworld_picker_pending.flag"
local STAGE_DIR = "baseroms"
local STAGE_PATH = "baseroms/baserom.z64"

local function text(s, ...)
  local ok, Strings = pcall(require, "src.core.Strings")
  if ok and type(Strings) == "function" then
    local okText, value = pcall(Strings, s, ...)
    if okText then return value end
  end
  if select("#", ...) > 0 then
    local okFmt, value = pcall(string.format, s, ...)
    if okFmt then return value end
  end
  return s
end

local function picker()
  local ok, value = pcall(V.require, "StadiumRomPick")
  if ok and type(value) == "table" then return value end
  return nil
end

local function rawRow()
  local p = picker()
  if not p or type(p.row) ~= "function" then return nil end
  local ok, row = pcall(p.row)
  if not ok then ok, row = pcall(p.row, p) end
  if ok and type(row) == "table" then return row end
  return nil
end

local function safeRemove(path)
  if love and love.filesystem and love.filesystem.remove then
    pcall(love.filesystem.remove, path)
  end
end

local function setStatus(value)
  M._status = value
end

local function stagedPath()
  if not (love and love.filesystem and love.filesystem.getInfo) then return nil end
  if love.filesystem.getInfo(STAGE_PATH, "file") then return STAGE_PATH end
  return nil
end

local function stadiumReady()
  local ok, install = pcall(V.require, "StadiumInstall")
  if not ok or type(install) ~= "table" or type(install.ready) ~= "function" then
    return false
  end
  local okReady, ready = pcall(install.ready)
  if not okReady then okReady, ready = pcall(install.ready, install) end
  return okReady and ready == true
end

local function cleanupStagingIfReady()
  if not stadiumReady() then return false end
  -- Once StadiumInstall's completion marker says the 151-pack cache is
  -- current, Dramatic Shape reads models from dramatic_shape/stadium. The
  -- temporary 32 MB ROM copy is no longer needed and should not keep
  -- re-triggering startup/import probes.
  safeRemove(PENDING_FLAG)
  safeRemove(PICKED_ROM)
  safeRemove(STAGE_PATH)
  setStatus("READY")
  return true
end

local function n64Format(data)
  if type(data) ~= "string" or #data < 4 then return nil end
  local a, b, c, d = data:byte(1, 4)
  -- Standard N64 ROM byte orders:
  --   z64 / big endian : 80 37 12 40
  --   v64 / byteswapped: 37 80 40 12
  --   n64 / little endian: 40 12 37 80
  if a == 0x80 and b == 0x37 and c == 0x12 and d == 0x40 then return "z64" end
  if a == 0x37 and b == 0x80 and c == 0x40 and d == 0x12 then return "v64" end
  if a == 0x40 and b == 0x12 and c == 0x37 and d == 0x80 then return "n64" end
  return nil
end

local function normalizeToZ64(data, fmt)
  if fmt == "z64" then return data end
  local out = {}
  local chunk = 8192
  if fmt == "v64" then
    -- Byte-swapped N64 images: swap each 16-bit pair.
    for base = 1, #data, chunk do
      local last = math.min(#data, base + chunk - 1)
      if ((last - base + 1) % 2) ~= 0 then last = last - 1 end
      local part = {}
      for i = base, last, 2 do
        part[#part + 1] = string.char(data:byte(i + 1), data:byte(i))
      end
      out[#out + 1] = table.concat(part)
    end
    return table.concat(out)
  elseif fmt == "n64" then
    -- Little-endian N64 images: reverse each 32-bit word.
    for base = 1, #data, chunk do
      local last = math.min(#data, base + chunk - 1)
      last = last - ((last - base + 1) % 4)
      local part = {}
      for i = base, last, 4 do
        part[#part + 1] = string.char(
          data:byte(i + 3), data:byte(i + 2), data:byte(i + 1), data:byte(i))
      end
      out[#out + 1] = table.concat(part)
    end
    return table.concat(out)
  end
  return nil
end

local function notifyDramaticShape(game)
  local p = picker()
  if p and type(p.poll) == "function" then
    local ok = pcall(p.poll, game)
    if not ok then pcall(p.poll, p, game) end
  end
end

local function consumeAndroidPick(game)
  if not (love and love.filesystem and love.filesystem.getInfo
      and love.filesystem.read and love.filesystem.write) then
    return false
  end
  if not love.filesystem.getInfo(PENDING_FLAG, "file") then return false end
  if not love.filesystem.getInfo(PICKED_ROM, "file") then return false end

  local data, err = love.filesystem.read(PICKED_ROM)
  if type(data) ~= "string" then
    safeRemove(PENDING_FLAG)
    safeRemove(PICKED_ROM)
    setStatus("READ ERROR")
    return true, err
  end

  local ext = n64Format(data)
  if not ext then
    safeRemove(PENDING_FLAG)
    safeRemove(PICKED_ROM)
    setStatus("NOT N64")
    return true, "selected file is not an N64 ROM image"
  end

  if love.filesystem.createDirectory then
    local ok = love.filesystem.createDirectory(STAGE_DIR)
    if ok == false then
      safeRemove(PENDING_FLAG)
      setStatus("WRITE ERROR")
      return true, "could not create " .. STAGE_DIR
    end
  end

  -- Dramatic Shape's Android helper specifically scans baseroms/baserom.z64.
  -- Normalize .v64/.n64 byte orders so every Android picker selection lands at
  -- that exact canonical path without asking the player to rename/copy it.
  local normalized = normalizeToZ64(data, ext)
  if type(normalized) ~= "string" then
    safeRemove(PENDING_FLAG)
    safeRemove(PICKED_ROM)
    setStatus("CONVERT ERROR")
    return true, "could not normalize selected N64 ROM"
  end

  safeRemove(STAGE_PATH)
  local okWrite, writeErr = love.filesystem.write(STAGE_PATH, normalized)
  if okWrite == false or okWrite == nil then
    safeRemove(PENDING_FLAG)
    setStatus("WRITE ERROR")
    return true, writeErr
  end

  -- The SAF copy is temporary. The original ROM stays wherever the user picked
  -- it (Downloads, SD card, Drive, etc.). Only the importer-facing staging copy
  -- is kept in the game's private save area.
  safeRemove(PICKED_ROM)
  safeRemove(PENDING_FLAG)
  pcall(love.filesystem.write, "stadium_overworld_rom_path.txt", STAGE_PATH)
  -- Dramatic Shape's own StadiumInstall starts when the overworld boots.
  -- Do not poke its legacy picker state here; on Android the clean path is:
  -- choose -> restart/boot -> StadiumInstall imports -> READY marker.
  setStatus("RESTART")
  return true, STAGE_PATH
end

function M.poll(game)
  if cleanupStagingIfReady() then return true end

  -- Consume OUR Android SAF result before any Dramatic Shape legacy picker.
  -- On Android we deliberately do not call StadiumRomPick.poll(): the ROM
  -- staging file is enough for StadiumInstall on the next overworld boot and
  -- avoids legacy picker/import state interfering with the voxel pipeline.
  local consumed = consumeAndroidPick(game)
  local osName = love and love.system and love.system.getOS and love.system.getOS() or nil
  if osName ~= "Android" and not consumed then notifyDramaticShape(game) end
  return consumed and true or false
end

local function invokeRow(row, game)
  if type(row) ~= "table" then return false end
  if type(row.activate) == "function" then
    local ok = pcall(row.activate, game)
    if not ok then ok = pcall(row.activate, row, game) end
    return ok
  end
  if type(row.step) == "function" then
    local ok = pcall(row.step, game, 1)
    if not ok then ok = pcall(row.step, row, game, 1) end
    return ok
  end
  return false
end

local function startAndroidPicker()
  if not (love and love.system and type(love.system.pickFile) == "function"
      and love.filesystem and type(love.filesystem.write) == "function") then
    setStatus("NO PICKER")
    return false
  end

  -- Mark ownership before opening Android's external Files/Documents activity.
  -- If Android kills and recreates the app while that activity is open, the
  -- flag survives and the next mod load can still consume picked_rom.gb.
  pcall(love.filesystem.write, PENDING_FLAG, "stadium\n")
  safeRemove(PICKED_ROM)
  setStatus("PICK...")

  -- Gen1Recomp currently recognizes rom/mod/sav kinds.  "rom" opens the
  -- general Android document picker and copies the chosen file to
  -- picked_rom.gb.  The original file may be .z64/.v64/.n64; our validator
  -- above identifies its actual byte order after the picker returns.
  local ok, launched = pcall(love.system.pickFile, "rom")
  if not ok or not launched then
    safeRemove(PENDING_FLAG)
    setStatus("NO PICKER")
    return false
  end
  return true
end

function M.choose(game)
  -- IMPORTANT: on Android, bypass Dramatic Shape's legacy row completely.
  -- Its action opens the in-game "PUT STADIUM US 1.0 HERE" instruction screen
  -- seen in older builds. Gen1Recomp's love.system.pickFile instead launches
  -- Android's real Storage Access Framework / Files app.
  local osName = love and love.system and love.system.getOS and love.system.getOS() or nil
  if osName == "Android" then
    if startAndroidPicker() then return true end
    setStatus("NO ANDROID PICKER")
    return false
  end

  -- Desktop/other-platform compatibility: use Dramatic Shape's own action when
  -- available because it owns the exact Stadium validation/build pipeline.
  local row = rawRow()
  if invokeRow(row, game) then return true end

  local p = picker()
  if p then
    for _, name in ipairs({ "choose", "pick", "open", "start", "request" }) do
      local fn = p[name]
      if type(fn) == "function" then
        local ok, result = pcall(fn, game)
        if not ok then ok, result = pcall(fn, p, game) end
        if ok and result ~= false then return true end
      end
    end
  end

  return startAndroidPicker()
end

local function labelString(row)
  if type(row) ~= "table" then return "" end
  local ok, s = pcall(tostring, row.label)
  return ok and (s or "") or ""
end

local function stadiumRowIndex(out, upstreamId)
  for i, row in ipairs(out) do
    if type(row) == "table" then
      if upstreamId ~= nil and row.id == upstreamId then return i end
      if row.id == "stadium_overworld:rom_file" then return i end
      local label = labelString(row):upper()
      if label:find("STADIUM", 1, true) and label:find("ROM", 1, true) then
        return i
      end
    end
  end
  return nil
end

local function insertionIndex(out)
  -- Put it immediately before MODS whenever possible so it is easy to find,
  -- even if an older OPTIONS menu does not group render-pipeline rows.
  for i, row in ipairs(out) do
    if type(row) == "table" and row.id == "mods" then return i end
  end
  return #out + 1
end

local function valueFromSource(source, game)
  if type(source) ~= "table" then return nil end
  local value = source.value
  if type(value) == "function" then
    local ok, result = pcall(value, game)
    if not ok then ok, result = pcall(value, source, game) end
    if ok and result ~= nil then return result end
  elseif value ~= nil then
    return value
  end
  return nil
end

local function makeRow(source)
  local out = {}
  if type(source) == "table" then
    for k, v in pairs(source) do out[k] = v end
  end

  out.id = (type(source) == "table" and source.id) or "stadium_overworld:rom_file"
  out.label = text("STADIUM ROM FILE")
  out.step = nil

  out.value = function(game)
    M.poll(game)
    if M._status then return text(M._status) end
    if stagedPath() then return text("RESTART") end
    local upstream = valueFromSource(source, game)
    if upstream ~= nil then return upstream end
    return text("CHOOSE")
  end

  out.activate = function(game)
    if type(source) == "table" then
      if invokeRow(source, game) then return true end
    end
    return M.choose(game)
  end
  return out
end

function M.ensureRow(rows, game)
  if type(rows) ~= "table" then return rows end
  M.poll(game)
  local source = rawRow()
  local row = makeRow(source)
  local at = stadiumRowIndex(rows, source and source.id or nil)
  if at then
    rows[at] = row
  else
    table.insert(rows, insertionIndex(rows), row)
  end
  return rows
end

function M.installOptionsHook(mod)
  if M._installed then return true end
  local installedAny = false

  -- Preferred modern extension point.
  if mod and mod.hooks and type(mod.hooks.wrap) == "function" then
    local ok = pcall(function()
      mod.hooks:wrap("ui.options.rows", function(next, game, rows)
        local out = next(game, rows)
        return M.ensureRow(out, game)
      end)
    end)
    installedAny = ok or installedAny
  end

  -- Compatibility fallback: some released Gen1Recomp builds predate (or do
  -- not dispatch) ui.options.rows.  Patch OptionsMenu.new itself as well.  On
  -- current builds this only sees that the hook already inserted our row and
  -- replaces it in-place, so there is never a duplicate.
  local okMenu, OptionsMenu = pcall(require, "src.ui.OptionsMenu")
  if okMenu and type(OptionsMenu) == "table" and type(OptionsMenu.new) == "function"
      and not OptionsMenu._stadiumOverworldRomMenuPatched then
    local originalNew = OptionsMenu.new
    OptionsMenu.new = function(game, opts)
      local menu = originalNew(game, opts)
      if type(menu) == "table" and type(menu.rows) == "table" then
        M.ensureRow(menu.rows, game)
      end
      return menu
    end
    OptionsMenu._stadiumOverworldRomMenuPatched = true
    installedAny = true
  end

  M._installed = installedAny
  return installedAny
end

-- Value shown beside STADIUM ROM FILE in the per-mod options screen.
function M.value(game)
  M.poll(game)
  if M._status then return text(M._status) end
  if stagedPath() then return text("RESTART") end
  local source = rawRow()
  local upstream = valueFromSource(source, game)
  if upstream ~= nil then return upstream end
  return text("CHOOSE")
end

-- Gen1Recomp exposes per-mod options from an options_schema, but its published
-- row types do not include a generic button/action.  Patch only the generated
-- row belonging to this mod so A/Confirm opens the ROM picker instead of merely
-- cycling a dummy choice.  No other mod's options are changed.
function M.installModManagerOptions(mod)
  if M._managerInstalled then return true end

  local okManager, ManagerState = pcall(require, "src.mods.ManagerState")
  if not okManager or type(ManagerState) ~= "table"
      or type(ManagerState.buildOptionRows) ~= "function" then
    return false
  end

  local modId = (mod and mod.id) or "STADIUM_OVERWORLD_MODELS"
  local originalBuild = ManagerState.buildOptionRows

  -- Avoid stacking wrappers if a loader hot-reloads this mod.
  if not ManagerState._stadiumOverworldRomOptionsPatched then
    ManagerState.buildOptionRows = function(self, m, schema)
      local rows = originalBuild(self, m, schema)
      if type(rows) ~= "table" or not m or m.id ~= modId then
        return rows
      end

      for _, row in ipairs(rows) do
        if type(row) == "table" and row.id == "stadiumRomFile" then
          row.label = text("STADIUM ROM FILE")
          row.value = function()
            return M.value(self.game)
          end
          row.activate = function()
            local ok = M.choose(self.game)
            if self.notify then
              self:notify(ok and "ROM PICKER OPENED" or "ROM PICKER UNAVAILABLE")
            end
            return ok
          end
          row.step = function()
            return row.activate()
          end
          break
        end
      end
      return rows
    end
    ManagerState._stadiumOverworldRomOptionsPatched = true
  end

  M._managerInstalled = true
  return true
end

function M.available()
  -- The picker is available even without Dramatic Shape's optional helper;
  -- Android native-pick fallback is handled by M.choose.
  return true
end

-- If Android recreated the process while the document picker was open, finish
-- staging immediately on load instead of waiting for OPTIONS to be reopened.
pcall(M.poll, nil)

return M
