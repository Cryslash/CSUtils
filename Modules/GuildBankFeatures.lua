local moduleID = "GuildBankFeatures"
local moduleTitle = "Banco da Guilda Aprimorado"
local moduleDesc = "Um conjunto de aprimoramentos para o Guild Bank: Exibe um aviso antes de depositar itens no banco " ..
                   "da guilda e adiciona um atalho manual para reorganizar (restack) pilhas duplicadas."

-- Namespace próprio para os eventos deste módulo (nunca usar o nome genérico "CSUtils"
-- para eventos que só este módulo deve tratar, senão outro módulo que registre o mesmo
-- evento sob o mesmo namespace sobrescreve esta inscrição).
local EVENT_NAMESPACE = "CSUtils_" .. moduleID

local DELAY = 100

-- CORREÇÃO 1: o Roomba original reserva 5 slots livres de margem, não 2. O restack pode
-- reter várias pilhas do MESMO item na mochila simultaneamente (uma por pilha duplicada
-- do grupo) antes do merge acontecer, então 2 slots é insuficiente para grupos com 3+
-- pilhas duplicadas — o processo falharia no meio do caminho.
local INVENTORY_SLOTS_NEEDED = 5

-- Vira true só durante o instante em que o próprio restack chama TransferToGuildBank,
-- para o hook de confirmação de depósito (mais abaixo) não interceptar essa chamada.
local isBypassingHook = false

-- ===== Estado do restack (baseado no addon Roomba, de Masteroshi430/Wobin/CrazyDutchGuy/
-- Ayantir/silvereyes — aqui simplificado: sem UI própria, sem modo lite, sem gamepad;
-- feedback só por mensagem de chat, disparo só manual via keybind) =====
local restackInProgress = false
local duplicates = {}       -- lista de grupos de pilhas duplicadas encontradas no banco
local duplicateGroupIndex   -- chave atual em `duplicates` (controlada via next())
local currentGroup          -- grupo do item sendo processado agora
local cSlot, cSlotIdx       -- slot atual sendo retirado do banco dentro do grupo
local inBagCollection = {}  -- pilhas do item já retiradas para a mochila
local lastRestackResult     -- resultado da fusão: lista de pilhas finais a devolver
local slotIndex              -- posição atual dentro de lastRestackResult sendo devolvida
local waitingRetries = 1
local slotsSaved = 0        -- soma de slots economizados, para o resumo final

-- CORREÇÃO DO BUG (grupos após o primeiro travavam): antes, EVENT_INVENTORY_SINGLE_SLOT_UPDATE
-- era desregistrado assim que a coleta de pilhas do grupo atual terminava, e nunca era
-- registrado de novo para o próximo grupo — então o item do grupo seguinte saía do banco,
-- chegava na mochila, e ninguém percebia (o processo travava esperando um evento morto).
-- Agora o evento fica registrado o tempo todo (só é removido em AbortRestack, igual aos
-- outros dois), e essa flag decide se um update de mochila deve ser tratado agora ou
-- ignorado (ex: durante o merge/devolução, quando updates de mochila não nos interessam).
local collectingGroup = false

local keybindDescriptor

local ProcessNextGroup, ReturnNextStack, AbortRestack, FinishRestack

-- CORREÇÃO 3: helper único para manter o label do botão da keybind strip sincronizado
-- com restackInProgress. O KEYBIND_STRIP não reavalia sozinho uma `name` dinâmica como
-- reavalia `visible` a cada frame — sem chamar UpdateKeybindButtonGroup explicitamente
-- depois de mudar restackInProgress, o texto do botão pode ficar preso no valor inicial.
local function RefreshKeybindLabel()
    if KEYBIND_STRIP:HasKeybindButtonGroup(keybindDescriptor) then
        KEYBIND_STRIP:UpdateKeybindButtonGroup(keybindDescriptor)
    end
end

