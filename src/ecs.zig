const std = @import("std");

const IdBase = u64;
pub const Gen = u32;

/// Entities is an union of all the entities in the world
pub fn World(comptime E: type) type {
    return struct {
        pub const Entities = E;
        pub const Id = EntId(std.meta.Tag(E));

        const Storage = EntStorage(Entities);
        const Self = @This();

        storage: Storage = .{},

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            inline for (comptime std.meta.fieldNames(Storage)) |name| {
                @field(self.storage, name).deinit(alloc);
            }
        }

        pub fn get(self: *Self, id: Id) ?AsPtrUnion(E) {
            return switch (id.tag) {
                inline else => |e| if (@field(self.storage, @tagName(e)).get(id)) |v|
                    @unionInit(AsPtrUnion(E), @tagName(e), v)
                else
                    null,
            };
        }

        pub fn selectOne(self: *Self, id: Id, comptime M: type) ?AsPtrStruct(M) {
            return switch (id.tag) {
                inline else => |e| if (@field(self.storage, @tagName(e)).get(id)) |v| {
                    var new: AsPtrStruct(M) = undefined;
                    inline for (comptime std.meta.fieldNames(M)) |name| {
                        if (!@hasField(@TypeOf(v), name)) return null;
                        @field(new, name) = @field(v, name);
                    }
                    return new;
                } else null,
            };
        }

        pub fn add(self: *Self, alloc: std.mem.Allocator, value: E) !Id {
            return switch (value) {
                inline else => |v, e| try @field(self.storage, @tagName(e)).add(alloc, v),
            };
        }

        pub fn nextId(self: *Self, tag: std.meta.Tag(E)) Id {
            return switch (tag) {
                inline else => |e| @field(self.storage, @tagName(e)).nextId(),
            };
        }

        pub fn remove(self: *Self, alloc: std.mem.Allocator, id: Id) bool {
            return switch (id.tag) {
                inline else => |e| try @field(self.storage, @tagName(e)).remove(alloc, id),
            };
        }

        pub fn select(self: *Self, comptime M: type) MultiSelect(M) {
            var new: MultiSelect(M) = .{};
            comptime var count = 0;
            inline for (MultiSelect(M).captured_tags) |tag| {
                new.iters[count] = @field(self.storage, @tagName(tag)).select(M);
                count += 1;
            }
            return new;
        }

        pub fn MultiSelect(comptime M: type) type {
            return struct {
                const captured_tags = findMatches(M);

                comptime len: usize = captured_tags.len,
                cursor: usize = 0,
                iters: [captured_tags.len]Select(M) = undefined,

                pub fn next(self: *@This()) ?struct { ent: AsPtrStruct(M), id: Id } {
                    while (self.cursor < self.len) {
                        if (self.iters[self.cursor].next()) |item| {
                            return .{
                                .ent = item,
                                .id = .{
                                    .tag = captured_tags[self.cursor],
                                    .index = @intCast(self.iters[self.cursor].cursor - 1),
                                    .gen = item.gen.*,
                                },
                            };
                        }
                        self.cursor += 1;
                    }

                    return null;
                }
            };
        }

        fn findMatches(comptime M: type) []const std.meta.Tag(E) {
            var count: usize = 0;
            for (std.meta.fields(E)) |arch| count += @intFromBool(isMatch(arch.type, M));

            comptime var tags: [count]std.meta.Tag(E) = undefined;
            comptime var cursor = 0;
            inline for (std.meta.fields(E)) |arch| {
                if (comptime !isMatch(arch.type, M)) continue;
                tags[cursor] = std.meta.stringToEnum(std.meta.Tag(E), arch.name).?;
                cursor += 1;
            }

            return &tags;
        }

        fn isMatch(comptime EN: type, comptime M: type) bool {
            return for (std.meta.fields(M)) |model_field| {
                const present = for (std.meta.fields(EN)) |arch_field| {
                    if (std.mem.eql(u8, arch_field.name, model_field.name)) {
                        std.debug.assert(model_field.type == arch_field.type);
                        break true;
                    }
                } else false;

                if (!present) {
                    break false;
                }
            } else true;
        }
    };
}

pub fn EntId(comptime T: type) type {
    return packed struct(IdBase) {
        pub const Tag = T;
        pub const Index = std.meta.Int(.unsigned, @bitSizeOf(IdBase) - @bitSizeOf(Tag) - @bitSizeOf(Gen));

        const Self = @This();

        tag: Tag,
        index: Index,
        gen: Gen,

        pub fn fromRaw(base: IdBase) Self {
            return @bitCast(base);
        }

        pub fn toRaw(self: Self) IdBase {
            return @bitCast(self);
        }
    };
}

