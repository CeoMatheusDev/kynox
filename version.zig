//************************************************************************//
//  version.zig                                                           //
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

//! Identity and version of the Kynox system, resolved at compile time.
//!
//! **One source.** The technical version is the content of the root file
//! `VERSION`. This module embeds that file; nothing else in the tree spells
//! the version or the generation name. `build.zig.zon` repeats the version
//! because the package manifest is another language, and a test fails when the
//! two disagree.
//!
//! **The official name is derived, never chosen.** Semantic Versioning fixes
//! the number; the major number selects the generation name from the table in
//! this file (the normative copy, mirrored in `docs/roadmap/ERAS.md`, with a
//! test that keeps both in step). Major `0` is always `Kynox One`; majors `1`
//! to `14` have their own names; a major without a name is rejected at compile
//! time instead of being invented.
//!
//!   * Technical form:  `MAJOR.MINOR.PATCH-PRERELEASE`
//!   * Public form:     `Kynox [Generation] [VERSION]`
//!   * Example:         `Kynox One 0.1.0-alpha.1`
//!
//! **Four independent version lines exist** and must not be confused:
//!
//!   * **System version** — this module, from `VERSION`, SemVer 2.0.0,
//!     released with a `v`-prefixed Git tag (`v0.1.0-alpha.1`).
//!   * **Generation/era identity** — the major number and its official name
//!     (`Kynox One`), from the table below.
//!   * **Native ABI revision** — `shared/syscall_abi.zig`; changes when the
//!     user/kernel contract changes, not when the product version changes.
//!   * **Binary format versions** — handoff, KEX, KPK, KNV and the internal
//!     protocol versions; each one is a field in its own header.
//!
//! See `docs/VERSIONING.md` for the policy, `docs/roadmap/ERAS.md` for the
//! generation map and the release procedure.

const std = @import("std");

/// Product name used in the public identity.
pub const name = "Kynox";

/// Root file that holds the technical version. It is the only writable
/// source; every other mention is derived from it.
pub const source_file = "VERSION";

/// Raw bytes of `VERSION`, exactly as committed.
const file_bytes = @embedFile("VERSION");

/// `VERSION` without surrounding whitespace, i.e. the technical version.
pub const string = std.mem.trim(u8, file_bytes, " \t\r\n");

/// Parsed technical version. A malformed `VERSION` fails the compilation:
/// there is no build of Kynox with an unparseable version.
pub const semver = std.SemanticVersion.parse(string) catch
    @compileError("VERSION must contain a Semantic Versioning 2.0.0 string");

pub const major: usize = semver.major;
pub const minor: usize = semver.minor;
pub const patch: usize = semver.patch;
/// Prerelease identifiers without the leading `-`; empty for a stable release.
pub const prerelease: []const u8 = semver.pre orelse "";
/// Build metadata without the leading `+`; empty when unused.
pub const build_metadata: []const u8 = semver.build orelse "";

/// A generation (era) of the product, selected by the major number.
pub const Generation = struct {
    /// Major version that opens the generation.
    major: usize,
    /// Official name, including the product name. Never derived from the
    /// number: the table is the only authority.
    name: []const u8,
};

/// Chart of the published versions.
///
/// The official names are normative and are not chosen by the build: they are
/// listed here and mirrored in `docs/roadmap/ERAS.md`. Adding a generation is a
/// deliberate change of this table (and of the document), never an inference.
pub const generations = [_]Generation{
    .{ .major = 0, .name = "Kynox One" },
    .{ .major = 1, .name = "Kynox Quark" },
    .{ .major = 2, .name = "Kynox Photon" },
    .{ .major = 3, .name = "Kynox Atom" },
    .{ .major = 4, .name = "Kynox Molecule" },
    .{ .major = 5, .name = "Kynox Crystal" },
    .{ .major = 6, .name = "Kynox Asteroid" },
    .{ .major = 7, .name = "Kynox Comet" },
    .{ .major = 8, .name = "Kynox Planet" },
    .{ .major = 9, .name = "Kynox Star" },
    .{ .major = 10, .name = "Kynox Pulsar" },
    .{ .major = 11, .name = "Kynox Nebula" },
    .{ .major = 12, .name = "Kynox Galaxy" },
    .{ .major = 13, .name = "Kynox Quasar" },
    .{ .major = 14, .name = "Kynox Cosmos" },
};

