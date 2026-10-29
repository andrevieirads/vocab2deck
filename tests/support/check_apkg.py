"""Confere um .apkg gerado pelo plugin sem a biblioteca do Anki (só testes).
uso: python3 -I check_apkg.py pacote.apkg
Imprime uma linha "chave=valor" por verificação; o run.lua compara.
Inclui a consulta exata que o importador do Anki fez na revlog (o erro
"no such column: ease" do pacote do KR2Anki)."""
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
import zipfile

path = sys.argv[1]
z = zipfile.ZipFile(path)
print("zip_ok=%s" % (z.testzip() is None))
print("entries=%s" % ",".join(sorted(z.namelist())))
print("media=%s" % z.read("media").decode())
d = tempfile.mkdtemp()
col_path = os.path.join(d, "collection.anki2")
with open(col_path, "wb") as f:
    f.write(z.read("collection.anki2"))
c = sqlite3.connect(col_path)

# a consulta do erro no Anki
c.execute("SELECT id, cid, usn, ease, cast(ivl AS integer), cast(lastIvl AS integer), factor, time, type FROM revlog").fetchall()
print("revlog_query=ok")
cols = [r[1] for r in c.execute("PRAGMA table_info(revlog)")]
print("revlog_cols=%s" % ",".join(cols))

ver, models, decks = c.execute("SELECT ver, models, decks FROM col").fetchone()
print("ver=%d" % ver)
models, decks = json.loads(models), json.loads(decks)
m = list(models.values())[0]
print("model=%s fields=%s" % (m["name"], ",".join(f["name"] for f in m["flds"])))
print("afmt_frontside=%s" % ("{{FrontSide}}" in m["tmpls"][0]["afmt"]))
print("arrays_ok=%s" % (isinstance(m["req"], list) and isinstance(m["flds"][0]["media"], list) and isinstance(m["tags"], list)))
names = {int(k): v["name"] for k, v in decks.items()}
print("decks=%s" % "|".join(sorted(names.values())))

notes = c.execute("SELECT id, guid, mid, flds, sfld, csum FROM notes ORDER BY id").fetchall()
print("notes=%d" % len(notes))
print("csum_ok=%s" % all(n[5] == int(hashlib.sha1(n[4].encode()).hexdigest()[:8], 16) for n in notes))
print("mid_ok=%s" % all(str(n[2]) in models for n in notes))
cards = c.execute("SELECT nid, did, ord, type, queue FROM cards").fetchall()
print("cards=%d" % len(cards))
print("cards_in_known_decks=%s" % all(cd[1] in names for cd in cards))
by_nid = {cd[0]: cd for cd in cards}
for n in notes:
    front, back = n[3].split("\x1f")
    print("note=%s|%s|%s|%s" % (n[1], names[by_nid[n[0]][1]], front, back))
