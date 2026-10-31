# Kynox — Estratégia de Arquitetura e Evolução

> Roadmap técnico vivo para transformar a base atual do Kynox em um sistema operacional x86_64 moderno. Este documento define direção, dependências entre fases, critérios de aceite e decisões que precisam ser tomadas antes de implementar recursos de grande impacto.

## 1. Visão do produto

Kynox será um sistema operacional nativo x86_64, com kernel e serviços escritos prioritariamente em Zig 0.17.0 e Assembly x86_64 onde necessário.

### Objetivos de engenharia

1. **Controle de hardware:** boot UEFI, CPU, interrupções, memória física/virtual, PCI, ACPI, DMA, armazenamento, rede, vídeo e entrada.
2. **Desempenho:** baixa latência, caminhos críticos curtos, localidade por CPU, alocação previsível, pouca cópia e concorrência escalável.
3. **Segurança:** isolamento de processos, Ring 3 por padrão, capabilities, validação de fronteiras, W^X, NX e menor privilégio.
4. **Modularidade:** subsistemas com contratos pequenos, dependências explícitas e drivers/serviços desacoplados.
5. **Evolução:** ABI versionada, testes host e QEMU, observabilidade e documentação de decisões.
6. **Experiência familiar:** desktop com janelas, foco, barra de tarefas, launcher, terminal, gerenciador de arquivos e painel de configurações, sem herdar limitações internas de sistemas legados.

### Não objetivos imediatos

- Suporte universal a todo hardware x86_64.
- Microkernel puro completo antes de existir um sistema funcional.
- Lock-free em todos os subsistemas.
- JIT obrigatório para aplicações.
- Renderização Vulkan/WebGPU antes de existir driver gráfico e modelo de memória adequados.
- Garantias de segurança equivalentes às de um sistema maduro sem auditoria e validação extensivas.

A estratégia é evoluir incrementalmente um **kernel híbrido modular**, com fronteiras de user-space cada vez mais fortes. A localização final de cada serviço deve ser decidida por isolamento, desempenho e maturidade dos mecanismos de IPC/DMA/interrupt.

## 2. Estado de partida observado

A árvore atual já contém boot UEFI próprio, kernel freestanding, Assembly x86_64, módulos de memória, APIC/ACPI/SMP, syscalls, capabilities, IPC, KVDI/VirtIO, filesystem, ELF, SDK, aplicações, gráficos e testes.

O build principal está em `build.zig`; `build.zig.zon` fixa Zig mínimo 0.17.0 e não declara dependências externas. O README documenta `zig build`, `zig build test` e testes QEMU.

### Estado conhecido que deve guiar as próximas mudanças

| Área | Situação observada | Próximo cuidado |
|---|---|---|
| Boot | UEFI próprio e contrato compartilhado KNB → KNK | Preservar handoff e ExitBootServices |
| Paging | 4 níveis, páginas 4 KiB e páginas grandes 2 MiB; comentários descrevem mapeamentos identity | Planejar high-half como migração controlada, não presumir que já existe |
| APIC | Módulo xAPIC existente | Integrar descoberta MADT e eliminar pressupostos fixos |
| ACPI | Parser/módulo existe | Validar tabelas, comprimentos, checksums e endereços |
| SMP | Módulo e trampoline existentes | Auditar startup, estado por CPU e sincronização |
| Memória | PMM/heap/DMA existem | Medir fragmentação, ownership e segurança de DMA |
| Segurança | Capability module existe | Auditar enforcement em cada operação, não apenas representação |
| IPC | Canais existem | Formalizar semântica, limites, ownership e backpressure |
| KVDI | Transporte moderno VirtIO e virtqueue dividida existem | O próprio módulo documenta que o caminho de bloco ainda não conclui I/O real |
| User-space | ELF/SDK/syscalls e aplicações existem | Consolidar ABI, isolamento e gestão de processos |
| Gráficos | Raster, compositor, framebuffer e janelas existem em diferentes estágios | Separar demo integrada de desktop interativo completo |

Esta tabela é uma fotografia inicial, não substitui inspeção do código atual. Atualize-a conforme cada subsistema evoluir.

## 3. Arquitetura de referência

### 3.1 Camadas

