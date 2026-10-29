# Vocabulário → Flashcards (vocab2deck)

Leva as palavras do Vocabulary Builder do KOReader até o Anki Viewer no fluxo do KR2Anki
(Inbox → Revisar → Revisado → Exportar), com campos editáveis como no "Adicionar" do Anki.
Grava direto no banco `koreader/ankiviewer/ankiviewer.sqlite3`, com backup antes de cada escrita.

- Menu: Ferramentas ▸ Vocabulário → Flashcards
- No livro: "＋ Adicionar ao baralho" na seleção de texto e no popup do dicionário
- Gestos (Geral): "Vocabulário → Flashcards: abrir / revisar o Inbox / exportar / estudar no Anki Viewer"

Documentação completa, roteiro de teste e riscos: README.md da pasta do projeto.

Créditos: partes adaptadas ou copiadas do KR2Anki (leitura do Vocabulary Builder, busca no
dicionário, `lib/u8.lua`, `lib/ruby.lua`, `lib/dictparse.lua`, `lib/sentence.lua`) e do Anki
Viewer (esquema do banco, padrão da tela de configurações); kit de interface e telas no estilo do KR2Anki. Ideia da captura por seleção: PhraseDeck (código não copiado). Cada arquivo diz o que veio de onde.
