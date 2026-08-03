--------------------------------------------------------------------------------
-- DEFENSE STATS PANEL MODULE
--------------------------------------------------------------------------------
-- Painel único (1 linha, 3 células: SR | PR | CR) que aparece ao segurar o
-- bloqueio, depois de um delay configurável. Continua visível enquanto o
-- bloqueio estiver segurado; ao soltar, permanece por mais um tempo
-- configurável antes de sumir. Mesma animação de entrada (slide-in a partir
-- do centro da tela, na direção do deslocamento configurado) usada no
-- TargetStatsPanel.
--
-- Não existe um evento nativo de "segurar bloqueio" na API do ESO, então o
-- estado é detectado por polling leve de IsBlockActive() a cada 100ms (mesma
-- granularidade que o Meterskull usa internamente pro bloqueio).
--------------------------------------------------------------------------------

local MODULE_ID = "defenseStatsPanel"

--------------------------------------------------------------------------------
-- DEFAULTS
--------------------------------------------------------------------------------
local defaults = {
    customScale     = 20,               -- 20 = escala 1.0x
    backgroundColor = { 0, 0, 0, 0.8 },
    showDelay       = 300,               -- ms segurando bloqueio antes do painel aparecer
    hideDelay       = 1500,              -- ms após soltar o bloqueio antes do painel sumir
    offsetX         = 0,                 -- deslocamento horizontal a partir do centro da tela
    offsetY         = -80,               -- deslocamento vertical a partir do centro da tela
    showBorder      = true,              -- desmarcar deixa o painel "flat" (sem borda)
    slideEnabled    = true,               -- ativa a animação de movimento (slide-in/out) do painel
    slideSpeed      = 220,                -- duração em ms do slide-in (menor = mais rápido)

    thresholds = {
        sr = {
            { value = 18000, color = { 0.9, 0.2, 0.2, 1 } },
            { value = 22000, color = { 0.9, 0.8, 0.2, 1 } },
            { value = 26000, color = { 0.2, 0.9, 0.2, 1 } },
        },
        pr = {
            { value = 18000, color = { 0.9, 0.2, 0.2, 1 } },
            { value = 22000, color = { 0.9, 0.8, 0.2, 1 } },
            { value = 26000, color = { 0.2, 0.9, 0.2, 1 } },
        },
        cr = {
            { value = 10, color = { 0.9, 0.2, 0.2, 1 } },
            { value = 20, color = { 0.9, 0.8, 0.2, 1 } },
            { value = 30, color = { 0.2, 0.9, 0.2, 1 } },
        },
    },
}

--------------------------------------------------------------------------------
-- CÁLCULOS DE STATS
--------------------------------------------------------------------------------
local function CalculateSpellResist()
    return GetPlayerStat(STAT_DAMAGE_RESIST_MAGIC)
end

local function CalculatePhysicalResist()
    return GetPlayerStat(STAT_DAMAGE_RESIST_PHYSICAL)
end

local function CalculateCritResist()
    return GetPlayerStat(STAT_CRITICAL_RESISTANCE)
end

-- Formata o valor bruto de CR junto do percentual de redução (derivado do
-- próprio valor bruto), ex: "1320 (-20%)".
local function FormatCritResist(rawValue)
    local percent = math.floor(-rawValue / 66)
    return string.format("%d (%d%%)", rawValue, percent)
end

--------------------------------------------------------------------------------
-- COR POR LIMIAR
--------------------------------------------------------------------------------
local function GetThresholdColor(thresholdList, value)
    local color = { 1, 1, 1, 1 } -- branco: abaixo de todos os limiares
    for _, level in ipairs(thresholdList) do
        if value >= level.value then
            color = level.color
        end
    end
    return color
end

--------------------------------------------------------------------------------
-- ESCALA (mesma fórmula do TargetStatsPanel: 20 = 1.0x, min 0.75x, max 1.5x)
--------------------------------------------------------------------------------
local SCALE = { MIN = 0.75, MAX = 1.5, DEFAULT_VALUE = 20 }
local BASE_SIZE = { panelW = 340, panelH = 45 } -- SR 95 + PR 95 + CR 150 (CR mais largo pro texto "1320 (-20%)")

