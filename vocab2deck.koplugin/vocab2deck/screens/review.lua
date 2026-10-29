--[[--
Revisão: uma palavra por tela, Inbox → Revisado num toque quando o primeiro
sentido está certo. Também é a tela de um item só, aberta da lista
(single = true).

Mesmo fluxo de kr2anki/screens/review.lua (KR2Anki):
* palavra (✎ para buscar outra forma ou editar o texto)
* frase de contexto (toque: encurtar, mais contexto, original, editar)
* "Escolha o sentido": os sentidos do dicionário em botões de rádio
* "Campos do cartão": abre o editor (como o "Adicionar" do Anki)
Navegação: página seguinte / deslizar para a esquerda = Pular; página
anterior / deslizar para a direita = item anterior, com a decisão ainda
editável.
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local B = require("vocab2deck/card_builder")
local BaseScreen = require("vocab2deck/ui/screen")
local Kit = require("vocab2deck/ui/kit")
local Safe = require("vocab2deck/safe")
local Tpl = require("vocab2deck/template")
local U = require("vocab2deck/lib/u8")
local _ = require("gettext")
local T = require("ffi/util").template

local Review = BaseScreen:extend{
    name = "vocab2deck_review",
    keys = nil,
    single = false,
    index = 1,
}

local MAX_SENSES = 6

function Review:setup()
    self.keys = self.keys or {}
    self.index = self.index or 1
    self.decisions = {} -- vkey -> status escolhido
    self.skipped = {}
    self:load()
end

function Review:store() return self.host:getStore() end

function Review:load()
    self.item = nil
    while self.index <= #self.keys do
        local it = self:store():get(self.keys[self.index])
        if it then
            -- a definição é buscada só quando a palavra aparece (uma busca por tela)
            self.item = self.host:ensureLookup(it)
            break
        end
        table.remove(self.keys, self.index)
    end
end

function Review:onDataChanged()
    self:load()
end

function Review:reload()
    self:load()
    self:refresh()
end

-- Depois de mudar algo do item: atualiza o cartão se ele já está no baralho.
function Review:changed()
    self.host:pushItemToDeck(self.item.vkey)
    self:reload()
end

local function fieldBySource(model, source)
    for __, f in ipairs(model) do
        if f.source == source then return f end
    end
end

-- Decisões ----------------------------------------------------------------------------

function Review:counts()
    local c = { ready = 0, discarded = 0, inbox = 0, skipped = 0 }
    for __, k in ipairs(self.keys) do
        local d = self.decisions[k]
        if d then c[d] = (c[d] or 0) + 1
        elseif self.skipped[k] then c.skipped = c.skipped + 1 end
    end
    return c
end

function Review:decide(status)
    local it = self.item
    if not it then return end
    Safe.run(_("mudar status"), function() self:store():setStatus({ it.vkey }, status) end)
    self.decisions[it.vkey] = status
    self.skipped[it.vkey] = nil
    if self.single then
        self:onClose()
        return
    end
    self:advance()
end

function Review:advance()
    self.index = self.index + 1
    self:load()
    self:refresh(true)
end

function Review:onNextPage()
    if self.single then return true end
    if self.index > #self.keys then return true end
    local it = self.item
    if it and not self.decisions[it.vkey] then self.skipped[it.vkey] = true end
    self:advance()
    return true
end

function Review:onPrevPage()
    if self.single then return true end
    if self.index > 1 then
        self.index = self.index - 1
        self:load()
        self:refresh(true)
    end
    return true
end

-- Diálogos ---------------------------------------------------------------------------------

local function dialog(title, rows)
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local buttons = {}
    for __, r in ipairs(rows) do
        buttons[#buttons + 1] = { {
            text = r.text, enabled = r.enabled,
            callback = function() UIManager:close(d); if r.callback then r.callback() end end,
        } }
    end
    buttons[#buttons + 1] = { { text = _("Cancelar"), callback = function() UIManager:close(d) end } }
    d = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(d)
end

function Review:input(title, value, on_ok, multiline)
    require("vocab2deck/ui").editText(title, value, function(v) Safe.run(_("salvar"), on_ok, v) end,
        { multiline = multiline, allow_empty = true })
end

-- ✎ da palavra: buscar outra forma (forma base) ou editar o texto no cartão.
function Review:wordActions()
    local it = self.item
    local model = self.host:modelFor(self.item)
    local wf = fieldBySource(model, "word")
    dialog(it.word, {
        { text = _("Buscar outra forma no dicionário"), callback = function()
            self:input(_("Forma a buscar (ex.: a forma base)"), it.word, function(word)
                word = U.trim(word or "")
                if word == "" then return end
                local res = self.host:lookupWord(word)
                if not res then
                    Safe.message(T(_("Nenhum dicionário tem \"%1\"."), word), 3)
                    return
                end
                self:store():setWord(it.vkey, word)
                self:store():setLookup(it.vkey, res)
                self:changed()
            end)
        end },
        { text = _("Editar o texto da palavra no cartão"), enabled = wf ~= nil, callback = function()
            local current = it.overrides[wf.id] or it.word
            self:input(wf.name, current, function(v)
                self:store():setOverride(it.vkey, wf.id, v)
                self:changed()
            end)
        end },
    })
end

-- Toque na frase: encurtar, mais contexto, original, editar.
function Review:sentenceActions()
    local it = self.item
    local sf = fieldBySource(self.host:modelFor(self.item), "sentence")
    if not sf then return end
    local function set(opts)
        return function()
            local s = B.contextSentence(it, opts)
            if s then
                self:store():setOverride(it.vkey, sf.id, "“" .. s.text .. "”")
                self:changed()
            end
        end
    end
    local has_ctx = it.prev ~= nil or it.next ~= nil
    dialog(_("Frase do cartão"), {
        { text = _("Encurtar"), enabled = has_ctx, callback = set({ max_words = 20, max_cjk = 40 }) },
        { text = _("Mostrar mais contexto"), enabled = has_ctx, callback = set({ extra = 1, max_words = 80, max_cjk = 160 }) },
        { text = _("Frase original"), enabled = it.overrides[sf.id] ~= nil, callback = function()
            self:store():setOverride(it.vkey, sf.id, nil)
            self:changed()
        end },
        { text = _("Editar o texto"), callback = function()
            local fields = Tpl.fields(it, self.host:modelFor(self.item), self.host.settings:cardOptions())
            local value = ""
            for __, f in ipairs(fields) do if f.id == sf.id then value = f.value end end
            self:input(sf.name, value, function(v)
                self:store():setOverride(it.vkey, sf.id, v)
                self:changed()
            end, true)
        end },
    })
end

function Review:chooseSense(i)
    local it = self.item
    local df = fieldBySource(self.host:modelFor(self.item), "definition")
    if not df then return end
    Safe.run(_("escolher sentido"), function()
        self:store():setOverride(it.vkey, df.id, i and it.senses[i] or nil)
    end)
    self:changed()
end

function Review:showFullEntry()
    local TextViewer = require("ui/widget/textviewer")
    local it = self.item
    UIManager:show(TextViewer:new{
        title = T("%1 · %2", it.word, it.dict or ""),
        text = table.concat(it.senses, "\n\n"),
    })
end

-- Blocos --------------------------------------------------------------------------------------

function Review:headerWidget(w)
    local it = self.item
    local title
    if self.single then
        title = _("Editar")
    else
        title = T(_("Revisar %1 / %2"), self.index, #self.keys)
        local d = it and self.decisions[it.vkey]
        if d then title = title .. "  " .. (Kit.SYMBOL[d] or "") end
    end
    local right
    if it then
        right = Kit.text(Kit.SYMBOL[it.status] .. " " .. Kit.STATUS_NAME[it.status], Kit.ui(Kit.SIZE.small),
            { fgcolor = Kit.GREY_DARK })
    end
    return Kit.header{ width = w, title = title, on_back = function() self:onClose() end, right = right }
end

function Review:wordBlock(cw)
    local it = self.item
    local edit = Kit.tap(Kit.bordered(Kit.box(Kit.TAP - 2 * Kit.dp(13.5), Kit.TAP - 2 * Kit.dp(13.5),
        Kit.text("✎", Kit.ui(Kit.SIZE.title), {})), { padding = Kit.dp(12) }), function() self:wordActions() end)
    local avail = cw - edit:getSize().w - Kit.dp(12)
    local line = HorizontalGroup:new{ align = "center",
        Kit.text(it.word, Kit.uiBold(Kit.SIZE.word), { max_width = avail }), Kit.hspan(Kit.dp(12)), edit }
    local g = VerticalGroup:new{ align = "left", line }
    if it.dict then
        table.insert(g, Kit.text(it.dict, Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK, max_width = cw }))
    end
    return g
end

function Review:sentenceBlock(cw, max_lines)
    local it = self.item
    local sf = fieldBySource(self.host:modelFor(self.item), "sentence")
    local inner_w = cw - 2 * (Kit.dp(1.5) + Kit.dp(14))
    local text, edited
    if sf and it.overrides[sf.id] then
        text, edited = it.overrides[sf.id], true
    else
        local s = B.contextSentence(it)
        if s then
            text = Kit.boldRange(s.text, s.hl_start, s.hl_end)
        end
    end
    local missing = text == nil or text == ""
    if missing then text = _("Sem frase: o Vocabulary Builder não guardou contexto para esta palavra.") end
    local tb = Kit.textbox(text, Kit.serif(Kit.SIZE.sentence), inner_w, { max_lines = max_lines, line_height = 0.45,
        fgcolor = missing and Kit.GREY_DARK or Kit.BLACK })
    local box = Kit.tap(Kit.bordered(Kit.box(inner_w, tb:getSize().h, tb, "left"), { padding = Kit.dp(14) }),
        function() self:sentenceActions() end)
    local meta = {}
    if it.book then meta[#meta + 1] = it.book end
    if edited then meta[#meta + 1] = _("frase editada") end
    if sf and sf.side == "none" then meta[#meta + 1] = _("não vai para o cartão") end
    return VerticalGroup:new{
        align = "left",
        box,
        Kit.vspan(Kit.dp(4)),
        Kit.text(#meta > 0 and table.concat(meta, " · ") or " ", Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = cw }),
    }
end

-- Escrever a definição à mão (vale no lugar da do dicionário).
function Review:editDefinition()
    local it = self.item
    local df = fieldBySource(self.host:modelFor(self.item), "definition")
    if not df then return end
    local current = it.overrides[df.id] or Tpl.defaultDefinition(it, self.host.settings:cardOptions().max_senses)
    self:input(df.name, current, function(v)
        self:store():setOverride(it.vkey, df.id, v)
        self:changed()
    end, true)
end

-- Sentidos: a definição escrita por você (se houver), "Padrão", e os sentidos do
-- dicionário, quantos couberem (até MAX_SENSES); e "Ver a entrada inteira".
function Review:sensesBlock(cw, avail)
    local it = self.item
    local df = fieldBySource(self.host:modelFor(self.item), "definition")
    local g = VerticalGroup:new{ align = "left" }
    local label = Kit.sectionLabel(_("Escolha o sentido"), cw,
        it.dict and Kit.text(T(_("%1 sentidos"), #it.senses), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK }) or nil)
    table.insert(g, label)
    if not df then
        table.insert(g, Kit.textbox(_("O campo Definição foi removido do modelo (Campos ▸ + Campo traz de volta)."),
            Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }))
        return g
    end
    local chosen = df and it.overrides[df.id]
    local is_sense = false
    for __, sense in ipairs(it.senses) do if sense == chosen then is_sense = true end end
    local own = chosen ~= nil and U.trim(chosen) ~= "" and not is_sense
    local used = label:getSize().h
    local foot_h = Kit.TAP + Kit.dp(4)
    local rows = {}
    if own then
        local own_row = Kit.markRow{ width = cw, mark = Kit.radio(true), text = T(_("Sua definição: %1"), chosen),
            bold = true, max_lines = 2, callback = function() self:editDefinition() end }
        rows[#rows + 1] = own_row
        used = used + own_row:getSize().h + Kit.dp(1)
    end
    if #it.senses == 0 then
        if not own then
            local text = it.definition and it.definition ~= "" and it.definition
                or _("Nenhuma definição encontrada nos dicionários.")
            table.insert(g, Kit.textbox(text, Kit.ui(Kit.SIZE.body), cw, { fgcolor = Kit.GREY_DARK, max_lines = 3 }))
        else
            table.insert(g, Kit.rows(cw, rows))
        end
        table.insert(g, Kit.vspan(Kit.dp(4)))
        table.insert(g, HorizontalGroup:new{ align = "center",
            Kit.link(own and _("Editar a definição") or _("Escrever a definição"), function() self:editDefinition() end),
            Kit.hspan(Kit.dp(24)),
            Kit.link(_("Buscar outra forma"), function() self:wordActions() end) })
        return g
    end
    local n_default = math.min(#it.senses, self.host.settings:cardOptions().max_senses)
    if #it.senses > 1 then
        local default_row = Kit.markRow{ width = cw, mark = Kit.radio(chosen == nil),
            text = T(_("Padrão: os %1 primeiros sentidos"), n_default), bold = chosen == nil, max_lines = 1,
            callback = function() self:chooseSense(nil) end }
        rows[#rows + 1] = default_row
        used = used + default_row:getSize().h + Kit.dp(1)
    end
    for i, sense in ipairs(it.senses) do
        if i > MAX_SENSES then break end
        local checked = chosen == sense or (#it.senses == 1 and chosen == nil)
        local row = Kit.markRow{ width = cw, mark = Kit.radio(checked), text = i .. ". " .. sense, bold = checked,
            max_lines = 2, callback = function() self:chooseSense(i) end }
        local rh = row:getSize().h + Kit.dp(1)
        if used + rh + foot_h > avail and #rows >= 1 then break end
        rows[#rows + 1] = row
        used = used + rh
    end
    table.insert(g, Kit.rows(cw, rows))
    table.insert(g, Kit.vspan(Kit.dp(4)))
    table.insert(g, HorizontalGroup:new{ align = "center",
        Kit.link(_("Ver a entrada inteira"), function() self:showFullEntry() end),
        Kit.hspan(Kit.dp(24)),
        Kit.link(own and _("Editar a definição") or _("Escrever a minha"), function() self:editDefinition() end) })
    return g
end

function Review:fieldsButton(cw)
    local it = self.item
    local n = #self.host:modelFor(self.item) + #it.extras
    return Kit.button{
        text = T(_("✎ Campos do cartão (%1) · pré-visualizar"), n), width = cw,
        callback = function() self.app:open("vocab2deck/screens/editor", { vkey = it.vkey }) end,
    }
end

function Review:bottomButtons()
    local it = self.item
    if not self.single then
        return {
            { text = _("Pular"), callback = function() self:onNextPage() end },
            { text = _("× Descartar"), callback = function() self:decide("discarded") end },
            { text = _("✓ Revisado"), primary = true, weight = 1.3, callback = function() self:decide("ready") end },
        }
    end
    local b = { { text = _("Fechar"), callback = function() self:onClose() end } }
    local st = it.status
    if st == "inbox" then
        b[#b + 1] = { text = _("× Descartar"), callback = function() self:decide("discarded") end }
        b[#b + 1] = { text = _("✓ Revisado"), primary = true, callback = function() self:decide("ready") end }
    elseif st == "ready" then
        b[#b + 1] = { text = _("○ Inbox"), callback = function() self:decide("inbox") end }
        b[#b + 1] = { text = _("× Descartar"), callback = function() self:decide("discarded") end }
    elseif st == "deck" then
        b[#b + 1] = { text = _("○ Inbox"), callback = function() self:decide("inbox") end }
        b[#b + 1] = { text = _("● Revisado"), callback = function() self:decide("ready") end }
        b[#b + 1] = { text = _("× Descartar"), callback = function() self:decide("discarded") end }
    elseif st == "discarded" then
        b[#b + 1] = { text = _("○ Voltar ao Inbox"), primary = true, callback = function() self:decide("inbox") end }
    end
    return b
end

-- Fim da sessão --------------------------------------------------------------------------------

function Review:summary(w, h)
    local c = self:counts()
    local header = Kit.header{ width = w, title = _("Revisão concluída"), on_back = function() self:onClose() end }
    local line = T(_("%1 Revisados · %2 Descartados · %3 pulados"), c.ready, c.discarded, c.skipped)
    local ready_total = self:store():counts().ready
    local bottom = Kit.bottomBar(w, {
        { text = _("Pronto"), callback = function() self:onClose() end },
        { text = T(_("Exportar (%1)"), ready_total), primary = true, enabled = ready_total > 0, callback = function()
            self:onClose()
            self.host:openExport()
        end },
    })
    local body = VerticalGroup:new{ align = "center",
        Kit.text("✓", Kit.uiBold(Kit.SIZE.big), {}),
        Kit.vspan(Kit.dp(12)),
        Kit.textbox(line, Kit.uiBold(Kit.SIZE.title), w - 2 * Kit.PAD, { alignment = "center" }),
        Kit.vspan(Kit.dp(16)),
        Kit.textbox(_("Deslize para a direita para voltar e mudar uma decisão."), Kit.ui(Kit.SIZE.small), w - 2 * Kit.PAD,
            { alignment = "center", fgcolor = Kit.GREY_DARK }),
    }
    return VerticalGroup:new{ align = "left", header,
        Kit.box(w, h - header:getSize().h - bottom:getSize().h, body), bottom }
end

function Review:build(w, h)
    if not self.item then
        if self.single then
            local header = Kit.header{ width = w, title = _("Editar"), on_back = function() self:onClose() end }
            return VerticalGroup:new{ align = "left", header,
                Kit.box(w, h - header:getSize().h, Kit.text(_("Esta palavra não existe mais."), Kit.ui(), {})) }
        end
        return self:summary(w, h)
    end
    local header = self:headerWidget(w)
    local bottom = Kit.bottomBar(w, self:bottomButtons(), { size = Kit.SIZE.small })
    local cw = w - 2 * Kit.PAD
    local avail = h - header:getSize().h - bottom:getSize().h
    local gap = Kit.dp(14)
    local landscape = w > h
    local body
    if landscape then
        local col = math.floor((cw - Kit.PAD) / 2)
        local left = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)), self:wordBlock(col), Kit.vspan(gap),
            self:sentenceBlock(col, 5), Kit.vspan(gap), self:fieldsButton(col) }
        local right = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)), self:sensesBlock(col, avail - Kit.dp(8)) }
        body = HorizontalGroup:new{ align = "top", left, Kit.hspan(Kit.PAD), right }
    else
        local top = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(10)), self:wordBlock(cw), Kit.vspan(gap),
            self:sentenceBlock(cw, 4), Kit.vspan(gap) }
        local fields = self:fieldsButton(cw)
        local senses_h = avail - top:getSize().h - fields:getSize().h - gap
        body = VerticalGroup:new{ align = "left", top, self:sensesBlock(cw, senses_h), Kit.vspan(gap), fields }
    end
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Review
