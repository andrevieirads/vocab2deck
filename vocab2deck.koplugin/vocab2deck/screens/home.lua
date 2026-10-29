--[[--
Início: o que estudar hoje, por onde as palavras passam e os baralhos.

* Cabeçalho "VOCABULÁRIO / Flashcards", com ⋮ (Campos · Importar · Configurações).
* PARA ESTUDAR HOJE: cartões para estudar nos baralhos deste plugin e "Estudar agora".
* DO KINDLE PARA O ANKI: Vocabulário | Destaques → ○ Inbox → ● Revisados →
  ✓ No baralho | × Descartados (Vocabulário abre o Vocabulary Builder do
  KOReader; os outros abrem a lista); avisos; Revisar (N) /
  Exportar (N) quando há o que fazer; "Atualizar N cartões alterados…".
* BARALHOS: todos os do Anki Viewer embutido, em árvore (sub-baralhos com
  recuo; tocar estuda; toque longo: sub-baralho, renomear, mover, apagar…).
* Barra de baixo: Adicionar (cartão ou baralho) · Buscar · Sincronizar (Vocabulary Builder +
  destaques -> Inbox; No baralho -> Anki Viewer) · Importar.
Em paisagem, os baralhos vão para uma coluna à direita.
O kit e o padrão das telas são os do KR2Anki (kr2anki/screens/home.lua).
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("vocab2deck/ui/screen")
local Decks = require("vocab2deck/decks")
local Kit = require("vocab2deck/ui/kit")
local _ = require("gettext")
local T = require("ffi/util").template

local Home = BaseScreen:extend{ name = "vocab2deck_home" }

function Home:setup()
    self:loadData()
end

function Home:loadData()
    -- antes de contar: leva para o Anki Viewer o que mudou nos cartões já no baralho
    self.host:autoUpdate()
    self.counts = self.host:getStore():counts()
    self.sources = self.host:getStore():sourceCounts()
    self.pending = self.host:pendingChanges()
    self.decks = self.host:allDecks()
    self.tree = Decks.tree(self.decks)
end

function Home:onDataChanged()
    self:loadData()
end

function Home:browse(status)
    self.app:open("vocab2deck/screens/items", {
        filter = { statuses = { [status] = true } },
        title = Kit.SYMBOL[status] .. " " .. Kit.STATUS_NAME[status],
    })
end

-- Lista de uma fonte (Destaques), com o status de cada item.
function Home:browseSource(source)
    self.app:open("vocab2deck/screens/items", {
        filter = { source = source },
        title = source == "vocab" and _("Vocabulary Builder") or _("Destaques"),
    })
end

-- Avisos curtos: o que a última leitura do Vocabulary Builder trouxe, erros, pendências.
function Home:notes()
    local out = {}
    local s = self.host.last_sync
    if s and s.error then
        out[#out + 1] = s.error
    elseif s and s.added > 0 then
        out[#out + 1] = T(_("○ %1 palavras novas vieram do Vocabulary Builder."), s.added)
    end
    local hl = self.host.last_highlights
    if hl and hl.error then
        out[#out + 1] = hl.error
    elseif hl and hl.added > 0 then
        out[#out + 1] = T(_("○ %1 destaques novos vieram dos livros."), hl.added)
    end
    local a = self.host.last_auto
    if a and a.updated > 0 then
        out[#out + 1] = T(_("✓ %1 cartões atualizados no Anki Viewer (progresso mantido)."), a.updated)
    end
    if a and a.moved > 0 then
        out[#out + 1] = T(_("✓ %1 cartões movidos para o baralho certo (progresso mantido)."), a.moved)
    end
    if self.pending.deleted > 0 then
        out[#out + 1] = T(_("%1 cartões apagados no Anki Viewer (Sincronizar os cria de novo)."), self.pending.deleted)
    end
    if s and s.filter_note then out[#out + 1] = s.filter_note end
    return out
end

-- Para estudar hoje: os baralhos deste plugin (todos, se ainda não exportou nada).
function Home:today()
    local pool = {}
    for _, d in ipairs(self.decks or {}) do
        if d.ours then pool[#pool + 1] = d end
    end
    if #pool == 0 then pool = self.decks or {} end
    local due, with_due = 0, {}
    for _, d in ipairs(pool) do
        due = due + (d.due or 0)
        if (d.due or 0) > 0 then with_due[#with_due + 1] = d end
    end
    local where
    if due == 0 then
        where = #pool == 0 and _("nenhum baralho ainda") or _("tudo em dia")
    elseif #with_due == 1 then
        where = T(_("no baralho %1"), with_due[1].name)
    else
        where = T(_("em %1 baralhos"), #with_due)
    end
    return due, where
end

local function plural(n, one, many) return n == 1 and one or many end

-- Cabeçalho: ‹  VOCABULÁRIO / Flashcards  ……  ⋮
function Home:header(w)
    local h = Kit.dp(68)
    local back = Kit.tap(Kit.box(Kit.TAP, h, Kit.icon("chevron_left", Kit.dp(20))), function() self:onClose() end)
    local titles = VerticalGroup:new{
        align = "left",
        Kit.text(_("VOCABULÁRIO"), Kit.uiBold(Kit.SIZE.tiny - 1), { fgcolor = Kit.GREY_DARK }),
        Kit.text(_("Flashcards"), Kit.uiBold(Kit.SIZE.title + 4), {}),
    }
    local menu = Kit.tap(Kit.box(Kit.TAP, h, Kit.icon("menu", Kit.dp(22))), function() self:showMenu() end)
    return VerticalGroup:new{
        align = "left",
        Kit.spread(w, h, HorizontalGroup:new{ align = "center", back, titles }, menu),
        Kit.hline(w, Kit.dp(2)),
    }
end

-- ⋮ : Campos · Importar · Configurações
function Home:showMenu()
    local dialog
    local function item(text, fn)
        return { { text = text, callback = function() UIManager:close(dialog); fn() end } }
    end
    dialog = ButtonDialog:new{
        buttons = {
            item(_("Campos"), function() self.app:open("vocab2deck/screens/model", {}) end),
            item(_("Importar"), function() self.host:importApkg() end),
            item(_("Configurações"), function() self.host:showSettings() end),
            { { text = _("Fechar"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

-- PARA ESTUDAR HOJE: número grande, "cartões / no baralho X" e Estudar agora.
function Home:todaySection(cw)
    local due, where = self:today()
    local num = Kit.text(tostring(due), Kit.uiBold(Kit.SIZE.big + 6), {})
    local num_w = num:getSize().w
    local gap = Kit.dp(12)
    local words = VerticalGroup:new{
        align = "left",
        Kit.text(plural(due, _("cartão"), _("cartões")), Kit.serif(Kit.SIZE.body), {}),
        Kit.text(where, Kit.serif(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK, max_width = cw - num_w - gap }),
    }
    return VerticalGroup:new{
        align = "left",
        Kit.sectionLabel(_("Para estudar hoje"), cw),
        HorizontalGroup:new{ align = "center", num, Kit.hspan(gap), words },
        Kit.vspan(Kit.dp(12)),
        Kit.button{ text = _("Estudar agora"), primary = true, width = cw, size = Kit.SIZE.body + 2,
                    callback = function() self.host:studyNow() end },
    }
end

-- DO KINDLE PARA O ANKI: as duas fontes e os quatro status lado a lado, com setas de fluxo.
function Home:funnelSection(cw)
    local c, src = self.counts, self.sources
    local border = Kit.dp(2)
    local h = Kit.dp(96)
    local sep_w = Kit.dp(10)
    local inner = cw - 2 * border
    local cell_w = math.floor((inner - 5 * sep_w) / 6)
    local function cell(label, value, on_tap)
        local zero = value == 0
        local font = zero and Kit.ui or Kit.uiBold
        -- nome que não cabe na caixa: letra um pouco menor antes de cortar
        local size = Kit.SIZE.tiny - 1
        if Kit.text(label, font(size), {}):getSize().w > cell_w - Kit.dp(4) then size = size - 2 end
        local group = VerticalGroup:new{
            align = "center",
            Kit.text(tostring(value), Kit.uiBold(Kit.SIZE.title + 6), { fgcolor = zero and Kit.GREY_LIGHT or Kit.BLACK,
                max_width = cell_w }),
            Kit.text(label, font(size), { fgcolor = zero and Kit.GREY_DARK or Kit.BLACK, max_width = cell_w }),
        }
        return Kit.tap(Kit.box(cell_w, h, group), on_tap)
    end
    local function status(st, label)
        return cell(label, c[st], function() self:browse(st) end)
    end
    local function source(key, label)
        return cell(label, src[key], function()
            -- Vocabulário abre o Vocabulary Builder original; Destaques, a lista do plugin
            if key == "vocab" then self.host:openVocabBuilder() else self:browseSource(key) end
        end)
    end
    local function sep(arrow)
        local bar = math.floor((h - Kit.dp(24)) / 2) - Kit.dp(10)
        if not arrow then
            return Kit.box(sep_w, h, Kit.vline(h - Kit.dp(24), Kit.dp(1), Kit.GREY_LIGHT))
        end
        return Kit.box(sep_w, h, VerticalGroup:new{
            align = "center",
            Kit.vline(bar, Kit.dp(1), Kit.GREY_LIGHT),
            Kit.vspan(Kit.dp(4)),
            Kit.icon("chevron_right", Kit.dp(9)),
            Kit.vspan(Kit.dp(4)),
            Kit.vline(bar, Kit.dp(1), Kit.GREY_LIGHT),
        })
    end
    local row = HorizontalGroup:new{
        align = "center",
        source("vocab", _("Vocabulário")), sep(false),
        source("highlights", _("Destaques")), sep(true),
        status("inbox", _("Inbox")), sep(true),
        status("ready", _("Revisados")), sep(true),
        status("deck", _("No baralho")), sep(false),
        status("discarded", _("Descartados")),
    }
    return VerticalGroup:new{
        align = "left",
        Kit.sectionLabel(_("Do Kindle para o Anki"), cw),
        Kit.bordered(row, { border = border, padding = 0 }),
    }
end

-- Avisos e o que há para fazer: Revisar / Exportar, Atualizar alterados.
function Home:actionsSection(cw)
    local g = VerticalGroup:new{ align = "left" }
    local lines = self:notes()
    if #lines == 0 and self.counts.inbox == 0 and self.counts.ready == 0 then
        lines = { _("Nenhuma palavra nova para revisar.") }
    end
    for i, line in ipairs(lines) do
        if i > 1 then table.insert(g, Kit.vspan(Kit.dp(4))) end
        table.insert(g, Kit.textbox(line, Kit.serifItalic(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK, max_lines = 3 }))
    end
    if self.counts.inbox > 0 or self.counts.ready > 0 then
        table.insert(g, Kit.vspan(Kit.dp(10)))
        table.insert(g, Kit.buttonRow(cw + 2 * Kit.PAD, {
            { text = T(_("Revisar (%1)"), self.counts.inbox), enabled = self.counts.inbox > 0,
              callback = function() self.host:openReview() end },
            { text = T(_("Exportar (%1)"), self.counts.ready),
              callback = function() self.host:openExport() end },
        }, { size = Kit.SIZE.small }))
    end
    if #self.pending.changed > 0 then
        table.insert(g, Kit.vspan(Kit.dp(10)))
        table.insert(g, Kit.button{
            text = T(_("Atualizar %1 cartões alterados…"), #self.pending.changed), width = cw, size = Kit.SIZE.small,
            callback = function() self.host:askChanges(self.pending.changed) end,
        })
    end
    return g
end

--[[--
Uma linha da lista de baralhos: nome (sub-baralho com recuo), "N cartões ·
em dia", bolinha com os para estudar, ›. Os números incluem os sub-baralhos.
--]]
function Home:deckRow(d, width)
    local h = Kit.dp(70)
    local due, n = d.total_due or d.due or 0, d.total_cards or d.cards or 0
    local right = HorizontalGroup:new{ align = "center" }
    if due > 0 then
        table.insert(right, Kit.badge(due))
        table.insert(right, Kit.hspan(Kit.dp(12)))
    end
    table.insert(right, Kit.icon("chevron_right", Kit.dp(16)))
    local cards = T(plural(n, _("%1 cartão"), _("%1 cartões")), n)
    local sub = due > 0 and cards or T(_("%1 · em dia"), cards)
    if (d.children or 0) > 0 then
        sub = T(plural(d.children, _("%1 · %2 sub-baralho"), _("%1 · %2 sub-baralhos")), sub, d.children)
    end
    local indent = math.min(d.depth or 0, 4) * Kit.dp(22)
    local label_w = width - indent - right:getSize().w - Kit.dp(16)
    local left = VerticalGroup:new{
        align = "left",
        Kit.text(d.label or d.name, Kit.serif(Kit.SIZE.body + 1), { max_width = label_w }),
        Kit.text(sub, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = label_w }),
    }
    if indent > 0 then left = HorizontalGroup:new{ align = "center", Kit.hspan(indent), left } end
    local tree = self.tree
    return Kit.tap(Kit.spread(width, h, left, right),
        function() require("vocab2deck/ui").studyFromTree(self.host, tree, d) end,
        function() self.host:deckOptions(d) end)
end

--[[--
BARALHOS. Mostra quantos couberem em `room`; se não couberem todos, a última
linha abre a lista inteira.
--]]
function Home:decksSection(width, room)
    local decks = self.tree or {}
    local head = VerticalGroup:new{
        align = "left",
        Kit.sectionLabel(_("Baralhos"), width),
        Kit.hline(width, Kit.dp(1.5)),
    }
    if #decks == 0 then
        return VerticalGroup:new{
            align = "left", head, Kit.vspan(Kit.dp(8)),
            Kit.textbox(_("Nenhum baralho ainda. Exporte os Revisados, toque em Importar ou em Adicionar ▸ Adicionar baralho."),
                Kit.serifItalic(Kit.SIZE.small), width, { fgcolor = Kit.GREY_DARK, max_lines = 2 }),
        }
    end
    local sample = self:deckRow(decks[1], width)
    local row_h = sample:getSize().h + Kit.dp(1)
    local fit = math.floor((room - head:getSize().h) / row_h)
    if fit < 1 then return nil end
    local rows = {}
    local shown = fit >= #decks and #decks or fit - 1
    for i = 1, shown do rows[i] = i == 1 and sample or self:deckRow(decks[i], width) end
    if shown < #decks then
        local more = Kit.spread(width, Kit.dp(70),
            Kit.text(T(_("Todos os baralhos (%1)…"), #decks), Kit.serif(Kit.SIZE.body + 1), {}),
            Kit.icon("chevron_right", Kit.dp(16)))
        rows[#rows + 1] = Kit.tap(more, function() require("vocab2deck/ui").showDecks(self.host, decks) end)
    end
    return VerticalGroup:new{ align = "left", head, Kit.rows(width, rows) }
end

-- ＋ Adicionar: um cartão novo (Frente/Verso) ou um baralho novo.
function Home:showAdd()
    local dialog
    local function item(text, fn)
        return { { text = text, callback = function() UIManager:close(dialog); fn() end } }
    end
    dialog = ButtonDialog:new{
        title = _("Adicionar"),
        title_align = "center",
        buttons = {
            item(_("＋ Adicionar cartão"), function() require("vocab2deck/capture").manual(self.host) end),
            item(_("＋ Adicionar baralho"), function() require("vocab2deck/ui").newDeck(self.host) end),
            { { text = _("Fechar"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

-- Barra de baixo: Adicionar · Buscar · Sincronizar (N) · Importar, ícone e nome.
function Home:bottomBar(w)
    local h = Kit.dp(76)
    local cell_w = math.floor(w / 4)
    local function item(kind, label, callback, opts)
        opts = opts or {}
        local enabled = opts.enabled ~= false
        local color = enabled and Kit.BLACK or Kit.GREY_LIGHT
        local icon = Kit.icon(kind, Kit.dp(24), { color = color })
        local top = icon
        if opts.badge and opts.badge > 0 then
            top = HorizontalGroup:new{ align = "top", Kit.hspan(Kit.dp(14)), icon, Kit.badge(opts.badge, Kit.SIZE.tiny - 1) }
        end
        local group = VerticalGroup:new{
            align = "center",
            top,
            Kit.vspan(Kit.dp(6)),
            Kit.text(label, Kit.ui(Kit.SIZE.tiny), { fgcolor = color }),
        }
        return Kit.tap(Kit.box(cell_w, h, group), callback, nil, { enabled = enabled })
    end
    return VerticalGroup:new{
        align = "left",
        Kit.hline(w, Kit.dp(2)),
        HorizontalGroup:new{
            align = "center",
            item("plus", _("Adicionar"), function() self:showAdd() end),
            item("search", _("Buscar"), function() self.host:askSearch(self.app) end),
            item("sync", _("Sincronizar"), function() self.host:syncAll() end, { badge = self.counts.deck }),
            item("import", _("Importar"), function() self.host:importApkg() end),
        },
    }
end

function Home:build(w, h)
    local header = self:header(w)
    local bottom = self:bottomBar(w)
    local avail = h - header:getSize().h - bottom:getSize().h
    local cw = w - 2 * Kit.PAD
    local top_gap, gap = Kit.dp(14), Kit.dp(22)
    local content
    if w > h then
        -- paisagem: baralhos numa coluna à direita
        local left_w = math.floor((cw - 2 * Kit.PAD) * 0.6)
        local col = cw - 2 * Kit.PAD - left_w
        local left = VerticalGroup:new{
            align = "left",
            Kit.vspan(top_gap), self:todaySection(left_w),
            Kit.vspan(gap), self:funnelSection(left_w),
            Kit.vspan(Kit.dp(12)), self:actionsSection(left_w),
        }
        local right = self:decksSection(col, avail - top_gap)
        content = HorizontalGroup:new{
            align = "top",
            left,
            Kit.hspan(2 * Kit.PAD),
            VerticalGroup:new{ align = "left", Kit.vspan(top_gap), right or Kit.vspan(0) },
        }
    else
        -- retrato: baralhos no espaço que sobra embaixo. Um grupo novo, sem
        -- inserir no já medido: no KOReader, VerticalGroup guarda as posições
        -- no primeiro getSize e um filho inserido depois quebra a pintura.
        local main = VerticalGroup:new{
            align = "left",
            Kit.vspan(top_gap), self:todaySection(cw),
            Kit.vspan(gap), self:funnelSection(cw),
            Kit.vspan(Kit.dp(12)), self:actionsSection(cw),
        }
        local decks = self:decksSection(cw, avail - main:getSize().h - gap)
        content = VerticalGroup:new{ align = "left", main }
        if decks then
            table.insert(content, Kit.vspan(gap))
            table.insert(content, decks)
        end
    end
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, avail, Kit.pad(content, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Home
