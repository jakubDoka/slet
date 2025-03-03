const std = @import("std");
const debug = @import("builtin").mode == .Debug;

fn dbg(any: anytype) @TypeOf(any) {
    std.debug.print("{any}\n", .{any});
    return any;
}

pub fn BuddyAllocator(
    comptime T: type,
    comptime sentinel: T,
    comptime max_cap_pow2: comptime_int,
    comptime base_cap_pow2: comptime_int,
) type {
    return struct {
        mem: []align(@alignOf(FreeHeader)) T = &.{},
        sclasses: [sclass_count]Index = [_]Index{index_sentinel} ** sclass_count,
        alloc_count: @TypeOf(default_int) = default_int,

        const default_int = if (debug) @as(usize, 0);

        comptime {
            if (base_cap * @sizeOf(T) < @sizeOf(FreeHeader)) {
                @compileError("the base cap is too small to fit the Allocator metadata, " ++
                    "the smalles possible valid base_cap_pow2 is " ++
                    std.fmt.comptimePrint(
                    "{d}",
                    .{std.math.log2_int_ceil(usize, @max(@sizeOf(FreeHeader) / @sizeOf(T), 1))},
                ));
            }
        }

        const Self = @This();
        pub const Elem = T;
        pub const SClass = std.meta.Int(.unsigned, std.math.log2_int_ceil(u16, sclass_count));
        pub const Index = Size;
        pub const Size = std.meta.Int(.unsigned, max_cap_pow2);

        pub const index_sentinel = std.math.maxInt(Index);
        pub const sclass_count = max_cap_pow2 - (base_cap_pow2 - 1);
        pub const base_cap = 1 << base_cap_pow2;
        pub const min_mem = base_cap * 2;
        pub const max_mem = 1 << max_cap_pow2;
        pub const uninit = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "uninit"))
                T.uninit
            else
                invertBits(sentinel),
            else => invertBits(sentinel),
        };

        const FreeHeader = struct {
            sentinel: T = sentinel,
            prev: Index,
            next: Index,
        };

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.mem);
            if (debug and self.alloc_count != 0) std.debug.panic("{d} leaked", .{self.alloc_count});
            self.* = undefined;
        }

        pub fn alloc(self: *Self, gpa: std.mem.Allocator, size: Size) !Index {
            std.debug.assert(std.math.isPowerOfTwo(size));
            std.debug.assert(size >= 1 << base_cap_pow2);

            const sclass = sclassOf(size);
            var max_sclass = maxSclass(@max(self.mem.len, size));
            const alloc_sclass: SClass = for (self.sclasses[sclass .. max_sclass + 1], sclass..) |head, i| {
                if (head != index_sentinel) break @intCast(i);
            } else b: {
                const old_size = self.mem.len;
                const new_size = @max(min_mem, std.math.ceilPowerOfTwo(usize, old_size + size) catch unreachable);
                if (new_size > max_mem) return error.OutOfMemory;
                self.mem = try gpa.realloc(self.mem, new_size);

                if (old_size == 0) {
                    self.freeNoDefrag(0, sclassOf(@intCast(new_size)));
                } else {
                    var cursor: Size = @intCast(old_size);
                    while (true) {
                        self.freeNoDefrag(cursor, max_sclass);
                        if (cursor >= new_size / 2) break;
                        cursor *= 2;
                        max_sclass += 1;
                    }
                }
                max_sclass = maxSclass(self.mem.len);
                break :b for (self.sclasses[sclass .. max_sclass + 1], sclass..) |head, i| {
                    if (head != index_sentinel) break @intCast(i);
                } else unreachable;
            };

            const allc = self.sclasses[alloc_sclass];
            const header = self.getHeader(allc).?;
            self.removeHeader(header, alloc_sclass);

            var cursor = allc +% size;
            var step = size;
            for (sclass..alloc_sclass) |sclss| {
                self.freeNoDefrag(cursor, @intCast(sclss));
                cursor +%= step;
                step *%= 2;
            }

            if (debug) self.alloc_count += 1;

            return allc;
        }

        pub fn shrink(self: *Self, idx: Index, size: Size) void {
            self.freeNoDefrag(idx + size / 2, sclassOf(size / 2));
        }

        pub fn grow(self: *Self, idx: Index, size: Size) bool {
            _ = self;
            _ = idx;
            _ = size;
            return false;
            //const sclass = sclassOf(size);
            //const buddyPos = buddyPosOf(idx, sclass);
            //if (buddyPos < idx or buddyPos > self.mem.len) return false;
            //const header = self.getHeader(buddyPos) orelse return false;
            //self.removeHeader(header, sclass);
            //return true;
        }

        pub fn free(self: *Self, idx: Index, size: Size) void {
            var curIdx = idx;
            var sclass = sclassOf(size);
            while (true) {
                const buddyPos = buddyPosOf(curIdx, sclass);
                if (buddyPos >= self.mem.len) break;
                std.debug.assert(buddyPos < self.mem.len);
                if (self.getHeader(buddyPos)) |buddy| {
                    if (sclass == 0 or b: {
                        const header = self.getHeader(buddyPos + base_cap) orelse break :b false;
                        break :b header.next == std.math.maxInt(Index) and sclass == header.prev;
                    })
                        self.removeHeader(buddy, sclass)
                    else
                        break;
                } else break;
                curIdx = @min(buddyPos, curIdx);
                sclass += 1;
            }

            std.debug.assert(!isSentinel(self.mem[curIdx]));
            self.freeNoDefrag(curIdx, sclass);

            if (debug) self.alloc_count -= 1;
        }

        fn freeNoDefrag(self: *Self, curIdx: Index, sclass: SClass) void {
            const header = self.getHeaderUnchecked(curIdx);
            header.* = .{
                .next = index_sentinel,
                .prev = self.sclasses[sclass],
            };
            std.debug.assert(self.getHeader(curIdx) != null);
            if (self.sclasses[sclass] != index_sentinel) {
                std.debug.assert(self.getHeader(self.sclasses[sclass]).?.next == index_sentinel);
                self.getHeader(self.sclasses[sclass]).?.next = curIdx;
            }
            if (sclass != 0) {
                self.getHeaderUnchecked(curIdx + base_cap).* = .{
                    .next = std.math.maxInt(Index),
                    .prev = sclass,
                };
            }
            self.sclasses[sclass] = curIdx;
        }

        fn removeHeader(self: *Self, header: *FreeHeader, sclass: SClass) void {
            if (header.prev != index_sentinel) {
                std.debug.assert(self.getHeader(self.getHeader(header.prev).?.next) == header);
                self.getHeader(header.prev).?.next = header.next;
            }
            if (header.next != index_sentinel) {
                std.debug.assert(self.getHeader(self.getHeader(header.next).?.prev) == header);
                self.getHeader(header.next).?.prev = header.prev;
            } else {
                std.debug.assert(self.getHeader(self.sclasses[sclass]).? == header);
                self.sclasses[sclass] = header.prev;
            }
            header.sentinel = uninit;
        }

        fn getHeader(self: *Self, pos: usize) ?*FreeHeader {
            const header = self.getHeaderUnchecked(pos);
            if (!isSentinel(header.sentinel)) return null;
            return header;
        }

        fn getHeaderUnchecked(self: *Self, pos: usize) *FreeHeader {
            return @alignCast(@ptrCast(&self.mem[pos]));
        }

        fn isSentinel(value: T) bool {
            if (std.meta.hasFn(T, "eql")) {
                return T.eql(value, sentinel);
            }
            return std.meta.eql(value, sentinel);
        }

        fn buddyPosOf(idx: Index, sclass: SClass) usize {
            const sclss = sclass + base_cap_pow2;
            std.debug.assert(idx & ((@as(usize, 1) << sclss) -% 1) == 0);
            return idx ^ (@as(usize, 1) << sclss);
        }

        pub fn sclassOf(size: Size) SClass {
            return @intCast(std.math.log2_int(Size, size) - base_cap_pow2);
        }

        pub fn sizeOf(sclass: SClass) usize {
            return @as(usize, 1) << (@as(u6, sclass) + base_cap_pow2);
        }

        fn maxSclass(len: usize) SClass {
            return std.math.log2_int(Size, @intCast(len / 2)) + 1 - base_cap_pow2;
        }

        fn invertBits(value: anytype) @TypeOf(value) {
            var inverted: @TypeOf(value) = undefined;
            switch (@typeInfo(@TypeOf(value))) {
                .@"struct" => |s| for (s.fields) |field| {
                    @field(inverted, field.name) = invertBits(@field(value, field.name));
                },
                .int => inverted = ~value,
                else => @compileError(
                    "unable to invert the element type to create value different from sentinel," ++
                        "add a declaration `const uninit: " ++ @typeName(T) ++ "` to supply this value",
                ),
            }
            return inverted;
        }
    };
}

test {
    const gpa = std.testing.allocator;

    const Bdy = BuddyAllocator(struct { u8, u16 }, .{ 0, 0 }, 10, 1);
    var buddy = Bdy{};
    defer buddy.deinit(gpa);

    const idx = try buddy.alloc(gpa, 32);
    buddy.free(idx, 32);

    inline for (.{ 4, 16, 64, 256 }) |size| {
        var idxs: [4]Bdy.Index = undefined;
        for (&idxs) |*id| id.* = try buddy.alloc(gpa, size);
        for (idxs) |id| buddy.free(id, size);
    }

    for (0..2) |_| {
        const allocs: [4]Bdy.Size = .{ 64, 16, 4, 1 };
        var idxs: [127]Bdy.Index = undefined;
        var cursor: usize = 0;
        for (allocs) |count| {
            const size = 256 / count;
            for (idxs[cursor..][0..count]) |*id| id.* = try buddy.alloc(gpa, size);
            cursor += count;
        }
        cursor = 0;
        for (allocs) |count| {
            const size = 256 / count;
            for (idxs[cursor..][0..count]) |id| buddy.free(id, size);
            cursor += count;
        }
    }
}
