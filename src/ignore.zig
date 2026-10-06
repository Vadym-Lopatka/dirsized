//! Gitignore-syntax rules for folders.
//!
//! A pattern is split into `/`-separated segments once, in `compile`. `match` then walks the
//! segments with an iterative matcher that backtracks only to the last `*` (inside a segment)
//! or the last `**` (across segments), so it needs no allocation, no recursion, and costs
//! O(pattern * path) at worst.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Match = struct { excluded: bool, rule: ?u32 };

/// One `/`-separated piece of a pattern. `text` still holds `\` escapes; `glob` reads them.
const Seg = struct { text: []const u8, dstar: bool };

const Pattern = struct {
    negated: bool,
    /// A `/` at the start or in the middle ties the pattern to the root. Otherwise it is
    /// a single segment that is compared with the folder's own name at any depth.
    anchored: bool,
    first: u32,
    count: u32,
};

pub const Rules = struct {
    patterns: []Pattern,
    segs: []Seg,
    bytes: []u8,

    /// `bad.*` is set to the index of the first invalid pattern when `error.BadPattern` is
    /// returned, and to null otherwise. Invalid: empty, only `!` and/or `/`, a trailing `\`.
    /// `#` is not a comment here: the patterns come from TOML strings.
    pub fn compile(gpa: Allocator, patterns: []const []const u8, bad: *?u32) !Rules {
        bad.* = null;
        var total: usize = 0;
        for (patterns) |p| total += p.len;
        const bytes = try gpa.alloc(u8, total);
        errdefer gpa.free(bytes);
        const pats = try gpa.alloc(Pattern, patterns.len);
        errdefer gpa.free(pats);
        var segs: std.ArrayList(Seg) = .empty;
        errdefer segs.deinit(gpa);

        var used: usize = 0;
        for (patterns, pats, 0..) |raw, *out, idx| {
            errdefer |e| if (e == error.BadPattern) {
                bad.* = @intCast(idx);
            };
            const negated = raw.len > 0 and raw[0] == '!';
            const body = if (negated) raw[1..] else raw;
            const first = segs.items.len;
            var start: usize = 0;
            var i: usize = 0;
            while (i <= body.len) : (i += 1) {
                if (i < body.len and body[i] == '\\') {
                    if (i + 1 == body.len) return error.BadPattern;
                    i += 1; // the escaped byte, even a `/`, never ends a segment
                    continue;
                }
                if (i < body.len and body[i] != '/') continue;
                // Empty segments (leading, trailing, doubled `/`) carry no meaning.
                if (i > start) {
                    const text = bytes[used..][0 .. i - start];
                    @memcpy(text, body[start..i]);
                    used += text.len;
                    try segs.append(gpa, .{ .text = text, .dstar = std.mem.eql(u8, text, "**") });
                }
                start = i + 1;
            }
            const count = segs.items.len - first;
            if (count == 0) return error.BadPattern;
            out.* = .{
                .negated = negated,
                .anchored = (body[0] == '/') or count > 1,
                .first = @intCast(first),
                .count = @intCast(count),
            };
        }
        return .{ .patterns = pats, .segs = try segs.toOwnedSlice(gpa), .bytes = bytes };
    }

    pub fn deinit(self: *Rules, gpa: Allocator) void {
        gpa.free(self.patterns);
        gpa.free(self.segs);
        gpa.free(self.bytes);
        self.* = undefined;
    }

    /// One folder, relative to its root, with no leading or trailing slash. The last
    /// matching pattern decides. Ancestors are not looked at.
    pub fn match(self: *const Rules, rel_path: []const u8, ignore_case: bool) Match {
        if (rel_path.len == 0) return .{ .excluded = false, .rule = null };
        const name = rel_path[if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |s| s + 1 else 0..];
        var i = self.patterns.len;
        while (i > 0) {
            i -= 1;
            const p = self.patterns[i];
            const segs = self.segs[p.first..][0..p.count];
            const hit = if (p.anchored)
                matchAnchored(segs, rel_path, ignore_case)
            else
                segs[0].dstar or glob(segs[0].text, name, ignore_case);
            if (hit) return .{ .excluded = !p.negated, .rule = @intCast(i) };
        }
        return .{ .excluded = false, .rule = null };
    }

    /// Tests each ancestor from the top and returns the first exclusion: a `!` rule cannot
    /// re-include a folder whose parent is excluded. With no exclusion, returns the verdict
    /// for the folder itself, so `rule` can name a `!` that kept it.
    pub fn explain(self: *const Rules, rel_path: []const u8, ignore_case: bool) Match {
        var end: usize = 0;
        while (true) {
            end = std.mem.indexOfScalarPos(u8, rel_path, end, '/') orelse rel_path.len;
            const m = self.match(rel_path[0..end], ignore_case);
            if (m.excluded or end == rel_path.len) return m;
            end += 1;
        }
    }
};

