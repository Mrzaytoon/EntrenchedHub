# Entrenched Hub

A client side aim, ESP and firing hub for the Roblox game **ENTRENCHED** (place `3678761576`).

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Mrzaytoon/EntrenchedHub/main/EntrenchedHub.lua"))()
```

**Hold Left Alt** to click anything in the panel. The cursor is only released while Alt is held, so mouse look and shift lock are never taken away mid fight, and a shot fired through the panel never clicks it. **Right Shift** shows and hides the panel by default, and the key can be changed in Settings. The minimise button collapses it to a small bar with your locked target, kills and headshot rate.

Settings save automatically and carry over from the previous version.

## Features

**Combat**
- Silent aim, with a choice of head, torso or closest. If the part you picked is covered and the other is not, the visible one is used.
- Field of view, hit chance, max distance, clear sight requirement, lead on moving targets, target priority, and a sticky lock that does not hop between players.
- Camera aimbot with smoothing, optionally only while aiming.
- Hold to fire for bolt action rifles, auto fire inside a small cone, and auto reload.

**Visuals**
- ESP boxes that fit crouching and prone bodies, names, distance, weapon, health bar and number, a spotted tag, chams, off screen pointers, and tracers.
- Green means a clear shot, red means something is in the way, gold marks the player you are locked onto.
- An aim circle and a marker on the locked target.

**World**
- A field of view offset that rides on top of the game's own zoom, so scopes still work.
- Clear view, which removes haze, distance blur, weather particles and the grey tint when hurt.
- A tactical radar that turns with your view.

**Stats**
- Kills, deaths, K/D, accuracy, headshot rate and best streak, counted from what the server confirms.
- A kill feed with headshot and distance.

**Settings**
- Five accent colours, interface scale, reduce motion, keybinds, restore defaults, and a full unload that reverts every change made to the game.

## How it works

The game's fire remote is:

```lua
ServerEvents.Shoot:FireServer(state, aimPoint, aiming, missedCount, hitList, cameraPos)
```

Rather than rewriting those arguments, the hub answers the `Crosshair` lookup inside `WeaponModule` with the target's position, so the game builds every value it sends from that point itself. The shot that leaves the client has the same shape as an honest perfect shot.

Measured on a live server:

| Part  | Damage multiplier |
|-------|-------------------|
| Head  | 1.5x              |
| Torso | 1.0x              |
| Limbs | 0.7x              |

## Limits worth knowing

- **Wallbang is not possible.** The server raycasts every shot itself from the camera to the aim point, so anything in the way stops it.
- **Weapons cannot fire faster than the server allows.** After every accepted shot the server locks the weapon and only unlocks it when it is ready. A shot sent while locked is silently thrown away, even though it looks and sounds real on your screen. Hold to fire sends each shot the instant the lock lifts, which is the true maximum.
- Automatic and semi automatic weapons already fire while held, so hold to fire only changes bolt action rifles.
- The only anti cheat in the client watches movement. The real risk is other players reporting you, so keep the field of view sensible.

## Credits

Built by reverse engineering the live client. Not affiliated with the game or its developers.
