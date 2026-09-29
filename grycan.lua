local players = game:GetService("Players")
local httpService = game:GetService("HttpService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local userInput = game:GetService("UserInputService")
local textChat = game:GetService("TextChatService")
local virtualUser = game:GetService("VirtualUser")
local runService = game:GetService("RunService")
local tweenService = game:GetService("TweenService")
local localPlayer = players.LocalPlayer

if _G.__grycan_loaded then
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if pg then
        local old = pg:FindFirstChild("grycan")
        if old then old:Destroy() end
    end
    _G.__grycan_loaded = false
    _G.__grycan_unload = nil
end
_G.__grycan_loaded = true

local http = (syn and syn.request) or (http and http.request) or http_request or request
if not http then _G.__grycan_loaded = false warn("no http executor") return end

local VERSION = "v0.1 beta"

local iconId = "rbxthumb://type=Asset&id=79985085633622&w=150&h=150"
local discordLink = "https://discord.gg/3MpTfDpSZ6"
local promptFile = "grycan_prompt.txt"
local instructionsFile = "grycan_instructions.txt"

local providers = {
    {id="lmstudio", name="lm studio", base="http://127.0.0.1:1234", needsKey=false, style="openai"},
    {id="openai",   name="openai",    base="https://api.openai.com", needsKey=true, style="openai"},
    {id="deepseek", name="deepseek",  base="https://api.deepseek.com", needsKey=true, style="openai"},
    {id="grok",     name="grok",      base="https://api.x.ai", needsKey=true, style="openai"},
    {id="gemini",   name="gemini",    base="https://generativelanguage.googleapis.com", needsKey=true, style="gemini"},
}

local currentProviderIdx = 1
local savedKeys = {lmstudio="lm-studio", openai="", deepseek="", grok="", gemini=""}
local activeKey = savedKeys.lmstudio

local modelName = ""
local enabled = true
local radius = 12
local queueDelay = 1.5
local camBehind = 6
local camHeight = 2
local camSmooth = 0.15

local defaultPrompt = "you are grycan, an ai assistant hanging out in this roblox game. you chat casually with nearby players. short, friendly, a little playful - like texting a friend. you're open about being an ai if asked, but you don't make it your whole personality. max 1-2 sentences. no emojis."
local defaultInstructions = ""

local customPrompt = defaultPrompt
local customInstructions = defaultInstructions

local function loadFromDisk(path, fallback)
    if not readfile then return fallback end
    local ok, data = pcall(function() return readfile(path) end)
    if ok and data and data ~= "" then return data end
    return fallback
end

local function saveToDisk(path, text)
    if not writefile then return end
    pcall(function() writefile(path, text) end)
end

customPrompt = loadFromDisk(promptFile, defaultPrompt)
customInstructions = loadFromDisk(instructionsFile, defaultInstructions)

local memory = {}
local currentTarget
local camConn
local queue = {}
local processing = false
local antiAfkOn = true
local chatLines = {}
local modelList = {}
local connections = {}
local unloaded = false
local sayToChat = false
local targetScale = 1
local currentScale = 1
local scaleVelocity = 0
local currentThemeIdx = 1

local U = {}
local accentListeners = {}

local function track(c) table.insert(connections, c) return c end
local function clamp(n, a, b) return math.max(a, math.min(b, n)) end

local function logChat(speaker, text, kind)
    if unloaded then return end
    kind = kind or "player"
    local prefix = "   "
    if kind == "ai" then prefix = "›  "
    elseif kind == "sys" then prefix = "·  "
    elseif kind == "test" then prefix = "◇  " end
    table.insert(chatLines, prefix .. speaker .. ": " .. text)
    if #chatLines > 100 then table.remove(chatLines, 1) end
    if U.chatLabel then U.chatLabel.Text = table.concat(chatLines, "\n") end
end

track(localPlayer.Idled:Connect(function()
    if not antiAfkOn or unloaded then return end
    virtualUser:CaptureController()
    virtualUser:ClickButton2(Vector2.new())
end))

local isLegacy = false
local legacySay, legacyDone
local chatEvents = replicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
if chatEvents then
    legacySay = chatEvents:FindFirstChild("SayMessageRequest")
    legacyDone = chatEvents:FindFirstChild("OnMessageDoneFiltering")
    if legacySay and legacyDone then isLegacy = true end
end

local function nearby(p)
    local a, b = localPlayer.Character, p.Character
    if not a or not b then return false end
    local x = a:FindFirstChild("HumanoidRootPart")
    local y = b:FindFirstChild("HumanoidRootPart")
    if not x or not y then return false end
    return (x.Position - y.Position).Magnitude <= radius
end

local function say(text)
    if unloaded then return end
    if isLegacy and legacySay then
        pcall(function() legacySay:FireServer(text, "All") end)
    else
        local ch = textChat:FindFirstChild("TextChannels")
        local gen = ch and ch:FindFirstChild("RBXGeneral")
        if gen then pcall(function() gen:SendAsync(text) end) end
    end
    logChat("grycan", text, "ai")
end

local function buildSystemPrompt()
    local out = customPrompt
    if customInstructions and customInstructions ~= "" then
        out = out .. "\n\nadditional instructions:\n" .. customInstructions
    end
    return out
end

local function askAI(speaker, message)
    if unloaded or modelName == "" then return nil end
    local p = providers[currentProviderIdx]
    local ctx = memory[speaker] or {}
    table.insert(ctx, {role="user", content=speaker .. ": " .. message})
    memory[speaker] = ctx

    local sys = buildSystemPrompt()
    local headers = {["Content-Type"]="application/json", ["Accept"]="application/json"}
    local url, body

    if p.style == "openai" then
        if p.needsKey and activeKey ~= "" then headers["Authorization"] = "Bearer " .. activeKey end
        url = p.base .. "/v1/chat/completions"
        local msgs = {{role="system", content=sys}}
        for _, m in ipairs(ctx) do table.insert(msgs, {role=m.role, content=m.content}) end
        body = {model=modelName, messages=msgs, max_tokens=100, temperature=0.9}
    elseif p.style == "gemini" then
        url = p.base .. "/v1beta/models/" .. modelName .. ":generateContent?key=" .. activeKey
        local contents = {}
        for _, m in ipairs(ctx) do
            local role = (m.role == "assistant") and "model" or "user"
            table.insert(contents, {role=role, parts={{text=m.content}}})
        end
        body = {
            contents = contents,
            systemInstruction = {parts={{text=sys}}},
            generationConfig = {maxOutputTokens=100, temperature=0.9},
        }
    else
        return nil
    end

    local t0 = os.clock()
    local ok, res = pcall(function()
        return http({Url=url, Method="POST", Headers=headers, Body=httpService:JSONEncode(body)})
    end)
    local ms = math.floor((os.clock() - t0) * 1000)
    if U.latencyLabel then
        U.latencyLabel.Text = ms .. " ms"
        if ms < 400 then U.latencyLabel.TextColor3 = Color3.fromRGB(150, 220, 175)
        elseif ms < 1500 then U.latencyLabel.TextColor3 = Color3.fromRGB(235, 205, 130)
        else U.latencyLabel.TextColor3 = Color3.fromRGB(240, 150, 158) end
    end

    if not ok or not res or res.StatusCode ~= 200 then return nil end
    local ok2, data = pcall(function() return httpService:JSONDecode(res.Body) end)
    if not ok2 then return nil end

    local reply
    if p.style == "openai" then
        if data.choices and data.choices[1] and data.choices[1].message then
            reply = data.choices[1].message.content
        end
    elseif p.style == "gemini" then
        if data.candidates and data.candidates[1] and data.candidates[1].content
           and data.candidates[1].content.parts and data.candidates[1].content.parts[1] then
            reply = data.candidates[1].content.parts[1].text
        end
    end

    if not reply or reply == "" then return nil end
    reply = reply:gsub("^%s+", ""):gsub("%s+$", "")
    table.insert(memory[speaker], {role="assistant", content=reply})
    return reply
end

local function handleChat(speaker, message)
    if unloaded or not enabled then return end
    if speaker == localPlayer.Name or speaker == "" or message == "" then return end
    local p = players:FindFirstChild(speaker)
    if not p or not nearby(p) then return end
    logChat(speaker, message, "player")
    currentTarget = p
    table.insert(queue, {name = speaker, message = message, player = p})
    if not processing then
        processing = true
        task.spawn(function()
            while #queue > 0 and not unloaded do
                local item = table.remove(queue, 1)
                currentTarget = item.player
                local r = askAI(item.name, item.message)
                if r then say(r) end
                task.wait(queueDelay)
            end
            processing = false
        end)
    end
end

if isLegacy and legacyDone then
    track(legacyDone.OnClientEvent:Connect(function(d) handleChat(d.FromSpeaker, d.Message) end))
else
    track(textChat.MessageReceived:Connect(function(m)
        local ts = m.TextSource
        if not ts then return end
        local p = players:GetPlayerByUserId(ts.UserId)
        if p then handleChat(p.Name, m.Text) end
    end))
end

local function updateCam()
    if unloaded then return end
    local mine = localPlayer.Character
    local hrp = mine and mine:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local cam = workspace.CurrentCamera
    local dir = hrp.CFrame.LookVector
    if currentTarget and currentTarget.Character then
        local th = currentTarget.Character:FindFirstChild("HumanoidRootPart")
        if th then dir = (th.Position - hrp.Position).Unit end
    end
    local behind = hrp.Position - dir * camBehind + Vector3.new(0, camHeight, 0)
    cam.CameraType = Enum.CameraType.Scriptable
    cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(behind, hrp.Position + dir * 10), camSmooth)
end

local function setCam(on)
    if on then
        if not camConn then camConn = track(runService.RenderStepped:Connect(updateCam)) end
    else
        if camConn then camConn:Disconnect(); camConn = nil end
        workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
    end
end

local function lerpNumberSeq(a, b, t)
    local out = {}
    local kpsA, kpsB = a.Keypoints, b.Keypoints
    local n = math.min(#kpsA, #kpsB)
    for i = 1, n do
        local ka, kb = kpsA[i], kpsB[i]
        table.insert(out, NumberSequenceKeypoint.new(
            ka.Time,
            ka.Value + (kb.Value - ka.Value) * t,
            ka.Envelope + (kb.Envelope - ka.Envelope) * t
        ))
    end
    return NumberSequence.new(out)
end

local function lerpColorSeq(a, b, t)
    local out = {}
    local kpsA, kpsB = a.Keypoints, b.Keypoints
    local n = math.min(#kpsA, #kpsB)
    for i = 1, n do
        local ka, kb = kpsA[i], kpsB[i]
        table.insert(out, ColorSequenceKeypoint.new(ka.Time, ka.Value:Lerp(kb.Value, t)))
    end
    return ColorSequence.new(out)
end

local function tweenNumSeq(obj, target, dur)
    task.spawn(function()
        local startSeq = obj.Transparency
        local steps = math.max(6, math.floor(dur * 40))
        for i = 1, steps do
            if unloaded or not obj.Parent then return end
            local t = i / steps
            local et = 1 - math.pow(1 - t, 3)
            obj.Transparency = lerpNumberSeq(startSeq, target, et)
            task.wait(dur / steps)
        end
        if not unloaded and obj.Parent then obj.Transparency = target end
    end)
end

local function tweenColorSeq(obj, target, dur)
    task.spawn(function()
        local startSeq = obj.Color
        local steps = math.max(8, math.floor(dur * 40))
        for i = 1, steps do
            if unloaded or not obj.Parent then return end
            local t = i / steps
            local et = 1 - math.pow(1 - t, 3)
            obj.Color = lerpColorSeq(startSeq, target, et)
            task.wait(dur / steps)
        end
        if not unloaded and obj.Parent then obj.Color = target end
    end)
end

-- bulletproof tw: routes UIGradient Color/Transparency to manual sequence tweeners
local function tw(o, p, t, style, dir)
    if o:IsA("UIGradient") then
        if p.Color ~= nil then tweenColorSeq(o, p.Color, t or 0.24) end
        if p.Transparency ~= nil then tweenNumSeq(o, p.Transparency, t or 0.24) end
        local rest = {}
        for k, v in pairs(p) do
            if k ~= "Color" and k ~= "Transparency" then rest[k] = v end
        end
        if next(rest) then
            local t2 = tweenService:Create(o, TweenInfo.new(t or 0.24, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), rest)
            t2:Play()
            return t2
        end
        return nil
    end
    local t2 = tweenService:Create(o, TweenInfo.new(t or 0.24, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), p)
    t2:Play()
    return t2
end

local function draggable(frame, handle)
    handle = handle or frame
    local drag, start, orig
    track(handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            drag, start, orig = true, i.Position, frame.Position
        end
    end))
    track(handle.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = false end
    end))
    track(userInput.InputChanged:Connect(function(i)
        if not drag then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - start
            frame.Position = UDim2.new(orig.X.Scale, orig.X.Offset + d.X, orig.Y.Scale, orig.Y.Offset + d.Y)
        end
    end))
end

local C = {
    text     = Color3.fromRGB(242, 244, 250),
    textMid  = Color3.fromRGB(168, 172, 188),
    textDim  = Color3.fromRGB(118, 122, 140),
    accent   = Color3.fromRGB(120, 170, 245),
    accentHi = Color3.fromRGB(155, 200, 255),
    green    = Color3.fromRGB(130, 220, 165),
    yellow   = Color3.fromRGB(240, 205, 120),
    red      = Color3.fromRGB(240, 130, 140),
}

local themes = {
    {name="midnight", c1=Color3.fromRGB(52,68,130),  c2=Color3.fromRGB(20,28,55),  c3=Color3.fromRGB(65,45,110),  accent=Color3.fromRGB(120,170,245), accentHi=Color3.fromRGB(155,200,255)},
    {name="emerald",  c1=Color3.fromRGB(36,100,90),  c2=Color3.fromRGB(18,40,42),  c3=Color3.fromRGB(45,80,75),   accent=Color3.fromRGB(105,200,155), accentHi=Color3.fromRGB(140,225,180)},
    {name="crimson",  c1=Color3.fromRGB(130,45,55),  c2=Color3.fromRGB(45,20,28),  c3=Color3.fromRGB(100,40,75),  accent=Color3.fromRGB(220,110,120), accentHi=Color3.fromRGB(245,145,155)},
    {name="sunset",   c1=Color3.fromRGB(140,70,45),  c2=Color3.fromRGB(60,32,40),  c3=Color3.fromRGB(120,55,90),  accent=Color3.fromRGB(230,160,90),  accentHi=Color3.fromRGB(250,190,120)},
    {name="violet",   c1=Color3.fromRGB(95,55,155),  c2=Color3.fromRGB(38,25,65),  c3=Color3.fromRGB(120,55,130), accent=Color3.fromRGB(170,130,235), accentHi=Color3.fromRGB(195,160,255)},
    {name="mono",     c1=Color3.fromRGB(75,75,82),   c2=Color3.fromRGB(38,38,42),  c3=Color3.fromRGB(58,58,65),   accent=Color3.fromRGB(180,185,200), accentHi=Color3.fromRGB(210,215,230)},
}

