const std = @import("std");

const LazyPath = std.Build.LazyPath;

/// Renders the scdoc file `source` into a roff manpage named `basename`
/// using the zzdoc executable.
pub fn addManpage(b: *std.Build, source: LazyPath, basename: []const u8) LazyPath {
    const zzdoc = b.dependencyFromBuildZig(@This(), .{ .optimize = .safe }).artifact("zzdoc");
    const run = b.addRunArtifact(zzdoc);
    run.setStdIn(.{ .lazy_path = source });
    return run.captureStdOut(.{ .basename = basename });
}

pub const ManpageOptions = struct {
    /// Directory containing the scdoc sources.
    root_doc_dir: LazyPath,
    /// Source file names in `root_doc_dir`, such as "foo.1.scd". The man
    /// section is taken from the name.
    files: []const []const u8,
    install_subdir: []const u8 = "share/man",
};

/// Renders each of `options.files` and installs it to
/// `<prefix>/<install_subdir>/man<section>/` as part of the install step.
pub fn installManpages(b: *std.Build, options: ManpageOptions) void {
    for (options.files) |file| {
        if (!std.mem.endsWith(u8, file, ".scd"))
            std.debug.panic("zzdoc: '{s}' does not end in .scd", .{file});
        const name = file[0 .. file.len - ".scd".len];
        const section = std.fs.path.extension(name);
        if (section.len < 2)
            std.debug.panic("zzdoc: '{s}' has no man section, expected a name like foo.1.scd", .{file});

        const page = addManpage(b, options.root_doc_dir.path(b, file), name);
        const dest = b.fmt("{s}/man{s}/{s}", .{ options.install_subdir, section[1..], name });
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(page, .prefix, dest).step);
    }
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
    // `artifact("zzdoc")`, which addManpage relies on.
    b.installArtifact(exe);
    exe_step.dependOn(b.getInstallStep());
}
