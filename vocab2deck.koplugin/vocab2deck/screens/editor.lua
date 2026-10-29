--[[--
Editor de campos de um cartão, no estilo da janela "Adicionar" do Anki: os
campos um embaixo do outro, cada um com o nome, o lado (frente/verso) e o
texto. Tocar no texto edita; "⋯" abre as opções do campo; "+ Campo" cria um
campo só deste cartão ou no modelo (todos os cartões); "− Campo" tira um
campo só deste cartão ou do modelo.

As caixas de campo usam o mesmo desenho do Kit.field do KR2Anki.
Toda mudança é gravada na hora; se a palavra já está no baralho, o cartão
do Anki Viewer recebe o texto novo (o progresso de revisão fica).

Modo "Novo cartão" (is_new, aberto pelo botão "＋ Adicionar ao baralho" no
livro): Cancelar descarta o item; Salvar no Inbox o guarda para o fluxo normal.
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("vocab2deck/ui/screen")
local Kit = require("vocab2deck/ui/kit")
local Safe = require("vocab2deck/safe")
local Tpl = require("vocab2deck/template")
local _ = require("gettext")
local T = require("ffi/util").template

local Editor = BaseScreen:extend{
    name = "vocab2deck_editor",
    vkey = nil,
    is_new = false,          -- cartão criado agora a partir do livro
    lookup_on_open = false,  -- buscar a definição no dicionário ao abrir
}

-- Trechos longos não estão em dicionário; só busca até este número de palavras.
local LOOKUP_MAX_WORDS = 4

local SIDE_LABEL = { front = _("frente"), back = _("verso"), none = _("não vai para o cartão") }

function Editor:setup()
    self.page = 1
    self:load()
    if self.item and self.lookup_on_open then
        local n = select(2, self.item.word:gsub("%S+", ""))
        if n <= LOOKUP_MAX_WORDS then
            self.item = self.host:ensureLookup(self.item)
            self:load()
        end
    end
end

-- Novo cartão: descartar (apaga o item) ou guardar no Inbox.
function Editor:discard()
    Safe.run(_("descartar"), function() self.host:getStore():delete(self.vkey) end)
    self.discarded = true
    BaseScreen.onClose(self)
end

function Editor:saveToInbox()
    BaseScreen.onClose(self)
    Safe.message(_("Salvo no ○ Inbox. Revise e exporte pelo Vocabulário → Flashcards."), 2)
end

function Editor:onClose()
    if self.is_new and not self.discarded then
        self:saveToInbox()
        return true
    end
    return BaseScreen.onClose(self)
end

function Editor:load()
    self.item = self.host:getStore():get(self.vkey)
    if self.item then
        self.fields = Tpl.fields(self.item, self.host:model(), self.host.settings:cardOptions())
    end
end

function Editor:onDataChanged()
    self:load()
end

function Editor:changed()
    self.host:pushItemToDeck(self.vkey)
    self:load()
    self:refresh()
end

local function choose(title, rows)
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local buttons = {}
    for __, r in ipairs(rows) do
        buttons[#buttons + 1] = { { text = r.text, enabled = r.enabled, callback = function()
            UIManager:close(d)
            if r.callback then Safe.run(_("campo"), r.callback) end
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Cancelar"), callback = function() UIManager:close(d) end } }
    d = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(d)
end

local function editText(title, value, on_save, opts)
    require("vocab2deck/ui").editText(title, value, function(v) Safe.run(_("salvar"), on_save, v) end, opts)
end

function Editor:editValue(f)
    editText(f.name, f.value, function(v)
        local store = self.host:getStore()
        if f.extra then store:updateExtra(f.id, { value = v }) else store:setOverride(self.vkey, f.id, v) end
        self:changed()
    end, { allow_empty = true })
end

function Editor:fieldOptions(f)
    local store = self.host:getStore()
    if f.extra then
        local function side(s)
            return { text = (f.side == s and "● " or "") .. T(_("Lado: %1"), SIDE_LABEL[s]), callback = function()
                store:updateExtra(f.id, { side = s })
                self:changed()
            end }
        end
        choose(T(_("%1 · só neste cartão"), f.name), {
            { text = _("Editar o texto"), callback = function() self:editValue(f) end },
            { text = _("Renomear"), callback = function()
                editText(_("Nome do campo"), f.name, function(v)
                    store:updateExtra(f.id, { name = v })
                    self:changed()
                end, { multiline = false })
            end },
            side("front"), side("back"), side("none"),
            { text = _("Remover este campo"), callback = function()
                store:removeExtra(f.id)
                self:changed()
            end },
        })
        return
    end
    choose(T(_("%1 · campo do modelo (%2)"), f.name, SIDE_LABEL[f.side]), {
        { text = _("Editar o texto"), callback = function() self:editValue(f) end },
        f.removed and { text = _("Trazer de volta para este cartão"), callback = function()
            store:setItemSide(self.vkey, f.id, nil)
            self:changed()
        end } or { text = _("− Tirar só deste cartão"), callback = function()
            store:setItemSide(self.vkey, f.id, "none")
            self:changed()
        end },
        { text = _("Restaurar o texto gerado"), enabled = f.edited and f.source ~= "none", callback = function()
            store:setOverride(self.vkey, f.id, nil)
            self:changed()
        end },
        { text = _("Mudar lado ou nome (no modelo, vale para todos)"), callback = function()
            self.app:open("vocab2deck/screens/model", {})
        end },
    })
end

-- "− Campo": campo só deste cartão sai; campo do modelo sai deste cartão ou de todos.
function Editor:removeField()
    local store = self.host:getStore()
    local rows = {}
    for __, f in ipairs(self.fields) do
        if f.extra then
            rows[#rows + 1] = { text = T(_("− %1 (só neste cartão)"), f.name), callback = function()
                store:removeExtra(f.id)
                self:changed()
            end }
        elseif not f.removed then
            rows[#rows + 1] = { text = "− " .. f.name, callback = function()
                choose(T(_("Tirar \"%1\" de onde?"), f.name), {
                    { text = _("Só deste cartão"), callback = function()
                        store:setItemSide(self.vkey, f.id, "none")
                        self:changed()
                    end },
                    { text = _("De todos os cartões (modelo)"), callback = function()
                        local ConfirmBox = require("ui/widget/confirmbox")
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Tirar o campo \"%1\" de todos os cartões? Dá para trazê-lo de volta em Campos ▸ + Campo."), f.name),
                            ok_text = _("Tirar"),
                            ok_callback = function()
                                Safe.run(_("campo"), function()
                                    self.host:removeModelField(f.id)
                                    self:changed()
                                end)
                            end,
                        })
                    end },
                })
            end }
        end
    end
    if #rows == 0 then
        Safe.message(_("Não há campo para tirar."), 2)
        return
    end
    choose(_("Qual campo tirar?"), rows)
