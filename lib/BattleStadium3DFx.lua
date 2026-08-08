-- Pokemon Stadium Overworld Models - Phase 5 world-space battle effects
--
-- This module does NOT replace Dramatic Shape's battle renderer. It wraps the
-- public Stadium.begin/update/draw/finish methods and draws additional
-- procedural billboards through Dramatic Shape's own Voxel3D scene while the
-- Stadium models are being drawn. Effects therefore occupy real arena (x,y,z)
-- positions and move correctly when the battle camera orbits.
--
-- No Pokemon Stadium effect assets are included or extracted here. The shapes
-- are original procedural stand-ins built from LÖVE canvases.
local V = ...
local M = {}

local PI, TAU = math.pi, math.pi * 2
local clamp = function(x,a,b) if x<a then return a elseif x>b then return b end return x end
local function lerp(a,b,t) return a + (b-a)*t end

local Stadium = V.require("Stadium")
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")
local BattleBillboard = V.require("BattleBillboard")

local live = { arena=nil, battle=nil, groundY=0, ready=false }
local tex = {}
local installed = false

local function log(level, fmt, ...)
  local l = V and V.mod and V.mod.log
  local fn = l and l[level]
  if type(fn)=="function" then pcall(fn, l, fmt, ...) end
end

local function safeGraphics(fn)
  local g = love and love.graphics
  if not g then return false end
  local oldCanvas = g.getCanvas and g.getCanvas() or nil
  local ok, err = pcall(fn, g)
  if g.setCanvas then pcall(g.setCanvas, oldCanvas) end
  if g.setColor then pcall(g.setColor, 1,1,1,1) end
  if g.setBlendMode then pcall(g.setBlendMode, "alpha") end
  if not ok then log("warn", "Phase 5 texture build skipped: %s", tostring(err)) end
  return ok
end

local function makeCanvas(name, draw)
  if tex[name] then return tex[name] end
  local g = love and love.graphics
  if not (g and g.newCanvas) then return nil end
  safeGraphics(function(gfx)
    local c = gfx.newCanvas(32,32)
    if c.setFilter then c:setFilter("linear","linear") end
    gfx.setCanvas(c)
    gfx.clear(0,0,0,0)
    gfx.setBlendMode("alpha")
    draw(gfx)
    tex[name] = c
  end)
  return tex[name]
end

