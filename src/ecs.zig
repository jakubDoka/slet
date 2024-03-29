const std = @import("std");
const Type = std.builtin.Type;

const Mask = u64;
const ArchId = u6;
const TypeId = u32;
pub const World = @This();

const TypeMeta = packed struct(u32) {
    alignment: u6,
    size: u26,

    pub fn fromType(comptime T: type) TypeMeta {
        return .{ .alignment = @intCast(@alignOf(T)), .size = @intCast(@sizeOf(T)) };
    }
};

const Archetype = struct {
    const Storage = struct {
        const Lane = struct {
            data: [*]u8,
            type: TypeId,
            meta: TypeMeta,
        };

        back_refs: [*]Id = @ptrFromInt(@alignOf(Id)),
        lanes: []Lane = undefined,
        len: usize = 0,
        cap: usize = 0,

        pub fn deinit(self: *Storage, alc: std.mem.Allocator) void {
            alc.free(self.back_refs[0..self.sizeForCap(self.cap)]);
            self.* = undefined;
        }

        pub fn sizeForCap(self: *Storage, cap: usize) usize {
            if (cap == 0) return 0;

            var size = @sizeOf(Id) * cap;
            for (self.lanes) |lane| {
                size += lane.meta.size * cap + lane.meta.alignment - 1;
            }
            return std.math.divCeil(usize, size, @alignOf(Id)) catch unreachable;
        }

        pub fn expand(self: *Storage, alc: std.mem.Allocator, new_cap: usize) !void {
            const size = self.sizeForCap(new_cap);
            const back_refs = try alc.alloc(Id, size);

            @memcpy(back_refs[0..self.cap], self.back_refs[0..self.cap]);

            var cursor: [*]u8 = @ptrCast(back_refs);
            cursor += @sizeOf(Id) * new_cap;

            for (self.lanes) |*lane| {
                cursor = std.mem.alignPointer(cursor, lane.meta.alignment).?;

                @memcpy(
                    cursor[0 .. self.cap * lane.meta.size],
                    lane.data[0 .. self.cap * lane.meta.size],
                );
                lane.data = cursor;

                cursor += lane.meta.size * new_cap;
            }

            alc.free(self.back_refs[0..self.sizeForCap(self.cap)]);
            self.back_refs = back_refs.ptr;
            self.cap = new_cap;
        }

        pub fn select(self: *Storage, comptime Q: type) Selector(Q) {
            var selector: Selector(Q) = undefined;
            var i: usize = 0;
            inline for (std.meta.fields(Q)) |f| {
                if (f.type == Id) {
                    @field(selector, f.name) = @alignCast(@ptrCast(self.back_refs));
                    continue;
                }
                while (self.lanes[i].type != componentIdOf(f.type)) i += 1;
                @field(selector, f.name) = @alignCast(@ptrCast(self.lanes[i].data));
                i += 1;
            }
            return selector;
        }

        pub fn push(self: *Storage, alc: std.mem.Allocator, init: anytype, id: Id) !void {
            if (self.len == self.cap) try self.expand(alc, @max(self.cap * 2, 16));
            self.back_refs[self.len] = id;
            inline for (std.meta.fields(@TypeOf(init)), 0..) |field, i| {
                const lane = &self.lanes[i];
                const offset = lane.meta.size * self.len;
                @as(*field.type, @alignCast(@ptrCast(&lane.data[offset]))).* = init[i];
            }
            self.len += 1;
        }

        pub fn dynPush(self: *Storage, alc: std.mem.Allocator, lanes: []Lane, id: Id) !void {
            if (self.len == self.cap) try self.expand(alc, @max(self.cap * 2, 16));
            self.back_refs[self.len] = id;
            for (lanes, 0..) |lane, i| {
                @memcpy(
                    self.lanes[i].data[lane.meta.size * self.len ..][0..lane.meta.size],
                    lane.data[0..lane.meta.size],
                );
            }
            self.len += 1;
        }

        pub fn remove(self: *Storage, index: usize) void {
            self.len -= 1;
            if (self.len == 0) return;
            self.back_refs[index] = self.back_refs[self.len];
            for (self.lanes) |lane| {
                const offset = lane.meta.size * index;
                const last = lane.meta.size * self.len;
                @memcpy(
                    lane.data[offset..][0..lane.meta.size],
                    lane.data[last..][0..lane.meta.size],
                );
            }
        }
    };

    mask: Mask = 0,
    storage: Storage = .{},
};

