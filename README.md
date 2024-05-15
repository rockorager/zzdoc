# zzdoc

`zzdoc` is a 1:1 port of `scdoc`, designed for use in your `build.zig` file. It
will compile `scdoc` syntax into roff manpages. It will do so without requiring
`scdoc` to be installed on the host system. All `scdoc` tests have been ported
as well, ensuring `zzdoc` produces consistent output.

## Usage

`zzdoc` exposes a generic manpage builder which accepts a `std.io.AnyWriter` and
`std.io.AnyReader`. This API allows `zzdoc` to be used with a wide variety of
inputs and outputs.

```zig
const std = @import("std");
const zzdoc = @import("zzdoc");

pub fn main() !void {
    const allocator = std.testing.allocator;
    var src = std.fs.cwd().openFile("zzdoc.5.scd", .{});
    defer src.close();
    var dst = std.fs.cwd().createFile("zzdoc.5", .{});
    defer dst.close();

    try zzdoc.generate(allocator, dst.writer().any(), src.reader().any());
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
