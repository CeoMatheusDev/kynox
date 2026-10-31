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

//! Single source of truth for the **Kynox system version**.
//!
//! Every component that reports or embeds the system version imports this
//! module (`kynox_version` in the build graph): the UEFI loader, the kernel,
//! the SDK and host tools. Do not spell the version anywhere else.
//!
//! Three different versions exist in the project and must not be confused:
//!
//!   * **System version** (this file): the product release, SemVer 2.0.0,
//!     released with a `v`-prefixed Git tag (`v0.1.0-alpha.1`).
//!   * **Native ABI revision** (`shared/syscall_abi.zig`): the contract
//!     between user mode and the kernel; it changes independently.
//!   * **Binary format versions** (boot handoff, KEX, KPK, KNV): each format
//!     carries its own version field in its header.
//!
//! See `docs/specs/versioning.md` for the policy and the release process.

const std = @import("std");

/// Product name, used in banners.
pub const name = "Kynox";

/// Major version: incompatible changes to the product contract.
pub const major: u16 = 0;
/// Minor version: functionality added in a compatible way.
pub const minor: u16 = 1;
/// Patch version: compatible fixes.
pub const patch: u16 = 0;
/// Prerelease identifiers, without the leading `-`. Empty for a stable release.
pub const prerelease: []const u8 = "alpha.1";
/// Build metadata, without the leading `+`. Empty when not used.
pub const build_metadata: []const u8 = "";

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

/// Full version string, e.g. `0.1.0-alpha.1`.
///
/// Built from the components above so the parts and the string cannot
/// disagree.
pub const string = if (prerelease.len == 0 and build_metadata.len == 0)
    std.fmt.comptimePrint("{d}.{d}.{d}", .{ major, minor, patch })
else if (build_metadata.len == 0)
    std.fmt.comptimePrint("{d}.{d}.{d}-{s}", .{ major, minor, patch, prerelease })
else if (prerelease.len == 0)
    std.fmt.comptimePrint("{d}.{d}.{d}+{s}", .{ major, minor, patch, build_metadata })
else
    std.fmt.comptimePrint("{d}.{d}.{d}-{s}+{s}", .{ major, minor, patch, prerelease, build_metadata });

/// Parsed form of `string`; the compilation fails if it is not valid SemVer.
pub const semver = std.SemanticVersion.parse(string) catch
    @compileError("version.zig produces an invalid SemVer string");

/// Tag name that a release of this version must use (`v0.1.0-alpha.1`).
pub const tag = "v" ++ string;

/// Human readable channel name, for diagnostics.
pub fn channelName() []const u8 {
    return switch (channel) {
        .stable => "stable",
        .alpha => "alpha",
        .beta => "beta",
        .release_candidate => "rc",
    };
}

/// Line printed by components that announce themselves at start up.
///
/// The component name is a compile time argument so the line costs no
/// formatting at runtime.
pub fn banner(comptime component: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s} {s} ({s})", .{ name, string, component });
}

test "the version string is valid SemVer and matches the components" {
    const parsed = try std.SemanticVersion.parse(string);
    try std.testing.expectEqual(major, parsed.major);
    try std.testing.expectEqual(minor, parsed.minor);
    try std.testing.expectEqual(patch, parsed.patch);
    try std.testing.expectEqualStrings(prerelease, parsed.pre.?);
    try std.testing.expectEqual(channel, .alpha);
    try std.testing.expectEqualStrings("0.1.0-alpha.1", string);
    try std.testing.expectEqualStrings("v0.1.0-alpha.1", tag);
}

test "the tag is the version with the v prefix" {
    try std.testing.expectEqual(string.len + 1, tag.len);
    try std.testing.expectEqual(@as(u8, 'v'), tag[0]);
    try std.testing.expectEqualStrings(string, tag[1..]);
}

test "build.zig.zon declares the same version as this module" {
    // The package manifest repeats the version in a different language; the
    // build graph cannot derive one from the other, so a divergence is caught
    // here instead of reaching a release. `@embedFile` is only compiled for
    // tests, therefore the kernel image does not carry the file.
    const manifest = @embedFile("build.zig.zon");
    const expected = std.fmt.comptimePrint(".version = \"{s}\"", .{string});
    try std.testing.expect(std.mem.indexOf(u8, manifest, expected) != null);
}

test "the channel is derived from the prerelease identifiers" {
    try std.testing.expectEqualStrings("alpha", channelName());
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
