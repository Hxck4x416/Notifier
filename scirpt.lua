local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local HttpService     = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local TweenService    = game:GetService("TweenService")
local CoreGui         = game:GetService("CoreGui")

local plr       = Players.LocalPlayer
local playerGui = plr:WaitForChild("PlayerGui")

local CONFIG_PATH = "pragra_v1.0_config.json"

local function loadConfig()
    local ok, data = pcall(readfile, CONFIG_PATH)
    if not ok or not data or data == "" then return nil end
    local ok2, cfg = pcall(HttpService.JSONDecode, HttpService, data)
    return ok2 and cfg or nil
end

local function saveConfig(cfg)
    pcall(writefile, CONFIG_PATH, HttpService:JSONEncode(cfg))
end

local PLACE_ID     = "109983668079237"
local WEBHOOK      = "https://discord.com/api/webhooks/1485845525289893931/tSszY0KRQsFrJiN1v8D3qMbu6LDXhQWV1UCDMIHmxpf2jJ6xdwgHFRHC9gJsHRoKlrxq"
local MIN_GEN      = 10000000
local HOP_SECONDS  = 4
local BATCH_COUNT  = 2

local currentMode   = nil
local activeThreads = {}

local function stopAllThreads()
    for _, t in ipairs(activeThreads) do pcall(task.cancel, t) end
    activeThreads = {}
end

local function toHex(str)
    if not str or str == "" then return "" end
    local hex = ""
    for i = 1, #str do
        hex = hex .. string.format("%02x", string.byte(str, i))
    end
    return hex
end

local _httpFn = nil
local function getHttp()
    if _httpFn then return _httpFn end
    for _, n in ipairs({"request","http_request"}) do
        local ok, f = pcall(function() return rawget(_G, n) end)
        if ok and type(f)=="function" then _httpFn=f; return f end
    end
    local ok, f = pcall(function() return request end)
    if ok and type(f)=="function" then _httpFn=f; return f end
    ok, f = pcall(function() return http_request end)
    if ok and type(f)=="function" then _httpFn=f; return f end
    return nil
end
local function rawHttp(opts)
    local fn = getHttp(); if not fn then return nil end
    local ok, r = pcall(fn, opts)
    if not ok then warn("[PRAGRA] HTTP: "..tostring(r)); _httpFn=nil; return nil end
    return r
end
local function httpGet(url)
    local r = rawHttp({Url=url, Method="GET", Headers={["User-Agent"]="PRAGRA/1"}})
    if not r then return nil end
    local body = type(r)=="table" and (r.Body or "") or tostring(r)
    local ok, d = pcall(HttpService.JSONDecode, HttpService, body)
    if not ok then warn("[PRAGRA] JSON err: "..body:sub(1,120)); return nil end
    return d
end
local function httpPost(url, payload)
    task.spawn(function()
        rawHttp({Url=url, Method="POST",
            Headers={["Content-Type"]="application/json"},
            Body=HttpService:JSONEncode(payload)})
    end)
end

local RELAY_BASE = "https://72.61.5.202:3000"
local RELAY_POST = RELAY_BASE .. "/relay"

local relayConn = true
local relayWS   = true

local function fmtMillions(n)
    if not n or n == 0 then return "0M" end
    if n >= 1e12 then return string.format("%.2fT", n/1e12)
    elseif n >= 1e9  then return string.format("%.2fB", n/1e9)
    else                  return string.format("%.1fM", n/1e6) end
end

