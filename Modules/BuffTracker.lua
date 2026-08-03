--------------------------------------------------------------------------------
-- BUFF TRACKER MODULE
--------------------------------------------------------------------------------
-- Tracker enxuto de Major/Minor buffs (positivos) no próprio jogador, com DUAS
-- caixas independentes:
--   - Caixa Principal: buffs de curta duração (a maioria dos buffs de
--     combate), com animação suave de entrada/saída/reposicionamento.
--   - Caixa de Efeitos Duradouros: buffs de longa duração ou sem expiração
--     definida (comida, mundus, undaunted mettle etc), SEM nenhuma animação
--     — só aparecem/desaparecem/reposicionam direto. Orientação e sentido de
--     crescimento configuráveis, tamanho de ícone/número próprios.
--
-- Um buff é classificado como "duradouro" se a duração total dele (endTime -
-- beginTime) passar de LONG_DURATION_THRESHOLD, ou se não tiver expiração
-- definida (endTime <= beginTime).
--
-- Detecção de Major/Minor: como o ESO não tem localização em português, o
-- nome do efeito sempre vem com o prefixo literal em inglês ("Major ..."/
-- "Minor ..."), então detectamos por esse padrão de nome em vez de manter uma
-- lista fixa de IDs — se a Zenimax adicionar um Major/Minor novo, já funciona
-- sem precisar atualizar nada aqui.
--------------------------------------------------------------------------------

local MODULE_ID = "buffTracker"

--------------------------------------------------------------------------------
-- DEFAULTS
--------------------------------------------------------------------------------
local defaults = {
    iconSize          = 36,     -- px do ícone (tamanho "normal", não-destaque) — caixa principal
    allowReposition   = false,  -- destrava o arrastar das DUAS caixas

    -- Configurações de Borda (compartilhadas pelas 2 caixas, por simplicidade)
    borderThickness   = 2,             -- Espessura em pixels (0 para esconder)
    borderColor       = {1, 1, 1, 1},  -- RGBA (Padrão: Branco)
    fontSize          = 18, -- Tamanho da fonte do número — caixa principal

    -- Posição salva da caixa principal (ponto de ancoragem na tela)
    point = CENTER,
    x     = 0,
    y     = 250,

    -- Caixa de Efeitos Duradouros: tudo com config própria, sem animação.
    longBox = {
        iconSize      = 32,
        fontSize      = 14,
        layout        = "right", -- "right" | "left" | "up" | "down" (horizontal-direita/esquerda ou vertical-cima/baixo)
        x = 0,
        y = 320,
    },
}

local ICON_SPACING     = 4    -- px entre ícones
local HIGHLIGHT_SCALE  = 1.25 -- fator de tamanho do ícone em destaque
local BLINK_WINDOW     = 3    -- segundos restantes em que começa a piscar
local BLINK_PERIOD     = 0.6  -- segundos por ciclo completo do "pisca suave"
local BLINK_MIN_ALPHA  = 0.12

-- Duração total (endTime - beginTime) acima da qual um buff é considerado
-- "duradouro" e vai pra segunda caixa. Buffs sem expiração definida
-- (endTime <= beginTime, ex: mundus, undaunted mettle) também contam como
-- duradouros.
local LONG_DURATION_THRESHOLD = 300 -- segundos (5 minutos)

--------------------------------------------------------------------------------
-- DETECÇÃO DE MAJOR/MINOR E CLASSIFICAÇÃO POR DURAÇÃO
--------------------------------------------------------------------------------
local function IsMajorMinorBuff(name)
    if not name then return false end
    -- Inglês: prefixo ("Major Sorcery", "Minor Berserk")
    if name:find("^Major ") or name:find("^Minor ") then return true end
    -- Português (addon de tradução): sufixo ("Brutalidade Maior", "Força Menor")
    if name:find(" Maior$") or name:find(" Menor$") then return true end
    return false
end

local function IsLongDurationBuff(beginTime, endTime)
    local duration = endTime - beginTime
    return duration <= 0 or duration > LONG_DURATION_THRESHOLD
end

-- Formata o tempo restante da Caixa de Duradouros: "H:MM" quando passa de 1
-- hora (o minuto só decrementa de minuto em minuto, então dá pra saber que é
-- hora:minuto), e "M:SS" abaixo disso (o segundo decrementa a cada segundo).
-- Segundos exibidos como número puro, sem essa lógica, seriam ilegíveis pra
-- comida de 3h+ de duração (ex: "10300").
local function FormatLongDuration(remainingSeconds)
    remainingSeconds = math.floor(remainingSeconds + 0.5)
    if remainingSeconds >= 3600 then
        local hours = math.floor(remainingSeconds / 3600)
        local minutes = math.floor((remainingSeconds % 3600) / 60)
        return string.format("%d:%02d", hours, minutes)
    else
        local minutes = math.floor(remainingSeconds / 60)
        local seconds = remainingSeconds % 60
        return string.format("%d:%02d", minutes, seconds)
    end
end

--------------------------------------------------------------------------------
-- ESTADO DO MÓDULO
--------------------------------------------------------------------------------
local container       -- top-level control da caixa principal, ancorado/arrastável
local longContainer    -- top-level control da caixa de efeitos duradouros

-- Pool de ícones com identidade por buff (caixa principal): cada ícone GUI,
-- uma vez atribuído a um slotKey (buff), permanece atribuído a ele até o
-- buff sumir de vez e a animação de saída terminar. Isso evita que um ícone
-- "herde" a posição de outro buff que ocupava aquele mesmo índice antes.
local iconsBySlot = {}  -- [buffName] = iconCtrl atualmente representando aquele buff
local freeIcons   = {}  -- pilha de iconCtrl sem buff atribuído, prontos pra reuso
local iconCounter = 0   -- contador só pra nomear controles novos

-- Pool simples por índice pra caixa de duradouros (sem animação, então não
-- precisa de identidade estável — a lista muda raramente).
local longIconPool = {}
local longIconCounter = 0

-- IMPORTANTE: a identidade de um buff pra fins de exibição é o NOME, não o
-- effectSlot. O jogo reaproveita effectSlot livremente, e em conteúdos que
-- reaplicam buffs de grupo com frequência (ex: dummy de trial simulando 12
-- jogadores, que reaplica tudo a cada segundo), CADA reaplicação costuma vir
-- como uma instância nova de verdade — o effectSlot antigo realmente expira
-- (FADED) e um effectSlot novo é criado (GAINED), mesmo sendo "o mesmo" buff
-- Major/Minor do ponto de vista do jogador. Como só existe uma instância
-- possível de cada Major/Minor por vez, rastrear por nome evita que o ícone
-- suma e reapareça (e a barra inteira reordene) a cada reaplicação.
local activeBuffs = {}     -- caixa principal: [buffName] = { name=, iconFile=, beginTime=, endTime=, abilityId=, effectSlot= }
local buffOrder = {}       -- caixa principal: array de buffName, na ordem em que foi detectado
local activeLongBuffs = {} -- caixa de duradouros: mesma estrutura de entrada
local longBuffOrder = {}   -- caixa de duradouros: array de buffName
local slotToName = {}      -- [effectSlot] = buffName -- comum às duas caixas, só pra rotear FADED
local isEnabled = false
local menuIsOpen = false -- true enquanto algum menu (bag, personagem, gameMenuInGame etc.) está aberto por cima da HUD

-- Destaque e rastreamento manual são salvos POR PERSONAGEM (não account-wide),
-- pra cada char poder ter sua própria lista — usa o mesmo arquivo
-- CSUtils_SavedVars.lua, mas com um namespace próprio, então não conflita
-- com o resto (account-wide) do CSUtils nem exige mudar o Core.lua/manifesto.
local CHAR_DEFAULTS = {
    highlightBuffs     = {}, -- lista de nomes exatos (ex: "Major Sorcery") ou abilityId em destaque; vazia = nenhum
    customTrackedBuffs = {}, -- lista de efeitos rastreados manualmente (string = nome exato, number = abilityId)
}
local charSavedVars -- inicializada no Init(), via ZO_SavedVars:NewCharacterIdSettings

-- Forward declarations: Tick/UpdateTickState (caixa principal, animada) e
-- LongTick/UpdateLongTickState (caixa de duradouros, sem animação) se
-- referenciam mutuamente dentro de cada par, e ReflowIcons/ReflowLongBox
-- (definidas mais abaixo, mas usadas antes das seções dos Ticks no arquivo)
-- também precisam chamar UpdateTickState/UpdateLongTickState. Declarando os
-- nomes aqui em cima, todo mundo enxerga a variável correta independente da
-- ordem em que os corpos das funções são definidos depois.
local tickActive = false     -- true enquanto o tick da caixa principal está registrado
local longTickActive = false -- true enquanto o tick da caixa de duradouros está registrado
local Tick
local UpdateTickState
local LongTick
local UpdateLongTickState
local ScanExistingBuffs -- usada pelo gerenciamento de rastreamento manual (add/remove) pra reavaliar tudo na hora