```text
┌──────────────────────────────────────────────────────────────┐
│                         USER EXPERIENCE                      │
│  Shell · Apps · File Manager · Settings · Window Manager     │
├──────────────────────────────────────────────────────────────┤
│                         USER SERVICES                        │
│  Init · Compositor · VFS · Network · Device Services         │
├──────────────────────────────────────────────────────────────┤
│                         USER SDK / ABI                        │
│  Syscalls · IPC · Capabilities · Shared Memory · KEX          │
├──────────────────────────────────────────────────────────────┤
│                         KERNEL CORE                            │
│  Scheduler · VM · PMM · IPC Core · Security · ELF Loader     │
├──────────────────────────────────────────────────────────────┤
│                      HARDWARE ABSTRACTION                      │
│  ACPI · PCI · APIC · DMA · KVDI · Timers · Interrupts        │
├──────────────────────────────────────────────────────────────┤
│                         x86_64 PLATFORM                        │
│  UEFI · CPU · MMU · Local APIC · IOAPIC · Devices             │
└──────────────────────────────────────────────────────────────┘
```

Princípios:
- Hardware access é restrito a módulos de plataforma e drivers autorizados.
- O kernel mantém mecanismos de proteção, scheduling, memória, IPC e concessão de capabilities.
- Serviços de política (filesystem, rede, display, device management) devem migrar para Ring 3 quando o mecanismo necessário estiver seguro e funcional.
- A aplicação não conhece endereços físicos, registradores de dispositivos ou estruturas privadas do kernel.
- Contratos de ABI são explícitos, versionados e testados.

### 3.2 Organização de código alvo

A estrutura abaixo é uma direção de evolução, não uma ordem para criar diretórios vazios ou mover o código existente imediatamente.

```text
boot/
  uefi/
shared/
  arch/x86_64/
  contracts/
kernel/
  arch/x86_64/
  core/
  memory/
  task/
  ipc/
  security/
  drivers/
  storage/
  fs/
  graphics/
sdk/
  src/
formats/
user/
  sys/
    rt0/
    libsys/
    libc/             # somente quando houver necessidade e ABI estável
  services/
    init/
    vfs/
    compositor/
    networkd/
    deviced/
  drivers/
    storage/
    input/
    net/
  apps/
    shell/
    terminal/
    file-manager/
    settings/
tests/
tools/
docs/
  architecture/
  decisions/
  specs/
```

Não duplique a árvore atual por estética. Faça a extração de módulos somente quando a fronteira estiver clara e a migração puder ser testada.

### 3.3 Layout virtual: política, não constantes arbitrárias

O objetivo é manter espaço de usuário e kernel separados, com endereços não mapeados entre regiões e proteções por página. O layout definitivo depende do número de níveis de paging, largura virtual implementada, KASLR (se adotado), LA57 e estratégia KPTI.

Direção inicial para x86_64 com 4 níveis:
- User canonical lower half: endereços de usuário validados e limitados ao intervalo inferior canônico.
- Null guard: página zero sempre não mapeada.
- ELF image: segmentos mapeados conforme permissões do ELF; nunca RWX.
- Heap: regiões sob controle do VM manager.
- Shared memory/IPC: mapeamentos explícitos, com permissões e ownership definidos.
- Stack: cresce para baixo, com guard page e limites.
- Kernel: região superior canônica, inacessível em Ring 3.
- MMIO: mapeado somente no espaço do kernel ou em processo autorizado, com capability e política de cache.

Não fixe `0x8000000000000000` como fronteira universal sem validar a canonicalidade: no modo de 4 níveis, a região canônica superior começa em `0xFFFF800000000000`; o intervalo entre as metades canônicas é hole. O layout deve ser expresso em constantes e funções de validação centrais, nunca espalhado por módulos.

**High-half e KPTI são decisões separadas.** High-half posiciona o kernel na metade superior. KPTI mantém tabelas de página de usuário sem os mapeamentos normais do kernel, mitigando exposição especulativa, com custo de troca de CR3/TLB que deve ser medido. Planeje e implemente separadamente.

## 4. Plano por fases

As fases são ordenadas por dependência técnica. Uma fase pode ter vários incrementos pequenos. Não avance apenas porque o código compila: cumpra os critérios de aceite.

