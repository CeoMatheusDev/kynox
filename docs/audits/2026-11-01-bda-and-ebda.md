# O trampolim e o dado do firmware: a área estendida de dados do BIOS — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nada disto foi bootado aqui.
- Companheiros: [`2026-11-01-ap-trampoline.md`](2026-11-01-ap-trampoline.md) (o
  trampolim que esta rodada protege), [`2026-11-01-cpu-affinity.md`](2026-11-01-cpu-affinity.md).
- Escopo: a leitura do ponteiro da EBDA, a regra de colocação do trampolim e a
  recusa que entra no caminho do boot.
- Fora do escopo: a leitura do resto da BDA, a EBDA de máquinas que não publicam
  o ponteiro, e qualquer boot.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 850/850 testes** |
| `zig build docs-check` | sucesso — 71 documentos classificados |

`arch-tests` foi de 176 para **181** (+5). O total foi de 845 para 850.

## 1. O buraco que o mapa do firmware esconde

O kernel coloca o bloco que inicia as APs em uma página abaixo de 1 MiB, e a
razão escolhida para considerar a região livre era o **mapa de memória do
handoff**. Esse mapa diz que a região é RAM utilizável — e ele está certo sobre a
RAM: ele foi construído pelo firmware **antes** de o firmware alocar a área
estendida de dados do BIOS (EBDA).

A EBDA é do firmware. Escrever o trampolim por cima dela corrompe dados que
ninguém mais no sistema conhece, e a falha aparece muito depois e em outro lugar:
um barramento, uma tabela de ACPI, um índice de teclado.

O ponteiro está a uma leitura de distância: a palavra em **0x40E** é o
**segmento** da EBDA, e o endereço físico é `palavra << 4`. Zero não é "EBDA no
endereço zero": é "o firmware não publicou uma".

## 2. O que o módulo promete, e o que ele não promete

`kernel/arch/x86_64/bda.zig` é puro: lê bytes, não toca em hardware, e por isso
tem testes de host que rodam em qualquer máquina.

| Função | O que faz |
|---|---|
| `ebdaFromWord(word)` | `null` para zero, senão `word << 4` — o ponteiro é um segmento |
| `ebdaBase(bytes)` | o mesmo a partir dos bytes da BDA, com `error.Short` para uma fatia que não alcança o ponteiro |
| `conventionalKiB(bytes)` | a memória convencional em KiB (0x413), para o relatório |
| `fitsBelowEbda(ebda, address, size)` | a regra: o **fim** do bloco tem de ficar na base da EBDA ou abaixo dela |

A EBDA **não tem campo de tamanho**: o firmware aloca o que quiser e nada declara
quanto. A regra é, por isso, conservadora — o bloco tem de terminar na base da
EBDA ou abaixo dela — e a função diz exatamente isso em vez de fingir que sabe
onde a EBDA acaba.

## 3. A recusa entrou no caminho do boot

`smp.prepareTrampoline` ganhou o parâmetro `ebda_base` e um erro novo,
`error.OverlapsEbda`. A ordem das verificações é a do dano crescente:

1. o bloco cabe na página e a página é a que a SIPI nomeia;
2. o bloco **não alcança a EBDA**;
3. a cópia e os campos cabem no bloco.

No boot, `main.zig` mapeia a página zero por identidade (o kernel não a mapeia:
ele mapeia a própria imagem e o framebuffer), lê a palavra e imprime o que
encontrou:

```text
[KNK] ap trampoline: EBDA at 0x9FC00 (word 0x9FC0 at 0x40E)
[KNK] ap trampoline: the firmware published no EBDA
[KNK] ap trampoline: the page of the BDA could not be mapped (OutOfTables); the EBDA was not checked
```

A terceira linha é a diferença entre "não há EBDA" e "não foi possível olhar". Uma
falha de mapeamento não é razão para parar o boot; é razão para dizer que a
verificação não aconteceu, em vez de reportar um `null` que parece uma resposta.

## 4. Os cinco testes novos

| Teste | Afirma |
|---|---|
| um ponteiro zero é um firmware sem EBDA | `ebdaFromWord(0)` é `null`, e uma BDA zerada também |
| o ponteiro é um segmento, não um endereço | `0x9FC0` vira `0x9FC00`, `0x0800` vira `0x8000` |
| a EBDA é lida na palavra de 0x40E | o ponteiro e a memória convencional saem dos offsets certos, e uma fatia curta é `error.Short` em vez de "sem EBDA" |
| um bloco que termina abaixo da EBDA cabe | o caso normal, o bloco que termina exatamente na base, e os dois casos em que ele entra na EBDA por um byte |
| um bloco cujo fim não cabe num endereço é recusado | `address + size` sem estouro não é tratado como "cabe" |

O que esses testes **não** provam: que a leitura de 0x40E funciona numa máquina
de verdade. Ela nunca foi executada — não há boot registrado aqui.

## 5. O que continua aberto

| Item | Por quê |
|---|---|
| A leitura real de 0x40E | nenhum boot aqui; a página zero nunca foi mapeada em hardware |
| O tamanho da EBDA | não existe campo; a regra conservadora é o máximo que se pode afirmar |
| Firmware que não publica o ponteiro | cai no caminho "sem EBDA"; a página 0x8000 é usada mesmo assim, e a checagem vira uma suposição documentada |
| O resto da BDA | a memória convencional é lida por completude e nada a consome ainda |

## 6. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `smp` **76% → 78%**, contagens medidas
  (850, arch 181), e a limitação "the EBDA pointer is not checked" deixa de ser
  verdade.
- `README.md`: a linha de SMP e os números dos testes.
- `docs/ai/context-pack.md`: a EBDA na linha de SMP.
- `docs/audits/2026-11-01-ap-trampoline.md`: a tabela do §7 ganha a correção
  datada do item da EBDA.
- `CHANGELOG.md`: a entrada da rodada.
