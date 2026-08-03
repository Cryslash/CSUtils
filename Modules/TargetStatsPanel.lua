--------------------------------------------------------------------------------
-- TARGET STATS PANEL MODULE
--------------------------------------------------------------------------------
-- Painel único (grade 2x2: PWR/PEN em cima, CC/CD embaixo) que aparece ancorado
-- ao centro da tela (posição da retícula) sempre que a retícula passar sobre um
-- alvo HOSTIL. Some com um pequeno delay quando nenhum alvo válido está mais sob
-- a retícula; ao trocar de alvo, os valores são animados suavemente (mesma
-- transição usada pra atualizações normais, com retargeting em voo caso uma
-- animação seja interrompida por outra troca).
--
-- Arquitetura de cálculo de stats inspirada no addon Meterskull (Powerskull,
-- Penskull e Critskull), reescrita e condensada num único módulo do CS Utils.
--------------------------------------------------------------------------------

local MODULE_ID = "targetStatsPanel"

--------------------------------------------------------------------------------
-- DEFAULTS
--------------------------------------------------------------------------------
local defaults = {
    customScale     = 20,               -- 20 = escala 1.0x (mesmo esquema do Meterskull)
    backgroundColor = { 0, 0, 0, 0.8 },
    hideDelay       = 3000,              -- ms de espera antes de sumir sem alvo válido
    showDelay       = 0,                 -- ms de espera antes de exibir o painel ao mirar um alvo válido
    offsetX         = 0,                 -- deslocamento horizontal a partir do centro da tela
    offsetY         = 40,                -- deslocamento vertical a partir do centro da tela
    onlyInCombat    = false,             -- só mostra o painel enquanto o jogador está em combate
    showBorder      = true,              -- desmarcar deixa o painel "flat" (sem borda)
    slideEnabled    = true,               -- ativa a animação de movimento (slide-in/out) do painel
    slideSpeed      = 220,                -- duração em ms do slide-in (menor = mais rápido)

    -- Cores por limiar (3 níveis por atributo, aplicados em ordem crescente).
    -- O valor exibido usa a cor do maior limiar que ele alcançar; abaixo de
    -- todos os limiares, usa branco.
    thresholds = {
        pwr = {
            { value = 3200, color = { 0.9, 0.2, 0.2, 1 } },
            { value = 3800, color = { 0.9, 0.8, 0.2, 1 } },
            { value = 4300, color = { 0.2, 0.9, 0.2, 1 } },
        },
        pen = {
            { value = 1000, color = { 0.9, 0.2, 0.2, 1 } },
            { value = 3000, color = { 0.9, 0.8, 0.2, 1 } },
            { value = 5000, color = { 0.2, 0.9, 0.2, 1 } },
        },
        cc = {
            { value = 40, color = { 0.9, 0.2, 0.2, 1 } },
            { value = 55, color = { 0.9, 0.8, 0.2, 1 } },
            { value = 70, color = { 0.2, 0.9, 0.2, 1 } },
        },
        cd = {
            { value = 80,  color = { 0.9, 0.2, 0.2, 1 } },
            { value = 100, color = { 0.9, 0.8, 0.2, 1 } },
            { value = 120, color = { 0.2, 0.9, 0.2, 1 } },
        },
    },
}

--------------------------------------------------------------------------------
-- TABELAS DE DEBUFFS NO ALVO (mesma base usada no Meterskull)
--------------------------------------------------------------------------------
local targetPenDebuffs = {
    [61742]  = 2974,  -- Minor Breach
    [61743]  = 5948,  -- Major Breach
    [120007] = 2108,  -- Infused Crusher Dummy
    [17906]  = 2108,  -- Infused Crusher
    [120018] = 6000,  -- Alkosh Dummy
    [76667]  = 6000,  -- Alkosh
    [159288] = 3541,  -- Crimson Oath
    [143808] = 1000,  -- Crystal Weapon
    [187742] = 2200,  -- Runic Sunder
}

local targetDebuffsFoN = {
    [18084]  = 660,   -- Burning
    [21929]  = 660,   -- Poisoned
    [148801] = 660,   -- Hemorrhaging
    [88401]  = 660,   -- Minor Magickasteal (work-around)
    [145875] = 660,   -- Minor Brittle (work-around)
    [79717]  = 660,   -- Minor Vulnerability (work-around)
    [61742]  = 660,   -- Minor Breach (work-around)
    [61726]  = 660,   -- Minor Defile (work-around)
}

