-- Pokemon Stadium models for overworld Pokemon entities.
--
-- This module deliberately reuses Dramatic Shape's existing StadiumPack,
-- StadiumMon and StadiumRig pipeline.  It does not contain or redistribute
-- Pokemon Stadium models.  A model exists only after the user has imported a
-- compatible Stadium ROM through Dramatic Shape's own model builder.
--
-- Integration contract:
--   * VoxelScene captures the real entity beside each rendered pose.
--   * prepare(posed) resolves an exact species, advances one StadiumMon per
--     entity, skins it once, and stores the model matrix on the pose.
--   * draw(pose) is used by both the main cast and water reflection.
--   * cast(pose, ShadowMap) sends the same skinned geometry to the sun pass.
--
-- Companion mods can tag a spawned NPC without mutating engine internals:
--
--   local ds = mod.find("DRAMATIC_SHAPE")
--   local ow = ds and ds.exports and ds.exports.lib
--              and ds.exports.lib.require("OverworldStadium")
--   if ow then ow.tag(npc, "PIKACHU") end
--
-- Accepted tags are National Dex numbers (1..151) or engine species strings.
local V = ...

local StadiumMon = V.require("StadiumMon")
local StadiumPack = V.require("StadiumPack")
local Mat4 = V.require("Mat4")
local Config = V.require("OverworldStadiumConfig")
local PokemonHeights = V.require("PokemonHeights")
local PokemonLocomotion = V.require("PokemonLocomotion")

local OverworldStadium = {}

local tagged = setmetatable({}, { __mode = "k" })
-- Last confirmed Pokemon identity for an entity.  Flight/control mods can
-- temporarily replace or strip follower metadata while swapping sprites; keep
-- the Stadium identity stable across that visual transition.
local entityDexCache = setmetatable({}, { __mode = "k" })
local slots = setmetatable({}, { __mode = "k" })
local nameCache = {}
local spriteCache = {}
local frameNo = 0
local reported = {}
local basePackKeep = tonumber(StadiumPack.KEEP) or 4

local function logOnce(key, fmt, ...)
  if reported[key] then return end
  reported[key] = true
  local log = V.mod and V.mod.log
  if log and log.warn then
    pcall(log.warn, log, fmt, ...)
  end
end

local function gameObject()
  local ok, Game = pcall(require, "src.core.Game")
  if not ok or type(Game) ~= "table" then return nil end
  return Game
end

local function gameData()
  local Game = gameObject()
  return Game and Game.data or nil
end

local function cleanName(v)
  if type(v) ~= "string" then return nil end
  local s = v:upper()
  s = s:gsub("[^A-Z0-9]", "")
  return s ~= "" and s or nil
end

local function dexNumber(v)
  if type(v) == "number" then
    local n = math.floor(v)
    if n >= 1 and n <= 151 then return n end
  elseif type(v) == "string" then
    local n = tonumber(v)
    if n then return dexNumber(n) end
  end
  return nil
end

local function speciesDex(v)
  local n = dexNumber(v)
  if n then return n end
  if type(v) ~= "string" then return nil end

  local cacheKey = cleanName(v) or v
  local cached = nameCache[cacheKey]
  if cached ~= nil then return cached or nil end

  local data = gameData()
  local pokemon = data and data.pokemon
  if not pokemon then
    nameCache[cacheKey] = false
    return nil
  end

  -- Engine species are normally canonical string keys such as "PIKACHU".
  local direct = pokemon[v] or pokemon[v:upper()]
  if direct and direct.dex then
    local d = dexNumber(direct.dex)
    nameCache[cacheKey] = d or false
    return d
  end

  -- Be forgiving for tags written as "Mr. Mime", "Nidoran-F", etc.  This
  -- runs only on a cache miss and the Gen 1 table is tiny.
  for key, def in pairs(pokemon) do
    if cleanName(key) == cacheKey then
      local d = def and dexNumber(def.dex)
      nameCache[cacheKey] = d or false
      return d
    end
  end

  nameCache[cacheKey] = false
  return nil
end

local function firstDex(t, explicitOnly)
  if type(t) ~= "table" then return nil end
  if t.stadiumModel == false or t.pokemonModel == false then return false end

  local keys = {
    "stadiumDex", "pokemonDex", "pokedex", "dexNo", "dexNumber",
    "stadiumSpecies", "pokemonSpecies",
  }
  for _, key in ipairs(keys) do
    local d = speciesDex(t[key])
    if d then return d end
  end

  -- A nested Pokemon/battler record is unambiguous enough to accept normal
  -- `dex` / `species` field names.  At the top entity level, a generic
  -- `species` is also useful for follower/roaming mods; it is accepted only
  -- when it resolves to an actual Gen 1 Pokemon key.
  local nested = t.pokemon or t.mon or t.battler
  if type(nested) == "table" then
    local d = speciesDex(nested.pokemonDex or nested.dex or nested.species)
    if d then return d end
  elseif nested ~= nil then
    local d = speciesDex(nested)
    if d then return d end
  end

  if not explicitOnly then
    local d = speciesDex(t.species)
    if d then return d end
  end
  return nil
