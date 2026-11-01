# O vetor vem do kernel, não do driver — 2026-11-01

- Status: **implementation record**. Diz o que a árvore faz agora, com os
  comandos executados e o resultado deles. Não afirma comportamento de runtime:
  nenhum driver pediu um vetor, nenhuma MSI e nenhuma MSI-X foram entregues.
- Companheiro imediato: [`2026-11-01-device-vectors.md`](2026-11-01-device-vectors.md)
  (a faixa 68..254, um ponto de entrada por vetor e o registro que dá dono a cada
  um).
- Escopo: o alocador de vetores de dispositivo — quem pede, quanto cabe, o
  alinhamento que a MSI exige, o que a MSI-X dispensa, e o que acontece entre
  reservar e instalar.
- Fora do escopo: um driver que use o alocador, o mapeamento da janela do BAR e a
  entrega de uma mensagem em hardware.

## 0. O que foi executado

| Comando | Resultado |
|---|---|
| `zig build` | sucesso — kernel, `kynox-boot.efi` (185 KiB) e `kynox.img` (128 MiB) |
| `zig build test --summary all` (cache novo) | sucesso — **52/52 passos, 881/881 testes** |
| `zig build docs-check` | sucesso — 75 documentos classificados |

`arch-tests` foi de 204 para **212** (+8). O total foi de 873 para 881.

## 1. O buraco que a rodada anterior deixou aberto

A faixa de vetores de dispositivo tinha dono, mas o dono precisava **escolher o
número**. Um driver que pede 70 e um segundo que também pede 70 descobrem o
conflito no registro — na máquina, na ordem em que os drivers rodam, e não na
ordem em que o kernel os carrega. Pior: ninguém sabia quais vetores estavam
livres, e a resposta só existia como uma varredura manual de 187 posições.

`kernel/arch/x86_64/vector_pool.zig` é o alocador entre os dois: o driver pede um
bloco e recebe uma base; o registro continua sendo quem sabe **de quem** é cada
vetor. O pool empresta, o registro dá dono.

## 2. Três regras que vêm do hardware, não do gosto

| Regra | Por quê |
|---|---|
| **N é potência de dois** | o campo de vetores do `Message Control` tem três bits e guarda log2(N): um pedido de 3 não é expressável, e arredondar para cima autorizaria o dispositivo a usar um vetor que o kernel não reservou |
| **a base é múltipla de N** | as mensagens de um bloco de N ocupam `base .. base+N-1`; uma base fora do alinhamento atravessaria dois blocos e o dispositivo escreveria vetores do bloco seguinte |
| **o bloco termina antes do 255** | 255 é o espúrio do APIC local — um bloco que o alcançasse daria ao dispositivo um vetor que o controlador já reivindicou |

O pedido de zero é recusado junto com os que não são potência de dois: um
dispositivo que interrompe para nada é um chamador com defeito, e as duas coisas
merecem o mesmo erro explícito.

## 3. 187 não é potência de dois, e isso não é um detalhe

A faixa tem 187 vetores (68..254). Um bloco de 128 alinhado teria de começar em 0
ou em 128; 128 + 128 = 256 passa do espúrio, e 0 é uma exceção. O maior bloco que
a faixa aceita é **64**, e ele cabe **uma vez**:

| Pedido | Base alinhada | Cabe |
|---|---|---|
| 1 | 68 | sim — 68..68 |
| 2 | 68 | sim — 68..69 |
| 4 | 68 | sim — 68..71 |
| 8 | 72 | sim — 72..79 (68 % 8 = 4) |
| 16 | 80 | sim |
| 32 | 96 | sim |
| 64 | 128 | sim, uma vez — 128..191 |
| 128 | 128 | **não** — 128 + 128 = 256 |

`max_block` é calculado em comptime a partir das duas constantes do registro
(`first_device_vector`, `device_vector_count`), com a mesma aritmética que `plan`
usa. Um quarto lugar com "187" escrito à mão seria um lugar para envelhecer
errado.

## 4. MSI pede um bloco; MSI-X pede N vetores

Essa diferença é do hardware e o módulo a expõe como duas chamadas, não como um
modo:

- **MSI** põe o vetor no dado da mensagem: uma função que pede quatro vetores
  recebe `base .. base+3`, um bloco alinhado. É `reserve(4, nome)`.
- **MSI-X** carrega o vetor em cada entrada da tabela: quatro entradas são quatro
  vetores independentes, e nada precisa ser vizinho. É `reserve(1, nome)` por
  entrada — a mesma função com outro número.

