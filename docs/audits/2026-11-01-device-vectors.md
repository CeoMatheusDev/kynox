# Os vetores de dispositivo têm dono — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nenhuma MSI e nenhuma MSI-X foram entregues aqui, e nenhum vetor de
  dispositivo disparou uma vez sequer.
- Companheiros imediatos: [`2026-11-01-msi-programming.md`](2026-11-01-msi-programming.md)
  (a mensagem nos registradores da capability) e
  [`2026-11-01-msix-table.md`](2026-11-01-msix-table.md) (a tabela na memória
  do dispositivo).
- Escopo: a faixa de vetores que um dispositivo pode nomear, um ponto de entrada
  por vetor, o registro que dá dono a cada um e o despacho que trata um vetor sem
  dono como um número e não como um palpite.
- Fora do escopo: um driver que consuma um vetor, o mapeamento da janela do BAR
  e a entrega de uma mensagem em hardware.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` (185 KiB) e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 873/873 testes** |
| `zig build docs-check` | sucesso — 74 documentos classificados |
| `readelf -rW zig-out/bin/kynox-kernel` | 1724 relocações `R_X86_64_RELATIVE`, **187 dentro da tabela de stubs** |

`arch-tests` foi de 199 para **204** (+5). O total foi de 868 para 873.

## 1. Uma mensagem sem ponto de entrada não é uma interrupção

As rodadas anteriores deixaram o kernel capaz de **escrever** a mensagem: a MSI
nos registradores da capability e a MSI-X numa entrada de 16 bytes da tabela do
dispositivo. Faltava o outro lado. Um dispositivo que escreve o vetor 70 na
memória do LAPIC chega à IDT — e antes desta rodada o vetor 70 estava na faixa
"unexpected vector", ou seja, a entrega terminava num relatório de defeito do
kernel. Programar a mensagem sem o portão instalado trocaria uma interrupção por
um pânico.

O ponto de entrada não é um detalhe de encanamento. O stub é quem diz ao handler
**qual** vetor chegou: a IDT carrega o número do vetor no *stub*, e o handler
recebe esse número no primeiro argumento. Um stub compartilhado por 187 vetores
entregaria sempre o mesmo número — e um handler que perguntasse ao controlador
"qual foi?" estaria perguntando a quem não sabe. Por isso são **187 pontos de
entrada**, um por vetor, e não um.

## 2. A faixa: 68 a 254, e o 187 que não é 188

| Faixa | Dono | Constante |
|---|---|---|
| 0..31 | exceções do processador | `exception_count` |
| 32..47 | linhas de hardware (8259, e o IOAPIC quando `-Dioapic-delivery=true`) | `hardware_interrupt_count` |
| 48..63 | livres, sem portão próprio | — |
| 64..67 | inventados pelo kernel: timer local, reschedule, shootdown, halt | `apic.*_vector` |
| **68..254** | **dispositivos (MSI/MSI-X)** | `first_device_vector` + `device_vector_count` |
| 255 | vetor espúrio do LAPIC | `apic.spurious_vector` |

A conta é `255 - 68 = 187`, e ela não é `255 - 68 + 1` porque **255 fica de
fora**. O vetor 255 é o espúrio do APIC local: um dispositivo que o nomeie está
pedindo ao kernel que trate uma mensagem real como defeito do controlador. O
registro recusa o 255 com `VectorNotDeliverable` e um teste afirma isso — o
relatório do boot também diz, em texto, que o espúrio está excluído.

Os vetores 48..63 continuam sem portão próprio: nenhum dispositivo pode nomeá-los
(`registerDevice` recusa abaixo de 68) e nada os entrega.

## 3. A tabela de stubs, e o que a PIE faz com ela

Em assembly, 187 stubs e uma tabela:

```asm
INTERRUPT_ENTRY 68
...
INTERRUPT_ENTRY 254

