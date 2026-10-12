const std = @import("std");

const LazyPath = std.Build.LazyPath;

/// Renders every `*.scd` file in `root_doc_dir` with the zzdoc executable.
/// The returned directory holds each page at `man<section>/<name>`, for
/// example `man1/foo.1` for `foo.1.scd`.
pub fn addManpages(b: *std.Build, root_doc_dir: LazyPath) LazyPath {
    const zzdoc = b.dependencyFromBuildZig(@This(), .{ .optimize = .safe }).artifact("zzdoc");
    const run = b.addRunArtifact(zzdoc);
    // The build system caches directory arguments by path, not contents, so
    // regenerate every build. Rendering takes milliseconds.
    run.has_side_effects = true;
    run.addDirectoryArg2(root_doc_dir, .{});
    return run.addOutputDirectoryArg2("manpages", .{});
}

pub const ManpageOptions = struct {
    /// Directory containing the scdoc sources, named like `foo.1.scd`.
    root_doc_dir: LazyPath,
    install_subdir: []const u8 = "share/man",
};

/// Renders every `*.scd` file in `options.root_doc_dir` and installs the
/// pages to `<prefix>/<install_subdir>/man<section>/` as part of the install
/// step.
pub fn installManpages(b: *std.Build, options: ManpageOptions) void {
    b.installDirectory(.{
        .source_dir = addManpages(b, options.root_doc_dir),
        .install_dir = .prefix,
        .install_subdir = options.install_subdir,
    });
}

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
    // Part of the default install step so dependents can use
    // `artifact("zzdoc")`, which addManpages relies on.
    b.installArtifact(exe);
    exe_step.dependOn(b.getInstallStep());
}
