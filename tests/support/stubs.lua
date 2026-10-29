-- Substitutos dos módulos do KOReader que não são de interface, para rodar o
-- plugin (e o ankiviewer_db.lua do Anki Viewer) no computador. Os widgets vêm
-- de uistubs.lua (copiado do KR2Anki), que precisa ser carregado antes.

local M = { trapper_infos = {} }

local function preload(name, value)
    package.preload[name] = function() return value end
end

function M.install(opts)
    M.data_dir = opts.data_dir
    M.settings_dir = opts.settings_dir

    preload("gettext", function(s) return s end)
    preload("logger", { dbg = function() end, info = function() end, warn = function() end,
                        err = function(...) io.stderr:write("[logger.err] ", table.concat({ ... }, " "), "\n") end })
    preload("datastorage", {
        getDataDir = function() return M.data_dir end,
        getSettingsDir = function() return M.settings_dir end,
    })
    preload("ffi/util", {
        template = function(fmt, ...)
            local args = table.pack(...)
            return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
        joinPath = function(a, b) return a .. "/" .. b end,
    })
    preload("util", {
        makePath = function(p) return os.execute("mkdir -p '" .. p .. "'") end,
        trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
    })
    preload("libs/libkoreader-lfs", {
        attributes = function(p, what)
            local mode
            if os.execute("test -d '" .. p .. "'") then mode = "directory" end
            local f = io.open(p, "rb")
            local size
            if f then
                if not mode then mode = "file" end
                size = f:seek("end")
                f:close()
            end
            if what == "mode" then return mode end
            if what == "size" then return size end
            return mode and { mode = mode, size = size } or nil
        end,
        dir = function(d)
            local p = io.popen("ls -a '" .. d .. "'")
            local names = {}
            for line in p:lines() do names[#names + 1] = line end
            p:close()
            local i = 0
            return function() i = i + 1; return names[i] end
        end,
    })
    preload("lua-ljsqlite3/init", require("sq3_shim"))
    -- rapidjson do KOReader: o codec de testes do KR2Anki (com json.array e json.null)
    local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
    preload("rapidjson", dofile(here .. "/json.lua"))

    -- Trapper que pode simular o toque que interrompe (trapper_abort_at = n-ésimo aviso)
    preload("ui/trapper", {
        wrap = function(_, fn) return fn() end,
        info = function(_, text)
            M.trapper_infos[#M.trapper_infos + 1] = text
            if M.trapper_abort_at and #M.trapper_infos >= M.trapper_abort_at then return false end
            return true
        end,
        clear = function() end,
    })

    -- Menu (usado nas configurações e na lista de alterações): guarda os itens.
    local Widget = require("ui/widget/widget")
    local Menu = Widget:extend{ __kind = "menu" }
    function Menu:init() _G.LAST_menu = self end
    function Menu:switchItemTable(title, items) self.title = title or self.title; self.item_table = items end
    function Menu:updateItems() self.updated = (self.updated or 0) + 1 end
    function Menu:paintTo() end
    function Menu:getSize() return require("ui/geometry"):new{ w = 1, h = 1 } end
    preload("ui/widget/menu", Menu)
end

function M.reset()
    M.trapper_infos = {}
    M.trapper_abort_at = nil
end

return M
