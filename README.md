# zzdoc

`zzdoc` is a 1:1 port of `scdoc`, designed for use in your `build.zig` file. It
will compile `scdoc` syntax into roff manpages. It will do so without requiring
`scdoc` to be installed on the host system. All `scdoc` tests have been ported
as well, ensuring `zzdoc` produces consistent output.

## Usage

`zzdoc` exposes a generic manpage builder which accepts a `std.Io.Writer` and
`std.Io.Reader`. This API allows `zzdoc` to be used with a wide variety of
inputs and outputs.

```zig
const std = @import("std");
const zzdoc = @import("zzdoc");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var environ = try init.environ_map.clone(allocator);
    defer environ.deinit();

    var src = try std.Io.Dir.cwd().openFile(io, "zzdoc.5.scd", .{});
    var src_buffer: [1024]u8 = undefined;
    var src_reader = src.reader(io, &src_buffer);
    defer src.close(io);
    var dst = try std.Io.Dir.cwd().createFile(io, "zzdoc.5", .{});
    var dst_buffer: [1024]u8 = undefined;
    var dst_writer = dst.writer(io, &dst_buffer);
    defer dst.close(io);

    try zzdoc.generate(io, allocator, environ, &dst_writer.interface, &src_reader.interface);
}
```

`zzdoc` also exposes `build.zig` helpers to make installation of manpages as
smooth as possible.

```zig
const std = @import("std");
const zzdoc = @import("zzdoc");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // All of our *.scd files live in ./docs/
    var man_step = zzdoc.addManpageStep(b, .{
        .root_doc_dir = b.path("docs/"),
    });

    // Add an install step. This helper will install manpages to their
    // appropriate subdirectory under `.prefix/share/man`
    const install_step = man_step.addInstallStep(.{});
    b.default_step.dependOn(&install_step.step);
}
```

## License

`zzdoc` is MIT licensed, the same as `scdoc`. Many thanks to Drew DeVault for
developing `scdoc`.
