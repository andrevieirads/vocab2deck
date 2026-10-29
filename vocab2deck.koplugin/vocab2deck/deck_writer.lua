--[[--
Escrita direta no banco interno do Anki Viewer
(<pasta de dados do KOReader>/ankiviewer/ankiviewer.sqlite3).

Por que direto no SQLite e não um .apkg: o Anki Viewer converte cada .apkg
importado em linhas da tabela `cards` (deck_id, front, back, source_key, …)
e estuda só a partir desse banco (ver vocab2deck/ankiviewer/db.lua). Escrever ali é o
mesmo que o importador dele faz no fim (DB.mergeDeckFromPairs), sem zip,
sem passar pela tela de mapeamento de campos e sem o risco de "Replace".

O que este módulo grava no banco do Anki Viewer
* decks: cria o baralho se não existir (INSERT INTO decks (name)).
* cards: INSERT de cartões novos com os padrões do próprio Anki Viewer
  (ease 2.5, interval 0, due = agora, reps 0); UPDATE só de front/back
  nos cartões já existentes. As colunas de agendamento (ease, interval,
  due, reps, lapses) NUNCA são tocadas.
* Duas tabelas próprias, com prefixo vocab2deck_ (o Anki Viewer as ignora):
    vocab2deck_words  definição guardada de cada palavra (evita buscar de novo)
    vocab2deck_cards  que cartão veio de que palavra/lado e o texto que o
                      plugin gravou (para detectar edição manual)
  vocab2deck_cards tem ON DELETE CASCADE no baralho: apagar o baralho no Anki
  Viewer zera o controle e a próxima exportação recria tudo.

Segurança
* Antes de qualquer escrita num banco existente: backup com VACUUM INTO
  (cópia consistente mesmo em modo WAL) em <dados>/vocab2deck/backups/,
  guardando os 5 mais recentes. Se o backup falhar, nada é escrito.
* Toda escrita é uma transação: ou entra tudo, ou nada (ROLLBACK).
* Banco com user_version < 4: o Anki Viewer apagaria tudo na próxima
  abertura (DB.init "Drop existing schema"), então o plugin se recusa a
  escrever e pede para abrir o Anki Viewer antes.
--]]

local W = {}
W.__index = W

-- Mesma versão de esquema do Anki Viewer 1.4.0 (DB_SCHEMA_VERSION em vocab2deck/ankiviewer/db.lua).
W.AV_SCHEMA_VERSION = 4
W.KEEP_BACKUPS = 5

-- Copiado de vocab2deck/ankiviewer/db.lua (SCHEMA_STATEMENTS + COLUMN_MIGRATIONS +
-- POST_MIGRATION_STATEMENTS). Usado só para criar o banco quando o Anki
-- Viewer ainda nunca foi aberto, para que ele o reconheça como seu.
local AV_SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS decks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
    )]],
    [[CREATE TABLE IF NOT EXISTS cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
        front TEXT NOT NULL,
        back TEXT NOT NULL,
        ease REAL NOT NULL DEFAULT 2.5,
        interval REAL NOT NULL DEFAULT 0,
        due INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        reps INTEGER NOT NULL DEFAULT 0,
        lapses INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_deck ON cards(deck_id)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_deck_due ON cards(deck_id, due)]],
    [[CREATE TABLE IF NOT EXISTS source_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
        mid TEXT,
        flds TEXT NOT NULL
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_source_notes_deck ON source_notes(deck_id)]],
    [[CREATE TABLE IF NOT EXISTS daily_new_cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
        date TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        UNIQUE(deck_id, date)
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_daily_new_cards_deck_date ON daily_new_cards(deck_id, date)]],
}

-- Colunas que o Anki Viewer adiciona sem mudar a versão (COLUMN_MIGRATIONS).
local AV_COLUMNS = {
    { "cards", "source_key", "TEXT" },
    { "source_notes", "guid", "TEXT" },
}
local AV_POST = {
    [[CREATE INDEX IF NOT EXISTS idx_cards_deck_source_key ON cards(deck_id, source_key)]],
}

local OWN_SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS vocab2deck_words (
        vkey TEXT PRIMARY KEY,
        word TEXT NOT NULL,
        definition TEXT,
        dict TEXT,
        updated_at INTEGER
    )]],
    [[CREATE TABLE IF NOT EXISTS vocab2deck_cards (
        vkey TEXT NOT NULL,
        side TEXT NOT NULL,
        deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
        source_key TEXT NOT NULL,
        written_front TEXT,
        written_back TEXT,
        updated_at INTEGER,
        PRIMARY KEY (vkey, side)
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_vocab2deck_cards_deck ON vocab2deck_cards(deck_id)]],
}

