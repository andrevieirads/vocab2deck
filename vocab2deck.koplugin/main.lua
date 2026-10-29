--[[--
Vocabulário → Flashcards (vocab2deck): traz as palavras do Vocabulary Builder
do KOReader para um Inbox, deixa revisar e editar cada cartão (fluxo do
KR2Anki, campos como no "Adicionar" do Anki), grava os revisados direto no
banco do Anki Viewer e estuda os cartões na tela do Anki Viewer, que vem
embutida (vocab2deck/ankiviewer): não é preciso instalar o Anki Viewer.

Entradas
* Menu principal ▸ Ferramentas ▸ "Vocabulário → Flashcards"
* Livro: "＋ Adicionar ao baralho" no menu da seleção e no popup do dicionário
* Ações de gesto (Gerenciador de gestos ▸ Geral):
    abrir · revisar o Inbox · exportar · estudar

Fluxo
  vocab_reader (Vocabulary Builder, só leitura) -> store (Inbox, banco próprio)
    -> screens/review + screens/editor (revisar, escolher o sentido, editar campos)
    -> screens/export -> sync.plan -> dict_lookup -> deck_writer (backup + transação)
    -> apkg: ankiviewer/shared/Vocab2Deck.apkg (Vocab2Deck::Livro), para o Anki
    -> "Estudar" abre a tela de estudo do Anki Viewer embutido no baralho

Reaproveita código do KR2Anki (leitura do Vocabulary Builder, busca no
dicionário, limpeza de definições, recorte da frase, kit de interface e o
desenho das telas) e traz o Anki Viewer 1.4.0 inteiro (estudo, importação de
.apkg, configurações), com o mesmo banco. Créditos no README.md.

@module koplugin.vocab2deck
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

-- Todos os módulos próprios são carregados aqui, durante o carregamento do
-- plugin, enquanto a pasta dele está no package.path do KOReader.
local Apkg = require("vocab2deck/apkg")
local App = require("vocab2deck/ui/app")
local B = require("vocab2deck/card_builder")
local Capture = require("vocab2deck/capture")
local DeckWriter = require("vocab2deck/deck_writer")
local DictLookup = require("vocab2deck/dict_lookup")
local Safe = require("vocab2deck/safe")
local Settings = require("vocab2deck/settings")
local Store = require("vocab2deck/store")
local Sync = require("vocab2deck/sync")
local Tpl = require("vocab2deck/template")
local UI = require("vocab2deck/ui")
local VocabReader = require("vocab2deck/vocab_reader")
require("vocab2deck/screens/home")
require("vocab2deck/screens/items")
require("vocab2deck/screens/review")
require("vocab2deck/screens/editor")
require("vocab2deck/screens/model")
require("vocab2deck/screens/export")
-- Anki Viewer embutido. Se ele não carregar, o resto do plugin continua funcionando.
local viewer_ok, AnkiViewer = pcall(require, "vocab2deck/ankiviewer/viewer")
if not viewer_ok then
    require("logger").err("vocab2deck: Anki Viewer embutido não carregou:", AnkiViewer)
    AnkiViewer = nil
end

local Vocab2Deck = WidgetContainer:extend{
    name = "vocab2deck",
    is_doc_only = false, -- funciona no leitor e no gerenciador de arquivos
}

-- Progresso: atualiza a tela a cada PROGRESS_EVERY palavras (poucos refreshes no e-ink).
local PROGRESS_EVERY = 5

function Vocab2Deck:init()
    self.settings = Settings.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/vocab2deck.lua"))
    Safe.run(_("registrar gestos"), self.onDispatcherRegisterActions, self)
    if self.ui and self.ui.menu then
        Safe.run(_("registrar menu"), function() self.ui.menu:registerToMainMenu(self) end)
    end
    -- "＋ Adicionar ao baralho" na seleção de texto e no popup do dicionário (só no leitor)
    if self.ui and self.ui.highlight then
        Safe.run(_("botão da seleção"), Capture.registerHighlightButton, self)
    end
    if self.ui and self.ui.dictionary then
        Safe.run(_("botão do dicionário"), Capture.registerDictButton, self)
    end
end

-- Com o livro aberto: garante o botão da seleção (o PhraseDeck registra aqui; o
-- KR2Anki, no init; registrar de novo só troca o botão de mesma chave).
function Vocab2Deck:onReaderReady()
    if self.ui and self.ui.highlight then
        Safe.run(_("botão da seleção"), Capture.registerHighlightButton, self)
    end
end

-- Menu e gestos ----------------------------------------------------------------------

function Vocab2Deck:addToMainMenu(menu_items)
    menu_items.vocab2deck = {
        text = _("Vocabulário → Flashcards"),
        sorting_hint = "tools",
        callback = function() self:onVocab2DeckOpen() end,
    }
end

-- Mesmo padrão do KR2Anki (onDispatcherRegisterActions + eventos). Os ids da
-- versão 1 continuam valendo para quem já ligou gestos a eles.
function Vocab2Deck:onDispatcherRegisterActions()
    Dispatcher:registerAction("vocab2deck_open", {
        category = "none", event = "Vocab2DeckOpen", general = true,
        title = _("Vocabulário → Flashcards: abrir"),
    })
    Dispatcher:registerAction("vocab2deck_triage", {
        category = "none", event = "Vocab2DeckTriage", general = true,
        title = _("Vocabulário → Flashcards: revisar o Inbox"),
    })
    Dispatcher:registerAction("vocab2deck_export", {
        category = "none", event = "Vocab2DeckExport", general = true,
        title = _("Vocabulário → Flashcards: exportar"),
    })
    Dispatcher:registerAction("vocab2deck_review", {
        category = "none", event = "Vocab2DeckReview", general = true, separator = true,
        title = _("Vocabulário → Flashcards: estudar"),
    })
end

function Vocab2Deck:onVocab2DeckOpen()
    Safe.run(_("abrir"), self.openHome, self)
    return true
end

function Vocab2Deck:onVocab2DeckTriage()
    Safe.run(_("revisar"), function()
        self:syncVocab()
        self:openReview()
    end)
    return true
end

function Vocab2Deck:onVocab2DeckExport()
    Safe.run(_("exportar"), function()
        self:syncVocab()
        self:openExport()
    end)
    return true
end

function Vocab2Deck:onVocab2DeckReview()
    Safe.run(_("estudar"), self.studyNow, self)
    return true
end

function Vocab2Deck:onCloseWidget()
    if self.app then self.app:closeAll() end
end

-- Serviços ---------------------------------------------------------------------------

function Vocab2Deck:writer()
    if not self._writer then self._writer = DeckWriter.new() end
    return self._writer
end

-- Banco próprio, aberto sob demanda (um problema nele nunca impede o KOReader de abrir).
function Vocab2Deck:getStore()
    if not self.store then
        self.store = Store.new(DataStorage:getSettingsDir() .. "/vocab2deck.sqlite3")
    end
    return self.store
end

function Vocab2Deck:model()
    return Tpl.load(self.settings)
end

-- Campos de um cartão: Frente/Verso para os criados em "＋ Adicionar cartão",
-- o modelo da tela Campos para os outros.
function Vocab2Deck:modelFor(item)
    if Tpl.isManual(item) then return Tpl.manual() end
    return self:model()
end

-- Função item -> campos, para planejar vários cartões de uma vez.
function Vocab2Deck:modelResolver()
    local general = self:model()
    return function(item)
        if Tpl.isManual(item) then return Tpl.manual() end
        return general
    end
end

function Vocab2Deck:setModel(list)
    Tpl.save(self.settings, list)
end

-- Tira um campo do modelo (de todos os cartões). Campo seu: o texto dele some;
-- campo do plugin: as edições ficam guardadas para quando ele voltar.
function Vocab2Deck:removeModelField(id)
    local list = self:model()
    if #list <= 1 then error(_("O cartão precisa de pelo menos um campo."), 0) end
    for i, f in ipairs(list) do
        if f.id == id then
            table.remove(list, i)
            if not Tpl.isBuiltin(f) then self:getStore():dropField(f.id) end
            break
        end
    end
    self:setModel(list)
end

function Vocab2Deck:addModelField(name, side)
    local list = self:model()
    list[#list + 1] = { id = Tpl.newId(list), name = name, side = side, source = "none" }
    self:setModel(list)
end

function Vocab2Deck:getApp()
    if not self.app then self.app = App.new(self) end
    return self.app
end

function Vocab2Deck:apkgPath()
    return DataStorage:getDataDir() .. "/ankiviewer/shared/" .. Apkg.FILE
end

-- Ao fechar o plugin: grava o .apkg se algo mudou no Anki Viewer desde o último
-- pacote ou se o arquivo ainda não existe (ex.: tudo já estava exportado).
function Vocab2Deck:onAppClosed(app)
    if self.app == app then self.app = nil end
    local f = io.open(self:apkgPath(), "rb")
    if f then f:close() end
    if self._apkg_dirty or not f then
        self._apkg_dirty = false
        self:writeApkg()
    end
end

-- Estado do Anki Viewer sem quebrar a interface se o banco tiver problema.
function Vocab2Deck:deckState()
    local ok, state = pcall(DeckWriter.loadState, self:writer())
    if not ok then return { words = {}, cards = {}, status = "error", error = state } end
    return state
end

--[[--
Traz as palavras do Vocabulary Builder para o banco próprio (rápido: sem
dicionário). Palavras novas vão para o Inbox. Resultado em self.last_sync.
--]]
function Vocab2Deck:syncVocab()
    local opts = self.settings:cardOptions()
    local vb, kind, detail = VocabReader.read()
    if not vb then
        self.last_sync = { error = UI.vocabError(kind, detail), added = 0 }
        return self.last_sync
    end
    local state = self:deckState()
    local exported, definitions = {}, {}
    for key in pairs(state.cards) do exported[key:match("^(.*)|[fr]$")] = true end
    for vkey, w in pairs(state.words) do
        if w.definition and w.definition ~= "" then definitions[vkey] = w.definition end
    end
    local skip
    if opts.only_unlearned and vb.has_streak then
        skip = function(w) return VocabReader.isLearned(w, opts.learned_streak) end
    end
    local res = self:getStore():syncFromVocab(vb.words, { exported = exported, definitions = definitions, skip = skip })
    if #vb.words == 0 then
        res.error = _("O Vocabulary Builder está vazio. Consulte palavras no dicionário durante a leitura para que elas cheguem aqui.")
    elseif opts.only_unlearned and not vb.has_streak then
        res.filter_note = _("Filtro 'só não aprendidas' indisponível: este Vocabulary Builder não tem a coluna streak_count.")
    end
    if state.status == "old_schema" or state.status == "bad_schema" then res.error = UI.deckError(state.status) end
    self.last_sync = res
    return res
end

--[[--
Na exportação: um ● Revisado que já tem cartão no Anki Viewer (ex.: saiu do
baralho para ser revisado de novo) não ganha cartão novo; o dele recebe o
texto atual (com o progresso) e o item volta a ✓ No baralho. Sem isso ele
ficaria ● Revisado para sempre. Inbox e Descartados ficam como estão.
@treturn number quantos voltaram ao baralho
--]]
function Vocab2Deck:normalizeStatuses(state)
    state = state or self:deckState()
    local live = {}
    for key, c in pairs(state.cards or {}) do
        if c.card_id then live[key:match("^(.*)|[fr]$")] = true end
    end
    local fix = {}
    for __, r in ipairs(self:getStore():query({ statuses = { ready = true } })) do
        if live[r.vkey] then fix[#fix + 1] = r.vkey end
    end
    if #fix > 0 then
        self:getStore():setStatus(fix, "deck")
        Safe.log("itens com cartão no Anki Viewer marcados como No baralho:", #fix)
    end
    return #fix
end

-- Busca a definição de um item que ainda não foi buscado (uma vez por item).
function Vocab2Deck:ensureLookup(item)
    if item.looked_up == 1 then return item end
    local dict = self.ui and self.ui.dictionary
    if not (dict and dict.startSdcv) then return item end
    local res, err = DictLookup.lookup(dict, item.word, self.settings:cardOptions().max_senses)
    if err then
        Safe.log("busca falhou para", item.word, err)
        return item
    end
    self:getStore():setLookup(item.vkey, res)
    return self:getStore():get(item.vkey) or item
end

function Vocab2Deck:lookupWord(word)
    local dict = self.ui and self.ui.dictionary
    if not (dict and dict.startSdcv) then return nil end
    return (DictLookup.lookup(dict, word, self.settings:cardOptions().max_senses))
end

-- Opções dos cartões, para planejar.
function Vocab2Deck:planOptions(extra)
    local opts = self.settings:cardOptions()
    for k, v in pairs(extra or {}) do opts[k] = v end
    return opts
end

--[[--
O que está pendente para cartões já no baralho.
@treturn table { changed = {…}, deleted = n, new_sides = n }
--]]
function Vocab2Deck:pendingChanges()
    local ok, res = pcall(function()
        local items = self:getStore():all({ statuses = { deck = true } })
        local plan = Sync.plan(items, self:deckState(), self:modelResolver(), self:planOptions())
        local sides = 0
        for __, e in ipairs(plan.new) do sides = sides + #e.sides end
        return { changed = plan.changed, deleted = plan.deleted, new_sides = sides }
    end)
    if not ok then
        Safe.log("pendências:", res)
        return { changed = {}, deleted = 0, new_sides = 0 }
    end
    return res
end

--[[--
Leva para o Anki Viewer, sem pedir, o que mudou nos cartões já no baralho:
texto novo (modelo, definição, contexto) e baralho novo (configurações).
O progresso de revisão fica. Cartões editados fora daqui continuam pedindo
confirmação (botão no Início). Desligado com "Ao exportar, cartões com
conteúdo novo: Perguntar / Ignorar".
@treturn table|nil { updated, moved }
--]]
function Vocab2Deck:autoUpdate()
    local mode = self.settings:get("on_change")
    if mode == "ignore" then return nil end
    local ok, res = pcall(function()
        local state = self:deckState()
        if state.status ~= "ok" then return nil end
        local items = self:getStore():all({ statuses = { deck = true } })
        local plan = Sync.plan(items, state, self:modelResolver(), self:planOptions())
        local ops = { moves = plan.moves, updates = mode == "update" and Sync.updateOps(plan.changed, true) or {} }
        if #ops.moves + #ops.updates == 0 then return nil end
        local r = DeckWriter.apply(self:writer(), ops, { backup_done = self._session_backup })
        self._session_backup = true
        self._apkg_dirty = true
        return { updated = r.updated, moved = r.moved }
    end)
    if not ok then
        Safe.message(T(_("Os cartões no Anki Viewer não foram atualizados:\n%1"), Safe.shortError(res)))
        return nil
    end
    if res then self.last_auto = res end
    return res
end

-- Depois de editar um item já no baralho: o cartão do Anki Viewer recebe o texto novo.
function Vocab2Deck:pushItemToDeck(vkey)
    local item = self:getStore():get(vkey)
    if not item or item.status ~= "deck" then return end
    local ups = Sync.itemUpdates(item, self:deckState(), self:modelResolver(), self:planOptions())
    if #ups == 0 then return end
    local ok, err = pcall(DeckWriter.apply, self:writer(), { updates = ups }, { backup_done = self._session_backup })
    if not ok then
        Safe.message(T(_("O cartão no Anki Viewer não foi atualizado:\n%1"), Safe.shortError(err)))
        return
    end
    self._session_backup = true
    self._apkg_dirty = true
end

-- Telas ------------------------------------------------------------------------------

function Vocab2Deck:openHome()
    self._session_backup = false
    self.last_auto = nil
    self:syncVocab()
    if self.settings:get("auto_export") then
        self:openExport({ autostart = true })
        return
    end
    self:getApp():open("vocab2deck/screens/home", {})
end

-- Revisão do Inbox (ou de um filtro), uma palavra por tela.
function Vocab2Deck:openReview(filter)
    local f = {}
    for k, v in pairs(filter or {}) do f[k] = v end
    f.statuses = { inbox = true }
    local keys = self:getStore():keys(f, "newest")
    if #keys == 0 then
        Safe.message(_("Nada para revisar no Inbox."), 3)
        return
    end
    self:getApp():open("vocab2deck/screens/review", { keys = keys })
end

function Vocab2Deck:openExport(opts)
    self:getApp():open("vocab2deck/screens/export", { autostart = opts and opts.autostart })
end

function Vocab2Deck:openModel()
    self:getApp():open("vocab2deck/screens/model", {})
end

function Vocab2Deck:showSettings()
    UI.showSettings(self, function()
        local top = self.app and self.app:topScreen()
        if top then top:onRevealed() end
    end)
end

function Vocab2Deck:askChanges(changed)
    UI.askChanges(self, changed)
end

function Vocab2Deck:askSearch(app, scope)
    UI.editText(_("Buscar palavras, definições e livros"), "", function(q)
        if not q:match("%S") then return end
        local f = {}
        for k, v in pairs(scope or {}) do f[k] = v end
        f.search = q
        app:open("vocab2deck/screens/items", { filter = f, title = T(_("Busca: %1"), q) })
    end, { multiline = false })
end

-- Exportação -------------------------------------------------------------------------

-- JSON com marcador de array (o Anki exige [] e não {} em alguns campos); mesmo
-- critério do KR2Anki: rapidjson do KOReader, ou o json com array sem marcador.
function Vocab2Deck:jsonCodec()
    if not self._json then
        local ok, rapidjson = pcall(require, "rapidjson")
        if ok then
            self._json = rapidjson
        else
            local JSON = require("json")
            self._json = { encode = JSON.encode, decode = JSON.decode, null = JSON.util and JSON.util.null,
                           array = function(t) return t end }
        end
    end
    return self._json
end

local function sha1()
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha1 then return sha2.sha1 end
    return require("vocab2deck/lib/sha1")
end

--[[--
Passo da exportação: grava <dados>/ankiviewer/shared/Vocab2Deck.apkg com todos
os cartões que estão no baralho (retrato completo a cada exportação), em
"Vocab2Deck::Título do livro". Sem interface: só um aviso no resultado se falhar.
@treturn string|nil caminho gravado, string|nil erro
--]]
function Vocab2Deck:writeApkg()
    local ok, path, err = pcall(function()
        local state = self:deckState()
        if state.status ~= "ok" then return nil end
        -- no Anki o verso já mostra a frente ({{FrontSide}}): aqui o verso não a repete
        local opts = self:planOptions({ front_on_back = false })
        local model = self:modelResolver()
        local notes = {}
        -- todo cartão do plugin que existe no Anki Viewer (menos de itens descartados)
        for __, item in ipairs(self:getStore():all({ statuses = { inbox = true, ready = true, deck = true } })) do
            local rendered = Sync.renderItem(item, model, opts)
            for __, side in ipairs({ "f", "r" }) do
                local c = state.cards[item.vkey .. "|" .. side]
                if c and c.card_id then
                    notes[#notes + 1] = { key = B.sourceKey(item.vkey, side), book = item.book,
                                          front = rendered[side].front, back = rendered[side].back }
                end
            end
        end
        if #notes == 0 then
            Safe.log("pacote .apkg não gravado: nenhum cartão no baralho")
            return nil
        end
        local dir = DataStorage:getDataDir() .. "/ankiviewer/shared"
        require("util").makePath(dir)
        local dest = self:apkgPath()
        local wok, werr = Apkg.write{
            path = dest, notes = notes, sqlite = require("lua-ljsqlite3/init"), json = self:jsonCodec(),
            sha1 = sha1(), tmpdir = DataStorage:getSettingsDir(),
        }
        if not wok then return nil, werr end
        return dest
    end)
    if not ok then path, err = nil, path end
    if err then Safe.log("pacote .apkg falhou:", err) end
    return path, err
end

--[[--
Exporta os Revisados (e, com include_inbox, o Inbox). Mostra o progresso com
o Trapper (tocar interrompe) e chama on_done(resultado).
--]]
function Vocab2Deck:runExport(opts, on_done)
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local result = Safe.run(_("exportação"), self._export, self, Trapper, opts or {})
        Trapper:clear()
        if not result then return end
        if on_done then on_done(result) end
        if #result.changes_pending > 0 then UI.askChanges(self, result.changes_pending) end
    end)
end

function Vocab2Deck:_export(Trapper, run_opts)
    local status = self:writer():check()
    if status == "old_schema" or status == "bad_schema" then
        return { error = UI.deckError(status), changes_pending = {} }
    end
    local store = self:getStore()
    local model = self:modelResolver()
    local opts = self:planOptions({ include_inbox = run_opts.include_inbox })
    local state = self:deckState()
    local plan = Sync.plan(store:all(), state, model, opts)
    local summary = {
        added = 0, items = 0, updated = 0, skipped_nodef = 0, lookup_errors = 0, aborted = false, remaining = 0,
        edited_kept = 0, changes_pending = {},
    }

    -- 1. definição dos itens que ainda não foram buscados no dicionário
    local dict = self.ui and self.ui.dictionary
    local processed = {}
    local total = #plan.new
    for i, e in ipairs(plan.new) do
        if i == 1 or i % PROGRESS_EVERY == 0 or i == total then
            local go_on = Trapper:info(T(_("Exportando %1 de %2…"), i, total) .. "\n\n" .. e.item.word
                .. "\n\n" .. _("Toque para interromper."))
            if not go_on then
                summary.aborted = true
                summary.remaining = total - i + 1
                break
            end
        end
        local keep = true
        if e.needs_lookup then
            if not (dict and dict.startSdcv) then
                summary.lookup_errors = summary.lookup_errors + 1
                keep = false
            else
                local res, err = DictLookup.lookup(dict, e.item.word, opts.max_senses)
                if err then
                    -- falha da busca (não é "sem definição"): não grava, tenta na próxima vez
                    Safe.log("busca falhou para", e.item.word, err)
                    summary.lookup_errors = summary.lookup_errors + 1
                    keep = false
                else
                    store:setLookup(e.item.vkey, res)
                    e.item = store:get(e.item.vkey)
                end
            end
        end
        if keep then processed[#processed + 1] = e end
    end

    -- 2. operações: cartões novos + (conforme a configuração) cartões alterados
    local ops, stats = Sync.insertOps(processed, model, opts)
    summary.skipped_nodef = stats.skipped_nodef
    local on_change = self.settings:get("on_change")
    -- ● Revisados que já têm cartão: você pediu para exportar de novo, então o
    -- cartão recebe o texto atual (o progresso fica); os outros seguem a configuração
    local resent, others = {}, {}
    for __, c in ipairs(plan.changed) do
        if c.item.status == "ready" then resent[#resent + 1] = c else others[#others + 1] = c end
    end
    ops.updates = Sync.updateOps(resent, false)
    if #others > 0 then
        if on_change == "update" then
            for __, u in ipairs(Sync.updateOps(others, true)) do ops.updates[#ops.updates + 1] = u end
            for __, c in ipairs(others) do if c.edited then summary.edited_kept = summary.edited_kept + 1 end end
        elseif on_change ~= "ignore" then
            summary.changes_pending = others
        end
    end
    if on_change ~= "ignore" then ops.moves = plan.moves end

    -- 3. gravação (backup + uma transação); só depois os itens viram ✓ No baralho
    if #ops.inserts + #(ops.updates or {}) + #(ops.moves or {}) > 0 then
        Trapper:info(_("Gravando no Anki Viewer…"))
        local ok, res = pcall(DeckWriter.apply, self:writer(), ops)
        if not ok then
            return { error = T(_("Erro ao gravar no Anki Viewer:\n%1\n\nNada foi alterado: a gravação é feita de uma vez só."),
                Safe.shortError(res)), changes_pending = {} }
        end
        store:setStatus(stats.vkeys, "deck")
        summary.added = res.added + res.adopted
        summary.updated = res.updated
        summary.items = stats.items
        summary.backup = res.backup
        self._session_backup = true
    end
    -- ● Revisados que já tinham cartão voltam a ✓ No baralho
    summary.resent = self:normalizeStatuses(self:deckState())

    -- 4. pacote para o Anki (ankiviewer/shared/Vocab2Deck.apkg); falhar aqui não desfaz nada
    local apkg_path, apkg_err = self:writeApkg()
    self._apkg_dirty = false
    summary.apkg = apkg_path
    summary.apkg_error = apkg_err and Safe.shortError(apkg_err) or nil
    return summary
end

--[[--
"Sincronizar com o Anki Viewer" (Início): manda de novo os itens ✓ No baralho.
* cartão que existe: recebe o texto atual (inclusive os editados fora daqui);
  ease/interval/due/reps/lapses não são tocados
* cartão que sumiu do Anki Viewer (apagado lá): é criado de novo, como novo
* cartão fora do baralho das configurações: é movido (o progresso vai junto)
Depois regrava o Vocab2Deck.apkg.
--]]
function Vocab2Deck:syncDeck()
    local msg = UI.busy(_("Sincronizando com o Anki Viewer…"))
    local ok, res = pcall(function()
        local status = self:writer():check()
        if status == "old_schema" or status == "bad_schema" then error(UI.deckError(status), 0) end
        if status == "ok" then self:writer():forgetDeleted() end
        local state = self:deckState()
        local model, opts = self:modelResolver(), self:planOptions()
        local items = self:getStore():all({ statuses = { deck = true } })
        local plan = Sync.plan(items, state, model, opts)
        local ops = Sync.insertOps(plan.new, model, opts)
        ops.updates = Sync.syncUpdates(items, state, model, opts)
        ops.moves = plan.moves
        local r = DeckWriter.apply(self:writer(), ops, { backup_done = self._session_backup })
        self._session_backup = true
        local apkg, apkg_err = self:writeApkg()
        self._apkg_dirty = false
        return { created = r.added + r.adopted, updated = r.updated, moved = r.moved, total = #items,
                 apkg = apkg, apkg_err = apkg_err }
    end)
    UIManager:close(msg)
    if not ok then
        Safe.message(T(_("A sincronização falhou; nada foi alterado:\n%1"), Safe.shortError(res)))
        return
    end
    local lines = { T(_("%1 palavras no baralho sincronizadas."), res.total) }
    if res.updated > 0 then lines[#lines + 1] = T(_("%1 cartões com texto atualizado."), res.updated) end
    if res.created > 0 then lines[#lines + 1] = T(_("%1 cartões que faltavam foram criados."), res.created) end
    if res.moved > 0 then lines[#lines + 1] = T(_("%1 cartões movidos para o baralho certo."), res.moved) end
    if res.updated + res.created + res.moved == 0 then lines[#lines + 1] = _("Tudo já estava igual.") end
    lines[#lines + 1] = _("O agendamento dos cartões no Anki Viewer não mudou.")
    if res.apkg_err then lines[#lines + 1] = T(_("O pacote Vocab2Deck.apkg não foi gravado: %1"), Safe.shortError(res.apkg_err)) end
    Safe.message(table.concat(lines, "\n"), 6)
    local top = self.app and self.app:topScreen()
    if top then top:onRevealed() end
end

-- Atualiza o texto de cartões alterados (progresso mantido).
function Vocab2Deck:applyUpdates(changed, only_unedited)
    local ups = Sync.updateOps(changed, only_unedited)
    if #ups == 0 then return end
    local msg = UI.busy(_("Gravando no Anki Viewer…"))
    local ok, res = pcall(DeckWriter.apply, self:writer(), { updates = ups })
    UIManager:close(msg)
    if not ok then
        Safe.message(T(_("Erro ao gravar no Anki Viewer:\n%1\n\nNada foi alterado."), Safe.shortError(res)))
        return
    end
    self._apkg_dirty = true
    Safe.message(T(_("%1 cartões atualizados. O progresso de revisão foi mantido."), res.updated), 4)
    local top = self.app and self.app:topScreen()
    if top then top:onRevealed() end
end

-- Busca de novo, nos dicionários, as palavras já no baralho e guarda as definições que mudaram.
function Vocab2Deck:checkDefinitions()
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local changed = Safe.run(_("verificar definições"), function()
            local dict = self.ui and self.ui.dictionary
            if not (dict and dict.startSdcv) then
                Safe.message(_("O dicionário do KOReader não está disponível agora."))
                return nil
            end
            local store = self:getStore()
            local items = store:all({ statuses = { deck = true } })
            for i, it in ipairs(items) do
                if i == 1 or i % PROGRESS_EVERY == 0 or i == #items then
                    if not Trapper:info(T(_("Verificando %1 de %2…"), i, #items) .. "\n\n" .. _("Toque para interromper.")) then
                        break
                    end
                end
                local res = DictLookup.lookup(dict, it.word, self.settings:cardOptions().max_senses)
                -- só troca quando achou uma definição; nunca apaga a guardada
                if res and res.definition ~= it.definition then store:setLookup(it.vkey, res) end
            end
            return self:pendingChanges().changed
        end)
        Trapper:clear()
        if not changed then return end
        if #changed == 0 then
            Safe.message(_("Nenhum cartão precisa de atualização."), 4)
        else
            UI.askChanges(self, changed)
        end
    end)
end

function Vocab2Deck:forgetDeleted()
    local n = Safe.run(_("recriar cartões"), function() return self:writer():forgetDeleted() end)
    if n == nil then return end
    if n == 0 then
        Safe.message(_("Nenhum cartão foi apagado no Anki Viewer."), 3)
    else
        Safe.message(T(_("%1 cartões serão recriados na próxima exportação."), n), 4)
    end
end

-- Estudo (Anki Viewer embutido) -----------------------------------------------------

-- Anki Viewer embutido, criado na primeira vez (mesmas configurações do original).
function Vocab2Deck:getViewer()
    if not self.viewer and AnkiViewer then
        self.viewer = AnkiViewer:new{ ui = self.ui }
    end
    return self.viewer
end

function Vocab2Deck:studyNow()
    local av = self:getViewer()
    if not av then
        Safe.message(_("A tela de estudo não carregou (veja o crash.log do KOReader)."))
        return
    end
    local function open(deck)
        Safe.run(_("abrir o estudo"), function()
            if self.app then self.app:closeAll() end
            -- a tela de estudo abre no último baralho usado (setting last_deck_id)
            if deck then av:saveSetting("last_deck_id", deck.id) end
            if av.screen and av.screen.onClose then av.screen:onClose() end
            av:showLocalStudy()
        end)
    end
    local decks = Safe.run(_("listar baralhos"), function() return self:writer():ourDecks() end)
    if not decks then return end
    if #decks == 0 then
        -- nada exportado ainda: abre como o Anki Viewer abria (último baralho, Import, Decks)
        open(nil)
    elseif #decks == 1 then
        open(decks[1])
    else
        UI.chooseDeck(decks, open)
    end
end

return Vocab2Deck