end

local function entityName(entity)
  if type(entity) ~= "table" then return nil end
  -- Prefer authored object names over the runtime-generated map_obj_N id.
  -- Yellow's follower, for example, is authored as PIKACHU_FOLLOWER.
  return entity.name or entity.objectName
      or (type(entity.def) == "table" and (entity.def.name or entity.def.id))
      or entity.id
end

-- Gen1Recomp Yellow creates the behind-the-player companion as an ordinary
-- NPC with def.name = PIKACHU_FOLLOWER and def.sprite = SPRITE_PIKACHU.
-- We keep that NPC for its movement/pathing, but render the CURRENT first
-- party Pokemon in its place. Reordering the party therefore changes the
-- follower immediately without touching Yellow's follower controller.
local function builtInFollowerDex(entity)
  if not Config.firstPartyFollower or type(entity) ~= "table" then return nil end
  local def = type(entity.def) == "table" and entity.def or nil
  if not def then return nil end

  local name = cleanName(def.name or entity.name or entity.objectName)

  -- Followers EX may reuse the stock Yellow follower entity but retarget its
  -- visual species explicitly. Respect that identity before our vanilla
  -- "party slot #1" behavior so the two mods do not fight over what model is
  -- supposed to be trailing the player.
  local followersExSpecies = speciesDex(entity._pokepcFollowerSpecies
      or entity.pokepcFollowerSpecies
      or (type(entity.pokepcMon) == "table" and entity.pokepcMon.species))
  if followersExSpecies then return followersExSpecies end

  -- The engine marks the real trailing entity with pikachuFollower=true.
  -- Fall back to its unique authored name for compatible older builds.
  -- Do NOT key only on SPRITE_PIKACHU: ordinary map Pikachu NPCs may share
  -- that sheet and must keep rendering as Pikachu rather than the party lead.
  if entity.pikachuFollower ~= true and name ~= "PIKACHUFOLLOWER" then
    return nil
  end

  local Game = gameObject()
  local save = Game and Game.save
  local party = save and save.party
  local lead = type(party) == "table" and party[1] or nil
  if type(lead) == "table" then
    -- Normal gen1recomp party mons use `species`; accept a few aliases so
    -- total-conversion / companion mods can use the same follower path.
    return speciesDex(lead.species or lead.pokemonSpecies
                      or lead.stadiumSpecies or lead.pokemonDex or lead.dex)
  end
  return speciesDex(lead)
end

-- Wilds of Kanto has several Pokemon entity families that do not all use the
-- same metadata shape. Normal encounter bodies expose `species`, peaceful
-- town/ambient NPCs expose `ambientSpecies`, and follower entities expose
-- `_wildsFollowerSpecies`. Resolve those explicit Pokemon-only fields before
-- falling back to generic NPC/sprite metadata so two instances of the same
-- species cannot split between 3D and 2D merely because they came from
-- different Wilds subsystems.
local function externalPokemonDex(entity)
  if type(entity) ~= "table" then return nil end

  -- These field names are Pokemon-specific and therefore safe even on a
  -- normal NPC table. Some are used by Wilds today; the aliases keep this
  -- bridge friendly with other roaming/follower mods using the same idea.
  local pokemonSpecific = {
    "ambientSpecies",
    "_wildsFollowerSpecies",
    -- Followers EX / PokePC controller identities.
    "_pokepcControlSpecies",
    "_pokepcFollowerSpecies",
    "pokepcFollowerSpecies",
    "dramaticSkyRideMountSpecies",
    "skyRideMountSpecies",
    "_stadiumSkyRideSpecies",
    "followerSpecies",
    "wildSpecies",
    "spawnSpecies",
    "encounterSpecies",
    "stadiumSpecies",
    "pokemonSpecies",
    "stadiumDex",
    "pokemonDex",
    "enhancedDexId",
  }
  for _, key in ipairs(pokemonSpecific) do
    local d = speciesDex(entity[key])
    if d then return d end
  end

  -- Followers EX pack trailers carry the actual party Pokemon object here.
  -- Trainer trailers intentionally have no pokepcMon and therefore remain
  -- normal 2D/voxel trainer sprites.
  if type(entity.pokepcMon) == "table" then
    local d = speciesDex(entity.pokepcMon.species
        or entity.pokepcMon.pokemonSpecies
        or entity.pokepcMon.dex)
    if d then return d end
  end

  -- Wilds ambient entities also use the authored name AMBIENT_<SPECIES>.
  -- This is a useful last-resort identity if another sprite provider has
  -- stripped the species field from the renderer/entity during a refresh.
  if entity.wildsAmbientPokemon == true then
    local raw = entity.name or entity.objectName
      or (type(entity.def) == "table" and entity.def.name)
    if type(raw) == "string" then
      local species = raw:upper():match("^AMBIENT[_%- ]+(.+)$")
      local d = species and speciesDex(species)
      if d then return d end
    end
  end

  return nil
