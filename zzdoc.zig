const std = @import("std");
const assert = std.debug.assert;
const zeit = @import("zeit.zig");

const Parser = struct {
    allocator: std.mem.Allocator,

    source_timestamp: ?i64 = null,

    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,

    line: usize = 1,
    col: usize = 1,

    queue: [32]u8 = undefined,
    qhead: ?usize = null,
    str: ?std.io.AnyReader = null,

    fmt_line: usize = 0,
    fmt_col: usize = 0,

    format: struct {
        bold: bool = false,
        underline: bool = false,
    } = .{},

    indent: usize = 0,

    const Format = enum {
        bold,
        underline,
    };

    const ListType = enum {
        numbered,
        bullet,
    };

    const Cell = struct {
        alignment: enum {
            left,
            center,
            right,
            left_expand,
            center_expand,
            right_expand,
        } = .left,
        contents: []const u8 = "",
        next: ?*Cell = null,
    };

    const Row = struct {
        cell: ?*Cell = null,
        next: ?*Row = null,
    };

    fn init(allocator: std.mem.Allocator, writer: std.io.AnyWriter, reader: std.io.AnyReader) !Parser {
        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
        };
    }

    fn getCh(self: *Parser) ?u8 {
        if (self.qhead) |head| {
            assert(head < self.queue.len);
            const ret = self.queue[head];
            switch (head) {
                0 => self.qhead = null,
                else => self.qhead.? -= 1,
            }
            return ret;
        }

        var b: ?u8 = null;

        if (self.str) |str| {
            b = str.readByte() catch blk: {
                self.str = null;
                break :blk null;
            };
        }

        if (b == null) {
            b = self.reader.readByte() catch return null;
        }

        switch (b.?) {
            '\n' => {
                self.col = 0;
                self.line += 1;
            },
            else => self.col += 1,
        }

        return b;
    }

    fn pushCh(self: *Parser, ch: u8) void {
        if (self.qhead) |head| {
            assert(head + 1 < self.queue.len);
            self.qhead = head + 1;
        } else {
            self.qhead = 0;
        }
        self.queue[self.qhead.?] = ch;
    }

    fn pushStr(self: *Parser, str: []const u8) !void {
        var stream = std.io.fixedBufferStream(str);
        self.str = stream.reader().any();
    }

    fn parsePreamble(self: *Parser) !void {
        var name = std.ArrayList(u8).init(self.allocator);
        defer name.deinit();

        var section: ?[]const u8 = null;

        var extra_1: ?[]const u8 = null;
        var extra_2: ?[]const u8 = null;
        defer {
            if (section) |_| self.allocator.free(section.?);
            if (extra_1) |_| self.allocator.free(extra_1.?);
            if (extra_2) |_| self.allocator.free(extra_2.?);
        }

        const date = if (self.source_timestamp) |ts| blk: {
            const days = zeit.daysSinceEpoch(ts);
            break :blk zeit.civilFromDays(days);
        } else zeit.now();

        while (self.getCh()) |ch| {
            switch (ch) {
                '0'...'9',
                'A'...'Z',
                'a'...'z',
                '_',
                '-',
                '.',
                => try name.append(@as(u8, @intCast(ch))),
                '(' => section = try self.parseSection(),
                '"' => {
                    if (extra_1 == null) {
                        extra_1 = try self.parseExtra();
                        continue;
                    }
                    if (extra_2 == null) {
                        extra_2 = try self.parseExtra();
                        continue;
                    }
                    return error.TooManyPreambleFields;
                },
                '\n' => {
                    if (name.items.len == 0) {
                        return error.ExpectedPreamble;
                    }
                    if (section == null) {
                        return error.ExpectedSection;
                    }
                    try self.writer.print(
                        ".TH \"{s}\" \"{s}\" \"{d:0>4}-{d:0>2}-{d:0>2}\"",
                        .{
                            name.items,
                            section.?,
                            @as(u32, @intCast(date.year)),
                            @intFromEnum(date.month),
                            date.day,
                        },
                    );
                    if (extra_1) |e1| try self.writer.print(" {s}", .{e1});
                    if (extra_2) |e2| try self.writer.print(" {s}", .{e2});
                    try self.writer.writeByte('\n');
                    return;
                },
                else => {},
            }
        }
    }

    /// caller owns the returned memory
    fn parseSection(self: *Parser) ![]const u8 {
        var section = std.ArrayList(u8).init(self.allocator);
        errdefer section.deinit();
        while (self.getCh()) |ch| {
            switch (ch) {
                '0'...'9',
                'A'...'Z',
                'a'...'z',
                => try section.append(@as(u8, @intCast(ch))),
                ')' => {
                    if (section.items.len == 0) return error.ExpectedSection;

                    const end = for (section.items, 0..) |char, i| {
                        switch (char) {
                            '0'...'9' => continue,
                            else => break i,
                        }
                    } else section.items.len;
                    const sec = try std.fmt.parseUnsigned(usize, section.items[0..end], 10);
                    if (sec < 0 or sec > 9) return error.InvalidSection;

                    return try section.toOwnedSlice();
                },
                else => return error.UnexpectedCharacter,
            }
        }
        return error.ExpectedManualSection;
    }

    fn parseExtra(self: *Parser) ![]const u8 {
        var extra = std.ArrayList(u8).init(self.allocator);
        errdefer extra.deinit();
        try extra.append('"');
        while (self.getCh()) |ch| {
            switch (ch) {
                '"' => {
                    try extra.append('"');
                    return try extra.toOwnedSlice();
                },
                '\n' => return error.UnclosedExtraPreambleField,
                else => {
                    try extra.append(ch);
                },
            }
        }
        return error.UnclosedExtraPreambleField;
    }

    fn parseDocument(self: *Parser) !void {
        self.indent = 0;
        while (true) {
            try self.parseIndent(true);
            const ch = self.getCh() orelse break;
            switch (ch) {
                ';' => {
                    if (self.getCh() != ' ') return error.ExpectedSpace;
                    while (self.getCh()) |char| {
                        if (char == '\n') break;
                    }
                },
                '#' => {
                    switch (self.indent) {
                        0 => try self.parseHeading(),
                        else => {
                            self.pushCh(ch);
                            try self.parseText();
                        },
                    }
                },
                '-' => try self.parseList(.bullet),
                '.' => {
                    const char = self.getCh() orelse break;
                    self.pushCh(' ');
                    switch (char) {
                        ' ' => try self.parseList(.numbered),
                        else => try self.parseText(),
                    }
                },
                '`' => try self.parseLiteral(),
                '[',
                '|',
                ']',
                => {
                    if (self.indent != 0) return error.TablesCannotBeIndented;
                    try self.parseTable(ch);
                },
                ' ' => return error.TabsRequiredForIndentation,
                '\n' => {
                    if (self.format.bold or self.format.underline) {
                        return error.ExpectedFormattingAtStartOfParagraph;
                    }
                    try self.roffMacro("PP");
                },
                else => {
                    self.pushCh(ch);
                    try self.parseText();
                },
            }
        }
    }

    fn parseIndent(self: *Parser, write: bool) !void {
        var i: usize = 0;
        while (self.getCh()) |ch| {
            switch (ch) {
                '\t' => i += 1,
                else => {
                    self.pushCh(ch);
                    if (ch == '\n' and self.indent != 0) return;
                    break;
                },
            }
        }
        if (write) {
            if ((i -| self.indent) > 1) return error.IndentTooLarge;
            if (i < self.indent) {
                var j: usize = self.indent;
                while (i < j) : (j -= 1) {
                    try self.roffMacro("RE");
                }
            }
            if (i == self.indent + 1) {
                _ = try self.writer.write(".RS 4\n");
            }
        }
        self.indent = i;
    }

    fn roffMacro(self: *Parser, cmd: []const u8) !void {
        try self.writer.print(".{s}\n", .{cmd});
    }

    fn parseText(self: *Parser) !void {
        var next: u8 = ' ';
        var last: u8 = ' ';
        var ch: u8 = ' ';
        var i: usize = 0;
        while (true) {
            ch = self.getCh() orelse break;
            switch (ch) {
                '\\' => {
                    ch = self.getCh() orelse return error.UnexpectedEOF;
                    switch (ch) {
                        '\\' => _ = try self.writer.write("\\e"),
                        '`' => _ = try self.writer.write("\\`"),
                        else => _ = {
                            try self.writer.writeByte(ch);
                        },
                    }
                },
                '*' => try self.parseFormat(.bold),
                '_' => {
                    next = self.getCh() orelse return self.writer.writeByte('_');
                    if (!isAlnum(last) or (self.format.underline and !isAlnum(next))) {
                        try self.parseFormat(.underline);
                    } else {
                        try self.writer.writeByte('_');
                    }
                    self.pushCh(next);
                },
                '+' => {
                    if (try self.parseLinebreak())
                        last = '\n';
                },
                '\n' => {
                    try self.writer.writeByte('\n');
                    return;
                },
                '.' => {
                    if (i == 0) {
                        _ = try self.writer.write("\\&.\\&");
                    } else {
                        last = ch;
                        try self.writer.writeAll(".\\&");
                    }
                },
                '\'' => {
                    if (i == 0) {
                        _ = try self.writer.write("\\&'\\&");
                    } else {
                        last = ch;
                        try self.writer.writeAll("'\\&");
                    }
                },
                '!' => {
                    last = ch;
                    _ = try self.writer.write("!\\&");
                },
                '?' => {
                    last = ch;
                    _ = try self.writer.write("?\\&");
                },
                else => {
                    last = ch;
                    try self.writer.writeByte(ch);
                },
            }
            i += 1;
        }
    }

    fn parseFormat(self: *Parser, format: Format) !void {
        switch (format) {
            .bold => {
                if (self.format.underline) return error.CannotNestInlineFormatting;
                switch (self.format.bold) {
                    true => _ = try self.writer.write("\\fR"),
                    false => _ = try self.writer.write("\\fB"),
                }
                self.format.bold = !self.format.bold;
            },
            .underline => {
                if (self.format.bold) return error.CannotNestInlineFormatting;
                switch (self.format.underline) {
                    true => _ = try self.writer.write("\\fR"),
                    false => _ = try self.writer.write("\\fI"),
                }
                self.format.underline = !self.format.underline;
            },
        }
    }

    fn parseLinebreak(self: *Parser) !bool {
        const plus = self.getCh() orelse return false;
        if (plus != '+') {
            try self.writer.writeByte('+');
            self.pushCh(plus);
            return false;
        }
        const lf = self.getCh() orelse return false;
        if (lf != '\n') {
            try self.writer.writeByte('+');
            self.pushCh(lf);
            self.pushCh(plus);
            return false;
        }
        const ch = self.getCh() orelse return false;
        if (ch == '\n') {
            return error.ExplicitLineBreakNotAllowed;
        }
        self.pushCh(ch);
        _ = try self.writer.write("\n.br\n");
        return true;
    }

    fn parseHeading(self: *Parser) !void {
        var level: usize = 1;
        while (self.getCh()) |ch| {
            switch (ch) {
                '#' => level += 1,
                ' ' => break,
                else => return error.InvalidHeading,
            }
        }
        switch (level) {
            1 => _ = try self.writer.write(".SH "),
            2 => _ = try self.writer.write(".SS "),
            else => return error.HeadingLevelTooHigh,
        }
        while (self.getCh()) |ch| {
            try self.writer.writeByte(ch);
            if (ch == '\n') break;
        }
    }

    fn parseList(self: *Parser, list_type: ListType) !void {
        if (self.getCh() != ' ') return error.ExpectedSpace;
        _ = try self.writer.write(".PD 0\n");
        var n: usize = 1;
        n = try self.listHeader(list_type, n);
        try self.parseText();
        while (true) {
            try self.parseIndent(true);
            const ch = self.getCh() orelse return;
            switch (ch) {
                ' ' => {
                    if (self.getCh() != ' ') return error.ExpectedTwoSpaces;
                    try self.parseText();
                },
                '.' => {
                    if (self.getCh() != ' ') return error.ExpectedSpace;
                    n = try self.listHeader(list_type, n);
                    try self.parseText();
                },
                else => {
                    try self.roffMacro("PD");
                    self.pushCh(ch);
                    return;
                },
            }
        }
    }

    fn listHeader(self: *Parser, list_type: ListType, n: usize) !usize {
        switch (list_type) {
            .bullet => _ = try self.writer.write(".IP \\(bu 4\n"),
            .numbered => {
                try self.writer.print(".IP {d}. 4\n", .{n});
                return n + 1;
            },
        }
        return 0;
    }

    fn parseLiteral(self: *Parser) !void {
        if (self.getCh() != '`' or self.getCh() != '`' or self.getCh() != '\n')
            return error.InvalidLiteralBeginning;
        try self.roffMacro("nf");
        try self.writer.writeAll(".RS 4\n");
        var ch: u8 = 0;
        var stops: usize = 0;
        var check_indent: bool = true;
        while (true) {
            if (check_indent) {
                const cur = self.indent;
                defer self.indent = cur;
                try self.parseIndent(false);
                if (self.indent < cur)
                    return error.CannotDedentInLiteralblock;
                while (self.indent > cur) {
                    self.indent -= 1;
                    try self.writer.writeByte('\t');
                }
                check_indent = false;
            }
            ch = self.getCh() orelse return;
            switch (ch) {
                '`' => {
                    stops += 1;
                    if (stops == 3) {
                        if (self.getCh() != '\n') return error.InvalidLiteralEnding;
                        try self.roffMacro("fi");
                        try self.roffMacro("RE");
                        return;
                    }
                },
                else => {
                    while (stops != 0) : (stops -= 1)
                        try self.writer.writeByte('`');
                    switch (ch) {
                        '.' => try self.writer.writeAll("\\&."),
                        '\'' => try self.writer.writeAll("\\&'"),
                        '\\' => {
                            ch = self.getCh() orelse return error.UnexpectedEOF;
                            switch (ch) {
                                '\\' => try self.writer.writeAll("\\\\"),
                                else => try self.writer.writeByte(ch),
                            }
                        },
                        '\n' => {
                            check_indent = true;
                            try self.writer.writeByte(ch);
                        },
                        else => try self.writer.writeByte(ch),
                    }
                },
            }
        }
    }

    fn parseTable(self: *Parser, style: u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var table: ?*Row = null;
        var cur_row: ?*Row = null;
        var prev_row: ?*Row = null;
        var cur_cell: ?*Cell = null;
        var column: usize = 0;
        var numcolumns: ?usize = 0;
        self.pushCh('|');
        outer: while (self.getCh()) |ch| {
            switch (ch) {
                '\n' => break :outer,
                '|' => {
                    prev_row = cur_row;
                    cur_row = try allocator.create(Row);
                    cur_row.?.* = .{};
                    if (prev_row) |row| {
                        if (numcolumns) |n| {
                            if (column != n) return error.ExpectedEqualColumns;
                        }
                        numcolumns = column;
                        column = 0;
                        row.next = cur_row;
                    }
                    cur_cell = try allocator.create(Cell);
                    cur_cell.?.* = .{};
                    cur_row.?.cell = cur_cell;
                    if (table == null) table = cur_row;
                },
                ':' => {
                    if (cur_row == null) return error.CannotStartTableWithoutStartingRow;
                    const prev_cell = cur_cell;
                    cur_cell = try allocator.create(Cell);
                    cur_cell.?.* = .{};
                    if (prev_cell) |cell| {
                        cell.next = cur_cell;
                    }
                    column += 1;
                },
                ' ' => {
                    var buffer = std.ArrayList(u8).init(allocator);
                    defer buffer.deinit();
                    const ch_ = self.getCh() orelse return error.UnexpectedEOF;
                    switch (ch_) {
                        ' ' => {
                            // Read out remainder of text
                            while (self.getCh()) |char| {
                                switch (char) {
                                    '\n' => break,
                                    else => try buffer.append(char),
                                }
                            }
                        },
                        '\n' => {},
                        else => return error.ExpectedSpaceOrNewline,
                    }
                    if (std.mem.indexOf(u8, buffer.items, "T{")) |_|
                        return error.IllegalCellContents;
                    if (std.mem.indexOf(u8, buffer.items, "T}")) |_|
                        return error.IllegalCellContents;
                    cur_cell.?.contents = try buffer.toOwnedSlice();
                    continue :outer;
                },
                else => return error.ExpectedPipeOrColon,
            }
            const char = self.getCh() orelse break;
            switch (char) {
                '[' => cur_cell.?.alignment = .left,
                '-' => cur_cell.?.alignment = .center,
                ']' => cur_cell.?.alignment = .right,
                '<' => cur_cell.?.alignment = .left_expand,
                '=' => cur_cell.?.alignment = .center_expand,
                '>' => cur_cell.?.alignment = .right_expand,
                ' ' => {
                    if (prev_row) |row| {
                        var pcell = row.cell;
                        var i: usize = 0;
                        while (i < column and pcell != null) {
                            defer {
                                i += 1;
                                pcell = pcell.?.next;
                            }
                            if (i == column) {
                                cur_cell.?.alignment = pcell.?.alignment;
                            }
                        }
                    } else {
                        return error.NoPreviousRowToInferAlignment;
                    }
                },
                else => {
                    return error.UnexpectedCharacter;
                },
            }
            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();
            const ch_ = self.getCh() orelse return error.UnexpectedEOF;
            switch (ch_) {
                ' ' => {
                    // Read out remainder of text
                    while (self.getCh()) |char_| {
                        switch (char_) {
                            '\n' => break,
                            else => try buffer.append(char_),
                        }
                    }
                },
                '\n' => continue,
                else => return error.ExpectedSpaceOrNewline,
            }
            if (std.mem.indexOf(u8, buffer.items, "T{")) |_|
                return error.IllegalCellContents;
            if (std.mem.indexOf(u8, buffer.items, "T}")) |_|
                return error.IllegalCellContents;
            cur_cell.?.contents = try buffer.toOwnedSlice();
        }
        // commit table
        try self.roffMacro("TS");
        switch (style) {
            '[' => try self.writer.writeAll("allbox;"),
            ']' => try self.writer.writeAll("box;"),
            else => {},
        }
        cur_row = table;
        while (cur_row) |row| {
            cur_cell = row.cell;
            while (cur_cell) |cell| {
                switch (cell.alignment) {
                    .left => try self.writer.writeAll("l"),
                    .center => try self.writer.writeAll("c"),
                    .right => try self.writer.writeAll("r"),
                    .left_expand => try self.writer.writeAll("lx"),
                    .center_expand => try self.writer.writeAll("cx"),
                    .right_expand => try self.writer.writeAll("rx"),
                }
                if (cell.next) |_| try self.writer.writeByte(' ');
                cur_cell = cell.next;
            }
            if (row.next == null) try self.writer.writeByte('.');
            try self.writer.writeByte('\n');
            cur_row = row.next;
        }

        // print contents
        cur_row = table;
        while (cur_row) |row| {
            cur_cell = row.cell;
            try self.writer.writeAll("T{\n");
            while (cur_cell) |cell| {
                try self.pushStr(cell.contents);
                try self.parseText();
                if (cell.next) |_|
                    try self.writer.writeAll("\nT}\tT{\n")
                else
                    try self.writer.writeAll("\nT}");
                cur_cell = cell.next;
            }
            try self.writer.writeByte('\n');
            cur_row = row.next;
        }
        try self.roffMacro("TE");
        try self.writer.writeAll(".sp 1\n");
    }
};

