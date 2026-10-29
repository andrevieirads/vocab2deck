--[[--
Pacote do Anki (.apkg) com os cartões que estão no baralho, gravado em
<dados do KOReader>/ankiviewer/shared/Vocab2Deck.apkg a cada exportação.

Hierarquia: baralho principal "Vocab2Deck" e, dentro dele, os baralhos do
Anki Viewer como estão organizados aqui ("Inglês::Verbos" vira
"Vocab2Deck::Inglês::Verbos"); cada cartão vai para o baralho em que está no
Anki Viewer. Nota sem baralho conhecido: subbaralho do livro, como antes
("Vocab2Deck::Título do livro"; sem livro, o principal). Cada cartão do plugin (palavra + lado) vira uma
nota do tipo "Vocab2Deck" (campos Frente e Verso; verso =
{{FrontSide}}<hr id=answer>{{Verso}}, como o "Básico" do Anki).

O GUID de cada nota vem da chave do cartão (source_key), e o tipo de nota e
os baralhos têm ids fixos: importar o pacote de novo no Anki atualiza as
notas em vez de duplicar.

Adaptado de kr2anki/apkg.lua (KR2Anki): mesma coleção legada (schema 11,
collection.anki2 + "media", zipada). Corrigido aqui: a tabela revlog tem a
coluna ease, que faltava no KR2Anki e fazia o Anki recusar o pacote
("no such column: ease").
--]]

local Decks = require("vocab2deck/decks")

local A = {}

A.DECK = "Vocab2Deck"
A.FILE = "Vocab2Deck.apkg"
A.MODEL_ID = 1729000000101 -- fixo: reimportar reaproveita o mesmo tipo de nota
A.MODEL_NAME = "Vocab2Deck"

-- Esquema da coleção legada do Anki (schema 11).
local SCHEMA = {
    [[CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null,
        ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null,
        models text not null, decks text not null, dconf text not null, tags text not null)]],
    [[CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null,
        usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null,
        flags integer not null, data text not null)]],
    [[CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null,
        mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null,
        ivl integer not null, factor integer not null, reps integer not null, lapses integer not null,
        left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null)]],
    [[CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null,
        ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null,
        type integer not null)]],
    [[CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null)]],
    "CREATE INDEX ix_notes_usn on notes (usn)",
    "CREATE INDEX ix_cards_usn on cards (usn)",
    "CREATE INDEX ix_revlog_usn on revlog (usn)",
    "CREATE INDEX ix_cards_nid on cards (nid)",
    "CREATE INDEX ix_cards_sched on cards (did, queue, due)",
    "CREATE INDEX ix_revlog_cid on revlog (cid)",
    "CREATE INDEX ix_notes_csum on notes (csum)",
}

local CSS = ".card { font-family: serif; font-size: 22px; text-align: center; color: black; background-color: white; }"

-- Id positivo e estável a partir do nome do baralho (mesma conta do KR2Anki).
function A.deckId(name)
    local h = 5381
    for i = 1, #name do
        h = (h * 33 + name:byte(i)) % 2147483647
    end
    return 1500000000000 + h
end

