--[[--
Busca da definição nos dicionários instalados (StarDict), sem abrir popup.

O Vocabulary Builder não guarda a definição: guarda só a palavra e o
contexto. Por isso, como o KR2Anki faz ao importar do Vocabulary Builder,
cada palavra nova é consultada de novo nos dicionários ativos.

* A chamada ReaderDictionary:startSdcv(word, dict.enabled_dict_names, false)
  e o filtro dos resultados vêm de kr2anki/capture.lua (C.silentLookup).
* A limpeza do HTML e a separação em sentidos usam kr2anki/dictparse.lua com
  o perfil genérico (P.GENERIC).
--]]

local P = require("vocab2deck/lib/dictparse")
local U = require("vocab2deck/lib/u8")

local L = {}

L.MAX_CHARS = 700 -- o Anki Viewer corta com "…" e mostra o texto inteiro ao tocar no cartão

-- Resultados válidos de uma busca silenciosa (lista vazia se nada foi achado).
function L.silentLookup(dict, word)
    if not (dict and dict.startSdcv) then return nil, "no_dictionary" end
    local ok, results = pcall(dict.startSdcv, dict, word, dict.enabled_dict_names, false)
    if not ok or type(results) ~= "table" then
        return nil, "lookup_failed", results
    end
    local out = {}
    for _, r in ipairs(results) do
        if not r.no_result and not r.is_wiki and r.dict and r.dict ~= ""
                and type(r.definition) == "string" and r.definition ~= "" then
            out[#out + 1] = r
        end
    end
    return out
end

--[[--
Texto da definição a partir de um resultado de dicionário: até max_senses
sentidos numerados ("1. …"), ou o texto limpo inteiro se não houver sentidos.
--]]
function L.definitionText(raw, headword, max_senses)
    max_senses = math.max(1, tonumber(max_senses) or 3)
    local ok, parsed = pcall(P.parse, raw, P.GENERIC, { headword = headword })
    local text
    if ok and parsed and parsed.senses and #parsed.senses > 0 then
        local parts = {}
        local n = math.min(#parsed.senses, max_senses)
        for i = 1, n do
            local s = parsed.senses[i]
            local line = U.squash(s.text or "")
            if s.pos and s.pos ~= "" then line = "(" .. s.pos .. ") " .. line end
            parts[#parts + 1] = n > 1 and (i .. ". " .. line) or line
        end
        text = table.concat(parts, "\n")
    else
        text = P.clean(raw)
    end
    text = U.trim(text)
    if U.len(text) > L.MAX_CHARS then text = U.ellipsize(text, L.MAX_CHARS) end
    return text
end

L.MAX_SENSES_KEPT = 8 -- sentidos guardados para escolher na revisão

-- Sentidos de um resultado (texto limpo de cada um, com a classe gramatical).
function L.senses(raw, headword)
    local ok, parsed = pcall(P.parse, raw, P.GENERIC, { headword = headword })
    local out = {}
    if ok and parsed and parsed.senses then
        for i, s in ipairs(parsed.senses) do
            if i > L.MAX_SENSES_KEPT then break end
            local line = U.squash(s.text or "")
            if s.pos and s.pos ~= "" then line = "(" .. s.pos .. ") " .. line end
            if line ~= "" then
                if U.len(line) > L.MAX_CHARS then line = U.ellipsize(line, L.MAX_CHARS) end
                out[#out + 1] = line
            end
        end
    end
    if #out == 0 then
        local clean = U.trim(P.clean(raw))
        if clean ~= "" then out[1] = U.len(clean) > L.MAX_CHARS and U.ellipsize(clean, L.MAX_CHARS) or clean end
    end
    return out
end

--[[--
Definição de uma palavra.
@treturn table|nil { definition, senses = {…}, dict, headword } ou nil quando não há definição
@treturn string|nil motivo do erro ("no_dictionary" | "lookup_failed")
--]]
function L.lookup(dict, word, max_senses)
    local results, err, detail = L.silentLookup(dict, word)
    if not results then return nil, err, detail end
    for _, r in ipairs(results) do
        local text = L.definitionText(r.definition, r.word or word, max_senses)
        if text ~= "" then
            return { definition = text, senses = L.senses(r.definition, r.word or word), dict = r.dict, headword = r.word }
        end
    end
    return nil
end

return L
