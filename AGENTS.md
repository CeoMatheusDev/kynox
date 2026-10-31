# AGENTS.md — Diretrizes de Engenharia do Kynox

> Este arquivo é o contrato de trabalho para agentes de código, automações e colaboradores que implementam ou modificam o Kynox. Leia também `strategy.md` antes de propor mudanças arquiteturais.

## 1. Identidade e objetivo

Kynox é um sistema operacional experimental nativo para **x86_64**, escrito principalmente em **Zig 0.17.0** e Assembly x86-64.

Objetivo de longo prazo: construir um sistema operacional moderno, modular, seguro, previsível e de alto desempenho, com controle explícito do hardware, isolamento forte entre processos e uma experiência de desktop familiar a usuários de Windows (janelas, foco, barra de tarefas, gerenciamento de arquivos e configurações).

A visão é uma direção de engenharia, não uma declaração de funcionalidades já implementadas. Sempre diferencie:
- **Implementado:** código existente e integrado ao caminho executado.
- **Parcial:** existe código, mas há limitações, caminhos não integrados ou dependências pendentes.
- **Planejado:** ainda não implementado.
- **Validado:** passou pelos testes relevantes no ambiente indicado.

Nunca transforme um item planejado em uma afirmação de suporte existente.

## 2. Fonte da verdade e ordem de leitura

Antes de alterar código:

1. Leia este arquivo e `strategy.md`.
2. Leia `README.md`, `build.zig` e `build.zig.zon`.
3. Inspecione os módulos e chamadores diretamente relacionados à mudança.
4. Procure contratos, testes e documentação já existentes antes de criar novos.
5. Verifique o estado atual do Git e preserve alterações não relacionadas.

O código, os testes e os contratos versionados são a fonte da verdade. Documentação antiga pode estar desatualizada: confirme-a contra a implementação.

### Mapa atual do repositório

| Caminho | Responsabilidade |
|---|---|
| `boot/uefi/` | Aplicação UEFI e carregamento do kernel |
| `kernel/main.zig` | Inicialização e integração do núcleo |
| `kernel/arch/x86_64/` | CPU, GDT/TSS, IDT, paging, APIC, SMP, syscalls e Assembly |
| `kernel/memory/` | PMM, heap e DMA |
| `kernel/task/` | Contexto de execução e escalonador |
| `kernel/security/` | Modelo de capabilities |
| `kernel/ipc/` | Canais e comunicação entre tarefas |
| `kernel/drivers/kvdi/` | Kynox Virtual Device Interface e transporte VirtIO |
| `kernel/storage/`, `kernel/fs/` | Bloco, armazenamento e sistemas de arquivos |
| `kernel/graphics/`, `kernel/input/` | Rasterização, composição, janelas, framebuffer e entrada |
| `kernel/ai/` | Componentes experimentais de IA |
| `shared/` | Contratos compartilhados entre bootloader, kernel e user-space |
| `sdk/` | API nativa para aplicações |
| `user/` | Aplicações e código executado em modo usuário |
| `formats/` | Formatos KEX e KPK |
| `tools/` | Ferramentas de build e conversão |
| `tests/` | Testes unitários, integração e aplicações de teste |
| `scripts/` | Execução e automação local |

Não mova diretórios ou renomeie APIs apenas para adequá-los a uma arquitetura idealizada. Faça migrações pequenas, com compatibilidade e testes.

## 3. Stack obrigatória

- **Zig:** 0.17.0. Respeite `minimum_zig_version` em `build.zig.zon`.
- **Arquitetura:** AMD64 / x86_64.
- **Assembly:** sintaxe e ABI efetivamente usadas pelos arquivos `.s` existentes. Inspecione o código antes de adicionar convenções novas.
- **Boot:** UEFI nativo, com o contrato KNB → KNK.
- **Kernel:** freestanding, sem depender de libc, runtime de sistema operacional hospedeiro ou serviços de firmware após a saída dos Boot Services.
- **Build:** sistema nativo Zig em `build.zig`.
- **Validação de hardware:** QEMU/OVMF e, quando possível, hardware físico.

Não atualize a versão de Zig, o formato de build, o ABI ou o protocolo de boot incidentalmente. Uma migração dessas exige mudança isolada, justificativa e validação completa.

