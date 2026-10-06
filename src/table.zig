//! The folder table: pure data structure, no I/O, owner thread only.
//!
//! Layout: 32-byte nodes in one flat array, a flat open-addressing index of u32 node ids keyed
//! by (parent, name), one name area that only grows until `shrinkToFit` compacts it, a free list
//! threaded through `next_sibling`.
//! Nodes refer to each other by index only.
//!
//! Allocation-failure safety: every fallible operation reserves all the memory it can need
//! (nodes, names, index, side map, caller's list) before it changes anything, then mutates with
//! `assumeCapacity` calls only. An error therefore leaves the table exactly as it was.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const NodeId = u32;
pub const none: NodeId = std.math.maxInt(u32);
/// `parent` of a freed node. Lets a loaded image tell free nodes from live ones in one pass.
pub const free_mark: NodeId = std.math.maxInt(u32) - 1;

pub const Node = extern struct {
    total: u64, // own + total of every child
    own: u64, // sum of logical lengths of regular files directly inside
    parent: NodeId, // `none` for a root
    first_child: NodeId,
    next_sibling: NodeId, // also the free-list link of a removed node
    name: u32, // low 29 bits: offset into the name area; high 3 bits: flags
};

comptime {
    assert(@sizeOf(Node) == 32);
}

pub const Flags = packed struct(u3) {
    pending: bool = false, // not read yet (or a re-read is owed after creation)
    denied: bool = false, // could not be read (permission)
    recheck: bool = false, // a re-read is owed but the value is believed current; never changes `state`
};

pub const State = enum { ok, scanning, partial };

pub const Root = struct { path: []const u8, node: NodeId };

pub const max_name_len = 255;
const offset_bits = 29;
/// Capacity of the name area in bytes.
pub const max_names: usize = 1 << offset_bits;
const offset_mask: u32 = (1 << offset_bits) - 1;
const max_nodes: usize = std.math.maxInt(u32) - 2;

/// Number of flagged descendants (self excluded). One map for both counters: a node that has
/// both kinds of flagged descendants costs one entry, and a pending node's ancestors already
/// hold keys.
const Below = struct { pending: u32 = 0, denied: u32 = 0 };

/// A node freed while it had an aux value; the owner drains `Table.freed` after each apply.
pub const Freed = struct { id: NodeId, aux: u32 };

/// Borrowed raw arrays of a table, for the snapshot writer. Valid until the next mutation.
pub const Image = struct {
    nodes: []const Node,
    names: []const u8,
    slots: []const NodeId,
    free_head: NodeId,
    free_count: usize,
    roots: []const Root,
};

pub const Deepest = struct { id: NodeId, exact: bool };

/// What a removed subtree took with it, to be subtracted from the ancestors.
const Subtree = struct { total: u64 = 0, pending: u32 = 0, denied: u32 = 0 };

pub const ChildIterator = struct {
    table: *const Table,
    cur: NodeId,

    /// Advances before returning, so the returned node may be removed during iteration.
    pub fn next(self: *ChildIterator) ?NodeId {
        if (self.cur == none) return null;
        const id = self.cur;
        self.cur = self.table.nodes.items[id].next_sibling;
        return id;
    }
};

