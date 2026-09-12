# Entrenched Hub

A client side aim and ESP hub for the Roblox game **ENTRENCHED** (place `3678761576`).

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Mrzaytoon/EntrenchedHub/main/EntrenchedHub.lua"))()
```

Press **Right Shift** to hide and show the panel. **Hold Left Alt** to click anything in it. Drag it by the header, and the minus button collapses it to the title bar.

The cursor is only released for as long as you hold Left Alt, so mouse look and shift lock are never taken away from you mid fight.

## How it works

The game's fire path is:

```lua
ServerEvents.Shoot:FireServer(state, aimPoint, aiming, missedCount, hitList, cameraPos)
```

Rather than rewriting those arguments, the hub hooks the `Crosshair` function inside `WeaponModule` and lets the game aim itself. That keeps `aimPoint`, `hitList` and `missedCount` consistent with one another, which a raw argument rewrite cannot guarantee. The shot that leaves the client is identical in shape to an honest perfect shot.

Measured live, damage scales by the part that was hit:

| Part  | Multiplier |
|-------|-----------|
| Head  | 1.5x      |
| Torso | 1.0x      |
| Limbs | 0.7x      |

Most rifles do 75 base, so a head hit is 112.5 against 105 max health. That is why the default aim part is the head.

## Features

**Aim** - silent aim, camera aimbot with smoothing, aim cone with an on screen ring, target part selection, line of sight check, lead prediction for bullet travel.

**Visuals** - corner bracket or full box ESP, names, distance, health bar, optional health number, tracers, chams, and off screen pointers. Green means a clear shot, red means something is in the way, gold is the current locked target.

**Weapon** - spread reduction, auto fire, fast fire, native bullet magnetism, extended hit reporting range.

**Settings** - camera field of view offset that rides on top of the game's own aim and scope tweens, cursor handling, and automatic config saving to `EntrenchedHub_Config.json`.

## Notes

- **Extended hit range is off by default and should stay off.** The game's own hit list builder at `WeaponModule:1379` has no team check, so raising the reporting range makes it report every ally your shot passes through and the server punishes you for the teamkill. The hub strips friendly entries before they are sent, but the feature buys very little because the server already resolves long range shots by itself.
- **Wallbang is unproven.** There is no penetration model in this game at all, so it works by fabricating the hit list outright. Whether the server re-checks line of sight is not readable from the client and testing did not confirm it. Left off by default.
- The only anti cheat in the client is movement related. Nothing watches aim, camera, ESP or hooks. The real risk is other players reporting you, so the defaults are deliberately restrained.

## Credits

Built by reverse engineering the live client. Not affiliated with the game or its developers.