Não adicione dependências externas sem necessidade técnica demonstrável. Prefira código pequeno, explícito, auditável e testável. Dependências inevitáveis devem ter versão/revisão fixada, licença compatível e justificativa documentada.

## 4. Regras de arquitetura

### 4.1 Modularidade e direção das dependências

- Cada módulo deve ter uma responsabilidade delimitada e uma API pequena.
- Separe lógica pura de acesso a hardware.
- Prefira injeção de interfaces/contextos para MMIO, I/O ports, relógio, alocação e interrupções quando isso permitir testes host.
- Evite dependências circulares e imports que exponham detalhes internos.
- Contratos compartilhados devem ficar em `shared/` somente quando forem realmente usados por mais de uma camada.
- O kernel deve integrar subsistemas; não concentre novas implementações em `kernel/main.zig`.
- Não crie abstrações genéricas sem dois ou mais casos reais que as justifiquem.

### 4.2 Zig

- Use APIs e sintaxe compatíveis com Zig 0.17.0; não presuma compatibilidade com versões anteriores.
- Prefira tipos explícitos, enums para estados, structs para contratos e funções pequenas.
- Use `comptime` quando eliminar trabalho real em runtime sem prejudicar legibilidade ou tamanho do binário.
- Diferencie `[*]T`, `[]T`, ponteiros opcionais e ponteiros não nulos conforme a semântica.
- Faça conversões de inteiros explícitas; valide limites antes de converter ou calcular offsets.
- Não use `undefined` como atalho para evitar inicialização. Só o use quando todos os caminhos garantirem escrita antes da leitura.
- Propague erros com error sets adequados. Não descarte erros silenciosamente.
- Não use alocação dinâmica em ISR, caminhos de interrupção, page fault ou caminhos críticos sem uma justificativa formal.
- Prefira buffers de tamanho conhecido, pools, arenas com ciclo de vida explícito e alocadores injetados.
- Não assuma que o allocator global existe no kernel.
- Comentários devem explicar invariantes, decisões de hardware e razões não óbvias, não repetir o código.

### 4.3 Assembly x86_64

Assembly é permitido e esperado para operações que exigem controle de registradores, instruções privilegiadas, transições de privilégio, entrada/saída de interrupções e context switch.

Antes de alterar Assembly:
- Documente a convenção de chamada e os registradores preservados.
- Verifique alinhamento de stack e requisitos da System V AMD64 ABI ou da convenção específica da transição.
- Preserve os registradores exigidos pelo ABI.
- Considere red zone: código de kernel e handlers não devem depender dela; compile/configure os caminhos freestanding adequadamente.
- Valide clobbers, flags, segmentos, estado de FPU/SIMD e direção de retorno.
- Mantenha estruturas compartilhadas com Zig explicitamente dimensionadas e alinhadas.
- Não faça chamadas Zig comuns a partir de ISR sem um stub que prepare corretamente o contexto.
- Evite instruções que dependam de recursos de CPU sem verificar CPUID e habilitar o estado arquitetural necessário.

Para syscalls, documente precisamente o contrato de registradores, MSRs, stack de kernel, retorno, erros e comportamento em interrupções/preempção.

### 4.4 Memória, ownership e concorrência

- Toda região de memória deve ter proprietário, tamanho, alinhamento, permissões e ciclo de vida definidos.
- Valide overflow em `base + length`, `count * stride`, offsets e tamanhos de páginas.
- Nunca confie em endereços, comprimentos, descritores ou estruturas fornecidas por user-space/dispositivos.
- Não mantenha ponteiros para buffers de DMA após devolver a propriedade ao dispositivo.
- Use atomics com ordering explícito e justificado.
- `volatile` serve para acessos observáveis a MMIO; não substitui atomics nem sincronização.
- Use locks simples quando forem suficientes. Lock-free não é objetivo por si só: só adote quando houver modelo de memória correto, prova de progresso, tratamento de ABA e benchmark que justifique a complexidade.
- Não bloqueie enquanto segura spinlock. Defina a ordem de aquisição dos locks.
- ISR deve ser curta: reconhecer/registrar o evento, transferir trabalho para contexto apropriado e executar EOI quando aplicável.
- Evite alocações, logs formatados e operações de filesystem em caminhos de latência crítica.

