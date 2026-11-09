# O slot da tarefa que terminou volta ao pool — 2026-11-08

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. **Não** afirma comportamento de
  runtime: nenhum reaper rodou numa máquina, porque não há QEMU nem OVMF neste
  ambiente (§8).
- Requisito que a rodada fecha: `KERNEL_COMPLETION_ROADMAP.md`, K3, "Required
  work" item 10 — *fix the task-slot leak: `terminateCurrent` no longer strands a
  slot; exit is a state transition and the slot is released by the reaper*.
  Estava listado como pendente em `docs/PROJECT_STATUS.md` (defeito K-01, lado
  aberto) e no relatório de auditoria de 2026-10-31 (defeito 14).
- Escopo: o ciclo de vida do **slot** de uma tarefa — quem o devolve, quando,
  e o que impede que ele seja devolvido cedo demais.
- Fora do escopo: o objeto `Process` (K4), o reaping do espaço de endereço e das
  capabilities (`process.reapFull`, que já existe e que **nenhum caminho do boot
  chama**), e qualquer forma de `join`/`wait` de pai para filho.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig version` | `0.17.0` (wheel PyPI, o mínimo declarado) |
| `zig build` | sucesso — `kynox-boot.efi`, `kynox-kernel`, `kynox.img` 128 MiB / 32 731 clusters |
| `zig build test --summary all` (cache novo, `rm -rf .zig-cache`) | sucesso — **52/52 passos, 888/888 testes** |
| `zig build docs-check` | sucesso — todo link relativo resolve |
| `gen-doc-index.py --check` | sucesso — 76 documentos classificados |
| `bash -n .github/workflows/ci.yml` (bloco de firmware) | sucesso — sem erro de sintaxe |
| a detecção de firmware sobre uma árvore falsa (§9) | o `ls` antigo devolve `rc=2`; o laço novo encontra o par |
| `zig build qemu-test` / `qemu-storage-test` / `qemu-interactive-test` | **não executados** — `qemu-boot-test: no OVMF firmware found` (o script lista os sete pares que procurou); sem QEMU, sem OVMF, e `scripts/provision-qemu.sh` não consegue baixar os binários: `release-assets.githubusercontent.com` recusa a conexão TLS neste ambiente. Os espelhos apt também estão inalcançáveis. §8 |

`task-tests` foi de 72 para **79** (+7). O total foi de 881 para **888**.

## 1. O defeito, como ele estava

`Scheduler.allocate` era um contador que só crescia:

```zig
if (self.count >= max_tasks) return null;
const index = self.count;
self.count += 1;
```

`terminateCurrent` e `killCurrent` marcavam a tarefa como `terminated` e
**paravam ali**. Nada devolvia o índice, nada punha `null` em `tasks[index]`, e
`count` era ao mesmo tempo "quantas tarefas existem", "quantas já existiram" e
"onde fica o próximo slot". As três coisas coincidem só enquanto nenhuma tarefa
termina.

A consequência não é teórica. O kernel do boot cria 2 workers, 1 idle e até 6
tarefas de modo usuário (`spawnUser` em `kernel/main.zig`), e cada processo de
modo usuário termina — o do `hello`, o do `client`, o da página que provoca o
page fault, o do toolchain. Um sistema que criasse e encerrasse processos ao
longo da vida da máquina chegaria ao 33º com `allocate` devolvendo `null`,
apesar de ter no máximo três tarefas vivas. `reportOutOfMemory()` no boot é a
mensagem que o operador veria, e ela aponta para o lugar errado: não falta
memória, falta devolver o slot.

O defeito também tornava `statistics.tasks` uma mentira: o relatório do boot
contava as tarefas que já existiram, e não as que existem.

## 2. Por que não dá para liberar dentro de `terminateCurrent`

A tentação é marcar `terminated` e devolver o slot na mesma função. Isso é
*use-after-free* com um nome diferente: `terminateCurrent` roda **no contexto da
tarefa que está terminando**, na pilha de kernel dessa tarefa, e o slot contém
`kernel_rsp`, `stack` e o `context` salvos. Limpar o slot sob os próprios pés
devolve ao pool uma memória que a próxima tarefa vai reutilizar enquanto a
anterior ainda está voltando dela.

Uma tarefa também não pode liberar a si mesma depois de fazer o switch: ela não
roda mais. Quem libera é **outro** contexto. O caminho existe no projeto desde
antes — `execution-model.md` diz "a thread atual nunca libera a própria pilha;
ela troca de contexto primeiro e o reaper a libera em outro contexto" — e é
exatamente o que faltava implementar.

Havia ainda um segundo motivo, mais sutil: uma tarefa pode terminar enquanto
está **bloqueada**. O slot dela guarda o `wait_queue.Node` que a fila de espera
aponta, e a fila acorda o nó mais tarde por ponteiro. Liberar o slot de uma
tarefa bloqueada deixaria a fila apontando para memória que agora é outra
tarefa — e o `wake` acordaria a tarefa errada.

## 3. O desenho

Três peças, nenhuma delas com alocação.

**A lista, no próprio slot.** `Task` ganhou `reap_next: ?*Task` e
`reap_queued: bool`; `Scheduler` ganhou `reap_head` e `reap_count`. É uma lista
encadeada intrusiva: o nó mora na tarefa, então pedir para ser coletado nunca
aloca, e nada aqui precisa do `heap`. Não é um `wait_queue.Node`: ninguém dorme
nesta lista e ninguém é acordado por ela, e a máquina de espera (rotina de wake,
wake lembrado, deadline) seria código que nunca roda.

**O pedido.** `requestReap` só aceita uma tarefa `terminated`, ignora a tarefa
de idle e é idempotente (`reap_queued`). `terminateCurrent` e `killCurrent`
passam a chamá-la — são os dois únicos lugares do kernel que encerram uma
tarefa, e a lista é o único caminho até a coleta.

**A coleta.** `reap()` varre a lista e libera o que pode. Roda a partir de
`tick()`, que é o único contexto que não é a tarefa sendo coletada nem um
chamador que já esteja dentro do escalonador por outro motivo; toma o
`state_lock` como qualquer outra entrada. Devolve quantos slots voltaram e
atualiza `statistics.reaped` / `pending_reap`.

## 4. As três condições para liberar

`reap()` deixa a tarefa na lista — e o contador `pending_reap` denuncia — quando
qualquer uma delas falha.

| Condição | Por quê |
|---|---|
| `state == .terminated` | Uma tarefa que voltou a ficar pronta não vai ser coletada |
| `!isRunning(task)` | A CPU ainda está na tarefa: o frame está naquela pilha, e o slot não pode virar outra tarefa no instante em que a CPU vai retornar nele |
| `mayCollect(task)` | A canária da pilha de kernel da tarefa ainda é a que ela recebeu |

`mayCollect` existe porque o slot guarda mais que um número. A canária é escrita
no topo baixo da pilha de kernel em `spawn` e verificada a cada switch; se ela
não confere, a pilha foi sobrescrita e **isso é evidência** — reutilizar o slot
apagaria o defeito em vez de reportá-lo. No host a canária não é verificada,
porque ali `stack_canary_address` é um endereço do processo de teste e não de
uma imagem de kernel; `builtin.target.os.tag` decide, em comptime.

## 5. O bug que os testes acharam

A primeira versão de `purgeReady` (a limpeza das filas de prontos antes de
liberar o slot) escrevia assim:

```zig
while (write < self.ready_count[cpu_id]) : (write += 1) {
    self.ready_queue[cpu_id][write] = null;
}
self.ready_count[cpu_id] = @intCast(write);
```

`write` já apontava para o novo fim da fila antes do laço de limpeza, então o
laço o levava até o fim antigo e a contagem **voltava ao valor original**. A
fila ficava com as entradas limpas, a contagem dizia dois, e a segunda entrada
era lixo: o teste `a slot that goes back to the pool leaves no queue pointing at
it` falhou com `expected 1, found 2`. A correção guarda o novo tamanho antes do
laço (`survivors`) e o laço usa uma cópia.

Sem essa limpeza, um `wake` que enfileirou a tarefa antes de ela terminar deixa
o ponteiro na fila; o slot é reaproveitado, e a fila passa a apontar para a nova
tarefa — que rodaria duas vezes. O teste cobre exatamente essa sequência:
enfileirar, terminar, coletar, recriar, e conferir que a fila só tem o
sobrevivente.

## 6. O que mudou no significado de `count`

`count` deixa de ser um cursor e passa a ser o **high-water mark** da lista: o
prefixo `tasks[0..count]` é onde pode haver slot, e um slot liberado é `null` no
meio dele. `allocate` varre esse prefixo atrás do primeiro `null` e, se não
achar, usa o primeiro índice acima dele. `releaseSlot` não reduz `count` — só
derruba a entrada — porque um slot abaixo do topo pode ser reutilizado sem mexer
no limite.

`statisticsOf().tasks` passou a contar entradas não nulas em vez de devolver
`count`: o relatório do boot agora diz quantas tarefas **existem**, e
`statistics.reaped` diz quantas já foram embora.

## 7. Os sete testes

| Teste | Afirma |
|---|---|
| um slot volta ao pool e é usado de novo | 33 vidas de tarefa em sequência (uma a mais que `max_tasks`) com `max_tasks + 1` coleções; `tasks` volta a zero e `reaped` fecha a conta |
| o slot de uma tarefa que uma CPU executa não é coletado | `terminateCurrent` deixa `pending_reap` em 1, `reap()` devolve 0, e só depois de a CPU sair a coleta acontece |
| um tick coleta as tarefas que terminaram | `tick()` zera `pending_reap`; um segundo `requestReap` da mesma tarefa não entra na lista |
| a tarefa de idle nunca é coletada | `ensureIdle`, `terminated`, `requestReap` → nada na lista, nada coletado, a tarefa continua existindo |
| a fila nunca entrega uma tarefa que terminou | `dequeueReady` pula a terminada e devolve a viva |
| um identificador não é reutilizado quando o slot volta ao pool | o slot é o mesmo endereço e o `id` é o seguinte; a identidade de uma tarefa é o `id`, nunca o endereço |
| um slot liberado não deixa fila apontando para ele | enfileirar → terminar → coletar → recriar: a fila tem só o sobrevivente |

## 8. O que continua aberto

| Item | Por quê |
|---|---|
| Um reaper rodando numa máquina | o caminho do tick nunca executou: sem QEMU e sem OVMF neste ambiente (as três alvos `qemu-*` continuam `not_executed`) |
| Reaping do espaço de endereço no fim da tarefa | `process.reapFull` existe e tem teste de host, mas **nenhum** caminho do boot o chama; o espaço de endereço de um processo de modo usuário que termina continua sem ser destruído |
| Uma tarefa que termina bloqueada | fica na lista (o slot guarda o nó da fila de espera); fechar isso exige um hook de cancelamento da espera no término, que é trabalho de K3/K4 e não desta rodada |
| Um `join`/`wait` de pai para filho | é K4.9; o status de saída existe (`exit_code`), mas ninguém o lê |
| Um limite de tarefas por CPU | `max_tasks` é do pool inteiro, não de uma fila |
| `tests/*_regression.zig` continuam fora do grafo de build | o achado A-13 do audit de 2026-10-31 segue aberto para esses arquivos (ver §9) |

## 9. Uma correção de leitura do estado

`docs/PROJECT_STATUS.json` (achado A-11) e `README.md` ainda dizem "no CI". A
árvore tem `.github/workflows/ci.yml` desde a rodada de 2026-11-01, e o job
`build and host tests` **passa** numa execução real registrada no GitHub Actions
(PR #4, run 41338112056). O que falhava era o job `runtime`, e a causa era um
defeito do próprio workflow: a verificação de firmware usava

```bash
ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/edk2/ovmf/OVMF_CODE*.fd \
   /usr/share/edk2/x64/OVMF_CODE*.fd
```

e `ls` com vários argumentos falha quando **qualquer** caminho não existe. Numa
distro que instala o OVMF em um desses diretórios e não nos outros — que é o caso
normal —, o passo falhava sempre, com ou sem o pacote `ovmf` instalado, e
reportava "OVMF firmware missing" sem ter olhado o par CODE/VARS. A rodada troca
o `ls` por um laço que para no primeiro **par** existente e imprime qual foi.

O comportamento foi medido, não suposto, com uma árvore de diretórios que imita
uma distro que instala só `/usr/share/edk2/x64`:

| Verificação | Resultado |
|---|---|
| `ls <3 caminhos>` (o passo antigo) | `rc=2` — o passo falharia e reportaria firmware ausente |
| o laço de pares (o passo novo) | `rc=0`, imprime o par encontrado |

O falso negativo some; a execução de verdade dos três alvos QEMU ainda depende de
um runner com os pacotes, e continua sem evidência registrada.

O mesmo arquivo dizia "no CI" em três lugares, e a árvore entrega `tests/` com
oito arquivos de teste que **nenhum** alvo compila (A-13). A rodada não fecha
A-13: fechar exige ou ligar os arquivos ao grafo (e então corrigir o
`@import("../../task/...")`, que Zig recusa fora do caminho do módulo, e o
`///` preso a um `test` em `pmm_regression.zig`) ou apagá-los depois de mover o
que é único para o módulo. O que a rodada faz é registrar a leitura correta: o
CI existe, o job de host passa, o job de runtime estava quebrado por um defeito
de shell.

## 10. A segunda rodada: a falha de runtime não deixava evidência

A PR #5 foi para o CI e o job `build and host tests` passou. O job `QEMU boot
suites` passou a chegar **de verdade** ao boot (o passo "Install QEMU and OVMF",
que antes falhava sempre, agora instala os pacotes) e então falhou, depois de
**18 min 22 s**, no passo "Automated boot". O artefato `qemu-logs` que o workflow
publica tem **807 bytes**: nenhuma evidência.

### O defeito

Os três scripts de integração criam o seu diretório de trabalho com `mktemp -d`
e o apagam no `trap` de saída:

```bash
WORK_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT
SERIAL_LOG="$WORK_DIRECTORY/serial.log"
```

O workflow, por outro lado, publica `docs/validation/logs/` — um caminho que
**nenhum** script escrevia. O artefato era, portanto, sempre vazio, e uma falha
de boot não deixava console, nem stderr do emulador, nem captura de tela. A
anotação do CI ainda por cima carrega apenas o fim do log do passo, então o
diagnóstico do kernel — a linha entre 70 mil — era perdido duas vezes.

Isso é o pior tipo de defeito de validação: o teste falha, e a informação que
diria *por que* ele falhou é destruída pelo próprio teste.

### A correção

`--evidence-dir=<path>` nos três scripts (`boot-qemu.sh`,
`interactive-qemu.sh`, `virtio-block-persistence.sh`), ligado ao `build.zig` por
`-Devidence-dir=`, com o default `docs/validation/logs` — o caminho que o
workflow publica. Em cada script:

- o diretório é criado e o `trap` é instalado **antes** de qualquer recusa de
  ambiente rodar, então "não há firmware" também deixa um resumo;
- o resumo (`summary.txt`) é escrito **primeiro**, com data, resultado, status
  de saída, duração, timeout, imagem, firmware, emulador e a lista dos checks
  que falharam;
- o console serial, o stderr do emulador e a captura de tela são copiados
  **antes** do `rm -rf` do diretório temporário;
- numa falha, as últimas 20 linhas do console são repetidas no log do passo, que
  é o pedaço que a anotação do CI carrega.

O `.gitignore` ignora os arquivos de execução (`*.log`, `*.stderr`, `*.ppm`,
`summary.txt`) e preserva o registro escrito à mão que já estava ali. O workflow
passa a usar `if-no-files-found: error`: um artefato vazio é um falso negativo, e
o job tem de dizê-lo em vez de publicar um diretório que parece um passe.

### O que foi medido

| Cenário | Resultado |
|---|---|
| `zig build qemu-test -Devidence-dir=/tmp/ev`, sem OVMF | `summary.txt` com `result: fail (exit status 2)`, `firmware_code: not found`, `qemu: not found` |
| `zig build qemu-test -Devidence-dir=docs/validation/logs` | `summary.txt` criado; `git status docs/validation/logs/` vazio (ignorado) |
| `interactive-qemu.sh --evidence-dir=...`, sem OVMF | `summary.txt` com `result: fail (exit status 2)` |
| `virtio-block-persistence.sh --evidence-dir=...`, sem QEMU | `summary.txt` com `result: fail (exit status 2)` |
| o trap com uma saída de status 7 (harness) | `result: fail (exit status 7)` — o status real, não 0 |
| array de checks vazio sob `set -u` | nenhuma referência inválida; `checks_failed: 0` |

### A evidência chegou, mas o log continua inalcançável

A execução seguinte (`b8ae418`) confirmou a correção pelo número: o artefato
`qemu-logs` foi de **807 bytes** para **86 240 bytes** e o passo "Runtime
evidence", antes um upload vazio, passou. O passo "Automated boot" falhou de
novo.

O log do passo, porém, não é legível deste ambiente: `.../jobs/<id>/logs`
redireciona para `productionresultssa*.blob.core.windows.net`, e a conexão TLS é
recusada. A **anotação** do job é servida pela própria API e chegou: uma falha,
apontando a linha **70 257** do log, com a mensagem genérica "Process completed
with exit code 1".

Um número de linha sem o texto não é diagnóstico. Mas o fato de a anotação ser
alcançável enquanto o log não é aponta a correção certa, e ela não depende de
nenhum host externo.

### A falha passa a se publicar como anotação

O GitHub Actions lê comandos de fluxo escritos no log do passo:
`::error title=...::mensagem`. O comando vira uma anotação, que é servida pela
API do repositório — o mesmo canal que já funciona.

`tests/integration/ci-annotate.sh` é o único lugar que escreve esse formato.
Escapa `%`, CR e LF (os três caracteres que encerrariam o comando) e não faz
nada quando `GITHUB_ACTIONS` não é `true`, então quem roda o script à mão vê a
saída de sempre. Os três scripts o carregam e o usam:

| Script | Anotação de falha | Anotações de recusa |
|---|---|---|
| `boot-qemu.sh` | os checks que falharam + as últimas 12 linhas do console | sem OVMF, sem `qemu-system-x86_64` |
| `interactive-qemu.sh` | a razão do monitor (via `tee` em `monitor.out`) + 12 linhas do console | sem OVMF |
| `virtio-block-persistence.sh` | o estágio e a razão + 12 linhas do console do estágio | sem `qemu-system-x86_64`, sem `timeout(1)`, sem OVMF |

Um detalhe que precisou de teste: `python3 ... <<PY 2>&1 | tee out` dentro de
`if !` mantém a decisão correta, mesmo sob `set -o pipefail` — o pipeline
inteiro falha quando o `python3` falha, e o `tee` ainda grava a razão.

### O que continua sem resposta

**Por que o boot falha nos 18 minutos.** O log do passo e o artefato ficam em
`results-receiver.actions.githubusercontent.com` e
`productionresultssa*.blob.core.windows.net`, e este ambiente não alcança nenhum
dos dois (a conexão TLS é recusada). A correção acima é o que faz a **próxima**
execução carregar a resposta: o `serial.log` e o `summary.txt` chegam ao
artefato, que é servido pelo mesmo host bloqueado aqui mas acessível a qualquer
pessoa com o navegador. Enquanto ninguém abrir esse artefato, a causa do
`exit 1` do passo "Automated boot" é **desconhecida**, e não é honesto supor.

## 11. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `scheduler` 83% → 84%; `tests_validation`
  65% → 66%; o achado K-01 e a lista de pendências do K3.
- `CHANGELOG.md`: a entrada da rodada.
- `docs/ai/context-pack.md`: o reaper na linha do escalonador.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: o item 10 do K3 marcado como
  feito, com o ponteiro para este registro.
- `tools/scripts/gen-doc-index.py`: este documento classificado (76).
- `docs/validation/qemu.md`: o procedimento de `--evidence-dir` e o que cada
  execução deixa para trás.
- `build.zig`: a opção `-Devidence-dir`, com o default que o workflow publica.
- `.github/workflows/ci.yml`: o artefato deixa de poder estar vazio
  (`if-no-files-found: error`).
- `tests/integration/ci-annotate.sh`: o formato de anotação do CI em um só
  lugar, com o escape de `%`, CR e LF.