/// End (exclusive) of the segment that starts at `pos`.
fn segEnd(path: []const u8, pos: usize) usize {
    return std.mem.indexOfScalarPos(u8, path, pos, '/') orelse path.len;
}

/// Whole-path match with `**` standing for any number of folders. The classic "remember the
/// last star" loop is enough: matching the earliest possible way never hurts later segments.
fn matchAnchored(segs: []const Seg, path: []const u8, ic: bool) bool {
    var i: usize = 0;
    var pos: usize = 0; // start of the next unmatched path segment; > path.len when none is left
    var star: ?usize = null;
    var star_pos: usize = 0;
    while (true) {
        if (i < segs.len and segs[i].dstar) {
            // `x/**` means "everything inside x": it needs at least one more folder.
            if (i == segs.len - 1) return pos <= path.len;
            star = i;
            star_pos = pos;
            i += 1;
            continue;
        }
        if (pos > path.len) return i == segs.len;
        if (i < segs.len) {
            const end = segEnd(path, pos);
            if (glob(segs[i].text, path[pos..end], ic)) {
                i += 1;
                pos = end + 1;
                continue;
            }
        }
        const s = star orelse return false;
        if (star_pos > path.len) return false;
        star_pos = segEnd(path, star_pos) + 1;
        pos = star_pos;
        i = s + 1;
    }
}

fn fold(c: u8, ic: bool) u8 {
    return if (ic) std.ascii.toLower(c) else c;
}

/// Matches one path segment against one pattern segment. `*` and `?` never see a `/`
/// because segments are split first. Backtracks only to the last `*`.
fn glob(pat: []const u8, text: []const u8, ic: bool) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pat.len) {
            switch (pat[p]) {
                '*' => {
                    p += 1;
                    star_p = p;
                    star_t = t;
                    continue;
                },
                '?' => {
                    p += 1;
                    t += 1;
                    continue;
                },
                else => if (atom(pat, p, text[t], ic)) |next| {
                    p = next;
                    t += 1;
                    continue;
                },
            }
        }
        const sp = star_p orelse return false;
        star_t += 1;
        t = star_t;
        p = sp;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// Tests the single-byte pattern item at `pat[p]` (a literal, an escape, or a `[...]` class)
