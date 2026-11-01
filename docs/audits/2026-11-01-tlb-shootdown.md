# The TLB shootdown: uma IPI, uma caixa de correio e uma garantia — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nenhuma AP respondeu aqui, então **nenhuma IPI jamais foi entregue**.
- Companheiros: [`2026-11-01-reschedule-ipi.md`](2026-11-01-reschedule-ipi.md)
  (a mesma infraestrutura de IPI, outro uso),
  [`2026-11-01-cpu-affinity.md`](2026-11-01-cpu-affinity.md) e
  [`../architecture/memory-management.md`](../architecture/memory-management.md)
  (o invariante M4, que esta rodada ataca).
- Escopo: o vetor 66, a caixa de correio do pedido, o gancho das tabelas de
  página e o que acontece quando alguém não responde.
- Fora do escopo: execução do handler em hardware, migração de tarefa em
  execução e qualquer medição de latência do shootdown.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 837/837 testes** |
| `zig build docs-check` | sucesso — todo link relativo resolve, 68 documentos classificados |

`arch-tests` foi de 159 para **168** (+9). O total foi de 828 para 837.

## 1. O buraco que esta rodada fecha

`unmapKernelPage` já invalidava a entrada **local** e o comentário da função
dizia o resto com honestidade: "outros processadores não são interrompidos: quem
recicla um endereço virtual depois desta função precisa de um TLB shootdown
antes de o endereço ser usado de novo". Esse é o invariante M4: *nenhuma entrada
de TLB sobrevive a um unmap em nenhuma CPU que rodou o espaço*.

Numa máquina com mais de um processador, uma entrada velha é memória que
continua acessível **depois** de a tabela dizer que não está: a página volta para
o alocador, outro dono a recebe, e a CPU que guardou a tradução velha escreve na
página do novo dono. Nenhum teste de host pega isso — é por isso que o
mecanismo tem de existir e ser explícito, não inferido.

## 2. Uma IPI não carrega um endereço

Uma IPI entrega um vetor e nada mais. O endereço tem, portanto, de viajar pela
memória, e o vetor é só o aviso de que há um pedido novo:

```text
remetente                          receptor
---------                          --------
begin(scope, endereço, alvos)      IPI vetor 66 chega
publica geração (release)          latch: geração nova?
envia IPI a cada alvo              invlpg(addr) ou CR3 recarregado
espera pending == 0                acknowledge: pending-- (CAS)
```

| Peça | Onde |
|---|---|
| vetor 66 e `apic.sendShootdown` | `kernel/arch/x86_64/apic.zig` |
| stub do vetor | `kernel/arch/x86_64/interrupt.s` (`INTERRUPT_ENTRY 66`) |
| porta no IDT e handler | `kernel/arch/x86_64/interrupt.zig` |
| caixa de correio, geração, reconhecimento | `kernel/arch/x86_64/tlb.zig` |
| remetente, receptor, recusas, contadores | `kernel/arch/x86_64/smp.zig` |
| `invlpg` e CR3 recarregado | `kernel/arch/x86_64/cpu.{zig,s}` |

O handler encerra a interrupção no controlador **antes** de invalidar, e a
resposta é a última coisa que aquela CPU faz: quem espera está esperando
exatamente por ela.

## 3. A geração resolve o que dá errado

Duas coisas dão errado num protocolo de resposta, e as duas têm a mesma
solução:

- **o aviso chega duas vezes** (IPI reentregue): sem número, o segundo
  reconhecimento descontaria duas vezes e o pedido fecharia com uma CPU devendo
  resposta — uma garantia perdida sem ninguém notar;
- **o reconhecimento chega tarde** (o remetente já desistiu): um decremento cego
  levaria o contador de pendentes de 0 para 4 294 967 295, e o pedido seguinte
  nunca fecharia.

Cada pedido tem então um número que só cresce, cada CPU guarda o último que
serviu, e o desconto é um *compare-and-swap* que nunca passa por baixo de zero.
Os quatro desfechos de um reconhecimento são explícitos: `accepted`,
`duplicate`, `idle` e `stale`.

## 4. O que acontece quando alguém não responde

O remetente espera por um orçamento de voltas de `pause`
(`shootdown_spin_budget`, 4 milhões) e então **desiste contando o tempo**:

