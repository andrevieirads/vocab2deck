# Vocabulário → Flashcards (`vocab2deck.koplugin`) · versão 2.6

Plugin do KOReader que leva as palavras do **Vocabulary Builder** até o **Anki Viewer** no
fluxo do **KR2Anki**:

**Inbox → Revisar (uma palavra por tela) → Revisado → Exportar → No baralho**

As palavras chegam ao Inbox de dois jeitos:
- pelo **Vocabulary Builder**;
- direto do livro, com **＋ Adicionar ao baralho** na seleção de texto ou no popup do
  dicionário (ideia do PhraseDeck).

Cada cartão tem **campos editáveis**, como na janela *Adicionar* do Anki. Os cartões são
gravados direto no banco do Anki Viewer, sem `.apkg`, sem rede e sem AnkiConnect.

Alvo: Kindle Paperwhite 11ª geração (jailbreak, firmware 5.19.x), KOReader com LuaJIT,
Anki Viewer 1.4.0.

---

## 1. Como os dois plugins funcionam por dentro

### KR2Anki: de onde vêm os dados

- **Vocabulary Builder** (`kr2anki/vbimport.lua`): abre `settings/vocabulary_builder.sqlite3`
  **só para leitura** e lê `word`, `title.name`, `prev_context`, `next_context`,
  `highlight` e `create_time`.
- **O Vocabulary Builder não guarda definição.** O KR2Anki busca de novo nos dicionários
  instalados (`ui.dictionary:startSdcv(word, dict.enabled_dict_names, false)`, em
  `capture.lua`) e separa os sentidos com `dictparse.lua`.
- A frase de contexto é recortada por `sentence.lua`.
- O estado de cada palavra fica num banco próprio (`kr2anki.sqlite3`), com os status
  Inbox → Ready → In Anki → Known/Discarded.
- As telas (`screens/home`, `items`, `review`, `export`) são construídas sobre um kit
  próprio (`ui/kit.lua`, `ui/screen.lua`, `app.lua`).

### Anki Viewer: onde guarda os cartões

- O `.apkg` é só a forma de importar. O estudo usa apenas o SQLite
  `<dados do KOReader>/ankiviewer/ankiviewer.sqlite3` (`ankiviewer_db.lua`,
  `user_version = 4`, WAL), com as tabelas
  `decks(id, name)` e `cards(id, deck_id, front, back, ease, interval, due, reps, lapses, source_key, …)`.
- **Ao tocar em *Show answer*, o Anki Viewer troca o texto da frente pelo verso**
  (`card_widget:setText(card.back)`). Não existe `{{FrontSide}}`. Por isso o verso que este
  plugin grava **sempre** repete a frente, acima de um traço.
- Se `user_version < 4`, o próprio Anki Viewer apaga o banco ao abrir.
- O estudo abre no baralho salvo em `last_deck_id`.

### PhraseDeck: cartões a partir de destaques

- Registra **"Add to Deck"** no menu da seleção (`ui.highlight:addToHighlightDialog`, em
  `onReaderReady`).
- Pega o texto selecionado (`selected_text.text`) e a frase em volta
  (`document:getSelectedWordContext`, só em EPUB/HTML).
- Abre um diálogo para editar a frase e outro para a nota, e grava no banco próprio dele
  (`cards(phrase, sentence, user_note, …)`).
- É **GPLv3**. Daqui foi aproveitada só a ideia; o código da captura veio do KR2Anki, que
  liga o mesmo menu (`capture.lua`).

### Caminho escolhido: escrever direto no SQLite do Anki Viewer

É o mesmo `INSERT INTO cards (deck_id, front, back, source_key)` que o importador dele faz,
e o mesmo `UPDATE` só de `front`/`back` do *Merge (keep progress)*. As colunas de
agendamento nunca são tocadas.

---

## 2. Arquitetura

```
Vocabulary Builder ──(ro)──► vocab_reader ──► store (settings/vocab2deck.sqlite3)
                                               │  status ○ Inbox / ● Revisado / ✓ No baralho / × Descartado
                                               │  sentidos do dicionário, campos editados, campos extras
                                               ▼
        screens/home ─► screens/items ─► screens/review ─► screens/editor   (template: modelo de campos)
                                               │
                                               ▼
        screens/export ─► sync.plan ─► dict_lookup (só quem falta) ─► deck_writer (backup + 1 transação)
                                                                         │
                                         apkg ─► ankiviewer/shared/Vocab2Deck.apkg (para o Anki)
                                                                         │
                                                       "Estudar no Anki Viewer" ◄┘
```

