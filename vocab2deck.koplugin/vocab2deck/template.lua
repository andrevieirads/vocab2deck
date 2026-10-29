--[[--
Modelo de campos (como o tipo de nota do Anki) e montagem do cartão.
Lógica pura, sem KOReader.

O modelo é uma lista de campos { id, name, side, source }:
  side   "front" | "back" | "none" (não aparece no cartão)
  source de onde vem o valor gerado:
         "word" (palavra) | "sentence" (frase de contexto) | "definition"
         (definição do dicionário) | "book" (título do livro) | "none" (vazio)
Os campos com source ~= "none" são do plugin: podem ser renomeados, mudar de
lado ou ser ocultados, mas não removidos. Os campos novos (source "none")
podem ser removidos.

Cada item pode ter:
  overrides[id] = texto  valor editado (vale no lugar do gerado)
  extras = { {id, name, value, side} }  campos só daquele cartão

O Anki Viewer mostra só texto, e ao mostrar a resposta troca a frente pelo
verso; por isso, com front_on_back, o verso repete a frente acima de B.SEPARATOR.
--]]

local B = require("vocab2deck/card_builder")
local U = require("vocab2deck/lib/u8")

local T = {}

T.SIDES = { "front", "back", "none" }
T.SIDE_NAME = { front = "frente", back = "verso", none = "não mostrar" }

function T.defaults()
    return {
        { id = "word", name = "Palavra", side = "front", source = "word" },
        { id = "sentence", name = "Frase", side = "front", source = "sentence" },
        { id = "definition", name = "Definição", side = "back", source = "definition" },
        { id = "book", name = "Livro", side = "back", source = "book" },
        { id = "notes", name = "Notas", side = "back", source = "none" },
    }
end

local function copy(list)
    local out = {}
    for i, f in ipairs(list) do out[i] = { id = f.id, name = f.name, side = f.side, source = f.source } end
    return out
end

--[[--
Modelo salvo nas configurações (chave "fields"). Na primeira vez, respeita as
opções antigas da versão 1 (include_context / include_book).
--]]
function T.load(settings)
    local saved = settings:get("fields")
    if type(saved) == "table" and #saved > 0 then return copy(saved) end
    local list = T.defaults()
    for _, f in ipairs(list) do
        if f.id == "sentence" and settings:get("include_context") == false then f.side = "none" end
        if f.id == "book" and settings:get("include_book") == false then f.side = "none" end
    end
    return list
end

function T.save(settings, list)
    settings:set("fields", copy(list))
end

-- Novo id para um campo criado pelo usuário.
function T.newId(list)
    local n = 0
    for _, f in ipairs(list) do
        local k = tonumber(tostring(f.id):match("^c(%d+)$"))
        if k and k > n then n = k end
    end
    return "c" .. (n + 1)
end

function T.isBuiltin(field)
    return field.source ~= nil and field.source ~= "none"
end

-- Definição padrão: os primeiros max_senses sentidos, numerados, ou a definição guardada.
function T.defaultDefinition(item, max_senses)
    local senses = item.senses or {}
    if #senses == 0 then return item.definition or "" end
    local n = math.min(#senses, math.max(1, tonumber(max_senses) or 3))
    if n == 1 then return senses[1] end
    local parts = {}
    for i = 1, n do parts[i] = i .. ". " .. senses[i] end
    return table.concat(parts, "\n")
end

-- Valor gerado de um campo do modelo.
function T.generated(item, field, opts)
    local src = field.source
    if src == "word" then return item.word or "" end
    if src == "sentence" then
        local s = B.contextSentence(item)
        return s and ("“" .. s.text .. "”") or ""
    end
    if src == "definition" then return T.defaultDefinition(item, opts and opts.max_senses) end
    if src == "book" then
        local b = item.book and U.squash(item.book) or ""
        return b ~= "" and ("— " .. b) or ""
    end
    return ""
end

--[[--
Campos do item, na ordem: os do modelo e depois os extras.
@treturn table { {id, name, value, side, source, extra, edited} }
--]]
function T.fields(item, list, opts)
    local out = {}
    local overrides = item.overrides or {}
    for _, f in ipairs(list) do
        local edited = overrides[f.id] ~= nil
        out[#out + 1] = {
            id = f.id, name = f.name, side = f.side, source = f.source, extra = false, edited = edited,
            value = edited and overrides[f.id] or T.generated(item, f, opts),
        }
    end
    for _, e in ipairs(item.extras or {}) do
        out[#out + 1] = { id = e.id, name = e.name, side = e.side, source = "none", extra = true, edited = true,
                          value = e.value or "" }
    end
    return out
end

-- Campo que conta como "o que o cartão ensina" no verso: a definição, ou um
-- campo escrito por você (campo seu, campo extra, ou campo do plugin editado).
-- A frase e o livro gerados sozinhos não contam.
local function teaches(f)
    if f.side ~= "back" then return false end
    if f.source == "definition" or f.source == "none" or f.extra then return true end
    return f.edited and f.source ~= "book"
end

--[[--
Texto curto do verso para listas: a definição, ou o primeiro campo escrito por
você no verso (ex.: Notas de um cartão criado no livro). nil se não houver.
--]]
function T.backPreview(fields)
    for _, f in ipairs(fields) do
        if f.source == "definition" and teaches(f) and U.trim(f.value or "") ~= "" then return f.value end
    end
    for _, f in ipairs(fields) do
        if teaches(f) and U.trim(f.value or "") ~= "" then return f.value end
    end
    return nil
end

--[[--
O cartão tem o que ensinar no verso? (definição ou um campo escrito por você)
Sem nenhum campo assim no modelo (ex.: Definição removida e nada no verso),
conta como sim: o verso é o que o modelo mandar.
--]]
function T.hasDefinition(fields)
    local any = false
    for _, f in ipairs(fields) do
        if teaches(f) then
            any = true
            if U.trim(f.value or "") ~= "" then return true end
        end
    end
    return not any
end

local function join(fields, side, placeholder)
    local parts = {}
    for _, f in ipairs(fields) do
        if f.side == side then
            local v = U.trim(f.value or "")
            if v == "" and f.source == "definition" and placeholder then v = B.PLACEHOLDER end
            if v ~= "" then parts[#parts + 1] = v end
        end
    end
    return table.concat(parts, "\n\n")
end

--[[--
Texto do cartão nos dois sentidos.
@param opts { front_on_back, missing_definition }
@treturn table { f = {front, back}, r = {front, back} }
--]]
function T.render(fields, opts)
    opts = opts or {}
    local placeholder = opts.missing_definition == "placeholder"
    local front = join(fields, "front", placeholder)
    local back = join(fields, "back", placeholder)
    local function withFront(shown_first, rest)
        if not opts.front_on_back or shown_first == "" then return rest end
        if rest == "" then return shown_first end
        return shown_first .. "\n\n" .. B.SEPARATOR .. "\n\n" .. rest
    end
    return {
        f = { front = front, back = withFront(front, back) },
        r = { front = back, back = withFront(back, front) },
    }
end

return T
