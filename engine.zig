const std = @import("std");
const ecs = @import("ecs.zig");
const rl = @import("rl.zig").rl;
const textures = @import("zig-out/sheet_frames.zig");

const Quad = @import("QuadTree.zig");
const Id = ecs.Id;

pub fn Level(comptime Spec: type) type {
    return @TypeOf(level(Spec, undefined, undefined));
}

const ColisionRec = struct { a: Id, b: Id, t: f32 };

const main = @import("main.zig");

pub fn level(comptime Spec: type, gpa: std.mem.Allocator, level_data: *main.SaveData) struct {
    level_data: *main.SaveData,
    spec: Spec = .{},
    world: World,
    quad: Quad,
    tile_map: TileMap,

    time: u32 = 0,
    boot_time: u32 = 0,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    player: Id = undefined,
    camera: rl.Camera2D = .{ .zoom = 1, .offset = .{ .x = 400, .y = 300 } },
    to_delete: std.ArrayList(Id),
    collisions: std.ArrayList(ColisionRec),
    won: bool = false,

    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const vec = @import("vec.zig");

    const Self = @This();
    const Vec = vec.T;
    const Ents = PackEnts(Spec);
    const World = ecs.World(Ents);

    pub const TileMap = struct {
        const Tile = std.math.IntFittingRange(0, Spec.tile_sheet.len);
        pub const no_tile = std.math.maxInt(Tile);
        pub const tile_size: u32 = @intFromFloat(Spec.tile_sheet[0].width * 2);
        pub const stride = (@as(u32, 1) << Spec.world_size_pow) / tile_size;
        const size = stride * stride;

        tiles: *[size]Tile,

        inline fn project(v: f32) u32 {
            return @intCast(std.math.clamp(@as(i32, @intFromFloat(v / tile_size)), 0, @as(i32, @intCast(stride - 1))));
        }

        pub inline fn get(self: *@This(), x: usize, y: usize) Tile {
            return self.tiles[y * stride + x];
        }

        pub inline fn set(self: *@This(), x: usize, y: usize, tile: Tile) void {
            self.tiles[y * stride + x] = tile;
        }

        pub fn draw(game: *Self, view_port: rl.Rectangle) void {
            const minx = project(view_port.x);
            const miny = project(view_port.y);
            const maxx = project(view_port.x + view_port.width + tile_size);
            const maxy = project(view_port.y + view_port.height + tile_size);

            const color = rl.WHITE;
            for (miny..maxy) |y| for (minx..maxx) |x| {
                const tile = game.tile_map.tiles[y * stride + x];
                const pos = Vec{ vec.tof(x * tile_size), vec.tof(y * tile_size) } + vec.splat(tile_size / 2);
                if (tile != no_tile) {
                    game.drawCenteredTexture(Spec.tile_sheet[tile], pos, 0, tile_size / 2, color);
                    continue;
                }

                const utils = struct {
                    pub inline fn sideMask(side: u2, value: bool) u8 {
                        return ([_]u8{ 0b111, 0b1_1_100, 0b111_0_000, 0b110_0_000_1 })[side] * @intFromBool(value);
                    }

                    pub inline fn cornerMask(side: u2, value: bool) u8 {
                        return ([_]u8{ 0b1, 0b100, 0b1_0_000, 0b0_100_0_000 })[side] * @intFromBool(value);
                    }
                };

                const s = stride - 1;
                const bitset: u8 =
                    utils.sideMask(0, y != 0 and game.tile_map.get(x, y - 1) == 0) |
                    utils.sideMask(1, x != s and game.tile_map.get(x + 1, y) == 0) |
                    utils.sideMask(2, y != s and game.tile_map.get(x, y + 1) == 0) |
                    utils.sideMask(3, x != 0 and game.tile_map.get(x - 1, y) == 0) |
                    utils.cornerMask(0, x != 0 and y != 0 and game.tile_map.get(x - 1, y - 1) == 0) |
                    utils.cornerMask(1, x != s and y != 0 and game.tile_map.get(x + 1, y - 1) == 0) |
                    utils.cornerMask(2, x != s and y != s and game.tile_map.get(x + 1, y + 1) == 0) |
                    utils.cornerMask(3, x != 0 and y != s and game.tile_map.get(x - 1, y + 1) == 0);

                for (0..8) |i| {
                    if (i % 2 == 0 and bitset & (@as(u8, 1) << @intCast(i)) != 0) {
                        game.drawCenteredTexture(Spec.weng_tiles[i % 2], pos, (std.math.tau / 4.0) * vec.tof(i / 2), tile_size / 2, color);
                    }
                }

                for (0..8) |i| {
                    if (i % 2 == 1 and bitset & (@as(u8, 1) << @intCast(i)) != 0) {
                        game.drawCenteredTexture(Spec.weng_tiles[i % 2], pos, (std.math.tau / 4.0) * vec.tof(i / 2), tile_size / 2, color);
                    }
                }
            };
        }
    };

    pub const Health = struct {
        points: u32,
        hit_tween: u32 = 0,

        pub fn draw(self: *@This(), ctx: anytype, game: *Self) f32 {
            var tone: f32 = 1;

            if (game.timeRem(self.hit_tween)) |n| {
                tone -= vec.divToFloat(n, Spec.hit_tween_duration);
            }

            if (self.points != @TypeOf(ctx.*).max_health) {
                const end = 360 * vec.divToFloat(self.points, @TypeOf(ctx.*).max_health);
                const size = @TypeOf(ctx.*).size;
                rl.DrawRing(vec.asRl(ctx.pos), size + 5, size + 8, 0.0, end, 50, rl.GREEN);
            }

            return tone;
        }

        pub fn takeDamage(self: *@This(), from: anytype, self_ref: Id, game: *Self) bool {
            if (World.cnst(self_ref, .team) == @TypeOf(from.*).team) return false;
            self.points -|= @TypeOf(from.*).damage;
            self.hit_tween = game.time + Spec.hit_tween_duration;
            const died = self.points == 0;
            if (died) game.queueDelete(self_ref);
            return died;
        }
    };

    pub const Phy = struct {
        coll_id: u32 = std.math.maxInt(u32),
        quad: Quad.Id = undefined,
    };

    pub const Turret = struct {
        rot: f32 = 0,
        reload: u32 = 0,
        target: Id = Id.invalid,

        pub fn update(self: *@This(), ctx: anytype, game: *Self) void {
            const Bullet = @TypeOf(ctx.*).Bullet;

            if (self.target != Id.invalid) if (game.world.field(self.target, .pos)) |target| b: {
                var pos = target.*;

                if (vec.dist(pos, ctx.pos) > @TypeOf(ctx.*).sight) {
                    break :b;
                }

                if (game.world.field(self.target, .vel)) |vel| {
                    pos = vec.predictTarget(ctx.pos, pos, vel.*, Bullet.speed) orelse break :b;
                }

                const dir = vec.norm(pos - ctx.pos);
                self.rot = vec.moveTowardsAngle(self.rot, vec.ang(dir), rl.GetFrameTime() * @TypeOf(ctx.*).turret_speed);
                self.rot = vec.normalizeAng(self.rot);

                const max_dist = World.cnst(self.target, .size) + Bullet.size;

                const offset_tolerance = std.math.asin(max_dist / vec.dist(pos, ctx.pos));

                if (@abs(self.rot - vec.ang(pos - ctx.pos)) < offset_tolerance and game.timer(&self.reload, @TypeOf(ctx.*).reload)) {
                    const bull = game.world.add(Bullet{
                        .pos = ctx.pos,
                        .vel = ctx.vel + vec.rad(self.rot, Bullet.speed),
                        .live_until = game.time + Bullet.lifetime,
                    });
                    game.initPhy(bull, Bullet);
                }

                return;
            };

            self.target = game.findEnemy(ctx, null) orelse Id.invalid;
        }
    };

    pub fn scrollZoom(self: *Self) void {
        const max_zoom = 2;
        const min_zoom = 0.5;
        const scroll = rl.GetMouseWheelMove();

        self.camera.zoom = std.math.clamp(self.camera.zoom + scroll / 2, min_zoom, max_zoom);
    }

    pub fn findEnemy(self: *Self, ctx: anytype, ignore_team: ?u32) ?Id {
        const pos = vec.asInt(ctx.pos);
        const size: i32 = @intFromFloat(@TypeOf(ctx.*).sight);
        const bds = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };
        var iter = self.quad.queryIter(bds, 0);
        while (iter.next()) |quid| for (self.quad.entities(quid)) |rid| {
            const id: Id = @enumFromInt(rid);
            if (@TypeOf(ctx.*).team == World.cnst(id, .team) or World.cnst(id, .team) == ignore_team) continue;
            if (World.cnst(id, .max_health) == 0) continue;
            const opos = (self.world.field(id, .pos) orelse continue).*;
            if (vec.dist(opos, ctx.pos) > @TypeOf(ctx.*).sight) continue;
            return id;
        };
        return null;
    }

    pub fn mousePos(self: *Self) Vec {
        return vec.fromRl(rl.GetScreenToWorld2D(rl.GetMousePosition(), self.camera));
    }

    const Frame = rl.Rectangle;

    pub fn drawTexture(self: *Self, texture: Frame, pos: Vec, size: f32, color: rl.Color) void {
        _ = self;
        const scale = size / (texture.width / 2);
        const real_width = texture.width * scale;
        const real_height = texture.height * scale;
        const dst = rl.Rectangle{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
        const origin = rl.Vector2{ .x = 0, .y = 0 };
        rl.DrawTexturePro(main.sheet, texture, dst, origin, 0, color);
    }

    pub fn drawReloadIndicators(self: *Self) void {
        inline for (self.world.slct(enum { pos, reload_timer })) |s| for (s) |ent| {
            const Ent = @TypeOf(ent);
            if (@hasDecl(Ent, "reload") and @hasDecl(Ent, "size") and @hasDecl(Ent, "color")) {
                self.drawReloadIndicator(ent.pos, ent.reload_timer, Ent.reload, Ent.size, Ent.color);
            }
        };

        inline for (self.world.slct(enum { pos, turret })) |s| for (s) |ent| {
            const Ent = @TypeOf(ent);
            if (@hasDecl(Ent, "reload") and @hasDecl(Ent, "size") and @hasDecl(Ent, "color")) {
                self.drawReloadIndicator(ent.pos, ent.turret.reload, Ent.reload, Ent.size, Ent.color);
            }
        };
    }

    pub fn drawReloadIndicator(self: *Self, pos: Vec, progress: u32, reload: u32, size: f32, color: rl.Color) void {
        if (self.timeRem(progress)) |rem| {
            const end = 360 * (1 - vec.divToFloat(rem, reload));
            rl.DrawRing(vec.asRl(pos), size + 10, size + 14, 0.0, end, 50, color);
        }
    }

    pub fn drawCenteredTexture(self: *Self, texture: Frame, pos: Vec, rot: f32, size: f32, color: rl.Color) void {
        _ = self;
        const scale = size / (texture.width / 2);
        const real_width = texture.width * scale;
        const real_height = texture.height * scale;
        const dst = rl.Rectangle{ .x = pos[0], .y = pos[1], .width = real_width, .height = real_height };
        const origin = rl.Vector2{ .x = real_width / 2, .y = real_height / 2 };
        rl.DrawTexturePro(main.sheet, texture, dst, origin, rot / std.math.tau * 360, color);
    }

    pub fn deinit(self: *Self) void {
        if (@hasDecl(Spec, "deinit")) self.spec.deinit(self.gpa);
        self.arena.deinit();
        self.world.deinit();
        self.quad.deinit(self.gpa);
        self.to_delete.deinit();
        self.collisions.deinit();
        self.gpa.destroy(self.tile_map.tiles);

        self.* = undefined;
    }

    pub fn initPhy(self: *Self, id: Id, comptime T: type) void {
        const ent = self.world.get(id, T).?;
        ent.phys.quad = self.quad.insert(
            self.gpa,
            vec.asInt(ent.pos),
            @intFromFloat(World.cnst(id, .size)),
            @intFromEnum(id),
        ) catch unreachable;
    }

    pub fn run(self: *Self) void {
        while (true) {
            {
                self.time = @intFromFloat(rl.GetTime() * 1000);
                self.boot_time = self.time;
                Spec.init(self);
                const player = self.world.get(self.player, Player).?;
                self.folowWithCamera(player.pos, 0);
            }

            while (self.world.isValid(self.player)) {
                if (rl.WindowShouldClose()) return;

                std.debug.assert(self.arena.reset(.retain_capacity));
                self.time = @intFromFloat(rl.GetTime() * 1000);

                if (self.update() and !self.won) {
                    if (self.world.get(self.player, Player)) |p| {
                        self.level_data.best_time = @min(self.level_data.best_time, self.time - self.boot_time);
                        self.level_data.no_hit = self.level_data.no_hit or
                            (@hasDecl(Player, "max_health") and
                            p.health.points == Player.max_health);
                    }
                    self.won = true;
                }

                self.input();

                rl.BeginDrawing();
                defer rl.EndDrawing();
                self.draw();

                if (rl.IsKeyPressed(rl.KEY_R)) break;
            }

            self.reset();
        }
    }

    pub fn reset(self: *Self) void {
        if (@hasDecl(Spec, "reset")) Spec.reset(self);
        self.won = false;
        self.player = undefined;
        self.world.deinit();
        self.quad.deinit(self.gpa);
        self.world = .{ .gpa = self.gpa };
        self.quad = Quad.init(self.gpa, 20) catch unreachable;
        self.prng = std.Random.DefaultPrng.init(0);
    }

    pub fn update(self: *Self) bool {
        self.world.invokeForAll(.update, .{self});
        var finished = false;
        if (@hasDecl(Spec, "update")) finished = Spec.update(self);

        for (self.to_delete.items) |id| {
            _ = self.world.invoke(id, .onDelete, .{self});
            if (self.world.field(id, .phys)) |phys| {
                self.quad.remove(self.gpa, phys.quad, @intFromEnum(id));
            }
            _ = self.world.remove(id);
        }
        self.to_delete.items.len = 0;

        return finished;
    }

    pub fn queueDelete(self: *Self, id: Id) void {
        self.to_delete.append(id) catch unreachable;
    }

    pub fn folowWithCamera(self: *Self, pos: Vec, lerp_coff: f32) void {
        self.camera.target = vec.asRl(std.math.lerp(pos, vec.fromRl(self.camera.target), vec.splat(lerp_coff)));
        self.camera.offset = .{
            .x = vec.tof(@divFloor(rl.GetScreenWidth(), 2)),
            .y = vec.tof(@divFloor(rl.GetScreenHeight(), 2)),
        };
    }

    pub fn updatePhysics(self: *Self) void {
        const delta = rl.GetFrameTime();
        inline for (self.world.slct(enum { pos, vel })) |s| for (s) |*ent| {
            ent.pos += ent.vel * vec.splat(delta);
            ent.vel *= vec.splat(1 - @TypeOf(ent.*).friction * delta);
        };
    }

    pub fn killTemporaryEnts(self: *Self) void {
        inline for (self.world.slct(enum { live_until })) |s| for (s) |tmp| {
            if (self.timeRem(tmp.live_until) == null) self.queueDelete(tmp.id);
        };
    }

    pub fn input(self: *Self) void {
        self.scrollZoom();
        if (@hasDecl(Spec, "input")) Spec.input(self);
    }

    fn draw(self: *Self) void {
        rl.ClearBackground(rl.BLACK);

        {
            rl.BeginMode2D(self.camera);

            const tl = rl.GetScreenToWorld2D(.{}, self.camera);
            const r = vec.tof(rl.GetScreenWidth());
            const b = vec.tof(rl.GetScreenHeight());
            const size = rl.Vector2Subtract(rl.GetScreenToWorld2D(.{ .x = r, .y = b }, self.camera), tl);
            TileMap.draw(self, .{ .x = tl.x, .y = tl.y, .width = size.x, .height = size.y });

            if (@hasDecl(Spec, "drawWorld")) Spec.drawWorld(self);

            rl.EndMode2D();
        }

        {
            const padding = 10;
            const font_size = 40;
            var cursor = Vec{ vec.tof(rl.GetScreenWidth()), padding };
            if (@hasDecl(Spec, "drawUi")) Spec.drawUi(self);

            if (@hasDecl(Spec, "time_limit")) {
                const spacing = 0;

                const rem = @min(self.time - self.boot_time, self.level_data.best_time);

                var buf: [32]u8 = undefined;
                var allc = std.heap.FixedBufferAllocator.init(&buf);

                const str = std.fmt.allocPrintZ(
                    allc.allocator(),
                    "{d}.{d}",
                    .{ rem / 1000, rem / 100 % 10 },
                ) catch unreachable;

                const text_size = vec.fromRl(rl.MeasureTextEx(main.font, str, font_size, spacing));

                var color = rl.WHITE;
                if (rem < Spec.time_limit) color = rl.GREEN;

                cursor[0] -= text_size[0] + padding;
                rl.DrawTextEx(main.font, str, vec.asRl(cursor), font_size, spacing, color);
            }

            if (self.level_data.no_hit) {
                cursor[0] -= textures.no_hit.width * 2 + padding;
                self.drawTexture(textures.no_hit, cursor, textures.no_hit.width, rl.WHITE);
            }
        }

        rl.DrawFPS(20, 20);
    }

    pub fn drawParticles(self: *Self) void {
        inline for (self.world.slct(enum { particle })) |s| for (s) |*pt| {
            pt.draw(self);
        };
    }

    const Player = std.meta.TagPayload(Ents, .player);

    pub fn drawVisibleEntities(self: *Self) void {
        const player = self.world.get(self.player, Player) orelse return;
        const width = @divFloor(rl.GetScreenWidth(), 2);
        const height = @divFloor(rl.GetScreenHeight(), 2);
        const cx, const cy = vec.asInt(player.pos);
        const bounds: [4]i32 = .{ cx - width, cy - height, cx + width, cy + height };

        var iter = self.quad.queryIter(bounds, 0);
        while (iter.next()) |quid| for (self.quad.entities(quid)) |uid| {
            const id: Id = @enumFromInt(uid);

            if (self.world.invoke(id, .draw, .{self}) == null) {
                rl.DrawCircleV(vec.asRl(self.world.field(id, .pos).?.*), World.cnst(id, .size), rl.RED);
            }
        };
    }

    pub fn drawOffScreenEnemyIndicators(self: *Self) void {
        const player = self.world.get(self.player, Player) orelse return;

        const tl = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(vec.zero), self.camera));
        const r = vec.tof(rl.GetScreenWidth());
        const b = vec.tof(rl.GetScreenHeight());
        const br = vec.fromRl(rl.GetScreenToWorld2D(vec.asRl(.{ r, b }), self.camera));
        const radius = 20;
        const font_size = 14;

        var dots = std.ArrayList(struct { Vec, usize }).init(self.arena.allocator());
        inline for (self.world.slct(enum { pos, indicated_enemy })) |s| for (s) |el| {
            const point =
                vec.intersect(0, el.pos, player.pos, tl[1], tl[0], br[0]) orelse
                vec.intersect(0, el.pos, player.pos, br[1], tl[0], br[0]) orelse
                vec.intersect(1, el.pos, player.pos, tl[0], tl[1], br[1]) orelse
                vec.intersect(1, el.pos, player.pos, br[0], tl[1], br[1]);

            if (point) |p| {
                for (dots.items) |*op| {
                    const diameter = radius * 2;
                    if (vec.dist2(op[0], p) < vec.tof(diameter * diameter)) {
                        op[1] += 1;
                        break;
                    }
                } else dots.append(.{ p, 1 }) catch unreachable;
            }
        };

        var buf: [10]u8 = undefined;
        for (dots.items) |*p| {
            var allc = std.heap.FixedBufferAllocator.init(&buf);
            const num = std.fmt.allocPrintZ(allc.allocator(), "{d}", .{p[1]}) catch undefined;
            const text_size = vec.fromRl(rl.MeasureTextEx(rl.GetFontDefault(), num, font_size, 0)) * vec.splat(0.5);
            const clamp_size = text_size + vec.splat(4);
            p[0] = std.math.clamp(p[0], tl + clamp_size, br - clamp_size);
            rl.DrawCircleV(vec.asRl(p[0]), vec.tof(radius), rl.RED);
            const point = vec.asInt(p[0] - text_size);
            rl.DrawText(num, point[0], point[1], font_size, rl.WHITE);
        }
    }

    pub fn handleCircleCollisions(self: *Self) void {
        const delta = rl.GetFrameTime();
        const Q = enum { pos, vel, phys };

        const util = enum {
            pub fn mass(size: f32) f32 {
                return size * size * std.math.pi;
            }
        };

        inline for (self.world.slct(Q)) |s| for (s) |*pb| {
            const pos = vec.asInt(pb.pos + pb.vel * vec.splat(0.5));
            const size: i32 = @intFromFloat(@TypeOf(pb.*).size * 2 + vec.len(pb.vel));
            const bb = .{ pos[0] - size, pos[1] - size, pos[0] + size, pos[1] + size };

            var query = self.quad.queryIter(bb, pb.phys.quad);
            while (query.next()) |qid| o: for (self.quad.entities(qid)) |rid| {
                const id: Id = @enumFromInt(rid);
                if (id == pb.id) continue;
                const opb = self.world.fields(id, Q) orelse continue;

                if (World.cnst(id, .team) == World.cnst(pb.id, .team)) continue;

                const g = @TypeOf(pb.*).size + World.cnst(id, .size);

                const dist = vec.dist2(pb.pos, opb.pos.*);
                if (g * g > dist) {
                    if (@TypeOf(pb.*).size > World.cnst(id, .size)) {
                        opb.pos.* = pb.pos + vec.norm(opb.pos.* - pb.pos) * vec.splat(g);
                    } else {
                        pb.pos = opb.pos.* + vec.norm(pb.pos - opb.pos.*) * vec.splat(g);
                    }
                }

                const d = opb.pos.* - pb.pos;
                const dv = opb.vel.* - pb.vel;

                const a = vec.dot(dv, dv);
                const b = 2 * vec.dot(dv, d);
                const c = vec.dot(d, d) - g * g;

                const disc = b * b - 4 * a * c;
                if (disc <= 0) continue;

                const t1 = (-b + std.math.sqrt(disc)) / (2 * a);
                const t2 = (-b - std.math.sqrt(disc)) / (2 * a);
                const t = @min(t1, t2);

                if (t < 0 or t > delta) continue;

                inline for (.{ pb, opb }) |p| {
                    if (p.phys.coll_id != std.math.maxInt(u32))
                        if (self.collisions.items[p.phys.coll_id].t > t) {
                            self.collisions.items[p.phys.coll_id].t = delta;
                        } else continue :o;
                }

                pb.phys.coll_id = @intCast(self.collisions.items.len);
                opb.phys.coll_id = @intCast(self.collisions.items.len);

                self.collisions.append(.{ .a = pb.id, .b = id, .t = t }) catch unreachable;
            };
        };

        for (self.collisions.items) |col| {
            const pb = self.world.fields(col.a, Q).?;
            const opb = self.world.fields(col.b, Q).?;

            pb.phys.coll_id = std.math.maxInt(u32);
            opb.phys.coll_id = std.math.maxInt(u32);

            if (col.t == delta) continue;

            pb.pos.* += pb.vel.* * vec.splat(col.t);
            opb.pos.* += opb.vel.* * vec.splat(col.t);

            const dist = vec.dist(pb.pos.*, opb.pos.*);

            {
                const mass = util.mass(World.cnst(col.a, .size));
                const amass = util.mass(World.cnst(col.b, .size));

                const norm = (opb.pos.* - pb.pos.*) / vec.splat(dist);
                const p = 2 * (vec.dot(pb.vel.*, norm) - vec.dot(opb.vel.*, norm)) / (mass + amass);

                inline for (.{ pb, opb }, .{ -amass, mass }) |c, m| {
                    c.vel.* += vec.splat(p * m) * norm;
                    c.pos.* += c.vel.* * vec.splat(delta - col.t);
                    c.pos.* -= c.vel.* * vec.splat(delta);
                }
            }

            _ = self.world.invoke(col.a, .onCollision, .{ self, col.b });
            _ = self.world.invoke(col.b, .onCollision, .{ self, col.a });
        }
        self.collisions.items.len = 0;
    }

    pub fn timer(self: *Self, state: *u32, duration: u32) bool {
        if (state.* > self.time) return false;
        state.* = self.time + duration;
        return true;
    }

    pub fn timeRem(self: *Self, until: u32) ?u32 {
        return std.math.sub(u32, until, self.time) catch null;
    }
} {
    const Self = Level(Spec);

    return .{
        .level_data = level_data,
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .world = .{ .gpa = gpa },
        .to_delete = std.ArrayList(Id).init(gpa),
        .collisions = std.ArrayList(ColisionRec).init(gpa),
        .quad = Quad.init(gpa, Spec.world_size_pow) catch unreachable,
        .tile_map = .{
            .tiles = b: {
                const tiles = gpa.create([Self.TileMap.size]Self.TileMap.Tile) catch unreachable;
                for (tiles) |*t| t.* = Self.TileMap.no_tile;
                break :b tiles;
            },
        },
    };
}