local function CalculateScaleFactor(value)
    if value == SCALE.DEFAULT_VALUE then return 1.0 end
    if value < SCALE.DEFAULT_VALUE then
        return SCALE.MIN + (1.0 - SCALE.MIN) * (value / SCALE.DEFAULT_VALUE)
    end
    return 1.0 + (SCALE.MAX - 1.0) * ((value - SCALE.DEFAULT_VALUE) / (100 - SCALE.DEFAULT_VALUE))
end

--------------------------------------------------------------------------------
-- ANIMAÇÃO DE TRANSIÇÃO DE TEXTO (com retargeting em voo)
--------------------------------------------------------------------------------
local function EaseOutExpo(t, b, c, d)
    return c * (-math.pow(2, -10 * t / d) + 1) + b
end

local ANIM_DURATION = 300 -- ms

-- Guarda o valor efetivamente exibido no momento (não só o valor "alvo"), pra
-- que uma nova atualização durante uma animação em andamento continue de onde
-- a transição visual realmente está, em vez de "saltar".
local liveValues = { sr = 0, pr = 0, cr = 0 }

local function AnimateValue(key, control, endValue, formatter)
    local formatFn = formatter
    if type(formatter) == "string" then
        formatFn = function(v) return string.format(formatter, v) end
    end

    local startValue = liveValues[key]

    if startValue == endValue then
        control:SetText(formatFn(endValue))
        return
    end

    local animName  = control:GetName() .. "Animation"
    local startTime = GetFrameTimeMilliseconds()
    local endTime   = startTime + ANIM_DURATION

    EVENT_MANAGER:UnregisterForUpdate(animName)
    EVENT_MANAGER:RegisterForUpdate(animName, 16, function()
        local now = GetFrameTimeMilliseconds()
        if now >= endTime then
            liveValues[key] = endValue
            control:SetText(formatFn(endValue))
            EVENT_MANAGER:UnregisterForUpdate(animName)
            return
        end
        local progress = EaseOutExpo(now - startTime, 0, 1, ANIM_DURATION)
        local current = startValue + (endValue - startValue) * progress
        liveValues[key] = current
        control:SetText(formatFn(current))
    end)
end

--------------------------------------------------------------------------------
-- ESTADO DO MÓDULO
--------------------------------------------------------------------------------
local panel
local cells        = {}   -- { sr = {cell=,value=,label=}, pr = {...}, cr = {...} }
local isEnabled    = false
local isBlocking   = false
local hideTimerId  = 0
local showTimerId  = 0

--------------------------------------------------------------------------------
-- CRIAÇÃO DA UI
--------------------------------------------------------------------------------
local function CreateFieldLabel(name, parent, font, color)
    local label = CreateControl(name, parent, CT_LABEL)
    label:SetFont(font)
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    label:SetHorizontalAlignment(TEXT_ALIGN_CENTER)
    label:SetColor(unpack(color))
    return label
end

local function CreateCell(parent, name, labelText, valueFontSize)
    local cell = CreateControl(name, parent, CT_CONTROL)

    local value = CreateFieldLabel(name .. "Value", cell, "$(GAMEPAD_BOLD_FONT)|" .. valueFontSize .. "|thin-outline", { 1, 1, 1, 1 })
    value:SetAnchor(TOP, cell, TOP, 0, 4)

    local label = CreateFieldLabel(name .. "Label", cell, "$(BOLD_FONT)|13|thin-outline", { 0.5, 0.5, 0.5, 1 })
    label:SetText(labelText)
    label:SetAnchor(BOTTOM, cell, BOTTOM, 0, -4)

    return cell, value, label
end

