--[[--
Banco próprio do plugin (settings/vocab2deck.sqlite3): o estado de cada
palavra trazida do Vocabulary Builder, como o kr2anki.sqlite3 do KR2Anki.

    items        uma linha por palavra (vkey), com o contexto copiado do
                 Vocabulary Builder, o status e a definição padrão
    item_senses  os sentidos que o dicionário devolveu (para escolher)
    item_fields  valores editados de campos do modelo (extra = 0), campos
                 extras só daquele cartão (extra = 1, com lado próprio) e
                 campos do modelo tirados só daquele cartão (extra = 2, side)

Status: inbox (○) → ready (● Revisado) → deck (✓ No baralho); discarded (×).
Origem (origin): "vocab" (Vocabulary Builder), "highlight" (destaque de um
livro, ver highlight_reader), "book" (botão "＋ Adicionar ao baralho" no livro)
ou "manual" (botão "＋ Adicionar cartão" no Início).
in_vocab / in_highlights: o texto está hoje no Vocabulary Builder / nos
destaques (as duas primeiras caixas do Início).
deck: baralho escolhido para o cartão (Trocar baralho); nil = o das
configurações (ou o do livro, com "um baralho por livro").

Mesmo desenho do kr2anki/db.lua: cada operação abre uma conexão curta, e toda
escrita é uma transação. O Vocabulary Builder nunca é escrito; o banco do
Anki Viewer é escrito só pelo deck_writer.
--]]

local Decks = require("vocab2deck/decks")

local Store = {}
Store.__index = Store

Store.STATUSES = { "inbox", "ready", "deck", "discarded" }
local VALID = { inbox = true, ready = true, deck = true, discarded = true }

local SCHEMA_VERSION = 1
local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)]],
    [[CREATE TABLE IF NOT EXISTS items (
        vkey       TEXT PRIMARY KEY,
        word       TEXT NOT NULL,
        book       TEXT,
        prev       TEXT,
        next       TEXT,
        highlight  TEXT,
        created    INTEGER,
        streak     INTEGER,
        status     TEXT NOT NULL DEFAULT 'inbox',
        looked_up  INTEGER NOT NULL DEFAULT 0,
        definition TEXT,
        dict       TEXT,
        in_vocab   INTEGER NOT NULL DEFAULT 1,
        added_at   INTEGER,
        updated_at INTEGER
    )]],
    [[CREATE INDEX IF NOT EXISTS items_status ON items(status)]],
    [[CREATE TABLE IF NOT EXISTS item_senses (
        vkey TEXT NOT NULL,
        ord  INTEGER NOT NULL,
        text TEXT NOT NULL,
        PRIMARY KEY (vkey, ord)
    )]],
    [[CREATE TABLE IF NOT EXISTS item_fields (
        id    INTEGER PRIMARY KEY AUTOINCREMENT,
        vkey  TEXT NOT NULL,
        field TEXT NOT NULL,
        value TEXT,
        side  TEXT,
        extra INTEGER NOT NULL DEFAULT 0,
        ord   INTEGER NOT NULL DEFAULT 0
    )]],
    [[CREATE INDEX IF NOT EXISTS item_fields_vkey ON item_fields(vkey)]],
    -- palavras limpas (botão Limpar nos Descartados): a leitura do Vocabulary
    -- Builder não as traz de volta
    [[CREATE TABLE IF NOT EXISTS cleared (
        vkey       TEXT PRIMARY KEY,
        cleared_at INTEGER
    )]],
}

-- Colunas novas, adicionadas no lugar (sem apagar nada), como o Anki Viewer faz.
local COLUMN_MIGRATIONS = {
    { "items", "origin", "TEXT NOT NULL DEFAULT 'vocab'" },
    { "items", "in_highlights", "INTEGER NOT NULL DEFAULT 0" },
    { "items", "deck", "TEXT" },
}

local unpack = table.unpack or unpack -- luacheck: ignore

local function num(v)
    if v == nil then return nil end
    return tonumber(v)
end

