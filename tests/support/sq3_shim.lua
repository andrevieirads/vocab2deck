-- Imitação da API do lua-ljsqlite3 (a parte usada pelo plugin e pelo Anki
-- Viewer) que executa o SQL de verdade no sqlite3 do Python, via dois FIFOs.
-- Só para testes no computador (aqui não há LuaJIT nem FFI).

local M = {}

local req_f, resp_f

local function jstr(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function json(v)
    local t = type(v)
    if v == nil then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if math.type and math.type(v) == "integer" then return tostring(v) end
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.17g", v)
    elseif t == "string" then return jstr(v)
    elseif t == "table" then
        local n = v.n or #v
        local parts = {}
        for i = 1, n do parts[i] = json(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    error("json: tipo não suportado " .. t)
end

local function call(op, ...)
    local args = table.pack(...)
    req_f:write('{"op":' .. jstr(op) .. ',"args":' .. json(args) .. "}\n")
    req_f:flush()
    local line = resp_f:read("l")
    if not line then error("bridge sqlite3 encerrou") end
    local res = assert(load(line))()
    if not res.ok then error(res.err, 2) end
    return res.v
end

function M.start(workdir)
    local req, resp = workdir .. "/req.fifo", workdir .. "/resp.fifo"
    os.remove(req); os.remove(resp)
    assert(os.execute("mkfifo '" .. req .. "' '" .. resp .. "'"))
    local bridge = debug.getinfo(1, "S").source:sub(2):gsub("sq3_shim%.lua$", "sq3_bridge.py")
    assert(os.execute("python3 -I '" .. bridge .. "' '" .. req .. "' '" .. resp .. "' &"))
    req_f = assert(io.open(req, "w"))
    resp_f = assert(io.open(resp, "r"))
end

function M.stop()
    if req_f then
        req_f:write('{"op":"quit"}\n'); req_f:flush(); req_f:close(); resp_f:close()
        req_f, resp_f = nil, nil
    end
end

local Stmt = {}
Stmt.__index = Stmt

function Stmt:bind(...) call("bind", self.id, table.pack(...)); return self end
function Stmt:step()
    local row = call("step", self.id)
    if row then row.n = nil end
    return row
end
function Stmt:reset() call("reset", self.id); return self end
function Stmt:clearbind() return self end
function Stmt:close() call("finalize", self.id) end
-- resultset("hik"): [0] = nomes, [i] = valores da coluna i, [nome] = idem; e o número de linhas
function Stmt:resultset()
    local r = call("resultset", self.id)
    local out = { [0] = {} }
    for i = 1, r.names.n do
        out[0][i] = r.names[i]
        out[i] = {}
        out[r.names[i]] = out[i]
    end
    local nrows = r.rows.n
    for j = 1, nrows do
        local row = r.rows[j]
        for i = 1, r.names.n do out[i][j] = row[i] end
    end
    if nrows == 0 then return nil, 0 end
    return out, nrows
end

local Conn = {}
Conn.__index = Conn

function M.open(path, mode)
    return setmetatable({ id = call("open", path, mode) }, Conn)
end
function Conn:exec(sql) call("exec", self.id, sql) end
function Conn:rowexec(sql)
    local row = call("rowexec", self.id, sql)
    if not row then return nil end
    return table.unpack(row, 1, row.n)
end
function Conn:prepare(sql) return setmetatable({ id = call("prepare", self.id, sql) }, Stmt) end
function Conn:set_busy_timeout() end
function Conn:close() call("close", self.id) end

return M
