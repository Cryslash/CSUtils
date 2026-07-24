local moduleID = "BeamMeUpTpAlias"
local moduleTitle = "Atalho /tp (Beam Me Up)"
local moduleDesc = "Converte /tp <destino> para o comando /bmutp/<destino> do Beam Me Up."

local BMU_COMMAND_PREFIX = "/bmutp/"

local function NormalizeDestination(text)
    if not text then return nil end

    text = zo_strtrim(text)
    if text == "" then return nil end

    text = string.lower(text)
    text = string.gsub(text, "%s+", "_")

    return text
end

local function ExecuteBmuCommand(destination)
    local bmuCommand = BMU_COMMAND_PREFIX .. destination
    local handler = SLASH_COMMANDS[bmuCommand]

    if handler then
        handler("")
        return true
    end

    return false
end

local function Initialize()
    SLASH_COMMANDS["/tp"] = function(text)
        local destination = NormalizeDestination(text)

        if not destination then
            d("|cFF6666[CS Utils]|r Uso: /tp <destino>  (ex: /tp deshaan, /tp leader, /tp high isle)")
            return
        end

        if not ExecuteBmuCommand(destination) then
            d("|cFF6666[CS Utils]|r Destino desconhecido ou Beam Me Up não carregado: " .. BMU_COMMAND_PREFIX .. destination)
        end
    end
end

CSUtils:RegisterModule(moduleID, moduleTitle, moduleDesc, Initialize)