pub const Table = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,
    /// Bytes in `names` that no live node refers to (freed folders). `compactNames` gives them back.
    dead_names: usize = 0,
    root_list: std.ArrayList(Root) = .empty,
    /// Power-of-two open-addressing table of node ids, `none` = empty. Deletion uses backward
    /// shift (not tombstones): no tombstone buildup under churn, no state to clear on growth,
    /// and probe chains stay short.
    slots: []NodeId = &.{},
    slots_used: usize = 0, // live non-root nodes
    free_head: NodeId = none,
    free_count: usize = 0,
    below: std.AutoHashMapUnmanaged(NodeId, Below) = .empty,
    /// Reused by applyRead; grows to the largest folder seen, never shrinks.
    scratch: std.ArrayList(NodeId) = .empty,
    /// Linux only (`enableAux`): one u32 per node (the inotify watch number, `none` = no watch).
    /// Empty and unused while `aux_on` is false.
    aux: std.ArrayList(u32) = .empty,
    aux_on: bool = false,
    /// Nodes freed while holding an aux value. The owner drains (and clears) it after each apply
    /// or remove. Its capacity always covers the node count, so freeing never allocates.
    freed: std.ArrayList(Freed) = .empty,

    pub fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Table) void {
        for (self.root_list.items) |r| self.gpa.free(r.path);
        self.root_list.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.gpa.free(self.slots);
        self.below.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.aux.deinit(self.gpa);
        self.freed.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- roots -------------------------------------------------------------------------

    /// Roots may nest (`/a` and `/a/b`); `lookup` picks the longest. A duplicate path is
    /// `error.RootExists`, an empty one `error.InvalidPath`.
    pub fn addRoot(self: *Table, abs_path: []const u8) !NodeId {
        if (abs_path.len == 0) return error.InvalidPath;
        for (self.root_list.items) |r| {
            if (std.mem.eql(u8, r.path, abs_path)) return error.RootExists;
        }
        try self.root_list.ensureUnusedCapacity(self.gpa, 1);
        try self.reserveNodes(1);
        const path = try self.gpa.dupe(u8, abs_path);
        const id = self.allocNode();
        self.nodes.items[id] = .{
            .total = 0,
            .own = 0,
            .parent = none,
            .first_child = none,
            .next_sibling = none,
            .name = packName(0, .{ .pending = true }),
        };
        self.root_list.appendAssumeCapacity(.{ .path = path, .node = id });
        return id;
    }

    pub fn removeRoot(self: *Table, id: NodeId) void {
        assert(self.nodes.items[id].parent == none);
        _ = self.freeSubtree(id);
        for (self.root_list.items, 0..) |r, i| {
            if (r.node != id) continue;
            self.gpa.free(r.path);
            _ = self.root_list.orderedRemove(i);
            return;
        }
        unreachable;
    }

    pub fn roots(self: *const Table) []const Root {
        return self.root_list.items;
    }

    // ---- queries -----------------------------------------------------------------------

    /// The longest root that is a path prefix of `abs_path` (on a component boundary).
    fn rootFor(self: *const Table, abs_path: []const u8) ?Root {
        var best: ?Root = null;
        for (self.root_list.items) |r| {
            if (!std.mem.startsWith(u8, abs_path, r.path)) continue;
            // `/a/b` must not claim `/a/bc`; a root such as `/` already ends in a separator.
            const rest = abs_path[r.path.len..];
            if (rest.len != 0 and r.path[r.path.len - 1] != '/' and rest[0] != '/') continue;
            if (best == null or r.path.len > best.?.path.len) best = r;
        }
        return best;
    }

    /// What follows the root in `abs_path`, without the separator.
    fn belowRoot(root: Root, abs_path: []const u8) []const u8 {
        const rest = abs_path[root.path.len..];
        if (rest.len == 0 or root.path[root.path.len - 1] == '/') return rest;
        return rest[1..];
    }

    pub fn lookup(self: *const Table, abs_path: []const u8) ?NodeId {
        const root = self.rootFor(abs_path) orelse return null;
        if (abs_path.len == root.path.len) return root.node;
        var id = root.node;
        var it = std.mem.splitScalar(u8, belowRoot(root, abs_path), '/');
        while (it.next()) |part| id = self.child(id, part) orelse return null;
        return id;
    }

    /// The deepest node on the path: `exact` when the whole path resolved, else its deepest
    /// existing ancestor. Null when no root contains the path.
    pub fn lookupDeepest(self: *const Table, abs_path: []const u8) ?Deepest {
        const root = self.rootFor(abs_path) orelse return null;
        if (abs_path.len == root.path.len) return .{ .id = root.node, .exact = true };
        var id = root.node;
        var it = std.mem.splitScalar(u8, belowRoot(root, abs_path), '/');
        while (it.next()) |part| id = self.child(id, part) orelse return .{ .id = id, .exact = false };
        return .{ .id = id, .exact = true };
    }

    pub fn child(self: *const Table, parent: NodeId, name_bytes: []const u8) ?NodeId {
        if (self.slots.len == 0) return null;
        const mask = self.slots.len - 1;
        var i: usize = @intCast(hash(parent, name_bytes) & mask);
        while (true) : (i = (i + 1) & mask) {
            const s = self.slots[i];
            if (s == none) return null;
            if (self.nodes.items[s].parent == parent and std.mem.eql(u8, self.nameOf(s), name_bytes)) return s;
        }
    }

    pub fn children(self: *const Table, parent: NodeId) ChildIterator {
        return .{ .table = self, .cur = self.nodes.items[parent].first_child };
    }

    /// For a root: its full path.
    pub fn name(self: *const Table, id: NodeId) []const u8 {
        if (self.nodes.items[id].parent != none) return self.nameOf(id);
        for (self.root_list.items) |r| {
            if (r.node == id) return r.path;
        }
        unreachable;
    }

    /// Appends the absolute path of `id` to `out` (does not clear it).
    pub fn pathOf(self: *const Table, id: NodeId, out: *std.ArrayList(u8), gpa: Allocator) !void {
        const nodes = self.nodes.items;
        var len: usize = 0;
        var top = id;
        while (nodes[top].parent != none) : (top = nodes[top].parent) len += 1 + self.nameOf(top).len;
        const root_path = self.name(top);
        // The component right under a root such as `/` needs no separator of its own.
        if (len != 0 and root_path[root_path.len - 1] == '/') len -= 1;

        const base = out.items.len;
        try out.resize(gpa, base + root_path.len + len);
        @memcpy(out.items[base..][0..root_path.len], root_path);
        var end = out.items.len;
        var n = id;
        while (nodes[n].parent != none) : (n = nodes[n].parent) {
            const nm = self.nameOf(n);
            end -= nm.len;
            @memcpy(out.items[end..][0..nm.len], nm);
            if (end > base + root_path.len) {
                end -= 1;
                out.items[end] = '/';
            }
        }
        assert(end == base + root_path.len);
    }

    pub fn total(self: *const Table, id: NodeId) u64 {
        return self.nodes.items[id].total;
    }

    pub fn state(self: *const Table, id: NodeId) State {
        const f = self.flags(id);
        const b = self.below.get(id) orelse Below{};
        if (f.pending or b.pending != 0) return .scanning;
        if (f.denied or b.denied != 0) return .partial;
        return .ok;
    }

    pub fn count(self: *const Table) usize {
        return self.nodes.items.len - self.free_count;
    }

    pub fn memoryBytes(self: *const Table) usize {
        var n = self.nodes.capacity * @sizeOf(Node) + self.names.capacity + self.slots.len * @sizeOf(NodeId);
        n += self.below.capacity() * (@sizeOf(NodeId) + @sizeOf(Below) + 1);
        n += self.root_list.capacity * @sizeOf(Root) + self.scratch.capacity * @sizeOf(NodeId);
        n += self.aux.capacity * @sizeOf(u32) + self.freed.capacity * @sizeOf(Freed);
        for (self.root_list.items) |r| n += r.path.len;
        return n;
    }

    // ---- updates -----------------------------------------------------------------------

    /// The update rule, DESIGN.md section 6 steps 4-7. `child_names` is the complete list of
    /// child folders now on disk. Clears `pending` and `denied` on `id` (the folder was just
    /// confirmed) but not `recheck`: that bit is the scanner's, cleared at dispatch, so an event
    /// that arrived while this read was in flight is not lost. New children are created with
    /// `pending = true`. They are appended to `new_children` together with the kept children that
    /// are still `pending`; the caller must read each of them (a pending child may have been
    /// dropped from the caller's queue after it failed to open). Children no longer on disk are
    /// removed with their whole subtree. `child_names` must not point into this table's name area.
    /// Errors: OutOfMemory, `NameTooLong` (a name over 255 bytes), `TableFull`; the table is
    /// unchanged on error. Returns whether the read changed anything: `own`, the child set, or
    /// a `pending` / `denied` flag (a repeated read of an unchanged folder returns false).
    pub fn applyRead(
        self: *Table,
        id: NodeId,
        own: u64,
        child_names: []const []const u8,
        new_children: *std.ArrayList(NodeId),
        gpa: Allocator,
    ) !bool {
        // Reserve everything first (see file header).
        self.scratch.clearRetainingCapacity();
        try self.scratch.ensureTotalCapacity(self.gpa, child_names.len);
        var fresh: usize = 0;
        var fresh_bytes: usize = 0;
        var waiting: usize = 0;
        for (child_names) |nm| {
            if (nm.len > max_name_len) return error.NameTooLong;
            if (self.child(id, nm)) |c| {
                self.scratch.appendAssumeCapacity(c);
                waiting += @intFromBool(self.flags(c).pending);
            } else {
                fresh += 1;
                fresh_bytes += 1 + nm.len;
            }
        }
        if (fresh != 0) {
            try self.reserveNodes(fresh);
            if (self.names.items.len + fresh_bytes > max_names) self.compactNames();
            if (self.names.items.len + fresh_bytes > max_names) return error.TableFull;
            try self.names.ensureUnusedCapacity(self.gpa, fresh_bytes);
            try self.reserveIndex(fresh);
            try self.below.ensureUnusedCapacity(self.gpa, self.depth(id) + 1);
        }
        try new_children.ensureUnusedCapacity(gpa, fresh + waiting);

        // Drop children that are no longer on disk. Unlinking while walking is O(1) per child.
        // `scratch` holds the kept children, sorted for binary search.
        std.sort.pdq(NodeId, self.scratch.items, {}, std.sort.asc(NodeId));
        var removed: Subtree = .{};
        var gone = false;
        var prev: NodeId = none;
        var c = self.nodes.items[id].first_child;
        while (c != none) {
            const next = self.nodes.items[c].next_sibling;
            if (std.sort.binarySearch(NodeId, self.scratch.items, c, orderIds) != null) {
                prev = c;
            } else {
                if (prev == none) self.nodes.items[id].first_child = next else self.nodes.items[prev].next_sibling = next;
                gone = true;
                const s = self.freeSubtree(c);
                removed.total +%= s.total;
                removed.pending += s.pending;
                removed.denied += s.denied;
            }
            c = next;
        }
        const node = &self.nodes.items[id];
        const delta = (own -% node.own) -% removed.total;
        const own_changed = node.own != own;
        node.own = own;
        self.addTotal(id, delta);
        const f = self.flags(id);
        self.setFlags(id, .{ .recheck = f.recheck });
        for (self.scratch.items) |kept| {
            if (self.flags(kept).pending) new_children.appendAssumeCapacity(kept);
        }

        var created: u32 = 0;
        if (fresh != 0) for (child_names) |nm| {
            if (self.child(id, nm) != null) continue; // kept, or a duplicate of one just created
            const nid = self.allocNode();
            const offset: u32 = @intCast(self.names.items.len);
            self.names.appendAssumeCapacity(@intCast(nm.len));
            self.names.appendSliceAssumeCapacity(nm);
            const nodes = self.nodes.items;
            nodes[nid] = .{
                .total = 0,
                .own = 0,
                .parent = id,
                .first_child = none,
                .next_sibling = nodes[id].first_child,
                .name = packName(offset, .{ .pending = true }),
            };
            nodes[id].first_child = nid;
            self.indexInsert(nid);
            new_children.appendAssumeCapacity(nid);
            created += 1;
        };

        // One pass for the whole change. `id` itself keeps its own flags out of its counters, and
        // clearing them here is why the ancestors see a net `created - 1` for a pending folder:
        // reading a pending folder with one new child (a deep chain) changes nothing above it.
        const self_p: i64 = @intFromBool(f.pending);
        const self_d: i64 = @intFromBool(f.denied);
        const dp = @as(i64, created) - removed.pending - self_p;
        const dd = -@as(i64, removed.denied) - self_d;
        self.shiftOne(id, dp + self_p, dd + self_d);
        self.shiftBelow(node.parent, dp, dd);
        return own_changed or gone or created != 0 or f.pending or f.denied;
    }

    /// The folder could not be read. Keeps its last known value and children, sets `denied` and
    /// clears `pending` (the read was attempted; leaving it set would keep the folder
    /// `scanning` forever). Returns true when a flag changed. Fails only with OutOfMemory (a new
    /// ancestor entry in the side map); the table is then unchanged.
    pub fn applyDenied(self: *Table, id: NodeId) Allocator.Error!bool {
        var f = self.flags(id);
        if (f.denied and !f.pending) return false;
        try self.below.ensureUnusedCapacity(self.gpa, self.depth(id));
        const was_pending: i64 = @intFromBool(f.pending);
        const was_denied: i64 = @intFromBool(f.denied);
        f.pending = false;
        f.denied = true;
        self.setFlags(id, f);
        self.shiftBelow(self.nodes.items[id].parent, -was_pending, 1 - was_denied);
        return true;
    }

    /// Sets `pending` on an existing folder, so its state becomes `scanning` until a read is
    /// applied (`scanSubtree` follows `pending`). Keeps the value and the children. Idempotent.
    /// A re-read that must not change the state is `markRecheck`. Fails only with OutOfMemory;
    /// the table is then unchanged.
    pub fn markPending(self: *Table, id: NodeId) Allocator.Error!void {
        var f = self.flags(id);
        if (f.pending) return;
        try self.below.ensureUnusedCapacity(self.gpa, self.depth(id));
        f.pending = true;
        self.setFlags(id, f);
        self.shiftBelow(self.nodes.items[id].parent, 1, 0);
    }

    /// Owes `id` a re-read without touching its state. Returns true if the bit was clear.
    /// No allocation.
    pub fn markRecheck(self: *Table, id: NodeId) bool {
        var f = self.flags(id);
        if (f.recheck) return false;
        f.recheck = true;
        self.setFlags(id, f);
        return true;
    }

    /// `pending` or `recheck`: the scanner must read this folder.
    pub fn needsRead(self: *const Table, id: NodeId) bool {
        const f = self.flags(id);
        return f.pending or f.recheck;
    }

    /// Clears `recheck`. The scanner calls it when it hands the read to a worker (not when the
    /// result is applied), so a `markRecheck` during the read survives.
    pub fn takeRecheck(self: *Table, id: NodeId) void {
        var f = self.flags(id);
        if (!f.recheck) return;
        f.recheck = false;
        self.setFlags(id, f);
    }

    /// True while `id` itself is waiting for a read. A removed node is never pending.
    pub fn isPending(self: *const Table, id: NodeId) bool {
        return self.flags(id).pending;
    }

    /// True while `id` itself could not be read (not its descendants).
    pub fn isDenied(self: *const Table, id: NodeId) bool {
        return self.flags(id).denied;
    }

    /// `none` for a root.
    pub fn parentOf(self: *const Table, id: NodeId) NodeId {
        return self.nodes.items[id].parent;
    }

    // ---- aux (Linux watch numbers) -------------------------------------------------------

    /// Adds the per-node aux array (all `none`). Idempotent. Without it nothing is allocated.
    pub fn enableAux(self: *Table) Allocator.Error!void {
        if (self.aux_on) return;
        try self.aux.ensureTotalCapacity(self.gpa, self.nodes.items.len);
        try self.freed.ensureTotalCapacity(self.gpa, self.nodes.items.len);
        self.aux.appendNTimesAssumeCapacity(none, self.nodes.items.len);
        self.aux_on = true;
    }

    pub fn setAux(self: *Table, id: NodeId, v: u32) void {
        assert(self.aux_on);
        self.aux.items[id] = v;
    }

    /// `none` when aux is off or the node has no value.
    pub fn getAux(self: *const Table, id: NodeId) u32 {
        return if (self.aux_on) self.aux.items[id] else none;
    }

    // ---- memory and snapshots ------------------------------------------------------------

    /// Gives unused capacity back (ids do not change). Never fails: a shrink that cannot
    /// allocate keeps the old memory. The index shrinks only to a size at <= 70 % load.
    pub fn shrinkToFit(self: *Table) void {
        self.nodes.shrinkAndFree(self.gpa, self.nodes.items.len);
        if (self.dead_names > self.names.items.len - self.dead_names) self.compactNames();
        self.names.shrinkAndFree(self.gpa, self.names.items.len);
        self.scratch.shrinkAndFree(self.gpa, 0);
        if (self.below.count() == 0) {
            self.below.deinit(self.gpa);
            self.below = .empty;
        } else self.below.rehash(std.hash_map.AutoContext(NodeId){}); // drops the tombstones churn left
        if (self.aux_on) {
            self.aux.shrinkAndFree(self.gpa, self.aux.items.len);
            // `freed` must keep room for every node (see `freeSubtree`).
            const keep = @max(self.freed.items.len, self.nodes.items.len);
            if (self.freed.capacity > keep) {
                const len = self.freed.items.len;
                if (self.gpa.remap(self.freed.allocatedSlice(), keep)) |m| {
                    self.freed.items = m[0..len];
                    self.freed.capacity = m.len;
                }
            }
        }
        self.shrinkIndex();
    }

    /// Rewrites the name area without the bytes of freed folders and patches the offsets (one
    /// pass over the nodes; the index holds ids, so it is untouched). Keeps the old area when
    /// the new one cannot be allocated.
    fn compactNames(self: *Table) void {
        if (self.dead_names == 0) return;
        const live = self.names.items.len - self.dead_names;
        const fresh = self.gpa.alloc(u8, live) catch return;
        var w: usize = 0;
        for (self.nodes.items) |*n| {
            if (n.parent == none or n.parent == free_mark) continue;
            const src = self.names.items[n.name & offset_mask ..];
            const len = 1 + @as(usize, src[0]);
            @memcpy(fresh[w..][0..len], src[0..len]);
            n.name = (n.name & ~offset_mask) | @as(u32, @intCast(w));
            w += len;
        }
        assert(w == live);
        self.names.deinit(self.gpa);
        self.names = .{ .items = fresh, .capacity = fresh.len };
        self.dead_names = 0;
    }

    fn shrinkIndex(self: *Table) void {
        if (self.slots.len == 0) return;
        if (self.slots_used == 0) {
            self.gpa.free(self.slots);
            self.slots = &.{};
            return;
        }
        var cap: usize = 16;
        while (self.slots_used * 10 > cap * 7) cap *= 2;
        if (cap >= self.slots.len) return;
        const fresh = self.gpa.alloc(NodeId, cap) catch return;
        @memset(fresh, none);
        const old = self.slots;
        self.slots = fresh;
        self.slots_used = 0;
        for (old) |s| if (s != none) self.indexInsert(s);
        self.gpa.free(old);
    }

    /// Borrowed view of the raw arrays for the snapshot writer.
    pub fn image(self: *const Table) Image {
        return .{
            .nodes = self.nodes.items,
            .names = self.names.items,
            .slots = self.slots,
            .free_head = self.free_head,
            .free_count = self.free_count,
            .roots = self.root_list.items,
        };
    }

    /// Rebuilds a table from arrays that `image` produced earlier. Takes ownership of `nodes`,
    /// `names` and `slots` (all allocated with `gpa`, exactly sized) only on success; on error
    /// the caller still owns them. Root paths are copied. Returns `error.BadImage` when an index
    /// is out of range (parent, child and sibling links, name offsets, index slots, roots), the
    /// free list does not match `free_count`, the index has no empty slot, or a parent chain
    /// loops. It does not check that child lists, parents, the index and the totals agree with
    /// each other, nor hash names: a damaged image that passes gives wrong answers, so the caller
    /// must vouch for the bytes (the snapshot checksum). One linear pass over the nodes rebuilds
    /// the `below` map: only nodes with `pending` or `denied` walk their ancestors.
    pub fn fromImage(
        gpa: Allocator,
        nodes: []Node,
        names: []u8,
        slots: []NodeId,
        free_head: NodeId,
        free_count: usize,
        image_roots: []const Root,
    ) !Table {
        if (nodes.len > max_nodes or names.len > max_names) return error.BadImage;
        if (slots.len != 0 and !std.math.isPowerOfTwo(slots.len)) return error.BadImage;
        if (free_count > nodes.len) return error.BadImage;
        for (image_roots) |r| {
            if (r.node >= nodes.len or nodes[r.node].parent != none) return error.BadImage;
        }
        var used: usize = 0;
        for (slots) |s| {
            if (s == none) continue;
            if (s >= nodes.len or nodes[s].parent >= nodes.len) return error.BadImage; // not a live non-root node
            used += 1;
        }
        if (slots.len != 0 and used == slots.len) return error.BadImage; // a probe for a missing key would never end
        // The free chain: exactly `free_count` nodes, all marked.
        var f = free_head;
        var seen: usize = 0;
        while (f != none) : (f = nodes[f].next_sibling) {
            if (f >= nodes.len or nodes[f].parent != free_mark or seen == free_count) return error.BadImage;
            seen += 1;
        }
        if (seen != free_count) return error.BadImage;

        var t: Table = .{ .gpa = gpa };
        errdefer t.below.deinit(gpa);
        var marked: usize = 0;
        var live_names: usize = 0;
        for (nodes) |n| {
            if (n.parent == free_mark) {
                marked += 1;
                continue;
            }
            if (n.parent != none and n.parent >= nodes.len) return error.BadImage;
            if ((n.first_child != none and n.first_child >= nodes.len) or
                (n.next_sibling != none and n.next_sibling >= nodes.len)) return error.BadImage;
            if (n.parent != none) {
                const off = n.name & offset_mask;
                if (off >= names.len or off + 1 + names[off] > names.len) return error.BadImage;
                live_names += @as(usize, 1) + names[off];
            }
            const fl: Flags = @bitCast(@as(u3, @intCast(n.name >> offset_bits)));
            if (!fl.pending and !fl.denied) continue;
            // The walk is bounded by the node count, so a parent cycle is an error, not a hang.
            var p = n.parent;
            var steps: usize = 0;
            while (p != none) : (p = nodes[p].parent) {
                // Also catches `free_mark`: it is above any valid index.
                if (p >= nodes.len or steps == nodes.len) return error.BadImage;
                steps += 1;
                const gop = try t.below.getOrPut(gpa, p);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.pending += @intFromBool(fl.pending);
                gop.value_ptr.denied += @intFromBool(fl.denied);
            }
        }
        if (marked != free_count) return error.BadImage;

        var list: std.ArrayList(Root) = .empty;
        errdefer {
            for (list.items) |r| gpa.free(r.path);
            list.deinit(gpa);
        }
        try list.ensureTotalCapacity(gpa, image_roots.len);
        for (image_roots) |r| list.appendAssumeCapacity(.{ .path = try gpa.dupe(u8, r.path), .node = r.node });

        t.nodes = .{ .items = nodes, .capacity = nodes.len };
        t.names = .{ .items = names, .capacity = names.len };
        t.dead_names = names.len -| live_names;
        t.root_list = list;
        t.slots = slots;
        t.slots_used = used;
        t.free_head = free_head;
        t.free_count = free_count;
        return t;
    }

    // ---- internals ---------------------------------------------------------------------

    fn orderIds(key: NodeId, item: NodeId) std.math.Order {
        return std.math.order(key, item);
    }

    fn packName(offset: u32, f: Flags) u32 {
        return offset | @as(u32, @as(u3, @bitCast(f))) << offset_bits;
    }

    fn flags(self: *const Table, id: NodeId) Flags {
        return @bitCast(@as(u3, @intCast(self.nodes.items[id].name >> offset_bits)));
    }

    fn setFlags(self: *Table, id: NodeId, f: Flags) void {
        const n = &self.nodes.items[id];
        n.name = packName(n.name & offset_mask, f);
    }

    fn nameOf(self: *const Table, id: NodeId) []const u8 {
        const off = self.nodes.items[id].name & offset_mask;
        return self.names.items[off + 1 ..][0..self.names.items[off]];
    }

    fn hash(parent: NodeId, name_bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(parent, name_bytes);
    }

    fn depth(self: *const Table, id: NodeId) u32 {
        var d: u32 = 0;
        var n = id;
        while (self.nodes.items[n].parent != none) : (n = self.nodes.items[n].parent) d += 1;
        return d;
    }

    fn reserveNodes(self: *Table, n: usize) !void {
        const need = n -| self.free_count;
        if (self.nodes.items.len + need > max_nodes) return error.TableFull;
        try self.nodes.ensureUnusedCapacity(self.gpa, need);
        if (self.aux_on) try self.reserveAux(need);
    }

    /// Keeps `aux` growable with the nodes and `freed` as large as the node count.
    fn reserveAux(self: *Table, need: usize) !void {
        try self.aux.ensureUnusedCapacity(self.gpa, need);
        try self.freed.ensureTotalCapacity(self.gpa, self.nodes.items.len + need);
    }

    /// Needs a prior `reserveNodes`.
    fn allocNode(self: *Table) NodeId {
        if (self.free_head != none) {
            const id = self.free_head;
            self.free_head = self.nodes.items[id].next_sibling;
            self.free_count -= 1;
            return id; // aux of a freed node is already `none`
        }
        const id: NodeId = @intCast(self.nodes.items.len);
        self.nodes.appendAssumeCapacity(undefined);
        if (self.aux_on) self.aux.appendAssumeCapacity(none);
        return id;
    }

    /// Room for `extra` more index entries at <= 70 % load. Grows by doubling; the new array is
    /// allocated before the old one is touched.
    fn reserveIndex(self: *Table, extra: usize) !void {
        const need = self.slots_used + extra;
        if (need * 10 <= self.slots.len * 7) return;
        var cap = @max(16, self.slots.len * 2);
        while (need * 10 > cap * 7) cap *= 2;
        const old = self.slots;
        self.slots = try self.gpa.alloc(NodeId, cap);
        @memset(self.slots, none);
        self.slots_used = 0;
        for (old) |s| if (s != none) self.indexInsert(s);
        self.gpa.free(old);
    }

    fn home(self: *const Table, id: NodeId) usize {
        return @intCast(hash(self.nodes.items[id].parent, self.nameOf(id)) & (self.slots.len - 1));
    }

    /// Needs a prior `reserveIndex`.
    fn indexInsert(self: *Table, id: NodeId) void {
        const mask = self.slots.len - 1;
        var i = self.home(id);
        while (self.slots[i] != none) i = (i + 1) & mask;
        self.slots[i] = id;
        self.slots_used += 1;
    }

    fn indexRemove(self: *Table, id: NodeId) void {
        const mask = self.slots.len - 1;
        var hole = self.home(id);
        while (self.slots[hole] != id) hole = (hole + 1) & mask;
        // Backward shift: pull later entries of the cluster into the hole unless that would
        // move them before their home slot.
        var j = hole;
        while (true) {
            j = (j + 1) & mask;
            const s = self.slots[j];
            if (s == none) break;
            if (((j -% self.home(s)) & mask) >= ((j -% hole) & mask)) {
                self.slots[hole] = s;
                hole = j;
            }
        }
        self.slots[hole] = none;
        self.slots_used -= 1;
    }

    /// Frees `top` and everything below it without recursion: a leaf is always the first child
    /// of its parent when reached, so the traversal needs no stack. The caller has already
    /// unlinked `top` from its parent's child list and fixes the ancestors with the result.
    fn freeSubtree(self: *Table, top: NodeId) Subtree {
        const b = self.below.get(top) orelse Below{};
        const f = self.flags(top);
        const result: Subtree = .{
            .total = self.nodes.items[top].total,
            .pending = b.pending + @intFromBool(f.pending),
            .denied = b.denied + @intFromBool(f.denied),
        };
        const nodes = self.nodes.items;
        var n = top;
        while (true) {
            while (nodes[n].first_child != none) n = nodes[n].first_child;
            const parent = nodes[n].parent;
            if (n != top) nodes[parent].first_child = nodes[n].next_sibling;
            if (parent != none) {
                self.indexRemove(n);
                self.dead_names += 1 + self.nameOf(n).len;
            }
            self.setFlags(n, .{}); // a stale id of a freed node must not look pending
            if (self.below.count() != 0) _ = self.below.remove(n);
            if (self.aux_on and self.aux.items[n] != none) {
                // Capacity was reserved with the nodes; a full list means the owner did not drain.
                assert(self.freed.items.len < self.freed.capacity);
                if (self.freed.items.len < self.freed.capacity) self.freed.appendAssumeCapacity(.{ .id = n, .aux = self.aux.items[n] });
                self.aux.items[n] = none;
            }
            nodes[n].parent = free_mark;
            nodes[n].next_sibling = self.free_head;
            self.free_head = n;
            self.free_count += 1;
            if (n == top) return result;
            n = parent;
        }
    }

    /// Adds `delta` (two's complement for a decrease) to `start` and every ancestor. Sizes wrap:
    /// folders of huge sparse files can sum past 2^64, and a wrong total must not crash.
    fn addTotal(self: *Table, start: NodeId, delta: u64) void {
        if (delta == 0) return;
        const nodes = self.nodes.items;
        var n = start;
        while (n != none) : (n = nodes[n].parent) nodes[n].total +%= delta;
    }

    /// `start` and every ancestor change their flagged-descendant counters by the signed deltas.
    fn shiftBelow(self: *Table, start: NodeId, pending: i64, denied: i64) void {
        if (pending == 0 and denied == 0) return;
        var n = start;
        while (n != none) : (n = self.nodes.items[n].parent) self.shiftOne(n, pending, denied);
    }

    /// Empty entries are dropped. Increases need reserved side-map capacity.
    fn shiftOne(self: *Table, n: NodeId, pending: i64, denied: i64) void {
        if (pending == 0 and denied == 0) return;
        const gop = self.below.getOrPutAssumeCapacity(n);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const e = gop.value_ptr;
        e.pending = @intCast(e.pending + pending);
        e.denied = @intCast(e.denied + denied);
        if (e.pending == 0 and e.denied == 0) _ = self.below.remove(n);
    }
};