### Fase 0 — Baseline, contratos e observabilidade

**Objetivo:** tornar o estado do sistema reproduzível antes de mudanças estruturais.

Trabalho:
- Confirmar Zig 0.17.0 e documentar ambiente de build.
- Executar build, testes host e integração QEMU existentes.
- Catalogar boot handoff, syscall ABI, ELF, IPC, capabilities e KVDI.
- Criar matriz de funcionalidades: implementado, parcial, planejado, validado.
- Definir logs de boot consistentes e códigos de erro.
- Estabelecer benchmarks de syscall, IPC, alocação, interrupção e composição.

Aceite:
- Build e testes atuais têm resultado conhecido.
- Cada contrato crítico possui documento ou referência.
- Nenhum benchmark é publicado sem baseline e cenário reproduzível.

### Fase 1 — Boot UEFI e transição para o kernel

**Objetivo:** sair do firmware com estado de hardware conhecido e controlado.

Trabalho:
- Preservar o fluxo UEFI e a chamada correta a ExitBootServices.
- Validar memory map final, framebuffer, ACPI RSDP e endereço/segmentos do ELF do kernel.
- Definir contrato de handoff versionado, com tamanhos, alinhamento e flags.
- Planejar high-half kernel: linker layout, relocations, virtual mapping, stack, entry trampoline e handoff.
- Construir page tables próprias antes de abandonar os mapeamentos necessários do firmware.
- Remover dependência de serviços UEFI após handoff.
- Manter serial/console mínimo para diagnóstico de falhas precoces.

Riscos:
- Endereço virtual/físico confundido no handoff.
- Kernel, stack, boot info ou framebuffer não mapeados durante a troca.
- Relocação incompleta de referências.
- Mapas UEFI invalidados por alocações após a captura final.

Aceite:
- Boot repetível em QEMU/OVMF.
- Handoff validado por magic, versão, tamanho e intervalos.
- Kernel opera com suas próprias tabelas e não depende de Boot Services.
- Testes verificam mapeamentos e falhas de handoff.

### Fase 2 — CPU, exceções e interrupções

**Objetivo:** domínio previsível da CPU e de todos os caminhos de exceção.

Trabalho:
- GDT, TSS, IST e IDT com contratos explícitos.
- Stubs de Assembly com stack/alinhamento/registradores corretos.
- Tratar separadamente faults, traps e aborts.
- Ler CPUID e construir capabilities da CPU; não assumir extensões.
- Habilitar NXE antes de usar bit NX em page tables.
- Descobrir Local APIC, IOAPIC e overrides pela ACPI MADT.
- Implementar xAPIC inicialmente; avaliar x2APIC via CPUID/MSR como incremento separado.
- Configurar timer local, IPI, EOI e roteamento de IRQ.
- ISR mínima, com trabalho pesado diferido.
- PIC legado somente como fallback de compatibilidade quando necessário, não como controlador primário.

Aceite:
- Exceções críticas produzem diagnóstico sem corromper o estado.
- IRQs têm rota, máscara, prioridade e EOI definidos.
- Endereços APIC/IOAPIC vêm de descoberta validada, não de constantes de QEMU.
- Testes host cobrem parsers e configuração; QEMU valida interrupções reais.

### Fase 3 — PMM, VMM e proteção de memória

**Objetivo:** gerência segura e eficiente de memória física e virtual.

PMM:
- Gerenciar frames de 4 KiB com bitmap, buddy ou estrutura equivalente após benchmark.
- Excluir regiões reservadas, firmware, MMIO, kernel, boot info e ACPI não recuperável.
- Definir ownership, refcount e operações de reserva/liberação.
- Preparar suporte a 2 MiB e 1 GiB somente quando CPU e alinhamento permitirem.

VMM:
- 4-level paging como base; LA57 apenas se detectado e projetado.
- Map/unmap/protect com validação de canonicalidade, alinhamento e overflow.
- NX, user/supervisor, read/write e W^X.
- Guard pages, demand paging e COW em etapas separadas.
- TLB invalidation local e shootdown SMP com protocolo explícito.
- Separar mapeamentos RAM, MMIO e DMA com atributos de cache corretos.