pub fn EntStorage(comptime E: type) type {
    const data = @typeInfo(E).Union;
    var fields: [data.fields.len]std.builtin.Type.StructField = undefined;
    inline for (&fields, data.fields) |*dst, src| {
        const Ty = Archetype(E, std.meta.stringToEnum(std.meta.Tag(E), src.name).?);
        dst.* = .{
            .name = src.name,
            .type = Ty,
            .default_value = &Ty{},
            .is_comptime = false,
            .alignment = @alignOf(Ty),
        };
    }

    return @Type(.{ .Struct = .{
        .layout = .Auto,
        .backing_integer = null,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn Archetype(comptime E: type, comptime field: std.meta.Tag(E)) type {
    return struct {
        pub const Entities = E;
        pub const Id = EntId(std.meta.Tag(E));
        pub const Field = std.meta.FieldType(Entities, field);
        pub const FieldWithGen = AddGen(Field);

        const Self = @This();
        const Storage = std.MultiArrayList(FieldWithGen);

        storage: Storage = .{},
        free: std.ArrayListUnmanaged(Id.Index) = .{},

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.storage.deinit(alloc);
            self.free.deinit(alloc);
        }

        pub fn nextId(self: *const Self) Id {
            const index = self.free.getLastOrNull() orelse self.storage.len;
            const gen = if (index == self.storage.len) 0 else self.storage.items(.gen)[index];
            return .{ .tag = field, .index = @intCast(index), .gen = gen };
        }

        pub fn get(self: *Self, id: Id) ?AsPtrStruct(Field) {
            if (!self.isVaid(id)) return null;

            var new: AsPtrStruct(Field) = undefined;
            inline for (comptime std.meta.fieldNames(Field)) |name|
                @field(new, name) = &self.storage
                    .items(nameToEnum(FieldWithGen, name))[id.index];

            return new;
        }

        pub fn add(self: *Self, alloc: std.mem.Allocator, value: Field) !Id {
            if (self.free.popOrNull()) |free| {
                inline for (comptime std.meta.fieldNames(Field)) |name| {
                    const findex = comptime nameToEnum(FieldWithGen, name);
                    self.storage.items(findex)[free] = @field(value, name);
                }

                return .{ .tag = field, .index = free, .gen = self.genOf(free) };
            }

            const index: Id.Index = @intCast(self.storage.len);
            try self.storage.append(alloc, append_gen(value, 0));

            return .{ .tag = field, .index = index, .gen = 0 };
        }

        pub fn remove(self: *Self, alloc: std.mem.Allocator, id: Id) !bool {
            if (!self.isValid(id)) return false;
            self.storage.items(.gen)[id.index] += 1;
            self.free.append(alloc, id.index);
            return true;
        }

        pub fn select(self: *Self, comptime M: type) Select(M) {
            var new = Select(M){};
            inline for (comptime std.meta.fieldNames(Select(M).Store)) |name|
                @field(new.slice, name) = self.storage
                    .items(nameToEnum(FieldWithGen, name));
            return new;
        }

        fn isVaid(self: *const Self, id: Id) bool {
            return self.genOf(id.index) == id.gen;
        }

        fn genOf(self: *const Self, id: Id.Index) Gen {
            return self.storage.items(.gen)[id];
        }
    };
}

fn nameToEnum(comptime S: type, comptime name: []const u8) std.meta.FieldEnum(S) {
    return std.meta.stringToEnum(std.meta.FieldEnum(S), name).?;
}

pub fn Select(comptime M: type) type {
    return struct {
        const SSelf = @This();
        const Store = AsSliceStruct(M);

        slice: Store = undefined,
        cursor: usize = 0,

        pub fn next(self: *SSelf) ?AsPtrStruct(M) {
            var res: AsPtrStruct(M) = undefined;
            inline for (comptime std.meta.fieldNames(Store)) |name| {
                if (self.cursor >= @field(self.slice, name).len) return null;
                @field(res, name) = &@field(self.slice, name)[self.cursor];
            }
            self.cursor += 1;
            return res;
        }
    };
}

pub fn AsPtrUnion(comptime E: type) type {
    comptime var data = @typeInfo(E).Union;
    comptime var new_fields = data.fields[0..data.fields.len].*;
    inline for (&new_fields) |*field| field.type = AsPtrStruct(field.type);
    data.fields = &new_fields;
    return @Type(.{ .Union = data });
}

pub fn AsPtrStruct(comptime S: type) type {
    comptime var data = @typeInfo(S).Struct;
    comptime var new_fields = data.fields[0..data.fields.len].*;
    inline for (&new_fields) |*field| field.type = *field.type;
    data.fields = &new_fields ++ .{std.builtin.Type.StructField{
        .name = "gen",
        .type = *Gen,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(*Gen),
    }};
    return @Type(.{ .Struct = data });
}

pub fn AsSliceStruct(comptime S: type) type {
    comptime var data = @typeInfo(S).Struct;
    comptime var new_fields = data.fields[0..data.fields.len].*;
    inline for (&new_fields) |*field| field.type = []field.type;
    data.fields = &new_fields ++ .{std.builtin.Type.StructField{
        .name = "gen",
        .type = []Gen,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf([]Gen),
    }};
    return @Type(.{ .Struct = data });
}

pub fn AddGen(comptime F: type) type {
    comptime var ty = @typeInfo(F).Struct;
    ty.fields = ty.fields ++ .{std.builtin.Type.StructField{
        .name = "gen",
        .type = Gen,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(Gen),
    }};
    return @Type(.{ .Struct = ty });
}

pub fn append_gen(value: anytype, gen: Gen) AddGen(@TypeOf(value)) {
    var new: AddGen(@TypeOf(value)) = undefined;
    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |name| {
        @field(new, name) = @field(value, name);
    }
    new.gen = gen;
    return new;
}

test {
    const Ent = union(enum) {
        Player: struct {
            pos: usize,
            rot: usize,
        },
        Block: struct {
            pos: usize,
        },
        Enemy: struct {
            rot: usize,
            fot: usize,
        },
    };

    const W = World(Ent);

    var w = W{};
    defer w.deinit(std.testing.allocator);

    _ = try w.add(std.testing.allocator, .{ .Player = .{ .pos = 1, .rot = 0 } });
    _ = try w.add(std.testing.allocator, .{ .Enemy = .{ .rot = 1, .fot = 0 } });

    var cursor = w.select(struct {
        rot: usize,
    });
    _ = cursor.next().?;
    _ = cursor.next().?;
    try std.testing.expect(cursor.next() == null);
}