local targetCritDebuffs = {
    [142610] = 5,   -- Flame Weakness
    [142652] = 5,   -- Frost Weakness
    [142653] = 5,   -- Shock Weakness
    [181606] = 15,  -- Elemental Catalyst (Target Dummy)
    [145975] = 10,  -- Minor Brittle
    [145977] = 20,  -- Major Brittle
}

--------------------------------------------------------------------------------
-- CÁLCULOS DE STATS
--------------------------------------------------------------------------------
local function IsForceOfNatureSlotted()
    for disciplineIndex = 1, 12 do
        if GetSlotBoundId(disciplineIndex, HOTBAR_CATEGORY_CHAMPION) == 276 then
            return true
        end
    end
    return false
end

local function IsBackstabberSlotted()
    for disciplineIndex = 1, 12 do
        if GetSlotBoundId(disciplineIndex, HOTBAR_CATEGORY_CHAMPION) == 31 then
            return true
        end
    end
    return false
end

local function GetTargetDebuffTotal(debuffTable)
    local total = 0
    if DoesUnitExist("reticleover") and not IsUnitPlayer("reticleover") then
        for i = 1, GetNumBuffs("reticleover") do
            local _, _, _, _, _, _, _, _, _, _, abilityId = GetUnitBuffInfo("reticleover", i)
            if debuffTable[abilityId] then
                total = total + debuffTable[abilityId]
            end
        end
    end
    return total
end

local function CalculatePower()
    return math.max(GetPlayerStat(STAT_POWER), GetPlayerStat(STAT_SPELL_POWER))
end

local function CalculatePenetration()
    local buffTotal = 0
    if IsForceOfNatureSlotted() then
        buffTotal = buffTotal + GetTargetDebuffTotal(targetDebuffsFoN)
    end
    local total = buffTotal + GetTargetDebuffTotal(targetPenDebuffs)

    local physicalPen = GetPlayerStat(STAT_PHYSICAL_PENETRATION) + total
    local spellPen    = GetPlayerStat(STAT_SPELL_PENETRATION)    + total
    return math.max(physicalPen, spellPen)
end

local function CalculateCritChance()
    return math.max(GetPlayerStat(STAT_SPELL_CRITICAL), GetPlayerStat(STAT_CRITICAL_STRIKE)) / 219.12
end

local function CalculateCritDamage()
    local _, _, advCritDamage = GetAdvancedStatValue(ADVANCED_STAT_DISPLAY_TYPE_CRITICAL_DAMAGE)
    local cpMod = IsBackstabberSlotted() and 10 or 0
    local debuffMod = GetTargetDebuffTotal(targetCritDebuffs)
    return 50 + advCritDamage + cpMod + debuffMod
end

--------------------------------------------------------------------------------
-- VALIDAÇÃO DE ALVO
--------------------------------------------------------------------------------
-- Bonecos de treino são nomeados pela Zenimax quase sempre com o prefixo
-- "Target " (Target Skeleton, Target Iron Atronach, Target Dro-m'Athra,
-- Target Minotaur Handler, Target Bloodknight, Target Centurion, Target Bone
-- Goliath...), e o "Trial Target Dummy (Perfected)" foge um pouco do padrão.
-- Detecção por nome é a mesma técnica usada por addons como o Combat
-- Metrics pra reconhecer dummies sem uma flag oficial da API.
local DUMMY_NAME_PATTERNS = {
    "^Target ",
    "^Robust Target ",
    "Target Dummy",
    "^The Precursor$",
    "^Prenúncio$",    
    "^Alvo ",
    "^Centurião Alvo,",
    " Robusto$",
}

local function IsTargetDummy()
    local name = GetUnitName("reticleover")
    if not name then return false end
    for _, pattern in ipairs(DUMMY_NAME_PATTERNS) do
        if name:find(pattern) then return true end
    end
    return false
end

local function IsValidTarget()
    if not DoesUnitExist("reticleover") then return false end
    if IsUnitDead("reticleover") then return false end

    local isHostile = GetUnitReaction("reticleover") == UNIT_REACTION_HOSTILE
    if not isHostile and not IsTargetDummy() then return false end

    if CSUtils.savedVars[MODULE_ID].onlyInCombat and not IsUnitInCombat("player") then return false end
    return true
