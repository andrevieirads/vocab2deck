--[[--
Peças comuns dos cartões. Lógica pura, sem KOReader.
O texto da frente/verso é montado pelos campos (template.lua); aqui ficam a
frase de contexto, o nome do baralho, os lados e a chave no Anki Viewer.

Lados: "f" (frente → verso) e, com "os dois sentidos", "r" (verso → frente).
A frase de contexto é recortada do prev/next_context com kr2anki/sentence.lua.
--]]

local S = require("vocab2deck/lib/sentence")
local U = require("vocab2deck/lib/u8")

local B = {}

B.PLACEHOLDER = "(sem definição — edite este cartão)"
B.SEPARATOR = "――――――"

-- Idioma aproximado pela escrita da palavra (só muda como a frase é recortada).
function B.detectLang(word)
    local sc = U.scripts(word or "")
    if sc.kana > 0 then return "ja" end
    if sc.han > 0 then return "zh" end
    if sc.hangul > 0 then return "ko" end
    return "en"
end

--[[--
Frase de contexto da palavra (item com word, prev, next, highlight).
@param opts { extra, max_words, max_cjk } (ver sentence.extract)
@treturn table|nil { text, hl_start, hl_end } (posições em bytes) ou nil sem contexto
--]]
function B.contextSentence(row, opts)
    if not row.prev and not row.next then return nil end
    local o = {
        prev = row.prev, selection = row.highlight or row.word, next = row.next, lang = B.detectLang(row.word),
    }
    for k, v in pairs(opts or {}) do o[k] = v end
    local ok, r = pcall(S.extract, o)
    if not ok or not r or r.missing or U.trim(r.text or "") == "" then return nil end
    return r
end

-- Nome do baralho de destino: com "um baralho por livro", o título do livro;
-- senão (ou sem livro), o baralho das configurações.
function B.deckName(opts, book)
    local base = opts.deck_name or "Vocabulary Builder"
    if opts.subdeck_per_book and book and U.trim(book) ~= "" then
        -- "::" no título viraria hierarquia num Anki de verdade; troca por ":"
        return (U.squash(book):gsub("::+", ":"))
    end
    return base
end

-- Lados desejados pelas configurações.
function B.sides(opts)
    if opts.both_directions then return { "f", "r" } end
    return { "f" }
end

-- Chave gravada em cards.source_key do Anki Viewer (única por palavra e lado).
function B.sourceKey(vkey, side)
    return "vocab2deck:" .. side .. ":" .. vkey
end

return B