--------------------------------------------------------------------------------
-- O canto de ancoragem da caixa de duradouros precisa "casar" com a direção
-- de crescimento configurada: crescendo pra direita/baixo, o canto fixo (que
-- não se move quando a caixa muda de tamanho) é o esquerdo/superior;
-- crescendo pra esquerda/cima, é o direito/inferior. Sem isso, a caixinha de
-- arrastar (e os ícones) "puxariam" pro lado errado toda vez que um ícone
-- fosse adicionado ou removido. Precisa existir antes da criação dos
-- containers, já que o handler OnMoveStop do longContainer já a usa.
--------------------------------------------------------------------------------
local function GetLongBoxAnchorPoint()
    local layout = CSUtils.savedVars[MODULE_ID].longBox.layout
    if layout == "left" then return TOPRIGHT end
    if layout == "up" then return BOTTOMLEFT end
    return TOPLEFT -- "right" (padrão) ou "down"
end

--------------------------------------------------------------------------------
-- CRIAÇÃO DA UI — CONTAINERS
--------------------------------------------------------------------------------
local function CreateContainer()
    if container then return end

    container = CreateControl("CSUtils_BuffTrackerContainer", GuiRoot, CT_TOPLEVELCONTROL)
    container:SetDimensions(650, 60)
    container:SetMouseEnabled(false)
    container:SetMovable(false)
    container:SetHidden(true)

    local bg = CreateControl("CSUtils_BuffTrackerContainerBG", container, CT_BACKDROP)
    bg:SetAnchorFill(container)
    bg:SetCenterColor(0, 0, 0, 0.3)
    bg:SetEdgeColor(0.6, 0.6, 0.6, 0.4)
    bg:SetEdgeTexture("", 1, 1, 1)
    bg:SetHidden(true) -- só aparece durante o modo de reposicionamento
    container.bg = bg

    container:SetHandler("OnMoveStop", function()
        local isValid, point, relativeTo, relativePoint, offsetX, offsetY = container:GetAnchor(0)

        if isValid then
            CSUtils.savedVars[MODULE_ID].point = point
            CSUtils.savedVars[MODULE_ID].x = offsetX
            CSUtils.savedVars[MODULE_ID].y = offsetY
        end
    end)
end

local function CreateLongContainer()
    if longContainer then return end

    longContainer = CreateControl("CSUtils_BuffTrackerLongContainer", GuiRoot, CT_TOPLEVELCONTROL)
    longContainer:SetDimensions(200, 60)
    longContainer:SetMouseEnabled(false)
    longContainer:SetMovable(false)
    longContainer:SetHidden(true)

    local bg = CreateControl("CSUtils_BuffTrackerLongContainerBG", longContainer, CT_BACKDROP)
    bg:SetAnchorFill(longContainer)
    bg:SetCenterColor(0, 0, 0, 0.3)
    bg:SetEdgeColor(0.6, 0.6, 0.6, 0.4)
    bg:SetEdgeTexture("", 1, 1, 1)
    bg:SetHidden(true)
    longContainer.bg = bg

    longContainer:SetHandler("OnMoveStop", function()
        -- GetLeft()/GetTop() sempre retornam a posição real (relativa ao
        -- TOPLEFT da tela), independente de qual ponto foi usado no
        -- SetAnchor — diferente de GetAnchor(), que o ESO pode normalizar
        -- internamente e reportar de forma pouco confiável.
        local left, top = longContainer:GetLeft(), longContainer:GetTop()
        local w, h = longContainer:GetDimensions()
        local sv = CSUtils.savedVars[MODULE_ID].longBox
        local anchorPoint = GetLongBoxAnchorPoint()

        if anchorPoint == TOPRIGHT then
            sv.x, sv.y = left + w, top
        elseif anchorPoint == BOTTOMLEFT then
            sv.x, sv.y = left, top + h
        else -- TOPLEFT
            sv.x, sv.y = left, top
        end
    end)
end

--------------------------------------------------------------------------------
-- TOOLTIP (compartilhado pelas 2 caixas)
--------------------------------------------------------------------------------
-- Tooltip enxuto e compacto (não usa o ItemTooltip nativo, que fica grande
-- demais): uma linha só, nome à esquerda e ID do buff à direita, acima do
-- ícone.
local tooltipFrame

local TOOLTIP_GAP = 12 -- px de espaço entre o tooltip e o ícone (antes era 4)

local function EnsureTooltipFrame()
    if tooltipFrame then return end

    tooltipFrame = CreateControl("CSUtils_BuffTrackerTooltip", GuiRoot, CT_TOPLEVELCONTROL)
    tooltipFrame:SetDimensions(290, 32)
    tooltipFrame:SetHidden(true)
    tooltipFrame:SetDrawLayer(DL_OVERLAY)
    tooltipFrame:SetDrawTier(DT_HIGH)

    local bg = CreateControl(tooltipFrame:GetName() .. "BG", tooltipFrame, CT_BACKDROP)
    bg:SetAnchorFill(tooltipFrame)
    bg:SetCenterColor(0, 0, 0, 0.85)
    bg:SetEdgeColor(0.6, 0.6, 0.6, 0.6)
    bg:SetEdgeTexture("", 1, 1, 1)

    local nameLabel = CreateControl(tooltipFrame:GetName() .. "Name", tooltipFrame, CT_LABEL)
    nameLabel:SetFont("$(BOLD_FONT)|20|soft-shadow-thin")
    nameLabel:SetColor(1, 1, 1, 1)
    nameLabel:SetHorizontalAlignment(TEXT_ALIGN_LEFT)
    nameLabel:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    nameLabel:SetAnchor(LEFT, tooltipFrame, LEFT, 10, 0)
    tooltipFrame.nameLabel = nameLabel

    local idLabel = CreateControl(tooltipFrame:GetName() .. "Id", tooltipFrame, CT_LABEL)
    idLabel:SetFont("$(BOLD_FONT)|16|soft-shadow-thin")
    idLabel:SetColor(0.65, 0.65, 0.65, 1)
    idLabel:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)
    idLabel:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    idLabel:SetAnchor(RIGHT, tooltipFrame, RIGHT, -10, 0)
    tooltipFrame.idLabel = idLabel
end

local function ShowBuffTooltip(control)
    -- o ícone pode pertencer à caixa principal OU à de duradouros
    local buff = activeBuffs[control.slotKey] or activeLongBuffs[control.slotKey]
    if not buff then return end

    EnsureTooltipFrame()
    tooltipFrame.nameLabel:SetText(buff.name)
    tooltipFrame.idLabel:SetText("ID: " .. tostring(buff.abilityId or "?"))

    -- Posiciona em coordenadas absolutas de tela (via GetScreenRect), em vez
    -- de um anchor relativo simples, pra poder limitar o tooltip dentro dos
    -- limites da tela e não cortar informação nas bordas.
    local screenW, screenH = GuiRoot:GetDimensions()
    local left, top, right, bottom = control:GetScreenRect()
    local tooltipW, tooltipH = tooltipFrame:GetDimensions()
    local iconCenterX = (left + right) / 2

    -- Horizontal: centraliza no ícone, mas nunca deixa passar das bordas.
    local halfW = tooltipW / 2
    local clampedCenterX = math.min(math.max(iconCenterX, halfW), screenW - halfW)

    -- Vertical: prefere acima do ícone; se não couber (ícone perto do topo
    -- da tela), mostra abaixo em vez de cortar.
    tooltipFrame:ClearAnchors()
    if (top - TOOLTIP_GAP - tooltipH) >= 0 then
        tooltipFrame:SetAnchor(BOTTOM, GuiRoot, TOPLEFT, clampedCenterX, top - TOOLTIP_GAP)
    else
        tooltipFrame:SetAnchor(TOP, GuiRoot, TOPLEFT, clampedCenterX, bottom + TOOLTIP_GAP)
    end

    tooltipFrame:SetHidden(false)
end

local function HideBuffTooltip()
    if tooltipFrame then tooltipFrame:SetHidden(true) end
end

