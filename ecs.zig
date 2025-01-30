const std = @import("std");

pub const Id = enum(u64) {
    _,
    pub const invalid: Id = @enumFromInt(std.math.maxInt(u64));
};

pub fn World(comptime Ents: type) type {
    const Index = u32;
    const EntKind, const Storage = DeclEnum(Ents);

    const Version = packed struct(Index) {
        kind: KindBits,
        index: Num,

        const Num = std.meta.Int(.unsigned, @bitSizeOf(Index) - @bitSizeOf(EntKind));
        const KindBits = @typeInfo(EntKind).Enum.tag_type;

        pub fn eql(a: @This(), b: @This()) bool {
            return @as(Index, @bitCast(a)) == @as(Index, @bitCast(b));
        }
    };

    const Slot = struct {
        index: Index,
        version: Version,
    };

    return struct {
        gpa: std.mem.Allocator,
        slots: std.ArrayListUnmanaged(Slot) = .{},
        free_head: Index = invalid_index,
        ents: Storage = .{},

        pub const RawId = extern struct {
            version: Version,
            index: Index,

            fn toId(self: @This()) Id {
                return @enumFromInt(@as(u64, @bitCast(self)));
            }

            fn fromId(vl: Id) @This() {
                return @bitCast(@as(u64, @intFromEnum(vl)));
            }
        };

        const invalid_index = std.math.maxInt(Index);
        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.gpa);
            inline for (@typeInfo(Storage).Struct.fields) |f| {
                @field(self.ents, f.name).deinit(self.gpa);
            }
            self.* = undefined;
        }

        pub fn invoke(self: *Self, id: Id, comptime tag: anytype, args: anytype) ?void {
            const raw = RawId.fromId(id);
            switch (@as(EntKind, @enumFromInt(raw.version.kind))) {
                inline else => |t| if (@hasDecl(std.meta.TagPayload(Ents, t), @tagName(tag))) {
                    return @call(.always_inline, @field(std.meta.TagPayload(Ents, t), @tagName(tag)), .{self.get(id, std.meta.TagPayload(Ents, t)) orelse return} ++ args);
                },
            }

            return null;
        }

        pub fn invokeForAll(self: *Self, comptime tag: anytype, args: anytype) void {
            inline for (@typeInfo(Ents).Union.fields) |f| {
                if (@hasDecl(f.type, @tagName(tag))) {
                    for (@field(self.ents, f.name).items) |*ent| {
                        @call(.always_inline, @field(f.type, @tagName(tag)), .{ent} ++ args);
                    }
                }
            }
        }

        pub fn CnstType(comptime tag: anytype) type {
            return for (@typeInfo(Ents).Union.fields) |e| {
                if (@hasDecl(e.type, @tagName(tag))) break @TypeOf(@field(e.type, @tagName(tag)));
            } else @compileError("no ents have an occurence of " ++ @tagName(tag));
        }

        pub fn cnst(id: Id, comptime tag: anytype) CnstType(tag) {
            const table = comptime b: {
                var tbl = [_]CnstType(tag){0} ** @typeInfo(Ents).Union.fields.len;
                for (@typeInfo(Ents).Union.fields, &tbl) |e, *t| {
                    if (@hasDecl(e.type, @tagName(tag))) t.* = @field(e.type, @tagName(tag));
                }
                const tb = tbl;
                break :b &tb;
            };

            return table[RawId.fromId(id).version.kind];
        }

        pub fn isValid(self: *Self, id: Id) bool {
            const raw = RawId.fromId(id);
            return raw.version.eql(self.slots.items[raw.index].version);
        }

        pub fn get(self: *Self, id: Id, comptime T: type) ?*T {
            const tag = comptime tagForPayload(T);
            const raw = RawId.fromId(id);
            std.debug.assert(@intFromEnum(tag) == raw.version.kind);
            if (!raw.version.eql(self.slots.items[raw.index].version)) return null;
            return &@field(self.ents, @tagName(tag)).items[self.slots.items[raw.index].index];
        }

        pub fn tagForPayload(comptime P: type) EntKind {
            for (@typeInfo(Ents).Union.fields, 0..) |f, i| {
                if (f.type == P) return @enumFromInt(i);
            }

            @compileError("wah");
        }

        pub fn add(self: *Self, value: anytype) Id {
            const tag = comptime tagForPayload(@TypeOf(value));
            const arch = @tagName(tag);
            const loc = @field(self.ents, arch).addOne(self.gpa) catch unreachable;
            loc.* = value;
            loc.id = self.allocId(arch).toId();
            return loc.id;
        }

        pub fn Query(comptime Q: type) type {
            var count = 0;
            var names: [@typeInfo(Ents).Union.fields.len]type = undefined;
            for (@typeInfo(Ents).Union.fields) |f| {
                if (for (@typeInfo(Q).Enum.fields) |fil| {
                    if (!@hasField(f.type, fil.name)) break false;
                } else true) {
                    names[count] = []f.type;
                    count += 1;
                }
            }
            return std.meta.Tuple(names[0..count]);
        }

        pub fn slct(self: *Self, comptime Q: type) Query(Q) {
            var iter: Query(Q) = undefined;
            comptime var i = 0;
            inline for (@typeInfo(Ents).Union.fields) |f| {
                if (comptime for (@typeInfo(Q).Enum.fields) |fil| {
                    if (!@hasField(f.type, fil.name)) break false;
                } else true) {
                    iter[i] = @field(self.ents, f.name).items;
                    i += 1;
                }
            }
            return iter;
        }

        const Size = std.math.IntFittingRange(0, b: {
            var max = 0;
            for (@typeInfo(Ents).Union.fields) |f| max = @max(max, @sizeOf(f.type));
            break :b max;
        });

        const sizes = b: {
            var arr: [@typeInfo(Ents).Union.fields.len]Size = undefined;
            for (@typeInfo(Ents).Union.fields, &arr) |f, *s| s.* = @sizeOf(f.type);
            break :b arr;
        };

        fn offsets(comptime name: [:0]const u8) *const [@typeInfo(Ents).Union.fields.len]Size {
            // great xp zig...
            return comptime b: {
                var arr: [@typeInfo(Ents).Union.fields.len]Size = undefined;
                for (@typeInfo(Ents).Union.fields, &arr) |f, *so| {
                    so.* = if (@hasField(f.type, name)) @offsetOf(f.type, name) else std.math.maxInt(Size);
                }
                const r = arr;
                if (std.mem.allEqual(Size, &r, std.math.maxInt(Size))) {
                    @compileError("no entity has a field called " ++ name);
                }
                break :b &r;
            };
        }

        fn FieldType(name: [:0]const u8) type {
            return for (@typeInfo(Ents).Union.fields) |f| {
                if (@hasField(f.type, name)) break @TypeOf(@field(@as(f.type, undefined), name));
            } else @compileError("wah");
        }

        fn FieldStruct(comptime Q: type) type {
            const decls = @typeInfo(Q).Enum.fields;

            var stores: [decls.len]std.builtin.Type.StructField = undefined;

            for (&stores, decls) |*s, d| {
                const Str = *FieldType(d.name);
                s.* = .{
                    .name = d.name,
                    .type = Str,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Str),
                };
            }

            return @Type(.{ .Struct = .{
                .layout = .auto,
                .fields = &stores,
                .decls = &.{},
                .is_tuple = false,
            } });
        }

        pub fn validEnts(comptime Q: type) *const std.StaticBitSet(@typeInfo(Ents).Union.fields.len) {
            return comptime b: {
                var set = std.StaticBitSet(@typeInfo(Ents).Union.fields.len).initEmpty();

                for (@typeInfo(Ents).Union.fields, 0..) |f, i| {
                    if (for (@typeInfo(Q).Enum.fields) |fil| {
                        if (!@hasField(f.type, fil.name)) break false;
                    } else true) {
                        set.set(i);
                    }
                }
                const st = set;
                if (st.count() == 0) {
                    @compileError("no entity can be selected by " ++ @typeName(Q));
                }
                break :b &st;
            };
        }

        pub fn fields(self: *Self, ent: Id, comptime Q: type) ?FieldStruct(Q) {
            const valid = validEnts(Q);

            const raw = RawId.fromId(ent);

            if (!raw.version.eql(self.slots.items[raw.index].version)) return null;
            if (!valid.isSet(raw.version.kind)) return null;

            const index = self.slots.items[raw.index].index;
            const ents: *[@typeInfo(Ents).Union.fields.len]std.ArrayListUnmanaged(u8) = @ptrCast(&self.ents);
            var res: FieldStruct(Q) = undefined;
            inline for (@typeInfo(Q).Enum.fields) |f| {
                const offs = offsets(f.name);
                @field(res, f.name) = @alignCast(@ptrCast(&ents[raw.version.kind].items.ptr[sizes[raw.version.kind] * index + offs[raw.version.kind]]));
            }
            return res;
        }

        pub fn field(self: *Self, ent: Id, comptime tag: anytype) ?*(FieldType(@tagName(tag))) {
            const name = @tagName(tag);

            const raw = RawId.fromId(ent);
            if (!raw.version.eql(self.slots.items[raw.index].version)) return null;
            const offs = offsets(name);
            if (offs[raw.version.kind] == std.math.maxInt(Size)) return null;

            const index = self.slots.items[raw.index].index;
            const ents: *[@typeInfo(Ents).Union.fields.len]std.ArrayListUnmanaged(u8) = @ptrCast(&self.ents);

            return @alignCast(@ptrCast(&ents[raw.version.kind].items.ptr[sizes[raw.version.kind] * index + offs[raw.version.kind]]));
        }

        pub fn remove(self: *Self, ent: Id) bool {
            const raw = RawId.fromId(ent);
            const index, const kind = self.freeId(raw) orelse return false;
            switch (kind) {
                inline else => |t| {
                    const ents = &@field(self.ents, @tagName(t));
                    _ = ents.swapRemove(index);
                    if (ents.items.len != index) {
                        self.slots.items[RawId.fromId(ents.items[index].id).index].index = index;
                    }
                },
            }
            return true;
        }

        fn allocId(self: *Self, comptime arch: [:0]const u8) RawId {
            const index = @field(self.ents, arch).items.len;
            const slota = Slot{ .index = @intCast(index - 1), .version = .{ .kind = @intFromEnum(@field(EntKind, arch)), .index = 0 } };
            if (self.free_head == invalid_index) {
                self.slots.append(self.gpa, slota) catch unreachable;
                return .{ .index = @intCast(self.slots.items.len - 1), .version = slota.version };
            }

            const slot = self.free_head;
            self.free_head = self.slots.items[slot].index;
            const prev_version = self.slots.items[slot].version.index;
            self.slots.items[slot] = slota;
            self.slots.items[slot].version.index = prev_version;
            return .{ .index = slot, .version = self.slots.items[slot].version };
        }

        fn freeId(self: *Self, id: RawId) ?struct { Index, EntKind } {
            if (!self.slots.items[id.index].version.eql(id.version)) return null;
            const index = self.slots.items[id.index].index;
            self.slots.items[id.index].index = self.free_head;
            self.free_head = id.index;
            self.slots.items[id.index].version.index += 1;
            return .{ index, @enumFromInt(self.slots.items[id.index].version.kind) };
        }
    };
}

pub fn DeclEnum(comptime T: type) struct { type, type } {
    const decls = @typeInfo(T).Union.fields;

    var variants: [decls.len]std.builtin.Type.EnumField = undefined;
    var stores: [decls.len]std.builtin.Type.StructField = undefined;

    for (&variants, &stores, decls, 0..) |*v, *s, d, i| {
        v.* = .{
            .name = d.name,
            .value = i,
        };
        const Str = std.ArrayListUnmanaged(d.type);
        s.* = .{
            .name = d.name,
            .type = Str,
            .default_value = &Str{},
            .is_comptime = false,
            .alignment = @alignOf(Str),
        };
    }

    return .{ @typeInfo(T).Union.tag_type.?, @Type(.{ .Struct = .{
        .layout = .auto,
        .fields = &stores,
        .decls = &.{},
        .is_tuple = false,
    } }) };
}
