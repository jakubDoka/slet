const std = @import("std");
const debug = @import("builtin").mode == .Debug;
const BuddyAllocator = @import("buddy.zig").BuddyAllocator;

const QuadTree = @This();

const Vec = @Vector(4, i32);

const Slices = BuddyAllocator(u64, std.math.maxInt(u64), 32, 1);

const Pos = [2]i32;

const Quad = struct {
    meta: packed struct(u32) {
        depth: u5 = 0,
        total: u27 = 0,
    } = .{},
    pos: Pos = .{ 0, 0 },
    parent: Id = invalid_id,
    children: Id = invalid_id,
    ents: @TypeOf(default_ents) = default_ents,
    ent_base: @TypeOf(default_base) = default_base,
    count: @TypeOf(default_int) = default_int,
    cap: @TypeOf(default_int) = default_int,

    const default_ents = if (use_allocator) std.ArrayListUnmanaged(Slices.Elem){};
    const default_int = if (!use_allocator) @as(u32, 0);
    const default_base = if (!use_allocator) @as(Slices.Index, 0);

    const use_allocator = false;

    inline fn entCount(self: Quad) usize {
        return if (use_allocator) self.ents.items.len else self.count;
    }

    inline fn entities(self: Quad, slices: Slices) []Slices.Elem {
        return if (use_allocator) self.ents.items else slices.mem[self.ent_base..][0..self.count];
    }

    fn pushEntity(self: *Quad, slices: *Slices, gpa: std.mem.Allocator, id: Slices.Elem) !void {
        if (use_allocator) {
            try self.ents.append(gpa, id);
        } else {
            if (self.count == 0) {
                self.cap = 2;
                self.ent_base = try slices.alloc(gpa, self.cap);
                slices.mem[self.ent_base] = id;
                self.count += 1;
                return;
            }

            if (self.count == @max(ceil(self.count), 2)) {
                if (!slices.grow(self.ent_base, self.count)) {
                    self.cap = self.count * 2;
                    const new = try slices.alloc(gpa, self.cap);
                    @memcpy(slices.mem[new..][0..self.count], slices.mem[self.ent_base..][0..self.count]);
                    slices.free(self.ent_base, ceil(self.count));
                    self.ent_base = new;
                }
            }

            slices.mem[self.ent_base + self.count] = id;
            self.count += 1;
        }
    }

    fn popEntity(self: *Quad, slices: *Slices, gpa: std.mem.Allocator) Slices.Elem {
        _ = gpa; // autofix
        if (use_allocator) {
            //defer if (self.ents.items.len == @max(self.ents.capacity / 2, 2))
            //    self.ents.shrinkAndFree(gpa, self.ents.items.len);
            return self.ents.pop();
        } else {
            std.debug.assert(self.count != 0);

            const value = slices.mem[self.ent_base + self.count - 1];

            if (self.count == 1) {
                slices.free(self.ent_base, self.cap);
                self.cap = 0;
                self.ent_base = 0;
            } else if (self.count - 1 == @max(self.cap / 2, 2)) {
                slices.shrink(self.ent_base, self.cap);
                self.cap /= 2;
            }
            self.count -= 1;

            return value;
        }
    }

    inline fn ceil(len: u32) u32 {
        return std.math.ceilPowerOfTwo(u32, len) catch unreachable;
    }
};

const FindResult = struct {
    id: Id,
    index: ?u4,
};

pub const Id = u32;

pub const quad_limit = 8; // exactly fills a size class
pub const invalid_id = std.math.maxInt(Id);

quads: std.ArrayListUnmanaged(Quad) = .{},
slices: Slices = .{},
free: Id = invalid_id,
radius: i32,
total_cache_count: usize = 0,
total_updates: usize = 0,

pub fn init(alc: std.mem.Allocator, radius: u5) !QuadTree {
    var self = QuadTree{ .radius = @as(i32, 1) << radius };
    try self.quads.append(alc, .{});
    return self;
}

pub fn deinit(self: *QuadTree, alc: std.mem.Allocator) void {
    if (Quad.use_allocator) {
        var iter = self.queryIter(.{ -self.radius, -self.radius, self.radius, self.radius }, 0);
        while (iter.next()) |id| self.quads.items[id].ents.deinit(alc);
    } else if (debug) {
        var iter = self.queryIter(.{ -self.radius, -self.radius, self.radius, self.radius }, 0);
        while (iter.next()) |id| if (self.quads.items[id].count != 0) self.slices.free(self.quads.items[id].ent_base, self.quads.items[id].cap);
    }
    self.quads.deinit(alc);
    self.slices.deinit(alc);
    self.* = undefined;
}

pub fn entities(self: *const QuadTree, id: Id) []const Slices.Elem {
    return self.quads.items[id].entities(self.slices);
}

