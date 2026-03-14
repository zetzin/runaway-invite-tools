-- Runaway Invite Tools - Core.lua
-- Fila de summon para raids: quem escrever "123" no chat de raid entra na lista.
-- Warlocks recebem alertas especiais para abrir o portal de summon.

local ADDON_NAME = "Runaway Invite Tools"

-- ============================================================
-- CONSTANTES
-- ============================================================
local TRIGGER          = "123"          -- palavra-chave no chat
local ROW_HEIGHT       = 32             -- altura de cada entrada na lista
local FRAME_WIDTH      = 290            -- largura do frame principal
local MAX_VISIBLE_ROWS = 10             -- máximo de linhas visíveis antes do scroll
local GLOW_SPEED       = 2.0            -- velocidade do pulso (ciclos/segundo)
local WARLOCK_ALERT_DURATION = 0        -- 0 = fica até ser dispensado manualmente

-- Cor do glow (ouro)
local GLOW_R, GLOW_G, GLOW_B = 1.0, 0.82, 0.0

-- ============================================================
-- ESTADO GLOBAL DO ADDON
-- ============================================================
local queue       = {}   -- array de entradas: { name, fullName, class, joinTime }
local inQueue     = {}   -- set: stripped_name -> true (evita duplicatas)
local isWarlock   = false

-- Referências aos frames (criados em Init)
local MainFrame      = nil
local WarlockAlert   = nil
local rowPool        = {}   -- pool de frames de linha reutilizáveis
local activeRows     = {}   -- linhas atualmente exibidas

-- ============================================================
-- UTILITÁRIOS
-- ============================================================
local function StripRealm(name)
    if not name then return "Desconhecido" end
    return (name:match("^([^%-]+)")) or name
end