Alocação de kernel:
- Slab/SLUB ou pools tipados para objetos pequenos, após medir o heap existente.
- Cache por CPU para reduzir contenção.
- Caminhos de fallback e limites de memória.
- Nenhuma alocação em ISR sem pool dedicado e bounded.

Aceite:
- Testes de fragmentação, double-free, frame reservado, overflow, mapeamento inválido e W^X.
- Testes de isolamento entre dois address spaces.
- TLB shootdown e concorrência validados em SMP antes de ativar livremente.

### Fase 4 — SMP, scheduler e concorrência

**Objetivo:** escalar com múltiplos núcleos sem introduzir races ou latência imprevisível.

Trabalho:
- Inicializar APs com trampoline e estado per-CPU.
- Definir estrutura per-CPU alinhada e isolada de false sharing.
- Scheduler preemptivo com fila local por CPU como direção.
- Definir prioridades, quantum, wake-up, afinidade e estados de thread.
- Work-stealing somente quando houver fila local ociosa e benchmark que comprove benefício.
- Atomics com memory ordering justificado.
- Locks com ordem documentada e sem bloquear durante spinlock.
- IPI para reschedule, TLB shootdown e coordenação entre CPUs.

Não implementar uma estrutura lock-free complexa por antecipação. Comece com locks corretos e instrumentação; otimize o gargalo identificado.

Aceite:
- Testes de stress SMP e invariantes de estado.
- Nenhuma thread executa simultaneamente em CPUs diferentes sem contrato de migração.
- Sem deadlocks conhecidos na ordem de locks.
- Métricas de fairness, latência de wake-up e contenção registradas.

### Fase 5 — Syscalls, processos e ABI de user-space

**Objetivo:** fronteira Ring 3/Ring 0 segura, estável e eficiente.

Trabalho:
- Consolidar `SYSCALL/SYSRET`, STAR/LSTAR/FMASK e estado de segmento.
- Definir stack de kernel por thread, troca segura de stack e tratamento de NMI/IRQ durante syscall.
- Documentar registradores de argumentos/retorno, erros, clobbers e convenção de chamada.
- Validar todos os ponteiros e tamanhos de user-space sem dereference inseguro.
- Implementar processos, threads, criação, término e reaping.
- Loader ELF64 com validação de segmentos, relocations suportadas, PIE e limites.
- Definir ABI versionada e testes cruzados kernel/SDK/apps.
- Introduzir KPTI como decisão de segurança separada, com análise de custo e política de mitigação.

Aceite:
- Aplicação Ring 3 executa sem permissões indevidas.
- Ponteiros inválidos não derrubam o kernel.
- Syscalls preservam estado arquitetural exigido e retornam erros consistentes.
- ELF malformado é rejeitado sem corrupção de memória.

### Fase 6 — Capabilities, IPC e serviços isolados

**Objetivo:** mover política e funcionalidades para user-space de forma segura.

Modelo:
- Capability identifica um direito sobre um recurso/objeto, não apenas um número de handle.
- Cada capability tem tipo, permissões, geração/validade e ownership.
- Handles não podem ser forjados nem reutilizados de forma a permitir ABA.
- IPC deve ter limites, backpressure, cancelamento e semântica de fechamento.
- Shared memory precisa de mapeamento autorizado, permissões, sincronização e ciclo de vida.
- Transferência de capabilities via IPC deve ser explícita e validada.
- Serviços devem reiniciar de forma controlada e ter política de falha.

Ordem sugerida:
1. Init/process manager em user-space.
2. Serviço de dispositivo e enumeração de dispositivos.
3. VFS server.
4. Drivers selecionados que não precisem de privilégio direto amplo.
5. Network service.
6. Compositor.

Drivers em Ring 3 exigem desenho seguro de DMA, interrupções, IOMMU quando disponível e delegação de recursos. Um driver não se torna seguro apenas por mudar o CPL.

Aceite:
- Processos isolados comunicam por IPC.
- Acesso negado por default e concedido por capability.
- Encerramento de serviço não deixa handles ou buffers órfãos.
- Testes de fuzz/entradas malformadas para mensagens e capabilities.

### Fase 7 — Hardware, KVDI e I/O

**Objetivo:** descoberta e acesso a dispositivos sem suposições estáticas.

