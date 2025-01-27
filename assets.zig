const std = @import("std");
const resources = @import("resources.zig");
const rl = @import("main.zig").rl;
const attacks = @import("attacks.zig");
const levels = @import("levels.zig");
const vec = @import("vec.zig");
const Game = @import("Game.zig");
const Vec = vec.T;
const cms = Game.cms;
const tof = @import("main.zig").tof;

pub const Frame = resources.sprites.Frame;

pub const Level = b: {
    const Spec = DeclEnum(levels);
    break :b struct {
        spec: Spec,

        const Self = @This();

        pub fn init(slot: *Self, comptime L: type, sheet: *rl.Texture2D, gpa: std.mem.Allocator) !void {
            slot.* = .{
                .spec = declToDeclEnum(levels, @as(L, undefined)),
            };

            const level = &@field(slot.spec, declToName(levels, L));
            level.* = L{};
            resolveRefs(level, level, "", &.{});
            sheet.* = try initTextures(&level.textures, gpa);
        }

        pub fn mount(self: *const Self, game: *Game) !void {
            try game.reset();
            switch (self.spec) {
                inline else => |*v| {
                    if (@hasField(@TypeOf(v.*), "attacks")) {
                        inline for (@typeInfo(@TypeOf(v.attacks)).Struct.fields, 0..) |f, i| {
                            const key = comptime b: {
                                var name: [f.name.len]u8 = undefined;
                                _ = std.ascii.upperString(&name, f.name);
                                break :b @field(rl, &name);
                            };
                            game.player_attacks[i] = Attack.new(key, @field(v.textures, f.name), @field(v.attacks, f.name));
                        }
                    }
                    try v.mount(game);
                },
            }
        }
    };
};

pub const Attack = b: {
    const State = DeclEnum(attacks);
    break :b struct {
        trigger: c_int,
        texture: Frame,
        cooldown: u32,
        duration: u32,
        ctor: State,

        recharge: u32 = 0,
        start: u32 = 0,
        state: ?State = null,

        const Self = @This();

        pub const none = Attack{
            .trigger = rl.KEY_NULL,
            .texture = undefined,
            .cooldown = 0,
            .duration = 0,
            .ctor = undefined,
        };

        pub fn new(trigger: c_int, texture: Frame, instance: anytype) Self {
            return .{
                .trigger = trigger,
                .texture = texture,
                .cooldown = @TypeOf(instance).cooldown,
                .duration = @TypeOf(instance).duration,
                .ctor = declToDeclEnum(attacks, instance),
            };
        }

        pub fn progress(self: *const Self, game: *const Game) f32 {
            return 1.0 - tof(self.recharge -| game.time) / tof(self.cooldown);
        }

        pub fn tryPoll(self: *Self, game: *Game) !void {
            if (self.state) |*s| {
                if (self.start + self.duration < game.time) {
                    self.state = null;
                    return;
                }

                switch (s.*) {
                    inline else => |*v| try v.poll(game),
                }
            }
        }

        pub fn crossHarePos(self: *@This(), game: *Game) Vec {
            return switch (self.ctor) {
                inline else => |*v| v.crossHarePos(game),
            };
        }

        pub fn tryTrigger(self: *Self, game: *Game) !void {
            if (rl.IsKeyDown(self.trigger) and game.timer(&self.recharge, self.cooldown)) {
                self.state = self.ctor;
                self.start = game.time;
                switch (self.state.?) {
                    inline else => |*v| if (@hasDecl(@TypeOf(v.*), "init")) try v.init(game),
                }
            }
        }
    };
};

pub fn declToName(comptime D: type, comptime T: type) [:0]const u8 {
    return for (@typeInfo(D).Struct.decls) |d| {
        if (@field(D, d.name) == T) break d.name;
    } else @compileError("invalid attack type '" ++ @typeName(T));
}

pub fn declToDeclEnum(comptime D: type, instance: anytype) DeclEnum(D) {
    return @unionInit(DeclEnum(D), declToName(D, @TypeOf(instance)), instance);
}

