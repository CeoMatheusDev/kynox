# KYNOX_NATIVE.md — Kynox Native Technology

> Política normativa para construir uma plataforma tecnológica própria. Este documento complementa `AGENTS.md` e `strategy.md`; agentes devem lê-lo antes de criar loaders, formatos, ABIs, bibliotecas, drivers ou subsistemas.

## 1. Princípio fundamental

O Kynox deve desenvolver seus próprios componentes, submódulos, bibliotecas, runtimes, drivers, serviços, ferramentas e formatos. A implementação deve pertencer ao projeto: código, arquitetura, APIs, ABI, testes, documentação, ciclo de vida e decisões técnicas sob controle do Kynox.

**Compatibilidade não significa dependência.** O Kynox implementa por conta própria os formatos e contratos necessários para interoperar com outros sistemas. Não usar Wine, WSL, Proton, glibc, musl, bibliotecas de compatibilidade de terceiros ou loaders prontos como fundamento da compatibilidade Linux/Windows.

Base tecnológica: Zig 0.17.0 e Assembly x86_64, respeitando os contratos externos necessários para hardware e interoperabilidade.

## 2. Três famílias de execução

A arquitetura de execução deve manter três ambientes distintos, com fronteiras e objetivos explícitos:

1. **Kynox Native (KX Native):** formato executável, ABI, loader, runtime, bibliotecas e SDK próprios. É o ambiente primário, com integração direta a processos, capabilities, IPC e serviços do Kynox.
2. **Kynox Linux Compatibility (KLC):** execução de binários Linux nativos, começando por ELF64 x86-64 e uma ABI Linux definida por escopo. Inclui parser/loader ELF, resolução de relocations, processo/stack/auxiliary vector, convenções de chamada, syscall ABI Linux e camada de compatibilidade de sinais, threads, memória e arquivos conforme forem implementados.
3. **Kynox Windows Compatibility (KWC):** execução de binários Windows nativos x86-64, começando por PE32+ e contratos Win64/NT selecionados. Inclui parser/loader PE, imports/exports, relocations, TLS, exception/unwind metadata, convenção x64, subsistema de processos/threads e implementação progressiva dos contratos Win32/NT necessários.

Esses ambientes não devem ser confundidos. O kernel continua tendo sua própria ABI. Linux e Windows são personalidades/ambientes de compatibilidade implementados sobre mecanismos internos do Kynox, não ABIs que contaminam o núcleo.

## 3. Formato e ABI nativos

O formato nativo do Kynox deve ser especificado e controlado pelo projeto. KEX já existe no repositório: primeiro auditar seu estado, finalidade, layout e uso real; evoluir o que existe antes de criar outro formato ou renomear componentes.

A especificação nativa deve definir, no mínimo:
- magic, versão, arquitetura, endianness e tamanhos;
- headers, segmentos/seções, alinhamento e limites;
- entry point e modelo de carregamento;
- relocations e símbolos;
- imports/exports e resolução de bibliotecas;
- TLS e metadados de unwind/exceções, se suportados;
- manifesto, capabilities solicitadas e metadados;
- assinatura, hash, política de confiança e rejeição de conteúdo inválido;
- dependências, versão mínima do sistema e compatibilidade ABI;
- regras de mmap, W^X, permissões e ciclo de vida.

O loader deve validar aritmética, offsets, tamanhos, alinhamentos, sobreposições, segmentos, permissões, relocations e referências antes de mapear ou executar. Nunca confiar no manifesto para conceder privilégios: o kernel/política do sistema decide capabilities.

## 4. Compatibilidade Linux e Windows: escopo real

Compatibilidade binária é um projeto de longo prazo, incremental e testável. "Executar binários nativos" significa executar os formatos e contratos originais sem recompilá-los para Kynox, dentro de uma matriz de suporte publicada.

### Linux
- ELF não é sinônimo de Linux ABI. Separar formato ELF, ABI de processo, syscall ABI, vDSO, TLS, signals, futexes, threads, filesystem semantics e bibliotecas de user-space.
- Implementar syscall ABI Linux por uma camada de tradução/dispatch própria, sem substituir a syscall ABI nativa do Kynox.
- Compatibilidade com glibc/musl é uma etapa adicional: envolve símbolos, versionamento, relocations, TLS, loader dinâmico e semântica de bibliotecas. Não alegar suporte a aplicações dinamicamente ligadas antes de esses contratos existirem.
- Começar com uma matriz pequena e explícita: arquitetura x86-64, ELF estático simples, syscalls selecionadas e testes de conformidade; expandir por famílias de chamadas.

### Windows
- PE32+ é formato de imagem, não implementação de Win32/NT.
- Separar loader PE, ABI Win64, NT system services, Win32 API, subsystem/process model, registry/configuration semantics, object handles, synchronization, exceptions/unwind, DLL loading e runtime requirements.
- Não alegar compatibilidade geral com Windows por apenas carregar PE ou resolver imports.
- Começar com executáveis x86-64 de console e subconjunto documentado de APIs; GUI, COM, DirectX, drivers Windows e aplicações complexas são escopos independentes e posteriores.