local function sendToRelay(realPets, jobId, inDuels)
    task.spawn(function()
        local brainrots = {}
        for _, pet in ipairs(realPets) do
            local dn = pet.mutTag and ("["..pet.mutTag.."] "..pet.name) or pet.name
            table.insert(brainrots, {
                name     = dn,
                value    = fmtMillions(pet.genValue),
                valueRaw = pet.genValue,
                duels    = inDuels and true or false
            })
        end
        local body = HttpService:JSONEncode({
            jobid     = tostring(jobId),
            brainrots = brainrots,
            bot       = tostring(plr.Name)
        })
        local ok, res = pcall(rawHttp, {
            Url     = RELAY_POST,
            Method  = "POST",
            Headers = {["Content-Type"] = "application/json"},
            Body    = body
        })
        if ok and res then
            local code = type(res)=="table" and (res.StatusCode or res.status or 0) or 0
            if code >= 200 and code < 300 then
                print(string.format("[PRAGRA] ✅ relay → %d brainrots | %s", #brainrots, tostring(jobId):sub(1,8)))
            else
                local rb = type(res)=="table" and (res.Body or "") or ""
                warn("[PRAGRA] relay "..tostring(code).." | "..rb:sub(1,120))
            end
        else
            warn("[PRAGRA] relay falló: "..tostring(res))
        end
    end)
end

local function dts(unix, fmt)
    return "<t:"..tostring(math.floor(unix or os.time()))..":"..(fmt or "R")..">"
end

local BASES = {
    {minX=-345.21,maxX=-286.79,minZ=-129.68,maxZ=-70.52},
    {minX=-347.74,maxX=-287.08,minZ=-24.34, maxZ=35.10 },
    {minX=-345.99,maxX=-286.48,minZ=83.28,  maxZ=142.31},
    {minX=-347.56,maxX=-286.52,minZ=191.39, maxZ=250.13},
    {minX=-532.26,maxX=-473.37,minZ=192.39, maxZ=248.67},
    {minX=-533.37,maxX=-472.37,minZ=84.78,  maxZ=143.82},
    {minX=-532.88,maxX=-473.79,minZ=-22.91, maxZ=37.28 },
    {minX=-533.50,maxX=-473.25,minZ=-129.12,maxZ=-70.64},
}
local function getBaseIdx(pos)
    for i, b in ipairs(BASES) do
        if pos.X>=b.minX and pos.X<=b.maxX and pos.Z>=b.minZ and pos.Z<=b.maxZ then
            return i
        end
    end
end

local function parseGen(text)
    if not text or text=="" then return 0 end
    local t = tostring(text):lower():gsub("%s+",""):gsub(",",""):gsub("%$",""):gsub("/s","")
    local n = tonumber(t:match("([%d%.]+)")); if not n then return 0 end
    if t:find("b") then return math.floor(n*1e9) end
    if t:find("m") then return math.floor(n*1e6) end
    if t:find("k") then return math.floor(n*1e3) end
    return math.floor(n)
end
local function isFusing(name)
    return name and name:lower():find("fus") ~= nil
end
local function isMachineGen(genText)
    if not genText then return false end
    local t   = tostring(genText):lower():gsub("%s+","")
    local orig = tostring(genText):lower()
    if t:match("%d+h") or t:match("%d+m%d+s") then return true end
    if t:match("%d+m$") and not t:match("%d+%.?%d*m$") then return true end
    if orig:match("%d+%s*m%s*%d+%s*s") or orig:match("%d+%s*h%s*%d+%s*m") then return true end
    if orig:match("^%s*%d+%s*[hms]%s*$") then return true end
    return false
end

local fusingOverheads = {}
local function scanFusing()
    local debris = workspace:FindFirstChild("Debris"); if not debris then return end
    for oh in pairs(fusingOverheads) do
        if not oh or not oh.Parent then fusingOverheads[oh] = nil end
    end
    for _, obj in ipairs(debris:GetDescendants()) do
        if obj and obj.Parent and obj.Name == "AnimalOverhead" then
            local gl = obj:FindFirstChild("Generation")
            if gl and gl:IsA("TextLabel") then
                local ok, txt = pcall(function() return gl.Text end)
                if ok and txt and txt ~= "" then
                    fusingOverheads[obj] = not txt:find("/s") or nil
                end
            end
        end
    end
end
local function isAdornFusing(adornPart)
    if not adornPart then return false end
    for oh in pairs(fusingOverheads) do
        if oh and oh.Parent then
            local tpl = oh.Parent
            if tpl and adornPart:IsDescendantOf(tpl) then return true end
            if oh.Parent == adornPart.Parent then return true end
        end
    end
    return false
end

local function getImage(name)
    if not name then return nil end
    local cleaned = name:lower():gsub(" ", "-")
    return "https://steal-a-brainrot.org/_next/image?url=%2Fimages%2Fbrainrots%2F"
        .. cleaned .. ".webp&w=3840&q=90"
end

local espObjects = {}
local function createESP(tplKey, adornPart, petName, genText, genValue, mutTag)
    if espObjects[tplKey] then return end
    local displayName = mutTag and ("["..mutTag.."] "..petName) or petName
    pcall(function()
        local col = genValue >= 100000000
            and Color3.fromRGB(220,0,0) or Color3.fromRGB(255,140,0)

        local h = Instance.new("Highlight")
        h.Adornee           = adornPart
        h.FillTransparency  = 0.4
        h.OutlineTransparency = 0
        h.FillColor         = col
        h.OutlineColor      = col
        h.Parent            = playerGui

        local bb = Instance.new("BillboardGui")
        bb.Size           = UDim2.new(0,220,0,60)
        bb.AlwaysOnTop    = true
        bb.StudsOffset    = Vector3.new(0,5,0)
        bb.Adornee        = adornPart
        bb.ResetOnSpawn   = false
        bb.Parent         = playerGui

        local l1 = Instance.new("TextLabel", bb)
        l1.Size                  = UDim2.new(1,0,0,30)
        l1.BackgroundTransparency= 1
        l1.TextScaled            = true
        l1.Font                  = Enum.Font.GothamBold
        l1.Text                  = displayName
        l1.TextColor3            = Color3.fromRGB(255,220,0)
        l1.TextStrokeTransparency= 0

        local l2 = Instance.new("TextLabel", bb)
        l2.Size                  = UDim2.new(1,0,0,30)
        l2.Position              = UDim2.new(0,0,0,30)
        l2.BackgroundTransparency= 1
        l2.TextScaled            = true
        l2.Font                  = Enum.Font.GothamBold
        l2.Text                  = genText
        l2.TextColor3            = Color3.fromRGB(0,255,100)
        l2.TextStrokeTransparency= 0

        espObjects[tplKey] = {highlight=h, billboard=bb}
    end)
end
local function removeESP(tplKey)
    local e = espObjects[tplKey]; if not e then return end
    pcall(function() e.highlight:Destroy() end)
    pcall(function() e.billboard:Destroy() end)
    espObjects[tplKey] = nil
end
local function clearAllESP()
    for k in pairs(espObjects) do removeESP(k) end
end

local duelGui = Instance.new("ScreenGui")
duelGui.Name             = "PRAGRA_DuelsESP"
duelGui.ResetOnSpawn     = false
duelGui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
duelGui.DisplayOrder     = 999999
duelGui.IgnoreGuiInset   = true
duelGui.Parent           = CoreGui

local duelESPs  = {}
local duelSetup = {}

local function clearDuelESP(pname)
    if duelESPs[pname] then
        for _, bb in ipairs(duelESPs[pname]) do pcall(function() bb:Destroy() end) end
        duelESPs[pname] = nil
    end
end
local function buildDuelESP(player, plot)
    clearDuelESP(player.Name)
    local pods = plot:FindFirstChild("AnimalPodiums"); if not pods then return end
    local ok, attr = pcall(function() return player:GetAttribute("__duels_block_steal") end)
    local inDuels = ok and attr and true or false
    local icon    = inDuels and "✗" or "✓"
    local col     = inDuels and Color3.fromRGB(255,50,50) or Color3.fromRGB(80,255,80)
    duelESPs[player.Name] = {}
    for _, pod in ipairs(pods:GetChildren()) do
        local base  = pod:FindFirstChild("Base") or pod
        local spawn = base:FindFirstChild("Spawn") or base
        local bb = Instance.new("BillboardGui")
        bb.Adornee     = spawn
        bb.AlwaysOnTop = true
        bb.Size        = UDim2.new(0,200,0,36)
        bb.StudsOffset = Vector3.new(0,4,0)
        bb.MaxDistance = math.huge
        bb.Parent      = duelGui
        local lbl = Instance.new("TextLabel", bb)
        lbl.Size                  = UDim2.new(1,0,1,0)
        lbl.BackgroundTransparency= 1
        lbl.Text                  = player.DisplayName.." "..icon
        lbl.TextColor3            = col
        lbl.TextSize              = 14
        lbl.Font                  = Enum.Font.GothamBold
        lbl.TextStrokeTransparency= 0
        lbl.TextStrokeColor3      = Color3.new(0,0,0)
        table.insert(duelESPs[player.Name], bb)
    end
end
local function setupDuelPlayer(player, plot)
    if duelSetup[player.Name] then return end
    duelSetup[player.Name] = true
    buildDuelESP(player, plot)
    player.AttributeChanged:Connect(function(a)
        if a == "__duels_block_steal" then buildDuelESP(player, plot) end
    end)
    player.AncestryChanged:Connect(function()
        if not player.Parent then
            clearDuelESP(player.Name); duelSetup[player.Name] = nil
        end
    end)
end
local function scanDuelPlots()
    local plots = workspace:FindFirstChild("Plots"); if not plots then return end
    for _, plot in ipairs(plots:GetChildren()) do
        local sign = plot:FindFirstChild("PlotSign", true); if not sign then continue end
        for _, v in ipairs(sign:GetDescendants()) do
            if v:IsA("TextLabel") then
                local nm = v.Text:match("^(.+)'s Base$")
                if nm and nm ~= "Empty" and nm ~= "" then
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p.DisplayName==nm or p.Name==nm then
                            setupDuelPlayer(p, plot); break
                        end
                    end; break
                end
            end
        end
    end
end

local ownerCache   = {}
local ownerCacheTs = {}
local function getOwner(baseIdx)
    local now = tick()
    if ownerCache[baseIdx] and (now-(ownerCacheTs[baseIdx] or 0))<15 then
        return ownerCache[baseIdx]
    end
    local b = BASES[baseIdx]
    local plots = workspace:FindFirstChild("Plots"); if not plots then return "Unknown" end
    for _, plot in ipairs(plots:GetChildren()) do
        local pods = plot:FindFirstChild("AnimalPodiums"); if not pods then continue end
        for _, pod in ipairs(pods:GetChildren()) do
            local part = pod:FindFirstChildOfClass("BasePart")
            if not part then
                for _, d in ipairs(pod:GetDescendants()) do
                    if d:IsA("BasePart") then part=d; break end
                end
            end
            if part then
                local p = part.Position
                if p.X>=b.minX-25 and p.X<=b.maxX+25 and p.Z>=b.minZ-25 and p.Z<=b.maxZ+25 then
                    local sign = plot:FindFirstChild("PlotSign", true)
                    if sign then
                        for _, v in ipairs(sign:GetDescendants()) do
                            if v:IsA("TextLabel") then
                                local nm = v.Text:match("^(.+)'s Base$")
                                if nm and nm~="Empty" and nm~="" then
                                    ownerCache[baseIdx]=nm; ownerCacheTs[baseIdx]=now
                                    return nm
                                end
                            end
                        end
                    end; break
                end
            end
        end
    end
    return "Unknown"
end
local function getDuels(ownerName)
    if not ownerName or ownerName=="Unknown" then return false end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.DisplayName==ownerName or p.Name==ownerName then
            local ok, attr = pcall(function() return p:GetAttribute("__duels_block_steal") end)
            return ok and attr and true or false
        end
    end
    return false
end

local function buildMutMap(debris)
    local map = {}
    for _, obj in ipairs(debris:GetDescendants()) do
        if obj.Name ~= "AnimalOverhead" then continue end
        local mutLabel = obj:FindFirstChild("Mutation")
        if not mutLabel or not mutLabel:IsA("TextLabel") then continue end
        local ok, vis = pcall(function() return mutLabel.Visible end)
        if not ok or not vis then continue end
        local ok2, txt = pcall(function() return mutLabel.Text end)
        if not ok2 or not txt or txt=="" then continue end
        local clean = txt:gsub("<[^>]+>",""):match("^%s*(.-)%s*$")
        if not clean or clean=="" then continue end
        local nameLabel = obj:FindFirstChild("DisplayName"); if not nameLabel then continue end
        local ok3, petName = pcall(function() return nameLabel.Text end)
        if not ok3 or not petName or petName=="" then continue end
        petName = petName:gsub("<[^>]+>",""):match("^%s*(.-)%s*$") or petName
        map[petName] = clean:upper()
    end
    return map
end

local function readSG(sg)
    local genLabel = sg:FindFirstChild("Generation", true)
    if not genLabel or not genLabel:IsA("TextLabel") then return nil end
    local genText = genLabel.Text or ""; if genText=="" then return nil end
    local genValue = parseGen(genText)
    if genValue < MIN_GEN then return nil end
    if isMachineGen(genText) then return nil end
    local nameLabel = sg:FindFirstChild("DisplayName", true)
    local petName = (nameLabel and nameLabel.Text~="" and nameLabel.Text) or "Unknown"
    petName = petName:gsub("<[^>]+>",""):match("^%s*(.-)%s*$") or petName
    if isFusing(petName) then return nil end
    if petName:lower():find("lucky") then return nil end
    return petName, genText, genValue
end

local function sendDiscord(pets, ownerName, inDuels)
    if #pets == 0 then return end
    local realPets = {}
    for _, pet in ipairs(pets) do
        if not isFusing(pet.name) then table.insert(realPets, pet) end
    end
    if #realPets == 0 then return end
    table.sort(realPets, function(a,b) return a.genValue > b.genValue end)

    local top    = realPets[1]
    local now    = os.time()
    local imgUrl = getImage(top.name:gsub("^%[.-%]%s*",""))
    local duelIcon = inDuels and "✗ En Duelos" or "✓ Libre"
    local prefix = top.mutTag and ("["..top.mutTag.."] ") or ""
    local title  = prefix..top.name.." ("..top.genText..")"

    local lines = {"Brainrots detectados"}
    for _, pet in ipairs(realPets) do
        local pre = pet.mutTag and ("["..pet.mutTag.."] ") or ""
        table.insert(lines, "• "..pre..pet.name.." ("..pet.genText..")")
    end

    local embedColor = currentMode=="hop" and 0x5DADE2 or 0x000000

    local embed = {
        color      = embedColor,
        title      = title,
        description= "```\n"..table.concat(lines,"\n").."\n```",
        fields     = {
            {name="👤 Owner", value="```\n"..(ownerName or "Unknown").."\n```", inline=true},
            {name="🤖 Bot",   value="```\n"..plr.Name.."\n```", inline=true},
            {name="⚔ Estado", value=duelIcon, inline=true},
        },
        footer     = {text="PRAGRA LOGS"},
        timestamp  = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
    }
    if imgUrl then embed.thumbnail = {url=imgUrl} end

    httpPost(WEBHOOK, {username="PRAGRA LOGS", embeds={embed}})

    sendToRelay(realPets, game.JobId, inDuels)

    print(string.format("[PRAGRA] ✓ %d pets | %s | %s | %s | relay=%s",
        #realPets, title, ownerName or "Unknown", duelIcon,
        relayConn and "✅" or "❌"))
end

local sentState = {}
local nowState  = {}

local function resetScanState()
    clearAllESP()
    sentState = {}
    nowState  = {}
end

local function scan()
    local Debris = workspace:FindFirstChild("Debris"); if not Debris then return end
    local mutMap     = buildMutMap(Debris)
    local frameState = {}

    for _, tpl in ipairs(Debris:GetChildren()) do
        if tpl.Name ~= "FastOverheadTemplate" then continue end
        local sg = tpl:FindFirstChildOfClass("SurfaceGui"); if not sg then continue end
        local adornPart = sg.Adornee; if not adornPart then continue end
        local ok, inWS = pcall(function() return adornPart:IsDescendantOf(workspace) end)
        if not ok or not inWS then continue end
        local pos; pcall(function() pos = adornPart.Position end); if not pos then continue end
        local baseIdx = getBaseIdx(pos); if not baseIdx then continue end
        local petName, genText, genValue = readSG(sg); if not petName then continue end
        if isAdornFusing(adornPart) then continue end

        local mutTag = mutMap[petName]
        local tplKey = tostring(tpl)
        if not frameState[baseIdx] then frameState[baseIdx] = {} end
        local ex = frameState[baseIdx][petName]
        if not ex or genValue > ex.genValue then
            frameState[baseIdx][petName] = {
                name=petName, genText=genText, genValue=genValue,
                mutTag=mutTag, tplKey=tplKey, adornPart=adornPart
            }
        end
        createESP(tplKey, adornPart, petName, genText, genValue, mutTag)
    end

    for baseIdx, prevNow in pairs(nowState) do
        if not frameState[baseIdx] then
            for _, pd in pairs(prevNow) do removeESP(pd.tplKey) end
            sentState[baseIdx] = nil; nowState[baseIdx] = nil
        else
            local curSent = sentState[baseIdx] or {}
            for petName, pd in pairs(prevNow) do
                if not frameState[baseIdx][petName] then
                    curSent[petName] = nil
                    removeESP(pd.tplKey)
                end
            end
            sentState[baseIdx] = curSent
        end
    end

    for baseIdx, petMap in pairs(frameState) do
        local prevSent = sentState[baseIdx] or {}
        local newPets  = {}
        for petName, pd in pairs(petMap) do
            if not prevSent[petName] then
                table.insert(newPets, pd)
                prevSent[petName] = true
            end
        end
        sentState[baseIdx] = prevSent
        nowState[baseIdx]  = petMap
        if #newPets > 0 then
            local ownerName = getOwner(baseIdx)
            local inDuels   = getDuels(ownerName)
            local allPets   = {}
            for _, pd in pairs(petMap) do table.insert(allPets, pd) end
            sendDiscord(allPets, ownerName, inDuels)
        end
    end
end

local scanConnected = false
local function ensureScanLoop()
    if scanConnected then return end
    scanConnected = true
    RunService.RenderStepped:Connect(function()
        local ok, err = pcall(scan)
        if not ok then warn("[PRAGRA] scan: "..tostring(err)) end
    end)
end

local function startNormalMode()
    resetScanState()
    ensureScanLoop()
    print("[PRAGRA] Modo NORMAL activo — escaneando servidor actual")
end

local hopGui = nil

local function destroyHopGui()
    if hopGui then pcall(function() hopGui:Destroy() end); hopGui = nil end
end

local function showHopCountdown(seconds)
    destroyHopGui()
    local gui = Instance.new("ScreenGui")
    gui.Name           = "PRAGRA_HopCountdown"
    gui.ResetOnSpawn   = false
    gui.DisplayOrder   = 9999998
    gui.IgnoreGuiInset = true
    gui.Parent         = CoreGui
    hopGui = gui

    local label = Instance.new("TextLabel", gui)
    label.Size                    = UDim2.new(0, 300, 0, 50)
    label.Position                = UDim2.new(0.5, -150, 0.4, 0)
    label.BackgroundColor3        = Color3.fromRGB(0, 0, 0)
    label.BackgroundTransparency  = 0.5
    label.TextColor3              = Color3.new(1, 1, 1)
    label.Font                    = Enum.Font.SourceSansBold
    label.TextSize                = 24
    label.Text                    = "Buscando servidor..."

    local cdLabel = Instance.new("TextLabel", gui)
    cdLabel.Size                    = UDim2.new(0, 50, 0, 30)
    cdLabel.Position                = UDim2.new(1, -60, 0, 10)
    cdLabel.BackgroundColor3        = Color3.fromRGB(0, 0, 0)
    cdLabel.BackgroundTransparency  = 0.5
    cdLabel.TextColor3              = Color3.new(1, 1, 1)
    cdLabel.Font                    = Enum.Font.SourceSansBold
    cdLabel.TextSize                = 24

    local dots = {".", "..", "...", "...."}
    local di   = 1
    local left = seconds
    while left > 0 do
        if currentMode ~= "hop" then destroyHopGui(); return false end
        label.Text   = "Buscando servidor" .. dots[di]
        cdLabel.Text = tostring(math.ceil(left))
        di = (di % #dots) + 1
        task.wait(1)
        left = left - 1
    end
    label.Text   = "Teletransportando..."
    cdLabel.Text = "0"
    return true
end

local function startHopMode()
    resetScanState()
    ensureScanLoop()

    local hopThread = task.spawn(function()
        print(string.format("[PRAGRA] Modo HOP activo | place=%s | %ds por server",
            PLACE_ID, HOP_SECONDS))

        while true do
            if currentMode ~= "hop" then break end

            local ok = showHopCountdown(HOP_SECONDS)
            if not ok then break end

            print("[PRAGRA] Saltando a servidor random...")
            local tpOk, tpErr = pcall(TeleportService.Teleport, TeleportService, game.PlaceId, plr)
            if not tpOk then
                warn("[PRAGRA] teleport falló: " .. tostring(tpErr))
                destroyHopGui()
                task.wait(5)
            end

            task.wait(5)
            destroyHopGui()
        end
        destroyHopGui()
    end)
    table.insert(activeThreads, hopThread)
end

local function applyMode(mode)
    stopAllThreads()
    currentMode = mode
    saveConfig({mode=mode})
    if mode == "hop" then
        startHopMode()
    else
        startNormalMode()
    end
    print("[PRAGRA] Modo activo: " .. mode)
end

local selectorGui = nil

local function showModeSelector(isChange)
    if selectorGui then pcall(function() selectorGui:Destroy() end) end

    local gui = Instance.new("ScreenGui")
    gui.Name           = "PRAGRA_ModeSelector"
    gui.ResetOnSpawn   = false
    gui.DisplayOrder   = 9999999
    gui.IgnoreGuiInset = true
    gui.Parent         = CoreGui
    selectorGui        = gui

    local overlay = Instance.new("Frame", gui)
    overlay.Size                 = UDim2.new(1,0,1,0)
    overlay.BackgroundColor3     = Color3.fromRGB(0,0,0)
    overlay.BackgroundTransparency = 0.45
    overlay.BorderSizePixel      = 0
    overlay.ZIndex               = 1

    local win = Instance.new("Frame", gui)
    win.Size             = UDim2.new(0,420,0,310)
    win.Position         = UDim2.new(0.5,-210,0.5,-155)
    win.BackgroundColor3 = Color3.fromRGB(10,10,18)
    win.BorderSizePixel  = 0
    win.ZIndex           = 2
    Instance.new("UICorner", win).CornerRadius = UDim.new(0,14)
    local border = Instance.new("UIStroke", win)
    border.Color       = Color3.fromRGB(255,140,0)
    border.Thickness   = 2
    border.Transparency= 0.3

    local titleL = Instance.new("TextLabel", win)
    titleL.Size                  = UDim2.new(1,0,0,48)
    titleL.BackgroundTransparency= 1
    titleL.Text                  = isChange and "⚙  CAMBIAR MODO" or "⚡  PRAGRA LOGS"
    titleL.TextColor3            = Color3.fromRGB(255,200,60)
    titleL.Font                  = Enum.Font.GothamBold
    titleL.TextSize              = 22
    titleL.ZIndex                = 3

    local sub = Instance.new("TextLabel", win)
    sub.Size                  = UDim2.new(1,-40,0,28)
    sub.Position              = UDim2.new(0,20,0,46)
    sub.BackgroundTransparency= 1
    sub.Text = isChange
        and ("Modo actual:  "..(currentMode=="hop" and "🚀 Server Hop" or "🔍 Normal"))
        or  "Elige cómo quieres ejecutar el detector"
    sub.TextColor3            = Color3.fromRGB(180,180,200)
    sub.Font                  = Enum.Font.Gotham
    sub.TextSize              = 14
    sub.ZIndex                = 3

    local sep = Instance.new("Frame", win)
    sep.Size            = UDim2.new(1,-40,0,1)
    sep.Position        = UDim2.new(0,20,0,80)
    sep.BackgroundColor3= Color3.fromRGB(60,60,80)
    sep.BorderSizePixel = 0
    sep.ZIndex          = 3

    local function makeCard(parent, yPos, icon, label, desc, accentColor, callback)
        local card = Instance.new("Frame", parent)
        card.Size            = UDim2.new(1,-40,0,82)
        card.Position        = UDim2.new(0,20,0,yPos)
        card.BackgroundColor3= Color3.fromRGB(18,18,30)
        card.BorderSizePixel = 0
        card.ZIndex          = 3
        Instance.new("UICorner", card).CornerRadius = UDim.new(0,10)
        local cs = Instance.new("UIStroke", card)
        cs.Color       = accentColor
        cs.Thickness   = 1.5
        cs.Transparency= 0.6

        local iconL = Instance.new("TextLabel", card)
        iconL.Size                  = UDim2.new(0,50,1,0)
        iconL.Position              = UDim2.new(0,8,0,0)
        iconL.BackgroundTransparency= 1
        iconL.Text                  = icon
        iconL.TextSize              = 28
        iconL.Font                  = Enum.Font.GothamBold
        iconL.TextColor3            = accentColor
        iconL.ZIndex                = 4

        local lblL = Instance.new("TextLabel", card)
        lblL.Size                  = UDim2.new(1,-130,0,26)
        lblL.Position              = UDim2.new(0,62,0,14)
        lblL.BackgroundTransparency= 1
        lblL.Text                  = label
        lblL.TextColor3            = Color3.fromRGB(255,255,255)
        lblL.Font                  = Enum.Font.GothamBold
        lblL.TextSize              = 16
        lblL.TextXAlignment        = Enum.TextXAlignment.Left
        lblL.ZIndex                = 4

        local descL = Instance.new("TextLabel", card)
        descL.Size                  = UDim2.new(1,-130,0,32)
        descL.Position              = UDim2.new(0,62,0,40)
        descL.BackgroundTransparency= 1
        descL.Text                  = desc
        descL.TextColor3            = Color3.fromRGB(150,150,170)
        descL.Font                  = Enum.Font.Gotham
        descL.TextSize              = 12
        descL.TextXAlignment        = Enum.TextXAlignment.Left
        descL.TextWrapped           = true
        descL.ZIndex                = 4

        local btn = Instance.new("TextButton", card)
        btn.Size            = UDim2.new(0,72,0,34)
        btn.Position        = UDim2.new(1,-82,0.5,-17)
        btn.BackgroundColor3= accentColor
        btn.BorderSizePixel = 0
        btn.Text            = "ELEGIR"
        btn.TextColor3      = Color3.fromRGB(10,10,18)
        btn.Font            = Enum.Font.GothamBold
        btn.TextSize        = 13
        btn.ZIndex          = 5
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,8)

        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.15), {
                BackgroundColor3 = Color3.fromRGB(
                    math.min(accentColor.R*255+40,255),
                    math.min(accentColor.G*255+40,255),
                    math.min(accentColor.B*255+40,255))
            }):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3=accentColor}):Play()
        end)
        btn.MouseButton1Click:Connect(function()
            pcall(function() gui:Destroy() end)
            selectorGui = nil
            callback()
        end)
        card.MouseEnter:Connect(function()
            TweenService:Create(cs, TweenInfo.new(0.15), {Transparency=0}):Play()
        end)
        card.MouseLeave:Connect(function()
            TweenService:Create(cs, TweenInfo.new(0.15), {Transparency=0.6}):Play()
        end)
    end

    makeCard(win, 96,
        "🚀", "Server Hop",
        "Salta entre servidores automáticamente\nbuscando brainrots",
        Color3.fromRGB(255,140,0),
        function() applyMode("hop") end)

    makeCard(win, 192,
        "🔍", "Normal",
        "Escanea el servidor actual sin saltar.\nReenvía si el pet desaparece y vuelve.",
        Color3.fromRGB(0,200,120),
        function() applyMode("normal") end)

    win.Position             = UDim2.new(0.5,-210,0.5,-185)
    win.BackgroundTransparency = 1
    TweenService:Create(win, TweenInfo.new(0.3,Enum.EasingStyle.Back,Enum.EasingDirection.Out), {
        Position             = UDim2.new(0.5,-210,0.5,-155),
        BackgroundTransparency = 0
    }):Play()