end

--------------------------------------------------------------------------------
-- COR POR LIMIAR (mesma ideia do GetThresholdColor do Meterskull)
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
-- ESCALA (mesma fórmula do Meterskull: 20 = 1.0x, min 0.75x, max 1.5x)
--------------------------------------------------------------------------------
local SCALE = { MIN = 0.75, MAX = 1.5, DEFAULT_VALUE = 20 }
local BASE_SIZE = { panelW = 190, panelH = 90, cellW = 95, cellH = 45 }

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
-- que uma nova troca de alvo durante uma animação em andamento continue de
-- onde a transição visual realmente está, em vez de "saltar" pro valor antigo.
local liveValues = { pwr = 0, pen = 0, cc = 0, cd = 0 }

local function AnimateValue(key, control, endValue, formatString)
    local startValue = liveValues[key]

    if startValue == endValue then
        control:SetText(string.format(formatString, endValue))
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
            control:SetText(string.format(formatString, endValue))
            EVENT_MANAGER:UnregisterForUpdate(animName)
            return
        end
        local progress = EaseOutExpo(now - startTime, 0, 1, ANIM_DURATION)
        local current = startValue + (endValue - startValue) * progress
        liveValues[key] = current
        control:SetText(string.format(formatString, current))
    end)
end

--------------------------------------------------------------------------------
-- ESTADO DO MÓDULO
--------------------------------------------------------------------------------
local panel
local cells       = {}   -- { pwr = {cell=,value=,label=}, pen = {...}, cc = {...}, cd = {...} }
local isEnabled   = false
local hideTimerId = 0
local showTimerId = 0

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

local function CreateCell(parent, name, labelText, anchorPoint)
    local cell = CreateControl(name, parent, CT_CONTROL)
    cell:SetAnchor(anchorPoint, parent, anchorPoint, 0, 0)

    local value = CreateFieldLabel(name .. "Value", cell, "$(GAMEPAD_BOLD_FONT)|22|thin-outline", { 1, 1, 1, 1 })
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

    panel = CreateControl("CSUtils_TargetStatsPanel", GuiRoot, CT_TOPLEVELCONTROL)
    panel:SetMouseEnabled(false)
    panel:SetMovable(false)
    panel:SetHidden(true)

    local bg = CreateControl("CSUtils_TargetStatsPanelBG", panel, CT_BACKDROP)
    bg:SetAnchor(CENTER, panel, CENTER, 0, 0)
    bg:SetCenterColor(unpack(CSUtils.savedVars[MODULE_ID].backgroundColor))
    bg:SetEdgeTexture("", 2, 2, 2)
    bg:SetInsets(2, 2, -2, -2)
    panel.bg = bg
    ApplyBorder()

    local pwrCell, pwrValue, pwrLabel = CreateCell(panel, "CSUtils_TSP_PWR", "PWR", TOPLEFT)
    local penCell, penValue, penLabel = CreateCell(panel, "CSUtils_TSP_PEN", "PEN", TOPRIGHT)
    local ccCell,  ccValue,  ccLabel  = CreateCell(panel, "CSUtils_TSP_CC",  "CC",  BOTTOMLEFT)
    local cdCell,  cdValue,  cdLabel  = CreateCell(panel, "CSUtils_TSP_CD",  "CD",  BOTTOMRIGHT)

    cells.pwr = { cell = pwrCell, value = pwrValue, label = pwrLabel }
    cells.pen = { cell = penCell, value = penValue, label = penLabel }
    cells.cc  = { cell = ccCell,  value = ccValue,  label = ccLabel  }
    cells.cd  = { cell = cdCell,  value = cdValue,  label = cdLabel  }
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

    local cellW, cellH = BASE_SIZE.cellW * factor, BASE_SIZE.cellH * factor
    local bigFont   = '$(GAMEPAD_BOLD_FONT)|' .. tostring(22 * factor) .. '|thin-outline'
    local smallFont = '$(BOLD_FONT)|' .. tostring(13 * factor) .. '|thin-outline'

    for _, field in pairs(cells) do
        field.cell:SetDimensions(cellW, cellH)
        field.value:SetFont(bigFont)
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