### Estrutura de pastas do plugin

```
vocab2deck.koplugin/
├── _meta.lua
├── main.lua                  plugin: menu, gestos, sincronização, exportação, estudo
└── vocab2deck/
    ├── vocab_reader.lua      lê o Vocabulary Builder (só leitura, colunas detectadas)
    ├── capture.lua           "＋ Adicionar ao baralho" na seleção e no popup do dicionário
    ├── store.lua             banco próprio: itens, status, sentidos, campos
    ├── template.lua          modelo de campos e montagem da frente/verso
    ├── sync.lua              o que é novo / alterado / apagado (lógica pura)
    ├── dict_lookup.lua       busca silenciosa da definição e dos sentidos
    ├── card_builder.lua      frase de contexto, nome do baralho, chave no Anki Viewer
    ├── deck_writer.lua       backup + escrita no banco do Anki Viewer
    ├── apkg.lua              pacote Vocab2Deck.apkg para o Anki (Vocab2Deck::Livro)
    ├── ui.lua                diálogos comuns e Configurações
    ├── settings.lua, safe.lua
    ├── screens/              home, items, review, editor, model, export
    ├── ui/                   kit.lua, screen.lua, app.lua (copiados do KR2Anki)
    └── lib/                  u8, ruby, dictparse, sentence, zip, sha1 (copiados do KR2Anki)
tests/                        testes no computador (não vão para o Kindle)
```

### Arquivos de dados no Kindle (`/mnt/us/koreader/`)

```
koreader/
├── settings/vocabulary_builder.sqlite3   Vocabulary Builder (só lido)
├── settings/vocab2deck.sqlite3           Inbox, status e campos deste plugin
├── settings/vocab2deck.lua               configurações e modelo de campos
├── ankiviewer/ankiviewer.sqlite3         banco do Anki Viewer (escrito)
├── ankiviewer/shared/Vocab2Deck.apkg     pacote para o Anki (regravado a cada exportação)
└── vocab2deck/backups/                   backups automáticos (os 5 mais recentes)
```

---

## 3. Telas

Todas no estilo do KR2Anki: cabeçalho com `‹`, botões de pelo menos ~9 mm, ação principal
invertida (branco no preto), sem animação. Deslizar para os lados, ou as teclas de página,
troca de página. As prévias aproximadas estão em `tests/previews/index.html`.

**Início:**
- Status com as contagens, cada linha abre a lista daquele status:
  ○ Inbox · ● Revisados · ✓ No baralho · × Descartados.
- Avisos: palavras novas que vieram do Vocabulary Builder, cartões apagados, erros.
- *Atualizar N cartões alterados…*, quando há cartões no baralho com texto novo.
- Linha de ações: **＋ Adicionar cartão** · ⌕ Buscar · Campos · Configurações.
  - *＋ Adicionar cartão* pede a frente (uma palavra ou um trecho) e abre o editor de
    **Novo cartão** com um **tipo próprio, só com Frente e Verso**:
    - **Frente** é o texto digitado.
    - **Verso** começa com a definição do dicionário (quando o texto tem até 4 palavras) e
      é editável.
  - Esse tipo não depende da tela Campos: mudar o modelo não afeta esses cartões.
  - No editor deles, + Campo e − Campo valem só para campos criados naquele cartão.
  - *Salvar no Inbox* guarda o cartão; *Cancelar* descarta.
- *Estudar no Anki Viewer* · **Sincronizar (N)**: manda de novo os itens ✓ No baralho.
  - Cartões que existem recebem o texto atual, mesmo os mexidos fora do plugin; **o
    agendamento não muda**.
  - Cartões que sumiram do Anki Viewer são criados de novo.
  - Cartões fora do baralho certo são movidos.
  - O `Vocab2Deck.apkg` é regravado.
- Barra de baixo: **Revisar (N)** · **Exportar (N)**.

**Lista:**
- Linhas paginadas com a palavra, o livro, o **verso** curto e o símbolo do status. O verso
  curto é a definição ou, se não houver, o primeiro campo do verso que você escreveu (por
  exemplo, as Notas de um cartão criado no livro).