local function buildTextures()
  if live.ready then return true end
  makeCanvas("orb", function(g)
    for r=13,2,-1 do
      local q = r/13
      g.setColor(1.0, 0.72 + 0.25*(1-q), 0.18 + 0.70*(1-q), 0.055 + 0.075*(1-q))
      g.circle("fill",16,16,r)
    end
    g.setColor(1,1,1,0.95); g.circle("fill",16,16,4)
  end)
  makeCanvas("water", function(g)
    for r=13,2,-1 do
      local q=r/13
      g.setColor(0.16+0.45*(1-q),0.55+0.35*(1-q),1.0,0.05+0.08*(1-q))
      g.circle("fill",16,16,r)
    end
    g.setColor(0.84,0.96,1,0.9); g.ellipse("fill",12,11,4,2)
  end)
  makeCanvas("electric", function(g)
    g.setLineWidth(4); g.setColor(1,0.78,0.05,0.55)
    g.line(6,3,18,11,11,16,24,23,17,29)
    g.setLineWidth(1.5); g.setColor(1,1,0.80,1)
    g.line(6,3,18,11,11,16,24,23,17,29)
  end)
  makeCanvas("wind", function(g)
    -- Android/LuaJIT-safe wind streak. Avoid love.graphics.arc here because
    -- older LÖVE signatures differ and can leave tex.wind nil with no visible
    -- tornado. A hand-built polyline works on every renderer we target.
    local pts = {3,22, 6,17, 11,13, 17,11, 24,12, 29,16}
    g.setLineWidth(5); g.setColor(0.72,0.90,1.00,0.62)
    g.line(pts)
    g.setLineWidth(2); g.setColor(1,1,1,0.98)
    g.line(pts)
    g.setLineWidth(1); g.setColor(0.86,0.96,1.00,0.92)
    g.line(5,26,10,22,16,20,23,21,28,24)
  end)
  makeCanvas("ice", function(g)
    g.setColor(0.55,0.92,1,0.78); g.polygon("fill",16,1,23,15,16,31,9,15)
    g.setColor(1,1,1,0.9); g.polygon("fill",16,4,18,15,16,27,14,15)
  end)
  makeCanvas("psychic", function(g)
    g.setLineWidth(2)
    for r=13,4,-3 do
      g.setColor(0.92,0.28,1.0,0.22 + (13-r)*0.03)
      g.circle("line",16,16,r)
    end
    g.setColor(1,0.75,1,0.85); g.circle("fill",16,16,3)
  end)
  makeCanvas("poison", function(g)
    g.setColor(0.62,0.08,0.75,0.48); g.circle("fill",13,18,9); g.circle("fill",21,13,7)
    g.setColor(0.92,0.52,1,0.7); g.circle("line",13,18,9); g.circle("line",21,13,7)
  end)
  makeCanvas("ring", function(g)
    g.setLineWidth(3); g.setColor(1,1,1,0.82); g.circle("line",16,16,11)
    g.setLineWidth(1); g.setColor(1,0.78,0.25,0.72); g.circle("line",16,16,14)
  end)
  makeCanvas("dust", function(g)
    for i=1,12 do
      local a=i*2.399; local r=4+(i%5)*2.2; local s=2+(i%3)
      g.setColor(0.58,0.44,0.28,0.25 + (i%4)*0.08)
      g.circle("fill",16+math.cos(a)*r,16+math.sin(a)*r,s)
    end
  end)
  makeCanvas("leaf", function(g)
    g.setColor(0.20,0.82,0.24,0.82)
    g.ellipse("fill",16,16,5,13,0.68)
    g.setColor(0.72,1.00,0.56,0.92)
    g.line(12,23,20,9)
  end)
  makeCanvas("shadow", function(g)
    for r=13,3,-2 do
      local q=r/13
      g.setColor(0.26,0.05,0.42,0.04+0.055*(1-q))
      g.circle("fill",16,16,r)
    end
    g.setColor(0.72,0.34,0.92,0.72); g.circle("line",16,16,9)
  end)
  makeCanvas("spark", function(g)
    g.setColor(1,0.92,0.38,0.92)
    g.polygon("fill",16,1,19,11,30,9,21,16,30,23,19,21,16,31,13,21,2,23,11,16,2,9,13,11)
    g.setColor(1,1,1,0.92); g.circle("fill",16,16,3)
  end)
  makeCanvas("bubble", function(g)
    g.setColor(0.38,0.78,1,0.22); g.circle("fill",16,16,11)
    g.setColor(0.78,0.95,1,0.86); g.setLineWidth(2); g.circle("line",16,16,11)
    g.setColor(1,1,1,0.82); g.circle("fill",12,12,2)
  end)
  makeCanvas("heart", function(g)
    g.setColor(1,0.30,0.52,0.86)
    g.circle("fill",11,12,6); g.circle("fill",21,12,6)
    g.polygon("fill",5,14,27,14,16,29)
  end)
  live.ready = tex.orb ~= nil
  return live.ready
end

local function moveDef(battle)
  if not (battle and battle.animName and battle.data and battle.data.moves) then return nil end
  return battle.data.moves[battle.animName]
end
local function norm(s) return type(s)=="string" and string.upper(s):gsub("[^A-Z0-9]","") or "" end
local function moveName(battle, def)
  local n = norm(def and (def.name or def.id))
  if n~="" then return n end
  return norm(battle and battle.animName)
end
local function moveType(def)
  local t=def and (def.type or def.moveType)
  if type(t)=="table" then t=t.id or t.name end
  return norm(t)
end
local function power(def) return tonumber(def and def.power) or 0 end

