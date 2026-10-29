--[[--
Modelo de campos (o "tipo de nota" de todos os cartões): ordem, nome e lado
de cada campo. Qualquer campo pode ser renomeado, mudar de lado, de
ordem ou ser removido; os do plugin (Palavra, Frase, Definição, Livro) podem
voltar por "+ Campo". Mudar o modelo muda o texto dos cartões já no baralho:
eles aparecem como "com conteúdo novo" no Início e podem ser atualizados sem
perder o progresso.
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("vocab2deck/ui/screen")
local Kit = require("vocab2deck/ui/kit")
local Safe = require("vocab2deck/safe")
local Tpl = require("vocab2deck/template")
local _ = require("gettext")
local T = require("ffi/util").template

local Model = BaseScreen:extend{ name = "vocab2deck_model" }

local SIDE_SYMBOL = { front = "F", back = "V", none = "—" }
local SIDE_LABEL = { front = _("Frente"), back = _("Verso"), none = _("Não mostrar") }
local SOURCE_LABEL = {
    word = _("preenchido com a palavra"), sentence = _("preenchido com a frase do livro"),
    definition = _("preenchido com a definição do dicionário"), book = _("preenchido com o título do livro"),
    none = _("campo seu, começa vazio"),
}

function Model:setup()
    self.list = self.host:model()
end

function Model:onDataChanged()
    self.list = self.host:model()
end

function Model:save()
    self.host:setModel(self.list)
    self.list = self.host:model()
    self:refresh()
end

-- Remove um campo do modelo. Campo seu: o texto escrito nele some de todos os
-- cartões. Campo do plugin (Palavra, Frase, Definição, Livro): suas edições ficam
-- guardadas e voltam se você adicionar o campo de novo.
function Model:removeField(i)
    local f = self.list[i]
    if #self.list <= 1 then
        Safe.message(_("O cartão precisa de pelo menos um campo."), 3)
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local text = Tpl.isBuiltin(f)
        and T(_("Remover o campo \"%1\" de todos os cartões? Dá para adicioná-lo de novo depois em + Campo."), f.name)
        or T(_("Remover o campo \"%1\" de todos os cartões? O texto escrito nele também é apagado."), f.name)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Remover"),
        ok_callback = function()
            Safe.run(_("modelo"), function()
                table.remove(self.list, i)
                if not Tpl.isBuiltin(f) then self.host:getStore():dropField(f.id) end
                self:save()
            end)
        end,
    })
end