pub fn generate(allocator: std.mem.Allocator, writer: std.io.AnyWriter, reader: std.io.AnyReader) !void {
    var parser = try Parser.init(allocator, writer, reader);
    try parser.parsePreamble();
    try parser.parseDocument();
}

fn isAlnum(c: u8) bool {
    switch (c) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        => return true,
        else => return false,
    }
}

fn testParserFromSlice(input: []const u8) !Parser {
    var stream = std.io.fixedBufferStream(input);
    return Parser.init(std.testing.allocator, std.io.null_writer.any(), stream.reader().any());
}

test "preamble: expects a name" {
    var stream = std.io.fixedBufferStream("(8)\n");
    var parser = try Parser.init(std.testing.allocator, std.io.null_writer.any(), stream.reader().any());
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: expects a section" {
    var stream = std.io.fixedBufferStream("test\n");
    var parser = try Parser.init(std.testing.allocator, std.io.null_writer.any(), stream.reader().any());
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: expects a section within the parentheses" {
    var stream = std.io.fixedBufferStream("test()\n");
    var parser = try Parser.init(std.testing.allocator, std.io.null_writer.any(), stream.reader().any());
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: expects name to alphanumeric" {
    var stream = std.io.fixedBufferStream("!!!!(8)\n");
    var parser = try Parser.init(std.testing.allocator, std.io.null_writer.any(), stream.reader().any());
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: expects section to start with a number" {
    var stream = std.io.fixedBufferStream("test(hello)\n");
    var parser = try Parser.init(std.testing.allocator, std.io.null_writer.any(), stream.reader().any());
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: expects section to be legit" {
    var parser = try testParserFromSlice("test(100)\n");
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: expects section to be legit with subsection" {
    var parser = try testParserFromSlice("test(100hello)\n");
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: expects section not to contain a space" {
    var parser = try testParserFromSlice("test(8 hello)\n");
    parser.parsePreamble() catch return;
    try std.testing.expect(false);
}

