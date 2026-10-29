--[[--
Exportação para o Anki Viewer: pré-checagem → gravação → resultado.
Mesmas três fases de kr2anki/screens/export.lua (KR2Anki), mas o destino é
o banco do Anki Viewer (deck_writer), sem rede.

Só os ● Revisados vão (e, se marcado, os ○ do Inbox como estão). Um item só
passa a ✓ No baralho depois que o cartão foi gravado.
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("vocab2deck/ui/screen")
local Kit = require("vocab2deck/ui/kit")
local _ = require("gettext")
local T = require("ffi/util").template

local Export = BaseScreen:extend{
    name = "vocab2deck_export",
    autostart = false,
}

function Export:setup()
    self.include_inbox = false
    self.result = nil
    self:loadCounts()
    if self.autostart then
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.2, function() self:start() end)
    end
end

function Export:loadCounts()
    self.counts = self.host:getStore():counts()
    self.pending = self.host:pendingChanges()
end

function Export:onDataChanged()
    if not self.result then self:loadCounts() end
end

function Export:total()
    return self.counts.ready + (self.include_inbox and self.counts.inbox or 0) + self.pending.new_sides
end

function Export:start()
    self.host:runExport({ include_inbox = self.include_inbox }, function(result)
        self.result = result
        self:loadCounts()
        self:refresh(true)
    end)
end

function Export:bigCount(cw, n, label)
    return VerticalGroup:new{ align = "left",
        Kit.text(tostring(n), Kit.uiBold(Kit.SIZE.big), {}),
        Kit.text(label, Kit.ui(Kit.SIZE.body), { max_width = cw }),
    }
end

function Export:precheck(cw)
    local opts = self.host.settings:cardOptions()
    local g = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(16)) }
    table.insert(g, self:bigCount(cw, self.counts.ready, _("● revisados prontos para exportar")))
    table.insert(g, Kit.vspan(Kit.dp(10)))
    table.insert(g, Kit.text(opts.subdeck_per_book and _("Baralho: o título de cada livro") or T(_("Baralho: %1"), opts.deck_name),
        Kit.ui(Kit.SIZE.small), { max_width = cw }))
    if self.pending.new_sides > 0 then
        table.insert(g, Kit.text(T(_("+ %1 cartões inversos de palavras já no baralho"), self.pending.new_sides),
            Kit.ui(Kit.SIZE.small), { max_width = cw }))
    end
    if self.counts.inbox > 0 then
        table.insert(g, Kit.vspan(Kit.dp(12)))
        table.insert(g, Kit.markRow{ width = cw, mark = Kit.checkbox(self.include_inbox),
            text = T(_("Também enviar os %1 do Inbox como estão"), self.counts.inbox), max_lines = 2,
            callback = function() self.include_inbox = not self.include_inbox; self:refresh() end })
    end
    if #self.pending.changed > 0 then
        table.insert(g, Kit.vspan(Kit.dp(12)))
        table.insert(g, Kit.textbox(T(_("%1 cartões já no baralho têm conteúdo novo; atualize pelo Início."),
            #self.pending.changed), Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }))
    end
    table.insert(g, Kit.vspan(Kit.dp(16)))
    table.insert(g, Kit.textbox(_("Antes de gravar, o banco do Anki Viewer é copiado para koreader/vocab2deck/backups. Cartões já no baralho não são duplicados nem perdem o progresso."),
        Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }))
    return g
end

function Export:resultBody(cw)
    local r = self.result
    local g = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(16)) }
    if r.error then
        table.insert(g, Kit.text(_("Nada foi gravado"), Kit.uiBold(Kit.SIZE.title), { max_width = cw }))
        table.insert(g, Kit.vspan(Kit.dp(10)))
        table.insert(g, Kit.textbox(r.error, Kit.ui(Kit.SIZE.body), cw))
        return g
    end
    local title = r.aborted and _("Interrompido") or _("✓ Concluído")
    table.insert(g, Kit.text(title, Kit.uiBold(Kit.SIZE.title), {}))
    table.insert(g, Kit.vspan(Kit.dp(8)))
    table.insert(g, Kit.text(T(_("%1 cartões novos adicionados."), r.added), Kit.ui(Kit.SIZE.title), { max_width = cw }))
    table.insert(g, Kit.vspan(Kit.dp(8)))
    local rows = {
        Kit.row{ width = cw, symbol = "✓", text = _("Palavras que foram para o baralho"), value = r.items },
    }
    if r.skipped_nodef > 0 then
        rows[#rows + 1] = Kit.row{ width = cw, symbol = "—", text = _("Sem definição (ficaram onde estavam)"), value = r.skipped_nodef }
    end
    if r.lookup_errors > 0 then
        rows[#rows + 1] = Kit.row{ width = cw, symbol = "×", text = _("Busca no dicionário falhou"), value = r.lookup_errors }
    end
    if r.remaining > 0 then
        rows[#rows + 1] = Kit.row{ width = cw, symbol = "○", text = _("Ficaram para a próxima vez"), value = r.remaining }
    end
    table.insert(g, Kit.rows(cw, rows))
    if r.backup then
        table.insert(g, Kit.vspan(Kit.dp(12)))
        table.insert(g, Kit.textbox(T(_("Backup: %1"), r.backup:match("[^/]+$") or r.backup), Kit.ui(Kit.SIZE.tiny), cw,
            { fgcolor = Kit.GREY_DARK }))
    end
    if r.apkg_error then
        table.insert(g, Kit.vspan(Kit.dp(8)))
        table.insert(g, Kit.textbox(T(_("O pacote Vocab2Deck.apkg não foi gravado: %1"), r.apkg_error),
            Kit.ui(Kit.SIZE.tiny), cw, { fgcolor = Kit.GREY_DARK }))
    end
    if r.skipped_nodef > 0 then
        table.insert(g, Kit.vspan(Kit.dp(8)))
        table.insert(g, Kit.textbox(_("Para exportar palavras sem definição, escreva a definição em \"✎ Campos do cartão\" ou ative Configurações ▸ Palavra sem definição ▸ Criar cartão."),
            Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }))
    end
    return g
end

function Export:build(w, h)
    local header = Kit.header{ width = w, title = _("Exportar para o Anki Viewer"), on_back = function() self:onClose() end }
    local bottom
    if self.result then
        bottom = Kit.bottomBar(w, {
            { text = _("Fechar"), callback = function() self:onClose() end },
            { text = _("Estudar no Anki Viewer"), primary = true, enabled = not self.result.error, callback = function()
                self:onClose()
                self.host:studyNow()
            end },
        })
    else
        local n = self:total()
        bottom = Kit.bottomBar(w, {
            { text = _("Cancelar"), callback = function() self:onClose() end },
            { text = T(_("Exportar (%1)"), n), primary = true, enabled = n > 0, callback = function() self:start() end },
        })
    end
    local cw = w - 2 * Kit.PAD
    local body = self.result and self:resultBody(cw) or self:precheck(cw)
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, h - header:getSize().h - bottom:getSize().h, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Export
