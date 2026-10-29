"""Servidor de teste: executa SQLite (módulo sqlite3 do Python) para o shim
Lua tests/support/sq3_shim.lua, que imita a API do lua-ljsqlite3 usada pelo
plugin e pelo Anki Viewer. Só para testes no computador; não vai para o Kindle.

Protocolo: uma linha JSON por pedido no FIFO de entrada; uma linha com um
chunk Lua ("return {...}") por resposta no FIFO de saída.
"""
import json
import sqlite3
import sys


def lua_str(s):
    out = ['"']
    for b in s.encode("utf-8"):
        c = chr(b)
        if c == '"' or c == "\\":
            out.append("\\" + c)
        elif 32 <= b < 127:
            out.append(c)
        else:
            out.append("\\%03d" % b)
    out.append('"')
    return "".join(out)


def lua_val(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, bytes):
        return lua_str(v.decode("utf-8", "replace"))
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        parts = ["n=%d" % len(v)]
        for i, x in enumerate(v):
            if x is not None:
                parts.append("[%d]=%s" % (i + 1, lua_val(x)))
        return "{" + ",".join(parts) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("[%s]=%s" % (lua_str(k), lua_val(x)) for k, x in v.items()) + "}"
    raise TypeError(type(v))


conns = {}
stmts = {}
next_id = [0]


def new_id():
    next_id[0] += 1
    return next_id[0]


def run(conn, sql, params=()):
    try:
        return conn.execute(sql, params)
    except sqlite3.ProgrammingError as e:
        if "one statement" in str(e) and not params:
            conn.executescript(sql)
            return None
        raise


def handle(req):
    op = req["op"]
    a = req.get("args", [])
    if op == "open":
        path, mode = a[0], a[1] if len(a) > 1 else None
        if mode == "ro":
            conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, isolation_level=None)
        else:
            conn = sqlite3.connect(path, isolation_level=None)
        cid = new_id()
        conns[cid] = conn
        return cid
    if op == "close":
        conns.pop(a[0]).close()
        return None
    if op == "exec":
        cur = run(conns[a[0]], a[1])
        if cur is not None:
            cur.fetchall()
        return None
    if op == "rowexec":
        cur = run(conns[a[0]], a[1])
        row = cur.fetchone() if cur is not None else None
        return list(row) if row else None
    if op == "prepare":
        sid = new_id()
        stmts[sid] = {"conn": a[0], "sql": a[1], "params": (), "rows": None, "pos": 0, "desc": None}
        return sid
    if op == "bind":
        st = stmts[a[0]]
        st["params"] = tuple(a[1]) if a[1] else ()
        st["rows"] = None
        return None
    if op == "step":
        st = stmts[a[0]]
        if st["rows"] is None:
            cur = run(conns[st["conn"]], st["sql"], st["params"])
            st["rows"] = cur.fetchall() if cur is not None else []
            st["desc"] = [d[0] for d in cur.description] if cur is not None and cur.description else []
            st["pos"] = 0
        if st["pos"] >= len(st["rows"]):
            return None
        row = st["rows"][st["pos"]]
        st["pos"] += 1
        return list(row)
    if op == "resultset":
        st = stmts[a[0]]
        cur = run(conns[st["conn"]], st["sql"], st["params"])
        rows = cur.fetchall()
        names = [d[0] for d in cur.description] if cur.description else []
        return {"names": names, "rows": [list(r) for r in rows]}
    if op == "reset":
        st = stmts[a[0]]
        st["rows"] = None
        return None
    if op == "finalize":
        stmts.pop(a[0], None)
        return None
    raise ValueError("op desconhecida: " + op)


def main():
    req_path, resp_path = sys.argv[1], sys.argv[2]
    with open(req_path, "r", encoding="utf-8") as req_f, open(resp_path, "w", encoding="utf-8") as resp_f:
        for line in req_f:
            line = line.strip()
            if not line:
                continue
            req = json.loads(line)
            if req["op"] == "quit":
                break
            try:
                res = "return {ok=true, v=%s}" % lua_val(handle(req))
            except Exception as e:  # erro vira erro Lua do lado do shim
                res = "return {ok=false, err=%s}" % lua_str("%s: %s" % (type(e).__name__, e))
            resp_f.write(res.replace("\n", " ") + "\n")
            resp_f.flush()


if __name__ == "__main__":
    main()