local function GetClassRGB(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.8, 0.8, 0.8
end

local function FormatElapsed(seconds)
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    if m > 0 then
        return string.format("%dm%02ds", m, s)
    else
        return string.format("%ds", s)
    end
end

local function FindClassInRaid(strippedName)
    for i = 1, GetNumGroupMembers() do
        local n, _, _, _, _, className = GetRaidRosterInfo(i)
        if n and StripRealm(n) == strippedName then
            return className  -- fileName = uppercase English class
        end
    end
    return nil
end

-- ============================================================
-- GERENCIAMENTO DA FILA
-- ============================================================
local function EnqueuePlayer(fullName, classHint)
    local name = StripRealm(fullName)
    if inQueue[name] then return end  -- já está na fila

    inQueue[name] = true
    local class = classHint or FindClassInRaid(name) or "UNKNOWN"

    table.insert(queue, {
        name     = name,
        fullName = fullName,
        class    = class,
        joinTime = GetTime(),
    })

    -- Atualiza UI
    if MainFrame then
        MainFrame.Refresh()
        MainFrame.StartGlow()
        MainFrame:Show()
    end

    -- Alerta para Warlocks
    if isWarlock and WarlockAlert then
        WarlockAlert.Flash(name, class)
    end

    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
end

local function DequeuePlayer(name)
    if not inQueue[name] then return end
    inQueue[name] = nil
    for i, entry in ipairs(queue) do
        if entry.name == name then
            table.remove(queue, i)
            break
        end
    end
    if MainFrame then
        MainFrame.Refresh()
        if #queue == 0 then
            MainFrame.StopGlow()
            MainFrame:Hide()
            if WarlockAlert then WarlockAlert:Hide() end
        end
    end
end

local function ClearQueue()
    wipe(queue)
    wipe(inQueue)
    if MainFrame then
        MainFrame.Refresh()
        MainFrame.StopGlow()
        MainFrame:Hide()
        if WarlockAlert then WarlockAlert:Hide() end
    end
end

-- Tenta resolver classes "UNKNOWN" após atualização do roster
local function ResolveUnknownClasses()
    local changed = false
    for _, entry in ipairs(queue) do
        if entry.class == "UNKNOWN" then
            local found = FindClassInRaid(entry.name)
            if found then
                entry.class = found
                changed = true
            end
        end
    end
    if changed and MainFrame then
        MainFrame.Refresh()
    end
end

-- ============================================================
-- UI: LINHAS DA FILA (pool de frames reutilizáveis)
-- ============================================================
local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetHeight(ROW_HEIGHT)

        -- Fundo alternado (definido no Refresh)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()

        -- Ícone de classe
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(22, 22)
        row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)

        -- Nome do jogador (colorido pela classe)
        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.nameText:SetPoint("RIGHT", row, "RIGHT", -70, 0)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        -- Tempo na fila
        row.timeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.timeText:SetPoint("RIGHT", row, "RIGHT", -32, 0)
        row.timeText:SetJustifyH("RIGHT")
        row.timeText:SetTextColor(0.55, 0.55, 0.55)

        -- Botão de "summonado" (checkmark)
        local btn = CreateFrame("Button", nil, row)
        btn:SetSize(26, 26)
        btn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        btn:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Check")
        btn:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText("Marcar como summonado", 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.doneBtn = btn

        -- Linha separadora
        row.sep = row:CreateTexture(nil, "ARTWORK")
        row.sep:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
        row.sep:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
        row.sep:SetHeight(1)
        row.sep:SetColorTexture(0.3, 0.3, 0.5, 0.4)
    end
    row:SetParent(parent)
    row:Show()
    return row
end

local function ReleaseRow(row)
    row:Hide()
    row:ClearAllPoints()
    row.entry = nil
    row.doneBtn:SetScript("OnClick", nil)
    table.insert(rowPool, row)
end

-- ============================================================
-- UI: FRAME PRINCIPAL
-- ============================================================
local function CreateMainFrame()
    local f = CreateFrame("Frame", "RITMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, 200)
    f:SetPoint("CENTER", UIParent, "CENTER", 320, 80)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:Hide()

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.10, 0.97)
    f:SetBackdropBorderColor(0.35, 0.35, 0.55, 1)

    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        RunawayInviteToolsDB.framePoint = {
            point = point, relPoint = relPoint, x = x, y = y
        }
    end)

    -- ---- GLOW BORDER (fora do frame, pulsa enquanto há jogadores na fila) ----
    local glowFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
    glowFrame:SetPoint("TOPLEFT",     f, "TOPLEFT",     -5, 5)
    glowFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  5, -5)
    glowFrame:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
    glowFrame:SetBackdrop({
        edgeFile = "Interface\\Buttons\\UI-ActionButton-Border",
        edgeSize = 22,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    glowFrame:SetBackdropBorderColor(GLOW_R, GLOW_G, GLOW_B, 0)

    -- Animação de pulso com AnimationGroup (BOUNCE = vai e volta automaticamente)
    local glowAG = glowFrame:CreateAnimationGroup()
    glowAG:SetLooping("BOUNCE")
    local glowAlpha = glowAG:CreateAnimation("Alpha")
    glowAlpha:SetFromAlpha(0.1)
    glowAlpha:SetToAlpha(1.0)
    glowAlpha:SetDuration(1.0 / GLOW_SPEED)
    glowAlpha:SetSmoothing("IN_OUT")

    -- Controlamos a cor pelo SetBackdropBorderColor + alpha da animação age sobre o frame
    -- Mas como a animação Alpha age no frame inteiro, vamos usar OnUpdate para a cor dourada
    local glowActive = false
    local glowT = 0
    glowFrame:SetScript("OnUpdate", function(self, dt)
        if not glowActive then return end
        glowT = glowT + dt * GLOW_SPEED
        local p = (math.sin(glowT * math.pi) + 1) * 0.5  -- 0..1 suave
        glowFrame:SetBackdropBorderColor(
            GLOW_R,
            GLOW_G - p * 0.15,
            GLOW_B,
            0.15 + p * 0.85
        )
    end)

    f.StartGlow = function()
        glowActive = true
        glowT = 0
    end
    f.StopGlow = function()
        glowActive = false
        glowFrame:SetBackdropBorderColor(GLOW_R, GLOW_G, GLOW_B, 0)
    end

    -- ---- BARRA DE TÍTULO ----
    local titleBar = f:CreateTexture(nil, "ARTWORK")
    titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",  5, -5)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    titleBar:SetHeight(30)
    titleBar:SetColorTexture(0.08, 0.08, 0.22, 0.9)

    -- Linha vermelha decorativa no topo (identidade Runaway)
    local accentLine = f:CreateTexture(nil, "OVERLAY")
    accentLine:SetPoint("TOPLEFT",  f, "TOPLEFT",  5, -5)
    accentLine:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    accentLine:SetHeight(2)
    accentLine:SetColorTexture(0.75, 0.12, 0.12, 1)

    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("LEFT", f, "LEFT", 14, 0)
    titleText:SetPoint("TOP",  f, "TOP",  0, -19)
    titleText:SetText("|cffCC2020Runaway|r |cffffd700Fila de Summon|r")

    local countBadge = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    countBadge:SetPoint("RIGHT", f, "RIGHT", -36, 0)
    countBadge:SetPoint("TOP",   f, "TOP",    0, -19)
    countBadge:SetJustifyH("RIGHT")
    countBadge:SetTextColor(0.7, 0.7, 0.7)
    f.countBadge = countBadge

    -- Botão fechar
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Separador
    local sep = f:CreateTexture(nil, "OVERLAY")
    sep:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -36)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -36)
    sep:SetHeight(1)
    sep:SetColorTexture(0.5, 0.5, 0.7, 0.5)

    -- ---- SCROLL FRAME ----
    local scrollFrame = CreateFrame("ScrollFrame", "RITScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     f, "TOPLEFT",     6,  -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 38)
    f.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", "RITScrollChild", scrollFrame)
    scrollChild:SetSize(scrollFrame:GetWidth() or (FRAME_WIDTH - 32), 10)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild

    -- ---- BOTÃO LIMPAR FILA ----
    local clearBtn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    clearBtn:SetSize(130, 24)
    clearBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 8)
    clearBtn:SetText("Limpar Fila")
    clearBtn:SetScript("OnClick", ClearQueue)

    -- Texto "arraste para mover"
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 12)
    hint:SetTextColor(0.4, 0.4, 0.4)
    hint:SetText("arraste para mover")

    -- ---- TICK: atualiza tempo na fila a cada 1 segundo ----
    local tickAccum = 0
    f:SetScript("OnUpdate", function(self, dt)
        tickAccum = tickAccum + dt
        if tickAccum < 1.0 then return end
        tickAccum = 0
        for _, row in ipairs(activeRows) do
            if row.entry then
                row.timeText:SetText(FormatElapsed(GetTime() - row.entry.joinTime))
            end
        end
    end)

    -- ---- REFRESH: reconstrói a lista de linhas ----
    f.Refresh = function()
        -- Libera todas as linhas ativas de volta para o pool
        for _, row in ipairs(activeRows) do
            ReleaseRow(row)
        end
        wipe(activeRows)

        local count = #queue
        f.countBadge:SetText(count > 0 and (count .. " na fila") or "")

        if count == 0 then return end

        local contentW = (scrollFrame:GetWidth() or (FRAME_WIDTH - 32)) - 4
        local contentH = 0

        for i, entry in ipairs(queue) do
            local row = AcquireRow(scrollChild)
            row:SetWidth(contentW)
            row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -contentH)

            -- Fundo alternado
            if i % 2 == 0 then
                row.bg:SetColorTexture(0.10, 0.10, 0.20, 0.55)
            else
                row.bg:SetColorTexture(0.06, 0.06, 0.14, 0.35)
            end

            -- Ícone de classe
            local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[entry.class]
            if coords then
                row.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
                row.icon:SetTexCoord(unpack(coords))
            else
                row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                row.icon:SetTexCoord(0, 1, 0, 1)
            end

            -- Nome colorido pela classe
            local r, g, b = GetClassRGB(entry.class)
            row.nameText:SetText(string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, entry.name))

            -- Tempo
            row.timeText:SetText(FormatElapsed(GetTime() - entry.joinTime))

            -- Botão de summonado
            local entryName = entry.name
            row.doneBtn:SetScript("OnClick", function()
                DequeuePlayer(entryName)
            end)

            row.entry = entry
            table.insert(activeRows, row)
            contentH = contentH + ROW_HEIGHT
        end

        scrollChild:SetHeight(math.max(contentH, 10))
        scrollFrame:UpdateScrollChildRect()

        -- Ajusta altura do frame principal
        local visibleRows = math.min(count, MAX_VISIBLE_ROWS)
        local frameH = 40 + (visibleRows * ROW_HEIGHT) + 44
        f:SetHeight(frameH)
    end

    return f