test "preamble: accepts a valid preamble" {
    var parser = try testParserFromSlice("test(8)\n");
    try parser.parsePreamble();
}

test "preamble: accepts a valid preamble with subsection" {
    var parser = try testParserFromSlice("test(8hello)\n");
    try parser.parsePreamble();
}

test "preamble: writes the appropriate header" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    var stream = std.io.fixedBufferStream("test(8)\n");
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    const expected =
        \\.TH "test" "8" "1970-01-01"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "preamble: preserves dashes" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    var stream = std.io.fixedBufferStream("test-manual(8)\n");
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    const expected =
        \\.TH "test-manual" "8" "1970-01-01"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "preamble: handles extra footer field" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\test-manual(8) "Footer"
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    const expected =
        \\.TH "test-manual" "8" "1970-01-01" "Footer"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "preamble: handles both extra footer fields" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\test-manual(8) "Footer" "Header"
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    const expected =
        \\.TH "test-manual" "8" "1970-01-01" "Footer" "Header"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "preamble: emits empty footer correctly" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\test-manual(8) "" "Header"
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    const expected =
        \\.TH "test-manual" "8" "1970-01-01" "" "Header"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "indent: indents indented text" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "Not indented\n\tIndented one level\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected =
        \\Not indented
        \\.RS 4
        \\Indented one level
        \\.RE
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "indent: deindents following indented text" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "Not indented\n\tIndented one level\nNot indented\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected =
        \\Not indented
        \\.RS 4
        \\Indented one level
        \\.RE
        \\Not indented
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "indent: disallows multi-step indents" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "Not indented\n\tIndented one level\n\t\t\tIndented three levels\nNot indented\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    parser.parseDocument() catch return;
    try std.testing.expect(false);
}