pub fn DeclEnum(comptime T: type) type {
    const decls = @typeInfo(T).Struct.decls;

    var elems: [decls.len]std.builtin.Type.UnionField = undefined;
    var variants: [decls.len]std.builtin.Type.EnumField = undefined;

    for (&elems, &variants, decls, 0..) |*e, *v, d, i| {
        e.* = .{
            .name = d.name,
            .type = @field(T, d.name),
            .alignment = @alignOf(@field(T, d.name)),
        };

        v.* = .{
            .name = d.name,
            .value = i,
        };
    }

    return @Type(.{ .Union = .{
        .layout = .auto,
        .tag_type = @Type(.{ .Enum = .{
            .tag_type = std.math.IntFittingRange(0, decls.len - 1),
            .fields = &variants,
            .decls = &.{},
            .is_exhaustive = true,
        } }),
        .fields = &elems,
        .decls = &.{},
    } });
}

fn initTextures(self: anytype, gpa: std.mem.Allocator) !rl.Texture2D {
    const info = @typeInfo(@TypeOf(self.*)).Struct;
    var images: [info.fields.len]rl.Image = undefined;
    inline for (info.fields, &images) |field, *i| {
        const data = @embedFile("assets/" ++ field.name ++ ".png");
        i.* = rl.LoadImageFromMemory(".png", data, data.len);
    }

    const frames: *[info.fields.len]Frame = @ptrCast(self);
    return try resources.sprites.pack(gpa, &images, frames, 128);
}

pub fn resolveRefs(
    level: anytype,
    cursor: anytype,
    comptime implicit_name: [:0]const u8,
    comptime default: *const @TypeOf(cursor.*),
) void {
    const info = @typeInfo(@TypeOf(cursor.*));
    if (info != .Struct) return;
    inline for (info.Struct.fields) |field| {
        comptime var matched = false;
        inline for (
            .{ "textures", "stats", "particles" },
            .{ Frame, Stats, ParticleStats },
        ) |name, ty| {
            const value: ?AssetRef(ty) = switch (field.type) {
                AssetRef(ty) => @field(default, field.name),
                ?AssetRef(ty) => @field(default, field.name),
                else => null,
            };

            if (value) |vl| {
                switch (vl) {
                    .implicit => {
                        @field(cursor, field.name) = .{ .value = &@field(@field(level, name), implicit_name) };
                    },
                    .name => |nm| {
                        @field(cursor, field.name) = .{ .value = &@field(@field(level, name), nm) };
                    },
                    .value => {},
                }
                matched = true;
            }
        }
        if (!matched) {
            resolveRefs(level, &@field(cursor, field.name), field.name, &@field(default, field.name));
        }
    }
}

pub const Stats = struct {
    fric: f32 = 0,
    speed: f32 = 0,
    cannon_speed: f32 = 0,
    size: f32 = 0,

    lifetime: u32 = 0,
    fade: bool = true,
    color: rl.Color = rl.WHITE,
    texture: ?AssetRef(Frame) = null,
    cannon_texture: ?AssetRef(Frame) = null,

    team: u32 = 0,
    max_health: u32 = 0,
    damage: u32 = 0,
    sight: f32 = 0,
    reload: u32 = 0,
    bullet: ?AssetRef(Stats) = null,
    trail: ?AssetRef(ParticleStats) = null,
    explosion: ?AssetRef(ParticleStats) = null,

    pub fn mass(self: *const @This()) f32 {
        return std.math.pow(f32, self.size, 2) * std.math.pi;
    }

    pub fn scale(self: *const @This()) f32 {
        std.debug.assert(self.texture.?.value.r.f.width == self.texture.?.value.r.f.height);
        return self.size / (self.texture.?.value.r.f.width / 2);
    }
};

pub fn AssetRef(comptime T: type) type {
    return union(enum) {
        implicit: void,
        name: [:0]const u8,
        value: *const T,
    };
}

pub const ParticleStats = struct {
    init_vel: f32 = 0,
    init_vel_variation: f32 = 0,
    offset: enum { after, center } = .center,
    lifetime_variation: u32 = 1,
    spawn_rate: u32 = 0,
    batch: u32 = 1,
    particle: AssetRef(Stats),
};
