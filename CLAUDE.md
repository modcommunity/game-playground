# game-playground

**A sandbox first**, in the classic physics-sandbox shape: hold Q, pick a prop, an
NPC or a
weapon, click it and it is yours; hold a prop with a physics gun, freeze it, throw it,
undo it. With map support, and with dot-timer kept — on a jump course in the corner of
the sandbox rather than only on the surf and bhop maps, because that is what says the
timer is not a surf-and-bhop thing.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and
each addon's own `CLAUDE.md` before working in it. This file is only about the joins.

## What this project is for

**It is the only place dot-fps-controller, dot-timer, dot-map, dot-props and
dot-leaderboard run together**, and by the family's own repeated lesson that is where
everything is found. Every one of those addons has a suite, every suite passes with
the others absent, and that proves very little: the bugs that have cost days here were
all in seams — a bridge reconciling on top of another bridge, a message keyed on the
wrong id, a value computed and consumed by nothing.

`examples/headless_playground.tscn` is the point of the repository. It boots the whole
game, drives a bot down a surf map, finishes a run, files it, ranks it, spawns props
and checks their bodies were built from their definitions, opens the spawn menu on a
real `DotScreenStack` and clicks a prop in it, runs the sandbox's own course and falls
off it, spawns NPCs and watches one walk toward the player, fires a weapon loaded from a
script path, and changes the map underneath all of it. **183 checks, and it has now
found nine real bugs — three of them in other repositories.** Three more were found by
a screenshot, which no assertion could have.

It is also playable: `game/playground.tscn` is a first-person client with a spawn
menu, a crosshair and a HUD.

## Layout

```
game/
  playground.gd          the simulation: maps, timers, props, boards. Headless
  playground_config.gd   what an operator configures, layered
  playground_module.gd   the DotServer bridge: every console command
  playground_client.gd   one local player, a camera, a HUD, the keys. Not headless
  playground_player.gd   the bridge: movement, timer, style, tools
  playground_spawn_menu.gd  the Q menu: three tabs, categories, search, icon cards
  playground_icons.gd    icons drawn from a definition, because this ships no art
  playground_spawnables.gd  the catalogue, and what "kind" a definition is
  playground_prop.gd     one prop, built from its DotPropDef. One scene, fourteen props
  playground_weapons.gd  the arsenal, and how a script becomes a weapon
  entities/
    playground_entity.gd   a prop with a script, ticked by the simulation
    npc_*.gd               the shipped NPCs. `extends` a PATH, deliberately
  weapons/
    playground_weapon_def.gd  one weapon, as a document
    playground_weapon.gd      the base: two buttons and a tick. Extends DotPropTool
    swep_*.gd                 the shipped weapons. `extends` a PATH, deliberately
  playground_hud.gd      the clock, the speed, the crosshair, what is in your hands
  playground_geometry.gd dev-textured boxes and ramps, in code
  playground_map.gd      base for the built-in maps
  prop.tscn / entity.tscn  one scene for every prop, one for every entity
maps/
  pg_lobby.gd            the sandbox, and a jump course on bonus 1
  pg_surf_intro.gd       two ramps and a valley
  pg_bhop_intro.gd       blocks with widening gaps
  *.zones.json           generated from the maps, and checked against them
tools/
  export_zones.gd        writes those files. Run it after changing a map
examples/
  headless_playground.gd the integration suite
  dedicated.gd           a real DotServer, the module, and its commands
```

## The joins, and what each one gets wrong first

### The game owns the tick loop

`DotFpsController.Drive.EXTERNAL`, not `LOCAL`, even in single player.

In `LOCAL` the controller accumulates frame time and ticks itself, so the timer would
be fed from a signal fired inside somebody else's loop — and a bot could not be driven
at all. `Playground._simulate_tick` owns it instead, which makes the order explicit:

1. `props.advance(step)`
2. every player: sample (if local), then `controller.simulate_tick`
3. every player: `timers.tick_player` with the position the move **just produced**

**Step 3 must come after step 2.** The timer works out whether the player crossed a
line during this tick from where they were and where they now are; ticking it first
shifts every run by exactly one tick, and by a *different* amount at each tickrate —
which is precisely the tickrate dependence dot-timer's sub-tick fractions exist to
remove.