// ---- tests -----------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

/// Applies a read with a fresh `new_children` list and returns it through `out`.
fn read(t: *Table, id: NodeId, own: u64, names: []const []const u8, out: *std.ArrayList(NodeId)) !void {
    out.clearRetainingCapacity();
    _ = try t.applyRead(id, own, names, out, ta);
}

fn pathString(t: *const Table, id: NodeId) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(ta);
    try t.pathOf(id, &list, ta);
    return list.toOwnedSlice(ta);
}

/// Removes one folder with its subtree and fixes the ancestors, like `applyRead` of its parent
/// does for every gone child. O(siblings) to unlink: a node has no room for a back link.
fn remove(t: *Table, id: NodeId) void {
    const parent = t.nodes.items[id].parent;
    assert(parent != none);
    var link: *NodeId = &t.nodes.items[parent].first_child;
    while (link.* != id) link = &t.nodes.items[link.*].next_sibling;
    link.* = t.nodes.items[id].next_sibling;
    const s = t.freeSubtree(id);
    t.addTotal(parent, 0 -% s.total);
    t.shiftBelow(parent, -@as(i64, s.pending), -@as(i64, s.denied));
}

/// Full internal consistency check: totals, side maps, index, free list.
fn verify(t: *const Table) !void {
    // An arena: the model test calls this often and the debug allocator's tracing is slow.
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const n = t.nodes.items.len;
    const sum = try a.alloc(u64, n);
    const pend = try a.alloc(u32, n);
    const den = try a.alloc(u32, n);
    @memset(sum, 0);
    @memset(pend, 0);
    @memset(den, 0);

    var order: std.ArrayList(NodeId) = .empty;
    for (t.root_list.items) |r| try order.append(a, r.node);
    var i: usize = 0;
    while (i < order.items.len) : (i += 1) {
        var it = t.children(order.items[i]);
        while (it.next()) |c| {
            try testing.expectEqual(order.items[i], t.nodes.items[c].parent);
            try order.append(a, c);
        }
    }
    try testing.expectEqual(t.count(), order.items.len);
    try testing.expectEqual(order.items.len - t.root_list.items.len, t.slots_used);

    var nonzero: usize = 0;
    var k = order.items.len;
    while (k > 0) {
        k -= 1;
        const id = order.items[k];
        const node = t.nodes.items[id];
        try testing.expectEqual(node.own +% sum[id], node.total);
        const b = t.below.get(id) orelse Below{};
        try testing.expectEqual(pend[id], b.pending);
        try testing.expectEqual(den[id], b.denied);
        if (b.pending != 0 or b.denied != 0) nonzero += 1;
        if (node.parent != none) {
            const f = t.flags(id);
            sum[node.parent] +%= node.total;
            pend[node.parent] += pend[id] + @intFromBool(f.pending);
            den[node.parent] += den[id] + @intFromBool(f.denied);
            try testing.expectEqual(@as(?NodeId, id), t.child(node.parent, t.nameOf(id)));
        }
    }
    try testing.expectEqual(nonzero, t.below.count());

    var live_names: usize = 0;
    for (order.items) |id| {
        if (t.nodes.items[id].parent != none) live_names += 1 + t.nameOf(id).len;
    }
    try testing.expectEqual(t.names.items.len, live_names + t.dead_names);

    var free: usize = 0;
    var f = t.free_head;
    while (f != none) : (f = t.nodes.items[f].next_sibling) {
        free += 1;
        try testing.expectEqual(free_mark, t.nodes.items[f].parent);
        try testing.expectEqual(Flags{}, t.flags(f));
        try testing.expectEqual(none, t.getAux(f));
    }
    try testing.expectEqual(t.free_count, free);
    var marked: usize = 0;
    for (t.nodes.items) |node| marked += @intFromBool(node.parent == free_mark);
    try testing.expectEqual(t.free_count, marked);
    if (t.aux_on) {
        try testing.expectEqual(t.nodes.items.len, t.aux.items.len);
        try testing.expect(t.freed.capacity >= t.nodes.items.len);
    }
}

