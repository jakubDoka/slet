const std = @import("std");
const ecs = @import("ecs.zig");
const rl = @import("raylib");
const Quad = @import("QuadTree.zig");
const vec = @import("vec.zig");

const Vec = vec.T;
const Type = std.builtin.Type;
pub const Entity = []const type;

pub usingnamespace variants;

pub const variants = struct {
    pub const InQuad = struct {
        pub const Stats = struct {
            radius: f32,
        };

        pub const Init = struct {
            pos: Vec,
            team: Team.Id,
            teams: *Team.Store,
            alc: std.mem.Allocator,
        };

        quad_id: Quad.Id,
        team: Team.Id,

        pub fn init(stats: Stats, in: Init, id: ecs.Id) !@This() {
            return .{
                .quad_id = try in.teams.get(in.team).quad
                    .insert(in.alc, vec.asInt(in.pos), @intFromFloat(stats.radius), id.toRaw()),
                .team = in.team,
            };
        }

        pub fn bounds(pos: Vec, radius: f32) [4]i32 {
            return [_]i32{
                @intFromFloat(pos[0] - radius),
                @intFromFloat(pos[1] - radius),
                @intFromFloat(pos[0] + radius),
                @intFromFloat(pos[1] + radius),
            };
        }
    };

    pub const Alive = struct {
        pub const Stats = struct {
            max_health: u32,
        };

        health: u32,

        pub fn init(stats: Stats) @This() {
            return .{ .health = stats.max_health };
        }
    };

    pub const Moving = struct {
        pub const Stats = struct {
            accel: f32,
            friction: f32,
        };

        vel: Vec = vec.zero,
    };

    pub const StaticMovement = struct {
        vel: Vec = vec.zero,
    };

    pub const Harmful = struct {
        pub const Stats = struct {
            damage: u32,
            cooldown: u32 = 0,
        };

        next_hit_after: u32 = 0,
    };

    pub const Temporary = struct {
        pub const Stats = struct {
            ttl: u32,
        };

        pub const Init = struct {
            time_millis: u32,
        };

        ttl: u32,

        pub fn init(stats: Stats, in: Init) @This() {
            return .{ .ttl = stats.ttl + in.time_millis };
        }
    };

    pub const Positioned = struct {
        pos: Vec,
    };

    pub const Turret = struct {
        pub const Stats = struct {
            range: f32,
            reload_time: u32,
        };

        target: ?ecs.Id = null,
        reload_until: u32 = 0,
    };

    pub const Mountable = struct {
        base: ecs.Id,
        slot: u32 = 0,
    };

    pub const MountSlots = struct {
        const Stats = struct {
            slot_offsets: []const Vec = &.{.{ 0, 0 }},
        };
    };

    pub const Segment = struct {
        rot: f32 = 0,
        next: ?ecs.Id = null,
        prev: ?ecs.Id = null,

        pub fn remove(world: anytype, target: ecs.Id) void {
            const selected = world.queryOne(target, Segment) orelse unreachable;
            removeOwned(world, selected.prev.*, selected.next.*);
        }

        pub fn removeOwned(world: anytype, prev: ?ecs.Id, next: ?ecs.Id) void {
            if (next) |nxt| if (world.queryOne(nxt, Segment)) |n| {
                n.prev.* = prev;
            };
            if (prev) |prv| if (world.queryOne(prv, Segment)) |p| {
                p.next.* = next;
            };
        }

        pub fn insert(world: anytype, after: ecs.Id, target: ecs.Id) void {
            const selected = world.queryOne(target, Segment) orelse unreachable;
            const placement = world.queryOne(after, Segment) orelse unreachable;
            selected.prev.* = after;
            selected.next.* = placement.next.*;
            if (placement.next.*) |next| if (world.queryOne(next, Segment)) |n| {
                n.prev.* = target;
            };
            placement.next.* = target;
        }
    };

    pub const Core = MarkerType("core");

    pub const ViwableStats = struct {
        show_stats_until: u32 = 0,

        pub fn trigger(value: *u32, time: u32) void {
            value.* = time + 1000;
        }
    };

    pub fn MarkerType(comptime marker_name: []const u8) type {
        return struct {
            pub const Stats = @Type(.{ .Struct = .{
                .fields = &.{.{
                    .name = marker_name,
                    .type = void,
                    .alignment = 0,
                    .is_comptime = false,
                    .default_value = &{},
                }},
                .layout = .Auto,
                .decls = &.{},
                .is_tuple = false,
            } });
        };
    }
};

pub const Team = struct {
    pub const invalid_id = std.math.maxInt(Id);

    pub const Id = u32;

    pub const Filter = union(enum) {
        All,
        Only: Id,
        Except: Id,
    };

    pub const Store = struct {
        slots: std.ArrayListUnmanaged(Team) = .{},

        pub fn deinit(self: *Store, alc: std.mem.Allocator) void {
            self.clear(alc);
            self.slots.deinit(alc);
            self.* = undefined;
        }

        pub fn add(self: *Store, alc: std.mem.Allocator, team: Team) !Id {
            try self.slots.append(alc, team);
            return @intCast(self.slots.items.len - 1);
        }

        pub fn get(self: *Store, id: Id) *Team {
            return &self.slots.items[id];
        }

        pub fn clear(self: *Store, alc: std.mem.Allocator) void {
            for (self.slots.items) |*slot| slot.deinit(alc);
            self.slots.items.len = 0;
        }
    };

    quad: Quad = .{ .radius = 0 },

    pub fn init(alc: std.mem.Allocator) !Team {
        return .{ .quad = try Quad.init(alc, 1 << 14) };
    }

    pub fn deinit(self: *Team, alc: std.mem.Allocator) void {
        self.quad.deinit(alc);
        self.* = undefined;
    }
};