end

local function knownPokemonEntity(entity)
  if type(entity) ~= "table" then return false end
  if entity.overworldWildSpawn == true
      or entity.wildsAmbientPokemon == true
      or entity.wildsFollower == true
      or entity.pokepcTrailer == true
      or entity._pokepcAsPokemon == true
      or entity._pokepcControlSpecies ~= nil
      or entity._pokepcFollowerSpecies ~= nil
      or entity.dramaticSkyRideMountSpecies ~= nil
      or entity.skyRideMountSpecies ~= nil
      or entity._stadiumSkyRideSpecies ~= nil
      or entity.pikachuFollower == true
      or entity.isPokemonFollower == true then
    return true
  end
  return externalPokemonDex(entity) ~= nil
end

local function overrideDex(p)
  local all = Config.overrides
  if type(all) ~= "table" then return nil end
  local map = all[p.mapId]
  if type(map) ~= "table" then return nil end
  local v = p.entityIndex and map[p.entityIndex] or nil
  if v == nil then
    local name = entityName(p.entity)
    if name ~= nil then v = map[name] end
  end
  return speciesDex(v)
end

local function spriteDex(sprite)
  if not (Config.autoSpriteSpecies and sprite and sprite.def) then return nil end
  local def = sprite.def

  -- Dramatic Sky Ride tags its generated mount sprite definition with the
  -- exact species and also names it SKY_RIDE_<SPECIES>. Treat either form as
  -- authoritative Pokemon identity so the flying mount can stay a Stadium
  -- model instead of falling back to the generated 2D follower sheet.
  local skyRideSpecies = speciesDex(def.dramaticSkyRideMountSpecies
      or def.skyRideMountSpecies)
  if skyRideSpecies then return skyRideSpecies end
  if type(def.id) == "string" then
    local skyName = def.id:upper():match("^SKY_RIDE[_%-](.+)$")
    local skyDex = skyName and speciesDex(skyName)
    if skyDex then return skyDex end
  end

  local explicit = firstDex(def, false)
  if explicit == false then return nil end
  if explicit then return explicit end

  local image = def.image
  if type(image) ~= "string" then return nil end
  if spriteCache[image] ~= nil then return spriteCache[image] or nil end

  -- Only infer from a species-specific basename.  This intentionally refuses
  -- generic sheets such as MONSTER/BIRD/BUG instead of inventing a Pokemon.
  local base = image:gsub("\\", "/"):match("([^/]+)$") or image
  base = base:gsub("%.[^%.]+$", "")
  base = base:gsub("^[Ss][Pp][Rr][Ii][Tt][Ee][_-]", "")
  -- Followers EX / PokePC sheets use follower_<SPECIES>.png.  Several flight
  -- mods temporarily leave only this sprite identity on the entity, so accept
  -- it as an explicit species-specific filename instead of falling back to 2D.
  base = base:gsub("^[Ff][Oo][Ll][Ll][Oo][Ww][Ee][Rr][_-]", "")
  base = base:gsub("^[Pp][Oo][Kk][Ee][Pp][Cc][_-]", "")
  local d = speciesDex(base)
  spriteCache[image] = d or false
  return d
end

local function resolveDex(p)
  local entity = p.entity
  local function remember(d)
    if d and type(entity) == "table" then entityDexCache[entity] = d end
    return d
  end
  -- Respect an explicit opt-out before any external compatibility aliases.
  if type(entity) == "table"
      and (entity.stadiumModel == false or entity.pokemonModel == false) then
    return nil
  end
  if entity and tagged[entity] ~= nil then
    local v = tagged[entity]
    if v == false then return nil end
    return remember(speciesDex(v))
  end

  -- Yellow's official trailing Pikachu is a special engine-created NPC, not
  -- a map object with Pokemon species metadata. Keep its pathing/visibility,
  -- but resolve its rendered species from party slot #1 every frame.
  local follower = builtInFollowerDex(entity)
  if follower then return remember(follower) end

  -- Resolve alternate roaming/follower metadata before map overrides and
  -- sprite filenames. This is what catches Wilds ambient Pokemon and its
  -- extra follower entities, which are not marked as normal wild spawns.
  local external = externalPokemonDex(entity)
  if external then return remember(external) end

  local d = overrideDex(p)
  if d then return remember(d) end

  if type(entity) == "table" then
    local top = firstDex(entity, false)
    if top == false then return nil end
    if top then return remember(top) end

    for _, key in ipairs({ "def", "obj", "object", "objDef", "data", "event" }) do
      local sub = entity[key]
      local got = firstDex(sub, true)
      if got == false then return nil end
      if got then return remember(got) end
    end
  end

  local fromSprite = spriteDex(p.sprite)
  if fromSprite then return remember(fromSprite) end

  -- Some flying/control mods replace the entity's normal Pokemon metadata for
  -- a few frames while keeping the same entity object.  Reuse the last species
  -- we positively identified rather than letting that transition turn the model
  -- back into a billboard.
  if type(entity) == "table" and entityDexCache[entity] then
    return entityDexCache[entity]
  end
  return nil