local SPECIAL = {
  HYPERBEAM="beam", SOLARBEAM="solarbeam", ICEBEAM="icebeam",
  HYDROPUMP="hydro", FIREBLAST="fireblast", THUNDER="thunder",
  SURF="surf", EARTHQUAKE="quake", EXPLOSION="explode", SELFDESTRUCT="explode",
  PSYCHIC="psychic", PSYBEAM="psybeam", CONFUSION="psychic",
  BLIZZARD="blizzard", AURORABEAM="aurora",
  ROCKSLIDE="rocks", ROCKTHROW="rocks", SWIFT="swift",
  THUNDERBOLT="thunderbolt", THUNDERSHOCK="thunderbolt", THUNDERWAVE="thunderwave",
  GUST="tornado", WHIRLWIND="tornado", RAZORWIND="tornado", WINGATTACK="windslash",
  FLAMETHROWER="flamethrower", EMBER="ember",
  BUBBLE="bubble", BUBBLEBEAM="bubble", WATERGUN="watergun",
  RAZORLEAF="razorleaf", VINEWHIP="vine", PETALDANCE="petals",
  MEGADRAIN="drain", ABSORB="drain", LEECHSEED="seed",
  POISONPOWDER="powder", STUNSPORE="powder", SLEEPPOWDER="powder", SPORE="powder",
  SLUDGEBOMB="sludge", ACID="sludge",
  NIGHTSHADE="night", LICK="night",
  DRAGONRAGE="dragon",
  DIG="dig", FISSURE="fissure",
  SEISMICTOSS="seismic", BODYSLAM="body", TAKEDOWN="body",
}

local FAMILY = {
  FIRE="fire", WATER="water", ELECTRIC="electric", ICE="ice",
  PSYCHIC="psychic", POISON="poison", GRASS="grass",
  NORMAL="impact", FIGHTING="impact", GROUND="ground", ROCK="rock",
  BUG="bug", GHOST="ghost", DRAGON="dragon", FLYING="wind",
}

local function phaseFor(battle, special)
  local duration = special and 52 or 42
  local f = tonumber(battle and battle.frame) or 0
  return (f % duration) / math.max(1,duration-1)
end

local function points()
  local arena, battle = live.arena, live.battle
  if not (arena and battle and arena.player and arena.enemy) then return nil end
  local playerAtk = battle.animAttackerIsPlayer and true or false
  local a = playerAtk and arena.player or arena.enemy
  local b = playerAtk and arena.enemy or arena.player
  local ay = (live.groundY or 0) + (playerAtk and 8.5 or 10.0)
  local by = (live.groundY or 0) + (playerAtk and 10.0 or 8.5)
  return {a[1],ay,a[2]}, {b[1],by,b[2]}
end

local function yawAt(x,z)
  local eye = Voxel3D.eye
  if type(BattleBillboard.yawToward)=="function" then
    return BattleBillboard.yawToward(x,z,eye)
  end
  if eye then return math.atan2(eye[1]-x, eye[3]-z) end
  return 0
end

local function cardMatrix(x,y,z,w,h,yaw,roll)
  local m = Mat4.mul(Mat4.translate(x,y,z), Mat4.rotateY(yaw or yawAt(x,z)))
  -- BattleBillboard's unit card is x=-.5..+.5, y=0..1. Center it vertically.
  m = Mat4.mul(m, Mat4.translate(0,-h*0.5,0))
  if roll and Mat4.rotateZ then m = Mat4.mul(m, Mat4.rotateZ(roll)) end
  return Mat4.mul(m, Mat4.scale(w,h,1))
end

local function drawCard(texture,x,y,z,w,h,pull,yaw,roll)
  if not texture then return end
  local m=cardMatrix(x,y,z,w,h,yaw,roll)
  Voxel3D.draw(BattleBillboard.mesh(), texture, m, pull or 0)
end

local function drawCross(texture,x,y,z,w,h,pull,spin)
  local y0=yawAt(x,z) + (spin or 0)
  drawCard(texture,x,y,z,w,h,pull,y0)
  drawCard(texture,x,y,z,w,h,pull,y0+PI/2)
end

local function along(a,b,t,lift)
  local x=lerp(a[1],b[1],t); local y=lerp(a[2],b[2],t)+(lift or 0); local z=lerp(a[3],b[3],t)
  return x,y,z
end

local function projectileTrail(texture,a,b,phase,pull,size,count,arc,spin)
  count=count or 7
  for i=0,count-1 do
    local lag=i*0.055
    local t=clamp(phase*1.22-lag,0,1)
    if t>0 and t<1 then
      local x,y,z=along(a,b,t, math.sin(t*PI)*(arc or 0))
      local fade=1-i/count
      drawCross(texture,x,y,z,size*fade,size*fade,pull,(spin or 0)+phase*TAU+i*.7)
    end
  end
