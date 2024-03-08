// # Restructuring of the ecs
//
// This time we use double indirection for accessing concrete entity,
// which allows us to have continuous array of entities.
//
// Each entity has optional config as well, that can further describe
// how it is stored.
//
// Finally, entiy transitions can be specified to transfere entity
// between types.

const std = @import("std");
const Type = std.builtin.Type;
const root = @This();

pub const Id = extern struct {
    index: u32,
    gen: Gen,

    pub fn toRaw(self: Id) u64 {
        return @bitCast(self);
    }

    pub fn fromRaw(raw: u64) Id {
        return @bitCast(raw);
    }
};

pub const Gen = u32;

pub fn World(comptime E: type) type {
    return struct {
        pub const Entity = E;
        pub const Tag = std.meta.Tag(E);
        pub const Storage = root.Storage(E);
        pub const Header = root.Header(Tag);
        pub const GetType = MapUnion(E, mappers.AsStructOfPtrs);

        const Self = @This();

        const null_free = std.math.maxInt(u32);

        const Slot = struct {
            header: union {
                taken: Self.Header,
                free: u32,
            },
            gen: Gen,
        };

        entities: Self.Storage = .{},
        headers: std.ArrayListUnmanaged(Slot) = .{},
        free: u32 = null_free,

        pub fn deinit(self: *Self, alc: std.mem.Allocator) void {
            inline for (std.meta.fields(Self.Storage)) |field|
                @field(self.entities, field.name).deinit(alc);
            self.headers.deinit(alc);
            self.* = undefined;
        }

        pub fn kindOf(self: *Self, id: Id) ?Tag {
            const slot = self.getValidSlot(id) orelse return null;
            return slot.header.taken.tag;
        }

        pub fn add(self: *Self, alc: std.mem.Allocator, entity: E) !Id {
            return switch (entity) {
                inline else => |v, t| {
                    const arch = &@field(self.entities, @tagName(t));
                    const id = try self.allocHeader(alc, t, arch.len);
                    try arch.append(alc, appendBackRef(v, id));
                    return id;
                },
            };
        }

        pub fn get(self: *Self, id: Id) ?E {
            const slot = self.getValidSlot(id) orelse return null;
            return switch (slot.header.taken.tag) {
                inline else => |t| {
                    const VarTy = std.meta.FieldType(E, t);
                    const arch = @field(self.entities, @tagName(t)).get(slot.header.taken.index);
                    var value: VarTy = undefined;
                    inline for (std.meta.fields(VarTy)) |field|
                        @field(value, field.name) = @field(arch, field.name);
                    return @unionInit(E, @tagName(t), value);
                },
            };
        }

        pub fn getPtr(self: *Self, id: Id) ?GetType {
            const slot = self.getValidSlot(id) orelse return null;
            return switch (slot.header.taken.tag) {
                inline else => |t| {
                    const VarTy = std.meta.FieldType(E, t);
                    var arch = @field(self.entities, @tagName(t)).slice();
                    var ptrs: MapStruct(VarTy, mappers.AsPtr) = undefined;
                    inline for (std.meta.fields(VarTy), 0..) |field, i| {
                        @field(ptrs, field.name) = &accessMultyArrItem(
                            field.type,
                            i,
                            &arch.ptrs,
                            arch.len,
                        )[slot.header.taken.index];
                    }
                    return @unionInit(GetType, @tagName(t), ptrs);
                },
            };
        }

        pub fn remove(self: *Self, id: Id) ?E {
            const slot = self.getValidSlot(id) orelse return null;
            return switch (slot.header.taken.tag) {
                inline else => |t| {
                    const VarTy = std.meta.FieldType(E, t);
                    const arch = &@field(self.entities, @tagName(t));

                    const value_and_br = arch.get(slot.header.taken.index);
                    const last_index = arch.items(.back_ref)[arch.len - 1].index;
                    self.headers.items[last_index].header.taken.index = slot.header.taken.index;
                    arch.swapRemove(slot.header.taken.index);
                    self.freeHeader(id);

                    var value: VarTy = undefined;
                    inline for (std.meta.fields(VarTy)) |field|
                        @field(value, field.name) = @field(value_and_br, field.name);
                    return @unionInit(E, @tagName(t), value);
                },
            };
        }

        pub fn exchange(self: *Self, alc: std.mem.Allocator, id: Id, new: E) !bool {
            const slot = self.getValidSlot(id) orelse return false;

            switch (slot.header.taken.tag) {
                inline else => |t| {
                    const arch = &@field(self.entities, @tagName(t));
                    const last_index = arch.items(.back_ref)[arch.len - 1].index;
                    self.headers.items[last_index].header.taken.index = slot.header.taken.index;
                    arch.swapRemove(slot.header.taken.index);
                },
            }

            switch (new) {
                inline else => |v, t| {
                    const arch = &@field(self.entities, @tagName(t));
                    slot.header.taken = .{ .tag = t, .index = @intCast(arch.len) };
                    try arch.append(alc, appendBackRef(v, id));
                },
            }

            return true;
        }

        pub fn clear(self: *Self) void {
            inline for (std.meta.fields(Self.Storage)) |field|
                @field(self.entities, field.name).clear();
            self.headers.clear();
            self.free = null_free;
        }

        pub fn QueryOneRes(comptime Q: type) type {
            return Merge(
                MapStruct(RemoveField(Q, "stats"), mappers.AsPtr),
                if (@hasField(Q, "stats")) std.meta.Child(std.meta.FieldType(Q, .stats)) else struct {},
            );
        }

        pub fn queryOne(self: *Self, id: Id, comptime Q: type) ?QueryOneRes(Q) {
            const slot = self.getValidSlot(id) orelse return null;
            return switch (slot.header.taken.tag) {
                inline else => |t| {
                    const VarTy = std.meta.FieldType(E, t);
                    const vt_fields = std.meta.fields(VarTy);
                    var arch = @field(self.entities, @tagName(t)).slice();

                    var ptrs: QueryOneRes(Q) = undefined;
                    inline for (std.meta.fields(Q)) |f| {
                        if (comptime std.mem.eql(u8, f.name, "stats")) {
                            continue;
                        }

                        const fname = comptime for (vt_fields, 0..) |vf, i| {
                            if (std.mem.eql(u8, vf.name, f.name)) break i;
                        } else std.math.maxInt(usize);
                        if (fname == std.math.maxInt(usize)) {
                            return null;
                        }

                        @field(ptrs, f.name) = &accessMultyArrItem(
                            vt_fields[fname].type,
                            fname,
                            &arch.ptrs,
                            arch.len,
                        )[slot.header.taken.index];
                    }

                    if (@hasField(Q, "stats")) {
                        const stats = arch.items(.stats)[slot.header.taken.index];
                        inline for (std.meta.fields(std.meta.Child(std.meta.FieldType(Q, .stats)))) |f| {
                            @field(ptrs, f.name) = @field(stats, f.name);
                        }
                    }
                    return ptrs;
                },
            };
        }

        pub fn query(self: *Self, comptime Q: type) Query(Q) {
            var q: Query(Q) = .{};
            const QT = @TypeOf(q);

            comptime if (q.to_visit.len == 0) @compileError(@typeName(Q));

            inline for (q.to_visit, &q.sub_queries) |field, *sq| {
                const Field = std.meta.FieldType(E, field);
                const vt_fields = std.meta.fields(Field);
                var arch = @field(self.entities, @tagName(field)).slice();
                inline for (std.meta.fields(QT.QNoStats), sq.ptrs[0 .. sq.ptrs.len - 1]) |f, *ptr| {
                    const fname = comptime for (vt_fields, 0..) |vf, i| {
                        if (std.mem.eql(u8, vf.name, f.name)) break i;
                    } else unreachable;
                    const p = accessMultyArrItem(
                        vt_fields[fname].type,
                        fname,
                        &arch.ptrs,
                        arch.len,
                    ).ptr;
                    ptr.* = @alignCast(@ptrCast(p));
                }

                sq.ptrs[sq.ptrs.len - 1] = @ptrCast(arch.items(.back_ref).ptr);

                if (@hasField(Q, "stats")) {
                    inline for (std.meta.fields(QT.Stats), &sq.stat_offsets) |f, *so| {
                        so.* = @offsetOf(std.meta.Child(std.meta.FieldType(Field, .stats)), f.name);
                    }
                    sq.stats = @ptrCast(arch.items(.stats).ptr);
                }
                sq.len = arch.len;
            }

            return q;
        }

        pub fn nextId(self: *Self) Id {
            if (self.free == null_free) {
                return .{ .index = @intCast(self.headers.items.len), .gen = 0 };
            } else {
                const id = self.free;
                const slot = &self.headers.items[id];
                return .{ .index = id, .gen = slot.gen };
            }
        }

        pub fn Query(comptime Q: type) type {
            return struct {
                const StatsPtr = if (@hasField(Q, "stats")) std.meta.FieldType(Q, .stats) else *const struct {};
                const Stats = std.meta.Child(StatsPtr);
                const QNoStats = RemoveField(Q, "stats");

                const SubQuery = struct {
                    len: usize,
                    stat_offsets: [std.meta.fields(Stats).len]usize,
                    stats: [*][*]u8,
                    ptrs: [std.meta.fields(QNoStats).len + 1][*]u8,
                };

                const Selector = Merge(AppendBackRef(MapStruct(QNoStats, mappers.AsPtr)), Stats);

                const to_visit = b: {
                    var match_count: usize = 0;
                    for (std.meta.fields(E)) |field| match_count += @intFromBool(matches(field.type));

                    var fields: [match_count]Tag = undefined;
                    match_count = 0;
                    for (std.meta.fields(E)) |field| if (matches(field.type)) {
                        fields[match_count] = std.meta.stringToEnum(Tag, field.name).?;
                        match_count += 1;
                    };

                    break :b fields;
                };

                comptime to_visit: [to_visit.len]Tag = to_visit,
                arch_cursor: usize = 0,
                entity_cursor: usize = 0,
                sub_queries: [to_visit.len]SubQuery = undefined,

                pub fn next(self: *@This()) ?Selector {
                    while (self.arch_cursor < self.to_visit.len) {
                        const sub_query = self.sub_queries[self.arch_cursor];
                        if (self.entity_cursor == sub_query.len) {
                            self.arch_cursor += 1;
                            self.entity_cursor = 0;
                            continue;
                        }

                        var ptrs: Selector = undefined;
                        var i: usize = 0;
                        inline for (std.meta.fields(QNoStats), sub_query.ptrs[0 .. sub_query.ptrs.len - 1]) |field, p| {
                            const ptr: [*]field.type = @alignCast(@ptrCast(p));
                            @field(ptrs, field.name) = &ptr[self.entity_cursor];
                            i += 1;
                        }

                        const ptr: [*]Id = @alignCast(@ptrCast(sub_query.ptrs[sub_query.ptrs.len - 1]));
                        ptrs.back_ref = ptr[self.entity_cursor];

                        if (@hasField(Q, "stats")) {
                            const stats = sub_query.stats[self.entity_cursor];
                            inline for (std.meta.fields(Stats), sub_query.stat_offsets) |f, o| {
                                @field(ptrs, f.name) = @as(*const f.type, @alignCast(@ptrCast(stats + o))).*;
                            }
                        }

                        self.entity_cursor += 1;
                        return ptrs;
                    }
                    return null;
                }

                fn matches(comptime F: type) bool {
                    for (std.meta.fields(Q)) |field| {
                        if (field.type == StatsPtr) {
                            const other_stats = std.meta.Child(std.meta.FieldType(F, .stats));
                            for (std.meta.fields(std.meta.Child(StatsPtr))) |f| {
                                if (!@hasField(other_stats, f.name)) return false;
                            }
                            continue;
                        }
                        if (!@hasField(F, field.name)) return false;
                        for (std.meta.fields(F)) |f| {
                            if (!std.mem.eql(u8, f.name, field.name)) continue;
                            if (f.type != field.type) return false;
                            break;
                        } else {
                            @compileLog("Field type mismatch: " ++ @typeName(F) ++ " " ++ field.name ++ " " ++ @typeName(field.type));
                            return false;
                        }
                    }
                    return true;
                }
            };
        }

        fn getValidSlot(self: *Self, id: Id) ?*Slot {
            const slot = &self.headers.items[id.index];
            if (slot.gen != id.gen) return null;
            return slot;
        }

        fn allocHeader(self: *Self, alc: std.mem.Allocator, tag: Tag, index: usize) !Id {
            if (self.free == null_free) {
                try self.headers.append(alc, .{
                    .header = .{ .taken = .{
                        .tag = tag,
                        .index = @intCast(index),
                    } },
                    .gen = 0,
                });
                return .{ .index = @intCast(self.headers.items.len - 1), .gen = 0 };
            } else {
                const id = self.free;
                const slot = &self.headers.items[id];
                self.free = slot.header.free;
                slot.header = .{ .taken = .{
                    .tag = tag,
                    .index = @intCast(index),
                } };
                return .{ .index = id, .gen = slot.gen };
            }
        }

        fn freeHeader(self: *Self, id: Id) void {
            self.headers.items[id.index].header = .{ .free = self.free };
            self.headers.items[id.index].gen +%= 1;
            self.free = id.index;
        }
    };
}