local function ApplyBorder()
    if not panel then return end
    if CSUtils.savedVars[MODULE_ID].showBorder then
        panel.bg:SetEdgeColor(0.6, 0.6, 0.6, 0.5)
    else
        panel.bg:SetEdgeColor(0.6, 0.6, 0.6, 0)
    end
end

local function CreatePanel()
    if panel then return end

    panel = CreateControl("CSUtils_DefenseStatsPanel", GuiRoot, CT_TOPLEVELCONTROL)
    panel:SetMouseEnabled(false)
    panel:SetMovable(false)
    panel:SetHidden(true)

    local bg = CreateControl("CSUtils_DefenseStatsPanelBG", panel, CT_BACKDROP)
    bg:SetAnchor(CENTER, panel, CENTER, 0, 0)
    bg:SetCenterColor(unpack(CSUtils.savedVars[MODULE_ID].backgroundColor))
    bg:SetEdgeTexture("", 2, 2, 2)
    bg:SetInsets(2, 2, -2, -2)
    panel.bg = bg
    ApplyBorder()

    local srCell, srValue, srLabel = CreateCell(panel, "CSUtils_DSP_SR", "SR", 22)
    srCell:SetAnchor(LEFT, panel, LEFT, 0, 0)

    local prCell, prValue, prLabel = CreateCell(panel, "CSUtils_DSP_PR", "PR", 22)
    prCell:SetAnchor(LEFT, srCell, RIGHT, 0, 0)

    -- CR mostra "valor (percentual%)" (ex: "1320 (-20%)"), um texto bem mais
    -- longo que os outros dois campos, então essa célula é mais larga —
    -- mas usa a mesma fonte de SR/PR pra manter consistência visual.
    local crCell, crValue, crLabel = CreateCell(panel, "CSUtils_DSP_CR", "CR", 22)
    crCell:SetAnchor(LEFT, prCell, RIGHT, 0, 0)

    cells.sr = { cell = srCell, value = srValue, label = srLabel, baseWidth = 95,  baseFont = 22 }
    cells.pr = { cell = prCell, value = prValue, label = prLabel, baseWidth = 95,  baseFont = 22 }
    cells.cr = { cell = crCell, value = crValue, label = crLabel, baseWidth = 150, baseFont = 22 }
end

--------------------------------------------------------------------------------
-- ESCALA E POSIÇÃO
--------------------------------------------------------------------------------
local function ApplyScale(customScale)
    if not panel then return end
    local factor = CalculateScaleFactor(customScale)

    local panelW, panelH = BASE_SIZE.panelW * factor, BASE_SIZE.panelH * factor
    panel:SetDimensions(panelW, panelH)
    panel.bg:SetDimensions(panelW, panelH)

    local smallFont = '$(BOLD_FONT)|' .. tostring(13 * factor) .. '|thin-outline'

    for _, field in pairs(cells) do
        field.cell:SetDimensions(field.baseWidth * factor, BASE_SIZE.panelH * factor)
        field.value:SetFont('$(GAMEPAD_BOLD_FONT)|' .. tostring(field.baseFont * factor) .. '|thin-outline')
        field.label:SetFont(smallFont)
    end
end

local function ApplyPosition()
    if not panel then return end
    panel:ClearAnchors()
    panel:SetAnchor(TOP, GuiRoot, CENTER, CSUtils.savedVars[MODULE_ID].offsetX, CSUtils.savedVars[MODULE_ID].offsetY)
end

--------------------------------------------------------------------------------
-- ANIMAÇÃO DE ENTRADA/SAÍDA (SLIDE-IN/OUT)
--------------------------------------------------------------------------------
local SLIDE_IN_ANIM_NAME  = MODULE_ID .. "SlideIn"
local SLIDE_OUT_ANIM_NAME = MODULE_ID .. "SlideOut"

