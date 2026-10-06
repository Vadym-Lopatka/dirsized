//! TOML-subset parser, Config and root validation.
//!
//! Only `roots` and `exclude` (arrays of strings) are accepted. Everything else is rejected
//! with a line number, because people and scripts edit this file by hand.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ignore = @import("ignore.zig");

/// `message` always points into a per-thread buffer: no allocation, nothing to free, and it
/// stays readable after `parse` or `resolveRoots` fail. It is overwritten by the next call
/// on the same thread, and truncated if it ever exceeds the buffer. `line` is 1-based; 0
/// means "no line" (for example a default value).
pub const Diag = struct { line: u32 = 0, message: []const u8 = "" };

threadlocal var msg_buf: [2048]u8 = undefined;

fn fail(diag: *Diag, line: u32, comptime fmt: []const u8, args: anytype) error{BadConfig} {
    var w = std.Io.Writer.fixed(&msg_buf);
    w.print(fmt, args) catch {}; // too long: the truncated text is still useful
    diag.* = .{ .line = line, .message = w.buffered() };
    return error.BadConfig;
}

/// Prints bytes as a quoted string with escapes, so odd names stay readable in messages.
fn q(bytes: []const u8) std.fmt.Alt([]const u8, quoted) {
    return .{ .data = bytes };
}
fn quoted(bytes: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("\"{f}\"", .{std.zig.fmtString(bytes)});
}

const default_roots = [_][]const u8{"~"};

pub const Config = struct {
    roots: []const []const u8, // as written, `~` not yet expanded
    exclude: []const []const u8,
    /// Line of each element, for messages from `resolveRoots`. Empty for defaults.
    roots_lines: []const u32 = &.{},
    exclude_lines: []const u32 = &.{},
    arena: ?std.heap.ArenaAllocator = null,

    /// Empty text, or a missing key, gives the defaults `roots = ["~"]`, `exclude = []`.
    pub fn parse(gpa: Allocator, text: []const u8, diag: *Diag) !Config {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var p: Parser = .{ .a = arena.allocator(), .src = text, .diag = diag };
        try p.run();
        var cfg: Config = .{ .roots = &default_roots, .exclude = &.{} };
        if (p.roots) |r| {
            cfg.roots = r.items.items;
            cfg.roots_lines = r.lines.items;
        }
        if (p.exclude) |e| {
            cfg.exclude = e.items.items;
            cfg.exclude_lines = e.lines.items;
        }
        // The lists live in the arena; moving the arena struct keeps its memory valid.
        cfg.arena = arena;
        return cfg;
    }

    pub fn deinit(self: *Config) void {
        if (self.arena) |*a| a.deinit();
        self.* = undefined;
    }
};

const Parsed = struct {
    key_line: u32,
    items: std.ArrayList([]const u8) = .empty,
    lines: std.ArrayList(u32) = .empty,
};