end

local function facingVector(facing)
  if facing == "up" then return 0, -1 end
  if facing == "left" then return -1, 0 end
  if facing == "right" then return 1, 0 end
  return 0, 1 -- down, nil, and unknown values use Stadium's native +Z
end

local function dtForFrame()
  local dt = 1 / 60
  if love and love.timer and love.timer.getDelta then
    local ok, got = pcall(love.timer.getDelta)
    if ok and type(got) == "number" and got >= 0 then dt = got end
  end
  -- A debugger pause should not fling animation anchors across the map.
  if dt > 0.10 then dt = 0.10 end
  return dt
end


-- Convert a canonical Pokedex height into this overworld's world-pixel scale.
-- StadiumMon:worldHeight() is intentionally battle-compressed (roughly 5..18
-- world px), so we leave StadiumMon itself untouched and apply a per-entity
-- scale multiplier here. This keeps Dramatic Shape battle sizing unchanged.
local function pokedexWorldHeight(dex)
  if not Config.pokedexScale then return nil end
  local meters = PokemonHeights and PokemonHeights.meters
                 and PokemonHeights.meters(dex) or nil
  if not (meters and meters > 0) then return nil end

  local humanMeters = tonumber(Config.humanReferenceMeters) or 1.60
  local humanWorld = tonumber(Config.humanReferenceWorldHeight) or 24
  if humanMeters <= 0 then humanMeters = 1.60 end
  if humanWorld <= 0 then humanWorld = 24 end

  local target = meters * (humanWorld / humanMeters)
  target = target * (tonumber(Config.pokedexScaleMultiplier) or 1)

  local overrides = Config.heightOverrides
  if type(overrides) == "table" then
    local mul = tonumber(overrides[dex])
    if mul and mul > 0 then target = target * mul end
  end

  local minH = tonumber(Config.minPokemonWorldHeight)
  local maxH = tonumber(Config.maxPokemonWorldHeight)
  if minH and minH > 0 and target < minH then target = minH end
  if maxH and maxH > 0 and target > maxH then target = maxH end
  return target, meters
end

local function scaleForDex(mon, dex)
  local base = mon and mon.worldHeight and mon:worldHeight() or nil

  -- Keep the restored pre-v0.1.6 Dramatic Shape sizing, but do not let very
  -- small Stadium models vanish completely inside Gen 1 tall grass. This is
  -- deliberately a ONE-WAY floor: medium/large Pokemon are never shrunk or
  -- enlarged by it, while tiny/low-profile species are brought up to a
  -- readable minimum visual height.
  if not Config.pokedexScale then
    if not (base and base > 0) then return 1, nil, nil end
    local floor = tonumber(Config.smallPokemonMinWorldHeight)
    local overrides = Config.smallPokemonMinHeightOverrides
    if type(overrides) == "table" then
      local speciesFloor = tonumber(overrides[dex])
      if speciesFloor and speciesFloor > 0 then floor = speciesFloor end
    end
    local scale = 1
    local target = base

    if floor and floor > 0 and target < floor then
      scale = floor / base
      target = floor
    end

    -- v0.1.39: give selected naturally large species more visual presence.
    -- Apply this after the small-species floor so the two systems never fight.
    local large = Config.largePokemonScaleOverrides
    if type(large) == "table" then
      local mul = tonumber(large[dex])
      if mul and mul > 1 then
        scale = scale * mul
        target = target * mul
      end
    end

    return scale, target, nil
  end

  local target, meters = pokedexWorldHeight(dex)
  if not target then return 1, base, nil end
  if not (base and base > 0) then return 1, target, meters end
  return target / base, target, meters
end

local TWO_PI = math.pi * 2

local function safeSlotAnim(mon, name)
  if not (mon and type(mon.slotAnim) == "function") then return nil end
  local ok, index = pcall(mon.slotAnim, mon, name)
  if ok and type(index) == "number" then return index end
  return nil
end