- Ordem *Mais novas* / *A–Z*, e busca.
- **Toque longo** entra no modo de seleção: *Selecionar todas*, e depois × Descartar,
  ○ Inbox ou ● Revisado em massa, inclusive na lista ✓ No baralho.
  - Na lista × Descartados, no lugar de × Descartar fica **Limpar**: depois de confirmar, as
    palavras saem do plugin.
  - O plugin registra as palavras limpas, e a leitura do Vocabulary Builder não as traz de
    volta. Para trazer uma de volta, adicione-a de novo pelo livro com *＋ Adicionar ao
    baralho*.
  - Limpar não apaga cartões no Anki Viewer.
  - O cartão continua no Anki Viewer, com o progresso.
  - Ao exportar de novo um ● Revisado que já tem cartão, o cartão recebe o texto atual e o
    item volta a ✓ No baralho, sem duplicar.
- Tocar numa linha abre a palavra.

**Revisar** (uma palavra por tela):
- A palavra, com ✎ para *Buscar outra forma no dicionário* ou editar o texto dela no cartão.
- A frase do livro. Tocar nela abre: Encurtar · Mostrar mais contexto · Frase original ·
  Editar o texto.
- **Escolha o sentido:** a opção *Padrão* (os N primeiros sentidos) e cada sentido do
  dicionário, em botões de rádio; também *Ver a entrada inteira* e *Escrever a minha*.
  A definição que você escreve aparece como **Sua definição** e vale no cartão, na lista e
  na revisão, mesmo quando o dicionário não tem a palavra.
- **✎ Campos do cartão · pré-visualizar** abre o editor.
- Barra de baixo: **Pular** · **× Descartar** · **✓ Revisado**.
- Deslizar para a direita volta à palavra anterior, com a decisão ainda editável.
- No fim, o resumo (*N Revisados · N Descartados · N pulados*) e o botão **Exportar (N)**.

**Campos do cartão** (o editor, como o *Adicionar* do Anki):
- Cada campo aparece com o nome, o lado (frente/verso/não mostrar) e o texto; tocar no texto
  edita.
- O botão `⋯` de cada campo abre as opções:
  - Restaurar o texto gerado
  - Renomear, lado e Remover (nos campos só deste cartão)
  - Mudar no modelo (nos campos do modelo)
- **+ Campo** cria um campo **só neste cartão** ou **no modelo** (todos os cartões).
- **− Campo** tira um campo.
  - Campo só deste cartão: sai do cartão.
  - Campo do modelo: escolha **Só deste cartão** (ele fica marcado "removido deste cartão",
    e o `⋯` traz de volta) ou **De todos os cartões** (sai do modelo).
- Os dois botões aparecem no cartão novo (destaque, popup do dicionário e *＋ Adicionar
  cartão*) e ao editar um cartão existente.
- **Pré-visualizar** mostra a frente e o verso exatamente como o Anki Viewer vai mostrar.
- Se a palavra já está no baralho, cada mudança atualiza o cartão na hora, sem mexer no
  progresso.

**Modelo de campos** (o "tipo de nota" das palavras do Vocabulary Builder e do livro; os
cartões de *＋ Adicionar cartão* têm o tipo fixo Frente/Verso):
- Padrão: Palavra (F) · Frase (F) · Definição (V) · Livro (V) · Notas (V).
- Tocar num campo abre: ✎ Renomear, Frente / Verso / Não mostrar, ↑ Subir / ↓ Descer e
  − Remover este campo. Vale para **qualquer** campo, inclusive Palavra, Frase, Definição e
  Livro.
- **− Campo** escolhe um campo para remover.
  - Campo seu: o texto escrito nele some.
  - Campo do plugin: as suas edições ficam guardadas para quando ele voltar.
- **+ Campo** cria um campo vazio (você escreve) ou traz de volta um campo do plugin que foi
  removido.
- **Padrão** restaura o modelo inicial. O cartão precisa de pelo menos um campo.

**Exportar:**
- Pré-checagem: N revisados, o baralho de destino, inversos pendentes, e a caixa
  *Também enviar os N do Inbox como estão*.
- Durante a gravação: *Exportando 12 de 40…*, atualizado a cada 5 palavras; tocar
  interrompe.
- Resultado: N cartões novos, palavras sem definição (ficam onde estavam), falhas e
  backup, com os botões **Estudar no Anki Viewer** · Fechar.