### 4.5 Segurança por padrão

O objetivo é aproximar-se das propriedades de segurança de sistemas maduros, sem alegar equivalência automática ao Linux.

- Kernel valida toda fronteira de privilégio.
- User-space não recebe acesso irrestrito a MMIO, I/O ports, DMA, memória física ou registradores privilegiados.
- Recursos são concedidos por capabilities/handles explícitos e revogáveis quando aplicável.
- Princípio do menor privilégio: negar por padrão e conceder apenas o necessário.
- Páginas de usuário não devem ser simultaneamente graváveis e executáveis (W^X).
- Habilite NX quando suportado e configurado; planeje SMEP/SMAP e outras proteções conforme suporte de CPU.
- Proteja page zero, stacks e regiões sensíveis com guard pages quando o VMM permitir.
- Valide identificadores, permissões, tamanho, versão e estado em toda mensagem IPC.
- Trate dados vindos de firmware, ACPI, PCI, dispositivos, arquivos e processos como entrada não confiável.
- Não confie em manifesto de aplicativo como autoridade: o kernel precisa validar e aplicar as permissões.
- Falhas de inicialização de recursos de segurança devem falhar de forma segura; não desabilite uma proteção silenciosamente para fazer o boot avançar.

### 4.6 Drivers e hardware

- Separe descoberta, transporte, protocolo e função do dispositivo.
- Use ACPI/MADT e enumeração PCI para descobrir hardware; não transforme endereços típicos de QEMU em pressupostos universais.
- Respeite BARs, tamanhos, alinhamentos, recursos reservados e cacheability de MMIO.
- Negocie features do dispositivo explicitamente e valide as features obrigatórias.
- Para DMA, valide endereço físico, alinhamento, limites, direção, ownership e coerência de cache.
- Não faça polling infinito sem timeout, limite de tentativas ou caminho de recuperação.
- Interrupções MSI/MSI-X devem ser introduzidas com configuração, roteamento, masking e EOI corretos.
- Mantenha caminhos de fallback apenas quando forem seguros e testados.

### 4.7 User-space e UX

A direção arquitetural é executar aplicações, servidores e, progressivamente, drivers em Ring 3, usando IPC e capabilities para acessar recursos. Isso é uma meta incremental: respeite o que já está integrado hoje.

- O SDK é a fronteira pública para aplicações; não faça apps dependerem diretamente de módulos internos do kernel.
- Defina ABI versionada, estável e documentada.
- Não exponha ponteiros do kernel no ABI.
- Para buffers compartilhados, defina propriedade, sincronização, vida útil e permissões.
- A experiência desktop deve ser familiar: janelas, foco, mover/redimensionar, minimizar/maximizar, barra de tarefas, launcher, terminal, gerenciador de arquivos e configurações.
- A familiaridade visual não justifica copiar a arquitetura interna do Windows.
- O compositor deve ser isolado do kernel quando a arquitetura e o ABI permitirem.
- Priorize input responsivo, composição incremental, buffers compartilhados e apresentação sem cópias desnecessárias, mas só anuncie zero-copy quando o caminho inteiro garantir isso.

## 5. Desempenho: regras verificáveis

Não use "mais rápido", "zero-copy", "lock-free", "real-time" ou "otimizado" como adjetivos sem evidência.

Para mudanças de performance:
1. Defina a métrica e o cenário.
2. Estabeleça baseline reproduzível.
3. Identifique o custo dominante.
4. Implemente a menor mudança possível.
5. Compare resultados antes/depois.
6. Registre hardware, configuração, número de amostras e dispersão.

Métricas úteis:
- Latência de syscall e IPC (mediana, p95/p99 quando houver amostras suficientes).
- Tempo de interrupção e tempo até conclusão do trabalho diferido.
- Custo de context switch e wake-up.
- Throughput de alocação, paging, filesystem e I/O.
- Pixels/s, tempo de composição e tempo de apresentação.
- Memória estática por CPU, fragmentação, número de locks e contenção.