end

local function createPersistentBtn()
    local ex = CoreGui:FindFirstChild("PRAGRA_PersistentBtn")
    if ex then ex:Destroy() end

    local g = Instance.new("ScreenGui", CoreGui)
    g.Name           = "PRAGRA_PersistentBtn"
    g.ResetOnSpawn   = false
    g.DisplayOrder   = 9999998

    local btn = Instance.new("TextButton", g)
    btn.Size            = UDim2.new(0,140,0,34)
    btn.Position        = UDim2.new(1,-150,0,10)
    btn.BackgroundColor3= Color3.fromRGB(10,10,18)
    btn.BorderSizePixel = 0
    btn.ZIndex          = 2
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,8)
    local stroke = Instance.new("UIStroke", btn)
    stroke.Color       = Color3.fromRGB(255,140,0)
    stroke.Thickness   = 1.5
    stroke.Transparency= 0.3

    local function updateBtnText()
        local relayIcon = (relayConn and relayWS) and " 🟢" or " 🔴"
        btn.Text = "⚙  "..(currentMode=="hop" and "🚀 Hop" or "🔍 Normal")..relayIcon
    end
    updateBtnText()
    btn.TextColor3 = Color3.fromRGB(255,200,60)
    btn.Font       = Enum.Font.GothamBold
    btn.TextSize   = 12

    btn.MouseEnter:Connect(function()
        TweenService:Create(stroke,TweenInfo.new(0.15),{Transparency=0}):Play()
        TweenService:Create(btn,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(20,20,35)}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(stroke,TweenInfo.new(0.15),{Transparency=0.3}):Play()
        TweenService:Create(btn,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(10,10,18)}):Play()
    end)
    btn.MouseButton1Click:Connect(function()
        updateBtnText(); showModeSelector(true)
    end)

    task.spawn(function()
        while g.Parent do
            task.wait(2); pcall(updateBtnText)
        end
    end)
end

task.spawn(function()
    task.wait(2); scanDuelPlots()
    Players.PlayerAdded:Connect(function() task.wait(4); scanDuelPlots() end)
    Players.PlayerRemoving:Connect(function(p)
        clearDuelESP(p.Name); duelSetup[p.Name] = nil
    end)
    while task.wait(3) do scanDuelPlots() end
end)

task.spawn(function()
    while task.wait(0.5) do
        local ok, err = pcall(scanFusing)
        if not ok then warn("[PRAGRA] scanFusing: "..tostring(err)) end
    end
end)

createPersistentBtn()

local savedCfg = loadConfig()
if savedCfg and (savedCfg.mode=="hop" or savedCfg.mode=="normal") then
    print("[PRAGRA] Config encontrada: modo=" .. savedCfg.mode)
    applyMode(savedCfg.mode)
else
    print("[PRAGRA] Primera ejecución — mostrando selector de modo")
    showModeSelector(false)
end