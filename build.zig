const std = @import("std");

const zzdoc = @import("zzdoc.zig");
pub const addManpageStep = zzdoc.addManpageStep;
pub const generate = zzdoc.generate;
pub const ManpageOptions = zzdoc.ManpageOptions;
pub const InstallOptions = zzdoc.InstallOptions;
pub const ManpageStep = zzdoc.ManpageStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdoc_module = b.addModule("zzdoc", .{
        .root_source_file = b.path("zzdoc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = zzdoc_module,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Install zzdoc
    const exe_step = b.step("install-zzdoc", "Install zzdoc as an executable");
    const exe_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zzdoc",
        .root_module = exe_module,
    });
    exe_step.dependOn(&exe.step);
    const install_step = b.addInstallArtifact(exe, .{});
    exe_step.dependOn(&install_step.step);
}