.section .data, "aw"
kynox_device_stub_table:
    .quad kynox_interrupt_68
    ...
    .quad kynox_interrupt_254
```

Do lado do Zig, a tabela é **um** `extern`:

```zig
extern var kynox_device_stub_table: [registry.device_vector_count]usize;
```

e `install()` percorre a faixa:

```zig
for (0..registry.device_vector_count) |index| {
    setGate(registry.first_device_vector + index, kynox_device_stub_table[index]);
}
```

O kernel é **PIE** (`Type: DYN`), e a tabela guarda endereços absolutos de
símbolos do próprio kernel. Isso só está correto porque o carregador aplica as
relocações relativas antes de saltar para o kernel, e isso foi **medido**, não
suposto:

| Medição | Resultado |
|---|---|
| `readelf -h` | `Type: DYN (Position-Independent Executable file)` |
| `readelf -rW`, seção `.rela.dyn` | 1724 entradas, todas `R_X86_64_RELATIVE` |
| entradas cujo deslocamento cai na tabela | **187** (exatamente um por stub, `0x14ab5d0` + 8·i) |
| o slot GOT da própria tabela (`kynox_device_stub_table$got`) | também relocado |
| `shared/elf64.zig` `collectRelocations` | aceita só `R_X86_64_RELATIVE` com índice de símbolo 0 e alvo em segmento **gravável** |
| `boot/uefi/knb/loader.zig` `relocate` | escreve `load_bias + addend` no alvo, recusando o que sai do limite mapeado |
| `max_relocations` | 4096 — 1724 em uso, **42%** |

A tabela está em `.data` (gravável), então o carregador não a recusa em
`RelocationOutsideWritableSegment`; o acesso do Zig passa pela GOT, cujo slot
também é relocado. Três condições, todas verificadas na imagem construída aqui.
Se qualquer uma falhasse, o kernel receberia um portão apontando para um endereço
do endereço de link, e a primeira interrupção de dispositivo saltaria para o
lugar errado — por isso a condição está escrita nesta seção e não num
comentário.

## 4. O registro: um dono, dois motivos de recusa

`interrupt_registry.zig` ganhou uma segunda tabela, ao lado da das linhas:

```zig
pub const DeviceRegistrationError = error{ VectorNotDeliverable, AlreadyRegistered };