--[[--
@param path arquivo do banco
@param opts { sq3 = módulo lua-ljsqlite3 (testes), now = relógio }
--]]
function Store.new(path, opts)
    opts = opts or {}
    local self = setmetatable({ path = path, sq3 = opts.sq3 or require("lua-ljsqlite3/init"),
                                now = opts.now or os.time }, Store)
    self:_init()
    return self
end

function Store:_open()
    local conn = self.sq3.open(self.path)
    if conn.set_busy_timeout then conn:set_busy_timeout(2000) end
    return conn
end

function Store:_read(fn)
    local conn = self:_open()
    local res = { pcall(fn, conn) }
    pcall(conn.close, conn)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

function Store:_tx(fn)
    local conn = self:_open()
    conn:exec("BEGIN IMMEDIATE")
    local res = { pcall(fn, conn) }
    if res[1] then
        conn:exec("COMMIT")
    else
        pcall(conn.exec, conn, "ROLLBACK")
    end
    pcall(conn.close, conn)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

function Store:_init()
    local conn = self:_open()
    conn:exec("PRAGMA journal_mode=TRUNCATE")
    for _, sql in ipairs(SCHEMA) do conn:exec(sql) end
    for _, def in ipairs(COLUMN_MIGRATIONS) do
        local present = num(conn:rowexec(string.format(
            "SELECT COUNT(*) FROM pragma_table_info('%s') WHERE name = '%s'", def[1], def[2]))) or 0
        if present == 0 then conn:exec(string.format("ALTER TABLE %s ADD COLUMN %s %s", def[1], def[2], def[3])) end
    end
    if not num(conn:rowexec("SELECT max(version) FROM schema_version")) then
        conn:exec("INSERT INTO schema_version(version) VALUES (" .. SCHEMA_VERSION .. ")")
    end
    conn:close()
end