const Parser = struct {
    a: Allocator,
    src: []const u8,
    diag: *Diag,
    pos: usize = 0,
    line: u32 = 1,
    roots: ?Parsed = null,
    exclude: ?Parsed = null,

    fn run(p: *Parser) !void {
        try p.checkUtf8();
        if (std.mem.startsWith(u8, p.src, "\xEF\xBB\xBF")) p.pos = 3;
        while (true) {
            try p.skipBlank();
            if (p.pos >= p.src.len) break;
            try p.keyValue();
        }
        if (p.roots) |r| if (r.items.items.len == 0)
            return fail(p.diag, r.key_line, "roots is empty: the daemon needs at least one folder, for example roots = [\"~\"]", .{});
    }

    fn checkUtf8(p: *Parser) !void {
        var i: usize = 0;
        var line: u32 = 1;
        while (i < p.src.len) {
            const n = std.unicode.utf8ByteSequenceLength(p.src[i]) catch 0;
            const ok = n != 0 and i + n <= p.src.len and
                if (std.unicode.utf8Decode(p.src[i..][0..n])) |_| true else |_| false;
            if (!ok) return fail(p.diag, line, "the file is not valid UTF-8 (bad byte 0x{x:0>2}); save it as UTF-8", .{p.src[i]});
            if (p.src[i] == '\n') line += 1;
            i += n;
        }
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    /// Spaces and tabs only.
    fn skipWs(p: *Parser) void {
        while (p.peek()) |c| : (p.pos += 1) if (c != ' ' and c != '\t') break;
    }

    fn atNewline(p: *const Parser) bool {
        return p.peek() == '\n' or std.mem.startsWith(u8, p.src[p.pos..], "\r\n");
    }

    fn eatNewline(p: *Parser) void {
        p.pos += if (p.peek() == '\r') 2 else 1;
        p.line += 1;
    }

    /// Skips an optional comment. Stops before the newline.
    fn skipComment(p: *Parser) !void {
        if (p.peek() != '#') return;
        while (p.peek()) |c| : (p.pos += 1) {
            if (p.atNewline()) return;
            if ((c < 0x20 and c != '\t') or c == 0x7f)
                return fail(p.diag, p.line, "control character 0x{x:0>2} in a comment is not allowed", .{c});
        }
    }

    /// Whitespace, comments and newlines.
    fn skipBlank(p: *Parser) !void {
        while (true) {
            p.skipWs();
            try p.skipComment();
            if (p.atNewline()) p.eatNewline() else return;
        }
    }

    fn keyValue(p: *Parser) !void {
        const line = p.line;
        const key = try p.parseKey();
        const slot: *?Parsed = if (std.mem.eql(u8, key, "roots")) &p.roots else if (std.mem.eql(u8, key, "exclude")) &p.exclude else return fail(p.diag, line, "unknown key {f}: only \"roots\" and \"exclude\" are allowed", .{q(key)});
        if (slot.*) |first| return fail(p.diag, line, "duplicate key {f} (first set on line {d})", .{ q(key), first.key_line });
        p.skipWs();
        if (p.peek() != '=') return fail(p.diag, line, "expected \"=\" after key {f}", .{q(key)});
        p.pos += 1;
        p.skipWs();
        if (p.peek() != '[') return fail(p.diag, p.line, "{f} must be an array of strings, for example {s} = [\"...\"]", .{ q(key), key });
        slot.* = .{ .key_line = line };
        try p.array(&slot.*.?);
        p.skipWs();
        try p.skipComment();
        if (p.pos < p.src.len and !p.atNewline())
            return fail(p.diag, p.line, "unexpected text after the array; put each key on its own line", .{});
    }

    fn parseKey(p: *Parser) ![]const u8 {
        const c = p.peek().?;
        if (c == '"' or c == '\'') {
            const k = try p.string();
            p.skipWs();
            return k;
        }
        const start = p.pos;
        while (p.peek()) |b| : (p.pos += 1) {
            if (!std.ascii.isAlphanumeric(b) and b != '_' and b != '-') break;
        }
        if (p.pos == start) {
            if (c == '[') return fail(p.diag, p.line, "tables ([section]) are not supported: write \"roots\" and \"exclude\" at the top level of the file", .{});
            return fail(p.diag, p.line, "unexpected character {f} where a key (roots or exclude) was expected", .{q(p.src[p.pos..][0..1])});
        }
        const k = p.src[start..p.pos];
        p.skipWs();
        if (p.peek() == '.') return fail(p.diag, p.line, "dotted keys are not supported: unknown key {f}", .{q(k)});
        return k;
    }

    fn array(p: *Parser, out: *Parsed) !void {
        const open_line = p.line;
        p.pos += 1; // '['
        while (true) {
            try p.skipBlank();
            const c = p.peek() orelse return fail(p.diag, open_line, "the array that starts here is not closed: missing \"]\"", .{});
            if (c == ']') {
                p.pos += 1;
                return;
            }
            if (c != '"' and c != '\'')
                return fail(p.diag, p.line, "array elements must be strings in quotes, found {f}", .{q(p.src[p.pos..][0..1])});
            const line = p.line;
            try out.items.append(p.a, try p.string());
            try out.lines.append(p.a, line);
            try p.skipBlank();
            switch (p.peek() orelse return fail(p.diag, open_line, "the array that starts here is not closed: missing \"]\"", .{})) {
                ',' => p.pos += 1,
                ']' => {},
                else => return fail(p.diag, p.line, "expected \",\" or \"]\" after a string, found {f}", .{q(p.src[p.pos..][0..1])}),
            }
        }
    }

    /// A one-line basic or literal string, starting at its opening quote.
    fn string(p: *Parser) ![]const u8 {
        const quote = p.src[p.pos];
        if (std.mem.startsWith(u8, p.src[p.pos..], &.{ quote, quote, quote }))
            return fail(p.diag, p.line, "multi-line strings are not supported: use one \"...\" or '...' string per element", .{});
        p.pos += 1;
        const start = p.pos;
        // Find the end first: a decoded string is never longer than its source, so one
        // allocation of that size is enough.
        while (true) : (p.pos += 1) {
            const c = p.peek() orelse return fail(p.diag, p.line, "unterminated string: missing closing {c}", .{quote});
            if (c == quote) break;
            if (p.atNewline() or c == '\r') return fail(p.diag, p.line, "unterminated string: missing closing {c} before the end of the line", .{quote});
            // Skip the escaped byte, unless it is a line end: the string is then unterminated.
            if (c == '\\' and quote == '"' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != '\n') p.pos += 1;
        }
        const raw = p.src[start..p.pos];
        p.pos += 1;
        const buf = try p.a.alloc(u8, raw.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if ((c < 0x20 and c != '\t') or c == 0x7f)
                return fail(p.diag, p.line, "control character 0x{x:0>2} in a string: use an escape such as \\u{x:0>4}", .{ c, c });
            if (c != '\\' or quote == '\'') {
                buf[n] = c;
                n += 1;
                i += 1;
                continue;
            }
            const e = raw[i + 1]; // a lone trailing backslash was rejected above as unterminated
            i += 2;
            const simple: ?u8 = switch (e) {
                'b' => 0x08,
                't' => '\t',
                'n' => '\n',
                'f' => 0x0c,
                'r' => '\r',
                'e' => 0x1b,
                '"' => '"',
                '\\' => '\\',
                else => null,
            };
            if (simple) |s| {
                buf[n] = s;
                n += 1;
                continue;
            }
            const digits: usize = switch (e) {
                'x' => 2,
                'u' => 4,
                'U' => 8,
                else => return fail(p.diag, p.line, "invalid escape \\{f} in a string; to write a backslash use \\\\ or a '...' string", .{std.zig.fmtString(&.{e})}),
            };
            const cp = if (i + digits <= raw.len) std.fmt.parseInt(u32, raw[i..][0..digits], 16) catch null else null;
            i += digits;
            const len = if (cp) |v| (if (v <= 0x10FFFF) std.unicode.utf8Encode(@intCast(v), buf[n..]) catch null else null) else null;
            n += len orelse return fail(p.diag, p.line, "invalid \\{c} escape: needs {d} hex digits that form a valid Unicode character", .{ e, digits });
        }
        return buf[0..n];
    }
};

/// <home>/.config/dirsized/config.toml
pub fn defaultPath(gpa: Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home, ".config", "dirsized", "config.toml" });
}