test "roots: common prefixes, outside paths, names" {
    var t = Table.init(ta);
    defer t.deinit();
    const ab = try t.addRoot("/a/b");
    const abc = try t.addRoot("/a/bc");
    try testing.expectEqual(State.scanning, t.state(ab));
    try testing.expectEqual(@as(usize, 2), t.roots().len);
    try testing.expectEqualStrings("/a/bc", t.name(abc));

    try testing.expectEqual(@as(?NodeId, ab), t.lookup("/a/b"));
    try testing.expectEqual(@as(?NodeId, abc), t.lookup("/a/bc"));
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/a/bcd"));
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/a/b/"));
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/a"));
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/x/y"));
    try testing.expectEqual(@as(?NodeId, null), t.lookup(""));
    try testing.expectError(error.RootExists, t.addRoot("/a/b"));
    try testing.expectError(error.InvalidPath, t.addRoot(""));

    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    const long = "L" ** 255;
    const weird = [_][]const u8{ "with space", "new\nline", "\xff\xfe\x00z", long, "x" };
    try read(&t, ab, 10, &weird, &nc);
    try testing.expectEqual(@as(usize, 5), nc.items.len);
    for (weird) |w| {
        const c = t.child(ab, w).?;
        try testing.expectEqualStrings(w, t.name(c));
        try testing.expectEqual(@as(?NodeId, null), t.child(abc, w));
        const p = try std.fmt.allocPrint(ta, "/a/b/{s}", .{w});
        defer ta.free(p);
        try testing.expectEqual(@as(?NodeId, c), t.lookup(p));
        const back = try pathString(&t, c);
        defer ta.free(back);
        try testing.expectEqualStrings(p, back);
    }
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/a/bc/x"));
    try verify(&t);
}

test "root slash and nested roots" {
    var t = Table.init(ta);
    defer t.deinit();
    const slash = try t.addRoot("/");
    const usr = try t.addRoot("/usr");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, slash, 1, &.{ "usr", "etc" }, &nc);
    try read(&t, usr, 5, &.{"lib"}, &nc);
    const etc = t.child(slash, "etc").?;
    try testing.expectEqual(@as(?NodeId, slash), t.lookup("/"));
    try testing.expectEqual(@as(?NodeId, etc), t.lookup("/etc"));
    try testing.expectEqual(@as(?NodeId, usr), t.lookup("/usr"));
    try testing.expectEqual(@as(?NodeId, nc.items[0]), t.lookup("/usr/lib"));
    const p = try pathString(&t, etc);
    defer ta.free(p);
    try testing.expectEqualStrings("/etc", p);
    // The `usr` child of `/` is shadowed by the root `/usr`, but still a distinct node.
    try testing.expect(t.child(slash, "usr").? != usr);
    try verify(&t);
    t.removeRoot(slash);
    try testing.expectEqual(@as(?NodeId, usr), t.lookup("/usr"));
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/etc"));
    try verify(&t);
}

test "name limit" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 7, &.{ "ok", "N" ** 255 }, &nc);
    const before = t.count();
    try testing.expectError(error.NameTooLong, read(&t, r, 99, &.{ "fine", "N" ** 256 }, &nc));
    try testing.expectEqual(before, t.count());
    try testing.expectEqual(@as(u64, 7), t.total(r));
    try testing.expectEqual(@as(?NodeId, null), t.child(r, "fine"));
    try verify(&t);
}

