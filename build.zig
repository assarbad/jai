const std = @import("std");

const version = "0.3-dev";

const sources = [_][]const u8{
    "complete.cc",
    "cred.cc",
    "default_conf.cc",
    "fs.cc",
    "jai.cc",
    "options.cc",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

    const path_bash = b.option(
        []const u8,
        "path-bash",
        "Path to bash",
    ) orelse "/usr/bin/bash";
    const untrusted_user = b.option(
        []const u8,
        "untrusted-user",
        "Name of the sandboxed untrusted user",
    ) orelse "jai";

    // Generate config.h the same way configure(1) would.  Use the "blank"
    // style so we do not depend on config.h.in, which is only produced by
    // autoheader (via autogen.sh) and is therefore missing from a fresh
    // checkout.
    const config_header = b.addConfigHeader(
        .{
            .style = .blank,
            .include_path = "config.h",
        },
        .{
            .PACKAGE = "jai",
            .PACKAGE_BUGREPORT = "https://github.com/stanford-scs/jai/issues or https://www.scs.stanford.edu/~dm/addr/",
            .PACKAGE_NAME = "jai",
            .PACKAGE_STRING = b.fmt("jai {s}", .{version}),
            .PACKAGE_TARNAME = "jai",
            .PACKAGE_URL = "https://jai.scs.stanford.edu/",
            .PACKAGE_VERSION = version,
            .PATH_BASH = path_bash,
            .UNTRUSTED_USER = untrusted_user,
            .VERSION = version,
        },
    );

    // jai.h does `#include "config.h"`, and a quote-include searches the
    // including file's directory first.  Write the freshly generated header
    // into the source directory (as configure does) so it is what the
    // compiler actually sees, and so `-Duntrusted-user` takes effect even
    // when a stale config.h from a previous configure run is present.
    const write_config = b.addSystemCommand(&.{"cp"});
    write_config.addFileArg(config_header.getOutputFile());
    write_config.addArg(b.pathFromRoot("config.h"));

    const exe = b.addExecutable(.{
        .name = "jai",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    exe.step.dependOn(&write_config.step);
    exe.root_module.addCSourceFiles(.{
        .files = &sources,
        .flags = &.{"-std=gnu++23"},
        .language = .cpp,
    });

    b.installArtifact(exe);

    // sysusers.d config: substitute @SYSUSER_U@ and @UNTRUSTED_USER@ as
    // configure would (SYSUSER_U is "u!" for systemd >= 257, else "u").
    const sysusers_conf = b.addConfigHeader(
        .{
            .style = .{ .autoconf_at = b.path("jai.conf.in") },
            .include_path = "jai.conf",
        },
        .{
            .SYSUSER_U = sysuserU(b),
            .UNTRUSTED_USER = untrusted_user,
        },
    );
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        sysusers_conf.getOutputFile(),
        .prefix,
        "lib/sysusers.d/jai.conf",
    ).step);

    // Bash completion
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("bash-completion/jai"),
        .prefix,
        "share/bash-completion/completions/jai",
    ).step);

    // Man page: render jai.1.md with pandoc when available.
    if (b.findProgram(&.{"pandoc"}, &.{}) catch null) |_| {
        const man = b.addSystemCommand(&.{
            "pandoc",
            "-s",
            "-w",
            "man",
            "-o",
        });
        const out = man.addOutputFileArg("jai.1");
        man.addFileArg(b.path("jai.1.md"));
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            out,
            .prefix,
            "share/man/man1/jai.1",
        ).step);
    }

    const test_step = b.step("test", "Build and run the C++ unit tests");
    const options_test = b.addExecutable(.{
        .name = "options_test",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    options_test.root_module.addCSourceFiles(.{
        .files = &.{ "tests/options_test.cc", "options.cc" },
        .flags = &.{"-std=gnu++23"},
        .language = .cpp,
    });
    test_step.dependOn(&b.addRunArtifact(options_test).step);

    const fs_acl_test = b.addExecutable(.{
        .name = "fs_acl_test",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    fs_acl_test.root_module.addCSourceFiles(.{
        .files = &.{ "tests/fs_acl_test.cc", "fs.cc" },
        .flags = &.{"-std=gnu++23"},
        .language = .cpp,
    });
    test_step.dependOn(&b.addRunArtifact(fs_acl_test).step);

    // Helper binaries used by the shell test scripts (run via make -C tests).
    const probe = b.addExecutable(.{
        .name = "jai_test_probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    probe.root_module.addCSourceFiles(.{
        .files = &.{"tests/jai-test-probe.cc"},
        .flags = &.{"-std=gnu++23"},
        .language = .cpp,
    });
    const pty_driver = b.addExecutable(.{
        .name = "jai_test_pty_driver",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    pty_driver.root_module.addCSourceFiles(.{
        .files = &.{"tests/jai-test-pty-driver.cc"},
        .flags = &.{"-std=gnu++23"},
        .language = .cpp,
    });
    test_step.dependOn(&probe.step);
    test_step.dependOn(&pty_driver.step);
}

/// Replicate configure's systemd version check: use "u!" for systemd >= 257,
/// "u" otherwise (falling back to "u" if systemd-sysusers is missing).
fn sysuserU(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(
        &.{ "systemd-sysusers", "--version" },
        &code,
        .ignore,
    ) catch return "u";
    defer b.allocator.free(out);
    if (code != 0)
        return "u";
    var fields = std.mem.tokenizeAny(u8, out, " \t\r\n");
    _ = fields.next() orelse return "u";
    const major_text = fields.next() orelse return "u";
    var dot = std.mem.tokenizeAny(u8, major_text, ".");
    const major = std.fmt.parseInt(u64, dot.next() orelse return "u", 10) catch return "u";
    return if (major >= 257) "u!" else "u";
}
