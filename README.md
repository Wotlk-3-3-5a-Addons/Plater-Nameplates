# PlaterWrath — Plater-style nameplates for WotLK 3.3.5a

A nameplate addon in the style of [Plater](https://www.curseforge.com/wow/addons/plater-nameplates),
written natively for the 3.3.5a client (Warmane and other WotLK realms).

`/plater` or `/plw` opens the options. There is also a minimap button.

## Install

The folder name must be `PlaterWrath`, because the client only loads a `.toc`
whose name matches its folder. Cloning this repository gives you a folder named
after the repository, so rename it:

```
git clone https://github.com/Wotlk-3-3-5a-Addons/Plater-Nameplates.git PlaterWrath
```

Place that `PlaterWrath` folder in `World of Warcraft 3.3.5a\Interface\AddOns\`,
then `/reload` or restart the client. Requires interface version 30300.

---

## Why this is a rewrite and not a port

Plater cannot be ported to 3.3.5a. It is built on the retail/BCC nameplate API:

| Plater needs | 3.3.5a has |
|---|---|
| `C_NamePlate.GetNamePlateForUnit()` | nothing |
| `NAME_PLATE_UNIT_ADDED` / `_REMOVED` | nothing |
| `nameplate1` … `nameplate40` unit tokens | nothing |
| `UnitAura` on a nameplate unit | nothing |
| `UnitDetailedThreatSituation` per plate | only for your target |
| DetailsFramework, LibOpenRaid, LibSharedMedia | none of them run |

On WotLK a nameplate is an **anonymous frame parented to `WorldFrame`** with no unit
attached to it at all. The only thing the client will ever hand you is the name string
printed on the plate. So this addon uses the technique WotLK nameplate addons have always
used — poll `WorldFrame`'s children, recognise Blizzard's plates by their artwork, hide
that artwork, and draw over the top — and rebuilds Plater's *features* on that foundation.

## What works

- Full visual replacement: health bar, border, background, name, level, health text
- **Class colors** for players, reaction colors for NPCs, custom colors, tapped detection
- **Threat coloring** with DPS / Tank / Automatic modes (Automatic follows Defensive
  Stance, Bear Form, Frost Presence or Righteous Fury)
- **Aura tracking** with icons, timers, stacks and school-colored borders
- **Cast bar** with spell name, icon, timer, channel color and an uninterruptible color
- Per-unit-type settings for enemy players, enemy NPCs, neutral NPCs, friendly players
  and friendly NPCs — each with its own color mode, alpha, scale, and which elements show
- Target highlight, target scale, target arrows, non-target fading
- **Movement smoothing** so plates drift towards fast-moving units instead of darting
- **Clickable health bars** and non-overlapping plates, by sizing the plate's hit box
  to the artwork
- Raid target icons, elite `+` marker, boss `??` level, execute-range coloring
- **Mods and scripts** with `Constructor` / `OnShow` / `OnUpdate` / `OnHide` /
  `OnEvent` / `Initialization` hooks, and mod options stored in `modTable.config`
- Import / export for individual mods and for whole profiles
- Profiles, per character

## Mods

Same contract as Plater: a mod declares options, the user sets values, and the values
live in `modTable.config` keyed by the option key. Updating a mod's code never touches
the values the user chose.

```lua
-- OnUpdate hook
function(unitFrame, unitName, modTable)
    if Plater.GetHealthPercent(unitFrame) <= modTable.config["threshold"] then
        local c = modTable.config["color"]
        Plater.SetNameplateColor(unitFrame, c[1], c[2], c[3])
    else
        Plater.ResetNameplateColor(unitFrame)
    end
end
```

Option types: `text`, `color`, `number`, `toggle`, `label`, `blank`.

Two example mods ship disabled — read them on the Mods tab to see the shape of a mod.

Script API (`Plater.` or `PlaterW.`): `SetNameplateColor`, `ResetNameplateColor`,
`SetBorderColor`, `ResetBorderColor`, `SetScale`, `SetAlpha`, `SetNameText`,
`ResetNameText`, `IsTarget`, `IsMouseover`, `GetHealth`, `GetHealthPercent`,
`GetUnitType`, `GetReaction`, `GetClass`, `IsCasting`, `GetCastInfo`,
`GetThreatSituation`, `GetAuras`, `HasAura`, `ForEachPlate`, `GetProfile`, `Print`.

## Known limits — all of them are the client, not the addon

1. **Auras are matched by unit name.** For anything that is not your target, focus or
   mouseover, aura state comes from the combat log, which identifies units by name. Two
   mobs with the same name in range share one aura bucket. Your target, focus and
   mouseover use the exact `UnitAura` API instead, so they are always correct.
2. **Aura durations are learned, not given.** The combat log never reports duration. The
   addon caches real durations whenever a unit passes through your target/focus/mouseover
   and falls back to a table of common WotLK spells. An unknown aura shows its icon with
   no timer.
3. **Player vs NPC needs one sighting.** With no unit token there is no `UnitIsPlayer`.
   A name is classified as a player once it appears in the combat log with the player
   flag, or once you target / mouse over it. Until then an enemy player is treated as an
   enemy NPC. Class colors need the same — a class is learned from a real unit token or
   from an unambiguous class-defining spell cast.
4. **Clicking targets Blizzard's plate frame, not our artwork.** There is no way to
   target from a custom frame without a unit token. Instead the addon resizes the plate
   frame to match the health bar, so the bar you see is the box you click — and because
   the client spaces plates apart using those same dimensions, that is also what stops
   plates overlapping each other. The hit box is also shifted onto the bar with hit rect
   insets, so the bar stays clickable however far you offset it from the unit. Turn it
   off, or tune the box independently of the bar, under General → Clickable area.
5. **No wago.io / WeakAuras-Companion.** Companion talks to retail Plater's import format
   and to a running WeakAuras install; neither applies here. Import/export uses this
   addon's own plain-Lua format.
6. **Cast bar data is whatever Blizzard shows.** For units you are not targeting, the
   nameplate cast bar is the only cast information the client exposes, so the addon
   mirrors it rather than tracking casts itself.

## Conflicts

Turn off any other addon that redraws or attaches to WotLK nameplates. In this install
that means **PlateBuffs** — it hooks the same `WorldFrame` children for its own aura
icons and you will get two sets of icons.

## Commands

| Command | Effect |
|---|---|
| `/plater` | open options |
| `/plater toggle` | enable / disable all custom nameplates |
| `/plater enemy` | toggle Blizzard's enemy nameplates |
| `/plater friendly` | toggle Blizzard's friendly nameplates |
| `/plater reset` | reset the active profile |
| `/plater minimap` | show / hide the minimap button |
| `/plater wipeauras` | clear the combat-log aura cache |
| `/plater status` | plates hooked, mod count, active profile |
| `/plater debug` | dump one live plate's widget layout to chat |
