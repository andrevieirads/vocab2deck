--[[--
Proteção contra crash: toda ação disparada pela interface passa por aqui.
Um erro é registrado no log do KOReader e mostrado como mensagem na tela.

Adaptado de kr2anki/safe.lua (KR2Anki).
--]]

local Safe = {}

local function logger()
    local ok, l = pcall(require, "logger")
    return ok and l or { err = function(...) print(...) end, warn = function(...) print(...) end }
end

function Safe.message(text, timeout)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok then return end
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- Primeira linha do erro, sem o prefixo "arquivo.lua:123: ".
function Safe.shortError(err)
    local msg = tostring(err):match("^[^\n]*") or tostring(err)
    return (msg:gsub("^.-%.lua:%d+: ", ""))
end

-- Executa fn(...) protegido. Em caso de erro: loga, avisa o usuário e retorna nil.
function Safe.run(what, fn, ...)
    local ok, a, b, c = xpcall(fn, debug.traceback, ...)
    if ok then return a, b, c end
    logger().err("vocab2deck:", what, "falhou:", a)
    Safe.message("Vocabulário → Flashcards: " .. what .. " falhou.\n\n" .. Safe.shortError(a))
    return nil
end

-- Embrulha um callback para que ele sempre rode protegido.
function Safe.wrap(what, fn)
    return function(...)
        return Safe.run(what, fn, ...)
    end
end

function Safe.log(...)
    logger().warn("vocab2deck:", ...)
end

return Safe