pub const Query = struct {
    quad: *QuadTree,
    bounds: [4]i32,
    cursor: Id,
    from: Id,
    state: State = .diving,

    const State = enum {
        diving,
        diving_advance_oob,
        diving_advance,
        returning,
    };

    pub fn next(self: *Query) ?Id {
        while (true) switch (self.state) {
            .diving => {
                const quad = self.quad.quads.items[self.cursor];
                const radius = self.quad.radius >> quad.meta.depth;
                const cx = quad.pos[0];
                const cy = quad.pos[1];

                const oob = self.bounds[0] > cx + radius or self.bounds[2] < cx - radius or
                    self.bounds[1] > cy + radius or self.bounds[3] < cy - radius;
                if (!oob) {
                    self.state = .diving_advance;
                    return self.cursor;
                }
                self.state = .diving_advance_oob;
            },
            .diving_advance, .diving_advance_oob => self.state =
                if (self.advance(self.state != .diving_advance)) .diving else .returning,
            .returning => if (self.from != invalid_id) {
                const ret = self.from;
                self.from = self.quad.quads.items[ret].parent;
                return ret;
            } else return null,
        };
    }

    fn advance(self: *Query, oob: bool) bool {
        var quad = self.quad.quads.items[self.cursor];
        if (quad.children == invalid_id or oob) {
            if (self.cursor == self.from) return false;
            while (self.cursor & 3 == 0) {
                self.cursor = quad.parent;
                if (self.cursor == self.from) return false;
                quad = self.quad.quads.items[self.cursor];
            }
            self.cursor += 1;
        } else {
            self.cursor = quad.children;
        }
        return true;
    }
};

pub fn queryIter(self: *QuadTree, bounds: [4]i32, from: Id) Query {
    return .{
        .quad = self,
        .bounds = bounds,
        .cursor = self.quads.items[from].children,
        .from = from,
        .state = if (self.quads.items[from].children == invalid_id) .returning else .diving,
    };
}

pub fn insert(
    self: *QuadTree,
    alc: std.mem.Allocator,
    pos: [2]i32,
    size: i32,
    id: Slices.Elem,
) !Id {
    defer self.checkIntegrity(0);
    //self.total_updates += 1;
    self.quads.items[0].meta.total += 1;
    const find_res = self.findQuad(pos, size, 0);
    return try self.insertInternal(alc, find_res, id, 0);
}

pub fn update(
    self: *QuadTree,
    gpa: std.mem.Allocator,
    quid: *Id,
    pos: [2]i32,
    size: i32,
    id: Slices.Elem,
) !void {
    const prev = quid.*;

    var node = &self.quads.items[prev];
    var radius = self.radius >> node.meta.depth;

    while (node.parent != invalid_id) {
        const parent = &self.quads.items[node.parent];
        //self.total_cache_count += 1;
        if (parent.meta.total > quad_limit) break;
        quid.* = node.parent;
        node = parent;
        radius <<= 1;
    }

    const px = pos[0];
    const py = pos[1];
    const cx = node.pos[0];
    const cy = node.pos[1];
    const pos_vec: Vec = .{ -(px - size), px + size, -(py - size), py + size };
    const outside = pos_vec > @as(Vec, @splat(self.radius));
    const ones: @Vector(4, u1) = @splat(1);
    const zeros: Vec = @splat(0);

    var shift: Vec = @splat(radius);
    var center_vec: Vec = .{ -cx, cx, -cy, cy };

    while (node.parent != invalid_id) {
        const parent = &self.quads.items[node.parent];
        const in_bound_mask: @Vector(4, bool) = center_vec + shift >= pos_vec;
        const in_bounds = (@as(u4, @bitCast(in_bound_mask)) | @as(u4, @bitCast(outside))) == 0xf;
        if (in_bounds) break;
        std.debug.assert(node.pos[0] + shift[0] < px + size or
            node.pos[0] + shift[0] > px - size or
            node.pos[1] + shift[0] < py + size or
            node.pos[1] + shift[0] > py - size);

        const index: u4 = @intCast((quid.* - 1) & 3);
        const norm_mask = ((index & 2) << 1 | (index & 1));
        const mask_int = norm_mask + 0b0101;
        const mask: @Vector(4, bool) = @bitCast(mask_int);
        const diff = @select(i32, mask, shift, zeros);
        center_vec += shift - (diff << ones);
        shift <<= ones;

        quid.* = node.parent;
        node = parent;
    }

    const top = quid.*;
    const better_pos = self.findQuad(pos, size, top);

    if (better_pos.id == prev and (better_pos.index == null or b: {
        //self.total_cache_count += 1;
        break :b node.meta.total < quad_limit;
    })) {
        std.debug.assert(quid.* == prev);
        return;
    }

    self.removeInternal(prev, id, top, gpa);
    quid.* = try self.insertInternal(gpa, better_pos, id, top);

    self.checkIntegrity(top);
}