end

-- ============================================================
-- UI: ALERTA ESPECIAL PARA WARLOCKS
-- ============================================================
local function CreateWarlockAlert()
    local f = CreateFrame("Frame", "RITWarlockAlert", UIParent, "BackdropTemplate")
    f:SetSize(420, 110)
    f:SetPoint("TOP", UIParent, "CENTER", 0, 160)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:Hide()

    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)

    -- Fundo roxo escuro (cor de Warlock)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.10, 0.02, 0.22, 0.97)
    f:SetBackdropBorderColor(0.55, 0.20, 0.90, 1)

    -- Overlay pulsante (brilho roxo interno)
    local pulseOverlay = f:CreateTexture(nil, "BACKGROUND")
    pulseOverlay:SetAllPoints()
    pulseOverlay:SetColorTexture(0.30, 0.05, 0.55, 0)

    -- ---- ÍCONE DO RITUAL OF SUMMONING ----
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(62, 62)
    icon:SetPoint("LEFT", f, "LEFT", 12, 0)
    -- GetSpellTexture(698) = Ritual of Summoning
    local spellTex = GetSpellTexture and GetSpellTexture(698)
    icon:SetTexture(spellTex or "Interface\\Icons\\Spell_Shadow_SummonSuccubus")

    -- Borda dourada ao redor do ícone
    local iconBorder = f:CreateTexture(nil, "OVERLAY")
    iconBorder:SetSize(70, 70)
    iconBorder:SetPoint("CENTER", icon, "CENTER")
    iconBorder:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    iconBorder:SetBlendMode("ADD")
    iconBorder:SetVertexColor(0.8, 0.3, 1.0)

    -- ---- TEXTOS ----
    local titleTxt = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleTxt:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -4)
    titleTxt:SetPoint("RIGHT",   f,    "RIGHT",   -12,  0)
    titleTxt:SetJustifyH("LEFT")
    titleTxt:SetTextColor(0.85, 0.45, 1.0)
    titleTxt:SetText("ABRA O PORTAL DE SUMMON!")
    f.titleTxt = titleTxt

    local subTxt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    subTxt:SetPoint("TOPLEFT", titleTxt, "BOTTOMLEFT", 0, -4)
    subTxt:SetPoint("RIGHT",   f,        "RIGHT",     -12, 0)
    subTxt:SetJustifyH("LEFT")
    subTxt:SetTextColor(0.75, 0.75, 0.75)
    subTxt:SetText("")
    f.subTxt = subTxt

    local spellHint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    spellHint:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 12, 4)
    spellHint:SetTextColor(0.60, 0.45, 0.80)
    spellHint:SetText("Use |cffffd700Ritual of Summoning|r (clique no ícone para conjurar)")

    -- ---- BOTÃO: CONJURAR PORTAL (clique no ícone) ----
    -- Filho de UIParent (não de f) para não contaminar f com o sistema seguro,
    -- o que bloquearia Show/Hide do frame de alerta por scripts de addon.
    local castBtn = CreateFrame("Button", "RITCastSummonBtn", UIParent, "SecureActionButtonTemplate")
    castBtn:SetSize(62, 62)
    castBtn:SetPoint("LEFT", f, "LEFT", 12, 0)  -- coincide com a posição do ícone
    castBtn:SetFrameStrata("DIALOG")
    castBtn:SetFrameLevel(f:GetFrameLevel() + 5)
    castBtn:SetAttribute("type", "spell")
    castBtn:SetAttribute("spell", "Ritual of Summoning")
    castBtn:Hide()

    castBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(698)
        GameTooltip:Show()
    end)
    castBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Sincroniza visibilidade com o frame de alerta
    f:HookScript("OnShow", function() castBtn:Show() end)
    f:HookScript("OnHide", function() castBtn:Hide() end)

    -- ---- BOTÃO DISPENSAR ----
    local dismissBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    dismissBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    dismissBtn:SetScript("OnClick", function() f:Hide() end)

    -- ---- ANIMAÇÃO: pulso roxo na borda e no overlay ----
    local pulseT = 0
    f:SetScript("OnUpdate", function(self, dt)
        pulseT = pulseT + dt * 2.5
        local p = (math.sin(pulseT * math.pi) + 1) * 0.5  -- 0..1
        -- Pulsa a borda
        f:SetBackdropBorderColor(
            0.40 + p * 0.35,
            0.10 + p * 0.15,
            0.70 + p * 0.30,
            0.7 + p * 0.3
        )
        -- Pulsa o overlay interno
        pulseOverlay:SetColorTexture(0.30, 0.05, 0.55, p * 0.18)
        -- Pulsa a borda do ícone
        iconBorder:SetVertexColor(0.6 + p * 0.4, 0.2 + p * 0.2, 0.8 + p * 0.2)
    end)

    -- ---- MÉTODO: Flash (exibir com info do jogador) ----
    f.Flash = function(playerName, class)
        local r, g, b = GetClassRGB(class or "UNKNOWN")
        local hex = string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
        local total = #queue
        if total == 1 then
            f.subTxt:SetText(hex .. playerName .. "|r quer ser summonado!")
        else
            f.subTxt:SetText(hex .. playerName .. "|r |cffaaaaaa+ " .. (total - 1) .. " outros na fila|r")
        end
        pulseT = 0
        f:Show()
        PlaySound(SOUNDKIT.ALARM_CLOCK_WARNING_3, "Master")
    end

    return f