O relatório do boot de uma função com MSI-X pergunta a coisa certa ("há N vetores
livres?"), e não a coisa errada ("existe um bloco alinhado de N?"). A linha do
boot mudou por causa disso:

```text
[KNK] device vectors: 0 of 187 registered, 187 free for drivers (vectors 68..254, the spurious 255 excluded)
[KNK] msix: 00:4.0 device=0x100e 32 vector(s), table at BAR 4+0x2000 (0xfe000000), PBA at BAR 4+0x3000 (pool: 187 free, enough for the 32 entries; the BAR window is not mapped)
```

## 5. Reservar não é instalar

```text
reserve(4, "virtio-blk")   ->  base 68, quatro vetores fora de circulação, sem dono
install(grant, handler)    ->  os quatro passam a ter dono no registro
release(grant)             ->  o dono sai e os quatro voltam
```

A janela entre reservar e instalar é **deliberada**, e o teste a exercita: uma
mensagem que chegue nesse intervalo não encontra dono, é contada em
`unhandledDeviceCount` e **não** é despachada para o driver que ainda está se
configurando. O contrário — registrar antes de o handler existir — seria o
registro chamando um ponteiro nulo.

`install` é **tudo ou nada**: se um dos vetores do bloco já tiver dono (um driver
que registrou à mão, um bloco de outro dono), os que já foram instalados são
devolvidos e o erro é `VectorBusy`. Meio bloco instalado é um dispositivo que
interrompe num vetor que ninguém observa.

`release` **verifica** o grant antes de liberar: base errada, contagem errada, um
vetor fora da faixa — devolve `false` e não libera nada. Uma liberação que não
pode ser checada é pior do que nenhuma: daria ao próximo driver um vetor que
outro dispositivo está usando.

## 6. As duas tabelas não podem divergir

`blockFree` pergunta às duas: o bitmap do pool **e** o registro. Um vetor
registrado à mão (fora do pool) bloqueia o bloco que o contém — testado com o
vetor 200 no meio de um bloco de 16. E `resetForTest` limpa as duas tabelas de
uma vez, porque pool e registro são duas vistas de um mesmo fato: limpar uma só
deixaria a outra descrevendo uma máquina que não existe mais.

## 7. Os oito testes

| Teste | Afirma |
|---|---|
| o bloco de um driver começa em 68 e todo tamanho é alinhado | a tabela de bases (1, 2, 4, 8, 16, 32, 64) e a propriedade `base % N == 0` para todos eles |
| 187 não é potência de dois: o maior bloco é 64 | `max_block`; 128 e 256 recusados com `CountTooLarge`; 0 e 3 com `CountNotPowerOfTwo`; o bloco de 64 cabe uma vez e o de 32 ainda cabe embaixo |
| um bloco reservado sai da conta e volta ao ser liberado | `inUse`, `freeCount`, `blockCount`, o bloco seguinte na base 72, e a segunda liberação do mesmo grant recusada |
| reservar não dá dono; instalar dá, e a lacuna é contada | a mensagem na janela contada como não tratada, o dono depois, o contador por vetor e a resposta de preempção do handler |
| instalar é tudo ou nada quando um vetor já tem dono | `VectorBusy`, os outros vetores devolvidos e o bloco ainda reservado |
| um vetor reservado não é dado a um segundo driver | dois blocos de 8 em sequência, um bloco de 16 que os atravessa recusado, e um registro à mão bloqueando o bloco que o contém |
| uma tabela de MSI-X toma um vetor por entrada | quatro reservas de 1 (68..71), quatro donos, e o bloco de 4 seguinte caindo na base 72 |
| um grant com a base ou a contagem errada não libera nada | `NotReserved` na instalação, `false` na liberação, e o vetor fora da faixa |

## 8. O que continua aberto

| Item | Por quê |
|---|---|
| Um driver que peça um vetor | o alocador existe; o primeiro consumidor, não |
| Uma MSI ou MSI-X entregue | nada disto rodou numa máquina |
| Um bloco maior que 64 | a faixa de 187 não alinha 128; um dia serão necessários mais vetores, e isso muda a IDT, não este módulo |
| A janela do BAR da MSI-X | continua não mapeada para um dispositivo que o kernel não conduz |
| Um vetor por fila de um dispositivo de várias filas | depende do driver |

## 9. Documentação atualizada junto do código

- `docs/PROJECT_STATUS.{md,json}`: `kernel_cpu_interrupts` **78% → 81%**,
  contagens medidas (881, arch 212, 75 documentos).
- `README.md`: a linha de interrupções e os números dos testes.
- `docs/ai/context-pack.md`: o alocador na linha de interrupções.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: o item de interrupções do K2.
- `CHANGELOG.md`: a entrada da rodada.
