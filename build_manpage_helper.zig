const std = @import("std");

const zzdoc = @import("zzdoc.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const environ = init.environ_map;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const input_path = args[1];
    const input_dir = try std.Io.Dir.cwd().openDir(io, input_path, .{ .iterate = true });
    defer input_dir.close(io);

    const output_path = args[2];
    const output_dir = try std.Io.Dir.cwd().openDir(io, output_path, .{});
    defer output_dir.close(io);

    var dir_iter = input_dir.iterate();
    while (try dir_iter.next(io)) |entry| {
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".scd")) {
            continue;
        }

        var src = try input_dir.openFile(io, entry.name, .{});
        var src_buffer: [1024]u8 = undefined;
        var src_reader = src.reader(io, &src_buffer);
        defer src.close(io);

        // trim '.scd' and extract manpage section
        var dst_name = entry.name[0..(entry.name.len - 4)];
        const ext_index = std.mem.findScalarLast(u8, dst_name, '.') orelse return error.NoExtension;
        const section = dst_name[ext_index + 1 ..];

        const dst_dir_name = try std.fmt.allocPrint(arena, "man{s}", .{section});
        var dst_dir = try output_dir.createDirPathOpen(io, dst_dir_name, .{});
        defer dst_dir.close(io);
        var dst = try dst_dir.createFile(io, dst_name, .{});
        var dst_buffer: [1024]u8 = undefined;
        var dst_writer = dst.writer(io, &dst_buffer);
        defer dst.close(io);

        try zzdoc.generate(io, arena, environ, &dst_writer.interface, &src_reader.interface);
    }
}