It is also the same shape a dot-net bridge and a dedicated server use, so nothing has
to be rearranged when one arrives.

### `body_ref` must not be `of_self()`

`DotNodeRef.of_self()` on the controller resolves to the **controller**, which is a
plain `Node`. `setup()` then refuses with "the player body must be a Node3D", the
controller never starts, `motor` stays null, and the player simply never moves. Leave
it unset: it defaults to the parent, which is the `Node3D` the movement drives.

This cost the first run of the integration suite nine failures, all of which pointed
somewhere else — no movement, no run, no statistics, no style effect.

### A style has two halves and they move together

`DotFpsStyle` transforms the tunables and filters the command; `DotTimerStyle` says
whether the run counts and what it is worth. `PlaygroundPlayer.set_style` applies
both. Applying one alone gives a run timed as "normal" while the player is actually
sideways, or the reverse — and nothing errors either way.

`DotFpsController.set_style` **rebuilds the motor**, which assigning the property
alone does not; the suite checks that specifically, because it is the way this is most
likely to be used wrongly.

### The timer decides and the game acts

`DotTimer` never moves a player. `Playground._on_effect_requested` turns a
`RESPAWN`, `TELEPORT` or `SLAY` zone into something that happens, because what those
mean is different in a first-person game, a 2D game and a replay being scrubbed.

The effects that change *where the player ends up* — a prespeed clamp, a speed-limit
zone — are read straight off the timer inside `PlaygroundPlayer._on_simulated`, on the
tick, rather than from a signal. Clamping a player's velocity is part of the
simulation, and doing it when a signal happens to arrive puts it a tick late.

### Statistics land when the run ends, which is when it is no longer active

`DotTimerManager.note_stats` originally guarded on "only while the run is active",
which silently discarded the one call that matters — the natural moment to fold in a
run's statistics is the moment it finishes. The suite caught it as a record whose
`stats` dictionary was empty, with no error anywhere, because refusing to write a
statistic is a legitimate thing for a timer with no run to do. Fixed in dot-timer.

### A map change happens with everything in flight

`_on_map_changing` runs **before** anything is torn down: it stops every run, makes
every tool let go, and clears the props — all of which are parented to, or standing
on, geometry that is about to be freed. dot-map's own ordering then loads the new
scene before freeing the old one, so a failure leaves the server on a working map.

**The prespeed clamp was dead.** `PlaygroundPlayer` asked
`timer.is_inside(DotTimerZone.Kind.START)`, which answers only for *effect* zones —
speed limits, freestyle, easy-bhop — and is always false for START, so a player could
carry any speed out of the pad. `in_zone` is the membership query. game-g2gfast had the
same line, its netcode suite found it, and the fix landed in both on the same day. The
lesson is the family's usual one: a guard that never fires looks exactly like a guard
that was never needed.

## What building the sandbox found

Three, all in other repositories, and all three the family's own recurring shape. Every
one parsed cleanly and none produced an error where it was written.

- **`DotTimer.effect_requested` was emitted by nothing at all.** The signal was
  declared, `DotTimerManager` forwarded it, and both this game and game-g2gfast
  connected a handler — so `RESPAWN`, `SLAY` and `TELEPORT` zones did nothing,
  anywhere, and a player who fell off a surf map fell for ever. Nothing errored,
  because a zone kind the timer has no rule for is a legitimate thing to find and the
  whole design says the timer must not act on one itself. It is the family's commonest
  pattern with the ends swapped: not a value produced and consumed by nothing, but a
  value **consumed by two games and produced by nobody**. Fixed in dot-timer, which now
  fires it once on entry, track-filtered, after the tick is complete.

  It was found by needing a course a player could fall off. It also **quietly invalidated
  a passing test**: game-g2gfast's "most of the descent is spent not grounded, which is
  surf" counted 1500 ticks of a bot that had missed the ramps and was falling through
  the void, none of which was surfing. With the respawn working, the bot is put back
  after ~500 ticks and is airborne for 94% of them, which is what the check was always
  meant to say.

- **`DotPropDef.mass` was not put on the body.** See "One scene, fourteen props" below.
  Only visible in a project where every prop is the same scene.

