CSUtils = {
    name = "CSUtils",
    displayName = "CS Utils",
    version = "1.0",
    modules = {},
    defaults = {
        modules = {} -- Armazenará o estado (true/false) de cada módulo
    }
}

-- Função que os módulos usarão para se registrar na base
function CSUtils:RegisterModule(id, title, description, initFunc)
    self.modules[id] = {
        title = title,
        description = description,
        init = initFunc
    }
    
    -- Define o estado padrão como ligado se for a primeira vez
    if self.defaults.modules[id] == nil then
        self.defaults.modules[id] = true
    end
end

-- Constrói o menu usando LibAddonMenu-2.0
local function BuildSettings()
    local LAM = LibAddonMenu2
    if not LAM then return end

    local panelData = {
        type = "panel",
        name = CSUtils.displayName,
        displayName = "|c00CCFFCS Utils|r",
        author = "Radamannthes",
        version = CSUtils.version,
        registerForRefresh = true,
        registerForDefaults = true,
    }
    
    local optionsData = {
        {
            type = "description",
            text = "Ative ou desative os módulos utilitários abaixo. Alterações exigem recarregar a interface (/reloadui).",
        },
        {
            type = "header",
            name = "Módulos Disponíveis",
        }
    }

    -- Cria um botão de toggle (checkbox) para cada módulo registrado
    for id, module in pairs(CSUtils.modules) do
        table.insert(optionsData, {
            type = "checkbox",
            name = module.title,
            tooltip = module.description,
            getFunc = function() return CSUtils.savedVars.modules[id] end,
            setFunc = function(value) CSUtils.savedVars.modules[id] = value end,
            requiresReload = true, -- Força aviso de /reloadui pois estamos mexendo com Hooks
        })
    end

    LAM:RegisterAddonPanel("CSUtils_SettingsPanel", panelData)
    LAM:RegisterOptionControls("CSUtils_SettingsPanel", optionsData)
end

-- Inicialização principal do addon
local function OnAddOnLoaded(event, addonName)
    if addonName ~= CSUtils.name then return end
    EVENT_MANAGER:UnregisterForEvent(CSUtils.name, EVENT_ADD_ON_LOADED)

    -- Carrega variáveis salvas
    CSUtils.savedVars = ZO_SavedVars:NewAccountWide("CSUtils_SavedVars", 1, nil, CSUtils.defaults)

    -- Inicia os módulos que estiverem marcados como 'true' nas opções
    for id, module in pairs(CSUtils.modules) do
        if CSUtils.savedVars.modules[id] then
            module.init()
        end
    end

    BuildSettings()
end

EVENT_MANAGER:RegisterForEvent(CSUtils.name, EVENT_ADD_ON_LOADED, OnAddOnLoaded)