test "indent: allows indentation changes > 1 in literal blocks" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "This is some code:\n\n```\nfoobar:\n\n\t\t# asdf\n```\n";

    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "This is some code:\n.PP\n.nf\n.RS 4\nfoobar:\n\n\t\t# asdf\n.fi\n.RE\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "indent: allows multi-sept dedents" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "Not indented\n\tIndented one level\n\t\tIndented two levels\nNot indented\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected =
        \\Not indented
        \\.RS 4
        \\Indented one level
        \\.RS 4
        \\Indented two levels
        \\.RE
        \\.RE
        \\Not indented
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "indent: allows indented literal blocks" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "\t```\n\tIndented\n\t```\nNot indented\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = ".RS 4\n.nf\n.RS 4\nIndented\n.fi\n.RE\n.RE\nNot indented\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "indent: disallows dedenting in literal blocks" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "\t\t```\n\t\tIndented\n\tDedented\n\t\t```\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    parser.parseDocument() catch return;
    try std.testing.expect(false);
}

test "comments: ignore comments" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\test(8)
        \\
        \\; comment
        \\
        \\Hello world!
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    try parser.parseDocument();
    const expected =
        \\.TH "test" "8" "1970-01-01"
        \\.PP
        \\.PP
        \\Hello world!\&
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "Fail on invalid comments" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\test(8)
        \\
        \\;comment
        \\
        \\Hello world!
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    parser.parseDocument() catch return;
    try std.testing.expect(false);
}

