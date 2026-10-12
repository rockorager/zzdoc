const std = @import("std");
const zzdoc = @import("zzdoc.zig");

/// With no arguments, renders scdoc from stdin to stdout like scdoc.
/// With `<input-dir> <output-dir>`, renders every `*.scd` file in the input
/// directory to `<output-dir>/man<section>/<name>`, replacing anything already
/// in the output directory.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const environ = init.environ_map;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    switch (args.len) {
        1 => {
            var stdin_buffer: [1024]u8 = undefined;
            var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
            var stdout_buffer: [1024]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            try zzdoc.generate(io, init.gpa, environ, &stdout_writer.interface, &stdin_reader.interface);
        },
        3 => try renderDir(io, arena, environ, args[1], args[2]),
        else => {
            std.log.err("usage: zzdoc [<input-dir> <output-dir>]", .{});
            std.process.exit(1);
        },
    }
}

fn renderDir(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, input_path: []const u8, output_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    var input_dir = try cwd.openDir(io, input_path, .{ .iterate = true });
    defer input_dir.close(io);

    // Start from an empty output directory so pages whose source was deleted
    // or renamed don't linger.
    try cwd.deleteTree(io, output_path);
    var output_dir = try cwd.createDirPathOpen(io, output_path, .{});
    defer output_dir.close(io);

    var dir_iter = input_dir.iterate();
    while (try dir_iter.next(io)) |entry| {
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".scd"))
            continue;

        // foo.1.scd -> foo.1 in man1/
        const name = entry.name[0 .. entry.name.len - ".scd".len];
        const section = std.fs.path.extension(name);
        if (section.len < 2) {
            std.log.err("{s}: no man section, expected a name like foo.1.scd", .{entry.name});
            return error.NoManSection;
        }

        var src = try input_dir.openFile(io, entry.name, .{});
        defer src.close(io);
        var src_buffer: [1024]u8 = undefined;
        var src_reader = src.reader(io, &src_buffer);

        var dst_dir = try output_dir.createDirPathOpen(io, try std.fmt.allocPrint(arena, "man{s}", .{section[1..]}), .{});
        defer dst_dir.close(io);
        var dst = try dst_dir.createFile(io, name, .{});
        defer dst.close(io);
        var dst_buffer: [1024]u8 = undefined;
        var dst_writer = dst.writer(io, &dst_buffer);

        try zzdoc.generate(io, arena, environ, &dst_writer.interface, &src_reader.interface);
    }
}