-- Só pesa o custo de montar/parsear o item link (para checar HP de armas de cerco) para
-- o raro caso de siege; para todo o resto usa GetSlotStackSize direto.
local function GetRealSlotStackSize(bagId, slotIndex)
    local stack, maxStack = GetSlotStackSize(bagId, slotIndex)

    if GetItemType(bagId, slotIndex) == ITEMTYPE_SIEGE then
        local itemLink = GetItemLink(bagId, slotIndex, LINK_STYLE_BRACKETS)
        local hp = select(23, ZO_LinkHandler_ParseLink(itemLink))
        if hp ~= "0" then
            maxStack = 1
        end
    end

    return stack, maxStack
end

local function MoveItem(sourceBag, sourceSlot, destBag, destSlot, qty)
    if IsProtectedFunction("RequestMoveItem") then
        CallSecureProtected("RequestMoveItem", sourceBag, sourceSlot, destBag, destSlot, qty)
    else
        RequestMoveItem(sourceBag, sourceSlot, destBag, destSlot, qty)
    end
end

-- Varre o banco da guilda e agrupa por itemInstanceId as pilhas que não estão no máximo.
local function ScanGuildBank()
    local bagToScan = SHARED_INVENTORY:GenerateFullSlotData(nil, BAG_GUILDBANK)
    local lookUp = {}
    local dupTemp = {}
    duplicates = {}

    for _, slot in pairs(bagToScan) do
        local stack, maxStack = GetRealSlotStackSize(slot.bagId, slot.slotIndex)

        if stack ~= maxStack then
            local itemInstanceId = slot.itemInstanceId

            if lookUp[itemInstanceId] then
                if not dupTemp[itemInstanceId] then
                    dupTemp[itemInstanceId] = lookUp[itemInstanceId]
                end
            else
                lookUp[itemInstanceId] = {}
            end

            table.insert(lookUp[itemInstanceId], {
                slotId = slot.slotIndex,
                stack = stack,
                texture = slot.iconFile,
                name = slot.name,
                itemInstanceId = slot.itemInstanceId,
            })
        end
    end

    for _, data in pairs(dupTemp) do
        table.insert(duplicates, data)
    end
end

