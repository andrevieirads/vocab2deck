--[[--
Lista de palavras: linhas paginadas (palavra, definição curta, símbolo do
status), ordem Mais novas / A–Z, busca, e modo de seleção (toque longo) com
ações em massa. Adaptado de kr2anki/screens/items.lua (KR2Anki), sem o filtro
por idioma/data.
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("vocab2deck/ui/screen")
local Kit = require("vocab2deck/ui/kit")
local Parse = require("vocab2deck/lib/dictparse")
local Safe = require("vocab2deck/safe")
local _ = require("gettext")
local T = require("ffi/util").template

local Items = BaseScreen:extend{
    name = "vocab2deck_items",
    filter = nil, -- { statuses = {…}, search = "…" }
    title = nil,
}

function Items:setup()
    self.filter = self.filter or {}
    self.sort = self.host.settings:get("browse_sort") or "newest"
    self.page = 1
    self.selecting = false
    self.selected = {}
    self:loadData()
end

function Items:loadData()
    self.total = self.host:getStore():count(self.filter)
end

function Items:onDataChanged()
    self:loadData()
end

function Items:toggleSort()
    self.sort = self.sort == "az" and "newest" or "az"
    self.host.settings:set("browse_sort", self.sort)
    self.page = 1
    self:refresh()
end

-- Linha ------------------------------------------------------------------------------

function Items:rowWidget(r, width)
    local check_w = self.selecting and Kit.dp(44) or 0
    local sym_w = Kit.dp(36)
    local word_w = math.floor((width - check_w - sym_w) * 0.42)
    local mean_w = width - check_w - sym_w - word_w - Kit.dp(8)
    local word = VerticalGroup:new{ align = "left", Kit.text(r.word or "", Kit.uiBold(Kit.SIZE.body), { max_width = word_w }) }
    if r.book then
        table.insert(word, Kit.text(r.book, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = word_w }))
    end
    -- a definição escrita por você vale no lugar da do dicionário
    local meaning = (r.my_def and r.my_def ~= "") and r.my_def or r.definition
    local mean_text = (meaning and meaning ~= "") and Parse.shortMeaning(meaning, 60)
        or (r.looked_up == 1 and _("sem definição") or "—")
    local mean = Kit.textbox(mean_text, Kit.ui(Kit.SIZE.small), mean_w, { max_lines = 2,
        fgcolor = (meaning and meaning ~= "") and Kit.BLACK or Kit.GREY_DARK })
    local h = self.row_h
    local row = HorizontalGroup:new{ align = "center" }
    if self.selecting then
        table.insert(row, Kit.box(check_w, h, Kit.checkbox(self.selected[r.vkey] == true), "left"))
    end
    table.insert(row, Kit.box(word_w, h, word, "left"))
    table.insert(row, Kit.hspan(Kit.dp(8)))
    table.insert(row, Kit.box(mean_w, h, mean, "left"))
    table.insert(row, Kit.box(sym_w, h, Kit.text(Kit.SYMBOL[r.status] or "?", Kit.ui(Kit.SIZE.title), {}), "right"))
    local key = r.vkey
    return Kit.tap(row, function()
        if self.selecting then
            self.selected[key] = not self.selected[key] or nil
            self:refresh()
        else
            self.app:open("vocab2deck/screens/review", { keys = { key }, single = true })
        end
    end, function()
        if not self.selecting then
            self.selecting = true
            self.selected = { [key] = true }
            self:refresh()
        end
    end)
end

-- Seleção ------------------------------------------------------------------------------

function Items:selectedKeys()
    local keys = {}
    for k in pairs(self.selected) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function Items:selectedCount()
    local n = 0
    for __ in pairs(self.selected) do n = n + 1 end
    return n
end

function Items:endSelection()
    self.selecting = false
    self.selected = {}
    self:loadData()
    self:refresh()
end

function Items:selectAll()
    for __, k in ipairs(self.host:getStore():keys(self.filter, self.sort)) do self.selected[k] = true end
    self:refresh()
end

function Items:bulkStatus(status)
    local keys = self:selectedKeys()
    if #keys == 0 then return end
    Safe.run(_("mudar status"), function()
        self.host:getStore():setStatus(keys, status)
    end)
    local InfoMessage = require("ui/widget/infomessage")
    local text = T(_("%1 marcados como %2."), #keys, Kit.STATUS_NAME[status])
    if status == "discarded" and self.filter.statuses and self.filter.statuses.deck then
        text = text .. "\n\n" .. _("Os cartões continuam no Anki Viewer; apague-os lá se quiser.")
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
    self:endSelection()
end

-- Montagem -------------------------------------------------------------------------------

function Items:subheader(w)
    local h = Kit.TAP
    local left_text = T(_("%1 palavras"), self.total)
    local right
    if self.selecting then
        right = Kit.link(T(_("Selecionar todas (%1)"), self.total), function() self:selectAll() end, { size = Kit.SIZE.small })
    else
        right = Kit.textButton(self.sort == "az" and _("A–Z ⇅") or _("Mais novas ⇅"), function() self:toggleSort() end,
            { size = Kit.SIZE.small })
    end
    return Kit.pad(Kit.spread(w - 2 * Kit.PAD, h, Kit.text(left_text, Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK,
        max_width = w - 2 * Kit.PAD - right:getSize().w - Kit.dp(8) }), right), Kit.PAD, 0)
end

function Items:bottom(w)
    if self.selecting then
        local any = self:selectedCount() > 0
        if (self.filter.statuses or {}).deck then
            -- já no Anki Viewer: voltar ao Inbox/Revisado não tiraria o cartão de lá
            return Kit.bottomBar(w, {
                { text = _("✕"), weight = 0.5, callback = function() self:endSelection() end },
                { text = _("× Descartar"), enabled = any, callback = function() self:bulkStatus("discarded") end },
            }, { size = Kit.SIZE.small })
        end
        return Kit.bottomBar(w, {
            { text = _("✕"), weight = 0.5, callback = function() self:endSelection() end },
            { text = _("× Descartar"), enabled = any, callback = function() self:bulkStatus("discarded") end },
            { text = _("○ Inbox"), enabled = any, callback = function() self:bulkStatus("inbox") end },
            { text = _("● Revisado"), weight = 1.4, primary = true, enabled = any, callback = function() self:bulkStatus("ready") end },
        }, { size = Kit.SIZE.small })
    end
    local st = self.filter.statuses or {}
    if st.inbox and self.total > 0 then
        return Kit.bottomBar(w, {
            { text = _("Fechar"), callback = function() self:onClose() end },
            { text = T(_("Revisar (%1)"), self.total), primary = true, callback = function()
                self.host:openReview(self.filter)
            end },
        })
    end
    if st.ready and self.total > 0 then
        return Kit.bottomBar(w, {
            { text = _("Fechar"), callback = function() self:onClose() end },
            { text = T(_("Exportar (%1)"), self.total), primary = true, callback = function() self.host:openExport() end },
        })
    end
    return nil
end

function Items:build(w, h)
    local header
    if self.selecting then
        header = Kit.header{ width = w, title = T(_("%1 selecionadas"), self:selectedCount()), back_symbol = "✕",
                             on_back = function() self:endSelection() end }
    else
        header = Kit.header{ width = w, title = self.title or _("Palavras"), on_back = function() self:onClose() end,
                             title_size = Kit.SIZE.body + 2,
                             right = Kit.textButton("⌕", function() self.host:askSearch(self.app, self.filter) end,
                                 { size = Kit.SIZE.title }) }
    end
    local sub = self:subheader(w)
    local bottom = self:bottom(w)
    local fixed = header:getSize().h + sub:getSize().h + Kit.dp(1)
    if bottom then fixed = fixed + bottom:getSize().h end

    if self.total == 0 then
        local body = Kit.box(w, h - fixed, Kit.emptyState(w, "○", _("Nada aqui."),
            _("As palavras que você consulta no dicionário durante a leitura chegam pelo Vocabulary Builder.")))
        return VerticalGroup:new{ align = "left", header, sub, Kit.hline(w, Kit.dp(1)), body, bottom }
    end

    local legend = Kit.box(w, Kit.dp(30), Kit.text(_("○ Inbox · ● Revisado · ✓ No baralho · × Descartado · toque longo seleciona"),
        Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = w - 2 * Kit.PAD }))
    fixed = fixed + legend:getSize().h + Kit.PAGER_H
    local avail = h - fixed
    local cw = w - 2 * Kit.PAD
    -- linhas de altura fixa (cabem duas linhas de definição), para páginas exatas
    self.row_h = math.max(Kit.TAP,
        2 * Kit.lineHeight(Kit.ui(Kit.SIZE.small)) + Kit.dp(14),
        Kit.text("Ag", Kit.uiBold(Kit.SIZE.body)):getSize().h + Kit.text("Ag", Kit.ui(Kit.SIZE.tiny)):getSize().h + Kit.dp(12))
    local per_page = math.max(1, math.floor(avail / (self.row_h + Kit.dp(1))))
    self.pages = math.max(1, math.ceil(self.total / per_page))
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local list = VerticalGroup:new{ align = "left" }
    for __, r in ipairs(self.host:getStore():query(self.filter, self.sort, (self.page - 1) * per_page, per_page)) do
        table.insert(list, self:rowWidget(r, cw))
        table.insert(list, Kit.hline(cw, Kit.dp(1), Kit.GREY_LIGHT))
    end
    local parts = VerticalGroup:new{
        align = "left", header, sub, Kit.hline(w, Kit.dp(1)),
        Kit.box(w, avail, Kit.pad(list, Kit.PAD, 0), "top"),
        legend,
        self:pagerWidget(w),
    }
    if bottom then table.insert(parts, bottom) end
    return parts
end

return Items