end

local function beam(texture,a,b,phase,pull,width)
  local reach=clamp((phase-0.18)/0.38,0,1)
  if reach<=0 then return end
  local segs=16
  for i=1,segs do
    local t=(i/segs)*reach
    local x,y,z=along(a,b,t, math.sin(t*PI)*0.7)
    local pulse=0.82+0.18*math.sin(phase*TAU*6+i)
    drawCross(texture,x,y,z,width*pulse,width*pulse,pull,phase*2+i*.31)
  end
end

local function targetBurst(texture,b,phase,pull,scale)
  local env=clamp(1-math.abs(phase-.68)/.22,0,1)
  if env<=0 then return end
  for i=1,8 do
    local a=i*TAU/8 + phase*2
    local r=(1-env)*5 + 1
    local x=b[1]+math.cos(a)*r; local z=b[3]+math.sin(a)*r; local y=b[2]+math.sin(a*2)*2
    drawCross(texture,x,y,z,(scale or 3)*(0.5+env),(scale or 3)*(0.5+env),pull,a)
  end
end

local function orbitCloud(texture,c,phase,pull,count,radius,size,rise)
  for i=1,(count or 10) do
    local ang=i*2.399 + phase*TAU*1.7
    local r=(radius or 5)*(0.45 + (i%5)/7)
    local y=(c[2] or 0) + ((i%4)-1.5)*(rise or 1.5) + math.sin(ang*1.7)*1.2
    drawCross(texture,c[1]+math.cos(ang)*r,y,c[3]+math.sin(ang)*r,size or 2.6,size or 2.6,pull,ang)
  end
end

local function groundRing(texture,c,phase,pull,count,radius,size)
  local grow=clamp(phase*1.5,0,1)
  for i=1,(count or 12) do
    local ang=i*TAU/(count or 12)+phase*1.2
    local r=(radius or 8)*grow
    drawCross(texture,c[1]+math.cos(ang)*r,(live.groundY or 0)+1.2,c[3]+math.sin(ang)*r,size or 2.4,size or 2.0,pull,ang)
  end
end