Regras:
- Não sacrifique segurança por ganhos não medidos.
- Evite false sharing em estruturas per-CPU e filas.
- Considere cache lines, alinhamento, TLB, localidade NUMA quando aplicável e custo de invalidação.
- Não faça benchmark com logs seriais no caminho medido, salvo quando o custo do log for a variável estudada.
- Não adote huge pages, work-stealing ou lock-free antes de existir uma baseline e um caso de uso.
- Otimização deve preservar comportamento e invariantes.

## 6. Build e validação

Com Zig 0.17.0 instalado, os comandos documentados atualmente são:

```sh
zig version
zig build
zig build test
zig build qemu-test
zig build qemu-storage-test
zig build qemu-interactive-test
zig build check
zig build qemu
```

Consulte `build.zig` para confirmar os targets e dependências atuais. Não invente targets.

### Política de testes

- Toda lógica pura nova deve ter testes host.
- Teste limites: zero, máximo, overflow, alinhamento, buffer truncado, estado inválido e entradas malformadas.
- Teste falhas de hardware por mocks/simuladores quando possível.
- Mudanças em boot, paging, interrupt, SMP, syscalls, DMA e drivers exigem teste de integração QEMU apropriado.
- Mudanças na ABI exigem testes de compatibilidade entre kernel, SDK e aplicações.
- Um teste só conta se estiver efetivamente incluído no artefato executado. Verifique que o módulo de teste importa os testes internos.
- Não altere expectativas de teste para mascarar regressões.
- Registre testes que não puderam ser executados e por quê.

Não declare build ou teste aprovado sem ter executado o comando no ambiente desta tarefa. Diferencie "não executado", "compilou", "passou em host" e "validado em QEMU".

## 7. Fluxo obrigatório para cada tarefa

1. **Entender:** descreva o comportamento atual, o contrato e os chamadores.
2. **Planejar:** identifique arquivos, invariantes, riscos e testes.
3. **Isolar:** faça uma alteração coesa; evite refatorações oportunistas.
4. **Implementar:** mantenha API pequena e erros explícitos.
5. **Testar:** execute os testes mínimos e os testes de regressão relevantes.
6. **Revisar:** procure overflow, use-after-free, race, deadlock, acesso privilegiado indevido, W^X e estados não tratados.
7. **Documentar:** atualize documentação e status real.
8. **Entregar:** resuma arquivos alterados, decisões, testes executados e pendências.

Se encontrar bug fora do escopo, registre-o; não amplie a mudança sem necessidade.

## 8. O que nunca fazer

- Não reescrever o kernel inteiro para encaixar em uma arquitetura ideal.
- Não substituir Zig por Rust/C/C++ ou introduzir libc como dependência do kernel sem decisão arquitetural explícita.
- Não introduzir POSIX/Linux ABI como objetivo implícito. Compatibilidade deve ser uma decisão de produto.
- Não criar uma syscall para contornar um problema que pertence a IPC, SDK ou serviço.
- Não executar drivers em Ring 0 por conveniência se o contrato pretendido permite isolamento; também não mover um driver para Ring 3 sem DMA, interrupções, IOMMU e delegação de recursos seguros.
- Não assumir que todos os CPUs x86_64 suportam AVX, PCID, LA57, x2APIC, NX ou outras extensões.
- Não habilitar LA57 ou trocar 4-level por 5-level paging sem detectar CPU, firmware, layout virtual, CR4.LA57 e impacto nos contratos.
- Não assumir que lock-free é sempre mais rápido ou que todas as CPUs têm topologia homogênea.
- Não usar endereços físicos fixos como solução geral para MMIO.
- Não mapear toda a memória física para Ring 3.
- Não marcar subsistemas como concluídos com base apenas em testes unitários.
- Não adicionar arquivos gerados, imagens de disco ou artefatos de build ao commit, salvo quando forem parte intencional do projeto.

## 9. Critério de conclusão

Uma tarefa está concluída somente quando:
- O comportamento está implementado e integrado ao caminho real.
- Os contratos e invariantes estão documentados.
- Testes relevantes cobrem o comportamento e falhas.
- Não há regressão conhecida nos targets relevantes.
- A documentação descreve o estado verdadeiro.
- Limitações e validações pendentes estão explícitas.

**Prioridade final:** correção → segurança → determinismo → desempenho medido → ergonomia de manutenção. O objetivo é um kernel rápido porque sua arquitetura é correta, não porque removeu verificações essenciais.