-- O painel nasce no centro da tela (posição 0,0) e desliza, com fade-in
-- simultâneo, até a posição configurada em offsetX/offsetY — a direção do
-- slide segue automaticamente o sentido do deslocamento já configurado.
local function AnimateSlideIn()
    if not panel then return end

    local targetX = CSUtils.savedVars[MODULE_ID].offsetX
    local targetY = CSUtils.savedVars[MODULE_ID].offsetY
    local enabled = CSUtils.savedVars[MODULE_ID].slideEnabled
    local duration = CSUtils.savedVars[MODULE_ID].slideSpeed

    EVENT_MANAGER:UnregisterForUpdate(SLIDE_IN_ANIM_NAME)
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_OUT_ANIM_NAME) -- cancela um slide-out em andamento, se houver

    if not enabled or (targetX == 0 and targetY == 0) then
        panel:ClearAnchors()
        panel:SetAnchor(TOP, GuiRoot, CENTER, targetX, targetY)
        panel:SetAlpha(1)
        return
    end

    local startX, startY = 0, 0
    local startTime = GetFrameTimeMilliseconds()
    local endTime   = startTime + duration

    panel:ClearAnchors()
    panel:SetAnchor(TOP, GuiRoot, CENTER, startX, startY)
    panel:SetAlpha(0)

    EVENT_MANAGER:RegisterForUpdate(SLIDE_IN_ANIM_NAME, 16, function()
        local now = GetFrameTimeMilliseconds()
        if now >= endTime then
            panel:ClearAnchors()
            panel:SetAnchor(TOP, GuiRoot, CENTER, targetX, targetY)
            panel:SetAlpha(1)
            EVENT_MANAGER:UnregisterForUpdate(SLIDE_IN_ANIM_NAME)
            return
        end
        local progress = EaseOutExpo(now - startTime, 0, 1, duration)
        local currentX = startX + (targetX - startX) * progress
        local currentY = startY + (targetY - startY) * progress
        panel:ClearAnchors()
        panel:SetAnchor(TOP, GuiRoot, CENTER, currentX, currentY)
        panel:SetAlpha(progress)
    end)
end

-- Lógica reversa do slide-in: parte da posição final configurada (onde o
-- painel já está) e desliza de volta em direção ao centro da tela, com
-- fade-out, até sumir de vez. onComplete roda quando termina (usado pra de
-- fato esconder o painel).
local function AnimateSlideOut(onComplete)
    if not panel then return end

    local startX = CSUtils.savedVars[MODULE_ID].offsetX
    local startY = CSUtils.savedVars[MODULE_ID].offsetY
    local enabled = CSUtils.savedVars[MODULE_ID].slideEnabled
    local duration = CSUtils.savedVars[MODULE_ID].slideSpeed

    EVENT_MANAGER:UnregisterForUpdate(SLIDE_IN_ANIM_NAME) -- cancela um slide-in em andamento, se houver
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_OUT_ANIM_NAME)

    if not enabled or (startX == 0 and startY == 0) then
        if onComplete then onComplete() end
        return
    end

    local endX, endY = 0, 0
    local startTime = GetFrameTimeMilliseconds()
    local endTime   = startTime + duration

    EVENT_MANAGER:RegisterForUpdate(SLIDE_OUT_ANIM_NAME, 16, function()
        local now = GetFrameTimeMilliseconds()
        if now >= endTime then
            EVENT_MANAGER:UnregisterForUpdate(SLIDE_OUT_ANIM_NAME)
            if onComplete then onComplete() end
            return
        end
        local progress = EaseOutExpo(now - startTime, 0, 1, duration)
        local currentX = startX + (endX - startX) * progress
        local currentY = startY + (endY - startY) * progress
        panel:ClearAnchors()
        panel:SetAnchor(TOP, GuiRoot, CENTER, currentX, currentY)
        panel:SetAlpha(1 - progress)
    end)
end