/// The exclude rules of `cfg`; the one place where they are compiled. error.BadConfig + diag.
pub fn compileRules(gpa: Allocator, cfg: *const Config, diag: *Diag) !ignore.Rules {
    var bad: ?u32 = null;
    return ignore.Rules.compile(gpa, cfg.exclude, &bad) catch |err| switch (err) {
        error.BadPattern => {
            const i = bad.?;
            const line: u32 = if (i < cfg.exclude_lines.len) cfg.exclude_lines[i] else 0;
            return fail(diag, line, "exclude pattern {f} is not valid: a pattern must not be empty, must have a name after \"!\" or \"/\", and must not end with a backslash", .{q(cfg.exclude[i])});
        },
        else => |e| return e,
    };
}

/// Expands `~`, resolves to real absolute paths, drops the trailing slash, rejects nested or
/// duplicate roots and (macOS) the root "/". error.BadConfig + diag. The result and each string
/// in it are owned by `gpa`.
pub fn resolveRoots(gpa: Allocator, cfg: *const Config, home: []const u8, diag: *Diag) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (cfg.roots, 0..) |root, i| {
        const line: u32 = if (i < cfg.roots_lines.len) cfg.roots_lines[i] else 0;
        const real = try resolveOne(gpa, root, home, line, diag);
        errdefer gpa.free(real);
        for (out.items, 0..) |prev, j| {
            const a = cfg.roots[j];
            if (std.mem.eql(u8, prev, real))
                return fail(diag, line, "roots {f} and {f} are the same folder ({f}); remove one", .{ q(a), q(root), q(real) });
            if (isInside(real, prev))
                return fail(diag, line, "root {f} ({f}) is inside root {f} ({f}); keep only the outer one", .{ q(root), q(real), q(a), q(prev) });
            if (isInside(prev, real))
                return fail(diag, line, "root {f} ({f}) is inside root {f} ({f}); keep only the outer one", .{ q(a), q(prev), q(root), q(real) });
        }
        try out.append(gpa, real);
    }
    return out.toOwnedSlice(gpa);
}