-- True world-space lightning: a jagged 3D trunk plus short side branches.
-- This stays entirely in the Phase 5 billboard layer and never touches the
-- Stadium model/summon path.
local function lightningBolt(a,b,phase,pull,width,seed,branches)
  local segs=18
  local wobble=(1-clamp(phase,0,1))*0.35 + 0.65
  local pts={}
  for i=0,segs do
    local t=i/segs
    local x,y,z=along(a,b,t, math.sin(t*PI)*0.8)
    if i>0 and i<segs then
      local k=(seed or 1)*11.731 + i*19.173 + math.floor(phase*22)*7.17
      local j1=math.sin(k*1.37)*1.55*wobble
      local j2=math.cos(k*1.91)*1.55*wobble
      x=x+j1; z=z+j2; y=y+math.sin(k*.73)*1.1*wobble
    end
    pts[#pts+1]={x,y,z}
  end
  for i=1,#pts do
    local q=pts[i]
    local pulse=0.78+0.22*math.sin(phase*TAU*12+i*1.7)
    drawCross(tex.electric,q[1],q[2],q[3],width*pulse,width*1.45*pulse,pull,phase*8+i*.41)
  end
  local n=branches or 5
  for j=1,n do
    local idx=2+((j*3 + (seed or 0)) % math.max(2,segs-2))
    local q=pts[idx]
    local ang=j*2.399 + phase*5 + (seed or 0)
    local len=2.2+(j%3)*1.4
    local tip={q[1]+math.cos(ang)*len, q[2]+((j%2==0) and 1.4 or -0.8), q[3]+math.sin(ang)*len}
    for k=1,4 do
      local t=k/4
      local x,y,z=along(q,tip,t,0)
      drawCross(tex.electric,x,y,z,width*.62,width*.92,pull,ang+k*.3)
    end
  end
end

-- 3D tornado funnel assembled from many world-space wind cards. Each level
-- spins independently and widens toward the top, making the funnel retain its
-- volume when Dramatic Shape's battle camera rotates.
local function tornadoFx(center,phase,pull,height,baseRadius,topRadius,strength)
  height=height or 20
  baseRadius=baseRadius or 1.8
  topRadius=topRadius or 8.0
  strength=strength or 1
  -- Big, high-contrast stacked rings.  This intentionally uses more visible
  -- geometry than v0.1.29 so the funnel reads clearly on a phone screen and
  -- remains visible from every Dramatic Shape camera angle.
  local levels=12
  local slices=7
  local ground=(live.groundY or 0)
  for level=0,levels-1 do
    local v=level/(levels-1)
    local y=ground+1.2+v*height
    local radius=lerp(baseRadius,topRadius,v)
      *(0.94+0.10*math.sin(phase*TAU*4+level*.65))
    for i=1,slices do
      local ang=i*TAU/slices + phase*TAU*(2.8+v*1.1) + level*.52
      local x=center[1]+math.cos(ang)*radius
      local z=center[3]+math.sin(ang)*radius
      local size=(2.1+v*3.5)*strength
      drawCross(tex.wind,x,y,z,size*2.15,size*0.72,pull,ang+PI*.5)
    end
  end
  -- Dense inner column so the tornado cannot disappear when viewed edge-on.
  for i=1,18 do
    local v=(i-1)/17
    local y=ground+1.3+v*height
    local ang=phase*TAU*3.6+i*1.73
    local r=0.65+v*2.0
    drawCross(tex.wind,center[1]+math.cos(ang)*r,y,center[3]+math.sin(ang)*r,
      (2.0+v*2.2)*strength,(1.1+v*.8)*strength,pull,ang)
  end
  -- Broad base dust/wind skirt anchors it visibly to the battle floor.
  for i=1,16 do
    local ang=i*TAU/16-phase*TAU*2.4
    local r=2.5+(i%5)*1.15
    drawCross(tex.wind,center[1]+math.cos(ang)*r,ground+1.0+(i%3)*.3,
      center[3]+math.sin(ang)*r,3.4*strength,1.25*strength,pull,ang)
  end
end

local function windSlash(a,b,phase,pull,strength)
  for i=0,7 do
    local t=clamp(phase*1.35-i*.045,0,1)
    if t>0 and t<1 then
      local x,y,z=along(a,b,t,math.sin(t*PI)*2.3)
      local ang=phase*TAU*4+i*.8
      drawCross(tex.wind,x,y,z,4.2*strength,1.5*strength,pull,ang)
    end
  end
end

local function drainStream(a,b,phase,pull)
  for i=0,9 do
    local t=clamp(phase*1.15-i*.045,0,1)
    if t>0 and t<1 then
      -- reverse travel: target energy flows back toward attacker
      local x,y,z=along(b,a,t,math.sin(t*PI)*3.0)
      drawCross(tex.leaf,x,y,z,2.0,2.8,pull,phase*4+i*.4)
    end
  end
end

local function drawWorldFx(pull)
  local battle=live.battle
  if not (battle and battle.animPlaying and battle.animName and live.arena) then return end
  if not buildTextures() then return end
  local def=moveDef(battle); if not def then return end
  local name=moveName(battle,def)
  local special=SPECIAL[name]
  local family=FAMILY[moveType(def)]
  if not special and not family then return end
  local phase=phaseFor(battle,special)
  local a,b=points(); if not a then return end
  local strength=clamp(.8+power(def)/220,.8,1.5)
  local p=(pull or 0)-0.15 -- a tiny camera-ward bias keeps translucent cards off terrain

  if special=="beam" then
    if phase<.28 then
      for i=1,7 do
        local ang=i*TAU/7+phase*5; local r=4*(1-phase/.28)
        drawCross(tex.orb,a[1]+math.cos(ang)*r,a[2]+math.sin(ang*2),a[3]+math.sin(ang)*r,2.8,2.8,p,ang)
      end
    else beam(tex.orb,a,b,phase,p,2.3*strength); targetBurst(tex.ring,b,phase,p,3.2*strength) end
  elseif special=="solarbeam" then
    if phase<.34 then
      orbitCloud(tex.leaf,a,phase,p,10,5,2.3,1.4)
      orbitCloud(tex.spark,a,phase,p,6,3.5,1.6,1.0)
    else
      beam(tex.leaf,a,b,phase,p,2.5*strength); beam(tex.spark,a,b,phase,p,1.4*strength)
      targetBurst(tex.leaf,b,phase,p,3.8)
    end
  elseif special=="hydro" then
    beam(tex.water,a,b,phase,p,2.4*strength); projectileTrail(tex.water,a,b,phase,p,3.4,10,3.0); targetBurst(tex.water,b,phase,p,3.5)
  elseif special=="watergun" then
    projectileTrail(tex.water,a,b,phase,p,2.4*strength,9,1.2); targetBurst(tex.water,b,phase,p,2.4)
  elseif special=="bubble" then
    projectileTrail(tex.bubble,a,b,phase,p,3.1*strength,10,4.5,phase*2); targetBurst(tex.bubble,b,phase,p,3.0)
  elseif special=="fireblast" then
    projectileTrail(tex.orb,a,b,phase,p,4.2*strength,6,2.2,phase*4); targetBurst(tex.orb,b,phase,p,5.0*strength)
  elseif special=="flamethrower" then
    beam(tex.orb,a,b,phase,p,1.9*strength); projectileTrail(tex.orb,a,b,phase,p,3.0,12,2.0,phase*6); targetBurst(tex.orb,b,phase,p,3.5)
  elseif special=="ember" then
    projectileTrail(tex.orb,a,b,phase,p,2.1*strength,8,4.0,phase*5); targetBurst(tex.orb,b,phase,p,2.3)
  elseif special=="thunder" then
    local top={b[1],b[2]+30,b[3]}
    lightningBolt(top,b,phase,p,3.2*strength,7,7)
    targetBurst(tex.electric,b,phase,p,4.8)
  elseif special=="thunderbolt" then
    lightningBolt(a,b,phase,p,2.45*strength,13,6)
    orbitCloud(tex.electric,b,phase,p,9,4.3,2.6,2.0)
    targetBurst(tex.electric,b,phase,p,3.8)
  elseif special=="thunderwave" then
    -- Multiple thinner bolts curl around the target instead of a flat halo.
    for i=1,4 do
      local ang=i*TAU/4+phase*TAU*2
      local src={b[1]+math.cos(ang)*7,b[2]+4+math.sin(ang*2)*2,b[3]+math.sin(ang)*7}
      lightningBolt(src,b,phase,p,1.25,20+i,2)
    end
    orbitCloud(tex.electric,b,phase,p,10,5.0,2.1,2.0)
  elseif special=="tornado" then
    local travel=clamp((phase-.05)/.58,0,1)
    local cx,cy,cz=along(a,b,travel,0)
    tornadoFx({cx,cy,cz},phase,p,17,1.2,6.3,1.0*strength)
    if phase>.55 then targetBurst(tex.wind,b,phase,p,4.2*strength) end
  elseif special=="windslash" then
    windSlash(a,b,phase,p,strength)
    if phase>.5 then tornadoFx(b,phase,p,10,1.0,3.8,.72*strength) end
  elseif special=="surf" then
    for i=1,14 do
      local t=(i-1)/13; local x,y,z=along(a,b,t,0)
      local wave=math.sin(t*TAU-phase*TAU*2)*3 + 3
      drawCross(tex.water,x,(live.groundY or 0)+2+wave,z,5.5,5.5,p,t*2)
    end
  elseif special=="quake" then
    for i=1,18 do
      local ang=i*2.399+phase; local r=3+(i%6)*2.2
      drawCross(tex.dust,b[1]+math.cos(ang)*r,(live.groundY or 0)+1.2,b[3]+math.sin(ang)*r,3.2,2.2,p,ang)
    end
  elseif special=="dig" then
    groundRing(tex.dust,a,phase,p,12,7,2.8); groundRing(tex.dust,b,clamp(phase-.28,0,1),p,12,6,2.8)
  elseif special=="fissure" then
    groundRing(tex.dust,b,phase,p,18,12,3.1)
    for i=1,10 do
      local ang=i*2.399
      drawCross(tex.shadow,b[1]+math.cos(ang)*(2+i*.5),(live.groundY or 0)+.7,b[3]+math.sin(ang)*(2+i*.5),3.2,1.4,p,ang)
    end
  elseif special=="explode" then
    local env=math.sin(clamp(phase,0,1)*PI)
    for i=1,18 do
      local ang=i*2.399; local r=env*(3+(i%7)*2)
      drawCross(tex.orb,a[1]+math.cos(ang)*r,a[2]+math.sin(ang*1.7)*r*.5,a[3]+math.sin(ang)*r,4+env*5,4+env*5,p,ang)
    end
  elseif special=="icebeam" then
    beam(tex.ice,a,b,phase,p,2.6*strength); targetBurst(tex.ice,b,phase,p,4)
  elseif special=="aurora" then
    beam(tex.psychic,a,b,phase,p,1.9*strength); projectileTrail(tex.ice,a,b,phase,p,2.1,9,3.5,phase*3)
  elseif special=="blizzard" then
    for i=1,22 do
      local ang=i*2.399+phase*4; local r=3+(i%8)*1.8
      drawCard(tex.ice,b[1]+math.cos(ang)*r,b[2]+(i%5)*2-3,b[3]+math.sin(ang)*r,2.5,4,p,nil,ang)
    end
  elseif special=="psychic" then
    for i=1,7 do
      local ang=i*TAU/7+phase*3; local r=2+i*.8+math.sin(phase*TAU+i)*2
      drawCross(tex.psychic,b[1]+math.cos(ang)*r,b[2]+math.sin(ang*2)*2,b[3]+math.sin(ang)*r,3+i*.4,3+i*.4,p,ang)
    end
  elseif special=="psybeam" then
    projectileTrail(tex.psychic,a,b,phase,p,3.0,12,2.0,phase*8); beam(tex.spark,a,b,phase,p,1.2)
  elseif special=="night" then
    projectileTrail(tex.shadow,a,b,phase,p,3.4,8,4.0,phase*3); orbitCloud(tex.shadow,b,phase,p,9,5,3.0,2.5)
  elseif special=="dragon" then
    beam(tex.orb,a,b,phase,p,2.0*strength); orbitCloud(tex.psychic,b,phase,p,7,4.2,2.5,2.0)
  elseif special=="rocks" then
    for i=1,12 do
      local t=clamp(phase*1.4-i*.035,0,1)
      if t>0 then drawCross(tex.dust,b[1]+math.cos(i)*5,b[2]+12*(1-t),b[3]+math.sin(i)*5,3.4,3.4,p,i) end
    end
  elseif special=="swift" then
    projectileTrail(tex.spark,a,b,phase,p,2.6,9,4.0,phase*5)
  elseif special=="razorleaf" then
    projectileTrail(tex.leaf,a,b,phase,p,2.4*strength,12,5.0,phase*8); targetBurst(tex.leaf,b,phase,p,3.0)
  elseif special=="vine" then
    beam(tex.leaf,a,b,phase,p,1.3*strength); targetBurst(tex.leaf,b,phase,p,2.6)
  elseif special=="petals" then
    orbitCloud(tex.leaf,b,phase,p,18,8,2.5,3.0)
  elseif special=="drain" then
    drainStream(a,b,phase,p); orbitCloud(tex.leaf,a,phase,p,7,3.6,2.0,1.5)
  elseif special=="seed" then
    projectileTrail(tex.leaf,a,b,phase,p,2.0,5,5.0,phase*3); orbitCloud(tex.leaf,b,phase,p,8,4,2.0,1.0)
  elseif special=="powder" then
    orbitCloud(tex.poison,b,phase,p,16,7,2.5,4.0)
  elseif special=="sludge" then
    projectileTrail(tex.poison,a,b,phase,p,3.7*strength,8,6.0,phase*2); targetBurst(tex.poison,b,phase,p,4.0)
  elseif special=="seismic" then
    groundRing(tex.dust,b,phase,p,14,9,2.5); targetBurst(tex.ring,b,phase,p,4.2)
  elseif special=="body" then
    targetBurst(tex.ring,b,phase,p,4.6*strength); groundRing(tex.dust,b,phase,p,10,6,2.0)
  elseif family=="fire" then
    projectileTrail(tex.orb,a,b,phase,p,3.0*strength,7,3.0); targetBurst(tex.orb,b,phase,p,3.0)
  elseif family=="water" then
    projectileTrail(tex.water,a,b,phase,p,2.8*strength,8,3.0); targetBurst(tex.water,b,phase,p,2.8)
  elseif family=="electric" then
    lightningBolt(a,b,phase,p,2.15*strength,31,5); targetBurst(tex.electric,b,phase,p,3.4)
  elseif family=="ice" then
    projectileTrail(tex.ice,a,b,phase,p,2.5*strength,7,4.0); targetBurst(tex.ice,b,phase,p,3.0)
  elseif family=="psychic" then
    projectileTrail(tex.psychic,a,b,phase,p,2.8*strength,6,2.0); targetBurst(tex.psychic,b,phase,p,3.3)
  elseif family=="poison" then
    projectileTrail(tex.poison,a,b,phase,p,3.0*strength,7,4.0); targetBurst(tex.poison,b,phase,p,3.2)
  elseif family=="wind" then
    local travel=clamp((phase-.02)/.72,0,1)
    local cx,cy,cz=along(a,b,travel,0)
    tornadoFx({cx,cy,cz},phase,p,18,1.5,6.8,.92*strength)
    if phase>.58 then targetBurst(tex.wind,b,phase,p,4.0*strength) end
  elseif family=="grass" then
    projectileTrail(tex.leaf,a,b,phase,p,2.6*strength,8,4.5,phase*4); targetBurst(tex.leaf,b,phase,p,2.8)
  elseif family=="ghost" then
    projectileTrail(tex.shadow,a,b,phase,p,3.0*strength,7,4.5,phase*3); targetBurst(tex.shadow,b,phase,p,3.4)
  elseif family=="dragon" then
    projectileTrail(tex.psychic,a,b,phase,p,3.0*strength,7,3.0,phase*4); targetBurst(tex.orb,b,phase,p,3.2)
  elseif family=="ground" then
    groundRing(tex.dust,b,phase,p,12,8,2.3); targetBurst(tex.dust,b,phase,p,2.8)
  elseif family=="rock" then
    targetBurst(tex.dust,b,phase,p,3.2*strength); groundRing(tex.dust,b,phase,p,8,5,2.2)
  elseif family=="bug" then
    projectileTrail(tex.leaf,a,b,phase,p,2.3*strength,7,3.0,phase*5); targetBurst(tex.ring,b,phase,p,2.6)
  elseif family=="impact" and power(def)>0 then
    targetBurst(tex.ring,b,phase,p,3.4*strength)
  end
end

function M.install()
  if installed or Stadium._stadiumPhase5WorldFx then return true end
  if type(Stadium.begin)~="function" or type(Stadium.update)~="function" or type(Stadium.draw)~="function" then
    return false, "Dramatic Shape Stadium world hooks unavailable"
  end

  local innerBegin, innerUpdate, innerDraw, innerFinish = Stadium.begin, Stadium.update, Stadium.draw, Stadium.finish

  Stadium.begin = function(arena, ...)
    live.arena, live.battle, live.groundY = arena, nil, 0
    pcall(buildTextures)
    return innerBegin(arena, ...)
  end

  Stadium.update = function(dt, battle, groundY, ...)
    live.battle = battle or live.battle
    if groundY~=nil then live.groundY=groundY end
    return innerUpdate(dt, battle, groundY, ...)
  end

  Stadium.draw = function(pull, ...)
    local out={innerDraw(pull, ...)}
    local ok,err=pcall(drawWorldFx,pull)
    if not ok then log("warn","Phase 5 world effect skipped: %s",tostring(err)) end
    local u=(table and table.unpack) or unpack
    if u then return u(out) end
  end

  if type(innerFinish)=="function" then
    Stadium.finish = function(...)
      live.arena, live.battle, live.groundY = nil,nil,0
      return innerFinish(...)
    end
  end

  Stadium._stadiumPhase5WorldFx=true
  installed=true
  log("info","Pokemon Stadium Phase 5 world-space battle effects installed")
  return true
end

function M.active() return installed and Stadium.active and Stadium.active() or false end
return M