-- Linhas como tabelas com nome de coluna (ncols nomes, na ordem do SELECT).
local function rows(conn, names, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    local out = {}
    local row = stmt:step()
    while row do
        local r = {}
        for i, name in ipairs(names) do
            local v = row[i]
            if type(v) == "cdata" then v = tonumber(v) end
            r[name] = v
        end
        out[#out + 1] = r
        row = stmt:step()
    end
    stmt:close()
    return out
end

local function exec(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    stmt:step()
    stmt:close()
end

local ITEM_COLS = { "vkey", "word", "book", "prev", "next", "highlight", "created", "streak", "status",
                    "looked_up", "definition", "dict", "in_vocab", "added_at", "updated_at", "origin", "deck" }
local ITEM_SELECT = "SELECT " .. table.concat(ITEM_COLS, ", ") .. " FROM items"

-- Vocabulary Builder -> itens -----------------------------------------------------------

--[[--
Traz as palavras do Vocabulary Builder. Palavras novas entram no Inbox;
as que já existem só têm o contexto atualizado (status e edições ficam).
@param words lista do vocab_reader
@param opts {
  exported    = { [vkey] = true } palavras que já têm cartão no Anki Viewer (viram ✓ No baralho)
  definitions = { [vkey] = texto } definições guardadas pela versão 1 (migração)
  skip        = função(word) -> true para não trazer (ex.: aprendida)
}
@treturn table { added, updated, total }
--]]
function Store:syncFromVocab(words, opts)
    opts = opts or {}
    local exported = opts.exported or {}
    local defs = opts.definitions or {}
    local now = self.now()
    return self:_tx(function(conn)
        local known = {}
        local origin = {}
        for _, r in ipairs(rows(conn, { "vkey", "status", "origin" }, "SELECT vkey, status, origin FROM items")) do
            known[r.vkey] = r.status
            origin[r.vkey] = r.origin
        end
        local cleared = {}
        for _, r in ipairs(rows(conn, { "vkey" }, "SELECT vkey FROM cleared")) do cleared[r.vkey] = true end
        local res = { added = 0, updated = 0, total = 0 }
        exec(conn, "UPDATE items SET in_vocab = 0")
        for _, w in ipairs(words) do
            local status = known[w.key]
            if cleared[w.key] and not status then
                -- limpa por você: fica de fora
                res.skipped_cleared = (res.skipped_cleared or 0) + 1
            elseif status and origin[w.key] ~= "vocab" then
                -- capturado no livro: mantém a frase e o livro da captura
                exec(conn, "UPDATE items SET streak = ?, in_vocab = 1 WHERE vkey = ?", w.streak, w.key)
                res.updated = res.updated + 1
                res.total = res.total + 1
            elseif status then
                -- o status fica como está (você pode ter mandado de volta ao Inbox de propósito)
                exec(conn, "UPDATE items SET word = ?, book = ?, prev = ?, next = ?, highlight = ?, created = ?, "
                    .. "streak = ?, in_vocab = 1 WHERE vkey = ?",
                    w.word, w.book, w.prev, w.next, w.highlight, w.created, w.streak, w.key)
                res.updated = res.updated + 1
                res.total = res.total + 1
            elseif not (opts.skip and opts.skip(w)) or exported[w.key] then
                local def = defs[w.key]
                exec(conn, "INSERT INTO items (vkey, word, book, prev, next, highlight, created, streak, status, "
                    .. "looked_up, definition, added_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    w.key, w.word, w.book, w.prev, w.next, w.highlight, w.created, w.streak,
                    exported[w.key] and "deck" or "inbox", def and 1 or 0, def, now, now)
                res.added = res.added + 1
                res.total = res.total + 1
            end
        end
        return res
    end)
end

--[[--
Traz os destaques dos livros (highlight_reader). Destaques novos entram no
Inbox; os que já existem só ficam marcados como destaque (status e edições
ficam). A nota do destaque vira a definição, enquanto a definição for a nota
(dict = Nota do destaque); trechos longos não passam pelo dicionário.
@param list highlight_reader.read().highlights
@param opts { exported = { [vkey] = true }, passage = função(texto) -> true se for trecho longo }
@treturn table { added, updated, total }
--]]
function Store:syncFromHighlights(list, opts)
    opts = opts or {}
    local exported = opts.exported or {}
    local NOTE = require("vocab2deck/highlight_reader").NOTE_DICT
    local now = self.now()
    return self:_tx(function(conn)
        local known = {}
        for _, r in ipairs(rows(conn, { "vkey", "origin", "dict" }, "SELECT vkey, origin, dict FROM items")) do
            known[r.vkey] = r
        end
        local cleared = {}
        for _, r in ipairs(rows(conn, { "vkey" }, "SELECT vkey FROM cleared")) do cleared[r.vkey] = true end
        local res = { added = 0, updated = 0, total = 0 }
        exec(conn, "UPDATE items SET in_highlights = 0")
        for _, h in ipairs(list) do
            local it = known[h.key]
            if cleared[h.key] and not it then
                res.skipped_cleared = (res.skipped_cleared or 0) + 1
            elseif it then
                exec(conn, "UPDATE items SET in_highlights = 1 WHERE vkey = ?", h.key)
                if it.origin == "highlight" then
                    exec(conn, "UPDATE items SET book = ? WHERE vkey = ?", h.book, h.key)
                    if it.dict == NOTE and h.note then
                        exec(conn, "UPDATE items SET definition = ? WHERE vkey = ?", h.note, h.key)
                    end
                end
                res.updated = res.updated + 1
                res.total = res.total + 1
            else
                local passage = opts.passage and opts.passage(h.word)
                exec(conn, "INSERT INTO items (vkey, word, book, highlight, created, status, looked_up, definition, "
                    .. "dict, in_vocab, in_highlights, origin, added_at, updated_at) "
                    .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, 'highlight', ?, ?)",
                    h.key, h.word, h.book, h.word, h.created or now, exported[h.key] and "deck" or "inbox",
                    (h.note or passage) and 1 or 0, h.note, h.note and NOTE or nil, now, now)
                res.added = res.added + 1
                res.total = res.total + 1
            end
        end
        return res
    end)
end

--[[--
Item vindo do livro (botão "＋ Adicionar ao baralho"). Se o texto já existe
(ex.: a palavra veio do Vocabulary Builder), não duplica.
@param c { word, prev, next, highlight, book, origin ("book" | "manual") }
@treturn string vkey, boolean created
--]]
function Store:addCapture(c)
    local vkey = require("vocab2deck/vocab_reader").keyFor(c.word)
    if not vkey then error("texto vazio", 0) end
    local now = self.now()
    return self:_tx(function(conn)
        local exists = rows(conn, { "vkey" }, "SELECT vkey FROM items WHERE vkey = ?", vkey)[1]
        if exists then return vkey, false end
        -- adicionada de novo pelo livro: deixa de contar como limpa
        exec(conn, "DELETE FROM cleared WHERE vkey = ?", vkey)
        exec(conn, "INSERT INTO items (vkey, word, book, prev, next, highlight, created, status, looked_up, "
            .. "in_vocab, origin, added_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'inbox', 0, 0, ?, ?, ?)",
            vkey, c.word, c.book, c.prev, c.next, c.highlight, now, c.origin or "book", now, now)
        return vkey, true
    end)
end

--[[--
Limpar (botão nos Descartados): tira as palavras do plugin e registra que
foram limpas, para a leitura do Vocabulary Builder não as trazer de volta.
O Anki Viewer não é tocado.
--]]
function Store:clear(vkeys)
    local now = self.now()
    self:_tx(function(conn)
        for _, k in ipairs(vkeys) do
            exec(conn, "DELETE FROM item_senses WHERE vkey = ?", k)
            exec(conn, "DELETE FROM item_fields WHERE vkey = ?", k)
            exec(conn, "DELETE FROM items WHERE vkey = ?", k)
            exec(conn, "INSERT OR REPLACE INTO cleared (vkey, cleared_at) VALUES (?, ?)", k, now)
        end
    end)
end

-- Apaga um item e o que é dele (só no banco próprio; o Anki Viewer não é tocado).
function Store:delete(vkey)
    self:_tx(function(conn)
        exec(conn, "DELETE FROM item_senses WHERE vkey = ?", vkey)
        exec(conn, "DELETE FROM item_fields WHERE vkey = ?", vkey)
        exec(conn, "DELETE FROM items WHERE vkey = ?", vkey)
    end)
end

-- Leitura -------------------------------------------------------------------------------

function Store:counts()
    return self:_read(function(conn)
        local c = { inbox = 0, ready = 0, deck = 0, discarded = 0, total = 0 }
        for _, r in ipairs(rows(conn, { "status", "n" }, "SELECT status, count(*) FROM items GROUP BY status")) do
            c[r.status] = r.n
            c.total = c.total + r.n
        end
        return c
    end)
end

-- Quantos itens estão hoje no Vocabulary Builder e nos destaques (qualquer status).
function Store:sourceCounts()
    return self:_read(function(conn)
        local r = rows(conn, { "vocab", "highlights" },
            "SELECT coalesce(sum(in_vocab), 0), coalesce(sum(in_highlights), 0) FROM items")[1]
        return { vocab = r and r.vocab or 0, highlights = r and r.highlights or 0 }
    end)
end

local ORDER = {
    newest = "coalesce(created, 0) DESC, vkey",
    oldest = "coalesce(created, 0) ASC, vkey",
    az = "word COLLATE NOCASE ASC",
}

-- filter = { statuses = { inbox = true, … }, source = "vocab" | "highlights", search = "texto" }
local function where(filter)
    local w, args = { "1 = 1" }, {}
    filter = filter or {}
    if filter.statuses and next(filter.statuses) then
        local list = {}
        for _, s in ipairs(Store.STATUSES) do
            if filter.statuses[s] then list[#list + 1] = "'" .. s .. "'" end
        end
        w[#w + 1] = "status IN (" .. table.concat(list, ",") .. ")"
    end
    if filter.source == "vocab" then w[#w + 1] = "in_vocab = 1" end
    if filter.source == "highlights" then w[#w + 1] = "in_highlights = 1" end
    if filter.search and filter.search:match("%S") then
        local q = "%" .. filter.search:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%%_\\]", "\\%0") .. "%"
        w[#w + 1] = "(lower(word) LIKE ? ESCAPE '\\' OR lower(coalesce(definition, '')) LIKE ? ESCAPE '\\' "
            .. "OR lower(coalesce(book, '')) LIKE ? ESCAPE '\\')"
        args[#args + 1] = q
        args[#args + 1] = q
        args[#args + 1] = q
    end
    return table.concat(w, " AND "), args
end

function Store:count(filter)
    local w, args = where(filter)
    return self:_read(function(conn)
        local r = rows(conn, { "n" }, "SELECT count(*) FROM items WHERE " .. w, unpack(args))[1]
        return r and r.n or 0
    end)
end

-- Linhas leves para listas. my_def = definição escrita por você (campo "definition"
-- editado), que vale no lugar da do dicionário.
function Store:query(filter, sort, offset, limit)
    local w, args = where(filter)
    local sql = "SELECT vkey, word, book, status, definition, looked_up, deck, "
        .. "(SELECT value FROM item_fields f WHERE f.vkey = items.vkey AND f.extra = 0 AND f.field = 'definition') "
        .. "FROM items WHERE " .. w
        .. " ORDER BY " .. (ORDER[sort or "newest"] or ORDER.newest)
    if limit then sql = sql .. " LIMIT " .. math.floor(limit) .. " OFFSET " .. math.floor(offset or 0) end
    return self:_read(function(conn)
        return rows(conn, { "vkey", "word", "book", "status", "definition", "looked_up", "deck", "my_def" }, sql, unpack(args))
    end)
end

function Store:keys(filter, sort)
    local out = {}
    for i, r in ipairs(self:query(filter, sort)) do out[i] = r.vkey end
    return out
end

local function loadFull(conn, item)
    item.senses = {}
    for _, s in ipairs(rows(conn, { "text" }, "SELECT text FROM item_senses WHERE vkey = ? ORDER BY ord", item.vkey)) do
        item.senses[#item.senses + 1] = s.text
    end
    item.overrides, item.extras, item.sides = {}, {}, {}
    for _, f in ipairs(rows(conn, { "id", "field", "value", "side", "extra", "ord" },
            "SELECT id, field, value, side, extra, ord FROM item_fields WHERE vkey = ? ORDER BY ord, id", item.vkey)) do
        if f.extra == 1 then
            item.extras[#item.extras + 1] = { id = f.id, name = f.field, value = f.value or "", side = f.side or "back" }
        elseif f.extra == 2 then
            item.sides[f.field] = f.side
        else
            item.overrides[f.field] = f.value or ""
        end
    end
    return item
end

-- Item completo: com sentidos, valores editados e campos extras.
function Store:get(vkey)
    return self:_read(function(conn)
        local it = rows(conn, ITEM_COLS, ITEM_SELECT .. " WHERE vkey = ?", vkey)[1]
        if not it then return nil end
        return loadFull(conn, it)
    end)
end

-- Todos os itens completos (para planejar a exportação), opcionalmente filtrados.
function Store:all(filter)
    local w, args = where(filter)
    return self:_read(function(conn)
        local list = rows(conn, ITEM_COLS, ITEM_SELECT .. " WHERE " .. w .. " ORDER BY " .. ORDER.oldest, unpack(args))
        for _, it in ipairs(list) do loadFull(conn, it) end
        return list
    end)
end

-- Escrita -------------------------------------------------------------------------------

function Store:setStatus(vkeys, status)
    if not VALID[status] then error("status inválido: " .. tostring(status)) end
    local now = self.now()
    self:_tx(function(conn)
        for _, k in ipairs(vkeys) do
            exec(conn, "UPDATE items SET status = ?, updated_at = ? WHERE vkey = ?", status, now, k)
        end
    end)
end

-- Baralho escolhido para os cartões (nil = volta ao das configurações).
function Store:setDeck(vkeys, deck)
    if deck == "" then deck = nil end
    local now = self.now()
    self:_tx(function(conn)
        for _, k in ipairs(vkeys) do
            exec(conn, "UPDATE items SET deck = ?, updated_at = ? WHERE vkey = ?", deck, now, k)
        end
    end)
end

-- Baralho renomeado/movido: os itens que o escolheram (ou um de dentro dele) seguem o nome novo.
function Store:renameDeck(old, new)
    local n = 0
    self:_tx(function(conn)
        for _, r in ipairs(rows(conn, { "vkey", "deck" }, "SELECT vkey, deck FROM items WHERE deck IS NOT NULL")) do
            local name = Decks.renamed(r.deck, old, new)
            if name then
                exec(conn, "UPDATE items SET deck = ? WHERE vkey = ?", name, r.vkey)
                n = n + 1
            end
        end
    end)
    return n
end

--[[--
Guarda o resultado da busca no dicionário.
@param lookup { definition, dict, senses = {…} } ou nil (nada encontrado)
--]]
function Store:setLookup(vkey, lookup)
    self:_tx(function(conn)
        exec(conn, "DELETE FROM item_senses WHERE vkey = ?", vkey)
        if lookup then
            for i, s in ipairs(lookup.senses or {}) do
                exec(conn, "INSERT INTO item_senses (vkey, ord, text) VALUES (?, ?, ?)", vkey, i, s)
            end
        end
        exec(conn, "UPDATE items SET looked_up = 1, definition = ?, dict = ?, updated_at = ? WHERE vkey = ?",
            lookup and lookup.definition or nil, lookup and lookup.dict or nil, self.now(), vkey)
    end)
end

-- Palavra principal trocada (ex.: forma base digitada na revisão).
function Store:setWord(vkey, word)
    self:_tx(function(conn)
        exec(conn, "UPDATE items SET word = ?, updated_at = ? WHERE vkey = ?", word, self.now(), vkey)
    end)
end

--[[--
Valor editado de um campo do modelo (field = id do campo). value == nil
apaga a edição e o campo volta ao valor gerado.
--]]
function Store:setOverride(vkey, field, value)
    self:_tx(function(conn)
        exec(conn, "DELETE FROM item_fields WHERE vkey = ? AND field = ? AND extra = 0", vkey, field)
        if value ~= nil then
            exec(conn, "INSERT INTO item_fields (vkey, field, value, extra) VALUES (?, ?, ?, 0)", vkey, field, value)
        end
        exec(conn, "UPDATE items SET updated_at = ? WHERE vkey = ?", self.now(), vkey)
    end)
end

--[[--
Lado de um campo do modelo só neste cartão ("none" = tirado deste cartão).
side == nil volta ao lado do modelo.
--]]
function Store:setItemSide(vkey, field, side)
    self:_tx(function(conn)
        exec(conn, "DELETE FROM item_fields WHERE vkey = ? AND field = ? AND extra = 2", vkey, field)
        if side ~= nil then
            exec(conn, "INSERT INTO item_fields (vkey, field, side, extra) VALUES (?, ?, ?, 2)", vkey, field, side)
        end
        exec(conn, "UPDATE items SET updated_at = ? WHERE vkey = ?", self.now(), vkey)
    end)
end

-- Campo extra só deste cartão. Retorna o id.
function Store:addExtra(vkey, name, side, value)
    return self:_tx(function(conn)
        local n = num(conn:rowexec("SELECT coalesce(max(ord), 0) FROM item_fields WHERE extra = 1")) or 0
        exec(conn, "INSERT INTO item_fields (vkey, field, value, side, extra, ord) VALUES (?, ?, ?, ?, 1, ?)",
            vkey, name, value or "", side or "back", n + 1)
        return num(conn:rowexec("SELECT last_insert_rowid()"))
    end)
end

-- patch = { name, value, side } (só os presentes mudam)
function Store:updateExtra(id, patch)
    self:_tx(function(conn)
        if patch.name ~= nil then exec(conn, "UPDATE item_fields SET field = ? WHERE id = ? AND extra = 1", patch.name, id) end
        if patch.value ~= nil then exec(conn, "UPDATE item_fields SET value = ? WHERE id = ? AND extra = 1", patch.value, id) end
        if patch.side ~= nil then exec(conn, "UPDATE item_fields SET side = ? WHERE id = ? AND extra = 1", patch.side, id) end
    end)
end

function Store:removeExtra(id)
    self:_tx(function(conn) exec(conn, "DELETE FROM item_fields WHERE id = ? AND extra = 1", id) end)
end

-- Campo do modelo removido: apaga as edições dele em todos os itens.
function Store:dropField(field)
    self:_tx(function(conn) exec(conn, "DELETE FROM item_fields WHERE field = ? AND extra = 0", field) end)
end

return Store