pub const Id = extern struct {
    index: u32,
    version: u32,

    pub fn toRaw(self: Id) u64 {
        return @bitCast(self);
    }
};

pub const Entity = struct {
    mask: Mask,
    arch: *Archetype.Storage,
    index: u32,

    pub fn id(self: Entity) Id {
        return self.arch.back_refs[self.index];
    }

    pub fn has(self: Entity, comptime C: type) bool {
        return self.mask & @as(Mask, 1) << @intCast(componentIdOf(C)) != 0;
    }

    pub fn get(self: *const Entity, comptime C: type) ?*C {
        if (!self.has(C)) return null;
        const tid = componentIdOf(C);
        const index = std.sort.binarySearch(Archetype.Storage.Lane, tid, self.arch.lanes, {}, struct {
            pub fn cmp(_: void, mid: u32, b: Archetype.Storage.Lane) std.math.Order {
                return std.math.order(mid, b.type);
            }
        }.cmp).?;
        const lane = self.arch.lanes[index];
        return @alignCast(@ptrCast(lane.data + self.index * lane.meta.size));
    }

    pub fn select(self: *const Entity, comptime Q: type) ?MapStruct(Q, ToPtr) {
        const mask = comptime computeMask(@typeInfo(Q).Struct);
        if (self.mask & mask != mask) return null;

        var selector = staticLanes(@typeInfo(Q).Struct);
        var i: usize = 0;
        for (self.arch.lanes) |lane| {
            if (lane.type == selector[i].type) {
                selector[i].data = lane.data + self.index * lane.meta.size;
                i += 1;
                if (i == selector.len) break;
            }
        }

        var result: MapStruct(Q, ToPtr) = undefined;
        inline for (std.meta.fields(Q), 0..) |f, j| {
            @field(result, f.name) = &@as([*]f.type, @alignCast(@ptrCast(selector[j].data)))[0];
        }
        return result;
    }
};

const Slot = struct {
    const Data = union {
        const null_free = std.math.maxInt(u32);
        const InnerId = packed struct(u32) {
            index: u26,
            arch: ArchId,
        };

        id: InnerId,
        next_free: u32,
    };

    data: Data,
    version: u32,
};

const componentIdOf = b: {
    comptime var types: []const type = &.{};
    break :b struct {
        pub fn next(comptime C: type) u32 {
            std.debug.assert(types.len < 64);
            const index = comptime for (types, 0..) |t, i| {
                if (t == C) break i;
            } else b: {
                types = types ++ .{C};
                break :b types.len - 1;
            };
            return index;
        }
    }.next;
};

archetypes: std.MultiArrayList(Archetype) = .{},
entities: std.ArrayListUnmanaged(Slot) = .{},
lane_arena: std.heap.ArenaAllocator.State = .{},
free_head: u32 = Slot.Data.null_free,

pub fn deinit(self: *World, alc: std.mem.Allocator) void {
    for (self.archetypes.items(.storage)) |*storage| storage.deinit(alc);
    self.archetypes.deinit(alc);
    self.entities.deinit(alc);
    self.lane_arena.promote(alc).deinit();
    self.* = undefined;
}

pub fn get(self: *World, id: Id) ?Entity {
    const slot = self.accessId(id) catch return null;
    return .{
        .mask = self.archetypes.items(.mask)[slot.arch],
        .arch = &self.archetypes.items(.storage)[slot.arch],
        .index = slot.index,
    };
}

pub fn nextId(self: *const World) Id {
    if (self.free_head == Slot.Data.null_free)
        return .{ .index = @intCast(self.entities.items.len), .version = 0 };
    return .{
        .index = self.free_head,
        .version = self.entities.items[self.free_head].version,
    };
}

pub fn create(self: *World, alc: std.mem.Allocator, raw_init: anytype) !Id {
    const init = normalize(raw_init);
    const info = @typeInfo(@TypeOf(init)).Struct;
    const mask = comptime computeMask(info);

    const arch_index = self.findArchetype(mask) orelse try self.createArchetype(alc, mask, info);
    const id = try self.allocId(alc, arch_index);
    const arch = &self.archetypes.items(.storage)[arch_index];

    try arch.push(alc, init, id);

    return id;
}