Trabalho:
- ACPI: RSDP, XSDT/RSDT, MADT, FADT e tabelas necessárias com validação de checksum, tamanho e endereço.
- PCI: enumeração, BAR sizing, bridge traversal, capabilities e interrupções.
- VirtIO moderno: feature negotiation, queue lifecycle, DMA e interrupções.
- Completar VirtIO Block: submit, completion, timeout, reset e tratamento de erro.
- Storage: block layer, cache, flush/barrier e persistência.
- Rede: transporte, RX/TX queues, DMA e interrupções; stack de rede como serviço.
- MSI/MSI-X com roteamento e masking corretos.
- IOMMU/VT-d/AMD-Vi como proteção de DMA quando disponível; fallback restrito e documentado.
- Drivers físicos por classe, adicionados com testes em QEMU e hardware real quando viável.

Aceite:
- Descoberta não depende de endereço fixo.
- Operações I/O têm timeout e recuperação.
- DMA tem ownership e limites verificados.
- Teste de persistência e integridade em múltiplos boots.

### Fase 8 — Filesystem, armazenamento e formato de aplicação

**Objetivo:** ambiente persistente, atualizável e seguro.

Direção:
- VFS com contratos independentes do filesystem concreto.
- Separar namespace, permissões, cache, block layer e drivers.
- Recuperação após falha e integridade transacional.
- Sistema base imutável/read-only como objetivo, com camada de atualização atômica e rollback.
- Configuração estruturada e versionada; escolher formato após avaliar parsing, atomicidade, migração e recuperação.
- KEX como formato de aplicação empacotado: código, manifesto, recursos e metadados.
- Manifesto declara capacidades solicitadas; concessão final depende de política do sistema/usuário e enforcement do kernel.
- Bibliotecas compartilhadas imutáveis e cacheadas somente depois de ABI e loader estáveis.
- Assinatura, hash e verificação de integridade antes de executar pacotes.

Não prometa "um arquivo sem dependências" se ele ainda exige serviços ou bibliotecas do sistema. O bundle deve declarar dependências e capabilities de forma verificável.

Árvore lógica de filesystem desejada:

```text
/system/bin/       executáveis e serviços base
/system/lib/       bibliotecas compartilhadas imutáveis
/drivers/          pacotes de drivers autorizados
/config/           configuração estruturada/versionada
/devices/          descoberta e handles mediados por serviços/capabilities
/home/<user>/      dados e configurações do usuário
```

Esses caminhos são uma proposta de namespace, não diretórios já existentes. O acesso a hardware deve ocorrer por handles/IPC, não por acesso livre a arquivos especiais.

Aceite:
- Integridade e recuperação verificadas após interrupção simulada.
- Permissões de arquivos e capabilities coerentes.
- Aplicações inválidas ou não autorizadas são rejeitadas.
- Atualização/rollback não corrompe o sistema base.

### Fase 9 — Desktop e experiência de uso

**Objetivo:** interface nativa familiar, fluida e consistente.

Componentes:
- Compositor e window manager.
- Shell/launcher, taskbar, gerenciamento de foco e workspaces.
- Terminal e shell de comandos.
- File manager, settings e notificações.
- Input service para teclado, mouse, HID e hotplug.
- API de janelas e superfícies no SDK.
- Fontes, rasterização, clipboard, drag-and-drop e acessibilidade em incrementos.

Performance:
- Buffer compartilhado entre app e compositor com ownership e sincronização explícitos.
- Damage tracking e composição incremental.
- Evitar cópias entre app, compositor e apresentação quando o hardware permitir.
- VSync e frame pacing; suporte a refresh rates diferentes.
- Prioridade moderada de foco para responsividade, sem starvation de tarefas de fundo.
- Animações opcionais e limitadas por frame budget.
- Aceleração GPU somente após driver e API de submissão seguros; raster CPU continua como fallback.

"120 Hz" é uma meta de experiência, não uma garantia universal. Medir input-to-photon latency, frame time e dropped frames em hardware definido.

Aceite:
- Desktop funcional com múltiplas janelas e input real.
- Compositor não bloqueia o sistema inteiro ao travar.
- Aplicações não podem desenhar fora de suas superfícies.
- Frame pacing e latência documentados em hardware de teste.

### Fase 10 — Robustez, segurança e evolução contínua