fn accessMultyArrItem(comptime F: type, comptime index: usize, ptrs: [][*]u8, len: usize) []F {
    const byte_ptr = ptrs[index];
    const casted_ptr: [*]F = if (@sizeOf(F) == 0)
        undefined
    else
        @ptrCast(@alignCast(byte_ptr));
    return casted_ptr[0..len];
}

fn Storage(comptime E: type) type {
    const info = @typeInfo(E).Union;

    var fields: [info.fields.len]Type.StructField = undefined;
    for (&fields, info.fields) |*field, f| {
        const Ty = std.MultiArrayList(AppendBackRef(f.type));
        field.* = .{
            .name = f.name,
            .type = Ty,
            .alignment = @alignOf(Ty),
            .default_value = &Ty{},
            .is_comptime = false,
        };
    }

    return @Type(.{ .Struct = .{
        .fields = &fields,
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn AppendBackRef(comptime E: type) type {
    var info = @typeInfo(E).Struct;

    info.fields = info.fields ++ .{.{
        .name = "back_ref",
        .type = Id,
        .alignment = @alignOf(Id),
        .default_value = null,
        .is_comptime = false,
    }};

    return @Type(.{ .Struct = info });
}

fn appendBackRef(value: anytype, back_ref: Id) AppendBackRef(@TypeOf(value)) {
    var result: AppendBackRef(@TypeOf(value)) = undefined;
    inline for (std.meta.fields(@TypeOf(value))) |field|
        @field(result, field.name) = @field(value, field.name);
    result.back_ref = back_ref;
    return result;
}

fn MapUnion(comptime S: type, comptime map: fn (type) type) type {
    var info = @typeInfo(S).Union;

    var fields = info.fields[0..info.fields.len].*;
    for (&fields) |*field| field.type = map(field.type);
    info.fields = &fields;

    return @Type(.{ .Union = info });
}

fn MapStruct(comptime S: type, comptime map: fn (type) type) type {
    var info = @typeInfo(S).Struct;
    info.decls = &.{};

    var fields = info.fields[0..info.fields.len].*;
    for (&fields) |*field| {
        field.default_value = null;
        field.type = map(field.type);
    }
    info.fields = &fields;

    return @Type(.{ .Struct = info });
}

fn Header(comptime T: type) type {
    return packed struct(u32) {
        const Tag = T;
        const Index = std.meta.Int(.unsigned, 32 - @bitSizeOf(T));

        tag: Tag,
        index: Index,
    };
}

const mappers = struct {
    fn AsPtr(comptime T: type) type {
        return *T;
    }

    fn AsSlice(comptime T: type) type {
        return []T;
    }

    fn AsStructOfPtrs(comptime T: type) type {
        return MapStruct(T, AsPtr);
    }
};

fn Merge(comptime A: type, comptime B: type) type {
    var info = @typeInfo(A).Struct;

    info.fields = info.fields ++ @typeInfo(B).Struct.fields;

    return @Type(.{ .Struct = info });
}

fn RemoveField(comptime S: type, comptime field: []const u8) type {
    var info = @typeInfo(S).Struct;

    var fields = info.fields[0..info.fields.len].*;
    const index = for (&fields, 0..) |*f, i| if (std.mem.eql(u8, f.name, field)) break i else {} else return S;
    std.mem.copyForwards(Type.StructField, fields[index .. fields.len - 1], fields[index + 1 ..]);

    info.fields = fields[0 .. fields.len - 1];

    return @Type(.{ .Struct = info });
}

test {
    const alc = std.testing.allocator;

    const Enum = union(enum) {
        A: struct {
            a: u32,
            name: u64,
        },
        B: struct {
            b: f32,
            name: u64,
        },
    };

    _ = Storage(Enum);
    _ = MapStruct(struct { a: u32, b: f32 }, mappers.AsPtr);
    const W = World(Enum);
    var w = W{};
    defer w.deinit(alc);

    const a = try w.add(alc, .{ .A = .{ .a = 1, .name = 2 } });
    const b = try w.add(alc, .{ .A = .{ .a = 3, .name = 2 } });
    _ = w.getPtr(a) orelse unreachable;
    var av = w.get(a) orelse unreachable;
    try std.testing.expectEqual(av.A.a, 1);

    av = w.remove(a) orelse unreachable;
    try std.testing.expectEqual(av.A.a, 1);

    try std.testing.expectEqual(w.get(a), null);
    try std.testing.expectEqual(w.get(b), .{ .A = .{ .a = 3, .name = 2 } });

    const c = try w.add(alc, .{ .B = .{ .b = 4.0, .name = 5 } });

    var iter = w.query(struct { name: u64 });
    _ = iter.next() orelse unreachable;
    const ent = iter.next() orelse unreachable;
    try std.testing.expectEqual(ent.back_ref, c);
    try std.testing.expectEqual(iter.next(), null);

    const q1 = w.queryOne(b, struct { a: u32 }) orelse unreachable;
    try std.testing.expectEqual(q1.a.*, 3);
}
