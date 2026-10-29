--[[--
Leitura dos destaques (highlights) dos livros do KOReader. SOMENTE LEITURA:
nada é gravado nos livros nem nos arquivos .sdr.

De onde vêm
* Livros: o histórico do KOReader (ReadHistory.hist, os livros já abertos).
* Destaques de cada livro: o arquivo de metadados ao lado do livro
  (DocSettings:open(arquivo)), chave "annotations" (KOReader 2024.04 em
  diante: { text, note, datetime, drawer, chapter, … }; marcadores não têm
  drawer e ficam de fora) ou, nos arquivos antigos, "highlight" (por página).
* O livro aberto agora: ui.annotation.annotations, que pode ter destaques
  ainda não gravados no .sdr.
O título vem de doc_props.title ou, sem ele, do nome do arquivo.

    local H = require("vocab2deck/highlight_reader")
    local res = H.read{ ui = self.ui }
    -- res = { highlights = { {key, word, book, note, created}, … }, books = n }
--]]

local U = require("vocab2deck/lib/u8")
local V = require("vocab2deck/vocab_reader")

local H = {}

-- Nome guardado em items.dict quando a definição é a nota do destaque.
H.NOTE_DICT = "Nota do destaque"

-- "2024-03-01 21:05:10" -> os.time
local function parseTime(s)
    local y, mo, d, h, mi, se = tostring(s or ""):match("^(%d+)%-(%d+)%-(%d+)%s+(%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(se) }
end

local function stem(file)
    return tostring(file or ""):match("([^/]+)%.[^./]*$") or tostring(file or ""):match("([^/]+)$")
end

local function clean(s)
    if type(s) ~= "string" then return nil end
    s = U.squash(s)
    if s == "" then return nil end
    return s
end

-- Destaques de uma lista de anotações (formato novo) ou da tabela antiga por página.
local function collect(out, annotations, old_highlight)
    if type(annotations) == "table" then
        for _, a in ipairs(annotations) do
            -- só destaques (com drawer); marcador de página não tem
            if type(a) == "table" and a.drawer and clean(a.text) then
                out[#out + 1] = { text = clean(a.text), note = clean(a.note), datetime = a.datetime }
            end
        end
        return
    end
    if type(old_highlight) == "table" then
        local pages = {}
        for page in pairs(old_highlight) do pages[#pages + 1] = page end
        table.sort(pages, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
        for _, page in ipairs(pages) do
            for _, hl in ipairs(old_highlight[page] or {}) do
                if type(hl) == "table" and clean(hl.text) then
                    out[#out + 1] = { text = clean(hl.text), datetime = hl.datetime }
                end
            end
        end
    end
end

-- Livros do histórico do KOReader, sem repetir.
function H.historyFiles()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or type(ReadHistory) ~= "table" then return {} end
    local out, seen = {}, {}
    for _, e in ipairs(ReadHistory.hist or {}) do
        if e.file and not seen[e.file] then
            seen[e.file] = true
            out[#out + 1] = e.file
        end
    end
    return out
end

-- Metadados de um livro: { annotations, highlight, doc_props } ou nil sem .sdr.
function H.openSidecar(file)
    local DocSettings = require("docsettings")
    if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(file) then return nil end
    local ds = DocSettings:open(file)
    return {
        annotations = ds:readSetting("annotations"),
        highlight = ds:readSetting("highlight"),
        doc_props = ds:readSetting("doc_props"),
    }
end

--[[--
Lê os destaques de todos os livros do histórico (e do livro aberto).
Textos repetidos (mesma chave da palavra, ver vocab_reader.keyFor) viram um só:
fica o mais antigo.
@param opts { ui, files = lista (padrão: histórico), open = função(file) -> metadados }
@treturn table { highlights, books, failed }
--]]
function H.read(opts)
    opts = opts or {}
    local open = opts.open or H.openSidecar
    local files = opts.files or H.historyFiles()
    local ui = opts.ui
    local current = ui and ui.document and ui.document.file
    if current then
        local listed = false
        for _, f in ipairs(files) do if f == current then listed = true end end
        if not listed then files[#files + 1] = current end
    end

    local found, books, failed = {}, 0, 0
    for _, file in ipairs(files) do
        local list = {}
        local title
        if file == current and ui.annotation and type(ui.annotation.annotations) == "table" then
            collect(list, ui.annotation.annotations)
            local props = ui.doc_props or {}
            title = props.display_title or props.title
        else
            local ok, meta = pcall(open, file)
            if not ok then
                failed = failed + 1
            elseif meta then
                collect(list, meta.annotations, meta.highlight)
                title = type(meta.doc_props) == "table" and meta.doc_props.title or nil
            end
        end
        if #list > 0 then
            books = books + 1
            title = clean(title) or stem(file)
            for _, h in ipairs(list) do
                h.book = title
                found[#found + 1] = h
            end
        end
    end

    local out, seen = {}, {}
    local order = {}
    for i, h in ipairs(found) do
        h.created = parseTime(h.datetime)
        h.ord = i
        order[i] = h
    end
    table.sort(order, function(a, b)
        if (a.created or 0) ~= (b.created or 0) then return (a.created or 0) < (b.created or 0) end
        return a.ord < b.ord
    end)
    for _, h in ipairs(order) do
        local key = V.keyFor(h.text)
        if key and not seen[key] then
            seen[key] = true
            out[#out + 1] = { key = key, word = h.text, book = h.book, note = h.note, created = h.created }
        end
    end
    return { highlights = out, books = books, failed = failed }
end

-- Trecho com mais de `n` palavras: não vale procurar no dicionário.
function H.isPassage(text, n)
    local count = 0
    for _ in tostring(text or ""):gmatch("%S+") do count = count + 1 end
    return count > (n or 3)
end

return H
