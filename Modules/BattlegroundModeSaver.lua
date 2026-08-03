local moduleID = "BattlegroundModeSaver"
local moduleTitle = "Manter Modo do Battleground"
local moduleDesc = "Lembra o último modo de batalha selecionado no Localizador de Batalhas (Battlegrounds) e o restaura automaticamente na próxima vez que a tela for aberta."

-- Namespace próprio para os eventos deste módulo (nunca usar o nome genérico "CSUtils"
-- para eventos que só este módulo deve tratar).
local EVENT_NAMESPACE = "CSUtils_" .. moduleID

-- Feature liga/desliga sem precisar de reload (supportsHotToggle = true, ver RegisterModule
-- no final do arquivo). O ZO_PostHook do jogo não tem como ser "desfeito" depois de
-- instalado, então em vez de tentar remover o hook quando o jogador desliga o módulo,
-- guardamos esse estado num flag local — os handlers simplesmente não fazem nada
-- enquanto ele estiver false.
local moduleEnabled = true

-- O combo box de filtros não tem um "SelectItemByName" pronto, então procuramos na
-- lista de itens já carregada o que bate com o nome do modo salvo.
local function FindModeItem(comboBox, modeName)
    for _, item in ipairs(comboBox.m_sortedItems) do
        if item.name == modeName then
            return item
        end
    end
end

-- Guarda o modo só quando é o JOGADOR escolhendo algo no dropdown — não quando é o
-- próprio jogo (ou o nosso RestoreLastMode) selecionando um item por conta própria.
-- IsDropdownVisible() é o que diferencia as duas origens: uma seleção programática
-- acontece com o dropdown fechado.
local function OnPlayerSelectedMode(comboBox, item)
    if not moduleEnabled or not item then
        return
    end

    if not comboBox:IsDropdownVisible() then
        return
    end

    CSUtils.savedVars[moduleID].lastSelectedMode = item.name
end

-- Sempre que a tela de filtros é (re)montada, se o modo salvo existir e for diferente
-- do que está selecionado agora, troca pra ele.
local function RestoreLastMode(finder)
    if not moduleEnabled then
        return
    end

    local savedMode = CSUtils.savedVars[moduleID].lastSelectedMode
    if not savedMode then
        return
    end

    local comboBox = finder.filterComboBox
    local rememberedItem = FindModeItem(comboBox, savedMode)
    if not rememberedItem then
        return
    end

    local currentItem = comboBox:GetSelectedItemData()

    if finder.fragment:IsShowing() and (not currentItem or currentItem.name ~= rememberedItem.name) then
        comboBox:SelectItem(rememberedItem)
    end
end

local function HookBattlegroundFinder()
    ZO_PostHook(BATTLEGROUND_FINDER_KEYBOARD.filterComboBox, "SelectItem", OnPlayerSelectedMode)

    ZO_PostHook(BATTLEGROUND_FINDER_KEYBOARD, "RefreshFilters", function()
        RestoreLastMode(BATTLEGROUND_FINDER_KEYBOARD)
    end)
end

local function Initialize()
    moduleEnabled = CSUtils.savedVars.modules[moduleID]

    -- BATTLEGROUND_FINDER_KEYBOARD só fica pronto depois que o jogador entra no mundo,
    -- então os hooks são aplicados nesse momento (uma única vez), não na carga do addon.
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_ACTIVATED, function()
        EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_ACTIVATED)
        HookBattlegroundFinder()
    end)
end

-- Registra o módulo na base do CS Utils. Sem buildSettings: o próprio checkbox de
-- ligar/desligar que o Core já gera cuida de tudo que esse módulo precisa configurar.
CSUtils:RegisterModule(moduleID, moduleTitle, moduleDesc, Initialize, true, {
    onToggle = function(value)
        moduleEnabled = value
    end,
    defaults = { lastSelectedMode = nil },
})