end

-- ============================================================
-- HANDLER DE EVENTOS
-- ============================================================
local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("ADDON_LOADED")

EventFrame:SetScript("OnEvent", function(self, event, ...)
    -- ---- ADDON LOADED: inicialização ----
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end

        -- Inicializa SavedVariables
        RunawayInviteToolsDB = RunawayInviteToolsDB or {}

        -- Checa se o jogador é Warlock
        local _, englishClass = UnitClass("player")
        isWarlock = (englishClass == "WARLOCK")

        -- Cria os frames
        MainFrame   = CreateMainFrame()
        if isWarlock then
            WarlockAlert = CreateWarlockAlert()
        end

        -- Restaura posição salva do frame principal
        local fp = RunawayInviteToolsDB.framePoint
        if fp then
            MainFrame:ClearAllPoints()
            MainFrame:SetPoint(fp.point, UIParent, fp.relPoint, fp.x, fp.y)
        end

        -- Registra os eventos de chat e grupo
        self:RegisterEvent("CHAT_MSG_RAID")
        self:RegisterEvent("CHAT_MSG_RAID_LEADER")
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        if isWarlock then
            self:RegisterEvent("UNIT_SPELLCAST_START")
        end

        self:UnregisterEvent("ADDON_LOADED")

        print("|cffCC2020[Runaway Invite Tools]|r Carregado! " ..
              (isWarlock and "|cffb36fffWarlock detectado — alertas de portal ativos.|r" or
               "Digite |cffffd700/rit|r para ajuda."))

    -- ---- CHAT DE RAID: detecta "123" ----
    elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
        local msg, sender = ...
        if msg and strtrim(msg) == TRIGGER then
            local stripped = StripRealm(sender or "")
            if stripped ~= "" then
                EnqueuePlayer(sender)
            end
        end

    -- ---- ROSTER ATUALIZADO: resolve classes desconhecidas ----
    elseif event == "GROUP_ROSTER_UPDATE" then
        ResolveUnknownClasses()

    -- ---- WARLOCK CONJURA RITUAL OF SUMMONING: esconde alerta ----
    elseif event == "UNIT_SPELLCAST_START" then
        local unit, _, spellID = ...
        if unit == "player" and spellID == 698 then
            if WarlockAlert then WarlockAlert:Hide() end
        end
    end
end)

