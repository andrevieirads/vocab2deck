--[[--
Planejamento da exportação e das atualizações. Lógica pura: recebe os itens
do banco próprio, o estado gravado no Anki Viewer e o modelo de campos, e diz
o que fazer, sem tocar em banco nenhum.

Regras
* Chave estável: vkey (ver vocab_reader.keyFor) + lado ("f"/"r").
* Exporta só itens ● Revisados (e os ○ do Inbox quando include_inbox).
  Itens ✓ No baralho que ainda não têm um lado (ex.: ligou "os dois
  sentidos") ganham esse lado.
* Já exportado e o cartão existe: o texto é remontado com os campos atuais;
  se mudou em relação ao que o plugin gravou -> ALTERADO (atualizar troca
  só o texto, o progresso fica). Se o cartão no Anki Viewer difere do que o
  plugin gravou, ele foi editado fora daqui (edited = true).
* Já exportado mas o cartão sumiu -> APAGADO no Anki Viewer: não é recriado.
* Nada é apagado.
--]]

local B = require("vocab2deck/card_builder")
local Tpl = require("vocab2deck/template")

local Sync = {}

-- Texto dos dois lados de um item. model é a lista de campos ou uma função
-- item -> lista (cada cartão pode ter o seu tipo, ex.: Frente/Verso dos manuais).
function Sync.renderItem(item, model, opts)
    if type(model) == "function" then model = model(item) end
    local fields = Tpl.fields(item, model, opts)
    return Tpl.render(fields, opts), fields
end

--[[--
@param items itens completos (Store:all)
@param state deck_writer:loadState()
@param model lista de campos (template.load)
@param opts Settings:cardOptions() (+ include_inbox)
@treturn table plan
  new      = { { item, sides = {…}, needs_lookup } }
  changed  = { { item, side, card_id, front, back, edited } }
  moves    = { { vkey, side, card_id, deck_name } } cartões fora do baralho que as
             configurações pedem (ex.: ligou "um baralho por livro")
  deleted, unchanged, edited_changed
--]]
function Sync.plan(items, state, model, opts)
    state = state or {}
    local cards = state.cards or {}
    local decks = state.decks or {}
    local plan = { new = {}, changed = {}, moves = {}, deleted = 0, unchanged = 0, edited_changed = 0 }
    local sides = B.sides(opts)
    for _, item in ipairs(items) do
        local exportable = item.status == "ready" or item.status == "deck"
            or (opts.include_inbox and item.status == "inbox")
        local rendered
        local missing = {}
        for _, side in ipairs(sides) do
            local c = cards[item.vkey .. "|" .. side]
            if c then
                if not c.card_id then
                    plan.deleted = plan.deleted + 1
                else
                    local want_deck = B.deckName(opts, item.book)
                    if item.status ~= "discarded" and decks[c.deck_id] and decks[c.deck_id] ~= want_deck then
                        plan.moves[#plan.moves + 1] = { vkey = item.vkey, side = side, card_id = c.card_id, deck_name = want_deck }
                    end
                    rendered = rendered or Sync.renderItem(item, model, opts)
                    local want = rendered[side]
                    if want.front ~= c.written_front or want.back ~= c.written_back then
                        local edited = c.front ~= c.written_front or c.back ~= c.written_back
                        if edited then plan.edited_changed = plan.edited_changed + 1 end
                        plan.changed[#plan.changed + 1] = {
                            item = item, side = side, card_id = c.card_id,
                            front = want.front, back = want.back, edited = edited,
                        }
                    else
                        plan.unchanged = plan.unchanged + 1
                    end
                end
            elseif exportable and item.status ~= "discarded" then
                missing[#missing + 1] = side
            end
        end
        if #missing > 0 then
            plan.new[#plan.new + 1] = { item = item, sides = missing, needs_lookup = item.looked_up ~= 1 }
        end
    end
    return plan
end

--[[--
Operações de escrita para as entradas novas (itens já com a busca feita).
@treturn table ops { inserts = {…} }, table stats { cards, items, skipped_nodef, vkeys }
--]]
function Sync.insertOps(entries, model, opts)
    local ops = { inserts = {} }
    local stats = { cards = 0, items = 0, skipped_nodef = 0, vkeys = {} }
    for _, e in ipairs(entries) do
        local rendered, fields = Sync.renderItem(e.item, model, opts)
        if not Tpl.hasDefinition(fields) and opts.missing_definition ~= "placeholder" then
            -- sem definição e configurado para pular: fica onde está, tenta de novo na próxima vez
            stats.skipped_nodef = stats.skipped_nodef + 1
        else
            local deck = B.deckName(opts, e.item.book)
            for _, side in ipairs(e.sides) do
                local t = rendered[side]
                ops.inserts[#ops.inserts + 1] = {
                    vkey = e.item.vkey, side = side, deck_name = deck,
                    source_key = B.sourceKey(e.item.vkey, side), front = t.front, back = t.back,
                }
                stats.cards = stats.cards + 1
            end
            stats.items = stats.items + 1
            stats.vkeys[#stats.vkeys + 1] = e.item.vkey
        end
    end
    return ops, stats
end

-- Operações de atualização para cartões alterados (only_unedited pula os editados fora daqui).
function Sync.updateOps(changed, only_unedited)
    local ups = {}
    for _, c in ipairs(changed) do
        if not (only_unedited and c.edited) then
            ups[#ups + 1] = { vkey = c.item.vkey, side = c.side, card_id = c.card_id, front = c.front, back = c.back }
        end
    end
    return ups
end

--[[--
Para "Sincronizar com o Anki Viewer": todo cartão vivo cujo texto no Anki
Viewer difere do texto que os campos dão hoje (inclusive editados fora daqui).
--]]
function Sync.syncUpdates(items, state, model, opts)
    local cards = (state or {}).cards or {}
    local ups = {}
    for _, item in ipairs(items) do
        local rendered
        for _, side in ipairs({ "f", "r" }) do
            local c = cards[item.vkey .. "|" .. side]
            if c and c.card_id then
                rendered = rendered or Sync.renderItem(item, model, opts)
                local want = rendered[side]
                if want.front ~= c.front or want.back ~= c.back or want.front ~= c.written_front or want.back ~= c.written_back then
                    ups[#ups + 1] = { vkey = item.vkey, side = side, card_id = c.card_id, front = want.front, back = want.back }
                end
            end
        end
    end
    return ups
end

-- Cartões vivos de um item que precisam do texto novo (depois de editar os campos).
function Sync.itemUpdates(item, state, model, opts)
    local plan = Sync.plan({ item }, state, model, opts)
    return Sync.updateOps(plan.changed, false)
end

return Sync