**Objetivo:** consolidar o sistema como plataforma testável e auditável.

Trabalho:
- Fuzzing de ACPI, ELF, KEX, KPK, IPC, VFS e protocolos de dispositivos.
- Fault injection em I/O, alocação, interrupções e serviços.
- Testes de stress SMP, memória, processos e filesystem.
- Hardening de kernel: SMEP/SMAP quando disponíveis, NX, W^X, ASLR/KASLR se viável, stack canaries e validação de módulos.
- Threat model por subsistema.
- Auditoria de capabilities, DMA, syscall ABI e superfícies de ataque.
- CI reproduzível com builds, testes host e QEMU.
- Política de versões de ABI, formato de executável e handoff.
- Documentar limitações de hardware e compatibilidade.

Aceite:
- Falhas induzidas não causam corrupção silenciosa.
- Segurança tem threat model e testes verificáveis.
- Releases têm matriz de suporte e artefatos reproduzíveis.

## 5. Decisões arquiteturais que precisam de ADR

Não misture decisões de longo prazo com mudanças de implementação. Crie um registro em `docs/decisions/` para cada decisão com impacto amplo.

ADRs prioritários:

1. Kernel híbrido modular versus microkernel estrito.
2. High-half layout, KASLR e eventual KPTI.
3. 4-level paging obrigatório inicialmente; política de LA57.
4. Estratégia PMM (bitmap/buddy) e heap (slab/pools).
5. Modelo de scheduler e preempção.
6. IPC síncrono, assíncrono ou ambos; semântica de shared memory.
7. Modelo de capabilities, revogação e transferência.
8. ABI de syscall e versionamento do SDK.
9. KEX: layout, assinatura, dependências, relocations e compatibilidade.
10. Driver model: Ring 0, Ring 3, DMA e interrupções.
11. Filesystem imutável, transações, atualização e rollback.
12. Compositor: CPU/GPU, buffers, sincronização e apresentação.

Cada ADR deve conter: contexto, opções, decisão, consequências, riscos, plano de migração e critérios de reversão.

## 6. Regras de performance e concorrência

### Medir antes de otimizar

Manter benchmarks pequenos e reproduzíveis para:
- syscall round-trip;
- IPC pequeno e buffers grandes;
- context switch/wake-up;
- page fault e mapeamento;
- PMM/heap por tamanho;
- VirtIO I/O throughput e latência;
- composição completa e incremental;
- input-to-frame latency.

Separar custo de instrumentação e logs. Usar TSC somente com calibração e invariantes adequados; considerar invariância, sincronização entre CPUs e alternativa de clock.

### Lock-free é ferramenta, não requisito

Adotar estrutura lock-free somente quando:
- Existe contenção comprovada.
- O algoritmo possui garantia de progresso definida.
- ABA, reclamation e lifetime estão resolvidos.
- Memory ordering foi revisado.
- Existe stress test SMP e benchmark comparativo.

Começar com locks curtos, filas bounded e ownership claro é preferível a uma estrutura lock-free incorreta.

### Per-CPU e work-stealing

- Estruturas per-CPU devem ter alinhamento e isolamento contra false sharing.
- Acesso a dados locais deve evitar locks globais.
- Work-stealing deve ocorrer em pontos controlados e com protocolo de migração.
- Interrupções e wake-ups remotos devem usar IPI de forma limitada.
- Não assumir NUMA no hardware alvo inicial; manter caminho extensível.

## 7. Política de segurança

Threat model mínimo:
- Aplicação Ring 3 maliciosa ou defeituosa.
- Serviço de user-space comprometido.
- Dados malformados vindos de disco/rede/dispositivo.
- Firmware/ACPI inconsistente.
- DMA de dispositivo defeituoso ou hostil.
- Corridas entre threads e CPUs.
- Handles/capabilities obsoletos ou forjados.
- Falhas de alocação e esgotamento de recursos.

Controles:
- Validação em todas as fronteiras.
- Menor privilégio e capabilities tipadas.
- W^X e NX.
- Isolamento de address spaces.
- Limites para filas, buffers, processos e operações.
- Timeouts e cancelamento.
- DMA restrito e IOMMU quando disponível.
- Recuperação e reinicialização de serviços.
- Logs sem expor dados sensíveis nem executar formatação complexa em ISR.