--------------------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------------------
local function Render(skipAnimation)
    if not panel then return end

    local sr    = CalculateSpellResist()
    local pr    = CalculatePhysicalResist()
    local crRaw = CalculateCritResist()
    local crPercent = math.floor(-crRaw / 66)

    local th = CSUtils.savedVars[MODULE_ID].thresholds
    cells.sr.value:SetColor(unpack(GetThresholdColor(th.sr, sr)))
    cells.pr.value:SetColor(unpack(GetThresholdColor(th.pr, pr)))
    cells.cr.value:SetColor(unpack(GetThresholdColor(th.cr, crPercent)))

    if skipAnimation then
        cells.sr.value:SetText(string.format("%d", sr))
        cells.pr.value:SetText(string.format("%d", pr))
        cells.cr.value:SetText(FormatCritResist(crRaw))
        liveValues.sr, liveValues.pr, liveValues.cr = sr, pr, crRaw
    else
        AnimateValue("sr", cells.sr.value, sr, "%d")
        AnimateValue("pr", cells.pr.value, pr, "%d")
        AnimateValue("cr", cells.cr.value, crRaw, FormatCritResist)
    end
end

--------------------------------------------------------------------------------
-- VISIBILIDADE / TIMERS DE DELAY
--------------------------------------------------------------------------------
local function StopTicking()
    EVENT_MANAGER:UnregisterForUpdate(MODULE_ID .. "Render")
end

local function Hide()
    if not panel then return end
    panel:SetHidden(true)
    panel:SetAlpha(1) -- garante que a próxima aparição não comece semi-transparente
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_IN_ANIM_NAME)
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_OUT_ANIM_NAME)
    StopTicking()
end

-- Some com o slide-out (parte da posição final e volta pro centro, com
-- fade), e só marca o painel como hidden quando a animação termina.
local function HideAnimated()
    if not panel or panel:IsHidden() then return end
    StopTicking()
    AnimateSlideOut(Hide)
end

local function CancelHideTimer()
    hideTimerId = hideTimerId + 1
end

local function ScheduleHide()
    hideTimerId = hideTimerId + 1
    local myTimer = hideTimerId
    zo_callLater(function()
        if myTimer ~= hideTimerId then return end -- bloqueio foi ativado de novo antes do delay acabar
        HideAnimated()
    end, CSUtils.savedVars[MODULE_ID].hideDelay)
end

-- Roda a cada 500ms enquanto o painel está visível, pra manter os valores
-- atualizados (buffs/debuffs de resistência podem mudar durante o bloqueio).
local function Tick()
    Render(false)
end

local function Show()
    if not panel then return end
    local wasHidden = panel:IsHidden()
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_OUT_ANIM_NAME) -- cancela um slide-out em andamento, se houver
    panel:SetHidden(false)
    StopTicking()
    EVENT_MANAGER:RegisterForUpdate(MODULE_ID .. "Render", 500, Tick)
    if wasHidden then
        AnimateSlideIn()
    else
        -- Painel ainda "visível" (interrompemos um slide-out em andamento):
        -- só garante que volte pra posição final, totalmente opaco.
        ApplyPosition()
        panel:SetAlpha(1)
    end
end

local function CancelShowTimer()
    showTimerId = showTimerId + 1
end

local function ScheduleShow()
    local delay = CSUtils.savedVars[MODULE_ID].showDelay
    if delay <= 0 then
        Show()
        Render(true)
        return
    end
    showTimerId = showTimerId + 1
    local myTimer = showTimerId
    zo_callLater(function()
        if myTimer ~= showTimerId then return end -- o bloqueio foi solto antes do delay acabar
        if not isBlocking then return end
        Show()
        Render(true)
    end, delay)
end

--------------------------------------------------------------------------------
-- EVENTOS
--------------------------------------------------------------------------------
local function OnBlockStateChanged(nowBlocking)
    if not isEnabled then return end
    if nowBlocking then
        CancelHideTimer()
        if panel and not panel:IsHidden() then
            Render(false)
        else
            ScheduleShow()
        end
    else
        CancelShowTimer()
        if panel and not panel:IsHidden() then
            ScheduleHide()
        end
    end
end

-- Não existe evento nativo de "segurar bloqueio"; detectamos por polling
-- leve, comparando o estado atual com o do tick anterior.
local function CheckBlockState()
    local nowBlocking = IsBlockActive()
    if nowBlocking ~= isBlocking then
        isBlocking = nowBlocking
        OnBlockStateChanged(isBlocking)
    end
