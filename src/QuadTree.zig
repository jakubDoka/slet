const std = @import("std");

const QuadTree = @This();

const Vec = @Vector(4, i32);

const Slices = struct {
    // 2 milion objects per slice is plenty
    const size_class_count = std.math.maxInt(SizeClass) - 10;
    const invalid_elem = std.math.maxInt(Elem);
    const null_index = std.math.maxInt(Index);
    const init_cap = 8;

    const Elem = u64;
    const Index = u32;
    const SizeClass = u5;
    const View = []Elem;

    const FreeHeader = extern struct {
        // this can be incorrect in case we used all of the memory i the u32 range
        // and last slot is of size 1, we still canot reach this value since minimal
        // size of a lice is 2
        const tail_sentinel = std.math.maxInt(u32) - 1;

        prev: u32 = tail_sentinel,
        next: u32 = tail_sentinel,

        pub fn isLast(self: FreeHeader) bool {
            return self.prev == tail_sentinel and self.next == tail_sentinel;
        }
    };

    const TakenHeader = extern struct {
        sentinel: u32 = std.math.maxInt(u32),
        len: u32,
    };

    const Slot = extern union {
        id: Elem,
        free: FreeHeader,
        taken: TakenHeader,
        free_len: u32,

        pub fn getTaken(self: *Slot) *TakenHeader {
            if (self.isFree()) {
                unreachable;
            }
            return &self.taken;
        }

        pub fn isFree(self: Slot) bool {
            return self.taken.sentinel != std.math.maxInt(u32);
        }
    };

    classes: [size_class_count]Index = .{FreeHeader.tail_sentinel} ** size_class_count,
    active_classes: u32 = 0,
    slice: []Slot = &.{},

    pub fn deinit(self: *Slices, alc: std.mem.Allocator) void {
        alc.free(self.slice);
        self.* = undefined;
    }

    pub fn push(self: *Slices, alc: std.mem.Allocator, index: *Index, value: Elem) !void {
        var prev = index.*;

        if (prev == null_index) {
            index.* = try self.alloc(alc, 1);
            self.view(index.*)[0] = value;
            return;
        }

        var len = self.lenOf(prev) + 1;
        var cap = capFor(len);
        const buddy = buddyIndex(prev, cap);

        if (len != cap) {
            self.slice[prev].getTaken().len += 1;
            //std.debug.assert(self.slice[prev + len].isFree());
            self.slice[prev + len] = .{ .id = value };
            return;
        }

        if (buddy >= self.slice.len) {
            _ = try self.expandAllocated(alc, cap);
        } else if (self.slice[buddy].isFree() and self.slice[buddy + 1].free_len == cap) {
            self.allocSpecific(buddy, cap);
        } else {
            index.* = try self.alloc(alc, len);
            if (len != 1) @memcpy(self.slice[index.*..][0..len], self.slice[prev..][0..len]);
            self.freeInternal(prev, cap, false);

            std.debug.assert(self.slice[index.* + len].isFree());
            self.slice[index.*].getTaken().len += 1;
            self.slice[index.* + len] = .{ .id = value };
            return;
        }

        cap *= 2;

        if (buddy < prev) {
            @memcpy(self.slice[buddy..][0..len], self.slice[prev..][0..len]);
            prev = buddy;
            index.* = buddy;
        }

        self.slice[prev].getTaken().len += 1;
        self.slice[prev + len] = .{ .id = value };
    }

    pub fn pop(self: *Slices, index: *Index) ?Elem {
        var prev = index.*;
        if (prev == null_index) return null;

        const len = self.slice[prev].getTaken().len;
        const last = self.slice[prev + len].id;
        if (len == 1) {
            index.* = null_index;
            self.freeInternal(prev, 2, false);
        } else {
            if (std.math.isPowerOfTwo(len)) {
                self.freeInternalNoDefrag(prev + len, len, true);
            }

            self.slice[prev].getTaken().len -= 1;
        }
        return last;
    }

    pub fn alloc(self: *Slices, alc: std.mem.Allocator, len: u32) !Index {
        const index = b: {
            if (len == 0) return null_index;
            if (self.tryReuse(len)) |index| break :b index;
            try self.expand(alc, len + 1);
            break :b self.tryReuse(len).?;
        };
        return index;
    }

    pub fn tryReuse(self: *Slices, len: u32) ?Index {
        const cap = capFor(len + 1);
        const free_index = freeIndex(cap);

        const mask = self.active_classes >> @intCast(free_index);
        if (mask == 0) return null;
        const class = free_index + @ctz(mask);

        const index = self.allocSizeClass(@intCast(class));
        std.debug.assert(index & 1 == 0);
        self.slice[index] = .{ .taken = .{ .len = len } };

        const goal = @as(u32, 1) << @intCast(class + 1);
        var cursor = cap;
        while (cursor != goal) {
            self.freeInternalNoDefrag(index + cursor, cursor, true);
            cursor *= 2;
        }

        return index;
    }

    pub fn free(self: *Slices, index: Index) void {
        if (index == null_index) return;
        self.freeInternal(index, capFor(self.slice[index].getTaken().len + 1), false);
    }

    pub fn view(self: *Slices, index: Index) View {
        if (index == null_index) return &.{};
        return @as([*]Elem, @ptrCast(self.slice.ptr))[index + 1 ..][0..self.slice[index].getTaken().len];
    }

    pub fn lenOf(self: *const Slices, index: Index) u32 {
        if (index == null_index) return 0;
        return self.slice[index].getTaken().len;
    }

    fn expand(self: *Slices, alc: std.mem.Allocator, additional: u32) !void {
        const prev_cap: u32 = @intCast(self.slice.len);
        const new_cap = try self.expandAllocated(alc, additional);

        if (prev_cap == 0) {
            self.freeInternalNoDefrag(0, new_cap, true);
            return;
        }

        var cursor = prev_cap;
        while (cursor != new_cap) {
            self.freeInternal(cursor, cursor, true);
            cursor *= 2;
        }
    }

    fn expandAllocated(self: *Slices, alc: std.mem.Allocator, additional: u32) !u32 {
        const prev_cap: u32 = @intCast(self.slice.len);
        const sum = @as(u32, @intCast(prev_cap + additional));
        const unskipped_new_cap = std.math.ceilPowerOfTwo(u32, sum) catch
            std.math.maxInt(u32);
        const new_cap = @max(init_cap, unskipped_new_cap) * 2;

        self.slice = try alc.realloc(self.slice, new_cap);

        return new_cap;
    }

    fn freeInternal(self: *Slices, p_index: u32, p_cap: u32, new: bool) void {
        var cap = p_cap;
        var index = p_index;

        var free_index = freeIndex(cap);
        var buddy = buddyIndex(index, cap);

        while (buddy != self.slice.len and
            self.slice[buddy].isFree() and
            self.slice[buddy + 1].free_len == cap)
        {
            self.allocSpecific(buddy, cap);

            cap *= 2;
            if (buddy < index) {
                self.slice[index] = .{ .free = .{} };
                index = buddy;
                self.slice[index] = .{ .taken = .{ .len = std.math.maxInt(u32) } };
            }
            free_index += 1;
            buddy = buddyIndex(index, cap);
        }

        self.freeInternalNoDefrag(index, cap, new);
    }

    fn freeInternalNoDefrag(self: *Slices, index: u32, cap: u32, new: bool) void {
        const free_index = freeIndex(cap);
        const current = self.classes[free_index];
        if (current != FreeHeader.tail_sentinel) {
            self.slice[current].free.prev = index;
        }

        std.debug.assert(!self.slice[index].isFree() or new);
        self.active_classes |= cap >> 1;
        self.slice[index] = .{ .free = .{ .next = current } };
        self.slice[index + 1] = .{ .free_len = cap };
        std.debug.assert(index & 1 == 0);
        self.classes[free_index] = index;
        self.checkClassIntegirty();
    }

    fn allocSizeClass(self: *Slices, class: u5) Index {
        std.debug.assert(self.classes[class] != FreeHeader.tail_sentinel);

        const index = self.classes[class];
        std.debug.assert(self.slice[index].isFree());
        std.debug.assert(index & ((@as(u32, 1) << class) - 1) == 0);
        self.classes[class] = self.slice[index].free.next;
        if (self.classes[class] == FreeHeader.tail_sentinel)
            self.active_classes &= ~(@as(u32, 1) << class)
        else
            self.slice[self.classes[class]].free.prev = FreeHeader.tail_sentinel;
        self.checkClassIntegirty();

        return index;
    }

    fn checkClassIntegirty(self: *Slices) void {
        _ = self;
        // for (self.classes, 0..) |c, i| {
        //     std.debug.assert(c == FreeHeader.tail_sentinel or
        //         self.active_classes & (@as(u32, 1) << @intCast(i)) != 0);

        //     var prev: u32 = FreeHeader.tail_sentinel;
        //     var root = c;
        //     while (root != FreeHeader.tail_sentinel) {
        //         const node = self.slice[root].free;
        //         std.debug.assert(node.prev == prev);
        //         prev = root;
        //         root = node.next;
        //     }
        // }
    }

    fn allocSpecific(self: *Slices, index: u32, cap: u32) void {
        const ts = FreeHeader.tail_sentinel;

        std.debug.assert(self.slice[index].isFree());
        self.checkClassIntegirty();
        const fh = self.slice[index].free;
        if (fh.next != ts) self.slice[fh.next].free.prev = fh.prev;
        if (fh.prev != ts) self.slice[fh.prev].free.next = fh.next else {
            if (fh.next == ts) self.active_classes &= ~(cap >> 1);
            self.classes[freeIndex(cap)] = fh.next;
        }
        self.checkClassIntegirty();
    }

    fn buddyIndex(index: u32, cap: u32) u32 {
        std.debug.assert(index & (cap - 1) == 0);
        const is_left = (index >> @intCast(@ctz(cap))) & 1 == 0;
        return if (is_left) index + cap else index - cap;
    }

    fn freeIndex(cap: u32) u5 {
        std.debug.assert(std.math.isPowerOfTwo(cap));
        return @intCast(@ctz(cap) - 1);
    }

    fn capFor(len: u32) u32 {
        return std.math.ceilPowerOfTwo(u32, len) catch unreachable;
    }
};