pub fn PackEnts(comptime S: type) type {
    const decls = @typeInfo(S).@"struct".decls;

    var enum_buf: [decls.len]std.builtin.Type.EnumField = undefined;
    var var_buf: [decls.len]std.builtin.Type.UnionField = undefined;
    var count = 0;
    for (decls) |d| {
        const value = @field(S, d.name);
        if (@TypeOf(value) != type) continue;
        if (@typeInfo(value) != .@"struct") continue;
        if (@typeInfo(value).@"struct".fields.len == 0) continue;
        if (!std.meta.eql(@typeInfo(value).@"struct".fields[0], @typeInfo(struct { id: Id = undefined }).@"struct".fields[0])) continue;

        const name = b: {
            var buf: [64]u8 = undefined;
            var i = 0;
            for (d.name) |c| {
                if (std.ascii.isUpper(c) and i != 0) {
                    buf[i] = '_';
                    i += 1;
                }
                buf[i] = std.ascii.toLower(c);
                i += 1;
            }
            buf[i] = 0;
            break :b buf[0..i :0];
        };

        enum_buf[count] = .{ .name = name, .value = count };
        var_buf[count] = .{ .name = name, .type = value, .alignment = @alignOf(value) };
        count += 1;
    }

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = @Type(.{ .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, count - 1),
            .fields = enum_buf[0..count],
            .decls = &.{},
            .is_exhaustive = true,
        } }),
        .fields = var_buf[0..count],
        .decls = &.{},
    } });
}