**＋ Adicionar ao baralho** (no livro):
- **Selecione um trecho** (toque longo e arraste): o botão aparece no menu da seleção.
- **Toque longo numa palavra:** o botão aparece no popup do dicionário, e a definição que
  está na tela já vem preenchida.
- Os dois abrem o editor em modo **Novo cartão**:
  - a palavra ou o trecho na frente;
  - a frase de contexto do livro;
  - o título do livro;
  - a definição do dicionário, buscada só quando o texto tem até 4 palavras.
- Edite os campos ou crie outros com **+ Campo**, e use **Pré-visualizar** para conferir.
- **Salvar no Inbox** guarda o cartão para o fluxo normal (revisar → exportar); **Cancelar**
  descarta.
- Se o texto já existe (por exemplo, a palavra já veio do Vocabulary Builder), o botão abre
  o cartão que já existe, sem duplicar.
- Um item capturado no livro mantém a frase e o livro da captura, mesmo que a palavra chegue
  depois pelo Vocabulary Builder.

**Pacote para o Anki** (passo da exportação, sem tela própria):
- A cada exportação, o plugin grava `koreader/ankiviewer/shared/Vocab2Deck.apkg` com **todos**
  os cartões que estão no baralho.
- Também grava o pacote ao fechar o plugin, se algum cartão no baralho mudou (edição,
  atualização automática) **ou se o arquivo ainda não existe**. Assim ele aparece mesmo
  quando tudo já estava exportado e o botão mostra *Exportar (0)*.
- Entram todos os cartões do plugin que existem no Anki Viewer, menos os de itens descartados.
- Estrutura no Anki:

  ```
  Vocab2Deck                        baralho principal (cartões sem livro)
  ├── Vocab2Deck::Título do livro A cartões do livro A
  └── Vocab2Deck::Título do livro B cartões do livro B
  ```

  A hierarquia é sempre por livro, independente da opção *Um baralho por livro*, que vale
  só para o Anki Viewer.
- **Tipo de nota "Vocab2Deck":** campos *Frente* e *Verso*; o verso é
  `{{FrontSide}}<hr id=answer>{{Verso}}`, como o *Básico* do Anki.
  - O texto é o mesmo dos campos do cartão, convertido para HTML (quebra de linha vira `<br>`).
  - No Anki o verso não repete a frente, porque `{{FrontSide}}` já faz isso.
  - Com *os dois sentidos*, cada sentido vira uma nota.
- **Importar de novo no Anki** (Arquivo ▸ Importar) atualiza as notas em vez de duplicar: o
  GUID de cada nota vem da chave do cartão e o tipo de nota tem id fixo. O pacote não leva
  agendamento: no Anki os cartões entram como novos.
- **Esquema:** a coleção legada do Anki (schema 11) com a tabela `revlog` completa, incluindo
  a coluna `ease` que faltava no gerador do KR2Anki e causava "no such column: ease".
- Se o pacote falhar, a exportação para o Anki Viewer vale do mesmo jeito; só aparece uma
  linha no resultado.

**Gestos** (Gerenciador de gestos ▸ **Geral**):
- *Vocabulário → Flashcards: abrir*
- *revisar o Inbox*
- *exportar*
- *estudar no Anki Viewer*

Os ids da versão 1 continuam valendo para gestos já configurados.

**Configurações:**
- nome do baralho
- um baralho por livro (o nome do baralho é só o título do livro)
- campos (modelo)
- direção (frente → verso, ou os dois sentidos)
- trazer do Vocabulary Builder (todas ou só não aprendidas) e o limite de acertos
- abrir direto na exportação
- cartões no baralho com texto novo: atualizar sozinho (padrão), perguntar ou ignorar
- palavra sem definição (pular ou criar cartão)
- quantos sentidos entram na definição padrão
- verificar definições nos dicionários
- recriar cartões apagados
- onde ficam os backups

---

## 4. Regras de sincronização

- **Abrir o plugin** lê o Vocabulary Builder (rápido, sem dicionário). Palavras novas entram
  no **Inbox**; as que já existem só atualizam o contexto, e status e edições ficam.
- **Busca no dicionário:** só quando a palavra aparece na revisão (uma por tela), ou na
  exportação para quem ainda não foi buscado.
- **Chave estável:** a palavra em minúsculas (`w:<palavra>`). No Anki Viewer,
  `source_key = vocab2deck:<lado>:<chave>`.