const Pos = [2]i32;

const Quad = struct {
    depth: u5 = 0,
    parent: Id = invalid_id,
    pos: Pos = .{ 0, 0 },
    total: u32 = 0,
    children: Id = invalid_id,
    entities: Slices.Index = Slices.null_index,
};

const FindResult = struct {
    id: Id,
    index: ?u4,
};

pub const Id = u32;

pub const quad_limit = 7; // exactly fills a size class
pub const invalid_id = std.math.maxInt(Id);

quads: std.ArrayListUnmanaged(Quad) = .{},
slices: Slices = .{},
free: Id = invalid_id,
radius: i32,

pub fn init(alc: std.mem.Allocator, radius: i32) !QuadTree {
    var self = QuadTree{ .radius = radius };
    try self.quads.append(alc, .{});
    return self;
}

pub fn deinit(self: *QuadTree, alc: std.mem.Allocator) void {
    self.quads.deinit(alc);
    self.slices.deinit(alc);
    self.free = undefined;
}

pub fn query(
    self: *QuadTree,
    bounds: [4]i32,
    buffer: *std.ArrayList(Slices.Elem),
    from: Id,
) !void {
    const quad = self.quads.items[from];
    const radius = self.radius >> quad.depth;
    const cx = quad.pos[0];
    const cy = quad.pos[1];
    const tx = bounds[0];
    const ty = bounds[1];
    const bx = bounds[2];
    const by = bounds[3];

    if (tx > cx + radius or
        bx < cx - radius or
        ty > cy + radius or
        by < cy - radius) return;

    try buffer.appendSlice(self.slices.view(quad.entities));

    if (quad.children == invalid_id) return;

    for (quad.children..quad.children + 4) |c|
        try self.query(bounds, buffer, @intCast(c));
}

