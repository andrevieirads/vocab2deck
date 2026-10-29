-- Testes no computador: lua tests/run.lua <pasta temporária> <pasta do ankiviewer.koplugin>
-- (use tests/run_tests.sh, que define o tamanho da tela).
--
-- Rodam o plugin de verdade (main.lua, telas, store, …) sobre os widgets de
-- mentira do KR2Anki (uistubs.lua: layout, toques e deslizes), e o
-- ankiviewer_db.lua REAL do Anki Viewer sobre o mesmo banco, para provar que
-- ele lê o que gravamos e que o progresso de revisão é mantido.
-- Com SNAP_DIR definido, salva um SVG de cada tela principal.

local TMP, AV_DIR = arg[1], arg[2]
assert(TMP and AV_DIR, "uso: lua tests/run.lua <tmp> <ankiviewer.koplugin>")
local HERE = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PLUGIN = HERE .. "/../vocab2deck.koplugin"
package.path = PLUGIN .. "/?.lua;" .. HERE .. "/support/?.lua;" .. package.path
unpack = unpack or table.unpack -- luacheck: ignore (uistubs usa o unpack global)

local env = dofile(HERE .. "/support/uistubs.lua")
local Shim = require("sq3_shim")
local Stubs = require("stubs")
Shim.start(TMP)
Stubs.install{ data_dir = TMP .. "/data", settings_dir = TMP .. "/data/settings" }
local SNAP = os.getenv("SNAP_DIR")
local svg
if SNAP and SNAP ~= "" then
    svg = dofile(HERE .. "/support/svgrender.lua")
    svg.install()
end

-- mini framework ----------------------------------------------------------------------
local passed, failed = 0, 0
local current = ""
local function check(cond, msg)
    if cond then passed = passed + 1 else
        failed = failed + 1
        io.stderr:write("  FALHOU [" .. current .. "] " .. msg .. "\n")
    end
end
local function eq(a, b, msg) check(a == b, msg .. " (esperado " .. tostring(b) .. ", veio " .. tostring(a) .. ")") end
local function contains(hay, needle) return hay ~= nil and tostring(hay):find(needle, 1, true) ~= nil end
local function has(needle)
    for _, t in ipairs(texts()) do if contains(t, needle) then return true end end
    return false
end
local function screenText() return table.concat(texts(), " | ") end
local function snap(name)
    if svg then
        local f = io.open(SNAP .. "/" .. name .. ".svg", "w")
        f:write(svg.render(paintTop(), env.W, env.H))
        f:close()
    end