| Situação | O que acontece |
| --- | --- |
| ● Revisado sem cartão | Exportar cria o cartão; o item vira ✓ No baralho só depois de gravado |
| ○ Inbox | Só vai se você marcar *Também enviar os do Inbox* |
| Editou um campo de um item ✓ No baralho | O cartão recebe o texto novo na hora; o progresso fica |
| Mudou o modelo, a definição ou o contexto | Ao abrir o plugin (ou voltar ao Início), os cartões são atualizados sozinhos; o progresso fica |
| Mudou o baralho (nome ou *um baralho por livro*) | Os cartões são movidos para o baralho novo; o progresso vai junto; o baralho antigo vazio é apagado |
| Cartão editado fora do plugin (versão 1, outro programa) | Não é sobrescrito sozinho: o Início mostra *Atualizar N cartões alterados…* |
| Verso vazio (sem definição e sem nenhum campo do verso escrito por você) | Pula e fica onde estava. Um cartão do livro só com *Notas* é exportado normalmente |
| Cartão apagado no Anki Viewer | Não volta na exportação; **Sincronizar** ou *Recriar cartões apagados* o trazem de volta |
| Baralho apagado no Anki Viewer | O controle é limpo; os itens são recriados na próxima exportação |
| × Descartado depois de exportado | O cartão continua no Anki Viewer; apague lá se quiser |
| Item mandado de ✓ No baralho para ○ Inbox ou ● Revisado | O status fica como você escolheu; o cartão continua no Anki Viewer. Ao exportar um ● Revisado, o cartão é atualizado (sem duplicar) e o item volta a ✓ No baralho |
| Limpar (nos Descartados) | A palavra sai do plugin e não volta do Vocabulary Builder; volta só se você a adicionar pelo livro. O Anki Viewer não é tocado |
| Nada é apagado sozinho | Palavras que saem do Vocabulary Builder continuam no plugin e no baralho |

**Migração da versão 1:**
- Na primeira abertura, as palavras já exportadas pela 1.x viram ✓ No baralho, com a
  definição guardada, e as outras entram no Inbox.
- Os cartões antigos são atualizados sozinhos para o formato novo (verso com a frente) e
  movidos para o baralho certo; o progresso fica.

**Segurança:**
- O Vocabulary Builder é aberto com `"ro"`.
- Antes de escrever no banco do Anki Viewer, o plugin faz backup com `VACUUM INTO`. Ao
  editar vários campos seguidos, é um backup por abertura do plugin. Se o backup falhar,
  nada é gravado.
- Cada gravação é uma transação.
- O plugin se recusa a escrever num banco do Anki Viewer com `user_version < 4`.

---

## 5. Instalação no Kindle

1. Conecte o Kindle por USB.
2. Apague a pasta antiga `koreader/plugins/vocab2deck.koplugin` e copie a nova (ou
   descompacte `vocab2deck.koplugin.zip` dentro de `koreader/plugins/`).
3. Ejete e reinicie o KOReader (menu ▸ Sair ▸ Reiniciar o KOReader).
4. Ligue um gesto a *Vocabulário → Flashcards: abrir*, já que o Zen UI esconde menus.
5. Pré-requisitos:
   - o Vocabulary Builder ativo;
   - ao menos um dicionário StarDict;
   - o Anki Viewer instalado, para *Estudar*.

---

## 6. Roteiro de teste no aparelho

Antes, copie `koreader/ankiviewer/ankiviewer.sqlite3` para o computador.

1. **Banco vazio:** sem palavras no Vocabulary Builder, abra o plugin. Esperado: aviso *está
   vazio*, Inbox 0, e nada criado em `ankiviewer/`.
2. **Revisão e primeira exportação**
   - Consulte 5 palavras num livro e abra o plugin. Esperado: *○ 5 palavras novas vieram do
     Vocabulary Builder* e Inbox 5.
   - Toque em **Revisar (5)**. Esperado: uma palavra por tela, com a frase e os sentidos.
   - Escolha um sentido numa palavra, toque na frase e use *Encurtar*, faça **✓ Revisado**
     em 3, **× Descartar** em 1 e **Pular** em 1.
   - Deslize para a direita e mude uma decisão.
   - No resumo, toque em **Exportar (3)**, depois em **Exportar**. Esperado: *3 cartões
     novos adicionados.*
   - Toque em **Estudar no Anki Viewer**. Esperado: a frente mostra a palavra e a frase;
     *Show answer* mostra a frente, o separador e o verso.