pub fn exchangeComps(
    self: *World,
    alc: std.mem.Allocator,
    id: Id,
    comptime R: type,
    raw_comps: anytype,
) !?Normalized(R) {
    const slot = self.accessId(id) catch return null;
    const arch = &self.archetypes.items(.storage)[slot.arch];
    const mask = self.archetypes.items(.mask)[slot.arch];
    const remove_mask = comptime computeMask(@typeInfo(R).Struct);
    const add_mask = comptime computeMask(@typeInfo(@TypeOf(raw_comps)).Struct);

    if (mask & remove_mask != remove_mask) return error.MissingComponent;
    if (mask & add_mask != 0) return error.ComponentOverlap;

    const N = Normalized(@TypeOf(raw_comps));
    var comps = normalize(raw_comps);
    var new_lanes = staticLanes(@typeInfo(N).Struct);
    inline for (0..@typeInfo(N).Struct.fields.len) |i| {
        new_lanes[i].data = @ptrCast(&comps[i]);
    }

    const NQ = Normalized(R);
    var removed_lanes = staticLanes(@typeInfo(NQ).Struct);

    var buffer: [64]Archetype.Storage.Lane = undefined;
    const lane_count = arch.lanes.len - removed_lanes.len + new_lanes.len;
    const new_mask = mask & ~remove_mask | add_mask;

    var i: usize = 0;
    var j: usize = 0;
    for (arch.lanes) |lane| {
        if (j < removed_lanes.len and lane.type == removed_lanes[j].type) {
            removed_lanes[j].data = lane.data + slot.index * lane.meta.size;
            j += 1;
            continue;
        }
        buffer[i] = lane;
        buffer[i].data += slot.index * lane.meta.size;
        i += 1;
    }
    mergeSortedLanes(buffer[0..i], &new_lanes, buffer[i..][0..lane_count]);

    const new_arch_index = self.findArchetype(new_mask) orelse b: {
        const lanes = try self.allocLanes(alc, lane_count);
        @memcpy(lanes, buffer[i..][0..lane_count]);
        break :b try self.createArchatypeWithLanes(
            alc,
            new_mask,
            lanes,
        );
    };

    const new_arch = &self.archetypes.items(.storage)[new_arch_index];
    slot.* = .{ .index = @intCast(new_arch.len), .arch = new_arch_index };
    try new_arch.dynPush(alc, buffer[i..][0..lane_count], id);

    var result: NQ = undefined;
    inline for (std.meta.fields(NQ), 0..) |f, k| {
        @field(result, f.name) = @as([*]f.type, @alignCast(@ptrCast(removed_lanes[k].data)))[0];
    }
    arch.remove(slot.index);

    return result;
}

pub fn exchangeComp(self: *World, alc: std.mem.Allocator, id: Id, comptime C: type, comp: anytype) !?C {
    return ((try self.exchangeComps(alc, id, struct { C }, .{comp})) orelse return null)[0];
}

pub fn addComps(self: *World, alc: std.mem.Allocator, id: Id, raw_comps: anytype) !void {
    _ = try self.exchangeComps(alc, id, struct {}, raw_comps);
}

pub fn addComp(self: *World, alc: std.mem.Allocator, id: Id, comp: anytype) !void {
    try self.addComps(alc, id, .{comp});
}

pub fn removeComps(self: *World, alc: std.mem.Allocator, id: Id, comptime Q: type) !?Q {
    return try self.exchangeComps(alc, id, Q, .{});
}

pub fn removeComp(self: *World, alc: std.mem.Allocator, id: Id, comptime C: type) !?C {
    return ((try self.removeComps(alc, id, struct { C })) orelse return null)[0];
}

pub fn remove(self: *World, id: Id) !void {
    const slot = try self.accessId(id);
    const arch = &self.archetypes.items(.storage)[slot.arch];
    arch.remove(slot.index);
    const last_id = arch.back_refs[slot.index];
    if (!std.meta.eql(last_id, id)) {
        const last_slot = self.accessId(last_id) catch unreachable;
        last_slot.index = slot.index;
    }
    self.freeId(id);
}

