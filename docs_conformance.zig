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
const status_json = @embedFile("docs/PROJECT_STATUS.json");
const adr_index = @embedFile("docs/decisions/README.md");

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
