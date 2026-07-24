local moduleID = "GuildBankConfirm"
local moduleTitle = "Confirmação de Banco da Guilda"
local moduleDesc = "Exibe um aviso antes de depositar qualquer item no banco da guilda."

local function Initialize()
    local isBypassingHook = false

    -- 1. Cria a janela de diálogo (Dialog) nativa do jogo
    ZO_Dialogs_RegisterCustomDialog("CSUTILS_GUILDBANK_CONFIRM", {
        canQueue = true,
        title = { text = "Aviso de Depósito" },
        mainText = { text = "Você está depositando um item no banco da guilda, deseja continuar?" },
        buttons = {
            [1] = {
                text = SI_DIALOG_CONFIRM, -- O jogo traduzirá para "Continue" / "Confirmar"
                keybind = "DIALOG_PRIMARY", -- Tecla 'E' por padrão
                callback = function(dialog)
                    -- O jogador confirmou. Ligamos o bypass para não entrar em loop infinito.
                    isBypassingHook = true
                    -- Executa a função original usando os dados salvos no dialog
                    TransferToGuildBank(dialog.data.bagId, dialog.data.slotIndex)
                    isBypassingHook = false
                end
            },
            [2] = {
                text = SI_DIALOG_CANCEL, -- O jogo traduzirá para "Cancel" / "Cancelar"
                keybind = "DIALOG_NEGATIVE", -- Tecla 'ALT' por padrão
                callback = function(dialog)
                    -- Não faz nada, o depósito é cancelado
                end
            }
        }
    })

    -- 2. Intercepta a função global de depósito
    ZO_PreHook("TransferToGuildBank", function(sourceBag, sourceSlot)
        -- Se estivermos contornando o hook (após confirmar), deixa a função rodar normalmente
        if isBypassingHook then return false end 

        -- Caso contrário, chama nosso aviso na tela e passa a bolsa e o slot do item
        ZO_Dialogs_ShowDialog("CSUTILS_GUILDBANK_CONFIRM", { bagId = sourceBag, slotIndex = sourceSlot })

        -- Retorna 'true' para impedir que a função original execute imediatamente
        return true 
    end)
end

-- Registra o módulo na base do CS Utils
CSUtils:RegisterModule(moduleID, moduleTitle, moduleDesc, Initialize)