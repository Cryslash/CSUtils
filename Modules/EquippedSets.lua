CSUtilsEquippedSets = CSUtilsEquippedSets or {}

local moduleID = "EquippedSets"
local moduleTitle = "Sets Equipados"
local moduleDesc = "Exibe os sets equipados na tela, ordenados do maior para o menor."

local ES = CSUtilsEquippedSets
local MAX_ROWS = 14

local DEFAULTS = {
    hideInCombat = true,
    unlockPosition = false,
    left = 1000,
    top = 500,
    headColor = { 0.8353, 0.7922, 0.8039, 1 },
    completeColor = { 0.4941, 1, 0.5098, 1 },
    incompleteColor = { 1, 0.3490, 0.2706, 1 },
    warningColor = { 1, 0.8118, 0.2549, 1 },
}

local rows = {}
local uiHidden = false
local inCombat = false

local function IsModuleEnabled()
    return CSUtils.savedVars.modules[moduleID]
end

local function GetSavedVars()
    return CSUtils.savedVars[moduleID]
end

local function IsUnlocked()
    return GetSavedVars().unlockPosition
end

local function GetLibLanguage()
    return string.lower(GetCVar("language.2") or "en")
end

function ES.SavePosition()
    local sv = GetSavedVars()
    sv.left = CSUtilsEquippedSetsFrame:GetLeft()
    sv.top = CSUtilsEquippedSetsFrame:GetTop()
end

local function RestorePosition()
    local sv = GetSavedVars()

    CSUtilsEquippedSetsFrame:ClearAnchors()
    CSUtilsEquippedSetsFrame:SetAnchor(
        TOPLEFT,
        GuiRoot,
        TOPLEFT,
        sv.left or DEFAULTS.left,
        sv.top or DEFAULTS.top
    )
end

local function ResetRows()
    for i = 1, MAX_ROWS do
        rows[i]:SetHidden(true)
    end
end

local function HideFrame()

    if IsUnlocked() then
        return
    end

    if not uiHidden then
        CSUtilsEquippedSetsFrame:SetHidden(true)
        uiHidden = true
    end
end

local function ShowFrame()

    if IsModuleEnabled() then
        CSUtilsEquippedSetsFrame:SetHidden(false)
        uiHidden = false
    end
end

local function OnCombatStateChanged()

    inCombat = IsUnitInCombat("player")

    if IsUnlocked() then
        ES.UpdateDisplay()
        return
    end

    if inCombat and GetSavedVars().hideInCombat then
        HideFrame()
    else
        ES.UpdateDisplay()
    end
end

local function OnReticleHiddenUpdate(_, hidden)

    if IsUnlocked() then
        return
    end

    if hidden and not uiHidden then
        HideFrame()
    elseif not hidden then
        OnCombatStateChanged()
    end
end

local function CountEquippedPieces(info)

    local totalEquipped = 0
    local highestBarCount = 0

    for location, numEquipped in pairs(info.numEquipped) do

        if location == "body" then
            totalEquipped = totalEquipped + numEquipped

        elseif numEquipped > highestBarCount then

            totalEquipped = (totalEquipped + numEquipped) - highestBarCount
            highestBarCount = numEquipped

        end
    end

    return totalEquipped
end

local function BuildSetEntries(equippedSets)

    local LSD = LibSetDetection
    local LS = LibSets
    local lang = GetLibLanguage()

    local entries = {}

    for setId, info in pairs(equippedSets) do

        local setName = info.name

        if setName == "" then
            setName = LS.GetSetName(setId, lang)
        end

        local maxEquipped = info.maxEquipped

        if maxEquipped == 0 then
            _, maxEquipped = LS.GetNumEquippedItemsBySetId(setId)
        end

        table.insert(entries, {
            setId = setId,
            name = setName,
            maxEquipped = maxEquipped,
            numEquipped = CountEquippedPieces(info),
        })
    end

    table.sort(entries, function(a, b)

        if a.numEquipped ~= b.numEquipped then
            return a.numEquipped > b.numEquipped
        end

        if a.maxEquipped ~= b.maxEquipped then
            return a.maxEquipped > b.maxEquipped
        end

        return a.name < b.name
    end)

    return entries
end
function ES.UpdateDisplay()

    if not IsModuleEnabled() then
        CSUtilsEquippedSetsFrame:SetHidden(true)
        uiHidden = true
        return
    end

    if not LibSetDetection or not LibSets then
        return
    end

    local sv = GetSavedVars()

    local entries = BuildSetEntries(
        LibSetDetection.GetEquippedSetsTable()
    )

    ResetRows()

    if inCombat and sv.hideInCombat and not IsUnlocked() then
        HideFrame()
        return
    end

    ShowFrame()

    CSUtilsEquippedSetsFrameTitle:SetColor(
        unpack(sv.headColor)
    )

    for index, entry in ipairs(entries) do

        if index > MAX_ROWS then
            break
        end

        local row = rows[index]

        local countText = entry.numEquipped .. "/" .. entry.maxEquipped
        local setName = zo_strformat(
            SI_ABILITY_NAME,
            entry.name
        )

        row.nums:SetText(countText)
        row.names:SetText(setName)

        local color

        if entry.numEquipped == entry.maxEquipped then

            color = sv.completeColor

        elseif entry.numEquipped > entry.maxEquipped
            or LibSets.IsMonsterSet(entry.setId) then

            color = sv.warningColor

        else

            color = sv.incompleteColor
        end

        row.nums:SetColor(unpack(color))
        row.names:SetColor(unpack(color))

        row:SetHidden(false)
    end