- **`set_anchors_preset` does not set offsets, and dot-ui had five of them.** The
  family's own CLAUDE.md has warned about this since dot-ui was written — "a `Control`
  built in code keeps the zero size it was created with, so the whole interface lays out
  inside nothing and is invisible while being, by every property, correctly configured"
  — and `DotScreenStack` itself, plus `DotCrosshair`, `DotHud` and `DotTableView`, all
  still had it. Nothing in dot-ui's own suite measured a size. The spawn menu here was
  the first screen anybody built on a stack whose parent is a plain `Node`, and it came
  out 0 × 0. All five now use `set_anchors_and_offsets_preset`, and both suites check a
  size rather than a property.

And two here, both of which say the same thing about signals:

- **A signal is not a state.** `PlaygroundClient` waited for the playground to finish
  booting with `await playground.ready_for_players`, and `Playground.change_map` can
  complete **without ever suspending** — a built-in map is a scene already in the
  build — so the playground finished booting inside `add_child` and the signal had
  already been emitted by the time the client reached its `await`. The client then
  waited for ever. **The symptom is a black screen with no error at all**: no camera,
  no HUD, no player, no failed load, nothing in the log. It is the family's own
  GDScript fan-out trap in its smallest form, and the fix is the same one:
  `if not playground.booted: await playground.ready_for_players`. No test caught it,
  because every test drives `Playground` directly; a screenshot caught it in one look.
- **A GDScript lambda captures locals by value**, which is already in the family's
  conventions: the first version of the respawn fix above broke out of a loop on a
  `bool` set inside a signal handler and reported "468 of 1500". Capture an `Array`.

**Two of the four wanted a screenshot rather than a test.** The 0 × 0 menu and the
black screen were both invisible to every assertion available — one because every
property was right, the other because nothing had failed. `tools/screenshot.sh` in
`game-dev/` renders this project on a machine with no display; it is not optional
after touching the client.

Building the entities, the weapons and the icon cards on top of that found three more,
and **every one of the three was a screenshot again**:

- **`TabBar.clip_tabs` defaults to on**, so the bar reported a minimum width of about
  one tab, hid the other two behind scroll arrows, and let the `HBoxContainer` lay the
  heading out underneath it. Two of the three tabs were unreachable and "Spawn" was
  drawn through "Props". Every property was correct.
- **The entity icon's torso covered its head.** The torso spanned the full height at
  0.62 of the half-width and the head sat at 0.42 of it, entirely inside — so every
  NPC in the menu was a coloured bar. A head has to be wider than the body and the body
  has to start below it.
- **A bot keeps the last command it was given.** `DotFpsController.apply_command` sets
  the pending command and it stays set, so the bot arrived in the entity test still
  holding forward and jump from the bhop test several tests earlier and auto-hopped
  across the sandbox for the whole of it. "Does the chaser close the distance" was
  measuring a player running away. Not a product bug — but a test that drives a bot and
  then stops driving it is a test with a bot that is still driving.

## The sandbox half

### One scene, fourteen props

`game/prop.tscn` is the only prop scene in the project and it has no shape, no mesh and
no mass in it. What makes a plank a plank is three fields of its `DotPropDef.meta` —
`shape`, `extent`, `colour` — which `PlaygroundProp.configure` turns into a collision
shape and an unshaded box. A server with real content points `scene_path` at its own
scenes and never loads this file at all, which is the seam `DotPropDef` was designed
around: the definition is checkable without loading anything, and the scene is fetched
only when something is actually created.

**The body is built by `configure`, not by `_ready`.** `DotPropSpawner` instantiates
the scene, places it, adds it to the world and *then* emits `spawned` — so the
definition is not available until after the node is in the tree, and a `_ready` that
built a default box would build one that is immediately thrown away. A prop nobody
configured has no collision shape and no mesh: it falls through the floor, is
invisible, and cannot be grabbed, which is three symptoms all pointing somewhere else.
So `_ready` schedules a deferred check that says so, loudly, once.