3. **Segunda exportação sem novas:** Exportar mostra **0** e o botão fica desativado. No
   Anki Viewer, continuam 3 cartões e os revisados mantêm os intervalos.
4. **Edição e definição alterada**
   - Abra **✓ No baralho**, depois uma palavra e **✎ Campos do cartão**. Mude a Definição.
     No Anki Viewer o verso muda, e o intervalo continua o mesmo.
   - **+ Campo ▸ Só neste cartão**, *Exemplo*, *Verso* e escreva algo. Use
     **Pré-visualizar** para conferir.
   - Em **Campos** (modelo), mude *Livro* para *Não mostrar* e volte ao Início. Esperado:
     *✓ 3 cartões atualizados no Anki Viewer*. O progresso fica.
   - Numa palavra sem definição, toque em **Escrever a definição**. Esperado: aparece
     *Sua definição: …* na revisão e na lista, e no cartão.
   - Troque de dicionário e use **Configurações ▸ Verificar definições**. Esperado: aparece
     a pergunta de atualização.
5. **Do livro**
   - Num EPUB, selecione um trecho e toque em **＋ Adicionar ao baralho**. Esperado: editor
     *Novo cartão* com o trecho, a frase e o livro. Escreva a Definição e toque em
     **Salvar no Inbox**: o trecho aparece no ○ Inbox.
   - Toque longo numa palavra e use o botão do popup do dicionário. Esperado: a definição
     já vem preenchida.
   - Toque em **Cancelar** num cartão novo. Esperado: nada é guardado.
6. **Pacote para o Anki**
   - Depois de uma exportação, copie `koreader/ankiviewer/shared/Vocab2Deck.apkg` para o
     computador e importe no Anki. Esperado: o baralho *Vocab2Deck* com um subbaralho por
     livro, e o verso mostra a frente, o traço e o verso.
   - Edite um cartão no plugin, feche o plugin e importe o pacote de novo. Esperado: a nota
     é atualizada e não aparece uma segunda.
7. **Extras**
   - Apague um cartão no Anki Viewer: ele não volta; *Recriar cartões apagados* o traz de volta.
   - Ative **Os dois sentidos**: Exportar mostra *+ N cartões inversos*.
   - Toque na tela durante uma exportação longa: ela para e grava o que já foi processado.
   - Toque longo numa linha da lista entra no modo de seleção.

### Testes no computador

```bash
tests/run_tests.sh /caminho/para/ankiviewer.koplugin --previews
```

- Usa `lua`, `luac` e `python3`.
- Roda os cenários duas vezes, em retrato (1236×1648) e paisagem.
- As telas de verdade rodam sobre os widgets de teste do KR2Anki (`tests/support/uistubs.lua`:
  layout, toques e deslizes).
- Verifica que nenhum texto sai da tela e nenhum conteúdo passa da caixa.
- Usa o **`ankiviewer_db.lua` real** sobre o mesmo banco, para provar que ele lê os cartões
  e que revisar, apagar e editar convivem.
- Com `--previews`, grava SVGs das telas e `tests/previews/index.html`.
- Abre o `Vocab2Deck.apkg` gerado com o Python (`tests/support/check_apkg.py`) e confere:
  - o zip;
  - a mesma consulta na `revlog` que falhou no Anki;
  - os baralhos, os campos e os arrays JSON;
  - o checksum das notas;
  - os GUIDs estáveis entre duas exportações.
- `V2D_REPLAY=<pasta>` roda também uma réplica com cópias dos bancos de um aparelho
  (`settings/` e `ankiviewer/`).
- Resultado atual: 223 verificações por orientação, 0 falhas. Um dos cenários reproduz o
  caso visto no aparelho: definição escrita à mão, modelo mudado, cartão antigo sem a frente
  no verso, e baralho antigo "Vocabulary Builder::Livro".

---

## 7. Riscos e pontos não confirmados pelo código

1. **"Aprendida" = `streak_count` ≥ N** é definição minha; a coluna é detectada e, sem ela,
   o filtro é desligado com aviso.
2. **Esquema do Vocabulary Builder:** só as colunas que o KR2Anki lê estão confirmadas; todas
   são detectadas por `PRAGMA table_info`.