local unpack = table.unpack or unpack -- luacheck: ignore

local function num(v)
    if v == nil then return nil end
    return tonumber(v)
end

--[[--
@param opts {
  path        banco do Anki Viewer (padrão: <dados>/ankiviewer/ankiviewer.sqlite3)
  backup_dir  pasta dos backups (padrão: <dados>/vocab2deck/backups)
  sq3, fs     dependências injetáveis (testes)
  now         relógio (padrão os.time)
}
--]]
function W.new(opts)
    opts = opts or {}
    local self = setmetatable({}, W)
    self.sq3 = opts.sq3 or require("lua-ljsqlite3/init")
    self.fs = opts.fs or W.koreaderFs()
    self.now = opts.now or os.time
    if opts.path then
        self.path = opts.path
        self.backup_dir = opts.backup_dir
    else
        local DataStorage = require("datastorage")
        local data = DataStorage:getDataDir()
        self.path = data .. "/ankiviewer/ankiviewer.sqlite3"
        self.backup_dir = opts.backup_dir or (data .. "/vocab2deck/backups")
    end
    self.dir = self.path:match("^(.*)/[^/]+$") or "."
    return self
end

-- Operações de arquivo usando as bibliotecas do KOReader.
function W.koreaderFs()
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    return {
        isFile = function(p) return lfs.attributes(p, "mode") == "file" end,
        size = function(p) return lfs.attributes(p, "size") end,
        makePath = function(p) return util.makePath(p) end,
        list = function(dir)
            local out = {}
            if lfs.attributes(dir, "mode") ~= "directory" then return out end
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then out[#out + 1] = name end
            end
            return out
        end,
        remove = os.remove,
    }
end

-- Conexão no mesmo modo que o Anki Viewer usa (vocab2deck/ankiviewer/db.lua openConnection).
function W:_open()
    local conn = self.sq3.open(self.path)
    if conn.set_busy_timeout then conn:set_busy_timeout(3000) end
    conn:exec("PRAGMA foreign_keys = ON;")
    conn:exec("PRAGMA synchronous = NORMAL;")
    conn:exec("PRAGMA journal_mode = WAL;")
    return conn
end

-- Roda fn(conn) e sempre fecha a conexão.
function W:_with(fn)
    local conn = self:_open()
    local res = { pcall(fn, conn) }
    pcall(conn.close, conn)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

-- Executa fn(conn) numa transação.
local function transaction(conn, fn)
    conn:exec("BEGIN IMMEDIATE;")
    local res = { pcall(fn, conn) }
    if res[1] then
        conn:exec("COMMIT;")
    else
        pcall(conn.exec, conn, "ROLLBACK;")
        error(res[2], 0)
    end
    return unpack(res, 2)
end

local function exec(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    stmt:step()
    stmt:close()
end

-- Linhas de uma consulta. O número de colunas vem do chamador, porque valores
-- NULL deixam buracos na tabela da linha devolvida por stmt:step().
local function rowsN(conn, ncols, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    local out = {}
    local row = stmt:step()
    while row do
        local copy = {}
        for i = 1, ncols do copy[i] = row[i] end
        out[#out + 1] = copy
        row = stmt:step()
    end
    stmt:close()
    return out
end

local function tableColumns(conn, tbl)
    local cols = {}
    for _, r in ipairs(rowsN(conn, 2, "PRAGMA table_info(" .. tbl .. ");")) do
        if r[2] then cols[tostring(r[2])] = true end
    end
    return cols
end

local function tableExists(conn, tbl)
    local n = num(conn:rowexec("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '" .. tbl .. "';"))
    return (n or 0) > 0
end

--[[--
Verifica o banco do Anki Viewer sem escrever nada.
@treturn string "absent" (ainda não existe; será criado) | "ok" | "old_schema" | "bad_schema"
@treturn table info { version, own_tables }
--]]
function W:check()
    if not self.fs.isFile(self.path) then return "absent", {} end
    return self:_with(function(conn)
        local version = num(conn:rowexec("PRAGMA user_version;")) or 0
        local has_cards = tableExists(conn, "cards")
        local has_decks = tableExists(conn, "decks")
        local info = { version = version, own_tables = tableExists(conn, "vocab2deck_cards") }
        if version == 0 and not has_cards and not has_decks then return "absent", info end
        if version < W.AV_SCHEMA_VERSION then return "old_schema", info end
        if not (has_cards and has_decks) then return "bad_schema", info end
        local c, d = tableColumns(conn, "cards"), tableColumns(conn, "decks")
        for _, col in ipairs({ "id", "deck_id", "front", "back", "due", "reps", "interval" }) do
            if not c[col] then return "bad_schema", info end
        end
        if not (d.id and d.name) then return "bad_schema", info end
        return "ok", info
    end)
end

-- Cria/completa o esquema (dentro de uma conexão já aberta, depois do backup).
local function ensureSchema(conn, fresh)
    if fresh then
        for _, sql in ipairs(AV_SCHEMA) do conn:exec(sql .. ";") end
        conn:exec("PRAGMA user_version = " .. W.AV_SCHEMA_VERSION .. ";")
    end
    -- mesma migração em linha que o Anki Viewer faz (ensureColumns)
    for _, def in ipairs(AV_COLUMNS) do
        if tableExists(conn, def[1]) and not tableColumns(conn, def[1])[def[2]] then
            conn:exec(string.format("ALTER TABLE %s ADD COLUMN %s %s;", def[1], def[2], def[3]))
        end
    end
    for _, sql in ipairs(AV_POST) do conn:exec(sql .. ";") end
    for _, sql in ipairs(OWN_SCHEMA) do conn:exec(sql .. ";") end
end

--[[--
Backup do banco (antes de escrever). Usa VACUUM INTO; se a versão do SQLite
não tiver, faz checkpoint do WAL e copia o arquivo.
@treturn string|nil caminho do backup (nil se o banco ainda não existe)
--]]
function W:backup()
    if not self.fs.isFile(self.path) then return nil end
    self.fs.makePath(self.backup_dir)
    local stamp = os.date("%Y%m%d-%H%M%S", self.now())
    local dest = self.backup_dir .. "/ankiviewer-" .. stamp .. ".sqlite3"
    local n = 1
    while self.fs.isFile(dest) do
        n = n + 1
        dest = self.backup_dir .. "/ankiviewer-" .. stamp .. "-" .. n .. ".sqlite3"
    end
    local ok_vacuum = pcall(function()
        self:_with(function(conn)
            conn:exec("VACUUM INTO '" .. dest:gsub("'", "''") .. "';")
        end)
    end)
    if not ok_vacuum or not self.fs.isFile(dest) then
        self:_with(function(conn) pcall(conn.exec, conn, "PRAGMA wal_checkpoint(TRUNCATE);") end)
        local src = io.open(self.path, "rb")
        if not src then error("não foi possível ler o banco do Anki Viewer para o backup", 0) end
        local data = src:read("*a")
        src:close()
        local out = io.open(dest, "wb")
        if not out then error("não foi possível criar o backup em " .. dest, 0) end
        local ok_write = out:write(data)
        out:close()
        if not ok_write then error("falha ao gravar o backup em " .. dest, 0) end
    end
    local size = self.fs.size and self.fs.size(dest)
    if not self.fs.isFile(dest) or (size and size == 0) then
        error("o backup ficou vazio: " .. dest, 0)
    end
    self:pruneBackups()
    return dest
end

-- Mantém só os W.KEEP_BACKUPS backups mais recentes (só arquivos criados por este plugin).
function W:pruneBackups()
    local names = {}
    for _, name in ipairs(self.fs.list(self.backup_dir)) do
        if name:match("^ankiviewer%-%d+%-%d+.*%.sqlite3$") then names[#names + 1] = name end
    end
    table.sort(names)
    for i = 1, #names - W.KEEP_BACKUPS do
        self.fs.remove(self.backup_dir .. "/" .. names[i])
    end
end

--[[--
Prepara uma sessão de escrita: verifica, faz backup e garante o esquema.
@treturn string|nil caminho do backup
--]]
function W:prepareWrite(skip_backup)
    local status = self:check()
    if status == "old_schema" then
        error("O banco do Anki Viewer é de uma versão antiga. Abra o Anki Viewer uma vez e tente de novo.", 0)
    elseif status == "bad_schema" then
        error("O banco do Anki Viewer tem um formato desconhecido; nada foi gravado.", 0)
    end
    local backup = nil
    if status == "ok" and skip_backup then
        -- backup já feito nesta sessão (edições seguidas de campos)
        self.fs.makePath(self.dir)
    elseif status == "ok" then
        backup = self:backup()
    else
        self.fs.makePath(self.dir)
    end
    self:_with(function(conn) ensureSchema(conn, status == "absent") end)
    return backup
end

--[[--
Estado gravado, para o planejamento (Sync.plan). Não escreve nada.
@treturn table { words = { [vkey] = {definition, dict} },
                 cards = { [vkey|side] = {card_id|nil, deck_id, front, back, written_front, written_back} },
                 status }
--]]
function W:loadState()
    local status = self:check()
    local state = { words = {}, cards = {}, decks = {}, status = status }
    if status ~= "ok" then return state end
    self:_with(function(conn)
        for _, r in ipairs(rowsN(conn, 2, "SELECT id, name FROM decks;")) do state.decks[num(r[1])] = r[2] end
        if not tableExists(conn, "vocab2deck_cards") then return end
        local has_source_key = tableColumns(conn, "cards").source_key
        for _, r in ipairs(rowsN(conn, 3, "SELECT vkey, definition, dict FROM vocab2deck_words;")) do
            state.words[r[1]] = { definition = r[2], dict = r[3] }
        end
        -- cartões atuais do plugin (identificados por source_key)
        local live = {}
        if has_source_key then
            for _, r in ipairs(rowsN(conn, 5,
                    "SELECT id, deck_id, source_key, front, back FROM cards WHERE source_key LIKE 'vocab2deck:%';")) do
                live[num(r[2]) .. "|" .. r[3]] = { id = num(r[1]), front = r[4], back = r[5] }
            end
        end
        for _, r in ipairs(rowsN(conn, 6,
                "SELECT vkey, side, deck_id, source_key, written_front, written_back FROM vocab2deck_cards;")) do
            local deck_id = num(r[3])
            local c = live[deck_id .. "|" .. r[4]]
            state.cards[r[1] .. "|" .. r[2]] = {
                deck_id = deck_id, source_key = r[4],
                written_front = r[5], written_back = r[6],
                card_id = c and c.id or nil,
                front = c and c.front or nil, back = c and c.back or nil,
            }
        end
    end)
    return state
end

local function deckId(conn, name, cache)
    if cache[name] then return cache[name] end
    local stmt = conn:prepare("SELECT id FROM decks WHERE name = ?;")
    stmt:bind(name)
    local row = stmt:step()
    stmt:close()
    local id = row and num(row[1])
    if not id then
        exec(conn, "INSERT INTO decks (name) VALUES (?);", name)
        id = num(conn:rowexec("SELECT last_insert_rowid();"))
    end
    if not id then error("não foi possível criar o baralho " .. name, 0) end
    cache[name] = id
    return id
end

--[[--
Grava as operações numa única transação (depois do backup).
@param ops {
  words   = { {vkey, word, definition, dict} }            definições a guardar
  inserts = { {vkey, side, deck_name, source_key, front, back} }  cartões novos
  updates = { {vkey, side, card_id, front, back} }         texto novo (progresso mantido)
  moves   = { {vkey, side, card_id, deck_name} }           troca de baralho (progresso mantido;
                                                           baralho que ficar vazio é apagado)
}
@param opts { backup_done = true quando já houve backup nesta sessão }
@treturn table { added, adopted, updated, moved, backup }
--]]
function W:apply(ops, opts)
    local result = { added = 0, adopted = 0, updated = 0, moved = 0 }
    if #(ops.words or {}) + #(ops.inserts or {}) + #(ops.updates or {}) + #(ops.moves or {}) == 0 then return result end
    result.backup = self:prepareWrite(opts and opts.backup_done)
    local now = self.now()
    self:_with(function(conn)
        transaction(conn, function()
            for _, w in ipairs(ops.words or {}) do
                exec(conn, "INSERT OR REPLACE INTO vocab2deck_words (vkey, word, definition, dict, updated_at) "
                    .. "VALUES (?, ?, ?, ?, ?);", w.vkey, w.word, w.definition, w.dict, now)
            end
            local decks = {}
            for _, ins in ipairs(ops.inserts or {}) do
                local deck_id = deckId(conn, ins.deck_name, decks)
                -- um cartão com a mesma chave já existe (controle perdido)? adota em vez de duplicar
                local stmt = conn:prepare("SELECT id, front, back FROM cards WHERE deck_id = ? AND source_key = ? LIMIT 1;")
                stmt:bind(deck_id, ins.source_key)
                local existing = stmt:step()
                local existing_id = existing and num(existing[1])
                local written_front, written_back = ins.front, ins.back
                if existing_id then
                    written_front, written_back = existing[2], existing[3]
                end
                stmt:close()
                if existing_id then
                    result.adopted = result.adopted + 1
                else
                    exec(conn, "INSERT INTO cards (deck_id, front, back, source_key) VALUES (?, ?, ?, ?);",
                        deck_id, ins.front, ins.back, ins.source_key)
                    result.added = result.added + 1
                end
                exec(conn, "INSERT OR REPLACE INTO vocab2deck_cards "
                    .. "(vkey, side, deck_id, source_key, written_front, written_back, updated_at) "
                    .. "VALUES (?, ?, ?, ?, ?, ?, ?);",
                    ins.vkey, ins.side, deck_id, ins.source_key, written_front, written_back, now)
            end
            for _, up in ipairs(ops.updates or {}) do
                -- só o texto; ease/interval/due/reps/lapses ficam como estão
                exec(conn, "UPDATE cards SET front = ?, back = ? WHERE id = ?;", up.front, up.back, up.card_id)
                exec(conn, "UPDATE vocab2deck_cards SET written_front = ?, written_back = ?, updated_at = ? "
                    .. "WHERE vkey = ? AND side = ?;", up.front, up.back, now, up.vkey, up.side)
                result.updated = result.updated + 1
            end
            local emptied = {}
            for _, mv in ipairs(ops.moves or {}) do
                local deck_id = deckId(conn, mv.deck_name, decks)
                local stmt = conn:prepare("SELECT deck_id FROM cards WHERE id = ?;")
                stmt:bind(mv.card_id)
                local row = stmt:step()
                local old = row and num(row[1])
                stmt:close()
                if old and old ~= deck_id then
                    -- só o baralho muda; ease/interval/due/reps/lapses vão junto com o cartão
                    exec(conn, "UPDATE cards SET deck_id = ? WHERE id = ?;", deck_id, mv.card_id)
                    exec(conn, "UPDATE vocab2deck_cards SET deck_id = ?, updated_at = ? WHERE vkey = ? AND side = ?;",
                        deck_id, now, mv.vkey, mv.side)
                    emptied[old] = true
                    result.moved = result.moved + 1
                end
            end
            -- baralho que ficou vazio é apagado, a não ser que o controle de um cartão
            -- apagado no Anki Viewer ainda aponte para ele (o cascade o levaria junto
            -- e o cartão voltaria na próxima exportação)
            for old in pairs(emptied) do
                exec(conn, "DELETE FROM decks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM cards WHERE deck_id = ?) "
                    .. "AND NOT EXISTS (SELECT 1 FROM vocab2deck_cards WHERE deck_id = ?);", old, old, old)
            end
        end)
    end)
    return result
end

--[[--
Esquece os cartões que foram apagados no Anki Viewer, para que a próxima
exportação os crie de novo (como cartões novos).
@treturn number quantos serão recriados, string|nil backup
--]]
function W:forgetDeleted()
    if self:check() ~= "ok" then return 0 end
    local n = self:_with(function(conn)
        if not tableExists(conn, "vocab2deck_cards") then return 0 end
        return num(conn:rowexec("SELECT COUNT(*) FROM vocab2deck_cards t WHERE NOT EXISTS ("
            .. "SELECT 1 FROM cards c WHERE c.deck_id = t.deck_id AND c.source_key = t.source_key);")) or 0
    end)
    if n == 0 then return 0 end
    local backup = self:prepareWrite()
    self:_with(function(conn)
        transaction(conn, function()
            conn:exec("DELETE FROM vocab2deck_cards WHERE NOT EXISTS (SELECT 1 FROM cards c "
                .. "WHERE c.deck_id = vocab2deck_cards.deck_id AND c.source_key = vocab2deck_cards.source_key);")
        end)
    end)
    return n, backup
end

--[[--
Baralhos que têm cartões deste plugin, com quantos cartões e quantos vencidos.
@treturn table { {id, name, cards, due} } ordenado por nome
--]]
function W:ourDecks()
    if self:check() ~= "ok" then return {} end
    return self:_with(function(conn)
        if not tableExists(conn, "vocab2deck_cards") then return {} end
        local out = {}
        for _, r in ipairs(rowsN(conn, 4, "SELECT d.id, d.name, COUNT(c.id), "
                .. "SUM(CASE WHEN c.due <= ? THEN 1 ELSE 0 END) "
                .. "FROM decks d JOIN cards c ON c.deck_id = d.id "
                .. "WHERE d.id IN (SELECT DISTINCT deck_id FROM vocab2deck_cards) "
                .. "GROUP BY d.id, d.name ORDER BY d.name COLLATE NOCASE;", self.now())) do
            out[#out + 1] = { id = num(r[1]), name = r[2], cards = num(r[3]) or 0, due = num(r[4]) or 0 }
        end
        return out
    end)
end

return W