-- Funde, na mochila, as pilhas de um mesmo item retiradas do banco: preenche a primeira
-- pilha até o máximo, e o que sobra vira novas pilhas cheias. Retorna a lista final de
-- pilhas que precisam ser devolvidas ao banco.
--
-- LIMITAÇÃO CONHECIDA (correção 2, não resolvida aqui): se o item for elegível para a
-- Craft Bag (ESO Plus), ele não ocupa slots separados na mochila — todas as pilhas
-- retiradas do banco caem automaticamente numa única entrada da Craft Bag, sem "pilhas"
-- para mesclar. O código não é destrutivo nesse caso, mas o grupo pode não fechar o
-- ciclo do jeito esperado. Vale monitorar se o restack travar especificamente em
-- matérias-primas.
local function MergeStacksInBackpack(bagId, items)
    local result = {}
    local baseSlot = nil
    local index = 1
    local itemInfo = items[index]

    while itemInfo do
        if not baseSlot then
            baseSlot = itemInfo
            baseSlot.actualStack, baseSlot.maxStack = GetRealSlotStackSize(bagId, itemInfo.slotId)
            table.insert(result, baseSlot)
        else
            itemInfo.maxStack = baseSlot.maxStack
            local spaceLeft = baseSlot.maxStack - baseSlot.actualStack

            if itemInfo.stack <= spaceLeft then
                -- Cabe tudo na pilha atual
                MoveItem(bagId, itemInfo.slotId, bagId, baseSlot.slotId, itemInfo.stack)
                baseSlot.actualStack = baseSlot.actualStack + itemInfo.stack
                result[#result].stack = baseSlot.actualStack
                result[#result].actualStack = baseSlot.actualStack
            else
                -- Só cabe parte: enche a pilha atual e o resto forma uma pilha nova
                MoveItem(bagId, itemInfo.slotId, bagId, baseSlot.slotId, spaceLeft)
                result[#result].stack = baseSlot.maxStack
                result[#result].actualStack = baseSlot.maxStack

                itemInfo.stack = itemInfo.stack - spaceLeft
                itemInfo.actualStack = itemInfo.stack
                table.insert(result, itemInfo)

                baseSlot = itemInfo
            end
        end

        index = index + 1
        itemInfo = items[index]
    end

    return result
end

-- ===== Máquina de eventos: retira do banco -> funde na mochila -> devolve ao banco =====

local function OnBackpackSlotUpdated(_, bagId, updatedSlotId)
    -- CORREÇÃO DO BUG: agora checamos `collectingGroup`, não a presença/ausência do
    -- registro do evento, já que o evento fica registrado o tempo todo.
    if not collectingGroup or not currentGroup or not (bagId == BAG_BACKPACK or bagId == BAG_VIRTUAL) then
        return
    end

    local id = GetItemInstanceId(bagId, updatedSlotId)
    if not id or id ~= cSlot.itemInstanceId then
        return
    end

    cSlot.bagId = bagId
    cSlot.slotId = updatedSlotId
    table.insert(inBagCollection, cSlot)

    if next(currentGroup, cSlotIdx) then
        -- Ainda tem outra pilha deste item no banco, retira também
        cSlotIdx, cSlot = next(currentGroup, cSlotIdx)

        local duplicateId = GetItemInstanceId(BAG_GUILDBANK, cSlot.slotId)
        if not duplicateId or duplicateId ~= cSlot.itemInstanceId then
            -- Alguém mexeu no item entre o scan e agora, aborta com segurança
            AbortRestack()
            return
        end

        TransferFromGuildBank(cSlot.slotId)
    else
        -- Já retiramos todas as pilhas deste item, hora de fundir. Desligamos a flag
        -- (não o evento) para que updates de mochila do merge/devolução sejam ignorados.
        collectingGroup = false

        local before = #currentGroup
        lastRestackResult = MergeStacksInBackpack(bagId, inBagCollection)
        slotsSaved = slotsSaved + (before - #lastRestackResult)

        slotIndex = 1

        -- Pequeno atraso necessário por causa da latência do SHARED_INVENTORY após o merge
        zo_callLater(function()
            ReturnNextStack()
        end, DELAY)
    end
end

ReturnNextStack = function()
    local slot = lastRestackResult and lastRestackResult[slotIndex]

    if slot and SHARED_INVENTORY:GenerateSingleSlotData(slot.bagId, slot.slotId) then
        isBypassingHook = true
        TransferToGuildBank(slot.bagId, slot.slotId)
        isBypassingHook = false
    else
        ProcessNextGroup()
    end
end

local function OnGuildBankItemAdded(_, gslot, localPlayer)
    if not localPlayer or not currentGroup or not lastRestackResult then
        return
    end

    local expected = lastRestackResult[slotIndex]
    if not expected or GetItemInstanceId(BAG_GUILDBANK, gslot) ~= expected.itemInstanceId then
        return
    end

    waitingRetries = 1

    if next(lastRestackResult, slotIndex) then
        slotIndex = slotIndex + 1
        zo_callLater(ReturnNextStack, DELAY)
    else
        ProcessNextGroup()
    end
end

local function OnGuildBankTransferError(_, errorCode)
    if not currentGroup then
        return
    end

    if errorCode == GUILD_BANK_NO_SPACE_LEFT then
        d("|c00CCFF[CS Utils]|r Banco da guilda sem espaço, restack interrompido.")
        AbortRestack()
    elseif errorCode == GUILD_BANK_ITEM_NOT_FOUND then
        if lastRestackResult and next(lastRestackResult, slotIndex) then
            slotIndex = slotIndex + 1
            zo_callLater(ReturnNextStack, DELAY)
        else
            ProcessNextGroup()
        end
    elseif errorCode == GUILD_BANK_TRANSFER_PENDING then
        waitingRetries = waitingRetries + 1
        if waitingRetries < 10 then
            zo_callLater(ReturnNextStack, DELAY * 5)
        else
            d("|c00CCFF[CS Utils]|r Banco da guilda ocupado, pulando um item durante o restack.")
            ProcessNextGroup()
        end
    else
        -- Erro não tratado (ex: outro addon/jogador mexeu no meio do processo): segue em frente
        ProcessNextGroup()
    end
end

ProcessNextGroup = function()
    duplicateGroupIndex, currentGroup = next(duplicates, duplicateGroupIndex)

    if not currentGroup then
        FinishRestack()
        return
    end

    cSlotIdx = 1
    cSlot = currentGroup[cSlotIdx]
    inBagCollection = {}
    lastRestackResult = nil

    -- CORREÇÃO DO BUG: liga a flag de coleta para ESTE grupo — é o que faltava para o
    -- segundo grupo (e os seguintes) serem processados corretamente.
    collectingGroup = true

    if not SHARED_INVENTORY:GenerateSingleSlotData(BAG_GUILDBANK, cSlot.slotId) then
        -- Item sumiu entre o scan e agora, pula para o próximo grupo
        ProcessNextGroup()
        return
    end

    TransferFromGuildBank(cSlot.slotId)
end

AbortRestack = function()
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_INVENTORY_SINGLE_SLOT_UPDATE)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_GUILD_BANK_ITEM_ADDED)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_GUILD_BANK_TRANSFER_ERROR)

    restackInProgress = false
    collectingGroup = false
    currentGroup = nil

    -- CORREÇÃO 3: garante que o botão volte a mostrar o texto normal assim que o
    -- processo para (por erro ou por conclusão).
    RefreshKeybindLabel()
end

FinishRestack = function()
    AbortRestack()

    d(string.format("|c00CCFF[CS Utils]|r Restack do banco da guilda concluído. Slots economizados: %d", slotsSaved))
end

local function StartRestack()
    if restackInProgress then
        return
    end

    if not CheckInventorySpaceAndWarn(INVENTORY_SLOTS_NEEDED) then
        return
    end

    ScanGuildBank()

    if #duplicates == 0 then
        d("|c00CCFF[CS Utils]|r Nenhuma pilha duplicada encontrada no banco da guilda.")
        return
    end

    restackInProgress = true
    duplicateGroupIndex = nil
    slotsSaved = 0
    waitingRetries = 1

    d("|c00CCFF[CS Utils]|r Reorganizando pilhas do banco da guilda, aguarde...")

    -- CORREÇÃO 3: atualiza o label pra "Reorganizando..." assim que o processo começa.
    RefreshKeybindLabel()

    -- Registrado uma única vez para todo o restack (todos os grupos). Ver CORREÇÃO DO
    -- BUG acima: quem controla se um update de mochila importa agora é `collectingGroup`.
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_INVENTORY_SINGLE_SLOT_UPDATE, OnBackpackSlotUpdated)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_GUILD_BANK_ITEM_ADDED, OnGuildBankItemAdded)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_GUILD_BANK_TRANSFER_ERROR, OnGuildBankTransferError)

    ProcessNextGroup()
