--[[
    ENTRENCHED HUB
    Target: place 3678761576 (ENTRENCHED by Edot)

    Built against the game's real fire path:
      ServerEvents.Shoot:FireServer(state, aimPoint, aiming, missedCount, hitList, cameraPos)

    The primary aim method hooks the WeaponModule global "Crosshair" so the game
    itself aims at the target. That keeps aimPoint, hitList and missedCount
    internally consistent, which a raw argument rewrite cannot guarantee.
]]

--========================================================================
-- 0. IDEMPOTENT RESTORE. Runs unconditionally on every load.
--========================================================================
local G = getgenv()

do
    local prev = rawget(G, "__ENTRENCHED_HUB")
    if prev then
        pcall(function() prev.running = false end)
        for _, c in ipairs(prev.conns or {}) do pcall(function() c:Disconnect() end) end
        for _, b in ipairs(prev.binds or {}) do
            pcall(function() game:GetService("RunService"):UnbindFromRenderStep(b) end)
        end
        for _, i in ipairs(prev.instances or {}) do pcall(function() i:Destroy() end) end
        pcall(function() if prev.restoreCrosshair then prev.restoreCrosshair() end end)
        pcall(function() if prev.restoreRange then prev.restoreRange() end end)
        pcall(function() if prev.restoreSpread then prev.restoreSpread() end end)
        pcall(function() if prev.restoreMagnet then prev.restoreMagnet() end end)
        pcall(function() if prev.releaseCursor then prev.releaseCursor() end end)
        pcall(function() game:GetService("RunService"):UnbindFromRenderStep("ENT_CURSOR") end)
        pcall(function() if prev.restoreFov then prev.restoreFov() end end)
    end
end

local Hub = { running = true, conns = {}, binds = {}, instances = {}, version = "1.0" }
Hub.stats = { shots = 0, redirects = 0, hits = 0, kills = 0, heads = 0, dmg = 0,
              friendlyBlocked = 0, fabricated = 0, last = "none" }
G.__ENTRENCHED_HUB = Hub

--========================================================================
-- 1. SERVICES
--========================================================================
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LP     = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- Executor globals, captured defensively. Referencing an undefined global in
-- Luau yields nil rather than raising, so these guards are safe on any executor.
local EX = {}
do
    local function grab(name)
        local ok, v = pcall(function() return (getgenv())[name] end)
        if ok and type(v) == "function" then return v end
        return nil
    end
    EX.gethui         = grab("gethui")
    EX.restorefunc    = grab("restorefunction")
    EX.click          = grab("mouse1click")
    EX.hookfunction   = grab("hookfunction")
    EX.hookmetamethod = grab("hookmetamethod")
    EX.namecallmethod = grab("getnamecallmethod")
    EX.writefile      = grab("writefile")
    EX.readfile       = grab("readfile")
    EX.isfile         = grab("isfile")
end

local function guiParent()
    if EX.gethui then
        local ok, h = pcall(EX.gethui)
        if ok and h then return h end
    end
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then return cg end
    return LP:WaitForChild("PlayerGui")
end

local rebindCamera   -- assigned once the FOV tracking exists