-- O painel nasce no centro da tela (posição 0,0 = a própria retícula) e
-- desliza, com fade-in simultâneo, até a posição configurada em offsetX/
-- offsetY. Ou seja, a direção do slide segue automaticamente o sentido do
-- deslocamento já configurado: se o painel fica acima e à direita da
-- retícula, ele desliza de baixo-esquerda (centro) pra cima-direita.
local function AnimateSlideIn()
    if not panel then return end

    local targetX = CSUtils.savedVars[MODULE_ID].offsetX
    local targetY = CSUtils.savedVars[MODULE_ID].offsetY
    local enabled = CSUtils.savedVars[MODULE_ID].slideEnabled
    local duration = CSUtils.savedVars[MODULE_ID].slideSpeed

    EVENT_MANAGER:UnregisterForUpdate(SLIDE_IN_ANIM_NAME)
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_OUT_ANIM_NAME) -- cancela um slide-out em andamento, se houver

    -- Sem deslocamento configurado não há "sentido" pra deslizar, e com o
    -- slide desativado o painel só aparece direto na posição final.
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
-- painel já está) e desliza de volta em direção ao centro da tela (a
-- retícula), com fade-out, até sumir de vez. onComplete roda quando termina
-- (usado pra de fato esconder o painel).
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

    local pwr = CalculatePower()
    local pen = CalculatePenetration()
    local cc  = CalculateCritChance()
    local cd  = CalculateCritDamage()

    local th = CSUtils.savedVars[MODULE_ID].thresholds
    cells.pwr.value:SetColor(unpack(GetThresholdColor(th.pwr, pwr)))
    cells.pen.value:SetColor(unpack(GetThresholdColor(th.pen, pen)))
    cells.cc.value:SetColor(unpack(GetThresholdColor(th.cc, cc)))
    cells.cd.value:SetColor(unpack(GetThresholdColor(th.cd, cd)))

    if skipAnimation then
        cells.pwr.value:SetText(string.format("%d", pwr))
        cells.pen.value:SetText(string.format("%d", pen))
        cells.cc.value:SetText(string.format("%.1f%%", cc))
        cells.cd.value:SetText(string.format("%d%%", cd))
        liveValues.pwr, liveValues.pen, liveValues.cc, liveValues.cd = pwr, pen, cc, cd
    else
        AnimateValue("pwr", cells.pwr.value, pwr, "%d")
        AnimateValue("pen", cells.pen.value, pen, "%d")
        AnimateValue("cc",  cells.cc.value,  cc,  "%.1f%%")
        AnimateValue("cd",  cells.cd.value,  cd,  "%d%%")
    end
end

--------------------------------------------------------------------------------
-- VISIBILIDADE / TIMER DE DELAY
--------------------------------------------------------------------------------
local function StopTicking()
    EVENT_MANAGER:UnregisterForUpdate(MODULE_ID .. "Render")
end

local function Hide()
    if not panel then return end
    panel:SetHidden(true)
    panel:SetAlpha(1) -- garante que uma próxima aparição não comece semi-transparente
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_IN_ANIM_NAME)
    EVENT_MANAGER:UnregisterForUpdate(SLIDE_OUT_ANIM_NAME)
    StopTicking()
end

-- Some com o slide-out (parte da posição final e volta pra retícula, com
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
        if myTimer ~= hideTimerId then return end -- um novo alvo válido cancelou este timer
        HideAnimated()
    end, CSUtils.savedVars[MODULE_ID].hideDelay)
end

-- Roda enquanto o painel está visível: se o alvo sob a retícula morrer (ou
-- deixar de ser válido por qualquer outro motivo) sem que o evento de troca
-- de retícula dispare, este tick pega a mudança e agenda o sumiço.
local function Tick()
    if not IsValidTarget() then
        StopTicking()
        ScheduleHide()
        return
    end
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
        if myTimer ~= showTimerId then return end -- o alvo saiu da retícula antes do delay acabar
        if not IsValidTarget() then return end
        Show()
        Render(true)
    end, delay)
end

--------------------------------------------------------------------------------
-- EVENTOS
--------------------------------------------------------------------------------
local function OnReticleTargetChanged()
    if not isEnabled then return end
    if IsValidTarget() then
        CancelHideTimer()
        if panel and not panel:IsHidden() then
            -- painel já visível, só trocou de alvo: atualiza suavemente, sem delay de exibição
            Render(false)
        else
            -- painel escondido: respeita o delay de exibição configurado
            ScheduleShow()
        end
    else
        CancelShowTimer()
        ScheduleHide()
    end