fn mergeSortedLanes(
    a: []const Archetype.Storage.Lane,
    b: []const Archetype.Storage.Lane,
    out: []Archetype.Storage.Lane,
) void {
    std.debug.assert(a.len + b.len == out.len);
    var i: usize = 0;
    var j: usize = 0;

    while (i < a.len and j < b.len) {
        if (a[i].type < b[j].type) {
            out[i + j] = a[i];
            i += 1;
        } else {
            out[i + j] = b[j];
            j += 1;
        }
    }

    while (i < a.len) {
        out[i + j] = a[i];
        i += 1;
    }

    while (j < b.len) {
        out[i + j] = b[j];
        j += 1;
    }

    // check that the merge was successful
    for (out[0 .. out.len - 1], 0..) |l, k| {
        std.debug.assert(l.type < out[k + 1].type);
    }
}

fn accessId(self: *World, id: Id) !*Slot.Data.InnerId {
    const slot = &self.entities.items[id.index];
    if (slot.version != id.version) return error.OutdatedId;
    return &slot.data.id;
}

pub fn Query(comptime Q: type) type {
    return struct {
        const Self = @This();

        match_mask: Mask,
        selector: Selector(Q) = undefined,
        chunk_len: usize = 0,
        chunk_cursor: usize = 0,
        world: *World,

        pub fn next(self: *Self) ?MapStruct(Q, ToPtr) {
            while (true) {
                if (self.chunk_cursor != self.chunk_len) {
                    var result: MapStruct(Q, ToPtr) = undefined;
                    inline for (std.meta.fields(Q)) |f| {
                        @field(result, f.name) = &@field(self.selector, f.name)[self.chunk_cursor];
                    }
                    self.chunk_cursor += 1;
                    return result;
                }

                if (self.match_mask == 0) return null;
                const index = @ctz(self.match_mask);
                self.match_mask &= self.match_mask - 1;

                const arch = &self.world.archetypes.items(.storage)[index];
                self.selector = arch.select(Q);
                self.chunk_len = arch.len;
                self.chunk_cursor = 0;
            }
        }
    };
}

pub fn select(self: *World, comptime Q: type) Query(Q) {
    const mask = comptime computeMask(@typeInfo(Q).Struct);
    const matches = searchSupersets(self.archetypes.items(.mask), mask);

    return .{
        .match_mask = matches,
        .world = self,
    };
}

pub fn selectOne(self: *World, id: Id, comptime Q: type) ?MapStruct(Q, ToPtr) {
    const ent = self.get(id) orelse return null;
    return ent.select(Q);
}

fn findArchetype(self: *World, mask: Mask) ?ArchId {
    return @intCast(searchMask(self.archetypes.items(.mask), mask) orelse return null);
}

fn createArchetype(
    self: *World,
    alc: std.mem.Allocator,
    mask: Mask,
    comptime info: std.builtin.Type.Struct,
) !ArchId {
    const lanes = try self.allocLanes(alc, info.fields.len);
    const static_lanes = staticLanes(info);
    @memcpy(lanes, &static_lanes);
    return createArchatypeWithLanes(self, alc, mask, lanes);
}

fn staticLanes(
    comptime info: std.builtin.Type.Struct,
) [info.fields.len]Archetype.Storage.Lane {
    var lanes: [info.fields.len]Archetype.Storage.Lane = undefined;
    inline for (&lanes, info.fields) |*lane, field| {
        lane.* = .{
            .type = comptime componentIdOf(field.type),
            .meta = TypeMeta.fromType(field.type),
            .data = undefined,
        };
    }

    return lanes;
}

fn allocLanes(
    self: *World,
    alc: std.mem.Allocator,
    len: usize,
) ![]Archetype.Storage.Lane {
    var arena = self.lane_arena.promote(alc);
    defer self.lane_arena = arena.state;
    return try arena.allocator().alloc(Archetype.Storage.Lane, len);
}

fn createArchatypeWithLanes(
    self: *World,
    alc: std.mem.Allocator,
    mask: Mask,
    lanes: []Archetype.Storage.Lane,
) !ArchId {
    const arch = self.archetypes.len;
    try self.archetypes.append(alc, .{ .mask = mask, .storage = .{
        .lanes = lanes,
    } });
    return @intCast(arch);
}