local WIN_W, WIN_H = 460, 580
local HEADER_H = 58
local TABS_H = 36
local MIN_W, MIN_H = 340, 320

local gui = Instance.new("ScreenGui")
gui.Name = "grycan"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = localPlayer:WaitForChild("PlayerGui")

local function registerAccent(obj, prop, use)
    table.insert(accentListeners, {obj = obj, prop = prop, use = use})
end

local function applyAccentToAll()
    local t = themes[currentThemeIdx]
    for _, listener in ipairs(accentListeners) do
        if listener.obj and listener.obj.Parent then
            if listener.use == "grad" then
                tweenColorSeq(listener.obj, ColorSequence.new(t.accentHi, t.accent), 0.6)
            else
                local target = (listener.use == "hi") and t.accentHi or t.accent
                tweenService:Create(listener.obj, TweenInfo.new(0.6, Enum.EasingStyle.Quart), {[listener.prop] = target}):Play()
            end
        end
    end
end

local function glassSurface(parent, order)
    local f = Instance.new("Frame", parent)
    f.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    f.BackgroundTransparency = 0.9
    f.BorderSizePixel = 0
    f.ZIndex = 5
    if order then f.LayoutOrder = order end
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 12)
    local grad = Instance.new("UIGradient", f)
    grad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(0.6, Color3.fromRGB(230, 232, 240)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 205, 218)),
    })
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.86),
        NumberSequenceKeypoint.new(1, 0.94),
    })
    grad.Rotation = 90
    local stroke = Instance.new("UIStroke", f)
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Thickness = 1
    local sg = Instance.new("UIGradient", stroke)
    sg.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 210, 230)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 148, 168)),
    })
    sg.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.4),
        NumberSequenceKeypoint.new(0.5, 0.68),
        NumberSequenceKeypoint.new(1, 0.85),
    })
    sg.Rotation = 90
    local spec = Instance.new("Frame", f)
    spec.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    spec.BackgroundTransparency = 1
    spec.BorderSizePixel = 0
    spec.Size = UDim2.new(1, -20, 0, 1)
    spec.Position = UDim2.new(0, 10, 0, 0)
    spec.ZIndex = 6
    local specGrad = Instance.new("UIGradient", spec)
    specGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, 0.55),
        NumberSequenceKeypoint.new(1, 1),
    })
    spec.Name = "_specular"
    return f
end

local function glassButton(parent, height, order)
    local b = Instance.new("TextButton", parent)
    b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    b.BackgroundTransparency = 0.88
    b.BorderSizePixel = 0
    b.Size = UDim2.new(1, 0, 0, height or 44)
    b.Text = ""
    b.AutoButtonColor = false
    b.ZIndex = 5
    if order then b.LayoutOrder = order end
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
    local grad = Instance.new("UIGradient", b)
    grad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 214, 226)),
    })
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.85),
        NumberSequenceKeypoint.new(1, 0.93),
    })
    grad.Rotation = 90
    local stroke = Instance.new("UIStroke", b)
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Thickness = 1
    local sGrad = Instance.new("UIGradient", stroke)
    sGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 158, 178)),
    })
    sGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.5),
        NumberSequenceKeypoint.new(1, 0.82),
    })
    sGrad.Rotation = 90
    track(b.MouseEnter:Connect(function()
        if b:GetAttribute("pressed") then return end
        tweenNumSeq(grad, NumberSequence.new({NumberSequenceKeypoint.new(0, 0.78), NumberSequenceKeypoint.new(1, 0.88)}), 0.22)
        tweenNumSeq(sGrad, NumberSequence.new({NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0.7)}), 0.22)
    end))
    track(b.MouseLeave:Connect(function()
        b:SetAttribute("pressed", false)
        tweenNumSeq(grad, NumberSequence.new({NumberSequenceKeypoint.new(0, 0.85), NumberSequenceKeypoint.new(1, 0.93)}), 0.26)
        tweenNumSeq(sGrad, NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0.82)}), 0.26)
    end))
    track(b.MouseButton1Down:Connect(function()
        b:SetAttribute("pressed", true)
        tweenNumSeq(grad, NumberSequence.new({NumberSequenceKeypoint.new(0, 0.72), NumberSequenceKeypoint.new(1, 0.84)}), 0.1)
    end))
    track(b.MouseButton1Up:Connect(function()
        b:SetAttribute("pressed", false)
        tweenNumSeq(grad, NumberSequence.new({NumberSequenceKeypoint.new(0, 0.78), NumberSequenceKeypoint.new(1, 0.88)}), 0.14)
    end))
    return b
end

local function applyTheme(idx)
    if unloaded then return end
    currentThemeIdx = idx
    local t = themes[idx]
    task.spawn(function()
        local prev = themes[(idx - 2) % #themes + 1]
        for s = 1, 24 do
            if unloaded then break end
            local p = s / 24
            local ep = 1 - math.pow(1 - p, 3)
            local c1 = prev.c1:Lerp(t.c1, ep)
            local c2 = prev.c2:Lerp(t.c2, ep)
            local c3 = prev.c3:Lerp(t.c3, ep)
            U.bgGrad.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0.0, c1),
                ColorSequenceKeypoint.new(0.5, c2),
                ColorSequenceKeypoint.new(1.0, c3),
            })
            task.wait(0.03)
        end
    end)
    if U.orb1 then tweenService:Create(U.orb1, TweenInfo.new(0.9, Enum.EasingStyle.Quart), {BackgroundColor3 = t.c1}):Play() end
    if U.orb2 then tweenService:Create(U.orb2, TweenInfo.new(0.9, Enum.EasingStyle.Quart), {BackgroundColor3 = t.c3}):Play() end
    if U.orb3 then tweenService:Create(U.orb3, TweenInfo.new(0.9, Enum.EasingStyle.Quart), {BackgroundColor3 = t.c2}):Play() end
    if U.themeLabel then U.themeLabel.Text = "theme · " .. t.name end
    applyAccentToAll()
end

local function setStatus(state, txt)
    if not U.statusDot then return end
    local col = C.red
    local label, lc = txt or "offline", C.red
    if state == "ok" then col = C.green; label, lc = "online", C.green
    elseif state == "loading" then col = C.yellow; label, lc = "loading", C.yellow end
    tw(U.statusDot, {BackgroundColor3 = col}, 0.36, Enum.EasingStyle.Quart)
    tw(U.statusText, {TextColor3 = lc}, 0.36, Enum.EasingStyle.Quart)
    if U.statusRing then tw(U.statusRing, {Color = col}, 0.36, Enum.EasingStyle.Quart) end
    U.statusText.Text = label
    if U.pillDot then U.pillDot.BackgroundColor3 = col end
end

local function clearModels()
    if not U.modelListFrame then return end
    for _, c in ipairs(U.modelListFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end
end

local function makeSpinner(parent, size, color)
    local wrap = Instance.new("Frame", parent)
    wrap.BackgroundTransparency = 1
    wrap.Size = UDim2.new(0, size, 0, size)
    wrap.ZIndex = 8
    wrap.Name = "_spinner"

    local ring = Instance.new("Frame", wrap)
    ring.BackgroundTransparency = 1
    ring.Size = UDim2.new(1, 0, 1, 0)
    ring.ZIndex = 8

    local dot = Instance.new("Frame", ring)
    dot.BackgroundColor3 = color
    dot.BorderSizePixel = 0
    dot.Size = UDim2.new(0, math.floor(size * 0.18), 0, math.floor(size * 0.18))
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.ZIndex = 9
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    local function step(angle)
        if unloaded or not wrap.Parent then return end
        local r = (size - dot.AbsoluteSize.X) * 0.5
        local rad = math.rad(angle)
        dot.Position = UDim2.new(0.5, math.cos(rad) * r, 0.5, math.sin(rad) * r)
    end

    task.spawn(function()
        local a = 0
        while not unloaded and wrap.Parent do
            step(a)
            a = a + 18
            task.wait(0.03)
        end
    end)

    return wrap
end

local function buildEmptyState(opts)
    clearModels()
    local frame = U.modelListFrame

    local card = Instance.new("Frame", frame)
    card.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    card.BackgroundTransparency = 0.93
    card.BorderSizePixel = 0
    card.Size = UDim2.new(1, 0, 0, 152)
    card.LayoutOrder = 1
    card.ZIndex = 6
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)
    local st = Instance.new("UIStroke", card)
    st.Color = Color3.fromRGB(255, 255, 255)
    st.Thickness = 1
    st.Transparency = 0.7
    local grad = Instance.new("UIGradient", card)
    grad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.88),
        NumberSequenceKeypoint.new(1, 0.95),
    })
    grad.Rotation = 90

    local iconHolder = Instance.new("Frame", card)
    iconHolder.BackgroundTransparency = 1
    iconHolder.Size = UDim2.new(0, 40, 0, 40)
    iconHolder.Position = UDim2.new(0.5, -20, 0, 16)
    iconHolder.ZIndex = 7
    Instance.new("UICorner", iconHolder).CornerRadius = UDim.new(1, 0)

    local iconBg = Instance.new("Frame", iconHolder)
    iconBg.BackgroundColor3 = opts.iconColor or C.textDim
    iconBg.BackgroundTransparency = 0.82
    iconBg.BorderSizePixel = 0
    iconBg.Size = UDim2.new(1, 0, 1, 0)
    iconBg.ZIndex = 7
    Instance.new("UICorner", iconBg).CornerRadius = UDim.new(1, 0)

    if opts.loading then
        makeSpinner(iconBg, 40, opts.iconColor or C.accent)
    else
        local glyph = Instance.new("TextLabel", iconBg)
        glyph.BackgroundTransparency = 1
        glyph.Size = UDim2.new(1, 0, 1, 0)
        glyph.Font = Enum.Font.GothamBold
        glyph.TextSize = 20
        glyph.TextColor3 = opts.iconColor or C.textDim
        glyph.Text = opts.icon or "!"
        glyph.ZIndex = 9
    end

    local titleL = Instance.new("TextLabel", card)
    titleL.BackgroundTransparency = 1
    titleL.Size = UDim2.new(1, -32, 0, 18)
    titleL.Position = UDim2.new(0, 16, 0, 66)
    titleL.Font = Enum.Font.GothamBold
    titleL.TextSize = 12
    titleL.TextColor3 = opts.titleColor or C.text
    titleL.Text = opts.title or "no models found"
    titleL.ZIndex = 7

    local subL = Instance.new("TextLabel", card)
    subL.BackgroundTransparency = 1
    subL.Size = UDim2.new(1, -32, 0, 14)
    subL.Position = UDim2.new(0, 16, 0, 86)
    subL.Font = Enum.Font.Gotham
    subL.TextSize = 10
    subL.TextColor3 = C.textMid
    subL.Text = opts.subtitle or ""
    subL.TextWrapped = true
    subL.ZIndex = 7

    if opts.actionText and opts.actionCb then
        local btn = Instance.new("TextButton", card)
        btn.BackgroundColor3 = opts.actionColor or C.accent
        btn.BorderSizePixel = 0
        btn.Size = UDim2.new(1, -32, 0, 28)
        btn.Position = UDim2.new(0, 16, 1, -38)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Text = opts.actionText
        btn.AutoButtonColor = false
        btn.ZIndex = 7
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
        local bg = Instance.new("UIGradient", btn)
        bg.Color = ColorSequence.new(opts.actionColor or C.accentHi, opts.actionColor or C.accent)
        bg.Rotation = 90
        local bs = Instance.new("UIStroke", btn)
        bs.Color = Color3.fromRGB(255, 255, 255)
        bs.Thickness = 1
        bs.Transparency = 0.55

        track(btn.MouseEnter:Connect(function()
            tw(btn, {BackgroundTransparency = 0.15}, 0.16)
            tweenService:Create(bs, TweenInfo.new(0.16), {Transparency = 0.35}):Play()
        end))
        track(btn.MouseLeave:Connect(function()
            tw(btn, {BackgroundTransparency = 0}, 0.2)
            tweenService:Create(bs, TweenInfo.new(0.2), {Transparency = 0.55}):Play()
        end))
        track(btn.MouseButton1Click:Connect(function()
            if unloaded then return end
            opts.actionCb()
        end))
    end

    card.BackgroundTransparency = 1
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(1, 1),
    })
    tweenNumSeq(grad, NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.88),
        NumberSequenceKeypoint.new(1, 0.95),
    }), 0.35)
    st.Transparency = 1
    tweenService:Create(st, TweenInfo.new(0.35, Enum.EasingStyle.Quart), {Transparency = 0.7}):Play()

    return card
end

local function loadModelAsync(id, cb)
    if providers[currentProviderIdx].id ~= "lmstudio" then
        return false, "loading is lm-studio only"
    end
    local h = {["Content-Type"]="application/json", ["Accept"]="application/json"}
    if activeKey ~= "" then h["Authorization"] = "Bearer " .. activeKey end
    if cb then cb(0) end
    local ok, res = pcall(function()
        return http({Url="http://127.0.0.1:1234/api/v0/models/load", Method="POST", Headers=h, Body=httpService:JSONEncode({model=id})})
    end)
    if unloaded then return false, "unloaded" end
    if not ok or not res then return false, "no response" end
    if res.StatusCode ~= 200 and res.StatusCode ~= 201 then return false, "http " .. res.StatusCode end
    if cb then cb(5) end
    local attempts = 0
    while attempts < 40 and not unloaded do
        task.wait(0.75)
        attempts = attempts + 1
        local pct = math.min(5 + math.floor((attempts / 40) * 90), 95)
        if cb then cb(pct) end
        local ok2, res2 = pcall(function()
            return http({Url="http://127.0.0.1:1234/api/v0/models", Method="GET", Headers={["Accept"]="application/json"}})
        end)
        if ok2 and res2 and res2.StatusCode == 200 then
            local okD, data = pcall(function() return httpService:JSONDecode(res2.Body) end)
            if okD and data and data.data then
                for _, m in ipairs(data.data) do
                    if m.id == id and m.state == "loaded" then
                        if cb then cb(100) end
                        return true, "loaded"
                    end
                end
            end
        end
    end
    if unloaded then return false, "unloaded" end
    return false, "timeout"