end

function Editor:addField()
    local store = self.host:getStore()
    local function askSide(on_side)
        choose(_("Em que lado do cartão?"), {
            { text = _("Frente"), callback = function() on_side("front") end },
            { text = _("Verso"), callback = function() on_side("back") end },
            { text = _("Não mostrar (só guardar)"), callback = function() on_side("none") end },
        })
    end
    choose(_("Novo campo"), {
        { text = _("Só neste cartão"), callback = function()
            editText(_("Nome do campo novo"), "", function(name)
                if not name:match("%S") then return end
                askSide(function(side)
                    local id = store:addExtra(self.vkey, name, side, "")
                    self:changed()
                    for __, f in ipairs(self.fields) do
                        if f.extra and f.id == id then self:editValue(f) end
                    end
                end)
            end, { multiline = false })
        end },
        { text = _("No modelo (todos os cartões)"), callback = function()
            editText(_("Nome do campo novo"), "", function(name)
                if not name:match("%S") then return end
                askSide(function(side)
                    self.host:addModelField(name, side)
                    self:changed()
                end)
            end, { multiline = false })
        end },
    })
end

function Editor:preview()
    local opts = self.host.settings:cardOptions()
    local r = Tpl.render(self.fields, opts)
    local parts = {
        _("FRENTE"), r.f.front ~= "" and r.f.front or _("(vazia)"), "",
        _("VERSO, como o Anki Viewer mostra ao tocar em Show answer"), r.f.back ~= "" and r.f.back or _("(vazio)"),
    }
    if opts.both_directions then
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("CARTÃO INVERSO · FRENTE")
        parts[#parts + 1] = r.r.front
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("CARTÃO INVERSO · VERSO")
        parts[#parts + 1] = r.r.back
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{ title = T(_("Pré-visualização · %1"), self.item.word), text = table.concat(parts, "\n") })
end

-- Uma caixa de campo: rótulo (nome · lado · ⋯) e o texto com borda.
function Editor:fieldWidget(f, width)
    local notes = { SIDE_LABEL[f.side] }
    if f.removed then
        notes = { _("removido deste cartão (⋯ traz de volta)") }
    elseif f.extra then notes[#notes + 1] = _("só neste cartão")
    elseif f.edited then notes[#notes + 1] = _("editado") end
    local label = Kit.text(f.name, Kit.uiBold(Kit.SIZE.small), {}) -- sem :upper(): no Lua ele não muda letras acentuadas
    local note = Kit.text(" · " .. table.concat(notes, " · "), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK })
    local more = Kit.textButton("⋯", function() self:fieldOptions(f) end, { size = Kit.SIZE.title, height = Kit.dp(40) })
    local left = require("ui/widget/horizontalgroup"):new{ align = "center", label, note }
    local inner_w = width - 2 * (Kit.dp(1.5) + Kit.dp(12))
    local empty = f.value == nil or f.value == ""
    local content = Kit.textbox(empty and _("Toque para preencher") or f.value, Kit.ui(Kit.SIZE.body), inner_w,
        { max_lines = 3, fgcolor = (empty or f.side == "none") and Kit.GREY_DARK or Kit.BLACK })
    local box = Kit.bordered(Kit.box(inner_w, math.max(content:getSize().h, Kit.TAP - 2 * (Kit.dp(1.5) + Kit.dp(12))),
        content, "left"))
    return VerticalGroup:new{
        align = "left",
        Kit.spread(width, Kit.dp(40), left, more),
        Kit.tap(box, function() self:editValue(f) end),
    }
end

function Editor:build(w, h)
    local title = self.item and T(_("Campos · %1"), self.item.word) or _("Campos")
    if self.is_new then title = _("Novo cartão") end
    local header = Kit.header{ width = w, title = title,
        on_back = function() self:onClose() end,
        right = self.item and Kit.textButton(_("Pré-visualizar"), function() self:preview() end, { size = Kit.SIZE.small }) or nil,
        title_size = Kit.SIZE.body + 2 }
    if not self.item then
        return VerticalGroup:new{ align = "left", header,
            Kit.box(w, h - header:getSize().h, Kit.text(_("Esta palavra não existe mais."), Kit.ui(), {})) }
    end
    local buttons = {
        { text = _("− Campo"), callback = function() self:removeField() end },
        { text = _("+ Campo"), callback = function() self:addField() end },
        { text = _("Pronto"), primary = true, callback = function() self:onClose() end },
    }
    if self.is_new then
        buttons = {
            { text = _("Cancelar"), callback = function() self:discard() end },
            { text = _("− Campo"), weight = 0.8, callback = function() self:removeField() end },
            { text = _("+ Campo"), weight = 0.8, callback = function() self:addField() end },
            { text = _("Salvar no Inbox"), primary = true, weight = 1.5, callback = function() self:onClose() end },
        }
    end
    local bottom = Kit.bottomBar(w, buttons, { size = Kit.SIZE.small })
    local cw = w - 2 * Kit.PAD
    local avail = h - header:getSize().h - bottom:getSize().h - Kit.PAGER_H
    -- distribui os campos em páginas pela altura real de cada caixa
    local widgets = {}
    for __, f in ipairs(self.fields) do widgets[#widgets + 1] = self:fieldWidget(f, cw) end
    local pages, used = { {} }, Kit.dp(8)
    for __, wdg in ipairs(widgets) do
        local fh = wdg:getSize().h + Kit.dp(10)
        if used + fh > avail and #pages[#pages] > 0 then
            pages[#pages + 1] = {}
            used = Kit.dp(8)
        end
        table.insert(pages[#pages], wdg)
        used = used + fh
    end
    self.pages = #pages
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local body = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)) }
    for __, wdg in ipairs(pages[self.page]) do
        table.insert(body, wdg)
        table.insert(body, Kit.vspan(Kit.dp(10)))
    end
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
        self:pagerWidget(w),
        bottom,
    }
end

return Editor