test "state transitions" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 1, &.{ "a", "b" }, &nc);
    const a = nc.items[0];
    const b = nc.items[1];
    try testing.expectEqual(State.scanning, t.state(r));
    try testing.expectEqual(State.scanning, t.state(a));

    try read(&t, a, 2, &.{"aa"}, &nc);
    const aa = nc.items[0];
    try testing.expectEqual(State.scanning, t.state(a)); // aa pending
    try read(&t, aa, 4, &.{}, &nc);
    try testing.expectEqual(State.ok, t.state(a));
    try testing.expectEqual(State.scanning, t.state(r)); // b pending
    try testing.expectEqual(@as(u64, 6), t.total(a));
    try testing.expectEqual(@as(u64, 7), t.total(r));

    // denied below -> partial all the way up; keeps value
    try read(&t, b, 0, &.{}, &nc);
    try testing.expect(try t.applyDenied(b));
    try testing.expectEqual(State.partial, t.state(b));
    try testing.expectEqual(State.partial, t.state(r));
    try testing.expect(!try t.applyDenied(b)); // idempotent, and says so
    try testing.expectEqual(State.ok, t.state(a));

    // both: pending wins over denied
    try read(&t, a, 2, &.{ "aa", "ab" }, &nc);
    try testing.expectEqual(State.scanning, t.state(r));
    try testing.expectEqual(State.scanning, t.state(a));
    try read(&t, nc.items[0], 0, &.{}, &nc);
    try testing.expectEqual(State.partial, t.state(r));

    // removing the denied descendant clears partial
    remove(&t, b);
    try testing.expectEqual(State.ok, t.state(r));
    try verify(&t);

    // removing a pending descendant clears scanning
    try read(&t, a, 2, &.{ "aa", "ac" }, &nc);
    const ac = nc.items[0];
    try testing.expectEqual(State.scanning, t.state(r));
    remove(&t, ac);
    try testing.expectEqual(State.ok, t.state(r));
    try verify(&t);

    // a re-read clears denied on the folder itself
    _ = try t.applyDenied(a);
    try testing.expectEqual(State.partial, t.state(r));
    try read(&t, a, 2, &.{"aa"}, &nc);
    try testing.expectEqual(State.ok, t.state(r));

    // recheck never changes the state, and a read does not clear it (the scanner does)
    try testing.expect(t.markRecheck(a));
    try testing.expect(!t.markRecheck(a));
    try testing.expect(t.needsRead(a));
    try testing.expectEqual(State.ok, t.state(a));
    try testing.expectEqual(State.ok, t.state(r));
    try testing.expectEqual(@as(usize, 0), t.below.count());
    try read(&t, a, 2, &.{"aa"}, &nc);
    _ = try t.applyDenied(a);
    try testing.expect(t.needsRead(a));
    try testing.expectEqual(State.partial, t.state(a));
    try read(&t, a, 2, &.{"aa"}, &nc);
    try testing.expect(t.flags(a).recheck);
    t.takeRecheck(a);
    t.takeRecheck(a);
    try testing.expect(!t.needsRead(a));
    try testing.expectEqual(State.ok, t.state(a));
    // a freed node has no flags
    try testing.expect(t.markRecheck(t.child(a, "aa").?));
    const aa2 = t.child(a, "aa").?;
    try read(&t, a, 2, &.{}, &nc);
    try testing.expect(!t.needsRead(aa2));
    try verify(&t);
}

test "lookupDeepest" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    const slash = try t.addRoot("/");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 1, &.{"a"}, &nc);
    const a = nc.items[0];
    try read(&t, a, 1, &.{"b"}, &nc);
    const b = nc.items[0];
    try testing.expectEqual(Deepest{ .id = r, .exact = true }, t.lookupDeepest("/r").?);
    try testing.expectEqual(Deepest{ .id = b, .exact = true }, t.lookupDeepest("/r/a/b").?);
    try testing.expectEqual(Deepest{ .id = b, .exact = false }, t.lookupDeepest("/r/a/b/c/d").?);
    try testing.expectEqual(Deepest{ .id = a, .exact = false }, t.lookupDeepest("/r/a/x").?);
    try testing.expectEqual(Deepest{ .id = r, .exact = false }, t.lookupDeepest("/r/zz/a").?);
    try testing.expectEqual(Deepest{ .id = slash, .exact = false }, t.lookupDeepest("/rr/a").?);
    try testing.expectEqual(Deepest{ .id = slash, .exact = true }, t.lookupDeepest("/").?);
    t.removeRoot(slash);
    try testing.expectEqual(@as(?Deepest, null), t.lookupDeepest("/rr/a"));
    try testing.expectEqual(@as(?Deepest, null), t.lookupDeepest(""));
}

test "applyRead is idempotent and handles child list changes" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    const names = [_][]const u8{ "a", "b", "c", "d" };
    try read(&t, r, 3, &names, &nc);
    try testing.expectEqual(@as(usize, 4), nc.items.len);
    for ([_][]const u8{ "a", "b", "c", "d" }) |nm| {
        try read(&t, t.child(r, nm).?, 10, &.{"sub"}, &nc);
        try read(&t, nc.items[0], 5, &.{}, &nc);
    }
    try read(&t, r, 3, &names, &nc);
    const count = t.count();
    const tot = t.total(r);
    try testing.expectEqual(@as(u64, 3 + 4 * 15), tot);
    try read(&t, r, 3, &names, &nc);
    try testing.expectEqual(@as(usize, 0), nc.items.len);
    try testing.expectEqual(count, t.count());
    try testing.expectEqual(tot, t.total(r));
    try testing.expectEqual(State.ok, t.state(r));

    // add e, f; drop b, c in one call
    try read(&t, r, 3, &.{ "a", "d", "e", "f" }, &nc);
    try testing.expectEqual(@as(usize, 2), nc.items.len);
    try testing.expectEqual(@as(?NodeId, null), t.child(r, "b"));
    try testing.expectEqual(@as(?NodeId, null), t.child(r, "c"));
    try testing.expectEqual(@as(u64, 3 + 2 * 15), t.total(r));
    try testing.expectEqual(State.scanning, t.state(r));
    var kids: usize = 0;
    var it = t.children(r);
    while (it.next()) |_| kids += 1;
    try testing.expectEqual(@as(usize, 4), kids);
    try verify(&t);

    // freed node ids are reused; the old name never resolves to it
    // (e and f are still pending, so they are handed out again with the new g)
    try read(&t, r, 3, &.{ "a", "d", "e", "f", "g" }, &nc);
    try testing.expectEqual(@as(usize, 3), nc.items.len);
    try testing.expect(std.mem.indexOfScalar(NodeId, nc.items, t.child(r, "g").?) != null);
    try testing.expectEqual(@as(?NodeId, null), t.child(r, "b"));
    try testing.expectEqualStrings("g", t.name(t.child(r, "g").?));
    try verify(&t);

    // empty list removes all children
    try read(&t, r, 0, &.{}, &nc);
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqual(@as(u64, 0), t.total(r));
    try testing.expectEqual(State.ok, t.state(r));
    try verify(&t);
}

test "remove subtree fixes ancestors and reuses nodes" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 1, &.{"a"}, &nc);
    const a = nc.items[0];
    try read(&t, a, 2, &.{ "b", "c" }, &nc);
    const b = nc.items[0];
    try read(&t, b, 4, &.{"d"}, &nc);
    try testing.expectEqual(@as(u64, 7), t.total(r));
    const peak = t.nodes.items.len;
    remove(&t, a);
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqual(@as(u64, 1), t.total(r));
    try testing.expectEqual(State.ok, t.state(r));
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/r/a"));
    try testing.expectEqual(@as(?NodeId, null), t.lookup("/r/a/b/d"));
    try verify(&t);

    try read(&t, r, 1, &.{"z"}, &nc);
    try read(&t, nc.items[0], 9, &.{ "y", "x", "w" }, &nc);
    try testing.expectEqual(peak, t.nodes.items.len);
    try testing.expectEqual(@as(u64, 10), t.total(r));
    try verify(&t);

    t.removeRoot(r);
    try testing.expectEqual(@as(usize, 0), t.count());
    try testing.expectEqual(@as(usize, 0), t.roots().len);
    try testing.expectEqual(@as(usize, 0), t.slots_used);
    try testing.expectEqual(@as(usize, 0), t.below.count());
    _ = try t.addRoot("/r"); // roots can be re-added after removal
    try verify(&t);
}

test "index grows across several resizes and survives deletes" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    var all: std.ArrayList([]u8) = .empty;
    defer {
        for (all.items) |s| ta.free(s);
        all.deinit(ta);
    }
    var sizes: [4]usize = undefined;
    var step: usize = 0;
    for ([_]usize{ 10, 100, 1000, 6000 }) |n| {
        while (all.items.len < n) try all.append(ta, try std.fmt.allocPrint(ta, "dir{d}", .{all.items.len}));
        try read(&t, r, 0, @ptrCast(all.items), &nc);
        sizes[step] = t.slots.len;
        step += 1;
        for (all.items) |s| try testing.expect(t.child(r, s) != null);
    }
    try testing.expect(sizes[3] > sizes[0] * 8);
    try verify(&t);

    // delete every other child, then the survivors must still resolve (backward shift)
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(ta);
    for (all.items, 0..) |s, i| if (i % 2 == 0) try keep.append(ta, s);
    try read(&t, r, 0, keep.items, &nc);
    for (all.items, 0..) |s, i| try testing.expectEqual(i % 2 == 0, t.child(r, s) != null);
    try verify(&t);
    // and again with the full list
    try read(&t, r, 0, @ptrCast(all.items), &nc);
    try testing.expectEqual(all.items.len, nc.items.len); // every child is pending
    for (all.items) |s| try testing.expect(t.child(r, s) != null);
    try verify(&t);
}

test "deep chain: add and remove without recursion" {
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot("/deep");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    const depth = 10_000;
    var cur = root;
    var first: NodeId = none;
    for (0..depth) |_| {
        try read(&t, cur, 1, &.{"d"}, &nc);
        cur = nc.items[0];
        if (first == none) first = cur;
    }
    try read(&t, cur, 1, &.{}, &nc);
    try testing.expectEqual(@as(usize, depth + 1), t.count());
    try testing.expectEqual(@as(u64, depth + 1), t.total(root));
    try testing.expectEqual(State.ok, t.state(root));

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(ta);
    try path.appendSlice(ta, "/deep");
    for (0..depth) |_| try path.appendSlice(ta, "/d");
    try testing.expectEqual(@as(?NodeId, cur), t.lookup(path.items));
    const back = try pathString(&t, cur);
    defer ta.free(back);
    try testing.expectEqualStrings(path.items, back);

    remove(&t, first);
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqual(@as(u64, 1), t.total(root));
    try testing.expectEqual(@as(usize, 0), t.slots_used);
    try verify(&t);
}

test "chain removal via applyRead of the top folder" {
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot("/deep");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    var cur = root;
    for (0..5000) |_| {
        try read(&t, cur, 2, &.{"d"}, &nc);
        cur = nc.items[0];
    }
    _ = try t.applyDenied(cur);
    try testing.expectEqual(State.partial, t.state(root));
    try read(&t, root, 2, &.{}, &nc);
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqual(State.ok, t.state(root));
    try verify(&t);
}