end

local function OnPlayerDead()
    isBlocking = false
    CancelShowTimer()
    CancelHideTimer()
    Hide()
end

local function RegisterEvents()
    EVENT_MANAGER:RegisterForUpdate(MODULE_ID .. "BlockPoll", 100, CheckBlockState)
    EVENT_MANAGER:RegisterForEvent(MODULE_ID, EVENT_PLAYER_DEAD, OnPlayerDead)
end

local function UnregisterEvents()
    EVENT_MANAGER:UnregisterForUpdate(MODULE_ID .. "BlockPoll")
    EVENT_MANAGER:UnregisterForEvent(MODULE_ID, EVENT_PLAYER_DEAD)
end

--------------------------------------------------------------------------------
-- ENABLE / DISABLE (hot toggle)
--------------------------------------------------------------------------------
local function EnableModule()
    if isEnabled then return end
    isEnabled = true
    RegisterEvents()
end

local function DisableModule()
    if not isEnabled then return end
    isEnabled = false
    UnregisterEvents()
    isBlocking = false
    CancelShowTimer()
    CancelHideTimer()
    Hide()
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------
local function Init()
    CreatePanel()
    ApplyScale(CSUtils.savedVars[MODULE_ID].customScale)
    ApplyPosition()

    if CSUtils.savedVars.modules[MODULE_ID] then
        EnableModule()
    end
end

--------------------------------------------------------------------------------
-- CONTROLES DE LIMIAR DE COR (LAM)
--------------------------------------------------------------------------------
local THRESHOLD_LEVEL_NAMES = { "Baixo", "Médio", "Alto" }

local function BuildThresholdControls(statKey, statTitle)
    local controls = { { type = "header", name = statTitle } }
    for i = 1, 3 do
        table.insert(controls, {
            type = "editbox",
            name = THRESHOLD_LEVEL_NAMES[i] .. " - Valor",
            width = "half",
            isMultiline = false,
            getFunc = function() return tostring(CSUtils.savedVars[MODULE_ID].thresholds[statKey][i].value) end,
            setFunc = function(v)
                local num = tonumber(v)
                if num then
                    CSUtils.savedVars[MODULE_ID].thresholds[statKey][i].value = num
                end
            end,
        })
        table.insert(controls, {
            type = "colorpicker",
            name = THRESHOLD_LEVEL_NAMES[i] .. " - Cor",
            width = "half",
            getFunc = function() return unpack(CSUtils.savedVars[MODULE_ID].thresholds[statKey][i].color) end,
            setFunc = function(r, g, b, a)
                CSUtils.savedVars[MODULE_ID].thresholds[statKey][i].color = { r, g, b, a }
            end,
        })
    end
    return controls
end

local function BuildAllThresholdControls()
    local all = {
        { type = "description", text = "Define, pra cada atributo, o valor mínimo em que cada cor passa a valer. O maior limiar atingido é o que vale; abaixo de todos, o texto fica branco." },
    }
    for _, entry in ipairs({
        { key = "sr", title = "SR (Resistência Mágica)" },
        { key = "pr", title = "PR (Resistência Física)"  },
        { key = "cr", title = "CR (Resistência Crítica, %)" },
    }) do
        for _, control in ipairs(BuildThresholdControls(entry.key, entry.title)) do
            table.insert(all, control)
        end
    end
    return all
end