end

local function renderModels(list)
    clearModels()
    modelList = list or {}
    local frame = U.modelListFrame
    if #modelList == 0 then return end

    for i, entry in ipairs(modelList) do
        local id = entry.id
        local loaded = entry.loaded
        local isActive = (id == modelName)
        local b = Instance.new("TextButton", frame)
        b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        b.BackgroundTransparency = isActive and 0.78 or 0.88
        b.BorderSizePixel = 0
        b.Size = UDim2.new(1, 0, 0, 42)
        b.Text = ""
        b.AutoButtonColor = false
        b.LayoutOrder = i
        b.ZIndex = 6
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
        local bg = Instance.new("UIGradient", b)
        bg.Color = isActive and
            ColorSequence.new(Color3.fromRGB(140, 180, 240), Color3.fromRGB(80, 120, 190)) or
            ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
        bg.Transparency = isActive and
            NumberSequence.new({NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0.82)}) or
            NumberSequence.new({NumberSequenceKeypoint.new(0, 0.85), NumberSequenceKeypoint.new(1, 0.93)})
        bg.Rotation = 90
        local st = Instance.new("UIStroke", b)
        st.Color = isActive and Color3.fromRGB(180, 210, 255) or Color3.fromRGB(255, 255, 255)
        st.Thickness = 1
        st.Transparency = isActive and 0.4 or 0.6
        local rowPad2 = Instance.new("UIPadding", b)
        rowPad2.PaddingLeft = UDim.new(0, 14)
        rowPad2.PaddingRight = UDim.new(0, 14)
        local dot = Instance.new("Frame", b)
        dot.Size = UDim2.new(0, 7, 0, 7)
        dot.Position = UDim2.new(0, 0, 0.5, -3)
        dot.BorderSizePixel = 0
        if isActive then dot.BackgroundColor3 = C.green
        elseif loaded then dot.BackgroundColor3 = Color3.fromRGB(140, 200, 165)
        else dot.BackgroundColor3 = C.textDim end
        dot.ZIndex = 7
        Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
        local l = Instance.new("TextLabel", b)
        l.BackgroundTransparency = 1
        l.Size = UDim2.new(1, -116, 1, 0)
        l.Position = UDim2.new(0, 18, 0, 0)
        l.Font = Enum.Font.Gotham
        l.TextSize = 11
        l.TextColor3 = C.text
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.Text = id
        l.ZIndex = 7
        local stateL = Instance.new("TextLabel", b)
        stateL.BackgroundTransparency = 1
        stateL.Size = UDim2.new(0, 88, 1, 0)
        stateL.Position = UDim2.new(1, -88, 0, 0)
        stateL.Font = Enum.Font.GothamMedium
        stateL.TextSize = 10
        stateL.TextXAlignment = Enum.TextXAlignment.Right
        stateL.ZIndex = 7
        if isActive then stateL.TextColor3 = C.green stateL.Text = "active"
        elseif loaded then stateL.TextColor3 = Color3.fromRGB(160, 210, 180) stateL.Text = "loaded"
        else stateL.TextColor3 = C.textMid stateL.Text = "load" end
        track(b.MouseEnter:Connect(function()
            if not isActive and b:GetAttribute("busy") ~= true then
                tw(b, {BackgroundTransparency = 0.8}, 0.18)
                tw(st, {Transparency = 0.45}, 0.18)
            end
        end))
        track(b.MouseLeave:Connect(function()
            if not isActive and b:GetAttribute("busy") ~= true then
                tw(b, {BackgroundTransparency = 0.88}, 0.22)
                tw(st, {Transparency = isActive and 0.4 or 0.6}, 0.22)
            end
        end))
        track(b.MouseButton1Click:Connect(function()
            if isActive or b:GetAttribute("busy") == true then return end
            if loaded or providers[currentProviderIdx].id ~= "lmstudio" then
                modelName = id
                U.modelNameLabel.Text = id
                U.modelHintLabel.Text = "switched"
                U.modelHintLabel.TextColor3 = C.green
                renderModels(modelList)
                return
            end
            b:SetAttribute("busy", true)
            stateL.TextColor3 = C.yellow
            stateL.Text = "0%"
            dot.BackgroundColor3 = C.yellow
            U.modelHintLabel.TextColor3 = C.yellow
            U.modelHintLabel.Text = "starting " .. id
            task.spawn(function()
                local success, msg = loadModelAsync(id, function(pct)
                    if unloaded then return end
                    stateL.Text = tostring(pct) .. "%"
                end)
                b:SetAttribute("busy", false)
                if unloaded then return end
                if success then
                    modelName = id
                    U.modelNameLabel.Text = id
                    U.modelHintLabel.Text = "loaded"
                    U.modelHintLabel.TextColor3 = C.green
                    task.wait(0.5)
                    if not unloaded then fetchModels() end
                else
                    stateL.TextColor3 = C.red
                    stateL.Text = "failed"
                    dot.BackgroundColor3 = C.red
                    U.modelHintLabel.Text = "failed: " .. msg
                    U.modelHintLabel.TextColor3 = C.red
                    task.wait(2)
                    if not unloaded then renderModels(modelList) end
                end
            end)
        end))
        b.BackgroundTransparency = 1
        b.Position = UDim2.new(0, 8, 0, 0)
        task.delay((i - 1) * 0.035, function()
            if unloaded or not b.Parent then return end
            tw(b, {
                Position = UDim2.new(0, 0, 0, 0),
                BackgroundTransparency = isActive and 0.78 or 0.88,
            }, 0.34, Enum.EasingStyle.Quart)
        end)
    end
end

function fetchModels()
    if unloaded then return end
    setStatus("loading")
    if U.modelNameLabel then U.modelNameLabel.Text = "connecting..." end

    buildEmptyState({
        loading = true,
        iconColor = C.accent,
        title = "fetching models",
        subtitle = "asking " .. providers[currentProviderIdx].name .. " for its model list...",
        titleColor = C.text,
    })

    task.spawn(function()
        local p = providers[currentProviderIdx]
        local list = {}
        local err = nil

        if p.style == "openai" then
            local url = p.base .. "/v1/models"
            local h = {["Accept"]="application/json"}
            if p.needsKey and activeKey ~= "" then h["Authorization"] = "Bearer " .. activeKey end
            local ok, res = pcall(function() return http({Url=url, Method="GET", Headers=h}) end)
            if not ok or not res then
                err = "couldn't reach server"
            elseif res.StatusCode == 401 or res.StatusCode == 403 then
                err = "api key rejected"
            elseif res.StatusCode ~= 200 then
                err = "server returned http " .. res.StatusCode
            else
                local okD, data = pcall(function() return httpService:JSONDecode(res.Body) end)
                if okD and data and data.data then
                    for _, m in ipairs(data.data) do
                        if m.id then table.insert(list, {id=m.id, loaded=true}) end
                    end
                end
            end
        elseif p.style == "gemini" then
            if activeKey == "" then
                err = "no api key"
            else
                local url = p.base .. "/v1beta/models?key=" .. activeKey
                local ok, res = pcall(function() return http({Url=url, Method="GET"}) end)
                if not ok or not res then
                    err = "couldn't reach server"
                elseif res.StatusCode ~= 200 then
                    err = "server returned http " .. res.StatusCode
                else
                    local okD, data = pcall(function() return httpService:JSONDecode(res.Body) end)
                    if okD and data and data.models then
                        for _, m in ipairs(data.models) do
                            if m.name then
                                local id = m.name:gsub("^models/", "")
                                table.insert(list, {id=id, loaded=true})
                            end
                        end
                    end
                end
            end
        end

        if unloaded then return end

        if #list == 0 then
            if p.id == "lmstudio" and err == "couldn't reach server" then
                buildEmptyState({
                    icon = "!",
                    iconColor = C.red,
                    title = "lm studio not running",
                    subtitle = "start the lm studio server on port 1234 and try again",
                    titleColor = C.red,
                    actionText = "retry",
                    actionColor = C.accent,
                    actionCb = fetchModels,
                })
                setStatus("fail", "no server")
                U.modelNameLabel.Text = "connection failed"
                U.modelHintLabel.Text = "check lm studio on :1234"
                U.modelHintLabel.TextColor3 = C.red
            elseif p.needsKey and activeKey == "" then
                buildEmptyState({
                    icon = "?",
                    iconColor = C.yellow,
                    title = "api key required",
                    subtitle = "paste your " .. p.name .. " key into the field above",
                    titleColor = C.yellow,
                    actionText = nil,
                })
                setStatus("fail", "need key")
                U.modelNameLabel.Text = "enter api key"
                U.modelHintLabel.Text = "paste your key above"
                U.modelHintLabel.TextColor3 = C.yellow
            elseif err == "api key rejected" then
                buildEmptyState({
                    icon = "!",
                    iconColor = C.red,
                    title = "api key rejected",
                    subtitle = "the key you entered for " .. p.name .. " isn't valid",
                    titleColor = C.red,
                    actionText = nil,
                })
                setStatus("fail", "bad key")
                U.modelNameLabel.Text = "auth failed"
                U.modelHintLabel.Text = "check your api key"
                U.modelHintLabel.TextColor3 = C.red
            else
                buildEmptyState({
                    icon = "?",
                    iconColor = C.yellow,
                    title = "no models found",
                    subtitle = err or ("nothing available from " .. p.name),
                    titleColor = C.yellow,
                    actionText = "retry",
                    actionColor = C.accent,
                    actionCb = fetchModels,
                })
                setStatus("fail", err or "no models")
                U.modelNameLabel.Text = "no models"
                U.modelHintLabel.Text = err or "try refreshing"
                U.modelHintLabel.TextColor3 = C.yellow
            end
            return
        end

        local found = false
        for _, e in ipairs(list) do if e.id == modelName then found = true break end end
        if not found then modelName = list[1].id end

        U.modelNameLabel.Text = modelName
        U.modelHintLabel.Text = "click a model to switch"
        U.modelHintLabel.TextColor3 = C.textDim
        setStatus("ok")
        renderModels(list)
    end)
end

