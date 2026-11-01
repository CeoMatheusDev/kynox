//************************************************************************//
//  docs_conformance.zig                                                  //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                   //
//             https://github.com/CeoMatheusDev/Kynox                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 Kynox - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! Structural guard for the planning documents.
//!
//! The architecture, market and roadmap documents are the input of the next
//! implementation phases. A broken link is caught by the link checker, but a
//! document that lost a required section, or that is not listed in the status
//! inventory, is invisible to every automated check. This test embeds the
//! documents and asserts the parts the project depends on.
//!
//! It checks structure only. It never asserts that a planned feature exists.

const std = @import("std");

const market = @embedFile("docs/strategy/market-landscape.md");
const platform = @embedFile("docs/architecture/platform-architecture.md");
const graphics = @embedFile("docs/architecture/graphics-platform.md");
const applications = @embedFile("docs/architecture/application-ecosystem.md");
const security = @embedFile("docs/architecture/security-architecture.md");
const experiences = @embedFile("docs/architecture/user-experiences.md");
const graphics_compat = @embedFile("docs/architecture/graphics-compatibility.md");
const linux_compat = @embedFile("docs/architecture/linux-compatibility.md");
const windows_compat = @embedFile("docs/architecture/windows-compatibility.md");
const compat_roadmap = @embedFile("docs/roadmap/COMPATIBILITY_ROADMAP.md");
const roadmap = @embedFile("docs/roadmap/PRODUCT_ROADMAP.md");
const kernel_audit = @embedFile("docs/audits/2026-10-31-kernel-core-audit.md");
const kernel_internals = @embedFile("docs/architecture/kernel-internals.md");
const memory_model = @embedFile("docs/architecture/memory-management.md");
const execution_model = @embedFile("docs/architecture/execution-model.md");
const driver_model = @embedFile("docs/architecture/device-driver-model.md");
const kernel_roadmap = @embedFile("docs/roadmap/KERNEL_COMPLETION_ROADMAP.md");
const status_json = @embedFile("docs/PROJECT_STATUS.json");
const adr_index = @embedFile("docs/decisions/README.md");
const ai_readme = @embedFile("docs/ai/README.md");
const ai_context = @embedFile("docs/ai/context-pack.md");
const ai_index = @embedFile("docs/ai/doc-index.json");

const planning_documents = [_]struct { path: []const u8, text: []const u8 }{
    .{ .path = "docs/strategy/market-landscape.md", .text = market },
    .{ .path = "docs/architecture/platform-architecture.md", .text = platform },
    .{ .path = "docs/architecture/graphics-platform.md", .text = graphics },
    .{ .path = "docs/architecture/application-ecosystem.md", .text = applications },
    .{ .path = "docs/architecture/security-architecture.md", .text = security },
    .{ .path = "docs/architecture/user-experiences.md", .text = experiences },
    .{ .path = "docs/architecture/graphics-compatibility.md", .text = graphics_compat },
    .{ .path = "docs/architecture/linux-compatibility.md", .text = linux_compat },
    .{ .path = "docs/architecture/windows-compatibility.md", .text = windows_compat },
    .{ .path = "docs/roadmap/COMPATIBILITY_ROADMAP.md", .text = compat_roadmap },
    .{ .path = "docs/roadmap/PRODUCT_ROADMAP.md", .text = roadmap },
    .{ .path = "docs/architecture/kernel-internals.md", .text = kernel_internals },
    .{ .path = "docs/architecture/memory-management.md", .text = memory_model },
    .{ .path = "docs/architecture/execution-model.md", .text = execution_model },
    .{ .path = "docs/architecture/device-driver-model.md", .text = driver_model },
    .{ .path = "docs/roadmap/KERNEL_COMPLETION_ROADMAP.md", .text = kernel_roadmap },
    .{ .path = "docs/audits/2026-10-31-kernel-core-audit.md", .text = kernel_audit },
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing text: {s}\n", .{needle});
        return error.MissingSection;
    }
}

test "every planning document states that it is not an implementation claim" {
    for (planning_documents) |document| {
        if (std.mem.indexOf(u8, document.text, "planning document") == null and
            std.mem.indexOf(u8, document.text, "planning") == null)
        {
            std.debug.print("document does not declare itself planning: {s}\n", .{document.path});
            return error.MissingPlanningStatement;
        }
    }
}