--------------------------------------------------------------------------------
-- REGISTRO DO MÓDULO NO CORE
--------------------------------------------------------------------------------
CSUtils:RegisterModule(
    MODULE_ID,
    "Painel Defensivo (Bloqueio)",
    "Mostra Resistência a Feitiço, Resistência Física e Resistência Crítica num painel que aparece ao segurar o bloqueio.",
    Init,
    true, -- supportsHotToggle
    {
        defaults = defaults,
        onToggle = function(value)
            if value then
                EnableModule()
            else
                DisableModule()
            end
        end,
        buildSettings = function()
            return {
                {
                    type = "slider",
                    name = "Delay para Exibir (ms)",
                    tooltip = "Tempo segurando o bloqueio antes do painel aparecer.",
                    min = 0, max = 2000, step = 50,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].showDelay end,
                    setFunc = function(v) CSUtils.savedVars[MODULE_ID].showDelay = v end,
                    default = defaults.showDelay,
                },
                {
                    type = "slider",
                    name = "Delay para Sumir (ms)",
                    tooltip = "Tempo de espera, após soltar o bloqueio, antes do painel sumir.",
                    min = 0, max = 6000, step = 100,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].hideDelay end,
                    setFunc = function(v) CSUtils.savedVars[MODULE_ID].hideDelay = v end,
                    default = defaults.hideDelay,
                },
                {
                    type = "slider",
                    name = "Escala do Painel",
                    tooltip = "Ajusta o tamanho do painel (20 = 100%).",
                    min = 0, max = 100, step = 1,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].customScale end,
                    setFunc = function(v)
                        CSUtils.savedVars[MODULE_ID].customScale = v
                        ApplyScale(v)
                    end,
                    default = defaults.customScale,
                },
                {
                    type = "slider",
                    name = "Deslocamento Horizontal",
                    tooltip = "Distância horizontal a partir do centro da tela.",
                    min = -400, max = 400, step = 5,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].offsetX end,
                    setFunc = function(v)
                        CSUtils.savedVars[MODULE_ID].offsetX = v
                        ApplyPosition()
                    end,
                    default = defaults.offsetX,
                },
                {
                    type = "slider",
                    name = "Deslocamento Vertical",
                    tooltip = "Distância vertical a partir do centro da tela.",
                    min = -400, max = 400, step = 5,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].offsetY end,
                    setFunc = function(v)
                        CSUtils.savedVars[MODULE_ID].offsetY = v
                        ApplyPosition()
                    end,
                    default = defaults.offsetY,
                },
                {
                    type = "colorpicker",
                    name = "Cor de Fundo",
                    getFunc = function() return unpack(CSUtils.savedVars[MODULE_ID].backgroundColor) end,
                    setFunc = function(r, g, b, a)
                        CSUtils.savedVars[MODULE_ID].backgroundColor = { r, g, b, a }
                        if panel then panel.bg:SetCenterColor(r, g, b, a) end
                    end,
                    default = { unpack(defaults.backgroundColor) },
                },
                {
                    type = "checkbox",
                    name = "Mostrar Borda",
                    tooltip = "Desmarque para um visual flat, sem contorno ao redor do painel.",
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].showBorder end,
                    setFunc = function(v)
                        CSUtils.savedVars[MODULE_ID].showBorder = v
                        ApplyBorder()
                    end,
                    default = defaults.showBorder,
                },
                {
                    type = "checkbox",
                    name = "Animação de Movimento (Slide-In/Out)",
                    tooltip = "Liga/desliga o slide do painel: ao aparecer, nasce no centro e desliza até a posição configurada; ao sumir, faz o caminho inverso. A direção segue automaticamente o deslocamento definido acima.",
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].slideEnabled end,
                    setFunc = function(v) CSUtils.savedVars[MODULE_ID].slideEnabled = v end,
                    default = defaults.slideEnabled,
                },
                {
                    type = "slider",
                    name = "Velocidade do Slide-in (ms)",
                    tooltip = "Duração da animação de entrada. Valores menores = movimento mais rápido.",
                    min = 50, max = 800, step = 10,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].slideSpeed end,
                    setFunc = function(v) CSUtils.savedVars[MODULE_ID].slideSpeed = v end,
                    default = defaults.slideSpeed,
                },
                {
                    type = "submenu",
                    name = "Cores por Limiar",
                    tooltip = "Configura as cores de SR, PR e CR conforme o valor atingido.",
                    controls = BuildAllThresholdControls(),
                },
            }
        end,
    }
)