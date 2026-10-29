--[[--
Leitura do banco do Vocabulary Builder do KOReader
(settings/vocabulary_builder.sqlite3). O banco é aberto SOMENTE PARA LEITURA
(modo "ro") e nunca é alterado.

A consulta base vem de kr2anki/vbimport.lua (V.readRows, KR2Anki):
    vocabulary.word, title.name, prev_context, next_context, highlight, create_time
Aqui as colunas são detectadas em tempo de execução (PRAGMA table_info), para
não quebrar com versões do Vocabulary Builder que não tenham alguma delas.
streak_count (acertos seguidos) não aparece no KR2Anki: só é usada se existir.

    local V = require("vocab2deck/vocab_reader")
    local res, err = V.read(V.PATH)
    -- res = { words = { {key, word, book, prev, next, highlight, created, streak}, … },
    --         has_streak = true|false, raw_count = n }
    -- err = "missing" | "open_failed" | "not_vocab" | "read_failed" (+ detalhe)
--]]

local V = {}

-- Caminho padrão. Resolvido sob demanda para não exigir DataStorage nos testes.
function V.defaultPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Chave estável da palavra: a própria palavra, sem espaços nas pontas e em
-- minúsculas (ASCII). No Vocabulary Builder a palavra identifica a linha, e o
-- livro/contexto pode mudar quando a palavra é consultada de novo; por isso o
-- livro NÃO entra na chave (senão a mesma palavra viraria dois cartões).
function V.keyFor(word)
    local w = trim(word)
    if w == "" then return nil end
    return "w:" .. w:lower()
end

local function emptyToNil(s)
    if s == nil then return nil end
    s = tostring(s)
    if trim(s) == "" then return nil end
    return s
end

-- Conjunto de colunas de uma tabela ({ nome = true }); vazio se a tabela não existe.
local function columns(conn, tbl)
    local cols = {}
    local stmt = conn:prepare("PRAGMA table_info(" .. tbl .. ")")
    local row = stmt:step()
    while row do
        if row[2] then cols[tostring(row[2])] = true end
        row = stmt:step()
    end
    stmt:close()
    return cols
end

-- Monta o SELECT só com as colunas que existem (as ausentes viram NULL).
local function buildQuery(vcols, tcols)
    local has_title = vcols.title_id and tcols.id and tcols.name
    local function col(name) return vcols[name] and ("v." .. name) or "NULL" end
    local sql = "SELECT v.word, " .. (has_title and "t.name" or "NULL") .. ", "
        .. col("prev_context") .. ", " .. col("next_context") .. ", " .. col("highlight") .. ", "
        .. col("create_time") .. ", " .. col("streak_count")
        .. " FROM vocabulary v"
    if has_title then sql = sql .. " LEFT JOIN title t ON t.id = v.title_id" end
    sql = sql .. (vcols.create_time and " ORDER BY v.create_time, v.word" or " ORDER BY v.word")
    return sql
end

--[[--
Lê todas as palavras. Palavras repetidas (mesma chave, ex.: "Casa" e "casa")
viram uma só: fica a primeira (a mais antiga).
@param path caminho do banco (padrão: V.defaultPath())
@param opts { sq3 = módulo lua-ljsqlite3 (para testes), exists = função(path) }
--]]
function V.read(path, opts)
    opts = opts or {}
    path = path or V.defaultPath()
    local exists = opts.exists or function(p)
        local lfs = require("libs/libkoreader-lfs")
        return lfs.attributes(p, "mode") == "file"
    end
    if not exists(path) then return nil, "missing" end

    local SQ3 = opts.sq3 or require("lua-ljsqlite3/init")
    local ok_open, conn = pcall(SQ3.open, path, "ro")
    if not ok_open or not conn then return nil, "open_failed", conn end

    local ok, res, kind = pcall(function()
        local vcols = columns(conn, "vocabulary")
        if not vcols.word then return nil, "not_vocab" end
        local tcols = columns(conn, "title")
        local stmt = conn:prepare(buildQuery(vcols, tcols))
        local words, seen, raw = {}, {}, 0
        local row = stmt:step()
        while row do
            raw = raw + 1
            local word = trim(row[1])
            local key = V.keyFor(word)
            if key and not seen[key] then
                seen[key] = true
                words[#words + 1] = {
                    key = key,
                    word = word,
                    book = emptyToNil(row[2]),
                    prev = emptyToNil(row[3]),
                    next = emptyToNil(row[4]),
                    highlight = emptyToNil(row[5]),
                    created = tonumber(row[6]),
                    streak = tonumber(row[7]),
                }
            end
            row = stmt:step()
        end
        stmt:close()
        return { words = words, has_streak = vcols.streak_count == true, raw_count = raw }
    end)
    pcall(conn.close, conn)
    if not ok then return nil, "read_failed", res end
    if not res then return nil, kind end
    return res
end

-- Palavra conta como aprendida quando streak_count >= limite.
function V.isLearned(word, threshold)
    return word.streak ~= nil and word.streak >= (threshold or 5)
end

-- Aplica o filtro "só não aprendidas" (ignorado se o banco não tem streak_count).
function V.filter(res, opts)
    if not (opts and opts.only_unlearned and res.has_streak) then return res.words end
    local out = {}
    for _, w in ipairs(res.words) do
        if not V.isLearned(w, opts.learned_streak) then out[#out + 1] = w end
    end
    return out
end

return V