-- Nome do subbaralho do livro ("::" no título viraria outro nível; troca por ":").
function A.deckName(book)
    local b = tostring(book or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if b == "" then return A.DECK end
    return A.DECK .. "::" .. b:gsub("::+", ":")
end

-- Baralho de uma nota no pacote.
function A.noteDeck(n)
    local deck = n.deck and Decks.normalize(n.deck)
    if deck then return A.DECK .. "::" .. deck end
    return A.deckName(n.book)
end

-- Texto puro -> HTML do campo do Anki.
function A.html(s)
    s = tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return (s:gsub("\r?\n", "<br>"))
end

function A.stripHtml(s)
    s = tostring(s or ""):gsub("<[^>]*>", "")
    s = s:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&amp;", "&")
    return s
end

local function modelJson(json, deck_id, now)
    return {
        id = A.MODEL_ID, name = A.MODEL_NAME, type = 0, mod = now, usn = -1, sortf = 0, did = deck_id,
        tmpls = { {
            name = "Cartão", ord = 0, qfmt = "{{Frente}}", afmt = "{{FrontSide}}\n\n<hr id=answer>\n\n{{Verso}}",
            bqfmt = "", bafmt = "", did = json.null, bfont = "", bsize = 0,
        } },
        flds = {
            { name = "Frente", ord = 0, sticky = false, rtl = false, font = "Arial", size = 20, media = json.array({}) },
            { name = "Verso", ord = 1, sticky = false, rtl = false, font = "Arial", size = 20, media = json.array({}) },
        },
        css = CSS,
        latexPre = "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n"
            .. "\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
        latexPost = "\\end{document}", latexsvg = false,
        req = json.array({ json.array({ 0, "all", json.array({ 0 }) }) }),
        tags = json.array({}), vers = json.array({}),
    }
end

local function deckJson(json, id, name, now)
    return {
        id = id, name = name, mod = now, usn = -1, desc = "", dyn = 0, conf = 1, collapsed = false,
        browserCollapsed = false, extendNew = 0, extendRev = 0,
        lrnToday = json.array({ 0, 0 }), revToday = json.array({ 0, 0 }),
        newToday = json.array({ 0, 0 }), timeToday = json.array({ 0, 0 }),
    }
end

local function dconfJson(json)
    return {
        ["1"] = {
            id = 1, name = "Default", mod = 0, usn = 0, maxTaken = 60, autoplay = true, timer = 0,
            replayq = true, dyn = false,
            new = { delays = json.array({ 1, 10 }), ints = json.array({ 1, 4, 0 }), initialFactor = 2500,
                    order = 1, perDay = 20, bury = false },
            lapse = { delays = json.array({ 10 }), mult = 0, minInt = 1, leechFails = 8, leechAction = 1 },
            rev = { perDay = 200, ease4 = 1.3, ivlFct = 1, maxIvl = 36500, bury = false, hardFactor = 1.2 },
        },
    }
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--[[--
Grava o pacote.
@param opts {
  path   arquivo .apkg de destino (gravado num temporário e trocado no fim)
  notes  { { key, book, deck, front, back } }  texto puro (front/back sem repetir a frente);
         deck = nome do baralho no Anki Viewer (ou nil)
  sqlite, json, sha1, zip  dependências (lua-ljsqlite3, rapidjson, função sha1 hex, Zip.write)
  tmpdir pasta para a coleção temporária
}
@treturn true | nil, erro
--]]
function A.write(opts)
    local SQ3, json, sha1 = assert(opts.sqlite), assert(opts.json), assert(opts.sha1)
    local now = opts.now or os.time()
    local tmp = (opts.tmpdir or "/tmp") .. "/vocab2deck-" .. tostring(now) .. "-" .. math.random(1000, 9999) .. ".anki2"
    os.remove(tmp)

    -- baralho principal sempre, mais os das notas e os de cima deles ("A" de "A::B")
    local decks, order = { [A.DECK] = A.deckId(A.DECK) }, { A.DECK }
    local function add(name)
        if decks[name] then return end
        local parent = name:match("^(.*)::")
        if parent and parent ~= "" then add(parent) end
        decks[name] = A.deckId(name)
        order[#order + 1] = name
    end
    for _, n in ipairs(opts.notes) do add(A.noteDeck(n)) end

    local ok, err = pcall(function()
        local conn = SQ3.open(tmp)
        for _, s in ipairs(SCHEMA) do conn:exec(s) end
        local models = { [tostring(A.MODEL_ID)] = modelJson(json, decks[A.DECK], now) }
        local deck_t = { ["1"] = deckJson(json, 1, "Default", now) }
        for _, name in ipairs(order) do deck_t[tostring(decks[name])] = deckJson(json, decks[name], name, now) end
        local conf = {
            nextPos = #opts.notes + 1, estTimes = true, activeDecks = json.array({ 1 }), sortType = "noteFld",
            timeLim = 0, sortBackwards = false, addToCur = true, curDeck = 1, newSpread = 0, dueCounts = true,
            curModel = A.MODEL_ID, collapseTime = 1200,
        }
        local stmt = conn:prepare("INSERT INTO col VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')")
        stmt:bind(math.floor(now / 86400) * 86400, now * 1000, now * 1000, json.encode(conf), json.encode(models),
            json.encode(deck_t), json.encode(dconfJson(json)))
        stmt:step()
        stmt:close()

        local note_stmt = conn:prepare("INSERT INTO notes VALUES (?, ?, ?, ?, -1, ?, ?, ?, ?, 0, '')")
        local card_stmt = conn:prepare("INSERT INTO cards VALUES (?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')")
        local base_id = now * 1000
        for i, n in ipairs(opts.notes) do
            local front, back = A.html(n.front), A.html(n.back)
            local nid = base_id + i
            local sfld = A.stripHtml(front)
            note_stmt:reset()
            -- GUID estável: o mesmo cartão do plugin é a mesma nota no Anki
            note_stmt:bind(nid, "v2d" .. sha1(n.key):sub(1, 17), A.MODEL_ID, now, " vocab2deck ",
                front .. "\31" .. back, sfld, tonumber(sha1(sfld):sub(1, 8), 16))
            note_stmt:step()
            card_stmt:reset()
            card_stmt:bind(base_id + #opts.notes + i, nid, decks[A.noteDeck(n)], now, i)
            card_stmt:step()
        end
        note_stmt:close()
        card_stmt:close()
        conn:close()
    end)
    if not ok then
        os.remove(tmp)
        return nil, "não foi possível montar a coleção: " .. tostring(err)
    end

    local collection = readFile(tmp)
    os.remove(tmp)
    if not collection then return nil, "não foi possível ler a coleção" end
    local entries = {
        { name = "collection.anki2", data = collection },
        { name = "media", data = "{}" },
    }
    -- grava num temporário ao lado e troca: o pacote antigo só some se o novo ficou pronto
    local part = opts.path .. ".part"
    os.remove(part)
    local zok, zerr = (opts.zip or require("vocab2deck/lib/zip").write)(part, entries, now)
    if not zok then
        os.remove(part)
        return nil, "não foi possível gravar o zip: " .. tostring(zerr)
    end
    os.remove(opts.path)
    local rok, rerr = os.rename(part, opts.path)
    if not rok then return nil, "não foi possível trocar o pacote: " .. tostring(rerr) end
    return true
end

return A