end

local function OnWeaponSwap()
    if panel and not panel:IsHidden() then
        Render(false)
    end
end

local function OnPlayerDead()
    CancelHideTimer()
    Hide()
end

local function OnCombatStateChanged(_, inCombat)
    if not isEnabled then return end
    if not CSUtils.savedVars[MODULE_ID].onlyInCombat then return end
    if inCombat then
        OnReticleTargetChanged() -- reavalia: mostra se a retícula já estiver sobre um alvo válido
    else
        ScheduleHide()
    end
end

local function RegisterEvents()
    EVENT_MANAGER:RegisterForEvent(MODULE_ID, EVENT_RETICLE_TARGET_CHANGED, OnReticleTargetChanged)
    EVENT_MANAGER:RegisterForEvent(MODULE_ID, EVENT_ACTIVE_WEAPON_PAIR_CHANGED, OnWeaponSwap)
    EVENT_MANAGER:RegisterForEvent(MODULE_ID, EVENT_PLAYER_DEAD, OnPlayerDead)
    EVENT_MANAGER:RegisterForEvent(MODULE_ID, EVENT_PLAYER_COMBAT_STATE, OnCombatStateChanged)
end

local function UnregisterEvents()
    EVENT_MANAGER:UnregisterForEvent(MODULE_ID, EVENT_RETICLE_TARGET_CHANGED)
    EVENT_MANAGER:UnregisterForEvent(MODULE_ID, EVENT_ACTIVE_WEAPON_PAIR_CHANGED)
    EVENT_MANAGER:UnregisterForEvent(MODULE_ID, EVENT_PLAYER_DEAD)
    EVENT_MANAGER:UnregisterForEvent(MODULE_ID, EVENT_PLAYER_COMBAT_STATE)
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
        { key = "pwr", title = "PWR" },
        { key = "pen", title = "PEN" },
        { key = "cc",  title = "CC"  },
        { key = "cd",  title = "CD"  },
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
    "Painel de Atributos do Alvo",
    "Mostra Poder, Penetração, Chance Crítica e Dano Crítico num painel único que aparece ancorado à retícula ao mirar num inimigo.",
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
                    type = "checkbox",
                    name = "Mostrar apenas em combate",
                    tooltip = "Se marcado, o painel só aparece enquanto o jogador estiver em combate, mesmo com a retícula sobre um inimigo.",
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].onlyInCombat end,
                    setFunc = function(v) CSUtils.savedVars[MODULE_ID].onlyInCombat = v end,
                    default = defaults.onlyInCombat,
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
                    name = "Delay para Exibir (ms)",
                    tooltip = "Tempo de espera, após a retícula mirar um alvo válido, antes do painel aparecer.",
                    min = 0, max = 3000, step = 50,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].showDelay end,
                    setFunc = function(v) CSUtils.savedVars[MODULE_ID].showDelay = v end,
                    default = defaults.showDelay,
                },
                {
                    type = "slider",
                    name = "Delay para Sumir (ms)",
                    tooltip = "Tempo de espera, após perder o alvo válido, antes do painel sumir.",
                    min = 500, max = 6000, step = 100,
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].hideDelay end,
                    setFunc = function(v) CSUtils.savedVars[MODULE_ID].hideDelay = v end,
                    default = defaults.hideDelay,
                },
                {
                    type = "slider",
                    name = "Deslocamento Horizontal",
                    tooltip = "Distância horizontal a partir do centro da tela (posição da retícula).",
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
                    tooltip = "Distância vertical a partir do centro da tela (posição da retícula).",
                    min = -200, max = 200, step = 5,
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
                    tooltip = "Liga/desliga o slide do painel: ao aparecer, nasce no centro (retícula) e desliza até a posição configurada; ao sumir, faz o caminho inverso. A direção segue automaticamente o deslocamento horizontal/vertical definido acima.",
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
                    tooltip = "Configura as cores de PWR, PEN, CC e CD conforme o valor atingido.",
                    controls = BuildAllThresholdControls(),
                },
            }
        end,
    }
)