end

local function InitUI()

    for i = 1, MAX_ROWS do

        local row = CSUtilsEquippedSetsFrame:GetNamedChild(
            "Row" .. i
        )

        row.nums = row:GetNamedChild("Nums")
        row.names = row:GetNamedChild("Names")

        rows[i] = row
    end

    CSUtilsEquippedSetsFrame:SetMovable(true)

    RestorePosition()

    ES.UpdateDisplay()
end

local function RegisterEvents()

    EVENT_MANAGER:RegisterForEvent(
        "CSUtils_" .. moduleID,
        EVENT_PLAYER_COMBAT_STATE,
        OnCombatStateChanged
    )

    EVENT_MANAGER:RegisterForEvent(
        "CSUtils_" .. moduleID,
        EVENT_RETICLE_HIDDEN_UPDATE,
        OnReticleHiddenUpdate
    )

    if LibSetDetection then

        LibSetDetection.RegisterEvent(
            LSD_EVENT_DATA_UPDATE,
            "CSUtils_" .. moduleID,
            ES.UpdateDisplay,
            LSD_UNIT_TYPE_PLAYER
        )

    end
end

local function SaveColor(key, r, g, b, a)

    GetSavedVars()[key] = {
        r,
        g,
        b,
        a
    }

    ES.UpdateDisplay()
end

local function BuildModuleSettings()

    local sv = GetSavedVars()

    return {

        {
            type = "description",
            text = "Arraste o painel na tela para reposicioná-lo. Ele também se oculta automaticamente em menus.",
        },

        {
            type = "checkbox",
            name = "Desbloquear posição",
            tooltip = "Mantém o painel visível para permitir o reposicionamento.",
            getFunc = function()
                return sv.unlockPosition
            end,

            setFunc = function(value)

                sv.unlockPosition = value

                ES.UpdateDisplay()

            end,

            default = DEFAULTS.unlockPosition,
        },

        {
            type = "header",
            name = "Opções",
        },

        {
            type = "checkbox",
            name = "Esconder em Combate",
            tooltip = "Oculta a lista ao entrar em combate.",

            getFunc = function()
                return sv.hideInCombat
            end,

            setFunc = function(value)

                sv.hideInCombat = value

                OnCombatStateChanged()

            end,

            default = DEFAULTS.hideInCombat,
        },

        {
            type = "header",
            name = "Cores",
        },

        {
            type = "colorpicker",
            name = "Cor do Título",
            tooltip = "Cor do cabeçalho \"Sets Equipados\".",

            getFunc = function()
                return unpack(sv.headColor)
            end,

            setFunc = function(r, g, b, a)

                SaveColor(
                    "headColor",
                    r,
                    g,
                    b,
                    a
                )

            end,

            default = DEFAULTS.headColor,
        },

        {
            type = "colorpicker",
            name = "Sets Completos",
            tooltip = "Cor quando todas as peças do set estão equipadas.",

            getFunc = function()
                return unpack(sv.completeColor)
            end,

            setFunc = function(r, g, b, a)

                SaveColor(
                    "completeColor",
                    r,
                    g,
                    b,
                    a
                )

            end,

            default = DEFAULTS.completeColor,
        },

        {
            type = "colorpicker",
            name = "Sets Incompletos",
            tooltip = "Cor quando faltam peças para completar o set.",

            getFunc = function()
                return unpack(sv.incompleteColor)
            end,

            setFunc = function(r, g, b, a)

                SaveColor(
                    "incompleteColor",
                    r,
                    g,
                    b,
                    a
                )

            end,

            default = DEFAULTS.incompleteColor,
        },

        {
            type = "colorpicker",
            name = "Cor de Aviso",
            tooltip = "Cor para sets de monstro ou peças acima do limite.",

            getFunc = function()
                return unpack(sv.warningColor)
            end,

            setFunc = function(r, g, b, a)

                SaveColor(
                    "warningColor",
                    r,
                    g,
                    b,
                    a
                )

            end,

            default = DEFAULTS.warningColor,
        },
    }
end

local function Initialize()

    if not LibSetDetection or not LibSets then

        d("|cFF6666[CS Utils]|r Módulo Sets Equipados requer LibSetDetection e LibSets.")

        return
    end


    InitUI()

    RegisterEvents()

end

CSUtils:RegisterModule(
    moduleID,
    moduleTitle,
    moduleDesc,
    Initialize,
    true,
    {
        defaults = DEFAULTS,

        buildSettings = BuildModuleSettings,

        onToggle = function()

            if IsModuleEnabled() then

                ES.UpdateDisplay()

            else

                CSUtilsEquippedSetsFrame:SetHidden(true)

                uiHidden = true

            end

        end,
    }
)