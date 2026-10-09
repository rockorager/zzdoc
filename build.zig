const std = @import("std");

const LazyPath = std.Build.LazyPath;
const Step = std.Build.Step;

pub const ManpageOptions = struct {
    root_doc_dir: LazyPath,
};

pub const InstallOptions = struct {
    install_subdir: []const u8 = "share/man",
};

pub const ManpageHelper = struct {
    helper_exe: *Step.Compile,
    output_dir: ?LazyPath = null,

    const Self = @This();

    pub fn init(b: *std.Build, zzdoc_dep: *std.Build.Dependency) Self {
        const h = b.addExecutable(.{
            .name = "zzdoc_man_helper",
            .root_module = b.createModule(.{
                .root_source_file = zzdoc_dep.path("build_manpage_helper.zig"),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
        return .{ .helper_exe = h };
    }

    pub fn addManpageStep(self: *Self, b: *std.Build, options: ManpageOptions) *Step.Run {
        const result = b.addRunArtifact(self.helper_exe);
        result.addDirectoryArg2(options.root_doc_dir, .{});
        self.output_dir = result.addOutputDirectoryArg2("manpages", .{});
        return result;
    }

    pub fn addInstallStep(self: *const Self, b: *std.Build, options: InstallOptions) *Step.InstallDir {
        const source_dir = self.output_dir orelse {
            std.log.err("missing output dir when calling addInstallStep, don't forget to call addManpageStep first", .{});
            std.process.exit(1);
        };
        return b.addInstallDirectory(.{
            .source_dir = source_dir,
            .install_dir = .prefix,
            .install_subdir = options.install_subdir,
        });
    }
};

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