local function buildUI()
    local container = Instance.new("Frame", gui)
    container.BackgroundTransparency = 1
    container.Size = UDim2.new(0, WIN_W, 0, WIN_H)
    container.Position = UDim2.new(0, 40, 0.5, 0)
    container.AnchorPoint = Vector2.new(0, 0.5)
    container.ZIndex = 1
    U.container = container
    local containerScale = Instance.new("UIScale", container)
    containerScale.Scale = 1
    U.containerScale = containerScale

    track(runService.RenderStepped:Connect(function(dt)
        if unloaded then return end
        if dt > 0.1 then dt = 0.1 end
        local diff = targetScale - currentScale
        local still = math.abs(diff) < 0.0005 and math.abs(scaleVelocity) < 0.0005
        if not still then
            local stiffness = 320
            local damping = 26
            scaleVelocity = scaleVelocity + (diff * stiffness - scaleVelocity * damping) * dt
            currentScale = currentScale + scaleVelocity * dt
            containerScale.Scale = currentScale
        elseif currentScale ~= targetScale then
            currentScale = targetScale
            scaleVelocity = 0
            containerScale.Scale = currentScale
        end
    end))

    local win = Instance.new("Frame", container)
    win.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
    win.BorderSizePixel = 0
    win.Size = UDim2.new(1, 0, 1, 0)
    win.Active = true
    win.ClipsDescendants = true
    win.ZIndex = 1
    U.win = win
    Instance.new("UICorner", win).CornerRadius = UDim.new(0, 16)
    local winStroke = Instance.new("UIStroke", win)
    winStroke.Color = Color3.fromRGB(255, 255, 255)
    winStroke.Thickness = 1
    local winSG = Instance.new("UIGradient", winStroke)
    winSG.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(140, 148, 168))
    winSG.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0.88)})
    winSG.Rotation = 90
    draggable(container, win)

    local function setupResize(handle, mode)
        local active, startPos, startSize = false, nil, nil
        track(handle.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                active = true
                startPos = i.Position
                startSize = Vector2.new(container.Size.X.Offset, container.Size.Y.Offset)
            end
        end))
        track(userInput.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                active = false
            end
        end))
        track(userInput.InputChanged:Connect(function(i)
            if not active then return end
            if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
                local d = i.Position - startPos
                local nw, nh = startSize.X, startSize.Y
                if mode == "both" or mode == "w" then nw = math.max(MIN_W, startSize.X + d.X) end
                if mode == "both" or mode == "h" then nh = math.max(MIN_H, startSize.Y + d.Y) end
                container.Size = UDim2.new(0, nw, 0, nh)
            end
        end))
    end

    local rzCorner = Instance.new("TextButton", win)
    rzCorner.BackgroundTransparency = 1
    rzCorner.Size = UDim2.new(0, 22, 0, 22)
    rzCorner.Position = UDim2.new(1, -22, 1, -22)
    rzCorner.Text = ""
    rzCorner.AutoButtonColor = false
    rzCorner.ZIndex = 90
    for i = 0, 2 do
        local d = Instance.new("Frame", rzCorner)
        d.BackgroundColor3 = C.textDim
        d.BackgroundTransparency = 0.3
        d.BorderSizePixel = 0
        d.Size = UDim2.new(0, 2, 0, 2)
        d.Position = UDim2.new(1, -6 - i * 5, 1, -6 - i * 5)
        Instance.new("UICorner", d).CornerRadius = UDim.new(1, 0)
    end
    setupResize(rzCorner, "both")

    local rzRight = Instance.new("TextButton", win)
    rzRight.BackgroundTransparency = 1
    rzRight.Size = UDim2.new(0, 6, 1, -60)
    rzRight.Position = UDim2.new(1, -3, 0, 30)
    rzRight.Text = ""
    rzRight.AutoButtonColor = false
    rzRight.ZIndex = 89
    setupResize(rzRight, "w")

    local rzBottom = Instance.new("TextButton", win)
    rzBottom.BackgroundTransparency = 1
    rzBottom.Size = UDim2.new(1, -60, 0, 6)
    rzBottom.Position = UDim2.new(0, 30, 1, -3)
    rzBottom.Text = ""
    rzBottom.AutoButtonColor = false
    rzBottom.ZIndex = 89
    setupResize(rzBottom, "h")

    local bgLayer = Instance.new("Frame", win)
    bgLayer.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
    bgLayer.BorderSizePixel = 0
    bgLayer.Size = UDim2.new(1, 0, 1, 0)
    bgLayer.ZIndex = 0
    bgLayer.ClipsDescendants = true
    Instance.new("UICorner", bgLayer).CornerRadius = UDim.new(0, 16)

    local bgGrad = Instance.new("UIGradient", bgLayer)
    local t0 = themes[currentThemeIdx]
    bgGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0.0, t0.c1),
        ColorSequenceKeypoint.new(0.5, t0.c2),
        ColorSequenceKeypoint.new(1.0, t0.c3),
    })
    bgGrad.Rotation = 35
    bgGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.4),
        NumberSequenceKeypoint.new(0.5, 0.62),
        NumberSequenceKeypoint.new(1, 0.4),
    })
    U.bgGrad = bgGrad

    local bgOverlay = Instance.new("Frame", bgLayer)
    bgOverlay.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
    bgOverlay.BackgroundTransparency = 0.6
    bgOverlay.BorderSizePixel = 0
    bgOverlay.Size = UDim2.new(1, 0, 1, 0)
    bgOverlay.ZIndex = 1
    Instance.new("UICorner", bgOverlay).CornerRadius = UDim.new(0, 16)

    local function makeOrb(color, size, startPos, d1, d2, dur, baseTrans)
        local o = Instance.new("Frame", bgLayer)
        o.BackgroundColor3 = color
        o.BackgroundTransparency = baseTrans
        o.BorderSizePixel = 0
        o.Size = UDim2.new(0, size, 0, size)
        o.Position = startPos
        o.ZIndex = 2
        Instance.new("UICorner", o).CornerRadius = UDim.new(1, 0)
        task.spawn(function()
            while not unloaded and o.Parent do
                tw(o, {Position = d1, BackgroundTransparency = baseTrans - 0.15}, dur, Enum.EasingStyle.Sine)
                task.wait(dur)
                if unloaded or not o.Parent then break end
                tw(o, {Position = d2, BackgroundTransparency = baseTrans + 0.05}, dur, Enum.EasingStyle.Sine)
                task.wait(dur)
                if unloaded or not o.Parent then break end
                tw(o, {Position = startPos, BackgroundTransparency = baseTrans}, dur, Enum.EasingStyle.Sine)
                task.wait(dur)
            end
        end)
        return o
    end

    U.orb1 = makeOrb(themes[currentThemeIdx].c1, 320, UDim2.new(-0.35, 0, -0.2, 0),
        UDim2.new(0.55, 0, -0.1, 0), UDim2.new(-0.05, 0, 0.55, 0), 16, 0.72)
    U.orb2 = makeOrb(themes[currentThemeIdx].c3, 280, UDim2.new(0.7, 0, 0.5, 0),
        UDim2.new(0.15, 0, 0.95, 0), UDim2.new(0.9, 0, 0.1, 0), 20, 0.78)
    U.orb3 = makeOrb(themes[currentThemeIdx].c2, 240, UDim2.new(0.3, 0, 0.7, 0),
        UDim2.new(-0.15, 0, 0.9, 0), UDim2.new(0.75, 0, -0.05, 0), 24, 0.82)

    local winSpec = Instance.new("Frame", win)
    winSpec.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    winSpec.BackgroundTransparency = 1
    winSpec.BorderSizePixel = 0
    winSpec.Size = UDim2.new(1, -40, 0, 1)
    winSpec.Position = UDim2.new(0, 20, 0, 0)
    winSpec.ZIndex = 3
    local wsGrad = Instance.new("UIGradient", winSpec)
    wsGrad.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.5), NumberSequenceKeypoint.new(1, 1)})

    task.spawn(function()
        while not unloaded do
            tw(bgGrad, {Rotation = bgGrad.Rotation + 360}, 60, Enum.EasingStyle.Linear)
            task.wait(60)
        end
    end)

    local header = Instance.new("Frame", win)
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, HEADER_H)
    header.ZIndex = 5
    local hPad = Instance.new("UIPadding", header)
    hPad.PaddingLeft = UDim.new(0, 16)
    hPad.PaddingRight = UDim.new(0, 16)
    hPad.PaddingTop = UDim.new(0, 12)
    hPad.PaddingBottom = UDim.new(0, 12)

    local hLeft = Instance.new("Frame", header)
    hLeft.BackgroundTransparency = 1
    hLeft.Size = UDim2.new(0.55, 0, 1, 0)
    hLeft.ZIndex = 6
    local hLL = Instance.new("UIListLayout", hLeft)
    hLL.FillDirection = Enum.FillDirection.Horizontal
    hLL.VerticalAlignment = Enum.VerticalAlignment.Center
    hLL.SortOrder = Enum.SortOrder.LayoutOrder
    hLL.Padding = UDim.new(0, 11)

    local iconBox = Instance.new("Frame", hLeft)
    iconBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    iconBox.BackgroundTransparency = 0.85
    iconBox.BorderSizePixel = 0
    iconBox.Size = UDim2.new(0, 34, 0, 34)
    iconBox.LayoutOrder = 1
    iconBox.ZIndex = 6
    Instance.new("UICorner", iconBox).CornerRadius = UDim.new(0, 9)
    local ibG = Instance.new("UIGradient", iconBox)
    ibG.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 205, 218))
    ibG.Rotation = 90
    local ibS = Instance.new("UIStroke", iconBox)
    ibS.Color = Color3.fromRGB(255, 255, 255)
    ibS.Thickness = 1
    ibS.Transparency = 0.5
    local iconImg = Instance.new("ImageLabel", iconBox)
    iconImg.BackgroundTransparency = 1
    iconImg.Size = UDim2.new(1, 0, 1, 0)
    iconImg.Position = UDim2.new(0, 0, 0, 0)
    iconImg.Image = iconId
    iconImg.ZIndex = 7
    Instance.new("UICorner", iconImg).CornerRadius = UDim.new(0, 9)

    local titleStack = Instance.new("Frame", hLeft)
    titleStack.BackgroundTransparency = 1
    titleStack.Size = UDim2.new(0, 150, 1, 0)
    titleStack.LayoutOrder = 2
    titleStack.ZIndex = 6
    local titleL = Instance.new("TextLabel", titleStack)
    titleL.BackgroundTransparency = 1
    titleL.Size = UDim2.new(1, 0, 0, 16)
    titleL.Position = UDim2.new(0, 0, 0, 3)
    titleL.Font = Enum.Font.GothamBold
    titleL.TextSize = 14
    titleL.TextColor3 = C.text
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Text = "grycan ai"
    titleL.ZIndex = 7
    local subL = Instance.new("TextLabel", titleStack)
    subL.BackgroundTransparency = 1
    subL.Size = UDim2.new(1, 0, 0, 12)
    subL.Position = UDim2.new(0, 0, 0, 19)
    subL.Font = Enum.Font.Gotham
    subL.TextSize = 10
    subL.TextColor3 = C.textDim
    subL.TextXAlignment = Enum.TextXAlignment.Left
    subL.Text = "way better then other people frrr"
    subL.ZIndex = 7

    local hRight = Instance.new("Frame", header)
    hRight.BackgroundTransparency = 1
    hRight.Size = UDim2.new(0.45, 0, 1, 0)
    hRight.Position = UDim2.new(0.55, 0, 0, 0)
    hRight.ZIndex = 6
    local hRL = Instance.new("UIListLayout", hRight)
    hRL.FillDirection = Enum.FillDirection.Horizontal
    hRL.HorizontalAlignment = Enum.HorizontalAlignment.Right
    hRL.VerticalAlignment = Enum.VerticalAlignment.Center
    hRL.SortOrder = Enum.SortOrder.LayoutOrder
    hRL.Padding = UDim.new(0, 8)

    local statusWrap = Instance.new("Frame", hRight)
    statusWrap.BackgroundTransparency = 1
    statusWrap.Size = UDim2.new(0, 84, 1, 0)
    statusWrap.LayoutOrder = 1
    statusWrap.ZIndex = 6
    local statusL = Instance.new("UIListLayout", statusWrap)
    statusL.FillDirection = Enum.FillDirection.Horizontal
    statusL.HorizontalAlignment = Enum.HorizontalAlignment.Right
    statusL.VerticalAlignment = Enum.VerticalAlignment.Center
    statusL.SortOrder = Enum.SortOrder.LayoutOrder
    statusL.Padding = UDim.new(0, 6)

    local statusText = Instance.new("TextLabel", statusWrap)
    statusText.BackgroundTransparency = 1
    statusText.Size = UDim2.new(0, 66, 1, 0)
    statusText.Font = Enum.Font.GothamMedium
    statusText.TextSize = 11
    statusText.TextColor3 = C.textMid
    statusText.TextXAlignment = Enum.TextXAlignment.Right
    statusText.Text = "offline"
    statusText.LayoutOrder = 1
    statusText.ZIndex = 7
    U.statusText = statusText

    local statusDot = Instance.new("Frame", statusWrap)
    statusDot.BackgroundColor3 = C.red
    statusDot.BorderSizePixel = 0
    statusDot.Size = UDim2.new(0, 7, 0, 7)
    statusDot.LayoutOrder = 2
    statusDot.ZIndex = 7
    Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)
    local sdRing = Instance.new("UIStroke", statusDot)
    sdRing.Color = C.red
    sdRing.Thickness = 1
    sdRing.Transparency = 0.6
    U.statusDot = statusDot
    U.statusRing = sdRing

    local function iconBtn(txt, order)
        local b = Instance.new("TextButton", hRight)
        b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        b.BackgroundTransparency = 0.85
        b.BorderSizePixel = 0
        b.Size = UDim2.new(0, 24, 0, 24)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 14
        b.TextColor3 = C.textMid
        b.Text = txt
        b.AutoButtonColor = false
        b.LayoutOrder = order
        b.ZIndex = 6
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
        local bg = Instance.new("UIGradient", b)
        bg.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
        bg.Rotation = 90
        local st = Instance.new("UIStroke", b)
        st.Color = Color3.fromRGB(255, 255, 255)
        st.Thickness = 1
        st.Transparency = 0.55
        return b
    end

    local btnMin = iconBtn("−", 2)
    local btnClose = iconBtn("×", 3)

    track(btnClose.MouseEnter:Connect(function() tw(btnClose, {BackgroundColor3 = Color3.fromRGB(200, 70, 85), BackgroundTransparency = 0.15, TextColor3 = Color3.fromRGB(255, 240, 245)}, 0.18) end))
    track(btnClose.MouseLeave:Connect(function() tw(btnClose, {BackgroundColor3 = Color3.fromRGB(255, 255, 255), BackgroundTransparency = 0.85, TextColor3 = C.textMid}, 0.22) end))
    track(btnMin.MouseEnter:Connect(function() tw(btnMin, {BackgroundTransparency = 0.7, TextColor3 = C.text}, 0.18) end))
    track(btnMin.MouseLeave:Connect(function() tw(btnMin, {BackgroundTransparency = 0.85, TextColor3 = C.textMid}, 0.22) end))

    local tabsBar = Instance.new("Frame", win)
    tabsBar.BackgroundTransparency = 1
    tabsBar.Size = UDim2.new(1, 0, 0, TABS_H)
    tabsBar.Position = UDim2.new(0, 0, 0, HEADER_H)
    tabsBar.ZIndex = 5

    local tabNames = {"logs", "toggles", "credits"}
    local tabBtns, tabPages = {}, {}
    local activeTab = "logs"

    for i, name in ipairs(tabNames) do
        local b = Instance.new("TextButton", tabsBar)
        b.BackgroundTransparency = 1
        b.Size = UDim2.new(1/3, 0, 1, 0)
        b.Position = UDim2.new((i - 1) / 3, 0, 0, 0)
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 12
        b.TextColor3 = C.textDim
        b.Text = name
        b.AutoButtonColor = false
        b.ZIndex = 6
        tabBtns[name] = b
    end

    local tabUnderline = Instance.new("Frame", tabsBar)
    tabUnderline.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    tabUnderline.BackgroundTransparency = 0.3
    tabUnderline.BorderSizePixel = 0
    tabUnderline.Size = UDim2.new(1/3, -80, 0, 3)
    tabUnderline.Position = UDim2.new(0, 40, 1, -4)
    tabUnderline.ZIndex = 7
    Instance.new("UICorner", tabUnderline).CornerRadius = UDim.new(1, 0)
    local tuG = Instance.new("UIGradient", tabUnderline)
    tuG.Color = ColorSequence.new(C.accentHi, C.accent)
    tuG.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 0.6)})
    registerAccent(tuG, "Color", "grad")

    local content = Instance.new("Frame", win)
    content.BackgroundTransparency = 1
    content.Size = UDim2.new(1, 0, 1, -HEADER_H - TABS_H)
    content.Position = UDim2.new(0, 0, 0, HEADER_H + TABS_H)
    content.ClipsDescendants = true
    content.ZIndex = 4

    for _, name in ipairs(tabNames) do
        local page = Instance.new("Frame", content)
        page.BackgroundTransparency = 1
        page.Size = UDim2.new(1, 0, 1, 0)
        page.Visible = (name == activeTab)
        page.ZIndex = 4
        tabPages[name] = page
    end

    local function switchTab(name)
        if name == activeTab then return end
        activeTab = name
        local newPage = tabPages[name]
        newPage.Visible = true
        local veil = Instance.new("Frame", newPage)
        veil.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
        veil.BackgroundTransparency = 0.5
        veil.BorderSizePixel = 0
        veil.Size = UDim2.new(1, 0, 1, 0)
        veil.ZIndex = 70
        tw(veil, {BackgroundTransparency = 1}, 0.32)
        task.delay(0.34, function() if veil and veil.Parent then veil:Destroy() end end)
        for n, p in pairs(tabPages) do
            if n ~= name then p.Visible = false end
        end
        local idx = table.find(tabNames, name)
        tw(tabUnderline, {Position = UDim2.new((idx - 1) / 3, 40, 1, -4)}, 0.4, Enum.EasingStyle.Quart)
        for n, b in pairs(tabBtns) do
            tw(b, {TextColor3 = (n == name) and C.text or C.textDim}, 0.24)
        end
    end

    for n, b in pairs(tabBtns) do
        track(b.MouseButton1Click:Connect(function() switchTab(n) end))
    end

    do
        local idx = table.find(tabNames, activeTab)
        tabUnderline.Position = UDim2.new((idx - 1) / 3, 40, 1, -4)
        tabBtns[activeTab].TextColor3 = C.text
    end

    local function section(parent, txt, order)
        local f = Instance.new("Frame", parent)
        f.BackgroundTransparency = 1
        f.Size = UDim2.new(1, 0, 0, 18)
        f.LayoutOrder = order or 0
        f.ZIndex = 5
        local l = Instance.new("TextLabel", f)
        l.BackgroundTransparency = 1
        l.Size = UDim2.new(1, 0, 1, 0)
        l.Font = Enum.Font.GothamBold
        l.TextSize = 10
        l.TextColor3 = C.textDim
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Text = string.upper(txt)
        l.ZIndex = 6
        local pl = Instance.new("UIPadding", f)
        pl.PaddingLeft = UDim.new(0, 4)
    end

    local function toggleRow(parent, label, initial, cb, order)
        local b = glassButton(parent, 48, order)
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
        local rowPad = Instance.new("UIPadding", b)
        rowPad.PaddingLeft = UDim.new(0, 16)
        rowPad.PaddingRight = UDim.new(0, 16)
        local l = Instance.new("TextLabel", b)
        l.BackgroundTransparency = 1
        l.Size = UDim2.new(1, -84, 1, 0)
        l.Font = Enum.Font.GothamMedium
        l.TextSize = 12
        l.TextColor3 = C.text
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Text = label
        l.ZIndex = 6
        local PW, PH, K = 40, 22, 18
        local toggleTrack = Instance.new("Frame", b)
        toggleTrack.Size = UDim2.new(0, PW, 0, PH)
        toggleTrack.Position = UDim2.new(1, -PW, 0.5, -PH / 2)
        toggleTrack.BackgroundColor3 = initial and C.green or Color3.fromRGB(64, 66, 78)
        toggleTrack.BackgroundTransparency = initial and 0 or 0.1
        toggleTrack.BorderSizePixel = 0
        toggleTrack.ZIndex = 6
        Instance.new("UICorner", toggleTrack).CornerRadius = UDim.new(1, 0)
        local ttStroke = Instance.new("UIStroke", toggleTrack)
        ttStroke.Color = Color3.fromRGB(255, 255, 255)
        ttStroke.Thickness = 1
        ttStroke.Transparency = initial and 0.6 or 0.75
        local knob = Instance.new("Frame", toggleTrack)
        knob.Size = UDim2.new(0, K, 0, K)
        knob.Position = UDim2.new(0, initial and (PW - K - 2) or 2, 0.5, -K / 2)
        knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        knob.BorderSizePixel = 0
        knob.ZIndex = 7
        Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
        local state = initial
        track(b.MouseButton1Click:Connect(function()
            state = not state
            local tx = state and (PW - K - 2) or 2
            tw(knob, {Position = UDim2.new(0, tx, 0.5, -K / 2)}, 0.4, Enum.EasingStyle.Back)
            tw(toggleTrack, {
                BackgroundColor3 = state and C.green or Color3.fromRGB(64, 66, 78),
                BackgroundTransparency = state and 0 or 0.1,
            }, 0.28)
            tweenService:Create(ttStroke, TweenInfo.new(0.28), {Transparency = state and 0.6 or 0.75}):Play()
            cb(state)
        end))
        return b
    end

    local logsPage = tabPages["logs"]

    local chatCard = glassSurface(logsPage)
    chatCard.Size = UDim2.new(1, -28, 1, -104)
    chatCard.Position = UDim2.new(0, 14, 0, 14)

    local chatScroll = Instance.new("ScrollingFrame", chatCard)
    chatScroll.BackgroundTransparency = 1
    chatScroll.BorderSizePixel = 0
    chatScroll.Size = UDim2.new(1, -28, 1, -28)
    chatScroll.Position = UDim2.new(0, 14, 0, 14)
    chatScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    chatScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    chatScroll.ScrollBarThickness = 2
    chatScroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
    chatScroll.ScrollBarImageTransparency = 0.7
    chatScroll.ZIndex = 6

    local chatLabel = Instance.new("TextLabel", chatScroll)
    chatLabel.BackgroundTransparency = 1
    chatLabel.Size = UDim2.new(1, 0, 0, 0)
    chatLabel.AutomaticSize = Enum.AutomaticSize.Y
    chatLabel.Font = Enum.Font.Code
    chatLabel.TextSize = 11
    chatLabel.TextColor3 = C.text
    chatLabel.TextXAlignment = Enum.TextXAlignment.Left
    chatLabel.TextYAlignment = Enum.TextYAlignment.Top
    chatLabel.TextWrapped = true
    chatLabel.LineHeight = 1.45
    chatLabel.Text = "waiting for nearby chatter..."
    chatLabel.ZIndex = 7
    U.chatLabel = chatLabel

    local inputBar = glassSurface(logsPage)
    inputBar.Size = UDim2.new(1, -28, 0, 70)
    inputBar.Position = UDim2.new(0, 14, 1, -84)

    local ibTop = Instance.new("Frame", inputBar)
    ibTop.BackgroundTransparency = 1
    ibTop.Size = UDim2.new(1, -28, 0, 14)
    ibTop.Position = UDim2.new(0, 14, 0, 10)
    ibTop.ZIndex = 6

    local ibLabel = Instance.new("TextLabel", ibTop)
    ibLabel.BackgroundTransparency = 1
    ibLabel.Size = UDim2.new(0.5, 0, 1, 0)
    ibLabel.Font = Enum.Font.GothamBold
    ibLabel.TextSize = 10
    ibLabel.TextColor3 = C.textDim
    ibLabel.TextXAlignment = Enum.TextXAlignment.Left
    ibLabel.Text = "TEST CHAT"
    ibLabel.ZIndex = 7

    local sayBtn = Instance.new("TextButton", ibTop)
    sayBtn.BackgroundTransparency = 1
    sayBtn.Size = UDim2.new(0.5, 0, 1, 0)
    sayBtn.Position = UDim2.new(0.5, 0, 0, 0)
    sayBtn.Text = ""
    sayBtn.AutoButtonColor = false
    sayBtn.ZIndex = 6

    local sayLabel = Instance.new("TextLabel", sayBtn)
    sayLabel.BackgroundTransparency = 1
    sayLabel.Size = UDim2.new(1, -14, 1, 0)
    sayLabel.Font = Enum.Font.Gotham
    sayLabel.TextSize = 10
    sayLabel.TextColor3 = C.textDim
    sayLabel.TextXAlignment = Enum.TextXAlignment.Right
    sayLabel.Text = "say in chat · off"
    sayLabel.ZIndex = 7

    local sayDot = Instance.new("Frame", sayBtn)
    sayDot.BackgroundColor3 = C.textDim
    sayDot.BorderSizePixel = 0
    sayDot.Size = UDim2.new(0, 7, 0, 7)
    sayDot.Position = UDim2.new(1, -7, 0.5, -3)
    sayDot.ZIndex = 7
    Instance.new("UICorner", sayDot).CornerRadius = UDim.new(1, 0)

    track(sayBtn.MouseButton1Click:Connect(function()
        sayToChat = not sayToChat
        sayLabel.Text = "say in chat · " .. (sayToChat and "on" or "off")
        sayLabel.TextColor3 = sayToChat and C.green or C.textDim
        tw(sayDot, {BackgroundColor3 = sayToChat and C.green or C.textDim}, 0.24)
    end))

    local testInput = Instance.new("TextBox", inputBar)
    testInput.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    testInput.BackgroundTransparency = 0.65
    testInput.BorderSizePixel = 0
    testInput.Size = UDim2.new(1, -110, 0, 32)
    testInput.Position = UDim2.new(0, 14, 0, 30)
    testInput.Font = Enum.Font.Gotham
    testInput.TextSize = 12
    testInput.TextColor3 = C.text
    testInput.PlaceholderText = "message..."
    testInput.PlaceholderColor3 = C.textDim
    testInput.Text = ""
    testInput.ClearTextOnFocus = false
    testInput.ZIndex = 6
    Instance.new("UICorner", testInput).CornerRadius = UDim.new(0, 8)
    local tiStroke = Instance.new("UIStroke", testInput)
    tiStroke.Color = Color3.fromRGB(255, 255, 255)
    tiStroke.Thickness = 1
    tiStroke.Transparency = 0.75
    local tiPad = Instance.new("UIPadding", testInput)
    tiPad.PaddingLeft = UDim.new(0, 12)
    tiPad.PaddingRight = UDim.new(0, 12)

    local sendBtn = Instance.new("TextButton", inputBar)
    sendBtn.BackgroundColor3 = C.accent
    sendBtn.BorderSizePixel = 0
    sendBtn.Size = UDim2.new(0, 82, 0, 32)
    sendBtn.Position = UDim2.new(1, -96, 0, 30)
    sendBtn.Font = Enum.Font.GothamBold
    sendBtn.TextSize = 11
    sendBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    sendBtn.Text = "send"
    sendBtn.AutoButtonColor = false
    sendBtn.ZIndex = 6
    Instance.new("UICorner", sendBtn).CornerRadius = UDim.new(0, 8)
    local sbGrad = Instance.new("UIGradient", sendBtn)
    sbGrad.Color = ColorSequence.new(C.accentHi, C.accent)
    sbGrad.Rotation = 90
    local sbStroke = Instance.new("UIStroke", sendBtn)
    sbStroke.Color = Color3.fromRGB(255, 255, 255)
    sbStroke.Thickness = 1
    sbStroke.Transparency = 0.55
    registerAccent(sendBtn, "BackgroundColor3", "accent")
    registerAccent(sbGrad, "Color", "grad")

    track(sendBtn.MouseEnter:Connect(function() tweenService:Create(sbStroke, TweenInfo.new(0.2), {Transparency = 0.35}):Play() end))
    track(sendBtn.MouseLeave:Connect(function() tweenService:Create(sbStroke, TweenInfo.new(0.24), {Transparency = 0.55}):Play() end))

    local function sendTest()
        if unloaded then return end
        local txt = testInput.Text
        if not txt or txt == "" then return end
        testInput.Text = ""
        logChat("you", txt, "test")
        task.spawn(function()
            local r = askAI("you", txt)
            if r then
                logChat("grycan", r, "ai")
                if sayToChat then say(r) end
            end
        end)
    end

    track(sendBtn.MouseButton1Click:Connect(sendTest))
    track(testInput.FocusLost:Connect(function(enter) if enter then sendTest() end end))

    local togglesPage = tabPages["toggles"]
    local tPad = Instance.new("UIPadding", togglesPage)
    tPad.PaddingTop = UDim.new(0, 14)
    tPad.PaddingBottom = UDim.new(0, 18)
    tPad.PaddingLeft = UDim.new(0, 14)
    tPad.PaddingRight = UDim.new(0, 14)

    local tScroll = Instance.new("ScrollingFrame", togglesPage)
    tScroll.BackgroundTransparency = 1
    tScroll.BorderSizePixel = 0
    tScroll.Size = UDim2.new(1, 0, 1, 0)
    tScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    tScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tScroll.ScrollBarThickness = 2
    tScroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
    tScroll.ScrollBarImageTransparency = 0.7
    tScroll.ZIndex = 5
    local tList = Instance.new("UIListLayout", tScroll)
    tList.SortOrder = Enum.SortOrder.LayoutOrder
    tList.Padding = UDim.new(0, 8)

    section(tScroll, "appearance", 0)

    local themeCard = glassSurface(tScroll, 1)
    themeCard.Size = UDim2.new(1, 0, 0, 72)

    local themeLabel = Instance.new("TextLabel", themeCard)
    themeLabel.BackgroundTransparency = 1
    themeLabel.Size = UDim2.new(1, -28, 0, 14)
    themeLabel.Position = UDim2.new(0, 14, 0, 12)
    themeLabel.Font = Enum.Font.GothamBold
    themeLabel.TextSize = 10
    themeLabel.TextColor3 = C.textDim
    themeLabel.TextXAlignment = Enum.TextXAlignment.Left
    themeLabel.Text = "theme · " .. themes[currentThemeIdx].name
    themeLabel.ZIndex = 6
    U.themeLabel = themeLabel

    local swatchRow = Instance.new("Frame", themeCard)
    swatchRow.BackgroundTransparency = 1
    swatchRow.Size = UDim2.new(1, -28, 0, 28)
    swatchRow.Position = UDim2.new(0, 14, 0, 32)
    swatchRow.ZIndex = 6
    local swatchLayout = Instance.new("UIListLayout", swatchRow)
    swatchLayout.FillDirection = Enum.FillDirection.Horizontal
    swatchLayout.SortOrder = Enum.SortOrder.LayoutOrder
    swatchLayout.Padding = UDim.new(0, 10)
    swatchLayout.VerticalAlignment = Enum.VerticalAlignment.Center

    for i, t in ipairs(themes) do
        local sw = Instance.new("TextButton", swatchRow)
        sw.BackgroundColor3 = t.c1
        sw.BorderSizePixel = 0
        sw.Size = UDim2.new(0, 26, 0, 26)
        sw.Text = ""
        sw.AutoButtonColor = false
        sw.LayoutOrder = i
        sw.ZIndex = 6
        Instance.new("UICorner", sw).CornerRadius = UDim.new(1, 0)
        local swGrad = Instance.new("UIGradient", sw)
        swGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255):Lerp(t.c1, 0.6), t.c1)
        swGrad.Rotation = 90
        local swStroke = Instance.new("UIStroke", sw)
        swStroke.Color = (i == currentThemeIdx) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 185, 200)
        swStroke.Thickness = (i == currentThemeIdx) and 2 or 1
        swStroke.Transparency = (i == currentThemeIdx) and 0.2 or 0.65
        track(sw.MouseEnter:Connect(function()
            tw(sw, {Size = UDim2.new(0, 30, 0, 30)}, 0.2, Enum.EasingStyle.Back)
        end))
        track(sw.MouseLeave:Connect(function()
            tw(sw, {Size = UDim2.new(0, 26, 0, 26)}, 0.24, Enum.EasingStyle.Quart)
        end))
        track(sw.MouseButton1Click:Connect(function()
            applyTheme(i)
            for _, child in ipairs(swatchRow:GetChildren()) do
                if child:IsA("TextButton") then
                    local st = child:FindFirstChildOfClass("UIStroke")
                    if st then
                        local active = (child.LayoutOrder == i)
                        tweenService:Create(st, TweenInfo.new(0.26), {
                            Color = active and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 185, 200),
                            Thickness = active and 2 or 1,
                            Transparency = active and 0.2 or 0.65,
                        }):Play()
                    end
                end
            end
        end))
    end

    section(tScroll, "scale", 2)

    local scaleCard = glassSurface(tScroll, 3)
    scaleCard.Size = UDim2.new(1, 0, 0, 56)

    local scaleLabel = Instance.new("TextLabel", scaleCard)
    scaleLabel.BackgroundTransparency = 1
    scaleLabel.Size = UDim2.new(1, -180, 1, 0)
    scaleLabel.Position = UDim2.new(0, 16, 0, 0)
    scaleLabel.Font = Enum.Font.GothamBold
    scaleLabel.TextSize = 11
    scaleLabel.TextColor3 = C.text
    scaleLabel.TextXAlignment = Enum.TextXAlignment.Left
    scaleLabel.Text = "zoom · " .. string.format("%.2f", targetScale)
    scaleLabel.ZIndex = 6
    U.scaleLabel = scaleLabel

    local function scaleBtn(txt, order, onClick)
        local b = Instance.new("TextButton", scaleCard)
        b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        b.BackgroundTransparency = 0.8
        b.BorderSizePixel = 0
        b.Size = UDim2.new(0, 34, 0, 30)
        b.Position = UDim2.new(1, -(34 * (4 - order) + 12 + (3 - order) * 6), 0.5, -15)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 13
        b.TextColor3 = C.text
        b.Text = txt
        b.AutoButtonColor = false
        b.ZIndex = 6
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
        local bg = Instance.new("UIGradient", b)
        bg.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
        bg.Rotation = 90
        local st = Instance.new("UIStroke", b)
        st.Color = Color3.fromRGB(255, 255, 255)
        st.Thickness = 1
        st.Transparency = 0.6
        track(b.MouseEnter:Connect(function() tw(b, {BackgroundTransparency = 0.68}, 0.18) end))
        track(b.MouseLeave:Connect(function() tw(b, {BackgroundTransparency = 0.8}, 0.22) end))
        track(b.MouseButton1Click:Connect(onClick))
    end

    scaleBtn("−", 1, function()
        targetScale = clamp(targetScale - 0.1, 0.7, 1.5)
        scaleLabel.Text = "zoom · " .. string.format("%.2f", targetScale)
    end)
    scaleBtn("1", 2, function()
        targetScale = 1
        scaleLabel.Text = "zoom · 1.00"
    end)
    scaleBtn("+", 3, function()
        targetScale = clamp(targetScale + 0.1, 0.7, 1.5)
        scaleLabel.Text = "zoom · " .. string.format("%.2f", targetScale)
    end)

    section(tScroll, "personality", 5)

    local promptCard = glassSurface(tScroll, 6)
    promptCard.Size = UDim2.new(1, 0, 0, 172)

    local promptTitle = Instance.new("TextLabel", promptCard)
    promptTitle.BackgroundTransparency = 1
    promptTitle.Size = UDim2.new(1, -28, 0, 14)
    promptTitle.Position = UDim2.new(0, 14, 0, 12)
    promptTitle.Font = Enum.Font.GothamBold
    promptTitle.TextSize = 10
    promptTitle.TextColor3 = C.textDim
    promptTitle.TextXAlignment = Enum.TextXAlignment.Left
    promptTitle.Text = "system prompt"
    promptTitle.ZIndex = 6

    local promptBox = Instance.new("TextBox", promptCard)
    promptBox.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    promptBox.BackgroundTransparency = 0.65
    promptBox.BorderSizePixel = 0
    promptBox.Size = UDim2.new(1, -28, 0, 96)
    promptBox.Position = UDim2.new(0, 14, 0, 30)
    promptBox.Font = Enum.Font.Gotham
    promptBox.TextSize = 11
    promptBox.TextColor3 = C.text
    promptBox.PlaceholderText = "type the ai system prompt..."
    promptBox.PlaceholderColor3 = C.textDim
    promptBox.Text = customPrompt
    promptBox.TextXAlignment = Enum.TextXAlignment.Left
    promptBox.TextYAlignment = Enum.TextYAlignment.Top
    promptBox.TextWrapped = true
    promptBox.ClearTextOnFocus = false
    promptBox.MultiLine = true
    promptBox.ZIndex = 6
    Instance.new("UICorner", promptBox).CornerRadius = UDim.new(0, 8)
    local pbStroke = Instance.new("UIStroke", promptBox)
    pbStroke.Color = Color3.fromRGB(255, 255, 255)
    pbStroke.Thickness = 1
    pbStroke.Transparency = 0.75
    local pbPad = Instance.new("UIPadding", promptBox)
    pbPad.PaddingLeft = UDim.new(0, 10)
    pbPad.PaddingRight = UDim.new(0, 10)
    pbPad.PaddingTop = UDim.new(0, 8)
    pbPad.PaddingBottom = UDim.new(0, 8)

    local promptSaveBtn = Instance.new("TextButton", promptCard)
    promptSaveBtn.BackgroundColor3 = C.accent
    promptSaveBtn.BorderSizePixel = 0
    promptSaveBtn.Size = UDim2.new(0, 76, 0, 26)
    promptSaveBtn.Position = UDim2.new(0, 14, 1, -36)
    promptSaveBtn.Font = Enum.Font.GothamBold
    promptSaveBtn.TextSize = 10
    promptSaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    promptSaveBtn.Text = "save"
    promptSaveBtn.AutoButtonColor = false
    promptSaveBtn.ZIndex = 6
    Instance.new("UICorner", promptSaveBtn).CornerRadius = UDim.new(0, 7)
    local psGrad = Instance.new("UIGradient", promptSaveBtn)
    psGrad.Color = ColorSequence.new(C.accentHi, C.accent)
    psGrad.Rotation = 90
    local psStroke = Instance.new("UIStroke", promptSaveBtn)
    psStroke.Color = Color3.fromRGB(255, 255, 255)
    psStroke.Thickness = 1
    psStroke.Transparency = 0.55
    registerAccent(promptSaveBtn, "BackgroundColor3", "accent")
    registerAccent(psGrad, "Color", "grad")

    local promptResetBtn = Instance.new("TextButton", promptCard)
    promptResetBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    promptResetBtn.BackgroundTransparency = 0.8
    promptResetBtn.BorderSizePixel = 0
    promptResetBtn.Size = UDim2.new(0, 76, 0, 26)
    promptResetBtn.Position = UDim2.new(0, 98, 1, -36)
    promptResetBtn.Font = Enum.Font.GothamBold
    promptResetBtn.TextSize = 10
    promptResetBtn.TextColor3 = C.text
    promptResetBtn.Text = "reset"
    promptResetBtn.AutoButtonColor = false
    promptResetBtn.ZIndex = 6
    Instance.new("UICorner", promptResetBtn).CornerRadius = UDim.new(0, 7)
    local prGrad = Instance.new("UIGradient", promptResetBtn)
    prGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
    prGrad.Rotation = 90
    local prStroke = Instance.new("UIStroke", promptResetBtn)
    prStroke.Color = Color3.fromRGB(255, 255, 255)
    prStroke.Thickness = 1
    prStroke.Transparency = 0.6

    local promptStatus = Instance.new("TextLabel", promptCard)
    promptStatus.BackgroundTransparency = 1
    promptStatus.Size = UDim2.new(1, -196, 0, 14)
    promptStatus.Position = UDim2.new(0, 184, 1, -30)
    promptStatus.Font = Enum.Font.Gotham
    promptStatus.TextSize = 10
    promptStatus.TextColor3 = C.green
    promptStatus.TextXAlignment = Enum.TextXAlignment.Left
    promptStatus.Text = ""
    promptStatus.TextTransparency = 1
    promptStatus.ZIndex = 6

    track(promptSaveBtn.MouseEnter:Connect(function() tw(promptSaveBtn, {BackgroundTransparency = 0.05}, 0.18) end))
    track(promptSaveBtn.MouseLeave:Connect(function() tw(promptSaveBtn, {BackgroundTransparency = 0}, 0.22) end))
    track(promptResetBtn.MouseEnter:Connect(function() tw(promptResetBtn, {BackgroundTransparency = 0.68}, 0.18) end))
    track(promptResetBtn.MouseLeave:Connect(function() tw(promptResetBtn, {BackgroundTransparency = 0.8}, 0.22) end))

    track(promptSaveBtn.MouseButton1Click:Connect(function()
        customPrompt = promptBox.Text
        saveToDisk(promptFile, customPrompt)
        promptStatus.Text = "saved"
        promptStatus.TextColor3 = C.green
        promptStatus.TextTransparency = 0
        task.delay(1.6, function()
            for i = 0, 10 do
                if unloaded then return end
                promptStatus.TextTransparency = i / 10
                task.wait(0.03)
            end
        end)
    end))

    track(promptResetBtn.MouseButton1Click:Connect(function()
        promptBox.Text = defaultPrompt
        customPrompt = defaultPrompt
        saveToDisk(promptFile, defaultPrompt)
        promptStatus.Text = "reset"
        promptStatus.TextColor3 = C.textMid
        promptStatus.TextTransparency = 0
        task.delay(1.6, function()
            for i = 0, 10 do
                if unloaded then return end
                promptStatus.TextTransparency = i / 10
                task.wait(0.03)
            end
        end)
    end))

    section(tScroll, "custom instructions", 8)

    local instrCard = glassSurface(tScroll, 9)
    instrCard.Size = UDim2.new(1, 0, 0, 152)

    local instrTitle = Instance.new("TextLabel", instrCard)
    instrTitle.BackgroundTransparency = 1
    instrTitle.Size = UDim2.new(1, -28, 0, 14)
    instrTitle.Position = UDim2.new(0, 14, 0, 12)
    instrTitle.Font = Enum.Font.GothamBold
    instrTitle.TextSize = 10
    instrTitle.TextColor3 = C.textDim
    instrTitle.TextXAlignment = Enum.TextXAlignment.Left
    instrTitle.Text = "extra rules · appended to system prompt"
    instrTitle.ZIndex = 6

    local instrBox = Instance.new("TextBox", instrCard)
    instrBox.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    instrBox.BackgroundTransparency = 0.65
    instrBox.BorderSizePixel = 0
    instrBox.Size = UDim2.new(1, -28, 0, 78)
    instrBox.Position = UDim2.new(0, 14, 0, 30)
    instrBox.Font = Enum.Font.Gotham
    instrBox.TextSize = 11
    instrBox.TextColor3 = C.text
    instrBox.PlaceholderText = "e.g. swear sometimes · use emojis · keep replies super short..."
    instrBox.PlaceholderColor3 = C.textDim
    instrBox.Text = customInstructions
    instrBox.TextXAlignment = Enum.TextXAlignment.Left
    instrBox.TextYAlignment = Enum.TextYAlignment.Top
    instrBox.TextWrapped = true
    instrBox.ClearTextOnFocus = false
    instrBox.MultiLine = true
    instrBox.ZIndex = 6
    Instance.new("UICorner", instrBox).CornerRadius = UDim.new(0, 8)
    local ibStroke2 = Instance.new("UIStroke", instrBox)
    ibStroke2.Color = Color3.fromRGB(255, 255, 255)
    ibStroke2.Thickness = 1
    ibStroke2.Transparency = 0.75
    local ibPad2 = Instance.new("UIPadding", instrBox)
    ibPad2.PaddingLeft = UDim.new(0, 10)
    ibPad2.PaddingRight = UDim.new(0, 10)
    ibPad2.PaddingTop = UDim.new(0, 8)
    ibPad2.PaddingBottom = UDim.new(0, 8)

    local instrSaveBtn = Instance.new("TextButton", instrCard)
    instrSaveBtn.BackgroundColor3 = C.accent
    instrSaveBtn.BorderSizePixel = 0
    instrSaveBtn.Size = UDim2.new(0, 76, 0, 26)
    instrSaveBtn.Position = UDim2.new(0, 14, 1, -34)
    instrSaveBtn.Font = Enum.Font.GothamBold
    instrSaveBtn.TextSize = 10
    instrSaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    instrSaveBtn.Text = "save"
    instrSaveBtn.AutoButtonColor = false
    instrSaveBtn.ZIndex = 6
    Instance.new("UICorner", instrSaveBtn).CornerRadius = UDim.new(0, 7)
    local isGrad = Instance.new("UIGradient", instrSaveBtn)
    isGrad.Color = ColorSequence.new(C.accentHi, C.accent)
    isGrad.Rotation = 90
    local isStroke = Instance.new("UIStroke", instrSaveBtn)
    isStroke.Color = Color3.fromRGB(255, 255, 255)
    isStroke.Thickness = 1
    isStroke.Transparency = 0.55
    registerAccent(instrSaveBtn, "BackgroundColor3", "accent")
    registerAccent(isGrad, "Color", "grad")

    local instrClearBtn = Instance.new("TextButton", instrCard)
    instrClearBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    instrClearBtn.BackgroundTransparency = 0.8
    instrClearBtn.BorderSizePixel = 0
    instrClearBtn.Size = UDim2.new(0, 76, 0, 26)
    instrClearBtn.Position = UDim2.new(0, 98, 1, -34)
    instrClearBtn.Font = Enum.Font.GothamBold
    instrClearBtn.TextSize = 10
    instrClearBtn.TextColor3 = C.text
    instrClearBtn.Text = "clear"
    instrClearBtn.AutoButtonColor = false
    instrClearBtn.ZIndex = 6
    Instance.new("UICorner", instrClearBtn).CornerRadius = UDim.new(0, 7)
    local icGrad = Instance.new("UIGradient", instrClearBtn)
    icGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
    icGrad.Rotation = 90
    local icStroke = Instance.new("UIStroke", instrClearBtn)
    icStroke.Color = Color3.fromRGB(255, 255, 255)
    icStroke.Thickness = 1
    icStroke.Transparency = 0.6

    local instrStatus = Instance.new("TextLabel", instrCard)
    instrStatus.BackgroundTransparency = 1
    instrStatus.Size = UDim2.new(1, -196, 0, 14)
    instrStatus.Position = UDim2.new(0, 184, 1, -28)
    instrStatus.Font = Enum.Font.Gotham
    instrStatus.TextSize = 10
    instrStatus.TextColor3 = C.green
    instrStatus.TextXAlignment = Enum.TextXAlignment.Left
    instrStatus.Text = ""
    instrStatus.TextTransparency = 1
    instrStatus.ZIndex = 6

    track(instrSaveBtn.MouseEnter:Connect(function() tw(instrSaveBtn, {BackgroundTransparency = 0.05}, 0.18) end))
    track(instrSaveBtn.MouseLeave:Connect(function() tw(instrSaveBtn, {BackgroundTransparency = 0}, 0.22) end))
    track(instrClearBtn.MouseEnter:Connect(function() tw(instrClearBtn, {BackgroundTransparency = 0.68}, 0.18) end))
    track(instrClearBtn.MouseLeave:Connect(function() tw(instrClearBtn, {BackgroundTransparency = 0.8}, 0.22) end))

    track(instrSaveBtn.MouseButton1Click:Connect(function()
        customInstructions = instrBox.Text
        saveToDisk(instructionsFile, customInstructions)
        instrStatus.Text = "saved"
        instrStatus.TextColor3 = C.green
        instrStatus.TextTransparency = 0
        task.delay(1.6, function()
            for i = 0, 10 do
                if unloaded then return end
                instrStatus.TextTransparency = i / 10
                task.wait(0.03)
            end
        end)
    end))

    track(instrClearBtn.MouseButton1Click:Connect(function()
        instrBox.Text = ""
        customInstructions = ""
        saveToDisk(instructionsFile, "")
        instrStatus.Text = "cleared"
        instrStatus.TextColor3 = C.textMid
        instrStatus.TextTransparency = 0
        task.delay(1.6, function()
            for i = 0, 10 do
                if unloaded then return end
                instrStatus.TextTransparency = i / 10
                task.wait(0.03)
            end
        end)
    end))

    section(tScroll, "connection", 10)

    local providerCard = glassSurface(tScroll, 11)
    providerCard.Size = UDim2.new(1, 0, 0, 132)

    local providerTitle = Instance.new("TextLabel", providerCard)
    providerTitle.BackgroundTransparency = 1
    providerTitle.Size = UDim2.new(1, -28, 0, 12)
    providerTitle.Position = UDim2.new(0, 14, 0, 12)
    providerTitle.Font = Enum.Font.GothamBold
    providerTitle.TextSize = 10
    providerTitle.TextColor3 = C.textDim
    providerTitle.TextXAlignment = Enum.TextXAlignment.Left
    providerTitle.Text = "PROVIDER"
    providerTitle.ZIndex = 6

    local provPrev = Instance.new("TextButton", providerCard)
    provPrev.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    provPrev.BackgroundTransparency = 0.8
    provPrev.BorderSizePixel = 0
    provPrev.Size = UDim2.new(0, 32, 0, 30)
    provPrev.Position = UDim2.new(0, 14, 0, 28)
    provPrev.Font = Enum.Font.GothamBold
    provPrev.TextSize = 15
    provPrev.TextColor3 = C.text
    provPrev.Text = "‹"
    provPrev.AutoButtonColor = false
    provPrev.ZIndex = 6
    Instance.new("UICorner", provPrev).CornerRadius = UDim.new(0, 8)

    local provLabel = Instance.new("TextLabel", providerCard)
    provLabel.BackgroundTransparency = 1
    provLabel.Size = UDim2.new(1, -92, 0, 30)
    provLabel.Position = UDim2.new(0, 52, 0, 28)
    provLabel.Font = Enum.Font.GothamBold
    provLabel.TextSize = 13
    provLabel.TextColor3 = C.text
    provLabel.TextXAlignment = Enum.TextXAlignment.Center
    provLabel.Text = providers[currentProviderIdx].name
    provLabel.ZIndex = 6

    local provNext = Instance.new("TextButton", providerCard)
    provNext.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    provNext.BackgroundTransparency = 0.8
    provNext.BorderSizePixel = 0
    provNext.Size = UDim2.new(0, 32, 0, 30)
    provNext.Position = UDim2.new(1, -46, 0, 28)
    provNext.Font = Enum.Font.GothamBold
    provNext.TextSize = 15
    provNext.TextColor3 = C.text
    provNext.Text = "›"
    provNext.AutoButtonColor = false
    provNext.ZIndex = 6
    Instance.new("UICorner", provNext).CornerRadius = UDim.new(0, 8)

    local keyTitle = Instance.new("TextLabel", providerCard)
    keyTitle.BackgroundTransparency = 1
    keyTitle.Size = UDim2.new(1, -28, 0, 12)
    keyTitle.Position = UDim2.new(0, 14, 0, 68)
    keyTitle.Font = Enum.Font.GothamBold
    keyTitle.TextSize = 10
    keyTitle.TextColor3 = C.textDim
    keyTitle.TextXAlignment = Enum.TextXAlignment.Left
    keyTitle.Text = "API KEY"
    keyTitle.ZIndex = 6

    local keyBox = Instance.new("TextBox", providerCard)
    keyBox.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    keyBox.BackgroundTransparency = 0.65
    keyBox.BorderSizePixel = 0
    keyBox.Size = UDim2.new(1, -28, 0, 30)
    keyBox.Position = UDim2.new(0, 14, 0, 84)
    keyBox.Font = Enum.Font.Code
    keyBox.TextSize = 11
    keyBox.TextColor3 = C.text
    keyBox.PlaceholderText = "paste key here"
    keyBox.PlaceholderColor3 = C.textDim
    keyBox.Text = activeKey
    keyBox.ClearTextOnFocus = false
    keyBox.ZIndex = 6
    Instance.new("UICorner", keyBox).CornerRadius = UDim.new(0, 8)
    local kbStroke = Instance.new("UIStroke", keyBox)
    kbStroke.Color = Color3.fromRGB(255, 255, 255)
    kbStroke.Thickness = 1
    kbStroke.Transparency = 0.75
    local kbPad = Instance.new("UIPadding", keyBox)
    kbPad.PaddingLeft = UDim.new(0, 10)
    kbPad.PaddingRight = UDim.new(0, 10)

    local function updateProviderUI()
        local p = providers[currentProviderIdx]
        provLabel.Text = p.name
        keyBox.Text = savedKeys[p.id] or ""
        activeKey = keyBox.Text
        if p.needsKey then
            keyTitle.Text = "API KEY"
            keyTitle.TextColor3 = C.textDim
            keyBox.TextEditable = true
            kbStroke.Transparency = 0.75
        else
            keyTitle.Text = "API KEY · not required"
            keyTitle.TextColor3 = C.textDim
            keyBox.TextEditable = false
            kbStroke.Transparency = 0.88
        end
    end

    local function switchProvider(dir)
        savedKeys[providers[currentProviderIdx].id] = keyBox.Text
        currentProviderIdx = currentProviderIdx + dir
        if currentProviderIdx < 1 then currentProviderIdx = #providers end
        if currentProviderIdx > #providers then currentProviderIdx = 1 end
        modelName = ""
        updateProviderUI()
        fetchModels()
    end

    track(provPrev.MouseEnter:Connect(function() tw(provPrev, {BackgroundTransparency = 0.68}, 0.18) end))
    track(provPrev.MouseLeave:Connect(function() tw(provPrev, {BackgroundTransparency = 0.8}, 0.22) end))
    track(provNext.MouseEnter:Connect(function() tw(provNext, {BackgroundTransparency = 0.68}, 0.18) end))
    track(provNext.MouseLeave:Connect(function() tw(provNext, {BackgroundTransparency = 0.8}, 0.22) end))
    track(provPrev.MouseButton1Click:Connect(function() switchProvider(-1) end))
    track(provNext.MouseButton1Click:Connect(function() switchProvider(1) end))

    track(keyBox:GetPropertyChangedSignal("Text"):Connect(function()
        savedKeys[providers[currentProviderIdx].id] = keyBox.Text
        activeKey = keyBox.Text
    end))

    updateProviderUI()

    section(tScroll, "models", 13)

    local modelCard = glassSurface(tScroll, 14)
    modelCard.Size = UDim2.new(1, 0, 0, 70)

    local modelNameLabel = Instance.new("TextLabel", modelCard)
    modelNameLabel.BackgroundTransparency = 1
    modelNameLabel.Size = UDim2.new(1, -110, 0, 18)
    modelNameLabel.Position = UDim2.new(0, 16, 0, 12)
    modelNameLabel.Font = Enum.Font.GothamMedium
    modelNameLabel.TextSize = 13
    modelNameLabel.TextColor3 = C.text
    modelNameLabel.TextXAlignment = Enum.TextXAlignment.Left
    modelNameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    modelNameLabel.Text = "fetching..."
    modelNameLabel.ZIndex = 6
    U.modelNameLabel = modelNameLabel

    local latencyLabel = Instance.new("TextLabel", modelCard)
    latencyLabel.BackgroundTransparency = 1
    latencyLabel.Size = UDim2.new(0, 60, 0, 12)
    latencyLabel.Position = UDim2.new(0, 16, 0, 34)
    latencyLabel.Font = Enum.Font.Gotham
    latencyLabel.TextSize = 10
    latencyLabel.TextColor3 = C.textDim
    latencyLabel.TextXAlignment = Enum.TextXAlignment.Left
    latencyLabel.Text = "—"
    latencyLabel.ZIndex = 6
    U.latencyLabel = latencyLabel

    local modelHintLabel = Instance.new("TextLabel", modelCard)
    modelHintLabel.BackgroundTransparency = 1
    modelHintLabel.Size = UDim2.new(1, -110, 0, 12)
    modelHintLabel.Position = UDim2.new(0, 16, 0, 50)
    modelHintLabel.Font = Enum.Font.Gotham
    modelHintLabel.TextSize = 10
    modelHintLabel.TextColor3 = C.textDim
    modelHintLabel.TextXAlignment = Enum.TextXAlignment.Left
    modelHintLabel.Text = "click a model to load it"
    modelHintLabel.ZIndex = 6
    U.modelHintLabel = modelHintLabel

    local refreshBtn = Instance.new("TextButton", modelCard)
    refreshBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    refreshBtn.BackgroundTransparency = 0.78
    refreshBtn.BorderSizePixel = 0
    refreshBtn.Size = UDim2.new(0, 80, 0, 32)
    refreshBtn.Position = UDim2.new(1, -96, 0.5, -16)
    refreshBtn.Font = Enum.Font.GothamBold
    refreshBtn.TextSize = 10
    refreshBtn.TextColor3 = C.text
    refreshBtn.Text = "refresh"
    refreshBtn.AutoButtonColor = false
    refreshBtn.ZIndex = 6
    Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 8)
    local rbGrad = Instance.new("UIGradient", refreshBtn)
    rbGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
    rbGrad.Rotation = 90
    local rbStroke = Instance.new("UIStroke", refreshBtn)
    rbStroke.Color = Color3.fromRGB(255, 255, 255)
    rbStroke.Thickness = 1
    rbStroke.Transparency = 0.55

    track(refreshBtn.MouseEnter:Connect(function()
        tw(refreshBtn, {BackgroundTransparency = 0.7}, 0.18)
        tweenService:Create(rbStroke, TweenInfo.new(0.18), {Transparency = 0.4}):Play()
    end))
    track(refreshBtn.MouseLeave:Connect(function()
        tw(refreshBtn, {BackgroundTransparency = 0.78}, 0.22)
        tweenService:Create(rbStroke, TweenInfo.new(0.22), {Transparency = 0.55}):Play()
    end))

    local modelListFrame = Instance.new("Frame", tScroll)
    modelListFrame.BackgroundTransparency = 1
    modelListFrame.Size = UDim2.new(1, 0, 0, 0)
    modelListFrame.AutomaticSize = Enum.AutomaticSize.Y
    modelListFrame.LayoutOrder = 15
    modelListFrame.ZIndex = 5
    local mlL = Instance.new("UIListLayout", modelListFrame)
    mlL.Padding = UDim.new(0, 6)
    mlL.SortOrder = Enum.SortOrder.LayoutOrder
    U.modelListFrame = modelListFrame

    section(tScroll, "ai", 16)
    toggleRow(tScroll, "ai enabled", true, function(v) enabled = v end, 17)
    toggleRow(tScroll, "camera follow", true, function(v) setCam(v) end, 18)
    toggleRow(tScroll, "anti-afk", true, function(v) antiAfkOn = v end, 19)

    section(tScroll, "system", 22)

    local unloadBtn = Instance.new("TextButton", tScroll)
    unloadBtn.BackgroundColor3 = Color3.fromRGB(180, 55, 70)
    unloadBtn.BackgroundTransparency = 0.15
    unloadBtn.BorderSizePixel = 0
    unloadBtn.Size = UDim2.new(1, 0, 0, 52)
    unloadBtn.Text = ""
    unloadBtn.AutoButtonColor = false
    unloadBtn.LayoutOrder = 23
    unloadBtn.ZIndex = 5
    Instance.new("UICorner", unloadBtn).CornerRadius = UDim.new(0, 10)
    local ubGrad = Instance.new("UIGradient", unloadBtn)
    ubGrad.Color = ColorSequence.new(Color3.fromRGB(220, 75, 90), Color3.fromRGB(150, 40, 55))
    ubGrad.Rotation = 90
    local ubStroke = Instance.new("UIStroke", unloadBtn)
    ubStroke.Color = Color3.fromRGB(255, 200, 210)
    ubStroke.Thickness = 1
    ubStroke.Transparency = 0.5

    local ubL = Instance.new("TextLabel", unloadBtn)
    ubL.BackgroundTransparency = 1
    ubL.Size = UDim2.new(1, 0, 0, 18)
    ubL.Position = UDim2.new(0, 16, 0, 10)
    ubL.Font = Enum.Font.GothamBold
    ubL.TextSize = 12
    ubL.TextColor3 = Color3.fromRGB(255, 245, 250)
    ubL.TextXAlignment = Enum.TextXAlignment.Left
    ubL.Text = "unload grycan"
    ubL.ZIndex = 6

    local ubS = Instance.new("TextLabel", unloadBtn)
    ubS.BackgroundTransparency = 1
    ubS.Size = UDim2.new(1, 0, 0, 12)
    ubS.Position = UDim2.new(0, 16, 0, 30)
    ubS.Font = Enum.Font.Gotham
    ubS.TextSize = 10
    ubS.TextColor3 = Color3.fromRGB(255, 200, 210)
    ubS.TextXAlignment = Enum.TextXAlignment.Left
    ubS.Text = "removes the ui and disconnects everything"
    ubS.ZIndex = 6

    track(unloadBtn.MouseEnter:Connect(function()
        tw(unloadBtn, {BackgroundTransparency = 0}, 0.18)
        tweenService:Create(ubStroke, TweenInfo.new(0.18), {Transparency = 0.35}):Play()
    end))
    track(unloadBtn.MouseLeave:Connect(function()
        tw(unloadBtn, {BackgroundTransparency = 0.15}, 0.22)
        tweenService:Create(ubStroke, TweenInfo.new(0.22), {Transparency = 0.5}):Play()
    end))
    track(unloadBtn.MouseButton1Click:Connect(function()
        if _G.__grycan_unload then _G.__grycan_unload() end
    end))

    track(refreshBtn.MouseButton1Click:Connect(fetchModels))

    local creditsPage = tabPages["credits"]
    local cPadding = Instance.new("UIPadding", creditsPage)
    cPadding.PaddingTop = UDim.new(0, 24)
    cPadding.PaddingBottom = UDim.new(0, 24)
    cPadding.PaddingLeft = UDim.new(0, 24)
    cPadding.PaddingRight = UDim.new(0, 24)

    local credCard = glassSurface(creditsPage)
    credCard.Size = UDim2.new(1, 0, 0, 260)

    local credPad = Instance.new("UIPadding", credCard)
    credPad.PaddingTop = UDim.new(0, 28)
    credPad.PaddingBottom = UDim.new(0, 28)
    credPad.PaddingLeft = UDim.new(0, 28)
    credPad.PaddingRight = UDim.new(0, 28)

    local credLayout = Instance.new("UIListLayout", credCard)
    credLayout.SortOrder = Enum.SortOrder.LayoutOrder
    credLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    credLayout.Padding = UDim.new(0, 14)

    local cIcon = Instance.new("Frame", credCard)
    cIcon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    cIcon.BackgroundTransparency = 0.8
    cIcon.BorderSizePixel = 0
    cIcon.Size = UDim2.new(0, 72, 0, 72)
    cIcon.LayoutOrder = 1
    cIcon.ZIndex = 6
    Instance.new("UICorner", cIcon).CornerRadius = UDim.new(0, 18)
    local cIconGrad = Instance.new("UIGradient", cIcon)
    cIconGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 205, 218))
    cIconGrad.Rotation = 90
    local cIconStroke = Instance.new("UIStroke", cIcon)
    cIconStroke.Color = Color3.fromRGB(255, 255, 255)
    cIconStroke.Thickness = 1
    cIconStroke.Transparency = 0.5
    local cIconImg = Instance.new("ImageLabel", cIcon)
    cIconImg.BackgroundTransparency = 1
    cIconImg.Size = UDim2.new(1, 0, 1, 0)
    cIconImg.Position = UDim2.new(0, 0, 0, 0)
    cIconImg.Image = iconId
    cIconImg.ZIndex = 7
    Instance.new("UICorner", cIconImg).CornerRadius = UDim.new(0, 18)

    local madeBy = Instance.new("TextLabel", credCard)
    madeBy.BackgroundTransparency = 1
    madeBy.Size = UDim2.new(1, 0, 0, 24)
    madeBy.Font = Enum.Font.GothamBold
    madeBy.TextSize = 17
    madeBy.TextColor3 = C.text
    madeBy.Text = "made by grycan"
    madeBy.LayoutOrder = 2
    madeBy.ZIndex = 6

    local tagline = Instance.new("TextLabel", credCard)
    tagline.BackgroundTransparency = 1
    tagline.Size = UDim2.new(1, 0, 0, 14)
    tagline.Font = Enum.Font.Gotham
    tagline.TextSize = 11
    tagline.TextColor3 = C.textMid
    tagline.Text = "join the discord for updates and support"
    tagline.LayoutOrder = 3
    tagline.ZIndex = 6

    local linkBtn = Instance.new("TextButton", credCard)
    linkBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    linkBtn.BackgroundTransparency = 0.65
    linkBtn.BorderSizePixel = 0
    linkBtn.Size = UDim2.new(1, 0, 0, 48)
    linkBtn.Text = ""
    linkBtn.AutoButtonColor = false
    linkBtn.LayoutOrder = 4
    linkBtn.ZIndex = 6
    Instance.new("UICorner", linkBtn).CornerRadius = UDim.new(0, 10)
    local lkStroke = Instance.new("UIStroke", linkBtn)
    lkStroke.Color = Color3.fromRGB(255, 255, 255)
    lkStroke.Thickness = 1
    lkStroke.Transparency = 0.72

    local linkText = Instance.new("TextLabel", linkBtn)
    linkText.BackgroundTransparency = 1
    linkText.Size = UDim2.new(1, -84, 1, 0)
    linkText.Position = UDim2.new(0, 14, 0, 0)
    linkText.Font = Enum.Font.Gotham
    linkText.TextSize = 11
    linkText.TextColor3 = C.text
    linkText.TextXAlignment = Enum.TextXAlignment.Left
    linkText.TextTruncate = Enum.TextTruncate.AtEnd
    linkText.Text = discordLink
    linkText.ZIndex = 7

    local copyBtn = Instance.new("TextButton", linkBtn)
    copyBtn.BackgroundColor3 = C.accent
    copyBtn.BorderSizePixel = 0
    copyBtn.Size = UDim2.new(0, 70, 0, 32)
    copyBtn.Position = UDim2.new(1, -70, 0.5, -16)
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.TextSize = 10
    copyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    copyBtn.Text = "copy"
    copyBtn.AutoButtonColor = false
    copyBtn.ZIndex = 7
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 8)
    local cgGrad = Instance.new("UIGradient", copyBtn)
    cgGrad.Color = ColorSequence.new(C.accentHi, C.accent)
    cgGrad.Rotation = 90
    local cgStroke = Instance.new("UIStroke", copyBtn)
    cgStroke.Color = Color3.fromRGB(255, 255, 255)
    cgStroke.Thickness = 1
    cgStroke.Transparency = 0.55
    registerAccent(copyBtn, "BackgroundColor3", "accent")
    registerAccent(cgGrad, "Color", "grad")

    track(copyBtn.MouseEnter:Connect(function() tweenService:Create(cgStroke, TweenInfo.new(0.18), {Transparency = 0.35}):Play() end))
    track(copyBtn.MouseLeave:Connect(function() tweenService:Create(cgStroke, TweenInfo.new(0.22), {Transparency = 0.55}):Play() end))

    local copiedL = Instance.new("TextLabel", credCard)
    copiedL.BackgroundTransparency = 1
    copiedL.Size = UDim2.new(1, 0, 0, 14)
    copiedL.Font = Enum.Font.GothamMedium
    copiedL.TextSize = 11
    copiedL.TextColor3 = C.green
    copiedL.Text = ""
    copiedL.TextTransparency = 1
    copiedL.LayoutOrder = 5
    copiedL.ZIndex = 6

    local function doCopy()
        if unloaded then return end
        if setclipboard then pcall(function() setclipboard(discordLink) end)
        elseif toclipboard then pcall(function() toclipboard(discordLink) end) end
        copiedL.Text = "copied to clipboard"
        copiedL.TextTransparency = 0
        task.delay(2, function()
            for i = 0, 10 do
                if unloaded then return end
                copiedL.TextTransparency = i / 10
                task.wait(0.03)
            end
        end)
    end

    track(copyBtn.MouseButton1Click:Connect(doCopy))
    track(linkBtn.MouseButton1Click:Connect(doCopy))

    local pill = Instance.new("TextButton", gui)
    pill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    pill.BackgroundTransparency = 1
    pill.BorderSizePixel = 0
    pill.Size = UDim2.new(0, 160, 0, 46)
    pill.Position = UDim2.new(0.5, -80, 0, -60)
    pill.Text = ""
    pill.AutoButtonColor = false
    pill.Visible = false
    pill.ZIndex = 200
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)

    local pillBg = Instance.new("Frame", pill)
    pillBg.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    pillBg.BackgroundTransparency = 0.82
    pillBg.BorderSizePixel = 0
    pillBg.Size = UDim2.new(1, 0, 1, 0)
    pillBg.ZIndex = 200
    Instance.new("UICorner", pillBg).CornerRadius = UDim.new(1, 0)
    local pillGrad = Instance.new("UIGradient", pillBg)
    pillGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 215, 228))
    pillGrad.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.78), NumberSequenceKeypoint.new(1, 0.88)})
    pillGrad.Rotation = 90
    local pillStroke = Instance.new("UIStroke", pillBg)
    pillStroke.Color = Color3.fromRGB(255, 255, 255)
    pillStroke.Thickness = 1
    pillStroke.Transparency = 0.5

    local pillIconBox = Instance.new("Frame", pillBg)
    pillIconBox.BackgroundTransparency = 1
    pillIconBox.Size = UDim2.new(0, 30, 0, 30)
    pillIconBox.Position = UDim2.new(0, 8, 0.5, -15)
    pillIconBox.ZIndex = 201
    Instance.new("UICorner", pillIconBox).CornerRadius = UDim.new(0, 15)
    local pillIcon = Instance.new("ImageLabel", pillIconBox)
    pillIcon.BackgroundTransparency = 1
    pillIcon.Size = UDim2.new(1, 0, 1, 0)
    pillIcon.Position = UDim2.new(0, 0, 0, 0)
    pillIcon.Image = iconId
    pillIcon.ZIndex = 202
    Instance.new("UICorner", pillIcon).CornerRadius = UDim.new(0, 15)

    local pillTitle = Instance.new("TextLabel", pillBg)
    pillTitle.BackgroundTransparency = 1
    pillTitle.Size = UDim2.new(1, -76, 1, 0)
    pillTitle.Position = UDim2.new(0, 46, 0, 0)
    pillTitle.Font = Enum.Font.GothamBold
    pillTitle.TextSize = 12
    pillTitle.TextColor3 = C.text
    pillTitle.TextXAlignment = Enum.TextXAlignment.Left
    pillTitle.Text = "grycan ai"
    pillTitle.ZIndex = 201

    local pillDot = Instance.new("Frame", pillBg)
    pillDot.BackgroundColor3 = C.red
    pillDot.BorderSizePixel = 0
    pillDot.Size = UDim2.new(0, 8, 0, 8)
    pillDot.Position = UDim2.new(1, -24, 0.5, -4)
    pillDot.ZIndex = 201
    Instance.new("UICorner", pillDot).CornerRadius = UDim.new(1, 0)
    U.pillDot = pillDot

    track(pill.MouseEnter:Connect(function() tw(pillBg, {BackgroundTransparency = 0.7}, 0.2) end))
    track(pill.MouseLeave:Connect(function() tw(pillBg, {BackgroundTransparency = 0.82}, 0.24) end))

    local minimized = false
    local function setMinimized(state)
        minimized = state
        if state then
            tw(win, {Size = UDim2.new(1, 0, 0, HEADER_H)}, 0.36, Enum.EasingStyle.Quart)
            content.Visible = false
            tabsBar.Visible = false
        else
            content.Visible = true
            tabsBar.Visible = true
            tw(win, {Size = UDim2.new(1, 0, 1, 0)}, 0.4, Enum.EasingStyle.Quart)
        end
    end

    local function hideUI()
        pill.Visible = true
        pill.Position = UDim2.new(0.5, -80, 0, -60)
        tw(pill, {Position = UDim2.new(0.5, -80, 0, 14)}, 0.46, Enum.EasingStyle.Back)
        tw(win, {BackgroundTransparency = 1}, 0.16)
        task.delay(0.16, function()
            if not unloaded then container.Visible = false end
        end)
    end

    local function showUI()
        container.Visible = true
        win.BackgroundTransparency = 0
        tw(pill, {Position = UDim2.new(0.5, -80, 0, -60)}, 0.3, Enum.EasingStyle.Cubic, Enum.EasingDirection.In)
        task.delay(0.32, function()
            if not unloaded then pill.Visible = false end
        end)
    end

    track(btnClose.MouseButton1Click:Connect(hideUI))
    track(pill.MouseButton1Click:Connect(showUI))
    track(btnMin.MouseButton1Click:Connect(function()
        setMinimized(not minimized)
    end))

    U.hideUI = hideUI
    U.showUI = showUI

    local versionTag = Instance.new("TextLabel", win)
    versionTag.BackgroundTransparency = 1
    versionTag.Size = UDim2.new(0, 120, 0, 14)
    versionTag.Position = UDim2.new(0, 14, 1, -16)
    versionTag.Font = Enum.Font.Gotham
    versionTag.TextSize = 9
    versionTag.TextColor3 = C.textDim
    versionTag.TextTransparency = 0.45
    versionTag.TextXAlignment = Enum.TextXAlignment.Left
    versionTag.Text = VERSION
    versionTag.ZIndex = 40
end

buildUI()
applyAccentToAll()

local function unload()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    connections = {}
    if camConn then pcall(function() camConn:Disconnect() end) camConn = nil end
    pcall(function() workspace.CurrentCamera.CameraType = Enum.CameraType.Custom end)
    if gui and gui.Parent then gui:Destroy() end
    _G.__grycan_loaded = false
    _G.__grycan_unload = nil
    print("[grycan] unloaded")
end

_G.__grycan_unload = unload

track(userInput.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.RightShift then unload() end
end))

track(localPlayer.Chatted:Connect(function(msg)
    if msg == "/grycan unload" or msg == "/unload" then unload()
    elseif msg == "/grycan on" then enabled = true
    elseif msg == "/grycan off" then enabled = false
    elseif msg == "/grycan show" and U.showUI then U.showUI()
    elseif msg == "/grycan hide" and U.hideUI then U.hideUI()
    end
end))

task.spawn(function()
    task.wait(0.4)
    if unloaded then return end
    fetchModels()
end)

setCam(true)