test "the status inventory lists every planning document" {
    for (planning_documents) |document| {
        if (std.mem.indexOf(u8, status_json, document.path) == null) {
            std.debug.print("status inventory does not reference: {s}\n", .{document.path});
            return error.DocumentNotListed;
        }
    }
}

test "the market analysis carries dated sources" {
    try expectContains(market, "## 9. Sources");
    try expectContains(market, "2026-10-31");
    try expectContains(market, "https://");
    // A market claim without a source marker is not acceptable in this file.
    if (std.mem.indexOf(u8, market, "[S1]") == null) return error.MissingSourceMarkers;
}

test "the graphics document covers the required platform areas" {
    const required = [_][]const u8{
        "## 4. Display System (KDS)",
        "## 5. GPU driver model",
        "## 6. Graphics core (KGC)",
        "## 7. Native graphics API (KGA)",
        "## 8. Renderer (KGR)",
        "## 9. Window system and compositor (KWM)",
        "## 10. Graphics tools (KGT)",
        "## 11. Security of the graphics stack",
    };
    for (required) |heading| try expectContains(graphics, heading);
}

test "the platform document separates kernel mode from user mode" {
    try expectContains(platform, "## 3. Kernel mode versus user mode");
    try expectContains(platform, "## 10. State today and next steps");
}

test "the roadmap keeps the fifteen stages and the evidence ladder" {
    try expectContains(roadmap, "### S0");
    try expectContains(roadmap, "### S15");
    try expectContains(roadmap, "**H** Hardware-validated");
    try expectContains(roadmap, "does not raise any maturity percentage");
}

test "the ADR index lists the architecture decisions created with these documents" {
    try expectContains(adr_index, "0004-graphics-stack-split.md");
    try expectContains(adr_index, "0005-native-graphics-api.md");
    try expectContains(adr_index, "0006-userspace-compositor.md");
    try expectContains(adr_index, "0007-packaging-sandbox-updates.md");
}

test "the user-experience document covers the five profiles with requirements" {
    try expectContains(experiences, "## 3. Home");
    try expectContains(experiences, "## 4. Gaming");
    try expectContains(experiences, "## 5. Development");
    try expectContains(experiences, "## 6. Enterprise");
    try expectContains(experiences, "## 7. Professional applications");
    try expectContains(experiences, "## 8. What all profiles share");
    const ids = [_][]const u8{ "HOM-01", "GAM-01", "DEV-01", "ENT-01", "PRO-01" };
    for (ids) |id| try expectContains(experiences, id);
    // A profile must never be described as a separate ABI or package format.
    try expectContains(experiences, "A profile may never change");
}

test "the platform document separates public from internal interfaces" {
    try expectContains(platform, "### 4.0 Public and internal interfaces per subsystem");
    try expectContains(platform, "Public interface (stable, versioned)");
    try expectContains(platform, "Internal interface (private, changeable)");
    try expectContains(platform, "### 4.17 Updates and recovery");
    try expectContains(platform, "### 4.18 Virtualisation and enterprise resources");
}

test "the graphics compatibility document separates KGA, KGL and KVK over one core" {
    try expectContains(graphics_compat, "## 2. KGA — the native API, formalised");
    try expectContains(graphics_compat, "## 3. KGX — the shared execution core");
    try expectContains(graphics_compat, "## 4. KGL — OpenGL compatibility");
    try expectContains(graphics_compat, "## 5. KVK — Vulkan compatibility");
    try expectContains(graphics_compat, "## 6. The shared core is not a lowest common denominator");
    try expectContains(graphics_compat, "zero overhead");
    // The document must not present any of this as implemented.
    try expectContains(graphics_compat, "Nothing here is implemented");
}

test "the Linux document separates the seven contracts and refuses to be glibc" {
    try expectContains(linux_compat, "## 2. The seven things that must be separated");
    try expectContains(linux_compat, "## 5. Syscall interface: the translation problem");
    try expectContains(linux_compat, "## 11. Security model");
    try expectContains(linux_compat, "not a port of glibc");
    try expectContains(linux_compat, "does **not** run Linux binaries today");
    try expectContains(linux_compat, "## 13. Support matrix");
}

test "the Windows document separates format, ABI, NT and Win32" {
    try expectContains(windows_compat, "## 3. The five separated contracts");
    try expectContains(windows_compat, "## 4. PE32+ loader");
    try expectContains(windows_compat, "## 6. Handles and objects (KOB)");
    try expectContains(windows_compat, "## 14. Security model");
    try expectContains(windows_compat, "does **not** run Windows binaries today");
    try expectContains(windows_compat, "not Wine");
}