pub fn insert(
    self: *QuadTree,
    alc: std.mem.Allocator,
    pos: [2]i32,
    size: i32,
    id: Slices.Elem,
) !Id {
    defer self.checkCountIntegrity(0);
    self.quads.items[0].total += 1;
    var find_res = self.findQuad(pos, size, 0);
    return try self.insertInternal(alc, find_res, id, 0);
}

pub fn update(
    self: *QuadTree,
    alc: std.mem.Allocator,
    quid: *Id,
    pos: [2]i32,
    size: i32,
    id: Slices.Elem,
) !void {
    const prev = quid.*;

    var node = &self.quads.items[prev];
    var radius = self.radius >> node.depth;

    while (node.parent != invalid_id) {
        const parent = &self.quads.items[node.parent];
        if (parent.total > quad_limit) break;
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

    if (better_pos.id == prev and (better_pos.index == null or node.total < quad_limit)) {
        std.debug.assert(quid.* == prev);
        return;
    }

    self.removeInternal(prev, id, top);
    quid.* = try self.insertInternal(alc, better_pos, id, top);

    self.checkCountIntegrity(top);
}

pub fn remove(self: *QuadTree, quad: Id, id: Slices.Elem) void {
    self.quads.items[0].total -= 1;
    self.removeInternal(quad, id, 0);
}

fn insertInternal(
    self: *QuadTree,
    alc: std.mem.Allocator,
    find_res: FindResult,
    id: Slices.Elem,
    inc_up_to: Id,
) !Id {
    var final_id = find_res.id;
    var node = &self.quads.items[find_res.id];
    if (node.total > quad_limit and find_res.index != null and
        node.depth != std.math.maxInt(u5))
        final_id = try self.split(alc, find_res, id)
    else
        try self.slices.push(alc, &node.entities, id);

    var cursor = final_id;
    node = &self.quads.items[cursor];
    while (cursor != inc_up_to) {
        node.total += 1;
        cursor = node.parent;
        node = &self.quads.items[cursor];
    }

    return final_id;
}

fn removeInternal(self: *QuadTree, quid: Id, id: Slices.Elem, dec_up_to: Id) void {
    var node = &self.quads.items[quid];
    const view = self.slices.view(node.entities);
    const index = std.mem.indexOfScalar(Slices.Elem, view, id) orelse std.debug.panic("{any} {any}", .{ view, id });
    std.mem.swap(Slices.Elem, &view[index], &view[view.len - 1]);
    _ = self.slices.pop(&node.entities).?;

    var cursor = quid;
    while (cursor != dec_up_to) {
        node.total -= 1;
        self.checkCountIntegrity(cursor);
        if (self.slices.lenOf(node.entities) == node.total) {
            self.freeChildren(node.children);
            node.children = invalid_id;
        }
        cursor = node.parent;
        node = &self.quads.items[cursor];
    }
}

fn checkCountIntegrity(self: *QuadTree, from: Id) void {
    _ = from;
    _ = self;
    // const node = self.quads.items[from];
    // if (node.children != invalid_id) {
    //     var sum: u32 = self.slices.lenOf(node.entities);
    //     for (self.quads.items[node.children..][0..4]) |q| sum += q.total;
    //     if (sum != node.total) std.debug.panic("{any} sum: {any} total: {any}", .{ from, sum, node.total });
    //     for (node.children..node.children + 4) |c| self.checkCountIntegrity(@intCast(c));
    // } else {
    //     if (self.slices.lenOf(node.entities) != node.total) std.debug.panic("{any} total: {any} sum: {any}", .{ from, node.total, self.slices.lenOf(node.entities) });
    // }
}

fn split(self: *QuadTree, alc: std.mem.Allocator, find_res: FindResult, id: Slices.Elem) !Id {
    const target = try self.allocChildren(alc, find_res.id) + find_res.index.?;
    const quad = &self.quads.items[target];
    try self.slices.push(alc, &quad.entities, id);
    return target;
}

fn allocChildren(self: *QuadTree, alc: std.mem.Allocator, parent: Id) !Id {
    const node = &self.quads.items[parent];
    const next_depth = node.depth + 1;
    std.debug.assert(node.children == invalid_id);

    const shift = self.radius >> (node.depth + 1);
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
    inline for (buf) |*q| q.depth = next_depth;

    return id;
}

inline fn freeChildren(self: *QuadTree, id: Id) void {
    if (id == invalid_id) return;
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
    var shift: Vec = @splat(self.radius >> from_node.depth);

    while (true) {
        const quad = &self.quads.items[node];

        if (quad.total <= quad_limit) return .{ .id = node, .index = null };

        const mask = pos_vec < center_vec;
        const mask_int: u4 = @bitCast(mask);
        if (@popCount(mask_int) != 2) return .{ .id = node, .index = null };

        const diff = @select(i32, mask, shift, zeros);
        shift >>= ones;
        center_vec -= diff - shift;

        const norm_mask = (mask_int - 0b0101);
        const index = (norm_mask >> 1) | (norm_mask & 1);

        if (quad.children == invalid_id) return .{ .id = node, .index = index };

        node = quad.children + index;
    }
}

test {
    const alc = std.testing.allocator;
    const count = 10000;
    {
        var slices = Slices{};
        defer slices.deinit(alc);
        const index = try slices.alloc(alc, 1);
        var view = slices.view(index);
        try std.testing.expectEqual(view.len, 1);
        view[0] = 100;
        view = slices.view(index);
        try std.testing.expectEqual(view.len, 1);
        slices.free(index);

        var arr: [count]Slices.Index = undefined;

        for (&arr) |*slot| slot.* = try slices.alloc(alc, 1);
        for (arr) |slot| slices.free(slot);

        for (&arr) |*slot| slot.* = try slices.alloc(alc, 1);
        std.mem.reverse(Slices.Index, &arr);
        for (arr) |slot| slices.free(slot);

        for (&arr, 0..) |*slot, i| slot.* = try slices.alloc(alc, @as(u32, 1) << @intCast(i % 3));
        for (arr) |slot| slices.free(slot);

        var slice = try slices.alloc(alc, 0);
        var res_arr: [count]Slices.Elem = undefined;
        for (0..count) |i| {
            try slices.push(alc, &slice, i);
            res_arr[i] = i;
        }
        try std.testing.expectEqualSlices(Slices.Elem, &res_arr, slices.view(slice));
    }

    const radius = 1024 << 4;
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
                rng.intRangeAtMost(i32, -radius, radius),
                rng.intRangeAtMost(i32, -radius, radius),
            },
            .vel = .{
                rng.intRangeAtMost(i32, -vel, vel),
                rng.intRangeAtMost(i32, -vel, vel),
            },
        };
        e.id = try quad.insert(alc, e.pos, 4, i);
    }

    var now = try std.time.Timer.start();
    for (0..1000) |_| {
        for (&ents, 0..) |*e, i| {
            e.pos[0] += e.vel[0];
            e.pos[1] += e.vel[1];

            if (e.pos[0] > radius) e.pos[0] -= radius * 2;
            if (e.pos[0] < -radius) e.pos[0] += radius * 2;
            if (e.pos[1] > radius) e.pos[1] -= radius * 2;
            if (e.pos[1] < -radius) e.pos[1] += radius * 2;

            // quad.remove(e.id, i);
            // e.id = try quad.insert(alc, e.pos, 4, i);
            try quad.update(alc, &e.id, e.pos, 4, i);
        }
    }
    std.debug.print("{any} {any} {any}\n", .{ now.lap(), quad.quads.items.len, quad.slices.slice.len });
}