Nenhuma técnica isolada torna o sistema "seguro como Linux". Segurança depende de implementação, revisão, testes, auditoria, atualização e resposta a vulnerabilidades.

## 8. Critérios de prioridade

Ordene trabalho nesta sequência:

1. Corrigir bugs que afetam boot, memória, privilégio ou corrupção.
2. Fechar contratos e testes de subsistemas já iniciados.
3. Integrar o caminho real (não apenas código isolado).
4. Melhorar isolamento e recuperação.
5. Medir e otimizar gargalos reais.
6. Expandir hardware e user experience.
7. Refatorar nomes/estrutura quando reduzir acoplamento de fato.

Para cada incremento, declare:
- Estado inicial.
- Objetivo mensurável.
- Arquivos e módulos envolvidos.
- Contratos afetados.
- Riscos de segurança e concorrência.
- Testes host e QEMU necessários.
- Métrica de desempenho, se aplicável.
- Critério objetivo de conclusão.

## 9. Definição de pronto por subsistema

Um subsistema não é "completo" porque tem um arquivo ou um teste unitário.

- **Implementado:** código funcional existe.
- **Integrado:** caminho de execução real o utiliza.
- **Testado:** casos normais, limites e falhas relevantes cobertos.
- **Validado:** build e testes executados no ambiente documentado.
- **Robusto:** stress/fault injection e recuperação avaliados.
- **Pronto para uso:** threat model, documentação, compatibilidade e limitações publicados.

Use esses níveis em README, roadmap e relatórios. Nunca pule níveis na comunicação.

## 10. Próximo caminho recomendado

Com a base atual, a sequência mais eficiente é:

1. Rodar e registrar baseline de `zig build`, `zig build test`, `zig build qemu-test`, `zig build qemu-storage-test` e `zig build qemu-interactive-test`.
2. Auditar o contrato KNB → KNK, mapa de memória e transição de page tables.
3. Fechar descoberta ACPI/MADT e APIC/IOAPIC, eliminando pressupostos fixos.
4. Auditar PMM/VMM, ownership, W^X, NX e limites dos address spaces.
5. Fechar SMP e invariantes do scheduler antes de otimizações lock-free.
6. Formalizar syscall ABI, IPC e enforcement de capabilities.
7. Completar o caminho real de I/O VirtIO Block, DMA, interrupções e persistência.
8. Evoluir serviços e drivers para Ring 3 conforme o modelo de recursos estiver seguro.
9. Consolidar KEX, VFS e atualização transacional.
10. Transformar o compositor atual em desktop interativo com serviços isolados.

A ordem pode mudar diante de bugs ou dependências encontradas no código, mas toda mudança de ordem deve ser justificada.

---

**Princípio central:** construir primeiro mecanismos corretos, seguros e observáveis; depois políticas e serviços modulares; por fim otimizar com medições. O Kynox deve evoluir por incrementos verificáveis, mantendo o boot funcional e sem confundir visão de produto com capacidade já entregue.


## 11. Formato executável nativo e compatibilidade Linux/Windows

Compatibilidade binária com Linux e Windows é um **objetivo explícito de produto**, não um não-objetivo. A prioridade continua sendo consolidar primeiro o ambiente nativo; compatibilidade será construída em camadas sem substituir a identidade nem a ABI do Kynox.

Leia **`KYNOX_NATIVE.md`** como especificação de política e direção para esta área.

### Três ambientes de execução

| Ambiente | Contratos principais | Direção |
|---|---|---|
| Kynox Native | KEX, ABI nativa, loader, linker, runtime e SDK | Ambiente primário e totalmente controlado pelo projeto |
| Linux Compatibility | ELF64 x86-64, Linux process ABI, syscall ABI, loader dinâmico e semântica de user-space | Executar binários Linux originais sem recompilação |
| Windows Compatibility | PE32+, Win64 ABI, NT/Win32, DLL loader, TLS e unwind | Executar binários Windows originais sem recompilação |

Não confundir formato com ABI: ELF não garante compatibilidade Linux; PE32+ não garante compatibilidade Windows. A execução real depende também de syscalls, convenções de processo, threads, memória, sinais/exceções, linking dinâmico, bibliotecas e serviços.