-- ============================================================
-- COMANDOS DE BARRA
-- ============================================================
SLASH_RIT1 = "/rit"
SLASH_RIT2 = "/runawayinvite"

SlashCmdList["RIT"] = function(msg)
    msg = strtrim(msg or ""):lower()

    if msg == "clear" or msg == "limpar" then
        ClearQueue()
        print("|cffCC2020[RIT]|r Fila limpa.")

    elseif msg == "test" then
        -- Adiciona entradas de teste (para debug fora de raid)
        EnqueuePlayer("Testador-Realm",  "MAGE")
        EnqueuePlayer("Guerreiro-Realm", "WARRIOR")
        EnqueuePlayer("Bruxo-Realm",     "WARLOCK")
        EnqueuePlayer("Padre-Realm",     "PRIEST")
        print("|cffCC2020[RIT]|r Entradas de teste adicionadas.")

    elseif msg == "help" or msg == "ajuda" then
        print("|cffCC2020=== Runaway Invite Tools ===|r")
        print("|cffffd700/rit|r — Mostra/esconde a janela da fila")
        print("|cffffd700/rit clear|r — Limpa toda a fila")
        print("|cffffd700/rit test|r — Adiciona jogadores de teste")
        print("|cffffd700/rit help|r — Este menu")
        print("Quando alguém escrever |cffffd700123|r no chat de raid, entra na fila.")
        if isWarlock then
            print("|cffb36fff(Warlock) Você receberá alertas para abrir o portal de summon.|r")
        end

    else
        -- Sem argumentos: toggle do frame
        if not MainFrame then return end
        if MainFrame:IsShown() then
            MainFrame:Hide()
        else
            if #queue > 0 then
                MainFrame:Show()
            else
                print("|cffCC2020[RIT]|r Nenhum jogador na fila de summon.")
            end
        end
    end
end