**`DotPropDef.mass` used to be a number nothing simulated.** It is read in exactly one
place in dot-props — `DotPropTool.may_act_on`, against `grab_mass_limit` — and the body
kept whatever mass its scene was saved with. A catalogue that says 900 kg over a scene
saved at 20 kg gives a prop a physics gun refuses for being too heavy and a gravity gun
throws like a beach ball, with nothing erroring and the two numbers only ever compared
by a player wondering why. `DotPropSpawner` now puts it on the body before the body
enters the tree — earlier than the first physics step, because dot-props' own suite
already found that a mass set *after* an impulse divides that impulse by the old mass.
Fixed in dot-props; this repository is where it showed, because every prop here is the
same scene and the mass is the only thing distinguishing them.

### An entity is a prop with a script, and the script is named by a PATH

This is the division every sandbox of this kind makes, and it is the right one: a
crate is a shape with a
mass and needs no code, and a thing that walks about needs code. dot-props knows
nothing of the difference — it instantiates a scene, places it and counts it against a
budget — so the difference is two fields of `DotPropDef.meta`:

```json
{ "kind": "entity", "script": "res://game/entities/npc_wanderer.gd" }
```

`Playground._configure_entity` loads it and attaches it to the bare `RigidBody3D` that
`entity.tscn` is. That is the whole mechanism.

**The script is named by a path, and that is not a style choice.** A game delivered
through dot-cloud is a mounted `.pck`, and **a mounted pack's `class_name` globals are
not registered in the host** — measured, and written down in the family's own
CLAUDE.md. Every cross-file type reference inside a pack fails to compile; `preload`
and `extends` by path both work. A catalogue that named a class could therefore only
ever ship inside the build. The shipped entities are written the same way —
`extends "res://game/entities/playground_entity.gd"` — because they are the template a
pack copies, and if that path ever stopped working they would stop with it.

**`_ready` has already run by the time the script is attached.** The spawner adds the
body to the world and *then* emits `spawned`, so nothing in an entity may rely on
`_ready`; the base has `_entity_ready` and `bind` instead. This is the same ordering
`PlaygroundProp.configure` exists for.

**A failure removes the prop rather than leaving it.** A body whose script did not load
sits there being a crate, which is indistinguishable from an NPC that has nothing to
do — and "the NPC does not move" sends the next person to the movement code. Both
failure shapes are checked and both are loud: a path that is not there, and a path that
is a real script which is not an entity. The second is the one a copy-paste actually
produces.

**An entity extends `PlaygroundProp`, so it is a prop to everything else.** It counts
against a budget, it can be undone, it goes when its owner leaves, a physics gun can
pick it up and a gravity gun can punt it. An NPC you cannot pick up is the first thing
a sandbox player will try.

**A held entity stops driving itself.** Otherwise it fights the physics gun's spring —
the gun writes a velocity toward the goal, the NPC writes one toward wherever it was
walking, the prop shudders between them and the player concludes the gun is broken.

**Entities tick before players**, from `Playground._simulate_tick`, at the simulation's
fixed rate. Not `_process`, which would make an NPC's speed a function of the frame
rate; not after the players, which would leave a chaser visibly a tick behind its
target at exactly the rate the server ticks.

### A weapon is a script too, and it is not in the prop catalogue

Same mechanism, different registry. `PlaygroundWeapons.make` loads a path, instantiates
it, and checks the result actually *is* a `PlaygroundWeapon` — because a script that is
valid GDScript but extends the wrong thing constructs perfectly and then has none of
the methods the client calls, and the first symptom is a crash inside a mouse handler.

**Weapons are deliberately not `DotPropDef`s.** dot-props' catalogue is "things you
spawn into the world" and requires a `scene_path`, because that is what a spawn needs.
A weapon is never spawned and has no body. Giving one a scene path so it would fit is
the sort of lie that becomes "why does this crate have no collision". The player sees
three tabs; underneath, one of them is a different system, and it is different for a
reason.

**`PlaygroundWeapon` extends `DotPropTool`**, which is most of the work: the spawner,
the wielder, the reach, a `target()` that resolves a ray to a prop, and a
`may_act_on()` that asks the *host* the ownership question rather than answering it.
A physics gun and a gravity gun are the two dot-props ships; these are the game's own,
and they are the same kind of object — not a node, no camera, handed an origin and a
direction so the same weapon works for a player, a bot, a replay and a headless test.