/// `child` is strictly below `parent`; both are real absolute paths without trailing slash.
pub fn isInside(child: []const u8, parent: []const u8) bool {
    if (parent.len == 0 or child.len <= parent.len or !std.mem.startsWith(u8, child, parent)) return false;
    return parent.len == 1 or child[parent.len] == '/'; // parent "/" is the only one ending in "/"
}

fn resolveOne(gpa: Allocator, root: []const u8, home: []const u8, line: u32, diag: *Diag) ![]u8 {
    if (root.len == 0) return fail(diag, line, "a root is an empty string; use an absolute path or \"~\"", .{});
    if (std.mem.indexOfScalar(u8, root, 0) != null) return fail(diag, line, "root {f} contains a NUL byte", .{q(root)});
    const expanded = if (root[0] != '~')
        try gpa.dupeZ(u8, root)
    else if (root.len == 1 or root[1] == '/') blk: {
        if (home.len == 0) return fail(diag, line, "root {f} needs the home folder, but it is not known (HOME is not set)", .{q(root)});
        break :blk try std.mem.concatWithSentinel(gpa, u8, &.{ home, root[1..] }, 0);
    } else return fail(diag, line, "root {f}: \"~user\" is not supported; use \"~\" or an absolute path", .{q(root)});
    defer gpa.free(expanded);
    if (expanded[0] != '/')
        return fail(diag, line, "root {f} is not an absolute path; start it with \"/\" or \"~/\"", .{q(root)});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.c.realpath(expanded, &buf) orelse {
        const e = std.c.errno(@as(c_int, -1));
        if (e == .NOENT) return fail(diag, line, "root {f} does not exist (looked for {f})", .{ q(root), q(expanded) });
        return fail(diag, line, "root {f} cannot be resolved: {t}", .{ q(root), e });
    };
    const path = std.mem.span(real);
    // realpath accepts files too; a scan of a file would only fail later.
    const fd = std.c.open(real, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd >= 0) _ = std.c.close(fd) else if (std.c.errno(fd) == .NOTDIR)
        return fail(diag, line, "root {f} is not a folder ({f})", .{ q(root), q(path) });
    if (builtin.os.tag == .macos and std.mem.eql(u8, path, "/"))
        return fail(diag, line, "root {f} is the whole disk, which is not allowed on macOS (system volumes are counted twice); use \"~\" or a folder below it", .{q(root)});
    return gpa.dupe(u8, path);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectParse(text: []const u8, roots: []const []const u8, exclude: []const []const u8) !void {
    var diag: Diag = .{};
    var cfg = Config.parse(testing.allocator, text, &diag) catch |e| {
        std.debug.print("unexpected {t} line {d}: {s}\ninput: {f}\n", .{ e, diag.line, diag.message, q(text) });
        return e;
    };
    defer cfg.deinit();
    try testing.expectEqual(roots.len, cfg.roots.len);
    for (roots, cfg.roots) |a, b| try testing.expectEqualStrings(a, b);
    try testing.expectEqual(exclude.len, cfg.exclude.len);
    for (exclude, cfg.exclude) |a, b| try testing.expectEqualStrings(a, b);
}

fn expectBad(text: []const u8, line: u32, needle: []const u8) !void {
    var diag: Diag = .{};
    if (Config.parse(testing.allocator, text, &diag)) |*c| {
        var cfg = c.*;
        cfg.deinit();
        std.debug.print("accepted: {f}\n", .{q(text)});
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.BadConfig, e);
    testing.expectEqual(line, diag.line) catch |e| {
        std.debug.print("input {f}: message: {s}\n", .{ q(text), diag.message });
        return e;
    };
    testing.expect(std.mem.indexOf(u8, diag.message, needle) != null) catch |e| {
        std.debug.print("input {f}: message {s} lacks {s}\n", .{ q(text), diag.message, needle });
        return e;
    };
}

test "defaults" {
    try expectParse("", &.{"~"}, &.{});
    try expectParse("  \n# only a comment\n\n", &.{"~"}, &.{});
    try expectParse("exclude = [\"a\"]", &.{"~"}, &.{"a"});
    try expectParse("roots = [\"/x\"]", &.{"/x"}, &.{});
    try expectParse("\xEF\xBB\xBFroots = [\"/x\"]", &.{"/x"}, &.{});
}

test "DESIGN 13.1 example" {
    try expectParse(
        \\# Folders that the daemon monitors. "~" is the home folder.
        \\roots = ["~"]
        \\
        \\# Folders that the daemon ignores. The syntax is the syntax of .gitignore.
        \\exclude = [
        \\  "node_modules/",        # each folder with this name, at each depth
        \\  "/Library/Caches/",     # only this path, from the top of a root
        \\  "*.photoslibrary/",     # a name pattern
        \\  "target/",
        \\  "!/prog/app/target/",  # exception: count this folder
        \\]
        \\
    , &.{"~"}, &.{ "node_modules/", "/Library/Caches/", "*.photoslibrary/", "target/", "!/prog/app/target/" });
}

test "valid spellings" {
    try expectParse("roots=[\"/a\",'/b']", &.{ "/a", "/b" }, &.{});
    try expectParse("  \"roots\"\t=\t[ \"/a\" , ]  # c\r\n'exclude' = [ # c\r\n\r\n 'x' # c\n , # c\n \"y\", # c\n ]\r\n", &.{"/a"}, &.{ "x", "y" });
    try expectParse("exclude = []", &.{"~"}, &.{});
    try expectParse("exclude = [ ]\nroots = [\n\"/a\"\n]", &.{"/a"}, &.{});
    try expectParse("exclude = ['C:\\dir', '\\n', 'a#b', \"a#b\"]", &.{"~"}, &.{ "C:\\dir", "\\n", "a#b", "a#b" });
    try expectParse("exclude = [\"\\b\\t\\n\\f\\r\\e\\\"\\\\\"]", &.{"~"}, &.{"\x08\t\n\x0c\r\x1b\"\\"});
    try expectParse("exclude = [\"\\u00e9\\U0001F600\\x41\\xe9\", \"\"]", &.{"~"}, &.{ "é\u{1F600}Aé", "" });
    try expectParse("exclude = [\"é\", \"a\tb\"]\n", &.{"~"}, &.{ "é", "a\tb" });
    try expectParse("\"r\\u006fots\" = [\"/a\"]", &.{"/a"}, &.{});
    try expectParse("exclude = [\"\\u0000\"]", &.{"~"}, &.{"\x00"});
}

test "invalid files" {
    try expectBad("foo = [\"a\"]", 1, "\"foo\"");
    try expectBad("\n\nfoo.bar = 1", 3, "foo");
    try expectBad("roots = [\"/a\"]\nroots = [\"/b\"]", 2, "duplicate key \"roots\" (first set on line 1)");
    try expectBad("[server]\nroots = [\"/a\"]", 1, "[section]");
    try expectBad("[[x]]", 1, "[section]");
    try expectBad("roots = \"/a\"", 1, "array of strings");
    try expectBad("roots = 5", 1, "array of strings");
    try expectBad("exclude = {a = 1}", 1, "array of strings");
    try expectBad("exclude = true", 1, "array of strings");
    try expectBad("exclude =\n", 1, "array of strings");
    try expectBad("exclude [\"a\"]", 1, "\"=\"");
    try expectBad("exclude = [1]", 1, "must be strings");
    try expectBad("exclude = [\"a\",\n 2]", 2, "must be strings");
    try expectBad("exclude = [\"a\" \"b\"]", 1, "expected \",\"");
    try expectBad("exclude = [,]", 1, "must be strings");
    try expectBad("exclude = [\"a\",,]", 1, "must be strings");
    try expectBad("exclude = [[\"a\"]]", 1, "must be strings");
    try expectBad("exclude = [\"\"\"a\"\"\"]", 1, "multi-line");
    try expectBad("exclude = \"\"\"a\"\"\"", 1, "array of strings");
    try expectBad("exclude = [\n'''a'''\n]", 2, "multi-line");
    try expectBad("exclude = [\"a\"", 1, "not closed");
    try expectBad("\nexclude = [\"a\",\n\"b\"\n", 2, "not closed");
    try expectBad("exclude = [", 1, "not closed");
    try expectBad("exclude = [\"abc", 1, "unterminated");
    try expectBad("exclude = [\"abc\n\"]", 1, "unterminated");
    try expectBad("\nexclude = ['abc\r\n']", 2, "unterminated");
    try expectBad("exclude = [\"a\\", 1, "unterminated");
    try expectBad("exclude = [\"a\\\n\"]", 1, "unterminated");
    try expectBad("exclude = [\"\\q\"]", 1, "invalid escape \\q");
    try expectBad("exclude = [\"\\u12\"]", 1, "\\u");
    try expectBad("exclude = [\"\\ud800\"]", 1, "\\u");
    try expectBad("exclude = [\"\\U00110000\"]", 1, "\\U");
    try expectBad("exclude = [\"\\xZZ\"]", 1, "\\x");
    try expectBad("exclude = [\"a\x01\"]", 1, "control character");
    try expectBad("exclude = ['a\x7f']", 1, "control character");
    try expectBad("exclude = [\"a\"] # bad \x01", 1, "control character");
    try expectBad("# ok\nexclude = [\"a\"] x", 2, "after the array");
    try expectBad("exclude = [\"a\"] roots = [\"/b\"]", 1, "after the array");
    try expectBad("roots = []", 1, "roots is empty");
    try expectBad("\n# c\nroots = [ # none\n]", 3, "roots is empty");
    try expectBad("= 1", 1, "unexpected character");
    try expectBad("a\nb", 1, "unknown key");
    try expectBad("roots = [\"/a\"]\n\xff", 2, "UTF-8");
    try expectBad("exclude = [\"\xc3\"]", 1, "UTF-8");
    try expectBad("a\r\nb\xed\xa0\x80", 2, "UTF-8");
    try expectBad("exclude = [\"a\"]\rroots = []", 1, "after the array");
}

test "message survives the error and does not leak" {
    var diag: Diag = .{};
    try testing.expectError(error.BadConfig, Config.parse(testing.allocator, "x = 1", &diag));
    try testing.expect(diag.message.len > 0);
}

fn tmpPath(tmp: anytype, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(testing.io, buf)];
}