local function startWalkClip(slot, mon)
  if slot.walkClip then return end
  -- `idle_alt` is the second Stadium standby loop and is the safest source
  -- skeletal motion for overworld locomotion. Some species do not have one;
  -- those use their ordinary idle plus the distance-driven footfall motion.
  local index = safeSlotAnim(mon, "idle_alt") or safeSlotAnim(mon, "idle")
  if index then
    local ok = pcall(mon.play, mon, "idle", index)
    if ok then
      slot.walkClip = true
      slot.walkAnim = index
    end
  end
end

local function stopWalkClip(slot, mon)
  if not slot.walkClip then return end
  pcall(mon.play, mon, "idle")
  slot.walkClip = false
  slot.walkAnim = nil
end

-- Advance a gait from ACTUAL distance travelled instead of wall-clock time.
-- That keeps the feet locked to the overworld: a Pokemon that pauses freezes
-- its step instead of moonwalking, and a faster movement mod naturally makes
-- the gait advance faster. The returned bob/pitch are applied to the model
-- matrix after the Stadium skeleton is posed.
local function locomotionFor(slot, p, dex, targetHeight, dt, mon)
  local x, z = tonumber(p.px) or 0, tonumber(p.py) or 0
  local eligible = Config.walkingAnimations ~= false
      and PokemonLocomotion
      and PokemonLocomotion.isGroundedBiped(dex, Config.walkSpeciesOverrides)

  if slot.walkDex ~= dex then
    stopWalkClip(slot, mon)
    slot.walkDex = dex
    slot.walkX, slot.walkZ = x, z
    slot.walkPhase = 0
    slot.walkBlend = 0
  end

  local dx, dz, dist = 0, 0, 0
  if slot.walkX ~= nil and slot.walkZ ~= nil then
    dx, dz = x - slot.walkX, z - slot.walkZ
    dist = math.sqrt(dx * dx + dz * dz)
  end
  slot.walkX, slot.walkZ = x, z

  if not eligible then
    stopWalkClip(slot, mon)
    slot.walkBlend = 0
    return 0, 0, false
  end

  -- A seam/warp can move an entity dozens of pixels in one frame. That is a
  -- teleport, not a forty-step sprint, so do not feed it into the gait clock.
  local moving = dist > 0.01 and dist <= 8
  local blend = tonumber(slot.walkBlend) or 0
  local target = moving and 1 or 0
  local rate = moving and 12 or 7
  local k = math.min(1, math.max(0, (dt or 0) * rate))
  blend = blend + (target - blend) * k
  if blend < 0.001 then blend = 0 end
  slot.walkBlend = blend

  if moving then
    local cycle = PokemonLocomotion.cycleDistance(
      targetHeight, dex, Config.walkCadenceMultiplier)
    if not (cycle and cycle > 0) then cycle = 18 end
    slot.walkPhase = ((tonumber(slot.walkPhase) or 0)
                     + dist / cycle * TWO_PI) % TWO_PI
    startWalkClip(slot, mon)
  elseif blend <= 0.06 then
    stopWalkClip(slot, mon)
  end

  local active = slot.walkClip and blend > 0
  if active and mon and mon.model and mon.anim then
    -- Stadium's standby clips have their own intro/loopStart. Map our gait
    -- phase onto the actual looping portion so every foot cycle closes cleanly.
    local anim = mon.model.anims and mon.model.anims[mon.anim]
    if anim and anim.frames and anim.frames > 0 then
      local first = tonumber(anim.loopStart) or 0
      if first < 0 or first >= anim.frames then first = 0 end
      local span = math.max(1, anim.frames - first)
      local frac = (tonumber(slot.walkPhase) or 0) / TWO_PI
      local fps = tonumber(StadiumMon.FPS) or tonumber(StadiumPack.FPS) or 30
      mon.time = (first + frac * span) / fps
    end
  end

  if not active then return 0, 0, false end
  local phase = tonumber(slot.walkPhase) or 0
  local bob = math.abs(math.sin(phase))
      * PokemonLocomotion.bobAmount(targetHeight, dex, Config.walkBobMultiplier)
      * blend
  local pitch = math.sin(phase)
      * PokemonLocomotion.pitchAmount(dex, Config.walkPitchMultiplier)
      * blend
  return bob, pitch, true
end

local function releaseSlot(slot)
  if slot and slot.mon then pcall(slot.mon.release, slot.mon) end
end

function OverworldStadium.tag(entity, speciesOrDex)
  if type(entity) ~= "table" then return false end
  if speciesOrDex == nil then
    tagged[entity] = nil
    return true
  end
  if speciesOrDex == false then
    tagged[entity] = false
    return true
  end
  if not speciesDex(speciesOrDex) then return false end
  tagged[entity] = speciesOrDex
  return true
end

function OverworldStadium.untag(entity)
  if type(entity) ~= "table" then return false end
  tagged[entity] = nil
  return true
end

function OverworldStadium.dexFor(pose)
  return resolveDex(pose or {})
end

