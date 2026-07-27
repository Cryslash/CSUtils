CSUtils = {
    name = "CSUtils",
    displayName = "CS Utils",
    version = "1.0",
    modules = {},
    defaults = { modules = {} },
}

--- Registra um novo módulo utilitário.
function CSUtils:RegisterModule(id, title, description, initFunc, supportsHotToggle, options)
    options = options or {}

    self.modules[id] = {
        title = title,
        description = description,
        init = initFunc,
        supportsHotToggle = supportsHotToggle or false,
        buildSettings = options.buildSettings,
        onToggle = options.onToggle,
    }

    if options.defaults then
        self.defaults[id] = options.defaults
    end

    if self.defaults.modules[id] == nil then
        self.defaults.modules[id] = true
    end
end

-- Cria o checkbox de ligar/desligar de um módulo.
local function BuildModuleToggle(id, module, insideSubmenu)
    return {
        type = "checkbox",
        name = insideSubmenu and "Ligado" or module.title,
        tooltip = module.description,
        getFunc = function() return CSUtils.savedVars.modules[id] end,
        setFunc = function(value)
            CSUtils.savedVars.modules[id] = value
            if module.onToggle then
                module.onToggle(value)
            end
        end,
        requiresReload = not module.supportsHotToggle,
    }
end

-- Monta a entrada do painel: checkbox simples, ou submenu quando o módulo
-- tem configurações próprias (buildSettings).
local function BuildModuleEntry(id, module)
    if not module.buildSettings then
        return BuildModuleToggle(id, module, false)
    end

    local controls = { BuildModuleToggle(id, module, true), { type = "divider" } }

    for _, setting in ipairs(module.buildSettings()) do
        table.insert(controls, setting)
    end

    return {
        type = "submenu",
        name = module.title,
        tooltip = module.description,
        controls = controls,
    }
end

-- Retorna os módulos ordenados alfabeticamente pelo título.
local function GetSortedModules()
    local sorted = {}

    for id, module in pairs(CSUtils.modules) do
        table.insert(sorted, { id = id, module = module })
    end

    table.sort(sorted, function(a, b)
        return a.module.title:lower() < b.module.title:lower()
    end)

    return sorted
end

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
        { type = "description", text = "Ative ou desative os módulos utilitários abaixo." },
        { type = "header", name = "Módulos Disponíveis" },
    }

    for _, entry in ipairs(GetSortedModules()) do
        table.insert(optionsData, BuildModuleEntry(entry.id, entry.module))
    end

    LAM:RegisterAddonPanel("CSUtils_SettingsPanel", panelData)
    LAM:RegisterOptionControls("CSUtils_SettingsPanel", optionsData)
end

local function OnAddOnLoaded(event, addonName)
    if addonName ~= CSUtils.name then return end

    EVENT_MANAGER:UnregisterForEvent(CSUtils.name, EVENT_ADD_ON_LOADED)

    CSUtils.savedVars = ZO_SavedVars:NewAccountWide("CSUtils_SavedVars", 1, nil, CSUtils.defaults)

    for id, module in pairs(CSUtils.modules) do
        if CSUtils.savedVars.modules[id] or module.supportsHotToggle then
            module.init()
        end
    end

    BuildSettings()
end

EVENT_MANAGER:RegisterForEvent(CSUtils.name, EVENT_ADD_ON_LOADED, OnAddOnLoaded)