fn expectRootErr(cfg: Config, home: []const u8, line: u32, needles: []const []const u8) !void {
    var diag: Diag = .{};
    if (resolveRoots(testing.allocator, &cfg, home, &diag)) |r| {
        for (r) |s| testing.allocator.free(s);
        testing.allocator.free(r);
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.BadConfig, e);
    try testing.expectEqual(line, diag.line);
    for (needles) |n| testing.expect(std.mem.indexOf(u8, diag.message, n) != null) catch |e| {
        std.debug.print("message {s} lacks {s}\n", .{ diag.message, n });
        return e;
    };
}

test "compileRules reports the line of a bad pattern" {
    var diag: Diag = .{};
    var cfg = try Config.parse(testing.allocator, "exclude = [\n  \"a/\",\n  \"!\",\n]", &diag);
    defer cfg.deinit();
    try testing.expectError(error.BadConfig, compileRules(testing.allocator, &cfg, &diag));
    try testing.expectEqual(@as(u32, 3), diag.line);
    try testing.expect(std.mem.indexOf(u8, diag.message, "not valid") != null);
}

test "isInside: the root / contains everything" {
    try testing.expect(isInside("/a", "/"));
    try testing.expect(isInside("/a/b", "/a"));
    try testing.expect(!isInside("/ab", "/a"));
    try testing.expect(!isInside("/a", "/a"));
    try testing.expect(!isInside("/a", "/a/b"));
    try testing.expect(!isInside("/a", ""));
}