**A muzzle velocity is not an impulse, and the arsenal uses both on purpose.**
`PlaygroundWeapon.launch` writes a velocity: an impulse is divided by the mass, which
is right for a punt and exactly wrong for a launcher, whose boulder would otherwise
leave at a fortieth of the speed of its ball. `swep_impulse` does the opposite for the
opposite reason — a shockwave *should* throw a beach ball further than a boulder.

**Tuning lives in the definition, not in the script.** It is what lets one script serve
three catalogue entries — `npc_wanderer` and `npc_hopper` are the same file at
different speeds — and it is the only half of an entity an operator editing a JSON
catalogue can reach.

### The Q menu

`PlaygroundSpawnMenu` is a `DotScreen` on a `DotScreenStack`, and dot-props is right
that it belongs here: "a menu of four hundred props with icons and a search box is a
game's own design". What the addon does provide is everything the menu needs **without
loading a single scene** — `categories()`, `in_category()` and `search()` all read
fields of a `DotPropDef`.

Three behaviours come straight from the sandboxes this copies, and each is a decision:

- **Hold to browse, tap to pin.** One key, two behaviours, and not a toggle: holding
  shows the menu for as long as you hold it, which is a glance with your place kept;
  tapping leaves it up, which is what you want while building. A plain toggle loses the
  glance and a plain hold means you cannot let go of the mouse.
- **Clicking a prop spawns it**, and the menu stays open. A menu that only *selects*
  means every prop costs two actions and a wall is nine open-and-closes.
- **The menu never spawns anything itself.** It emits and the client asks the server,
  which is the same division the tools make and the reason the file works unchanged
  when a dot-net bridge arrives and a spawn becomes a message.

**Three tabs — props, entities, weapons — and switching one clears the filter.**
Carrying "containers" onto the weapons tab shows nothing and reads as the tab being
broken. The search reaches across the whole tab but not across tabs: a player typing
"barrel" wants the barrel and not "you are on the Toys tab", and a weapon turning up in
a prop search is not a result, it is a surprise.

**The grid is the single source of what is on screen.** `shown()` and `card_for()` read
the buttons' own metadata rather than re-running the filter, because a second copy of a
filter is a second thing that can disagree with the first — and the copy that would be
wrong is the one nobody is looking at.

**A card is a `Button`, not a container.** A Button is focusable and a `VBoxContainer`
is not, so Godot's own focus neighbours make the whole grid navigable with a gamepad or
the arrow keys for free — and a menu that cannot be used without a mouse is exactly the
failure dot-ui's `initial_focus` exists to prevent. Icon above text is
`vertical_icon_alignment`, which is what that property is for.

**The first card takes focus, not the search box, and `/` is what reaches the search.**
Focusing the search box on open sends W, A, S and D into it: the player stands still
typing "wasd" while the menu looks exactly as it should. This is a menu you can walk
around with, so the search needs a key that is not a movement key — and Enter puts the
keyboard back, because otherwise there is no way out of the box that is not the mouse.

**An empty grid says why it is empty.** A search with no results and a tab with nothing
on it look identical when both are blank, and the player's next move is different.

### The icons are drawn from the definition

`DotPropDef.icon_path` is honoured first and almost never set here: a server with
content points it at a thumbnail and that is what the menu shows. This project ships no
art, and a grid of forty identical grey squares is worse than a grid of names — so when
the field is empty `PlaygroundIcons` draws one from **the same three fields the body is
built from**. A barrel is a green cylinder in the world and a green cylinder in the
menu, at the right aspect ratio, because both read `meta` through
`PlaygroundProp.shape_of` / `extent_of` / `colour_of`. A second copy of "what does meta
mean" is a second thing that can disagree with the first.

**Cached by what is drawn, not by prop id.** Fourteen props share four silhouettes and
eleven colours, and a four-hundred-prop catalogue shares far more. A menu that built
four hundred images on open would hitch every time somebody pressed Q.

**An entity is drawn at a fixed, person-shaped aspect rather than its body's.** A
wanderer is a 0.8 by 1.7 box, and at that ratio the head is three pixels across and the
icon reads as a coloured bar.

### The tools are two, and they behave differently