/// against `c`. Returns the index after the item on a match.
fn atom(pat: []const u8, p: usize, c: u8, ic: bool) ?usize {
    switch (pat[p]) {
        '\\' => return if (fold(pat[p + 1], ic) == fold(c, ic)) p + 2 else null,
        '[' => {},
        else => return if (fold(pat[p], ic) == fold(c, ic)) p + 1 else null,
    }
    var i = p + 1;
    const negate = i < pat.len and (pat[i] == '!' or pat[i] == '^');
    if (negate) i += 1;
    const lo_c = std.ascii.toLower(c);
    const up_c = std.ascii.toUpper(c);
    var hit = false;
    var first = true;
    while (true) : (first = false) {
        // A class that never closes is not a class: `[` is then an ordinary byte.
        if (i >= pat.len) return if (fold('[', ic) == fold(c, ic)) p + 1 else null;
        if (pat[i] == ']' and !first) return if (hit != negate) i + 1 else null;
        var lo = pat[i];
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        i += 1;
        var hi = lo;
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            hi = pat[i + 1];
            i += 2;
            if (hi == '\\' and i < pat.len) {
                hi = pat[i];
                i += 1;
            }
        }
        if ((lo <= c and c <= hi) or (ic and ((lo <= lo_c and lo_c <= hi) or (lo <= up_c and up_c <= hi)))) hit = true;
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Case = struct {
    path: []const u8,
    excluded: bool,
    rule: ?u32 = null,
    ic: bool = false,
};

fn compileOrFail(patterns: []const []const u8) !Rules {
    var bad: ?u32 = null;
    return Rules.compile(testing.allocator, patterns, &bad);
}

fn expectCases(patterns: []const []const u8, cases: []const Case) !void {
    var rules = try compileOrFail(patterns);
    defer rules.deinit(testing.allocator);
    for (cases) |c| {
        const m = rules.match(c.path, c.ic);
        testing.expectEqual(c.excluded, m.excluded) catch |e| {
            std.debug.print("patterns {any} path '{s}'\n", .{ patterns, c.path });
            return e;
        };
        testing.expectEqual(c.rule, m.rule) catch |e| {
            std.debug.print("patterns {any} path '{s}' rule\n", .{ patterns, c.path });
            return e;
        };
    }
}

test "DESIGN 13.1 example" {
    try expectCases(&.{
        "node_modules/",
        "/Library/Caches/",
        "*.photoslibrary/",
        "target/",
        "!/prog/app/target/",
    }, &.{
        .{ .path = "node_modules", .excluded = true, .rule = 0 },
        .{ .path = "a/b/node_modules", .excluded = true, .rule = 0 },
        .{ .path = "Library/Caches", .excluded = true, .rule = 1 },
        .{ .path = "x/Library/Caches", .excluded = false },
        .{ .path = "Pictures/Fotos.photoslibrary", .excluded = true, .rule = 2 },
        .{ .path = "a/target", .excluded = true, .rule = 3 },
        .{ .path = "prog/app/target", .excluded = false, .rule = 4 },
        .{ .path = "prog/other/target", .excluded = true, .rule = 3 },
        .{ .path = "prog", .excluded = false },
    });
}

test "unanchored, trailing slash, anchoring" {
    try expectCases(&.{"foo"}, &.{
        .{ .path = "foo", .excluded = true, .rule = 0 },
        .{ .path = "a/foo", .excluded = true, .rule = 0 },
        .{ .path = "foo/a", .excluded = false }, // match() ignores ancestors
        .{ .path = "foobar", .excluded = false },
        .{ .path = "afoo", .excluded = false },
    });
    try expectCases(&.{"foo/"}, &.{
        .{ .path = "foo", .excluded = true, .rule = 0 },
        .{ .path = "a/b/foo", .excluded = true, .rule = 0 },
    });
    try expectCases(&.{"foo//"}, &.{.{ .path = "x/foo", .excluded = true, .rule = 0 }});
    try expectCases(&.{"/foo"}, &.{
        .{ .path = "foo", .excluded = true, .rule = 0 },
        .{ .path = "a/foo", .excluded = false },
    });
    try expectCases(&.{"a/b"}, &.{
        .{ .path = "a/b", .excluded = true, .rule = 0 },
        .{ .path = "x/a/b", .excluded = false },
        .{ .path = "b", .excluded = false },
    });
    try expectCases(&.{"a/b/"}, &.{
        .{ .path = "a/b", .excluded = true, .rule = 0 },
        .{ .path = "x/a/b", .excluded = false },
    });
}

test "wildcards never cross slash" {
    try expectCases(&.{"*.log"}, &.{
        .{ .path = "x.log", .excluded = true, .rule = 0 },
        .{ .path = "a/b/x.log", .excluded = true, .rule = 0 },
        .{ .path = ".log", .excluded = true, .rule = 0 },
        .{ .path = "x.logs", .excluded = false },
    });
    try expectCases(&.{"a*b"}, &.{
        .{ .path = "ab", .excluded = true, .rule = 0 },
        .{ .path = "axxb", .excluded = true, .rule = 0 },
        .{ .path = "x/ab", .excluded = true, .rule = 0 },
        .{ .path = "a/b", .excluded = false },
    });
    try expectCases(&.{"/a*b"}, &.{.{ .path = "a/b", .excluded = false }});
    try expectCases(&.{"a/*"}, &.{
        .{ .path = "a/b", .excluded = true, .rule = 0 },
        .{ .path = "a/b/c", .excluded = false },
        .{ .path = "a", .excluded = false },
    });
    try expectCases(&.{"a?c"}, &.{
        .{ .path = "abc", .excluded = true, .rule = 0 },
        .{ .path = "ac", .excluded = false },
        .{ .path = "abbc", .excluded = false },
    });
    try expectCases(&.{"*"}, &.{
        .{ .path = "a", .excluded = true, .rule = 0 },
        .{ .path = "a/b/c", .excluded = true, .rule = 0 },
    });
}

test "character classes" {
    try expectCases(&.{"[abc]x"}, &.{
        .{ .path = "ax", .excluded = true, .rule = 0 },
        .{ .path = "dx", .excluded = false },
    });
    try expectCases(&.{"v[0-9]"}, &.{
        .{ .path = "v5", .excluded = true, .rule = 0 },
        .{ .path = "va", .excluded = false },
        .{ .path = "v55", .excluded = false },
    });
    try expectCases(&.{"v[!0-9]"}, &.{
        .{ .path = "v5", .excluded = false },
        .{ .path = "va", .excluded = true, .rule = 0 },
    });
    try expectCases(&.{"v[^0-9]"}, &.{.{ .path = "va", .excluded = true, .rule = 0 }});
    try expectCases(&.{"[]a]"}, &.{ // `]` first is a member
        .{ .path = "]", .excluded = true, .rule = 0 },
        .{ .path = "a", .excluded = true, .rule = 0 },
        .{ .path = "b", .excluded = false },
    });
    try expectCases(&.{"[a-]"}, &.{
        .{ .path = "-", .excluded = true, .rule = 0 },
        .{ .path = "a", .excluded = true, .rule = 0 },
    });
    try expectCases(&.{"a[b"}, &.{ // unterminated: literal `[`
        .{ .path = "a[b", .excluded = true, .rule = 0 },
        .{ .path = "ab", .excluded = false },
    });
    try expectCases(&.{"[z-a]"}, &.{.{ .path = "m", .excluded = false }});
    try expectCases(&.{"[\\]]"}, &.{.{ .path = "]", .excluded = true, .rule = 0 }});
    try expectCases(&.{"[a/b]"}, &.{.{ .path = "x/b", .excluded = false }});
}

test "double star" {
    try expectCases(&.{"**/x"}, &.{
        .{ .path = "x", .excluded = true, .rule = 0 },
        .{ .path = "a/x", .excluded = true, .rule = 0 },
        .{ .path = "a/b/x", .excluded = true, .rule = 0 },
        .{ .path = "a/xy", .excluded = false },
    });
    try expectCases(&.{"x/**"}, &.{
        .{ .path = "x", .excluded = false }, // only what is inside
        .{ .path = "x/a", .excluded = true, .rule = 0 },
        .{ .path = "x/a/b", .excluded = true, .rule = 0 },
        .{ .path = "a/x/b", .excluded = false },
    });
    try expectCases(&.{"a/**/b"}, &.{
        .{ .path = "a/b", .excluded = true, .rule = 0 },
        .{ .path = "a/x/b", .excluded = true, .rule = 0 },
        .{ .path = "a/x/y/b", .excluded = true, .rule = 0 },
        .{ .path = "a/x/y", .excluded = false },
        .{ .path = "z/a/b", .excluded = false },
        .{ .path = "a/b/c", .excluded = false },
    });
    try expectCases(&.{"**"}, &.{
        .{ .path = "a", .excluded = true, .rule = 0 },
        .{ .path = "a/b", .excluded = true, .rule = 0 },
    });
    try expectCases(&.{"a**b"}, &.{ // not a whole segment: acts like `*`
        .{ .path = "axb", .excluded = true, .rule = 0 },
        .{ .path = "a/b", .excluded = false },
    });
    try expectCases(&.{"/**/a/**/b/**"}, &.{
        .{ .path = "a/b/c", .excluded = true, .rule = 0 },
        .{ .path = "x/a/y/b/z/w", .excluded = true, .rule = 0 },
        .{ .path = "a/b", .excluded = false },
        .{ .path = "b/a/c", .excluded = false },
    });
    try expectCases(&.{"**/a/**"}, &.{
        .{ .path = "a/b", .excluded = true, .rule = 0 },
        .{ .path = "q/a/b", .excluded = true, .rule = 0 },
        .{ .path = "q/a", .excluded = false },
    });
}

test "negation and last match wins" {
    try expectCases(&.{ "*.o", "!keep.o" }, &.{
        .{ .path = "a.o", .excluded = true, .rule = 0 },
        .{ .path = "keep.o", .excluded = false, .rule = 1 },
    });
    try expectCases(&.{ "!keep.o", "*.o" }, &.{.{ .path = "keep.o", .excluded = true, .rule = 1 }});
    try expectCases(&.{ "a", "!a", "a" }, &.{.{ .path = "a", .excluded = true, .rule = 2 }});
    try expectCases(&.{"!a"}, &.{.{ .path = "a", .excluded = false, .rule = 0 }});
}

test "escapes and literals" {
    try expectCases(&.{"\\#x"}, &.{
        .{ .path = "#x", .excluded = true, .rule = 0 },
        .{ .path = "x", .excluded = false },
    });
    try expectCases(&.{"#x"}, &.{.{ .path = "#x", .excluded = true, .rule = 0 }}); // no comments
    try expectCases(&.{"\\!x"}, &.{
        .{ .path = "!x", .excluded = true, .rule = 0 },
        .{ .path = "x", .excluded = false },
    });
    try expectCases(&.{"\\*"}, &.{
        .{ .path = "*", .excluded = true, .rule = 0 },
        .{ .path = "a", .excluded = false },
    });
    try expectCases(&.{"a\\?b"}, &.{
        .{ .path = "a?b", .excluded = true, .rule = 0 },
        .{ .path = "axb", .excluded = false },
    });
    try expectCases(&.{"\\\\x"}, &.{.{ .path = "\\x", .excluded = true, .rule = 0 }});
    try expectCases(&.{"a\\/b"}, &.{.{ .path = "a/b", .excluded = false }}); // a name cannot hold `/`
    try expectCases(&.{"a b "}, &.{.{ .path = "a b ", .excluded = true, .rule = 0 }}); // spaces are kept
    try expectCases(&.{"\\**"}, &.{.{ .path = "*zz", .excluded = true, .rule = 0 }});
}

test "bytes, not UTF-8" {
    try expectCases(&.{"\xff*"}, &.{
        .{ .path = "a/\xff\xfe", .excluded = true, .rule = 0 },
        .{ .path = "\xfe", .excluded = false },
    });
    try expectCases(&.{"é"}, &.{
        .{ .path = "é", .excluded = true, .rule = 0 },
        .{ .path = "É", .excluded = false, .ic = true }, // non-ASCII is exact
    });
    try expectCases(&.{"a?"}, &.{.{ .path = "aé", .excluded = false }}); // `?` is one byte
}

test "ignore case" {
    try expectCases(&.{ "Node_Modules", "/Library/CACHES", "[A-C]x", "*.PhotosLibrary" }, &.{
        .{ .path = "node_modules", .excluded = false },
        .{ .path = "node_modules", .excluded = true, .rule = 0, .ic = true },
        .{ .path = "library/caches", .excluded = true, .rule = 1, .ic = true },
        .{ .path = "library/caches", .excluded = false },
        .{ .path = "bx", .excluded = false },
        .{ .path = "bx", .excluded = true, .rule = 2, .ic = true },
        .{ .path = "Bx", .excluded = true, .rule = 2, .ic = true },
        .{ .path = "x.photoslibrary", .excluded = true, .rule = 3, .ic = true },
    });
    try expectCases(&.{"[a-c]x"}, &.{.{ .path = "BX", .excluded = true, .rule = 0, .ic = true }});
}

test "explain: excluded ancestor wins" {
    var rules = try compileOrFail(&.{ "build", "!/a/build/keep", "/a/**/gen", "!/a/x/gen/ok" });
    defer rules.deinit(testing.allocator);
    // The `!` cannot re-include a child of an excluded folder.
    var m = rules.explain("a/build/keep", false);
    try testing.expect(m.excluded);
    try testing.expectEqual(@as(?u32, 0), m.rule);
    // match() alone, without ancestors, would say "kept".
    try testing.expect(!rules.match("a/build/keep", false).excluded);
    m = rules.explain("a/x/gen/ok/deep", false);
    try testing.expect(m.excluded);
    try testing.expectEqual(@as(?u32, 2), m.rule);
    m = rules.explain("a/y", false);
    try testing.expect(!m.excluded);
    try testing.expectEqual(@as(?u32, null), m.rule);
    // Nothing excluded: the verdict of the folder itself, here a `!` that kept it.
    var r2 = try compileOrFail(&.{ "x*", "!xy" });
    defer r2.deinit(testing.allocator);
    m = r2.explain("a/xy", false);
    try testing.expect(!m.excluded);
    try testing.expectEqual(@as(?u32, 1), m.rule);
    m = r2.explain("xa/b/c", false);
    try testing.expect(m.excluded);
    try testing.expectEqual(@as(?u32, 0), m.rule);
    try testing.expect(!r2.explain("", false).excluded);
}

test "bad patterns report their index" {
    const bads = [_][]const u8{ "", "!", "/", "//", "!/", "a\\", "!\\" };
    for (bads) |b| {
        var bad: ?u32 = null;
        try testing.expectError(error.BadPattern, Rules.compile(testing.allocator, &.{ "ok", "ok2", b }, &bad));
        try testing.expectEqual(@as(?u32, 2), bad);
    }
    var bad: ?u32 = 7;
    var r = try Rules.compile(testing.allocator, &.{}, &bad);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, null), bad);
    try testing.expect(!r.match("a", false).excluded);
}

