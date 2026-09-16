-- ==== en_00_boot.lua ====
--[[
    ENTRENCHED HUB  v2
    Place 3678761576, ENTRENCHED by Edot.

    Built from numbered parts. Every part after this one is a do ... end block
    that reaches shared state through the single table E. Execute the BUILT file,
    never a part on its own.

    Ground truth this build rests on, all measured on a live client:
      - The fire remote is ServerEvents.Shoot:FireServer(state, aimPoint, aiming,
        missedCount, hitList, cameraPos). The server raycasts every shot itself
        from the camera to aimPoint and re-checks line of sight for hit list
        entries, so controlling aimPoint is the whole game. Wallbang is impossible.
      - Redirecting the WeaponModule global Crosshair makes the game aim itself:
        238 shots, 72 hits, 42 headshots, 39 kills in one session.
      - Head 1.5x, torso 1.0x, limbs 0.7x.
      - Replicated velocity is honest in this game (observed over reported 0.99).
      - The server sets the Tool's CanFire attribute false after every shot and
        replicates it, so the true fire rate ceiling is readable from the client.
]]

local E = {}

do
    local G = getgenv()

    ------------------------------------------------------------------------
    -- Tear down whatever was here before. Covers this build AND the original
    -- single file hub, whose hooks cannot be removed but go inert once its
    -- `running` flag is false.
    ------------------------------------------------------------------------
    local prev = rawget(G, "__ENTRENCHED")
    if type(prev) == "table" and type(prev.unload) == "function" then
        pcall(prev.unload, "reload")
    end

    local v1 = rawget(G, "__ENTRENCHED_HUB")
    if type(v1) == "table" then
        pcall(function() v1.running = false end)
        for _, c in ipairs(v1.conns or {}) do pcall(function() c:Disconnect() end) end
        for _, b in ipairs(v1.binds or {}) do
            pcall(function() game:GetService("RunService"):UnbindFromRenderStep(b) end)
        end
        for _, i in ipairs(v1.instances or {}) do pcall(function() i:Destroy() end) end
        for _, k in ipairs({ "restoreCrosshair", "restoreRange", "restoreSpread",
                             "restoreMagnet", "releaseCursor", "restoreFov" }) do
            pcall(function() if v1[k] then v1[k]() end end)
        end
        G.__ENTRENCHED_HUB = nil
    end

    E.G       = G          -- the executor's shared environment, captured once
    E.version = "2.0.0"
    E.alive   = true
    E.faults  = {}
    E.cap     = {}
    G.__ENTRENCHED = E

    ------------------------------------------------------------------------
    -- Services
    ------------------------------------------------------------------------
    local function svc(n) return game:GetService(n) end
    E.Players      = svc("Players")
    E.RunService   = svc("RunService")
    E.UIS          = svc("UserInputService")
    E.RS           = svc("ReplicatedStorage")
    E.TextService  = svc("TextService")
    E.HttpService  = svc("HttpService")
    E.Lighting     = svc("Lighting")
    E.Stats        = svc("Stats")
    E.Teams        = svc("Teams")
    E.GuiService   = svc("GuiService")
    E.LP           = E.Players.LocalPlayer

    ------------------------------------------------------------------------
    -- Executor capabilities. Referencing a missing global in Luau yields nil,
    -- so each is probed through getgenv and only kept if it is callable.
    ------------------------------------------------------------------------
    local X = {}
    for _, name in ipairs({
        "hookfunction", "restorefunction", "getconnections", "getgc", "islclosure",
        "gethui", "writefile", "readfile", "isfile", "isfolder", "makefolder",
        "delfile", "getcustomasset", "cloneref",
        "hookmetamethod", "newcclosure", "getnamecallmethod", "checkcaller",
        "fireproximityprompt", "request",
    }) do
        local ok, v = pcall(function() return G[name] end)
        if ok and type(v) == "function" then X[name] = v end
    end
    E.X = X

    ------------------------------------------------------------------------
    -- Fault capture. Every call that touches game code goes through E.try so a
    -- failure is recorded with a label instead of silently killing a loop, and
    -- each label warns once so a per frame error cannot flood the console.
    ------------------------------------------------------------------------
    local warned = {}
    function E.fault(label, err)
        local msg = tostring(err)
        E.faults[#E.faults + 1] = label .. ": " .. msg
        if #E.faults > 60 then table.remove(E.faults, 1) end
        if not warned[label] then
            warned[label] = true
            warn("[Entrenched] " .. label .. ": " .. msg)
        end
    end

    function E.try(label, fn, ...)
        local ok, a, b, c = pcall(fn, ...)
        if not ok then E.fault(label, a) return false end
        return true, a, b, c
    end

    ------------------------------------------------------------------------
    -- Maid. Cleanup is registered at the moment something is created, so
    -- unload never has to know what exists. Runs in reverse order.
    ------------------------------------------------------------------------
    local tasks = {}
    function E.own(item)
        tasks[#tasks + 1] = item
        return item
    end

    function E.connect(signal, fn)
        local ok, conn = pcall(function() return signal:Connect(fn) end)
        if ok and conn then tasks[#tasks + 1] = conn return conn end
        E.fault("connect", conn)
        return nil
    end

    local binds = {}
    function E.bind(name, priority, fn)
        pcall(function() E.RunService:UnbindFromRenderStep(name) end)
        local ok, err = pcall(function() E.RunService:BindToRenderStep(name, priority, fn) end)
        if not ok then E.fault("bind " .. name, err) return end
        binds[name] = true
    end
    function E.unbind(name)
        pcall(function() E.RunService:UnbindFromRenderStep(name) end)
        binds[name] = nil
    end

    -- A loop that dies with the hub. `fn` returns the seconds to wait next.
    function E.loop(label, fn)
        task.spawn(function()
            while E.alive do
                local ok, wait = pcall(fn)
                if not ok then E.fault(label, wait) wait = 1 end
                task.wait(type(wait) == "number" and wait or 0.1)
            end
        end)
    end

    -- Event bus. Features emit, the interface listens, and neither needs to know
    -- the other exists or which was built first.
    local listeners = {}
    function E.on(name, fn)
        listeners[name] = listeners[name] or {}
        table.insert(listeners[name], fn)
    end
    function E.emit(name, ...)
        for _, fn in ipairs(listeners[name] or {}) do E.try("event " .. name, fn, ...) end
    end

    local unloadHooks = {}
    function E.onUnload(fn) unloadHooks[#unloadHooks + 1] = fn end

    function E.unload(reason)
        if not E.alive then return end
        E.alive = false
        for i = #unloadHooks, 1, -1 do pcall(unloadHooks[i], reason) end
        for name in pairs(binds) do
            pcall(function() E.RunService:UnbindFromRenderStep(name) end)
        end
        for i = #tasks, 1, -1 do
            local t = tasks[i]
            local ty = typeof(t)
            if ty == "RBXScriptConnection" then pcall(function() t:Disconnect() end)
            elseif ty == "Instance" then pcall(function() t:Destroy() end)
            elseif ty == "function" then pcall(t)
            end
        end
        table.clear(tasks)
        if rawget(G, "__ENTRENCHED") == E then G.__ENTRENCHED = nil end
    end

    ------------------------------------------------------------------------
    -- Game check. Reserved and private servers carry a different PlaceId but
    -- the same GameId, so accept either.
    ------------------------------------------------------------------------
    E.PLACE_ID, E.GAME_ID = 3678761576, 1281592938
    E.inGame = (game.PlaceId == E.PLACE_ID) or (game.GameId == E.GAME_ID)
    if not E.inGame then
        warn("[Entrenched] This hub is built for ENTRENCHED. Game features are disabled here.")
    end

    function E.clock() return os.clock() end
end

-- ==== en_01_config.lua ====
-- en_01_config: versioned settings, dotted-path access, change watchers, saving.
do
    E.CFG_VERSION = 2
    E.CFG_FILE = "EntrenchedHub_Config.json"

    -- Every key here has a control in the panel. Nothing outside this table is
    -- ever read back from disk, so a stale file cannot quietly change behaviour.
    E.DEFAULTS = {
        aim = {
            silent    = true,
            part      = "Head",       -- Head | Torso | Closest
            fov       = 25,           -- degrees
            maxDist   = 2000,
            visible   = true,         -- require a clear line from the camera
            predict   = true,
            priority  = "Crosshair",  -- Crosshair | Distance | Health
            sticky    = true,
            hitChance = 100,          -- percent of shots redirected
            showFov   = true,
        },
        cam = {
            enabled = false,
            hold    = true,           -- only while right mouse is held
            smooth  = 0.35,
        },
        fire = {
            rapid      = true,        -- keep firing while the button is held
            auto       = false,
            autoCone   = 4,           -- degrees around the crosshair
            autoReload = true,
        },
        esp = {
            enabled   = true,
            box       = true,
            name      = true,
            dist      = true,
            health    = true,
            hpText    = true,
            weapon    = true,
            spotted   = true,
            chams     = true,
            offscreen = true,
            tracers   = false,
            maxDist   = 2000,
        },
        radar = {
            enabled = false,
            range   = 350,
            size    = 170,
        },
        world = {
            fov          = 0,         -- offset added to the game's own field of view
            clearWeather = false,
        },
        ui = {
            accent       = "Amber",
            reduceMotion = false,
            scale        = 1,
            autoSave     = true,
            killFeed     = true,
            tab          = "Combat",
            x            = -1,
            y            = -1,
            minimised    = false,
        },
        -- Experiments: untested ideas the user tries by hand. Everything that
        -- changes gameplay ships off; the two alerts only warn.
        exp = {
            noSpread       = false,
            magnetism      = false,
            noRecoil       = false,
            fastReload     = false,
            instantAim     = false,
            longThrow      = false,
            finishDowned   = false,
            adaptiveLead   = false,
            noFallDamage   = false,
            safeSprint     = false,
            instantPrompts = false,
            meleeReach     = false,
            meleeRange     = 12,     -- studs
            autoSpot       = false,
            modAlert       = true,
            modLeave       = false,
            voteAlert      = true,
            voteLeave      = false,
            streamer       = false,
        },
        keys = {
            panel  = "RightShift",
            silent = "None",
            esp    = "None",
        },
    }

    local function deepcopy(t)
        local o = {}
        for k, v in pairs(t) do o[k] = type(v) == "table" and deepcopy(v) or v end
        return o
    end

    E.cfg = deepcopy(E.DEFAULTS)

    ------------------------------------------------------------------------
    -- Dotted path access
    ------------------------------------------------------------------------
    local function split(path)
        local a, b = string.match(path, "^([%w_]+)%.([%w_]+)$")
        return a, b
    end

    function E.get(path)
        local a, b = split(path)
        local sec = a and E.cfg[a]
        if sec == nil then return nil end
        return sec[b]
    end

    local watchers = {}
    function E.watch(path, fn)
        watchers[path] = watchers[path] or {}
        table.insert(watchers[path], fn)
    end

    local function notify(path, value)
        for _, fn in ipairs(watchers[path] or {}) do E.try("watch " .. path, fn, value) end
        local a = split(path)
        for _, fn in ipairs(watchers[(a or "") .. ".*"] or {}) do E.try("watch " .. path, fn, value, path) end
        for _, fn in ipairs(watchers["*"] or {}) do E.try("watch *", fn, value, path) end
    end

    -- set enforces the default's type, so a slider cannot write a string into a
    -- boolean and a bad file cannot poison the running state
    function E.set(path, value, silent)
        local a, b = split(path)
        local def = a and E.DEFAULTS[a] and E.DEFAULTS[a][b]
        if def == nil then E.fault("set", "unknown setting " .. tostring(path)) return end
        if type(value) ~= type(def) then return end
        if E.cfg[a][b] == value then return end
        E.cfg[a][b] = value
        if not silent then notify(path, value) end
        if E.save then E.save() end
    end

    -- fire every watcher with the current values, used once the UI and the
    -- features exist so restored settings actually take effect
    function E.replay()
        for sec, keys in pairs(E.cfg) do
            for key, value in pairs(keys) do notify(sec .. "." .. key, value) end
        end
    end

    ------------------------------------------------------------------------
    -- Disk
    ------------------------------------------------------------------------
    local function mergeKnown(src)
        if type(src) ~= "table" then return end
        for sec, keys in pairs(E.DEFAULTS) do
            local s = src[sec]
            if type(s) == "table" then
                for key, def in pairs(keys) do
                    local v = s[key]
                    if v ~= nil and type(v) == type(def) then E.cfg[sec][key] = v end
                end
            end
        end
    end

    -- the original single file hub used different section names; carry over the
    -- values the user actually tuned and drop everything that no longer exists
    local function migrateV1(d)
        local function pick(t, k, want)
            if type(t) == "table" and type(t[k]) == want then return t[k] end
        end
        local c = E.cfg
        local s, tg, es, ab, wp, ui = d.silent, d.target, d.esp, d.aimbot, d.weapon, d.ui
        local v
        v = pick(s, "enabled", "boolean")   if v ~= nil then c.aim.silent = v end
        v = pick(tg, "fov", "number")       if v ~= nil then c.aim.fov = math.clamp(v, 1, 179) end
        v = pick(tg, "maxDist", "number")   if v ~= nil then c.aim.maxDist = v end
        v = pick(tg, "visCheck", "boolean") if v ~= nil then c.aim.visible = v end
        v = pick(tg, "predict", "boolean")  if v ~= nil then c.aim.predict = v end
        v = pick(tg, "part", "string")
        if v == "Head" then c.aim.part = "Head"
        elseif v == "UpperTorso" or v == "HumanoidRootPart" or v == "LowerTorso" then c.aim.part = "Torso"
        elseif v == "Nearest" then c.aim.part = "Closest" end
        for _, k in ipairs({ "enabled", "box", "name", "dist", "health", "hpText", "chams", "offscreen", "tracer" }) do
            v = pick(es, k, "boolean")
            if v ~= nil then c.esp[k == "tracer" and "tracers" or k] = v end
        end
        v = pick(es, "maxDist", "number")   if v ~= nil then c.esp.maxDist = v end
        v = pick(ab, "enabled", "boolean")  if v ~= nil then c.cam.enabled = v end
        v = pick(ab, "hold", "boolean")     if v ~= nil then c.cam.hold = v end
        v = pick(ab, "smooth", "number")    if v ~= nil then c.cam.smooth = math.clamp(v, 0, 1) end
        v = pick(wp, "fastFire", "boolean") if v ~= nil then c.fire.rapid = v end
        v = pick(wp, "triggerbot", "boolean") if v ~= nil then c.fire.auto = v end
        v = pick(ui, "autoSave", "boolean") if v ~= nil then c.ui.autoSave = v end
    end

    E.cfgSource = "defaults"
    do
        local X = E.X
        if X.isfile and X.readfile then
            local ok, exists = pcall(X.isfile, E.CFG_FILE)
            if ok and exists then
                local ok2, txt = pcall(X.readfile, E.CFG_FILE)
                local ok3, data = false, nil
                if ok2 and type(txt) == "string" and #txt > 0 then
                    ok3, data = pcall(function() return E.HttpService:JSONDecode(txt) end)
                end
                if ok3 and type(data) == "table" then
                    if data._version == E.CFG_VERSION then
                        mergeKnown(data)
                        E.cfgSource = "restored"
                    else
                        migrateV1(data)
                        E.cfgSource = "migrated"
                    end
                end
            end
        end
    end

    local queued = false
    local function writeNow()
        if not E.X.writefile then return end
        local out = deepcopy(E.cfg)
        out._version = E.CFG_VERSION
        pcall(function() E.X.writefile(E.CFG_FILE, E.HttpService:JSONEncode(out)) end)
    end

    function E.save(force)
        if force then writeNow() return end
        if not E.cfg.ui.autoSave or queued then return end
        queued = true
        task.delay(0.8, function()
            queued = false
            -- a save queued by an earlier load must never overwrite this one
            if rawget(getgenv(), "__ENTRENCHED") ~= E or not E.alive then return end
            writeNow()
        end)
    end

    -- a migrated file is rewritten straight away so the old sections are gone
    if E.cfgSource == "migrated" then writeNow() end

    function E.resetConfig()
        for sec, keys in pairs(E.DEFAULTS) do
            for key, def in pairs(keys) do
                if E.cfg[sec][key] ~= def then
                    E.cfg[sec][key] = def
                    notify(sec .. "." .. key, def)
                end
            end
        end
        writeNow()
    end
end

-- ==== en_02_theme.lua ====
-- en_02_theme: palette, accent themes, type, spacing and motion tokens.
do
    local rgb = Color3.fromRGB

    local T = {
        base    = rgb(11, 11, 14),     -- window
        surface = rgb(18, 18, 23),     -- cards and sections
        raised  = rgb(26, 26, 33),     -- hovered rows, inputs
        track   = rgb(37, 37, 46),     -- control tracks
        line    = rgb(38, 38, 48),
        text    = rgb(237, 237, 242),
        dim     = rgb(152, 152, 166),
        mute    = rgb(98, 98, 112),
        good    = rgb(86, 214, 140),   -- clear shot
        bad     = rgb(242, 96, 98),    -- something in the way
        warn    = rgb(250, 196, 84),
        black   = rgb(0, 0, 0),
        white   = rgb(255, 255, 255),
    }

    T.ACCENTS = {
        { name = "Amber",   color = rgb(255, 184, 76) },
        { name = "Violet",  color = rgb(141, 112, 255) },
        { name = "Crimson", color = rgb(255, 84, 106) },
        { name = "Mint",    color = rgb(74, 222, 172) },
        { name = "Ice",     color = rgb(98, 178, 255) },
    }

    function T.accentColor(name)
        for _, a in ipairs(T.ACCENTS) do
            if a.name == name then return a.color end
        end
        return T.ACCENTS[1].color
    end

    T.accent = T.accentColor(E.cfg.ui.accent)

    ------------------------------------------------------------------------
    -- Type. Builder Sans through Font.new where the client supports it,
    -- Gotham otherwise. Each role carries both so a label can pick either.
    ------------------------------------------------------------------------
    local families = "rbxasset://fonts/families/BuilderSans.json"
    local canFace = pcall(function() return Font.new(families, Enum.FontWeight.Medium) end)
    T.fontFace = canFace

    local function role(weight, legacy, size)
        return {
            face   = canFace and Font.new(families, weight) or nil,
            legacy = legacy,
            size   = size,
        }
    end
    T.type = {
        title   = role(Enum.FontWeight.Bold,     Enum.Font.GothamBold,   15),
        heading = role(Enum.FontWeight.SemiBold, Enum.Font.GothamBold,   11),
        label   = role(Enum.FontWeight.Medium,   Enum.Font.GothamMedium, 13),
        body    = role(Enum.FontWeight.Regular,  Enum.Font.Gotham,       12),
        small   = role(Enum.FontWeight.Medium,   Enum.Font.GothamMedium, 11),
        digits  = role(Enum.FontWeight.SemiBold, Enum.Font.GothamBold,   20),
        value   = role(Enum.FontWeight.SemiBold, Enum.Font.GothamMedium, 12),
    }

    function T.applyType(label, roleName, sizeOverride)
        local r = T.type[roleName] or T.type.body
        if r.face then
            label.FontFace = r.face
        else
            label.Font = r.legacy
        end
        label.TextSize = sizeOverride or r.size
    end

    -- TextBounds lies for wrapped text and AutomaticSize locks the lie in, so
    -- every measurement asks TextService what the text actually needs
    local params
    pcall(function() params = Instance.new("GetTextBoundsParams") end)
    function T.measure(text, roleName, width, sizeOverride)
        local r = T.type[roleName] or T.type.body
        local size = sizeOverride or r.size
        local w = width or 10000
        if params and r.face then
            local ok, v = pcall(function()
                params.Text = text
                params.Font = r.face
                params.Size = size
                params.Width = w
                return E.TextService:GetTextBoundsAsync(params)
            end)
            if ok and v then return v end
        end
        local ok, v = pcall(function()
            return E.TextService:GetTextSize(text, size, r.legacy, Vector2.new(w, 10000))
        end)
        return ok and v or Vector2.new(#text * size * 0.55, size)
    end

    ------------------------------------------------------------------------
    -- Geometry
    ------------------------------------------------------------------------
    T.space  = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }
    T.radius = { sm = 6, md = 8, lg = 12, pill = 999 }
    T.row    = 38

    ------------------------------------------------------------------------
    -- Motion: { duration seconds, bounce }. Bounce lives at the end of a
    -- gesture only; frequently used surfaces stay crisp.
    ------------------------------------------------------------------------
    T.motion = {
        hover    = { 0.22, 0.05 },
        press    = { 0.14, 0.00 },
        toggle   = { 0.32, 0.18 },
        select   = { 0.40, 0.20 },
        page     = { 0.34, 0.00 },
        reveal   = { 0.42, 0.00 },
        panel    = { 0.46, 0.14 },
        collapse = { 0.30, 0.00 },
        digits   = { 0.55, 0.00 },
        release  = { 0.50, 0.38 },
        toast    = { 0.40, 0.00 },
        fade     = { 0.24, 0.00 },
        follow   = { 0.12, 0.00 },
        light    = { 0.60, 0.00 },
    }
    T.reduced = { 0.18, 0.00 }

    E.T = T
end

-- ==== en_03_motion.lua ====
-- en_03_motion: closed form damped springs and a property animator built on them.
--
-- Each spring is the exact solution of x'' + 2*zeta*w*x' + w^2*x = 0 for the
-- offset from its target, so a step of any length lands where continuous motion
-- would: identical at 30 and 240 fps and never unstable. Tuning is expressed as
-- a perceptual duration and bounce:
--     w    = 2*pi / duration
--     zeta = 1 - bounce         for bounce >= 0 (under or critically damped)
--     zeta = 1 / (1 + bounce)   for bounce <  0 (over damped)
-- Retargeting changes only the target, never the velocity, so a control that
-- changes its mind mid animation carries its momentum into the new destination.
do
    local TAU = math.pi * 2
    local exp, cos, sin, sqrt = math.exp, math.cos, math.sin, math.sqrt

    local Spring = {}
    Spring.__index = Spring

    local function tuning(spec)
        local d = math.max(spec[1] or 0.3, 1e-3)
        local b = math.clamp(spec[2] or 0, -0.9, 0.9)
        local w = TAU / d
        local z = b >= 0 and (1 - b) or (1 / (1 + b))
        return w, z
    end

    function Spring.new(value, spec)
        local s = setmetatable({ x = value, v = 0, g = value }, Spring)
        s.w, s.z = tuning(spec or { 0.3, 0 })
        return s
    end

    function Spring:tune(spec) self.w, self.z = tuning(spec) end

    function Spring:step(dt)
        if dt <= 0 then return self.x end
        if dt > 0.2 then dt = 0.2 end              -- a hitch must not throw the UI
        local w, z = self.w, self.z
        local x0, v0 = self.x - self.g, self.v
        if x0 == 0 and v0 == 0 then return self.x end
        local x, v
        if z < 0.9995 then
            local a = z * w
            local wd = w * sqrt(1 - z * z)
            local e = exp(-a * dt)
            local c, s = cos(wd * dt), sin(wd * dt)
            local B = (v0 + a * x0) / wd
            x = e * (x0 * c + B * s)
            v = e * ((B * wd - a * x0) * c - (x0 * wd + a * B) * s)
        elseif z <= 1.0005 then
            local e = exp(-w * dt)
            local B = v0 + w * x0
            x = e * (x0 + B * dt)
            v = e * (B - w * (x0 + B * dt))
        else
            local r = sqrt(z * z - 1)
            local r1, r2 = -w * (z - r), -w * (z + r)
            local c2 = (v0 - r1 * x0) / (r2 - r1)
            local c1 = x0 - c2
            local e1, e2 = exp(r1 * dt), exp(r2 * dt)
            x = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        end
        if x ~= x or v ~= v then x, v = 0, 0 end   -- NaN guard
        self.x, self.v = x + self.g, v
        return self.x
    end

    function Spring:settled()
        return math.abs(self.x - self.g) < 1e-3 and math.abs(self.v) < 1e-2
    end

    E.Spring = Spring

    ------------------------------------------------------------------------
    -- Property animator
    ------------------------------------------------------------------------
    local Anim = {}

    local function specOf(token)
        if E.cfg.ui.reduceMotion then return E.T.reduced end
        if type(token) == "table" then return token end
        return E.T.motion[token or "fade"] or E.T.motion.fade
    end

    -- channel packing per value type
    local kinds = {
        number  = { n = 1, pack = function(v) return { v } end,
                    unpack = function(c) return c[1] end },
        UDim2   = { n = 4, pack = function(v) return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } end,
                    unpack = function(c) return UDim2.new(c[1], c[2], c[3], c[4]) end },
        UDim    = { n = 2, pack = function(v) return { v.Scale, v.Offset } end,
                    unpack = function(c) return UDim.new(c[1], c[2]) end },
        Vector2 = { n = 2, pack = function(v) return { v.X, v.Y } end,
                    unpack = function(c) return Vector2.new(c[1], c[2]) end },
        Color3  = { n = 3, pack = function(v) return { v.R, v.G, v.B } end,
                    unpack = function(c) return Color3.new(math.clamp(c[1], 0, 1),
                        math.clamp(c[2], 0, 1), math.clamp(c[3], 0, 1)) end },
    }

    local byInst = setmetatable({}, { __mode = "k" })
    local active = {}          -- track -> true
    local free = {}            -- standalone value springs -> true

    local function trackFor(inst, prop)
        local props = byInst[inst]
        if not props then props = {} byInst[inst] = props end
        local tr = props[prop]
        if tr then return tr end
        local cur = inst[prop]
        local kind = kinds[typeof(cur)]
        if not kind then return nil end
        local ch = kind.pack(cur)
        local springs = {}
        for i = 1, kind.n do springs[i] = Spring.new(ch[i]) end
        tr = { inst = inst, prop = prop, kind = kind, springs = springs, buf = {} }
        props[prop] = tr
        return tr
    end

    function Anim.to(inst, prop, target, token)
        if not inst then return end
        local tr = trackFor(inst, prop)
        if not tr then inst[prop] = target return end
        local spec = specOf(token)
        local ch = tr.kind.pack(target)
        for i, s in ipairs(tr.springs) do
            s:tune(spec)
            s.g = ch[i]
        end
        active[tr] = true
    end

    function Anim.set(inst, prop, value)
        if not inst then return end
        local props = byInst[inst]
        local tr = props and props[prop]
        if tr then
            local ch = tr.kind.pack(value)
            for i, s in ipairs(tr.springs) do s.x, s.g, s.v = ch[i], ch[i], 0 end
            active[tr] = nil
        end
        inst[prop] = value
    end

    function Anim.stop(inst, prop)
        local props = byInst[inst]
        local tr = props and props[prop]
        if tr then active[tr] = nil props[prop] = nil end
    end

    -- A spring not bound to a property, for counters, sweeps and other values
    -- that are drawn by code rather than written to one Instance.
    function Anim.value(initial, token, onStep)
        local s = Spring.new(initial, specOf(token))
        local h = { spring = s, onStep = onStep }
        function h.to(v, tok)
            if tok then s:tune(specOf(tok)) end
            s.g = v
            free[h] = true
        end
        function h.snap(v)
            s.x, s.g, s.v = v, v, 0
            free[h] = nil
            if onStep then onStep(v) end
        end
        function h.kick(dv) s.v = s.v + dv free[h] = true end
        function h.get() return s.x end
        function h.target() return s.g end
        return h
    end

    local function step(dt)
        for tr in pairs(active) do
            local inst = tr.inst
            if inst.Parent == nil then
                active[tr] = nil
            else
                local done = true
                local buf = tr.buf
                for i, s in ipairs(tr.springs) do
                    buf[i] = s:step(dt)
                    if not s:settled() then done = false end
                end
                if done then
                    for i, s in ipairs(tr.springs) do s.x, s.v = s.g, 0 buf[i] = s.g end
                    active[tr] = nil
                end
                local ok = pcall(function() inst[tr.prop] = tr.kind.unpack(buf) end)
                if not ok then active[tr] = nil end
            end
        end
        for h in pairs(free) do
            local s = h.spring
            local v = s:step(dt)
            if s:settled() then s.x, s.v = s.g, 0 v = s.g free[h] = nil end
            if h.onStep then
                local ok, err = pcall(h.onStep, v)
                if not ok then free[h] = nil E.fault("anim value", err) end
            end
        end
    end

    E.bind("ENT_MOTION", Enum.RenderPriority.Last.Value - 10, step)

    E.Anim = Anim
end

-- ==== en_04_assets.lua ====
-- en_04_assets: generated by tools/gen_sprites.py. Do not edit by hand.
do
local B64 = {
    shadow = "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",
    shadow_soft = "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",
    glow = "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYAAABccqhmAAAgkUlEQVR42u1d227rOAykHP//H0fal10ga0jiDEm5vpBAkTQ5p00Tz3B4EVlaa5KWlvZO2/ItSEtLAkhLS0sCSEtLSwJIS0tLAkhLS0sCSEtLSwJIS0tLAkhLS0sCSEtLSwJIS0tLAkhLS0sCSEtLSwJIS0tLAkhLS0sCSEtLSwJIS0tLAkhLS0sCSEtLSwJIS0tLAkhLS0sCSEtLSwJIS0s7yfZ8Cx5l5aTfk7PkkwDSXgB09vcnMSQBpD0M7N7XmqSQBJD2UMBb/p4khCSAtIWgLxeP/0uSQRJAmh+o5QHxf5JBEkCC/iFhgTf+TzJIAkjQ34Qo2uL4P8ngrIsz14NfBvjlAYqgybpcQl6oSQCPA375YyI5IwnY/pg40pIALgX88kfEcAXvH0kGeeEmAdwG+GXx81fNAbTFzycRJAE8FvjlAmFBpNxvSQRJAAn88XMewJeLyn4L6FsSQRLA04C/+vGrhQDtjx5PIkgC+BPwRwC53IAIIoHfTiCCvLiTAC4D/HJjIvgL4LckgiSAtwDf+m/OIIEo8Legf5NEkARwOfBbAFwWEcUVCCAC/NHkkCSQBBCevY8GfqQyOCsE8IL9L4ggL/okgPCyXRTQI5TDikSgVepbwR9BDEkESQDLvb4V+KsI4ewqwArAn6EQkgSSAEKTeV7ge4kiMiRogSSw4r72XHTyMAkgvX4Y8M8kg5VJwNWgjyCCVANJAC7we+W95fkI8JdFwzpaIAlYQL8yTHglCbyNADyS3+qhSwABrAoJVsT9HrDPHosMGTIkeCEBWMGPEIEV+GcSAUoI1pJfJMhZIojOFbyGBN5CABGlvAhPz95GhwZRKiBK6rO3EcogqoSYBPBC8Fu9f/QtQwLR8wAs4F91G6UMXksCTycAC/g9iTvm9uok8BfgX00IljzBo0ngyQSwEvzRgI8OESLCAdRjesG/khCSBF5KAN5GHqu3R587WxFEE8BKjx9NDpYyohgPGkkuBnke+L1e3koCTySA9u/raD+vafTY8b448hiW34M+lgrgZuAffW8lAQTULCFYFAITDnhJACUAxsPP7nuUAqMKIroJUwE8GPxWD+95jlUESELQSgKs5x95/+N9zSMX44TiAigA7Xc9WgnsLwU/I/8jQe/93hMSeBqBPJL/6MlHwI8Cfxu0OWskIORreAQJ7C+c1uuN9y0g9jxmCQuiVADj/VECOH5/JIURMWigOwK5DMhgRAyW/MPtSWB/QakvAvwsAYwe057Tfo43HLAoAK/sRwDfA32Ux52FAkxycPT7b00C+0t6+yPBbwE88nyEImBCAasCYCW/DMDeBl8yIAOWEGaKgCEB5HfelgT2h5cAZzFwtMdngM7+vwgS8AwEiQT/TAXMAC+T0CBaEQiZFMwQ4CZJvwjwe4HuUQkjIhgRwsoQYEQCGvCR5z3EoKmACEXwmKTgnuA/3dtvwYqATQjOSICN/5F4nwV9NV4TjawQJAnckACuBH7v1yZ+dYAQwQoCQIDPevn/gL8FqoJeWTBJ4CU5AC0ORqS+LAT4JrHhQkQuwBr7R8n6aGVgVQICtipnDuBC3h9pgFkJ/m3x46ga+CsCQEmgkgQwUgY1qDlo1Dcw8+yWcwRJACcc8GFP9XnAzwB4M/wbqxo43mdLgrPmHybm17L/tfN47YB8CyIEhgQkoDx4CxLYH9rj78nwi1G2z0DOPBeRH/D2AyDJP2ucPyOC2c8/Av8I+A0gA5QEJKg8eHkS2B8e9yMtsgj4Nyfo2fsWImBODTIkgNb8EeCXwWN1oAJkQgYzwG8TImiTkegzBfDIfMD+wLifzfTPCAEFv3YffQwNF6wkYA0BvOBngN/7PfUA6q2jCnpg3yYkIGReIHKuQBLAye2/M6nMSn4L8DcHIUSRQEQIEAH+crh/JIEeGSBEMAsNqvJ3FjAv8Li24P3Gp/yQuH8k+QVI9FnAH3WLhAcMCaBEwCQAmYTfDPwzwItCBD0FsJEk0CMCJCRgQH9ZUtgfLv2LAfiFkPzMbRQZjAhBSBJgFACaAKwTApiBf3QbQQjM394jgkIOGLlVKLA/9PDPyOtba/os+DXgM8RgUQOeMMAj/7dBpl+Lp0eg7z32C/bRbY8ENqJ3YDYk5FGHg/abe38B6/xRHX2oZ5/dZ/5vVCjgCQFY6f9LAlunAtDz9r37zEASlASKoQpSgOEhclcVsD8g8ceU+kbdgQwRoECfgX72/YgIWDJgOgKZDkCmxj8C/vGxo7fvfd8jgP8APyOBYuiALMYSoWQfwPmJPwETfmjdH5X7GuCtjzGhwfF1CqEC2B6ANijP/Xr+Yzx+BMmIDI5EoJFBD/hiCAu0vgAtMWhJ+F2KFPYbNvkg3p+R/kJ4fMbDW59DyMCaC7DkAGbef+sogCPwRgTQI4Ee8ItSy2dJoCjgZysEZ+w2eAUBFPLflUUxvxYGsOCPIgQ2LyBGFcA2/2jx/jaQ/jPAz4DfA32PBKJHpc1yAloocFkVsN/Q+1ukvzX273lhL/gtBIGEApvwZwNY+S8D4DfF85YBGTCAR0mgDNQAQgANuMYsoUD2ASz2/gLE+xbZXxTgI+D/nEgCbDXAEv+P5L8X/LPXrpFAmRDB8b41HGgKuG+pAvaHev/oiT3bwONaQf85mQRWEMAK8GuKDSGC0gkFNiUs8IQDt1YB+4O8P7oghDn5x4B+Bu5PIBGMQpK/IIBjD34deN1KAJ/x/igZaETQBqU/Nhy4nQrYH+T9PRl/JPEXAf6PM0SwVgVWEEAdxP+VAH4JBr5GBkhitJGVklurgP0l3t/i+TcnMcyA/3HmCNhQYBUBjEKAKr6DS5ZkXVM+KwlWAo9QAfvNvT8a/4uz7MeW8jSwe1SBRQVEE8DR+7eB9z9+fYU7t4CcVJSfpCSiAqKUQFO6KW+hAvabe39NAUTN+WMTfx8A8B+nImByAUhDENMAVA/3Ge//BZuTinGFGaIGqkIAiBIok3DgNipgf0jsLyfF/AVo//2Qt6PHZmSAHByaqQCEAFj5P/P+3wEJiKNluXW8f+uUBFE1wCoBz0yAbAQKjP01MtBGgluIwZoctJCCJR9gDQMs8X87gB31/J6QZHS7gSqg976MRoMX46EhVgW8igCKxB8XnmWWJaj9txgBf3wsiggsYYCXAGalP837fwU/qThL9mm3paMK2NkJo5kAHhVwuTBgv5H8ZzL/zJLPzQh8hgw+wH2NCLwqIJIAmjHulwC5P3qNm4EIRvmAphCBtU34cmHAfiP5z9T9Pfv+tHh/Fg58BsAfgR8hA4QIGAJAJDdKAG3i+Ufe//dWiPbbUaJy64QBs7xAm1wLx+dm4YClTThDAKP8t5YHWdCzo8BYBTADvzUcsIYBqLe1yH9U9jPAR2YTbofbcrg/OjNQAlRAhIc/nSj2i8p/7UJBO8s82363yalAS5//RwE/qgaiwgArAaDyvxq9/gj4DSCEHhn0SGD2NVIBzaBYmLkBGQIE9g1oMwM84C9AHuDT8fwaITC5gSsQQAOkv2Umobb2WzuZuAWSALI09FZjwP+aAIrhOST5h8b/xTkHsDiSgMgXEhIclcbsmHIkAfTk/28ibVTrP3p/65oyZBhp6wCeAT4TCszKgpZlon9CHlc8C2BJ/olB+ntGgXmHgHyMIYFHBXiTgCP5XweyP0LyWzYPb5OcwIgMxBAKaGXBqKUiGQIYk38CrAMTx2wAD+AZpYAmBLVkoIcAkOTfLPH3BQH/CSIERvL3wOoNBTIEWJD9F/DsuGdW4AYCvziHg1jDArYkyOYBRvJ/A5N/1ZHwGxECsnuwdLz/rArQlPhfFBKQSSgQsTjkNALZL9r8gzT5FFABFMcOgAICvoDgn5UELQTwCU4EIiVAzftbJu0cFQBCArUD+DYghGLIBbQJCcgkFEBj+0tUA+6wF6A4SokI+CVoKAh7WpAhAiYXgOQBZvHrKP4fjfvq9fp/Afk/A/5nkuCbgb8phMB+9iMSQEF7+e1Ad5oKXMCZALJgJZj3kNDHSQQrwgAmEaeBvxf7I+W+GfA/ygDSURgw+oya8TqYJfKKsxrwGgIoEpMbQLP/zHkBy4pw68lAlAg2Y2kQCQMsIcBM/o/q/jNiYYG/gWQwywt4B5I2ZUGoEDMFL1MO3G9W/mOz/yL+KUGb0iq8GfoDPgrIP0AHIRoGIN2SzakAkFN9n8ljGvC3yRzC1hkCyoQB2rXQgCPDQrYHXyY02G9e/kOy/8V5AUS3CqP5AbYsuAENQZYcwHHzT8TIMRTwGhFUx84BMYQCbC4gl4MGgV4bA8ZehBETg5AlntaZAVtALiAqBDiu/PK0GI/k/gcA/mj/wEwNeIaSsj39K8qBqQDA8p+QDT4StCykkAtE2bBAO2NwBgG0wU4/7We2Sdw/8v4z4M+Wj3jVAFMR0EDO5gEeTwBMAtAS/7P/19ovsBGtwx4i8HQHonkANgcwIwAhG3xmXl4D/gaWJJFwxZI0tm7/nf37Pw0h9hvV+pn435L8E8choS0wKYj0/H+IOQErCWDk+WYdfTPZf7zPkADj+SUwGRjZ7ffKeQAScEJQnN5fFuwS9AwTRXIBM8JAm4GQEKD+tPmiJMIk/Wagj5b5BbwGJLCbL4eCBsb+Rbhjw8iwEDkJ+AXc97c5tw7NKgHaRX48CFQPHq8Cs/GRs/oz734E+koiYNUjAnYx9gQkARgbgzzZf2SisDUnUAgy8JYOZzMCmKSdDKR/nZBHMwzrGHn+Eei12H4jFpBqJOCpBtxuUMidqgBMeMCUDbVDRZYE4QZMG/YMGdmMB4MsCuDX61XDWf5t0FCEgr4MnkMTfcxnjVxD7c7Hf88mgJUVABFsZZi2J8DaLSjOLsJVIQFaCkQkfDnkACyDPI61+pnkH71vVewlPCF6AGZqYbYCjPX+l6kE7A+oAHi6BjW2j0oQMjMFPBOIPb0Aox4ALcGHrBCvE+9fQBXgifEZVShkIlDuXAnYH1IBQMaHafIfUQyrdhAyJcYN2FVwBgGMDuto4K9BoBcwsWf5jGeOwVIOzL0AfzQZWDsxiFwkzP3I9WPIcI9ZiXGWixBlDdaRAGpn7952+PejxNyocy+ylMd8PsxR8lkYcPtxYHfrAyhOcmDPFwiYUCoSGyIgE4lnScQZqWh/Zy/ht3WWaPS27vR6B7aggzsWEiiGz5m5lm63CfjufQBo8i+iZRhdHV1O/NqI6oM1BCiT5J0MNu9ug1Fc9cT3RisLM/0jbCv67Hhv9gGcuDUYSTKiIGYOGlmbmaKJYTOCRsDmlt6QDc+kHctrRMI9rbqEkoeQ75PcsRfgzn0AlqlBEeFHMYCbeZ0rQwqm2eU3BKiLvDX7Hmnvrcebo9dTexJY9oc1AcmCHgU0Q8x6f4QQrFlvJhkmgwx/mazVZqsiYvj7Le+xdbpU1PXUkgCuSwiMxLPsJfB4f6ZpKSoJaWm0QgdqoM01q1WA9fMuTwX8G0KAFSFDhJxEwac1qCA1bAGVwcjry2QdloDAt6gmb+jGJHi9IeIjbHuB579qFcM7Fk0IkrB2ZLI/11pWi3zf8hp8EQG85UMvwpVGo18jQijlYu9RWhJAWlpaEkC8tT/+fW3Sn7/iNWo/tw1e45M/kySAFwLR+hpbEOhRgCKAZR9Dfq7ltUe/b3kNSlYBxLGSWhZ51gZe1DOgtcn3bVLPR4+cMicBtdejvXbPeySOz6kF/B7JRqDrgbiAFwfjHTVPhmynZQdojMCtPdfIs/zs69J+B/vaI96rBn5G7Ofd3hJy7A8GvOcDbABxNCeoUO+rgR1Z6IE2royAy/xO9LVb3ydGNVlDlteEAvtLJb1HTq5SAR4vrE3kkZ9+fpasavBrYkMvq/ePSog+OmTYH+bZGzC1Fplkq8lJq4da8XWc29+I3AAz3qtHCnXx32bJrWikoH3WlgTqbZXCfqMs66xNtQR581lyDSWPlUAfDd5oh/Hd0jnJdzy6q5Xz6uHn/n5pCqGe/N6I8llZErxMHgAtjaYCcHh0DejI82xtXYtnZSHIR1twe8dT6yHOb5OJPqJste29pqo8NiKInlJYEVJouQe2Z6E5vfiqfozX5wDQEKEBgBYgSy3kfQ/wZ+Cvk8GbZTC3f+ss9DgeBmpACFA7IG8TRTACf1VIJRL8GimgiUNruJc5gIVg76mCmVJoyoUu4EXCZL0Z0B/BzS6+nM3tZ08DogRQlecqQAIIiaDg1yoU7GcsRJIRDSmTAJQjp9HkwMR6GutHSvw6iectW2+REeqe7cAzkGtfbUIWLZAMUJJgGq5YDx/R7SlP2w6sAbIY430kGcg017BeBiWGCoL+F+hH0FfjYI/j3H7ParAeCXyNZICEEJUkhIjPEFUM4miy8rZ5Zx8AqAKsYYAYGnHaQMbP4vZezH8kgQIQgAb+4+RaSwjQA+43kAjQfEIlKg0CdCta5P/tJP4dCcDj/ZFKgBbTC+HdN6JcNwL9r6fvef0q3OTiNpjb71EAWgjwNYYIlSSD6mhWEqKrkSn9WVVAEoDjTUOSg2y9OLJ0h4B+m3h+jQC02fOts7QDyRn03o9RGPA9ISSYlRYjSopsfwd70Cj7AE6sBKB5h7aABBgiQDz/9wewXyXB17twtbn9TBJwlgjskcDxiyWIM4BvaRiyHDTKPoCTKgGjcqClfMSAvXc7uz8C/XcAfC32nwG3TJZ2RBHAL7C/YIjwJQihKfetbcliTBhaDhpdtgJwFgGsrAS0yYLLYsgDiCPmR0lg5PV78v/rOGtQgJn+4uwF6IF6pgIiQgQE9JXM/LPe39oyfKkKwN2qAG2QAxiRiLVsZJX5GxHbz2T/V/Q1Vkjo8pcEMPo3X0O+AAF/RHhgma3g7RrMHIBBGYx62T3VAMvpu22yBXcDvLwm+79ENnpEAPWwHkzAMqBMwIWEAWguwBIONEAheAeasNn/iPMFSQDOEKJHAlHszxzcKYZbK/BFeW2WKkILyAN8gXDg6ywZer2+BFYMbnsuYL8QqJG+fu24cEQycOTxj5txNTWAAP5X7n/B2f8NkOtbx/tHhQCNJIBRhcASFiBevxraij2lY0v8365CFvvFvDibOS1KUxCSDETArxHCqG6vefoyifu/IEi3zpd2hsAyvKQSDUFfJS+AhAWWkqFnNoEYSsfeqUF/rh72G80CmMWtlnKgBfyaQhiRAQr8L+hFmoh8wBJlceYAGnj67ztJ+H0VVcAQgeXgUHX2C7CzIZkR6pkDCOgRGOUCoioCFdhQ2/O41Ql8+QG7dID/AUqSESEAczDoC5IASgSo56/Bh4hmJUPP5OAcCRbQzTcKAWQSBli9vyUMGDXzMMDXYshRCIDI/2KsLHjDAJYIGCWgyf8qvuoAcqgouovwUQQQce6/TTrhCpgLYGR/jwgKQAhF6ej7GuLEX4+/Tbz/MSF5BD6aAxClFNiIbr8v+MUeMkJmClQyHEBjf8tegssdGtofNA5sVg1oAyIQhyJgvr7KjvoCyv+j7B95/54q8RAAmgdgcgGzZiFvB2EzVAC0KcOWngHJMuCaciBaDZh1BhZwzHavRddKBJYWXxkA/9Px/CPvj8h/tBQ4mg/4JUuDUS3DVVEoSOsws5gFzf5fuvx3pZFgQp78E2X2f28bjrfrb6QAEBLwLCP5DG6PCqAp3j+CACwq4OvIC3yNJwijdxcgA0bZ7P9lmof2h04ERkIBVvJrtf4Z6BnJr5XltsFX6dz+FQFUAwFUICywHhqynha0NP5kCBB4rLcp3XAi83PySChgIQEZxNZlAnqr5J8l/pDk3woCaEo2/kuoATZHsLpVWIgcAbNZOuoY8SPnAUQvCGFDgdoJITQSqBMCGAG/GPv8P2DnHyL/rUlAiwr4GtRABU4WooeFPKPIxXFg6PLZ/zt1AjLJwFkeYKYCpEMGva07xxn8pUMGQgK/gTH/Fij/i/OgETsu/GvIDSBNQg3YVcAsI7FugYpYN/7qTkDEwyPJQIsKmA36GBGBDFSAkHIb2Wf3AU4ksvI/ggAa2Jn3DSIC65kAZHuR1/tbkn8tTwPKkg3AMiAKyxQglAg0cBUn8GfeH5H/kQTgVQEoEVhmBkSuH9P2BESX9FqeBeDGfjdlNPYsHCjGY8HS2cNXDISAgu4DeH5E/vdeSyFbjhECaGDy7kuQgvVkoHdIKFP2QzYUZwiweBNwU3IBiNdtgx17ouQFPHJfk/ya52fkP0MAkWFABU78WUkB2Va8agfh7TcG7zep6xdlBZgA5cICEMAoHzAih+KUeCN5ycT92+FQklX+e/IAlnyAlQQsZwQsS0SQ8l4jSn6X7BvYLz4DAC33Ib0B6HQXRg3MCAE9cTcCGRP3R8T/EXkAyxLRb8CykWivjx4VPqs8+KqzANZcQAE/gJESOM74E1INoHG1ZzBpnRz7ReP/aAJgVYBVFVSn169k9h8BdUTs3zIHEJcL0N5MixKoC/4+6x7CWexfTyYAJBfQHCRQjUeEV8X86PHf23j/K7YCr1QBViWwBZGBtqdeA/5o3NcGHEpaRQBoKOAlAo8aiPb8j/H+d9kLwKgA7752JiSo5EXCDiXtkc8Gjv06kwCiSSAK9NG7BJklobfw/lftBPSogEIcGOp9OEdwjYhABo9ZwR4B/k05jxBBAAJM2llBAta14szxYDHK/tt6/7tNBWZVQCHe/NEH+gs0mRBBdYQDXvCPFoBIMAGwJUELCbSg5p/qWBrqbfe9jfe/ciOQRQUwZUExMPoxFGBIoFfi07b6HsmgDFZ+Ick/pDxpaQiyVAWiCKEBDUGrZH97gve/UyuwEHMDWCJAw4GeGqii9/trgN8mBFAmyb+e/Bdn/I/mAWTiXdk9fujBnhWrw8UIfOacf7YCBw/+9IQCTQH/L/BZEjgSwgj4m/RHe88IoCh1/woCvyiHppiWaXQEtwbQavjeCv4KkkCU9JfcC7COFNCEIHpoSAsJEBIok0Gl2+D7I9i3yYrvZphHiBwEYkaSNUc40ICz+xYvj3p8NPbXMv6o9M/loAu2A6HPR+UENEWAgKx0VMDx/qZ4/jJZ+KnF/p4cQEQuwBoaWDx9VPlPDJuBmOeTABaQhZYTQD+AevDYaFjQI4Vfb398rClJzZHn3xTQWxOATCJQgIM2KAE00rNbwF8DZgFELf5IAghUAUhVwKIG0NwAOg+g5+1HtzMCKETnn6ZIUA/WAkOB5gA2Cvga7PWRrP/tvP+d+gCiloowRHBUASMSsBJCmYB/UwhglfyPCgMsiiAK8JYV4UjCz7PcI/sATkoIzhKFvTBAI4IRCZTJYZwZERwBXwDwbwQBiCMByCQCo0kAJQSL168E8LWNwGwCOUOAi4QCRckFzIigRwI9BYAQQY8MevdXgN+6pWgFCVhAbYnvKwF8RvLfXvo/JQnIkoB2eKhMSKBM1ACyjLOQwC9G8Hu8P1sO9OQEWGAzSb0q3HFftiP0EQnAO/cBaGvDhUgKoiTQA/yMJCqYoW+dxp5GLhuVgASgJREojjJbJcMFj9RHl4Aia8GZNeDZB3AiCSCKQIiQoAGlwtIhhN7jx8dap5TXgMk+I0JhJxMX4Q5JoZ2BYgR+5ONe8IvB498S/E9YDqrlA5CloR4SsBDCDMTRsv9MAhDnYZuIYZ4R4Eem/rYngP8pOQDG+wuZHPRYNXhxq9dny3/FeUwaCQUkmABaIAGgUv+Rcf//LoTWbvf3IJt3ehc/coss+/SAGJX4zO+1lP68BGDJCchCIpBA8DNJv1t7/7sqADYpiJQHLUrAut6sOghFk/0e8HtUABsOyAle3pLkexX476oA/kIJrFYF7M+U4Ng/KhcgDs98lrdP8L8kB8CUB3tKwPq7C/B8IRKAEeD3LGJdQQLiBDr6cz2glyce/nkSAVjbgleEBTOiKR1iaMGJvoj435oHiEwQygLAR3h8eVL775OPAzPlQZYEovIUpfMaZipAiJjf2vxjaQoSopxmUQQs4D2gb8ZyXx4HvskwUYQEtJmBqCJoE2/fA30Llvwa8Ivh5BqrAsQIWivIGSLyAl6yFfgZlQFRugQjmoOQ6kTv+xYo+0vAe7siHECBHQ16y5CP9kTw370KEFEZ0ADkqRgIGctb5X5R/paoEAAFERsWsAQRHee/FvxPJABG9moeszjJwAtyr+T3kgCSDPSGBLLQw686yptVgIccHGKSg2fsNhg99iQC8CgECTizn+B/gQLQLnikWShSFSAe3fpzGdkfSQCWcMAC5BZAMmyy75HZ/jcSwGoSWEkIXo9vyf5bqwGrFYEs9PavBv8bCMBKAhbwRymFK4D/L0kgEvAM2F8H/rcQQDQJoKCPBroF/EXi8ipeElgF+AhP/0rwv4kAGBJgQFWCCSGCBDTgF0dzizUxaCUEr9wXx/COd3jGFxGAhwQsHjgS5B7gl2DvfwYRRHh6Tz3/PV7xZQTAekdviOBJKHqAXwzvg6X1dVVoIM4ynlXyvwr8byUAi0RGgR9BCtHx/goF4AX/KrB7u/je5w1fSgARIYGXCFaB3hP/W0GymgyiYvuWwE8CWKkGIoggQu4XWddlGRUWrMrgp9dPAlhOApFE4AX8KukfEQpEEcKqUl56vySAUDWwkhhWlPxkQUjgCREiPXwCPwkgnATOIoJIuV8Wgj9ybdYZwE/wJwEsI4FIcoiU+n9BAFEkEJ3My4s9CeDSRMB6+dXgjyaBFY8l8JMAbkUEdwL+FYgggZ8EcAsSiCKCKwJ/JRGsGsOdF3YSwOWIwAruqwA/0gOvKtvlBZ0EcAsi8IC+LHitEWBqC55L4CcBvJoIGABfJQSIAnYCPwngUUQQRRh/KftXg7UtUidpSQCXIoJVQC8X8f6rvHhesEkAjyOCFcRxVRWwkkjSkgBuTwQegJcLAt37//ICTQJ4NRlc2eNfiSjSJDcD3QkQxQmI8hCwJ+iTAJIMAgFTLg70BH0SQFowGdwJVAn6JIA0AiDlYX9PWhJA2sPi/wR7EkDaBYBWEuhpSQBJDGlpkG35FqSlJQGkpaUlAaSlpSUBpKWlJQGkpaUlAaSlpSUBpKWlJQGkpaUlAaSlpSUBpKWlJQGkpaUlAaSlpSUBpKWlJQGkpaUlAaSlpSUBpKWlJQGkpaUlAaSlpSUBpKWlJQGkpaUlAaSlpSUBpKWlnWT/ABGQ2W0yCXGPAAAAAElFTkSuQmCC",
    rim = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAACKUlEQVR42u2bz2sTURSFv/vys1GCRQrFQu2u4M7uiv4VgvgP69pV3duFXWUTdGpsMsdF7gtjOi1uCsm8eyAkYWbgne9dTt7kzTW2JMnMTP55CrwBXgETYADUgLGbEpCAO6ACfgDfzGy+7S3L2sxLmgDvgJfADLj2959+jXYUQB7bcx/7acPDFzOrtiFYi/lT4D3wHfhqZhV7LJ/Mt8Br4LOZXd+rBEnm7+eSPkk6bh7Lrz0yfW/Mko7d23nTc9P8iaSPkkb+PdERZS+SRu7xZOPdSY0lfZB01DXzLRCO3Ou4WQWXki7+KY0OqlHtF5IuAZKHxBS4avuZ6JI85A24AqaSJgk4A2ZmtqAQudcZcJaAQ+CG8nQDHCagD8xziRQw+9njHOjntL8tsAJu8XXzaofX9k+9bF5lAKUqACRgucN3d09967yMCvA/OEpVHRXgAErNgE0IlqplZEBkQGRAZEAshEoPwbrgDKgThSsABIAAEAACQAAIAAEgAASAABAAAkAACAABIAAEgAAQAAJAAAgAZQFQoSASoLw11isQQC9vjS2BYYEAhnl7fAH0utwpQnvnSA9YJDOrWT8jcFDQ7B8AKzPb7A5XwFBSv4DZ73v5V9sHBpJedL1pyj0OHjph5Cf0uzjz7m3EQ73DuRKAZ8Af4LdnxL73C4697H+Z2d2jABoXTTwpVw5jtUfPEyUf+7DhoWqbTPsPeiPWbfP7tlqsWbfRLx6r4r/9EVJ8KezgjAAAAABJRU5ErkJggg==",
    circle = "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",
    chevron = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAADmklEQVR42u1aO2sVQRT+5j4S0oS8wPQar6hgYW9S+Q9EKw0BSZVC7NIkpZWF+ANMmzaVVbBPE6MYFCx9IVGwMY+dz8KzcFj2JruzM/exdw5c9t5m73yPmTnnzAAxYsSIEaM/QdKQbEQmRlR5Q3Ke5PWRcwLJpjyfk3wr3xsjNe9JzpL8wf9xRxNTdwJa8twQ8Jbk7kgQIMobkldI/iaZkDwTIu7WngQ197cE9KmQQJKHJMdTkuqsfofkXwFuBXzqgke1dUGO+iloKjLq6QIFflGAa/DMELJcOxcoAnZz1M+64KtskaYWLsio3w081aJIkpu1cIFKesZJ7imlu4WVz89euSB0+tkwxlgADwDcBpBc8J8GgAUwC2DNGEMAzTqofyjKnqd+ngvmh7ZQUnN/ucDc77YjvBrKtUCVu7OyqhdVX7sgkYSpE9IFoazVlPm7BmC+wNzPWwsIYBzAurzLDJv6MzKPrUp56eqCUD2DRqCVnwCeympuHdXTLngxjAXPcabgcY10QVwKsSD6doAR9dcBjImCvubuxsCrL8+FnHK3aqQ7yOLAbotq39922PeLErA3kOWyAr8UADwHvmmSKXdtIAKCNE0aPsAbYxJpai7JwtcMlLRZAB0A96XIqjx+UzXpkXe0AezL4GzADDPNKT5LdfkHAGXn6YsDdLnbcUh5XcabALgM4IkPFxgP6jcAvANwVewfunSlfI4AXJMnXF3Q8KD+ag+sn5ciz/lompgK6gPADIBPAKYc32cdhUjVPgJwE8B3yUJtrxygy91pmZemJIAz+f90XtuSwqWts2dVymVTQf0pUX+mxLsoYFvy+wuAXwBuyO9ErStF14JTALcAfHR1gWvS87JE1mdVy5skv8np8BzJJskVkgeZrC8pkR1u9SQ7zJS7pwUKnjzgmyQv5bx7zIEI3TRZCH7R4oLzvVLASbbS6aSVcyAiHcN2UBeocrdzTrmbZEg5F3hOK82ViKBNkywBr7uc7joB90TEWdCbJrJQmZxyNwv8gORjF+AeiEiCuSDndPckB/gKybEsaZ66zEWIOJHvb+S/m77B3xOWjy8A3grRrSlIRDq2h15coM732iQ/9EJxT0S8lzFXa5oo9Vflxfv9Al6CiH0Z62olF6gTnmmSO0JCu9/ACxDRlrHuyNjd7hioJGWS5MSgAS9AxATJyUz9Uu2G5zDc2REiWt4PO4HhvJGOGDFixIgRI0aMGDFy4x8whdricsxcYAAAAABJRU5ErkJggg==",
    i_combat = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAFBUlEQVR42u1bzWtUVxT/nXkzMWMrYynZdSO02oUbS2kRiaaC0LX/gLRk1dKF0P+gm8Y/oIjU1kC3IhYMxY2mQkuKFNxFWmhBoYtSGiGOSWbe+3XhOfR4vW/mZUzexOReuMzH/Tgf99xzfufe9wRjKCQbALLg70JEcqRSb5G6V15ECpIzAGYAFMqDAPhDROZJiohwV2qbZFM/L/D5ctdtj9pKc0y6WAXQ1yrqD/4dByPjUkDD0TYFZONiZE+XpICkgKSA2kOhlOEPbdt9CiDZUAyQKciJQV5qW0ayWRceaG6z4JkKVijq65NsA9gf6d4i2RaRJ0HOINuZI8g2Jju2oiD5NoAPAUwDeBfAFIBJR58Kiv4CcBfAHQA/iMiy3zaqyB0PdzP3/QzJ6yTXuPmypmPPxObeqcI39PMwyYVAoB7JPsmcZFEidK59esH/CyQPjyNXqOzZbXVIzpJcCQQqtJpwMQUUTkm+f67tKyRnzRLGETGqCH/RCdR3gvVH2AJ9pyg//uKOUYIKbynuJWfqhbMAK+skvyf5Kcmvtd+a1h7JJZKfaZ/1YFt4CyHJS5Zej1UJkZXfiFjABsnLJI+6cV9EVnzJtR/VMRsRC9gILWEsYZBkJiI5yY8AfAOgB6ClzX3FGL8C+ERElnRMS0PeNIBTig0MkP0J4Ds8jXd97f8+gK8AvOPmhKP1sYh8a7zU6u3V/N8kuRrsVzPTyyQPOFNtjIAcQfKAzuXnNr+yqjxIrdHBhbubgYna55VBsdsEDGo2BFNcKaF1s9bw6Pb96YARc1b3SO5XIRtbZG0NnfNeQMton64NKDkF3AjCVa4e/dhWM+NoHlMaeRBeb9SigADpdSNxet6f/lYMo4LNnSjPR3BGtxak6Jg4H3FKXZJHqjikcHtU2S7O8R4JlG88nN+M8p87DyhxTM9UzdUzACc1nInm9gJgEcBvAJqDsja9+Cj0gqRDsuN+l1qDztlUGosBbQI4qbxlw+R4YSsh+cA5I1uBcxVPg2wLXSX5t9arzoSlwjzn3OqbQ3ww0oGIAzQz+P+6qkxD1MOMKWdBxvA0yUMAFkXkll2DhWcEJN8C8BOA1928ZwGcInkcwO+xsWohHyiAekObMkd/iuQcgO4AgGey3RaR2yQzQ2dl11WjlLnYXrTkRXN8yw0s6zPsf90nVxHfM7dFPF4wZNosua4a5khi7eu6Io9L9n1O8qDCYCqUtZXyELkjIisll6SPlb8cwL4ID/0hfJtsq2WCiKuj5BWjjt0qGlJxfPRUuK0ruM/d1ZXVWJnQtsmIB6ea9SM97xNNaKi1p//dAfBI/VLsinxSaUyU8DCMb5Ot7S3ACC0DuKXmNQhRtQAcj/T5RU30vnOYoQMFgM8BnAic4ASAf7Rt0Nj7yuMrAN4L+uQAflZllhWTbbmETmVs/jBySDFbYxicjRy+PHyh+G4Ibkhtab9rDouHeLxZRQn6vUOyU/VmyEUDn4dYLnJNeWtVkEMSFE7JUEqH04FIOhJLh6LpWDxdjKSrsXQ5mq7H0wMSe/oRmfSQ1HZbQ2iyJNskvwy2BUn+qI/QhYAoe2mfEzRwokpo6IOST0h2I9172mZgqahjxWt5X8AelCRp5hxbVUuN8zpNvXaPqn6BA9qQnhZPCkgKSArALn9rrAhemyt7h2DXKuBVpe3pv7YXFGDxfQFP7/GfeXV25OuqVF6Sl6d34uvz/wGVMkk9tZBrfAAAAABJRU5ErkJggg==",
    i_visuals = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAEIUlEQVR42u2av4tdRRTHP+e+TaIIiYUEDYsrYlZRUFSyxlLIH2CZRsimyJYptLRIYWtjlWxjwCZVSG2TMmhQ0SCYXREjkiVN2A3Ihs2792tzJp5M5r29b/NE5M0XHne498758Z0zZ87MfVBRUVFRUVFRUVFRUVExe7B/W4Ekcz3WU6fCVWam/w0BwdnGb3Vm1j2hzCbKmzYpNiWnGwAzawvPDwEHgaM+qi8BC962MNoG3AJ+9/Y6cM/MtgoyB4Fg/ScEpJExs2G4NwcsAkvAW8DbwBvAM8DTE6rYBv4CfgZ+AH4EvgXWCjr3HGm2B8cHkXlJB4EPgA+B95yAQaFrF+f2GHuSTU3heQusAd8AV4CrZnYvRmIpCqdCQK5A0pvAR8BJYL5gqLJ8wIQEROKSrJzYP4FLwFdm9lNpgKaV3AahfULS15KG+getpAd+7fw69HtDvzcpukxGlJ10JQzdphMlm58oAiQ1ZtZJOgJ8BiyHx8MwKinERyne9Ge/Ar95exAipgVeBl7x9rMj5LTZFGmBufD8S+BTM7udbN8TAWlJc+dPAp8DR0JINn7tMgPSPP0F+N4T15Yns/vAq8D7niRf9D5/eJK7BtwEnvLkecgT6jvAa4X8MnQ7zO1IU+428LGZXfJkPdnSKclSCEk6H0LtQQj5OAW2JF2RdErS656Zc5mHJa1K2h4T9tv+zuFC/zmXfcp1bWVToM1slKTzaTr4gPZ2fs7bq0FoF5Ql3JD0iaT5Ut6QdMDbxyVtZEQOs180fEPSce97oDSfJc277hsZESl/JHmrgUDrnfDCyO9kyU6SbkpaTg6mXOFKmlAnIGlJ0t0gq9sl8SV9dyUtZbIe0REIWnablCXHnTwS+jp/OhPQBcFfeHXHKGbdUJP0vKQ7hcjZDendOy7DotN5pKaK021TWDGiD6fHkuACTdJzkjZdSBuWI0k6M87xApEXC1HUF6nPxXGGF4g4E0jsgh+b7psV7Q7z/lwh4UnSij/fN24uhXBdlHQ/G41J64DWZSxG2WOI2Oftlcz25Mu56GtRgKS1rJiRpMvJ+R45JBF5tpCVJ0Xqe3ak4Y/rTyRczlaIzn17ZACbUOzId2wLWaEh4IKz32fDkdbbd8eUvBMVoi6LnvI6t/VCeD/5sgAcNTOlaGqygugFYH+o1wdexFz3imoSAhZG1PaT7lUsDEovAtzW6277IPiz33186HMz60diTcbsBrATmG+9HD2Wncz0Ka9v7bLz6xv+cll9d6+N23rMbW+DPzvu40Of00lO54lhPSjrgtIVD6tJCPhuSkdu5rJ6E+C2roT3uzAo65LssU1SXQZnvRCa+VK4bobqdng2D0Rm/khs5g9F67H4rH8YqZ/G6sfR+nm8/kGCWf6LTEVFRUVFRUVFRUVFRcUs4m9WLwNmcN/K5AAAAABJRU5ErkJggg==",
    i_world = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAE4UlEQVR42u1bz4scRRT+XndnTTDCbsRdyMlcvEXQkCAshBVDvOY/WAibIV485yiReMvFsxfPOQRykAREyUEUEhLYHAJe9GIgjrPZIBLM9PTnwVf6qK3+uT0znZ0uKLqmpuq9772qevXqF7DgQebBlGQU4E0RydCHA9wDSIqIkOR7AJZdtuL4VUR+cWUOpLa164Pkj9wbvtD/klliSuaki78AZAAm2gMSAH/PA8i8FBBppMZoXgY5WnQjGDUcy7Ebz12xLSTjmQwBkpGITEw6m7fwDkMTPFFNZomIZCQHJDc03cSOMCeiIZ4NkoN94KnGTL9bOm3tkjxdZ+oy0+DdwDR4tSYth+e0YiHJralMpQa4E/6lfnfqKMHQuaV1/yA51PSVGnSs8Dsepi3Lqw3hY/0OlMGYZEZy0kQJWu4oyRWSyxpXSB5u0PJO+IliGuvvgcXehoUVkh+RHBmGJJkGlBDNwJO0wqceppFilTZ7QRHj1DCupAQFtyfWwDDKwTC9hsjpeqkZFiT5nORaFYHqLqI0rikPyzNtOhTbUsLYdL9PSCbTGAY6FBPl4br8eGbC5yhhZKaxS661SloyVkFiFSry8grr6/eS4TuamfABJZwi+RvJy2UA6ljkorKG92XlfWo/wst+XVCSb4rIKM8Nda2mGyERgA8AfAjgfbMpsgvgAYDvAfykdP+r15T3LDc4pKwlSV4kuc3ysE3yYllvMMNhvouyAuGdco6TvG0EdA5L6kXnYLlwm+TxIiHbnGmm1TPOkHwSmC0yI7RTRhaw7k9InulESzfwHNdIPvXmbDtvh4L9z9V5anyLqPO7wgbkHQDnAKS670DD83cAPwDY1rx3AawDWPXKubrfAvhYjWLW5dZ3C6dNrxUz08U/J7kaqLuq//nlHY3N1hY4JY5KUhZL6h8i+dhbMaaaHnjbao6mnS0GWjb1VnqPlXaRo5RUiDLt1l8PCE+S1/T/pRAIVd6Spq8FVnoZyfW2e0HiORYnAGya0xp/G0sAvADwpYi88E5xXPkNTU/0G+mYv67AxyHnRh2lsZa5DmALwFvKN1OsG2o7JHDadATApwCOlOD/Wk+g/neeTOudZ7VwzJ+HDY2bpvVcC96o2nKGzo0AnZsBB8s5RMcqYj9vafjTyku1vO5r41i/w5wNTJe3Esh7pECrjD+3lH7k0bC08/gPPaw2WtkKt8XFxLz/0OHDXsmZ4oPYfQUcAhBrzAvLBcoBgGeBvJM6TqtsfVPLngwI8qzAfxHFloc9NjLuUYADNtQVWRYYHs6I/KldLE8B9wFc0PKxfs+q3XhedPxtxzOAs+bccGJo5ylgDOAbAG/kGEEn07BgGC3eNBgCEZXFDjtCUYU4PRv2KrrC/WJo0ZfD/YZIvyW24Jui/bb4oh+M9Edj/eFofzzeX5Dor8jM4ZLU4cAlqaOdvCTV8jU5B/6K1h3qVbkdkreq9qCZXpNr+aKko3E14AHerQO8rYuSlQuKSKpXU79SkD+LyD3NS2vq070TSNUbjTWNBnjukbwA4B3F1gRPo/V+7W5mWu0zY0+cEfuuIc3GeBrdFlcfPO7KKy/FE/2blMlMXow0YTRtJaB/MYJX6s2QO/DMzIlNtkgKeE1735LJe32RHk6eAPC2d4KzKyIPD/TDSfSPp/vH050L/wDW4oD9GRplzgAAAABJRU5ErkJggg==",
    i_stats = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAACh0lEQVR42u2by4rUQBSG/786DgqCC0EYxPUIs9YHGHwLd8LgxofwJYQRLy/h1jdw5663M7gQVBBE7bY7v4s+BaHppCqaLiaZc6BIXypVqS91O5cCXK62cIwPLSn53CQ1yTcmaZaZL0yuB0giSUm6AeA6AG21IX7/TrKO+afy5oNdn0g6l/RF0ret9NXSR0kP+/SEUXR7SY+UL58lHUpi15wRRjZZn1g3X9q1La0A3AFwbEOgtZ3VyDrDwmCExPwVGiA6JUx42WZO/vFPEP8pDsABOAAH4AAcgAO4ulJdMl1eJOtJAjDdfJ2j9paEUAyAGTIeALi5q902HD+RnJc0ZFSFDBkE8ALA00T2paRnJF+V6glh32PeGvHYGr8CULekNYADAC8l3TeTVhj7KhDV0SNrZOzqu9LMIBDAvVI2y1LL4DLDiBEbLAB/prYPGNyQ4RshB+AAHIADcAAOoIwuMGV/fDWUemr7/vWkAJhaGpWSWx3++N8kf43RH1+l3rz52V8DuNuyra0B/JT0nOTb0gaNvQCwMS9JhwDeYeNq7pLbAN5IOif5fkzDoW0VCNaVj63xq4Q/PvrrT8YWepOaBFcNHT7ljyc2/vtJ7QP6qqb0jZADcAAOwAE4AAfgAByAA3AADsABTABA1PdzRT1/71vnUOVkA7jWcFmnKquxCXDYJQeN+IBUObR691kOUgaRWMGFfW4GL7TZAQKA+db98Tq3/2M0SFudM7te7KmcfzqkdCppkXFG50zSbDusRVKw388yylhIOt112GmocnpZcBrH1I6wsQrXLff8IPkhA+ogUWJFo81yA5VS3qMc71JOfUOV08uG1wh163KNrUtFil7GiFOXscpfMYMftrnsp1IAAAAASUVORK5CYII=",
    i_settings = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAFf0lEQVR42u2bz4sVRxDHPzVvVkggkFUMJKAiwZAYcjARPIh6CQFDjoIHL+7/kIugN28JePCmFy/ecgwGNKc9KZgEjXFFCUGjBiNrDjEJ2X0z31yqodPOe29+vP3h21fQ7NuZnurq6qrqqupqmMLGBluLQSX1fOzSH2WAzKyYeI775Bu/e+klQJIBmJkk7QOOAB/66++Br8zsWtxvklbdwsQkndFgOJP2nxQGZN7O+UQLScuS+t6W/Zm8TyYpmyidlzTnE1ySVFasfunvJGlurWxCU7HOJPW82ZDVN0nzvsr9ISrQ9z7zAf+QscO42aqry6CVSZ8HXZa0WdLTaKUHQXj31L95wRbUHbsu5G302cwKX513gDeBP4GfzOwfSeaW3oDczJYlPW+44xjw3PHMSOoHnD72K8D7wGvAb8DdQJOZlauhz0cl3Yx0VpIeSDoVmBR/I+mApMe+wqMkoPS+B+JVDTglnfKxFNmUm5KOrqjdiAg4nRBdJJO65P22Svpc0g21hxuOY6vjvJQwq0j6n04XYNwrfyQyVv0KRiz778uSHlbodhOIv3noOJVsmaqg50gTSbAGXlwO/Oh6XwKDBijdtwfo+++2K1J6yytwp1D4u7vAB0C/jjeZ1TR6AnYBO/1xbwTOIiK8izhmjqOMJjgIAk07gV1uNLPODIikZBuwCajjo/c6TryKzjoiLadxW10Jb0LkMxfp9Q59p7U2Z0fqoduA28BiEsevJyidtkXgttNcdmaA639mZn8BZ18CBpx1WrM6RtCa+gHA18DhERZ5LSafAd8An/nClWNNiLhIhXYJ+MQtc6/D9pZKYxuGBhouA5+6IVTdhErTAQXMAu+2/L50HGF7i1vm78oWOwRO02zNXapZMJQENseB7W5t8xYrBbAAXAPu+/87gH3Aey5hTSTLnJbtwHEz+zIOoDq7wElgMyPp1gA/fBgEF/mqpI8l5RVj5f7uavJNHQjxyC1JM0kuotcpiem/ZyW9Lml/C99+OUp15Qlzc2+9hBHnWjAh0LTfaZ2tmkvTBOacpG89QfFM0pOGAU2QkvNxJmeExIWxzyc46sITp/Wp0z5XO9EaExitQlsIhF+P0me1Yo8ojXa9JRNSOJcyeFTYG1LX/3qYWdZIZlQxoJB0KIh2AynM/e+hCE8TVQit73OIU+69UZPfG+lf2XH177pOW8uka+44ukhBGdmSvSkTsgqn6NgYTo7CXj5vZv2WDk7m384nOOlw+nUsfZZVEL1njMdm9zvgsgQHYzgC3JMyczJOXzomGtLfP0Rub1fY0QGXEhydfLpkblkVA0KnixXP2jL2oFv0Nvpb+rcHO0prPIeLQ+e1obfBqSM0dYWnwdCGDIfzEQnRoiIhcgH4osZBRTpO4UmPK8CCpEEJkZA8yRt6njlwwWmc8ZOhctw5QYAtwHeegVFDL6+M8oqDtiw13PICDQ+AjzwtzkrlBA34A7jT0j/PorR6P2mBOVnLuOOO02YrUiY3qWnxrK4xdIQnfPL9dRZHZE7TYeCEmZVjOx6PdP9V4GfgjRZ6uponQ78DbwN/17EFWc24XMBuN4Bap1FkOFfYAuwOR3rjNIKb2xRVrQHkTuvYToeDCP0KLNU0nMWYD1BDgUQdlV5yWmtFs3VOh8Px+D3gl2iCw4jtRYap7DjxflQgUY5gOk7jPS+pK8elApmZLQMnIwkohhB7BXiUnPm1iePDGeIjxzmIqUUkASed1mxaJse0UHL8FyZCOWrDUtlNwONoG7URfv0i8JaZLUWBjSLcVaWy5YqXyk5isXQrXfHC5BfK5dNLT+6MhABqYUBlSFXlyEIIbFJPLhr7f+Xy6/bC1cRemJhemZmQS1PTa3PTi5PTq7NT2NDwH8vq7nVib7WEAAAAAElFTkSuQmCC",
    i_lab = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAEnklEQVR42u1bPW8UVxQ9d2Z3Y5PKjkWHBG6CJSJFwekJMg2IghI6JCooTY/oaPgNuOIHuF0hS2kdRUhBQSkQkWhAKHIV7MieOSl8nvL0NLOfb+cjniuN3ko7e+9955535747b4EzLhZDCUkDkFTse25mRCc1MoCkmRlJrgD4vmLfX5vZgfOhFvRIphq3WL1s+T7MKr1IWJwAyHUtOhc4GycxlPUiLiWXCEMAuIBlarESeGwAFvakKbDVKACOARwA+BrAIPjuCMChHOYUkySAZQBLBbb+1tgMITkguULyZyWoE5LH+vxM361pnORy9z6TjmPppGyskBw0igF6JBVF5YuZHcwI7JcRtpqVA0iWrfdUzvamyNzu3rTElk25pBYOAFQQFQZS33HSgsXdW6ZQ30VhQIIzLh0AHQAdAB0AHQAdAB0AHQAdAJE6wxY0QjKcdnAwR/cnC2p+i1UGRwVAdb6/G+xrM3NuDrXnpKMf7AbZGAAUDZJcAnDBa2h8ALAL4M0MrTF37xvp+OCx64JsRdkQxWBAqojcAXBZlE1w2h06BPDKo/M01Id+eyhdiXRfBnBHNlM0oBuUaNzzukGZPn8kuUpyqnXr7tdvP0pX5nWF9nzbdU4+laPXPCfpOXpf9/Vm0N3TeD/Q6Wxck+20VgA0vvR6d7muz+rtzZS1PRasSZfT63qNL2O8GJmL+nJwg+ShnKPn4NN5HfQAfhrozmVzQz4kdQDgKPq8wLl/SK7P65wH8rp0hiA/n3WJzf3o03We5CePnm6dvohFT48FL7xc4Ox9kg9Ri6Npor8dRMQlqM0FALAZ2HA2tytlgRf9JZK/KxKZF5lXom4SOd8k0p17j9pcPixVxgIv+neDx5Mbb8bOzh4LbpbYvFsZC4LCJ4zGW5LLsaPhsW5ZNkLWVVMYTVD4PFhUJDzmPaitMFpk4dP4wqiKwqfRhdGYwucoRuEzZWF0VFlhFNCvqPDZqaou91iwU1IYxV+GXvSfBAnIGb6iBNnXuMjL2bji2fd9ehKVBV70ByTfBY8gktytcTe6G/Qgcvk4mJQFk6CUmFlG8h6AdXVlUq9rs0/yutexqUKc/X0At70Tapl8vGdmO1ou2VwnRUkmZpaT3Aew6QHQRHG+/WJmPzrfZwZACOYAfgIwLOkjMsZRlYjH89yEbwDYcwyeuSmq5uO27mWJE0lNl5V0lBMA25O0z21MzU8A3wL4Ff+d1zM0W+idT/wBwB+ncSxeCsno4BsBPMbpgcWsBZN3Acrk82PNwaZigPf4+AbAW41oCQA+C/4CsKERRUsiGfOy4xGANSWWtkzeBSqX749GvUSxEdHvK/qXvMTSJnFBey8WHBexICkpfAjAFT55S1+jJ/LdFUaFQUxGrJ+H+P/Iw7IXtElY+KjquwXgKsrP67ZFUs3hKslbmls6SRLcin2WuEbpBXOaaPeXkvyO5NDb/bVN3O5wqLmkRbvDXtlJbDP7jeQQwHVl0H7LIu98HmouvaI6oDemFF7VMvmqhdR3Pq+OatPZmD9EXgJwUdnTWgaA8/lPM3tf6x8sW/vXWVHHWj5HjmuKnGn5FwQ+zU0MxXBOAAAAAElFTkSuQmCC",
    i_lock = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAADsklEQVR42u1bu24UMRQ9d9abEIqEBKWHP0iQUqTkoeUz+ANEhWhpIkSF6CipIvEHRAHKFEgkfQroIxQIUjbZ16HIdeI4s7uz9mg3m7Gl0Wge9vgcX1/bZ66Biifp94BkNuj5CIki0gvKeA3qUD0LICkiQpKrAO7EsK7l/xKRn7bcgi1v63AfwD2nrND0R0R2h9aBpJA0JDOSOywnbWjZZgTTN3reKKkOO4rJkLxE5KVKKTsd/fgRgJ5emwDWbb7TiJY7LakOR+oDrviBzHE2ILlC8ivJbQBr+ryu5hd6lNFNQ4+6Ylgjua3YVlzMxvMFywAeFh0phqS6nmsR4GsOkJi0COCxg/Ecl29WbQBdNRWjLxGA7Q72ukjqKoDjiIofAzh0yipqMdSWn3euO3qv3dcH6Ms1r9X/AljVc8go0FT/0ils8xfvvgPwIXAUWACw64xkNSVABhHQD8hvEfk39jFa5ATASeAkqlPEWot61roOH6N0AX90CQEhgU6TRf2GGWEqSZLBYAItgAGkQetaKG9W9alwIiARkAhIBCQCEgGJgOomkzPv7zgrP7ECyZSmjh50VogcRMBMzr3lkoSNSeidyzn3Z/IIsKzsA3jtXNvlbHMKCWgCeAVgzsOz72KeWMuSdHUHikh34rK4Lj9rAwSKMoDLWZGXf1SoRscyV5t9lOiu+w0Zc6uf6/Ik13Gh030RkR3/nRuV9J+DkFwiuZmj3W/qMwkUQq49ATUF90kBt72D+kzUP9ws8NbsFWgrxwLsvXU3z02ZCVqTbgxQeK2W1xinf0prgXH1Aj1vDVCWrWVseXmSE0zD4CRCZKoyEUpT4bQYUvZFpKcxOc9ylsPvRaQ5DfN0J75oDsDznOXwR41Zys6t0JmpNfrE2CxF/KwcOwF6XuqDpeFi9vtIK0cSO5zSMZkADnAWHeJKYq1hARLGI8AAU615Go8ASVPhREAiIBGQCEgEJAISAYmAEWZ5VqSQguF3Ew2U1DpKmQS0FQTHHCrLUP2RZLssAgTA3VF2fPjB0hrzG2IBt5zlbEiwtIQESLjh8ragvYhw+bcA3pA0RZUl590XAF5Ghsu79eGwAIm6fqjmFbgQYcm3I/MuliT81L2NHLkBEgcAvmlrP3DW0ojYrxMjdXWdsB0TAf4QwA+1igMXs1Fn09PzHoBHaoafATyJ+HhZTpMRZdm6fxeRp56D7V3pAo4q3NP+k8GLqRkh2XyzEeBnS6rDvKrO2VBVuNIbJ5G2zqbN05VL/wFz72Fzh3+emgAAAABJRU5ErkJggg==",
    i_close = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAABVElEQVR42u2awY6CMBRFoeEPZuFP6Mr4SSbOhxtXknEtcmbzjE2jI0Ip0+aehEjQ+O69aQu0rSohhBBCCCGEmABQl1jrI0GAS1DL/asQPEFfc4eQstZQQY19HoAjsPWvz1Rra7UOc9X6tNnveXAGdrGFeeZ3VuPOfpHuADigAb5NyA242nkbM4TAfGs1rlYT09Ak6w5AbccKuHiCALqYIbww3wU1L6alTtYSvMHIb5JdzBDemO+edDm31Oj/l8BRIQw03y5mfoLQZon/zCaE7MzHFJ6t+RgGsjc/xUgx5seGUJT5ESGs7SjH/MAQbt6DzDm4lr/5NyHcjfbeS00ffJe/+Rch/ASG++Ac+00Z5p+EsAFOgXE/iBOwSWneVUJdQIOgboN6ENKjsF6G9DqsCRFNiWlSVNPiWhjR0pgWR7U8rg0S2iKjTVLaJieEEEIIIYQonV98fka8QGcEcgAAAABJRU5ErkJggg==",
    i_min = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAv0lEQVR42u3WwQ3CMAyF4feaHlmCGWAfZmMYbiBGYITeONGaC5EqbpDKReL/pB4TO3YcVQIAAAAAAAAAAAD+glsWR0Rp3WMBYXuklZk3ICJsOyLiIGkraZLUJedeY95sH2tOWQXobE8RcZa0W7mJF9v7mtOni/vG4IOkh6RRUkk+eI05tGzSLzBC8y97fJvjthZg8+pCWeHql1kO6QWoj81J0n3lEbi+5YTMH6HuJw7xxesPAAAAAAAAAAAA/JknUUcwn5TVqmUAAAAASUVORK5CYII=",
}
E.SPRITE_B64 = B64
end

-- ==== en_05_sprites.lua ====
-- en_05_sprites: install the embedded PNGs to disk and resolve asset ids.
-- getcustomasset keys on the file's basename, so every sprite carries a unique
-- prefix or two different images can silently resolve to the same id.
do
    E.sprite = {}
    local X = E.X
    local B64 = E.SPRITE_B64 or {}
    E.SPRITE_B64 = nil

    local function nativeDecode()
        local G = getgenv()
        local c = rawget(G, "crypt")
        if type(c) == "table" then
            if type(c.base64decode) == "function" then return c.base64decode end
            if type(c.base64) == "table" and type(c.base64.decode) == "function" then return c.base64.decode end
        end
        for _, n in ipairs({ "base64_decode", "base64decode" }) do
            local f = rawget(G, n)
            if type(f) == "function" then return f end
        end
    end

    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local lookup = {}
    for i = 1, #alphabet do lookup[string.byte(alphabet, i)] = i - 1 end

    local function luaDecode(s)
        local out, n, bits, acc = table.create(math.floor(#s * 3 / 4)), 0, 0, 0
        for i = 1, #s do
            local v = lookup[string.byte(s, i)]
            if v then
                acc = acc * 64 + v
                bits = bits + 6
                if bits >= 8 then
                    bits = bits - 8
                    local byte = math.floor(acc / 2 ^ bits) % 256
                    n = n + 1
                    out[n] = string.char(byte)
                    acc = acc % 2 ^ bits
                end
            end
        end
        return table.concat(out, "", 1, n)
    end

    local decode = nativeDecode() or luaDecode

    local ok = X.writefile and X.getcustomasset and X.isfile
    E.cap.sprites = false
    if not ok then return end

    local folder = "EntrenchedHub"
    pcall(function()
        if X.isfolder and not X.isfolder(folder) and X.makefolder then X.makefolder(folder) end
    end)

    local installed, failed = 0, 0
    for name, data in pairs(B64) do
        local path = folder .. "/enh2_" .. name .. ".png"
        local good = E.try("sprite " .. name, function()
            local bytes = decode(data)
            local write = true
            if X.isfile(path) and X.readfile then
                local okr, cur = pcall(X.readfile, path)
                if okr and cur == bytes then write = false end
            end
            if write then X.writefile(path, bytes) end
            E.sprite[name] = X.getcustomasset(path)
        end)
        if good and E.sprite[name] then installed = installed + 1 else failed = failed + 1 end
    end
    E.cap.sprites = installed > 0 and failed == 0
    E.spriteStats = { installed = installed, failed = failed }
end

-- ==== en_06_game.lua ====
-- en_06_game: bindings to the game's own code and the liveness and team rules.
do
    local Game = {}
    E.game = Game
    local G = getgenv()
    local RS, Players, LP = E.RS, E.Players, E.LP

    local function find(parent, name, timeout)
        local t0 = os.clock()
        local v = parent:FindFirstChild(name)
        while not v and os.clock() - t0 < (timeout or 8) do
            task.wait(0.2)
            v = parent:FindFirstChild(name)
        end
        return v
    end

    ------------------------------------------------------------------------
    -- WeaponModule and the Crosshair global it resolves at call time
    ------------------------------------------------------------------------
    if E.inGame then
        local mod = find(RS, "WeaponModule")
        if mod then
            local ok, wm = pcall(require, mod)
            if ok and type(wm) == "table" and type(wm.Shoot) == "function" then
                Game.WM = wm
                local okEnv, env = pcall(getfenv, wm.Shoot)
                if okEnv and type(env) == "table" and type(rawget(env, "Crosshair")) == "function" then
                    Game.env = env
                    -- Pin the genuine function once per session. Later loads must
                    -- never mistake a wrapper for the original.
                    local wrappers = rawget(G, "__ENT_WRAPPERS")
                    if type(wrappers) ~= "table" then
                        wrappers = setmetatable({}, { __mode = "k" })
                        G.__ENT_WRAPPERS = wrappers
                    end
                    Game.wrappers = wrappers
                    local cur = rawget(env, "Crosshair")
                    local pinned = rawget(G, "__ENT_CROSSHAIR")
                    if type(pinned) ~= "function" then
                        if not wrappers[cur] then G.__ENT_CROSSHAIR = cur pinned = cur end
                    end
                    Game.Crosshair = pinned
                end
            end
        end
        local se = find(RS, "ServerEvents")
        local ce = find(RS, "ClientEvents")
        Game.Shoot = se and se:FindFirstChild("Shoot")
        Game.Hit = ce and ce:FindFirstChild("Hit")
        Game.Kill = ce and ce:FindFirstChild("Kill")
        Game.Projectile = ce and ce:FindFirstChild("Projectile")
    end

    E.cap.weaponModule = Game.WM ~= nil
    E.cap.crosshair = Game.env ~= nil and type(Game.Crosshair) == "function"
    E.cap.stateLookup = E.X.getconnections ~= nil or E.X.getgc ~= nil

    ------------------------------------------------------------------------
    -- Live per-weapon state table, the one WeaponModule.Shoot expects.
    -- Preferred route: upvalue 2 of the tool's own Equipped handler. getgc is a
    -- fallback and has been seen returning a stale copy with no animation
    -- tracks, so every candidate has its shape checked.
    ------------------------------------------------------------------------
    local stateCache = setmetatable({}, { __mode = "k" })

    local function shaped(t, tool)
        if type(t) ~= "table" or rawget(t, "Tool") ~= tool then return false end
        if type(rawget(t, "resetBool")) ~= "table" then return false end
        local al = rawget(t, "animationList")
        return type(al) == "table" and typeof(rawget(al, "equipAnimation")) == "Instance"
    end

    function Game.stateOf(tool)
        if not tool then return nil end
        local st = stateCache[tool]
        if st then return st end
        local X = E.X
        if X.getconnections then
            local ok, conns = pcall(X.getconnections, tool.Equipped)
            if ok then
                for _, c in ipairs(conns) do
                    local fn = c.Function
                    if fn and (not X.islclosure or X.islclosure(fn)) then
                        local okU, up = pcall(debug.getupvalue, fn, 2)
                        if okU and shaped(up, tool) then stateCache[tool] = up return up end
                    end
                end
            end
        end
        if X.getgc then
            local ok, gc = pcall(X.getgc, true)
            if ok then
                for _, t in ipairs(gc) do
                    if shaped(t, tool) then stateCache[tool] = t return t end
                end
            end
        end
        return nil
    end

    -- the equipped firearm and its state, or nil for melee, flamethrowers,
    -- flare guns, tools that are not weapons, and a character that cannot shoot
    function Game.equipped()
        local char = LP.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        if not tool or tool:GetAttribute("CanFire") == nil then return nil end
        if not tool:FindFirstChild("AmmoLoaded") then return nil end
        local tt = tool:GetAttribute("ToolType")
        if tt == "Flamethrower" or tt == "Flaregun" then return nil end
        return tool, Game.stateOf(tool), tt
    end

    ------------------------------------------------------------------------
    -- Teams and liveness. Team display names change between maps, so only
    -- Team object identity is compared. Health > 0 is wrong in both
    -- directions here: downed players regenerate and dead ones still read
    -- above zero while they wait to respawn.
    ------------------------------------------------------------------------
    local selectionRef = E.Teams:FindFirstChild("SelectionTeam")

    function Game.isEnemy(p)
        if p == LP or not p.Team or not LP.Team then return false end
        if selectionRef and selectionRef:IsA("ObjectValue") and p.Team == selectionRef.Value then return false end
        if p.Team.Name == "Selection" then return false end
        return p.Team ~= LP.Team
    end

    function Game.humanoid(char)
        return char and char:FindFirstChildOfClass("Humanoid")
    end

    function Game.isDowned(char)
        return char ~= nil and char:FindFirstChild("ReviveTime") ~= nil
    end

    function Game.isAlive(char)
        local h = Game.humanoid(char)
        if not h or h.Health <= 0 then return false end
        local ok, st = pcall(h.GetState, h)
        if ok and st == Enum.HumanoidStateType.Dead then return false end
        if char:FindFirstChild("RespawnDelay") then return false end
        return true
    end

    local spawnBase
    function Game.inLobby(char)
        if not spawnBase or not spawnBase.Parent then
            local sb = workspace:FindFirstChild("Spawnbox")
            spawnBase = sb and sb:FindFirstChild("Base")
        end
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not (spawnBase and root) then return false end
        return (root.Position - spawnBase.Position).Magnitude < 250
    end

    -- Whitelisted aim parts. The honeypot part AENcD and AimAttachPart are
    -- deliberately absent.
    Game.PARTS = {
        Head = true, UpperTorso = true, LowerTorso = true, HumanoidRootPart = true,
        LeftUpperArm = true, RightUpperArm = true, LeftLowerArm = true, RightLowerArm = true,
        LeftHand = true, RightHand = true, LeftUpperLeg = true, RightUpperLeg = true,
        LeftLowerLeg = true, RightLowerLeg = true, LeftFoot = true, RightFoot = true,
    }

    function Game.myHead()
        local c = LP.Character
        return c and c:FindFirstChild("Head")
    end

    function Game.enemyWeapon(char)
        local t = char and char:FindFirstChildOfClass("Tool")
        return t and t.Name or nil
    end

    -- the name shown anywhere in the hub; streamer mode hides real names
    function E.nameOf(p, fallback)
        if E.cfg.exp and E.cfg.exp.streamer then return fallback or "Enemy" end
        if typeof(p) ~= "Instance" then return fallback or "?" end
        local dn = p.DisplayName
        return (type(dn) == "string" and dn ~= "") and dn or p.Name
    end

    function Game.ping()
        local ok, p = pcall(LP.GetNetworkPing, LP)
        return ok and p or 0.06
    end
end

-- ==== en_07_world.lua ====
-- en_07_world: one snapshot of every valid enemy, rebuilt each render frame.
-- Aim, auto fire, ESP and radar all read this table so nothing re-walks the
-- player list or repeats liveness checks per feature.
do
    local Game = E.game
    local Players, LP = E.Players, E.LP

    local W = {
        list = {},              -- array of entries for this frame
        map = setmetatable({}, { __mode = "k" }), -- Player -> entry (persists)
        frame = 0,
        cam = workspace.CurrentCamera,
    }
    E.world = W

    -- The server resolves shots by raycasting from the camera position it is
    -- sent, through the Projectiles collision group, so sight lines are cast
    -- the same way. Cosmetic tracers are CanQuery and would otherwise block.
    local params = RaycastParams.new()
    params.CollisionGroup = "Projectiles"
    params.IgnoreWater = true
    params.FilterType = Enum.RaycastFilterType.Exclude

    local lastFilterChar, lastCosmetic
    local function refreshFilter()
        local char = LP.Character
        local cosmetic = workspace:FindFirstChild("CosmeticProjectiles")
        if char ~= lastFilterChar or cosmetic ~= lastCosmetic then
            local f = { char }
            if cosmetic then f[#f + 1] = cosmetic end
            params.FilterDescendantsInstances = f
            lastFilterChar, lastCosmetic = char, cosmetic
        end
    end

    function W.sightline(origin, part, char)
        if not part then return false end
        local dir = part.Position - origin
        local hit = workspace:Raycast(origin, dir, params)
        return hit == nil or hit.Instance:IsDescendantOf(char)
    end

    local VIS_TTL = 0.1

    local function torsoOf(char)
        return char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
    end

    local function build()
        W.frame = W.frame + 1
        local cam = workspace.CurrentCamera
        W.cam = cam
        if not cam then table.clear(W.list) return end
        local cf = cam.CFrame
        W.camPos, W.look = cf.Position, cf.LookVector
        W.vp = cam.ViewportSize
        refreshFilter()

        local now = os.clock()
        local list = W.list
        table.clear(list)

        for i, p in ipairs(Players:GetPlayers()) do
            if Game.isEnemy(p) then
                local char = p.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                local head = char and char:FindFirstChild("Head")
                local hum = Game.humanoid(char)
                if root and head and hum and Game.isAlive(char) and not Game.inLobby(char) then
                    local e = W.map[p]
                    if not e or e.char ~= char then
                        e = { player = p, visT = 0, weaponT = 0 }
                        W.map[p] = e
                    end
                    e.char, e.root, e.head, e.hum = char, root, head, hum
                    e.torso = torsoOf(char)
                    e.downed = Game.isDowned(char)
                    e.health, e.maxHealth = hum.Health, math.max(hum.MaxHealth, 1)
                    e.dist = (root.Position - W.camPos).Magnitude
                    e.vel = root.AssemblyLinearVelocity
                    e.spotted = hum:GetAttribute("Spotted") == true

                    -- stagger sight checks across frames so a full server does
                    -- not cast every ray in the same frame
                    if now - e.visT > VIS_TTL + (i % 5) * 0.004 then
                        e.visT = now
                        e.visHead = W.sightline(W.camPos, head, char)
                        e.visTorso = e.torso and W.sightline(W.camPos, e.torso, char) or false
                    end
                    e.visible = e.visHead or e.visTorso

                    if now - e.weaponT > 0.5 then
                        e.weaponT = now
                        e.weapon = Game.enemyWeapon(char)
                    end

                    -- angle off the crosshair, used by selection and auto fire
                    local d = head.Position - W.camPos
                    local m = d.Magnitude
                    e.angle = m > 0 and math.deg(math.acos(math.clamp(W.look:Dot(d / m), -1, 1))) or 180

                    list[#list + 1] = e
                end
            end
        end
    end

    E.bind("ENT_WORLD", Enum.RenderPriority.Camera.Value + 2, function()
        if not E.inGame then return end
        local ok, err = pcall(build)
        if not ok then E.fault("world snapshot", err) end
    end)

    E.connect(Players.PlayerRemoving, function(p) W.map[p] = nil end)
end

-- ==== en_08_aim.lua ====
-- en_08_aim: target selection, prediction, silent aim and the camera aimbot.
do
    local Game, W = E.game, E.world
    local UIS, LP = E.UIS, E.LP
    local cfg = E.cfg

    local Aim = {
        target = nil,          -- world entry currently locked
        part = nil,            -- the part being aimed at this frame
        point = nil,           -- predicted world point this frame
        route = "none",        -- how silent aim is installed
        wrapperCalls = 0,
        shots = 0,
        lastShotAt = 0,
        leadScale = 1,         -- multiplier from the self tuning lead, exactly 1 while it is off
        leadStats = nil,       -- what the self tuning lead has learned, for debugging
        -- how the current point was led, for reading back while testing
        leadInfo = { time = 0, flight = 0, delay = 0, dodge = 0, mode = "ground", scale = 1, speed = 0 },
    }
    E.aim = Aim

    local function finishing()
        local ex = cfg.exp
        return ex ~= nil and ex.finishDowned == true
    end

    ------------------------------------------------------------------------
    -- Part choice. When sight is required and the chosen part is covered but
    -- the other is not, aim at the one that can actually be hit. In a trench a
    -- head peeks over cover while the body stays hidden, and the reverse
    -- happens behind a loophole.
    ------------------------------------------------------------------------
    local function pickPart(e)
        local want = cfg.aim.part
        local head, torso = e.head, e.torso or e.root
        if want == "Closest" then
            local look, origin = W.look, W.camPos
            local function off(p)
                local d = p.Position - origin
                return (d - look * d:Dot(look)).Magnitude
            end
            if cfg.aim.visible then
                if e.visHead and not e.visTorso then return head end
                if e.visTorso and not e.visHead then return torso end
            end
            return off(head) <= off(torso) and head or torso
        end
        local primary, secondary, pVis, sVis
        if want == "Torso" then
            primary, secondary, pVis, sVis = torso, head, e.visTorso, e.visHead
        else
            primary, secondary, pVis, sVis = head, torso, e.visHead, e.visTorso
        end
        if cfg.aim.visible and not pVis and sVis then return secondary end
        return primary
    end

    local function valid(e, fovLimit)
        if not e then return false end
        -- a downed enemy is normally left alone, it is no threat until revived.
        -- The finish downed experiment wants exactly those.
        if e.downed and not finishing() then return false end
        if not e.char or not e.char.Parent then return false end
        if e.dist > cfg.aim.maxDist then return false end
        if e.angle > fovLimit then return false end
        if cfg.aim.visible and not e.visible then return false end
        return true
    end

    local function better(a, b)
        if finishing() then
            local ad, bd = a.downed == true, b.downed == true
            if ad ~= bd then return ad end
        end
        local pr = cfg.aim.priority
        if pr == "Distance" then return a.dist < b.dist end
        if pr == "Health" then
            if math.abs(a.health - b.health) > 1 then return a.health < b.health end
        end
        return a.angle < b.angle
    end

    local function select()
        local half = cfg.aim.fov / 2
        local cur = Aim.target
        -- sticky: hold the current target through small crosshair drift so the
        -- lock does not flicker between two people standing close together
        if cfg.aim.sticky and cur and W.map[cur.player] == cur and valid(cur, half * 1.5) then
            if not (finishing() and not cur.downed) then return cur end
            -- finishing a downed enemy outranks the lock, because a teammate
            -- can revive them while we stay on someone else
            local swap
            for _, e in ipairs(W.list) do
                if e ~= cur and e.downed and valid(e, half) and (not swap or better(e, swap)) then swap = e end
            end
            return swap or cur
        end
        local best
        for _, e in ipairs(W.list) do
            if valid(e, half) and (not best or better(e, best)) then best = e end
        end
        return best
    end

    ------------------------------------------------------------------------
    -- Prediction. Replicated velocity is honest in this game (observed over
    -- reported measured at 0.99), and the server flies every bullet itself at
    -- the Tool's Velocity with no gravity, so a moving target is hit where it
    -- will be when the bullet arrives, not where it is drawn now.
    --
    -- Every enemy keeps a small track, fed once a frame from the velocity the
    -- world snapshot already read:
    --   short average   about 0.1s, follows the current run
    --   long average    about 0.7s, the drift underneath side to side dodging
    --   acceleration    from successive short averages, clamped and fading
    --   reversal rate   how often the run direction flips, which is A and D
    --                   dodging when it is high
    ------------------------------------------------------------------------
    local VEL_TAU        = 0.10   -- short velocity average, seconds
    local LONG_TAU       = 0.70   -- long velocity average, seconds
    local ACC_TAU        = 0.15   -- acceleration average, seconds
    local ACC_DECAY      = 0.35   -- acceleration fades toward zero over this many seconds
    local ACC_MAX        = 45     -- studs per second squared; humanoids change speed almost at once, so more is noise
    local RAW_SPEED_MAX  = 120    -- a fling reads far faster than this and says nothing about where they go next
    local SPEED_CAP      = 24     -- the client kicks itself above 23 studs per second, so no legit run is faster
    local TRACK_STALE    = 0.5    -- a gap in samples longer than this starts the track again
    local REV_MIN_SPEED  = 4      -- slower than this the run direction is too noisy to read
    local REV_COS        = -0.5   -- a direction change past 120 degrees is a reversal
    local REV_WINDOW     = 0.6    -- but only if the old direction was still seen this recently
    local REV_RATE_TAU   = 1.5    -- reversals are counted over roughly this many seconds

    -- Lead time is bullet flight plus network delay. GetNetworkPing is a round
    -- trip, and both legs matter: what we see of an enemy is already behind
    -- the server, and our shot then takes time to reach it. On top of that
    -- Roblox draws other players a little in the past to smooth them out.
    local DEFAULT_SPEED  = 2500   -- muzzle speed when the Tool has no Velocity attribute
    local INTERP_BUFFER  = 0.05   -- seconds other characters are drawn behind their newest update
    local PING_MAX       = 0.4    -- a lag spike beyond this is not worth chasing with the aim
    local SOLVE_STEPS    = 4      -- fixed point steps; bullets are 75 times faster than a runner, so 4 is plenty
    local MAX_LEAD       = 16     -- studs, the furthest the point may sit from the real part
    local MIN_LEAD_CAP   = 4      -- studs, so a close target still gets its network lead
    local LEAD_DIST_FRAC = 0.25   -- and never more than a quarter of the distance
    local AIR_VY         = 1.5    -- vertical speed that confirms a jump or fall
    local VY_MAX         = 150

    local STATE = Enum.HumanoidStateType
    local tracks = setmetatable({}, { __mode = "k" })   -- world entry -> track

    local function finite(n)
        return n == n and n > -math.huge and n < math.huge
    end

    local function sample(e, now)
        local v = e.vel
        if not v then return end
        local x, z = v.X, v.Z
        if not (finite(x) and finite(z)) then return end
        x, z = math.clamp(x, -RAW_SPEED_MAX, RAW_SPEED_MAX), math.clamp(z, -RAW_SPEED_MAX, RAW_SPEED_MAX)
        local tr = tracks[e]
        if not tr or now - tr.t > TRACK_STALE then
            tracks[e] = {
                t = now, vx = x, vz = z, lx = x, lz = z, ax = 0, az = 0,
                hx = 0, hz = 0, hT = -1, rate = 0, speed = math.sqrt(x * x + z * z),
            }
            return
        end
        local dt = now - tr.t
        if dt <= 1e-4 then return end
        tr.t = now

        local pvx, pvz = tr.vx, tr.vz
        local kv = 1 - math.exp(-dt / VEL_TAU)
        local vx, vz = pvx + (x - pvx) * kv, pvz + (z - pvz) * kv
        tr.vx, tr.vz = vx, vz
        tr.speed = math.sqrt(vx * vx + vz * vz)

        local kl = 1 - math.exp(-dt / LONG_TAU)
        tr.lx, tr.lz = tr.lx + (x - tr.lx) * kl, tr.lz + (z - tr.lz) * kl

        local ka, fade = 1 - math.exp(-dt / ACC_TAU), math.exp(-dt / ACC_DECAY)
        local ax = (tr.ax + ((vx - pvx) / dt - tr.ax) * ka) * fade
        local az = (tr.az + ((vz - pvz) / dt - tr.az) * ka) * fade
        local am = math.sqrt(ax * ax + az * az)
        if am > ACC_MAX then ax, az = ax * ACC_MAX / am, az * ACC_MAX / am end
        tr.ax, tr.az = ax, az

        -- The heading follows gradual turns frame by frame, so only a sharp
        -- flip counts. A and D dodging passes through a near stop, which is
        -- skipped, and the next reading points the other way.
        tr.rate = tr.rate * math.exp(-dt / REV_RATE_TAU)
        local sp = math.sqrt(x * x + z * z)
        if sp > REV_MIN_SPEED then
            local dx, dz = x / sp, z / sp
            if tr.hT >= 0 and dx * tr.hx + dz * tr.hz < REV_COS and now - tr.hT <= REV_WINDOW then
                tr.rate = tr.rate + 1
            end
            tr.hx, tr.hz, tr.hT = dx, dz, now
        end
    end

    -- While someone dodges, the way they will be running when the bullet lands
    -- is close to a coin flip. Treating each reversal as a random event at the
    -- measured rate f, the distance they still cover in their current run over
    -- t seconds shrinks by (1 - e^(-2ft)) / (2ft). That share of the lead comes
    -- from the current run and the rest from the long average. A steady runner
    -- has f near zero and keeps the short average plus acceleration in full.
    local function keep(tr, t)
        local x = 2 * (tr.rate / REV_RATE_TAU) * t
        if x < 1e-3 then return 1 end
        return (1 - math.exp(-x)) / x
    end

    local function drift(tr, t)
        local k = keep(tr, t)
        -- an average of a steady speed change trails it by acceleration times
        -- the time constant, so that is added back first
        local cx, cz = tr.vx + tr.ax * VEL_TAU, tr.vz + tr.az * VEL_TAU
        local bx, bz = tr.lx + (cx - tr.lx) * k, tr.lz + (cz - tr.lz) * k
        local half = 0.5 * k * t * t
        local ox, oz = bx * t + tr.ax * half, bz * t + tr.az * half
        -- acceleration may turn or stop a run, never push it past a speed a
        -- humanoid can actually reach
        local cap = math.max(math.sqrt(bx * bx + bz * bz), SPEED_CAP) * t
        local m = math.sqrt(ox * ox + oz * oz)
        if m > cap and m > 0 then ox, oz = ox * cap / m, oz * cap / m end
        return ox, oz, k
    end

    local function moveMode(hum, vy)
        local ok, st = pcall(hum.GetState, hum)
        if ok then
            if st == STATE.Freefall or st == STATE.Jumping then return "air" end
            if st == STATE.Climbing then return "climb" end
        end
        -- FloorMaterial is not trusted alone on other players' humanoids, so it
        -- only counts together with real vertical speed
        if hum.FloorMaterial == Enum.Material.Air and math.abs(vy) > AIR_VY then return "air" end
        return "ground"
    end

    -- On the ground a jump bob or a slope reverses long before the bullet
    -- lands, so vertical speed is ignored. In the air it follows the arc.
    local function rise(mode, vy, g, t)
        if mode == "air" then return vy * t - 0.5 * g * t * t end
        if mode == "climb" then return vy * t end
        return 0
    end

    local groundParams = RaycastParams.new()
    groundParams.FilterType = Enum.RaycastFilterType.Exclude
    groundParams.IgnoreWater = true
    pcall(function() groundParams.RespectCanCollide = true end)
    local gfChar, gfMine, gfCosmetic

    -- An arc can carry the prediction through the floor. Cast straight down
    -- from just above the target's current feet at the predicted spot, so a
    -- step or trench lip is caught but a roof overhead is not, and keep the
    -- root at least standing height above whatever is there.
    local function landing(e, root, hum, x, z, vo)
        local mine = LP.Character
        local cosmetic = workspace:FindFirstChild("CosmeticProjectiles")
        if e.char ~= gfChar or mine ~= gfMine or cosmetic ~= gfCosmetic then
            local f = { e.char }
            if mine then f[#f + 1] = mine end
            if cosmetic then f[#f + 1] = cosmetic end
            groundParams.FilterDescendantsInstances = f
            gfChar, gfMine, gfCosmetic = e.char, mine, cosmetic
        end
        local rootY = root.Position.Y
        local stand = hum.HipHeight + root.Size.Y * 0.5
        if not finite(stand) or stand <= 0 then stand = 3 end
        local hit = workspace:Raycast(Vector3.new(x, rootY - stand + 1, z), Vector3.new(0, vo - 3, 0), groundParams)
        if hit then
            local lowest = hit.Position.Y + stand - rootY
            if vo < lowest then return lowest end
        end
        return vo
    end

    -- Same firearm filter as Game.equipped, without its state table lookup,
    -- which can fall back to a full getgc scan and has no place in a frame.
    local function muzzleSpeed()
        local char = LP.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        if tool and tool:GetAttribute("CanFire") ~= nil and tool:FindFirstChild("AmmoLoaded") then
            local tt = tool:GetAttribute("ToolType")
            if tt ~= "Flamethrower" and tt ~= "Flaregun" then
                local v = tool:GetAttribute("Velocity")
                if type(v) == "number" and finite(v) and v > 0 then return v end
            end
        end
        return DEFAULT_SPEED
    end

    local function leadMultiplier()
        local ex = cfg.exp
        if ex and ex.adaptiveLead then return Aim.leadScale end
        return 1
    end

    local function lead(e, part, pos)
        local root, hum = e.root, e.hum
        if not (root and hum) then return pos end
        local now = os.clock()
        local tr = tracks[e]
        if not tr or now - tr.t > TRACK_STALE then
            sample(e, now)
            tr = tracks[e]
            if not tr then return pos end
        end

        -- the game casts every shot from your own Head, not the camera
        local head = Game.myHead()
        local origin = head and head.Position or W.camPos
        if not origin then return pos end

        local speed = muzzleSpeed()

        local ping = Game.ping()
        if type(ping) ~= "number" or not finite(ping) then ping = 0 end
        local delay = math.clamp(ping, 0, PING_MAX) + INTERP_BUFFER

        local vy = e.vel and e.vel.Y or 0
        if not finite(vy) then vy = 0 end
        vy = math.clamp(vy, -VY_MAX, VY_MAX)
        local mode = moveMode(hum, vy)
        local g = workspace.Gravity
        if not finite(g) then g = 196.2 end

        local dx, dy, dz = pos.X - origin.X, pos.Y - origin.Y, pos.Z - origin.Z
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        local t = delay + dist / speed
        local hx, hz, k, vo
        for _ = 1, SOLVE_STEPS do
            hx, hz, k = drift(tr, t)
            vo = rise(mode, vy, g, t)
            local fx, fy, fz = dx + hx, dy + vo, dz + hz
            t = delay + math.sqrt(fx * fx + fy * fy + fz * fz) / speed
        end
        hx, hz, k = drift(tr, t)
        vo = rise(mode, vy, g, t)

        local scale = leadMultiplier()
        hx, hz = hx * scale, hz * scale

        local maxLead = math.min(MAX_LEAD, math.max(MIN_LEAD_CAP, dist * LEAD_DIST_FRAC))
        local m = math.sqrt(hx * hx + vo * vo + hz * hz)
        if m > maxLead then
            local s = maxLead / m
            hx, vo, hz = hx * s, vo * s, hz * s
        end

        if mode == "air" and vo < 0 then
            vo = landing(e, root, hum, pos.X + hx, pos.Z + hz, vo)
        end

        if not (finite(hx) and finite(vo) and finite(hz) and finite(t)) then return pos end

        if e == Aim.target then
            local li = Aim.leadInfo
            li.target, li.time, li.flight, li.delay = e, t, t - delay, delay
            li.dodge, li.mode, li.scale, li.speed = 1 - k, mode, scale, speed
        end
        return Vector3.new(pos.X + hx, pos.Y + vo, pos.Z + hz)
    end

    local leadFaulted = false
    function Aim.predict(e, part)
        local pos = part.Position
        if not cfg.aim.predict then return pos end
        local ok, pt = pcall(lead, e, part, pos)
        if ok and typeof(pt) == "Vector3" then return pt end
        if not ok and not leadFaulted then
            leadFaulted = true
            E.fault("aim lead", pt)
        end
        return pos
    end

    ------------------------------------------------------------------------
    -- Self tuning lead (Experiments). The lead model can be off in ways the
    -- client cannot see, such as how far behind the server really keeps
    -- positions or how a player's dodge rhythm lines up with bullet flight.
    -- So a plain multiplier on the lead is learned from results. Five scales
    -- compete as a small multi armed bandit: each block of shots uses the
    -- scale with the best hit rate so far, and about 15 percent of blocks try
    -- one at random. Only shots that can teach anything count: a target far
    -- enough away and moving fast enough that the lead decides the hit.
    ------------------------------------------------------------------------
    local SCALES        = { 0.6, 0.8, 1.0, 1.2, 1.4 }
    local BASE_ARM      = 3        -- 1.0, the plain lead
    local EXPLORE       = 0.15
    local BLOCK_SHOTS   = 3        -- a scale is kept for a few shots so hits from a burst land on the scale that fired them
    local LEARN_SPEED   = 5        -- studs per second
    local LEARN_DIST    = 60       -- studs
    local HIT_WINDOW    = 0.5      -- seconds past the flight time a hit still counts for its shot
    local FORGET        = 0.995    -- old results fade, so it keeps adjusting as ping and weapons change
    local PRIOR_HITS    = 0.5      -- an untried scale is assumed to land one shot in four
    local PRIOR_SHOTS   = 2
    local MAX_PENDING   = 40
    local CAM_STEER_COS = math.cos(math.rad(1.5))

    local Lead = { arm = BASE_ARM, blockLeft = BLOCK_SHOTS, pending = {} }
    local pointArm = BASE_ARM      -- the scale the current Aim.point was built with
    local openShot = nil           -- recorded by the shot listener, kept or dropped once the shot is decided

    local stats = { arms = {}, pending = 0, resolved = 0, hits = 0, explored = 0, lastPick = "start" }
    for i, s in ipairs(SCALES) do stats.arms[i] = { scale = s, shots = 0, hits = 0, rate = 0 } end
    Aim.leadStats = stats

    local function resetLearning()
        table.clear(Lead.pending)
        openShot = nil
        Lead.arm, Lead.blockLeft = BASE_ARM, BLOCK_SHOTS
        pointArm = BASE_ARM
        Aim.leadScale = 1
        for _, a in ipairs(stats.arms) do a.shots, a.hits, a.rate = 0, 0, 0 end
        stats.pending, stats.resolved, stats.hits, stats.explored, stats.lastPick = 0, 0, 0, 0, "start"
    end

    local function pickArm()
        local arm
        if math.random() < EXPLORE then
            arm = math.random(1, #SCALES)
            stats.explored = stats.explored + 1
            stats.lastPick = "explore"
        else
            local bestMean
            for i, a in ipairs(stats.arms) do
                local mean = (a.hits + PRIOR_HITS) / (a.shots + PRIOR_SHOTS)
                -- a tie goes to the scale nearest 1, so an empty table starts on plain lead
                if not arm or mean > bestMean + 1e-9
                    or (math.abs(mean - bestMean) <= 1e-9 and math.abs(SCALES[i] - 1) < math.abs(SCALES[arm] - 1)) then
                    arm, bestMean = i, mean
                end
            end
            stats.lastPick = "best"
        end
        Lead.arm, Lead.blockLeft = arm, BLOCK_SHOTS
        Aim.leadScale = SCALES[arm]
    end

    local function resolve(arm, hit)
        for _, a in ipairs(stats.arms) do a.shots, a.hits = a.shots * FORGET, a.hits * FORGET end
        local a = stats.arms[arm]
        if a then
            a.shots = a.shots + 1
            if hit then a.hits = a.hits + 1 end
        end
        for _, b in ipairs(stats.arms) do b.rate = b.shots > 0 and b.hits / b.shots or 0 end
        stats.resolved = stats.resolved + 1
        if hit then stats.hits = stats.hits + 1 end
    end

    -- a shot whose window has passed with no hit on its target was a miss
    local function expire(now)
        local list = Lead.pending
        local i = 1
        while i <= #list do
            local r = list[i]
            if now - r.at > r.flight + HIT_WINDOW then
                table.remove(list, i)
                resolve(r.arm, false)
            else
                i = i + 1
            end
        end
        stats.pending = #list
    end

    -- Runs inside the game's shot, before silent aim decides. Only notes the
    -- shot; settleShot keeps it once it is known the bullet went to the point.
    local function recordShot()
        openShot = nil
        local ex = cfg.exp
        if not (ex and ex.adaptiveLead and cfg.aim.predict) then return end
        local e, li = Aim.target, Aim.leadInfo
        if not (e and Aim.point and e.char and li.target == e) then return end
        local tr = tracks[e]
        if not tr or tr.speed < LEARN_SPEED or (e.dist or 0) < LEARN_DIST then return end
        openShot = {
            at = os.clock(), name = e.char.Name, arm = pointArm,
            flight = li.flight, eta = li.flight + li.delay,
        }
    end

    local function settleShot(pt)
        local rec = openShot
        openShot = nil
        if not rec then return end
        local steered = pt ~= nil
        if not steered and cfg.cam.enabled and Aim.point then
            -- without silent aim the bullet goes where the camera looks, which
            -- is the led point only while the camera aimbot sits on it
            local cam = workspace.CurrentCamera
            if cam then
                local cf = cam.CFrame
                local d = Aim.point - cf.Position
                local m = d.Magnitude
                steered = m > 0 and cf.LookVector:Dot(d / m) >= CAM_STEER_COS
            end
        end
        -- a shot left where the player aimed says nothing about the lead
        if not steered then return end
        local list = Lead.pending
        if #list >= MAX_PENDING then
            local old = table.remove(list, 1)
            resolve(old.arm, false)
        end
        list[#list + 1] = rec
        expire(rec.at)
        Lead.blockLeft = Lead.blockLeft - 1
        if Lead.blockLeft <= 0 then pickArm() end
    end

    -- ClientEvents.Hit arrives once per damaging hit. A burst can have several
    -- shots waiting on the same target, so the hit goes to the one whose
    -- expected arrival (flight plus network delay) is closest to now.
    local function onHit(info)
        local ex = cfg.exp
        if not (ex and ex.adaptiveLead) then return end
        if type(info) ~= "table" or type(info.victim) ~= "string" then return end
        local now = os.clock()
        local best, bestErr
        for i, r in ipairs(Lead.pending) do
            local age = now - r.at
            if r.name == info.victim and age >= 0 and age <= r.flight + HIT_WINDOW then
                local err = math.abs(age - r.eta)
                if not best or err < bestErr then best, bestErr = i, err end
            end
        end
        if best then
            local r = table.remove(Lead.pending, best)
            resolve(r.arm, true)
        end
        expire(now)
    end

    -- Hooked the first time the experiment is switched on, so nothing extra
    -- runs on a shot for anyone who never uses it.
    local learnerHooked = false
    E.watch("exp.adaptiveLead", function(on)
        if on then
            if not learnerHooked then
                learnerHooked = true
                Aim.onShot(recordShot)
                E.on("hit", onHit)
            end
        else
            resetLearning()
        end
    end)
    E.onUnload(resetLearning)

    local function frame()
        if not E.inGame then return end
        if cfg.aim.predict then
            local now = os.clock()
            for _, e in ipairs(W.list) do sample(e, now) end
        end
        local t = select()
        Aim.target = t
        if t then
            local part = pickPart(t)
            Aim.part = part
            Aim.point = part and Aim.predict(t, part) or nil
            pointArm = Lead.arm
        else
            Aim.part, Aim.point = nil, nil
        end
        if #Lead.pending > 0 then expire(os.clock()) end
    end

    E.bind("ENT_AIM", Enum.RenderPriority.Camera.Value + 4, function()
        local ok, err = pcall(frame)
        if not ok then E.fault("aim frame", err) end
    end)

    ------------------------------------------------------------------------
    -- Silent aim. WeaponModule calls the global Crosshair(state, camera, 1000)
    -- inside shootEffect to decide where a shot goes, and Crosshair(state,
    -- camera) with no range from its per frame torso look. Answering the 1000
    -- call with the target makes the game build every value it sends from
    -- that point itself, so aim point, hit list and miss count stay consistent.
    ------------------------------------------------------------------------
    local shotListeners = {}
    function Aim.onShot(fn) shotListeners[#shotListeners + 1] = fn end

    local function decide()
        if not cfg.aim.silent then return nil end
        if not Aim.point then return nil end
        if cfg.aim.hitChance < 100 and math.random(1, 100) > cfg.aim.hitChance then return nil end
        return Aim.point
    end

    -- decided once per shot, inside the game's own call
    function Aim.shotPoint(state)
        Aim.shots = Aim.shots + 1
        Aim.lastShotAt = os.clock()
        for _, fn in ipairs(shotListeners) do pcall(fn, state) end
        local pt = decide()
        pcall(settleShot, pt)
        return pt
    end

    local env, ORIG = Game.env, Game.Crosshair

    local function install()
        if not (E.cap.crosshair and env and type(ORIG) == "function") then
            Aim.route = "unavailable"
            return
        end

        -- route 1: replace the module global and call the genuine function
        local wrapper
        wrapper = function(state, cam, range)
            local EE = rawget(getgenv(), "__ENTRENCHED")
            if EE and EE.alive and EE.aim then
                EE.aim.wrapperCalls = EE.aim.wrapperCalls + 1
                if range == 1000 then
                    local ok, pt = pcall(EE.aim.shotPoint, state)
                    if ok and pt then return pt end
                end
            end
            return ORIG(state, cam, range)
        end
        Game.wrappers[wrapper] = true
        env.Crosshair = wrapper
        Aim.route = "global"
        E.onUnload(function()
            if rawget(env, "Crosshair") == wrapper then env.Crosshair = ORIG end
        end)

        -- The swap only works if the module looks Crosshair up at call time.
        -- It does after getfenv has touched the environment, but prove it: the
        -- torso look calls Crosshair every frame while a weapon is out.
        task.spawn(function()
            local armedSince
            while E.alive and Aim.route == "global" do
                task.wait(0.25)
                if Game.equipped() then
                    armedSince = armedSince or os.clock()
                    if Aim.wrapperCalls > 0 then return end
                    if os.clock() - armedSince > 2 then break end
                else
                    armedSince = nil
                end
            end
            if not E.alive or Aim.wrapperCalls > 0 or Aim.route ~= "global" then return end

            -- route 2: hookfunction. The clone it returns has been seen with
            -- dead upvalues on this executor, so it is only trusted if every
            -- upvalue it carries is still alive.
            if rawget(env, "Crosshair") == wrapper then env.Crosshair = ORIG end
            local X = E.X
            if not (X.hookfunction and X.restorefunction) then
                Aim.route = "unavailable"
                E.fault("silent aim", "global swap had no effect and hookfunction is unavailable")
                return
            end
            -- Record the genuine upvalue shape BEFORE hooking. pairs() never
            -- yields a nil slot, so a dead upvalue shows up as a missing entry or
            -- a changed type, which only a before and after comparison can see.
            local wantTypes = {}
            local okO, origUps = pcall(debug.getupvalues, ORIG)
            if okO and type(origUps) == "table" then
                for k, v in pairs(origUps) do wantTypes[k] = typeof(v) end
            end
            local clone
            local okH = pcall(function()
                clone = X.hookfunction(ORIG, function(state, cam, range)
                    local EE = rawget(getgenv(), "__ENTRENCHED")
                    if EE and EE.alive and EE.aim and range == 1000 then
                        local ok, pt = pcall(EE.aim.shotPoint, state)
                        if ok and pt then return pt end
                    end
                    return clone(state, cam, range)
                end)
            end)
            local healthy = okH and type(clone) == "function" and next(wantTypes) ~= nil
            if healthy then
                local okU, ups = pcall(debug.getupvalues, clone)
                if not (okU and type(ups) == "table") then
                    healthy = false
                else
                    for k, ty in pairs(wantTypes) do
                        if typeof(ups[k]) ~= ty then healthy = false break end
                    end
                end
            end
            if not healthy then
                pcall(X.restorefunction, ORIG)
                Aim.route = "unavailable"
                E.fault("silent aim", "hookfunction clone was not usable")
                return
            end
            Aim.route = "hook"
            E.onUnload(function() pcall(X.restorefunction, ORIG) end)
        end)
    end
    install()
    E.cap.silentAim = Aim.route ~= "unavailable"

    ------------------------------------------------------------------------
    -- Camera aimbot. The game's camera is incremental: it reads the current
    -- look vector back each frame and adds only mouse delta, so a rotation
    -- written after it is carried forward and also soaks up recoil.
    ------------------------------------------------------------------------
    local rmb = false
    E.connect(UIS.InputBegan, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton2 then rmb = true end
    end)
    E.connect(UIS.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton2 then rmb = false end
    end)
    E.connect(UIS.WindowFocusReleased, function() rmb = false end)

    E.bind("ENT_CAMAIM", Enum.RenderPriority.Camera.Value + 6, function(dt)
        if not (E.inGame and cfg.cam.enabled and Aim.point) then return end
        if cfg.cam.hold and not rmb then return end
        local cam = workspace.CurrentCamera
        if not cam or cam.CameraType ~= Enum.CameraType.Custom then return end
        if E.ui and E.ui.altHeld then return end    -- never fight the user while they click the panel
        local cf = cam.CFrame
        local goal = CFrame.lookAt(cf.Position, Aim.point)
        local s = math.clamp(cfg.cam.smooth, 0, 1)
        if s <= 0.001 then
            cam.CFrame = goal
        else
            -- framerate independent exponential approach
            local rate = 40 * (1 - s) ^ 2 + 2.5
            cam.CFrame = cf:Lerp(goal, 1 - math.exp(-rate * dt))
        end
    end)
end

-- ==== en_09_fire.lua ====
-- en_09_fire: hold to fire for bolt actions, auto fire, auto reload.
--
-- Measured on a live server: after every accepted shot the server sets the
-- Tool's CanFire attribute false and replicates it back in about 0.06s. A shot
-- sent while it is false is silently discarded (no echo, no ammo used) even
-- though it looks and sounds real on the client. So nothing here ever tries to
-- beat that lock. Every shot waits for it, and waits for the server to
-- acknowledge the previous shot before trusting CanFire again.
do
    local Game, Aim, W = E.game, E.aim, E.world
    local UIS = E.UIS
    local cfg = E.cfg

    local Fire = {
        pendingAck = false,
        lastSent = 0,
        sent = 0,
        mode = "idle",
        lastReload = 0,
    }
    E.fire = Fire

    ------------------------------------------------------------------------
    -- Server acknowledgement. The lock turning on, or the magazine dropping,
    -- both mean the server took the shot.
    ------------------------------------------------------------------------
    local watchedTool, ackConns = nil, {}
    local function watch(tool)
        if tool == watchedTool then return end
        for _, c in ipairs(ackConns) do pcall(function() c:Disconnect() end) end
        table.clear(ackConns)
        watchedTool = tool
        Fire.pendingAck = false
        if not tool then return end
        local ok1, c1 = pcall(function()
            return tool:GetAttributeChangedSignal("CanFire"):Connect(function()
                if tool:GetAttribute("CanFire") == false then Fire.pendingAck = false end
            end)
        end)
        if ok1 and c1 then ackConns[#ackConns + 1] = c1 end
        local ammo = tool:FindFirstChild("AmmoLoaded")
        if ammo then
            local ok2, c2 = pcall(function()
                return ammo.Changed:Connect(function() Fire.pendingAck = false end)
            end)
            if ok2 and c2 then ackConns[#ackConns + 1] = c2 end
        end
    end
    E.onUnload(function() watch(nil) end)

    ------------------------------------------------------------------------
    -- Input
    ------------------------------------------------------------------------
    -- The game stores the input object on the state when its own fire action
    -- receives a press, and clears it on release, unequip and focus loss. That
    -- already excludes presses swallowed by chat or other GUI. Confirm with the
    -- physical button so a stuck object can never keep a loop running.
    local function held(st)
        local io = rawget(st, "ShootInputObject")
        if not io then return false end
        local s = io.UserInputState
        if s ~= Enum.UserInputState.Begin and s ~= Enum.UserInputState.Change then return false end
        if io.UserInputType == Enum.UserInputType.MouseButton1 then
            return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end
        if io.KeyCode == Enum.KeyCode.ButtonR2 then
            return UIS:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonR2)
        end
        return true
    end

    local function reloading(st)
        local al = rawget(st, "animationList")
        local r = al and rawget(al, "reloadAnimation")
        return typeof(r) == "Instance" and r.IsPlaying
    end

    -- Bolt actions only fire while the aim or equip animation is playing, and
    -- only when the Cycle flag the bolt animation normally clears is off.
    local function rearm(st, tool, tt)
        st.clientCanFire = true
        if tt ~= "Bolt Action" then return true end
        st.Cycle = false
        local al = st.animationList
        if al.aimAnimation.IsPlaying or al.equipAnimation.IsPlaying then return true end
        if al.boltCycleAnimation.IsPlaying then al.boltCycleAnimation:Stop(0) end
        if tool:GetAttribute("Aiming") == true then
            pcall(Game.WM.Aim, st, nil, true)
        else
            pcall(Game.WM.freezeAnimationAtTime, st, al.equipAnimation)
        end
        return al.aimAnimation.IsPlaying or al.equipAnimation.IsPlaying
    end

    local function canSend(tool)
        if tool:GetAttribute("CanFire") == false then return false end
        -- until the server answers the last shot, CanFire still reads true from
        -- before the shot and cannot be trusted
        if Fire.pendingAck and os.clock() - Fire.lastSent < 0.45 then return false end
        local ammo = tool:FindFirstChild("AmmoLoaded")
        return ammo ~= nil and ammo.Value >= 1
    end

    local function send(st, tool, tt)
        if not rearm(st, tool, tt) then return false end
        Fire.pendingAck = true
        Fire.lastSent = os.clock()
        Fire.sent = Fire.sent + 1
        -- mode true keeps the game from arming its own repeat loop on top
        task.spawn(function()
            local ok, err = pcall(Game.WM.Shoot, st, true)
            if not ok then E.fault("fire", err) end
        end)
        return true
    end

    local function step()
        if not (E.inGame and Game.WM) then return end
        local tool, st, tt = Game.equipped()
        watch(tool)
        if not (tool and st) then Fire.mode = "idle" return end
        if E.ui and E.ui.altHeld then Fire.mode = "idle" return end
        if reloading(st) then Fire.mode = "reloading" return end

        local ammo = tool:FindFirstChild("AmmoLoaded")

        -- auto reload: only on an empty magazine, never mid fight on a whim
        if cfg.fire.autoReload and ammo and ammo.Value < 1 and os.clock() - Fire.lastReload > 1.2 then
            Fire.lastReload = os.clock()
            pcall(Game.WM.Reload, st)
            Fire.mode = "reloading"
            return
        end

        local pressing = held(st)

        -- hold to fire. Automatic and semi automatic weapons already repeat
        -- while held through the game's own loop, so driving them too would
        -- only send shots into the server lock. Bolt actions have no loop.
        if pressing then
            if cfg.fire.rapid and tt == "Bolt Action" then
                Fire.mode = "rapid"
                if canSend(tool) and os.clock() - Aim.lastShotAt > 0.12 then send(st, tool, tt) end
            else
                Fire.mode = "manual"
            end
            return
        end

        -- auto fire: a locked, visible target close to the crosshair
        if cfg.fire.auto then
            local t = Aim.target
            if t and t.visible and (not t.downed or (cfg.exp and cfg.exp.finishDowned)) and t.angle <= cfg.fire.autoCone then
                Fire.mode = "auto"
                if canSend(tool) and os.clock() - Aim.lastShotAt > 0.08 then send(st, tool, tt) end
                return
            end
        end
        Fire.mode = "idle"
    end

    E.connect(E.RunService.Heartbeat, function()
        local ok, err = pcall(step)
        if not ok then E.fault("fire step", err) end
    end)
end

-- ==== en_10_telemetry.lua ====
-- en_10_telemetry: what actually happened, measured from the server's replies.
do
    local Game, Aim = E.game, E.aim
    local LP = E.LP

    local S = {
        sent = 0,        -- shots the client fired (every real shootEffect)
        accepted = 0,    -- shots the server echoed back to everyone
        hits = 0,
        heads = 0,
        damage = 0,
        kills = 0,
        deaths = 0,
        assists = 0,
        streak = 0,
        bestStreak = 0,
        started = os.clock(),
        lastHit = nil,
    }
    E.stats = S

    Aim.onShot(function() S.sent = S.sent + 1 end)

    if Game.Projectile then
        E.connect(Game.Projectile.OnClientEvent, function(state)
            if type(state) == "table" and state.Character == LP.Character and LP.Character ~= nil then
                S.accepted = S.accepted + 1
            end
        end)
    end

    if Game.Hit then
        E.connect(Game.Hit.OnClientEvent, function(hum, part, dmg)
            S.hits = S.hits + 1
            local partName = typeof(part) == "Instance" and part.Name or "?"
            local head = partName == "Head"
            if head then S.heads = S.heads + 1 end
            if type(dmg) == "number" then S.damage = S.damage + dmg end
            local victim = (typeof(hum) == "Instance" and hum.Parent) and hum.Parent or nil
            local dist
            local root = victim and victim:FindFirstChild("HumanoidRootPart")
            local cam = workspace.CurrentCamera
            if root and cam then dist = (root.Position - cam.CFrame.Position).Magnitude end
            S.lastHit = { victim = victim and victim.Name or "?", part = partName,
                          damage = dmg, head = head, dist = dist, at = os.clock() }
            E.emit("hit", S.lastHit)
        end)
    end

    if Game.Kill then
        E.connect(Game.Kill.OnClientEvent, function(other, kind, assist)
            local k = tostring(kind)
            local realName = typeof(other) == "Instance" and (other.DisplayName ~= "" and other.DisplayName or other.Name) or "?"
            local name = E.nameOf(other, "an enemy")
            if k == "Kill" then
                S.kills = S.kills + 1
                S.streak = S.streak + 1
                if S.streak > S.bestStreak then S.bestStreak = S.streak end
            elseif k == "Assist" then
                S.assists = S.assists + 1
            else
                S.deaths = S.deaths + 1
                S.streak = 0
            end
            E.emit("kill", { kind = k, name = name, realName = realName, assist = assist, lastHit = S.lastHit })
        end)
    end

    function S.accuracy()
        if S.accepted <= 0 then return 0 end
        return math.clamp(S.hits / S.accepted, 0, 1)
    end
    function S.headRate()
        if S.hits <= 0 then return 0 end
        return S.heads / S.hits
    end
    function S.kd()
        return S.kills / math.max(S.deaths, 1)
    end
    function S.reset()
        for _, k in ipairs({ "sent", "accepted", "hits", "heads", "damage", "kills", "deaths", "assists", "streak", "bestStreak" }) do
            S[k] = 0
        end
        S.started = os.clock()
        S.lastHit = nil
    end
end

-- ==== en_11_visuals.lua ====
-- en_11_visuals: ESP boxes and labels, chams, off screen pointers, tracers, the FOV ring and the lock marker.
--
-- Everything draws into E.ui.overlayScreen. That screen has no UIScale and uses
-- IgnoreGuiInset, so every offset written here is a real pixel in the same
-- space Camera:WorldToViewportPoint returns. This part loads before the
-- interface core, so the layers are built on the first render frame after E.ui
-- exists instead of at load. Enemies come only from E.world.list.
do
    local T, Anim, W = E.T, E.Anim, E.world
    local cfg = E.cfg

    local PAD = 3                          -- pixels around the projected extremes
    local DROP = Vector3.new(0, 3, 0)      -- foot fallback below the root
    local CHAM_MAX = 28                    -- Roblox draws at most 31 Highlights
    local CHAM_EVERY = 0.25
    local LABEL_W = 420
    local ESCAPES = { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;", ["'"] = "&apos;" }

    local new                              -- E.ui.new, bound when the layers are built
    local root, layerTracer, layerBox, layerText, layerPointer, layerRing, layerMarker
    local ringO, ringStroke, ringAlpha
    local ringAlphaNow, ringGoal = 1, -1
    local marker, markerO, markerGlow, glowO, markerAlpha
    local markerAlphaNow, markerOn, markerEntry = 1, false, nil
    local hasChevron = false
    local HEX_WARN, HEX_DIM = "#FAC454", "#9898A6"

    local tags = {}                        -- Player -> tag, pruned explicitly
    local chamSlots = {}
    local candidates = {}
    local wanted = {}
    local scratch = {}
    local stamp = 0
    local lastAssign, lastPrune = 0, 0

    local V = { drawn = 0, chams = 0 }
    E.visuals = V

    ------------------------------------------------------------------------
    -- Small helpers
    ------------------------------------------------------------------------
    local function slot(inst)
        return { i = inst, c = {} }
    end

    -- write a property only when it differs from the last value written, so a
    -- still frame costs no property writes at all
    local function put(o, prop, v)
        local c = o.c
        if c[prop] ~= v then
            c[prop] = v
            o.i[prop] = v
        end
    end

    local function escapeRich(s)
        return (string.gsub(s, "[<>&\"']", ESCAPES))
    end

    local function hexOf(c)
        return string.format("#%02X%02X%02X",
            math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
    end

    local function stateColor(e, target)
        if e == target then return T.accent end
        if e.downed then return T.mute end
        if e.visible then return T.good end
        return T.bad
    end

    -- full health reads good and empty reads bad; the middle passes through
    -- warn so it stays a clear colour instead of a muddy blend of the two
    local function healthColor(frac)
        if frac >= 0.5 then return T.warn:Lerp(T.good, (frac - 0.5) * 2) end
        return T.bad:Lerp(T.warn, frac * 2)
    end

    local function byDist(a, b)
        return a.dist < b.dist
    end

    ------------------------------------------------------------------------
    -- Layers, ring, marker and the Highlight pool. Built once.
    ------------------------------------------------------------------------
    local LAYERS = {
        { "Tracers", 1 }, { "Boxes", 2 }, { "Labels", 3 },
        { "Pointers", 4 }, { "Ring", 5 }, { "Marker", 6 },
    }

    local function buildLayers(ui)
        new = ui.new
        local screen = ui.overlayScreen
        root = new("Frame", {
            Name = "ENT_Visuals",
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 1,
        }, screen)
        local made = {}
        for _, spec in ipairs(LAYERS) do
            made[spec[1]] = new("Frame", {
                Name = spec[1],
                BackgroundTransparency = 1,
                Size = UDim2.fromScale(1, 1),
                ZIndex = spec[2],
            }, root)
        end
        layerTracer, layerBox, layerText = made.Tracers, made.Boxes, made.Labels
        layerPointer, layerRing, layerMarker = made.Pointers, made.Ring, made.Marker

        hasChevron = E.sprite.chevron ~= nil
        HEX_WARN, HEX_DIM = hexOf(T.warn), hexOf(T.dim)

        -- FOV ring
        local ring = new("Frame", {
            Name = "Fov",
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(0, 0),
            Visible = false,
            ZIndex = 1,
        }, layerRing)
        new("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
        ringStroke = new("UIStroke", { Color = T.accent, Thickness = 1.5, Transparency = 1 }, ring)
        ui.accent(ringStroke, "Color")
        ringO = slot(ring)
        ringAlpha = Anim.value(1, "fade", function(v)
            ringAlphaNow = v
            ringStroke.Transparency = v
        end)

        -- lock marker, with a soft pool of accent light beneath it
        if E.sprite.glow then
            markerGlow = new("ImageLabel", {
                Name = "LockGlow",
                BackgroundTransparency = 1,
                Image = E.sprite.glow,
                ImageColor3 = T.accent,
                ImageTransparency = 1,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Size = UDim2.fromOffset(76, 76),
                Visible = false,
                ZIndex = 1,
            }, layerMarker)
            ui.accent(markerGlow, "ImageColor3")
            glowO = slot(markerGlow)
        end
        marker = new("ImageLabel", {
            Name = "Lock",
            BackgroundTransparency = 1,
            Image = E.sprite.i_lock or "",
            ImageColor3 = T.accent,
            ImageTransparency = 1,
            ScaleType = Enum.ScaleType.Fit,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(28, 28),
            Visible = false,
            ZIndex = 2,
        }, layerMarker)
        ui.accent(marker, "ImageColor3")
        markerO = slot(marker)
        -- without the sprite the marker falls back to a thin accent circle
        local markerRing
        if not E.sprite.i_lock then
            new("UICorner", { CornerRadius = UDim.new(1, 0) }, marker)
            markerRing = new("UIStroke", { Color = T.accent, Thickness = 1.5, Transparency = 1 }, marker)
            ui.accent(markerRing, "Color")
        end
        markerAlpha = Anim.value(1, "fade", function(v)
            markerAlphaNow = v
            marker.ImageTransparency = v
            if markerRing then markerRing.Transparency = v end
            if markerGlow then markerGlow.ImageTransparency = 0.82 + 0.18 * v end
        end)

        -- Highlight pool
        local folder = new("Folder", { Name = "ENT_Chams" }, screen)
        for i = 1, CHAM_MAX do
            local hl = new("Highlight", {
                Name = "Cham" .. i,
                Enabled = false,
                DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
                FillTransparency = 0.72,
                OutlineTransparency = 0.15,
                FillColor = T.bad,
                OutlineColor = T.bad,
            }, folder)
            local s = slot(hl)
            s.c.Enabled = false
            chamSlots[i] = s
        end
    end

    ------------------------------------------------------------------------
    -- Per player tag. Created the first time a player is drawn, never per frame.
    ------------------------------------------------------------------------
    local function makeLabel(roleName, props)
        local l = new("TextLabel", {
            BackgroundTransparency = 1,
            Text = "",
            TextColor3 = T.text,
            TextStrokeColor3 = T.black,
            TextStrokeTransparency = 0.55,
            TextXAlignment = Enum.TextXAlignment.Center,
            Visible = false,
            ZIndex = 1,
        }, layerText)
        T.applyType(l, roleName)
        for k, v in pairs(props) do l[k] = v end
        return l
    end

    local function makeTag(player)
        local dn = player.DisplayName
        local tag = {
            player = player,
            display = (type(dn) == "string" and dn ~= "") and dn or player.Name,
            stamp = 0,
            limbT = 0,
        }

        local shade = new("Frame", { Name = "Shade", BackgroundTransparency = 1, Visible = false, ZIndex = 1 }, layerBox)
        local shadeStroke = new("UIStroke", {
            Color = T.black, Thickness = 3, Transparency = 0.55, LineJoinMode = Enum.LineJoinMode.Miter,
        }, shade)
        local box = new("Frame", { Name = "Box", BackgroundTransparency = 1, Visible = false, ZIndex = 2 }, layerBox)
        local boxStroke = new("UIStroke", {
            Color = T.bad, Thickness = 1, Transparency = 0, LineJoinMode = Enum.LineJoinMode.Miter,
        }, box)

        local hp = new("Frame", {
            Name = "Health",
            BackgroundColor3 = T.black,
            BackgroundTransparency = 0.45,
            Visible = false,
            ZIndex = 3,
        }, layerBox)
        local hpFill = new("Frame", {
            BackgroundColor3 = T.good,
            AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.new(0, 1, 1, -1),
            Size = UDim2.fromOffset(3, 0),
            ZIndex = 4,
        }, hp)

        local nameL = makeLabel("label", {
            RichText = true,
            AnchorPoint = Vector2.new(0.5, 1),
            TextYAlignment = Enum.TextYAlignment.Bottom,
        })
        local infoL = makeLabel("small", {
            TextTransparency = 0.2,
            AnchorPoint = Vector2.new(0.5, 0),
            TextYAlignment = Enum.TextYAlignment.Top,
        })
        local hpL = makeLabel("value", {
            AnchorPoint = Vector2.new(1, 0),
            TextXAlignment = Enum.TextXAlignment.Right,
            TextYAlignment = Enum.TextYAlignment.Top,
        })

        local tracer = new("Frame", {
            Name = "Tracer",
            BackgroundColor3 = T.bad,
            BackgroundTransparency = 0.4,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Visible = false,
            ZIndex = 1,
        }, layerTracer)

        local pointer = new("ImageLabel", {
            Name = "Pointer",
            BackgroundTransparency = 1,
            Image = E.sprite.chevron or "",
            ImageColor3 = T.bad,
            ScaleType = Enum.ScaleType.Fit,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(20, 20),
            Visible = false,
            ZIndex = 1,
        }, layerPointer)
        if not hasChevron then
            -- no sprite: a small rounded chip still shows the bearing
            pointer.Size = UDim2.fromOffset(10, 10)
            pointer.BackgroundTransparency = 0.2
            new("UICorner", { CornerRadius = UDim.new(0, 2) }, pointer)
        end

        tag.shade, tag.shadeStroke = slot(shade), slot(shadeStroke)
        tag.box, tag.boxStroke = slot(box), slot(boxStroke)
        tag.hp, tag.hpFill = slot(hp), slot(hpFill)
        tag.name, tag.info, tag.hpText = slot(nameL), slot(infoL), slot(hpL)
        tag.tracer, tag.pointer = slot(tracer), slot(pointer)
        tag.objs = { tag.shade, tag.box, tag.hp, tag.name, tag.info, tag.hpText, tag.tracer, tag.pointer }
        for _, o in ipairs(tag.objs) do o.c.Visible = false end
        return tag
    end

    local function hideTag(tag)
        for _, o in ipairs(tag.objs) do put(o, "Visible", false) end
    end

    local function releaseChamsOf(player)
        for _, s in ipairs(chamSlots) do
            if s.entry and s.entry.player == player then
                s.entry, s.char = nil, nil
                put(s, "Enabled", false)
                put(s, "Adornee", nil)
            end
        end
    end

    local function destroyTag(player)
        releaseChamsOf(player)
        local tag = tags[player]
        if not tag then return end
        tags[player] = nil
        for _, o in ipairs(tag.objs) do
            local inst = o.i
            pcall(function() inst:Destroy() end)
        end
    end

    E.connect(E.Players.PlayerRemoving, function(leaving)
        E.try("visuals remove", destroyTag, leaving)
    end)

    ------------------------------------------------------------------------
    -- Box from projected body extremes. A fixed width ratio cannot fit a prone
    -- or crouching body, so the rectangle is the hull of the real points.
    ------------------------------------------------------------------------
    local function refreshLimbs(tag, char, now)
        if tag.limbChar ~= char or now - tag.limbT > 1 then
            tag.limbChar, tag.limbT = char, now
            tag.lf = char:FindFirstChild("LeftFoot")
            tag.rf = char:FindFirstChild("RightFoot")
            tag.lh = char:FindFirstChild("LeftHand")
            tag.rh = char:FindFirstChild("RightHand")
        end
    end

    local function boxOf(cam, e, tag, now)
        refreshLimbs(tag, e.char, now)
        local rootPos = e.root.Position
        local head = e.head
        local hcf = head.CFrame
        scratch[1] = hcf.Position + hcf.UpVector * (head.Size.Y * 0.6)
        scratch[2] = tag.lf and tag.lf.Position or (rootPos - DROP)
        scratch[3] = tag.rf and tag.rf.Position or (rootPos - DROP)
        scratch[4] = rootPos
        local count = 4
        if tag.lh then
            count = count + 1
            scratch[count] = tag.lh.Position
        end
        if tag.rh then
            count = count + 1
            scratch[count] = tag.rh.Position
        end

        local x0, y0, x1, y1, n = math.huge, math.huge, -math.huge, -math.huge, 0
        for i = 1, count do
            local sp = cam:WorldToViewportPoint(scratch[i])
            if sp.Z > 0 then
                n = n + 1
                local sx, sy = sp.X, sp.Y
                if sx < x0 then x0 = sx end
                if sx > x1 then x1 = sx end
                if sy < y0 then y0 = sy end
                if sy > y1 then y1 = sy end
            end
        end
        if n < 3 then return nil end
        return x0 - PAD, y0 - PAD, x1 + PAD, y1 + PAD
    end

    ------------------------------------------------------------------------
    -- Off screen pointer. atan2(rel.X, -rel.Z) is correct in every quadrant:
    -- ahead is 0, right is +90, behind is 180. No extra pi and no special case.
    ------------------------------------------------------------------------
    local function drawPointer(tag, e, camCF, vp, col, esp)
        local rel = camCF:PointToObjectSpace(e.root.Position)
        local ang = math.atan2(rel.X, -rel.Z)
        local r = math.min(vp.X, vp.Y) * 0.34
        local px = vp.X / 2 + math.sin(ang) * r
        local py = vp.Y / 2 - math.cos(ang) * r
        local far = math.clamp(e.dist / math.max(esp.maxDist, 1), 0, 1)
        local alpha = math.floor((0.1 + far * 0.55) * 50 + 0.5) / 50
        local p = tag.pointer
        put(p, "Position", UDim2.fromOffset(px, py))
        put(p, "Rotation", math.deg(ang))
        if hasChevron then
            put(p, "ImageColor3", col)
            put(p, "ImageTransparency", alpha)
        else
            put(p, "BackgroundColor3", col)
            put(p, "BackgroundTransparency", alpha)
        end
        put(p, "Visible", true)
    end

    ------------------------------------------------------------------------
    -- One enemy
    ------------------------------------------------------------------------
    local function drawEntry(tag, e, cam, camCF, vp, target, esp, now)
        tag.entry = e
        local col = stateColor(e, target)
        local isTarget = e == target
        local bx0, by0, bx1, by1 = boxOf(cam, e, tag, now)
        local onScreen = bx0 ~= nil and bx1 >= 0 and bx0 <= vp.X and by1 >= 0 and by0 <= vp.Y

        if not onScreen then
            put(tag.box, "Visible", false)
            put(tag.shade, "Visible", false)
            put(tag.hp, "Visible", false)
            put(tag.hpText, "Visible", false)
            put(tag.name, "Visible", false)
            put(tag.info, "Visible", false)
            put(tag.tracer, "Visible", false)
            if esp.offscreen then
                drawPointer(tag, e, camCF, vp, col, esp)
            else
                put(tag.pointer, "Visible", false)
            end
            return
        end
        put(tag.pointer, "Visible", false)

        -- a body right against the lens projects huge, so keep the frames sane
        local x0 = math.floor(math.max(bx0, -vp.X) + 0.5)
        local y0 = math.floor(math.max(by0, -vp.Y) + 0.5)
        local x1 = math.floor(math.min(bx1, vp.X * 2) + 0.5)
        local y1 = math.floor(math.min(by1, vp.Y * 2) + 0.5)
        local w, h = math.max(x1 - x0, 1), math.max(y1 - y0, 1)
        local cx = math.floor((x0 + x1) / 2 + 0.5)
        local size = math.clamp(math.floor(14 - e.dist / 120 + 0.5), 10, 14)
        local subSize = math.max(size - 1, 10)

        -- box: a 1px colour line with a dark hairline either side of it
        if esp.box then
            local th = isTarget and 2 or 1
            put(tag.box, "Position", UDim2.fromOffset(x0, y0))
            put(tag.box, "Size", UDim2.fromOffset(w, h))
            put(tag.boxStroke, "Color", col)
            put(tag.boxStroke, "Thickness", th)
            put(tag.shade, "Position", UDim2.fromOffset(x0 + 1, y0 + 1))
            put(tag.shade, "Size", UDim2.fromOffset(math.max(w - 2, 0), math.max(h - 2, 0)))
            put(tag.shadeStroke, "Thickness", th + 2)
            put(tag.box, "Visible", true)
            put(tag.shade, "Visible", true)
        else
            put(tag.box, "Visible", false)
            put(tag.shade, "Visible", false)
        end

        -- health
        local frac = math.clamp(e.health / e.maxHealth, 0, 1)
        local q = math.floor(frac * 100 + 0.5)
        if q ~= tag.kHpQ then
            tag.kHpQ = q
            tag.hpColor = healthColor(q / 100)
        end
        if esp.health then
            put(tag.hp, "Position", UDim2.fromOffset(x0 - 10, y0 - 1))
            put(tag.hp, "Size", UDim2.fromOffset(5, h + 2))
            put(tag.hpFill, "Size", UDim2.fromOffset(3, math.floor(h * q / 100 + 0.5)))
            put(tag.hpFill, "BackgroundColor3", tag.hpColor)
            put(tag.hp, "Visible", true)
        else
            put(tag.hp, "Visible", false)
        end
        if esp.hpText then
            local hpInt = math.floor(e.health + 0.5)
            if hpInt ~= tag.kHpInt then
                tag.kHpInt = hpInt
                put(tag.hpText, "Text", tostring(hpInt))
            end
            put(tag.hpText, "TextColor3", tag.hpColor)
            put(tag.hpText, "TextSize", subSize)
            put(tag.hpText, "Size", UDim2.fromOffset(48, subSize + 4))
            put(tag.hpText, "Position", UDim2.fromOffset(x0 - 13, y0 - 2))
            put(tag.hpText, "Visible", true)
        else
            put(tag.hpText, "Visible", false)
        end

        -- name line with its state tags
        local nameStr = esp.name and (E.cfg.exp.streamer and "Enemy" or tag.display) or nil
        local spotted = esp.spotted and e.spotted == true
        local downed = e.downed == true
        if nameStr ~= tag.kName or spotted ~= tag.kSpotted or downed ~= tag.kDowned or size ~= tag.kSize then
            tag.kName, tag.kSpotted, tag.kDowned, tag.kSize = nameStr, spotted, downed, size
            local tagSize = math.max(size - 3, 10)
            local s = nameStr and escapeRich(nameStr) or ""
            if spotted then
                s = s .. (s ~= "" and "  " or "")
                    .. string.format('<font color="%s" size="%d">SPOTTED</font>', HEX_WARN, tagSize)
            end
            if downed then
                s = s .. (s ~= "" and "  " or "")
                    .. string.format('<font color="%s" size="%d">DOWNED</font>', HEX_DIM, tagSize)
            end
            tag.nameText = s
            put(tag.name, "Text", s)
            put(tag.name, "TextSize", size)
            put(tag.name, "Size", UDim2.fromOffset(LABEL_W, size + 8))
        end
        if tag.nameText ~= "" then
            put(tag.name, "TextColor3", isTarget and T.accent or T.text)
            put(tag.name, "Position", UDim2.fromOffset(cx, y0 - 4))
            put(tag.name, "Visible", true)
        else
            put(tag.name, "Visible", false)
        end

        -- info line: distance and weapon
        local distN = esp.dist and math.floor(e.dist + 0.5) or nil
        local weapon = esp.weapon and e.weapon or nil
        if distN ~= tag.kDist or weapon ~= tag.kWeapon or subSize ~= tag.kInfoSize then
            tag.kDist, tag.kWeapon, tag.kInfoSize = distN, weapon, subSize
            local s = distN and (tostring(distN) .. "m") or ""
            if weapon and weapon ~= "" then
                s = s .. (s ~= "" and "  " or "") .. weapon
            end
            tag.infoText = s
            put(tag.info, "Text", s)
            put(tag.info, "TextSize", subSize)
            put(tag.info, "Size", UDim2.fromOffset(LABEL_W, subSize + 8))
        end
        if tag.infoText ~= "" then
            put(tag.info, "Position", UDim2.fromOffset(cx, y1 + 4))
            put(tag.info, "Visible", true)
        else
            put(tag.info, "Visible", false)
        end

        -- tracer: a Frame rotates around its centre, so it sits at the midpoint
        if esp.tracers then
            local ax, ay = vp.X / 2, vp.Y
            local dx, dy = cx - ax, y1 - ay
            local len = math.sqrt(dx * dx + dy * dy)
            if len >= 2 then
                put(tag.tracer, "Position", UDim2.fromOffset((ax + cx) / 2, (ay + y1) / 2))
                put(tag.tracer, "Size", UDim2.fromOffset(len, 1))
                put(tag.tracer, "Rotation", math.deg(math.atan2(dy, dx)))
                put(tag.tracer, "BackgroundColor3", col)
                put(tag.tracer, "Visible", true)
            else
                put(tag.tracer, "Visible", false)
            end
        else
            put(tag.tracer, "Visible", false)
        end
    end

    ------------------------------------------------------------------------
    -- Chams. Slots keep the character they already hold so a reshuffle does
    -- not flicker, and only the nearest CHAM_MAX are ever lit.
    ------------------------------------------------------------------------
    local function assignChams(target, esp)
        table.clear(candidates)
        for _, e in ipairs(W.list) do
            local tag = tags[e.player]
            if tag and tag.stamp == stamp and tag.entry == e and e.dist <= esp.maxDist then
                candidates[#candidates + 1] = e
            end
        end
        table.sort(candidates, byDist)
        local n = math.min(#candidates, CHAM_MAX)

        table.clear(wanted)
        for i = 1, n do wanted[candidates[i].char] = candidates[i] end

        for _, s in ipairs(chamSlots) do
            if s.char and wanted[s.char] then
                s.entry = wanted[s.char]
                wanted[s.char] = nil
            else
                s.entry, s.char = nil, nil
            end
        end
        local cursor = 1
        for i = 1, n do
            local e = candidates[i]
            if wanted[e.char] then
                wanted[e.char] = nil
                while chamSlots[cursor] and chamSlots[cursor].char do cursor = cursor + 1 end
                local s = chamSlots[cursor]
                if not s then break end
                s.char, s.entry = e.char, e
            end
        end

        for _, s in ipairs(chamSlots) do
            if s.entry then
                local col = stateColor(s.entry, target)
                put(s, "FillColor", col)
                put(s, "OutlineColor", col)
                put(s, "Adornee", s.char)
                put(s, "Enabled", true)
            else
                put(s, "Enabled", false)
                put(s, "Adornee", nil)
            end
        end
    end

    local function drawChams(now, esp, target)
        local want = esp.enabled and esp.chams
        local lit = 0
        for _, s in ipairs(chamSlots) do
            local e = s.entry
            if e then
                local tag = tags[e.player]
                if not want or not tag or tag.stamp ~= stamp or tag.entry ~= e or e.char ~= s.char then
                    s.entry, s.char = nil, nil
                    put(s, "Enabled", false)
                    put(s, "Adornee", nil)
                else
                    local col = stateColor(e, target)
                    put(s, "FillColor", col)
                    put(s, "OutlineColor", col)
                    lit = lit + 1
                end
            end
        end
        if want and now - lastAssign >= CHAM_EVERY then
            lastAssign = now
            assignChams(target, esp)
            lit = 0
            for _, s in ipairs(chamSlots) do
                if s.entry then lit = lit + 1 end
            end
        end
        V.chams = lit
    end

    ------------------------------------------------------------------------
    -- FOV ring. camera.FieldOfView is vertical, so the cone half angle maps to
    -- a radius against half the viewport height.
    ------------------------------------------------------------------------
    local function drawRing(cam, vp)
        local aimCfg = cfg.aim
        local goal = aimCfg.showFov and (aimCfg.silent and 0.35 or 0.75) or 1
        if goal ~= ringGoal then
            ringGoal = goal
            ringAlpha.to(goal, "fade")
        end
        if goal >= 1 and ringAlphaNow >= 0.999 then
            put(ringO, "Visible", false)
            return
        end
        local half = math.clamp(aimCfg.fov / 2, 0, 89)
        local camHalf = math.clamp(cam.FieldOfView, 1, 179) / 2
        local radius = (vp.Y / 2) * math.tan(math.rad(half)) / math.tan(math.rad(camHalf))
        radius = math.clamp(radius, 0, 20000)
        local d = math.floor(radius * 2 + 0.5)
        put(ringO, "Size", UDim2.fromOffset(d, d))
        put(ringO, "Position", UDim2.fromOffset(math.floor(vp.X / 2 + 0.5), math.floor(vp.Y / 2 + 0.5)))
        put(ringO, "Visible", d >= 2)
    end

    ------------------------------------------------------------------------
    -- Lock marker. Springs follow the aim point; a new lock settles in from a
    -- larger, turned bracket so the change of target reads at a glance.
    ------------------------------------------------------------------------
    local function drawMarker(cam)
        local aim = E.aim
        local tgt = aim and aim.target
        local sx, sy
        if tgt then
            local pos = aim.point
            if not pos and aim.part then pos = aim.part.Position end
            if pos then
                local sp = cam:WorldToViewportPoint(pos)
                if sp.Z > 0 then sx, sy = sp.X, sp.Y end
            end
        end

        if sx then
            local goal = UDim2.fromOffset(sx, sy)
            if not markerOn then
                markerOn = true
                -- fully faded: appear in place rather than sweep in from the last lock
                if markerAlphaNow > 0.95 then
                    Anim.set(marker, "Position", goal)
                    if markerGlow then Anim.set(markerGlow, "Position", goal) end
                end
                markerAlpha.to(0, "fade")
            end
            if tgt ~= markerEntry then
                markerEntry = tgt
                Anim.set(marker, "Size", UDim2.fromOffset(44, 44))
                Anim.set(marker, "Rotation", 45)
                Anim.to(marker, "Size", UDim2.fromOffset(28, 28), "select")
                Anim.to(marker, "Rotation", 0, "select")
            end
            Anim.to(marker, "Position", goal, "follow")
            if markerGlow then Anim.to(markerGlow, "Position", goal, "follow") end
            put(markerO, "Visible", true)
            if glowO then put(glowO, "Visible", true) end
        else
            if markerOn then
                markerOn = false
                markerAlpha.to(1, "fade")
            end
            markerEntry = nil
            if markerAlphaNow >= 0.999 then
                put(markerO, "Visible", false)
                if glowO then put(glowO, "Visible", false) end
            end
        end
    end

    ------------------------------------------------------------------------
    -- Frame
    ------------------------------------------------------------------------
    local function renderVisuals()
        if not root then
            local ui = E.ui
            if not (ui and ui.overlayScreen and ui.overlayScreen.Parent) then return end
            buildLayers(ui)
        end
        if not root.Parent then return end
        local cam = workspace.CurrentCamera
        if not cam then return end

        local vp = cam.ViewportSize
        local camCF = cam.CFrame
        local now = os.clock()
        local esp = cfg.esp
        local target = E.aim and E.aim.target or nil
        stamp = stamp + 1

        local drawn = 0
        if esp.enabled then
            for _, e in ipairs(W.list) do
                if e.dist <= esp.maxDist and e.char and e.root and e.head then
                    local tag = tags[e.player]
                    if not tag then
                        tag = makeTag(e.player)
                        tags[e.player] = tag
                    end
                    tag.stamp = stamp
                    drawEntry(tag, e, cam, camCF, vp, target, esp, now)
                    drawn = drawn + 1
                end
            end
        end
        V.drawn = drawn

        for _, tag in pairs(tags) do
            if tag.stamp ~= stamp then hideTag(tag) end
        end

        -- a player who left between the snapshot and this frame still got a tag
        if now - lastPrune > 1 then
            lastPrune = now
            for player in pairs(tags) do
                if player.Parent == nil then destroyTag(player) end
            end
        end

        drawChams(now, esp, target)
        drawRing(cam, vp)
        drawMarker(cam)
    end

    E.bind("ENT_VISUALS", Enum.RenderPriority.Last.Value, function()
        local ok, err = pcall(renderVisuals)
        if not ok then E.fault("visuals frame", err) end
    end)
end

-- ==== en_12_radar.lua ====
-- en_12_radar: compact tactical radar in the top right corner, forward is up.
--
-- Rules this file follows:
--  * Lives in the overlay screen, which has no UIScale, so every offset here is
--    a real pixel and matches GetMouseLocation and the viewport directly.
--  * No CanvasGroup, no AutomaticSize, nothing inside a list layout.
--  * Blips are placed in scale units of the card, so a size change that is
--    still settling keeps every blip on its ring.
--  * Hover goes through E.ui.hoverable and dragging only starts while Alt is
--    held. The cursor itself is never touched here.
--  * This part loads before en_20_ui_core, so E.ui does not exist yet when it
--    runs. Everything is built once the interface is ready.
do
    local function build()
        local T, Anim, UI = E.T, E.Anim, rawget(E, "ui")
        local UIS = E.UIS
        local cfg = E.cfg
        local new = UI.new

        local EDGE_RIGHT, EDGE_TOP = 24, 72    -- viewport margins for the default spot
        local PAD = 14                         -- card edge to the outer ring
        local TICK = 1 / 30
        local BLIP, LOCKED, FAR = 7, 10, 5     -- blip diameters
        local LABEL_X, LABEL_B, LABEL_H = 10, 8, 14
        local SHADOW_T = 0.45

        ------------------------------------------------------------------------
        -- State
        ------------------------------------------------------------------------
        local geo = { size = 170, range = 350, rf = 0.4 }   -- rf: usable radius / card size
        local custom = nil          -- centre in pixels after a drag, kept for this session only
        local lastVp = Vector2.zero
        local drag = nil
        local hovered = false
        local shown = false
        local acc = 0
        local blips = {}            -- world entry -> blip
        local spare = {}            -- hidden blips ready for reuse
        local seen = {}
        local widthCache = {}

        ------------------------------------------------------------------------
        -- Shell: transparent holder, shadow sibling behind the card
        ------------------------------------------------------------------------
        local holder = new("Frame", {
            Name = "Radar",
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(geo.size, geo.size),
            Visible = false,
            ZIndex = 40,
        }, UI.overlayScreen)

        -- the holder is not in a list layout, so a UIScale here moves nothing else
        local lift = new("UIScale", { Scale = 1 }, holder)

        local shadow = UI.shadow(holder, true, false, 1)

        local card = new("Frame", {
            Name = "Card",
            BackgroundColor3 = T.surface,
            BackgroundTransparency = 0.12,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 2,
        }, holder)
        UI.corner(card, 14)
        UI.rim(card, 9, 0.55)

        -- quiet accent edge that only shows while the card can be dragged
        local outline = new("UIStroke", {
            Color = T.accent,
            Thickness = 1,
            Transparency = 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, card)
        UI.accent(outline, "Color")

        ------------------------------------------------------------------------
        -- Range rings and cross hair
        ------------------------------------------------------------------------
        local function ring(transparency)
            local f = new("Frame", {
                BackgroundTransparency = 1,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromScale(0.8, 0.8),
                ZIndex = 3,
            }, card)
            new("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
            new("UIStroke", { Color = T.line, Thickness = 1, Transparency = transparency }, f)
            return f
        end
        local outerRing = ring(0)
        local innerRing = ring(0.3)

        -- faded at both ends and parted at the centre so the self marker sits clear
        local fadeSeq = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.22, 0.25),
            NumberSequenceKeypoint.new(0.43, 0.25),
            NumberSequenceKeypoint.new(0.5, 1),
            NumberSequenceKeypoint.new(0.57, 0.25),
            NumberSequenceKeypoint.new(0.78, 0.25),
            NumberSequenceKeypoint.new(1, 1),
        })
        local hLine = new("Frame", {
            BackgroundColor3 = T.line,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.new(0.8, 0, 0, 1),
            ZIndex = 3,
        }, card)
        new("UIGradient", { Transparency = fadeSeq }, hLine)
        local vLine = new("Frame", {
            BackgroundColor3 = T.line,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.new(0, 1, 0.8, 0),
            ZIndex = 3,
        }, card)
        new("UIGradient", { Transparency = fadeSeq, Rotation = 90 }, vLine)

        local layer = new("Frame", {
            Name = "Blips",
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 5,
        }, card)

        local selfMark = UI.icon(card, "chevron", 14, T.text, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            ZIndex = 7,
        })
        if not E.sprite.chevron then
            selfMark.Size = UDim2.fromOffset(6, 6)
            selfMark.BackgroundColor3 = T.text
            selfMark.BackgroundTransparency = 0
            selfMark.Rotation = 45
        end

        local rangeLabel = UI.text(card, "", "small", {
            AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.new(0, LABEL_X, 1, -LABEL_B),
            Size = UDim2.fromOffset(64, LABEL_H),
            TextColor3 = T.mute,
            ZIndex = 6,
        })

        ------------------------------------------------------------------------
        -- Placement
        ------------------------------------------------------------------------
        local function viewport()
            local cam = workspace.CurrentCamera
            if cam then return cam.ViewportSize end
            return UI.overlayScreen.AbsoluteSize
        end

        -- math.clamp errors when min exceeds max, which a tiny window can cause
        local function clampCentre(p, S, vp)
            local half = S / 2
            local x = math.max(half + 8, math.min(vp.X - half - 8, p.X))
            local y = math.max(half + 8, math.min(vp.Y - half - 8, p.Y))
            return Vector2.new(x, y)
        end

        local function centreFor(S, vp)
            if custom then return clampCentre(custom, S, vp) end
            return Vector2.new(vp.X - EDGE_RIGHT - S / 2, EDGE_TOP + S / 2)
        end

        local function place(animated)
            local vp = viewport()
            lastVp = vp
            local c = centreFor(geo.size, vp)
            local pos = UDim2.fromOffset(c.X, c.Y)
            if animated then
                Anim.to(holder, "Position", pos, "collapse")
            else
                Anim.set(holder, "Position", pos)
            end
        end

        ------------------------------------------------------------------------
        -- Geometry from settings
        ------------------------------------------------------------------------
        local function labelWidth(str)
            local w = widthCache[str]
            if not w then
                w = math.ceil(T.measure(str, "small").X)
                widthCache[str] = w
            end
            return w
        end

        -- the outer ring stays clear of the range label's inner corner
        local function usableRadius(S, labelW)
            local r = S / 2 - PAD
            local cx = S / 2 - (LABEL_X + labelW + 2)
            local cy = S / 2 - (LABEL_B + LABEL_H + 2)
            if cx > 0 and cy > 0 then
                r = math.min(r, math.sqrt(cx * cx + cy * cy) - 3)
            end
            return math.max(r, S * 0.34)
        end

        local function layout(animated)
            local S = math.clamp(math.floor(tonumber(cfg.radar.size) or 170), 80, 400)
            local range = math.max(tonumber(cfg.radar.range) or 350, 10)
            local str = string.format("%dm", math.floor(range + 0.5))
            rangeLabel.Text = str
            local rf = usableRadius(S, labelWidth(str)) / S
            geo.size, geo.range, geo.rf = S, range, rf

            local targets = {
                { holder, "Size", UDim2.fromOffset(S, S) },
                { outerRing, "Size", UDim2.fromScale(rf * 2, rf * 2) },
                { innerRing, "Size", UDim2.fromScale(rf, rf) },
                { hLine, "Size", UDim2.new(rf * 2, 0, 0, 1) },
                { vLine, "Size", UDim2.new(0, 1, rf * 2, 0) },
            }
            for _, t in ipairs(targets) do
                if animated then
                    Anim.to(t[1], t[2], t[3], "collapse")
                else
                    Anim.set(t[1], t[2], t[3])
                end
            end
            -- same token as the size, so the right edge holds its margin while it settles
            place(animated)
        end

        ------------------------------------------------------------------------
        -- Blip pool
        ------------------------------------------------------------------------
        local function makeBlip()
            local dot = new("Frame", {
                BackgroundColor3 = T.bad,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Size = UDim2.fromOffset(0, 0),
                Visible = false,
                ZIndex = 6,
            }, layer)
            new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
            local halo = new("Frame", {
                BackgroundTransparency = 1,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.new(1, 6, 1, 6),
                Visible = false,
                ZIndex = 6,
            }, dot)
            new("UICorner", { CornerRadius = UDim.new(1, 0) }, halo)
            local stroke = new("UIStroke", { Color = T.bad, Thickness = 1, Transparency = 0.35 }, halo)
            return { dot = dot, halo = halo, stroke = stroke }
        end

        local function takeBlip()
            local b = table.remove(spare)
            if not b then b = makeBlip() end
            b.key, b.leaving, b.fresh = nil, nil, true
            return b
        end

        local function release(e, b)
            b.dot.Visible = false
            b.halo.Visible = false
            blips[e] = nil
            spare[#spare + 1] = b
        end

        local function releaseAll()
            for e, b in pairs(blips) do release(e, b) end
        end

        local function colourFor(e, locked)
            if locked then return T.accent, "lock" end
            if e.downed then return T.mute, "down" end
            if e.visible then return T.good, "vis" end
            return T.bad, "hid"
        end

        ------------------------------------------------------------------------
        -- Update, about 30 times a second
        ------------------------------------------------------------------------
        local function update(now)
            local vp = viewport()
            if vp ~= lastVp then place(false) end

            local cam = workspace.CurrentCamera
            if not cam then return end
            local cf = cam.CFrame
            local camPos = cf.Position

            -- flattened, normalised camera axes on the ground plane
            local look, right = cf.LookVector, cf.RightVector
            local fx, fz = look.X, look.Z
            local rx, rz = right.X, right.Z
            local fm = math.sqrt(fx * fx + fz * fz)
            local rm = math.sqrt(rx * rx + rz * rz)
            if rm > 1e-4 then rx, rz = rx / rm, rz / rm end
            if fm > 1e-4 then
                fx, fz = fx / fm, fz / fm
            elseif rm > 1e-4 then
                fx, fz = rz, -rx            -- looking straight up or down: world up cross right
            else
                fx, fz = 0, -1
            end
            if rm <= 1e-4 then rx, rz = -fz, fx end

            local range, rf = geo.range, geo.rf
            local aim = E.aim
            local target = aim and aim.target
            local world = E.world
            local list = world and world.list or {}
            table.clear(seen)

            for _, e in ipairs(list) do
                local root = e.root
                if root then
                    local p = root.Position
                    local dx, dz = p.X - camPos.X, p.Z - camPos.Z
                    local ahead = dx * fx + dz * fz
                    local side = dx * rx + dz * rz
                    local nx, ny = side / range, -ahead / range
                    local n = math.sqrt(nx * nx + ny * ny)
                    local far = n > 1
                    if far then nx, ny = nx / n, ny / n end

                    local b = blips[e]
                    if not b then
                        b = takeBlip()
                        blips[e] = b
                    end
                    seen[e] = true

                    local locked = e == target
                    local col, kind = colourFor(e, locked)
                    local key = kind .. (far and "_far" or "_near")
                    local diameter = locked and LOCKED or (far and FAR or BLIP)
                    local pos = UDim2.fromScale(0.5 + nx * rf, 0.5 + ny * rf)
                    local dot = b.dot

                    local snap = b.fresh
                    if snap then
                        b.fresh = false
                        Anim.set(dot, "Position", pos)
                        Anim.set(dot, "Size", UDim2.fromOffset(0, 0))
                        dot.Visible = true
                    else
                        Anim.to(dot, "Position", pos, "follow")
                    end
                    if b.leaving then
                        b.leaving = nil
                        b.key = nil
                    end

                    if b.key ~= key then
                        b.key = key
                        dot.ZIndex = locked and 8 or (e.downed and 6 or 7)
                        local fade = far and 0.5 or 0
                        local ringFade = far and 0.7 or 0.35
                        Anim.to(dot, "Size", UDim2.fromOffset(diameter, diameter), "toggle")
                        if snap then
                            Anim.set(dot, "BackgroundColor3", col)
                            Anim.set(dot, "BackgroundTransparency", fade)
                            Anim.set(b.stroke, "Color", col)
                            Anim.set(b.stroke, "Transparency", ringFade)
                        else
                            Anim.to(dot, "BackgroundColor3", col, "hover")
                            Anim.to(dot, "BackgroundTransparency", fade, "fade")
                            Anim.to(b.stroke, "Color", col, "hover")
                            Anim.to(b.stroke, "Transparency", ringFade, "fade")
                        end
                    end
                    b.halo.Visible = e.spotted == true
                end
            end

            -- entries that left the snapshot shrink away, then return to the pool
            for e, b in pairs(blips) do
                if not seen[e] then
                    if not b.leaving then
                        b.leaving = now
                        b.key = nil
                        Anim.to(b.dot, "Size", UDim2.fromOffset(0, 0), "fade")
                    elseif now - b.leaving > 0.3 then
                        release(e, b)
                    end
                end
            end
        end

        ------------------------------------------------------------------------
        -- Show and hide
        ------------------------------------------------------------------------
        local function paintOutline()
            local t = 1
            if drag then t = 0.45 elseif hovered then t = 0.72 end
            Anim.to(outline, "Transparency", t, "hover")
        end

        local function endDrag()
            if not drag then return end
            drag = nil
            Anim.to(lift, "Scale", 1, "release")
            if shadow then Anim.to(shadow, "ImageTransparency", SHADOW_T, "fade") end
            paintOutline()
        end

        local function setShown(on)
            on = on == true
            if on == shown then return end
            shown = on
            if on then
                layout(false)
                holder.Visible = true
                acc = TICK
                Anim.set(lift, "Scale", 0.94)
                Anim.to(lift, "Scale", 1, "panel")
                if shadow then
                    Anim.set(shadow, "ImageTransparency", 1)
                    Anim.to(shadow, "ImageTransparency", SHADOW_T, "reveal")
                end
            else
                endDrag()
                hovered = false
                Anim.set(outline, "Transparency", 1)
                holder.Visible = false
                releaseAll()
            end
        end

        ------------------------------------------------------------------------
        -- Hover and drag, Alt only
        ------------------------------------------------------------------------
        UI.hoverable(card, {
            enter = function()
                hovered = true
                paintOutline()
            end,
            leave = function()
                hovered = false
                paintOutline()
            end,
            gate = function() return shown end,
        })

        local function beginDrag(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
            if not (UI.altHeld and shown and holder.Visible) then return end
            local m = UI.mouse()
            if not UI.inside(card, m) then return end
            -- the panel sits above the overlay; a press on it belongs to the panel
            if UI.panelOpen and UI.holder and UI.inside(UI.holder, m) then return end
            local cur = holder.Position
            drag = { start = m, origin = Vector2.new(cur.X.Offset, cur.Y.Offset) }
            Anim.to(lift, "Scale", 1.025, "press")
            if shadow then Anim.to(shadow, "ImageTransparency", 0.3, "hover") end
            paintOutline()
        end

        local function moveDrag(input)
            if not drag or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
            local m = UI.mouse()
            local c = clampCentre(drag.origin + (m - drag.start), geo.size, viewport())
            custom = c
            Anim.to(holder, "Position", UDim2.fromOffset(c.X, c.Y), "follow")
        end

        E.connect(UIS.InputBegan, function(input) E.try("radar drag", beginDrag, input) end)
        E.connect(UIS.InputChanged, function(input) E.try("radar drag", moveDrag, input) end)
        E.connect(UIS.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                E.try("radar drag", endDrag)
            end
        end)
        UI.onAlt(function(on) if not on then endDrag() end end)

        ------------------------------------------------------------------------
        -- Frame loop, throttled, and skipped entirely while the radar is off
        ------------------------------------------------------------------------
        E.connect(E.RunService.Heartbeat, function(dt)
            if not (shown and cfg.radar.enabled) then return end
            acc = acc + dt
            if acc + 0.002 < TICK then return end
            acc = 0
            local ok, err = pcall(update, os.clock())
            if not ok then E.fault("radar update", err) end
        end)

        ------------------------------------------------------------------------
        -- Settings
        ------------------------------------------------------------------------
        E.watch("radar.enabled", function(v) setShown(v == true) end)
        E.watch("radar.size", function() if shown then layout(true) end end)
        E.watch("radar.range", function() if shown then layout(true) end end)

        -- blip colours depend on state, so an accent change repaints on the next tick
        E.on("accent", function()
            for _, b in pairs(blips) do b.key = nil end
        end)

        setShown(cfg.radar.enabled == true)
    end

    -- wait for the whole of en_20 (panelOpen is the last thing it sets), then build
    task.spawn(function()
        local t0 = os.clock()
        while E.alive do
            local ui = rawget(E, "ui")
            if type(ui) == "table" and ui.panelOpen ~= nil and ui.overlayScreen then break end
            if os.clock() - t0 > 30 then
                E.fault("radar", "the interface never became ready")
                return
            end
            task.wait()
        end
        if E.alive then E.try("radar build", build) end
    end)
end

-- ==== en_13_remotes.lua ====
-- en_13_remotes: one shared, thin hook on outgoing FireServer calls.
--
-- Experiments need to change or drop a few of the game's own remote calls
-- (melee, throw, fall damage). A __namecall hook can never be removed, so it is
-- installed ONCE per session, pinned in getgenv, and does nothing but hand the
-- call to whichever hub instance is loaded now. Rules learned the hard way:
--   1. getnamecallmethod() is read on the first line. ANY method call made
--      afterwards overwrites it.
--   2. Once a handler has run it may have called methods, so the call leaves
--      through a FireServer function captured at install, never through `old`
--      (which would re-dispatch whatever method name was called last).
--   3. Only RemoteEvent:FireServer is handled. InvokeServer yields, and a yield
--      inside a namecall hook is not safe on every executor.
--
-- API
--   E.remotes.on(name, fn)   fn(args) where args = { n = count, ... }. Return
--                            "drop" to swallow the call, true to send the
--                            (possibly edited) args table, or nil to leave the
--                            call untouched. Several handlers per name run in
--                            the order registered.
--   E.remotes.log[name]      the last 6 calls as short argument summaries, for
--                            reading back what a remote actually carries.
do
    local G = E.G
    local X = E.X
    local R = { watch = {}, handlers = {}, log = {}, installed = false }
    E.remotes = R

    local se = E.RS:FindFirstChild("ServerEvents")

    -- short, method free description of one argument
    local function describe(v, depth)
        local ty = typeof(v)
        if ty == "Instance" then return "Instance(" .. tostring(v) .. ")" end
        if ty == "table" then
            if depth >= 1 then return "table" end
            local parts, count = {}, 0
            for k, val in pairs(v) do
                count = count + 1
                if count > 6 then parts[#parts + 1] = "..." break end
                parts[#parts + 1] = tostring(k) .. "=" .. describe(val, depth + 1)
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        if ty == "string" then return string.format("%q", string.sub(v, 1, 40)) end
        return ty .. "(" .. tostring(v) .. ")"
    end

    local function record(name, args)
        local list = R.log[name]
        if not list then list = {} R.log[name] = list end
        local parts = {}
        for i = 1, math.min(args.n, 8) do parts[i] = describe(args[i], 0) end
        list[#list + 1] = string.format("%.2f  %s", os.clock(), table.concat(parts, "  |  "))
        if #list > 6 then table.remove(list, 1) end
    end

    -- called from the pinned shim with the remote and its packed arguments
    function R.dispatch(remote, args)
        local name = R.watch[remote]
        if not name then return nil end
        pcall(record, name, args)
        local list = R.handlers[name]
        if not list then return nil end
        local changed = false
        for _, fn in ipairs(list) do
            local ok, res = pcall(fn, args)
            if not ok then
                E.fault("remote " .. name, res)
            elseif res == "drop" then
                return "drop"
            elseif res == true then
                changed = true
            end
        end
        return changed and "send" or nil
    end

    local function install()
        if R.installed then return true end
        if rawget(G, "__ENT_NAMECALL") then R.installed = true return true end
        if not (X.hookmetamethod and X.getnamecallmethod and X.checkcaller) then return false end
        local probe = Instance.new("RemoteEvent")
        local FIRE = probe.FireServer
        probe:Destroy()
        local wrap = X.newcclosure or function(f) return f end
        local getMethod, isOurs = X.getnamecallmethod, X.checkcaller
        local old
        local ok = pcall(function()
            old = X.hookmetamethod(game, "__namecall", wrap(function(self, ...)
                local method = getMethod()
                if method == "FireServer" and not isOurs() then
                    local EE = rawget(G, "__ENTRENCHED")
                    local RR = EE and EE.alive and EE.remotes
                    if RR and RR.watch[self] then
                        local args = table.pack(...)
                        local okD, verdict = pcall(RR.dispatch, self, args)
                        if okD and verdict == "drop" then return nil end
                        if okD and verdict == "send" then
                            return FIRE(self, table.unpack(args, 1, args.n))
                        end
                        return FIRE(self, ...)
                    end
                end
                return old(self, ...)
            end))
        end)
        if not ok or not old then return false end
        G.__ENT_NAMECALL = true
        R.installed = true
        return true
    end

    -- watch a ServerEvents remote by name; installs the hook on first use
    function R.on(name, fn)
        local remote = se and se:FindFirstChild(name)
        if not (remote and remote:IsA("RemoteEvent")) then
            E.fault("remote " .. name, "not found in ServerEvents")
            return false
        end
        if not install() then
            E.fault("remote hook", "this executor has no namecall hook")
            return false
        end
        R.watch[remote] = name
        R.handlers[name] = R.handlers[name] or {}
        table.insert(R.handlers[name], fn)
        return true
    end

    -- log only, so the next session can read what a remote carries
    function R.observe(name)
        local remote = se and se:FindFirstChild(name)
        if not (remote and remote:IsA("RemoteEvent")) then return false end
        if not install() then return false end
        R.watch[remote] = name
        return true
    end

    E.cap.remoteHook = X.hookmetamethod ~= nil and X.getnamecallmethod ~= nil
    E.onUnload(function()
        -- the pinned shim stays, but with no watched remotes it passes every
        -- call straight through
        table.clear(R.watch)
        table.clear(R.handlers)
    end)
end

-- ==== en_13_worldfx.lua ====
-- en_13_worldfx: camera field of view offset and a clear view of the battlefield.
do
    local Lighting = E.Lighting
    local cfg = E.cfg

    ------------------------------------------------------------------------
    -- Field of view offset. The game tweens FieldOfView on aim and scope, so
    -- we track what the game last asked for and add the offset on top. Our own
    -- write is recognised by VALUE: a flag cleared on a deferred task can be
    -- cleared before the change signal arrives, which records our output as the
    -- game's intent and compounds the offset on every pass.
    ------------------------------------------------------------------------
    local camConn, intended, ours
    local function watchCamera()
        if camConn then pcall(function() camConn:Disconnect() end) end
        local cam = workspace.CurrentCamera
        if not cam then return end
        intended, ours = cam.FieldOfView, nil
        camConn = cam:GetPropertyChangedSignal("FieldOfView"):Connect(function()
            local v = cam.FieldOfView
            if ours and math.abs(v - ours) < 1e-3 then return end
            intended = v
        end)
    end
    watchCamera()
    E.connect(workspace:GetPropertyChangedSignal("CurrentCamera"), watchCamera)
    E.onUnload(function()
        if camConn then pcall(function() camConn:Disconnect() end) end
        local cam = workspace.CurrentCamera
        if cam and ours and intended then pcall(function() cam.FieldOfView = intended end) end
    end)

    E.bind("ENT_FOV", Enum.RenderPriority.Camera.Value + 8, function()
        local cam = workspace.CurrentCamera
        if not (cam and intended) then return end
        local off = cfg.world.fov
        if off ~= 0 then
            local want = math.clamp(intended + off, 1, 120)
            if math.abs(cam.FieldOfView - want) > 1e-2 then
                ours = want
                cam.FieldOfView = want
            end
        elseif ours then
            ours = nil
            cam.FieldOfView = intended
        end
    end)

    ------------------------------------------------------------------------
    -- Clear view: haze, distance blur, weather particles and the grey out when
    -- hurt. The weather system keeps changing these, so they are re-asserted on
    -- a short loop, and every original is restored the moment it turns off.
    ------------------------------------------------------------------------
    local saved = {}           -- instance -> { prop -> original }
    -- We only ever write `value`, so any other value found here is the game's
    -- latest intent (a new map sets its own fog and haze) and becomes the
    -- original that unload restores.
    local function force(inst, prop, value)
        if not inst or not inst.Parent then return end
        local cur = inst[prop]
        if cur ~= value then
            saved[inst] = saved[inst] or {}
            saved[inst][prop] = cur
            pcall(function() inst[prop] = value end)
        end
    end
    -- instances from a finished map are dropped rather than held forever
    local function prune()
        for inst in pairs(saved) do
            if not inst.Parent then saved[inst] = nil end
        end
    end
    local function restoreAll()
        for inst, props in pairs(saved) do
            if inst.Parent then
                for prop, v in pairs(props) do pcall(function() inst[prop] = v end) end
            end
        end
        table.clear(saved)
    end

    local function apply()
        prune()
        for _, c in ipairs(Lighting:GetChildren()) do
            if c:IsA("Atmosphere") then
                force(c, "Density", 0)
                force(c, "Haze", 0)
            elseif c:IsA("DepthOfFieldEffect") then
                force(c, "Enabled", false)
            elseif c:IsA("ColorCorrectionEffect") and c.Name == "healthColor" then
                force(c, "Saturation", 0)
                force(c, "TintColor", Color3.new(1, 1, 1))
            end
        end
        if Lighting.FogEnd < 100000 then
            force(Lighting, "FogEnd", 100000)
        elseif Lighting.FogEnd ~= 100000 and saved[Lighting] then
            -- the map itself cleared the fog; nothing of ours to restore
            saved[Lighting].FogEnd = nil
        end
        for _, c in ipairs(workspace:GetChildren()) do
            if c:IsA("BasePart") and string.find(c.Name, "ParticleFollower") then
                for _, d in ipairs(c:GetDescendants()) do
                    if d:IsA("ParticleEmitter") or d:IsA("Beam") then force(d, "Enabled", false) end
                end
            end
        end
    end

    -- each enable starts a new generation; an older loop sees the mismatch and
    -- exits, so rapid toggling can never leave two loops running
    local generation = 0
    local function setClear(on)
        generation = generation + 1
        local mine = generation
        if not on then
            restoreAll()
            return
        end
        task.spawn(function()
            while E.alive and mine == generation and cfg.world.clearWeather do
                local ok, err = pcall(apply)
                if not ok then E.fault("clear view", err) end
                task.wait(0.5)
            end
        end)
    end
    E.watch("world.clearWeather", setClear)
    E.onUnload(restoreAll)
end

-- ==== en_14_exp_weapon.lua ====
-- en_14_exp_weapon: shooting experiments. No spread, the game's own bullet
-- magnetism, no recoil, faster reloads, instant aim and longer throws.
--
-- Everything here ships off and touches nothing until it is switched on, and
-- every value it changes is written down first so turning a setting off or
-- unloading the hub puts the game back exactly as it was. Each feature keeps
-- one short line in E.expWeapon.status for hand testing.
do
    local Game, Aim = E.game, E.aim
    local LP = E.LP
    local cfg = E.cfg

    local status = {
        noSpread   = "off",
        magnetism  = "off",
        noRecoil   = "off",
        fastReload = "off",
        instantAim = "off",
        longThrow  = "off",
    }
    E.expWeapon = { status = status }

    local faulted = {}
    local function faultOnce(label, err)
        if faulted[label] then return end
        faulted[label] = true
        E.fault(label, err)
    end

    local function attempt(label, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then faultOnce(label, err) end
        return ok
    end

    ------------------------------------------------------------------------
    -- No spread.
    --
    -- WeaponModule computes, for the shot it is about to send:
    --     hipfirePenalty = 1 / SpreadDefault / 6
    --     totalSpread    = (Bloom or SpreadDefault)
    --                      + (aiming and standing still and 0 or hipfirePenalty)
    -- so writing zero divides by zero and gives every hip shot an infinite cone.
    -- While aiming the penalty term is already gone, so a tiny base is pure
    -- gain. Otherwise x + 1/(6x) is smallest at x = 1/sqrt(6).
    --
    -- The patch runs inside the game's own Crosshair call, which is before the
    -- cone is computed, and the restore is deferred so it lands after the shot
    -- has been sent. shootEffect never yields in between.
    ------------------------------------------------------------------------
    local SPREAD_HIP = 0.4082482904638631
    local patching, patched = false, 0

    local function patchSpread(state)
        if cfg.exp.noSpread ~= true or patching then return end
        local tool = type(state) == "table" and rawget(state, "Tool") or nil
        if typeof(tool) ~= "Instance" then tool = Game.equipped() end
        if not tool then return end
        local orig = tool:GetAttribute("SpreadDefault")
        if type(orig) ~= "number" or orig <= 0 then return end

        local aiming = tool:GetAttribute("Aiming") == true
        local bloom = tool:FindFirstChild("Bloom")
        local bloomOrig = (bloom and bloom:IsA("NumberValue")) and bloom.Value or nil

        patching = true
        tool:SetAttribute("SpreadDefault", aiming and 0.001 or SPREAD_HIP)
        if bloomOrig ~= nil then bloom.Value = 0 end
        patched = patched + 1
        status.noSpread = "patched " .. patched .. " shots"

        task.defer(function()
            pcall(function()
                if tool.Parent then tool:SetAttribute("SpreadDefault", orig) end
                if bloomOrig ~= nil and bloom and bloom.Parent then bloom.Value = bloomOrig end
            end)
            patching = false
        end)
    end

    Aim.onShot(function(state)
        if cfg.exp.noSpread ~= true then return end
        if not attempt("no spread", patchSpread, state) then patching = false end
    end)

    E.watch("exp.noSpread", function(on)
        if on then
            if patched == 0 then status.noSpread = "waiting for a shot" end
        else
            status.noSpread = "off"
        end
    end)

    ------------------------------------------------------------------------
    -- Native bullet magnetism. The game ships aim help for touch players
    -- (bulletMagnetism, a 15 wide cone) and decides who gets it from an
    -- invisible frame in its own HUD plus one attribute on PlayerClient.
    --
    -- Each original is saved at the moment WE first change it and cleared when
    -- we hand it back, so a value we wrote can never be mistaken for the
    -- game's own. The HUD is rebuilt on respawn, so while this is on it is
    -- re-asserted on a slow loop.
    ------------------------------------------------------------------------
    local magSaved, hoverSaved = nil, nil

    local function touchFlag()
        local pg = LP:FindFirstChild("PlayerGui")
        local gg = pg and pg:FindFirstChild("GameGui")
        local hud = gg and gg:FindFirstChild("headsUpDisplay")
        local pd = hud and hud:FindFirstChild("PlatformDetection")
        local mobile = pd and pd:FindFirstChild("Mobile")
        return (mobile and mobile:IsA("GuiObject")) and mobile or nil
    end

    local function playerClient()
        local ps = LP:FindFirstChild("PlayerScripts")
        local pc = ps and ps:FindFirstChild("PlayerClient")
        return pc
    end

    local function applyMagnet()
        local on = cfg.exp.magnetism == true
        local mobile = touchFlag()
        if mobile then
            if on then
                if magSaved == nil then magSaved = mobile.Visible end
                if mobile.Visible ~= true then mobile.Visible = true end
            elseif magSaved ~= nil then
                if mobile.Visible ~= magSaved then mobile.Visible = magSaved end
                magSaved = nil
            end
        elseif not on then
            magSaved = nil
        end

        local pc = playerClient()
        if pc then
            if on then
                if hoverSaved == nil then
                    local cur = pc:GetAttribute("HoverAutoFire")
                    hoverSaved = (cur == true)
                end
                if pc:GetAttribute("HoverAutoFire") ~= true then
                    pc:SetAttribute("HoverAutoFire", true)
                end
            elseif hoverSaved ~= nil then
                pc:SetAttribute("HoverAutoFire", hoverSaved)
                hoverSaved = nil
            end
        end

        if not on then
            status.magnetism = "off"
        elseif mobile then
            status.magnetism = "on"
        else
            status.magnetism = "waiting for the game HUD"
        end
    end

    E.watch("exp.magnetism", function() attempt("magnetism", applyMagnet) end)
    E.loop("magnetism", function()
        if cfg.exp.magnetism == true then
            attempt("magnetism", applyMagnet)
            return 3
        end
        return 2
    end)

    ------------------------------------------------------------------------
    -- Per weapon patches: recoil and reload speed.
    --
    -- Recoil is read twice by the game: the first shot kick uses the Tool's
    -- Recoil attribute live, and the sustained fire pattern is built FROM that
    -- attribute when the weapon is equipped. Setting it to zero on every
    -- weapon the player carries, before it is equipped, covers both. The
    -- pattern already built for the weapon in hand is flattened as well, with
    -- a copy kept so it can be put back.
    --
    -- Reload timing is almost certainly the server's decision. The client
    -- values are lowered anyway, because the animation and the local gate read
    -- them, and the hand test will show whether it changes anything.
    ------------------------------------------------------------------------
    local RELOAD_SCALE = 0.5
    local toolRec = {}      -- tool -> { recoil, rtm, rt, conns = {} }

    local function isFirearm(tool)
        return typeof(tool) == "Instance" and tool:IsA("Tool")
            and tool:GetAttribute("CanFire") ~= nil
    end

    local function flattenPattern(tool, rec)
        local state = Game.stateOf(tool)
        local pat = type(state) == "table" and rawget(state, "RecoilPattern") or nil
        if type(pat) ~= "table" then return end
        if not rec.pattern then
            local copy = {}
            for i, tier in ipairs(pat) do
                if type(tier) == "table" then
                    local t = {}
                    for k, v in pairs(tier) do t[k] = v end
                    copy[i] = t
                end
            end
            if next(copy) == nil then return end
            rec.pattern, rec.patternRef = copy, pat
        end
        -- tier shape is { startShot, pitch, ..., horizontal }: only the two
        -- magnitudes are zeroed, everything else is left as the game built it
        for _, tier in ipairs(pat) do
            if type(tier) == "table" then
                if type(tier[2]) == "number" then tier[2] = 0 end
                if type(tier[5]) == "number" then tier[5] = 0 end
            end
        end
    end

    local function restorePattern(rec)
        local pat, copy = rec.patternRef, rec.pattern
        if type(pat) ~= "table" or type(copy) ~= "table" then return end
        for i, tier in ipairs(pat) do
            local was = copy[i]
            if type(tier) == "table" and type(was) == "table" then
                for k, v in pairs(was) do tier[k] = v end
            end
        end
        rec.pattern, rec.patternRef = nil, nil
    end

    local function applyTool(tool)
        if not isFirearm(tool) then return end
        local wantRecoil = cfg.exp.noRecoil == true
        local wantReload = cfg.exp.fastReload == true
        local rec = toolRec[tool]

        if not (wantRecoil or wantReload) then
            if rec then
                if rec.recoil ~= nil then tool:SetAttribute("Recoil", rec.recoil) end
                if rec.rtm ~= nil then tool:SetAttribute("ReloadTimeMultiplier", rec.rtm) end
                if rec.rt ~= nil then tool:SetAttribute("ReloadTime", rec.rt) end
                restorePattern(rec)
                for _, c in ipairs(rec.conns) do pcall(function() c:Disconnect() end) end
                toolRec[tool] = nil
            end
            return
        end

        if not rec then
            rec = { conns = {} }
            toolRec[tool] = rec
            -- the server can write these attributes back at any time, so a
            -- change that is not ours is re-applied
            local c1 = tool:GetAttributeChangedSignal("Recoil"):Connect(function()
                if cfg.exp.noRecoil == true and tool:GetAttribute("Recoil") ~= 0 then
                    rec.recoil = tool:GetAttribute("Recoil")
                    tool:SetAttribute("Recoil", 0)
                end
            end)
            rec.conns[#rec.conns + 1] = c1
        end

        if wantRecoil then
            local cur = tool:GetAttribute("Recoil")
            if type(cur) == "number" and cur ~= 0 then
                if rec.recoil == nil then rec.recoil = cur end
                tool:SetAttribute("Recoil", 0)
            end
            flattenPattern(tool, rec)
        elseif rec.recoil ~= nil then
            tool:SetAttribute("Recoil", rec.recoil)
            rec.recoil = nil
            restorePattern(rec)
        end

        if wantReload then
            local rtm = tool:GetAttribute("ReloadTimeMultiplier")
            if type(rtm) == "number" and rtm > RELOAD_SCALE then
                if rec.rtm == nil then rec.rtm = rtm end
                tool:SetAttribute("ReloadTimeMultiplier", rtm * RELOAD_SCALE)
            end
            local rt = tool:GetAttribute("ReloadTime")
            if type(rt) == "number" and rt > 0.2 then
                if rec.rt == nil then rec.rt = rt end
                tool:SetAttribute("ReloadTime", rt * RELOAD_SCALE)
            elseif typeof(rt) == "Vector3" then
                if rec.rt == nil then rec.rt = rt end
                tool:SetAttribute("ReloadTime", rt * RELOAD_SCALE)
            end
        else
            if rec.rtm ~= nil then tool:SetAttribute("ReloadTimeMultiplier", rec.rtm) rec.rtm = nil end
            if rec.rt ~= nil then tool:SetAttribute("ReloadTime", rec.rt) rec.rt = nil end
        end
    end

    local function carried()
        local out = {}
        local char = LP.Character
        if char then
            for _, c in ipairs(char:GetChildren()) do
                if c:IsA("Tool") then out[#out + 1] = c end
            end
        end
        local bp = LP:FindFirstChildOfClass("Backpack")
        if bp then
            for _, c in ipairs(bp:GetChildren()) do
                if c:IsA("Tool") then out[#out + 1] = c end
            end
        end
        return out
    end

    local restoreAllTools

    local function applyAllTools()
        if cfg.exp.noRecoil ~= true and cfg.exp.fastReload ~= true then
            -- both off: hand every weapon back, carried or not
            restoreAllTools()
            status.noRecoil, status.fastReload = "off", "off"
            return
        end
        for _, t in ipairs(carried()) do applyTool(t) end
        -- a weapon that has been dropped or destroyed is forgotten
        for tool, rec in pairs(toolRec) do
            if not tool.Parent then
                for _, c in ipairs(rec.conns) do pcall(function() c:Disconnect() end) end
                toolRec[tool] = nil
            end
        end
        local n = 0
        for _ in pairs(toolRec) do n = n + 1 end
        status.noRecoil = cfg.exp.noRecoil == true and ("on, " .. n .. " weapons") or "off"
        status.fastReload = cfg.exp.fastReload == true and ("on, " .. n .. " weapons") or "off"
    end

    function restoreAllTools()
        for tool, rec in pairs(toolRec) do
            pcall(function()
                if tool.Parent then
                    if rec.recoil ~= nil then tool:SetAttribute("Recoil", rec.recoil) end
                    if rec.rtm ~= nil then tool:SetAttribute("ReloadTimeMultiplier", rec.rtm) end
                    if rec.rt ~= nil then tool:SetAttribute("ReloadTime", rec.rt) end
                end
                restorePattern(rec)
            end)
            for _, c in ipairs(rec.conns) do pcall(function() c:Disconnect() end) end
        end
        table.clear(toolRec)
    end

    E.watch("exp.noRecoil", function() attempt("no recoil", applyAllTools) end)
    E.watch("exp.fastReload", function() attempt("fast reload", applyAllTools) end)

    -- a new weapon, a respawn or an equip all need the patch re-applied, and
    -- the pattern only exists once the weapon has been equipped at least once
    E.loop("weapon patches", function()
        if cfg.exp.noRecoil == true or cfg.exp.fastReload == true then
            attempt("weapon patches", applyAllTools)
            return 1
        end
        if next(toolRec) ~= nil then attempt("weapon patches", applyAllTools) end
        return 2
    end)

    ------------------------------------------------------------------------
    -- Instant aim. Every zoom in this game is a 0.2 second tween on the
    -- camera. While this is on, the camera is written straight to the value
    -- the game is easing toward for a quarter of a second after the aim state
    -- changes, which skips the ease without fighting anything afterwards.
    --
    -- This runs BEFORE the hub's own field of view offset (ENT_FOV, camera
    -- priority plus 8), so a user offset is still added on top.
    ------------------------------------------------------------------------
    local SNAP_TIME = 0.25
    local BASE_FOV = 70
    local snapUntil, snapTo, lastAiming = 0, nil, nil

    local function scopeShowing()
        local pg = LP:FindFirstChild("PlayerGui")
        local sg = pg and pg:FindFirstChild("ScopeGui")
        local screen = sg and sg:FindFirstChild("scopeScreen")
        return screen ~= nil and screen.Visible == true
    end

    local function aimFov(tool, aiming)
        if not aiming then return BASE_FOV end
        if scopeShowing() then
            local scoped = tool:GetAttribute("aimFOVScope")
            if type(scoped) == "number" and scoped > 0 then return scoped end
        end
        local fov = tool:GetAttribute("aimFOV")
        if type(fov) == "number" and fov > 0 then return fov end
        return nil
    end

    local function instantAimStep()
        local tool = Game.equipped()
        if not tool then
            lastAiming = nil
            return
        end
        local aiming = tool:GetAttribute("Aiming") == true
        if aiming ~= lastAiming then
            lastAiming = aiming
            local want = aimFov(tool, aiming)
            if want then
                snapTo = want
                snapUntil = os.clock() + SNAP_TIME
                status.instantAim = "snapped to " .. math.floor(want)
            end
        end
        if snapTo and os.clock() < snapUntil then
            local cam = workspace.CurrentCamera
            if cam and math.abs(cam.FieldOfView - snapTo) > 0.01 then
                cam.FieldOfView = snapTo
            end
        end
    end

    E.watch("exp.instantAim", function(on)
        if on then
            lastAiming = nil
            status.instantAim = "on"
            E.bind("ENT_INSTANTAIM", Enum.RenderPriority.Camera.Value + 7, function()
                if cfg.exp.instantAim ~= true then return end
                attempt("instant aim", instantAimStep)
            end)
        else
            E.unbind("ENT_INSTANTAIM")
            snapTo, snapUntil, lastAiming = nil, 0, nil
            status.instantAim = "off"
        end
    end)

    ------------------------------------------------------------------------
    -- Long throw. Grenades and flares are the only tools with real gravity on
    -- them, so they are recognised by that. The numbers the client holds are
    -- raised while this is on; if the server builds the arc from its own copy
    -- this changes nothing, which the hand test will show.
    ------------------------------------------------------------------------
    local THROW_SPEED, THROW_GRAVITY, THROW_RANGE = 1.6, 0.6, 2
    local throwRec = {}     -- tool -> { velocity, gravity, range }
    local throwObserved = false

    local function isThrowable(tool)
        if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then return false end
        if tool:GetAttribute("CanFire") ~= nil then return false end
        local g = tool:GetAttribute("ProjectileGravity")
        return typeof(g) == "Vector3" and g.Y < -1
    end

    local function applyThrow(tool)
        if not isThrowable(tool) then return end
        local on = cfg.exp.longThrow == true
        local rec = throwRec[tool]
        if on then
            if rec then return end
            rec = {}
            local v = tool:GetAttribute("Velocity")
            local g = tool:GetAttribute("ProjectileGravity")
            local r = tool:GetAttribute("ProjectileMaxDistance")
            if type(v) == "number" and v > 0 then
                rec.velocity = v
                tool:SetAttribute("Velocity", v * THROW_SPEED)
            end
            if typeof(g) == "Vector3" then
                rec.gravity = g
                tool:SetAttribute("ProjectileGravity", g * THROW_GRAVITY)
            end
            if type(r) == "number" and r > 0 then
                rec.range = r
                tool:SetAttribute("ProjectileMaxDistance", r * THROW_RANGE)
            end
            throwRec[tool] = rec
        elseif rec then
            if rec.velocity ~= nil then tool:SetAttribute("Velocity", rec.velocity) end
            if rec.gravity ~= nil then tool:SetAttribute("ProjectileGravity", rec.gravity) end
            if rec.range ~= nil then tool:SetAttribute("ProjectileMaxDistance", rec.range) end
            throwRec[tool] = nil
        end
    end

    local function applyAllThrow()
        for _, t in ipairs(carried()) do applyThrow(t) end
        -- a thrown or dropped tool is put back and forgotten
        for tool in pairs(throwRec) do
            if not tool.Parent then
                throwRec[tool] = nil
            elseif cfg.exp.longThrow ~= true then
                applyThrow(tool)
            end
        end
        local n = 0
        for _ in pairs(throwRec) do n = n + 1 end
        status.longThrow = cfg.exp.longThrow == true and ("on, " .. n .. " throwables") or "off"
    end

    local function restoreAllThrow()
        for tool, rec in pairs(throwRec) do
            pcall(function()
                if tool.Parent then
                    if rec.velocity ~= nil then tool:SetAttribute("Velocity", rec.velocity) end
                    if rec.gravity ~= nil then tool:SetAttribute("ProjectileGravity", rec.gravity) end
                    if rec.range ~= nil then tool:SetAttribute("ProjectileMaxDistance", rec.range) end
                end
            end)
        end
        table.clear(throwRec)
    end

    E.watch("exp.longThrow", function(on)
        if on and not throwObserved and E.remotes and E.remotes.observe then
            -- record what a real throw carries, so a later session can read it
            throwObserved = E.remotes.observe("Throw") == true
        end
        attempt("long throw", applyAllThrow)
    end)

    E.loop("throwables", function()
        if cfg.exp.longThrow == true then
            attempt("long throw", applyAllThrow)
            return 1.5
        end
        if next(throwRec) ~= nil then attempt("long throw", applyAllThrow) end
        return 2
    end)

    ------------------------------------------------------------------------
    -- Put everything back
    ------------------------------------------------------------------------
    E.onUnload(function()
        pcall(function()
            local wasMag = cfg.exp.magnetism
            cfg.exp.magnetism = false
            applyMagnet()
            cfg.exp.magnetism = wasMag
        end)
        restoreAllTools()
        restoreAllThrow()
    end)
end

-- ==== en_15_exp_safety.lua ====
-- en_15_exp_safety: server hop, rejoin, moderator alert and votekick alert.
--
-- Nothing in this part changes the game. It reads who is in the server,
-- listens to the votekick broadcast, and moves you with TeleportService when
-- asked. What it rests on:
--   - A teleport call does not throw when Roblox refuses it. It returns
--     normally and fires TeleportInitFailed a moment later, so a pcall proves
--     nothing and every failure is taken from that signal instead.
--   - Moderators in mod mode are invisible and carry the replicated Player
--     attribute AEIgnore, which exempts them from the server's anti exploit.
--     Mods are rank 248 or higher in the game's group (ModPanel IsModPanelUser).
--   - ClientEvents.VoteKick drives a timed vote bar in InterfaceScript, but its
--     arguments have never been captured, so every call is logged to
--     E.exp.voteLog and read without assuming any shape.
--
-- The two alerts that ship on never install the namecall hook. Only "Leave
-- when votekicked" does, the first time it is switched on, and all it does
-- there is note when you send a votekick request yourself, so a vote you
-- started or voted in is not mistaken for one against you.
do
    local Players, RS, LP, Http = E.Players, E.RS, E.LP, E.HttpService
    local cfg = E.cfg
    local X = E.X

    E.exp = E.exp or {}
    local Exp = E.exp

    ------------------------------------------------------------------------
    -- Small helpers
    ------------------------------------------------------------------------
    -- the toast part loads after this one, so it is looked up on every call
    local function toast(title, body, kind)
        if E.toast then E.try("safety toast", E.toast, title, body, kind) end
    end

    local function short(v, n)
        local s = (string.gsub(tostring(v), "%s+", " "))
        return string.sub(s, 1, n or 80)
    end

    -- Connections owned by one feature, so switching it off can drop exactly
    -- its own without growing the hub wide cleanup list on every toggle.
    local function link(list, signal, fn)
        local ok, c = pcall(function() return signal:Connect(fn) end)
        if ok and c then
            list[#list + 1] = c
            return c
        end
        return nil
    end

    local function unlinkAll(list)
        for i = #list, 1, -1 do
            local c = list[i]
            pcall(function() c:Disconnect() end)
            list[i] = nil
        end
    end

    -- Runs fn on its own thread and stops waiting after `timeout` seconds. The
    -- game's moderator modules may yield on web requests, and a worker must
    -- never hang on one. A timed out thread is simply abandoned.
    local function callTimed(timeout, fn, ...)
        local args = table.pack(...)
        local box = { done = false, ok = false, value = nil }
        task.spawn(function()
            local r = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
            box.ok, box.value, box.done = r[1], r[2], true
        end)
        local t0 = os.clock()
        while not box.done and E.alive and os.clock() - t0 < timeout do
            task.wait(0.1)
        end
        if not box.done then return false, "timed out", true end
        return box.ok, box.value, false
    end

    local rng = Random.new()

    local TS
    local function teleportService()
        if not TS then
            local ok, s = pcall(game.GetService, game, "TeleportService")
            if ok then TS = s end
        end
        return TS
    end

    ------------------------------------------------------------------------
    -- Server list. The public games API pages 100 servers at a time; fullest
    -- first means the first page is almost always enough.
    ------------------------------------------------------------------------
    local LIST_URL = "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&excludeFullGames=true&limit=100"

    local function httpGet(url)
        local ok, body = pcall(function() return game:HttpGet(url) end)
        if ok and type(body) == "string" and #body > 0 then return body end
        -- some executors throw from HttpGet on a non 200 reply, request does not
        if X.request then
            local ok2, res = pcall(X.request, { Url = url, Method = "GET" })
            if ok2 and type(res) == "table" and type(res.Body) == "string" and #res.Body > 0 then
                return res.Body
            end
        end
        return nil
    end

    -- Ids of other public servers with room. Servers with a single free slot
    -- are kept apart, because someone else often takes that slot during the
    -- few seconds a teleport needs, and that fails as GameFull.
    local function fetchServers()
        local base = string.format(LIST_URL, game.PlaceId)
        local roomy, tight = {}, {}
        local cursor, why = nil, nil
        for _ = 1, 3 do
            local url = base
            if cursor then url = url .. "&cursor=" .. Http:UrlEncode(cursor) end
            local body = httpGet(url)
            if not body then
                why = "The server list could not be downloaded."
                break
            end
            local ok, data = pcall(Http.JSONDecode, Http, body)
            if not ok or type(data) ~= "table" then
                why = "The server list came back unreadable."
                break
            end
            if type(data.data) ~= "table" then
                -- a rate limited reply is { errors = { ... } } with no data
                if data.errors ~= nil then
                    why = "Roblox is limiting server list requests right now."
                else
                    why = "The server list came back empty."
                end
                break
            end
            for _, s in ipairs(data.data) do
                if type(s) == "table" and type(s.id) == "string" and s.id ~= game.JobId
                    and type(s.playing) == "number" and type(s.maxPlayers) == "number" then
                    local free = s.maxPlayers - s.playing
                    if free >= 2 then
                        roomy[#roomy + 1] = s.id
                    elseif free >= 1 then
                        tight[#tight + 1] = s.id
                    end
                end
            end
            cursor = type(data.nextPageCursor) == "string" and data.nextPageCursor or nil
            if #roomy + #tight > 0 or not cursor then break end
        end
        return roomy, tight, why
    end

    ------------------------------------------------------------------------
    -- Moves. One attempt at a time. An attempt may make a second move after a
    -- refusal, and each move is numbered so a watchdog or retry left over from
    -- an earlier move can tell it is stale.
    ------------------------------------------------------------------------
    local Hop = { attempt = nil, lastPress = -1e9, lastBusy = -1e9, failConn = nil, stateConn = nil }
    local WATCHDOG = 25
    local WATCHDOG_EXTRA = 20

    local function pickServer(a)
        for _, bucket in ipairs({ a.roomy, a.tight }) do
            local open = {}
            for _, id in ipairs(bucket) do
                if not a.tried[id] then open[#open + 1] = id end
            end
            if #open > 0 then return open[rng:NextInteger(1, #open)] end
        end
        return nil
    end

    local function finish(a, failed)
        if Hop.attempt ~= a then return end
        Hop.attempt = nil
        if failed and a.onFail then pcall(a.onFail) end
    end

    -- A successful teleport ends this script with the client, so still being
    -- here long after a move means it silently never started. A move Roblox
    -- has reported as under way (Player.OnTeleport) is only waiting on a slow
    -- destination server, so it gets two extra waits before giving up.
    local function armWatchdog(a)
        a.move = a.move + 1
        local mine = a.move
        local function check(extra)
            if not E.alive or Hop.attempt ~= a or a.move ~= mine then return end
            if a.progress == mine and extra > 0 then
                task.delay(WATCHDOG_EXTRA, check, extra - 1)
                return
            end
            toast("Still in this server", "The move never started. Try again in a moment.", "warn")
            finish(a, true)
        end
        task.delay(WATCHDOG, check, 2)
    end

    local function goPlace(a)
        local ts = teleportService()
        local ok, err = pcall(function() ts:Teleport(game.PlaceId, LP) end)
        if not ok then
            toast("Could not change server", "Roblox refused the move. " .. short(err), "warn")
            finish(a, true)
            return false
        end
        armWatchdog(a)
        return true
    end

    local function goInstance(a, id)
        a.tried[id] = true
        local ts = teleportService()
        local ok = pcall(function() ts:TeleportToPlaceInstance(game.PlaceId, id, LP) end)
        if not ok then return goPlace(a) end
        armWatchdog(a)
        return true
    end

    local REASONS = {
        GameFull     = "That server filled up.",
        GameEnded    = "That server has closed.",
        GameNotFound = "That server no longer exists.",
        Unauthorized = "Roblox did not allow the move.",
        Flooded      = "Too many moves in a short time.",
    }

    local function onInitFailed(player, result, message)
        if player ~= LP then return end
        local a = Hop.attempt
        if not a then return end
        local okName, name = pcall(function() return result.Name end)
        name = okName and tostring(name) or tostring(result)
        -- a second request while the first is still in flight; nothing failed
        if name == "IsTeleporting" then return end

        a.move = a.move + 1 -- the refused move's watchdog is now stale
        local why = REASONS[name]
        if not why then
            why = (type(message) == "string" and message ~= "") and short(message, 100) or "Roblox refused the move."
        end

        -- asking again for a server you are not allowed back into cannot work,
        -- and a public server instead would not be the rejoin that was asked for
        if a.retried or (a.kind == "rejoin" and name == "Unauthorized") then
            toast(a.kind == "rejoin" and "Could not rejoin" or "Could not change server", why, "warn")
            finish(a, true)
            return
        end
        a.retried = true

        -- rejoining a server that has closed cannot work, so that one case
        -- falls through to a fresh server instead of trying the same id again
        local sameAgain = a.kind == "rejoin" and name ~= "GameEnded" and name ~= "GameNotFound"
        if a.kind == "hop" then
            toast("Could not join that server", why .. " Trying another one.", "info")
        elseif sameAgain then
            toast("Could not rejoin", why .. " Trying once more.", "info")
        else
            toast("Could not change server", why .. " Trying a fresh server.", "info")
        end

        task.delay(name == "Flooded" and 5 or 1.5, function()
            if not E.alive or Hop.attempt ~= a then return end
            if a.kind == "hop" then
                local id = pickServer(a)
                if id then goInstance(a, id) else goPlace(a) end
            elseif sameAgain then
                goInstance(a, game.JobId)
            else
                goPlace(a)
            end
        end)
    end

    local function ensureFailListener()
        if not Hop.failConn then
            local ts = teleportService()
            if ts then Hop.failConn = E.connect(ts.TeleportInitFailed, onInitFailed) end
        end
        if not Hop.stateConn then
            local okS, sig = pcall(function() return LP.OnTeleport end)
            if okS and sig then
                Hop.stateConn = E.connect(sig, function(state)
                    local a = Hop.attempt
                    -- Failed is left to TeleportInitFailed, which carries the reason
                    if a and state ~= Enum.TeleportState.Failed then a.progress = a.move end
                end)
            end
        end
    end

    -- `auto` is a move the hub starts itself (a moderator, a votekick). It
    -- skips the double click guard but never runs beside another move; its
    -- failure callback is chained onto the move already in flight instead.
    local function begin(kind, auto, onFail)
        local now = os.clock()
        local cur = Hop.attempt
        if cur then
            if onFail then
                local prev = cur.onFail
                cur.onFail = function()
                    if prev then pcall(prev) end
                    pcall(onFail)
                end
            end
            if not auto and now - Hop.lastBusy > 3 then
                Hop.lastBusy = now
                toast("Already changing server", "Give it a few seconds.", "info")
            end
            return nil
        end
        if not auto then
            if now - Hop.lastPress < 4 then return nil end
            Hop.lastPress = now
        end
        ensureFailListener()
        local a = { kind = kind, tried = {}, roomy = {}, tight = {}, move = 0, retried = false, onFail = onFail }
        Hop.attempt = a
        return a
    end

    -- Join a different public server of this place. `reason` is only passed
    -- by the hub's own alerts; the panel button calls it bare.
    function Exp.hop(reason, onFail)
        local a = begin("hop", reason ~= nil, onFail)
        if not a then return false end
        task.spawn(function()
            -- an alert that starts a hop has already said so in its own toast
            if reason == nil then
                toast("Finding another server", "Looking for a public server with room.", "info")
            end
            local ok, roomy, tight, why = pcall(fetchServers)
            if not E.alive or Hop.attempt ~= a then return end
            if ok then
                a.roomy, a.tight = roomy, tight
            else
                why = "The server list could not be read."
            end
            local id = pickServer(a)
            if id then
                local count = #a.roomy + #a.tight
                toast("Joining another server",
                    string.format("%d %s room. Picked one at random.", count, count == 1 and "server has" or "servers have"), "info")
                goInstance(a, id)
            else
                toast("Joining any open server",
                    (why or "No other public server has room right now.") .. " Roblox will pick one for you.", "info")
                goPlace(a)
            end
        end)
        return true
    end

    function Exp.rejoin()
        local a = begin("rejoin", false, nil)
        if not a then return false end
        task.spawn(function()
            -- an empty server shuts down the moment its last player leaves, so
            -- asking for it back by id would only fail with GameEnded
            local alone = #Players:GetPlayers() <= 1
            if alone or game.JobId == "" then
                a.kind = "fresh"
                toast("Joining a fresh server",
                    alone and "You are the only player here, and an empty server closes when you leave."
                        or "This server cannot be rejoined directly.", "info")
                goPlace(a)
            else
                toast("Rejoining this server", "You should be back in a few seconds.", "info")
                goInstance(a, game.JobId)
            end
        end)
        return true
    end

    ------------------------------------------------------------------------
    -- Moderator alert
    --
    -- Two signals. AEIgnore is exact but only exists while a mod is actively
    -- in mod mode. The rank check catches staff who are playing normally, and
    -- is done the game's own way first (ModPanel's IsModPanelUser module) and
    -- then straight from the group rank. Module signatures are unknown, so
    -- only a boolean answer is ever believed, every call runs on a worker
    -- thread with a timeout, and any error just moves on to the next route.
    ------------------------------------------------------------------------
    local MOD_RANK = 248
    local GRACE = 3

    local Mod = {
        active = false,
        conns = {},
        perPlayer = {},   -- Player -> AEIgnore connection
        known = {},       -- UserId -> { player, how }
        toasted = {},     -- UserId -> true, once per player per load
        verdict = {},     -- UserId -> true | false | "unknown" | "queued"
        queue = {},
        working = false,
        leaving = false,
    }
    Exp.modLog = {}
    Exp.modInfo = { route = "not checked yet", groupId = nil, groupSource = nil }

    local function logMod(line)
        local log = Exp.modLog
        log[#log + 1] = string.format("%.1f  %s", os.clock(), line)
        if #log > 12 then table.remove(log, 1) end
    end

    local function modPresent()
        for _, k in pairs(Mod.known) do
            if k.player and k.player.Parent == Players then return true end
        end
        return false
    end

    local considerLeave

    local function flag(p, how)
        local id = p.UserId
        local k = Mod.known[id]
        if k then
            k.player = p
            if how == "modmode" then k.how = how end
        else
            Mod.known[id] = { player = p, how = how }
            logMod(string.format("user %d flagged by %s", id, how))
        end
        if not Mod.toasted[id] and (cfg.exp.modAlert or cfg.exp.modLeave) then
            Mod.toasted[id] = true
            local who = E.nameOf(p, "A moderator")
            local body
            if how == "modmode" then
                body = who .. " is in mod mode, which makes them invisible."
            else
                body = who .. " is here. Moderators can spectate you and act on reports."
            end
            if cfg.exp.modLeave and not Mod.leaving then body = body .. " Leaving in a few seconds." end
            toast("Moderator in your server", body, "warn")
        end
        considerLeave(false)
    end

    -- The short grace period is deliberate: it lets the toast be read, and it
    -- respects a change of mind or a moderator who was only passing through.
    considerLeave = function(fromToggle)
        if not cfg.exp.modLeave or Mod.leaving or not modPresent() then return end
        Mod.leaving = true
        if fromToggle then
            toast("Leaving this server", "A moderator is still here. Moving you in a few seconds.", "warn")
        end
        task.delay(GRACE, function()
            if not E.alive then return end
            if not cfg.exp.modLeave then
                Mod.leaving = false
                return
            end
            if not modPresent() then
                Mod.leaving = false
                toast("Staying in this server", "The moderator left before you did.", "info")
                return
            end
            Exp.hop("moderator", function() Mod.leaving = false end)
        end)
    end

    -- resolved once per load, on the worker thread
    local checkers, groupId, resolved = {}, nil, false

    local function asCallable(v, name)
        if type(v) == "function" then return v, nil end
        if type(v) ~= "table" then return nil, nil end
        for _, key in ipairs({ name, "IsModPanelUser", "WaitForIsModPanelUser", "Check" }) do
            local f = rawget(v, key)
            if type(f) == "function" then return f, v end
        end
        local okM, mt = pcall(getmetatable, v)
        local call = okM and type(mt) == "table" and rawget(mt, "__call") or nil
        if type(call) == "function" then
            return function(...) return call(v, ...) end, nil
        end
        return nil, nil
    end

    local function addChecker(fn, owner, name, yields)
        checkers[#checkers + 1] = { fn = fn, owner = owner, name = name, yields = yields, misses = 0, timeouts = 0 }
    end

    local function resolve()
        if resolved then return end
        resolved = true

        local panel = RS:FindFirstChild("ModPanel")
        if not panel then
            local ok, v = callTimed(9, RS.WaitForChild, RS, "ModPanel", 8)
            panel = (ok and typeof(v) == "Instance") and v or nil
        end
        local utils = panel and panel:FindFirstChild("Utils")
        local node = utils and utils:FindFirstChild("Mod")

        local function fromModule(ms, name, yields)
            if not (ms and ms:IsA("ModuleScript")) then return end
            local ok, mod = callTimed(4, require, ms)
            if not ok then return end
            local fn, owner = asCallable(mod, name)
            if fn then addChecker(fn, owner, name, yields) end
        end

        if node then
            fromModule(node:FindFirstChild("IsModPanelUser"), "IsModPanelUser", false)
            fromModule(node:FindFirstChild("WaitForIsModPanelUser"), "WaitForIsModPanelUser", true)
            -- Mod may itself be a module holding both functions
            if #checkers == 0 and node:IsA("ModuleScript") then
                local ok, mod = callTimed(4, require, node)
                if ok and type(mod) == "table" then
                    for _, key in ipairs({ "IsModPanelUser", "WaitForIsModPanelUser" }) do
                        local f = rawget(mod, key)
                        if type(f) == "function" then addChecker(f, mod, key, key ~= "IsModPanelUser") end
                    end
                end
            end
        end

        -- The group behind the rank. Moderators are ranked in the group that
        -- owns the game, so that one is trusted first. Only a game owned by a
        -- user falls back to reading a lone group sized number out of the
        -- check's own constants and upvalues, with the place, universe and
        -- owner ids ruled out so they cannot be mistaken for a group.
        local creatorGroup
        local notGroup = { [E.PLACE_ID] = true, [E.GAME_ID] = true }
        pcall(function()
            notGroup[game.PlaceId], notGroup[game.GameId] = true, true
            if game.CreatorType == Enum.CreatorType.Group then
                creatorGroup = game.CreatorId
            else
                notGroup[game.CreatorId] = true
            end
        end)
        local dbg = type(debug) == "table" and debug or nil
        local found, count = {}, 0
        for _, reader in ipairs({ dbg and rawget(dbg, "getconstants"), dbg and rawget(dbg, "getupvalues") }) do
            if type(reader) == "function" then
                for _, c in ipairs(checkers) do
                    local ok, list = pcall(reader, c.fn)
                    if ok and type(list) == "table" then
                        for _, v in pairs(list) do
                            if type(v) == "number" and v >= 10000 and v < 1e12 and v % 1 == 0
                                and not notGroup[v] and not found[v] then
                                found[v] = true
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end
        if creatorGroup then
            groupId = creatorGroup
            Exp.modInfo.groupSource = found[creatorGroup] and "game owner, confirmed by the check" or "game owner"
        elseif count == 1 then
            for v in pairs(found) do groupId = v end
            Exp.modInfo.groupSource = "check constants"
        end
        if not groupId and panel then
            -- last resort: the rank cache may keep the id as a plain field
            local subs = panel:FindFirstChild("Subsystems")
            local cache = subs and subs:FindFirstChild("GroupRankCache")
            if cache and cache:IsA("ModuleScript") then
                local ok, mod = callTimed(4, require, cache)
                if ok and type(mod) == "table" then
                    for k, v in pairs(mod) do
                        if type(k) == "string" and string.find(string.lower(k), "group", 1, true)
                            and type(v) == "number" and v >= 1000 and v % 1 == 0 then
                            groupId, Exp.modInfo.groupSource = v, "rank cache"
                            break
                        end
                    end
                end
            end
        end

        Exp.modInfo.groupId = groupId
        local names = {}
        for _, c in ipairs(checkers) do names[#names + 1] = c.name end
        Exp.modInfo.route = string.format("module checks: %s. group rank: %s.",
            #names > 0 and table.concat(names, ", ") or "none",
            groupId and tostring(groupId) or "none")
        logMod(Exp.modInfo.route)
    end

    -- only a boolean counts as an answer; anything else means "this route
    -- cannot tell", and a route that keeps failing is dropped for the session
    local function ask(c, p)
        if c.dead then return nil end
        local ok, v, timedOut = callTimed(c.yields and 5 or 3, c.fn, p)
        if ok and type(v) == "boolean" then return v end
        if timedOut then
            c.timeouts = c.timeouts + 1
            if c.timeouts >= 2 then c.dead = true end
            return nil
        end
        -- a method written with a colon wants its table first
        if c.owner then
            ok, v, timedOut = callTimed(3, c.fn, c.owner, p)
            if ok and type(v) == "boolean" then return v end
        end
        c.misses = c.misses + 1
        if c.misses >= 3 then c.dead = true end
        return nil
    end

    local function evaluate(p)
        resolve()
        local plain, rank
        for _, c in ipairs(checkers) do
            if not c.yields then
                local v = ask(c, p)
                if v == true then return true, "module" end
                if v == false then plain = false end
            end
        end
        if groupId then
            local ok, r = callTimed(8, p.GetRankInGroup, p, groupId)
            if ok and type(r) == "number" then
                if r >= MOD_RANK then return true, "rank" end
                rank = r
            end
        end
        -- the waiting check may block until something only mods ever get, so
        -- it is asked only when nothing else could answer
        if plain == nil and rank == nil then
            for _, c in ipairs(checkers) do
                if c.yields then
                    local v = ask(c, p)
                    if v ~= nil then return v, "module" end
                end
            end
            return nil, "unknown"
        end
        return false, "clear"
    end

    local function drain()
        while E.alive and Mod.active and #Mod.queue > 0 do
            local p = table.remove(Mod.queue, 1)
            if p.Parent == Players then
                local ok, verdict, how = pcall(evaluate, p)
                if not ok then
                    Mod.verdict[p.UserId] = "unknown"
                    logMod("check failed: " .. short(verdict))
                else
                    if verdict == nil then
                        Mod.verdict[p.UserId] = "unknown"
                    else
                        Mod.verdict[p.UserId] = verdict
                    end
                    if verdict == true and Mod.active then flag(p, how) end
                end
            else
                Mod.verdict[p.UserId] = nil
            end
            task.wait(0.2)
        end
        -- anyone still waiting is asked again the next time the alert is on
        for _, p in ipairs(Mod.queue) do
            if Mod.verdict[p.UserId] == "queued" then Mod.verdict[p.UserId] = nil end
        end
        table.clear(Mod.queue)
        Mod.working = false
    end

    local function enqueue(p)
        if p == LP then return end
        local known = Mod.verdict[p.UserId]
        if known == true then
            -- a moderator already found this load, back in the server or seen
            -- again after the alert was off: track the new Player object so
            -- leaving still works, without asking the web again
            local k = Mod.known[p.UserId]
            flag(p, k and k.how or "module")
            return
        end
        if known ~= nil then return end
        Mod.verdict[p.UserId] = "queued"
        Mod.queue[#Mod.queue + 1] = p
        if not Mod.working then
            Mod.working = true
            task.spawn(drain)
        end
    end

    local function inModMode(p)
        local ok, v = pcall(p.GetAttribute, p, "AEIgnore")
        return ok and v ~= nil and v ~= false
    end

    local function attach(p)
        if p == LP or Mod.perPlayer[p] then return end
        local ok, c = pcall(function()
            return p:GetAttributeChangedSignal("AEIgnore"):Connect(function()
                if Mod.active and inModMode(p) then flag(p, "modmode") end
            end)
        end)
        if ok and c then Mod.perPlayer[p] = c end
        if inModMode(p) then flag(p, "modmode") end
    end

    local function modOn()
        if Mod.active then return end
        Mod.active = true
        link(Mod.conns, Players.PlayerAdded, function(p)
            if not Mod.active then return end
            attach(p)
            enqueue(p)
        end)
        link(Mod.conns, Players.PlayerRemoving, function(p)
            local c = Mod.perPlayer[p]
            if c then
                pcall(function() c:Disconnect() end)
                Mod.perPlayer[p] = nil
            end
        end)
        for _, p in ipairs(Players:GetPlayers()) do
            attach(p)
            enqueue(p)
        end
        considerLeave(false)
    end

    local function modOff()
        if not Mod.active then return end
        Mod.active = false
        unlinkAll(Mod.conns)
        for _, c in pairs(Mod.perPlayer) do
            pcall(function() c:Disconnect() end)
        end
        table.clear(Mod.perPlayer)
    end

    local function refreshMod()
        if E.inGame and (cfg.exp.modAlert or cfg.exp.modLeave) then modOn() else modOff() end
    end
    E.watch("exp.modAlert", refreshMod)
    E.watch("exp.modLeave", function(on)
        refreshMod()
        if on then considerLeave(true) end
    end)

    ------------------------------------------------------------------------
    -- Votekick alert
    --
    -- The vote sends several updates while its bar fills, so calls that arrive
    -- within VOTE_WINDOW of each other are one vote and toast once. Players
    -- are found in the arguments as a Player, a character, a user id or a
    -- name (also inside a sentence), one table level deep, in the order they
    -- appear. From that:
    --   - only you named, or you named first: the vote is against you
    --   - you and exactly one other player on the call that opens the vote:
    --     treated as against you, the other most likely being who started it
    --   - you named later in a vote about someone else, or beside several
    --     players: most likely a list of voters, so it warns but never moves you
    -- A votekick request you sent yourself shortly before or during the vote
    -- means you started it or voted in it, and that always wins.
    ------------------------------------------------------------------------
    local VOTE_WINDOW = 15
    local VOTE_LONGEST = 90
    local SENT_LEAD = 10

    local Vote = {
        active = false,
        conns = {},
        guis = setmetatable({}, { __mode = "k" }),
        gen = 0,
        started = -1e9,
        lastAt = -1e9,
        key = nil,
        told = false,
        me = nil,          -- per vote: nil, "mentioned", "aimed" or "mine"
        left = false,
        retryAfter = 0,
        sentAt = nil,      -- when you last sent ServerEvents.VoteKick, once watched
        sendWatch = false,
    }
    Exp.voteLog = {}
    Exp.voteInfo = { sendWatch = "not started" }

    local function describe(v, depth)
        local ty = typeof(v)
        if ty == "Instance" then
            local okC, cls = pcall(function() return v.ClassName end)
            return (okC and tostring(cls) or "Instance") .. "(" .. short(v, 30) .. ")"
        end
        if ty == "table" then
            if depth >= 1 then return "table" end
            local parts, count = {}, 0
            for k, val in pairs(v) do
                count = count + 1
                if count > 6 then
                    parts[#parts + 1] = "..."
                    break
                end
                parts[#parts + 1] = tostring(k) .. "=" .. describe(val, depth + 1)
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        if ty == "string" then return string.format("%q", string.sub(v, 1, 60)) end
        return ty .. "(" .. tostring(v) .. ")"
    end

    local function escape(s)
        return (string.gsub(s, "%W", "%%%0"))
    end

    -- Words a vote message or gui is likely to hold. A player who happens to
    -- be called one of these is never matched by name, or every vote would
    -- look like it names them.
    local STOP = {
        vote = true, votes = true, voted = true, kick = true, kicked = true, votekick = true,
        yes = true, no = true, player = true, players = true, start = true, started = true,
        ["end"] = true, ended = true, against = true, cancel = true, time = true, team = true,
    }

    -- Lower case names of everyone here, built at most once per call.
    -- Usernames are letters, digits and underscores, so a whole word match
    -- inside a sentence cannot fire on part of a longer name. Display names
    -- are matched inside text only when they have that same shape, and
    -- otherwise only when they are the entire string.
    local function roster()
        local list = {}
        for _, p in ipairs(Players:GetPlayers()) do
            local ok, name, display = pcall(function()
                return string.lower(p.Name), string.lower(p.DisplayName)
            end)
            if ok then
                local useDisplay = #display >= 3 and display ~= name and not STOP[display]
                list[#list + 1] = {
                    p = p,
                    id = tostring(p.UserId),
                    name = not STOP[name] and name or nil,
                    display = useDisplay and display or nil,
                    displayWord = useDisplay and string.match(display, "^[%w_]+$") ~= nil,
                }
            end
        end
        return list
    end

    -- where player r is named in the lower case text s, or nil
    local function nameAt(s, r)
        if s == r.id then return 1 end
        if r.name then
            if s == r.name then return 1 end
            local at = string.find(s, "%f[%w_]" .. escape(r.name) .. "%f[^%w_]")
            if at then return at end
        end
        if r.display then
            if s == r.display then return 1 end
            if r.displayWord then
                local at = string.find(s, "%f[%w_]" .. escape(r.display) .. "%f[^%w_]")
                if at then return at end
            end
        end
        return nil
    end

    local function playerOf(inst)
        if inst:IsA("Player") then return inst end
        if inst:IsA("Humanoid") then inst = inst.Parent end
        if inst and inst:IsA("Model") then return Players:GetPlayerFromCharacter(inst) end
        return nil
    end

    -- Everyone the arguments name. `first` says whether you or someone else
    -- was named first, so a payload that puts the target before the voters
    -- can be read the right way round.
    local function scan(args)
        local found = { me = false, first = nil, others = {} }
        local seen, list = {}, nil
        local function note(p)
            if typeof(p) ~= "Instance" then return end
            if p == LP then
                found.me = true
                found.first = found.first or "me"
            elseif not seen[p] then
                seen[p] = true
                found.others[#found.others + 1] = p
                found.first = found.first or "other"
            end
        end
        local function look(v)
            local ty = typeof(v)
            if ty == "Instance" then
                local ok, p = pcall(playerOf, v)
                if ok then note(p) end
            elseif ty == "number" then
                if v >= 1000 and v % 1 == 0 then
                    local ok, p = pcall(Players.GetPlayerByUserId, Players, v)
                    if ok then note(p) end
                end
            elseif ty == "string" and #v >= 3 and #v <= 200 then
                list = list or roster()
                local s = string.lower(v)
                local hits = {}
                for _, r in ipairs(list) do
                    local at = nameAt(s, r)
                    if at then hits[#hits + 1] = { at = at, p = r.p } end
                end
                if #hits > 1 then table.sort(hits, function(a, b) return a.at < b.at end) end
                for _, h in ipairs(hits) do note(h.p) end
            end
        end
        for i = 1, math.min(args.n or #args, 10) do
            local v = args[i]
            look(v)
            if type(v) == "table" then
                local count = 0
                for k, inner in pairs(v) do
                    count = count + 1
                    if count > 24 then break end
                    look(k)
                    look(inner)
                end
            end
        end
        return found
    end

    -- a votekick request of your own went out shortly before or during this
    -- vote, so you started it or voted in it
    local function tookPart()
        return Vote.sentAt ~= nil and Vote.sentAt >= Vote.started - SENT_LEAD
    end

    local function canLeave()
        return not Vote.left and os.clock() >= Vote.retryAfter
    end

    local function leaveForVote()
        if not canLeave() then return end
        Vote.left = true
        Exp.hop("votekick", function()
            Vote.left = false
            Vote.retryAfter = os.clock() + 8
        end)
    end

    local function onVote(source, args)
        if not Vote.active then return end
        local found = scan(args)
        local me, others = found.me, found.others

        local parts = {}
        for i = 1, math.min(args.n or #args, 8) do parts[i] = describe(args[i], 0) end
        local log = Exp.voteLog
        log[#log + 1] = string.format("%.1f  %s%s  %s", os.clock(), source,
            me and " (mentions you)" or "", table.concat(parts, "  |  "))
        if #log > 8 then table.remove(log, 1) end

        local now = os.clock()
        local key = nil
        if found.first == "me" then
            key = "you"
        elseif found.first == "other" then
            key = tostring(others[1].UserId)
        end
        -- A new vote starts after a quiet gap, or once the longest vote is
        -- over. A later call naming the same player first is still the same
        -- vote, such as a result sent when the timer runs out, so it does not
        -- toast twice or move you on a vote that already ended.
        local sameTarget = key ~= nil and key == Vote.key
        local fresh = now - Vote.started > VOTE_LONGEST
            or (now - Vote.lastAt > VOTE_WINDOW and not sameTarget)
        Vote.lastAt = now
        if fresh then
            Vote.started, Vote.key = now, key
            Vote.told, Vote.me, Vote.left = false, nil, false
        elseif key and not Vote.key then
            Vote.key = key
        end

        local alert, leave = cfg.exp.voteAlert, cfg.exp.voteLeave

        if me then
            -- decided once it is certain; a mere mention may still be upgraded
            if Vote.me ~= "aimed" and Vote.me ~= "mine" then
                local state
                if tookPart() then
                    state = "mine"
                elseif #others == 0 or found.first == "me" or (fresh and #others == 1) then
                    state = "aimed"
                else
                    state = "mentioned"
                end
                if state ~= Vote.me then
                    local was = Vote.me
                    Vote.me, Vote.told = state, true
                    if state == "aimed" and (alert or leave) then
                        local body = "Players may be voting to kick you. Turn on Leave when votekicked to move out automatically."
                        if leave then
                            body = canLeave() and "Moving you to another server now."
                                or "Your last move did not work. Press Hop to try again."
                        end
                        toast("Votekick against you", body, "warn")
                    elseif state == "mine" and alert and was == nil then
                        toast("Votekick started", "It names you because you started it or voted in it.", "info")
                    elseif state == "mentioned" and (alert or leave) then
                        toast("Votekick mentions you",
                            "Other players are named too, so it may not be about you."
                                .. (leave and " You are staying for now." or ""),
                            "warn")
                    end
                end
            end
        elseif not Vote.told then
            Vote.told = true
            if alert then
                local body = "A vote to kick a player has started in this server."
                if #others == 1 then
                    body = E.nameOf(others[1], "Another player") .. " appears to be the target."
                end
                toast("Votekick started", body, "info")
            end
        end

        if Vote.me == "aimed" and leave then leaveForVote() end
    end

    -- Installs the shared remote hook, so it waits until Leave when
    -- votekicked is first switched on. It only notes the time of your own
    -- request and never touches the call.
    local function ensureSendWatch()
        if Vote.sendWatch then return end
        local R = E.remotes
        if not (R and R.on) then return end
        Vote.sendWatch = true
        local ok = R.on("VoteKick", function()
            Vote.sentAt = os.clock()
            return nil
        end)
        Exp.voteInfo.sendWatch = ok and "watching your own votekick requests"
            or "unavailable, so a vote you start yourself may be read as one against you"
    end

    -- Fallback for a remote that never fires: a GUI named like VoteKick being
    -- shown. Event driven only. Just the transition to shown counts, because
    -- a template that is already visible when the gui is cloned on respawn
    -- would otherwise raise a false alarm every life.
    local function voteNamed(name)
        -- every gui the game creates passes through here, so reject most names
        -- with a pattern that allocates nothing before building a new string
        if not string.find(name, "[Vv][Oo][Tt][Ee]") then return false end
        local n = (string.gsub(string.lower(name), "[%s_%-]", ""))
        if not (string.find(n, "votekick", 1, true) or string.find(n, "kickvote", 1, true)) then
            return false
        end
        -- the screen where you pick someone to vote against lists every player,
        -- you included, so opening it must not read as a vote naming you
        for _, word in ipairs({ "button", "menu", "list", "select", "picker" }) do
            if string.find(n, word, 1, true) then return false end
        end
        return true
    end

    local function shown(inst)
        local node = inst
        while node and node ~= LP do
            if node:IsA("LayerCollector") then return node.Enabled end
            if node:IsA("GuiObject") and not node.Visible then return false end
            node = node.Parent
        end
        return false
    end

    local function readGui(inst)
        local args = { n = 1, inst.Name }
        for _, d in ipairs(inst:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local t = d.Text
                if t ~= "" then
                    args.n = args.n + 1
                    args[args.n] = t
                    if args.n >= 10 then break end
                end
            end
        end
        return args
    end

    local function watchGui(inst)
        if Vote.guis[inst] or not voteNamed(inst.Name) then return end
        local prop
        if inst:IsA("GuiObject") then
            prop = "Visible"
        elseif inst:IsA("LayerCollector") then
            prop = "Enabled"
        else
            return
        end
        Vote.guis[inst] = true
        -- drop connections whose gui has since been destroyed
        if #Vote.conns > 64 then
            for i = #Vote.conns, 1, -1 do
                if not Vote.conns[i].Connected then table.remove(Vote.conns, i) end
            end
        end
        local was = shown(inst)
        link(Vote.conns, inst:GetPropertyChangedSignal(prop), function()
            local now = shown(inst)
            if now and not was then
                -- the game fills in the names around the same moment it shows
                -- the frame, so read the text a beat later
                task.delay(0.15, function()
                    if not (E.alive and Vote.active) then return end
                    E.try("votekick gui", function()
                        if shown(inst) then onVote("gui", readGui(inst)) end
                    end)
                end)
            end
            was = now
        end)
    end

    local function voteOn()
        if Vote.active then return end
        Vote.active = true
        Vote.gen = Vote.gen + 1
        local gen = Vote.gen

        task.spawn(function()
            E.try("votekick remote", function()
                local ce = RS:FindFirstChild("ClientEvents") or RS:WaitForChild("ClientEvents", 10)
                local remote = ce and (ce:FindFirstChild("VoteKick") or ce:WaitForChild("VoteKick", 10))
                if Vote.gen ~= gen or not Vote.active then return end
                if not (remote and remote:IsA("RemoteEvent")) then
                    Exp.voteLog[#Exp.voteLog + 1] = "ClientEvents.VoteKick was not found, only the gui fallback is watching"
                    return
                end
                link(Vote.conns, remote.OnClientEvent, function(...)
                    E.try("votekick alert", onVote, "remote", table.pack(...))
                end)
            end)
        end)

        task.spawn(function()
            E.try("votekick gui watch", function()
                local pg = LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui", 10)
                if Vote.gen ~= gen or not Vote.active or not pg then return end
                link(Vote.conns, pg.DescendantAdded, function(d)
                    if Vote.active then pcall(watchGui, d) end
                end)
                for _, d in ipairs(pg:GetDescendants()) do pcall(watchGui, d) end
            end)
        end)
    end

    local function voteOff()
        if not Vote.active then return end
        Vote.active = false
        Vote.gen = Vote.gen + 1
        unlinkAll(Vote.conns)
        table.clear(Vote.guis)
    end

    local function refreshVote()
        if E.inGame and (cfg.exp.voteAlert or cfg.exp.voteLeave) then voteOn() else voteOff() end
        if E.inGame and cfg.exp.voteLeave then ensureSendWatch() end
    end
    E.watch("exp.voteAlert", refreshVote)
    E.watch("exp.voteLeave", function(on)
        refreshVote()
        -- switched on in the middle of a vote that is already against you
        if on and Vote.me == "aimed" and canLeave() and os.clock() - Vote.lastAt < VOTE_WINDOW then
            toast("Leaving this server", "The votekick against you is still running.", "warn")
            leaveForVote()
        end
    end)

    E.onUnload(function()
        modOff()
        voteOff()
        Hop.attempt = nil
    end)
end

-- ==== en_16_exp_player.lua ====
-- en_16_exp_player: movement and gear experiments. No fall damage, safe
-- sprint, instant prompts, melee reach and auto spot.
--
-- Everything here ships off and installs nothing until it is first switched
-- on, so a player who never opens the Experiments page never gets the shared
-- remote hook, a render bind or a loop from this part. Each feature keeps one
-- short line in E.expPlayer.status so a hand test can read what happened.
do
    local Game, W = E.game, E.world
    local LP, RS = E.LP, E.RS
    local X = E.X
    local cfg = E.cfg

    local status = {
        noFallDamage   = "off",
        safeSprint     = "off",
        instantPrompts = "off",
        meleeReach     = "off",
        autoSpot       = "off",
    }
    E.expPlayer = { status = status }

    -- one recorded fault per label, so a failure that repeats every frame
    -- cannot churn E.faults
    local faulted = {}
    local function faultOnce(label, err)
        if faulted[label] then return end
        faulted[label] = true
        E.fault(label, err)
    end

    local clone = table.clone or function(t)
        local c = {}
        for k, v in pairs(t) do c[k] = v end
        return c
    end

    ------------------------------------------------------------------------
    -- No fall damage. The FallDamage LocalScript the game copies into every
    -- character measures the landing itself and reports it by firing
    -- ServerEvents.FallDMG. Nothing else tells the server about a fall, so a
    -- report that never leaves means no damage. The preferred route drops the
    -- call in the shared remote hook. Without a hook, the script is switched
    -- off on each spawn instead and switched back on when this turns off.
    ------------------------------------------------------------------------
    local fall = {
        route = nil,       -- nil until first enabled, then "hook" or "script"
        dropped = 0,
        scripts = {},      -- only the scripts we switched off
        watching = false,
    }

    local function scriptEnabled(s)
        local ok, v = pcall(function() return s.Enabled end)
        if ok and type(v) == "boolean" then return v end
        ok, v = pcall(function() return s.Disabled end)
        if ok and type(v) == "boolean" then return not v end
        return nil
    end

    -- Enabled on current engines, Disabled on older ones
    local function setScriptEnabled(s, on)
        if pcall(function() s.Enabled = on end) then return true end
        return (pcall(function() s.Disabled = not on end))
    end

    local function fallScriptStatus()
        status.noFallDamage = next(fall.scripts) and "on, the fall damage script is switched off"
            or "on, waiting for the fall damage script"
    end

    local function muteFallScript(char)
        if not char then return end
        local s = char:FindFirstChild("FallDamage")
        if not (s and s:IsA("BaseScript")) or fall.scripts[s] then return end
        -- a script the game already turned off is not ours to turn back on
        if scriptEnabled(s) ~= true then return end
        if setScriptEnabled(s, false) then fall.scripts[s] = true end
        fallScriptStatus()
    end

    local function unmuteFallScripts()
        for s in pairs(fall.scripts) do
            if s.Parent then setScriptEnabled(s, true) end
        end
        table.clear(fall.scripts)
    end

    local function watchSpawns()
        if fall.watching then return end
        fall.watching = true
        E.connect(LP.CharacterAdded, function(char)
            -- scripts from the last life are gone with their character
            for s in pairs(fall.scripts) do
                if not s.Parent then fall.scripts[s] = nil end
            end
            if not (cfg.exp.noFallDamage and fall.route == "script") then return end
            task.spawn(function()
                -- the script is copied in just after the character appears
                local ok, s = pcall(char.WaitForChild, char, "FallDamage", 10)
                if not (ok and s) then return end
                if E.alive and cfg.exp.noFallDamage and fall.route == "script" then
                    E.try("no fall damage", muteFallScript, char)
                end
            end)
        end)
    end

    local function setNoFall(on)
        if not on then
            unmuteFallScripts()
            status.noFallDamage = "off"
            return
        end
        if not E.inGame then status.noFallDamage = "only works in ENTRENCHED" return end
        if fall.route == nil then
            local hooked = E.remotes ~= nil and E.remotes.on("FallDMG", function()
                if not cfg.exp.noFallDamage then return nil end
                fall.dropped = fall.dropped + 1
                status.noFallDamage = "on, " .. fall.dropped .. " fall reports dropped"
                return "drop"
            end)
            fall.route = hooked and "hook" or "script"
            if not hooked and E.toast then
                E.toast("No fall damage", "This executor cannot filter remotes, so the fall damage script is switched off instead.", "info")
            end
        end
        if fall.route == "hook" then
            status.noFallDamage = "on, " .. fall.dropped .. " fall reports dropped"
        else
            watchSpawns()
            E.try("no fall damage", muteFallScript, LP.Character)
            fallScriptStatus()
        end
    end

    ------------------------------------------------------------------------
    -- Safe sprint. The client anti cheat checks WalkSpeed once on spawn and
    -- then every 4 seconds, and kicks above 23 on public servers or above
    -- DefaultWalkSpeed + 9 on any other kind. DefaultWalkSpeed is 12 or 14 by
    -- class and a legit sprint is DefaultWalkSpeed + 6, so the target is
    -- DefaultWalkSpeed + 8.5 capped at 22.5. That one formula clears both
    -- limits by at least half a stud, and every write is clamped again at the
    -- single place WalkSpeed is written.
    --
    -- The game changes WalkSpeed for sprinting, aiming, crouching and carrying.
    -- Its latest value is tracked by VALUE, like the FOV offset: anything the
    -- Humanoid holds that is not our own last write is the game's intent, and
    -- that value comes back as soon as you stop moving, crouch, sit, go down,
    -- die, switch this off or unload.
    ------------------------------------------------------------------------
    local SPEED_CEILING = 22.5
    local SPEED_HEADROOM = 8.5
    local SPRINT_BIND = "ENT_SAFESPRINT"

    local sprint = {
        hum = nil,          -- the Humanoid the fields below belong to
        intended = nil,     -- the game's own latest WalkSpeed
        ours = nil,         -- our last write while it still stands, else nil
        checkAt = 0,
        eligible = false,   -- slow checks: alive, not downed, not in the lobby
        target = nil,
        serverType = nil,
        serverTypeAt = -math.huge,
    }

    local function writeSpeed(hum, v)
        if type(v) ~= "number" or v ~= v then return nil end
        if v > SPEED_CEILING then v = SPEED_CEILING end
        if v < 0 then v = 0 end
        if not pcall(function() hum.WalkSpeed = v end) then return nil end
        return v
    end

    -- give the game its value back, but only if our write is still the one
    -- standing; if the game has written since, its value is already there
    local function releaseSpeed()
        local hum, ours, intended = sprint.hum, sprint.ours, sprint.intended
        sprint.ours = nil
        if not (hum and ours and intended) then return end
        local ok, cur = pcall(function() return hum.WalkSpeed end)
        if ok and type(cur) == "number" and math.abs(cur - ours) < 1e-3 then
            writeSpeed(hum, intended)
        end
    end

    local function serverType()
        local now = os.clock()
        if now - sprint.serverTypeAt < 10 then return sprint.serverType end
        sprint.serverTypeAt = now
        local ok, v = pcall(function()
            local pss = workspace:FindFirstChild("PrivateServerSettings")
            local st = pss and pss:FindFirstChild("ServerType")
            return st and st.Value
        end)
        sprint.serverType = (ok and type(v) == "string") and v or nil
        return sprint.serverType
    end

    local function sprintTarget(hum)
        local dws = hum:GetAttribute("DefaultWalkSpeed")
        if type(dws) ~= "number" or dws ~= dws or dws <= 0 then
            -- off a public server the limit hangs off this value, so never guess it there
            local st = serverType()
            if st ~= nil and st ~= "Public" then return nil end
            dws = 12
        end
        return math.min(SPEED_CEILING, dws + SPEED_HEADROOM)
    end

    local function sprintStep()
        local char = LP.Character
        local hum = sprint.hum
        if not (hum and char and hum.Parent == char) then
            hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum ~= sprint.hum then
                releaseSpeed()
                sprint.hum, sprint.intended, sprint.ours = hum, nil, nil
                sprint.checkAt = 0
            end
            if not hum then
                status.safeSprint = "on, waiting for your character"
                return
            end
        end

        local cur = hum.WalkSpeed
        if not (sprint.ours and math.abs(cur - sprint.ours) < 1e-3) then
            sprint.intended, sprint.ours = cur, nil
        end
        local intended = sprint.intended

        local now = os.clock()
        if now >= sprint.checkAt then
            sprint.checkAt = now + 0.25
            sprint.eligible = Game.isAlive(char) and not Game.isDowned(char) and not Game.inLobby(char)
            sprint.target = sprint.eligible and sprintTarget(hum) or nil
            if not sprint.eligible then
                status.safeSprint = "on, paused while you are down, dead or in the lobby"
            elseif not sprint.target then
                status.safeSprint = "on, paused because this server's speed limit is unknown"
            else
                status.safeSprint = string.format("on, %.1f while you move (the game's own is %.1f)",
                    sprint.target, intended)
            end
        end

        -- A zero means the game is holding you still, so never move you then.
        -- Cheapest checks first, since this runs every frame. Going down is
        -- checked every frame too: a quarter second of a 22.5 crawl would be
        -- plain to anyone watching.
        local target = sprint.target
        local boost = target ~= nil and intended > 0 and target > intended
            and hum.MoveDirection.Magnitude > 0.05
            and not hum.Sit and hum.SeatPart == nil
            and hum.Health > 0
            and hum:GetAttribute("Crouching") ~= true
            and char:FindFirstChild("ReviveTime") == nil

        if boost then
            if not sprint.ours or math.abs(sprint.ours - math.min(target, SPEED_CEILING)) > 1e-3 then
                sprint.ours = writeSpeed(hum, target)
            end
        elseif sprint.ours then
            writeSpeed(hum, intended)
            sprint.ours = nil
        end
    end

    local function setSafeSprint(on)
        if not on then
            E.unbind(SPRINT_BIND)
            releaseSpeed()
            sprint.hum, sprint.intended = nil, nil
            status.safeSprint = "off"
            return
        end
        if not E.inGame then status.safeSprint = "only works in ENTRENCHED" return end
        -- after the default character controls, so a WalkSpeed the game set
        -- this frame is already visible when it is read
        E.bind(SPRINT_BIND, Enum.RenderPriority.Character.Value + 5, function()
            local ok, err = pcall(sprintStep)
            if not ok then faultOnce("safe sprint", err) end
        end)
        status.safeSprint = "on"
    end

    ------------------------------------------------------------------------
    -- Instant prompts. The hold timer runs on your own client, so a prompt
    -- whose HoldDuration is zero finishes the moment you press. Prompts are
    -- zeroed as they are shown; one that was already on screen when this was
    -- switched on is zeroed when the hold starts, and if the executor can fire
    -- prompts and that hold still has not finished a moment later, it is fired
    -- directly. Originals are kept in a plain table and handed back as each
    -- prompt hides, so it only ever holds what is on screen. A weak table can
    -- lose the entry for a prompt that still exists, because the Lua handle of
    -- an Instance can be collected while nothing in Lua refers to it.
    ------------------------------------------------------------------------
    local prompts = {
        hooked = false,
        saved = {},        -- prompt -> the game's HoldDuration, only prompts we zeroed
        pending = {},      -- prompt -> token of the delayed direct fire
        fired = 0,
    }

    local function zeroPrompt(prompt)
        if typeof(prompt) ~= "Instance" or not prompt:IsA("ProximityPrompt") then return end
        local cur = prompt.HoldDuration
        if cur > 0 then
            -- any non zero value is the game's latest, even on a prompt we zeroed before
            prompts.saved[prompt] = cur
            prompt.HoldDuration = 0
        end
    end

    local function restorePrompt(prompt)
        local orig = prompts.saved[prompt]
        prompts.saved[prompt] = nil
        prompts.pending[prompt] = nil
        if orig and prompt.Parent and prompt.HoldDuration == 0 then
            prompt.HoldDuration = orig
        end
    end

    local function restoreAllPrompts()
        for prompt in pairs(prompts.saved) do pcall(restorePrompt, prompt) end
        table.clear(prompts.saved)
        table.clear(prompts.pending)
    end

    local function hookPrompts()
        if prompts.hooked then return true end
        local ok, PPS = pcall(game.GetService, game, "ProximityPromptService")
        if not (ok and PPS) then return false end
        prompts.hooked = true

        E.connect(PPS.PromptShown, function(prompt)
            if not cfg.exp.instantPrompts then return end
            E.try("instant prompts", zeroPrompt, prompt)
        end)

        E.connect(PPS.PromptHidden, function(prompt)
            if prompts.saved[prompt] ~= nil then pcall(restorePrompt, prompt) end
        end)

        E.connect(PPS.PromptButtonHoldBegan, function(prompt, player)
            if not cfg.exp.instantPrompts then return end
            if player ~= nil and player ~= LP then return end
            E.try("instant prompts", zeroPrompt, prompt)
            local fire = X.fireproximityprompt
            if not fire then return end
            -- a short wait so a hold that the zero already finished is not
            -- triggered a second time, which would undo a toggle style prompt
            local token = {}
            prompts.pending[prompt] = token
            task.delay(0.1, function()
                if prompts.pending[prompt] ~= token then return end
                prompts.pending[prompt] = nil
                if not (E.alive and cfg.exp.instantPrompts) then return end
                local okLive, live = pcall(function() return prompt.Parent ~= nil and prompt.Enabled end)
                if not (okLive and live) then return end
                local okFire, err = pcall(fire, prompt)
                if okFire then
                    prompts.fired = prompts.fired + 1
                    status.instantPrompts = "on, " .. prompts.fired .. " prompts fired directly"
                else
                    faultOnce("instant prompts fire", err)
                end
            end)
        end)

        E.connect(PPS.PromptTriggered, function(prompt)
            prompts.pending[prompt] = nil
        end)
        return true
    end

    local function setInstantPrompts(on)
        if not on then
            restoreAllPrompts()
            status.instantPrompts = "off"
            return
        end
        if not E.inGame then status.instantPrompts = "only works in ENTRENCHED" return end
        if not hookPrompts() then status.instantPrompts = "unavailable" return end
        status.instantPrompts = X.fireproximityprompt and "on, with direct firing as a backup" or "on"
    end

    ------------------------------------------------------------------------
    -- Melee reach. What ServerEvents.Melee carries has never been read, so
    -- this only edits values that plainly name who was hit: a body part of a
    -- character, a Humanoid, or a character Model. It looks at the top level
    -- arguments, inside a plain table, and inside a small record in that table
    -- (the shape Shoot uses for its hit list). Anything else passes through,
    -- and E.remotes.log.Melee keeps the last few calls so the real shape can be
    -- read after a test. A hit that already landed on a live enemy is kept.
    -- This runs inside the namecall hook: no yields, no remote calls, nothing
    -- that belongs to your own character is changed, and the game's own tables
    -- are copied before any edit, never changed in place.
    ------------------------------------------------------------------------
    local melee = { route = nil, changed = 0 }
    local VEC_SNAP = 8           -- a hit position this close to the struck part moves with it

    -- the character a value points at, and how it points at it
    local function resolve(v)
        if typeof(v) ~= "Instance" then return nil end
        if v:IsA("BasePart") then
            local m = v:FindFirstAncestorOfClass("Model")
            local hops = 0
            while m and not m:FindFirstChildOfClass("Humanoid") and hops < 4 do
                m = m:FindFirstAncestorOfClass("Model")
                hops = hops + 1
            end
            if m and m:FindFirstChildOfClass("Humanoid") then return m, "part" end
        elseif v:IsA("Humanoid") then
            local m = v.Parent
            if m and m.ClassName == "Model" then return m, "humanoid" end
        elseif v.ClassName == "Model" and v:FindFirstChildOfClass("Humanoid") then
            return v, "model"
        end
        return nil
    end

    local function plainTable(t, limit)
        if getmetatable(t) ~= nil then return false end
        -- the weapon state table travels by reference; never look inside it
        if rawget(t, "Tool") ~= nil or rawget(t, "animationList") ~= nil then return false end
        local n = 0
        for _ in pairs(t) do
            n = n + 1
            if n > limit then return false end
        end
        return true
    end

    -- run fn over every value the handler may see, copying any table it
    -- changes so the caller's original is left exactly as it was
    local function walk(v, depth, fn)
        if type(v) ~= "table" then return fn(v) end
        if depth >= 2 or not plainTable(v, depth == 0 and 32 or 8) then return v, false end
        local edits
        for k, item in pairs(v) do
            local nv, changed = walk(item, depth + 1, fn)
            if changed then
                edits = edits or {}
                edits[k] = nv
            end
        end
        if not edits then return v, false end
        local copy = clone(v)
        for k, nv in pairs(edits) do copy[k] = nv end
        return copy, true
    end

    local function enemyByChar(model)
        for _, e in ipairs(W.list) do
            if e.char == model then return e end
        end
        return nil
    end

    -- downed enemies count; the world list already leaves out teammates,
    -- the dead and anyone in the lobby
    local function nearestEnemy(origin, range)
        local best, bestD
        for _, e in ipairs(W.list) do
            local root, char, hum = e.root, e.char, e.hum
            if root and root.Parent and char and char.Parent and hum and hum.Parent then
                local d = (root.Position - origin).Magnitude
                if d <= range and (not bestD or d < bestD) then best, bestD = e, d end
            end
        end
        return best
    end

    local function meleeHandler(args)
        if not cfg.exp.meleeReach then return nil end
        local myChar = LP.Character
        local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
        if not myRoot then return nil end

        -- pass 1: the first value that names someone other than you
        local origModel, origPart
        local function find(v)
            if not origModel then
                local m, kind = resolve(v)
                if m and m ~= myChar then
                    origModel = m
                    if kind == "part" then origPart = v end
                end
            end
            return v, false
        end
        for i = 1, args.n do walk(args[i], 0, find) end
        if not origModel then
            status.meleeReach = "on, the last swing named no target"
            return nil
        end

        -- A swing that already hit a live enemy stays on them. The only edit
        -- then is moving it off a part outside the whitelist, such as the
        -- AENcD honeypot, onto the same enemy's root.
        local enemy = enemyByChar(origModel)
        local keepTarget = enemy ~= nil
        if not enemy then
            local range = math.clamp(tonumber(cfg.exp.meleeRange) or 12, 1, 30)
            enemy = nearestEnemy(myRoot.Position, range)
            if not enemy then
                status.meleeReach = "on, no enemy within " .. range .. " studs"
                return nil
            end
        end

        local function partFor(name)
            local p = Game.PARTS[name] and enemy.char:FindFirstChild(name)
            if p and p:IsA("BasePart") then return p end
            return enemy.root
        end

        local refPart = origPart or origModel:FindFirstChild("HumanoidRootPart")
        local refPos = (refPart and refPart:IsA("BasePart")) and refPart.Position or nil
        local anchor = origPart and partFor(origPart.Name) or enemy.root
        local myPos, camPos = myRoot.Position, W.camPos

        -- pass 2: swap only what points at the original target
        local function swap(v)
            local ty = typeof(v)
            if ty == "Instance" then
                local m, kind = resolve(v)
                if m ~= origModel then return v, false end
                if kind == "part" then
                    if keepTarget and Game.PARTS[v.Name] then return v, false end
                    local p = partFor(v.Name)
                    return p, p ~= v
                end
                if keepTarget then return v, false end
                if kind == "humanoid" then return enemy.hum, enemy.hum ~= v end
                return enemy.char, enemy.char ~= v
            elseif ty == "Vector3" and refPos and not keepTarget then
                -- A short vector is a direction or offset, not a place in the
                -- world. A position nearer you or the camera than the target
                -- is where the swing came from, and stays.
                if v.Magnitude < 1.5 then return v, false end
                local d = (v - refPos).Magnitude
                if d <= VEC_SNAP and d < (v - myPos).Magnitude
                    and (not camPos or d < (v - camPos).Magnitude) then
                    return anchor.Position, true
                end
            end
            return v, false
        end

        local changed = false
        for i = 1, args.n do
            local nv, ch = walk(args[i], 0, swap)
            if ch then
                args[i] = nv
                changed = true
            end
        end
        if not changed then return nil end
        melee.changed = melee.changed + 1
        if keepTarget then
            status.meleeReach = "on, kept a real hit off a hidden body part"
        else
            status.meleeReach = "on, " .. melee.changed .. " swings sent, last to " .. E.nameOf(enemy.player, "an enemy")
        end
        return true
    end

    local function setMeleeReach(on)
        if not on then status.meleeReach = "off" return end
        if not E.inGame then status.meleeReach = "only works in ENTRENCHED" return end
        if melee.route == nil then
            local hooked = E.remotes ~= nil and E.remotes.on("Melee", meleeHandler)
            melee.route = hooked and "hook" or "none"
        end
        status.meleeReach = melee.route == "hook" and "on, waiting for a swing"
            or "unavailable, this executor cannot filter remotes"
    end

    ------------------------------------------------------------------------
    -- Auto spot. ServerEvents.Spot:InvokeServer(state, aimPoint) is what the
    -- game's own spot key sends. The server works out who is at aimPoint by
    -- itself and answers "Cannot" while the cooldown runs. It needs a tool
    -- whose CanSpot attribute is true plus that tool's live state table. It is
    -- a RemoteFunction and yields, so it runs on its own thread, one call at a
    -- time, from a slow loop and never from a render step or a hook.
    ------------------------------------------------------------------------
    local SPOT_RANGE = 500       -- the game's own spot casts Crosshair's default 500 stud ray
    local spot = {
        started = false,
        busy = nil,              -- token of the call in flight
        busySince = 0,
        nextAt = 0,
        done = 0,
        remote = nil,
        tried = {},              -- player -> last attempt on them
        noState = {},            -- tool -> when its state lookup may be tried again
    }

    local function spotRemote()
        local r = spot.remote
        if r and r.Parent then return r end
        local se = RS:FindFirstChild("ServerEvents")
        r = se and se:FindFirstChild("Spot")
        spot.remote = (r and r:IsA("RemoteFunction")) and r or nil
        return spot.remote
    end

    -- Prefers the tool in your hands. A failed state lookup can fall back to a
    -- full getgc scan, so a tool that failed waits 15 seconds before the next
    -- try, and at most one lookup runs per pass.
    local function spotTool(char)
        local now = os.clock()
        for t, at in pairs(spot.noState) do
            if not t.Parent or now >= at then spot.noState[t] = nil end
        end
        local candidates = {}
        local held = char:FindFirstChildOfClass("Tool")
        if held then candidates[1] = held end
        local bp = LP:FindFirstChildOfClass("Backpack")
        if bp then
            for _, t in ipairs(bp:GetChildren()) do
                if t:IsA("Tool") then candidates[#candidates + 1] = t end
            end
        end
        local found = nil
        for _, t in ipairs(candidates) do
            if t:GetAttribute("CanSpot") == true then
                found = found or t
                if not spot.noState[t] then
                    local st = Game.stateOf(t)
                    if st then return t, st end
                    spot.noState[t] = now + 15
                    return t, nil
                end
            end
        end
        return found, nil
    end

    local function spotTarget()
        local now = os.clock()
        local best, bestPart, bestScore
        for _, e in ipairs(W.list) do
            if e.visible and not e.spotted and e.dist <= SPOT_RANGE
                and now - (spot.tried[e.player] or -math.huge) > 6 then
                local part = (e.visTorso and e.torso) or (e.visHead and e.head) or nil
                if part and part.Parent then
                    -- a downed enemy is only worth it when nobody standing is in sight
                    local score = e.angle + (e.downed and 1000 or 0)
                    if not bestScore or score < bestScore then
                        best, bestPart, bestScore = e, part, score
                    end
                end
            end
        end
        return best, bestPart
    end

    local function spotTick()
        if not cfg.exp.autoSpot then return 0.5 end
        local now = os.clock()
        if spot.busy then
            -- a reply that never arrives must not stop the feature for good
            if now - spot.busySince < 10 then return 0.25 end
            spot.busy = nil
            spot.nextAt = now + 4
        end
        if now < spot.nextAt then return math.max(0.1, spot.nextAt - now) end

        for p, at in pairs(spot.tried) do
            if now - at > 30 or not p.Parent then spot.tried[p] = nil end
        end

        local remote = spotRemote()
        if not remote then status.autoSpot = "unavailable, the spot remote was not found" return 5 end
        local char = LP.Character
        if not (char and Game.isAlive(char)) or Game.isDowned(char) or Game.inLobby(char) then
            status.autoSpot = "on, waiting until you are deployed"
            return 1
        end
        local tool, st = spotTool(char)
        if not tool then status.autoSpot = "on, none of your tools can spot" return 1.5 end
        if not st then status.autoSpot = "on, could not read the spotting tool's state" return 1.5 end
        local e, part = spotTarget()
        if not e then status.autoSpot = "on, no unspotted enemy in sight" return 0.5 end

        local token = {}
        spot.busy, spot.busySince = token, now
        spot.tried[e.player] = now
        local pos = part.Position
        local name = E.nameOf(e.player, "an enemy")
        task.spawn(function()
            local ok, res = pcall(function() return remote:InvokeServer(st, pos) end)
            if spot.busy ~= token or not E.alive then return end
            spot.busy = nil
            local t = os.clock()
            if not ok or res == "Cannot" or res == false then
                spot.nextAt = t + 4
                if not ok then faultOnce("auto spot", res) end
                if cfg.exp.autoSpot then
                    status.autoSpot = ok and "on, the game said not yet, trying again in 4s"
                        or "on, the spot call failed, trying again in 4s"
                end
            else
                spot.done = spot.done + 1
                spot.nextAt = t + 1.5
                if cfg.exp.autoSpot then
                    status.autoSpot = "on, spotted " .. name .. " (" .. spot.done .. " so far)"
                end
            end
        end)
        return 0.25
    end

    local function setAutoSpot(on)
        if not on then status.autoSpot = "off" return end
        if not E.inGame then status.autoSpot = "only works in ENTRENCHED" return end
        if not spot.started then
            spot.started = true
            E.loop("auto spot", spotTick)
        end
        status.autoSpot = "on"
    end

    ------------------------------------------------------------------------
    -- Settings. E.replay fires each of these once after load, so a saved
    -- setting takes effect the same way a click does.
    ------------------------------------------------------------------------
    E.watch("exp.noFallDamage", setNoFall)
    E.watch("exp.safeSprint", setSafeSprint)
    E.watch("exp.instantPrompts", setInstantPrompts)
    E.watch("exp.meleeReach", setMeleeReach)
    E.watch("exp.autoSpot", setAutoSpot)

    -- remote handlers are cleared by en_13 and binds by the boot maid; what
    -- is left is putting the game's own values back
    E.onUnload(function()
        E.unbind(SPRINT_BIND)
        pcall(releaseSpeed)
        pcall(restoreAllPrompts)
        pcall(unmuteFallScripts)
    end)
end

-- ==== en_20_ui_core.lua ====
-- en_20_ui_core: screens, the Alt gated pointer, window shell, tabs and pages.
--
-- Rules this file follows, each one learned from a shipped bug:
--  * Text never lives inside a CanvasGroup (it resamples and goes soft).
--  * Nothing inside a UIListLayout is scaled with UIScale (it shoves siblings).
--  * No full size click overlay over a container with nested buttons (under
--    ZIndexBehavior.Sibling it swallows every click below it).
--  * Wrapped text is measured with TextService, never TextBounds.
--  * Hover never uses MouseEnter or MouseLeave. One per frame hit test drives
--    every hover spring, and only while Left Alt is held, because the rest of
--    the time the cursor is locked to the centre of the screen and would light
--    up whatever sits under the crosshair.
do
    local T, Anim = E.T, E.Anim
    local UIS, LP = E.UIS, E.LP
    local cfg = E.cfg

    local UI = { altHeld = false, clickable = false, hoverables = {}, tabs = {}, pages = {} }
    E.ui = UI

    ------------------------------------------------------------------------
    -- Instance helper
    ------------------------------------------------------------------------
    function UI.new(class, props, parent)
        local inst = Instance.new(class)
        if props then
            for k, v in pairs(props) do
                if k ~= "Children" then inst[k] = v end
            end
        end
        if class == "Frame" or class == "ScrollingFrame" or class == "TextLabel"
            or class == "TextButton" or class == "ImageLabel" or class == "ImageButton" then
            if props == nil or props.BorderSizePixel == nil then inst.BorderSizePixel = 0 end
        end
        if parent then inst.Parent = parent end
        return inst
    end
    local new = UI.new

    function UI.corner(parent, r)
        return new("UICorner", { CornerRadius = UDim.new(0, r or T.radius.md) }, parent)
    end

    function UI.text(parent, text, role, props)
        local l = new("TextLabel", {
            BackgroundTransparency = 1,
            Text = text or "",
            TextColor3 = T.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            RichText = false,
        }, parent)
        T.applyType(l, role or "label")
        if props then for k, v in pairs(props) do l[k] = v end end
        return l
    end

    -- soft 9 sliced drop shadow, always a SIBLING placed behind its surface
    function UI.shadow(parent, surfaceSize, soft, zindex)
        local sprite = soft and E.sprite.shadow_soft or E.sprite.shadow
        if not sprite then return nil end
        local pad = soft and 46 or 24
        local canvas = soft and 140 or 96
        return new("ImageLabel", {
            Name = "Shadow",
            BackgroundTransparency = 1,
            Image = sprite,
            ImageColor3 = T.black,
            ImageTransparency = soft and 0.25 or 0.45,
            ScaleType = Enum.ScaleType.Slice,
            SliceCenter = Rect.new(pad + 14, pad + 14, canvas - pad - 14, canvas - pad - 14),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, soft and 10 or 5),
            Size = surfaceSize and UDim2.new(1, pad * 2, 1, pad * 2) or UDim2.new(1, pad * 2, 1, pad * 2),
            ZIndex = zindex or 0,
        }, parent)
    end

    -- top weighted inner highlight in place of a hairline stroke
    function UI.rim(parent, zindex, transparency)
        if not E.sprite.rim then return nil end
        return new("ImageLabel", {
            Name = "Rim",
            BackgroundTransparency = 1,
            Image = E.sprite.rim,
            ImageTransparency = transparency or 0.15,
            ScaleType = Enum.ScaleType.Slice,
            SliceCenter = Rect.new(14, 14, 50, 50),
            Size = UDim2.fromScale(1, 1),
            ZIndex = zindex or 50,
        }, parent)
    end

    function UI.icon(parent, name, size, color, props)
        local img = E.sprite[name]
        local l = new("ImageLabel", {
            BackgroundTransparency = 1,
            Image = img or "",
            ImageColor3 = color or T.dim,
            Size = UDim2.fromOffset(size, size),
            ScaleType = Enum.ScaleType.Fit,
        }, parent)
        if props then for k, v in pairs(props) do l[k] = v end end
        return l
    end

    ------------------------------------------------------------------------
    -- Screens
    ------------------------------------------------------------------------
    local function hostParent()
        local X = E.X
        if X.gethui then
            local ok, h = pcall(X.gethui)
            if ok and h then return h end
        end
        local ok, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok and cg then return cg end
        return LP:WaitForChild("PlayerGui")
    end

    function UI.screen(name, order)
        local g = new("ScreenGui", {
            Name = name,
            ResetOnSpawn = false,
            IgnoreGuiInset = true,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
            DisplayOrder = order,
        })
        g.Parent = hostParent()
        E.own(g)
        return g
    end

    UI.overlayScreen = UI.screen("ent_overlay", 90)    -- ESP, radar, rings
    UI.panelScreen   = UI.screen("ent_panel", 1000)
    UI.toastScreen   = UI.screen("ent_toasts", 1001)

    -- a map change or a game reset must never strand the hub without a screen
    for _, screen in ipairs({ UI.overlayScreen, UI.panelScreen, UI.toastScreen }) do
        E.connect(screen.AncestryChanged, function()
            if screen.Parent or not E.alive then return end
            task.defer(function()
                if E.alive and not screen.Parent then
                    pcall(function() screen.Parent = hostParent() end)
                end
            end)
        end)
    end

    ------------------------------------------------------------------------
    -- Left Alt and the cursor. The game locks the cursor in first person and
    -- while aiming; we only override that while Alt is held, and on release we
    -- stop writing so the game reclaims it next frame. Forcing a value back on
    -- release is what used to break shift lock.
    --
    -- The panel is clickable whenever the cursor is really free: the game has
    -- released it (third person, menus), or Alt is held. Only a LOCKED cursor
    -- is blocked, because a click under lock lands on whatever GUI sits at
    -- screen centre, so firing through the panel would flip its controls.
    ------------------------------------------------------------------------
    local iconSaved = nil
    local behaviourConn = nil
    local altListeners, clickListeners = {}, {}
    function UI.onAlt(fn) altListeners[#altListeners + 1] = fn end
    function UI.onClickable(fn) clickListeners[#clickListeners + 1] = fn end
    UI.clickable = false

    -- reapplied rather than trusted, so no path (minimise, a new map, a
    -- respawn) can leave a button stuck in the wrong state
    function UI.syncInteract()
        local on = UI.clickable
        for _, screen in ipairs({ UI.panelScreen, UI.toastScreen }) do
            if screen.Parent then
                for _, d in ipairs(screen:GetDescendants()) do
                    if d:IsA("GuiButton") and d.Interactable ~= on then d.Interactable = on end
                end
            end
        end
    end

    local function setClickable(on)
        if UI.clickable == on then return end
        UI.clickable = on
        UI.syncInteract()
        for _, fn in ipairs(clickListeners) do E.try("click listener", fn, on) end
    end

    -- the game's own cursor state; a lock that lasts a single frame (the game
    -- reclaiming it right after Alt is released) never counts as free
    local freeSince = nil
    local function gameCursorFree()
        if UI.altHeld then return false end        -- while held the value is ours
        if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
            freeSince = nil
            return false
        end
        freeSince = freeSince or os.clock()
        return os.clock() - freeSince >= 0.1
    end

    local function freeCursor()
        if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
            UIS.MouseBehavior = Enum.MouseBehavior.Default
        end
        if not UIS.MouseIconEnabled then UIS.MouseIconEnabled = true end
    end

    local wasFree = false
    local function setAlt(on)
        if UI.altHeld == on then return end
        if on then
            wasFree = gameCursorFree()
            UI.altHeld = true
            iconSaved = UIS.MouseIconEnabled
            E.bind("ENT_CURSOR", Enum.RenderPriority.Last.Value + 2, freeCursor)
            -- a script that locks the cursor after our bind has run is undone
            -- the moment it writes, not a frame later
            if behaviourConn then behaviourConn:Disconnect() end
            behaviourConn = UIS:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
                if UI.altHeld then freeCursor() end
            end)
            freeCursor()
        else
            UI.altHeld = false
            E.unbind("ENT_CURSOR")
            if behaviourConn then behaviourConn:Disconnect() behaviourConn = nil end
            if iconSaved ~= nil then
                pcall(function() UIS.MouseIconEnabled = iconSaved end)
                iconSaved = nil
            end
            -- a cursor that was free before Alt stays clickable with no flicker
            freeSince = wasFree and (os.clock() - 1) or nil
        end
        setClickable(on or gameCursorFree())
        for _, fn in ipairs(altListeners) do E.try("alt listener", fn, on) end
    end
    UI.setAlt = setAlt
    for _, screen in ipairs({ UI.panelScreen, UI.toastScreen }) do
        E.connect(screen.DescendantAdded, function(d)
            if d:IsA("GuiButton") then d.Interactable = UI.clickable end
        end)
    end
    E.loop("interact sync", function()
        UI.syncInteract()
        return 0.5
    end)

    function UI.live() return UI.clickable end

    local focused = true
    E.connect(UIS.InputBegan, function(input)
        if input.KeyCode == Enum.KeyCode.LeftAlt then
            focused = true
            setAlt(true)
        end
    end)
    E.connect(UIS.InputEnded, function(input)
        if input.KeyCode == Enum.KeyCode.LeftAlt then setAlt(false) end
    end)
    E.connect(UIS.WindowFocused, function() focused = true end)
    E.connect(UIS.WindowFocusReleased, function()
        focused = false
        setAlt(false)
    end)
    E.onUnload(function()
        setAlt(false)
        if behaviourConn then behaviourConn:Disconnect() behaviourConn = nil end
    end)

    -- Every frame: a release the game never reported (a loading screen, a
    -- focus change) turns Alt off, and clickable follows the real cursor.
    -- This only ever turns Alt OFF; turning it on still needs a key press.
    E.bind("ENT_ALTWATCH", Enum.RenderPriority.First.Value, function()
        if UI.altHeld and (not focused or not UIS:IsKeyDown(Enum.KeyCode.LeftAlt)) then
            setAlt(false)
        end
        setClickable(UI.altHeld or gameCursorFree())
    end)

    ------------------------------------------------------------------------
    -- Pointer: one hit test per frame for everything that reacts to hover
    ------------------------------------------------------------------------
    function UI.mouse()
        return UIS:GetMouseLocation()
    end

    local function inside(frame, m, pad)
        if not frame.Parent or not frame.Visible then return false end
        local p, s = frame.AbsolutePosition, frame.AbsoluteSize
        pad = pad or 0
        return m.X >= p.X - pad and m.X <= p.X + s.X + pad and m.Y >= p.Y - pad and m.Y <= p.Y + s.Y + pad
    end
    UI.inside = inside

    -- register(frame, { enter = fn, leave = fn, move = fn(m), pad = n, gate = fn })
    function UI.hoverable(frame, handlers)
        local h = { frame = frame, over = false, handlers = handlers }
        UI.hoverables[#UI.hoverables + 1] = h
        return h
    end

    local function visibleChain(f)
        local cur = f
        while cur and cur:IsA("GuiObject") do
            if not cur.Visible then return false end
            cur = cur.Parent
        end
        return true
    end

    E.bind("ENT_POINTER", Enum.RenderPriority.Input.Value + 1, function()
        local m = UI.mouse()
        local live = UI.clickable and UI.panelOpen
        local keep = {}
        for _, h in ipairs(UI.hoverables) do
            local f = h.frame
            if f.Parent then
                keep[#keep + 1] = h
                local gate = h.handlers.gate
                local over = live and visibleChain(f) and inside(f, m, h.handlers.pad)
                    and (not gate or gate())
                if over ~= h.over then
                    h.over = over
                    local fn = over and h.handlers.enter or h.handlers.leave
                    if fn then E.try("hover", fn) end
                end
                if over and h.handlers.move then E.try("hover move", h.handlers.move, m) end
            end
        end
        UI.hoverables = keep
    end)

    ------------------------------------------------------------------------
    -- Window
    ------------------------------------------------------------------------
    local WIN_W, WIN_H = 760, 520
    local SIDE_W, HEAD_H = 168, 56
    UI.WIN_W, UI.WIN_H, UI.SIDE_W, UI.HEAD_H = WIN_W, WIN_H, SIDE_W, HEAD_H

    local holder = new("Frame", {
        Name = "Holder",
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(WIN_W, WIN_H),
        AnchorPoint = Vector2.new(0, 0),
    }, UI.panelScreen)
    UI.holder = holder

    local scale = new("UIScale", { Scale = 1 }, holder)
    UI.scaleObj = scale

    local function viewportScale()
        local cam = workspace.CurrentCamera
        local vy = cam and cam.ViewportSize.Y or 1080
        return math.clamp(vy / 1080, 0.8, 1.4) * math.clamp(cfg.ui.scale, 0.7, 1.4)
    end
    function UI.rescale() Anim.to(scale, "Scale", viewportScale(), "panel") end
    scale.Scale = viewportScale()
    E.watch("ui.scale", UI.rescale)

    UI.shadow(holder, true, true, 0)

    local win = new("Frame", {
        Name = "Window",
        BackgroundColor3 = T.base,
        Size = UDim2.fromScale(1, 1),
        ZIndex = 1,
    }, holder)
    UI.corner(win, T.radius.lg)
    UI.window = win
    UI.rim(win, 60, 0.12)

    -- a quiet accent wash along the top edge gives the surface a light source
    local wash = new("Frame", {
        BackgroundColor3 = T.accent,
        BackgroundTransparency = 0.9,
        Size = UDim2.new(1, 0, 0, 140),
        ZIndex = 1,
    }, win)
    UI.corner(wash, T.radius.lg)
    new("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.2),
            NumberSequenceKeypoint.new(1, 1),
        }),
    }, wash)
    UI.wash = wash

    ------------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------------
    local header = new("Frame", {
        Name = "Header",
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, HEAD_H),
        ZIndex = 5,
    }, win)
    UI.header = header

    local mark = new("Frame", {
        BackgroundColor3 = T.accent,
        Size = UDim2.fromOffset(10, 10),
        Position = UDim2.fromOffset(22, HEAD_H / 2 - 5),
        Rotation = 45,
        ZIndex = 6,
    }, header)
    UI.corner(mark, 2)
    UI.mark = mark

    local title = UI.text(header, "ENTRENCHED", "title", {
        Position = UDim2.fromOffset(42, 0),
        Size = UDim2.new(0, 160, 1, 0),
        ZIndex = 6,
    })
    UI.title = title

    local titleW = T.measure("ENTRENCHED", "title").X
    local ver = new("Frame", {
        BackgroundColor3 = T.raised,
        Position = UDim2.fromOffset(42 + titleW + 10, HEAD_H / 2 - 10),
        Size = UDim2.fromOffset(40, 20),
        ZIndex = 6,
    }, header)
    UI.corner(ver, T.radius.pill)
    UI.text(ver, "v" .. string.match(E.version, "^(%d+%.%d+)"), "small", {
        Size = UDim2.fromScale(1, 1),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextColor3 = T.dim,
        ZIndex = 7,
    })

    -- header right: Alt hint, then window buttons
    local hint = UI.text(header, "Hold Alt to click", "small", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -96, 0.5, 0),
        Size = UDim2.fromOffset(160, 20),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextColor3 = T.mute,
        ZIndex = 6,
    })
    UI.hint = hint
    UI.onClickable(function(on)
        Anim.to(hint, "TextTransparency", on and 1 or 0, "fade")
    end)

    local function headerButton(iconName, x, onClick)
        local b = new("TextButton", {
            BackgroundColor3 = T.raised,
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, x, 0.5, 0),
            Size = UDim2.fromOffset(30, 30),
            ZIndex = 8,
        }, header)
        UI.corner(b, T.radius.sm)
        local ic = UI.icon(b, iconName, 14, T.dim, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            ZIndex = 9,
        })
        UI.hoverable(b, {
            enter = function()
                Anim.to(b, "BackgroundTransparency", 0, "hover")
                Anim.to(ic, "ImageColor3", T.text, "hover")
            end,
            leave = function()
                Anim.to(b, "BackgroundTransparency", 1, "hover")
                Anim.to(ic, "ImageColor3", T.dim, "hover")
            end,
        })
        b.Activated:Connect(function()
            if UI.clickable then E.try("header button", onClick) end
        end)
        return b
    end
    UI.headerButton = headerButton

    ------------------------------------------------------------------------
    -- Sidebar with a sliding hover plate and a settling selection bar
    ------------------------------------------------------------------------
    local side = new("Frame", {
        Name = "Sidebar",
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, HEAD_H),
        Size = UDim2.new(0, SIDE_W, 1, -HEAD_H),
        ZIndex = 5,
    }, win)
    UI.side = side

    local plate = new("Frame", {
        BackgroundColor3 = T.white,
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(SIDE_W - 24, 36),
        Position = UDim2.fromOffset(12, 8),
        ZIndex = 5,
    }, side)
    UI.corner(plate, T.radius.md)

    local selBar = new("Frame", {
        BackgroundColor3 = T.accent,
        Size = UDim2.fromOffset(3, 18),
        Position = UDim2.fromOffset(12, 17),
        ZIndex = 7,
    }, side)
    UI.corner(selBar, 2)
    UI.selBar = selBar

    local divider = new("Frame", {
        BackgroundColor3 = T.line,
        BackgroundTransparency = 0.35,
        Position = UDim2.new(0, SIDE_W, 0, HEAD_H + 12),
        Size = UDim2.new(0, 1, 1, -HEAD_H - 24),
        ZIndex = 5,
    }, win)

    local content = new("Frame", {
        Name = "Content",
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Position = UDim2.fromOffset(SIDE_W + 1, HEAD_H),
        Size = UDim2.new(1, -SIDE_W - 1, 1, -HEAD_H - 8),
        ZIndex = 5,
    }, win)
    UI.content = content

    local TAB_Y0, TAB_H, TAB_GAP = 10, 38, 4
    local plateVisible = false

    function UI.addTab(name, iconName)
        local index = #UI.tabs + 1
        local y = TAB_Y0 + (index - 1) * (TAB_H + TAB_GAP)
        local btn = new("TextButton", {
            Name = "Tab_" .. name,
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            Position = UDim2.fromOffset(12, y),
            Size = UDim2.fromOffset(SIDE_W - 24, TAB_H),
            ZIndex = 8,
        }, side)
        local ic = UI.icon(btn, iconName, 16, T.mute, {
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 16, 0.5, 0),
            ZIndex = 9,
        })
        local lbl = UI.text(btn, name, "label", {
            Position = UDim2.fromOffset(44, 0),
            Size = UDim2.new(1, -48, 1, 0),
            TextColor3 = T.dim,
            ZIndex = 9,
        })

        local page = new("ScrollingFrame", {
            Name = "Page_" .. name,
            BackgroundTransparency = 1,
            ScrollBarThickness = 3,
            ScrollBarImageColor3 = T.track,
            ScrollBarImageTransparency = 0.2,
            CanvasSize = UDim2.new(),
            ScrollingDirection = Enum.ScrollingDirection.Y,
            Size = UDim2.fromScale(1, 1),
            Visible = false,
            ZIndex = 6,
        }, content)
        local list = new("UIListLayout", {
            Padding = UDim.new(0, 12),
            SortOrder = Enum.SortOrder.LayoutOrder,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
        }, page)
        new("UIPadding", {
            PaddingTop = UDim.new(0, 12),
            PaddingBottom = UDim.new(0, 18),
            PaddingLeft = UDim.new(0, 16),
            PaddingRight = UDim.new(0, 16),
        }, page)
        -- canvas height from the layout's own measurement, never AutomaticSize
        local function fit()
            page.CanvasSize = UDim2.fromOffset(0, list.AbsoluteContentSize.Y / math.max(scale.Scale, 0.01) + 30)
        end
        list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)

        local tab = { name = name, index = index, button = btn, icon = ic, label = lbl, page = page, y = y }
        UI.tabs[index] = tab
        UI.pages[name] = page

        UI.hoverable(btn, {
            enter = function()
                if not plateVisible then
                    Anim.set(plate, "Position", UDim2.fromOffset(12, y))
                end
                plateVisible = true
                Anim.to(plate, "Position", UDim2.fromOffset(12, y), "hover")
                Anim.to(plate, "BackgroundTransparency", 0.955, "fade")
                if UI.current ~= tab then Anim.to(lbl, "TextColor3", T.text, "hover") end
            end,
            leave = function()
                if UI.current ~= tab then Anim.to(lbl, "TextColor3", T.dim, "hover") end
                task.defer(function()
                    local anyOver = false
                    for _, t in ipairs(UI.tabs) do
                        for _, h in ipairs(UI.hoverables) do
                            if h.frame == t.button and h.over then anyOver = true end
                        end
                    end
                    if not anyOver then
                        plateVisible = false
                        Anim.to(plate, "BackgroundTransparency", 1, "fade")
                    end
                end)
            end,
        })
        btn.Activated:Connect(function() if UI.clickable then UI.select(name) end end)
        return page
    end

    function UI.select(name, instant)
        local tab
        for _, t in ipairs(UI.tabs) do if t.name == name then tab = t end end
        if not tab then return end
        local prev = UI.current
        if prev == tab then return end
        UI.current = tab

        for _, t in ipairs(UI.tabs) do
            local on = t == tab
            Anim.to(t.label, "TextColor3", on and T.text or T.dim, "hover")
            Anim.to(t.icon, "ImageColor3", on and T.accent or T.mute, "hover")
        end
        local barPos = UDim2.fromOffset(12, tab.y + TAB_H / 2 - 9)
        if instant then Anim.set(selBar, "Position", barPos) else Anim.to(selBar, "Position", barPos, "select") end

        -- directional slide inside the clipped content area
        local dir = prev and (tab.index > prev.index and 1 or -1) or 0
        local page = tab.page
        page.Visible = true
        if instant or dir == 0 or cfg.ui.reduceMotion then
            Anim.set(page, "Position", UDim2.new())
            if prev then prev.page.Visible = false end
        else
            Anim.set(page, "Position", UDim2.fromOffset(0, 26 * dir))
            Anim.to(page, "Position", UDim2.new(), "page")
            local old = prev.page
            Anim.to(old, "Position", UDim2.fromOffset(0, -26 * dir), "page")
            task.delay(0.16, function()
                if UI.current ~= prev then old.Visible = false end
            end)
        end
        if cfg.ui.tab ~= name then E.set("ui.tab", name) end
        E.emit("tab", name)
    end

    ------------------------------------------------------------------------
    -- Dragging: header only, only while Alt is held, clamped to the screen
    ------------------------------------------------------------------------
    local drag
    header.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not UI.clickable then return end
        local m = UI.mouse()
        drag = { start = m, origin = holder.Position }
    end)
    E.connect(UIS.InputChanged, function(input)
        if not drag or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local m = UI.mouse()
        local d = m - drag.start
        local o = drag.origin
        Anim.to(holder, "Position", UDim2.new(o.X.Scale, o.X.Offset + d.X, o.Y.Scale, o.Y.Offset + d.Y), "follow")
    end)
    local function clampToScreen()
        local cam = workspace.CurrentCamera
        if not cam then return end
        local vp = cam.ViewportSize
        local s = holder.AbsoluteSize
        local p = holder.AbsolutePosition
        local x = math.clamp(p.X, 8 - s.X * 0.6, vp.X - s.X * 0.4)
        local y = math.clamp(p.Y, 8, vp.Y - 60)
        Anim.to(holder, "Position", UDim2.fromOffset(x, y), "panel")
        return x, y
    end
    E.connect(UIS.InputEnded, function(input)
        if drag and input.UserInputType == Enum.UserInputType.MouseButton1 then
            drag = nil
            task.delay(0.15, function()
                local x, y = clampToScreen()
                if x then
                    E.set("ui.x", math.floor(x))
                    E.set("ui.y", math.floor(y))
                end
            end)
        end
    end)
    UI.onClickable(function(on) if not on then drag = nil end end)
    function UI.cancelDrag() drag = nil end

    function UI.placeInitial()
        local cam = workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
        local x, y = cfg.ui.x, cfg.ui.y
        if x < 0 or y < 0 or x > vp.X - 80 or y > vp.Y - 60 then
            x = 48
            y = math.floor(vp.Y / 2 - (WIN_H * scale.Scale) / 2)
        end
        holder.Position = UDim2.fromOffset(x, y)
    end

    ------------------------------------------------------------------------
    -- Accent: every element that uses the accent registers here so a theme
    -- change repaints live
    ------------------------------------------------------------------------
    local accentUsers = {}
    function UI.accent(inst, prop, alpha)
        accentUsers[#accentUsers + 1] = { inst = inst, prop = prop }
        return T.accent
    end
    UI.accent(mark, "BackgroundColor3")
    UI.accent(selBar, "BackgroundColor3")
    UI.accent(wash, "BackgroundColor3")

    E.watch("ui.accent", function(name)
        T.accent = T.accentColor(name)
        local keep = {}
        for _, u in ipairs(accentUsers) do
            if u.inst.Parent then
                keep[#keep + 1] = u
                Anim.to(u.inst, u.prop, T.accent, "fade")
            end
        end
        accentUsers = keep
        if UI.current then
            for _, t in ipairs(UI.tabs) do
                Anim.to(t.icon, "ImageColor3", t == UI.current and T.accent or T.mute, "fade")
            end
        end
        E.emit("accent", T.accent)
    end)

    UI.panelOpen = true
end

-- ==== en_21_ui_controls.lua ====
-- en_21_ui_controls: cards, rows and every control, each bound to a config path.
-- A control never owns its value: it reads E.get, writes E.set and repaints from
-- E.watch, so the panel cannot drift from what the features are really using.
do
    local T, Anim, UI = E.T, E.Anim, E.ui
    local UIS = E.UIS
    local new, text = UI.new, UI.text

    local ROW_H = T.row
    local PAD_X = 16

    ------------------------------------------------------------------------
    -- Section card
    ------------------------------------------------------------------------
    local order = 0
    local function nextOrder() order = order + 1 return order end

    function UI.section(page, title, subtitle)
        local wrap = new("Frame", {
            Name = "Section_" .. title,
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 60),
            LayoutOrder = nextOrder(),
            ZIndex = 6,
        }, page)
        UI.shadow(wrap, true, false, 6)
        local card = new("Frame", {
            BackgroundColor3 = T.surface,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 7,
        }, wrap)
        UI.corner(card, T.radius.lg)
        UI.rim(card, 8, 0.55)

        local body = new("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 8,
        }, card)
        local list = new("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 0),
        }, body)
        new("UIPadding", {
            PaddingTop = UDim.new(0, 10),
            PaddingBottom = UDim.new(0, 8),
        }, body)

        local head = new("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, subtitle and 40 or 28),
            LayoutOrder = 0,
            ZIndex = 8,
        }, body)
        text(head, string.upper(title), "heading", {
            Position = UDim2.fromOffset(PAD_X, 0),
            Size = UDim2.new(1, -PAD_X * 2, 0, 20),
            TextColor3 = T.mute,
            ZIndex = 9,
        })
        if subtitle then
            text(head, subtitle, "body", {
                Position = UDim2.fromOffset(PAD_X, 18),
                Size = UDim2.new(1, -PAD_X * 2, 0, 18),
                TextColor3 = T.dim,
                ZIndex = 9,
            })
        end

        local function fit()
            local s = UI.scaleObj.Scale
            wrap.Size = UDim2.new(1, 0, 0, list.AbsoluteContentSize.Y / math.max(s, 0.01) + 18)
        end
        list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)

        local sec = { wrap = wrap, card = card, body = body, rows = 0 }
        function sec.addRow(height)
            sec.rows = sec.rows + 1
            return new("Frame", {
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, height),
                LayoutOrder = sec.rows,
                ZIndex = 8,
            }, body)
        end
        return sec
    end

    ------------------------------------------------------------------------
    -- Row: label on the left, optional wrapped description beneath it, and a
    -- quiet highlight that follows the pointer while Alt is held.
    ------------------------------------------------------------------------
    local CONTENT_W = UI.WIN_W - UI.SIDE_W - 1 - 32 - PAD_X * 2

    local function row(sec, label, desc, controlW, extraH)
        local descH = 0
        if desc then
            descH = T.measure(desc, "body", CONTENT_W - (controlW or 0) - 12).Y + 2
        end
        local h = math.max(ROW_H, 22 + descH + 10) + (extraH or 0)
        local r = sec.addRow(h)

        local hl = new("Frame", {
            BackgroundColor3 = T.white,
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(6, 1),
            Size = UDim2.new(1, -12, 1, -2),
            ZIndex = 8,
        }, r)
        UI.corner(hl, T.radius.md)

        local labelY = desc and 8 or 0
        local lbl = text(r, label, "label", {
            Position = UDim2.fromOffset(PAD_X, labelY),
            Size = UDim2.new(1, -PAD_X * 2 - (controlW or 0), 0, desc and 20 or ROW_H),
            ZIndex = 10,
        })
        local d
        if desc then
            d = text(r, desc, "body", {
                Position = UDim2.fromOffset(PAD_X, 28),
                Size = UDim2.new(1, -PAD_X * 2 - (controlW or 0) - 12, 0, descH),
                TextColor3 = T.dim,
                TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top,
                ZIndex = 10,
            })
        end

        UI.hoverable(r, {
            enter = function() Anim.to(hl, "BackgroundTransparency", 0.972, "hover") end,
            leave = function() Anim.to(hl, "BackgroundTransparency", 1, "hover") end,
        })
        return r, lbl, d, h
    end
    UI.row = row

    ------------------------------------------------------------------------
    -- Confirmation spark: eight short strokes burst from a point. Parented to
    -- the panel screen itself so it can leave the control's bounds.
    ------------------------------------------------------------------------
    function UI.spark(absPos, color)
        if E.cfg.ui.reduceMotion then return end
        local layer = new("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 200,
        }, UI.panelScreen)
        local lines = {}
        for i = 1, 8 do
            local a = math.rad((i - 1) * 45)
            local f = new("Frame", {
                BackgroundColor3 = color or T.accent,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Rotation = math.deg(a),
                Size = UDim2.fromOffset(9, 2),
                ZIndex = 201,
            }, layer)
            UI.corner(f, 1)
            lines[i] = { f = f, dx = math.cos(a), dy = math.sin(a) }
        end
        local v = Anim.value(0, { 0.42, 0 }, function(t)
            local len = 9 * (1 - t)
            local dist = 8 + 16 * t
            for _, l in ipairs(lines) do
                l.f.Size = UDim2.fromOffset(math.max(len, 0.5), 2)
                l.f.Position = UDim2.fromOffset(absPos.X + l.dx * (dist + len / 2), absPos.Y + l.dy * (dist + len / 2))
                l.f.BackgroundTransparency = t * t
            end
        end)
        v.to(1)
        task.delay(0.6, function() layer:Destroy() end)
    end

    ------------------------------------------------------------------------
    -- Toggle
    ------------------------------------------------------------------------
    function UI.toggle(sec, label, path, desc)
        local TW, TH = 40, 22
        local r = row(sec, label, desc, TW + 8)
        local btn = new("TextButton", {
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            Size = UDim2.fromScale(1, 1),
            ZIndex = 11,
        }, r)

        local trackHolder = new("Frame", {
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -PAD_X, 0, (desc and 10 or (ROW_H - TH) / 2)),
            Size = UDim2.fromOffset(TW, TH),
            ZIndex = 12,
        }, r)
        local glow
        if E.sprite.glow then
            glow = new("ImageLabel", {
                BackgroundTransparency = 1,
                Image = E.sprite.glow,
                ImageColor3 = T.accent,
                ImageTransparency = 1,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromOffset(TW + 34, TH + 30),
                ZIndex = 12,
            }, trackHolder)
            UI.accent(glow, "ImageColor3")
        end
        local track = new("Frame", {
            BackgroundColor3 = T.track,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 13,
        }, trackHolder)
        UI.corner(track, T.radius.pill)
        local knob = new("Frame", {
            BackgroundColor3 = T.white,
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 3, 0.5, 0),
            Size = UDim2.fromOffset(16, 16),
            ZIndex = 14,
        }, track)
        UI.corner(knob, T.radius.pill)

        local function paint(on, instant)
            local pos = on and UDim2.new(0, TW - 19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
            local col = on and T.accent or T.track
            local kc = on and T.base or T.dim
            if instant then
                Anim.set(knob, "Position", pos)
                Anim.set(track, "BackgroundColor3", col)
                Anim.set(knob, "BackgroundColor3", kc)
                if glow then Anim.set(glow, "ImageTransparency", on and 0.78 or 1) end
            else
                Anim.to(knob, "Position", pos, "toggle")
                Anim.to(track, "BackgroundColor3", col, "hover")
                Anim.to(knob, "BackgroundColor3", kc, "hover")
                if glow then Anim.to(glow, "ImageTransparency", on and 0.78 or 1, "fade") end
            end
        end
        paint(E.get(path) == true, true)

        E.watch(path, function(v) paint(v == true) end)
        E.on("accent", function()
            if E.get(path) == true then Anim.to(track, "BackgroundColor3", T.accent, "fade") end
        end)

        btn.Activated:Connect(function()
            if not UI.clickable then return end
            local nv = not (E.get(path) == true)
            E.set(path, nv)
            if nv then
                local p, s = trackHolder.AbsolutePosition, trackHolder.AbsoluteSize
                UI.spark(Vector2.new(p.X + s.X - 11, p.Y + s.Y / 2))
            end
        end)
        UI.hoverable(r, {
            enter = function() Anim.to(knob, "Size", UDim2.fromOffset(18, 18), "hover") end,
            leave = function() Anim.to(knob, "Size", UDim2.fromOffset(16, 16), "hover") end,
        })
        return r
    end

    ------------------------------------------------------------------------
    -- Slider with an elastic overflow when dragged past either end
    ------------------------------------------------------------------------
    local function fmtValue(v, step, suffix)
        local dec = 0
        if step < 1 then dec = math.max(0, math.ceil(-math.log10(step) - 1e-9)) end
        return string.format("%." .. dec .. "f", v) .. (suffix or "")
    end

    function UI.slider(sec, label, path, min, max, step, suffix, desc)
        step = step or 1
        local r, _, _, h = row(sec, label, desc, 0, 18)
        local valW = 64
        local val = text(r, "", "value", {
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -PAD_X, 0, desc and 8 or 0),
            Size = UDim2.fromOffset(valW, desc and 20 or ROW_H),
            TextXAlignment = Enum.TextXAlignment.Right,
            TextColor3 = T.dim,
            ZIndex = 10,
        })

        local trackY = h - 16
        local zone = new("TextButton", {
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            Position = UDim2.fromOffset(PAD_X - 6, trackY - 12),
            Size = UDim2.new(1, -PAD_X * 2 + 12, 0, 24),
            ZIndex = 11,
        }, r)
        local holder = new("Frame", {
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(PAD_X, trackY),
            Size = UDim2.new(1, -PAD_X * 2, 0, 0),
            ZIndex = 12,
        }, r)
        local track = new("Frame", {
            BackgroundColor3 = T.track,
            AnchorPoint = Vector2.new(0, 0.5),
            Size = UDim2.new(1, 0, 0, 4),
            ZIndex = 12,
        }, holder)
        UI.corner(track, T.radius.pill)
        local fill = new("Frame", {
            BackgroundColor3 = T.accent,
            Size = UDim2.fromScale(0, 1),
            ZIndex = 13,
        }, track)
        UI.corner(fill, T.radius.pill)
        UI.accent(fill, "BackgroundColor3")
        local knob = new("Frame", {
            BackgroundColor3 = T.white,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0, 0.5),
            Size = UDim2.fromOffset(12, 12),
            ZIndex = 14,
        }, track)
        UI.corner(knob, T.radius.pill)

        local function frac(v) return max > min and math.clamp((v - min) / (max - min), 0, 1) or 0 end
        local function paint(v, instant)
            local f = frac(v)
            val.Text = fmtValue(v, step, suffix)
            if instant then
                Anim.set(fill, "Size", UDim2.fromScale(f, 1))
                Anim.set(knob, "Position", UDim2.fromScale(f, 0.5))
            else
                Anim.to(fill, "Size", UDim2.fromScale(f, 1), "follow")
                Anim.to(knob, "Position", UDim2.fromScale(f, 0.5), "follow")
            end
        end
        paint(E.get(path), true)
        E.watch(path, function(v) paint(v) end)

        local dragging = false
        local stretch = Anim.value(0, "release", function(o)
            -- positive stretches right, negative stretches left, anchored at the far end
            local w = math.abs(o)
            local sq = 4 - math.min(w / 40, 1) * 1.2
            if o >= 0 then
                track.Position = UDim2.new(0, 0, 0, 0)
                track.Size = UDim2.new(1, w, 0, sq)
            else
                track.Position = UDim2.new(0, -w, 0, 0)
                track.Size = UDim2.new(1, w, 0, sq)
            end
        end)

        local function apply(mx)
            local p, s = holder.AbsolutePosition.X, holder.AbsoluteSize.X
            if s <= 1 then return end
            local sc = UI.scaleObj.Scale
            local over = 0
            if mx < p then over = -(p - mx) / sc elseif mx > p + s then over = (mx - p - s) / sc end
            -- soft cap so a long pull resists rather than tearing
            local soft = 2 * (1 / (1 + math.exp(-over / 40)) - 0.5) * 26
            stretch.snap(soft)
            local f = math.clamp((mx - p) / s, 0, 1)
            local v = min + (max - min) * f
            v = math.floor(v / step + 0.5) * step
            v = math.clamp(v, min, max)
            if step < 1 then
                local m = 1 / step
                v = math.floor(v * m + 0.5) / m
            end
            E.set(path, v)
        end

        zone.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not UI.clickable then return end
            dragging = true
            Anim.to(knob, "Size", UDim2.fromOffset(16, 16), "toggle")
            apply(UI.mouse().X)
        end)
        E.connect(UIS.InputChanged, function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                apply(UI.mouse().X)
            end
        end)
        local function release()
            if not dragging then return end
            dragging = false
            stretch.to(0, "release")
            Anim.to(knob, "Size", UDim2.fromOffset(12, 12), "toggle")
        end
        E.connect(UIS.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then release() end
        end)
        UI.onClickable(function(on) if not on then release() end end)

        UI.hoverable(r, {
            enter = function() Anim.to(val, "TextColor3", T.text, "hover") end,
            leave = function() Anim.to(val, "TextColor3", T.dim, "hover") end,
        })
        return r
    end

    ------------------------------------------------------------------------
    -- Segmented choice with a sliding selection plate
    ------------------------------------------------------------------------
    function UI.segmented(sec, label, path, options, desc)
        local pad, gap = 12, 2
        local widths, total = {}, 0
        for i, o in ipairs(options) do
            widths[i] = math.ceil(T.measure(o, "small").X) + pad * 2
            total = total + widths[i] + (i > 1 and gap or 0)
        end
        local W = total + 6
        local r = row(sec, label, desc, W + 8)
        local box = new("Frame", {
            BackgroundColor3 = T.raised,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -PAD_X, 0, desc and 8 or (ROW_H - 26) / 2),
            Size = UDim2.fromOffset(W, 26),
            ZIndex = 11,
        }, r)
        UI.corner(box, T.radius.pill)
        local plate = new("Frame", {
            BackgroundColor3 = T.accent,
            Position = UDim2.fromOffset(3, 3),
            Size = UDim2.fromOffset(widths[1], 20),
            ZIndex = 12,
        }, box)
        UI.corner(plate, T.radius.pill)
        UI.accent(plate, "BackgroundColor3")

        local xs, labels = {}, {}
        local x = 3
        for i, o in ipairs(options) do
            xs[i] = x
            local b = new("TextButton", {
                BackgroundTransparency = 1,
                AutoButtonColor = false,
                Text = "",
                Position = UDim2.fromOffset(x, 3),
                Size = UDim2.fromOffset(widths[i], 20),
                ZIndex = 14,
            }, box)
            labels[i] = text(b, o, "small", {
                Size = UDim2.fromScale(1, 1),
                TextXAlignment = Enum.TextXAlignment.Center,
                TextColor3 = T.dim,
                ZIndex = 15,
            })
            b.Activated:Connect(function() if UI.clickable then E.set(path, o) end end)
            x = x + widths[i] + gap
        end

        local function paint(v, instant)
            local idx = 1
            for i, o in ipairs(options) do if o == v then idx = i end end
            local pos, size = UDim2.fromOffset(xs[idx], 3), UDim2.fromOffset(widths[idx], 20)
            if instant then
                Anim.set(plate, "Position", pos)
                Anim.set(plate, "Size", size)
            else
                Anim.to(plate, "Position", pos, "select")
                Anim.to(plate, "Size", size, "select")
            end
            for i, l in ipairs(labels) do
                local c = i == idx and T.base or T.dim
                if instant then Anim.set(l, "TextColor3", c) else Anim.to(l, "TextColor3", c, "hover") end
            end
        end
        paint(E.get(path), true)
        E.watch(path, function(v) paint(v) end)
        return r
    end

    ------------------------------------------------------------------------
    -- Accent swatches
    ------------------------------------------------------------------------
    function UI.swatches(sec, label, path, list, desc)
        local D, gap = 20, 10
        local W = #list * D + (#list - 1) * gap
        local r = row(sec, label, desc, W + 8)
        local box = new("Frame", {
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -PAD_X, 0, desc and 8 or (ROW_H - D) / 2),
            Size = UDim2.fromOffset(W, D),
            ZIndex = 11,
        }, r)
        local ring = new("Frame", {
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(D + 8, D + 8),
            ZIndex = 12,
        }, box)
        UI.corner(ring, T.radius.pill)
        local stroke = new("UIStroke", { Color = T.text, Thickness = 1.5, Transparency = 0.1 }, ring)
        local centers = {}
        for i, item in ipairs(list) do
            local cx = (i - 1) * (D + gap) + D / 2
            centers[item.name] = cx
            local b = new("TextButton", {
                BackgroundColor3 = item.color,
                AutoButtonColor = false,
                Text = "",
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromOffset(cx, D / 2),
                Size = UDim2.fromOffset(D, D),
                ZIndex = 13,
            }, box)
            UI.corner(b, T.radius.pill)
            b.Activated:Connect(function() if UI.clickable then E.set(path, item.name) end end)
        end
        local function paint(v, instant)
            local cx = centers[v] or D / 2
            local pos = UDim2.fromOffset(cx, D / 2)
            if instant then Anim.set(ring, "Position", pos) else Anim.to(ring, "Position", pos, "select") end
        end
        paint(E.get(path), true)
        E.watch(path, function(v) paint(v) end)
        return r
    end

    ------------------------------------------------------------------------
    -- Keybind capture
    ------------------------------------------------------------------------
    local capturing = nil
    function UI.keybind(sec, label, path, desc)
        local W = 96
        local r = row(sec, label, desc, W + 8)
        local b = new("TextButton", {
            BackgroundColor3 = T.raised,
            AutoButtonColor = false,
            Text = "",
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -PAD_X, 0, desc and 8 or (ROW_H - 26) / 2),
            Size = UDim2.fromOffset(W, 26),
            ZIndex = 11,
        }, r)
        UI.corner(b, T.radius.sm)
        local l = text(b, "", "small", {
            Size = UDim2.fromScale(1, 1),
            TextXAlignment = Enum.TextXAlignment.Center,
            TextColor3 = T.text,
            ZIndex = 12,
        })
        local function show(v)
            if capturing == path then
                l.Text = "Press a key"
                Anim.to(l, "TextColor3", T.accent, "hover")
            else
                l.Text = (v == "None" or v == "") and "Not set" or v
                Anim.to(l, "TextColor3", (v == "None" or v == "") and T.mute or T.text, "hover")
            end
        end
        show(E.get(path))
        E.watch(path, show)

        b.Activated:Connect(function()
            if not UI.clickable then return end
            capturing = path
            show(E.get(path))
        end)
        E.connect(UIS.InputBegan, function(input, gpe)
            if capturing ~= path then return end
            if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
            local k = input.KeyCode
            if k == Enum.KeyCode.LeftAlt then return end
            capturing = nil
            if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace then
                E.set(path, "None")
            else
                E.set(path, k.Name)
            end
            show(E.get(path))
        end)
        UI.hoverable(r, {
            enter = function() Anim.to(b, "BackgroundColor3", T.track, "hover") end,
            leave = function() Anim.to(b, "BackgroundColor3", T.raised, "hover") end,
        })
        return r
    end

    ------------------------------------------------------------------------
    -- Button
    ------------------------------------------------------------------------
    function UI.button(sec, label, caption, onClick, desc, danger)
        local W = math.ceil(T.measure(caption, "small").X) + 32
        local r = row(sec, label, desc, W + 8)
        local holder = new("Frame", {
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -PAD_X, 0, desc and 8 or (ROW_H - 28) / 2),
            Size = UDim2.fromOffset(W, 28),
            ZIndex = 11,
        }, r)
        local face = new("TextButton", {
            BackgroundColor3 = danger and T.bad or T.raised,
            BackgroundTransparency = danger and 0.8 or 0,
            AutoButtonColor = false,
            Text = "",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(1, 1),
            ZIndex = 12,
        }, holder)
        UI.corner(face, T.radius.sm)
        local l = text(face, caption, "small", {
            Size = UDim2.fromScale(1, 1),
            TextXAlignment = Enum.TextXAlignment.Center,
            TextColor3 = danger and T.bad or T.text,
            ZIndex = 13,
        })
        face.Activated:Connect(function()
            if not UI.clickable then return end
            -- press dip on the inner face, never UIScale inside a list
            Anim.set(face, "Size", UDim2.new(1, -4, 1, -3))
            Anim.to(face, "Size", UDim2.fromScale(1, 1), "toggle")
            E.try("button " .. label, onClick)
        end)
        UI.hoverable(r, {
            enter = function()
                Anim.to(face, "BackgroundColor3", danger and T.bad or T.track, "hover")
                Anim.to(face, "BackgroundTransparency", danger and 0.7 or 0, "hover")
            end,
            leave = function()
                Anim.to(face, "BackgroundColor3", danger and T.bad or T.raised, "hover")
                Anim.to(face, "BackgroundTransparency", danger and 0.8 or 0, "hover")
            end,
        })
        return r, l
    end

    ------------------------------------------------------------------------
    -- Note: a wrapped line of help text
    ------------------------------------------------------------------------
    function UI.note(sec, str)
        local h = T.measure(str, "body", CONTENT_W).Y + 10
        local r = sec.addRow(h)
        text(r, str, "body", {
            Position = UDim2.fromOffset(PAD_X, 2),
            Size = UDim2.new(1, -PAD_X * 2, 0, h - 6),
            TextColor3 = T.mute,
            TextWrapped = true,
            TextYAlignment = Enum.TextYAlignment.Top,
            ZIndex = 10,
        })
        return r
    end

    ------------------------------------------------------------------------
    -- Rolling digits: each place is a wheel that only turns while the places
    -- below it wrap, so 39 to 40 rolls the tens once instead of spinning.
    ------------------------------------------------------------------------
    function UI.counter(parent, role, color, decimals, suffix)
        role = role or "digits"
        decimals = decimals or 0
        local digitW = 0
        for d = 0, 9 do digitW = math.max(digitW, math.ceil(T.measure(tostring(d), role).X)) end
        local lineH = math.ceil(T.measure("0", role).Y)
        local box = new("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.fromOffset(digitW, lineH),
            ZIndex = parent.ZIndex + 1,
        }, parent)
        local cells = {}
        local suffixLbl
        if suffix then
            suffixLbl = text(box, suffix, role == "digits" and "label" or "small", {
                TextColor3 = T.dim,
                AnchorPoint = Vector2.new(0, 1),
                Size = UDim2.fromOffset(40, lineH),
                ZIndex = parent.ZIndex + 2,
            })
        end
        local function cell(i)
            local c = cells[i]
            if c then return c end
            local clip = new("Frame", {
                BackgroundTransparency = 1,
                ClipsDescendants = true,
                Size = UDim2.fromOffset(digitW, lineH),
                ZIndex = parent.ZIndex + 1,
            }, box)
            local a = text(clip, "0", role, {
                Size = UDim2.fromOffset(digitW, lineH),
                TextXAlignment = Enum.TextXAlignment.Center,
                TextColor3 = color or T.text,
                ZIndex = parent.ZIndex + 2,
            })
            local b = a:Clone()
            b.Parent = clip
            c = { clip = clip, a = a, b = b }
            cells[i] = c
            return c
        end

        local scaleMul = 10 ^ decimals
        local function draw(v)
            local n = math.max(0, v * scaleMul)
            local digits = math.max(#tostring(math.floor(n + 1e-6)), decimals + 1)
            local totalW = digits * digitW + (decimals > 0 and math.floor(digitW * 0.45) or 0)
            box.Size = UDim2.fromOffset(totalW + (suffixLbl and 4 or 0), lineH)
            for i = 1, math.max(digits, #cells) do
                local c = cell(i)
                if i > digits then
                    c.clip.Visible = false
                else
                    c.clip.Visible = true
                    local place = 10 ^ (digits - i)
                    local base = math.floor(n / place) % 10
                    local roll
                    if place == 1 then
                        roll = n % 1
                    else
                        roll = math.max(0, (n % place) - (place - 1))
                    end
                    local x = (i - 1) * digitW
                    if decimals > 0 and i > digits - decimals then x = x + math.floor(digitW * 0.45) end
                    c.clip.Position = UDim2.fromOffset(x, 0)
                    c.a.Text = tostring(base)
                    c.b.Text = tostring((base + 1) % 10)
                    c.a.Position = UDim2.fromOffset(0, -roll * lineH)
                    c.b.Position = UDim2.fromOffset(0, (1 - roll) * lineH)
                    c.a.TextTransparency = roll * 0.9
                    c.b.TextTransparency = (1 - roll) * 0.9
                end
            end
            if suffixLbl then suffixLbl.Position = UDim2.new(0, totalW + 3, 1, 0) end
        end
        local spring = Anim.value(0, "digits", draw)
        draw(0)
        local api = { box = box, lineH = lineH }
        function api.set(v, instant)
            if instant then spring.snap(v) else spring.to(v, "digits") end
        end
        function api.setColor(c)
            for _, cc in pairs(cells) do cc.a.TextColor3 = c cc.b.TextColor3 = c end
        end
        return api
    end
end

-- ==== en_22_toast.lua ====
-- en_22_toast: notification deck on the right edge and the kill feed that feeds it.
--
-- Rules this file keeps:
--  * Cards are positioned by hand, never inside a UIListLayout, so moving them
--    is safe. The vertical slot lives on the holder and the horizontal slide on
--    an inner frame, so a restack and an entrance never fight over one spring.
--  * Fades animate each element's own transparency. No CanvasGroup anywhere.
--  * Heights come from TextService through E.T.measure, never TextBounds.
--  * The toast screen has no UIScale, so every offset here is a real pixel.
--  * Hover and click only respond while Alt is held (E.ui.hoverable gates it).
do
    local T, Anim, UI = E.T, E.Anim, E.ui
    local new, text = UI.new, UI.text
    local cfg = E.cfg

    local CARD_W     = 272
    local EDGE       = 24       -- in from the right edge
    local TOP        = 72
    local GAP        = 8
    local MAX        = 4
    local LIFE       = 4
    local SLIDE      = 40
    local RADIUS     = 10
    local PAD_Y      = 11
    local STRIP_X    = 8
    local STRIP_W    = 3
    local TEXT_X     = 24
    local TEXT_W     = CARD_W - TEXT_X - 16
    local LINE_GAP   = 2
    local MIN_H      = 40
    local CARD_REST  = 0.04     -- card BackgroundTransparency when shown
    local GONE_AFTER = 0.5      -- seconds from dismissal to Destroy

    local KINDS = { kill = true, head = true, info = true, warn = true }

    -- how bright the light behind the strip settles; info stays unlit
    local GLOW_REST = { kill = 0.74, head = 0.76, warn = 0.8 }

    local function kindColor(kind)
        if kind == "kill" then return T.accent end
        if kind == "head" then return T.warn end
        if kind == "warn" then return T.bad end
        return T.dim
    end

    local live = {}       -- shown and counting down, newest first
    local leaving = {}    -- sliding out, destroyed once their time is up

    local deck = new("Frame", {
        Name = "Toasts",
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        ZIndex = 1,
    }, UI.toastScreen)

    ------------------------------------------------------------------------
    -- Layout
    ------------------------------------------------------------------------
    local function topY()
        local r = cfg.radar
        if r and r.enabled then return TOP + (tonumber(r.size) or 0) + 16 end
        return TOP
    end

    local function slotPos(y)
        return UDim2.new(1, -EDGE, 0, y)
    end

    -- newest on top, each older card one card height plus the gap below it
    local function restack(token)
        local y = topY()
        for _, t in ipairs(live) do
            local pos = slotPos(y)
            if t.placed then
                Anim.to(t.holder, "Position", pos, token or "select")
            else
                Anim.set(t.holder, "Position", pos)
                t.placed = true
            end
            y = y + t.h + GAP
        end
    end

    local function fadeTo(t, shown, token)
        Anim.to(t.card, "BackgroundTransparency", shown and CARD_REST or 1, token)
        Anim.to(t.strip, "BackgroundTransparency", shown and 0 or 1, token)
        Anim.to(t.title, "TextTransparency", shown and 0 or 1, token)
        if t.body then Anim.to(t.body, "TextTransparency", shown and 0 or 1, token) end
        if t.shadow then Anim.to(t.shadow, "ImageTransparency", shown and t.shadowRest or 1, token) end
        if t.glow and not shown then Anim.to(t.glow, "ImageTransparency", 1, token) end
    end

    local function dismiss(t)
        if t.leaving then return end
        t.leaving = true
        t.goneAt = os.clock() + GONE_AFTER
        local i = table.find(live, t)
        if i then table.remove(live, i) end
        leaving[#leaving + 1] = t
        t.holder.ZIndex = 5
        Anim.to(t.slider, "Position", UDim2.fromOffset(SLIDE, 0), "toast")
        fadeTo(t, false, "fade")
        restack("select")
    end

    -- the same message again while it is still up: refresh it with a soft
    -- flash of light instead of stacking a copy
    local function pulse(t)
        t.age = 0
        Anim.set(t.card, "BackgroundColor3", T.track)
        Anim.to(t.card, "BackgroundColor3", t.hover and T.raised or T.surface, "light")
        if t.glow then
            Anim.set(t.glow, "ImageTransparency", 0.4)
            Anim.to(t.glow, "ImageTransparency", t.glowRest, "light")
        end
    end

    ------------------------------------------------------------------------
    -- Card
    ------------------------------------------------------------------------
    local function build(req)
        local kind = req.kind
        local titleH = math.max(math.ceil(T.measure(req.title, "label", TEXT_W).Y), 14)
        local bodyH = 0
        if req.body then
            bodyH = math.max(math.ceil(T.measure(req.body, "body", TEXT_W).Y), 12)
        end
        local blockH = titleH + (req.body and (LINE_GAP + bodyH) or 0)
        local h = math.max(PAD_Y * 2 + blockH, MIN_H)
        local y0 = math.floor((h - blockH) / 2)
        local color = kindColor(kind)

        local holder = new("Frame", {
            Name = "Toast",
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = slotPos(topY()),
            Size = UDim2.fromOffset(CARD_W, h),
            ZIndex = 10,
        }, deck)

        local slider = new("Frame", {
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(SLIDE, 0),
            Size = UDim2.fromScale(1, 1),
            ZIndex = 1,
        }, holder)

        -- shadow is a sibling of the card inside the transparent slider
        local shadow = UI.shadow(slider, true, false, 1)
        local shadowRest = 0.45
        if shadow then
            shadowRest = shadow.ImageTransparency
            shadow.ImageTransparency = 1
        end

        local card = new("Frame", {
            Name = "Card",
            BackgroundColor3 = T.surface,
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 2,
        }, slider)
        UI.corner(card, RADIUS)

        local glowRest = GLOW_REST[kind]
        local glow
        if glowRest and E.sprite.glow then
            glow = new("ImageLabel", {
                BackgroundTransparency = 1,
                Image = E.sprite.glow,
                ImageColor3 = color,
                ImageTransparency = 0.4,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromOffset(STRIP_X + STRIP_W / 2, h / 2),
                Size = UDim2.fromOffset(STRIP_W + 30, h - 20 + 30),
                ZIndex = 1,
            }, card)
        end

        local strip = new("Frame", {
            BackgroundColor3 = color,
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(STRIP_X, 10),
            Size = UDim2.fromOffset(STRIP_W, h - 20),
            ZIndex = 2,
        }, card)
        UI.corner(strip, 2)

        local titleLbl = text(card, req.title, "label", {
            Position = UDim2.fromOffset(TEXT_X, y0),
            Size = UDim2.fromOffset(TEXT_W, titleH),
            TextColor3 = T.text,
            TextWrapped = true,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextTransparency = 1,
            ZIndex = 3,
        })

        local bodyLbl
        if req.body then
            bodyLbl = text(card, req.body, "body", {
                Position = UDim2.fromOffset(TEXT_X, y0 + titleH + LINE_GAP),
                Size = UDim2.fromOffset(TEXT_W, bodyH),
                TextColor3 = T.dim,
                TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top,
                TextTransparency = 1,
                ZIndex = 3,
            })
        end

        local t = {
            kind = kind, titleText = req.title, bodyText = req.body,
            holder = holder, slider = slider, card = card, strip = strip,
            title = titleLbl, body = bodyLbl, shadow = shadow, shadowRest = shadowRest,
            glow = glow, glowRest = glowRest,
            h = h, age = 0, hover = false, placed = false, leaving = false,
        }

        UI.hoverable(card, {
            enter = function()
                t.hover = true
                if not t.leaving then Anim.to(card, "BackgroundColor3", T.raised, "hover") end
            end,
            leave = function()
                t.hover = false
                Anim.to(card, "BackgroundColor3", T.surface, "hover")
            end,
        })

        table.insert(live, 1, t)
        restack("select")
        Anim.to(slider, "Position", UDim2.fromOffset(0, 0), "toast")
        fadeTo(t, true, "toast")
        if glow then Anim.to(glow, "ImageTransparency", glowRest, "light") end

        while #live > MAX do dismiss(live[#live]) end
    end

    ------------------------------------------------------------------------
    -- Public API. Measuring can yield, so requests go through one ordered
    -- worker: callers never yield, and a kill toast always lands before the
    -- streak toast that follows it.
    ------------------------------------------------------------------------
    local queue, working = {}, false

    local function drain()
        while E.alive and #queue > 0 do
            local req = table.remove(queue, 1)
            E.try("toast build", build, req)
        end
        working = false
    end

    -- a queued request keeps its strings in title and body; a built card keeps
    -- them in titleText and bodyText, since title and body hold its labels
    local function sameCard(t, title, body, kind)
        return t ~= nil and t.kind == kind and t.titleText == title and t.bodyText == body
    end
    local function sameRequest(r, title, body, kind)
        return r ~= nil and r.kind == kind and r.title == title and r.body == body
    end

    function E.toast(title, body, kind)
        if not E.alive then return end
        title = string.sub(tostring(title or ""), 1, 120)
        if title == "" then return end
        if body ~= nil then
            body = string.sub(tostring(body), 1, 240)
            if body == "" then body = nil end
        end
        if not KINDS[kind] then kind = "info" end

        local newest = live[1]
        if newest and not newest.leaving and #queue == 0 and sameCard(newest, title, body, kind) then
            pulse(newest)
            return
        end
        if sameRequest(queue[#queue], title, body, kind) then return end

        queue[#queue + 1] = { title = title, body = body, kind = kind }
        if not working then
            working = true
            task.spawn(drain)
        end
    end

    function E.notify(msg)
        E.toast(msg, nil, "info")
    end

    ------------------------------------------------------------------------
    -- Lifetime. Countdown pauses while any card is hovered with Alt held.
    ------------------------------------------------------------------------
    local function anyHover()
        for _, t in ipairs(live) do
            if t.hover then return true end
        end
        return false
    end

    local function step(dt)
        if #live == 0 and #leaving == 0 then return end
        dt = math.min(type(dt) == "number" and dt or 0, 0.1)
        if not anyHover() then
            for _, t in ipairs(live) do t.age = t.age + dt end
        end
        for i = #live, 1, -1 do
            local t = live[i]
            if t and t.age >= LIFE then dismiss(t) end
        end
        local now = os.clock()
        for i = #leaving, 1, -1 do
            local t = leaving[i]
            if now >= t.goneAt then
                table.remove(leaving, i)
                t.holder:Destroy()
            end
        end
    end

    E.connect(E.RunService.Heartbeat, function(dt)
        local ok, err = pcall(step, dt)
        if not ok then E.fault("toast step", err) end
    end)

    -- Alt and click a card to put it away early
    E.connect(E.UIS.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not UI.clickable then return end
        local ok, err = pcall(function()
            local m = UI.mouse()
            for _, t in ipairs(live) do
                if UI.inside(t.card, m) then
                    dismiss(t)
                    return
                end
            end
        end)
        if not ok then E.fault("toast click", err) end
    end)

    -- the deck starts below the radar whenever the radar is on
    local function onRadar() restack("select") end
    E.watch("radar.enabled", onRadar)
    E.watch("radar.size", onRadar)

    E.on("accent", function(color)
        local c = typeof(color) == "Color3" and color or T.accent
        for _, list in ipairs({ live, leaving }) do
            for _, t in ipairs(list) do
                if t.kind == "kill" then
                    Anim.to(t.strip, "BackgroundColor3", c, "fade")
                    if t.glow then Anim.to(t.glow, "ImageColor3", c, "fade") end
                end
            end
        end
    end)

    ------------------------------------------------------------------------
    -- Kill feed
    ------------------------------------------------------------------------
    local MILESTONES = { [3] = true, [5] = true, [10] = true }
    local HEAD_WINDOW = 2      -- a headshot only counts if it landed this recently
    local DIST_WINDOW = 10     -- older hits are likely a different fight

    local function fmtDist(d)
        return string.format("%dm", math.floor(d + 0.5))
    end

    -- fallback when no recent hit carries a distance: the victim's body, but
    -- only when exactly one player carries that name
    local function victimDistance(name)
        local cam = workspace.CurrentCamera
        if not cam then return nil end
        local found
        for _, p in ipairs(E.Players:GetPlayers()) do
            if p ~= E.LP and (p.DisplayName == name or p.Name == name) then
                if found then return nil end
                found = p
            end
        end
        local char = found and found.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then return nil end
        return (root.Position - cam.CFrame.Position).Magnitude
    end

    local announced = 0

    E.on("kill", function(info)
        if type(info) ~= "table" then return end
        local kind = tostring(info.kind)
        local S = E.stats
        local streak = (S and tonumber(S.streak)) or 0
        if streak < announced then announced = 0 end

        if kind ~= "Kill" and kind ~= "Assist" then return end
        local feed = cfg.ui.killFeed == true
        local name = tostring(info.name or "?")

        if kind == "Assist" then
            if feed then E.toast("Assist on " .. name, nil, "info") end
            return
        end

        local now = os.clock()
        local lh = type(info.lastHit) == "table" and info.lastHit or nil
        local at = lh and type(lh.at) == "number" and lh.at or nil
        local head = at ~= nil and now - at <= HEAD_WINDOW and lh.head == true

        local dist
        if at and type(lh.dist) == "number" and now - at <= DIST_WINDOW then
            dist = lh.dist
        else
            dist = victimDistance(tostring(info.realName or name))
        end

        local body
        if head then
            body = dist and ("Headshot, " .. fmtDist(dist)) or "Headshot"
        elseif dist then
            body = fmtDist(dist)
        end

        if feed then E.toast("Eliminated " .. name, body, head and "head" or "kill") end

        if MILESTONES[streak] and streak ~= announced then
            announced = streak
            if feed then E.toast("Streak of " .. streak, nil, "head") end
        end
    end)
end

-- ==== en_23_pages.lua ====
-- en_23_pages: the five pages, composed from the control library.
do
    local T, UI, Anim = E.T, E.ui, E.Anim
    local new, text = UI.new, UI.text

    ------------------------------------------------------------------------
    -- Combat
    ------------------------------------------------------------------------
    local combat = UI.addTab("Combat", "i_combat")
    do
        local s = UI.section(combat, "Silent aim", "Each shot is redirected inside the game's own aiming, so the server receives an ordinary shot.")
        if not E.cap.silentAim then
            UI.note(s, "Silent aim could not attach to this game version. Everything else still works.")
        end
        UI.toggle(s, "Silent aim", "aim.silent")
        UI.segmented(s, "Aim at", "aim.part", { "Head", "Torso", "Closest" },
            "Head deals 1.5 times damage. If your choice is covered and the other part is not, the visible one is used.")
        UI.slider(s, "Field of view", "aim.fov", 1, 179, 1, " deg")
        UI.slider(s, "Hit chance", "aim.hitChance", 1, 100, 1, "%",
            "Below 100, some shots stay where you aimed, which looks more natural to other players.")
        UI.slider(s, "Max distance", "aim.maxDist", 50, 3000, 50, "m")
        UI.toggle(s, "Require clear sight", "aim.visible",
            "Only locks onto players the server can actually hit. Bullets cannot pass through walls in this game.")
        UI.toggle(s, "Lead moving targets", "aim.predict")
        UI.segmented(s, "Priority", "aim.priority", { "Crosshair", "Distance", "Health" })
        UI.toggle(s, "Stay on target", "aim.sticky",
            "Keeps the lock through small crosshair drift instead of hopping between players.")

        local c = UI.section(combat, "Camera aimbot")
        UI.toggle(c, "Camera aimbot", "cam.enabled",
            "Turns your view toward the target. Silent aim already lands the shot, so this mostly helps you follow a fight.")
        UI.toggle(c, "Only while aiming", "cam.hold")
        UI.slider(c, "Smoothing", "cam.smooth", 0, 1, 0.01, "")

        local f = UI.section(combat, "Firing")
        UI.toggle(f, "Hold to fire", "fire.rapid",
            "Bolt action rifles keep firing while you hold the button, each shot sent the moment the server allows it. Automatic weapons already fire while held.")
        UI.toggle(f, "Auto fire", "fire.auto", "Fires when a visible target is inside the cone below.")
        UI.slider(f, "Auto fire cone", "fire.autoCone", 1, 30, 1, " deg")
        UI.toggle(f, "Auto reload", "fire.autoReload", "Reloads as soon as the magazine runs empty.")
    end

    ------------------------------------------------------------------------
    -- Visuals
    ------------------------------------------------------------------------
    local visuals = UI.addTab("Visuals", "i_visuals")
    do
        local s = UI.section(visuals, "Players", "Enemies only. Players waiting in the lobby are left out.")
        UI.toggle(s, "ESP", "esp.enabled")
        UI.toggle(s, "Box", "esp.box")
        UI.toggle(s, "Name", "esp.name")
        UI.toggle(s, "Distance", "esp.dist")
        UI.toggle(s, "Weapon", "esp.weapon")
        UI.toggle(s, "Health bar", "esp.health")
        UI.toggle(s, "Health number", "esp.hpText")
        UI.toggle(s, "Spotted tag", "esp.spotted", "Marks enemies your team has spotted.")
        UI.toggle(s, "Chams", "esp.chams")
        UI.toggle(s, "Off screen pointers", "esp.offscreen")
        UI.toggle(s, "Tracers", "esp.tracers")
        UI.slider(s, "ESP distance", "esp.maxDist", 50, 3000, 50, "m")
        UI.note(s, "Green means a clear shot, red means something is in the way, and gold marks the player you are locked onto.")

        local o = UI.section(visuals, "Overlay")
        UI.toggle(o, "Show aim circle", "aim.showFov")
    end

    ------------------------------------------------------------------------
    -- World
    ------------------------------------------------------------------------
    local world = UI.addTab("World", "i_world")
    do
        local v = UI.section(world, "View")
        UI.slider(v, "Field of view", "world.fov", -30, 40, 1, "",
            "Added on top of the game's own value, so aiming and scopes still zoom normally.")
        UI.toggle(v, "Clear view", "world.clearWeather",
            "Removes haze, distance blur, weather particles and the grey tint when you are hurt.")

        local r = UI.section(world, "Radar")
        UI.toggle(r, "Radar", "radar.enabled")
        UI.slider(r, "Range", "radar.range", 100, 800, 25, "m")
        UI.slider(r, "Size", "radar.size", 120, 260, 10, "px")
    end

    ------------------------------------------------------------------------
    -- Stats
    ------------------------------------------------------------------------
    local stats = UI.addTab("Stats", "i_stats")
    do
        local s = UI.section(stats, "This session", "Counted from what the server confirms, not from what the client sends.")

        local gridRow = s.addRow(172)
        local grid = new("Frame", {
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(16, 4),
            Size = UDim2.new(1, -32, 1, -8),
            ZIndex = 9,
        }, gridRow)
        new("UIGridLayout", {
            CellSize = UDim2.new(1 / 3, -6, 0, 76),
            CellPadding = UDim2.fromOffset(9, 9),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }, grid)

        local tiles = {}
        local function tile(key, label, decimals, suffix, order)
            local t = new("Frame", {
                BackgroundColor3 = T.raised,
                LayoutOrder = order,
                ZIndex = 10,
            }, grid)
            UI.corner(t, T.radius.md)
            local holder = new("Frame", {
                BackgroundTransparency = 1,
                Position = UDim2.fromOffset(14, 12),
                Size = UDim2.new(1, -28, 0, 30),
                ZIndex = 11,
            }, t)
            local counter = UI.counter(holder, "digits", T.text, decimals, suffix)
            text(t, string.upper(label), "heading", {
                Position = UDim2.fromOffset(14, 48),
                Size = UDim2.new(1, -28, 0, 16),
                TextColor3 = T.mute,
                ZIndex = 11,
            })
            tiles[key] = counter
        end
        tile("kills", "Kills", 0, nil, 1)
        tile("deaths", "Deaths", 0, nil, 2)
        tile("kd", "K / D", 2, nil, 3)
        tile("acc", "Accuracy", 0, "%", 4)
        tile("head", "Headshots", 0, "%", 5)
        tile("streak", "Best streak", 0, nil, 6)

        local detail = UI.section(stats, "Shots")
        local lines = {}
        local function line(label)
            local r = UI.row(detail, label, nil, 160)
            local v = text(r, "", "value", {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, -16, 0, 0),
                Size = UDim2.fromOffset(240, T.row),
                TextXAlignment = Enum.TextXAlignment.Right,
                TextColor3 = T.dim,
                ZIndex = 10,
            })
            lines[#lines + 1] = v
            return v
        end
        local sentL = line("Shots fired")
        local accL = line("Accepted by the server")
        local hitL = line("Hits")
        local dmgL = line("Damage dealt")
        local lastL = line("Last hit")
        UI.button(detail, "Session", "Reset", function()
            E.stats.reset()
            if E.notify then E.notify("Session stats reset") end
        end)

        local function fmtInt(n)
            local s2 = tostring(math.floor(n + 0.5))
            local out = s2:reverse():gsub("(%d%d%d)", "%1,"):reverse()
            return (out:gsub("^,", ""))
        end

        E.loop("stats page", function()
            if not (UI.current and UI.current.name == "Stats" and UI.panelOpen) then return 0.5 end
            local S = E.stats
            tiles.kills.set(S.kills)
            tiles.deaths.set(S.deaths)
            tiles.kd.set(S.kd())
            tiles.acc.set(S.accuracy() * 100)
            tiles.head.set(S.headRate() * 100)
            tiles.streak.set(S.bestStreak)
            sentL.Text = fmtInt(S.sent)
            accL.Text = fmtInt(S.accepted)
            hitL.Text = fmtInt(S.hits) .. "  (" .. fmtInt(S.heads) .. " to the head)"
            dmgL.Text = fmtInt(S.damage)
            local lh = S.lastHit
            if lh then
                local where = lh.head and "Head" or tostring(lh.part)
                lastL.Text = where .. " on " .. tostring(lh.victim)
                    .. (lh.dist and ("  " .. math.floor(lh.dist) .. "m") or "")
            else
                lastL.Text = "None yet"
            end
            return 0.25
        end)
    end

    ------------------------------------------------------------------------
    -- Experiments: untested ideas. Each one may do nothing on the live server,
    -- so the page says so plainly and everything that changes gameplay is off.
    ------------------------------------------------------------------------
    local lab = UI.addTab("Experiments", "i_lab")
    do
        local intro = UI.section(lab, "Read this first",
            "These are untested ideas. Some may do nothing, and some are easier for other players to notice. Turn on one at a time and see what changes.")
        UI.note(intro, "If something feels wrong, turn it off again. Every change here is undone when you switch it off or unload the hub.")

        local s = UI.section(lab, "Shooting")
        UI.toggle(s, "No spread", "exp.noSpread",
            "Removes the random spread on each shot, including when you shoot without aiming.")
        UI.toggle(s, "Game bullet magnetism", "exp.magnetism",
            "Turns on the aim help the game already gives phone players, which pulls shots toward nearby enemies.")
        UI.toggle(s, "No recoil", "exp.noRecoil", "Stops your view kicking up when you fire.")
        UI.toggle(s, "Faster reload", "exp.fastReload", "Asks the game for shorter reloads. The server may not allow it.")
        UI.toggle(s, "Instant aim", "exp.instantAim", "Zooms in straight away when you aim down sights, instead of easing in.")
        UI.toggle(s, "Finish downed enemies", "exp.finishDowned",
            "Silent aim also targets downed enemies, and goes for them first so they cannot be revived.")
        UI.toggle(s, "Self tuning lead", "exp.adaptiveLead",
            "Learns from your hits and misses how far ahead of moving targets to aim, and adjusts as you play.")

        local m = UI.section(lab, "Movement and gear")
        UI.toggle(m, "No fall damage", "exp.noFallDamage", "You take no damage from falling.")
        UI.toggle(m, "Safe sprint", "exp.safeSprint",
            "Keeps you just under the game's speed limit while you move. Going over the limit gets you kicked, so it never does.")
        UI.toggle(m, "Long throw", "exp.longThrow", "Throws grenades and flares further.")
        UI.toggle(m, "Melee reach", "exp.meleeReach",
            "Your spade and bayonet hits reach the nearest enemy within the distance below.")
        UI.slider(m, "Melee distance", "exp.meleeRange", 6, 30, 1, " studs")
        UI.toggle(m, "Instant prompts", "exp.instantPrompts",
            "Hold prompts finish straight away, such as reviving a teammate.")

        local t = UI.section(lab, "Team")
        UI.toggle(t, "Auto spot", "exp.autoSpot",
            "Spots every enemy you can see for your whole team, as often as the game allows.")

        local g = UI.section(lab, "Safety")
        UI.toggle(g, "Moderator alert", "exp.modAlert", "Warns you when a moderator is in your server.")
        UI.toggle(g, "Leave when a moderator joins", "exp.modLeave",
            "Moves you to another server as soon as a moderator is detected.")
        UI.toggle(g, "Votekick alert", "exp.voteAlert", "Warns you when a votekick starts.")
        UI.toggle(g, "Leave when votekicked", "exp.voteLeave",
            "Moves you to another server when a votekick starts against you.")
        UI.toggle(g, "Streamer mode", "exp.streamer", "Hides real player names in the ESP, the kill feed and the minimised bar.")
        UI.button(g, "Join another server", "Hop", function()
            if E.exp and E.exp.hop then E.exp.hop() end
        end)
        UI.button(g, "Rejoin this server", "Rejoin", function()
            if E.exp and E.exp.rejoin then E.exp.rejoin() end
        end)
    end

    ------------------------------------------------------------------------
    -- Settings
    ------------------------------------------------------------------------
    local settings = UI.addTab("Settings", "i_settings")
    do
        local a = UI.section(settings, "Appearance")
        UI.swatches(a, "Accent colour", "ui.accent", T.ACCENTS)
        UI.slider(a, "Interface scale", "ui.scale", 0.7, 1.4, 0.05, "x")
        UI.toggle(a, "Reduce motion", "ui.reduceMotion", "Shortens every animation and turns off the decorative ones.")

        local b = UI.section(settings, "Behaviour")
        UI.toggle(b, "Kill feed", "ui.killFeed")
        UI.toggle(b, "Save settings automatically", "ui.autoSave")

        local k = UI.section(settings, "Keys", "Click normally. When the game locks the cursor, hold Left Alt to free it.")
        UI.keybind(k, "Show or hide panel", "keys.panel")
        UI.keybind(k, "Toggle silent aim", "keys.silent")
        UI.keybind(k, "Toggle ESP", "keys.esp")

        local h = UI.section(settings, "Hub")
        UI.button(h, "Save settings now", "Save", function()
            E.save(true)
            if E.notify then E.notify("Settings saved") end
        end)
        UI.button(h, "Restore defaults", "Reset", function()
            E.resetConfig()
            if E.notify then E.notify("Settings restored to defaults") end
        end)
        UI.button(h, "Unload the hub", "Unload", function() E.unload("user") end,
            "Removes the panel and every change it made to the game.", true)

        local caps = {}
        local function cap(name, ok) caps[#caps + 1] = name .. (ok and " ready" or " unavailable") end
        cap("Silent aim", E.cap.silentAim)
        cap("Weapon control", E.cap.weaponModule and E.cap.stateLookup)
        cap("Graphics", E.cap.sprites)
        UI.note(h, "Version " .. E.version .. ".  " .. table.concat(caps, ",  ") .. ".")
    end
end

-- ==== en_24_pill.lua ====
-- en_24_pill: panel visibility, the minimised pill, and global keybinds.
--
-- The window and the pill share one rule: nothing reacts to the pointer
-- while the game has the cursor locked. Show and hide are springs on the holder's UIScale
-- and Position; the pill is not inside a list layout, so scaling it is safe.
do
    local T, Anim, UI = E.T, E.Anim, E.ui
    local UIS = E.UIS
    local new, text = UI.new, UI.text
    local holder, scaleObj = UI.holder, UI.scaleObj

    local NUDGE = 12          -- pixels the window travels while it shows or hides
    local SETTLE = 0.6        -- seconds a show animation owns the window position
    local HIDE_AFTER = 0.22   -- seconds before a hiding surface is made invisible

    ------------------------------------------------------------------------
    -- Helpers
    ------------------------------------------------------------------------
    -- the same formula UI.rescale targets in en_20_ui_core
    local function restingScale()
        local cam = workspace.CurrentCamera
        local vy = cam and cam.ViewportSize.Y or 1080
        return math.clamp(vy / 1080, 0.8, 1.4) * math.clamp(E.cfg.ui.scale, 0.7, 1.4)
    end

    local function viewport()
        local cam = workspace.CurrentCamera
        return cam and cam.ViewportSize or Vector2.new(1920, 1080)
    end

    local function lowered(p)
        return UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset + NUDGE)
    end

    -- "RightShift" reads better as "Right Shift"
    local function keyLabel(name)
        return (string.gsub(name, "(%l)(%u)", "%1 %2"))
    end

    local function keyBound(name)
        return type(name) == "string" and name ~= "" and name ~= "None"
    end

    -- E.notify belongs to a later part, so it is looked up at call time
    local function notify(msg)
        if type(E.notify) == "function" then
            E.try("notify", E.notify, msg)
            return true
        end
        return false
    end

    ------------------------------------------------------------------------
    -- Window visibility
    ------------------------------------------------------------------------
    local isOpen = UI.panelOpen ~= false
    UI.panelOpen = isOpen
    local restPos = nil          -- where the window sits when fully open
    local settleUntil = 0
    local openGen = 0            -- bumps on every show or hide so a stale hide cannot land
    local hintShown = false
    local minimisedShown = false
    local booting = true

    -- While open and settled the window may have been dragged, so its live
    -- position is the truth. While opening or closed, the remembered spot is.
    local function restSpot()
        if restPos and (not isOpen or os.clock() < settleUntil) then return restPos end
        return holder.Position
    end

    local function panelHint()
        if hintShown then return end
        local key = E.cfg.keys.panel
        if not keyBound(key) then return end
        if notify("Press " .. keyLabel(key) .. " to show the panel") then hintShown = true end
    end

    local hiddenAt = 0           -- os.clock() of the last hide, for the consistency check

    local function showWindow()
        if isOpen then return end
        if UI.cancelDrag then UI.cancelDrag() end
        local rest = restSpot()
        restPos = rest
        isOpen = true
        UI.panelOpen = true
        openGen = openGen + 1
        settleUntil = os.clock() + SETTLE
        local s = restingScale()
        if not holder.Visible then
            Anim.set(scaleObj, "Scale", s * 0.94)
            Anim.set(holder, "Position", lowered(rest))
            holder.Visible = true
        end
        -- reopened mid hide: the springs simply turn around with their momentum
        Anim.to(scaleObj, "Scale", s, "panel")
        Anim.to(holder, "Position", rest, "panel")
        UI.syncInteract()
    end

    local function hideWindow(quiet, instant)
        if not isOpen then return end
        if UI.cancelDrag then UI.cancelDrag() end
        restPos = restSpot()
        isOpen = false
        UI.panelOpen = false
        settleUntil = 0
        hiddenAt = os.clock()
        openGen = openGen + 1
        local s = restingScale() * 0.94
        if instant then
            Anim.set(scaleObj, "Scale", s)
            Anim.set(holder, "Position", lowered(restPos))
            holder.Visible = false
        else
            local gen = openGen
            Anim.to(scaleObj, "Scale", s, "collapse")
            Anim.to(holder, "Position", lowered(restPos), "collapse")
            task.delay(HIDE_AFTER, function()
                if E.alive and gen == openGen and not isOpen then holder.Visible = false end
            end)
        end
        if not quiet and not minimisedShown then panelHint() end
    end

    -- a later part places the window once it knows the viewport; keep the
    -- remembered spot in step so the next show lands there
    local basePlace = UI.placeInitial
    if type(basePlace) == "function" then
        function UI.placeInitial(...)
            basePlace(...)
            local p = holder.Position
            restPos = p
            settleUntil = 0
            Anim.set(holder, "Position", isOpen and p or lowered(p))
        end
    end

    ------------------------------------------------------------------------
    -- Pill
    ------------------------------------------------------------------------
    local PILL_H, PAD, GAP = 44, 16, 12
    local MARK_W = 14                        -- a 10px square turned 45 degrees spans about 14px
    local CHIP_H, CHIP_PAD, CHIP_MAX = 24, 10, 150

    local pill = new("Frame", {
        Name = "Pill",
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(240, PILL_H),
        Position = UDim2.fromOffset(48, 48),
        Visible = false,
        ZIndex = 20,
    }, UI.panelScreen)
    UI.pill = pill
    -- appear and vanish scale around the top left, where the window collapses
    local pillScale = new("UIScale", { Scale = 1 }, pill)

    UI.shadow(pill, true, true, 0)

    local body = new("Frame", {
        Name = "Body",
        BackgroundColor3 = T.base,
        BackgroundTransparency = 0.02,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(1, 1),
        ZIndex = 1,
    }, pill)
    UI.corner(body, T.radius.pill)
    UI.pillBody = body
    -- press dip scales around the centre of the body
    local pressScale = new("UIScale", { Scale = 1 }, body)

    -- The rim sprite is 9 sliced around a 12px radius, and the pill's ends are
    -- full semicircles, so a UICorner would clip the sprite's line into a notch
    -- at each end. A border stroke follows the pill's real shape instead. The
    -- pill never cross fades (it scales and then hides), so a stroke is safe.
    local RIM_IDLE, RIM_LIVE = 0.84, 0.55
    local rim = new("UIStroke", {
        Color = T.white,
        Thickness = 1,
        Transparency = RIM_IDLE,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, body)

    local markX = PAD + MARK_W / 2
    local glow
    if E.sprite.glow then
        glow = new("ImageLabel", {
            BackgroundTransparency = 1,
            Image = E.sprite.glow,
            ImageColor3 = T.accent,
            ImageTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0, markX, 0.5, 0),
            Size = UDim2.fromOffset(40, 40),
            ZIndex = 2,
        }, body)
        UI.accent(glow, "ImageColor3")
    end

    local mark = new("Frame", {
        BackgroundColor3 = T.accent,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, markX, 0.5, 0),
        Size = UDim2.fromOffset(10, 10),
        Rotation = 45,
        ZIndex = 3,
    }, body)
    UI.corner(mark, 2)
    UI.accent(mark, "BackgroundColor3")

    local titleX = PAD + MARK_W + GAP
    local titleW = math.ceil(T.measure("ENTRENCHED", "title").X)
    text(body, "ENTRENCHED", "title", {
        Position = UDim2.fromOffset(titleX, 0),
        Size = UDim2.fromOffset(titleW + 2, PILL_H),
        ZIndex = 3,
    })

    local chipX = titleX + titleW + GAP
    local chip = new("Frame", {
        BackgroundColor3 = T.raised,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, chipX, 0.5, 0),
        Size = UDim2.fromOffset(60, CHIP_H),
        ZIndex = 3,
    }, body)
    UI.corner(chip, T.radius.pill)
    local chipLabel = text(chip, "Idle", "small", {
        Position = UDim2.fromOffset(CHIP_PAD, 0),
        Size = UDim2.fromOffset(40, CHIP_H),
        TextColor3 = T.dim,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 4,
    })

    local kills = UI.counter(body, "value", T.text, 0, "K")
    local heads = UI.counter(body, "value", T.text, 0, "%")
    kills.box.AnchorPoint = Vector2.new(0, 0.5)
    heads.box.AnchorPoint = Vector2.new(0, 0.5)

    -- counter widths from the same measurements UI.counter makes, so the
    -- layout knows the final width before the digits finish rolling
    local digitW = 0
    for d = 0, 9 do digitW = math.max(digitW, math.ceil(T.measure(tostring(d), "value").X)) end
    local killsSufW = math.ceil(T.measure("K", "small").X)
    local headsSufW = math.ceil(T.measure("%", "small").X)
    local function counterW(v, sufW)
        local n = math.max(0, math.floor(v + 1e-6))
        return #tostring(n) * digitW + 3 + sufW
    end

    local measured = {}
    local function labelW(s)
        local w = measured[s]
        if not w then
            w = math.ceil(T.measure(s, "small").X)
            measured[s] = w
        end
        return w
    end

    local pillW = 240
    local shown = { label = "Idle", locked = false, kills = 0, heads = 0 }

    local function put(inst, prop, value, instant)
        if instant then Anim.set(inst, prop, value) else Anim.to(inst, prop, value, "hover") end
    end

    local function layout(instant)
        local lw = math.min(labelW(shown.label), CHIP_MAX)
        chipLabel.Size = UDim2.fromOffset(lw + 2, CHIP_H)
        local chipW = lw + CHIP_PAD * 2
        put(chip, "Size", UDim2.fromOffset(chipW, CHIP_H), instant)
        local x = chipX + chipW + GAP
        put(kills.box, "Position", UDim2.new(0, x, 0.5, 0), instant)
        x = x + counterW(shown.kills, killsSufW) + GAP
        put(heads.box, "Position", UDim2.new(0, x, 0.5, 0), instant)
        x = x + counterW(shown.heads, headsSufW) + PAD
        pillW = x
        put(pill, "Size", UDim2.fromOffset(pillW, PILL_H), instant)
    end

    local function readStatus()
        local label, locked = "Idle", false
        local t = E.aim and E.aim.target
        local p = t and t.player
        if p then
            label = E.nameOf(p, "Target")
            locked = true
        end
        local S = E.stats
        local k = (S and tonumber(S.kills)) or 0
        local r = 0
        if S and type(S.headRate) == "function" then
            local rate = S.headRate()
            if type(rate) == "number" and rate == rate then
                r = math.clamp(math.floor(rate * 100 + 0.5), 0, 100)
            end
        end
        return label, locked, k, r
    end

    local function paintLock(locked, instant)
        local c = locked and T.accent or T.dim
        local g = locked and 0.72 or 1
        if instant then
            Anim.set(chipLabel, "TextColor3", c)
            if glow then Anim.set(glow, "ImageTransparency", g) end
        else
            Anim.to(chipLabel, "TextColor3", c, "fade")
            if glow then Anim.to(glow, "ImageTransparency", g, "light") end
        end
    end

    local function refresh(instant)
        instant = instant == true
        local label, locked, k, r = readStatus()
        local changed = instant
        if label ~= shown.label then
            shown.label = label
            chipLabel.Text = label
            changed = true
            if not instant then
                -- the new name fades in while the chip grows to fit it
                Anim.set(chipLabel, "TextTransparency", 1)
                Anim.to(chipLabel, "TextTransparency", 0, "fade")
            end
        end
        if instant then Anim.set(chipLabel, "TextTransparency", 0) end
        if instant or locked ~= shown.locked then
            shown.locked = locked
            paintLock(locked, instant)
        end
        if instant or k ~= shown.kills then
            shown.kills = k
            kills.set(k, instant)
            changed = true
        end
        if instant or r ~= shown.heads then
            shown.heads = r
            heads.set(r, instant)
            changed = true
        end
        if changed then layout(instant) end
    end

    E.on("accent", function(c)
        if shown.locked then Anim.to(chipLabel, "TextColor3", c, "fade") end
    end)

    ------------------------------------------------------------------------
    -- Pill show and hide
    ------------------------------------------------------------------------
    local pillGen = 0
    local press = nil

    local function clampPill(x, y)
        local vp = viewport()
        x = math.clamp(x, 8, math.max(8, vp.X - pillW - 8))
        y = math.clamp(y, 8, math.max(8, vp.Y - PILL_H - 8))
        return math.floor(x), math.floor(y)
    end

    local function showPill(windowPos)
        pillGen = pillGen + 1
        refresh(true)
        local vp = viewport()
        local x, y = clampPill(windowPos.X.Scale * vp.X + windowPos.X.Offset,
                               windowPos.Y.Scale * vp.Y + windowPos.Y.Offset)
        if not pill.Visible then
            Anim.set(pillScale, "Scale", 0.86)
            Anim.set(pill, "Position", UDim2.fromOffset(x, y))
            Anim.set(pressScale, "Scale", 1)
            pill.Visible = true
        end
        Anim.to(pillScale, "Scale", 1, "select")
        Anim.to(pill, "Position", UDim2.fromOffset(x, y), "panel")
        Anim.set(rim, "Transparency", UI.clickable and RIM_LIVE or RIM_IDLE)
        UI.syncInteract()
    end

    local pillHiddenAt = 0
    local function hidePill()
        pillGen = pillGen + 1
        local gen = pillGen
        press = nil
        pillHiddenAt = os.clock()
        Anim.to(pressScale, "Scale", 1, "press")
        Anim.to(pillScale, "Scale", 0.9, "collapse")
        task.delay(HIDE_AFTER, function()
            if E.alive and gen == pillGen then pill.Visible = false end
        end)
    end

    ------------------------------------------------------------------------
    -- Minimise
    ------------------------------------------------------------------------
    local function applyMinimised(on)
        on = on == true
        if on == minimisedShown then return end
        minimisedShown = on
        if on then
            -- minimised before anything placed the window: place it first so
            -- the pill does not appear in the corner under the Roblox menu
            if not restPos and holder.Position == UDim2.new() then UI.placeInitial() end
            local spot = restSpot()
            hideWindow(true, booting)
            showPill(spot)
        else
            hidePill()
            UI.setOpen(true)
        end
    end

    function UI.setMinimised(on)
        on = on == true
        E.set("ui.minimised", on)
        applyMinimised(on)
    end

    function UI.setOpen(on)
        if on then
            if minimisedShown then UI.setMinimised(false) else showWindow() end
        elseif not minimisedShown then
            hideWindow(false)
        end
    end

    function UI.toggleOpen()
        if minimisedShown then
            UI.setMinimised(false)
        else
            UI.setOpen(not isOpen)
        end
    end

    E.watch("ui.minimised", applyMinimised)

    ------------------------------------------------------------------------
    -- Pill input: click restores, a press that travels more than 4px drags.
    -- Nothing here reacts unless Alt is held.
    ------------------------------------------------------------------------
    local hit = new("TextButton", {
        Name = "Hit",
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        Size = UDim2.fromScale(1, 1),
        ZIndex = 20,
    }, body)

    local function endPress(click)
        local p = press
        press = nil
        if not p then return end
        Anim.to(pressScale, "Scale", 1, "release")
        if p.moved then
            local x, y = clampPill(p.goal.X, p.goal.Y)
            Anim.to(pill, "Position", UDim2.fromOffset(x, y), "panel")
        elseif click and UI.clickable and minimisedShown then
            UI.setMinimised(false)
        end
    end

    E.connect(hit.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if not (UI.clickable and minimisedShown and pill.Visible) then return end
        local o = pill.Position
        local origin = Vector2.new(o.X.Offset, o.Y.Offset)
        press = { start = UI.mouse(), origin = origin, goal = origin, moved = false }
        Anim.to(pressScale, "Scale", 0.96, "press")
    end)

    E.connect(UIS.InputChanged, function(input)
        if not press or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        if not UI.clickable then endPress(false) return end
        local d = UI.mouse() - press.start
        if not press.moved then
            if d.Magnitude <= 4 then return end
            press.moved = true
            Anim.to(pressScale, "Scale", 1.03, "hover")
        end
        press.goal = press.origin + d
        Anim.to(pill, "Position", UDim2.fromOffset(press.goal.X, press.goal.Y), "follow")
    end)

    E.connect(UIS.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then endPress(true) end
    end)

    UI.onClickable(function(on)
        if not on then endPress(false) end
        -- the rim brightens while the pill can be clicked
        if pill.Visible then
            Anim.to(rim, "Transparency", on and RIM_LIVE or RIM_IDLE, "fade")
        end
    end)

    ------------------------------------------------------------------------
    -- Header buttons
    ------------------------------------------------------------------------
    UI.minButton = UI.headerButton("i_min", -52, function()
        UI.setMinimised(true)
    end)
    UI.closeButton = UI.headerButton("i_close", -16, function()
        if keyBound(E.cfg.keys.panel) then
            UI.setOpen(false)
        else
            -- with no panel key a closed window could never come back
            UI.setMinimised(true)
        end
    end)

    ------------------------------------------------------------------------
    -- Global keybinds
    ------------------------------------------------------------------------
    -- A keybind capture consumes the same press that would trigger its
    -- action, so any press that lands within 0.3s of a key change is ignored.
    local keyChangedAt = { panel = -1, silent = -1, esp = -1 }
    for name in pairs(keyChangedAt) do
        E.watch("keys." .. name, function() keyChangedAt[name] = os.clock() end)
    end

    local function recentlyRebound()
        local now = os.clock()
        for _, t in pairs(keyChangedAt) do
            if now - t < 0.3 then return true end
        end
        return false
    end

    local function flip(path, onText, offText)
        local v = not (E.get(path) == true)
        E.set(path, v)
        notify(v and onText or offText)
    end

    local function onKey(keyName)
        if recentlyRebound() then return end
        local keys = E.cfg.keys
        if keys.panel == keyName then
            if minimisedShown then UI.setMinimised(false) else UI.toggleOpen() end
        end
        if keys.silent == keyName then flip("aim.silent", "Silent aim on", "Silent aim off") end
        if keys.esp == keyName then flip("esp.enabled", "ESP on", "ESP off") end
    end

    E.connect(UIS.InputBegan, function(input, gameProcessed)
        if gameProcessed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local k = input.KeyCode
        if k == Enum.KeyCode.Unknown or k == Enum.KeyCode.LeftAlt then return end
        local keyName = k.Name
        -- deferred so a capture control listening to this same press has
        -- already stored its key, whichever connection happens to run first
        task.defer(function()
            if E.alive then E.try("keybind", onKey, keyName) end
        end)
    end)

    ------------------------------------------------------------------------
    -- Status: about five updates a second, and only while the pill shows
    ------------------------------------------------------------------------
    refresh(true)
    E.loop("pill status", function()
        if minimisedShown and pill.Visible then refresh(false) end
        return 0.2
    end)

    -- Consistency net. Whatever happens in between (a hide timer that never
    -- landed, a map change mid animation), the surfaces always settle into
    -- the state the flags describe: a hidden pill can never sit over the
    -- window, and a restored window is always shown at full size.
    E.loop("surface check", function()
        local now = os.clock()
        if not minimisedShown and pill.Visible and now - pillHiddenAt > 0.6 then
            press = nil
            pill.Visible = false
        end
        if minimisedShown and not pill.Visible then
            showPill(restSpot())
        end
        if isOpen then
            if not holder.Visible then holder.Visible = true end
            if now > settleUntil then
                local s = restingScale()
                if math.abs(scaleObj.Scale - s) > 0.02 then Anim.to(scaleObj, "Scale", s, "panel") end
            end
        elseif holder.Visible and now - hiddenAt > 0.6 then
            holder.Visible = false
        end
        return 0.5
    end)

    -- a saved minimised state is applied once the rest of the build has run,
    -- unless a replay of the settings already did it
    task.defer(function()
        if E.alive and E.cfg.ui.minimised == true and not minimisedShown then
            E.try("pill startup", applyMinimised, true)
        end
        booting = false
    end)
end

-- ==== en_99_start.lua ====
-- en_99_start: runs last, once every part exists.
do
    local UI = E.ui

    UI.placeInitial()

    local wanted, found = E.cfg.ui.tab, false
    for _, t in ipairs(UI.tabs) do if t.name == wanted then found = true end end
    UI.select(found and wanted or UI.tabs[1].name, true)

    -- restored settings only take effect once their watchers fire
    E.replay()

    if E.cfg.ui.minimised and UI.setMinimised then
        UI.setMinimised(true)
    elseif UI.setOpen then
        UI.setOpen(true)
    end

    task.delay(0.7, function()
        if not E.alive then return end
        if E.toast then
            local key = E.cfg.keys.panel
            local keyText = (key == "None" or key == "") and "" or ("  " .. key .. " shows or hides the panel.")
            E.toast("Entrenched is ready", "When the cursor is locked, hold Left Alt to click." .. keyText, "info")
        end
    end)

    local ready = {}
    for k, v in pairs(E.cap) do ready[#ready + 1] = k .. "=" .. tostring(v) end
    table.sort(ready)
    print(string.format("[Entrenched] v%s loaded. settings %s. %s. aim route %s.",
        E.version, E.cfgSource, table.concat(ready, " "), tostring(E.aim and E.aim.route)))
end