fn allocId(self: *World, alc: std.mem.Allocator, arch: ArchId) !Id {
    const index = self.archetypes.items(.storage)[arch].len;
    const inner_id: Slot.Data = .{ .id = .{ .index = @intCast(index), .arch = arch } };
    if (self.free_head == Slot.Data.null_free) {
        try self.entities.append(alc, .{ .data = inner_id, .version = 0 });
        return .{ .index = @intCast(self.entities.items.len - 1), .version = 0 };
    }

    const slot = self.free_head;
    self.free_head = self.entities.items[slot].data.next_free;
    self.entities.items[slot].data = inner_id;
    return .{ .index = slot, .version = self.entities.items[slot].version };
}

fn freeId(self: *World, id: Id) void {
    self.entities.items[id.index].data = .{ .next_free = self.free_head };
    self.free_head = id.index;
    self.entities.items[id.index].version += 1;
}

fn searchMask(masks: []const Mask, mask: Mask) ?usize {
    const recommended_size = comptime std.simd.suggestVectorSize(Mask) orelse 1;
    const Vec = @Vector(recommended_size, Mask);
    const Int = std.meta.Int(.unsigned, recommended_size);

    const query: Vec = @splat(mask);

    const full_vecs = masks.len / recommended_size;
    return for (0..full_vecs) |i| {
        const vec: Vec = masks[i * recommended_size ..][0..recommended_size].*;
        const eq: Int = @bitCast(query == vec);
        const index = @ctz(eq);
        if (index != recommended_size)
            break index + i * recommended_size;
    } else b: {
        if (masks.len % recommended_size == 0)
            return null;

        break :b for (masks[full_vecs * recommended_size ..], 0..) |m, i| {
            if (m == mask)
                break full_vecs * recommended_size + i;
        } else null;
    };
}

fn searchSupersets(supersets: []const Mask, subset: Mask) Mask {
    const recommended_size = comptime std.simd.suggestVectorSize(Mask) orelse 1;
    const Vec = @Vector(recommended_size, Mask);
    const Int = std.meta.Int(.unsigned, recommended_size);

    const query: Vec = @splat(subset);

    var result: Mask = 0;
    const full_vecs = supersets.len / recommended_size;
    for (0..full_vecs) |i| {
        const vec: Vec = supersets[i * recommended_size ..][0..recommended_size].*;
        const eq: Int = @bitCast(query == vec & query);
        result |= @as(Mask, @intCast(eq)) << @intCast(i * recommended_size);
    }

    if (supersets.len % recommended_size != 0)
        for (supersets[full_vecs * recommended_size ..], 0..) |m, i| {
            const eq = m & subset == subset;
            result |= @as(Mask, @intFromBool(eq)) << @intCast(full_vecs * recommended_size + i);
        };

    return result;
}

fn normalize(tuple: anytype) Normalized(@TypeOf(tuple)) {
    const N = Normalized(@TypeOf(tuple));
    if (N == @TypeOf(tuple)) return tuple;

    var norm: N = undefined;
    inline for (0..std.meta.fields(N).len) |i| inline for (0..std.meta.fields(N).len) |j| {
        if (@TypeOf(tuple[i]) == @TypeOf(norm[j])) {
            if (@sizeOf(@TypeOf(tuple[i])) == 0) continue;
            norm[j] = tuple[i];
            break;
        }
    };
    return norm;
}

fn Selector(comptime Q: type) type {
    return Normalized(MapStruct(Q, ToUnboundPtr));
}

fn Normalized(comptime T: type) type {
    var info = @typeInfo(T).Struct;

    if (info.fields.len == 0) return T;

    var fields = info.fields[0..info.fields.len].*;
    for (1..fields.len) |i| for (0..i) |j| {
        if (componentIdOf(fields[i].type) < componentIdOf(fields[j].type))
            std.mem.swap(Type.StructField, &fields[i], &fields[j]);
    };

    for (&fields, 0..) |*field, i| {
        if (info.is_tuple) {
            var buffer: [64]u8 = undefined;
            field.name = std.fmt.bufPrint(&buffer, "{d}", .{i}) catch unreachable;
        }
        field.is_comptime = false;
    }

    info.fields = &fields;
    return @Type(.{ .Struct = info });
}

