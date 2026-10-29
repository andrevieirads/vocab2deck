# Vocabulário → Flashcards (vocab2deck)

Leva as palavras do Vocabulary Builder e os destaques dos livros do KOReader até o Anki Viewer no fluxo do KR2Anki
(Inbox → Revisar → Revisado → Exportar), com campos editáveis como no "Adicionar" do Anki.
Grava direto no banco `koreader/ankiviewer/ankiviewer.sqlite3`, com backup antes de cada escrita.
O Anki Viewer 1.4.0 vem embutido (`vocab2deck/ankiviewer/`): o botão Estudar abre a tela de
estudo dele. Não é preciso instalar o `ankiviewer.koplugin`; o progresso já feito nele continua.

- Menu: Ferramentas ▸ Vocabulário → Flashcards
- No livro: "＋ Adicionar ao baralho" na seleção de texto e no popup do dicionário
- Sincronizar (Início): Vocabulary Builder + destaques → Inbox; No baralho → Anki Viewer
- Gestos (Geral): "Vocabulário → Flashcards: abrir / revisar o Inbox / exportar / estudar"

Documentação completa, roteiro de teste e riscos: README.md da pasta do projeto.

Créditos: partes adaptadas ou copiadas do KR2Anki (leitura do Vocabulary Builder, busca no
dicionário, `lib/u8.lua`, `lib/ruby.lua`, `lib/dictparse.lua`, `lib/sentence.lua`) e do Anki
Viewer 1.4.0 (embutido inteiro em vocab2deck/ankiviewer/); kit de interface e telas no estilo do KR2Anki. Ideia da captura por seleção: PhraseDeck (código não copiado). Cada arquivo diz o que veio de onde.
