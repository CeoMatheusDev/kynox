# The clock of each processor: um relógio por CPU, e um contador que sabe de quem é — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nenhuma AP respondeu aqui, então nenhum AP jamais armou um relógio.
- Companheiros: [`2026-11-01-reschedule-ipi.md`](2026-11-01-reschedule-ipi.md)
  (a IPI que acorda uma CPU sem relógio),
  [`2026-11-01-tlb-shootdown.md`](2026-11-01-tlb-shootdown.md) e
  [`2026-11-01-ap-trampoline.md`](2026-11-01-ap-trampoline.md).
- Escopo: a política de qual relógio conta em qual processador, o registro por
  CPU, a armação do timer local de uma AP com a medida do BSP, e o contador de
  ticks ignorados.
- Fora do escopo: a entrega do vetor 64 numa AP, e qualquer medição de deriva
  entre os relógios.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 841/841 testes** |
| `zig build docs-check` | sucesso — todo link relativo resolve, 69 documentos classificados |

`arch-tests` foi de 168 para **172** (+4). O total foi de 837 para 841.

## 1. O defeito que existia antes desta rodada

O handler do vetor 64 fazia isto:

```zig
const owns_tick = timer.drivesScheduler(.apic);
timer.onTick(.apic);
apic.eoi();
if (!owns_tick) return 0;
```

`drivesScheduler` é uma política **por sistema**: o 8254 é o dono, então um
tick da APIC nunca é o dono. Numa AP — que só tem o próprio timer local, porque
o 8254 não chega nela — o resultado era:

- a interrupção era reconhecida e **não preemptava**;
- o tempo não era contado (correto: o relógio do sistema é um só);
- e nada dizia que aquilo estava acontecendo: o tick simplesmente não fazia
  nada.

Ou seja: armar o timer local de uma AP teria dado uma CPU que acorda 100 vezes
por segundo para não fazer nada. Esta rodada separa as duas perguntas que
estavam juntas.

## 2. As duas perguntas

| Pergunta | Quem responde |
|---|---|
| Este tick é o **relógio do sistema** (tempo, timeouts)? | `timer.drivesScheduler(source)` — uma resposta por máquina |
| Este tick é o **relógio desta CPU** (preemptar a tarefa dela)? | `timer.drivesSchedulerOn(cpu_index, source)` — uma resposta por processador |

O registro é explícito, um papel por CPU:

| Papel | O que conta | Onde |
|---|---|---|
| `system` | o relógio da máquina: a fonte que `selectTickSource` escolheu | o BSP, com o 8254 |
| `local` | o próprio timer local da APIC; **nunca** o relógio da máquina | cada AP |

E a armação é idempotente mas não contraditória: armar duas vezes com o **mesmo**
papel não muda nada (o boot arma o BSP, e quem chama de novo não precisa saber se
já aconteceu); armar com papel **diferente** é recusado — um processador que
contasse os dois relógios é o defeito C.6 da auditoria de 2026-10-31 em outro
lugar.

## 3. O contador que torna o erro visível

Um tick que chega num processador cujo relógio não é o que disparou não é tempo
e não é preempção: é **um tick ignorado**, contado em `timer.ignoredTicks()` e
impresso no boot.

```text
[KNK] timer: cpu=0 owns the clock of the system
[KNK] timer: 0 ignored ticks (a clock that fired on a processor that does not count it)
[KNK] smp: cpu=1 clock armed (its own local APIC timer)
```

Uma configuração errada deixa de ser uma impressão e vira um número.

## 4. A AP não repete a calibração

`initApicTimer` mede o barramento do APIC com um one-shot e o TSC, e a medida
vale para a máquina inteira: `calibrated_bus_frequency` fica guardada.
`timer.armLocalApicTimer()` usa essa medida e **recusa** em vez de adivinhar:

- o APIC local não está mapeado → falso;
- não há medida (`0`) → falso;
- a frequência pedida não cabe na medida → falso.

Um divisor adivinhado é um relógio que anda na velocidade errada sem nada no log
dizendo isso.

## 5. A ordem na entrada da AP

`kynox_ap_entry` passou a fazer, **depois** do gancho que dá à CPU uma tarefa:

1. `apic.enable()` e `apic.setTpr(0)` — o APIC local de cada processador é
   habilitado por ele mesmo; o BSP habilitou o dele;
2. `timer.armCpuClock(cpu_id, .local)`;
3. `timer.armLocalApicTimer()`, cujo resultado é impresso em uma linha.

A ordem não é decorativa: um relógio armado antes de a CPU ter uma tarefa
corrente levaria o handler do tick a decidir sobre uma fila que ainda não
existe.

## 6. Os quatro testes novos

| Teste | Afirma |
|---|---|
| um processador é armado uma vez e com um papel | armar o mesmo papel duas vezes é verdadeiro e não muda nada; o papel contrário é recusado; um número fora do limite não tem relógio |
| o relógio do sistema é contado por quem o possui | `onCpuTick(0, .pit)` move o tempo **e** o contador da CPU; `onCpuTick(0, .apic)` não move nenhum dos dois e conta um ignorado |
| uma AP conta o próprio timer e nunca move o relógio do sistema | dois ticks locais movem só o contador da AP; o tempo da máquina não muda; um tick do 8254 ali é ignorado |
| um processador que ninguém armou não tem relógio | `drivesSchedulerOn` falso para as duas fontes, o tick é ignorado, e um número fora do limite não tem contador |

O que esses testes **não** provam: que a AP recebe o vetor 64. Isso exige uma AP
que respondeu, e nenhuma respondeu aqui.

## 7. O que continua aberto

| Item | Por quê |
|---|---|
| Um tick entregue numa AP | nenhuma AP respondeu; a armação é código e teste de host |
| Deriva entre os relógios | cada CPU conta o próprio tempo; nada compara os dois contadores nem corrige diferença |
| Um relógio de parede | o tempo do sistema continua contado em ticks do BSP; não há TSC por CPU na conta |
| O timer local do BSP | continua calibrado e desarmado por política (o 8254 é o dono); trocar a fonte é uma linha, e nunca foi bootado |

## 8. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `smp` **68% → 73%**,
  `kernel_cpu_interrupts` **70% → 73%**, contagens medidas (841, arch 172).
- `README.md`: as linhas de SMP, de interrupções e de testes.
- `docs/ai/context-pack.md`: o relógio por CPU.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: a anotação do K2 sobre a fonte de
  tick por CPU.
- `CHANGELOG.md`: a entrada da rodada.