--------------------------------------------------------------------------------
-- POOL DE ÍCONES — CAIXA PRINCIPAL (identidade estável por slotKey)
--------------------------------------------------------------------------------
local function CreateIconControl()
    iconCounter = iconCounter + 1
    local index = iconCounter

    local root = CreateControl("CSUtils_BuffTrackerIcon" .. index, container, CT_CONTROL)
    root:SetMouseEnabled(true)
    root:SetHandler("OnMouseEnter", ShowBuffTooltip)
    root:SetHandler("OnMouseExit", HideBuffTooltip)

    local icon = CreateControl(root:GetName() .. "Tex", root, CT_TEXTURE)
    icon:SetAnchorFill(root)

    local border = CreateControl(root:GetName() .. "Border", root, CT_BACKDROP)
    border:SetAnchorFill(root)
    border:SetCenterColor(0, 0, 0, 0)
    border:SetDrawLayer(DL_OVERLAY)
    border:SetDrawLevel(1)

    local durationLabel = CreateControl(root:GetName() .. "Dur", root, CT_LABEL)
    durationLabel:SetFont("$(BOLD_FONT)|18|outline")
    durationLabel:SetColor(1, 1, 1, 1)
    durationLabel:SetDrawLayer(DL_OVERLAY)
    durationLabel:SetDrawLevel(2)
    durationLabel:SetAnchor(BOTTOMLEFT, root, BOTTOMLEFT, 0, 3)
    durationLabel:SetAnchor(BOTTOMRIGHT, root, BOTTOMRIGHT, 0, 3)
    durationLabel:SetHorizontalAlignment(TEXT_ALIGN_CENTER)
    durationLabel:SetVerticalAlignment(TEXT_ALIGN_BOTTOM)

    local entry = {
        root = root, icon = icon, durationLabel = durationLabel, border = border,
        -- animação / estado
        currentX = 0, targetX = 0,
        currentSize = 0, targetSize = 0,
        visible = false,
        initialized = false, -- true assim que o ícone já "nasceu" na posição certa
        releasing = false,   -- true quando está encolhendo pra ser devolvido ao pool
        slotKey = nil,
        -- cache do último valor efetivamente aplicado na UI, pra evitar
        -- chamadas nativas (SetAnchor/SetText/SetAlpha) redundantes quando
        -- nada mudou de fato naquele tick
        lastAppliedSize = nil,
        lastAppliedX = nil,
        lastDisplayedSeconds = nil,
        lastAlpha = nil,
    }
    return entry
end

-- Retorna o ícone já atribuído a esse buff, ou pega um do pool livre / cria um
-- novo. Um ícone só é liberado de volta pro pool depois de terminar a
-- animação de saída (ver Tick), então nunca "rouba" a posição de outro buff.
local function AcquireIconForSlot(slotKey)
    local ctrl = iconsBySlot[slotKey]
    if ctrl then return ctrl end

    ctrl = table.remove(freeIcons)
    if not ctrl then
        ctrl = CreateIconControl()
    end

    ctrl.slotKey = slotKey
    ctrl.root.slotKey = slotKey
    ctrl.initialized = false
    ctrl.releasing = false
    -- zera o cache: um ícone reciclado pode ter tido posição/texto/alpha
    -- bem diferentes do buff anterior, então força reaplicar tudo no
    -- próximo tick em vez de arriscar "pular" uma atualização real
    ctrl.lastAppliedSize = nil
    ctrl.lastAppliedX = nil
    ctrl.lastDisplayedSeconds = nil
    ctrl.lastAlpha = nil
    iconsBySlot[slotKey] = ctrl
    return ctrl
end

local function ReleaseIcon(ctrl)
    iconsBySlot[ctrl.slotKey] = nil
    ctrl.slotKey = nil
    ctrl.root.slotKey = nil
    ctrl.root:SetHidden(true)
    ctrl.initialized = false
    ctrl.releasing = false
    table.insert(freeIcons, ctrl)
end

--------------------------------------------------------------------------------
-- POOL DE ÍCONES — CAIXA DE EFEITOS DURADOUROS (sem animação, pool por índice)
--------------------------------------------------------------------------------
local function GetOrCreateLongIcon(index)
    if longIconPool[index] then return longIconPool[index] end

    longIconCounter = longIconCounter + 1
    local root = CreateControl("CSUtils_BuffTrackerLongIcon" .. longIconCounter, longContainer, CT_CONTROL)
    root:SetMouseEnabled(true)
    root:SetHandler("OnMouseEnter", ShowBuffTooltip)
    root:SetHandler("OnMouseExit", HideBuffTooltip)

    local icon = CreateControl(root:GetName() .. "Tex", root, CT_TEXTURE)
    icon:SetAnchorFill(root)

    local border = CreateControl(root:GetName() .. "Border", root, CT_BACKDROP)
    border:SetAnchorFill(root)
    border:SetCenterColor(0, 0, 0, 0)
    border:SetDrawLayer(DL_OVERLAY)
    border:SetDrawLevel(1)

    local durationLabel = CreateControl(root:GetName() .. "Dur", root, CT_LABEL)
    durationLabel:SetColor(1, 1, 1, 1)
    durationLabel:SetDrawLayer(DL_OVERLAY)
    durationLabel:SetDrawLevel(2)
    durationLabel:SetAnchor(BOTTOMLEFT, root, BOTTOMLEFT, 0, 3)
    durationLabel:SetAnchor(BOTTOMRIGHT, root, BOTTOMRIGHT, 0, 3)
    durationLabel:SetHorizontalAlignment(TEXT_ALIGN_CENTER)
    durationLabel:SetVerticalAlignment(TEXT_ALIGN_BOTTOM)

    longIconPool[index] = { root = root, icon = icon, durationLabel = durationLabel, border = border }
    return longIconPool[index]
end

--------------------------------------------------------------------------------
-- POSIÇÃO / REPOSICIONAMENTO
--------------------------------------------------------------------------------
local function ApplyPosition()
    if not container then return end
    local sv = CSUtils.savedVars[MODULE_ID]

    container:ClearAnchors()
    container:SetAnchor(sv.point, GuiRoot, sv.point, sv.x, sv.y)
end

-- O offset salvo (x/y) é a posição ABSOLUTA de tela (relativa ao TOPLEFT do
-- GuiRoot, que é sempre (0,0)) do canto do controle que está servindo de
-- âncora no momento. Ancorar sempre com relativePoint=TOPLEFT (nunca variar
-- esse lado) e variar só o PONTO PRÓPRIO (self point) é o que garante que
-- adicionar/remover buff (mudando largura/altura) nunca desloca esse canto —
-- só a ponta oposta (onde os ícones crescem) se estende ou recolhe.
--
-- Importante: GetAnchor() não é confiável aqui — o próprio ESO pode
-- normalizar/converter o ponto de ancoragem internamente ao reportar de
-- volta. GetLeft()/GetTop() sempre retornam a posição real (relativa ao
-- TOPLEFT da tela), então são a fonte confiável pra salvar/converter.
local function ApplyLongPosition()
    if not longContainer then return end
    local sv = CSUtils.savedVars[MODULE_ID].longBox
    local anchorPoint = GetLongBoxAnchorPoint()

    longContainer:ClearAnchors()
    longContainer:SetAnchor(anchorPoint, GuiRoot, TOPLEFT, sv.x, sv.y)
end