pub fn remove(self: *QuadTree, gpa: std.mem.Allocator, quad: Id, id: Slices.Elem) void {
    //self.total_updates += 1;
    self.quads.items[0].meta.total -= 1;
    self.removeInternal(quad, id, 0, gpa);
}

fn insertInternal(
    self: *QuadTree,
    alc: std.mem.Allocator,
    find_res: FindResult,
    id: Slices.Elem,
    inc_up_to: Id,
) !Id {
    var final_id = find_res.id;
    var quad = &self.quads.items[find_res.id];
    if (quad.entCount() >= quad_limit and find_res.index != null and
        quad.meta.depth != std.math.maxInt(u5))
    {
        std.debug.assert(quad.meta.total == quad.entCount() + @intFromBool(final_id == inc_up_to));
        final_id = try self.split(alc, find_res, id);
    } else try quad.pushEntity(&self.slices, alc, id);

    var cursor = final_id;
    quad = &self.quads.items[cursor];
    while (cursor != inc_up_to) {
        // self.total_updates += 1;
        quad.meta.total += 1;
        cursor = quad.parent;
        quad = &self.quads.items[cursor];
    }

    return final_id;
}

fn removeInternal(self: *QuadTree, quid: Id, id: Slices.Elem, dec_up_to: Id, gpa: std.mem.Allocator) void {
    var node = &self.quads.items[quid];
    const view = node.entities(self.slices);
    const index = std.mem.indexOfScalar(Slices.Elem, view, id) orelse std.debug.panic("{any} {any}", .{ view, id });
    std.mem.swap(Slices.Elem, &view[index], &view[view.len - 1]);
    _ = node.popEntity(&self.slices, gpa);

    var cursor = quid;
    while (cursor != dec_up_to) {
        //self.total_updates += 1;
        node.meta.total -= 1;
        self.checkIntegrity(cursor);
        if (node.entCount() == node.meta.total) {
            // self.total_cache_count += 1;
            self.freeChildren(node.children, gpa);
            node.children = invalid_id;
        }
        cursor = node.parent;
        node = &self.quads.items[cursor];
    }
}

fn checkIntegrity(self: *QuadTree, from: Id) void {
    if (!debug or true) return;
    const node = self.quads.items[from];
    if (node.children != invalid_id) {
        var sum: u32 = node.count;
        const shift = self.radius >> node.meta.depth + 1;
        const offs: [4][2]i32 = .{
            .{ -shift, -shift },
            .{ shift, -shift },
            .{ -shift, shift },
            .{ shift, shift },
        };
        for (self.quads.items[node.children..][0..4], offs) |q, off| {
            std.debug.assert(q.pos[0] - off[0] == node.pos[0]);
            std.debug.assert(q.pos[1] - off[1] == node.pos[1]);
            sum += q.meta.total;
        }
        if (sum != node.meta.total) std.debug.panic("{any} sum: {any} total: {any}", .{ from, sum, node.meta.total });
        for (node.children..node.children + 4) |c| self.checkIntegrity(@intCast(c));
    } else {
        if (node.count != node.meta.total) std.debug.panic("{any} total: {any} sum: {any}", .{ from, node.meta.total, node.count });
    }
}

fn split(self: *QuadTree, gpa: std.mem.Allocator, find_res: FindResult, id: Slices.Elem) !Id {
    const target = try self.allocChildren(gpa, find_res.id) + find_res.index.?;
    const quad = &self.quads.items[target];
    try quad.pushEntity(&self.slices, gpa, id);
    return target;
}

fn allocChildren(self: *QuadTree, alc: std.mem.Allocator, parent: Id) !Id {
    const node = &self.quads.items[parent];
    const next_depth = node.meta.depth + 1;
    std.debug.assert(node.children == invalid_id);

    const shift = self.radius >> next_depth;
    const cx = node.pos[0];
    const cy = node.pos[1];

    const id = if (self.free == invalid_id) b: {
        const id: Id = @intCast(self.quads.items.len);
        node.children = id;
        try self.quads.resize(alc, self.quads.items.len + 4);
        break :b id;
    } else b: {
        node.children = self.free;
        self.free = self.quads.items[node.children].parent;
        break :b node.children;
    };

    const buf = self.quads.items[id..][0..4];
    buf.* = .{
        .{ .pos = .{ cx - shift, cy - shift } },
        .{ .pos = .{ cx + shift, cy - shift } },
        .{ .pos = .{ cx - shift, cy + shift } },
        .{ .pos = .{ cx + shift, cy + shift } },
    };
    inline for (buf) |*q| q.parent = parent;
    inline for (buf) |*q| q.meta.depth = next_depth;

    return id;
}