test "heading: fail on ###" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\test(8)
        \\
        \\### invalid heading
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    parser.parseDocument() catch return;
    try std.testing.expect(false);
}

test "heading: expects a space after #" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\test(8)
        \\
        \\#invalid heading
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parsePreamble();
    parser.parseDocument() catch return;
    try std.testing.expect(false);
}

test "heading: emits a new sections" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\# HEADER
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    try parser.parseDocument();
    const expected =
        \\.SH HEADER
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "heading: emits a new subsection" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\## HEADER
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    try parser.parseDocument();
    const expected =
        \\.SS HEADER
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "formatting: disallows nested formatting" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "_hello *world*_";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    parser.parseDocument() catch return;
    try std.testing.expect(false);
}

test "formatting: ignores underscores in words" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hello_world";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected =
        \\hello_world
    ;
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "formatting: ignores underscores in underlined words" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "_hello_world_\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "\\fIhello_world\\fR\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "formatting: ignores underscores in bold words" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "*hello_world*\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "\\fBhello_world\\fR\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "formatting: emits bold text" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hello \\_world\\_\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "hello _world_\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "line-breaks: handles line break" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hello++\nworld\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "hello\n.br\nworld\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "line-breaks: disallows empty line after line break" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hello++\n\nworld\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    parser.parseDocument() catch return;
    try std.testing.expect(false);
}

