const std = @import("std");
const rl = @import("raylib");

pub const T = @Vector(2, f32);

pub const zero = T{ 0.0, 0.0 };

pub fn asInt(a: T) [2]i32 {
    return .{ @intFromFloat(a[0]), @intFromFloat(a[1]) };
}

pub fn asRl(a: T) rl.Vector2 {
    return @bitCast(a);
}

pub fn splat(scal: f32) T {
    return @splat(scal);
}

pub fn len2(a: T) f32 {
    return @reduce(.Add, a * a);
}

pub fn len(a: T) f32 {
    return std.math.sqrt(len2(a));
}

pub fn dist2(a: T, b: T) f32 {
    return len2(a - b);
}

pub fn dist(a: T, b: T) f32 {
    return len(a - b);
}

pub fn unit(angle: f32) T {
    return .{ @cos(angle), @sin(angle) };
}

pub fn rad(angle: f32, length: f32) T {
    return unit(angle) * splat(length);
}

pub fn orth(a: T) T {
    return .{ -a[1], a[0] };
}

pub fn normalize(a: T) ?T {
    const l = len(a);
    if (l == 0.0) {
        return null;
    }
    return a / splat(l);
}

pub fn ang(a: T) f32 {
    return std.math.atan2(f32, a[1], a[0]);
}

pub fn dot(a: T, b: T) f32 {
    return @reduce(.Add, a * b);
}

pub fn angBetween(a: T, b: T) f32 {
    return std.math.acos(dot(a, b) / (len(a) * len(b)));
}

pub fn proj(a: T, b: T) ?T {
    const ln = len2(b);
    if (ln == 0.0) {
        return null;
    }
    return b * splat(dot(a, b) / ln);
}

test "projection" {
    const a = T{ 1.0, 2.0 };
    const b = T{ 3.0, 4.0 };
    const p = proj(a, b) orelse unreachable;
    const ort = a - p;
    try std.testing.expectApproxEqAbs(dot(p, ort), 0.0, 0.000001);
}
