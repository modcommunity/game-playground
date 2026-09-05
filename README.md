This is a **sandbox game** built on TMC's **Dot** collection, rather than a piece of it. Spawn things, break things, and find out how much a server puts up with before it complains.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This project is built out of them, so it doubles as a worked example of what they look like in a real game rather than in a demo.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## A Sandbox, and Where the Movement Half Meets
**A Godot 4 sandbox in the classic physics-sandbox shape** — hold Q, pick a prop,
an NPC or a
weapon, click it and it is yours; pick props up with a physics gun, freeze them, throw
them, undo them. Plus map support, and a timer that is not only for surf and bunny-hop
maps.

It is two things at once: a game you can play, and the only place the movement half of
the `dot-*` family runs together.

## What it uses

| | |
| --- | --- |
| [dot-fps-controller](../dot-fps-controller) | Classic strafe movement: air-strafing, surf, bunny-hopping, styles |
| [dot-timer](../dot-timer) | Zones, tracks, stages, styles, records, replays |
| [dot-map](../dot-map) | Three maps in one game, with a rotation |
| [dot-props](../dot-props) | Spawnable props, a physics gun, a gravity gun |
| [dot-leaderboard](../dot-leaderboard) | Boards, ranking points, player statistics |
| [dot-server](../dot-server) | A dedicated server: console, RCON, permissions, modules |
| [dot-core](../dot-core) | The foundation all of them share |

## Playing it

```bash
godot --path .
```

| | |
| --- | --- |
| **Q** | The spawn menu. **Hold** it to browse and release to close; **tap** it to pin it open |
| **Mouse 1** | The tool's primary — grab and hold with the physics gun, punt with the gravity gun |
| **Mouse 2** | The tool's secondary — freeze what is held, or pull and carry |
| **Wheel** | How far out the physics gun holds a prop |
| **Shift + mouse** | Turn the prop the physics gun is holding |
| **1** / **2** / **3** | Physics gun / gravity gun / cycle the weapons you have |
| **E** | Spawn the prop the menu last armed, again |
| **R** | Unfreeze everything you have frozen |
| **Z** | Undo your last spawn |
| **WASD** | Move — including while the menu is open |
| **Space** | Jump (hold it — auto-hop is on) |
| **Ctrl** | Crouch |
| **T** | Switch track: the sandbox, or the course in the corner of it |
| **Tab** | Cycle style — normal, sideways, half-sideways, backwards, low gravity, prebhop |
| **M** | Next map |
| **C** / **V** | Save a practice checkpoint / go back to one |
| **X** / **B** | Cycle which checkpoint / forget them all |
| **Esc** | Close the menu, or release the mouse |

**Clicking a prop in the menu spawns it**, rather than arming a separate spawn key —
and the menu stays open, so a wall is nine clicks rather than nine open-and-closes.
Three tabs, `/` to search, and icons drawn from each definition because this project
ships no art:

| Tab | |
| --- | --- |
| **Props** | Fourteen, in three categories. Planks, panels, beams and pillars to build with; crates and barrels; balls from a 2 kg beach ball to a 900 kg boulder |
| **Entities** | Four NPCs with scripts — one wanders, one chases you, one hops, one spins and shoves whatever comes near. They are props too, so you can pick one up with the physics gun and punt it |
| **Weapons** | A launcher that fires whatever you have armed, a remover, and an impulse gun that shoves everything nearby |

Entities and weapons are **scripts named by path in the catalogue**, which is what lets
a downloaded content pack ship its own — a mounted `.pck` cannot use `class_name`. See
[`CLAUDE.md`](CLAUDE.md).

Saving a checkpoint is free. *Restoring* one costs you the run — the HUD says
**PRACTICE** once it has, which is much better than finding out at the finish line.

## The maps

- **pg_lobby** — the sandbox. A 200-metre plate to build on, a staircase, a walkable
  ramp and one steep enough to learn to surf on — and, out in one corner, a nine-
  platform jump course with a start line, a split and a finish. The course is on
  **bonus 1** and the main track has no timer at all, so building is never timed and
  the minigame is one **T** away. It is also what says the timer is not a surf-and-bhop
  thing: nothing about a jump course is a movement genre.
- **pg_surf_intro** — two ramps meeting in a valley. Drop in, hold a strafe, keep your
  speed to the bottom.
- **pg_bhop_intro** — blocks with gaps that widen. The later ones need the speed you
  kept from the earlier ones.

## Setting up

Every `dot-*` addon is its own repository. For local development, symlink them:

```bash
for pair in dot_core:dot-core dot_fps_controller:dot-fps-controller \
            dot_timer:dot-timer dot_map:dot-map dot_props:dot-props \
            dot_leaderboard:dot-leaderboard dot_ui:dot-ui dot_server:dot-server; do
  ln -s "../../${pair##*:}/addons/${pair%%:*}" "addons/${pair%%:*}"
done
```

A shipped build copies them in instead.

## Running it as a dedicated server

```bash
godot --headless --path . res://examples/dedicated.tscn
```

`server.cfg`:

```
sv_tickrate 100
hostname "surf | playground"
pg_map_seconds 1800
```

The tick rate is the server's, and it reaches the timer and every record filed — see
[`CLAUDE.md`](CLAUDE.md). Once connected, an admin draws zones on a map whose author
never used this engine the way they always have:

```
pg_zone start          // pick a kind
pg_zone_mark           // stand on one corner
pg_zone_mark           // and the other
pg_zone_save
```

## Validating

```bash
godot --headless --path . --import
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_playground.tscn   # 183 checks
godot --headless --path . res://examples/dedicated.tscn             # 57 checks
```

The headless suite boots the whole game, drives a bot down the surf map, finishes and
files a run, ranks it, spawns props and builds their bodies from their definitions,
spawns NPCs and watches one walk toward the player, fires a weapon loaded from a script
path, opens the spawn menu on a real screen stack and clicks through all three tabs,
runs the sandbox's course, falls off it, and changes the map underneath all of it. It
has found nine real bugs, three of them in other repositories; a screenshot found three
more that no assertion could have. See [`CLAUDE.md`](CLAUDE.md).

## Licence

MIT. See [LICENSE](LICENSE).