end
local function noOffscreen(where)
    local bad = offscreen()
    check(#bad == 0, where .. ": texto fora da tela: " .. table.concat(bad, "; "))
    if _G.OVERFLOWS and #_G.OVERFLOWS > 0 then
        check(false, where .. ": conteúdo maior que a caixa: " .. table.concat(_G.OVERFLOWS, "; "))
    end
    _G.OVERFLOWS = {}
end
local function scenario(name, fn)
    current = name
    print("• " .. name)
    Stubs.reset()
    UIM.stack = {}
    _G.LAST_infomessage, _G.LAST_buttondialog, _G.LAST_inputdialog, _G.LAST_confirmbox = nil, nil, nil, nil
    _G.OVERFLOWS = {}
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then failed = failed + 1; io.stderr:write("  ERRO [" .. name .. "] " .. tostring(err) .. "\n") end
end
local function info() return _G.LAST_infomessage and _G.LAST_infomessage.text end
-- avança as páginas da tela até `text` aparecer
local function findOnPages(text)
    local guard = 0
    while not has(text) and guard < 10 do
        local scr = UIM:top()
        if not scr.page or not scr.pages or scr.page >= scr.pages then break end
        swipe("west")
        guard = guard + 1
    end
    return has(text)
end
-- toca na última ocorrência de um texto na tela
local function tapLast(pattern)
    local n = 0
    for _, t in ipairs(texts()) do if tostring(t):find(pattern) then n = n + 1 end end
    return tapText(pattern, n)
end

-- ambiente -----------------------------------------------------------------------------
local SQ3 = require("lua-ljsqlite3/init")
local run_id = 0
local function freshEnv()
    run_id = run_id + 1
    local data = TMP .. "/env" .. run_id
    os.execute("mkdir -p '" .. data .. "/settings'")
    Stubs.data_dir = data
    Stubs.settings_dir = data .. "/settings"
    return data
end

-- Banco do Vocabulary Builder igual ao do KOReader (colunas usadas pelo KR2Anki + streak_count).
local function makeVocab(data, words, opts)
    opts = opts or {}
    local conn = SQ3.open(data .. "/settings/vocabulary_builder.sqlite3")
    conn:exec([[CREATE TABLE IF NOT EXISTS vocabulary (word TEXT NOT NULL UNIQUE PRIMARY KEY, title_id INTEGER,
        create_time INTEGER NOT NULL, review_time INTEGER, due_time INTEGER NOT NULL DEFAULT 0,
        review_count INTEGER NOT NULL DEFAULT 0, prev_context TEXT, next_context TEXT,
        streak_count INTEGER NOT NULL DEFAULT 0, highlight TEXT)]])
    conn:exec("CREATE TABLE IF NOT EXISTS title (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, filter INTEGER NOT NULL DEFAULT 1)")
    for i, w in ipairs(words) do
        local title_id
        if w.book then
            local st = conn:prepare("INSERT OR IGNORE INTO title (name) VALUES (?)")
            st:bind(w.book); st:step(); st:close()
            local st2 = conn:prepare("SELECT id FROM title WHERE name = ?")
            st2:bind(w.book); title_id = st2:step()[1]; st2:close()
        end
        local st = conn:prepare("INSERT OR REPLACE INTO vocabulary (word, title_id, create_time, prev_context, next_context, streak_count, highlight) VALUES (?, ?, ?, ?, ?, ?, ?)")
        st:bind(w.word, title_id, 1000 + i, w.prev, w.next, w.streak or 0, w.highlight)
        st:step(); st:close()
    end
    conn:close()
end

local function avDbPath(data) return data .. "/ankiviewer/ankiviewer.sqlite3" end

-- Carrega o ankiviewer_db.lua real (cada dofile zera o "initialized" interno).
local function loadAV()
    return dofile(AV_DIR .. "/ankiviewer_db.lua")
end

local function scalar(data, sql)
    local conn = SQ3.open(avDbPath(data))
    local v = conn:rowexec(sql)
    conn:close()
    return v
end

-- Dicionário falso: ReaderDictionary:startSdcv(word, dict_names, fuzzy) -> resultados
local function fakeDict(defs, fail)
    return {
        lookups = 0,
        startSdcv = function(self, word)
            self.lookups = self.lookups + 1
            if fail and fail[word] then error("sdcv quebrou") end
            local d = defs[word]
            if not d then return { { no_result = true, dict = "", word = word, definition = "" } } end
            return { { dict = "Teste EN-PT", word = word, definition = d } }
        end,
    }
end

local function fakeAV()
    local av = { settings = {}, opened = 0 }
    function av:saveSetting(k, v) self.settings[k] = v end
    function av:readSetting(k) return self.settings[k] end
    function av:showLocalStudy() self.opened = self.opened + 1 end
    return av
end

local Plugin = dofile(PLUGIN .. "/main.lua")
local registered
local function newPlugin(dict, av, extra)
    local ui = { menu = { registerToMainMenu = function(_, x) registered = x end }, dictionary = dict, ankiviewer = av }
    for k, v in pairs(extra or {}) do ui[k] = v end
    return Plugin:new{ ui = ui, path = PLUGIN }
end

-- Leitor falso: ReaderHighlight (menu da seleção) e documento com título.
local function fakeReader()
    local hl = { buttons = {}, closed = 0 }
    function hl:addToHighlightDialog(key, fn) self.buttons[key] = fn end
    function hl:getSelectedWordContext() return self.ctx_prev, self.ctx_next end
    function hl:onClose() self.closed = self.closed + 1; self.selected_text = nil end
    function hl:clear() self.selected_text = nil end
    return {
        highlight = hl,
        document = { file = "/mnt/us/books/Dom Quixote.epub" },
        doc_props = { display_title = "Dom Quixote" },
    }
end

local WORDS = {
    { word = "serendipity", book = "Livro A", prev = "It was pure ", next = " that we met. Then we left.", highlight = "serendipity" },
    { word = "ephemeral", book = "Livro A", prev = "The joy was ", next = " and fleeting.", streak = 7 },
    { word = "quixotic", book = "Livro B", prev = "A ", next = " plan, doomed from the start." },
}
local DEFS = {
    serendipity = "1. the faculty of making fortunate discoveries by accident<br>2. luck<br>3. a happy chance",
    ephemeral = "<b>adj.</b> lasting a very short time",
    quixotic = "exceedingly idealistic; unrealistic and impractical",
}

local function sched(data, id)
    return scalar(data, "SELECT ease || '|' || interval || '|' || due || '|' || reps FROM cards WHERE id = " .. id)
end

-- cenários -----------------------------------------------------------------------------

scenario("registro: menu e quatro ações de gesto", function()
    freshEnv()
    newPlugin(fakeDict(DEFS), fakeAV())
    local items = {}
    registered:addToMainMenu(items)
    eq(items.vocab2deck.text, "Vocabulário → Flashcards", "texto do menu")
    eq(items.vocab2deck.sorting_hint, "tools", "menu em Ferramentas")
    for _, id in ipairs({ "vocab2deck_open", "vocab2deck_triage", "vocab2deck_export", "vocab2deck_review" }) do
        check(DISPATCHER_ACTIONS[id] ~= nil, "ação " .. id)
    end
end)

scenario("Vocabulary Builder ausente e vazio: aviso no Início", function()
    local data = freshEnv()
    local p = newPlugin(fakeDict(DEFS), fakeAV())
    p:onVocab2DeckOpen()
    check(has("não foi encontrado"), "ausente: " .. screenText())
    makeVocab(data, {})
    UIM.stack = {}
    p:onVocab2DeckOpen()
    check(has("está vazio"), "vazio: " .. screenText())
    check(io.open(avDbPath(data)) == nil, "nada criado no Anki Viewer")
end)

local S = {}

scenario("Início → Revisar: um por tela, escolher sentido, Revisado / Pular / Descartar", function()
    local data = freshEnv()
    S.data = data
    makeVocab(data, WORDS)
    S.dict = fakeDict(DEFS)
    S.av = fakeAV()
    S.p = newPlugin(S.dict, S.av)
    S.p:onVocab2DeckOpen()
    check(has("Inbox") and has("Revisados") and has("No baralho"), "status no Início: " .. screenText())
    check(has("3 palavras novas vieram do Vocabulary Builder"), "aviso das palavras novas")
    eq(S.dict.lookups, 0, "abrir não busca no dicionário")
    noOffscreen("início")
    snap("1_inicio")

    tapText("^Revisar %(3%)")
    check(has("Revisar 1 / 3"), "revisão aberta: " .. screenText())
    eq(S.dict.lookups, 1, "uma busca, só da palavra na tela")
    check(has("quixotic") and has("ESCOLHA O SENTIDO"), "palavra e sentidos")
    noOffscreen("revisão")
    tapText("✓ Revisado")
    -- ephemeral
    check(has("Revisar 2 / 3") and has("ephemeral"), "segunda palavra: " .. screenText())
    swipe("west") -- pular
    -- serendipity: três sentidos; escolhe o 2
    check(has("serendipity") and has("2. luck"), "sentidos de serendipity: " .. screenText())
    snap("2_revisao")
    tapText("^2%. luck")
    check(has("serendipity"), "continua no item após escolher")
    tapText("✓ Revisado")
    check(has("Revisão concluída") and has("2 Revisados · 0 Descartados · 1 pulados"), "resumo: " .. screenText())
    swipe("east") -- volta e muda a decisão
    check(has("serendipity"), "voltou ao item anterior")
    swipe("west")
    tapText("^Exportar %(2%)")
    check(has("revisados prontos para exportar"), "pré-checagem: " .. screenText())
    snap("3_exportar")
    tapText("^Exportar %(2%)")
    check(has("2 cartões novos adicionados."), "resultado: " .. screenText())
    snap("4_resultado")

    local AV = loadAV()
    AV.init()
    local decks = AV.listDecks()
    eq(#decks, 1, "um baralho")
    eq(decks[1].card_count, 2, "2 cartões vistos pelo Anki Viewer")
    eq(tonumber(scalar(data, "PRAGMA user_version")), 4, "user_version 4")
    local front = scalar(data, "SELECT front FROM cards WHERE source_key = 'vocab2deck:f:w:serendipity'")
    local back = scalar(data, "SELECT back FROM cards WHERE source_key = 'vocab2deck:f:w:serendipity'")
    check(contains(front, "serendipity") and contains(front, "“It was pure serendipity that we met.”"), "frente: " .. tostring(front))
    eq(back:sub(1, #front), front, "verso repete a frente")
    check(contains(back, "luck") and not contains(back, "faculty"), "só o sentido escolhido: " .. back)
    check(contains(back, "— Livro A"), "livro no verso")
    eq(S.p:getStore():counts().deck, 2, "2 itens ✓ No baralho")
    eq(S.p:getStore():counts().inbox, 1, "o pulado segue no Inbox")

    tapText("Estudar no Anki Viewer")
    eq(S.av.opened, 1, "Anki Viewer aberto")
    eq(S.av.settings.last_deck_id, decks[1].id, "no baralho certo")
    S.deck_id = decks[1].id
end)

scenario("editor de campos: editar, campo extra, pré-visualizar; progresso mantido", function()
    local p, data = S.p, S.data
    local id = tonumber(scalar(data, "SELECT id FROM cards WHERE source_key = 'vocab2deck:f:w:quixotic'"))
    local AV = loadAV()
    AV.updateCardScheduling({ id = id, ease = 2.5, interval = 0, reps = 0, lapses = 0 }, "easy", os.time(), 0)
    local before = sched(data, id)

    p:onVocab2DeckOpen()
    tapText("^No baralho")
    check(has("quixotic") and has("serendipity"), "lista No baralho: " .. screenText())
    noOffscreen("lista")
    snap("5_lista")
    tapText("^quixotic")
    check(has("Editar"), "item aberto: " .. screenText())
    tapText("Campos do cartão")
    check(has("Palavra") and has("Frase") and has("Definição") and has("Livro"), "campos: " .. screenText())
    noOffscreen("editor")
    snap("6_editor")

    -- editar a definição
    tapText("exceedingly idealistic")
    LAST_inputdialog._input = "idealista ao extremo (minha definição)"
    pressDialogButton(LAST_inputdialog, "Salvar")
    check(has("idealista ao extremo"), "valor novo na tela")
    check(has("editado"), "marcado como editado")
    local back = scalar(data, "SELECT back FROM cards WHERE id = " .. id)
    check(contains(back, "idealista ao extremo"), "cartão do Anki Viewer atualizado: " .. back)
    eq(sched(data, id), before, "agendamento intacto depois de editar")

    -- campo só deste cartão
    tapText("^%+ Campo")
    pressDialogButton(LAST_buttondialog, "Só neste cartão")
    LAST_inputdialog._input = "Exemplo"
    pressDialogButton(LAST_inputdialog, "Salvar")
    pressDialogButton(LAST_buttondialog, "Verso")
    LAST_inputdialog._input = "a quixotic quest for perfection"
    pressDialogButton(LAST_inputdialog, "Salvar")
    check(findOnPages("Exemplo") and has("só neste cartão"), "campo extra na tela: " .. screenText())
    back = scalar(data, "SELECT back FROM cards WHERE id = " .. id)
    check(contains(back, "a quixotic quest for perfection"), "campo extra no verso")
    eq(sched(data, id), before, "agendamento intacto depois do campo extra")
    snap("7_editor_extra")

    tapText("Pré%-visualizar")
    check(contains(LAST_textviewer.text, "FRENTE") and contains(LAST_textviewer.text, "a quixotic quest"), "pré-visualização")
    UIM:close(LAST_textviewer)

    -- campo extra na frente; depois oculto
    tapLast("⋯")
    pressDialogButton(LAST_buttondialog, "Lado: não vai para o cartão")
    back = scalar(data, "SELECT back FROM cards WHERE id = " .. id)
    check(not contains(back, "a quixotic quest"), "campo oculto sai do cartão")
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM cards")), 2, "sem duplicar")
end)

scenario("modelo: novo campo para todos e ocultar Livro → atualizar sem perder progresso", function()
    local p, data = S.p, S.data
    local id = tonumber(scalar(data, "SELECT id FROM cards WHERE source_key = 'vocab2deck:f:w:quixotic'"))
    local before = sched(data, id)
    p:onVocab2DeckOpen()
    tapText("^Campos$")
    check(has("Palavra") and has("Definição") and not has("Repetir a frente no verso"), "modelo: " .. screenText())
    noOffscreen("modelo")
    snap("8_modelo")
    tapText("^Livro$")
    pressDialogButton(LAST_buttondialog, "Não mostrar")
    tapText("^%+ Campo")
    LAST_inputdialog._input = "Sinônimos"
    pressDialogButton(LAST_inputdialog, "Salvar")
    pressDialogButton(LAST_buttondialog, "Verso")
    check(has("Sinônimos"), "campo novo no modelo")
    tapText("‹")
    check(has("2 cartões atualizados no Anki Viewer"), "Início atualiza sozinho: " .. screenText())
    local back = scalar(data, "SELECT back FROM cards WHERE id = " .. id)
    check(not contains(back, "— Livro B"), "livro saiu do verso: " .. back)
    eq(sched(data, id), before, "agendamento intacto")
    check(not has("cartões alterados"), "nada mais pendente")
end)

scenario("segunda exportação sem novos: nada duplica; os dois sentidos", function()
    local p, data = S.p, S.data
    p:onVocab2DeckOpen()
    tapText("^Exportar %(0%)")
    check(has("Exportar (0)"), "nada para exportar")
    tapText("^Cancelar")
    p.settings:set("direction", "both")
    UIM.stack = {}
    p:onVocab2DeckExport()
    check(has("+ 2 cartões inversos"), "inversos pendentes: " .. screenText())
    tapText("^Exportar %(2%)")
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM cards")), 4, "2 inversos")
    local rfront = scalar(data, "SELECT front FROM cards WHERE source_key = 'vocab2deck:r:w:serendipity'")
    check(contains(rfront, "luck") and not contains(rfront, "serendipity"), "inverso: verso vira frente: " .. tostring(rfront))
    p.settings:set("direction", "forward")
end)

scenario("cartão apagado no Anki Viewer não volta (até pedir)", function()
    local p, data = S.p, S.data
    local AV = loadAV()
    AV.deleteCard(tonumber(scalar(data, "SELECT id FROM cards WHERE source_key = 'vocab2deck:f:w:serendipity'")))
    p:onVocab2DeckOpen()
    check(has("1 cartões apagados no Anki Viewer"), "aviso: " .. screenText())
    p:forgetDeleted()
    check(contains(info(), "1 cartões serão recriados"), "aviso de recriação")
    UIM.stack = {}
    p:onVocab2DeckExport()
    tapText("^Exportar %(1%)")
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM cards WHERE source_key = 'vocab2deck:f:w:serendipity'")), 1, "recriado")
end)

scenario("Inbox como está, sem definição pula, falha e interrupção", function()
    local data = freshEnv()
    local many = { { word = "zyzzyva", prev = "a ", next = " b" } }
    local defs = {}
    for i = 1, 12 do many[#many + 1] = { word = "w" .. i, prev = "x ", next = " y" }; defs["w" .. i] = "def " .. i end
    makeVocab(data, many)
    local p = newPlugin(fakeDict(defs, { w2 = true }), fakeAV())
    p:onVocab2DeckOpen()
    tapText("^Exportar %(0%)")
    tapText("Também enviar os 13 do Inbox")
    check(has("Exportar (13)"), "checkbox inclui o Inbox: " .. screenText())
    Stubs.trapper_abort_at = 2 -- toca na tela no segundo aviso de progresso (item 5)
    tapText("^Exportar %(13%)")
    check(has("Interrompido"), "interrupção: " .. screenText())
    check(has("Busca no dicionário falhou"), "falha listada")
    local n = tonumber(scalar(data, "SELECT COUNT(*) FROM cards"))
    check(n >= 2 and n <= 3, "gravou as já processadas (veio " .. n .. ")")
    Stubs.trapper_abort_at = nil
    p.ui.dictionary = fakeDict(defs)
    UIM.stack = {}
    p:onVocab2DeckExport()
    tapText("Também enviar os")
    tapText("^Exportar %(")
    check(has("Sem definição"), "zyzzyva pulada sem definição: " .. screenText())
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM cards")), 12, "as 12 com definição")
    eq(p:getStore():get("w:zyzzyva").status, "inbox", "a sem definição fica no Inbox")
end)

scenario("migração da versão 1: cartões antigos viram ✓ No baralho", function()
    local data = freshEnv()
    makeVocab(data, WORDS)
    -- grava como a versão 1 gravava (definição em vocab2deck_words, cartão controlado)
    local W = require("vocab2deck/deck_writer").new()
    W:apply({
        words = { { vkey = "w:quixotic", word = "quixotic", definition = "velha definição", dict = "X" } },
        inserts = { { vkey = "w:quixotic", side = "f", deck_name = "Vocabulary Builder",
                      source_key = "vocab2deck:f:w:quixotic", front = "quixotic", back = "velha definição" } },
    })
    local p = newPlugin(fakeDict(DEFS), fakeAV())
    p:onVocab2DeckOpen()
    eq(p:getStore():get("w:quixotic").status, "deck", "status No baralho")
    eq(p:getStore():get("w:quixotic").definition, "velha definição", "definição da v1 aproveitada")
    check(has("1 cartões atualizados no Anki Viewer"), "cartão antigo atualizado sozinho: " .. screenText())
    local back = scalar(data, "SELECT back FROM cards WHERE source_key = 'vocab2deck:f:w:quixotic'")
    check(back:sub(1, 8) == "quixotic", "verso antigo agora repete a frente: " .. back)
    eq(p:getStore():counts().inbox, 2, "as outras no Inbox")
end)

scenario("só não aprendidas e subbaralho por livro", function()
    local data = freshEnv()
    makeVocab(data, WORDS)
    local p = newPlugin(fakeDict(DEFS), fakeAV())
    p.settings:set("only_unlearned", true)
    p.settings:set("subdeck_per_book", true)
    p:onVocab2DeckOpen()
    eq(p:getStore():counts().inbox, 2, "ephemeral (streak 7) não entrou")
    p:getStore():setStatus({ "w:serendipity", "w:quixotic" }, "ready")
    UIM.stack = {}
    p:onVocab2DeckExport()
    tapText("^Exportar %(2%)")
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM decks WHERE name IN ('Livro A','Livro B')")), 2, "um baralho com o título de cada livro")
    p:studyNow()
    check(LAST_buttondialog and contains(LAST_buttondialog.title, "Qual baralho"), "escolha de baralho")
    pressDialogButton(LAST_buttondialog, "Livro B")
    eq(p.ui.ankiviewer.opened, 1, "abriu")
end)

scenario("caso do aparelho: definição escrita à mão, modelo mudado, cartão antigo e baralho antigo", function()
    local data = freshEnv()
    makeVocab(data, {
        { word = "evolving", book = "Databricks Guide" },                     -- sem contexto, sem definição
        { word = "demands", book = "Databricks Guide", prev = "The ", next = " grew." },
    })
    local defs = { demands = "1. economics: amount a consumer is willing to buy<br>2. desire to purchase" }
    -- cartão como a versão 1.0.0 gravava: verso sem a frente, no baralho "Vocabulary Builder::Livro"
    local W = require("vocab2deck/deck_writer").new()
    W:apply({
        words = { { vkey = "w:demands", word = "demands", definition = "1. economics: amount a consumer is willing to buy" } },
        inserts = { { vkey = "w:demands", side = "f", deck_name = "Vocabulary Builder::Databricks Guide",
                      source_key = "vocab2deck:f:w:demands", front = "demands",
                      back = "1. economics: amount a consumer is willing to buy" } },
    })
    local id = tonumber(scalar(data, "SELECT id FROM cards WHERE source_key = 'vocab2deck:f:w:demands'"))
    loadAV().updateCardScheduling({ id = id, ease = 2.5, interval = 0, reps = 0, lapses = 0 }, "good", os.time(), 0)
    local before = sched(data, id)

    local p = newPlugin(fakeDict(defs), fakeAV())
    p.settings:set("subdeck_per_book", true)
    -- o modelo do aparelho: Frase no verso, Livro oculto
    local model = require("vocab2deck/template").defaults()
    model[2].side = "back"
    model[4].side = "none"
    p:setModel(model)
    p:onVocab2DeckOpen()
    check(has("1 cartões atualizados no Anki Viewer") and has("1 cartões movidos"), "atualizou e moveu sozinho: " .. screenText())
    local back = scalar(data, "SELECT back FROM cards WHERE id = " .. id)
    check(back:sub(1, 7) == "demands" and contains(back, "――――――"), "verso mostra a frente, o traço e o verso: " .. back)
    eq(scalar(data, "SELECT d.name FROM cards c JOIN decks d ON d.id = c.deck_id WHERE c.id = " .. id), "Databricks Guide", "baralho = só o título do livro")
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM decks WHERE name = 'Vocabulary Builder::Databricks Guide'")), 0, "baralho antigo vazio apagado")
    eq(sched(data, id), before, "progresso intacto depois de mover e atualizar")

    -- evolving: sem dicionário; escreve a definição na revisão
    tapText("^Revisar %(1%)")
    check(has("evolving") and has("Nenhuma definição encontrada"), "revisão sem definição: " .. screenText())
    tapText("^Escrever a definição")
    LAST_inputdialog._input = "envolver"
    pressDialogButton(LAST_inputdialog, "Salvar")
    check(has("Sua definição: envolver"), "a definição escrita aparece na revisão: " .. screenText())
    snap("9_definicao_sua")
    tapText("✓ Revisado")
    tapText("^Exportar %(1%)")
    tapText("^Exportar %(1%)")
    check(has("1 cartões novos adicionados."), "exportou a palavra sem dicionário: " .. screenText())
    local eback = scalar(data, "SELECT back FROM cards WHERE source_key = 'vocab2deck:f:w:evolving'")
    check(eback:sub(1, 8) == "evolving" and contains(eback, "envolver"), "verso com a definição escrita: " .. tostring(eback))
    UIM.stack = {}
    p:onVocab2DeckOpen()
    tapText("^No baralho")
    check(has("envolver") and not has("sem definição"), "a lista mostra a definição escrita: " .. screenText())
end)

scenario("livro: ＋ Adicionar ao baralho na seleção e no dicionário → editor → Inbox", function()
    local data = freshEnv()
    makeVocab(data, WORDS)
    local reader = fakeReader()
    local dict = fakeDict(DEFS)
    local dict_buttons = {}
    dict.addToDictButtons = function(_, spec) dict_buttons[spec.id] = spec end
    local p = newPlugin(dict, fakeAV(), reader)
    p:onReaderReady()
    p:syncVocab()
    local hl = reader.highlight
    check(hl.buttons.vocab2deck_add ~= nil, "botão no menu da seleção")
    check(dict_buttons.zz_vocab2deck_add ~= nil, "botão no popup do dicionário")

    -- trecho selecionado no livro
    hl.selected_text = { text = "a  noble   madness" }
    hl.ctx_prev, hl.ctx_next = "He lived with ", ", and nobody stopped him."
    local btn = hl.buttons.vocab2deck_add(hl)
    eq(btn.text, "＋ Adicionar ao baralho", "texto do botão")
    btn.callback()
    eq(hl.closed, 1, "fechou o menu da seleção")
    check(has("Novo cartão") and has("a noble madness") and has("Salvar no Inbox"), "editor de novo cartão: " .. screenText())
    check(has("“He lived with a noble madness, and nobody stopped him.”"), "frase de contexto do livro")
    check(has("Dom Quixote"), "livro")
    noOffscreen("novo cartão")
    snap("10_novo_cartao")
    tapText("Toque para preencher") -- a Definição (trecho não está no dicionário)
    LAST_inputdialog._input = "loucura nobre"
    pressDialogButton(LAST_inputdialog, "Salvar")
    tapText("^Salvar no Inbox")
    check(contains(info(), "Salvo no ○ Inbox"), "aviso ao salvar")
    local it = p:getStore():get("w:a noble madness")
    eq(it and it.status, "inbox", "foi para o Inbox")
    eq(it and it.origin, "book", "origem: livro")

    -- cancelar descarta
    hl.selected_text = { text = "windmills" }
    hl.buttons.vocab2deck_add(hl).callback()
    tapText("^Cancelar")
    eq(p:getStore():get("w:windmills"), nil, "Cancelar não guarda nada")

    -- popup do dicionário: a definição na tela vem preenchida
    UIM.stack = {}
    local lookups_before = dict.lookups
    local popup = { word = "valiant", closed = false,
        results = { { dict = "Teste EN-PT", word = "valiant", definition = "1. brave<br>2. heroic" } }, dict_index = 1 }
    function popup:onClose() self.closed = true end
    dict_buttons.zz_vocab2deck_add.callback(popup)
    check(popup.closed, "fechou o popup")
    check(has("Novo cartão") and has("valiant"), "editor aberto: " .. screenText())
    check(has("1. brave"), "definição do popup preenchida: " .. screenText())
    eq(dict.lookups, lookups_before, "não buscou de novo no dicionário")
    tapText("^Salvar no Inbox")

    -- palavra que já existe (veio do Vocabulary Builder): abre a que existe
    UIM.stack = {}
    hl.selected_text = { text = "Quixotic" }
    hl.buttons.vocab2deck_add(hl).callback()
    check(contains(info(), "já está no plugin"), "aviso de existente")
    check(has("Campos · quixotic") and not has("Novo cartão"), "abriu o existente: " .. screenText())
    eq(p:getStore():count({}), 5, "3 do Vocabulary Builder + 2 do livro, sem duplicar")

    -- a sincronização com o Vocabulary Builder não apaga os do livro
    UIM.stack = {}
    p:onVocab2DeckOpen()
    eq(p:getStore():counts().inbox, 5, "todos no Inbox")
    eq(p:getStore():get("w:a noble madness").book, "Dom Quixote", "a captura continua com o livro dela")
    -- revisar e exportar o trecho
    p:getStore():setStatus({ "w:a noble madness" }, "ready")
    UIM.stack = {}
    p:onVocab2DeckExport()
    tapText("^Exportar %(1%)")
    local front = scalar(data, "SELECT front FROM cards WHERE source_key = 'vocab2deck:f:w:a noble madness'")
    local back = scalar(data, "SELECT back FROM cards WHERE source_key = 'vocab2deck:f:w:a noble madness'")
    check(contains(front, "a noble madness"), "frente: o trecho")
    check(back:sub(1, #front) == front and contains(back, "loucura nobre"), "verso: frente + sua definição: " .. tostring(back))
end)

-- Roda tests/support/check_apkg.py e devolve { chave = valor } e a lista de notas.
local function checkApkg(path)
    local out = io.popen("python3 -I '" .. HERE .. "/support/check_apkg.py' '" .. path .. "' 2>&1")
    local r, notes, raw = {}, {}, {}
    for line in out:lines() do
        raw[#raw + 1] = line
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k == "note" then notes[#notes + 1] = v elseif k then r[k] = v end
    end
    out:close()
    r.raw = table.concat(raw, "\n")
    return r, notes
end

scenario("passo .apkg: ankiviewer/shared/Vocab2Deck.apkg com Vocab2Deck::Livro", function()
    local data = freshEnv()
    makeVocab(data, {
        { word = "serendipity", book = "Livro A", prev = "It was pure ", next = " that we met." },
        { word = "quixotic", book = "Livro B", prev = "A ", next = " plan." },
        { word = "ephemeral", prev = "The joy was ", next = " and fleeting." }, -- sem livro
    })
    local p = newPlugin(fakeDict(DEFS), fakeAV())
    p:onVocab2DeckOpen()
    p:getStore():setStatus({ "w:serendipity", "w:quixotic", "w:ephemeral" }, "ready")
    UIM.stack = {}
    p:onVocab2DeckExport()
    tapText("^Exportar %(3%)")
    check(has("3 cartões novos adicionados.") and not has("não foi gravado"), "exportou: " .. screenText())
    local path = data .. "/ankiviewer/shared/Vocab2Deck.apkg"
    check(io.open(path, "rb") ~= nil, "pacote gravado na pasta shared do Anki Viewer")
    local r, notes = checkApkg(path)
    eq(r.zip_ok, "True", "zip íntegro")
    eq(r.entries, "collection.anki2,media", "conteúdo do pacote")
    eq(r.revlog_query, "ok", "a consulta do Anki na revlog funciona: " .. r.raw)
    check(contains(r.revlog_cols, "ease"), "revlog tem a coluna ease")
    eq(r.ver, "11", "coleção legada (schema 11)")
    eq(r.decks, "Default|Vocab2Deck|Vocab2Deck::Livro A|Vocab2Deck::Livro B", "hierarquia de baralhos")
    eq(r.notes, "3", "uma nota por cartão")
    eq(r.cards_in_known_decks, "True", "cartões nos baralhos do pacote")
    eq(r.csum_ok, "True", "checksum das notas")
    eq(r.arrays_ok, "True", "arrays JSON de verdade")
    eq(r.afmt_frontside, "True", "verso do Anki usa {{FrontSide}}")
    local by_word = {}
    for _, n in ipairs(notes) do
        local guid, deck, front, back = n:match("^(.-)|(.-)|(.-)|(.*)$")
        by_word[front:match("^[^<]*")] = { guid = guid, deck = deck, front = front, back = back }
    end
    eq(by_word.serendipity and by_word.serendipity.deck, "Vocab2Deck::Livro A", "serendipity no subbaralho do livro")
    eq(by_word.quixotic and by_word.quixotic.deck, "Vocab2Deck::Livro B", "quixotic no subbaralho do livro")
    eq(by_word.ephemeral and by_word.ephemeral.deck, "Vocab2Deck", "sem livro: no baralho principal")
    local sb = by_word.serendipity.back
    check(contains(sb, "luck") and not contains(sb, "――――――") and not contains(sb, "serendipity"),
        "verso no Anki não repete a frente: " .. sb)
    check(contains(by_word.serendipity.front, "<br>"), "quebras de linha viram <br>")

    -- exportar de novo: mesmos GUIDs (o Anki atualiza em vez de duplicar), texto novo
    local first_guid = by_word.serendipity.guid
    -- editar um cartão já no baralho: o Início atualiza o Anki Viewer, e ao fechar
    -- o plugin o pacote é regravado (sem precisar exportar nada novo)
    p:getStore():setOverride("w:serendipity", "definition", "acaso feliz")
    UIM.stack = {}
    p:onVocab2DeckOpen()
    check(has("1 cartões atualizados no Anki Viewer"), "Anki Viewer atualizado: " .. screenText())
    p.app:closeAll()
    local r2, notes2 = checkApkg(path)
    eq(r2.notes, "3", "sem duplicar no pacote")
    local found
    for _, n in ipairs(notes2) do if n:find("^" .. first_guid) then found = n end end
    check(found and contains(found, "acaso feliz"), "mesmo GUID, texto novo: " .. tostring(found))
    check(io.open(path .. ".part", "rb") == nil, "nenhum temporário sobrando")
end)

scenario("itens Revisados com cartão já no Anki Viewer: viram No baralho e o .apkg nasce ao fechar", function()
    local data = freshEnv()
    makeVocab(data, WORDS)
    local p = newPlugin(fakeDict(DEFS), fakeAV())
    p:onVocab2DeckOpen()
    p:getStore():setStatus({ "w:serendipity", "w:quixotic", "w:ephemeral" }, "ready")
    UIM.stack = {}
    p:onVocab2DeckExport()
    tapText("^Exportar %(3%)")
    -- o estado visto no aparelho: cartões no Anki Viewer, itens de volta a Revisado, sem pacote
    p.app:closeAll()
    local path = data .. "/ankiviewer/shared/Vocab2Deck.apkg"
    os.remove(path)
    p:getStore():setStatus({ "w:serendipity", "w:quixotic", "w:ephemeral" }, "ready")
    UIM.stack = {}
    p:onVocab2DeckOpen()
    eq(p:getStore():counts().deck, 3, "voltaram para ✓ No baralho")
    check(has("Exportar (0)"), "nada para exportar de novo: " .. screenText())
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM cards")), 3, "sem duplicar no Anki Viewer")
    p.app:closeAll()
    local r = checkApkg(path)
    eq(r.notes, "3", "pacote gravado ao fechar, mesmo sem nada novo: " .. tostring(r.raw))
    -- lista No baralho: seleção só oferece Descartar
    UIM.stack = {}
    p:onVocab2DeckOpen()
    tapText("^No baralho")
    local target
    walk(paintTop(), function(w) if w.text == "quixotic" and w.dimen then target = w return true end end)
    tapAt(target.dimen.x + 2, target.dimen.y + 2, "hold")
    local exact = {}
    for _, t in ipairs(texts()) do exact[t] = true end
    check(exact["× Descartar"] and not exact["○ Inbox"] and not exact["● Revisado"], "seleção no baralho: " .. screenText())
end)

-- Rodada com cópias dos bancos de um aparelho (V2D_REPLAY=pasta com settings/ e ankiviewer/).
local REPLAY = os.getenv("V2D_REPLAY")
if REPLAY and REPLAY ~= "" then
    scenario("réplica dos dados do aparelho", function()
        local data = freshEnv()
        os.execute("cp -R '" .. REPLAY .. "/settings/.' '" .. data .. "/settings/'")
        os.execute("mkdir -p '" .. data .. "/ankiviewer' && cp -R '" .. REPLAY .. "/ankiviewer/.' '" .. data .. "/ankiviewer/'")
        local p = newPlugin(fakeDict(DEFS), fakeAV())
        local saved = dofile(data .. "/settings/vocab2deck.lua")
        for k, v in pairs(saved) do p.settings:set(k, v) end
        local before = p:getStore():counts()
        print("    antes:", before.inbox, "inbox", before.ready, "revisados", before.deck, "no baralho")
        p:onVocab2DeckOpen()
        local after = p:getStore():counts()
        print("    depois:", after.inbox, "inbox", after.ready, "revisados", after.deck, "no baralho")
        print("    " .. screenText())
        p.app:closeAll()
        local path = data .. "/ankiviewer/shared/Vocab2Deck.apkg"
        local r, notes = checkApkg(path)
        check(r.notes and tonumber(r.notes) > 0, "pacote gravado com os cartões do aparelho: " .. tostring(r.raw))
        print("    pacote: notas=" .. tostring(r.notes) .. " baralhos=" .. tostring(r.decks) .. " revlog=" .. tostring(r.revlog_query))
        for i = 1, math.min(3, #notes) do print("    nota: " .. notes[i]:sub(1, 150)) end
    end)
end

scenario("lista: seleção em massa e busca", function()
    local data = freshEnv()
    makeVocab(data, WORDS)
    local p = newPlugin(fakeDict(DEFS), fakeAV())
    p:onVocab2DeckOpen()
    tapText("^Inbox")
    -- toque longo na primeira linha abre a seleção
    local target
    walk(paintTop(), function(w) if w.text == "quixotic" and w.dimen then target = w return true end end)
    tapAt(target.dimen.x + 2, target.dimen.y + 2, "hold")
    check(has("1 selecionadas"), "modo seleção: " .. screenText())
    tapText("Selecionar todas")
    check(has("3 selecionadas"), "todas")
    tapText("^● Revisado$")
    eq(p:getStore():counts().ready, 3, "3 revisados")
    UIM.stack = {}
    p:askSearch(p:getApp(), {})
    LAST_inputdialog._input = "livro b"
    pressDialogButton(LAST_inputdialog, "Salvar")
    check(has("Busca: livro b") and has("quixotic") and not has("ephemeral"), "busca: " .. screenText())
end)

scenario("banco do Anki Viewer antigo: recusa escrever", function()
    local data = freshEnv()
    makeVocab(data, WORDS)
    os.execute("mkdir -p '" .. data .. "/ankiviewer'")
    local conn = SQ3.open(avDbPath(data))
    conn:exec("CREATE TABLE decks (id INTEGER PRIMARY KEY, name TEXT)")
    conn:exec("CREATE TABLE cards (id INTEGER PRIMARY KEY, deck_id INTEGER, front TEXT, back TEXT)")
    conn:exec("PRAGMA user_version = 2")
    conn:close()
    local p = newPlugin(fakeDict(DEFS), fakeAV())
    p:onVocab2DeckOpen()
    check(has("versão antiga"), "aviso no Início")
    p:getStore():setStatus({ "w:quixotic" }, "ready")
    UIM.stack = {}
    p:onVocab2DeckExport()
    tapText("^Exportar %(1%)")
    check(has("Nada foi gravado") and has("versão antiga"), "resultado: " .. screenText())
    eq(tonumber(scalar(data, "SELECT COUNT(*) FROM cards")), 0, "nada escrito")
end)

scenario("Anki Viewer desativado e configurações sem erro", function()
    local data = freshEnv()
    makeVocab(data, WORDS)
    local p = newPlugin(fakeDict(DEFS), nil)
    p:onVocab2DeckReview()
    check(contains(info(), "não está instalado ou está desativado"), "aviso")
    p:showSettings()
    local menu = LAST_menu
    for _, item in ipairs(menu.item_table) do
        if item.mandatory_func then check(type(item.mandatory_func()) == "string", "valor de " .. item.text) end
    end
    for _, item in ipairs(menu.item_table) do
        if not item.text:find("^Recriar") and not item.text:find("^Verificar") then
            _G.LAST_infomessage = nil
            menu:onMenuChoice(item)
            check(not contains(info(), "falhou"), "sem erro em " .. item.text .. ": " .. tostring(info()))
        end
    end
end)

Shim.stop()
print(string.format("\n%d verificações ok, %d falharam", passed, failed))
os.exit(failed == 0 and 0 or 1)