test "the compatibility roadmap keeps every phase and its non-promises" {
    const phases = [_][]const u8{
        "### C0", "### C1", "### C2", "### C3", "### C4",
        "### C5", "### C6", "### C7", "### C8", "### C9", "### C10", "### C11",
    };
    for (phases) |phase| try expectContains(compat_roadmap, phase);
    try expectContains(compat_roadmap, "## 2. Critical review of the proposed order");
    try expectContains(compat_roadmap, "## 8. What this roadmap will never promise");
    try expectContains(compat_roadmap, "No phase below is complete");
}

test "no compatibility document claims that a layer runs today" {
    const docs = [_]struct { text: []const u8, claim: []const u8 }{
        .{ .text = graphics_compat, .claim = "Nothing here is implemented" },
        .{ .text = linux_compat, .claim = "KLC is 0%" },
        .{ .text = windows_compat, .claim = "KWC is 0%" },
        .{ .text = compat_roadmap, .claim = "No phase below is complete" },
    };
    for (docs) |doc| try expectContains(doc.text, doc.claim);
}

test "the security document refuses to claim unimplemented guarantees" {
    try expectContains(security, "## 1. What is claimed today (and what is not)");
    try expectContains(security, "## 13. Explicit non-guarantees");
}

test "the kernel roadmap keeps the fourteen stages and the evidence ladder" {
    const stages = [_][]const u8{
        "### K0 — Boot and architecture foundation",
        "### K1 — Memory management",
        "### K2 — Interrupts, time base and SMP",
        "### K3 — Synchronisation and scheduler",
        "### K4 — Processes and threads",
        "### K5 — Security and capabilities",
        "### K6 — Syscalls and IPC",
        "### K7 — Drivers and the device model",
        "### K8 — DMA and IOMMU readiness",
        "### K9 — Block layer and storage",
        "### K10 — VFS and filesystems",
        "### K11 — Input, console and terminal",
        "### K12 — Timekeeping and power",
        "### K13 — Diagnostics and hardening",
    };
    for (stages) |stage| try expectContains(kernel_roadmap, stage);
    // The ladder and the validation layers are the contract that keeps a plan
    // from being read as an implementation.
    try expectContains(kernel_roadmap, "| **P** Prototype | Code exists");
    try expectContains(kernel_roadmap, "| **H** Hardware-validated |");
    try expectContains(kernel_roadmap, "## 5. Validation layers");
    try expectContains(kernel_roadmap, "## 4. Genuine parallelism");
}

test "the kernel roadmap does not claim a started or completed stage" {
    try expectContains(kernel_roadmap, "No stage below is started.");
    try expectContains(kernel_roadmap, "no stage in this document is above");
    try expectContains(kernel_roadmap, "absence of an OVMF firmware image in the build environment");
}

test "the kernel audit keeps the classification vocabulary and the ranked defects" {
    const classes = [_][]const u8{
        "NOT_STARTED", "STUB", "PARTIAL", "IMPLEMENTED", "INTEGRATED", "VALIDATED",
    };
    for (classes) |class| try expectContains(kernel_audit, class);
    try expectContains(kernel_audit, "VALIDATED (host)");
    try expectContains(kernel_audit, "## 2. A. Boot and architecture");
    try expectContains(kernel_audit, "## 7. F. Storage and filesystems");
    try expectContains(kernel_audit, "## 10. Architecture defects (ranked)");
}

test "the memory model keeps the invariants and the reclaim rule" {
    try expectContains(memory_model, "## 3. Invariants (the tests are written against these)");
    try expectContains(memory_model, "| M1 |");
    try expectContains(memory_model, "| M8 |");
    try expectContains(memory_model, "## 4. Concurrency and TLB");
    try expectContains(memory_model, "never unmaps a frame");
}

test "the execution model separates threads from processes and lists the locks" {
    try expectContains(execution_model, "## 2. Objects");
    try expectContains(execution_model, "## 4. Scheduling policy");
    try expectContains(execution_model, "| **Wait queue** |");
    try expectContains(execution_model, "## 5. Synchronisation primitives (ordered by need)");
    try expectContains(execution_model, "FPU state is part of the context");
}