end

-- ===== Keybind (aparece só dentro do banco da guilda, quando a feature está ligada) =====

-- CORREÇÃO 4: keybind própria "CSUTILS_RESTACK_GUILDBANK" (declarada em Bindings.xml),
-- em vez de reaproveitar "DIALOG_TERTIARY" — um ID emprestado do sistema de diálogos que
-- poderia colidir se um diálogo com botão terciário estivesse aberto ao mesmo tempo.
local function BuildKeybindDescriptor()
    keybindDescriptor = {
        alignment = KEYBIND_STRIP_ALIGN_LEFT,
        [1] = {
            name = function()
                return restackInProgress and "Reorganizando..." or "Juntar Tudo (apenas banco da guilda)"
            end,
            keybind = "CSUTILS_RESTACK_GUILDBANK",
            callback = StartRestack,
        },
    }
end

-- Função GLOBAL exposta só pra ser chamada pelo Bindings.xml via <Down> — o XML de
-- keybinds não enxerga funções locais, precisa de algo no namespace global (mesmo
-- motivo do Roomba original ter Roomba_StartRoomba como função global, sem "local").
function CSUtils_RestackGuildBank()
    StartRestack()
end

local function OnOpenGuildBank()
    if not CSUtils.savedVars[moduleID].restackEnabled then
        return
    end

    if not KEYBIND_STRIP:HasKeybindButtonGroup(keybindDescriptor) then
        KEYBIND_STRIP:AddKeybindButtonGroup(keybindDescriptor)
    end