/// First major that has an official name (the initial generation).
pub const first_named_major: usize = 0;

/// Last major that has an official name today.
pub const last_named_major: usize = 14;

/// The major number has no official name in the chart.
pub const NameError = error{UnnamedGeneration};

/// Resolves the generation that owns a major number.
///
/// Pure function over `generations`; used at compile time for this build and
/// in tests for every published major. A number outside the chart is an error,
/// never a generated name.
pub fn generationFor(major_number: usize) NameError!Generation {
    for (generations) |candidate| {
        if (candidate.major == major_number) return candidate;
    }
    return error.UnnamedGeneration;
}

/// Resolves the official name of a major number.
pub fn generationNameFor(major_number: usize) NameError![]const u8 {
    return (try generationFor(major_number)).name;
}

/// Resolves the whole generation identity from a version string.
///
/// Parses the version, takes its major and returns the generation. Fails when
/// the string is not SemVer or the major has no name.
pub fn generationOf(version: []const u8) !Generation {
    const parsed = try std.SemanticVersion.parse(version);
    return generationFor(parsed.major);
}

/// Generation of this build.
pub const generation: Generation = generationFor(major) catch
    @compileError("VERSION uses a major number without an official generation name");

/// Official generation name of this build (`Kynox One`).
pub const generation_name: []const u8 = generation.name;

/// Public identity of this build: `Kynox [Generation] [VERSION]`.
pub const display: []const u8 = std.fmt.comptimePrint("{s} {s}", .{ generation_name, string });

/// Builds the public identity of an arbitrary version, e.g. `Kynox Quark 1.0.0`.
///
/// `buffer` receives the text; the returned slice points into it. Used by the
/// tests to prove the resolution works for every major, not only the current
/// one.
pub fn publicNameInto(buffer: []u8, version: []const u8) ![]const u8 {
    const generation_name_for_version = try generationNameFor((try std.SemanticVersion.parse(version)).major);
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ generation_name_for_version, version });
}

/// Release channel implied by the prerelease identifiers.
pub const Channel = enum {
    /// No prerelease identifier: stable release.
    stable,
    /// `alpha.N`: architecture and interfaces may still change.
    alpha,
    /// `beta.N`: planned functionality integrated, interfaces stabilizing.
    beta,
    /// `rc.N`: scope frozen; only blocking fixes.
    release_candidate,
};

/// Channel of this build, derived from `prerelease` at compile time.
pub const channel: Channel = blk: {
    if (prerelease.len == 0) break :blk .stable;
    if (std.mem.startsWith(u8, prerelease, "alpha")) break :blk .alpha;
    if (std.mem.startsWith(u8, prerelease, "beta")) break :blk .beta;
    if (std.mem.startsWith(u8, prerelease, "rc")) break :blk .release_candidate;
    @compileError("prerelease must start with alpha, beta or rc");
};

/// Human readable channel name, for diagnostics.
pub fn channelName() []const u8 {
    return switch (channel) {
        .stable => "stable",
        .alpha => "alpha",
        .beta => "beta",
        .release_candidate => "rc",
    };
}

/// Tag name that a release of this version must use (`v0.1.0-alpha.1`).
pub const tag = "v" ++ string;