-- True when this entity has enough information to be rendered directly from
-- the user's Stadium pack.  In particular this does NOT require a healthy 2D
-- SpriteRenderer, which is what lets us rescue Wilds of Kanto entities that
-- its billboard adapter has put on the emergency overlay path.
function OverworldStadium.canRenderEntity(entity)
  if type(entity) ~= "table" then return false end
  local dex = resolveDex({ entity = entity, sprite = entity.sprite,
                           mapId = entity.mapId })
  if not dex then return false end
  local ok, available = pcall(StadiumPack.available, dex)
  return ok and available == true, dex
end

local function wildBodyVisible(entity)
  if type(entity) ~= "table" then return false end
  if entity.hiddenEncounter or entity.visibleSprite == false
      or entity.hiddenBody == true or entity.state == "removed" then
    return false
  end
  -- Mirror Wilds' SpawnFx.bodyVisible gate closely enough that claiming its
  -- body does not make a Pokemon appear during the hidden part of spawn FX.
  local fx = entity.spawnFx
  if type(fx) == "table" and not fx.done and not fx.bodyShown then
    return false
  end
  return true
end

function OverworldStadium.claimWildEntity(entity)
  if type(entity) ~= "table" or entity.overworldWildSpawn ~= true then
    return false
  end
  if not wildBodyVisible(entity) then
    entity._stadiumOverworldWildClaim = nil
    return false
  end
  local ok, dex = OverworldStadium.canRenderEntity(entity)
  if not ok then
    entity._stadiumOverworldWildClaim = nil
    return false
  end

  -- Wilds' emergency overlay and Dramatic Shape filter key off this renderer
  -- string.  Claim the Pokemon for the depth-rendered world pass instead; its
  -- Entity:draw() then also knows not to paint a second 2D body later.
  entity._stadiumOverworldWildClaim = dex
  entity.worldRenderer = "DRAMATIC_SHAPE"
  entity.pokemonRenderer = "NATIVE_SPRITE_RENDERER"
  entity.dramaticBillboardSkipped = false
  entity.voxelDisabled = false
  entity.voxelRegistered = true
  entity.voxelUpdateOk = true
  entity.render2DFallback = false
  return true, dex
end

function OverworldStadium.claimWilds(state)
  for _, entity in ipairs((state and state.entities) or {}) do
    if entity and entity.overworldWildSpawn == true then
      OverworldStadium.claimWildEntity(entity)
    end
  end
end

function OverworldStadium.isClaimedWild(entity)
  return type(entity) == "table" and entity._stadiumOverworldWildClaim ~= nil
end

-- Pose rescue is intentionally broader than `isClaimedWild`. Wilds ambient
-- Pokemon and follower entities are ordinary NPCs (`overworldWildSpawn=false`)
-- but can still lose their native SpriteRenderer during provider refreshes.
-- If the entity is positively identified as a Pokemon AND its Stadium model
-- exists, world position/facing are sufficient for the 3D renderer.
function OverworldStadium.canRescuePose(entity)
  if not knownPokemonEntity(entity) then return false end
  -- Do not resurrect hidden encounter bodies or the concealed phase of Wilds'
  -- spawn effect just because their 2D pose intentionally returns nil.
  if not wildBodyVisible(entity) then return false end
  local ok = OverworldStadium.canRenderEntity(entity)
  return ok == true
end