local function connect(signal, fn)
    local ok, c = pcall(function() return signal:Connect(fn) end)
    if ok and c then Hub.conns[#Hub.conns + 1] = c end
    return ok and c or nil
end

local function track(inst)
    Hub.instances[#Hub.instances + 1] = inst
    return inst
end

local function bind(name, priority, fn)
    pcall(function() RunService:UnbindFromRenderStep(name) end)
    RunService:BindToRenderStep(name, priority, fn)
    for _, n in ipairs(Hub.binds) do
        if n == name then return end
    end
    Hub.binds[#Hub.binds + 1] = name
end

--========================================================================
-- 2. CONFIG
--========================================================================
local Cfg = {
    silent = {
        enabled   = true,    -- invisible to other players, and it does the work
        fabricate = false,   -- only needed for wallbang, and unproven server side
        wallbang  = false,   -- loudest thing this can send, opt in only
    },
    aimbot = {
        enabled = false,     -- silent aim already lands the shot without moving the view
        hold    = true,
        smooth  = 0.35,
    },
    target = {
        fov      = 50,       -- stays inside the camera's own view
        part     = "Head",   -- measured 1.5x, a one shot with most rifles
        visCheck = true,
        maxDist  = 2000,
        -- Velocity and ProjectileGravity are read by no client script, so the
        -- server simulates bullet travel and leading genuinely helps. Gravity is
        -- zero on every firearm, so this is lead only and never drop.
        predict  = true,
    },
    weapon = {
        noSpread   = true,
        extRange   = false,  -- makes the game report allies it rays through
        extRangeV  = 1000,
        magnetism  = false,
        triggerbot = false,
        fastFire   = true,
        fireRate   = 1.0,    -- 1 is stock, the fast fire path only acts below 1
        stackHits  = 3,      -- only used when fabricating
    },
    esp = {
        enabled   = true,
        box       = true,
        style     = "Corners",
        name      = true,
        dist      = true,
        health    = true,
        hpText    = false,
        tracer    = false,
        chams     = true,
        offscreen = true,
        maxDist   = 2000,
    },
    view = {
        fovCircle = true,
        camFov    = 0,
    },
    ui = {
        -- shipped ON so the panel is clickable out of the box. Turn it off if you
        -- would rather keep mouse look while the panel is visible.
        freeCursor = true,
        autoSave   = true,
    },
}
Hub.cfg = Cfg

--========================================================================
-- 2b. CONFIG PERSISTENCE
--========================================================================
local CFG_FILE = "EntrenchedHub_Config.json"
local HttpService = game:GetService("HttpService")

-- Merge only keys we already know about, and only when the type matches, so a
-- stale or hand edited file can never inject something unexpected.
local function mergeInto(dst, src)
    for k, v in pairs(src) do
        local cur = dst[k]
        if type(cur) == "table" and type(v) == "table" then
            mergeInto(cur, v)
        elseif cur ~= nil and type(cur) == type(v) then
            dst[k] = v
        end
    end
end

local function loadCfg()
    if not (EX.isfile and EX.readfile) then return false end
    local ok, raw = pcall(EX.isfile, CFG_FILE)
    if not ok or not raw then return false end
    local ok2, txt = pcall(EX.readfile, CFG_FILE)
    if not ok2 or type(txt) ~= "string" or txt == "" then return false end
    local ok3, tbl = pcall(function() return HttpService:JSONDecode(txt) end)
    if not ok3 or type(tbl) ~= "table" then return false end
    mergeInto(Cfg, tbl)
    return true
end

local saveQueued = false

-- force=true writes even when autoSave is off, which is how switching autoSave
-- off manages to persist its own new value instead of silently reverting.
local function saveCfg(force)
    if not EX.writefile then return end
    if not (force or Cfg.ui.autoSave) then return end
    if force then
        pcall(function() EX.writefile(CFG_FILE, HttpService:JSONEncode(Cfg)) end)
        return
    end
    if saveQueued then return end
    saveQueued = true
    task.delay(0.75, function()
        saveQueued = false
        -- a save queued by a previous load must not overwrite the new one
        if rawget(G, "__ENTRENCHED_HUB") ~= Hub then return end
        pcall(function() EX.writefile(CFG_FILE, HttpService:JSONEncode(Cfg)) end)
    end)
end

local cfgLoaded = loadCfg()
Hub.saveCfg = saveCfg

--========================================================================
-- 3. THEME
--========================================================================
local T = {
    bg     = Color3.fromRGB(16, 16, 18),
    panel  = Color3.fromRGB(23, 23, 26),
    raised = Color3.fromRGB(31, 31, 35),
    stroke = Color3.fromRGB(44, 44, 50),
    text   = Color3.fromRGB(233, 233, 236),
    dim    = Color3.fromRGB(129, 129, 139),
    accent = Color3.fromRGB(201, 162, 39),
    good   = Color3.fromRGB(118, 188, 108),
    bad    = Color3.fromRGB(205, 95, 90),
    font   = Enum.Font.Gotham,
    fontB  = Enum.Font.GothamBold,
}

--========================================================================
-- 4. GAME BINDINGS
--========================================================================
local SE = ReplicatedStorage:WaitForChild("ServerEvents")
local CE = ReplicatedStorage:WaitForChild("ClientEvents")
local ShootRemote = SE:FindFirstChild("Shoot")

local WeaponModule, WMEnv, shootEffect
do
    local ok, mod = pcall(require, ReplicatedStorage:WaitForChild("WeaponModule"))
    if ok and type(mod) == "table" then
        WeaponModule = mod
        pcall(function() WMEnv = getfenv(mod.Shoot) end)
        pcall(function() shootEffect = debug.getupvalue(mod.Shoot, 3) end)
    end
end

local TeamRefs = {}
do
    local tf = game:GetService("Teams")
    for _, n in ipairs({ "Team1", "Team2", "SelectionTeam" }) do
        local ov = tf:FindFirstChild(n) or ReplicatedStorage:FindFirstChild(n)
        if ov and ov:IsA("ObjectValue") then TeamRefs[n] = ov end
    end
end

local SpawnboxBase
pcall(function()
    local sb = workspace:FindFirstChild("Spawnbox")
    SpawnboxBase = sb and sb:FindFirstChild("Base")
end)

-- Valid aim parts. Whitelist only. AENcD and AimAttachPart must never appear here.
local AIM_PARTS = {
    Head = true, UpperTorso = true, LowerTorso = true, HumanoidRootPart = true,
    LeftUpperArm = true, RightUpperArm = true, LeftLowerArm = true, RightLowerArm = true,
    LeftHand = true, RightHand = true, LeftUpperLeg = true, RightUpperLeg = true,
    LeftLowerLeg = true, RightLowerLeg = true, LeftFoot = true, RightFoot = true,
}

--========================================================================
-- 5. TARGETING
--========================================================================
local Targeting = {}
Targeting.current = nil

local function getHum(char)
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function myHead()
    local c = LP.Character
    return c and c:FindFirstChild("Head") or nil
end

-- Health > 0 is wrong in this game in both directions. Downed players regenerate
-- and dead-awaiting-respawn players still read above zero.
function Targeting.isAlive(char)
    local h = getHum(char)
    if not h then return false end
    local ok, st = pcall(function() return h:GetState() end)
    if ok and st == Enum.HumanoidStateType.Dead then return false end
    if char:FindFirstChild("ReviveTime") then return false end
    if char:FindFirstChild("RespawnDelay") then return false end
    return h.Health > 0
end

function Targeting.inLobby(char)
    if not SpawnboxBase then return false end
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    return (root.Position - SpawnboxBase.Position).Magnitude < 250
end

function Targeting.isEnemy(p)
    if p == LP then return false end
    if not p.Team or not LP.Team then return false end
    if TeamRefs.SelectionTeam and p.Team == TeamRefs.SelectionTeam.Value then return false end
    return p.Team ~= LP.Team
end

-- Mirror the game's own damage raycast params, or our notion of visibility will
-- disagree with what the server actually sees.
-- Mirror the game's DAMAGE raycast, which filters only your own character.
-- Do NOT exclude ShootThrough-tagged geometry here. That tag only filters the
-- cosmetic tracer, so barbed wire really does stop damage; excluding it would
-- report targets behind wire as visible and every shot at them would miss.
local function losParams(extra)
    local rp = RaycastParams.new()
    rp.CollisionGroup = "Projectiles"
    rp.IgnoreWater = true
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local filter = { LP.Character }
    local cp = workspace:FindFirstChild("CosmeticProjectiles")
    if cp then filter[#filter + 1] = cp end
    if extra then filter[#filter + 1] = extra end
    rp.FilterDescendantsInstances = filter
    return rp
end

function Targeting.visible(part, char)
    local head = myHead()
    if not head or not part then return false end
    local dir = part.Position - head.Position
    return workspace:Raycast(head.Position, dir, losParams(char)) == nil
end

function Targeting.aimPart(char)
    local want = Cfg.target.part
    if want == "Nearest" then
        local head = myHead()
        local best, bd
        for _, p in ipairs(char:GetChildren()) do
            if p:IsA("BasePart") and AIM_PARTS[p.Name] then
                local d = head and (p.Position - head.Position).Magnitude or 0
                if not bd or d < bd then best, bd = p, d end
            end
        end
        return best
    end
    local p = char:FindFirstChild(want)
    if p and AIM_PARTS[p.Name] then return p end
    return char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
end

-- Gravity is zero on every firearm, so this is lead only, never drop.
function Targeting.aimPoint(char, part)
    part = part or Targeting.aimPart(char)
    if not part then return nil end
    local pos = part.Position
    if not Cfg.target.predict then return pos end
    local tool = LP.Character and LP.Character:FindFirstChildOfClass("Tool")
    local vel = tool and tool:GetAttribute("Velocity") or 0
    local root = char:FindFirstChild("HumanoidRootPart")
    local head = myHead()
    if vel and vel > 0 and root and head then
        local t = (pos - head.Position).Magnitude / vel
        pos = pos + root.AssemblyLinearVelocity * t
    end
    return pos
end

function Targeting.select()
    local best, bestAng = nil, math.huge
    local origin = Camera.CFrame.Position
    local look = Camera.CFrame.LookVector
    local limit = math.rad(Cfg.target.fov / 2)

    for _, p in ipairs(Players:GetPlayers()) do
        if Targeting.isEnemy(p) then
            local char = p.Character
            if char and Targeting.isAlive(char) and not Targeting.inLobby(char) then
                local part = Targeting.aimPart(char)
                if part then
                    local delta = part.Position - origin
                    local dist = delta.Magnitude
                    if dist <= Cfg.target.maxDist and dist > 0 then
                        local ang = math.acos(math.clamp(look:Dot(delta.Unit), -1, 1))
                        if ang <= limit and ang < bestAng then
                            local pass = (not Cfg.target.visCheck) or Cfg.silent.wallbang
                                or Targeting.visible(part, char)
                            if pass then
                                best = { player = p, char = char, part = part }
                                bestAng = ang
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

--========================================================================
-- 6. AIM
--========================================================================
local Aim = {}

-- Resolve the point the weapon should report this shot.
function Aim.silentPoint()
    local t = Targeting.current
    if not t then return nil end
    local char = t.char
    if not char or not char.Parent or not Targeting.isAlive(char) then return nil end
    -- Reuse the exact part select() already validated. Recomputing it here would
    -- pick a different part under "Nearest" whose sight line was never checked.
    local part = t.part
    if not part or not part.Parent then part = Targeting.aimPart(char) end
    if not part then return nil end
    return Targeting.aimPoint(char, part), part, char
end

-- 6a. Crosshair hook. shootEffect calls Crosshair(state, camera, 1000); the torso
-- look and the spot tool call it with no range. The 1000 discriminates the shot.
if WMEnv and rawget(WMEnv, "Crosshair") and EX.hookfunction then
    local ref = WMEnv.Crosshair
    local orig
    orig = EX.hookfunction(ref, function(state, cam, range)
        if range == 1000 then
            Hub.stats.shots = Hub.stats.shots + 1
            Hub.lastState = state
            -- runs before WeaponModule computes this shot's spread cone
            if Cfg.weapon.noSpread and Hub.Weapon then
                pcall(Hub.Weapon.patchSpreadForShot, state and state.Tool)
            end
        end
        if range == 1000 and Cfg.silent.enabled and Hub.running then
            local ok, pt = pcall(Aim.silentPoint)
            if ok and pt then
                Hub.stats.redirects = Hub.stats.redirects + 1
                return pt
            end
        end
        return orig(state, cam, range)
    end)
    Hub.restoreCrosshair = function()
        if EX.restorefunc then pcall(EX.restorefunc, ref) end
    end
end

-- Your own collision group, refreshed outside the hook.
-- Body parts are in "PlayersTeam1" or "PlayersTeam2", so comparing the group of
-- a hit part against our own classifies friend or foe with PURE PROPERTY READS.
-- That matters enormously here: see the re-entrancy note on the shim below.
local function refreshMyGroup()
    local c = LP.Character
    local r = c and c:FindFirstChild("HumanoidRootPart")
    Hub.myGroup = r and r.CollisionGroup or nil
end
refreshMyGroup()
connect(LP.CharacterAdded, function()
    task.wait(1)
    refreshMyGroup()
end)

-- 6b. Shoot interception.
-- hookmetamethod can only meaningfully be installed once per executor session,
-- so the hook body must stay a thin shim. All real logic lives in Hub.onShoot,
-- which the newest load replaces. Without this, re-executing the file leaves the
-- FIRST load's logic running forever while the edited file appears to do nothing.
function Hub.onShoot(a, cfg, hub)
    local changed = false

    -- (1) fabrication, the only thing the Crosshair hook cannot do
    if cfg.silent.enabled and cfg.silent.fabricate then
        local fn = (hub.Aim and hub.Aim.silentPoint) or Aim.silentPoint
        local ok, pt, part = pcall(fn)
        if ok and pt and part then
            local reported = part
            -- diagnostic override: report a different part than we aim at, which
            -- is the only way to tell whether the server trusts the hit list or
            -- silently re-resolves the shot from the aim point on its own
            if hub.debugHitPart and part.Parent then
                local alt = part.Parent:FindFirstChild(hub.debugHitPart)
                if alt and alt:IsA("BasePart") then reported = alt end
            end
            local tool = a[1] and a[1].Tool
            local n = 1
            if tool then
                local pr = tool:GetAttribute("Projectiles")
                if type(pr) == "number" and pr > 0 then n = pr end
            end
            local head = myHead()
            local normal = head and (head.Position - pt).Unit or Vector3.new(0, 1, 0)
            -- One entry per pellet is exactly what an honest perfect shot looks
            -- like. Sending MORE than Projectiles is the probe most likely to
            -- trip a server side consistency check, so it is opt in and clamped.
            local stack = math.clamp(math.floor(cfg.weapon.stackHits or 1), 1, 8)
            local total = n * stack
            local list = table.create(total)
            for i = 1, total do
                list[i] = {
                    Instance = reported,
                    Position = reported.Position,
                    Normal   = normal,
                    Material = Enum.Material.Plastic,
                }
            end
            a[2] = pt
            a[4] = 0
            a[5] = list
            hub.stats.fabricated = (hub.stats.fabricated or 0) + 1
            changed = true
        end
    end

    -- (2) friendly fire guard, ALWAYS on.
    -- WeaponModule:1379 adds anything whose parent has a Humanoid to the hit list
    -- with no team check at all. At the stock 100 stud ray you rarely shoot
    -- through an ally, but with the range raised you constantly do, and the
    -- server punishes you for the teamkill. Strip friendly and self entries
    -- before they leave, and put each dropped pellet back into missedCount so the
    -- two arguments stay consistent with each other.
    local list = a[5]
    local myGroup = hub.myGroup
    if myGroup and type(list) == "table" and #list > 0 then
        local clean, dropped = {}, 0
        for _, e in ipairs(list) do
            local inst = (type(e) == "table") and e.Instance or nil
            -- property read only, never a method call, and default to KEEPING
            -- so an unknown part can never silently break the shot
            local keep = true
            if typeof(inst) == "Instance" then
                keep = inst.CollisionGroup ~= myGroup
            end
            if keep then
                clean[#clean + 1] = e
            else
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            a[5] = clean
            if type(a[4]) == "number" then a[4] = a[4] + dropped end
            hub.stats.friendlyBlocked = (hub.stats.friendlyBlocked or 0) + dropped
            changed = true
        end
    end

    return changed
end

-- Direct function reference, captured once. Calling it as fireShoot(remote, ...)
-- goes through __index and a plain call, NOT through __namecall, so it cannot
-- re-enter this hook.
local fireShoot = ShootRemote and ShootRemote.FireServer or nil

if not rawget(G, "__ENT_HUB_NAMECALL") and ShootRemote and fireShoot
    and EX.hookmetamethod and EX.namecallmethod then
    G.__ENT_HUB_NAMECALL = true
    local old
    old = EX.hookmetamethod(game, "__namecall", function(self, ...)
        -- Read the method FIRST. Any method call we make afterwards overwrites
        -- the pending namecall method, and re-dispatching through old(self, ...)
        -- would then invoke THAT name on this remote. That is not theoretical:
        -- it fired Shoot:GetPlayerFromCharacter and killed every shot.
        local method = EX.namecallmethod()
        local hub = rawget(G, "__ENTRENCHED_HUB")
        if hub and hub.running and self == ShootRemote and method == "FireServer" then
            local handler = hub.onShoot
            if handler then
                local a = table.pack(...)
                if a.n >= 6 then
                    local ok, changed = pcall(handler, a, hub.cfg, hub)
                    -- always leave via the direct reference once the handler has
                    -- run, because the handler makes method calls of its own
                    if ok and changed then
                        return fireShoot(self, table.unpack(a, 1, a.n))
                    end
                    if ok then
                        return fireShoot(self, ...)
                    end
                end
            end
        end
        return old(self, ...)
    end)
end

-- 6c. Camera aimbot. The camera here is incremental: ClassicCamera reads the
-- current LookVector back each frame and adds only the mouse delta, so a
-- per-frame rotation write is stable and absorbs the game's recoil for free.
local function freecamActive()
    local gui = LP:FindFirstChild("PlayerGui")
    local fc = gui and gui:FindFirstChild("Freecam")
    if not fc then return false end
    return Camera.CameraType == Enum.CameraType.Scriptable
end

local aimKeyDown = false
connect(UserInputService.InputBegan, function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton2 then aimKeyDown = true end
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then aimKeyDown = false end
end)

bind("ENT_AIM", Enum.RenderPriority.Camera.Value + 5, function(dt)
    if not Hub.running then return end

    Targeting.current = nil
    if Cfg.silent.enabled or Cfg.aimbot.enabled or Cfg.weapon.triggerbot then
        local ok, sel = pcall(Targeting.select)
        if ok then Targeting.current = sel end
    end

    if not Cfg.aimbot.enabled then return end
    if Camera.CameraType ~= Enum.CameraType.Custom then return end
    if freecamActive() then return end
    if Cfg.aimbot.hold and not aimKeyDown then return end

    local t = Targeting.current
    if not t then return end
    local pt = Targeting.aimPoint(t.char, t.part)
    if not pt then return end

    -- Rotation only. The camera position is recomputed from the subject each
    -- frame, so writing a position of our own would be discarded anyway.
    local pos = Camera.CFrame.Position
    local goal = CFrame.lookAt(pos, pt)
    local s = math.clamp(Cfg.aimbot.smooth, 0, 1)
    if s <= 0.001 then
        Camera.CFrame = goal
    else
        local alpha = math.clamp(dt / (s * 0.5 + 0.0001), 0, 1)
        Camera.CFrame = Camera.CFrame:Lerp(goal, alpha)
    end
end)

--========================================================================
-- 7. WEAPON
--========================================================================
local Weapon = {}
Hub.Weapon = Weapon

-- 7a. Extended client hit range. shootEffect raycasts .Unit * 100 when building
-- the hit list; constant 57 is that 100.
local RANGE_CONST_IDX, RANGE_CONST_ORIG = nil, 100
if shootEffect and debug and debug.getconstants then
    local ok, consts = pcall(debug.getconstants, shootEffect)
    if ok and consts then
        for i = 1, 160 do
            if consts[i] == 100 then RANGE_CONST_IDX = i break end
        end
    end
end

function Weapon.applyRange()
    if not (RANGE_CONST_IDX and shootEffect and debug and debug.setconstant) then return false end
    local v = Cfg.weapon.extRange and Cfg.weapon.extRangeV or RANGE_CONST_ORIG
    local ok = pcall(debug.setconstant, shootEffect, RANGE_CONST_IDX, v)
    return ok
end
Hub.restoreRange = function()
    if RANGE_CONST_IDX and shootEffect and debug and debug.setconstant then
        pcall(debug.setconstant, shootEffect, RANGE_CONST_IDX, RANGE_CONST_ORIG)
    end
end

-- 7b. Spread.
-- WeaponModule:1345 computes
--     hipfirePenalty = 1 / SpreadDefault / 6
--     totalSpread    = (Bloom or SpreadDefault)
--                      + (aiming and stationary and 0 or hipfirePenalty)
-- Writing SpreadDefault = 0 therefore divides by zero and gives every hipfire
-- shot an infinite cone and a NaN raycast. NEVER write zero here.
-- While aiming and stationary the game zeroes the penalty term, so a tiny base
-- is pure gain. Otherwise x + 1/(6x) is minimised at x = 1/sqrt(6).
local SPREAD_MIN_HIPFIRE = 0.4082482904638631
local spreadPatchActive = false

function Weapon.patchSpreadForShot(tool)
    if not Cfg.weapon.noSpread or spreadPatchActive then return end
    if not tool then return end
    local orig = tool:GetAttribute("SpreadDefault")
    if type(orig) ~= "number" or orig <= 0 then return end

    local aiming = tool:GetAttribute("Aiming") == true
    local bloom = tool:FindFirstChild("Bloom")
    local bloomOrig = (bloom and bloom:IsA("NumberValue")) and bloom.Value or nil

    spreadPatchActive = true
    pcall(function()
        tool:SetAttribute("SpreadDefault", aiming and 0.001 or SPREAD_MIN_HIPFIRE)
        if bloomOrig ~= nil then bloom.Value = 0 end
    end)

    -- shootEffect runs straight through FireServer without yielding, so a
    -- deferred restore lands only after the shot has been reported.
    task.defer(function()
        pcall(function()
            tool:SetAttribute("SpreadDefault", orig)
            if bloomOrig ~= nil and bloom and bloom.Parent then bloom.Value = bloomOrig end
        end)
        spreadPatchActive = false
    end)
end

function Weapon.applySpread() end
Hub.restoreSpread = function() end

-- 7c. Native bullet magnetism. bulletMagnetism is gated to touch and console;
-- the touch branch needs PlatformDetection.Mobile visible and HoverAutoFire true.
local magnetSaved = nil
local hoverSaved = nil
function Weapon.applyMagnetism()
    local gui = LP:FindFirstChild("PlayerGui")
    local gg = gui and gui:FindFirstChild("GameGui")
    local hud = gg and gg:FindFirstChild("headsUpDisplay")
    local pd = hud and hud:FindFirstChild("PlatformDetection")
    local mobile = pd and pd:FindFirstChild("Mobile")
    if not mobile then return false end
    if magnetSaved == nil then magnetSaved = mobile.Visible end
    mobile.Visible = Cfg.weapon.magnetism and true or magnetSaved
    local pc = LP:FindFirstChild("PlayerScripts")
    pc = pc and pc:FindFirstChild("PlayerClient")
    if pc then
        if hoverSaved == nil then hoverSaved = pc:GetAttribute("HoverAutoFire") end
        pcall(function()
            pc:SetAttribute("HoverAutoFire", Cfg.weapon.magnetism and true or hoverSaved)
        end)
    end
    return true
end
Hub.restoreMagnet = function()
    local gui = LP:FindFirstChild("PlayerGui")
    local gg = gui and gui:FindFirstChild("GameGui")
    local hud = gg and gg:FindFirstChild("headsUpDisplay")
    local pd = hud and hud:FindFirstChild("PlatformDetection")
    local mobile = pd and pd:FindFirstChild("Mobile")
    if mobile and magnetSaved ~= nil then pcall(function() mobile.Visible = magnetSaved end) end
    local pc = LP:FindFirstChild("PlayerScripts")
    pc = pc and pc:FindFirstChild("PlayerClient")
    if pc and hoverSaved ~= nil then
        pcall(function() pc:SetAttribute("HoverAutoFire", hoverSaved) end)
    end
end

-- 7c2. Fast fire.
-- u10.Shoot gates on state.clientCanFire, and bolt actions additionally gate on
-- state.Cycle which is normally only cleared by an animation marker. Both live
-- in the client state table, so clearing them re-arms the weapon early. The
-- server keeps its own timestamps and may rate limit independently, which is why
-- this is off by default and the multiplier starts at stock.
task.spawn(function()
    while Hub.running do
        task.wait(0.03)
        if Cfg.weapon.fastFire then
            local st = Hub.lastState
            local tool = st and st.Tool
            if tool and tool.Parent then
                local mult = math.clamp(Cfg.weapon.fireRate or 1, 0.05, 1)
                if mult < 1 then
                    pcall(function()
                        st.clientCanFire = true
                        if tool:GetAttribute("ToolType") == "Bolt Action" then
                            st.Cycle = false
                        end
                    end)
                end
            end
        end
    end
end)

-- 7d. Auto fire. Uses a real synthetic click so the game's own input path,
-- cooldowns and animations all run normally.
task.spawn(function()
    while Hub.running do
        task.wait(0.03)
        if Cfg.weapon.triggerbot and Targeting.current and EX.click
            and not (Hub.ui and Hub.ui.Enabled and Cfg.ui.freeCursor) then
            local t = Targeting.current
            local part = t.part
            -- honour the same sight rules the rest of the hub uses, otherwise the
            -- triggerbot refuses to fire whenever wallbang or no-vis-check is on
            local sighted = (not Cfg.target.visCheck) or Cfg.silent.wallbang
                or Targeting.visible(part, t.char)
            if part and sighted then
                local fire = false
                if Cfg.silent.enabled then
                    -- silent aim rewrites the shot anyway, so anything select()
                    -- has already accepted inside the cone is a valid trigger and
                    -- the crosshair does not need to be on the target at all
                    fire = true
                else
                    local origin = Camera.CFrame.Position
                    local look = Camera.CFrame.LookVector
                    local delta = part.Position - origin
                    if delta.Magnitude > 0 then
                        local ang = math.deg(math.acos(math.clamp(look:Dot(delta.Unit), -1, 1)))
                        fire = ang <= 2.5
                    end
                end
                if fire then
                    pcall(EX.click)
                    task.wait(0.08)
                end
            end
        end
    end
end)

--========================================================================
-- 8. VIEW
--========================================================================
local baseFov = Camera.FieldOfView
Hub.baseFov = baseFov

-- The game tweens FieldOfView on aim and scope. We track whatever it last wanted
-- and add our offset on top. Our own write is identified by VALUE rather than by
-- a flag, because a flag cleared on a deferred task can be cleared before the
-- change signal arrives, at which point our own output gets recorded as the
-- game's intent and the offset compounds on every pass.
local intendedFov = Camera.FieldOfView
local ourFov = nil

local fovConn
local function watchFov()
    if fovConn then pcall(function() fovConn:Disconnect() end) end
    fovConn = connect(Camera:GetPropertyChangedSignal("FieldOfView"), function()
        local v = Camera.FieldOfView
        if ourFov and math.abs(v - ourFov) < 0.001 then return end
        intendedFov = v
    end)
end
watchFov()

-- Camera is swapped on respawn and on map change. Reassigning the local updates
-- every closure that shares it, so aim, ESP and FOV all follow.
rebindCamera = function()
    local c = workspace.CurrentCamera
    if c and c ~= Camera then
        Camera = c
        intendedFov = Camera.FieldOfView
        ourFov = nil
        watchFov()
    end
end
connect(workspace:GetPropertyChangedSignal("CurrentCamera"), rebindCamera)

local function applyFov()
    if Cfg.view.camFov ~= 0 then
        local want = math.clamp(intendedFov + Cfg.view.camFov, 1, 120)
        if math.abs(Camera.FieldOfView - want) > 0.01 then
            ourFov = want
            Camera.FieldOfView = want
        end
    elseif ourFov ~= nil then
        -- offset returned to zero, hand the game's own value back once
        ourFov = nil
        Camera.FieldOfView = intendedFov
    end
end
Hub.restoreFov = function()
    pcall(function()
        if ourFov ~= nil then Camera.FieldOfView = intendedFov end
    end)
end

--========================================================================
-- 9. VISUALS (ESP + FOV ring)
--========================================================================
local espGui = track(Instance.new("ScreenGui"))
espGui.Name = "ent_visuals"
espGui.ResetOnSpawn = false
espGui.IgnoreGuiInset = true
espGui.DisplayOrder = 100
espGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
espGui.Parent = guiParent()

-- FOV ring
local fovRing = Instance.new("Frame")
fovRing.Name = "fovRing"
fovRing.AnchorPoint = Vector2.new(0.5, 0.5)
fovRing.BackgroundTransparency = 1
fovRing.BorderSizePixel = 0
fovRing.Parent = espGui
local fovCorner = Instance.new("UICorner")
fovCorner.CornerRadius = UDim.new(1, 0)
fovCorner.Parent = fovRing
local fovStroke = Instance.new("UIStroke")
fovStroke.Color = T.accent
fovStroke.Thickness = 1
fovStroke.Transparency = 0.4
fovStroke.Parent = fovRing

-- Line of sight is a raycast per enemy. At 60fps with a full server that is
-- roughly 1700 casts a second for information that changes slowly, so cache it.
local visCache = {}
local VIS_TTL = 0.12

local function cachedVisible(char, part)
    local now = tick()
    local e = visCache[char]
    if e and now - e.t < VIS_TTL then return e.v end
    local v = Targeting.visible(part, char)
    visCache[char] = { t = now, v = v }
    return v
end

--------------------------------------------------------------------
-- tag construction
--------------------------------------------------------------------
local function newLine(parent, zi)
    local f = Instance.new("Frame")
    f.BorderSizePixel = 0
    f.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    f.ZIndex = zi or 2
    f.Parent = parent
    return f
end

local function newTag()
    local holder = Instance.new("Frame")
    holder.Name = "tag"
    holder.BackgroundTransparency = 1
    holder.BorderSizePixel = 0
    holder.Visible = false
    holder.Parent = espGui

    -- eight arms make four corner brackets. Brackets read far better than a
    -- closed rectangle once the target is small on screen.
    local arms = {}
    for i = 1, 8 do arms[i] = newLine(holder, 2) end

    -- full rectangle, used when the box style is set to Box
    local rect = Instance.new("Frame")
    rect.BackgroundTransparency = 1
    rect.BorderSizePixel = 0
    rect.Size = UDim2.fromScale(1, 1)
    rect.Visible = false
    rect.ZIndex = 2
    rect.Parent = holder
    local rectStroke = Instance.new("UIStroke")
    rectStroke.Thickness = 1
    rectStroke.Parent = rect

    local nameLbl = Instance.new("TextLabel")
    nameLbl.BackgroundTransparency = 1
    nameLbl.Font = T.fontB
    nameLbl.TextSize = 13
    nameLbl.TextColor3 = T.text
    nameLbl.TextStrokeTransparency = 0.35
    nameLbl.TextStrokeColor3 = Color3.new(0, 0, 0)
    nameLbl.Size = UDim2.new(1, 160, 0, 14)
    nameLbl.Position = UDim2.new(0.5, 0, 0, -17)
    nameLbl.AnchorPoint = Vector2.new(0.5, 0)
    nameLbl.ZIndex = 3
    nameLbl.Parent = holder

    local infoLbl = nameLbl:Clone()
    infoLbl.Font = T.font
    infoLbl.TextSize = 12
    infoLbl.TextColor3 = T.dim
    infoLbl.Position = UDim2.new(0.5, 0, 1, 3)
    infoLbl.Parent = holder

    local hpBack = Instance.new("Frame")
    hpBack.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    hpBack.BackgroundTransparency = 0.3
    hpBack.BorderSizePixel = 0
    hpBack.Size = UDim2.new(0, 3, 1, 0)
    hpBack.Position = UDim2.new(0, -6, 0, 0)
    hpBack.ZIndex = 2
    hpBack.Parent = holder

    local hpFill = Instance.new("Frame")
    hpFill.BorderSizePixel = 0
    hpFill.AnchorPoint = Vector2.new(0, 1)
    hpFill.Position = UDim2.fromScale(0, 1)
    hpFill.Size = UDim2.fromScale(1, 1)
    hpFill.ZIndex = 3
    hpFill.Parent = hpBack

    local tracer = newLine(espGui, 1)
    tracer.AnchorPoint = Vector2.new(0.5, 0)
    tracer.Size = UDim2.fromOffset(1, 0)
    tracer.Visible = false

    -- off screen pointer, a short line at the edge aimed at the target
    local arrow = newLine(espGui, 4)
    arrow.AnchorPoint = Vector2.new(0.5, 0.5)
    arrow.Size = UDim2.fromOffset(3, 16)
    arrow.Visible = false

    return {
        holder = holder, arms = arms, rect = rect, rectStroke = rectStroke,
        nm = nameLbl, info = infoLbl, hpb = hpBack, hpf = hpFill,
        tr = tracer, arrow = arrow,
    }
end

local espPool = {}
local chamsPool = {}

local function setChams(char, on, colour)
    local h = chamsPool[char]
    if on then
        if not h or not h.Parent then
            h = Instance.new("Highlight")
            h.FillTransparency = 0.7
            h.OutlineTransparency = 0
            h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            h.Adornee = char
            pcall(function() h.Parent = espGui end)
            chamsPool[char] = h
            Hub.instances[#Hub.instances + 1] = h
        end
        h.FillColor = colour
        h.OutlineColor = colour
        h.Enabled = true
    elseif h then
        h.Enabled = false
    end
end

-- GetBoundingBox includes the held rifle, which made boxes roughly three times
-- too wide side on, and projecting a point behind the near plane blows the
-- rectangle up to tens of thousands of pixels. Derive from head and root, and
-- require both anchors to be in front of the camera.
local function boxRect(char)
    local root = char:FindFirstChild("HumanoidRootPart")
    local head = char:FindFirstChild("Head")
    if not (root and head) then return nil end
    local top = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, head.Size.Y, 0))
    local bot = Camera:WorldToViewportPoint(root.Position - Vector3.new(0, 3.2, 0))
    if top.Z <= 0 or bot.Z <= 0 then return nil end
    local h = math.abs(bot.Y - top.Y)
    if h < 1 or h > 6000 then return nil end
    local w = h * 0.58
    return (top.X + bot.X) * 0.5 - w * 0.5, math.min(top.Y, bot.Y), w, h
end

local function layoutCorners(tag, w, h, col, thick)
    local len = math.clamp(math.min(w, h) * 0.3, 3, 26)
    local t = thick
    local a = tag.arms
    local pts = {
        { 0, 0, len, t }, { 0, 0, t, len },                 -- top left
        { w - len, 0, len, t }, { w - t, 0, t, len },       -- top right
        { 0, h - t, len, t }, { 0, h - len, t, len },       -- bottom left
        { w - len, h - t, len, t }, { w - t, h - len, t, len }, -- bottom right
    }
    for i = 1, 8 do
        local q = pts[i]
        local f = a[i]
        f.Position = UDim2.fromOffset(q[1], q[2])
        f.Size = UDim2.fromOffset(q[3], q[4])
        f.BackgroundColor3 = col
        f.Visible = true
    end
end

local function hideArms(tag)
    for i = 1, 8 do tag.arms[i].Visible = false end
end

--------------------------------------------------------------------
-- render
--------------------------------------------------------------------
bind("ENT_VISUALS", Enum.RenderPriority.Last.Value, function()
    if not Hub.running then return end
    applyFov()

    local vp = Camera.ViewportSize
    local cx, cy = vp.X * 0.5, vp.Y * 0.5

    -- FOV ring. Shown whenever the user asks for it. It used to be gated behind
    -- aimbot or silent aim being on, which made the toggle look broken.
    fovRing.Visible = Cfg.view.fovCircle
    if Cfg.view.fovCircle then
        -- tan approaches infinity at 90 degrees, and an infinite offset wraps the
        -- int32 UDim2 and makes the ring vanish, so cap both.
        local half = math.clamp(Cfg.target.fov / 2, 0, 89)
        local r = (vp.Y / 2) * math.tan(math.rad(half))
                  / math.tan(math.rad(math.clamp(Camera.FieldOfView, 1, 120) / 2))
        r = math.clamp(r, 0, 20000)
        fovRing.Size = UDim2.fromOffset(r * 2, r * 2)
        fovRing.Position = UDim2.fromOffset(cx, cy)
    end

    local used = {}
    if Cfg.esp.enabled then
        local camPos = Camera.CFrame.Position
        local cur = Targeting.current
        local curPlayer = cur and cur.player or nil

        for _, p in ipairs(Players:GetPlayers()) do
            if Targeting.isEnemy(p) then
                local char = p.Character
                if char and Targeting.isAlive(char) and not Targeting.inLobby(char) then
                    local root = char:FindFirstChild("HumanoidRootPart")
                    local hum = getHum(char)
                    if root and hum then
                        local dist = (root.Position - camPos).Magnitude
                        if dist <= Cfg.esp.maxDist then
                            local tag = espPool[p]
                            if not tag then
                                tag = newTag()
                                espPool[p] = tag
                                Hub.instances[#Hub.instances + 1] = tag.holder
                                Hub.instances[#Hub.instances + 1] = tag.tr
                                Hub.instances[#Hub.instances + 1] = tag.arrow
                            end
                            used[p] = true

                            local aimPart = Targeting.aimPart(char) or root
                            local seen = cachedVisible(char, aimPart)

                            -- colour carries the two things worth knowing at a
                            -- glance: is this the locked target, and can it be shot
                            local col
                            if p == curPlayer then
                                col = T.accent
                            elseif seen then
                                col = T.good
                            else
                                col = T.bad
                            end

                            local bx, by, bw, bh = boxRect(char)
                            -- in front of the camera is not the same as on screen.
                            -- A target 80 degrees to the side still projects to a
                            -- valid point, just one nobody can see, so it belongs
                            -- on the pointer ring rather than as a box in limbo.
                            local onScreen = bx ~= nil
                                and (bx + bw) > 0 and bx < vp.X
                                and (by + bh) > 0 and by < vp.Y
                            if onScreen then
                                tag.holder.Visible = true
                                tag.holder.Position = UDim2.fromOffset(bx, by)
                                tag.holder.Size = UDim2.fromOffset(bw, bh)
                                tag.arrow.Visible = false

                                local thick = (p == curPlayer) and 2 or 1

                                if Cfg.esp.box then
                                    if Cfg.esp.style == "Box" then
                                        hideArms(tag)
                                        tag.rect.Visible = true
                                        tag.rectStroke.Color = col
                                        tag.rectStroke.Thickness = thick
                                    else
                                        tag.rect.Visible = false
                                        layoutCorners(tag, bw, bh, col, thick)
                                    end
                                else
                                    hideArms(tag)
                                    tag.rect.Visible = false
                                end

                                -- text shrinks with distance so a busy server stays readable
                                local ts = math.clamp(14 - dist / 220, 9, 14)

                                tag.nm.Visible = Cfg.esp.name
                                if Cfg.esp.name then
                                    tag.nm.Text = (p.DisplayName ~= "" and p.DisplayName or p.Name)
                                    tag.nm.TextColor3 = col
                                    tag.nm.TextSize = ts
                                    tag.nm.Position = UDim2.new(0.5, 0, 0, -(ts + 4))
                                end

                                local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)

                                tag.info.Visible = Cfg.esp.dist or Cfg.esp.hpText
                                if tag.info.Visible then
                                    local bits = ""
                                    if Cfg.esp.dist then bits = string.format("%dm", math.floor(dist)) end
                                    if Cfg.esp.hpText then
                                        if bits ~= "" then bits = bits .. "  " end
                                        bits = bits .. string.format("%d hp", math.floor(hum.Health))
                                    end
                                    tag.info.Text = bits
                                    tag.info.TextSize = math.max(ts - 1, 9)
                                end

                                tag.hpb.Visible = Cfg.esp.health
                                if Cfg.esp.health then
                                    tag.hpf.Size = UDim2.fromScale(1, frac)
                                    tag.hpf.BackgroundColor3 = T.good:Lerp(T.bad, 1 - frac)
                                end

                                if Cfg.esp.tracer then
                                    local tx, ty = bx + bw * 0.5, by + bh
                                    local dx, dy = tx - cx, ty - vp.Y
                                    local len = math.sqrt(dx * dx + dy * dy)
                                    tag.tr.Visible = true
                                    tag.tr.BackgroundColor3 = col
                                    tag.tr.Position = UDim2.fromOffset(cx, vp.Y)
                                    tag.tr.Size = UDim2.fromOffset(1, len)
                                    tag.tr.Rotation = math.deg(math.atan2(dy, dx)) - 90
                                else
                                    tag.tr.Visible = false
                                end

                                setChams(char, Cfg.esp.chams, col)

                            elseif Cfg.esp.offscreen then
                                -- behind us or off to the side: park a pointer on a
                                -- ring around the crosshair aimed the right way
                                tag.holder.Visible = false
                                tag.tr.Visible = false
                                local rel = Camera.CFrame:PointToObjectSpace(root.Position)
                                local ang = math.atan2(rel.X, -rel.Z)
                                if rel.Z > 0 then ang = math.atan2(rel.X, rel.Z) + math.pi end
                                local rad = math.min(vp.X, vp.Y) * 0.32
                                tag.arrow.Visible = true
                                tag.arrow.BackgroundColor3 = col
                                tag.arrow.Position = UDim2.fromOffset(
                                    cx + math.sin(ang) * rad, cy - math.cos(ang) * rad)
                                tag.arrow.Rotation = math.deg(ang)
                                setChams(char, Cfg.esp.chams, col)
                            else
                                tag.holder.Visible = false
                                tag.tr.Visible = false
                                tag.arrow.Visible = false
                            end
                        end
                    end
                end
            end
        end
    end

    for p, tag in pairs(espPool) do
        if not used[p] then
            tag.holder.Visible = false
            tag.tr.Visible = false
            tag.arrow.Visible = false
            if p.Character then setChams(p.Character, false) end
        end
    end
end)

-- Without this the pools keep a Player or Character reference for every person
-- who has ever been in the server, and the per frame sweep walks all of them.
local function dropPlayer(p)
    local tag = espPool[p]
    if tag then
        pcall(function() tag.holder:Destroy() end)
        pcall(function() tag.tr:Destroy() end)
        pcall(function() tag.arrow:Destroy() end)
        espPool[p] = nil
    end
end
connect(Players.PlayerRemoving, function(p)
    dropPlayer(p)
    local c = p.Character
    if c and chamsPool[c] then
        pcall(function() chamsPool[c]:Destroy() end)
        chamsPool[c] = nil
    end
end)

task.spawn(function()
    while Hub.running do
        task.wait(5)
        for char, hl in pairs(chamsPool) do
            if not char.Parent then
                pcall(function() hl:Destroy() end)
                chamsPool[char] = nil
            end
        end
        for char in pairs(visCache) do
            if not char.Parent then visCache[char] = nil end
        end
    end
end)

--========================================================================
-- 10. UI
--========================================================================
local ui = track(Instance.new("ScreenGui"))
ui.Name = "ent_ui"
ui.ResetOnSpawn = false
ui.IgnoreGuiInset = true
ui.DisplayOrder = 999
ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ui.Parent = guiParent()
Hub.ui = ui

local function corner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = p
    return c
end
local function stroke(p, col, th)
    local s = Instance.new("UIStroke")
    s.Color = col or T.stroke
    s.Thickness = th or 1
    s.Parent = p
    return s
end

local root = Instance.new("Frame")
root.Name = "root"
root.Size = UDim2.fromOffset(660, 474)
root.Position = UDim2.new(0, 60, 0.5, -237)
root.BackgroundColor3 = T.bg
root.BorderSizePixel = 0
root.Active = true
root.Parent = ui
corner(root, 8)
stroke(root)

-- header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundColor3 = T.panel
header.BorderSizePixel = 0
header.Parent = root
corner(header, 8)
local hdrFix = Instance.new("Frame")
hdrFix.Size = UDim2.new(1, 0, 0, 10)
hdrFix.Position = UDim2.new(0, 0, 1, -10)
hdrFix.BackgroundColor3 = T.panel
hdrFix.BorderSizePixel = 0
hdrFix.Parent = header

local dot = Instance.new("Frame")
dot.Size = UDim2.fromOffset(6, 6)
dot.Position = UDim2.new(0, 16, 0.5, -3)
dot.BackgroundColor3 = T.accent
dot.BorderSizePixel = 0
dot.Parent = header
corner(dot, 3)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Font = T.fontB
title.TextSize = 14
title.TextColor3 = T.text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "ENTRENCHED"
title.Position = UDim2.new(0, 32, 0, 0)
title.Size = UDim2.new(0, 200, 1, 0)
title.Parent = header

local sub = Instance.new("TextLabel")
sub.BackgroundTransparency = 1
sub.Font = T.font
sub.TextSize = 11
sub.TextColor3 = T.dim
sub.TextXAlignment = Enum.TextXAlignment.Left
sub.Text = "v" .. Hub.version
sub.Position = UDim2.new(0, 124, 0, 0)
sub.Size = UDim2.new(0, 80, 1, 0)
sub.Parent = header

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(28, 24)
minBtn.Position = UDim2.new(1, -38, 0.5, -12)
minBtn.BackgroundColor3 = T.raised
minBtn.BorderSizePixel = 0
minBtn.Font = T.fontB
minBtn.TextSize = 14
minBtn.TextColor3 = T.dim
minBtn.Text = "-"
minBtn.AutoButtonColor = false
minBtn.Parent = header
corner(minBtn, 5)

-- body
-- Drag from the header only. Making the whole window a drag handle fights the
-- sliders, which live inside it.
do
    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = i.Position
            startPos = root.Position
        end
    end)
    connect(UserInputService.InputChanged, function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                      startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    connect(UserInputService.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

local body = Instance.new("Frame")
body.Size = UDim2.new(1, 0, 1, -40)
body.Position = UDim2.new(0, 0, 0, 40)
body.BackgroundTransparency = 1
body.Parent = root

local rail = Instance.new("Frame")
rail.Size = UDim2.new(0, 140, 1, 0)
rail.BackgroundTransparency = 1
rail.Parent = body
local railList = Instance.new("UIListLayout")
railList.Padding = UDim.new(0, 2)
railList.Parent = rail
local railPad = Instance.new("UIPadding")
railPad.PaddingLeft = UDim.new(0, 12)
railPad.PaddingTop = UDim.new(0, 10)
railPad.PaddingRight = UDim.new(0, 6)
railPad.Parent = rail

local divider = Instance.new("Frame")
divider.Size = UDim2.new(0, 1, 1, -20)
divider.Position = UDim2.new(0, 140, 0, 10)
divider.BackgroundColor3 = T.stroke
divider.BorderSizePixel = 0
divider.Parent = body

local pages = {}
local tabBtns = {}
local activeTab

local function makePage(name)
    local sc = Instance.new("ScrollingFrame")
    sc.Size = UDim2.new(1, -156, 1, -16)
    sc.Position = UDim2.new(0, 149, 0, 8)
    sc.BackgroundTransparency = 1
    sc.BorderSizePixel = 0
    sc.ScrollBarThickness = 2
    sc.ScrollBarImageColor3 = T.stroke
    sc.CanvasSize = UDim2.new()
    sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sc.Visible = false
    sc.Parent = body
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 6)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = sc
    local pd = Instance.new("UIPadding")
    pd.PaddingRight = UDim.new(0, 10)
    pd.PaddingBottom = UDim.new(0, 10)
    pd.Parent = sc
    pages[name] = sc
    return sc
end

local function selectTab(name)
    activeTab = name
    for n, pg in pairs(pages) do pg.Visible = (n == name) end
    for n, b in pairs(tabBtns) do
        b.TextColor3 = (n == name) and T.text or T.dim
        b.BackgroundTransparency = (n == name) and 0 or 1
    end
end

local function makeTab(name)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 32)
    b.BackgroundColor3 = T.panel
    b.BackgroundTransparency = 1
    b.BorderSizePixel = 0
    b.Font = T.font
    b.TextSize = 13
    b.TextColor3 = T.dim
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.Text = "   " .. name
    b.AutoButtonColor = false
    b.Parent = rail
    corner(b, 5)
    tabBtns[name] = b
    makePage(name)
    b.MouseButton1Click:Connect(function() selectTab(name) end)
    return b
end

-- widgets
local function row(page, h)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, h or 36)
    f.BackgroundColor3 = T.panel
    f.BorderSizePixel = 0
    f.Parent = page
    corner(f, 6)
    return f
end

local function label(parent, text, size, col, x)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Font = T.font
    l.TextSize = size or 13
    l.TextColor3 = col or T.text
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = text
    l.Position = UDim2.new(0, x or 12, 0, 0)
    l.Size = UDim2.new(1, -(x or 12) - 60, 1, 0)
    l.Parent = parent
    return l
end

-- Every widget registers its render function. One control can change a value
-- another control displays (Ignore line of sight force-enables Fabricate), so a
-- change must repaint all of them or the panel starts lying about its own state.
local RENDERERS = {}
local function refreshAll()
    for _, fn in ipairs(RENDERERS) do pcall(fn) end
end
Hub.refreshAll = refreshAll

local function mkToggle(page, text, get, set)
    local f = row(page)
    label(f, text)
    local sw = Instance.new("TextButton")
    sw.Size = UDim2.fromOffset(34, 18)
    sw.Position = UDim2.new(1, -46, 0.5, -9)
    sw.BackgroundColor3 = T.raised
    sw.BorderSizePixel = 0
    sw.Text = ""
    sw.AutoButtonColor = false
    sw.Parent = f
    corner(sw, 9)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(12, 12)
    knob.Position = UDim2.new(0, 3, 0.5, -6)
    knob.BackgroundColor3 = T.dim
    knob.BorderSizePixel = 0
    knob.Parent = sw
    corner(knob, 6)

    local function render()
        local on = get()
        sw.BackgroundColor3 = on and T.accent or T.raised
        knob.BackgroundColor3 = on and Color3.fromRGB(20, 20, 20) or T.dim
        knob.Position = on and UDim2.new(1, -15, 0.5, -6) or UDim2.new(0, 3, 0.5, -6)
    end
    sw.MouseButton1Click:Connect(function()
        set(not get())
        refreshAll()
        saveCfg()
    end)
    RENDERERS[#RENDERERS + 1] = render
    render()
    return f, render
end

local function mkSlider(page, text, min, max, get, set, suffix, decimals)
    local f = row(page, 46)
    local l = label(f, text)
    l.Size = UDim2.new(1, -90, 0, 22)
    l.Position = UDim2.new(0, 12, 0, 4)

    local val = Instance.new("TextLabel")
    val.BackgroundTransparency = 1
    val.Font = T.font
    val.TextSize = 13
    val.TextColor3 = T.accent
    val.TextXAlignment = Enum.TextXAlignment.Right
    val.Position = UDim2.new(1, -54, 0, 4)
    val.Size = UDim2.fromOffset(42, 22)
    val.Parent = f

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -24, 0, 3)
    track.Position = UDim2.new(0, 12, 1, -14)
    track.BackgroundColor3 = T.raised
    track.BorderSizePixel = 0
    track.Parent = f
    corner(track, 2)

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = T.accent
    fill.BorderSizePixel = 0
    fill.Size = UDim2.fromScale(0, 1)
    fill.Parent = track
    corner(fill, 2)

    local hit = Instance.new("TextButton")
    hit.BackgroundTransparency = 1
    hit.Text = ""
    hit.Size = UDim2.new(1, 0, 0, 20)
    hit.Position = UDim2.new(0, 0, 1, -22)
    hit.Parent = f

    local function render()
        local v = get()
        local a = (max > min) and math.clamp((v - min) / (max - min), 0, 1) or 0
        fill.Size = UDim2.fromScale(a, 1)
        val.Text = string.format("%." .. (decimals or 0) .. "f", v) .. (suffix or "")
    end

    -- Drag state must start from this slider's own hit area. Reading the global
    -- mouse location is wrong here because the game locks the cursor to the
    -- centre of the screen during play, which would slam every slider to an end.
    local dragging = false
    local function apply(px)
        local w = track.AbsoluteSize.X
        if w < 10 then return end
        local a = math.clamp((px - track.AbsolutePosition.X) / w, 0, 1)
        local v = min + (max - min) * a
        local d = decimals or 0
        if d == 0 then
            v = math.floor(v + 0.5)
        else
            -- quantise to what the label shows, or the saved config and the
            -- displayed value drift apart
            local m = 10 ^ d
            v = math.floor(v * m + 0.5) / m
        end
        set(v)
        render()
        saveCfg()
    end

    hit.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            apply(i.Position.X)
        end
    end)
    hit.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    connect(UserInputService.InputChanged, function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            apply(i.Position.X)
        end
    end)
    connect(UserInputService.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    RENDERERS[#RENDERERS + 1] = render
    render()
    return f, render
end

local function mkCycle(page, text, options, get, set)
    local f = row(page)
    label(f, text)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(120, 22)
    b.Position = UDim2.new(1, -132, 0.5, -11)
    b.BackgroundColor3 = T.raised
    b.BorderSizePixel = 0
    b.Font = T.font
    b.TextSize = 12
    b.TextColor3 = T.text
    b.AutoButtonColor = false
    b.Parent = f
    corner(b, 5)
    local function render() b.Text = tostring(get()) end
    b.MouseButton1Click:Connect(function()
        local cur, idx = get(), 1
        for i, o in ipairs(options) do if o == cur then idx = i break end end
        set(options[(idx % #options) + 1])
        refreshAll()
        saveCfg()
    end)
    RENDERERS[#RENDERERS + 1] = render
    render()
    return f, render
end

local TextService = game:GetService("TextService")
local NOTE_W = 484

-- TextBounds is unreliable before a frame has rendered and AutomaticSize inside a
-- ScrollingFrame collapses the row, so measure explicitly instead.
local function mkNote(page, text)
    local f = Instance.new("TextLabel")
    f.BackgroundTransparency = 1
    f.Font = T.font
    f.TextSize = 12
    f.TextColor3 = T.dim
    f.TextXAlignment = Enum.TextXAlignment.Left
    f.TextYAlignment = Enum.TextYAlignment.Top
    f.TextWrapped = true
    f.Text = text
    local h = 24
    local ok, sz = pcall(function()
        return TextService:GetTextSize(text, 12, T.font, Vector2.new(NOTE_W, 10000))
    end)
    if ok and sz then h = sz.Y + 6 end
    f.Size = UDim2.new(1, 0, 0, h)
    f.Parent = page
    return f
end

local function mkHeading(page, text)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 22)
    l.BackgroundTransparency = 1
    l.Font = T.fontB
    l.TextSize = 12
    l.TextColor3 = T.dim
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = string.upper(text)
    l.Parent = page
    return l
end

--========================================================================
-- 11. PAGES
--========================================================================
makeTab("Aim")
makeTab("Visuals")
makeTab("Weapon")
makeTab("Settings")

local pAim = pages["Aim"]
mkHeading(pAim, "Silent aim")
mkToggle(pAim, "Silent aim", function() return Cfg.silent.enabled end,
    function(v) Cfg.silent.enabled = v end)
mkToggle(pAim, "Fabricate hit list", function() return Cfg.silent.fabricate end,
    function(v) Cfg.silent.fabricate = v end)
mkToggle(pAim, "Ignore line of sight", function() return Cfg.silent.wallbang end,
    function(v)
        Cfg.silent.wallbang = v
        if v then Cfg.silent.fabricate = true end
    end)
mkSlider(pAim, "Hit stacking", 1, 8, function() return Cfg.weapon.stackHits end,
    function(v) Cfg.weapon.stackHits = v end, "x", 0)
mkNote(pAim, "Hit stacking repeats each pellet in the reported hit list. Above 1x the client claims more hits than the weapon has pellets, which is the most obvious thing this hub can send. Leave it at 1 unless you are testing.")
mkNote(pAim, "Silent aim alone redirects the shot through the game's own code, so every value it reports stays consistent. Fabricate is only needed for wallbang.")

mkHeading(pAim, "Aimbot")
mkToggle(pAim, "Camera aimbot", function() return Cfg.aimbot.enabled end,
    function(v) Cfg.aimbot.enabled = v end)
mkToggle(pAim, "Only while right mouse held", function() return Cfg.aimbot.hold end,
    function(v) Cfg.aimbot.hold = v end)
mkSlider(pAim, "Smoothing", 0, 1, function() return Cfg.aimbot.smooth end,
    function(v) Cfg.aimbot.smooth = v end, "", 2)

mkHeading(pAim, "Targeting")
mkSlider(pAim, "Field of view", 0, 179, function() return Cfg.target.fov end,
    function(v) Cfg.target.fov = v end, " deg", 0)
mkCycle(pAim, "Aim at", { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso", "Nearest" },
    function() return Cfg.target.part end, function(v) Cfg.target.part = v end)
mkNote(pAim, "Measured live: a head hit deals 1.5x, torso 1.0x and limbs 0.7x. With a Mosin that makes the head a one shot kill, so Head is the default.")
mkToggle(pAim, "Visibility check", function() return Cfg.target.visCheck end,
    function(v) Cfg.target.visCheck = v end)
mkToggle(pAim, "Lead moving targets", function() return Cfg.target.predict end,
    function(v) Cfg.target.predict = v end)
mkSlider(pAim, "Max distance", 0, 2000, function() return Cfg.target.maxDist end,
    function(v) Cfg.target.maxDist = v end, " m", 0)

local pVis = pages["Visuals"]
mkHeading(pVis, "Enemy ESP")
mkToggle(pVis, "Enable ESP", function() return Cfg.esp.enabled end,
    function(v) Cfg.esp.enabled = v end)
mkToggle(pVis, "Box", function() return Cfg.esp.box end, function(v) Cfg.esp.box = v end)
mkToggle(pVis, "Name", function() return Cfg.esp.name end, function(v) Cfg.esp.name = v end)
mkToggle(pVis, "Distance", function() return Cfg.esp.dist end, function(v) Cfg.esp.dist = v end)
mkToggle(pVis, "Health bar", function() return Cfg.esp.health end, function(v) Cfg.esp.health = v end)
mkToggle(pVis, "Tracers", function() return Cfg.esp.tracer end, function(v) Cfg.esp.tracer = v end)
mkToggle(pVis, "Chams", function() return Cfg.esp.chams end, function(v) Cfg.esp.chams = v end)
mkToggle(pVis, "Health number", function() return Cfg.esp.hpText end, function(v) Cfg.esp.hpText = v end)
mkToggle(pVis, "Off screen pointers", function() return Cfg.esp.offscreen end,
    function(v) Cfg.esp.offscreen = v end)
mkCycle(pVis, "Box style", { "Corners", "Box" },
    function() return Cfg.esp.style end, function(v) Cfg.esp.style = v end)
mkSlider(pVis, "ESP distance", 0, 2000, function() return Cfg.esp.maxDist end,
    function(v) Cfg.esp.maxDist = v end, " m", 0)
mkNote(pVis, "Enemies only. Downed, respawning and lobby players are filtered out. Green means you have a clear shot, red means something is in the way, and gold is the target silent aim is currently locked onto.")

mkHeading(pVis, "Overlay")
mkToggle(pVis, "Show field of view ring", function() return Cfg.view.fovCircle end,
    function(v) Cfg.view.fovCircle = v end)

local pWep = pages["Weapon"]
mkHeading(pWep, "Range")
mkToggle(pWep, "Extended hit range", function() return Cfg.weapon.extRange end,
    function(v) Cfg.weapon.extRange = v Weapon.applyRange() end)
mkSlider(pWep, "Hit range", 100, 1000, function() return Cfg.weapon.extRangeV end,
    function(v) Cfg.weapon.extRangeV = v Weapon.applyRange() end, " m", 0)
mkNote(pWep, "Leave this off unless you are testing. The server already resolves long range shots by itself, so this adds very little, and raising it makes the game report every ally your shot passes through. Friendly hits are now stripped before they are sent, but the server still sees the longer range.")

mkHeading(pWep, "Handling")
mkToggle(pWep, "Remove spread", function() return Cfg.weapon.noSpread end,
    function(v) Cfg.weapon.noSpread = v Weapon.applySpread() end)
mkToggle(pWep, "Native bullet magnetism", function() return Cfg.weapon.magnetism end,
    function(v) Cfg.weapon.magnetism = v Weapon.applyMagnetism() end)
mkToggle(pWep, "Auto fire", function() return Cfg.weapon.triggerbot end,
    function(v) Cfg.weapon.triggerbot = v end)
mkNote(pWep, "With silent aim on, auto fire shoots at anything inside the aim cone without needing the crosshair on it. Turn silent aim off first if you want it to behave like a normal triggerbot.")

mkHeading(pWep, "Rate of fire")
mkToggle(pWep, "Fast fire", function() return Cfg.weapon.fastFire end,
    function(v) Cfg.weapon.fastFire = v end)
mkSlider(pWep, "Fire delay", 0.05, 1, function() return Cfg.weapon.fireRate end,
    function(v) Cfg.weapon.fireRate = v end, "x", 2)
mkNote(pWep, "Clears the client cooldown and the bolt cycle early. The server keeps its own timing and may simply ignore the extra shots, so walk the slider down from 1 rather than dropping it to the bottom.")
mkNote(pWep, "Magnetism turns on the aim assist the game already ships for touch players. It uses the game's own code path.")

local pSet = pages["Settings"]
mkHeading(pSet, "View")
mkSlider(pSet, "Field of view offset", -30, 40, function() return Cfg.view.camFov end,
    function(v) Cfg.view.camFov = v end, "", 0)
mkNote(pSet, "This is added on top of whatever the game wants the camera to be, so aiming and scoping keep working normally.")

mkHeading(pSet, "Panel")
mkToggle(pSet, "Free the cursor while panel is open", function() return Cfg.ui.freeCursor end,
    function(v)
        Cfg.ui.freeCursor = v
        if Hub.updateCursor then Hub.updateCursor() end
    end)
mkToggle(pSet, "Auto save settings", function() return Cfg.ui.autoSave end,
    function(v)
        Cfg.ui.autoSave = v
        -- force the write either way, otherwise switching this off is the one
        -- change that can never be recorded
        if Hub.saveCfg then Hub.saveCfg(true) end
    end)
mkNote(pSet, "Right Shift hides and shows this window. The minus button in the header collapses it to the title bar. Drag the header to move it. Settings are written to EntrenchedHub_Config.json and reloaded automatically.")
mkNote(pSet, "Turn the cursor option off if you would rather keep mouse look and shift lock while the panel is visible. The panel will not be clickable then.")

local statusRow = row(pSet, 34)
local statusLbl = label(statusRow, "Target: none")
statusLbl.TextSize = 12
statusLbl.TextColor3 = T.dim

selectTab("Aim")

--========================================================================
-- 12. MINIMISE / VISIBILITY
--========================================================================
local minimised = false
local fullSize = root.Size

minBtn.MouseButton1Click:Connect(function()
    minimised = not minimised
    body.Visible = not minimised
    divider.Visible = not minimised
    root.Size = minimised and UDim2.fromOffset(fullSize.X.Offset, 40) or fullSize
    minBtn.Text = minimised and "+" or "-"
    if Hub.updateCursor then Hub.updateCursor() end
end)

connect(UserInputService.InputBegan, function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        ui.Enabled = not ui.Enabled
        if Hub.updateCursor then Hub.updateCursor() end
    end
end)

-- The game locks the cursor to screen centre every frame, so the panel cannot be
-- clicked unless we override that. Two rules keep shift lock working normally:
-- the override is only bound while the panel is actually open, and we never
-- force a value back on close. Not writing is enough, because the game's camera
-- module reasserts its own MouseBehavior on the very next frame.
local cursorBound = false
local iconSaved = nil

local function updateCursor()
    local want = Cfg.ui.freeCursor and ui.Enabled and not minimised
    if want and not cursorBound then
        cursorBound = true
        if iconSaved == nil then iconSaved = UserInputService.MouseIconEnabled end
        bind("ENT_CURSOR", Enum.RenderPriority.Last.Value + 1, function()
            if not Hub.running then return end
            if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
                UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            end
            if not UserInputService.MouseIconEnabled then
                UserInputService.MouseIconEnabled = true
            end
        end)
    elseif (not want) and cursorBound then
        cursorBound = false
        pcall(function() RunService:UnbindFromRenderStep("ENT_CURSOR") end)
        -- MouseBehavior is left alone on purpose so the game reclaims it, but the
        -- cursor icon is ours to hand back or it stays drawn over the game.
        if iconSaved ~= nil then
            pcall(function() UserInputService.MouseIconEnabled = iconSaved end)
            iconSaved = nil
        end
    end
end
Hub.updateCursor = updateCursor

Hub.releaseCursor = function()
    pcall(function() RunService:UnbindFromRenderStep("ENT_CURSOR") end)
end

updateCursor()

--========================================================================
-- 13. RUNTIME LOOPS
--========================================================================
task.spawn(function()
    while Hub.running do
        task.wait(0.4)
        pcall(Weapon.applySpread)
        pcall(refreshMyGroup)
        pcall(function()
            local t = Targeting.current
            local st = Hub.stats
            statusLbl.Text = string.format("%s   |   shots %d, redirected %d, hits %d (%d head), kills %d, ff blocked %d",
                t and ("Target: " .. (t.player.DisplayName ~= "" and t.player.DisplayName or t.player.Name))
                  or "Target: none",
                st.shots, st.redirects, st.hits, st.heads, st.kills, st.friendlyBlocked or 0)
        end)
    end
end)

connect(LP.CharacterAdded, function()
    task.wait(1)
    pcall(Weapon.applyRange)
    pcall(Weapon.applyMagnetism)
end)

--========================================================================
-- 13b. HIT TELEMETRY
-- ClientEvents.Hit fires to the attacker once per damaging hit and carries the
-- part that actually took the damage, which is the only honest confirmation
-- that a redirected shot landed.
--========================================================================
do
    local hitEv = CE:FindFirstChild("Hit")
    if hitEv and hitEv:IsA("RemoteEvent") then
        connect(hitEv.OnClientEvent, function(hum, part, dmg, _kind)
            local st = Hub.stats
            st.hits = st.hits + 1
            local pn = (typeof(part) == "Instance") and part.Name or "?"
            if pn == "Head" then st.heads = st.heads + 1 end
            if type(dmg) == "number" then st.dmg = st.dmg + dmg end
            st.last = pn .. " " .. (type(dmg) == "number" and string.format("%.0f", dmg) or "?")
        end)
    end
    local killEv = CE:FindFirstChild("Kill")
    if killEv and killEv:IsA("RemoteEvent") then
        connect(killEv.OnClientEvent, function(_p, kind)
            if tostring(kind) == "Kill" then Hub.stats.kills = Hub.stats.kills + 1 end
        end)
    end
end

--========================================================================
-- 14. BOOT
--========================================================================
pcall(Weapon.applyRange)
pcall(Weapon.applySpread)
pcall(Weapon.applyMagnetism)
pcall(function() if Hub.updateCursor then Hub.updateCursor() end end)

local ready = {}
ready[#ready + 1] = "WeaponModule " .. (WeaponModule and "ok" or "missing")
ready[#ready + 1] = "Crosshair hook " .. (Hub.restoreCrosshair and "ok" or "unavailable")
ready[#ready + 1] = "range constant " .. (RANGE_CONST_IDX and ("index " .. RANGE_CONST_IDX) or "not found")
ready[#ready + 1] = "config " .. (cfgLoaded and "restored" or "defaults")
print("[ENTRENCHED HUB] " .. table.concat(ready, ", "))

Hub.Targeting = Targeting
Hub.Weapon = Weapon
Hub.Aim = Aim
return Hub