inline fn freeChildren(self: *QuadTree, id: Id, gpa: std.mem.Allocator) void {
    if (id == invalid_id) return;
    if (Quad.use_allocator) {
        for (self.quads.items[id..][0..4]) |*q| q.ents.deinit(gpa);
    } else {
        for (self.quads.items[id..][0..4]) |*q| std.debug.assert(q.count == 0);
    }

    self.quads.items[id..][0..4].* = undefined;
    self.quads.items[id].parent = self.free;
    self.free = id;
}

fn findQuad(
    self: *QuadTree,
    pos: [2]i32,
    size: i32,
    from: Id,
) FindResult {
    const x = pos[0];
    const y = pos[1];
    const pos_vec: Vec = .{ x + size, -(x - size), y + size, -(y - size) };
    const ones: @Vector(4, u1) = @splat(1);
    const zeros: Vec = @splat(0);
    const from_node = &self.quads.items[from];
    const ix = from_node.pos[0];
    const iy = from_node.pos[1];

    var node: Id = from;
    var center_vec: Vec = .{ ix, -ix, iy, -iy };
    var shift: Vec = @splat(self.radius >> from_node.meta.depth);
    while (true) {
        const quad = &self.quads.items[node];

        if (quad.meta.total <= quad_limit) return .{ .id = node, .index = null };

        const mask = pos_vec <= center_vec;
        const mask_int: u4 = @bitCast(mask);

        std.debug.assert(@popCount(mask_int) <= 2);
        if (@popCount(mask_int) != 2) return .{ .id = node, .index = null };
        std.debug.assert(@popCount(mask_int >> 2) == 1 and @popCount(mask_int & 3) == 1);

        const norm_mask = mask_int - 0b0101;
        const index = (norm_mask >> 1) | (norm_mask & 1);

        if (quad.children == invalid_id) return .{ .id = node, .index = index };

        const diff = @select(i32, mask, shift, zeros);
        shift >>= ones;
        center_vec -= diff - shift;
        node = quad.children + index;
    }
}

const mem = std.mem;

pub fn countingAllocator(backing_allocator: mem.Allocator) CountingAllocator {
    return CountingAllocator{ .backing_allocator = backing_allocator };
}

pub const CountingAllocator = struct {
    backing_allocator: mem.Allocator,
    count: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *CountingAllocator) mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        var self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            self.count += len;
            self.peak = @max(self.peak, self.count);
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        var self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            self.count -= buf.len;
            self.count += new_len;
            self.peak = @max(self.peak, self.count);
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        var self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count -= buf.len;
        self.backing_allocator.rawFree(buf, buf_align, ret_addr);
    }
};

test {
    var alca = countingAllocator(std.testing.allocator);
    const alc = alca.allocator();
    const count = 10000;

    const radius = 14;
    var quad = try QuadTree.init(alc, radius);
    defer quad.deinit(alc);

    var rng_core = std.rand.DefaultPrng.init(1000);
    var rng = rng_core.random();

    const Ent = struct {
        pos: Pos,
        vel: Pos,
        id: Id = undefined,
    };

    const vel = 100;
    var ents: [count]Ent = undefined;
    for (&ents, 0..) |*e, i| {
        e.* = .{
            .pos = .{
                rng.intRangeAtMost(i32, -quad.radius, quad.radius),
                rng.intRangeAtMost(i32, -quad.radius, quad.radius),
            },
            .vel = .{
                rng.intRangeAtMost(i32, -vel, vel),
                rng.intRangeAtMost(i32, -vel, vel),
            },
        };
        e.id = try quad.insert(alc, e.pos, 4, i);
    }

    var now = try std.time.Timer.start();
    const iter_count = 1000;
    for (0..iter_count) |_| {
        for (&ents, 0..) |*e, i| {
            e.pos[0] += e.vel[0];
            e.pos[1] += e.vel[1];

            if (e.pos[0] > quad.radius) e.pos[0] -= quad.radius * 2;
            if (e.pos[0] < -quad.radius) e.pos[0] += quad.radius * 2;
            if (e.pos[1] > quad.radius) e.pos[1] -= quad.radius * 2;
            if (e.pos[1] < -quad.radius) e.pos[1] += quad.radius * 2;

            //quad.remove(e.id, i);
            //e.id = try quad.insert(alc, e.pos, 4, i);
            try quad.update(alc, &e.id, e.pos, 4, i);
        }
    }
    std.debug.print("{any} {any} {any} {any} {any} {any} {any} {any}\n", .{
        now.lap(),
        quad.quads.items.len,
        quad.slices.mem.len,
        quad.total_cache_count,
        quad.total_updates,
        count * iter_count,
        alca.count,
        alca.peak,
    });
}