local function prepareOne(p, dex, dt)
  if not (p and p.entity and dex) then return false end

  local slot = slots[p.entity]
  if not slot then
    local okNew, mon = pcall(StadiumMon.new, "overworld")
    if not okNew or not mon then return false end
    slot = { mon = mon, lastSeen = frameNo }
    slots[p.entity] = slot
  end
  slot.lastSeen = frameNo
  local mon = slot.mon

  local okSpecies, ready = pcall(mon.setSpecies, mon, dex)
  if not okSpecies or not ready or not mon.rig then return false end

  -- keep() and KEEP appeared as the battle cache evolved.  Use them when
  -- present but never make an older/newer cache implementation a reason for
  -- the visible overworld model to disappear.
  if type(StadiumPack.keep) == "function" then pcall(StadiumPack.keep, dex) end

  local okScale, speciesScale, targetHeight, heightMeters =
    pcall(scaleForDex, mon, dex)
  if not okScale then
    speciesScale, targetHeight, heightMeters = 1, nil, nil
  end
  mon.scale = speciesScale or 1
  p.stadiumTargetHeight = targetHeight
  p.stadiumHeightMeters = heightMeters

  pcall(mon.update, mon, dt)
  local walkBob, walkPitch, walking = 0, 0, false
  local okWalk, wb, wp, wk = pcall(locomotionFor, slot, p, dex,
    targetHeight or (type(mon.worldHeight) == "function" and mon:worldHeight()) or 14,
    dt, mon)
  if okWalk then walkBob, walkPitch, walking = wb or 0, wp or 0, wk and true or false end

  local entity = type(p.entity) == "table" and p.entity or nil
  local skyMount = entity and entity._stadiumSkyRideMount == true

  -- Ordinary overworld Pokemon use their own pose/facing.  A Sky Ride mount is
  -- different: the Followers EX NPC is only the Pokemon ID / lifecycle owner.
  -- Its trail coordinates must NOT decide where the ridden model appears.
  -- Anchor the rendered Stadium body directly to the live rider position that
  -- main.lua publishes after Sky Ride and Followers EX finish updating.
  local renderFacing = (skyMount and entity._stadiumSkyRideAnchorFacing)
      or p.facing
  local fx, fz = facingVector(renderFacing)
  local x = ((skyMount and tonumber(entity._stadiumSkyRideAnchorPx))
      or (p.px or 0)) + 8
  local z = ((skyMount and tonumber(entity._stadiumSkyRideAnchorPy))
      or (p.py or 0)) + 8
  local y = (p.gh or 0) + (p.lift or 0) + (walkBob or 0)

  if skyMount then
    -- StadiumMon documents the same facing convention as the map: +Z is
    -- SOUTH / "down".  Older compatibility builds flipped the model 180
    -- degrees, which is why Charizard faced backwards.  No flip is needed.
    --
    -- Sky Ride exposes both absolute altitude and relative lift.  Use the
    -- mount's render-only ground/altitude rather than the follower NPC's own
    -- grounded pose.  Then lower the Pokemon's feet by a fraction of its
    -- visual height so the trainer sits on the upper back instead of at the
    -- Pokemon's feet.  This is purely a render transform; Followers EX's NPC
    -- remains untouched for landing and normal following.
    local lift = tonumber(entity._stadiumSkyRideLift) or 0
    local ground = tonumber(entity._stadiumSkyRideGround)
    if ground == nil then
      local absolute = tonumber(entity._stadiumSkyRideAltitude)
      ground = absolute and (absolute - lift) or (p.gh or 0)
    end

    local h = tonumber(targetHeight)
      or (type(mon.worldHeight) == "function" and mon:worldHeight()) or 14
    -- Approximate the saddle/back point.  Larger winged mounts need the rider
    -- near the upper half of the body, not at the model origin/feet.
    local seatFraction = 0.52
    if dex == 6 then seatFraction = 0.50       -- Charizard
    elseif dex == 18 then seatFraction = 0.58 -- Pidgeot
    elseif dex == 22 then seatFraction = 0.58 -- Fearow
    elseif dex == 42 then seatFraction = 0.50 -- Golbat
    elseif dex == 142 then seatFraction = 0.50 -- Aerodactyl
    elseif dex == 144 or dex == 145 or dex == 146 then seatFraction = 0.56
    elseif dex == 148 then seatFraction = 0.48 -- Dragonair
    elseif dex == 149 then seatFraction = 0.50 -- Dragonite
    end
    local riderFootLift = 7.0
    y = ground + lift + riderFootLift - h * seatFraction
  elseif entity and tonumber(entity._stadiumSkyRideLift) then
    -- Non-mount airborne party members keep their own X/Z trail position but
    -- follow the same vertical flight lift.
    y = y + tonumber(entity._stadiumSkyRideLift)
  end
  local okMatrix, matrix = pcall(mon.matrix, mon, x, y, z, fx, fz)
  if not okMatrix or not matrix then return false end

  if walking and walkPitch and walkPitch ~= 0 then
    local okPitch, pitched = pcall(function()
      return Mat4.mul(matrix, Mat4.rotateX(walkPitch))
    end)
    if okPitch and pitched then matrix = pitched end
  end
  mon.model_matrix = matrix

  local okBuild, didBuild = pcall(mon.build, mon)
  if not okBuild or not didBuild then return false end

  p.stadiumMon = mon
  p.stadiumMatrix = matrix
  p.stadiumDex = dex
  p.stadiumWalking = walking
  p.stadiumShadowTick = math.floor((tonumber(mon.time) or 0) * 12)
  return true
end


local function isPokemonPlayerPose(p, dex)
  if not (p and p.isPlayer) then return false end
  local e = p.entity
  if type(e) == "table" and (e._pokepcAsPokemon == true
      or e._pokepcControlSpecies ~= nil or e.pokepcControlSpecies ~= nil) then
    return dex ~= nil or externalPokemonDex(e) ~= nil
  end
  -- Dramatic Sky Ride must never turn the PLAYER pose into the Stadium mount.
  -- The existing party follower entity is used as the mount instead. This
  -- prevents the rider from becoming a duplicate Charizard/Pokemon.
  return false
end