pub fn initEnt(
    comptime types: Entity,
    next_id: ecs.Id,
    stats: *const MergeStats(types),
    in: MergeInits(types),
) !MergeComps(types) {
    var comps: MergeComps(types) = undefined;
    comps.stats = stats;
    inline for (std.meta.fields(MergeComps(types))) |f| if (f.default_value) |dv| {
        @field(&comps, f.name) = @as(*const f.type, @alignCast(@ptrCast(dv))).*;
    };

    inline for (types) |t| {
        if (!@hasDecl(t, "init")) {
            assignCommonFields(&comps, &in);
            continue;
        }

        const init = t.init;

        const Stats = if (@hasDecl(t, "Stats")) t.Stats else void;
        var sub_stats: Stats = undefined;
        assignCommonFields(&sub_stats, stats);

        const Init = if (@hasDecl(t, "Init")) t.Init else void;
        var sub_in: Init = undefined;
        assignCommonFields(&sub_in, &in);

        const argCount = @typeInfo(@TypeOf(init)).Fn.params.len;
        const init_val = switch (argCount) {
            1 => init(sub_stats),
            2 => init(sub_stats, sub_in),
            3 => init(sub_stats, sub_in, next_id),
            else => @compileError("init function has too many arguments"),
        };

        const unwrapped_val = if (@typeInfo(@TypeOf(init_val)) == .ErrorUnion)
            try init_val
        else
            init_val;

        assignCommonFields(&comps, &unwrapped_val);
    }

    return comps;
}

test {
    const dummy: Entity = &.{ variants.Alive, variants.Moving, variants.Positioned };

    const v = try initEnt(
        dummy,
        undefined,
        &.{ .max_health = 100, .accel = 1.0, .friction = 0.5 },
        .{ .pos = vec.zero },
    );
    _ = v;
}

fn assignCommonFields(dst: anytype, src: anytype) void {
    const DstTy = std.meta.Child(@TypeOf(dst));
    const SrcTy = std.meta.Child(@TypeOf(src));

    if (DstTy == void or SrcTy == void) return;

    inline for (std.meta.fields(DstTy)) |f| {
        if (!@hasField(SrcTy, f.name)) continue;
        @field(dst, f.name) = @field(src, f.name);
    }
}

pub fn MergeComps(comptime types: []const type) type {
    return JustMerge(types ++ .{struct { stats: *const MergeStats(types) }});
}

pub fn MergeStats(comptime types: []const type) type {
    return MergeDecl(types, "Stats", false);
}

pub fn MergeInits(comptime types: []const type) type {
    return MergeDecl(types, "Init", true);
}

fn MergeDecl(comptime types: []const type, comptime name: []const u8, comptime default_to_self: bool) type {
    var decls: [types.len]type = undefined;
    var i: usize = 0;
    for (types) |t| if (@hasDecl(t, name)) {
        decls[i] = @field(t, name);
        i += 1;
    } else if (default_to_self and !@hasDecl(t, "init")) {
        decls[i] = t;
        i += 1;
    };
    return JustMerge(decls[0..i]);
}

// fields are deduped
fn JustMerge(comptime types: []const type) type {
    var field_count: usize = 0;
    for (types) |t| field_count += std.meta.fields(t).len;

    var fields: [field_count]Type.StructField = undefined;
    var i: usize = 0;
    for (types) |t| {
        o: for (std.meta.fields(t)) |f| {
            for (fields[0..i]) |*field| if (std.mem.eql(u8, field.name, f.name)) {
                if (field.type != f.type) {
                    @compileError("duplicate fields do not have same type (" ++
                        f.name ++ ")" ++ @typeName(t) ++ " != " ++ @typeName(field.type));
                }
                continue :o;
            };
            fields[i] = f;
            i += 1;
        }
    }

    return @Type(.{ .Struct = .{
        .fields = fields[0..i],
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn queryEnt(ent: anytype, comptime Q: type) ?InlinedStats(Q) {
    return switch (ent) {
        inline else => |v| {
            var q: InlinedStats(Q) = undefined;

            inline for (std.meta.fields(Q)) |field| {
                if (comptime std.mem.eql(u8, field.name, "stats")) continue;
                if (!@hasField(@TypeOf(v), field.name)) return null;
                @field(q, field.name) = @field(v, field.name);
            }

            if (@hasField(Q, "stats")) {
                const stats = v.stats;
                inline for (std.meta.fields(std.meta.Child(std.meta.FieldType(Q, .stats)))) |field| {
                    if (!@hasField(@TypeOf(stats.*), field.name)) return null;
                    @field(q, field.name) = @field(stats, field.name);
                }
            }

            return q;
        },
    };
}

fn InlinedStats(comptime Q: type) type {
    if (!@hasField(Q, "stats")) return Q;

    const Stats = std.meta.Child(std.meta.FieldType(Q, .stats));

    var fields: [std.meta.fields(Q).len + std.meta.fields(Stats).len - 1]Type.StructField = undefined;
    var i: usize = 0;
    for (std.meta.fields(Q)) |f| {
        if (std.mem.eql(u8, f.name, "stats")) continue;
        fields[i] = f;
        i += 1;
    }
    for (std.meta.fields(Stats)) |f| {
        fields[i] = f;
        i += 1;
    }

    return @Type(.{ .Struct = .{
        .fields = &fields,
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
    } });
}
