--[[--
Diálogos comuns, com widgets nativos do KOReader (ButtonDialog, Menu,
InputDialog, ConfirmBox, InfoMessage). As telas cheias (Início, lista,
revisão, editor de campos, modelo, exportação) ficam em vocab2deck/screens/.

Pensado para e-ink: nada se atualiza sozinho, sem animação; cada diálogo é
desenhado uma vez e só muda quando o usuário toca.

A tela de configurações usa o mesmo padrão da tela "Settings" do Anki Viewer
(Menu com mandatory_func, keep_menu_open e onMenuChoice próprio).
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Safe = require("vocab2deck/safe")
local U = require("vocab2deck/lib/u8")

local UI = {}

local function yesNo(v) return v and _("Sim") or _("Não") end

local function info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- Mensagem curta enquanto um trabalho rápido roda (desenhada uma vez, sem animação).
function UI.busy(text)
    local msg = InfoMessage:new{ text = text, timeout = 0 }
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

-- Erros de leitura do Vocabulary Builder em texto claro.
function UI.vocabError(kind, detail)
    if kind == "missing" then
        return _("O banco do Vocabulary Builder não foi encontrado.\n\nAtive o Vocabulary Builder (menu Ferramentas) e salve algumas palavras ao consultar o dicionário.")
    elseif kind == "not_vocab" then
        return _("O arquivo vocabulary_builder.sqlite3 não tem a tabela de palavras esperada.")
    elseif kind == "open_failed" then
        return T(_("Não foi possível abrir o banco do Vocabulary Builder:\n%1"), Safe.shortError(detail))
    end
    return T(_("Erro ao ler o Vocabulary Builder:\n%1"), Safe.shortError(detail))
end

-- Erros do banco do Anki Viewer em texto claro.
function UI.deckError(status)
    if status == "old_schema" then
        return _("O banco do Anki Viewer é de uma versão antiga.\n\nToque em Estudar uma vez (o Anki Viewer embutido atualiza o próprio banco) e tente de novo.")
    end
    return _("O banco do Anki Viewer tem um formato desconhecido. Por segurança, nada será gravado.")
end

--[[--
Caixa de texto para editar um campo.
@param opts { multiline (padrão true), allow_empty (padrão false) }
--]]
function UI.editText(title, text, on_save, opts)
    opts = opts or {}
    local multiline = opts.multiline ~= false
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = text or "",
        allow_newline = multiline,
        fullscreen = multiline,
        condensed = multiline,
        buttons = { {
            { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dlg) end },
            {
                text = _("Salvar"), is_enter_default = not multiline,
                callback = function()
                    local value = dlg:getInputText() or ""
                    if not opts.allow_empty and U.trim(value) == "" then
                        info(_("O texto não pode ficar vazio."), 3)
                        return
                    end
                    UIManager:close(dlg)
                    on_save(value)
                end,
            },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Conteúdo mudou: perguntar antes de atualizar -------------------------------------

function UI.askChanges(plugin, changed)
    local edited = 0
    for __, c in ipairs(changed) do if c.edited then edited = edited + 1 end end
    local text = T(_("%1 cartões têm conteúdo novo (campos, definição, contexto ou formato)."), #changed)
    if edited > 0 then
        text = text .. "\n" .. T(_("%1 deles foram editados fora daqui (versão 1 ou outro programa)."), edited)
    end
    text = text .. "\n\n" .. _("Atualizar troca só o texto: o progresso de revisão é mantido.")
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = {}
    if edited < #changed then
        buttons[#buttons + 1] = { {
            text = edited > 0 and T(_("Só os não editados (%1)"), #changed - edited) or _("Atualizar"),
            font_bold = true,
            callback = function() close(); plugin:applyUpdates(changed, true) end,
        } }
    end
    if edited > 0 then
        buttons[#buttons + 1] = { {
            text = _("Atualizar todos (sobrescreve as edições)"),
            callback = function() close(); plugin:applyUpdates(changed, false) end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Ver a lista"),
        callback = function() close(); UI.showChangedList(plugin, changed) end,
    } }
    buttons[#buttons + 1] = { { text = _("Agora não"), callback = close } }
    dialog = ButtonDialog:new{ title = text, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Lista das palavras com conteúdo novo (só leitura).
function UI.showChangedList(plugin, changed)
    local items = {}
    for __, c in ipairs(changed) do
        items[#items + 1] = {
            text = c.item.word .. (c.side == "r" and "  ⇄" or ""),
            mandatory = c.edited and "✎" or nil,
            change = c,
        }
    end
    local menu = UI.fullMenu(T(_("Conteúdo novo (%1)"), #changed), items)
    function menu:onMenuChoice(item)
        local c = item.change
        UIManager:show(ConfirmBox:new{
            text = T(_("Novo texto:\n\n%1\n\n――――\n\n%2"), U.ellipsize(c.front, 300), U.ellipsize(c.back, 300)),
            ok_text = _("Atualizar este"),
            cancel_text = _("Voltar"),
            ok_callback = function()
                UIManager:close(menu)
                plugin:applyUpdates({ c }, false)
            end,
        })
        return true
    end
    UIManager:show(menu)
end

-- Escolha de baralho para estudar (quando há subbaralhos por livro).
function UI.chooseDeck(decks, on_choice)
    local dialog
    local buttons = {}
    for __, d in ipairs(decks) do
        buttons[#buttons + 1] = { {
            text = T(_("%1 — %2 para estudar / %3"), d.name, d.due, d.cards),
            callback = function() UIManager:close(dialog); on_choice(d) end,
        } }
    end
    buttons[#buttons + 1] = { { text = _("Fechar"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = _("Qual baralho estudar?"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Texto de um baralho nas listas: "Nome — 3 para estudar / 40".
function UI.deckLabel(d)
    return T(_("%1 — %2 para estudar / %3"), d.name, d.due, d.cards)
end

-- Toque longo num baralho (Início): estudar, mapeamento de campos (baralhos
-- importados de .apkg) e apagar, como no Decks do Anki Viewer.
function UI.deckOptions(plugin, deck)
    local dialog
    local buttons = {
        { { text = _("Estudar"), callback = function() UIManager:close(dialog); plugin:studyDeck(deck.id) end } },
    }
    if not deck.ours then
        buttons[#buttons + 1] = { { text = _("Mapeamento de campos"), callback = function()
            UIManager:close(dialog)
            local av = plugin:getViewer()
            if av then Safe.run(_("mapeamento de campos"), av.openDeckFieldMapping, av, deck) end
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Apagar baralho"), callback = function()
        UIManager:close(dialog)
        local extra = deck.ours and _("\n\nOs cartões deste plugin voltam na próxima exportação (como cartões novos).") or ""
        UIManager:show(ConfirmBox:new{
            text = T(_("Apagar o baralho \"%1\" e os %2 cartões dele, com o progresso?"), deck.name, deck.cards) .. extra,
            ok_text = _("Apagar"),
            ok_callback = function()
                local av = plugin:getViewer()
                if not av then return end
                if Safe.run(_("apagar baralho"), function() av:deleteDeck(deck.id, deck.name); return true end) then
                    info(T(_("Baralho \"%1\" apagado."), deck.name), 3)
                end
            end,
        })
    end } }
    buttons[#buttons + 1] = { { text = _("Fechar"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = deck.name, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Todos os baralhos numa lista em tela cheia (quando não cabem no Início).
function UI.showDecks(plugin, decks)
    local menu
    local items = {}
    for __, d in ipairs(decks) do
        items[#items + 1] = { text = UI.deckLabel(d), deck = d }
    end
    menu = UI.fullMenu(_("Baralhos"), items)
    function menu:onMenuChoice(item)
        UIManager:close(self)
        plugin:studyDeck(item.deck.id)
        return true
    end
    function menu:onMenuHold(item)
        UIManager:close(self)
        plugin:deckOptions(item.deck)
        return true
    end
    UIManager:show(menu)
end

-- Menu em tela cheia (lista paginada, sem rolagem contínua).
function UI.fullMenu(title, items)
    local Screen = Device.screen
    return Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
end

-- Configurações ---------------------------------------------------------------------

local CHANGE_LABELS = { ask = _("Perguntar"), update = _("Atualizar"), ignore = _("Ignorar") }

local function askNumber(title, current, description, on_value)
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = tostring(current),
        input_type = "number",
        description = description,
        buttons = { {
            { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dlg) end },
            {
                text = _("Salvar"), is_enter_default = true,
                callback = function()
                    local n = tonumber(dlg:getInputText())
                    UIManager:close(dlg)
                    if n then on_value(n) end
                end,
            },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function choose(title, options, on_value)
    local dialog
    local buttons = {}
    for __, o in ipairs(options) do
        buttons[#buttons + 1] = { {
            text = o.text,
            callback = function() UIManager:close(dialog); on_value(o.value) end,
        } }
    end
    buttons[#buttons + 1] = { { text = _("Cancelar"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- on_close: chamado ao fechar (a tela de baixo recarrega os dados).
function UI.showSettings(plugin, on_close)
    local s = plugin.settings
    local menu
    local function refresh()
        if menu and menu.updateItems then menu:updateItems(1, true) end
    end
    -- opções de estudo do Anki Viewer embutido
    local function study(key, default)
        local av = plugin:getViewer()
        if not av then return default end
        return av:readSetting(key, default)
    end
    local function setStudy(key, value)
        local av = plugin:getViewer()
        if av then av:saveSetting(key, value) end
    end
    local function toggle(key, note)
        return function()
            s:toggle(key)
            refresh()
            if note then info(note, 4) end
        end
    end

    local items = {
        {
            text = _("Nome do baralho"),
            keep_menu_open = true,
            mandatory_func = function() return U.ellipsize(s:get("deck_name"), 24) end,
            callback = function()
                local dlg
                dlg = InputDialog:new{
                    title = _("Nome do baralho de destino"),
                    input = s:get("deck_name"),
                    description = _("Os cartões já exportados são movidos para o novo nome (o progresso vai junto)."),
                    buttons = { {
                        { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dlg) end },
                        {
                            text = _("Salvar"), is_enter_default = true,
                            callback = function()
                                local name = U.trim(dlg:getInputText() or "")
                                UIManager:close(dlg)
                                if name ~= "" then s:set("deck_name", name); refresh() end
                            end,
                        },
                    } },
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        },
        {
            text = _("Um baralho por livro"),
            keep_menu_open = true,
            mandatory_func = function() return yesNo(s:get("subdeck_per_book")) end,
            callback = toggle("subdeck_per_book", _("Cada livro vira um baralho com o título dele. Os cartões já exportados são movidos (o progresso vai junto).")),
        },
        {
            text = _("Campos do cartão (modelo)"),
            callback = function() plugin:openModel() end,
        },
        {
            text = _("Direção do cartão"),
            keep_menu_open = true,
            mandatory_func = function()
                return s:get("direction") == "both" and _("Os dois sentidos") or _("Frente → verso")
            end,
            callback = function()
                local both = s:get("direction") ~= "both"
                s:set("direction", both and "both" or "forward")
                refresh()
                info(both and _("Na próxima exportação, cada palavra ganha também o cartão verso → frente.")
                    or _("Os cartões inversos já criados não são apagados."), 4)
            end,
        },
        {
            text = _("Trazer do Vocabulary Builder"),
            keep_menu_open = true,
            mandatory_func = function() return s:get("only_unlearned") and _("Só não aprendidas") or _("Todas") end,
            callback = toggle("only_unlearned", _("Vale para as próximas palavras que chegarem ao Inbox.")),
        },
        {
            text = _("Aprendida = acertos seguidos ≥"),
            keep_menu_open = true,
            mandatory_func = function() return tostring(s:get("learned_streak")) end,
            callback = function()
                askNumber(_("Acertos seguidos para contar como aprendida"), s:get("learned_streak"),
                    _("Usa a coluna streak_count do Vocabulary Builder (acertos seguidos na revisão dele)."),
                    function(n) s:set("learned_streak", math.max(1, math.floor(n))); refresh() end)
            end,
        },
        {
            text = _("Abrir direto na exportação"),
            keep_menu_open = true,
            mandatory_func = function() return yesNo(s:get("auto_export")) end,
            callback = toggle("auto_export", _("Ao abrir o plugin, os Revisados são exportados na hora.")),
        },
        {
            text = _("Cartões no baralho com texto novo"),
            keep_menu_open = true,
            mandatory_func = function() return CHANGE_LABELS[s:get("on_change")] or CHANGE_LABELS.update end,
            callback = function()
                choose(_("Quando o texto ou o baralho de um cartão já exportado mudar (modelo, definição, contexto, configurações):"), {
                    { text = _("Atualizar sozinho (menos os editados fora daqui)"), value = "update" },
                    { text = _("Perguntar"), value = "ask" },
                    { text = _("Ignorar"), value = "ignore" },
                }, function(v) s:set("on_change", v); refresh() end)
            end,
        },
        {
            text = _("Palavra sem definição"),
            keep_menu_open = true,
            mandatory_func = function()
                return s:get("missing_definition") == "placeholder" and _("Criar cartão") or _("Pular")
            end,
            callback = function()
                local v = s:get("missing_definition") == "placeholder" and "skip" or "placeholder"
                s:set("missing_definition", v)
                refresh()
            end,
        },
        {
            text = _("Sentidos na definição padrão"),
            keep_menu_open = true,
            mandatory_func = function() return tostring(s:get("max_senses")) end,
            callback = function()
                choose(_("Quantos sentidos do dicionário entram na definição padrão?"), {
                    { text = "1", value = 1 }, { text = "2", value = 2 },
                    { text = "3", value = 3 }, { text = "5", value = 5 },
                }, function(v) s:set("max_senses", v); refresh() end)
            end,
        },
        -- Estudo: as opções do Settings do Anki Viewer embutido (mesmas chaves,
        -- guardadas em settings/ankiviewer.lua)
        {
            text = _("Estudo: aleatório entre cartões do mesmo dia"),
            keep_menu_open = true,
            mandatory_func = function() return yesNo(study("randomize_equal_due", false)) end,
            callback = function()
                setStudy("randomize_equal_due", not study("randomize_equal_due", false))
                refresh()
            end,
        },
        {
            text = _("Estudo: cartões novos por dia"),
            keep_menu_open = true,
            mandatory_func = function()
                local n = tonumber(study("daily_new_cards_limit", 20)) or 20
                return n == 0 and _("Sem limite") or tostring(n)
            end,
            callback = function()
                askNumber(_("Cartões novos por dia"), tonumber(study("daily_new_cards_limit", 20)) or 20,
                    _("Quantos cartões novos aparecem por dia no estudo. 0 = sem limite."),
                    function(n) setStudy("daily_new_cards_limit", math.max(0, math.floor(n))); refresh() end)
            end,
        },
        {
            text = _("Estudo: tela cheia"),
            keep_menu_open = true,
            mandatory_func = function() return yesNo(study("fullscreen_study", false)) end,
            callback = function()
                setStudy("fullscreen_study", not study("fullscreen_study", false))
                refresh()
                info(_("Vale a partir da próxima vez que o estudo abrir."), 3)
            end,
        },
        {
            text = _("Estudo: intervalo mínimo"),
            keep_menu_open = true,
            mandatory_func = function()
                local d = tonumber(study("min_interval_days", 0)) or 0
                return d == 0 and _("Padrão") or T(_("%1 d"), d)
            end,
            callback = function()
                choose(_("Intervalo mínimo entre revisões (vale para Again; os outros botões crescem na mesma proporção)"), {
                    { text = _("Padrão (sem mínimo)"), value = 0 },
                    { text = _("1 dia"), value = 1 }, { text = _("3 dias"), value = 3 },
                    { text = _("7 dias"), value = 7 }, { text = _("14 dias"), value = 14 },
                }, function(v) setStudy("min_interval_days", v); refresh() end)
            end,
        },
        {
            text = _("Estudo: mapeamento de campos de um baralho importado"),
            callback = function()
                local imported = {}
                for __, d in ipairs(plugin:allDecks()) do
                    if not d.ours then imported[#imported + 1] = { text = d.name, value = d } end
                end
                if #imported == 0 then
                    info(_("Nenhum baralho importado de .apkg."), 3)
                    return
                end
                choose(_("Qual baralho?"), imported, function(d)
                    local av = plugin:getViewer()
                    if av then Safe.run(_("mapeamento de campos"), av.openDeckFieldMapping, av, d) end
                end)
            end,
        },
        {
            text = _("Verificar definições nos dicionários (lento)"),
            callback = function() plugin:checkDefinitions() end,
        },
        {
            text = _("Recriar cartões apagados no Anki Viewer"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Os cartões que você apagou no Anki Viewer voltam como cartões novos na próxima exportação. Continuar?"),
                    ok_text = _("Recriar"),
                    ok_callback = function() plugin:forgetDeleted() end,
                })
            end,
        },
        {
            text = _("Backups"),
            keep_menu_open = true,
            callback = function()
                info(T(_("Antes de cada gravação, o banco do Anki Viewer é copiado para:\n%1\n\nFicam os 5 backups mais recentes. Para restaurar, copie um deles por cima de ankiviewer/ankiviewer.sqlite3 com o KOReader fechado."),
                    plugin:writer().backup_dir))
            end,
        },
        {
            text = _("Fechar"),
            callback = function() end,
        },
    }

    menu = UI.fullMenu(_("Configurações · Vocabulário → Flashcards"), items)
    function menu:onMenuChoice(item)
        if not item.keep_menu_open then
            UIManager:close(self)
            if on_close then on_close() end
        end
        if item.callback then Safe.run(_("configuração"), item.callback) end
        return true
    end
    menu.close_callback = on_close
    UIManager:show(menu)
end

return UI