3. **Espaços no contexto:** segui a convenção dos testes do KR2Anki (o contexto inclui os
   espaços em volta da palavra).
4. **APIs internas do Anki Viewer** para abrir o estudo: `ui.ankiviewer`,
   `saveSetting("last_deck_id")`, `.screen`, `showLocalStudy()`. Não são públicas, e o
   esquema está fixado na versão 4.
5. **"Replace" no Anki Viewer** num baralho deste plugin (o nome das configurações ou o título
   de um livro) apaga os cartões. O plugin os vê como apagados e não os recria.
6. **Atualização sozinha:** com o padrão *Atualizar sozinho*, abrir o plugin pode gravar no
   banco do Anki Viewer (sempre com backup antes). Para não gravar sem pedir, use *Perguntar*.
   Mover para outro baralho apaga o baralho antigo se ele ficar vazio.
7. **Tabelas extras `vocab2deck_*` no banco do Anki Viewer:** o Anki Viewer 1.4.0 as ignora
   (lido no código).
8. **Widgets:**
   - As telas usam o kit do KR2Anki, testado por ele no KOReader 2026.07.1.
   - O `InputDialog` com `fullscreen`/`condensed` não é usado por nenhum dos dois plugins.
   - O layout foi testado com widgets de teste (medidas de fonte aproximadas), não no
     Paperwhite.
9. **Maiúsculas:** `string.upper` do Lua não muda letras acentuadas, por isso os nomes de
   campo aparecem como você escreve. Rótulos de seção com acento ficariam com as letras
   acentuadas em minúsculas.
10. **Velocidade:** uma busca `sdcv` por palavra, na revisão ou na exportação.
11. **Não testado no aparelho:** os testes rodam em Lua 5.5 + SQLite do Python, não em
    LuaJIT + lua-ljsqlite3. O código converte os inteiros `cdata` com `tonumber`, como os
    dois plugins.
12. **Chave em minúsculas só ASCII:** `Été` e `été` contam como palavras diferentes.
13. **Botão no popup do dicionário:** como no KR2Anki, se você já personalizou os botões do
    popup, ele pode não aparecer sozinho. Ative em: popup ▸ Configurações do dicionário ▸
    Personalizar botões ▸ *Vocabulário → Flashcards: adicionar ao baralho*. A frase de
    contexto vem do `getSelectedWordContext` do KOReader; em PDF pode não vir.
14. **Trechos longos** viram a frente inteira do cartão; o Anki Viewer corta com "…" e
    mostra tudo ao tocar no cartão.
15. **Não importe o `Vocab2Deck.apkg` no próprio Anki Viewer.** Ele fica na pasta `shared`
    e aparece em *Import*; importar cria um baralho "Vocab2Deck" com cópias dos cartões que
    o plugin já grava lá.
16. **Validação do pacote:** conferido com o Python e com a consulta do erro, mas não com o
    Anki de verdade. A biblioteca `anki` não pôde ser instalada aqui; o KR2Anki validava o
    mesmo formato com ela. Teste uma importação no Anki antes de confiar no pacote.
17. **Licenças:** nenhum dos dois zips traz arquivo de licença. Confira nos repositórios
    antes de redistribuir.

## Créditos

- **KR2Anki**:
  - Copiados: `lib/u8.lua`, `ruby.lua`, `dictparse.lua`, `sentence.lua`, `zip.lua` e
    `sha1.lua`, sem mudança de lógica; `apkg.lua`, adaptado (tipo de nota próprio, baralhos
    por livro, coluna `ease` corrigida na `revlog`); `ui/kit.lua`, `ui/screen.lua` e `ui/app.lua`, com os textos traduzidos e os
    status deste plugin; e `tests/support/uistubs.lua` e `svgrender.lua`.
  - Adaptados: o desenho e o fluxo das telas Início, Lista, Revisão e Exportação; a leitura
    do Vocabulary Builder; a busca silenciosa; `safe.lua` e `settings.lua`; e o padrão dos
    gestos.
- **PhraseDeck** (GPLv3): a ideia de criar cartões a partir da seleção no livro. O código não
  foi copiado.
- **Anki Viewer**: o esquema do banco (para criar um banco idêntico) e o padrão da tela de
  configurações.
- O que veio de onde está escrito no topo de cada arquivo.
