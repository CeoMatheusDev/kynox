# MSI: a interrupção que o dispositivo entrega por escrita — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nenhuma MSI foi entregue aqui, porque nada disto rodou numa máquina.
- Companheiros: [`2026-10-31-kernel-core-audit.md`](2026-10-31-kernel-core-audit.md)
  (A–G e os defeitos), [`2026-11-01-halt-ipi-and-fatal.md`](2026-11-01-halt-ipi-and-fatal.md)
  (os vetores que o kernel reserva), [`../specs/acpi-platform.md`](../specs/acpi-platform.md).
- Escopo: a interpretação do `Message Control`, o cálculo da mensagem e do
  layout dos registradores, a programação da capability e o relatório de boot.
- Fora do escopo: MSI-X (a tabela em memória), a entrega de um vetor por um
  dispositivo, e a troca da linha do 8259 pela MSI no caminho de um driver.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` e `kynox.img` (128 MiB) |
| `zig build -Dmsi-delivery=true` | sucesso — o caminho que programa a capability compila |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 860/860 testes** |
| `zig build docs-check` | sucesso — 72 documentos classificados |

`arch-tests` foi de 181 para **191** (+10). O total foi de 850 para 860.

## 1. O buraco: uma capability lida e ignorada

`pci.CapabilityIterator` percorre a lista de capabilities e classifica
corretamente o que encontra — inclusive o caso em que o byte 2 **não** é um
tamanho, que é o da MSI. O identificador `0x05` estava documentado no próprio
código e ninguém o usava: o kernel lia "este dispositivo suporta MSI", e a
interrupção continuava chegando pela linha do 8259, com todos os limites que uma
linha compartilhada tem.

## 2. A mensagem é uma escrita na memória

| Campo | Onde |
|---|---|
| `Message Address` | `0xFEE0_0000 \| (apic_id << 12)` — o destino mora nos bits 19:12 |
| `Message Data` | o vetor nos bits 7:0, com entrega fixa, borda e destino físico |
| `Message Control` | bit 0 habilita; bits 1–3 = quantos vetores o dispositivo **pode**; bits 4–6 = quantos ele **vai** usar |

O campo de vetores é de três bits e descreve uma **potência de dois**: um pedido
de três vetores não pode ser expresso, e arredondar para cima daria ao dispositivo
um vetor que o kernel não reservou. `msi.allocate` recusa em vez de arredondar.

## 3. Os vetores do kernel não são do dispositivo

`first_device_vector = 68`, e tudo abaixo é do kernel: 0..31 exceções, 32..47
linhas de hardware, 64..67 timer local, reschedule, shootdown e parada. Entregar
o vetor 8 a um dispositivo faria o kernel tratar um pacote de rede como falha
dupla — e o teste percorre exatamente esses números.

## 4. O layout depende de dois bits

| Capability | Endereço | Superior | Dado | Máscara |
|---|---|---|---|---|
| 32 bits | +4 | — | +8 | +12 |
| 64 bits | +4 | +8 | +12 | +16 |

Um erro de aritmética aqui escreve em cima do começo da capability seguinte, e o
primeiro teste a pegar isso foi o de uma capability no fim do espaço: `offset +
12` estourava um `u8` e voltava ao começo **em silêncio**. A aritmética passou a
ser feita em `usize`, com a verificação de que o último registrador cabe antes de
converter de volta.

## 5. A ordem das escritas é a da especificação

Endereço, endereço superior (quando existe), dado, e o `Message Control` **por
último** com o bit de habilitação: o dispositivo pode entregar uma mensagem no
instante em que o bit sobe, e nesse instante tudo o mais tem de estar no lugar.

O `Message Control` mora no terceiro e quarto bytes da capability, e o espaço de
configuração legado só aceita acesso de 32 bits alinhado — então o dword inteiro
é lido, alterado e escrito de volta, o que preserva o identificador e o ponteiro
da lista que estão nos dois primeiros bytes. Há teste para isso.

## 6. Uma recusa não deixa nada pela metade

`msi.programWith` calcula o layout, monta a mensagem e valida a alocação **antes**
da primeira escrita. O teste compara os 256 bytes da imagem antes e depois de três
recusas diferentes, e eles são idênticos: uma capability meio programada é pior
que uma intocada.

## 7. A escolha é um sinalizador de build, não uma edição silenciosa

| Build | O que acontece |
|---|---|
| `zig build` (padrão) | o boot relata o que cada função oferece e o que **seria** escrito; nada é programado |
| `zig build -Dmsi-delivery=true` | a capability é programada e a linha diz endereço, dado e controle que foram escritos |

O motivo é o mesmo de `-Dioapic-delivery`: programar a MSI **desliga a INTx**
daquela função, e um driver que ainda depende da linha clássica ficaria sem
interrupção. A opção existe para que a troca seja uma decisão visível — e a linha
de boot diz qual dos dois caminhos rodou.

```text
[KNK] msi: 00:3.0 device=0x1041 MSI capable (4 vector(s)) address=0xfee00000 data=0x44 (not programmed: -Dmsi-delivery=false)
[KNK] msi: 00:4.0 device=0x100e offers MSI-X only (table in memory; not programmed here)
[KNK] msi: 1 function(s) with MSI, 1 with MSI-X only, 0 programmed
```

## 8. Os dez testes

| Teste | Afirma |
|---|---|
| a mensagem leva o APIC id da CPU e o vetor | o endereço, o dado e os campos guardados para o relatório |
| um vetor do kernel não pode ser entregue | os oito vetores reservados são recusados, e o primeiro livre é aceito |
| os campos de vetores são potências de dois de três bits | a codificação do `Message Control` nos dois deslocamentos |
| o pedido tem de ser potência de dois e caber | 1 e 4 aceitos; 3, 8 (quando o dispositivo oferece 4) e 0 recusados |
| o layout depende de 64 bits e de máscara | os quatro casos, e a recusa de uma capability que não é MSI |
| uma capability no fim do espaço não é programável | o caso que revelou o estouro do `u8` |
| programar uma MSI de 32 bits | endereço, dado, controle, e o identificador e o ponteiro preservados |
| programar uma MSI de 64 bits | o endereço superior escrito e o dado em +12 |
| uma recusa não escreve nada | três recusas, os 256 bytes idênticos |
| a capability é encontrada pela lista | MSI-X antes de MSI numa lista real, e uma função sem lista devolvendo null |

## 9. O que continua aberto

| Item | Por quê |
|---|---|
| Uma MSI entregue | nada disto rodou numa máquina; a mensagem e a programação são código e testes de host |
| MSI-X | a tabela mora na memória do dispositivo e exige mapear o BAR da tabela; não é programada aqui |
| Mais de um vetor por dispositivo | o kernel reserva **um** vetor (68) e programa um por função; uma fila por vetor não existe |
| A troca da linha | a entrega continua no 8259 para as linhas ISA, e nenhum driver consome o vetor de um dispositivo |
| Mascaramento por vetor | a capability com `per_vector_masking` tem o layout calculado e nada escreve nos bits de máscara |

## 10. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `acpi_pci_apic` **50% → 57%**, contagens
  medidas (860, arch 191), e o item "MSI parsing" deixa de existir como lacuna.
- `README.md`: a linha de ACPI/PCI/APIC e os números dos testes.
- `docs/ai/context-pack.md`: a MSI na linha de ACPI/PCI/APIC.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: o item 8 do K2 sai da lista de
  ausentes e passa a dizer o que falta (MSI-X e a entrega observada).
- `CHANGELOG.md`: a entrada da rodada.