test "names of freed folders are given back by shrinkToFit" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    const long = "n" ** 100;
    try read(&t, r, 0, &.{ "keep", "also" }, &nc);
    for (0..2000) |_| {
        try read(&t, r, 0, &.{ "keep", "also", long }, &nc);
        try read(&t, r, 0, &.{ "keep", "also" }, &nc);
    }
    try testing.expect(t.names.items.len > 200_000);
    try verify(&t);
    t.shrinkToFit();
    try testing.expectEqual(@as(usize, 5 + 5), t.names.items.len);
    try testing.expectEqual(@as(usize, 0), t.dead_names);
    try testing.expectEqualStrings("also", t.name(t.child(r, "also").?));
    try testing.expectEqualStrings("keep", t.name(t.child(r, "keep").?));
    try testing.expectEqual(@as(?NodeId, null), t.child(r, long));
    try verify(&t);
    try roundTrip(&t);
    try testing.expectEqual(@as(usize, 0), t.dead_names);
    try verify(&t);
}

test "shrinkToFit clears the tombstones of the side map" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 0, &.{"keep"}, &nc);
    // A pending child folder gives its ancestors entries; removing it deletes them again.
    for (0..200) |i| {
        var buf: [16]u8 = undefined;
        const nm = try std.fmt.bufPrint(&buf, "d{d}", .{i});
        try read(&t, r, 0, &.{ "keep", nm }, &nc);
        try read(&t, t.child(r, nm).?, 0, &.{"x"}, &nc);
        try read(&t, r, 0, &.{"keep"}, &nc);
    }
    var tombs: usize = 0;
    for (0..t.below.capacity()) |i| tombs += @intFromBool(t.below.metadata.?[i].isTombstone());
    try testing.expect(tombs > 0);
    t.shrinkToFit();
    tombs = 0;
    for (0..t.below.capacity()) |i| tombs += @intFromBool(t.below.metadata.?[i].isTombstone());
    try testing.expectEqual(@as(usize, 0), tombs);
    try verify(&t);
}

test "totals wrap instead of panicking" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 0, &.{ "a", "b" }, &nc);
    const a = t.child(r, "a").?;
    const b = t.child(r, "b").?;
    try read(&t, a, 1 << 63, &.{}, &nc);
    try read(&t, b, 1 << 63, &.{}, &nc);
    try read(&t, r, std.math.maxInt(u64), &.{ "a", "b" }, &nc);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), t.total(r));
    try read(&t, r, 3, &.{}, &nc); // both children go, together worth 2^64
    try testing.expectEqual(@as(u64, 3), t.total(r));
    try verify(&t);
}

test "denied clears pending, markPending owes a re-read, freed nodes are not pending" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 1, &.{ "a", "b" }, &nc);
    const a = t.child(r, "a").?;
    const b = t.child(r, "b").?;
    try testing.expect(t.isPending(a));
    try testing.expectEqual(none, t.parentOf(r));
    try testing.expectEqual(r, t.parentOf(a));

    // a never-read folder that cannot be read ends `partial`, not `scanning`
    _ = try t.applyDenied(a);
    try testing.expect(!t.isPending(a));
    try testing.expectEqual(State.scanning, t.state(r)); // b is still pending
    try read(&t, b, 2, &.{"bb"}, &nc);
    const bb = nc.items[0];
    try read(&t, bb, 4, &.{}, &nc);
    try testing.expectEqual(State.partial, t.state(r));
    try verify(&t);

    // re-read owed: value and children stay, state goes back to scanning, idempotent
    try t.markPending(bb);
    try t.markPending(bb);
    try testing.expect(t.isPending(bb));
    try testing.expectEqual(State.scanning, t.state(b));
    try testing.expectEqual(State.scanning, t.state(r));
    try testing.expectEqual(@as(u64, 7), t.total(r));
    try verify(&t);
    try read(&t, bb, 5, &.{}, &nc);
    try testing.expectEqual(State.ok, t.state(b));
    try testing.expectEqual(State.partial, t.state(r));
    try verify(&t);

    // a pending denied folder (re-read owed) that is denied again drops back to partial
    try t.markPending(a);
    try testing.expectEqual(State.scanning, t.state(a));
    _ = try t.applyDenied(a);
    try testing.expectEqual(State.partial, t.state(a));
    try verify(&t);

    // a removed pending node does not look pending through a stale id
    try t.markPending(bb);
    try read(&t, r, 1, &.{"a"}, &nc);
    try testing.expect(!t.isPending(b));
    try testing.expect(!t.isPending(bb));
    try verify(&t);
}

test "pathOf appends" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try read(&t, r, 0, &.{"x"}, &nc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try out.appendSlice(ta, ">");
    try t.pathOf(nc.items[0], &out, ta);
    try t.pathOf(r, &out, ta);
    try testing.expectEqualStrings(">/r/x/r", out.items);
}

test "size: 32-byte node and bytes per folder" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(Node));

    var t = Table.init(ta);
    defer t.deinit();
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    const target = 100_000;
    const root = try t.addRoot("/big");
    var frontier: std.ArrayList(NodeId) = .empty;
    defer frontier.deinit(ta);
    var next: std.ArrayList(NodeId) = .empty;
    defer next.deinit(ta);
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try frontier.append(ta, root);
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ta);
    while (t.count() < target) {
        next.clearRetainingCapacity();
        for (frontier.items) |id| {
            if (t.count() >= target) break;
            names.clearRetainingCapacity();
            for (0..10) |i| {
                const len = r.intRangeAtMost(usize, 4, 20); // mean 12
                const nm = try arena.allocator().alloc(u8, len);
                for (nm) |*ch| ch.* = 'a' + r.uintLessThan(u8, 26);
                nm[0] = '0' + @as(u8, @intCast(i)); // unique within a folder
                try names.append(ta, nm);
            }
            try read(&t, id, 1000, names.items, &nc);
            try next.appendSlice(ta, nc.items);
        }
        std.mem.swap(std.ArrayList(NodeId), &frontier, &next);
        _ = arena.reset(.retain_capacity);
    }
    try testing.expect(t.memoryBytes() / t.count() < 80);
}

// ---- randomized model test -------------------------------------------------------------

/// Naive reference: a tree of heap nodes with recursive totals and states.
const Model = struct {
    const M = struct {
        name: []const u8, // a root's name is its full path
        own: u64 = 0,
        pending: bool = true,
        denied: bool = false,
        recheck: bool = false,
        aux: u32 = none,
        id: NodeId = none,
        parent: ?*M = null,
        kids: std.ArrayList(*M) = .empty,
    };

    arena: std.heap.ArenaAllocator,
    roots: std.ArrayList(*M) = .empty,

    fn a(self: *Model) Allocator {
        return self.arena.allocator();
    }

    fn total(m: *const M) u64 {
        var s = m.own;
        for (m.kids.items) |k| s += total(k);
        return s;
    }

    fn any(m: *const M, comptime field: []const u8) bool {
        if (@field(m, field)) return true;
        for (m.kids.items) |k| if (any(k, field)) return true;
        return false;
    }

    fn state(m: *const M) State {
        if (any(m, "pending")) return .scanning;
        if (any(m, "denied")) return .partial;
        return .ok;
    }

    fn path(self: *Model, m: *const M) ![]u8 {
        var parts: std.ArrayList(*const M) = .empty;
        var p: ?*const M = m;
        while (p) |x| : (p = x.parent) try parts.append(self.a(), x);
        var out: std.ArrayList(u8) = .empty;
        var i = parts.items.len;
        while (i > 0) {
            i -= 1;
            if (i + 1 != parts.items.len) try out.append(self.a(), '/');
            try out.appendSlice(self.a(), parts.items[i].name);
        }
        return out.items;
    }

    fn kid(m: *const M, nm: []const u8) ?*M {
        for (m.kids.items) |k| if (std.mem.eql(u8, k.name, nm)) return k;
        return null;
    }

    /// The same resolution rule as Table.lookup, written the obvious way.
    fn lookup(self: *Model, p: []const u8) ?*M {
        var best: ?*M = null;
        for (self.roots.items) |r| {
            if (!std.mem.startsWith(u8, p, r.name)) continue;
            if (p.len != r.name.len and p[r.name.len] != '/') continue;
            if (best == null or r.name.len > best.?.name.len) best = r;
        }
        var cur = best orelse return null;
        var rest = p[cur.name.len..];
        while (rest.len != 0) {
            rest = rest[1..];
            const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            cur = kid(cur, rest[0..end]) orelse return null;
            rest = rest[end..];
        }
        return cur;
    }

    /// The same rule as Table.lookupDeepest: the last node that resolved.
    fn deepest(self: *Model, p: []const u8) ?struct { m: *M, exact: bool } {
        var best: ?*M = null;
        for (self.roots.items) |r| {
            if (!std.mem.startsWith(u8, p, r.name)) continue;
            if (p.len != r.name.len and p[r.name.len] != '/') continue;
            if (best == null or r.name.len > best.?.name.len) best = r;
        }
        var cur = best orelse return null;
        var rest = p[cur.name.len..];
        while (rest.len != 0) {
            rest = rest[1..];
            const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            cur = kid(cur, rest[0..end]) orelse return .{ .m = cur, .exact = false };
            rest = rest[end..];
        }
        return .{ .m = cur, .exact = true };
    }

    /// Every node of the subtree with an aux value, as the table must report it when it frees it.
    fn noteFreed(m: *M, out: *std.ArrayList(Freed), gpa: Allocator) !void {
        if (m.aux != none) try out.append(gpa, .{ .id = m.id, .aux = m.aux });
        for (m.kids.items) |k| try noteFreed(k, out, gpa);
    }

    fn all(self: *Model, out: *std.ArrayList(*M)) !void {
        out.clearRetainingCapacity();
        for (self.roots.items) |r| try out.append(self.a(), r);
        var i: usize = 0;
        while (i < out.items.len) : (i += 1) try out.appendSlice(self.a(), out.items[i].kids.items);
    }
};

const pool = [_][]const u8{
    "a", "b", "c", "ab", "a b", "x\ny", "\xff\xfe", "d", "e", "f", "g", "h", "L" ** 255,
};
const root_paths = [_][]const u8{ "/r", "/r/a", "/ra", "/s t\n", "/r/a/b", "/q" };

