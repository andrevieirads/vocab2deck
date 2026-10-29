--[[--
Cartões a partir do livro: o botão "＋ Adicionar ao baralho" no menu da
seleção de texto e no popup do dicionário. Abre o editor de campos com a
palavra ou o trecho na frente, a frase de contexto e, quando houver, a
definição; salvar manda para o ○ Inbox (o fluxo normal: revisar → exportar).

Adaptado de kr2anki/capture.lua (KR2Anki): bookInfo, selectionContext e o
registro dos botões. Interfaces do KOReader usadas (as mesmas do KR2Anki):
* ReaderHighlight:addToHighlightDialog(key, fn), .selected_text,
  :getSelectedWordContext(n), :onClose()
* ReaderDictionary:addToDictButtons(spec); DictQuickLookup .word,
  .lookupword, .results, .dict_index, :onClose()
A ideia (botão na seleção → editar → salvar) é a do PhraseDeck; o código não
foi copiado dele (é GPLv3).
--]]

local B = require("vocab2deck/card_builder")
local DictLookup = require("vocab2deck/dict_lookup")
local Safe = require("vocab2deck/safe")
local U = require("vocab2deck/lib/u8")
local _ = require("gettext")

local C = {}

C.HIGHLIGHT_KEY = "vocab2deck_add"   -- ordena depois dos botões do KOReader ("01_select" …)
C.DICT_BUTTON_ID = "zz_vocab2deck_add"
C.LABEL = _("＋ Adicionar ao baralho")

-- Livro aberto (título como o KOReader mostra).
function C.bookTitle(ui)
    if not (ui and ui.document) then return nil end
    local props = ui.doc_props or {}
    local title = props.display_title or props.title
    if (not title or title == "") and ui.document.file then
        title = ui.document.file:match("([^/]+)%.[^./]*$") or ui.document.file:match("([^/]+)$")
    end
    if title == "" then return nil end
    return title
end

-- Contexto em volta da seleção atual: prev, next (texto antes e depois).
function C.selectionContext(ui, selection)
    local hl = ui and ui.highlight
    if not (hl and hl.selected_text and hl.getSelectedWordContext and ui.document) then return nil, nil end
    local nb = B.detectLang(selection) == "en" and 50 or 80
    local ok, prev, nxt = pcall(hl.getSelectedWordContext, hl, nb)
    if not ok then return nil, nil end
    return prev, nxt
end

--[[--
Cria (ou acha) o item e abre o editor.
@param cap { text, prev, next, book, lookup, origin }  lookup = resultado do dicionário já na tela
--]]
function C.open(host, cap)
    local text = U.squash(cap.text or "")
    if text == "" then
        Safe.message(_("Nenhum texto selecionado."), 3)
        return
    end
    local store = host:getStore()
    local vkey, created = store:addCapture{
        word = text, prev = cap.prev, next = cap.next, highlight = text, book = cap.book,
        origin = cap.origin,
    }
    if created and cap.lookup then
        store:setLookup(vkey, cap.lookup)
    end
    if not created then
        Safe.message(_("Este texto já está no plugin; abrindo o cartão que existe."), 2)
    end
    host:getApp():open("vocab2deck/screens/editor", { vkey = vkey, is_new = created, lookup_on_open = created and not cap.lookup })
end

--[[--
"＋ Adicionar cartão" no Início: pede a frente (palavra ou trecho) e abre o
mesmo editor de Novo cartão. Sem frase de contexto; com o título do livro se
houver um aberto.
--]]
function C.manual(host)
    require("vocab2deck/ui").editText(_("Frente do cartão (palavra ou trecho)"), "", function(text)
        Safe.run(_("adicionar cartão"), C.open, host, {
            text = text, book = C.bookTitle(host.ui), origin = "manual",
        })
    end, { multiline = true })
end

-- Menu da seleção de texto (trecho selecionado no livro).
function C.registerHighlightButton(host)
    local hl = host.ui and host.ui.highlight
    if not (hl and hl.addToHighlightDialog) then
        Safe.log("ReaderHighlight:addToHighlightDialog não existe; botão da seleção desativado")
        return false
    end
    hl:addToHighlightDialog(C.HIGHLIGHT_KEY, function(this)
        return {
            text = C.LABEL,
            enabled = this.selected_text ~= nil,
            callback = Safe.wrap(_("adicionar ao baralho"), function()
                local sel = this.selected_text
                if not sel then return end
                local text = U.squash(sel.text or "")
                local prev, nxt = C.selectionContext(host.ui, text)
                local book = C.bookTitle(host.ui)
                this:onClose()
                C.open(host, { text = text, prev = prev, next = nxt, book = book })
            end),
        }
    end)
    return true
end

-- Resultado do dicionário que está na tela, no formato de DictLookup.lookup.
local function popupLookup(popup)
    local r = popup.results and popup.results[popup.dict_index or 1]
    if not r or r.no_result or r.is_wiki or type(r.definition) ~= "string" or r.definition == "" then return nil end
    local senses = DictLookup.senses(r.definition, r.word)
    if #senses == 0 then return nil end
    return { definition = DictLookup.definitionText(r.definition, r.word, 3), senses = senses, dict = r.dict, headword = r.word }
end

-- Popup do dicionário (toque longo numa palavra).
function C.registerDictButton(host)
    local dict = host.ui and host.ui.dictionary
    if not (dict and dict.addToDictButtons) then
        Safe.log("ReaderDictionary:addToDictButtons não existe; botão do dicionário desativado")
        return false
    end
    dict:addToDictButtons({
        id = C.DICT_BUTTON_ID,
        menu_text = _("Vocabulário → Flashcards: adicionar ao baralho"),
        text = C.LABEL,
        text_func = function() return C.LABEL end,
        show_func = function(popup) return not popup.is_wiki and not popup.is_wiki_fullpage end,
        callback = Safe.wrap(_("adicionar ao baralho"), function(popup)
            local hl = host.ui and host.ui.highlight
            local text = popup.word or popup.lookupword
            if hl and hl.selected_text and hl.selected_text.text and hl.selected_text.text ~= "" then
                text = hl.selected_text.text
            end
            text = U.squash(text or "")
            local prev, nxt = C.selectionContext(host.ui, text)
            local lookup = popupLookup(popup)
            local book = C.bookTitle(host.ui)
            if popup.onClose then popup:onClose() end
            if hl and hl.clear then pcall(hl.clear, hl) end
            C.open(host, { text = text, prev = prev, next = nxt, book = book, lookup = lookup })
        end),
    })
    return true
end

return C