fn computeMask(comptime info: std.builtin.Type.Struct) Mask {
    var mask: Mask = 0;
    for (info.fields) |field| {
        if (field.type == Id) continue;
        mask |= 1 << componentIdOf(field.type);
    }
    return mask;
}

fn MapStruct(comptime T: type, comptime map: fn (type) type) type {
    var info = @typeInfo(T).Struct;
    var fields = info.fields[0..info.fields.len].*;
    for (&fields) |*field| {
        field.type = map(field.type);
        field.default_value = null;
    }
    info.fields = &fields;
    return @Type(.{ .Struct = info });
}

fn ToArray(comptime T: type) type {
    return []T;
}

fn ToUnboundPtr(comptime T: type) type {
    return [*]T;
}

fn ToPtr(comptime T: type) type {
    return *T;
}

test {
    const alc = std.testing.allocator;
    var w = World{};
    defer w.deinit(alc);
    try w.archetypes.append(alc, .{});
    const id = try w.allocId(alc, 0);
    w.freeId(id);
    const id2 = try w.allocId(alc, 0);
    try std.testing.expect(id.index == id2.index);
    try std.testing.expect(id.version + 1 == id2.version);
    w.freeId(id2);

    const foo = try w.create(alc, .{@as([]const u8, "foo")});

    const hell = try w.create(alc, .{@as([]const u8, "hell")});
    const no = try w.create(alc, .{ @as([]const u8, "no"), @as(u32, 0) });
    _ = no;

    _ = try w.remove(foo);

    var iter = w.select(struct { []const u8 });
    try std.testing.expectEqualStrings(iter.next().?[0].*, "hell");
    try std.testing.expectEqualStrings(iter.next().?[0].*, "no");
    try std.testing.expect(iter.next() == null);

    try w.addComps(alc, hell, .{@as(u32, 1)});

    var iter2 = w.select(struct { name: []const u8, foo: u32, id: Id });
    try std.testing.expectEqual(iter2.next().?.name.*, "no");
    try std.testing.expectEqualStrings(iter2.next().?.name.*, "hell");

    const removed = try w.removeComps(alc, hell, struct { []const u8 });
    try std.testing.expectEqualStrings(removed[0], "hell");

    const exchanged = try w.exchangeComps(alc, hell, struct { foo: u32 }, .{@as([]const u8, "hell")});
    try std.testing.expectEqual(exchanged.foo, 1);

    const other_exchanged = try w.exchangeComps(alc, hell, struct { name: []const u8 }, .{@as(u32, 2)});
    try std.testing.expectEqualStrings(other_exchanged.name, "hell");

    var ent = w.get(hell).?;
    try std.testing.expectEqual(ent.get(u32).?.*, 2);

    const masks = [_]Mask{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    for (masks) |mask| {
        const index = searchMask(&masks, mask);
        try std.testing.expectEqual(masks[index.?], mask);
    }

    const supersets = [_]Mask{ 0b0, 0b1, 0b10, 0b11 };
    try std.testing.expectEqual(searchSupersets(&supersets, 0b0), 0b1111);
    try std.testing.expectEqual(searchSupersets(&supersets, 0b1), 0b1010);

    const retryes = 10000;
    const lot_of_masks = try std.testing.allocator.alloc(u64, 64);
    defer std.testing.allocator.free(lot_of_masks);
    var timer = try std.time.Timer.start();
    for (0..retryes) |_| {
        const index = searchMask(lot_of_masks, 1);
        try std.testing.expect(index == null);
    }

    timer.reset();
    for (0..retryes) |_| {
        for (lot_of_masks) |m| {
            if (m == 1) try std.testing.expect(false);
        }
    }

    timer.reset();
    for (0..retryes) |_| {
        const result = searchSupersets(lot_of_masks, 0);
        try std.testing.expectEqual(result, std.math.maxInt(Mask));
    }

    const tuple1: struct { []const u8, usize } = .{ "", 1 };
    const tuple2: struct { usize, []const u8 } = .{ 1, "" };

    try std.testing.expectEqual(normalize(tuple1), normalize(tuple2));
}