fn checkNode(t: *const Table, model: *Model, m: *Model.M) !void {
    const id = m.id;
    try testing.expectEqual(Model.total(m), t.total(id));
    try testing.expectEqual(Model.state(m), t.state(id));
    try testing.expectEqualStrings(m.name, t.name(id));
    var n: usize = 0;
    var it = t.children(id);
    while (it.next()) |c| {
        n += 1;
        const mk = Model.kid(m, t.name(c)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(mk.id, c);
    }
    try testing.expectEqual(m.kids.items.len, n);
    const p = try model.path(m);
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var back: std.ArrayList(u8) = .empty;
    try t.pathOf(id, &back, fba.allocator());
    try testing.expectEqualStrings(p, back.items);
    const want: ?NodeId = if (model.lookup(p)) |x| x.id else null;
    try testing.expectEqual(want, t.lookup(p));
    try testing.expectEqual(m.recheck, t.flags(id).recheck);
    try testing.expectEqual(m.pending or m.recheck, t.needsRead(id));
    try testing.expectEqual(m.aux, t.getAux(id));
    // A nested root can shadow this node's own path, so ask the model, not `id`.
    const dp = model.deepest(p).?;
    try testing.expectEqual(Deepest{ .id = dp.m.id, .exact = dp.exact }, t.lookupDeepest(p).?);
    var longer: std.ArrayList(u8) = .empty;
    try longer.appendSlice(model.a(), p);
    try longer.appendSlice(model.a(), "/zz/q");
    const dm = model.deepest(longer.items).?;
    try testing.expectEqual(Deepest{ .id = dm.m.id, .exact = dm.exact }, t.lookupDeepest(longer.items).?);
}

fn checkAll(t: *const Table, model: *Model, list: *std.ArrayList(*Model.M)) !void {
    try model.all(list);
    try testing.expectEqual(list.items.len, t.count());
    for (list.items) |m| try checkNode(t, model, m);
    try verify(t);
}

fn freedLess(_: void, a: Freed, b: Freed) bool {
    return a.id < b.id;
}

/// The table's drained `freed` list must hold exactly what the model says was freed with an aux
/// value; both are cleared.
fn expectFreed(t: *Table, expected: *std.ArrayList(Freed)) !void {
    std.mem.sort(Freed, t.freed.items, {}, freedLess);
    std.mem.sort(Freed, expected.items, {}, freedLess);
    try testing.expectEqual(expected.items.len, t.freed.items.len);
    for (expected.items, t.freed.items) |e, g| try testing.expectEqual(e, g);
    t.freed.clearRetainingCapacity();
    expected.clearRetainingCapacity();
}

/// Replaces `t` by a table rebuilt from a copy of its image. Aux values do not survive.
fn roundTrip(t: *Table) !void {
    const img = t.image();
    const nodes = try ta.dupe(Node, img.nodes);
    errdefer ta.free(nodes);
    const names = try ta.dupe(u8, img.names);
    errdefer ta.free(names);
    const slots = try ta.dupe(NodeId, img.slots);
    errdefer ta.free(slots);
    var fresh = try Table.fromImage(ta, nodes, names, slots, img.free_head, img.free_count, img.roots);
    errdefer fresh.deinit();
    const had_aux = t.aux_on;
    t.deinit();
    t.* = fresh;
    if (had_aux) try t.enableAux();
}

fn runModel(seed: u64, steps: usize, aux: bool) !void {
    var t = Table.init(ta);
    defer t.deinit();
    var model: Model = .{ .arena = .init(ta) };
    defer model.arena.deinit();
    const ma = model.a();
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var list: std.ArrayList(*Model.M) = .empty;
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ta);
    var expected: std.ArrayList(Freed) = .empty;
    defer expected.deinit(ta);

    for (0..steps) |step| {
        if (aux and step == 50) try t.enableAux();
        try model.all(&list);
        const op = rnd.uintLessThan(u8, 100);
        if (list.items.len == 0 or op < 4) {
            const p = root_paths[rnd.uintLessThan(usize, root_paths.len)];
            const exists = for (model.roots.items) |r| {
                if (std.mem.eql(u8, r.name, p)) break true;
            } else false;
            if (exists) {
                try testing.expectError(error.RootExists, t.addRoot(p));
            } else {
                const m = try ma.create(Model.M);
                m.* = .{ .name = p, .id = try t.addRoot(p) };
                try model.roots.append(ma, m);
            }
        } else if (op < 8) {
            const ri = rnd.uintLessThan(usize, model.roots.items.len);
            try Model.noteFreed(model.roots.items[ri], &expected, ta);
            t.removeRoot(model.roots.items[ri].id);
            _ = model.roots.orderedRemove(ri);
        } else if (op < 16) {
            const m = list.items[rnd.uintLessThan(usize, list.items.len)];
            if (m.parent != null) {
                try Model.noteFreed(m, &expected, ta);
                remove(&t, m.id);
                const siblings = &m.parent.?.kids;
                for (siblings.items, 0..) |k, i| if (k == m) {
                    _ = siblings.orderedRemove(i);
                    break;
                };
            }
        } else if (op < 24) {
            const m = list.items[rnd.uintLessThan(usize, list.items.len)];
            _ = try t.applyDenied(m.id);
            m.denied = true;
            m.pending = false;
        } else if (op < 28) {
            const m = list.items[rnd.uintLessThan(usize, list.items.len)];
            if (rnd.boolean()) {
                try testing.expectEqual(!m.recheck, t.markRecheck(m.id));
                m.recheck = true;
            } else {
                t.takeRecheck(m.id);
                m.recheck = false;
            }
        } else if (op < 31) {
            // lookup of random paths: outside roots, prefixes, removed nodes
            for (0..8) |_| {
                var p: std.ArrayList(u8) = .empty;
                if (rnd.boolean()) {
                    try p.appendSlice(ma, root_paths[rnd.uintLessThan(usize, root_paths.len)]);
                } else {
                    try p.appendSlice(ma, "/zz");
                }
                for (0..rnd.uintLessThan(usize, 4)) |_| {
                    try p.append(ma, '/');
                    try p.appendSlice(ma, pool[rnd.uintLessThan(usize, pool.len)]);
                }
                const want: ?NodeId = if (model.lookup(p.items)) |x| x.id else null;
                try testing.expectEqual(want, t.lookup(p.items));
                const got = t.lookupDeepest(p.items);
                if (model.deepest(p.items)) |d| {
                    try testing.expectEqual(Deepest{ .id = d.m.id, .exact = d.exact }, got.?);
                    try testing.expectEqual(want != null, d.exact);
                } else try testing.expectEqual(@as(?Deepest, null), got);
            }
        } else if (op < 34) {
            if (t.aux_on) {
                const m = list.items[rnd.uintLessThan(usize, list.items.len)];
                m.aux = if (rnd.boolean()) none else rnd.uintLessThan(u32, 1000);
                t.setAux(m.id, m.aux);
            }
        } else if (op < 35) {
            t.shrinkToFit();
            try testing.expectEqual(t.nodes.items.len, t.nodes.capacity);
            try testing.expectEqual(t.names.items.len, t.names.capacity);
            try testing.expect(t.slots.len == 0 or t.slots_used * 10 <= t.slots.len * 7);
            if (t.below.count() == 0) try testing.expectEqual(@as(u32, 0), t.below.capacity());
            try model.all(&list);
            try checkAll(&t, &model, &list);
        } else if (op < 36) {
            try roundTrip(&t);
            for (list.items) |m| m.aux = none;
            try model.all(&list);
            try checkAll(&t, &model, &list);
        } else {
            const m = list.items[rnd.uintLessThan(usize, list.items.len)];
            names.clearRetainingCapacity();
            for (m.kids.items) |k| if (rnd.uintLessThan(u8, 10) < 7) try names.append(ta, k.name);
            var depth: usize = 0;
            var p = m.parent;
            while (p) |x| : (p = x.parent) depth += 1;
            if (depth < 5 and list.items.len < 150) for (0..rnd.uintLessThan(usize, 5)) |_| {
                const nm = pool[rnd.uintLessThan(usize, pool.len)];
                const dup = for (names.items) |e| {
                    if (std.mem.eql(u8, e, nm)) break true;
                } else false;
                if (!dup) try names.append(ta, nm);
            };
            rnd.shuffle([]const u8, names.items);
            const own: u64 = if (rnd.uintLessThan(u8, 4) == 0) m.own else rnd.uintLessThan(u64, 5000);

            var owed: usize = 0; // new children and kept ones that are still pending
            var kept: std.ArrayList(*Model.M) = .empty;
            for (names.items) |nm| {
                if (Model.kid(m, nm)) |k| {
                    try kept.append(ma, k);
                    owed += @intFromBool(k.pending);
                } else {
                    const k = try ma.create(Model.M);
                    k.* = .{ .name = nm, .parent = m };
                    try kept.append(ma, k);
                    owed += 1;
                }
            }
            for (m.kids.items) |k| {
                if (std.mem.indexOfScalar(*Model.M, kept.items, k) == null) try Model.noteFreed(k, &expected, ta);
            }
            nc.clearRetainingCapacity();
            _ = try t.applyRead(m.id, own, names.items, &nc, ta);
            try testing.expectEqual(owed, nc.items.len);
            m.kids = kept;
            m.own = own;
            m.pending = false;
            m.denied = false;
            for (m.kids.items) |k| {
                k.id = t.child(m.id, k.name) orelse return error.TestUnexpectedResult;
                try testing.expectEqual(m.id, t.nodes.items[k.id].parent);
            }
            for (nc.items) |c| try testing.expect(t.flags(c).pending);
        }

        try expectFreed(&t, &expected);
        try model.all(&list);
        if (step % 20 == 0) {
            try checkAll(&t, &model, &list);
        } else if (list.items.len != 0) {
            try testing.expectEqual(list.items.len, t.count());
            for (0..3) |_| try checkNode(&t, &model, list.items[rnd.uintLessThan(usize, list.items.len)]);
        }
    }
    try checkAll(&t, &model, &list);
}

test "model: randomized operations against a naive tree" {
    for ([_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 0xdeadbeef, 12345 }) |seed| try runModel(seed, 4000, seed % 2 == 0);
}

test "allocation failure leaves the table consistent" {
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(ta, .{ .fail_index = fail_at });
        const gpa = fa.allocator();
        var t = Table.init(gpa);
        defer t.deinit();
        var nc: std.ArrayList(NodeId) = .empty;
        defer nc.deinit(gpa);
        const failed = blk: {
            script(&t, &nc, gpa) catch |e| {
                try testing.expectEqual(error.OutOfMemory, e);
                break :blk true;
            };
            break :blk false;
        };
        try verify(&t);
        if (!failed) break;
    }
}

