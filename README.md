# slet

```sh
git clone --recursive http://github.com/jakubDoka/slet
zig version # 0.14.0
zig build run
```

## cross compile

```sh
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-windows-gnu    # common windows devices
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-gnu.2.35 # Ubuntu I guess
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl     # any linux most likely
```

## idea

Each level should feature a setting that seems impossible but if the weapons are used in more creative way, the level should become easy, if not trivial. Completing a level without a hit and/or quickly can add a little bit of optional difficulty (maybe also unlock a bonus levels).

### level brainstorming (SPOILERS)

Thus far, we have a level with a single turret that can't be touched with a short range attack unless the recoil is used as boost. Now this level is a bit too advanced for a first one. First level and subsequent ones should gradually set the expectations.

Level 1: Simple weapon that shoots 4 projectiles consecutively. Goal it to defeat a turret that shoots 4 homing missiles that cant be dodged. Player dies after 2 hits. The missile turret dies after 8 hits from the player weapon, or 2 explosions of the missiles. The missiles are shot from the back of the turret and can be detonated prematurely if hit.