`1` and `2`, and both mouse buttons mean something different depending on which is in
hand. That is dot-props' own division — a physics gun is a building tool with arbitrary
distance, free rotation and a soft spring; a gravity gun is a weapon with one carrying
position, a stiff hold and a punt — and shipping one and calling it both gives a
building tool that cannot throw.

**Switching tools lets go of everything first.** `DotPropInstance.held_by` allows one
holder, so a gravity gun still carrying a crate makes the physics gun's grab do
nothing — with nothing on screen to say why.

**Opening the menu lets go too.** The mouse is about to become a cursor, and a physics
gun still holding a crate would drag it round the world following a pointer the player
is aiming at buttons with.

## The timer is not a surf-and-bhop thing, and `pg_lobby` is where that is said

`pg_lobby` is a sandbox on the **main** track and a nine-platform jump course on
**bonus 1**, and both halves are deliberate.

The main track has no start zone and no end zone, so a player building on the plate is
on a map with no timer — which is what `pg_lobby` has always been for, and the one
thing proving the rest of the game does not quietly require one. Putting the course on
a bonus track keeps that *and* adds a minigame, and the mixed case is a better test than
the empty one because it is the case a real sandbox server is in.

Nothing about a jump course is a movement genre. It is zones drawn round platforms, and
the same sub-tick fractions, styles, records and replays apply to it — which is the
whole claim `dot-timer` makes by depending on nothing but dot-core.

**The reset volume is on the bonus track, and that track filter is what makes it
usable.** It is the air just above the sandbox floor under the course: a player on
bonus 1 who falls off touches it and goes back to the start pad, and a player on the
main track walking through the same corner with a physics gun is not touched at all.
`DotTimer` filters zones by the run's track before it acts on any of them.

**`Playground.tracks_on_this_map()` is derived from the zones, not declared.** A second
list of tracks is a second thing that can disagree with the zone file — and it is the
zone file a *delivered* map ships, so the declaration would be the half that is missing
exactly when it matters. `MAIN` is always in the result even with no zones on it,
because a sandbox is a legitimate track and a player has to be able to get back to it.

## The tick rate comes from `server.cfg`, and every link in the chain is silent

```
server.cfg:  sv_tickrate 100
      ↓      dot-server, _apply_tickrate()
Engine.physics_ticks_per_second
      ↓      Playground._resolve_tick_rate()
Playground.tick_rate  →  DotTimerConfig.tick_rate = 0 ("ask the engine")
      ↓
DotTimerManager.tick_rate  →  DotTimerRecord.tick_rate
```

A timer counting 128 a second on a server stepping 100 reports every run 28% long, and
**nothing about the run looks unusual** — it finishes, it files, and it sits on a
leaderboard shared with servers that got it right.
`examples/dedicated.gd::_test_tickrate_reaches_the_timer` walks the whole chain in one
test, with the server configured for 100 precisely because the project's own default is
128: a test using the same number at both ends would pass with the chain disconnected.

`sv_tickrate` goes in **`server.cfg`, not `autoexec.cfg`** — it is startup-only, and
dot-server execs the first before the listener and the second after.

## The server module

`game/playground_module.gd` is the only file here that names dot-server, which is where
the family's own documentation says such a bridge belongs. It is also where the game
becomes administrable:

| | |
| --- | --- |
| `pg_timer` `pg_restart` `pg_style` `pg_track` `pg_top` | the run |
| `pg_cp` `pg_tp` `pg_cp_clear` | practice mode |
| `pg_zone` `pg_zone_mark` `pg_zone_spawn` `pg_zone_list` `pg_zone_undo` `pg_zone_save` | drawing zones, the `sm_zones` workflow |
| `pg_map` `pg_nextmap` `pg_rtv` `pg_extend` | maps |
| `pg_prop` `pg_undo` `pg_props_clear` | props |
| `pg_status` | everything at once |

**The zone commands are `CHANGEMAP`, not `GENERIC`.** Drawing a start line is editing
the map's rules, and somebody who can do it can invalidate every record on it.

**One painter per admin.** Two admins drawing at once would otherwise share a first
corner, and the failure is a zone spanning the distance between them — saved, with
nothing to say it was not meant.

