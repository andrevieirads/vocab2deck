--[[--
Banco próprio do plugin (settings/vocab2deck.sqlite3): o estado de cada
palavra trazida do Vocabulary Builder, como o kr2anki.sqlite3 do KR2Anki.

    items        uma linha por palavra (vkey), com o contexto copiado do
                 Vocabulary Builder, o status e a definição padrão
    item_senses  os sentidos que o dicionário devolveu (para escolher)
    item_fields  valores editados de campos do modelo (extra = 0) e campos
                 extras só daquele cartão (extra = 1, com lado próprio)

Status: inbox (○) → ready (● Revisado) → deck (✓ No baralho); discarded (×).
Origem (origin): "vocab" (Vocabulary Builder) ou "book" (botão "＋ Adicionar ao
baralho" no livro).

Mesmo desenho do kr2anki/db.lua: cada operação abre uma conexão curta, e toda
escrita é uma transação. O Vocabulary Builder nunca é escrito; o banco do
Anki Viewer é escrito só pelo deck_writer.
--]]

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
}

-- Colunas novas, adicionadas no lugar (sem apagar nada), como o Anki Viewer faz.
local COLUMN_MIGRATIONS = {
    { "items", "origin", "TEXT NOT NULL DEFAULT 'vocab'" },
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
                    "looked_up", "definition", "dict", "in_vocab", "added_at", "updated_at", "origin" }
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
        local res = { added = 0, updated = 0, total = 0 }
        exec(conn, "UPDATE items SET in_vocab = 0")
        for _, w in ipairs(words) do
            local status = known[w.key]
            if status and origin[w.key] == "book" then
                -- capturado no livro: mantém a frase e o livro da captura
                exec(conn, "UPDATE items SET streak = ?, in_vocab = 1 WHERE vkey = ?", w.streak, w.key)
                res.updated = res.updated + 1
                res.total = res.total + 1
            elseif status then
                exec(conn, "UPDATE items SET word = ?, book = ?, prev = ?, next = ?, highlight = ?, created = ?, "
                    .. "streak = ?, in_vocab = 1 WHERE vkey = ?",
                    w.word, w.book, w.prev, w.next, w.highlight, w.created, w.streak, w.key)
                -- exportada por outra versão / outro caminho: passa a ✓ No baralho
                if exported[w.key] and status ~= "deck" and status ~= "discarded" then
                    exec(conn, "UPDATE items SET status = 'deck', updated_at = ? WHERE vkey = ?", now, w.key)
                end
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
Item vindo do livro (botão "＋ Adicionar ao baralho"). Se o texto já existe
(ex.: a palavra veio do Vocabulary Builder), não duplica.
@param c { word, prev, next, highlight, book }
@treturn string vkey, boolean created
--]]
function Store:addCapture(c)
    local vkey = require("vocab2deck/vocab_reader").keyFor(c.word)
    if not vkey then error("texto vazio", 0) end
    local now = self.now()
    return self:_tx(function(conn)
        local exists = rows(conn, { "vkey" }, "SELECT vkey FROM items WHERE vkey = ?", vkey)[1]
        if exists then return vkey, false end
        exec(conn, "INSERT INTO items (vkey, word, book, prev, next, highlight, created, status, looked_up, "
            .. "in_vocab, origin, added_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'inbox', 0, 0, 'book', ?, ?)",
            vkey, c.word, c.book, c.prev, c.next, c.highlight, now, now, now)
        return vkey, true
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

local ORDER = {
    newest = "coalesce(created, 0) DESC, vkey",
    oldest = "coalesce(created, 0) ASC, vkey",
    az = "word COLLATE NOCASE ASC",
}

-- filter = { statuses = { inbox = true, … }, search = "texto" }
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
    local sql = "SELECT vkey, word, book, status, definition, looked_up, "
        .. "(SELECT value FROM item_fields f WHERE f.vkey = items.vkey AND f.extra = 0 AND f.field = 'definition') "
        .. "FROM items WHERE " .. w
        .. " ORDER BY " .. (ORDER[sort or "newest"] or ORDER.newest)
    if limit then sql = sql .. " LIMIT " .. math.floor(limit) .. " OFFSET " .. math.floor(offset or 0) end
    return self:_read(function(conn)
        return rows(conn, { "vkey", "word", "book", "status", "definition", "looked_up", "my_def" }, sql, unpack(args))
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
    item.overrides, item.extras = {}, {}
    for _, f in ipairs(rows(conn, { "id", "field", "value", "side", "extra", "ord" },
            "SELECT id, field, value, side, extra, ord FROM item_fields WHERE vkey = ? ORDER BY ord, id", item.vkey)) do
        if f.extra == 1 then
            item.extras[#item.extras + 1] = { id = f.id, name = f.field, value = f.value or "", side = f.side or "back" }
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