/// Every step is tried again after a failure by the caller sweeping `fail_at`, so each failure
/// point is hit in some run.
fn script(t: *Table, nc: *std.ArrayList(NodeId), gpa: Allocator) !void {
    const r = try t.addRoot("/r");
    _ = try t.applyRead(r, 5, &.{ "a", "b", "c" }, nc, gpa);
    const a = t.child(r, "a").?;
    const b = t.child(r, "b").?;
    try t.enableAux();
    t.setAux(a, 5);
    var many: [40][2]u8 = undefined;
    var slices: [40][]const u8 = undefined;
    for (&many, &slices, 0..) |*m, *s, i| {
        m.* = .{ 'k', 'a' + @as(u8, @intCast(i % 26)) };
        s.* = m;
    }
    _ = try t.applyRead(a, 1, slices[0..26], nc, gpa);
    _ = try t.applyDenied(t.child(a, "ka").?);
    _ = try t.applyRead(b, 2, &.{ "x", "y" }, nc, gpa);
    _ = try t.applyDenied(b);
    _ = try t.applyRead(a, 3, slices[5..10], nc, gpa);
    _ = try t.applyRead(r, 5, &.{ "a", "b" }, nc, gpa);
    remove(t, t.child(r, "b").?);
}

// ---- aux, shrink, image ----------------------------------------------------------------

/// A small tree: /r -> a, b; a -> x, y (x and y pending); b denied.
fn smallTree(t: *Table) !void {
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    const r = try t.addRoot("/r");
    try read(t, r, 5, &.{ "a", "b" }, &nc);
    try read(t, t.child(r, "a").?, 7, &.{ "x", "y" }, &nc);
    try read(t, t.child(r, "b").?, 1, &.{"z"}, &nc);
    try read(t, t.child(t.child(r, "b").?, "z").?, 2, &.{}, &nc);
    _ = try t.applyDenied(t.child(r, "b").?);
    _ = t.markRecheck(r);
}

test "aux: freeing records watch numbers and never allocates" {
    var fa = std.testing.FailingAllocator.init(ta, .{});
    const gpa = fa.allocator();
    var t = Table.init(gpa);
    defer t.deinit();
    try smallTree(&t);
    try testing.expectEqual(none, t.getAux(0)); // off: reads as none, nothing allocated
    try testing.expectEqual(@as(usize, 0), t.aux.capacity);
    try t.enableAux();
    try t.enableAux();
    const r = t.lookup("/r").?;
    const a = t.child(r, "a").?;
    const b = t.child(r, "b").?;
    const x = t.child(a, "x").?;
    t.setAux(r, 1);
    t.setAux(a, 2);
    t.setAux(x, 3);
    t.setAux(b, 4);
    try verify(&t);
    try testing.expect(t.memoryBytes() > 0);

    // From here on every allocation fails: removal must still work.
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;
    remove(&t, a);
    try testing.expectEqual(@as(usize, 2), t.freed.items.len);
    try testing.expectEqual(none, t.getAux(a));
    var seen: u32 = 0;
    for (t.freed.items) |fr| seen |= @as(u32, 1) << @intCast(fr.aux);
    try testing.expectEqual(@as(u32, 0b1100), seen);
    t.freed.clearRetainingCapacity();
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    _ = try t.applyRead(r, 5, &.{}, &nc, ta); // drops b with its aux
    try testing.expectEqual(@as(usize, 1), t.freed.items.len);
    try testing.expectEqual(Freed{ .id = b, .aux = 4 }, t.freed.items[0]);
    t.freed.clearRetainingCapacity();
    t.removeRoot(r);
    try testing.expectEqual(@as(usize, 1), t.freed.items.len);
    try testing.expectEqual(@as(u32, 1), t.freed.items[0].aux);
    try verify(&t);

    // A reused id starts without aux.
    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);
    const r2 = try t.addRoot("/q");
    try testing.expectEqual(none, t.getAux(r2));
    try verify(&t);
}

test "shrinkToFit releases capacity, keeps ids, survives failing allocations" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    var all: std.ArrayList([]u8) = .empty;
    defer {
        for (all.items) |s| ta.free(s);
        all.deinit(ta);
    }
    for (0..3000) |i| try all.append(ta, try std.fmt.allocPrint(ta, "dir{d}", .{i}));
    try read(&t, r, 0, @ptrCast(all.items), &nc);
    var it = t.children(r);
    var scratch: std.ArrayList(NodeId) = .empty;
    defer scratch.deinit(ta);
    while (it.next()) |c| try read(&t, c, 1, &.{}, &scratch);
    const big_slots = t.slots.len;
    const before = t.memoryBytes();
    try read(&t, r, 0, @ptrCast(all.items[0..50]), &nc);
    const keep = t.child(r, "dir7").?;
    t.shrinkToFit();
    try testing.expect(t.slots.len < big_slots);
    try testing.expect(t.slots_used * 10 <= t.slots.len * 7);
    try testing.expect(t.memoryBytes() < before);
    try testing.expectEqual(@as(?NodeId, keep), t.child(r, "dir7"));
    try testing.expectEqual(@as(?NodeId, null), t.child(r, "dir77"));
    try verify(&t);
    t.shrinkToFit(); // again: nothing to do
    try verify(&t);
    // The shrunk table still grows.
    try read(&t, r, 0, @ptrCast(all.items), &nc);
    try testing.expectEqual(@as(usize, 2950), nc.items.len);
    try verify(&t);

    // Failing allocations: shrink gives up quietly.
    var fa = std.testing.FailingAllocator.init(ta, .{});
    var t2 = Table.init(fa.allocator());
    defer t2.deinit();
    try smallTree(&t2);
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;
    t2.shrinkToFit();
    try verify(&t2);
}

/// Owned copies of a table's arrays, as a snapshot loader would allocate them.
const Copy = struct {
    nodes: []Node,
    names: []u8,
    slots: []NodeId,

    fn of(t: *const Table) !Copy {
        const img = t.image();
        const nodes = try ta.dupe(Node, img.nodes);
        errdefer ta.free(nodes);
        const names = try ta.dupe(u8, img.names);
        errdefer ta.free(names);
        return .{ .nodes = nodes, .names = names, .slots = try ta.dupe(NodeId, img.slots) };
    }

    fn free(c: Copy) void {
        ta.free(c.nodes);
        ta.free(c.names);
        ta.free(c.slots);
    }

    fn load(c: Copy, t: *const Table) !Table {
        const img = t.image();
        return Table.fromImage(ta, c.nodes, c.names, c.slots, img.free_head, img.free_count, img.roots);
    }
};

test "fromImage: round trip keeps totals, states and flags; bad images are errors" {
    var t = Table.init(ta);
    defer t.deinit();
    try smallTree(&t);
    const r = t.lookup("/r").?;
    remove(&t, t.lookup("/r/b/z").?); // leaves a free node
    try testing.expect(t.free_count != 0);

    // The good image.
    const c = try Copy.of(&t);
    var u = try c.load(&t);
    defer u.deinit(); // owns the copy now
    try testing.expectEqual(t.total(r), u.total(r));
    try testing.expectEqual(t.state(r), u.state(r));
    try testing.expectEqual(State.scanning, u.state(r));
    try testing.expectEqual(t.below.count(), u.below.count());
    try testing.expect(u.flags(r).recheck);
    try testing.expectEqual(t.lookup("/r/a/y"), u.lookup("/r/a/y"));
    try testing.expectEqual(t.slots_used, u.slots_used);
    try verify(&u);

    // Bad images: every one must come back as BadImage and leave the arrays to the caller.
    const Case = enum { slots_len, root_range, root_parent, free_count, free_chain, full_index, slot_range, parent_range, name_range, child_range, cycle };
    inline for (@typeInfo(Case).@"enum".fields) |fld| {
        const bad = try Copy.of(&t);
        defer bad.free();
        var slots = bad.slots;
        var free_count = t.free_count;
        var roots_node = r;
        var scratch_slots: ?[]NodeId = null;
        defer if (scratch_slots) |ss| ta.free(ss);
        switch (@field(Case, fld.name)) {
            .slots_len => slots = slots[0 .. slots.len - 1],
            .root_range => roots_node = @intCast(bad.nodes.len),
            .root_parent => roots_node = t.lookup("/r/a").?,
            .free_count => free_count += 1,
            .free_chain => bad.nodes[t.free_head].parent = 0,
            .full_index => {
                scratch_slots = try ta.alloc(NodeId, 4);
                @memset(scratch_slots.?, t.lookup("/r/a").?);
                slots = scratch_slots.?;
            },
            .slot_range => {
                for (slots) |*s| if (s.* != none) {
                    s.* = @intCast(bad.nodes.len + 5);
                    break;
                };
            },
            .parent_range => bad.nodes[t.lookup("/r/a/x").?].parent = @intCast(bad.nodes.len + 1),
            .name_range => bad.nodes[t.lookup("/r/a/x").?].name = @intCast(bad.names.len + 9),
            .child_range => bad.nodes[r].first_child = @intCast(bad.nodes.len + 3),
            .cycle => {
                // x is pending: point a's parent at x, so the walk from x never reaches a root.
                bad.nodes[t.lookup("/r/a").?].parent = t.lookup("/r/a/x").?;
            },
        }
        const img = t.image();
        var roots = [_]Root{.{ .path = "/r", .node = roots_node }};
        try testing.expectError(error.BadImage, Table.fromImage(ta, bad.nodes, bad.names, slots, img.free_head, free_count, &roots));
    }
}

test "fromImage: allocation failure leaves the arrays to the caller" {
    var t = Table.init(ta);
    defer t.deinit();
    try smallTree(&t);
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(ta, .{ .fail_index = fail_at });
        const c = try Copy.of(&t);
        const img = t.image();
        var u = Table.fromImage(fa.allocator(), c.nodes, c.names, c.slots, img.free_head, img.free_count, img.roots) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            c.free();
            continue;
        };
        try verify(&u);
        u.deinit();
        break;
    }
}

test "applyRead says whether the read changed the table" {
    var t = Table.init(ta);
    defer t.deinit();
    const r = try t.addRoot("/r");
    var nc: std.ArrayList(NodeId) = .empty;
    defer nc.deinit(ta);
    try testing.expect(try t.applyRead(r, 0, &.{}, &nc, ta)); // pending cleared
    try testing.expect(!try t.applyRead(r, 0, &.{}, &nc, ta));
    try testing.expect(try t.applyRead(r, 5, &.{}, &nc, ta)); // own
    try testing.expect(try t.applyRead(r, 5, &.{"a"}, &nc, ta)); // child added
    try testing.expect(try t.applyRead(t.child(r, "a").?, 0, &.{}, &nc, ta));
    try testing.expect(!try t.applyRead(r, 5, &.{"a"}, &nc, ta));
    try testing.expect(try t.applyRead(r, 5, &.{"b"}, &nc, ta)); // renamed: same count, other name
    try testing.expect(try t.applyRead(r, 5, &.{}, &nc, ta)); // child dropped
}
