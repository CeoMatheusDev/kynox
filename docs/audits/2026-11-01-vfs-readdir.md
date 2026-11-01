# O VFS aprende a listar um diretório — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  o kernel não foi inicializado aqui, e a linha do boot que aparece abaixo é o
  formato que o código imprime, não uma saída observada.
- Escopo: a operação `readdir` do VFS — pedaços, cookie, geração do namespace, e
  as recusas.
- Fora do escopo: permissões, um segundo backend real, e a ordenação alfabética
  que uma listagem não promete.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` (185 KiB) e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 889/889 testes** |
| `zig build docs-check` | sucesso — 76 documentos classificados |

`fs-loader-tests` foi de 154 para **162** (+8). O total foi de 881 para 889.

## 1. A operação que faltava

O RamFS sabia listar (`ramfs.listDir`), e o VFS não expunha nada disso: quem
quisesse saber o que há em `/` precisava conhecer o backend. O inventário de
`kfsx_vfs` registrava exatamente isso — **"incomplete VFS operation set"** — e a
consequência é que um shell ou o gerenciador de arquivos do desktop não teria
como pedir uma listagem sem furar a camada.

`fs.readdir(path, cookie, generation, out)` é a operação, e ela atravessa o
namespace como as outras: caminho absoluto passa pelo roteamento de maior
prefixo (então `/data` lista o volume montado ali, e não o diretório homônimo da
raiz), caminho relativo é da instância padrão.

## 2. Listar em pedaços, sem alocar

A listagem não recebe um buffer do tamanho do diretório e não aloca: ela enche o
buffer do chamador e devolve **onde continuar**.

```text
readdir("/", 0,  0, out[4])   ->  count 4, next 5,  generation G
readdir("/", 5,  G, out[4])   ->  count 4, next 9,  generation G
readdir("/", 9,  G, out[4])   ->  count 0, next 0,  generation G   (fim)
```

O cookie é o índice da entrada na tabela do volume por onde continuar, e `0`
tanto significa "comece do início" quanto "acabou". Quem chama não precisa de um
descritor de diretório aberto no kernel para listar um diretório: precisa de
três números.

Um buffer que não cabe uma única entrada é recusado com `BufferTooSmall` em vez
de devolver o mesmo cookie com `count == 0` — isso seria um laço infinito
disfarçado de sucesso.

## 3. A listagem pode ser invalidada no meio, e o VFS recusa

Aqui está a parte que não é encanamento. Uma listagem atravessa várias chamadas,
e o diretório pode mudar entre elas. A tabela de entradas do RamFS é **uma só
para todos os diretórios** e tem 64 posições: quando uma entrada sai, a posição
fica livre, e a próxima entrada criada ocupa essa mesma posição. Um cookie que
guardasse só o índice descreveria, na segunda chamada, outra coisa:

| O que acontece | Sem geração | Com geração |
|---|---|---|
| uma entrada antes do cookie é removida | a posição é reutilizada e um nome novo cai no lugar de um já entregue | `DirectoryChanged` |
| uma entrada nova é criada em posição anterior | o chamador **não** a vê, e nada avisa | `DirectoryChanged` |
| o diretório é renomeado | a listagem continua com nomes de outro diretório | `DirectoryChanged` |

O RamFS ganhou um contador de **geração por volume**, incrementado em toda
mutação de namespace (`addDirEntryFor`, `unlinkFileFor`, `renameFileFor`). Uma
operação que falha — criar um nome que já existe, remover um nome inexistente —
**não** incrementa: ela não mudou o namespace, e invalidar a listagem de quem
está no meio dela por causa de uma tentativa recusada seria ruído.

O comparativo acima é a razão de o VFS recusar em vez de continuar. Continuar é
o defeito silencioso clássico de `readdir`: o chamador pula um nome, ou recebe
dois nomes diferentes para a mesma posição, e o programa que lista um diretório
para copiá-lo perde um arquivo sem nenhuma mensagem de erro.

O contador é **por volume**: criar um arquivo em um volume montado não invalida
uma listagem da raiz, e o teste afirma isso.

## 4. O que a listagem não promete

| Não promete | Por quê |
|---|---|
| ordem alfabética | a tabela do RamFS não tem índice ordenado; ordenar exigiria uma cópia e uma ordenação no kernel |
| `.` e `..` | não são entradas do volume; o chamador os acrescenta se quiser |
| estabilidade depois de uma mutação | os nomes são fatias para o estado do volume, válidas até a próxima mutação daquele volume |
| `stat` de cada entrada | a entrada traz nome, tipo e inode; tamanho e permissões continuam sendo outra chamada |

A entrada entregue é `{ name, kind, inode }`: o tipo vem do inode no momento da
listagem, e o inode é o número que o resto da API já usa.

## 5. Um defeito que o teste encontrou

A primeira versão de `ramfs.listDirFrom` copiava a entrada para uma variável
local antes de fatiar o nome:

```zig
const entry = state.dir_entries[slot];      // copia: o array `name` vem junto
out[count] = .{ .name = entry.name[0..entry.name_len], ... };  // fatia para a pilha
```

`DirEntry` guarda o nome num array de 64 bytes, então a cópia levava o nome para
a pilha da função e a fatia devolvida apontava para memória que deixava de
existir no `return`. Os testes falharam com nomes que não batiam com nada; a
correção é uma linha — usar um **ponteiro** para a entrada do estado, como
`listDirFor` já fazia. Fica registrado porque é o tipo de defeito que uma
listagem pequena esconde: com uma entrada só, a memória da pilha ainda está
intacta e o nome parece certo.

## 6. O boot lista a raiz com a API de verdade

Depois de instalar os arquivos, o boot chama `fs.readdir("/")` em pedaços de
quatro, com cookie e geração, e imprime o que a listagem devolveu:

```text
[KNK] vfs: / listed in chunks of 4: 1 entries, 1 directories, 0 files (generation G, 1 call(s))
```

A raiz tem um diretório (`/apps`) e nenhum arquivo direto: os arquivos do boot
são criados dentro de `/apps`. O número da geração depende de quantas mutações o
boot fez antes da listagem, e por isso aparece como `G` aqui — a linha real só
existe na máquina, e o kernel não foi inicializado neste ambiente. O relatório
não lê a tabela do RamFS por fora: ele usa a mesma função que um processo usa,
com um limite de rodadas para que um cookie que não avance vire uma linha de
erro e não um boot travado.

## 7. Os oito testes

| Teste | Afirma |
|---|---|
| um diretório vazio não lista nada e encerra | `count 0`, `next 0`, e uma geração diferente de zero |
| um diretório é listado em pedaços sem perder uma entrada | cinco nomes em pedaços de dois: três chamadas, cada nome exatamente uma vez, o tipo de cada um |
| um arquivo não é um diretório, e um caminho ausente é recusado | `NotADirectory`, `EntryNotFound`, `InvalidPath` e `BufferTooSmall` |
| uma entrada traz o seu tipo, e um subdiretório é listado por conta própria | a raiz com um diretório e um arquivo, e o subdiretório vazio |
| uma mudança no namespace invalida o cookie | `DirectoryChanged` com o cookie antigo, e a listagem reiniciada com a geração nova vendo as três entradas |
| um volume montado é listado pelo próprio diretório | `/data` vê as entradas do volume 7 e a raiz não vê; a geração é por volume |
| uma listagem em pedaços retoma no cookie e recusa um buffer vazio | no RamFS, o cookie e as recusas de `listDirFrom` |
| a geração do namespace avança em toda mudança, e só nela | quatro mutações que avançam, duas que falham e não avançam, e a geração nunca zero |

## 8. O que continua aberto

| Item | Por quê |
|---|---|
| Um segundo backend | o VFS ainda chama `ramfs.*` direto; o contrato de operações não existe |
| Permissões | `mode` é aceito e ignorado; não há dono nem verificação |
| Ordenação | a listagem segue a tabela, não o alfabeto |
| `stat` na entrada | tamanho e permissões continuam sendo outra chamada |
| Um processo listando um diretório | a listagem está pronta; o espaço de usuário ainda não tem a chamada de sistema |

## 9. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `kfsx_vfs` **35% → 43%**, `ramfs`
  **55% → 57%**, contagens medidas (889, `fs-loader` 162, 76 documentos).
- `README.md`: as linhas de RamFS/KFSX e os números dos testes.
- `docs/ai/context-pack.md`: a listagem na linha de RamFS/KFSX.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: a anotação do estágio de
  armazenamento.
- `CHANGELOG.md`: a entrada da rodada.