/// Line printed by components that announce themselves at start up.
///
/// The component name is a compile time argument so the line costs no
/// formatting at runtime.
pub fn banner(comptime component: []const u8) []const u8 {
    return comptime std.fmt.comptimePrint("{s} ({s})", .{ display, component });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "VERSION is the canonical form of the technical version" {
    // One trailing newline, no padding: the file is meant to be edited by a
    // human and read by a parser, so the canonical form is enforced here.
    try std.testing.expectEqualStrings(string ++ "\n", file_bytes);
    try std.testing.expect(string.len > 0);
}

test "the version string is valid SemVer and matches the parsed components" {
    const parsed = try std.SemanticVersion.parse(string);
    try std.testing.expectEqual(major, parsed.major);
    try std.testing.expectEqual(minor, parsed.minor);
    try std.testing.expectEqual(patch, parsed.patch);
    try std.testing.expectEqualStrings(prerelease, parsed.pre orelse "");
    try std.testing.expectEqualStrings(build_metadata, parsed.build orelse "");
    try std.testing.expectEqual(@as(usize, 0), major);
    try std.testing.expectEqualStrings("0.1.0-alpha.1", string);
    try std.testing.expectEqualStrings("v0.1.0-alpha.1", tag);
    try std.testing.expectEqual(channel, .alpha);
    try std.testing.expectEqualStrings("alpha", channelName());
}

test "major 0 belongs to Kynox One" {
    try std.testing.expectEqualStrings("Kynox One", try generationNameFor(0));
    try std.testing.expectEqualStrings("Kynox One", generation_name);
    try std.testing.expectEqualStrings("Kynox One 0.1.0-alpha.1", display);
    try std.testing.expectEqualStrings("Kynox One 0.1.0-alpha.1 (KNK)", banner("KNK"));
}

test "the official chart maps every major from 0 to 14" {
    try std.testing.expectEqual(last_named_major + 1, generations.len);
    for (generations, 0..) |generation_entry, index| {
        try std.testing.expectEqual(index, generation_entry.major);
        try std.testing.expect(std.mem.startsWith(u8, generation_entry.name, name ++ " "));
        try std.testing.expectEqualStrings(generation_entry.name, try generationNameFor(generation_entry.major));
    }
    // The names are unique: two majors cannot share an era.
    for (generations, 0..) |left, left_index| {
        for (generations[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

test "the published names match the normative chart" {
    const expected = [_][]const u8{
        "Kynox One",     "Kynox Quark",   "Kynox Photon", "Kynox Atom",
        "Kynox Molecule", "Kynox Crystal", "Kynox Asteroid", "Kynox Comet",
        "Kynox Planet",  "Kynox Star",    "Kynox Pulsar", "Kynox Nebula",
        "Kynox Galaxy",  "Kynox Quasar",  "Kynox Cosmos",
    };
    try std.testing.expectEqual(expected.len, generations.len);
    for (expected, generations) |name_text, generation_entry| {
        try std.testing.expectEqualStrings(name_text, generation_entry.name);
    }
}

test "majors without an official name are rejected" {
    try std.testing.expectError(error.UnnamedGeneration, generationFor(last_named_major + 1));
    try std.testing.expectError(error.UnnamedGeneration, generationFor(1000));
    try std.testing.expectError(error.UnnamedGeneration, generationOf("15.0.0"));
    // A negative number cannot even be expressed: the parameter is unsigned.
}

test "the public name is generated from the version that owns it" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Kynox One 0.1.0-alpha.1", try publicNameInto(&buffer, "0.1.0-alpha.1"));
    try std.testing.expectEqualStrings("Kynox One 0.7.0", try publicNameInto(&buffer, "0.7.0"));
    try std.testing.expectEqualStrings("Kynox Quark 1.0.0", try publicNameInto(&buffer, "1.0.0"));
    try std.testing.expectEqualStrings("Kynox Photon 2.0.0", try publicNameInto(&buffer, "2.0.0"));
    try std.testing.expectEqualStrings("Kynox Atom 3.0.0", try publicNameInto(&buffer, "3.0.0"));
    try std.testing.expectEqualStrings("Kynox Planet 8.0.0", try publicNameInto(&buffer, "8.0.0"));
    try std.testing.expectEqualStrings("Kynox Cosmos 14.1.2", try publicNameInto(&buffer, "14.1.2"));
    try std.testing.expectError(error.UnnamedGeneration, publicNameInto(&buffer, "15.0.0"));
    try std.testing.expectError(error.InvalidVersion, publicNameInto(&buffer, "not-a-version"));
}

test "the generation identity of a version follows its major number" {
    try std.testing.expectEqual(@as(usize, 0), (try generationOf("0.1.0-alpha.1")).major);
    try std.testing.expectEqualStrings("Kynox One", (try generationOf("0.1.0-alpha.1")).name);
    try std.testing.expectEqualStrings("Kynox Quark", (try generationOf("1.4.2")).name);
    try std.testing.expectEqualStrings("Kynox Cosmos", (try generationOf("14.0.0-rc.1")).name);
}

test "build.zig.zon declares the same version as VERSION" {
    // The package manifest repeats the version in a different language; the
    // build graph cannot derive one from the other, so a divergence is caught
    // here instead of reaching a release. `@embedFile` is only compiled for
    // tests, therefore the kernel image does not carry the file.
    const manifest = @embedFile("build.zig.zon");
    const expected = std.fmt.comptimePrint(".version = \"{s}\"", .{string});
    try std.testing.expect(std.mem.indexOf(u8, manifest, expected) != null);
}

test "no component hardcodes the version or the generation name" {
    // The point of the single source is that a change to VERSION propagates.
    // A component that spelled the value itself would silently diverge, so the
    // compiled sources are inspected here. Documentation is excluded on
    // purpose: it is allowed to quote the current identity (and a test below
    // checks that it quotes the right one).
    const sources = [_][]const u8{
        @embedFile("boot/uefi/main.zig"),
        @embedFile("kernel/main.zig"),
        @embedFile("sdk/src/root.zig"),
        @embedFile("tools/fatimg.zig"),
        @embedFile("build.zig"),
    };
    for (sources, 0..) |source, index| {
        if (std.mem.indexOf(u8, source, string) != null) {
            std.debug.print("source #{d} spells the version string\n", .{index});
            return error.VersionHardcoded;
        }
        if (std.mem.indexOf(u8, source, generation_name) != null) {
            std.debug.print("source #{d} spells the generation name\n", .{index});
            return error.VersionHardcoded;
        }
        if (std.mem.indexOf(u8, source, tag) != null) {
            std.debug.print("source #{d} spells the tag\n", .{index});
            return error.VersionHardcoded;
        }
    }
}

test "docs/roadmap/ERAS.md documents the chart exactly" {
    const eras = @embedFile("docs/roadmap/ERAS.md");
    for (generations) |generation_entry| {
        var buffer: [64]u8 = undefined;
        const row = try std.fmt.bufPrint(&buffer, "| {d} | {s} |", .{ generation_entry.major, generation_entry.name });
        if (std.mem.indexOf(u8, eras, row) == null) {
            std.debug.print("missing row in ERAS.md: {s}\n", .{row});
            return error.DocumentationOutOfDate;
        }
    }
}

test "docs/VERSIONING.md states the current identity" {
    const versioning = @embedFile("docs/VERSIONING.md");
    try std.testing.expect(std.mem.indexOf(u8, versioning, display) != null);
    try std.testing.expect(std.mem.indexOf(u8, versioning, string) != null);
    try std.testing.expect(std.mem.indexOf(u8, versioning, tag) != null);
}

test "components and formats have independent versions" {
    const shared = @import("kynox_shared");
    const abi = shared.syscall_abi;
    const handoff = shared.handoff;
    // The system version must not be used as an ABI or format version by
    // accident: these values are maintained by their own contracts.
    try std.testing.expect(abi.version >= 1);
    try std.testing.expectEqual(@as(u32, 1), handoff.handoff_version);
    try std.testing.expect(!std.mem.eql(u8, string, abi.string));
}