**A zone is live the moment it is drawn** (`set_zones` right after the second mark). An
admin who had to reload the map to test a start line would test it once.

**Saving a set with a problem is refused, not warned about.** A zone file with a start
and no end is playable and unfinishable, and the moment it is on disk somebody else has
a copy.

There is deliberately **no `pg_tickrate` cvar**. A second cvar for the same number is a
second number that can disagree with the first.

## Maps are content, not projects

Three maps, one game. See [dot-map's CLAUDE.md](../dot-map/CLAUDE.md) for why a
project per map falls apart at map forty.

**The built-in maps build their geometry and their zones from the same constants**, in
one script, so a start line cannot drift half a metre from where the ramps actually
are — which would be a leaderboard nobody can compare with anybody else's.

A **delivered** map cannot do that: it ships geometry and a zone file. So
`tools/export_zones.gd` writes those files from the same source, they are committed,
and `examples/headless_playground.gd::_test_zone_file_matches_the_map` checks that the
file still matches what the map builds. A hand-copied zone file is correct exactly
once.

**Run the tool after changing a map**, or the check fails:

```bash
godot --headless --path . --script tools/export_zones.gd
```

`pg_lobby`'s **main track** has no timer, and that is not filler: it is the one place
that proves the rest of the game does not quietly require one. Its bonus track does —
see above.

## The movement is a bhop server's, not the addon's defaults

`PlaygroundPlayer._tunables` differs from `DotFpsTunables`'s defaults in five places
and every one is the genre:

| | Default | Here | Why |
| --- | --- | --- | --- |
| `auto_hop` | off | **on** | Otherwise the skill is a keyboard-hardware contest, not an aiming one |
| `bhop_speed_cap_scale` | 0 | 0 | Kept at 0 explicitly. A cap is what those shooters added to *stop* bunny-hopping |
| `crease_slide` | on | on | Kept explicitly: a surf map is made of seams |
| `coyote_time` | 0.1 | **0** | Free speed on a timed map, and a run set with it is not comparable |
| `jump_buffer_time` | 0.1 | **0** | The same |

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_playground.tscn   # 183 checks
godot --headless --path . res://examples/dedicated.tscn             # 57 checks
```

**Run the check-only pass first.** A script that fails to parse makes the scene fail
to load and the process then **hangs** rather than exiting.

Every addon's own suite still has to pass too — this one exercises the joins and
deliberately does not re-test what they cover.

## Things deliberately not here

- **Networking.** dot-net's bridge is the next piece, and it is now the only thing
  between this and a server people can join: `examples/dedicated.tscn` boots a real
  `DotServer` with a listener, a console and the module, and what is missing is the
  per-player replication. The shape is ready — the timer and the prop spawner are
  authoritative in one place, the game owns the tick, and every controller is already
  `EXTERNAL`. **Props will not be predicted when it arrives** — rigid-body simulation is
  not reproducible across machines, so the bridge replicates transforms rather than
  replaying inputs. The sandbox half is already shaped for that: the spawn menu emits
  rather than spawning, and the tools send intent.
- **A scoreboard and a vote UI.** dot-ui has the screen stack and the spawn menu is
  built on it; a scoreboard and a vote panel are the same shape and are not written.
- **Art.** `DotPropDef.icon_path` is read and nothing here sets it: the icons are drawn
  from the definition, which is honest for a project with no models. A server with
  content sets the field and gets its own thumbnails with no code change.
- **NPCs that fight.** They walk, chase and shove. Health and damage are dot-combat's
  and this project does not depend on it; a half-built damage model that disagreed with
  the addon's would be worse than none.
- **Welding, ropes, thrusters, duplicators.** dot-props says why: constraints are a much
  larger surface than spawning, they interact with each other, and a half-built
  constraint system is worse than none. `DotPropTool` is the hook.
- **Saving a build.** A save format has to survive the catalogue changing under it,
  which is a versioning problem rather than a physics one.
- **Real maps.** These three are test fixtures that happen to be playable. A real map
  is authored in the editor and zoned with `DotTimerZonePainter`.
- **Sound, art, animation.** The maps are unshaded grey boxes on purpose.
- **Replay playback.** dot-timer records and stores them; drawing a ghost is a game's
  own decision and every game's is different.
