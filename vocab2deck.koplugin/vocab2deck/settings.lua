--[[--
Configurações do plugin (settings/vocab2deck.lua no KOReader), com valores
padrão. Mesmo desenho de kr2anki/settings.lua (KR2Anki): um LuaSettings por
baixo e get/set com padrão.
--]]

local Settings = {}
Settings.__index = Settings

Settings.DEFAULTS = {
    deck_name = "Vocabulary Builder",  -- baralho de destino no Anki Viewer
    subdeck_per_book = false,          -- true: um baralho com o título de cada livro
    include_context = true,            -- (versão 1; hoje vira o lado do campo Frase no modelo)
    include_book = true,               -- (versão 1; hoje vira o lado do campo Livro no modelo)
    direction = "forward",             -- "forward" (palavra → definição) | "both" (os dois sentidos)
    only_unlearned = false,            -- exportar só palavras ainda não aprendidas
    import_highlights = true,          -- Sincronizar traz também os destaques dos livros
    apkg_dir = nil,                    -- pasta do Vocab2Deck.apkg; nil = <dados>/ankiviewer/shared
    learned_streak = 5,                -- acertos seguidos (streak_count) para contar como aprendida
    auto_export = false,               -- abrir já exportando os Revisados
    on_change = "update",              -- texto de cartão no baralho mudou: "update" (sozinho) | "ask" | "ignore"
    missing_definition = "skip",       -- palavra sem definição: "skip" | "placeholder"
    max_senses = 3,                    -- quantos sentidos entram na definição padrão
    browse_sort = "newest",            -- ordem das listas: "newest" | "az"
    fields = nil,                      -- modelo de campos (template.lua); nil = padrão
}

-- store: qualquer objeto com readSetting/saveSetting/flush (LuaSettings).
function Settings.new(store)
    return setmetatable({ store = store }, Settings)
end

function Settings:get(key)
    local v = self.store:readSetting(key)
    if v == nil then return Settings.DEFAULTS[key] end
    return v
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
    self.store:flush()
end

function Settings:toggle(key)
    self:set(key, not self:get(key))
end

-- Opções usadas para montar os cartões e escolher as palavras.
function Settings:cardOptions()
    local deck = tostring(self:get("deck_name") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if deck == "" then deck = Settings.DEFAULTS.deck_name end
    return {
        deck_name = deck,
        subdeck_per_book = self:get("subdeck_per_book") == true,
        -- sempre: ao tocar em "Show answer" o Anki Viewer troca a frente pelo verso,
        -- então o verso precisa repetir a frente para os dois lados aparecerem
        front_on_back = true,
        both_directions = self:get("direction") == "both",
        only_unlearned = self:get("only_unlearned") == true,
        learned_streak = tonumber(self:get("learned_streak")) or Settings.DEFAULTS.learned_streak,
        missing_definition = self:get("missing_definition"),
        max_senses = tonumber(self:get("max_senses")) or Settings.DEFAULTS.max_senses,
    }
end

return Settings