test "resolveRoots" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "home/a", .default_dir);
    try tmp.dir.createDir(io, "home/a/inner", .default_dir);
    try tmp.dir.createDir(io, "home/ab", .default_dir); // shares a prefix with "a", not nested
    try tmp.dir.writeFile(io, .{ .sub_path = "home/file", .data = "x" });
    try tmp.dir.symLink(io, "a", "home/link", .{});
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(tmp, &b);
    const home = try std.fmt.allocPrint(gpa, "{s}/home", .{base});
    defer gpa.free(home);
    const abs_a = try std.fmt.allocPrint(gpa, "{s}/a/", .{home});
    defer gpa.free(abs_a);

    // `~`, `~/x`, trailing slash, a symlink, and a prefix-sharing sibling all resolve.
    var diag: Diag = .{};
    var cfg = try Config.parse(gpa, "roots = [\"~/a\", \"~/ab/\"]", &diag);
    const got = try resolveRoots(gpa, &cfg, home, &diag);
    cfg.deinit();
    defer {
        for (got) |s| gpa.free(s);
        gpa.free(got);
    }
    try testing.expectEqual(2, got.len);
    var want: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}/a", .{home}), got[0]);
    try testing.expect(std.mem.endsWith(u8, got[1], "/home/ab"));

    const home_only: Config = .{ .roots = &.{"~"}, .exclude = &.{} };
    const r = try resolveRoots(gpa, &home_only, home, &diag);
    defer {
        for (r) |s| gpa.free(s);
        gpa.free(r);
    }
    try testing.expectEqualStrings(home, r[0]);

    const abs: Config = .{ .roots = &.{abs_a}, .exclude = &.{} };
    const r2 = try resolveRoots(gpa, &abs, "", &diag);
    defer {
        for (r2) |s| gpa.free(s);
        gpa.free(r2);
    }
    try testing.expect(std.mem.endsWith(u8, r2[0], "/home/a"));

    const l = [_]u32{ 4, 7 };
    try expectRootErr(.{ .roots = &.{ "~/a", "~/link" }, .exclude = &.{}, .roots_lines = &l }, home, 7, &.{ "same folder", "\"~/a\"", "\"~/link\"" });
    try expectRootErr(.{ .roots = &.{ "~/a", "~/a/inner" }, .exclude = &.{}, .roots_lines = &l }, home, 7, &.{ "inside", "\"~/a/inner\"", "\"~/a\"" });
    try expectRootErr(.{ .roots = &.{ "~/a/inner", "~/a" }, .exclude = &.{}, .roots_lines = &l }, home, 7, &.{ "inside", "\"~/a/inner\"", "\"~/a\"" });
    try expectRootErr(.{ .roots = &.{"~/nope"}, .exclude = &.{}, .roots_lines = &l }, home, 4, &.{ "does not exist", "~/nope" });
    try expectRootErr(.{ .roots = &.{"~/file"}, .exclude = &.{} }, home, 0, &.{"not a folder"});
    try expectRootErr(.{ .roots = &.{"docs"}, .exclude = &.{} }, home, 0, &.{ "not an absolute path", "docs" });
    try expectRootErr(.{ .roots = &.{"~bob/x"}, .exclude = &.{} }, home, 0, &.{"~user"});
    try expectRootErr(.{ .roots = &.{"~"}, .exclude = &.{} }, "", 0, &.{"home folder"});
    try expectRootErr(.{ .roots = &.{""}, .exclude = &.{} }, home, 0, &.{"empty"});
    try expectRootErr(.{ .roots = &.{"/a\x00b"}, .exclude = &.{} }, home, 0, &.{"NUL"});
    if (builtin.os.tag == .macos)
        try expectRootErr(.{ .roots = &.{"/"}, .exclude = &.{} }, home, 0, &.{"macOS"});
}

