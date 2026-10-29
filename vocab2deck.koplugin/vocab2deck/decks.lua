--[[--
Nomes e hierarquia dos baralhos. Lógica pura, sem KOReader.

Sub-baralhos usam o separador do Anki: "Inglês::Verbos" é o baralho Verbos
dentro de Inglês. O banco do Anki Viewer guarda só o nome completo (decks.name),
então criar um sub-baralho, renomear ou mover um baralho é trocar nomes:
mover "Verbos" para dentro de "Inglês" = renomear "Verbos" para
"Inglês::Verbos", e os sub-baralhos dele vão junto.
--]]

local U = require("vocab2deck/lib/u8")

local D = {}

D.SEP = "::"

-- Partes de um nome ("A::B" -> { "A", "B" }), sem espaços sobrando nem partes vazias.
function D.parts(name)
    local out = {}
    for raw in (tostring(name or "") .. D.SEP):gmatch("(.-)" .. D.SEP) do
        local part = U.squash(raw)
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

-- Nome limpo ("  A :: B " -> "A::B"); nil se ficar vazio.
function D.normalize(name)
    local parts = D.parts(name)
    if #parts == 0 then return nil end
    return table.concat(parts, D.SEP)
end

-- Último nível ("A::B" -> "B").
function D.leaf(name)
    local parts = D.parts(name)
    return parts[#parts] or ""
end

-- Baralho de cima ("A::B" -> "A"; "A" -> nil).
function D.parent(name)
    local parts = D.parts(name)
    if #parts < 2 then return nil end
    table.remove(parts)
    return table.concat(parts, D.SEP)
end

function D.depth(name)
    return math.max(0, #D.parts(name) - 1)
end

-- Junta o baralho de cima (ou nil = topo) e um nome.
function D.join(parent, name)
    if not parent or parent == "" then return D.normalize(name) end
    return D.normalize(parent .. D.SEP .. name)
end

-- name é o próprio ancestor ou está dentro dele (em qualquer nível).
function D.isWithin(name, ancestor)
    if not name or not ancestor then return false end
    return name == ancestor or name:sub(1, #ancestor + #D.SEP) == ancestor .. D.SEP
end

-- Nome depois de renomear old -> new (vale para old e tudo dentro dele); nil se não muda.
function D.renamed(name, old, new)
    if not D.isWithin(name, old) then return nil end
    return new .. name:sub(#old + 1)
end

--[[--
Baralhos em árvore, na ordem de leitura (cada um seguido dos de dentro dele).
Um baralho de cima que não existe no banco (ex.: só "A::B" existe) entra
como linha sem id, para a árvore não ficar sem o pai.
@param decks { {id, name, cards, due, …} }
@treturn table a mesma lista, ordenada, com depth, label (último nível),
  children (quantos logo abaixo) e total_cards / total_due (com os de dentro)
--]]
function D.tree(decks)
    local by_name, list = {}, {}
    for _, d in ipairs(decks or {}) do
        local copy = {}
        for k, v in pairs(d) do copy[k] = v end
        copy.name = D.normalize(d.name) or d.name
        by_name[copy.name] = copy
        list[#list + 1] = copy
    end
    for _, d in ipairs(list) do
        local p = D.parent(d.name)
        while p and not by_name[p] do
            local ghost = { name = p, cards = 0, due = 0, ghost = true }
            by_name[p] = ghost
            list[#list + 1] = ghost
            p = D.parent(p)
        end
    end
    for _, d in ipairs(list) do
        d.depth = D.depth(d.name)
        d.label = D.leaf(d.name)
        d.children = 0
        d.total_cards, d.total_due = 0, 0
    end
    for _, d in ipairs(list) do
        local p = D.parent(d.name)
        if p then by_name[p].children = by_name[p].children + 1 end
        -- soma no próprio e em todos os de cima
        local n = d.name
        while n do
            local a = by_name[n]
            a.total_cards = a.total_cards + (d.cards or 0)
            a.total_due = a.total_due + (d.due or 0)
            n = D.parent(n)
        end
    end
    local function key(d)
        local parts = D.parts(d.name)
        for i, p in ipairs(parts) do parts[i] = p:lower() end
        return parts
    end
    table.sort(list, function(a, b)
        local ka, kb = key(a), key(b)
        for i = 1, math.min(#ka, #kb) do
            if ka[i] ~= kb[i] then return ka[i] < kb[i] end
        end
        return #ka < #kb
    end)
    return list
end

-- Baralho e todos os de dentro dele, a partir da árvore.
function D.subtree(tree, name)
    local out = {}
    for _, d in ipairs(tree or {}) do
        if D.isWithin(d.name, name) then out[#out + 1] = d end
    end
    return out
end

return D