function Model:fieldMenu(i)
    local f = self.list[i]
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local function act(fn) return function() UIManager:close(d); Safe.run(_("modelo"), fn) end end
    local rows = {}
    rows[#rows + 1] = { { text = _("✎ Renomear"), callback = act(function()
        require("vocab2deck/ui").editText(_("Nome do campo"), f.name, function(v)
            v = v:gsub("^%s+", ""):gsub("%s+$", "")
            if v ~= "" then f.name = v; self:save() end
        end, { multiline = false })
    end) } }
    local side_row = {}
    for __, s in ipairs(Tpl.SIDES) do
        side_row[#side_row + 1] = { text = (f.side == s and "● " or "") .. SIDE_LABEL[s], callback = act(function()
            f.side = s
            self:save()
        end) }
    end
    rows[#rows + 1] = side_row
    rows[#rows + 1] = {
        { text = _("↑ Subir"), enabled = i > 1, callback = act(function()
            self.list[i], self.list[i - 1] = self.list[i - 1], self.list[i]
            self:save()
        end) },
        { text = _("↓ Descer"), enabled = i < #self.list, callback = act(function()
            self.list[i], self.list[i + 1] = self.list[i + 1], self.list[i]
            self:save()
        end) },
    }
    rows[#rows + 1] = { { text = _("− Remover este campo"), callback = act(function() self:removeField(i) end) } }
    rows[#rows + 1] = { { text = _("Cancelar"), callback = function() UIManager:close(d) end } }
    d = ButtonDialog:new{ title = T(_("%1 · %2"), f.name, SOURCE_LABEL[f.source] or ""), buttons = rows }
    UIManager:show(d)
end

-- Escolher qual campo remover (botão "− Campo").
function Model:chooseRemove()
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local rows = {}
    for i, f in ipairs(self.list) do
        rows[#rows + 1] = { { text = "− " .. f.name, callback = function()
            UIManager:close(d)
            self:removeField(i)
        end } }
    end
    rows[#rows + 1] = { { text = _("Cancelar"), callback = function() UIManager:close(d) end } }
    d = ButtonDialog:new{ title = _("Qual campo remover?"), buttons = rows }
    UIManager:show(d)
end

-- "+ Campo": um campo seu (vazio) ou um campo do plugin que foi removido.
function Model:addField()
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local function askSide(on_side)
        local d2
        local rows = {}
        for __, s in ipairs(Tpl.SIDES) do
            rows[#rows + 1] = { { text = SIDE_LABEL[s], callback = function()
                UIManager:close(d2)
                Safe.run(_("modelo"), function() on_side(s) end)
            end } }
        end
        d2 = ButtonDialog:new{ title = _("Em que lado do cartão?"), buttons = rows }
        UIManager:show(d2)
    end
    local present = {}
    for __, f in ipairs(self.list) do present[f.id] = true end
    local rows = { { { text = _("Campo novo, vazio (você escreve em cada cartão)"), callback = function()
        UIManager:close(d)
        require("vocab2deck/ui").editText(_("Nome do campo novo"), "", function(name)
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            if name == "" then return end
            askSide(function(s)
                self.host:addModelField(name, s)
                self.list = self.host:model()
                self:refresh()
            end)
        end, { multiline = false })
    end } } }
    for __, f in ipairs(Tpl.defaults()) do
        if Tpl.isBuiltin(f) and not present[f.id] then
            rows[#rows + 1] = { { text = T(_("%1 (%2)"), f.name, SOURCE_LABEL[f.source]), callback = function()
                UIManager:close(d)
                askSide(function(s)
                    f.side = s
                    self.list[#self.list + 1] = f
                    self:save()
                end)
            end } }
        end
    end
    rows[#rows + 1] = { { text = _("Cancelar"), callback = function() UIManager:close(d) end } }
    d = ButtonDialog:new{ title = _("Adicionar campo"), buttons = rows }
    UIManager:show(d)
end

function Model:build(w, h)
    local header = Kit.header{ width = w, title = _("Campos do cartão"), on_back = function() self:onClose() end }
    local bottom = Kit.bottomBar(w, {
        { text = _("Padrão"), callback = function()
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Voltar ao modelo padrão (Palavra, Frase, Definição, Livro, Notas)? Campos seus são removidos do modelo."),
                ok_text = _("Restaurar"),
                ok_callback = function() self.list = Tpl.defaults(); self:save() end,
            })
        end },
        { text = _("− Campo"), callback = function() self:chooseRemove() end },
        { text = _("+ Campo"), primary = true, callback = function() self:addField() end },
    })
    local cw = w - 2 * Kit.PAD
    local rows = {}
    for i, f in ipairs(self.list) do
        rows[#rows + 1] = Kit.row{ width = cw, symbol = SIDE_SYMBOL[f.side], text = f.name,
            sub = T(_("%1 · %2"), SIDE_LABEL[f.side], SOURCE_LABEL[f.source] or ""),
            callback = function() self:fieldMenu(i) end }
    end
    local body = VerticalGroup:new{ align = "left",
        Kit.sectionLabel(_("Toque num campo: renomear, lado, ordem, remover"), cw),
        Kit.rows(cw, rows),
        Kit.vspan(Kit.dp(12)),
        Kit.textbox(_("No Anki Viewer, \"Show answer\" mostra a frente, um traço e o verso."),
            Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }),
        Kit.vspan(Kit.dp(8)),
        Kit.textbox(_("Na revisão, \"✎ Campos do cartão\" deixa editar o texto de cada campo e criar campos só para aquele cartão."),
            Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }),
    }
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, h - header:getSize().h - bottom:getSize().h, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Model
