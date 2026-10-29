-- Substituto do módulo "bit" do LuaJIT (só para os testes no Lua 5.3+), com a
-- mesma semântica de 32 bits: tobit devolve inteiros com sinal, as outras
-- operações trabalham sobre os 32 bits de baixo.
local M = {}

local function u(x)
    return math.tointeger(math.floor(x) % 0x100000000)
end

function M.tobit(x)
    local v = u(x)
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

function M.band(a, b, ...)
    local r = u(a) & u(b)
    for _, c in ipairs({ ... }) do r = r & u(c) end
    return M.tobit(r)
end
function M.bor(a, b, ...)
    local r = u(a) | u(b)
    for _, c in ipairs({ ... }) do r = r | u(c) end
    return M.tobit(r)
end
function M.bxor(a, b, ...)
    local r = u(a) ~ u(b)
    for _, c in ipairs({ ... }) do r = r ~ u(c) end
    return M.tobit(r)
end
function M.bnot(a) return M.tobit(~u(a) & 0xFFFFFFFF) end
function M.lshift(a, n) return M.tobit((u(a) << (n % 32)) & 0xFFFFFFFF) end
function M.rshift(a, n) return M.tobit(u(a) >> (n % 32)) end
function M.rol(a, n)
    n = n % 32
    local v = u(a)
    return M.tobit(((v << n) | (v >> (32 - n))) & 0xFFFFFFFF)
end

return M