test "defaultPath" {
    const a = try defaultPath(testing.allocator, "/Users/x");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/Users/x/.config/dirsized/config.toml", a);
    const b = try defaultPath(testing.allocator, "/Users/x/");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/Users/x/.config/dirsized/config.toml", b);
}

test "fuzz parse: no crash, no leak" {
    var prng = std.Random.DefaultPrng.init(0xc0f16);
    const r = prng.random();
    const seed =
        \\# c
        \\roots = ["~", '/x']
        \\exclude = [
        \\  "a\u00e9\n", 'b', # c
        \\]
        \\
    ;
    const frag = [_][]const u8{ "\"", "'", "[", "]", ",", "\\", "=", "#", "\n", "\r\n", "\\u", "\\U0010FFFF", "\"\"\"", "roots", "exclude", "\xff", "\x00", "é", " " };
    var buf: [256]u8 = undefined;
    for (0..20000) |i| {
        var n: usize = 0;
        switch (i % 3) {
            0 => { // random bytes
                n = r.uintAtMost(usize, buf.len);
                r.bytes(buf[0..n]);
            },
            else => { // the valid file with random byte edits and fragment splices
                @memcpy(buf[0..seed.len], seed);
                n = seed.len;
                for (0..r.uintAtMost(usize, 4)) |_| {
                    const at = r.uintLessThan(usize, n);
                    if (i % 3 == 1) {
                        buf[at] = r.int(u8);
                    } else {
                        const f = frag[r.uintLessThan(usize, frag.len)];
                        if (n + f.len > buf.len) continue;
                        std.mem.copyBackwards(u8, buf[at + f.len .. n + f.len], buf[at..n]);
                        @memcpy(buf[at..][0..f.len], f);
                        n += f.len;
                    }
                }
            },
        }
        var diag: Diag = .{};
        var cfg = Config.parse(testing.allocator, buf[0..n], &diag) catch |e| {
            try testing.expectEqual(error.BadConfig, e);
            try testing.expect(diag.line >= 1 and diag.message.len > 0);
            continue;
        };
        cfg.deinit();
    }
}