local function ApplyReposition()
    if not container then return end
    local allow = CSUtils.savedVars[MODULE_ID].allowReposition
    container:SetMovable(allow)
    container:SetMouseEnabled(allow)
    container.bg:SetHidden(not allow)
    if allow then
        container:SetHidden(false) -- pra dar pra ver e arrastar mesmo sem buff ativo
    else
        container:SetHidden(#buffOrder == 0)
    end
end

local function ApplyLongReposition()
    if not longContainer then return end
    local allow = CSUtils.savedVars[MODULE_ID].allowReposition
    longContainer:SetMovable(allow)
    longContainer:SetMouseEnabled(allow)
    longContainer.bg:SetHidden(not allow)
    if allow then
        longContainer:SetHidden(false)
    else
        longContainer:SetHidden(#longBuffOrder == 0)
    end
end

-- Uma única opção ("Permitir Reposicionar") controla as duas caixas juntas.
local function ApplyAllReposition()
    ApplyReposition()
    ApplyLongReposition()
end

--------------------------------------------------------------------------------
-- ENTRADA <-> RÓTULO (compartilhado pela lista de destaque e de rastreamento
-- manual): cada entrada é uma string (nome exato) ou um number (abilityId).
--------------------------------------------------------------------------------
local function EntryToLabel(entry)
    if type(entry) == "number" then
        return "ID: " .. tostring(entry)
    end
    return entry
end

local function LabelToEntry(label)
    local idStr = label:match("^ID: (%d+)$")
    if idStr then return tonumber(idStr) end
    return label
end

local function ListContainsEntry(list, entry)
    for _, existing in ipairs(list) do
        if existing == entry then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- LISTA DE BUFFS EM DESTAQUE (só se aplica à caixa principal)
--------------------------------------------------------------------------------
local HIGHLIGHT_DROPDOWN_REF = "CSUtils_BuffTracker_HighlightDropdown"

local function IsHighlightedBuff(name, abilityId)
    for _, entry in ipairs(charSavedVars.highlightBuffs) do
        if type(entry) == "number" then
            if abilityId == entry then return true end
        elseif name == entry then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- RASTREAMENTO MANUAL (por nome OU abilityId, mesmo se não for Major/Minor)
--------------------------------------------------------------------------------
-- Cada entrada da lista é uma string (nome exato do efeito) ou um number
-- (abilityId). Um efeito rastreado manualmente é sempre elegível pra
-- exibição e sempre vai pra CAIXA PRINCIPAL, mesmo que a duração dele seria
-- "longa" o bastante pra ir pra caixa de duradouros — é o comportamento
-- pedido: forçar exibição animada de algo específico que o jogador escolheu.
local CUSTOM_DROPDOWN_REF = "CSUtils_BuffTracker_CustomTrackedDropdown"

local function IsCustomTrackedBuff(name, abilityId)
    for _, entry in ipairs(charSavedVars.customTrackedBuffs) do
        if type(entry) == "number" then
            if abilityId == entry then return true end
        elseif type(entry) == "string" then
            if name == entry then return true end
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- REFLOW — CAIXA PRINCIPAL: recalcula os alvos (targetX/targetSize), animado
--------------------------------------------------------------------------------
local function ReflowIcons()
    local sv = CSUtils.savedVars[MODULE_ID]
    local baseSize = sv.iconSize

    -- Primeiro, construímos uma lista de tamanhos (já aplicando destaque)
    local sizes = {}
    for i, slotKey in ipairs(buffOrder) do
        local buff = activeBuffs[slotKey]
        local isHighlight = IsHighlightedBuff(buff.name, buff.abilityId)
        sizes[i] = isHighlight and (baseSize * HIGHLIGHT_SCALE) or baseSize
    end

    -- Calcula largura total do conjunto e centra em 0
    local totalWidth = 0
    for i, size in ipairs(sizes) do
        if i > 1 then totalWidth = totalWidth + ICON_SPACING end
        totalWidth = totalWidth + size
    end

    local cursor = -totalWidth / 2
    local activeSlotSet = {}

    -- Define targets sequencialmente da esquerda para a direita
    for i, slotKey in ipairs(buffOrder) do
        local buff = activeBuffs[slotKey]
        local iconCtrl = AcquireIconForSlot(slotKey)
        activeSlotSet[slotKey] = true

        local size = sizes[i]
        local centerX = cursor + size / 2
        cursor = cursor + size + ICON_SPACING

        if not iconCtrl.initialized then
            -- Ícone novo: já nasce na posição X final e cresce a partir do
            -- tamanho 0 ("pop" no lugar), em vez de deslizar do centro do
            -- container até lá enquanto cresce ao mesmo tempo.
            iconCtrl.currentX = centerX
            iconCtrl.currentSize = 0
            iconCtrl.initialized = true
        end

        iconCtrl.targetX = centerX
        iconCtrl.targetSize = size
        iconCtrl.releasing = false
        iconCtrl.visible = true

        iconCtrl.icon:SetTexture(buff.iconFile)
        local baseFontSize = sv.fontSize or 18
        local finalFontSize = IsHighlightedBuff(buff.name, buff.abilityId) and math.floor(baseFontSize * HIGHLIGHT_SCALE) or baseFontSize
        iconCtrl.durationLabel:SetFont("$(BOLD_FONT)|" .. finalFontSize .. "|outline")

        -- borda (aplica imediatamente, pois não é animada)
        local bThick = sv.borderThickness or 2
        if bThick == 0 then
            iconCtrl.border:SetHidden(true)
        else
            iconCtrl.border:SetHidden(false)
            local bColor = sv.borderColor or {1, 1, 1, 1}
            iconCtrl.border:SetEdgeTexture("", 1, 1, bThick)
            iconCtrl.border:SetEdgeColor(unpack(bColor))
        end
    end

    -- Buffs que saíram de buffOrder: o ícone mantém a posição atual (não
    -- salta pra outro lugar) e só encolhe até sumir; a devolução ao pool de
    -- ícones livres acontece no Tick, quando a animação de saída terminar.
    for slotKey, iconCtrl in pairs(iconsBySlot) do
        if not activeSlotSet[slotKey] then
            iconCtrl.targetSize = 0
            iconCtrl.releasing = true
            iconCtrl.visible = false
        end
    end

    if CSUtils.savedVars[MODULE_ID].allowReposition then
        container:SetHidden(false)
    elseif menuIsOpen then
        container:SetHidden(true)
    else
        container:SetHidden(#buffOrder == 0)
    end

    UpdateTickState()
end

--------------------------------------------------------------------------------
-- REFLOW — CAIXA DE EFEITOS DURADOUROS: posicionamento direto, SEM animação
--------------------------------------------------------------------------------
-- Ordem de exibição: efeitos COM tempo de expiração (comida, pergaminhos de
-- XP/AP etc.) sempre antes dos efeitos PERMANENTES (mundus, undaunted mettle,
-- sem duração definida) — dentro de cada um dos 2 grupos, mantém a ordem de
-- detecção. Assim, comer uma comida nova sempre entra "depois" das comidas já
-- ativas mas "antes" de qualquer permanente; um permanente ativado depois
-- sempre cai pro final da pilha toda.
local function GetLongBoxDisplayOrder()
    local timed, permanent = {}, {}
    for _, name in ipairs(longBuffOrder) do
        local buff = activeLongBuffs[name]
        if buff then
            if buff.endTime > buff.beginTime then
                table.insert(timed, name)
            else
                table.insert(permanent, name)
            end
        end
    end
    -- Índices mais altos ficam na ponta mais distante do canto de ancoragem
    -- (ver GetLongBoxAnchorPoint) — ou seja, o lado pra onde a caixa cresce.
    -- Efeitos PERMANENTES ficam mais perto da âncora (índices baixos); os
    -- efeitos COM tempo (comida, pergaminhos etc.) ficam sempre na ponta
    -- mais distante (índices altos) — pedido explicitamente pelo usuário,
    -- pra sempre cair no topo/base/direita/esquerda dependendo do layout.
    for _, name in ipairs(timed) do
        table.insert(permanent, name)
    end
    return permanent
end

local function ReflowLongBox()
    local sv = CSUtils.savedVars[MODULE_ID].longBox
    local mainSv = CSUtils.savedVars[MODULE_ID]
    local size = sv.iconSize
    local spacing = ICON_SPACING
    local isVertical = (sv.layout == "up" or sv.layout == "down")
    local displayOrder = GetLongBoxDisplayOrder()

    -- Redimensiona o container pra envolver exatamente o conteúdo atual.
    -- Como o container está ancorado (ver ApplyLongPosition/
    -- GetLongBoxAnchorPoint) pelo mesmo canto de onde os ícones começam a
    -- crescer, redimensionar não desloca os ícones já posicionados — só
    -- estende a caixa na direção correta.
    local REPOSITION_MIN_SLOTS = 5 -- "espaço pra N ícones" mostrado durante o reposicionamento
    local count = #displayOrder
    local slotsForSizing = count
    if CSUtils.savedVars[MODULE_ID].allowReposition then
        slotsForSizing = math.max(count, REPOSITION_MIN_SLOTS)
    end

    local contentW, contentH
    if isVertical then
        contentW = size
        contentH = slotsForSizing > 0 and (slotsForSizing * size + (slotsForSizing - 1) * spacing) or size
    else
        contentH = size
        contentW = slotsForSizing > 0 and (slotsForSizing * size + (slotsForSizing - 1) * spacing) or size
    end
    longContainer:SetDimensions(contentW, contentH)
    ApplyLongPosition()

    for i, buffName in ipairs(displayOrder) do
        local buff = activeLongBuffs[buffName]
        local iconCtrl = GetOrCreateLongIcon(i)
        iconCtrl.root.slotKey = buffName

        iconCtrl.root:SetDimensions(size, size)
        iconCtrl.icon:SetTexture(buff.iconFile)
        iconCtrl.durationLabel:SetFont("$(BOLD_FONT)|" .. (sv.fontSize or 14) .. "|outline")

        -- Borda reaproveita a mesma configuração da caixa principal, por
        -- simplicidade (não pedido separar).
        local bThick = mainSv.borderThickness or 2
        if bThick == 0 then
            iconCtrl.border:SetHidden(true)
        else
            iconCtrl.border:SetHidden(false)
            iconCtrl.border:SetEdgeTexture("", 1, 1, bThick)
            iconCtrl.border:SetEdgeColor(unpack(mainSv.borderColor or {1, 1, 1, 1}))
        end

        local offset = (i - 1) * (size + spacing)
        iconCtrl.root:ClearAnchors()

        if sv.layout == "up" then
            iconCtrl.root:SetAnchor(BOTTOMLEFT, longContainer, BOTTOMLEFT, 0, -offset)
        elseif sv.layout == "down" then
            iconCtrl.root:SetAnchor(TOPLEFT, longContainer, TOPLEFT, 0, offset)
        elseif sv.layout == "left" then
            iconCtrl.root:SetAnchor(TOPRIGHT, longContainer, TOPRIGHT, -offset, 0)
        else -- "right" (padrão)
            iconCtrl.root:SetAnchor(TOPLEFT, longContainer, TOPLEFT, offset, 0)
        end

        iconCtrl.root:SetHidden(false)
    end

    for i = count + 1, #longIconPool do
        longIconPool[i].root:SetHidden(true)
        longIconPool[i].root.slotKey = nil
    end

    if CSUtils.savedVars[MODULE_ID].allowReposition then
        longContainer:SetHidden(false)
    elseif menuIsOpen then
        longContainer:SetHidden(true)
    else
        longContainer:SetHidden(#longBuffOrder == 0)
    end

    UpdateLongTickState()
end

--------------------------------------------------------------------------------
-- GERENCIAMENTO DA LISTA DE DESTAQUE (add/remove/dropdown)
--------------------------------------------------------------------------------
local function RefreshHighlightDropdown()
    local dropdown = _G[HIGHLIGHT_DROPDOWN_REF]
    if not dropdown then return end

    local labels = {}
    for i, entry in ipairs(charSavedVars.highlightBuffs) do
        labels[i] = EntryToLabel(entry)
    end
    dropdown:UpdateChoices(labels)
    dropdown:UpdateValue()
end

local function AddHighlightBuff(value)
    if not value then return end
    value = value:match("^%s*(.-)%s*$") -- trim
    if value == "" then return end

    -- Se for só dígitos, trata como abilityId; senão, como nome exato.
    local entry = value:match("^%d+$") and tonumber(value) or value

    local list = charSavedVars.highlightBuffs
    if ListContainsEntry(list, entry) then return end

    table.insert(list, entry)
    ReflowIcons()
    RefreshHighlightDropdown()
end

local function RemoveHighlightBuff(entry)
    local list = charSavedVars.highlightBuffs
    for i, existing in ipairs(list) do
        if existing == entry then
            table.remove(list, i)
            break
        end
    end
    ReflowIcons()
    RefreshHighlightDropdown()
end

ZO_Dialogs_RegisterCustomDialog("CSUTILS_BUFFTRACKER_REMOVE_HIGHLIGHT", {
    title = { text = "Remover Destaque" },
    mainText = {
        text = function(dialog)
            return string.format("Remover \"%s\" da lista de buffs em destaque?", dialog.data.label)
        end,
    },
    buttons = {
        {
            text = SI_DIALOG_YES,
            callback = function(dialog)
                RemoveHighlightBuff(dialog.data.entry)
            end,
        },
        {
            text = SI_DIALOG_NO,
        },
    },
})

--------------------------------------------------------------------------------
-- GERENCIAMENTO DO RASTREAMENTO MANUAL (add/remove/dropdown)
--------------------------------------------------------------------------------
local function RefreshCustomTrackedDropdown()
    local dropdown = _G[CUSTOM_DROPDOWN_REF]
    if not dropdown then return end

    local labels = {}
    for i, entry in ipairs(charSavedVars.customTrackedBuffs) do
        labels[i] = EntryToLabel(entry)
    end
    dropdown:UpdateChoices(labels)
    dropdown:UpdateValue()
end

local function AddCustomTrackedBuff(value)
    if not value then return end
    value = value:match("^%s*(.-)%s*$") -- trim
    if value == "" then return end

    -- Se for só dígitos, trata como abilityId; senão, como nome exato.
    local entry = value:match("^%d+$") and tonumber(value) or value

    for _, existing in ipairs(charSavedVars.customTrackedBuffs) do
        if existing == entry then return end -- já rastreado
    end

    table.insert(charSavedVars.customTrackedBuffs, entry)
    RefreshCustomTrackedDropdown()

    -- Reavalia os buffs já ativos agora, em vez de esperar o próximo evento
    -- EVENT_EFFECT_CHANGED (que pode demorar pra vir, ou nem vir, se o efeito
    -- for algo estático que já estava ativo há muito tempo).
    ScanExistingBuffs()
end

local function RemoveCustomTrackedBuff(entry)
    local list = charSavedVars.customTrackedBuffs
    for i, existing in ipairs(list) do
        if existing == entry then
            table.remove(list, i)
            break
        end
    end
    RefreshCustomTrackedDropdown()
    ScanExistingBuffs()
end

ZO_Dialogs_RegisterCustomDialog("CSUTILS_BUFFTRACKER_REMOVE_CUSTOM", {
    title = { text = "Remover Rastreamento Manual" },
    mainText = {
        text = function(dialog)
            return string.format("Parar de rastrear \"%s\" manualmente?", dialog.data.label)
        end,
    },
    buttons = {
        {
            text = SI_DIALOG_YES,
            callback = function(dialog)
                RemoveCustomTrackedBuff(dialog.data.entry)
            end,
        },
        {
            text = SI_DIALOG_NO,
        },
    },
})

--------------------------------------------------------------------------------
-- TICK — CAIXA PRINCIPAL: contagem regressiva, pisca perto de expirar, anima
--------------------------------------------------------------------------------
-- Só mantém o timer de 50ms rodando enquanto existe trabalho de verdade a
-- fazer: algum buff ativo (buffOrder) ou algum ícone ainda encolhendo pra
-- sair de cena (iconsBySlot não-vazio). Na maior parte do tempo fora de
-- combate isso deixa o módulo com ZERO overhead por frame, em vez de ficar
-- chamando Tick() 20x/seg à toa.
UpdateTickState = function()
    local hasWork = (#buffOrder > 0) or (next(iconsBySlot) ~= nil)
    if hasWork and not tickActive then
        tickActive = true
        EVENT_MANAGER:RegisterForUpdate(MODULE_ID .. "Tick", 50, Tick)
    elseif not hasWork and tickActive then
        tickActive = false
        EVENT_MANAGER:UnregisterForUpdate(MODULE_ID .. "Tick")
    end
end

Tick = function()
    -- Atualizações de tempo/piscar/remover como antes
    local now = GetGameTimeSeconds()
    local removed = false
    for i = #buffOrder, 1, -1 do
        local slotKey = buffOrder[i]
        local buff = activeBuffs[slotKey]
        if not buff then
            table.remove(buffOrder, i)
            removed = true
        elseif buff.endTime > buff.beginTime and buff.endTime - now <= 0 then
            activeBuffs[slotKey] = nil
            if buff.effectSlot and slotToName[buff.effectSlot] == slotKey then
                slotToName[buff.effectSlot] = nil
            end
            table.remove(buffOrder, i)
            removed = true
        end
    end

    if removed then
        ReflowIcons()
    end

    -- Interpolação (suavização) baseada em fator maior + snapping
    local lerpFactor = 0.52  -- valor maior = mais rápido; ajuste entre 0.35..0.7 conforme gosto
    local snapThreshold = 0.8 -- distância em pixels/tamanho abaixo da qual "snap" para o alvo

    -- Itera por identidade (slotKey), não por posição no pool: cada ícone
    -- sempre representa o mesmo buff do frame anterior até ser liberado.
    for slotKey, iconCtrl in pairs(iconsBySlot) do
        local targetSize = iconCtrl.targetSize or 0
        local targetX = iconCtrl.targetX or 0

        -- Lerp
        iconCtrl.currentSize = iconCtrl.currentSize + (targetSize - iconCtrl.currentSize) * lerpFactor
        iconCtrl.currentX    = iconCtrl.currentX    + (targetX    - iconCtrl.currentX)    * lerpFactor

        -- Snapping quando muito próximo para evitar "arrastar"
        if math.abs(iconCtrl.currentSize - targetSize) < snapThreshold then
            iconCtrl.currentSize = targetSize
        end
        if math.abs(iconCtrl.currentX - targetX) < snapThreshold then
            iconCtrl.currentX = targetX
        end

        if targetSize < 1 and iconCtrl.currentSize < 1 then
            if iconCtrl.lastAppliedSize ~= 0 then
                iconCtrl.root:SetHidden(true)
                iconCtrl.lastAppliedSize = 0
            end
            if iconCtrl.releasing then
                ReleaseIcon(iconCtrl) -- devolve ao pool só agora, animação já terminou
            end
        else
            -- Só chama SetDimensions/SetAnchor de novo se o valor renderizado
            -- (arredondado) realmente mudou desde o último tick — parado no
            -- alvo, um ícone não precisa reancorar 20x/seg à toa.
            local sizeInt = math.max(1, math.floor(iconCtrl.currentSize + 0.5))
            local xRounded = math.floor(iconCtrl.currentX + 0.5)
            if iconCtrl.lastAppliedSize ~= sizeInt or iconCtrl.lastAppliedX ~= xRounded then
                iconCtrl.root:SetDimensions(sizeInt, sizeInt)
                iconCtrl.root:ClearAnchors()
                iconCtrl.root:SetAnchor(CENTER, container, CENTER, xRounded, 0)
                iconCtrl.root:SetHidden(false)
                iconCtrl.lastAppliedSize = sizeInt
                iconCtrl.lastAppliedX = xRounded
            end
        end
    end

    -- Agora atualiza os labels/pisca apenas para ícones ativos, na ordem
    for _, slotKey in ipairs(buffOrder) do
        local buff = activeBuffs[slotKey]
        local iconCtrl = iconsBySlot[slotKey]
        if iconCtrl and buff then
            if buff.endTime > buff.beginTime then
                local remaining = math.max(buff.endTime - now, 0)
                local secondsInt = math.floor(remaining + 0.5)

                -- O número exibido só muda 1x por segundo de verdade; evita
                -- reescrever o mesmo texto até 20x/seg.
                if iconCtrl.lastDisplayedSeconds ~= secondsInt then
                    iconCtrl.durationLabel:SetText(tostring(secondsInt))
                    iconCtrl.lastDisplayedSeconds = secondsInt
                end

                if remaining <= BLINK_WINDOW then
                    -- Dentro da janela de pisca o alpha muda a cada frame de
                    -- propósito (é a animação), então aplica sempre.
                    local phase = remaining * (2 * math.pi) / BLINK_PERIOD
                    local alpha = BLINK_MIN_ALPHA + (1 - BLINK_MIN_ALPHA) * (0.5 + 0.5 * math.sin(phase))
                    iconCtrl.root:SetAlpha(alpha)
                    iconCtrl.lastAlpha = alpha
                elseif iconCtrl.lastAlpha ~= 1 then
                    iconCtrl.root:SetAlpha(1)
                    iconCtrl.lastAlpha = 1
                end
            else
                if iconCtrl.lastDisplayedSeconds ~= false then
                    iconCtrl.durationLabel:SetText("")
                    iconCtrl.lastDisplayedSeconds = false
                end
                if iconCtrl.lastAlpha ~= 1 then
                    iconCtrl.root:SetAlpha(1)
                    iconCtrl.lastAlpha = 1
                end
            end
        end
    end

    UpdateTickState()
end

--------------------------------------------------------------------------------
-- TICK — CAIXA DE EFEITOS DURADOUROS: só atualiza número/expiração, 1x/seg,
-- sem nenhuma animação (nem pisca, nem lerp).
--------------------------------------------------------------------------------
UpdateLongTickState = function()
    local hasWork = #longBuffOrder > 0
    if hasWork and not longTickActive then
        longTickActive = true
        EVENT_MANAGER:RegisterForUpdate(MODULE_ID .. "LongTick", 1000, LongTick)
    elseif not hasWork and longTickActive then
        longTickActive = false
        EVENT_MANAGER:UnregisterForUpdate(MODULE_ID .. "LongTick")
    end
end

LongTick = function()
    local now = GetGameTimeSeconds()
    local removed = false

    for i = #longBuffOrder, 1, -1 do
        local buffName = longBuffOrder[i]
        local buff = activeLongBuffs[buffName]
        if not buff then
            table.remove(longBuffOrder, i)
            removed = true
        elseif buff.endTime > buff.beginTime and buff.endTime - now <= 0 then
            activeLongBuffs[buffName] = nil
            if buff.effectSlot and slotToName[buff.effectSlot] == buffName then
                slotToName[buff.effectSlot] = nil
            end
            table.remove(longBuffOrder, i)
            removed = true
        end
    end

    if removed then
        ReflowLongBox() -- já chama UpdateLongTickState no final
        return
    end

    for i, buffName in ipairs(GetLongBoxDisplayOrder()) do
        local buff = activeLongBuffs[buffName]
        local iconCtrl = longIconPool[i]
        if iconCtrl and buff then
            if buff.endTime > buff.beginTime then
                local remaining = math.max(buff.endTime - now, 0)
                iconCtrl.durationLabel:SetText(FormatLongDuration(remaining))
            else
                iconCtrl.durationLabel:SetText("")
            end
        end
    end
end

--------------------------------------------------------------------------------
-- RASTREAMENTO DE BUFFS (classifica em caixa principal ou de duradouros)
--------------------------------------------------------------------------------
local function RemoveBuff(buffName)
    local buff = activeBuffs[buffName]
    if buff then
        activeBuffs[buffName] = nil
        for i, key in ipairs(buffOrder) do
            if key == buffName then
                table.remove(buffOrder, i)
                break
            end
        end
        if buff.effectSlot and slotToName[buff.effectSlot] == buffName then
            slotToName[buff.effectSlot] = nil
        end
        ReflowIcons()
        return
    end

    local longBuff = activeLongBuffs[buffName]
    if longBuff then
        activeLongBuffs[buffName] = nil
        for i, key in ipairs(longBuffOrder) do
            if key == buffName then
                table.remove(longBuffOrder, i)
                break
            end
        end
        if longBuff.effectSlot and slotToName[longBuff.effectSlot] == buffName then
            slotToName[longBuff.effectSlot] = nil
        end
        ReflowLongBox()
    end
end

local function OnEffectChanged(eventCode, changeType, effectSlot, effectName, unitTag, beginTime, endTime,
                                stackCount, iconName, buffType, effectType, abilityType, statusEffectType,
                                unitName, unitId, abilityId, sourceUnitType)
    if unitTag ~= "player" then return end
    if effectType ~= BUFF_EFFECT_TYPE_BUFF then return end -- só buffs positivos, nunca debuffs

    if changeType == EFFECT_RESULT_FADED then
        -- Roteia o FADED pelo nome que esse effectSlot representava por
        -- último. Conteúdos que reaplicam buffs de grupo com frequência (ex:
        -- dummy de trial simulando 12 jogadores, renovando tudo a cada
        -- segundo) fazem o jogo criar uma instância nova (effectSlot novo) a
        -- cada reaplicação, enquanto a antiga genuinamente expira. Como só
        -- rastreamos por nome (só existe 1 instância possível de cada
        -- Major/Minor), só removemos da tela se esse effectSlot ainda for o
        -- que está associado ao nome — se o buff já foi renovado com um
        -- effectSlot mais novo antes desse FADED chegar, ignoramos, porque
        -- ele já não representa o que está exibido.
        local buffName = slotToName[effectSlot]
        slotToName[effectSlot] = nil
        if buffName then
            local current = activeBuffs[buffName] or activeLongBuffs[buffName]
            if current and current.effectSlot == effectSlot then
                RemoveBuff(buffName)
            end
        end
        return
    end

    local isMajorMinor = IsMajorMinorBuff(effectName)
    local isCustom = IsCustomTrackedBuff(effectName, abilityId)
    local isLong = IsLongDurationBuff(beginTime, endTime)

    -- Elegibilidade pra rastrear um efeito:
    --   - Major/Minor: sempre (curta ou longa duração, cada uma pra sua caixa)
    --   - rastreado manualmente: sempre, forçado pra caixa principal
    --   - nenhum dos dois: só se for de longa duração / sem expiração —
    --     assim mundus, comida, pergaminhos de XP/AP etc. aparecem na caixa
    --     de duradouros automaticamente, sem precisar de lista fixa de nomes
    --     pra cada um (é a mesma lógica que a própria UI nativa do ESO usa
    --     pra agrupar "efeitos permanentes sem duração" e "efeitos com mais
    --     de 1 minuto" separado do resto).
    if not isMajorMinor and not isCustom and not isLong then return end

    slotToName[effectSlot] = effectName

    local entry = {
        name       = effectName,
        iconFile   = iconName,
        beginTime  = beginTime,
        endTime    = endTime,
        abilityId  = abilityId,
        effectSlot = effectSlot,
    }

    -- Rastreamento manual sempre força a caixa principal, mesmo que a
    -- duração real seja "longa" — é justamente o ponto de adicionar um
    -- efeito manualmente: quer vê-lo animado, com destaque, na caixa
    -- principal, mesmo que ele não se qualificasse ali por conta própria.
    local goesToLongBox = isLong and not isCustom

    if goesToLongBox then
        -- Se estava na caixa principal (raro: renovado com duração bem
        -- maior que antes), remove de lá primeiro.
        if activeBuffs[effectName] then
            activeBuffs[effectName] = nil
            for i, key in ipairs(buffOrder) do
                if key == effectName then table.remove(buffOrder, i) break end
            end
            ReflowIcons()
        end

        local isNew = activeLongBuffs[effectName] == nil
        activeLongBuffs[effectName] = entry
        if isNew then table.insert(longBuffOrder, effectName) end
        ReflowLongBox()
    else
        -- Se estava na caixa de duradouros (raro: renovado com duração bem
        -- menor que antes, ou acabou de virar rastreamento manual), remove
        -- de lá primeiro.
        if activeLongBuffs[effectName] then
            activeLongBuffs[effectName] = nil
            for i, key in ipairs(longBuffOrder) do
                if key == effectName then table.remove(longBuffOrder, i) break end
            end
            ReflowLongBox()
        end

        local isNew = activeBuffs[effectName] == nil
        activeBuffs[effectName] = entry
        if isNew then table.insert(buffOrder, effectName) end
        ReflowIcons()
    end
end

-- Faz um scan completo dos buffs já ativos (login/reload/ativação do módulo,
-- ou quando a lista de rastreamento manual muda), já que o evento
-- EVENT_EFFECT_CHANGED só dispara pra mudanças a partir do momento em que é
-- registrado, não pros buffs que já estavam ativos antes.
ScanExistingBuffs = function()
    activeBuffs = {}
    buffOrder = {}
    activeLongBuffs = {}
    longBuffOrder = {}
    slotToName = {}

    for i = 1, GetNumBuffs("player") do
        local name, beginTime, endTime, buffSlot, stackCount, iconFile, buffType, effectType, abilityType,
              statusEffectType, abilityId = GetUnitBuffInfo("player", i)
        if effectType == BUFF_EFFECT_TYPE_BUFF then
            local isMajorMinor = IsMajorMinorBuff(name)
            local isCustom = IsCustomTrackedBuff(name, abilityId)
            local isLong = IsLongDurationBuff(beginTime, endTime)

            -- Mesma regra de elegibilidade/classificação do OnEffectChanged:
            -- ver comentário lá pra detalhes.
            if isMajorMinor or isCustom or isLong then
                local entry = {
                    name = name, iconFile = iconFile, beginTime = beginTime, endTime = endTime,
                    abilityId = abilityId, effectSlot = buffSlot,
                }
                slotToName[buffSlot] = name

                if isLong and not isCustom then
                    activeLongBuffs[name] = entry
                    table.insert(longBuffOrder, name)
                else
                    activeBuffs[name] = entry
                    table.insert(buffOrder, name)
                end
            end
        end
    end

    ReflowIcons()
    ReflowLongBox()
end

--------------------------------------------------------------------------------
-- VISIBILIDADE AO ABRIR MENUS (inventário, personagem, menu do jogo etc.)
--------------------------------------------------------------------------------
-- "hud" e "hudui" são as duas cenas "no mundo" (sem nenhum menu por cima);
-- qualquer outra cena ativa (bag, character, gameMenuInGame, crafting,
-- guild bank, mapa, etc.) significa que algum menu está aberto por cima da
-- HUD. As duas caixas somem instantaneamente nesse caso (sem animação) e
-- voltam ao estado normal assim que a cena volta a ser hud/hudui.
-- (menuIsOpen já declarada lá em cima, na seção ESTADO DO MÓDULO)

local function IsInWorldSceneName(name)
    return name == "hud" or name == "hudui"
end

local function ApplyMenuVisibility()
    if not container or not longContainer then return end

    -- Reposicionamento sempre tem prioridade: se está destravado pra
    -- arrastar, a caixa fica visível mesmo com um menu aberto (o próprio
    -- painel de configurações do CS Utils conta como "menu aberto", e é
    -- justamente ali que se ajusta a posição).
    if CSUtils.savedVars[MODULE_ID].allowReposition then
        container:SetHidden(false)
        longContainer:SetHidden(false)
        return
    end

    if menuIsOpen then
        container:SetHidden(true)
        longContainer:SetHidden(true)
    else
        container:SetHidden(#buffOrder == 0)
        longContainer:SetHidden(#longBuffOrder == 0)
    end
end

local function OnSceneStateChanged(scene, newState)
    if not isEnabled then return end
    if newState ~= SCENE_SHOWN and newState ~= SCENE_HIDDEN then return end

    local current = SCENE_MANAGER:GetCurrentScene()
    local currentName = current and current:GetName()
    local nowMenuOpen = not IsInWorldSceneName(currentName)

    if nowMenuOpen ~= menuIsOpen then
        menuIsOpen = nowMenuOpen
        ApplyMenuVisibility()
    end
end

--------------------------------------------------------------------------------
-- ENABLE / DISABLE (hot toggle)
--------------------------------------------------------------------------------
local function EnableModule()
    if isEnabled then return end
    isEnabled = true

    EVENT_MANAGER:RegisterForEvent(MODULE_ID, EVENT_EFFECT_CHANGED, OnEffectChanged)
    EVENT_MANAGER:AddFilterForEvent(MODULE_ID, EVENT_EFFECT_CHANGED, REGISTER_FILTER_UNIT_TAG, "player")
    SCENE_MANAGER:RegisterCallback("SceneStateChanged", OnSceneStateChanged)

    -- Estado inicial: parte do princípio de que a HUD normal está ativa
    -- (Init roda depois do login, com o jogo já no mundo).
    menuIsOpen = false

    -- ScanExistingBuffs chama ReflowIcons/ReflowLongBox, que por sua vez
    -- chamam UpdateTickState/UpdateLongTickState: os timers só ligam aqui se
    -- já existir algum Major/Minor ativo no momento em que o módulo é
    -- habilitado.
    ScanExistingBuffs()
end

local function DisableModule()
    if not isEnabled then return end
    isEnabled = false

    EVENT_MANAGER:UnregisterForEvent(MODULE_ID, EVENT_EFFECT_CHANGED)
    EVENT_MANAGER:UnregisterForUpdate(MODULE_ID .. "Tick")
    EVENT_MANAGER:UnregisterForUpdate(MODULE_ID .. "LongTick")
    SCENE_MANAGER:UnregisterCallback("SceneStateChanged", OnSceneStateChanged)
    tickActive = false
    longTickActive = false

    activeBuffs = {}
    buffOrder = {}
    activeLongBuffs = {}
    longBuffOrder = {}
    slotToName = {}

    -- Devolve todos os ícones da caixa principal ao pool livre e limpa o
    -- estado visual, pra não deixar "fantasmas" de identidade se o módulo
    -- for reativado depois.
    for slotKey, iconCtrl in pairs(iconsBySlot) do
        ReleaseIcon(iconCtrl)
    end

    for _, iconCtrl in ipairs(longIconPool) do
        iconCtrl.root:SetHidden(true)
        iconCtrl.root.slotKey = nil
    end

    if container then container:SetHidden(true) end
    if longContainer then longContainer:SetHidden(true) end
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------
local function Init()
    CreateContainer()
    CreateLongContainer()

    -- Namespace próprio dentro do mesmo CSUtils_SavedVars.lua, keyed por
    -- personagem (por ID interno, sobrevive a troca de nome do char).
    charSavedVars = ZO_SavedVars:NewCharacterIdSettings("CSUtils_SavedVars", 1, "buffTrackerChar", CHAR_DEFAULTS)

    ApplyPosition()
    ApplyLongPosition()
    ApplyAllReposition()

    if CSUtils.savedVars.modules[MODULE_ID] then
        EnableModule()
    end
end

--------------------------------------------------------------------------------
-- REGISTRO DO MÓDULO NO CORE
--------------------------------------------------------------------------------
CSUtils:RegisterModule(
    MODULE_ID,
    "Buff Tracker",
    "Barra enxuta que rastreia seus Major/Minor buffs ativos, com contagem regressiva e aviso piscando perto de expirar. Efeitos duradouros (comida, mundus etc) ficam numa segunda caixa separada.",
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
                    name = "Permitir Reposicionar",
                    tooltip = "Destrava as DUAS caixas (principal e de efeitos duradouros) pra arrastar na tela (mostra um fundo de referência enquanto estiver destravado).",
                    getFunc = function() return CSUtils.savedVars[MODULE_ID].allowReposition end,
                    setFunc = function(v)
                        CSUtils.savedVars[MODULE_ID].allowReposition = v
                        ApplyAllReposition()
                    end,
                    default = defaults.allowReposition,
                },
                {
                    type = "submenu",
                    name = "Caixa Principal (Curta Duração)",
                    tooltip = "Configurações da caixa de buffs de combate/curta duração.",
                    controls = {
                        {
                            type = "editbox",
                            name = "Adicionar Efeito (Nome ou ID)",
                            tooltip = "Digite o nome exato do efeito (ex: \"Empower\") OU o Ability ID numérico, e pressione Enter. Passa a aparecer na Caixa Principal mesmo não sendo Major/Minor. Útil pra buffs/procs específicos que você quer acompanhar de perto.",
                            isMultiline = false,
                            getFunc = function() return "" end,
                            setFunc = function(v) AddCustomTrackedBuff(v) end,
                        },
                        {
                            type = "dropdown",
                            name = "Efeitos Adicionados (clique pra remover)",
                            tooltip = "Selecione um efeito da lista pra parar de rastreá-lo manualmente.",
                            choices = (function()
                                local labels = {}
                                for i, entry in ipairs(charSavedVars.customTrackedBuffs) do
                                    labels[i] = EntryToLabel(entry)
                                end
                                return labels
                            end)(),
                            getFunc = function() return "" end,
                            setFunc = function(value)
                                local entry = LabelToEntry(value)
                                ZO_Dialogs_ShowDialog("CSUTILS_BUFFTRACKER_REMOVE_CUSTOM", { entry = entry, label = value })
                            end,
                            reference = CUSTOM_DROPDOWN_REF,
                        },
                        {
                            type = "divider",
                        },
                        {
                            type = "editbox",
                            name = "Adicionar Buff em Destaque",
                            tooltip = "Digite o nome exato do buff (ex: \"Major Sorcery\") OU o Ability ID numérico, e pressione Enter pra adicionar à lista de destaque abaixo. Pode adicionar quantos quiser.",
                            isMultiline = false,
                            getFunc = function() return "" end,
                            setFunc = function(v) AddHighlightBuff(v) end,
                        },
                        {
                            type = "dropdown",
                            name = "Buffs em Destaque (clique pra remover)",
                            tooltip = "Selecione um buff da lista pra remover o destaque dele.",
                            choices = (function()
                                local labels = {}
                                for i, entry in ipairs(charSavedVars.highlightBuffs) do
                                    labels[i] = EntryToLabel(entry)
                                end
                                return labels
                            end)(),
                            getFunc = function() return "" end,
                            setFunc = function(value)
                                local entry = LabelToEntry(value)
                                ZO_Dialogs_ShowDialog("CSUTILS_BUFFTRACKER_REMOVE_HIGHLIGHT", { entry = entry, label = value })
                            end,
                            reference = HIGHLIGHT_DROPDOWN_REF,
                        },
                        {
                            type = "divider",
                        },
                        {
                            type = "slider",
                            name = "Tamanho do Ícone",
                            tooltip = "Tamanho (em pixels) de cada ícone de buff.",
                            min = 20, max = 80, step = 1,
                            getFunc = function() return CSUtils.savedVars[MODULE_ID].iconSize end,
                            setFunc = function(v)
                                CSUtils.savedVars[MODULE_ID].iconSize = v
                                ReflowIcons()
                            end,
                            default = defaults.iconSize,
                        },
                        {
                            type = "slider",
                            name = "Tamanho do Número",
                            tooltip = "Ajusta o tamanho da fonte da contagem regressiva.",
                            min = 10, max = 40, step = 1,
                            getFunc = function() return CSUtils.savedVars[MODULE_ID].fontSize or 18 end,
                            setFunc = function(v)
                                CSUtils.savedVars[MODULE_ID].fontSize = v
                                ReflowIcons()
                            end,
                            default = defaults.fontSize,
                        },
                        {
                            type = "slider",
                            name = "Espessura da Borda",
                            tooltip = "Define a grossura da borda dos ícones de buff (vale pras 2 caixas). Deixe em 0 para remover a borda.",
                            min = 0, max = 5, step = 1,
                            getFunc = function() return CSUtils.savedVars[MODULE_ID].borderThickness or 2 end,
                            setFunc = function(v)
                                CSUtils.savedVars[MODULE_ID].borderThickness = v
                                ReflowIcons()
                                ReflowLongBox()
                            end,
                            default = defaults.borderThickness,
                        },
                        {
                            type = "colorpicker",
                            name = "Cor da Borda",
                            tooltip = "Altera a cor da borda dos ícones (vale pras 2 caixas).",
                            getFunc = function()
                                local c = CSUtils.savedVars[MODULE_ID].borderColor or defaults.borderColor
                                return unpack(c)
                            end,
                            setFunc = function(r, g, b, a)
                                CSUtils.savedVars[MODULE_ID].borderColor = {r, g, b, a}
                                ReflowIcons()
                                ReflowLongBox()
                            end,
                            default = defaults.borderColor,
                        },
                    },
                },
                {
                    type = "submenu",
                    name = "Caixa de Efeitos Duradouros",
                    tooltip = "Configurações da caixa separada pra buffs de longa duração ou sem expiração (comida, mundus, undaunted mettle etc). Sem animação — só a caixa principal anima.",
                    controls = {
                        {
                            type = "slider",
                            name = "Tamanho do Ícone",
                            tooltip = "Tamanho (em pixels) de cada ícone de buff duradouro.",
                            min = 20, max = 80, step = 1,
                            getFunc = function() return CSUtils.savedVars[MODULE_ID].longBox.iconSize end,
                            setFunc = function(v)
                                CSUtils.savedVars[MODULE_ID].longBox.iconSize = v
                                ReflowLongBox()
                            end,
                            default = defaults.longBox.iconSize,
                        },
                        {
                            type = "slider",
                            name = "Tamanho do Número",
                            tooltip = "Ajusta o tamanho da fonte da contagem regressiva.",
                            min = 10, max = 40, step = 1,
                            getFunc = function() return CSUtils.savedVars[MODULE_ID].longBox.fontSize end,
                            setFunc = function(v)
                                CSUtils.savedVars[MODULE_ID].longBox.fontSize = v
                                ReflowLongBox()
                            end,
                            default = defaults.longBox.fontSize,
                        },
                        {
                            type = "dropdown",
                            name = "Layout",
                            tooltip = "Direção em que os ícones crescem a partir do ponto onde a caixa está ancorada na tela.",
                            choices = { "Horizontal (direita)", "Horizontal (esquerda)", "Vertical (para baixo)", "Vertical (para cima)" },
                            getFunc = function()
                                local map = {
                                    right = "Horizontal (direita)", left = "Horizontal (esquerda)",
                                    down = "Vertical (para baixo)", up = "Vertical (para cima)",
                                }
                                return map[CSUtils.savedVars[MODULE_ID].longBox.layout] or "Horizontal (direita)"
                            end,
                            setFunc = function(value)
                                local map = {
                                    ["Horizontal (direita)"] = "right", ["Horizontal (esquerda)"] = "left",
                                    ["Vertical (para baixo)"] = "down", ["Vertical (para cima)"] = "up",
                                }

                                -- Captura o retângulo físico ATUAL (sempre
                                -- confiável via GetLeft/GetTop, independente
                                -- do anchor point usado até agora) antes de
                                -- trocar o layout.
                                local left, top = longContainer:GetLeft(), longContainer:GetTop()
                                local w, h = longContainer:GetDimensions()

                                CSUtils.savedVars[MODULE_ID].longBox.layout = map[value] or "right"

                                -- Recalcula o canto certo pro NOVO layout, a
                                -- partir do mesmo retângulo físico — a caixa
                                -- continua exatamente onde estava visualmente.
                                local sv = CSUtils.savedVars[MODULE_ID].longBox
                                local newAnchorPoint = GetLongBoxAnchorPoint()
                                if newAnchorPoint == TOPRIGHT then
                                    sv.x, sv.y = left + w, top
                                elseif newAnchorPoint == BOTTOMLEFT then
                                    sv.x, sv.y = left, top + h
                                else
                                    sv.x, sv.y = left, top
                                end

                                ReflowLongBox()
                            end,
                        },
                    },
                },
            }
        end,
    }
)