| Resultado | Significado |
|---|---|
| `.complete` | todos responderam; a tradução sumiu de todos |
| `.no_targets` | nenhuma outra CPU online: a invalidação local é a história toda |
| `.no_apic` | há outra CPU e o controlador não está mapeado: ninguém pode ser avisado |
| `.timeout` | as IPIs saíram e alguém não respondeu: **a garantia foi perdida** |

O `.timeout` é uma linha de boot, não um número escondido. Uma traducao velha
que sobrevive é exatamente o tipo de falha que este projeto proíbe reportar como
sucesso.

## 5. As tabelas de página não importam o APIC

`paging.zig` ganhou um gancho, não uma dependência:

```zig
pub var remote_flush: ?*const fn (u64) void = null;
pub fn installRemoteFlush(hook: ?*const fn (u64) void) void
```

O boot instala `smp.flushRemotePage` depois de mapear o APIC local. Com o gancho
nulo — uma máquina com um processador, ou a suíte de host — o comportamento é
exatamente o de antes. Um import direto de `smp` em `paging` amarraria as duas
camadas e faria os testes das tabelas precisarem de um controlador que eles não
têm.

As três saídas de página chamam o gancho depois do `invlpg` local:
`unmapKernelPage` e os dois caminhos de `unmapUserPageIn` (o que devolve a página
ao alocador e o que só remove a entrada).

## 6. Os nove testes novos

| Artefato | Teste | Afirma |
|---|---|---|
| `arch-tests` (5, em `tlb.zig`) | um pedido só termina depois de todas as respostas | geração 1, escopo e endereço certos, `pending` 2 → 1 → 0, `served` conta as duas |
| | a mesma CPU não serve o mesmo pedido duas vezes | o segundo `latch` é nulo, o segundo reconhecimento é `duplicate`, o pendente não cai |
| | um pedido abandonado conta o tempo e não aceita desconto do atrasado | `abandon` zera o pendente e conta um timeout; o reconhecimento atrasado é aceito mas não desconta; um segundo abandono não conta outro tempo |
| | o pedido seguinte tem número novo e o antigo vira obsoleto | geração 2, o reconhecimento da geração 1 é `stale`, o pendente do novo não se mexe |
| | uma caixa vazia não tem pedido para ninguém | `latch` nulo e reconhecimento `idle` |
| `arch-tests` (4, em `smp.zig`) | uma máquina com um processador não tem tradução remota | `.no_targets`, nenhum contador se move, nada pendente |
| | o shootdown recusa fingir sem controlador | com uma AP online e o APIC não mapeado: `.no_apic`, nada publicado |
| | um aviso espúrio não invalida nem conta | `handleShootdown` devolve `idle` e `served` não muda |
| | o handler invalida a página e reconhece uma vez | `accepted`, pendente 1 → 0, `served` +1, e o aviso repetido não desconta de novo |

O `invlpg` do handler é um no-op no host (a instrução só existe em
`freestanding`); o que o teste observa é o **protocolo**, que é justamente a
parte que erra em silêncio.

## 7. O que continua aberto

| Item | Por quê |
|---|---|
| Uma IPI entregue de verdade | nenhuma AP jamais respondeu aqui: vetor, porta, stub, handler e caixa de correio são código e testes de host |
| Latência do shootdown | não há medição, e o orçamento de espera é um número escolhido, não medido |
| Dois shootdowns aninhados | o remetente segura o lock enquanto espera; um pedido feito de dentro de outro pedido (ou de um handler) travaria. Os handlers não pedem shootdown, e é por isso que hoje não acontece |
| Desistência com garantia | quando o `.timeout` acontece, a página pode continuar traduzida em uma CPU; nada a persegue depois |
| Faixa de endereço no pedido | o pedido cobre uma página ou tudo; uma faixa exigiria uma lista, e o protocolo de um slot não a comporta |

## 8. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `smp` **60% → 68%**, `virtual_memory`
  **50% → 56%**, `kernel_cpu_interrupts` **66% → 70%**, as contagens medidas
  (837, arch 168) e as listas de limitação.
- `README.md`: as linhas de SMP, de memória virtual e de interrupções, e os
  números dos testes.
- `docs/architecture/memory-management.md`: o invariante M4 e a seção de
  concorrência e TLB deixam de dizer que o shootdown não existe.
- `docs/ai/context-pack.md`: o caminho do shootdown.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: a anotação do item 6 do K2.
- `CHANGELOG.md`: a entrada da rodada.
