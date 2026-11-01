# ADR-0009 · SPIR-V as the canonical shader ingestion format

- Status: **accepted for planning**. No compiler or validator exists; the
  decision fixes the contract, not a capability.
- Date: 2026-10-31.
- Source ids `S*` refer to the table in
  [`market-landscape.md`](../strategy/market-landscape.md) §9.
- Related: [`graphics-compatibility.md`](../architecture/graphics-compatibility.md) §2.5, §4.3, §5.7,
  [`graphics-platform.md`](../architecture/graphics-platform.md) §7.3, §7.6,
  ADR-[0005](0005-native-graphics-api.md) (§ "SPIR-V as input is a separate decision").

## Context

ADR-0005 left shader ingestion open. The compatibility work forces the decision:

- **KVK** must consume SPIR-V: it is Vulkan's only shader format `[S17]`.
- **KGL** can translate GLSL itself, but every extra compiler is another bug
  surface; producing SPIR-V and reusing one backend is cheaper.
- **KGA** needs one canonical input so that tools, caches and drivers agree.

Vulkan's current specification is 1.4.365 `[S16]`; the SDK ships SPIR-V 1.6
revision 7 and GLSL 4.60 `[S17]`. SPIR-V is the only format all three APIs can
share without inventing a second one.

## Options

**A. A proprietary Kynox IR as the only input.**
Freedom, but every application and every toolchain must target it; KVK would
have to translate SPIR-V into it anyway, so the IR exists regardless.

**B. SPIR-V as the only input, executed directly.**
Simple, but SPIR-V is a large surface with vendor-specific capabilities and its
validation is a project on its own; executing it directly in the driver would put
the validator inside the TCB.

**C. SPIR-V as canonical *ingestion*, lowered to a small backend IR (chosen).**
The front-end accepts SPIR-V (optionally GLSL/HLSL via Kynox front-ends that emit
SPIR-V), validates it against a Kynox profile, lowers it to a minimal backend IR,
and hands that to the vendor driver. The vendor never parses SPIR-V.

## Decision

Adopt **C**.

1. **Ingestion:** SPIR-V 1.6 modules, restricted to a documented Kynox profile
   (capabilities, extensions, memory model) declared per capability tier.
2. **Validation:** structure, types, control flow, capabilities and resource
   bindings are validated before lowering; invalid modules are rejected with a
   diagnostic, never partially executed.
3. **Lowering:** SPIR-V → Kynox backend IR, a small SSA form with explicit
   resource accesses; the backend IR is the driver contract.
4. **Tooling:** Kynox ships a SPIR-V inspector and a shader cache keyed by
   module hash + profile + driver version.
5. **Other sources:** GLSL (OpenGL) and HLSL (future Direct3D) are compiled by
   Kynox front-ends *to* SPIR-V, then follow the same path. No front-end emits
   backend IR directly.
6. **Reporting:** the implementation reports the SPIR-V version it accepts; a
   module using an unsupported capability fails at pipeline creation with the
   capability named.

## Consequences

- Positive: one validation and lowering path for three APIs; Vulkan shaders pass
  through unchanged; GLSL/HLSL reuse the backend; caches are portable across
  front-ends.
- Negative: Kynox must implement a SPIR-V validator (a large, security-sensitive
  component); profile restrictions may reject shaders that other platforms
  accept, which the matrix must state.
- Neutral: the vendor driver interface becomes smaller (backend IR only), which
  supports ADR-0004's isolation goal.

## Risks

| Risk | Mitigation |
|---|---|
| Validator bugs become security holes | fuzzing corpus, differential testing, no JIT of arbitrary machine code |
| Profile too narrow | profile versioned and widened by capability tier, with tests |
| SPIR-V evolves (new versions) | accept by declared version; unknown versions rejected explicitly |
| Front-end optimiser changes semantics | conformance corpus with golden numeric results |

## Reversal criteria

If the validator cannot be made safe under fuzzing after two sustained campaigns,
the ingestion boundary moves: KVK would pass validated SPIR-V only when it comes
from a signed toolchain, and untrusted shaders would be rejected. This is a
narrowing of scope, not a new format.
