--[[--
Início: onde cada palavra está e o caminho para revisar, editar e exportar.
Mesmo desenho da tela inicial do KR2Anki (kr2anki/screens/home.lua):
seção de status, linha de ações e barra de baixo "Revisar" / "Exportar".
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("vocab2deck/ui/screen")
local Kit = require("vocab2deck/ui/kit")
local _ = require("gettext")
local T = require("ffi/util").template

local Home = BaseScreen:extend{ name = "vocab2deck_home" }

function Home:setup()
    self:loadData()
end

function Home:loadData()
    -- antes de contar: leva para o Anki Viewer o que mudou nos cartões já no baralho
    self.host:autoUpdate()
    self.counts = self.host:getStore():counts()
    self.pending = self.host:pendingChanges()
end

function Home:onDataChanged()
    self:loadData()
end

function Home:browse(status)
    self.app:open("vocab2deck/screens/items", {
        filter = { statuses = { [status] = true } },
        title = Kit.SYMBOL[status] .. " " .. Kit.STATUS_NAME[status],
    })
end

function Home:statusSection(width)
    local c = self.counts
    local changed = #self.pending.changed
    local rows = {
        Kit.row{ width = width, symbol = Kit.SYMBOL.inbox, text = _("Inbox"), value = c.inbox,
                 sub = _("palavras do Vocabulary Builder para revisar"),
                 callback = function() self:browse("inbox") end },
        Kit.row{ width = width, symbol = Kit.SYMBOL.ready, text = _("Revisados"), value = c.ready,
                 sub = _("prontos para exportar"),
                 callback = function() self:browse("ready") end },
        Kit.row{ width = width, symbol = Kit.SYMBOL.deck, text = _("No baralho"), value = c.deck,
                 sub = changed > 0 and T(_("%1 com conteúdo novo para atualizar"), changed) or _("já no Anki Viewer"),
                 callback = function() self:browse("deck") end },
        Kit.row{ width = width, symbol = Kit.SYMBOL.discarded, text = _("Descartados"), value = c.discarded,
                 callback = function() self:browse("discarded") end },
    }
    return VerticalGroup:new{
        align = "left",
        Kit.sectionLabel(_("Status"), width),
        Kit.rows(width, rows),
        Kit.hline(width, Kit.dp(2)),
    }
end

-- Avisos curtos: o que a última leitura do Vocabulary Builder trouxe, erros, pendências.
function Home:notes()
    local out = {}
    local s = self.host.last_sync
    if s and s.error then
        out[#out + 1] = s.error
    elseif s and s.added > 0 then
        out[#out + 1] = T(_("○ %1 palavras novas vieram do Vocabulary Builder."), s.added)
    end
    local a = self.host.last_auto
    if a and a.updated > 0 then
        out[#out + 1] = T(_("✓ %1 cartões atualizados no Anki Viewer (progresso mantido)."), a.updated)
    end
    if a and a.moved > 0 then
        out[#out + 1] = T(_("✓ %1 cartões movidos para o baralho certo (progresso mantido)."), a.moved)
    end
    if self.pending.deleted > 0 then
        out[#out + 1] = T(_("%1 cartões apagados no Anki Viewer (Sincronizar os cria de novo)."), self.pending.deleted)
    end
    if s and s.filter_note then out[#out + 1] = s.filter_note end
    return out
end

function Home:build(w, h)
    local header = Kit.header{ width = w, title = _("Vocabulário → Flashcards"), on_back = function() self:onClose() end }
    local bottom = Kit.bottomBar(w, {
        { text = T(_("Revisar (%1)"), self.counts.inbox), enabled = self.counts.inbox > 0,
          callback = function() self.host:openReview() end },
        { text = T(_("Exportar (%1)"), self.counts.ready), primary = true,
          callback = function() self.host:openExport() end },
    })
    local avail = h - header:getSize().h - bottom:getSize().h
    local cw = w - 2 * Kit.PAD
    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, self:statusSection(cw))
    if #self.pending.changed > 0 then
        table.insert(body, Kit.vspan(Kit.dp(10)))
        table.insert(body, Kit.button{
            text = T(_("Atualizar %1 cartões alterados…"), #self.pending.changed), width = cw,
            callback = function() self.host:askChanges(self.pending.changed) end,
        })
    end
    for __, line in ipairs(self:notes()) do
        table.insert(body, Kit.vspan(Kit.dp(8)))
        table.insert(body, Kit.textbox(line, Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK, max_lines = 3 }))
    end
    table.insert(body, Kit.vspan(Kit.dp(12)))
    table.insert(body, Kit.buttonRow(cw + 2 * Kit.PAD, {
        { text = _("＋ Adicionar cartão"), weight = 1.6, callback = function()
            require("vocab2deck/capture").manual(self.host)
        end },
        { text = _("⌕ Buscar"), callback = function() self.host:askSearch(self.app) end },
        { text = _("Campos"), callback = function() self.app:open("vocab2deck/screens/model", {}) end },
        { text = _("Configurações"), weight = 1.4, callback = function() self.host:showSettings() end },
    }, { size = Kit.SIZE.small }))
    table.insert(body, Kit.vspan(Kit.dp(10)))
    table.insert(body, Kit.buttonRow(cw + 2 * Kit.PAD, {
        { text = _("Estudar no Anki Viewer"), callback = function() self.host:studyNow() end },
        { text = T(_("Sincronizar (%1)"), self.counts.deck), enabled = self.counts.deck > 0,
          callback = function() self.host:syncDeck() end },
    }, { size = Kit.SIZE.small }))
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Home
