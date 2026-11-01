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
const roadmap = @embedFile("docs/roadmap/PRODUCT_ROADMAP.md");
const status_json = @embedFile("docs/PROJECT_STATUS.json");
const adr_index = @embedFile("docs/decisions/README.md");

const planning_documents = [_]struct { path: []const u8, text: []const u8 }{
    .{ .path = "docs/strategy/market-landscape.md", .text = market },
    .{ .path = "docs/architecture/platform-architecture.md", .text = platform },
    .{ .path = "docs/architecture/graphics-platform.md", .text = graphics },
    .{ .path = "docs/architecture/application-ecosystem.md", .text = applications },
    .{ .path = "docs/architecture/security-architecture.md", .text = security },
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

test "the security document refuses to claim unimplemented guarantees" {
    try expectContains(security, "## 1. What is claimed today (and what is not)");
    try expectContains(security, "## 13. Explicit non-guarantees");
}