function OverworldStadium.shouldHidePose(p)
  local e = p and p.entity
  if type(e) ~= "table" or e.skyRideRider ~= true then return false end
  local m = V.mod and V.mod.find and V.mod:find("DRAMATIC_SKY_RIDE")
  local ex = m and m.exports
  if ex and type(ex.isFlying) == "function" then
    local ok, flying = pcall(ex.isFlying)
    return ok and flying == true
  end
  return false
end

function OverworldStadium.safeShouldHidePose(p)
  local ok, hide = pcall(OverworldStadium.shouldHidePose, p)
  return ok and hide == true
end

function OverworldStadium.prepare(posed)
  frameNo = frameNo + 1
  if not Config.enabled then return true end
  local dt = dtForFrame()

  local dexForPose = {}
  local liveDex, liveCount = {}, 0
  for i, p in ipairs(posed or {}) do
    -- Ordinary player/trainer rendering stays untouched. Followers EX can,
    -- however, turn the player entity itself into a Pokemon. In that mode its
    -- explicit _pokepcControlSpecies identity is safe to pass through Stadium.
    local okDex, dex = pcall(resolveDex, p)
    local playerPokemon = isPokemonPlayerPose(p, okDex and dex or nil)
    if (not p.isPlayer or playerPokemon) and p.entity then
      if okDex then dexForPose[i] = dex end
      if dex and not liveDex[dex] then
        local available = true
        if type(StadiumPack.available) == "function" then
          local okAvail, got = pcall(StadiumPack.available, dex)
          available = okAvail and got == true
        end
        if available then
          liveDex[dex] = true
          liveCount = liveCount + 1
        end
      end
    end
  end

  -- The stock Stadium battle cache is intentionally tiny.  Expanding it is
  -- useful in the overworld, but treat the field as optional compatibility
  -- metadata rather than an API contract.
  pcall(function()
    StadiumPack.KEEP = math.max(basePackKeep, liveCount + basePackKeep)
  end)

  for i, p in ipairs(posed or {}) do
    p.stadiumMon = nil
    p.stadiumMatrix = nil
    p.stadiumDex = nil
    p.stadiumShadowTick = nil
    p.stadiumTargetHeight = nil
    p.stadiumHeightMeters = nil
    p.stadiumWalking = nil

    local playerPokemon = isPokemonPlayerPose(p, dexForPose[i])
    if (not p.isPlayer or playerPokemon) and p.entity and dexForPose[i] then
      local dex = dexForPose[i]
      local ok, did = pcall(prepareOne, p, dex, dt)
      if not ok or not did then
        logOnce("prepare:" .. tostring(dex),
          "Stadium overworld model %d could not prepare this frame; using sprite", dex)
      end
    end
  end

  local stale = tonumber(Config.staleFrames) or 120
  for entity, slot in pairs(slots) do
    if frameNo - (slot.lastSeen or 0) > stale then
      pcall(releaseSlot, slot)
      slots[entity] = nil
    end
  end
  return true
end

-- Non-throwing entry points used by VoxelScenePatch.  The renderer itself is
-- never disabled globally because one species/model/provider had a bad frame.
function OverworldStadium.safePrepare(posed)
  local ok, result = pcall(OverworldStadium.prepare, posed)
  if not ok then
    logOnce("prepare-frame", "Stadium overworld prepare error: %s", tostring(result))
    return false
  end
  return result ~= false
end

function OverworldStadium.safeClaimWilds(state)
  local ok, result = pcall(OverworldStadium.claimWilds, state)
  if not ok then
    logOnce("claim-wilds", "Stadium Wilds claim error: %s", tostring(result))
    return false
  end
  return result ~= false
end

function OverworldStadium.draw(p)
  local mon = p and p.stadiumMon
  local matrix = p and p.stadiumMatrix
  if not (mon and mon.rig and matrix) then return false end
  local ok, result = pcall(mon.rig.draw, mon.rig, matrix, nil)
  if not ok then
    logOnce("draw:" .. tostring(p.stadiumDex),
      "Stadium overworld draw failed for dex %s; using sprite", tostring(p.stadiumDex))
    return false
  end
  return result ~= false
end

function OverworldStadium.safeDraw(p)
  local ok, result = pcall(OverworldStadium.draw, p)
  return ok and result == true
end

function OverworldStadium.cast(p, shadowMap)
  local mon = p and p.stadiumMon
  local matrix = p and p.stadiumMatrix
  if not (mon and mon.rig and matrix and shadowMap) then return false end
  local ok, result = pcall(mon.rig.caster, mon.rig, shadowMap, matrix)
  return ok and result ~= false
end

function OverworldStadium.safeCast(p, shadowMap)
  local ok, result = pcall(OverworldStadium.cast, p, shadowMap)
  return ok and result == true
end

function OverworldStadium.releaseAll()
  for entity, slot in pairs(slots) do
    releaseSlot(slot)
    slots[entity] = nil
  end
end

return OverworldStadium
