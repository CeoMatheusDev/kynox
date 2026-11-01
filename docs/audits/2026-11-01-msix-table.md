# MSI-X: a tabela na memória do dispositivo — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nenhuma MSI-X foi entregue aqui, e nenhuma tabela foi escrita em hardware.
- Companheiro imediato: [`2026-11-01-msi-programming.md`](2026-11-01-msi-programming.md)
  (a MSI, com os registradores no espaço de configuração).
- Escopo: a interpretação da capability (tamanho, BIR, offsets da tabela e da
  PBA), a entrada de 16 bytes, a ordem de habilitação e o relatório do boot.
- Fora do escopo: mapear o BAR do dispositivo, escrever na tabela em hardware,
  e a PBA (o vetor pendente) além de localizá-la.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 868/868 testes** |
| `zig build docs-check` | sucesso — 73 documentos classificados |

`arch-tests` foi de 191 para **199** (+8). O total foi de 860 para 868.

## 1. A diferença que a tabela faz

A MSI tem **uma** mensagem, nos registradores da capability: uma função, um
vetor. A MSI-X põe as mensagens numa **tabela na memória do dispositivo**,
apontada por um BAR, e compra com isso três coisas:

| Recurso | Por que importa |
|---|---|
| um vetor por entrada | um dispositivo com várias filas dá a cada fila o próprio vetor, e o kernel para de perguntar "qual fila foi?" depois de cada interrupção |
| mascaramento por entrada | uma fila pode ser desligada sem tocar nas outras |
| mascaramento da função inteira | a tabela pode ser preenchida antes de qualquer interrupção sair |

## 2. O campo de tamanho é o tamanho **menos um**

`Message Control` bits 10:0 guardam `N-1`. Ler o campo como "quantas" daria uma
entrada a menos em toda função — uma fila do dispositivo sem vetor — e o defeito
só apareceria num dispositivo com mais de uma fila, onde ninguém procura.

## 3. Onde a tabela está

O dword do `Table Offset/BIR` carrega o deslocamento nos bits 31:3 e o índice do
BAR nos bits 2:0; o da PBA tem o mesmo formato quatro bytes depois. O módulo
decodifica os dois em `msix.placement`, e `msix.validateTable` responde a única
pergunta que importa antes de um driver escrever: **o BAR que a capability
nomeia existe nesta função, é de memória, e a tabela cabe nele?**

| Recusa | Quando |
|---|---|
| `MissingBar` | o BIR aponta para um BAR que a função não implementa |
| `IoBar` | o BAR existe e é de espaço de I/O — a tabela é memória, escrita pela memória |
| `TableOutsideBar` | a entrada não cabe no tamanho do BAR, ou o fim dela não cabe num endereço |

## 4. A entrada e a ordem de habilitação

Uma entrada tem 16 bytes: endereço, endereço superior, dado e `Vector Control`
(bit 0 = mascarada). A mensagem é a mesma da MSI (`msi.build`), e a recusa
também: um vetor abaixo de 68 não entra na tabela de um dispositivo.

A entrada **nasce mascarada**, e isso é uma decisão, não um detalhe: preencher a
tabela e liberar um vetor são duas coisas, e a segunda só é correta quando o
handler daquele vetor existe. `msix.writeEntry` preenche; `msix.unmask` libera;
`msix.mask` volta atrás.

A ordem que a especificação manda, e que `msix.controlFor` torna explícita:

```text
função mascarada + desabilitada
   preenche a tabela (todas as entradas mascaradas)
   habilita a MSI-X          (bit 15) com a função ainda mascarada
   desmascara a função       (bit 14) por último
   desliga a INTx            (Command bit 10)
```

Sem o mascaramento da função no meio, um dispositivo com uma fila que entrega
durante o preenchimento entregaria um vetor que ainda não tem handler. E sem
desligar a INTx, o mesmo evento chegaria duas vezes — uma pela linha e uma pela
mensagem.

## 5. O que o boot reporta, e por que ele não escreve

```text
[KNK] msix: 00:4.0 device=0x100e 32 vector(s), table at BAR 4+0x2000 (0xfe000000), PBA at BAR 4+0x3000 (not programmed: the BAR window is not mapped)
[KNK] msix: 00:5.0 device=0x1041 16 vector(s) at BAR 2+0x1000, and that BAR is I/O space (the table is memory)
[KNK] msi: 1 function(s) with MSI, 1 with MSI-X only (0 with a usable table), 0 programmed
```

Escrever na tabela exige a janela do BAR mapeada, e o boot não mapeia o BAR de um
dispositivo que não conduz. O relatório diz onde a tabela está e se ela é
alcançável, o que é exatamente o que falta para um driver terminar o trabalho.

O **tamanho** do BAR não é sondado no relatório. A sonda de tamanho escreve no
registrador do BAR, e um dispositivo que o kernel não conduz pode estar ativo:
perturbar o BAR de um controlador em uso para satisfazer um número de relatório
seria trocar informação por risco. `msix.validateTable` faz a checagem de tamanho
quando quem chama já tem a medida — e é isso que o teste exercita.

## 6. Os oito testes

| Teste | Afirma |
|---|---|
| o tamanho da tabela é o campo mais um | 31 → 32, 0 → 1, e os bits de estado não inflam o tamanho |
| a tabela e a PBA saem dos dois dwords | BIR e offset dos dois, e o offset mascarado (os três bits baixos são o BIR) |
| uma capability que não é MSI-X não tem tabela | identificador errado e capability no fim do espaço |
| a tabela tem de estar num BAR de memória que existe | `MissingBar`, `IoBar`, `TableOutsideBar`, o caso que cabe, e um BIR sem BAR |
| uma entrada de 16 bytes | endereço, superior, dado e máscara; a vizinha intacta; mascarar e desmascarar |
| um vetor do kernel não entra na tabela | seis vetores reservados, e dois vetores livres diferentes na mesma tabela |
| escrever fora da janela é recusado | nenhuma escrita parcial, e mascarar/desmascarar fora da janela devolve falso |
| a função fica mascarada enquanto a tabela é preenchida | a sequência inteira dos três estados e o bit de INTx |

## 7. O que continua aberto

| Item | Por quê |
|---|---|
| Uma tabela escrita em hardware | o BAR não é mapeado para um dispositivo que não é conduzido |
| Uma MSI-X entregue | nada disto rodou numa máquina |
| A PBA | localizada e não lida: o vetor pendente exigiria ler a memória do dispositivo |
| O tamanho do BAR no relatório | exige sondar o BAR, e a sonda perturba um dispositivo ativo |
| Mais de uma fila por dispositivo | o kernel reserva um vetor (68); uma fila por vetor não existe |

## 8. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `acpi_pci_apic` **57% → 63%**, contagens
  medidas (868, arch 199).
- `README.md`: a linha de ACPI/PCI/APIC e os números dos testes.
- `docs/ai/context-pack.md`: MSI-X na linha de ACPI/PCI/APIC.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: a anotação do item 8 do K2.
- `CHANGELOG.md`: a entrada da rodada.