end

local function OnCloseGuildBank()
    if KEYBIND_STRIP:HasKeybindButtonGroup(keybindDescriptor) then
        KEYBIND_STRIP:RemoveKeybindButtonGroup(keybindDescriptor)
    end

    if restackInProgress then
        AbortRestack()
    end
end

-- ===== Submenu de configurações do módulo (LibAddonMenu2) =====

local function BuildModuleSettings()
    return {
        {
            type = "checkbox",
            name = "Habilitar Restack do Banco da Guilda",
            tooltip = "Adiciona um atalho manual no banco da guilda para reorganizar pilhas duplicadas de itens.",
            getFunc = function()
                return CSUtils.savedVars[moduleID].restackEnabled
            end,
            setFunc = function(value)
                CSUtils.savedVars[moduleID].restackEnabled = value

                if not value and KEYBIND_STRIP:HasKeybindButtonGroup(keybindDescriptor) then
                    KEYBIND_STRIP:RemoveKeybindButtonGroup(keybindDescriptor)
                end
            end,
        },
    }
end

-- ===== Inicialização do módulo =====

local function Initialize()

    -- 1. Cria a janela de diálogo (Dialog) nativa do jogo
    ZO_Dialogs_RegisterCustomDialog("CSUTILS_GUILDBANK_CONFIRM", {
        canQueue = true,
        title = { text = "Aviso de Depósito" },
        mainText = { text = "Você está depositando um item no banco da guilda, deseja continuar?" },
        buttons = {
            [1] = {
                text = SI_DIALOG_CONFIRM,
                keybind = "DIALOG_PRIMARY",
                callback = function(dialog)
                    isBypassingHook = true
                    TransferToGuildBank(dialog.data.bagId, dialog.data.slotIndex)
                    isBypassingHook = false
                end
            },
            [2] = {
                text = SI_DIALOG_CANCEL,
                keybind = "DIALOG_NEGATIVE",
                callback = function(dialog)
                    -- Não faz nada, o depósito é cancelado
                end
            }
        }
    })

    -- 2. Intercepta a função global de depósito
    ZO_PreHook("TransferToGuildBank", function(sourceBag, sourceSlot)
        if isBypassingHook then return false end

        ZO_Dialogs_ShowDialog("CSUTILS_GUILDBANK_CONFIRM", { bagId = sourceBag, slotIndex = sourceSlot })

        return true
    end)

    -- 3. Keybind de restack (a string de exibição no menu de Controles vem do
    -- Bindings.xml + SI_BINDING_NAME_CSUTILS_RESTACK_GUILDBANK, definida abaixo)
    ZO_CreateStringId("SI_BINDING_NAME_CSUTILS_RESTACK_GUILDBANK", "Juntar Itens no Banco da Guilda")

    BuildKeybindDescriptor()

    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_OPEN_GUILD_BANK, OnOpenGuildBank)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_CLOSE_GUILD_BANK, OnCloseGuildBank)
end

-- Registra o módulo na base do CS Utils
CSUtils:RegisterModule(moduleID, moduleTitle, moduleDesc, Initialize, false, {
    buildSettings = BuildModuleSettings,
    defaults = { restackEnabled = true },
})