# A IPI de parada e a máquina que falha inteira — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nenhuma AP respondeu aqui, então nenhuma IPI jamais foi entregue.
- Companheiros: [`2026-11-01-reschedule-ipi.md`](2026-11-01-reschedule-ipi.md),
  [`2026-11-01-tlb-shootdown.md`](2026-11-01-tlb-shootdown.md),
  [`2026-11-01-per-cpu-clock.md`](2026-11-01-per-cpu-clock.md).
- Escopo: o vetor 67, o aviso de parada, o relatório de quem foi avisado e o
  caminho de falha do kernel (`kernel/fatal.zig`).
- Fora do escopo: a entrega do vetor numa segunda CPU, e qualquer reinício da
  máquina depois da parada.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 845/845 testes** |
| `zig build docs-check` | sucesso — 70 documentos classificados |

`arch-tests` foi de 172 para **176** (+4). O total foi de 841 para 845.

## 1. O buraco

Todas as falhas fatais do kernel terminavam em `port.haltForever()`, que para
**aquele** processador. Numa máquina com mais de um, isso deixa a máquina num
estado pior do que parar inteira:

- as outras CPUs continuam escrevendo no mesmo port serial, então o relatório da
  falha sai intercalado com o trabalho normal — e um relatório ilegível é um
  defeito que não se reproduz;
- o alocador, os locks e as filas continuam sendo usados por quem não sabe que
  uma invariante acabou de quebrar.

## 2. A parada é um aviso, não um acordo

```text
quem falhou                        as outras CPUs
-----------                        ---------------
imprime o motivo                   recebem o vetor 67
stopOtherCpus()                    apic.eoi()
  conta os alvos                   handleStop() conta a parada
  entrega uma IPI por alvo         hlt para sempre
imprime o relatório
hlt para sempre
```

A CPU que recebe **não responde**: ela para, e uma CPU parada não manda
reconhecimento. É por isso que o relatório promete o que dá para prometer — "N
avisadas" — e não "N pararam". O `StopReport` carrega os dois números porque são
fatos diferentes:

| Campo | Significado |
|---|---|
| `targets` | processadores online que não são o que pediu |
| `delivered` | IPIs realmente escritas no controlador |
| `no_apic` | havia alvo e o APIC local não está mapeado: ninguém pôde ser avisado |

E a linha impressa diz qual dos três casos aconteceu:

```text
[KNK] panic: no other CPU online; this processor stops alone
[KNK] panic: 3 other CPU(s) online, 2 told to stop
[KNK] panic: 1 other CPU(s) online, none told to stop: the local APIC is not mapped
[KNK] panic: this processor stops here
```

## 3. O caminho de falha virou um lugar só

`kernel/fatal.zig` substitui as 176 chamadas a `port.haltForever()` que estavam
espalhadas pelo boot e pelo handler de exceções (174 em `main.zig`, 2 em
`interrupt.zig`). Duas portas de entrada:

- `fatal.stopTheMachine(reason)` — imprime `[KNK] FATAL: {reason}` e para;
- `fatal.stopAfterReport()` — o motivo já foi impresso por quem chamou (com um
  nome de erro, um endereço, um valor esperado), e a função acrescenta o aviso às
  outras CPUs e a linha final.

O módulo **não aloca memória**: ele roda no caminho da falha, onde o alocador
pode ser justamente o que quebrou. A formatação usa um buffer do chamador.

A única `port.haltForever()` que restou no handler é a do próprio vetor 67, e é
intencional: essa CPU já foi avisada por outra e não tem a quem avisar.

## 4. Os quatro testes novos

| Teste | Afirma |
|---|---|
| uma máquina com um processador não tem quem parar | zero alvos, zero entregues, `no_apic` falso, nenhum contador se move, e a linha diz "this processor stops alone" |
| uma parada sem controlador diz isso em vez de fingir | um alvo, nada entregue, `no_apic` verdadeiro, e a linha contém "none told to stop" e "not mapped" |
| o relatório de uma parada conta as CPUs avisadas | com três alvos e duas entregas a linha carrega os dois números |
| um processador que recebe a parada conta uma vez | `handleStop()` devolve verdadeiro e o contador sobe |

O que esses testes **não** provam: que uma CPU parou. Isso exige uma segunda CPU
que tenha recebido a IPI, e nenhuma recebeu aqui.

## 5. O que continua aberto

| Item | Por quê |
|---|---|
| Uma parada observada | nenhuma AP respondeu; o aviso é código e teste de host |
| Esperar a parada | o remetente não espera (não há reconhecimento); uma CPU presa continua presa |
| Reiniciar depois da falha | não há reinício: a máquina para, e o registro é o que sobra |
| O vetor numa AP | depende da AP existir, como todos os outros três |

## 6. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `smp` **73% → 76%**,
  `kernel_cpu_interrupts` **73% → 75%**, contagens medidas (845, arch 176).
- `README.md`: a linha de interrupções (quatro vetores do kernel agora) e a de
  SMP.
- `docs/ai/context-pack.md`: a parada da máquina.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: o item 6 do K2 deixa de listar a
  halt IPI como ausente.
- `CHANGELOG.md`: a entrada da rodada.