var device_registrations: [device_vector_count]Registration = @splat(.{});
```

| Recusa | Quando | Por que |
|---|---|---|
| `VectorNotDeliverable` | vetor < 68 ou vetor 255 | o vetor é da exceção, da linha, do kernel ou do espúrio — nenhum deles é de um dispositivo |
| `AlreadyRegistered` | o slot já tem handler | dois donos do mesmo vetor é um dos dois recebendo a interrupção do outro |

O resto da superfície é intencionalmente pequeno: `deviceName`, `deviceInterruptCount`,
`registeredDeviceVectors`, `unhandledDeviceCount`, `isDeviceVector`,
`dispatchDevice`, `unregisterDevice`. `unregisterDevice` **preserva o contador**:
o dispositivo entregou aquelas interrupções enquanto estava lá, e apagar o número
seria reescrever o passado. Um dono que chega depois não herda a contagem de
interrupções que chegaram antes de ele existir — também testado.

`resetForTest` limpa as duas tabelas; sem isso o contador de um teste vazaria
para o seguinte e uma suíte que passa na ordem certa falharia na ordem inversa.

## 5. O despacho: contar em vez de adivinhar

O `handler` recebe o vetor, e o primeiro ramo que o testa é o de dispositivo:

```zig
if (registry.isDeviceVector(vector)) {
    const must_switch = registry.dispatchDevice(vector);
    apic.eoi();
    return if (must_switch) 1 else 0;
}
```

Duas decisões moram nessas duas linhas:

- **`eoi()` depois do handler.** O dispositivo que é servido devagar não empilha
  uma segunda mensagem sobre a primeira; a interrupção é reconhecida quando o
  trabalho terminou, e não quando ela chegou.
- **Sem dono, conta e não chama ninguém.** `dispatchDevice` devolve `false`,
  incrementa `unhandledDeviceCount()` e não olha para o vetor seguinte. Um vetor
  sem dono é um número que o boot vai poder mostrar; um palpite seria uma
  interrupção entregue ao driver errado — o tipo de defeito que não aparece no
  primeiro teste e aparece em produção.

O ramo fica **antes** do ramo do halt IPI (67) e depois dos ramos de timer,
reschedule e shootdown: a faixa de dispositivo não pode roubar um vetor do kernel,
e `isDeviceVector` responde `false` para todos eles (testado com a linha 33 e com
o vetor 68 na mesma tabela).

## 6. `verify()` agora olha as duas pontas da faixa

`interrupt.verify()` é chamado no boot e o kernel para se ele responder `false`.
Ele comparava o ponteiro da IDT; agora ele também reconstrói o endereço do portão
a partir das três partes do descritor e compara com a tabela do assembly:

```zig
if (gateAddress(first) != kynox_device_stub_table[0]) return false;
if (gateAddress(last) != kynox_device_stub_table[registry.device_vector_count - 1]) return false;
```

As duas pontas bastam para provar que a faixa foi instalada a partir da tabela, e
não do stub "unexpected". O teste disso é o boot; no host não há como chamar
`install()` (ela carrega a IDT, instrução privilegiada).

## 7. O que o boot reporta

```text
[KNK] device vectors: 0 of 187 registered (vectors 68..254, the spurious 255 excluded)
```

`0` porque **nenhum driver consome um vetor de dispositivo** — e a linha diz isso
com a capacidade ao lado, em vez de um zero que poderia ser lido como "o kernel
não tem vetores para dar". A frase é a mesma que as outras linhas de relatório
usam: um número medido, e nenhuma afirmação de entrega.

## 8. Os cinco testes

| Teste | Afirma |
|---|---|
| um vetor de dispositivo despacha para o dono e conta as interrupções | nome, contagem, a resposta de preempção do handler, e que remover o dono preserva o contador |
| um vetor sem dono é contado e nunca despachado para um palpite | `unhandledDeviceCount` sobe, o handler não roda, e um dono que chega depois começa do zero |
| um dispositivo não pode tomar um vetor do kernel nem o espúrio | dez vetores reservados + 255 recusados; a primeira e a última posição da faixa são entregáveis |
| um segundo dono de um vetor de dispositivo é recusado | `AlreadyRegistered`, e depois da saída do primeiro o vetor passa ao segundo; remover quem nunca teve dono não é erro |
| a faixa de dispositivo e a de hardware são disjuntas | uma linha despachada como linha, um vetor despachado como dispositivo, os contadores sem se cruzar |

## 9. O que continua aberto

| Item | Por quê |
|---|---|
| Uma MSI ou MSI-X entregue | nenhum vetor de dispositivo disparou; o caminho inteiro é código e teste de host |
| Um driver que registre um vetor | nenhum driver conduz um dispositivo com MSI hoje |
| 187 vetores em uso | a faixa é a capacidade; um driver por dispositivo usaria uma fração dela |
| A janela do BAR mapeada | a tabela da MSI-X continua localizada e não escrita |
| 48..63 | livres, sem portão próprio, e inalcançáveis por um dispositivo |
| Uma MSI com vários vetores | a MSI oferece potências de dois; um vetor por dispositivo é o que o registro reserva |

## 10. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `kernel_cpu_interrupts` **75% → 78%**,
  `acpi_pci_apic` **63% → 66%**, contagens medidas (873, arch 204, 74 documentos).
- `README.md`: a linha de interrupções e os números dos testes.
- `docs/ai/context-pack.md`: os vetores de dispositivo na linha de interrupções.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: a anotação do item de interrupções.
- `CHANGELOG.md`: a entrada da rodada.