test "pathological patterns stay fast" {
    var rules = try compileOrFail(&.{ "a*a*a*a*a*a*a*a*b", "**/a/**/a/**/a/**/a/**/a/**/b", "[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*!" });
    defer rules.deinit(testing.allocator);
    const name = "a" ** 3000;
    try testing.expect(!rules.match(name, false).excluded);
    const deep = "a/" ** 1500 ++ "c";
    try testing.expect(!rules.match(deep, false).excluded);
    try testing.expect(!rules.explain(deep, false).excluded);
}

test "fuzz: no crash, no leak" {
    var prng = std.Random.DefaultPrng.init(0xd1125);
    const r = prng.random();
    const alphabet = "ab*?[]!^\\/#-.\xff A";
    var pbuf: [3][24]u8 = undefined;
    var pats: [3][]const u8 = undefined;
    var path: [40]u8 = undefined;
    for (0..20000) |_| {
        for (&pats, &pbuf) |*p, *buf| {
            const n = r.uintAtMost(usize, buf.len);
            for (buf[0..n]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
            p.* = buf[0..n];
        }
        const pn = r.uintAtMost(usize, path.len);
        for (path[0..pn]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        var bad: ?u32 = null;
        var rules = Rules.compile(testing.allocator, &pats, &bad) catch |e| {
            try testing.expectEqual(error.BadPattern, e);
            try testing.expect(bad.? < pats.len);
            continue;
        };
        defer rules.deinit(testing.allocator);
        const ic = r.boolean();
        _ = rules.match(path[0..pn], ic);
        _ = rules.explain(path[0..pn], ic);
    }
}