### Arquitetura

- Preservar a ABI nativa do Kynox como contrato primário.
- Implementar loaders e personalidades Linux/Windows em camadas isoladas.
- Compartilhar mecanismos internos seguros (address spaces, scheduler, handles, IPC, VFS e memória) sem expor a ABI de um sistema operacional à outra.
- Parser ELF/PE deve ser independente de operações privilegiadas e testável em host.
- Nunca usar execução em Ring 0 para contornar incompatibilidades.
- Bibliotecas e runtimes necessários devem ser implementados pelo projeto; dependências externas exigem ADR, auditoria e justificativa.

### Roadmap específico

1. Auditar KEX, ELF, SDK, syscall ABI, processo/threads, VMM e linker existentes.
2. Especificar e estabilizar KEX e a ABI nativa.
3. Consolidar parser/loader nativo com relocations, imports, dependências e validação.
4. Implementar Linux mínimo: ELF64 estático x86-64 e subconjunto de syscalls com testes de conformidade.
5. Expandir Linux: loader dinâmico, TLS, relocations, bibliotecas e semântica de processos/threads.
6. Implementar Windows mínimo: PE32+ x86-64 e aplicações de console com subconjunto documentado de NT/Win32.
7. Expandir Windows: DLLs, TLS, unwind/exceptions, sincronização, APIs de processo/arquivo e posteriormente GUI.
8. Fuzz, hardening, matriz de compatibilidade e benchmarks para cada incremento.

A ordem entre etapas de Linux e Windows pode ser ajustada por dependências e valor, mas ambas permanecem objetivos arquiteturais. Não prometer compatibilidade universal: publicar formatos, APIs, versões, limitações e testes efetivamente suportados.


## 12. Live progress and evidence

The current subsystem maturity snapshot is maintained in:
- docs/PROJECT_STATUS.md — human-readable progress, evidence, limitations and priorities.
- docs/PROJECT_STATUS.json — machine-readable status inventory for agents and automation.

Treat these as the current project-status source of truth, while source code and executed tests remain the authority for actual behavior. Update both status files whenever a subsystem changes state. Percentages are scoped engineering maturity estimates, not a global OS completion metric.

The current highest-value gaps are SMP scheduler integration, VMM completeness, APIC/IOAPIC discovery, full native executable ABI/linking, VFS and power-loss-safe storage, asynchronous device I/O, and complete desktop services. Linux and Windows binary compatibility remain explicit long-term goals at 0% implementation until their loaders and OS ABIs work end to end.

## 13. Identidade do produto e versionamento

A identidade pública do Kynox é derivada, não escolhida à mão: a versão técnica vive em `VERSION` (SemVer 2.0.0) e o major seleciona o nome da geração em um mapa normativo. Formato técnico `MAJOR.MINOR.PATCH-PRERELEASE`; formato público `Kynox [Geração] [VERSÃO]`. O estado atual é **Kynox One 0.1.0-alpha.1** (`docs/VERSIONING.md`).

Regras de arquitetura que decorrem disso:

1. **Uma fonte.** `version.zig` embute `VERSION`; kernel, bootloader, SDK e ferramentas importam o módulo. Nenhum componente repete a versão, a tag ou o nome da geração.
2. **Major é compatibilidade, não conclusão.** Abrir uma era significa quebrar o contrato anterior de propósito. Concluir funcionalidades dentro de uma era muda MINOR/PATCH/prerelease.
3. **Nomes são normativos.** O mapa `0 Kynox One … 14 Kynox Cosmos` está em `version.zig` e `docs/roadmap/ERAS.md`, com teste de concordância. Major sem nome é erro; não se inventa nome.
4. **Cinco linhas independentes.** Versão do sistema, identidade de geração, revisão de ABI, versões de formato binário e versões de protocolo interno evoluem por motivos diferentes e não se misturam.
5. **Release é evidência.** Tag `v` + `VERSION`, nome público gerado, autorização do mantenedor, nunca por calendário ou contagem de commits.

Os testes que sustentam a política estão em `version-tests` (fonte única, mapeamento, documentos, espelho no manifesto, ausência de literais) e `boot-markers-conformance-tests` (a linha de identidade impressa no boot continua sendo a esperada pelo teste de integração).