test "the driver model requires an interrupt registry and refuses a plugin system" {
    try expectContains(driver_model, "## 3. Interrupt registration");
    try expectContains(driver_model, "pub fn register(line: Line");
    try expectContains(driver_model, "Not a plugin system");
    try expectContains(driver_model, "## 9. Tests per driver");
}

test "the kernel documents state that the structure is planned, not built" {
    const internals_claims = [_][]const u8{
        "## 2. Target layering",
        "## 5. Global state policy",
        "## 11. Coding standards (binding for kernel work)",
    };
    for (internals_claims) |claim| try expectContains(kernel_internals, claim);
    try expectContains(kernel_internals, "What \"done\" means for the kernel");
    try expectContains(kernel_internals, "Not justified now");
}

test "the AI bundle tells an agent where to start and what is binding" {
    // The entry point has to state the reading order and the rule that no
    // number exists without a command behind it.
    try expectContains(ai_readme, "## 1. The order to read, and what each step costs");
    try expectContains(ai_readme, "## 2. Authority: what you may do with a document");
    try expectContains(ai_readme, "## 3. Hard rules (the ones an agent breaks first)");
    try expectContains(ai_readme, "A compile is not a run and a host test is not a boot");
    try expectContains(ai_readme, "**No number without a command.**");
    try expectContains(ai_readme, "AGENTS.md");

    // The context pack has to keep the sections the guide promises, and it must
    // never present a runtime result as observed.
    try expectContains(ai_context, "## 2. Commands and their results");
    try expectContains(ai_context, "**not executed**");
    try expectContains(ai_context, "## 5. The open defects that matter");
    try expectContains(ai_context, "## 6. Invariants that a change must not break");

    // The AI documents are part of the inventory, not a second source of truth.
    try expectContains(status_json, "docs/ai/README.md");
    try expectContains(status_json, "docs/ai/context-pack.md");
    try expectContains(status_json, "docs/ai/doc-index.json");
}

test "the document index parses, classifies every document and lists the reading order" {
    const index = std.json.parseFromSlice(std.json.Value, std.testing.allocator, ai_index, .{}) catch {
        return error.IndexIsNotJson;
    };
    defer index.deinit();

    const root = index.value.object;

    const documents = root.get("documents") orelse return error.MissingDocuments;
    if (documents.array.items.len < 40) return error.TooFewDocuments;

    // The authority of every entry is one of the seven that the guide defines.
    const authorities = [_][]const u8{ "binding", "current", "record", "audit", "planning", "decision", "reference" };
    for (documents.array.items) |item| {
        const entry = item.object;
        const path = entry.get("path").?.string;
        const authority = entry.get("authority").?.string;
        var known = false;
        for (authorities) |value| {
            if (std.mem.eql(u8, authority, value)) known = true;
        }
        if (!known) {
            std.debug.print("unknown authority {s} for {s}\n", .{ authority, path });
            return error.UnknownAuthority;
        }
        // The two fields the guide tells an agent to trust are never empty.
        if (entry.get("summary").?.string.len == 0) return error.MissingSummary;
        if (path.len == 0) return error.MissingPath;
    }

    // The reading order names documents that the index holds.
    const order = root.get("reading_order") orelse return error.MissingReadingOrder;
    if (order.array.items.len == 0) return error.EmptyReadingOrder;
    for (order.array.items) |item| {
        const wanted = item.string;
        var found = false;
        for (documents.array.items) |entry| {
            if (std.mem.eql(u8, entry.object.get("path").?.string, wanted)) found = true;
        }
        if (!found) {
            std.debug.print("reading order names a document that is not indexed: {s}\n", .{wanted});
            return error.UnindexedReadingStep;
        }
    }

    // The status files are in the index, with the authority that makes them the
    // only source of numbers.
    const status = [_][]const u8{ "docs/PROJECT_STATUS.md", "docs/PROJECT_STATUS.json", "README.md", "CHANGELOG.md" };
    for (status) |wanted| {
        var entry_authority: []const u8 = "";
        for (documents.array.items) |entry| {
            if (std.mem.eql(u8, entry.object.get("path").?.string, wanted)) {
                entry_authority = entry.object.get("authority").?.string;
            }
        }
        if (!std.mem.eql(u8, entry_authority, "current")) {
            std.debug.print("{s} is not indexed as current\n", .{wanted});
            return error.StatusNotCurrent;
        }
    }
}