test "line-breaks: leave single +" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hello+world\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "hello+world\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "line-breaks: leave double + without newline" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hello++world\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "hello++world\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "line-breaks: handles underlined text following line break" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hello++\n_world_\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "hello\n.br\n\\fIworld\\fR\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "line-breaks: suppresses sentence spacing" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input = "hel!lo.\nworld.\n";
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = "hel!\\&lo.\\&\nworld.\\&\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "tables: handles cells" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\[[ *Foo*
        \\:- bar
        \\:- baz
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = ".TS\nallbox;l c c.\nT{\n\\fBFoo\\fR\nT}\tT{\nbar\nT}\tT{\nbaz\nT}\n.TE\n.sp 1\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}

test "tables: handles empty table cells" {
    const allocator = std.testing.allocator;
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();
    const input =
        \\[[ *Foo*
        \\:- 
        \\:-
        \\
    ;
    var stream = std.io.fixedBufferStream(input);
    var parser = try Parser.init(std.testing.allocator, writer.writer().any(), stream.reader().any());
    parser.source_timestamp = 0;
    try parser.parseDocument();
    const expected = ".TS\nallbox;l c c.\nT{\n\\fBFoo\\fR\nT}\tT{\n\nT}\tT{\n\nT}\n.TE\n.sp 1\n";
    try std.testing.expectEqualStrings(expected, writer.items);
}