### Limites comuns
- Binários x86-64 nativos são o alvo inicial. Emulação de outras arquiteturas não está implícita.
- Compatibilidade não garante execução de qualquer programa: versões, APIs, extensões, drivers, anti-cheat, DRM e dependências específicas podem impedir execução.
- Nunca executar código incompatível em Ring 0 para contornar lacunas de ABI.
- Aplicações compatíveis continuam isoladas por processos, address spaces e políticas de segurança do Kynox.

## 5. Arquitetura interna recomendada

Separar componentes para permitir testes host e evolução independente:

- **Executable Core:** parser e validação de estruturas comuns, sem assumir ABI de sistema operacional.
- **KX Loader:** carregamento de formato nativo e resolução de dependências nativas.
- **ELF Loader / Linux Personality:** ELF + processo Linux + syscall translation + semântica Linux.
- **PE Loader / Windows Personality:** PE32+ + processo Windows + NT/Win32 compatibility services.
- **Dynamic Linker(s):** resolução de símbolos, versões, relocations, TLS e carregamento de módulos conforme cada ABI.
- **Runtime & Libraries:** bibliotecas nativas Kynox; implementações próprias dos contratos necessários para os ambientes compatíveis.
- **Conformance Harness:** corpus legal de executáveis de teste, testes diferenciais, testes de malformed input, traces de syscalls e matriz de compatibilidade.

Parser de formato deve ser código puro sempre que possível. Mapeamento de memória, criação de processo, resolução de capabilities e execução devem ocorrer em camadas separadas. Não misturar parsing de ELF/PE com chamadas diretas ao kernel.

## 6. Estratégia de implementação por etapas

1. **Inventário:** auditar KEX, ELF existente, SDK, syscalls, processo/threads, memória virtual e bibliotecas. Documentar o que está implementado, parcial ou ausente.
2. **Contratos nativos:** estabilizar process ABI, syscall ABI, KEX, relocations, linking e runtime nativo.
3. **Loader robusto:** parser/loader com validação defensiva, testes host, fuzzing e rejeição de entradas malformadas.
4. **Linux mínimo:** ELF64 estático x86-64 e conjunto pequeno de syscalls; publicar matriz e executar testes de conformidade.
5. **Linux dinâmico:** loader dinâmico, TLS, relocations avançadas, bibliotecas e expansão progressiva da syscall ABI.
6. **Windows mínimo:** PE32+ x86-64, imports/relocations essenciais, processo e subconjunto inicial de NT/Win32 para aplicações de console.
7. **Windows ampliado:** DLLs, TLS, unwind/exceptions, sincronização, filesystem/process APIs e depois APIs de GUI.
8. **Hardening/performance:** fuzzing, isolamento, assinatura, caches de linking, page sharing quando seguro, profiling e benchmarks.

Cada etapa exige critério de aceite e matriz de compatibilidade. Não avançar apenas porque um executável de demonstração iniciou.

## 7. Política de implementação própria e dependências

- Não incorporar loaders, runtimes ou subsistemas de compatibilidade prontos como implementação final.
- Não usar wrappers superficiais que apenas encaminham toda a execução para um projeto externo.
- Especificações públicas, documentação de ABI, manuais de CPU e formatos são referências normativas legítimas; implementar o comportamento no código do Kynox.
- Dependências externas em tooling/testes podem ser aceitas por ADR; componentes embarcados no sistema exigem justificativa, auditoria, licença e plano de manutenção.
- Não copiar código protegido/licenciado incompatível. Reimplementar a partir de especificações públicas e testes independentes.
- Toda exceção à política deve ser explícita, pequena e reversível.

## 8. Identidade, siglas e registro tecnológico

Cada tecnologia própria deve ter nome estável, sigla única, responsabilidade, especificação, API/ABI, estado e testes. Não inventar siglas por branding nem renomear módulos existentes sem migração justificada.

Siglas já observadas no repositório incluem KEX, KPK, KNB, KNK e KVDI. Suas expansões e contratos devem ser confirmados na documentação/código antes de serem redefinidos.

Sugestões ainda não oficiais para possíveis subsistemas: KPMM (physical memory manager), KVMM (virtual memory manager), KTS (scheduler), KIPC (IPC), KDF (driver framework), KFS (filesystem), KNS (network stack), KRT (runtime), KSL (standard library), KDM (device manager), KGE (graphics engine) e KWM (window manager). Só oficializar após verificar colisões e registrar decisão.

## 9. Requisitos de qualidade

Cada loader, parser, ABI ou serviço de compatibilidade deve possuir:
- especificação versionada e matriz explícita de suporte;
- ownership e ciclo de vida de memória definidos;
- validação de limites, overflow, alinhamento e referências;
- testes positivos, negativos, fuzzing e regressão;
- testes de interoperabilidade com artefatos de referência;
- política de segurança e isolamento;
- métricas de custo de carregamento, memória e syscall;
- documentação de limitações e incompatibilidades conhecidas.

**Regra de comunicação:** nunca dizer "compatível com Linux/Windows" sem qualificar formato, arquitetura, ABI, APIs, versões e testes efetivamente aprovados.
