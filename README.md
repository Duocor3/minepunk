# Minepunk: Minecraft x Cyberpunk 2077

Real Minecraft Java running inside Cyberpunk 2077. Steve replaces V, and Minecraft's items work in Night City:

- **Ender pearls** teleport you, off buildings too.
- **The sword** hits and launches NPCs.
- **Arrows** hurt NPCs.
- **TNT, creepers and fireworks** set off real Cyberpunk explosions.
- **The elytra** glides you over Japantown.
- **Blocks you build are solid:** stand on them, pillar up, place them on walls.
- **Health is shared:** V's health and Steve's hearts are the same value, so damage in either game shows in both.

It's two mods working together:
- a **Fabric mod** for Minecraft;
- a **RED4ext plugin + Cyber Engine Tweaks script + ReShade add-on** for Cyberpunk.

Both games run at the same time:
- Cyberpunk sends its camera to Minecraft every frame.
- Minecraft draws the world on a transparent background, and that picture is blended into Cyberpunk's frame using depth, so Night City's buildings still hide blocks behind them.
- Events go back and forth over a local connection ("pearl landed here", "V took damage", "TNT exploded").

> Fan project, not affiliated with or endorsed by Mojang Studios, Microsoft or CD Projekt Red. Single-player only.
> You need to own both games.

## Requirements

| | Version tested |
|---|---|
| Cyberpunk 2077 (Steam, base game, no Phantom Liberty) | **2.31** |
| [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks) | 1.37.1 |
| [RED4ext](https://github.com/wopss/RED4ext) | 1.30.0 |
| [redscript](https://github.com/jac3km4/redscript) | 1.0.0-preview.22 |
| [Codeware](https://github.com/psiberx/cp2077-codeware) | **1.18.1** (newer versions target newer game patches and fail to compile on 2.31) |
| [ReShade](https://reshade.me) **with add-on support** | 6.8.0, installed into `bin\x64` as `dxgi.dll` (DirectX 12) |
| [World Builder](https://github.com/justarandomguyintheinternet/CP77_entSpawner) | 1.0.7. Only its `archive\pc\mod\baseEntity.archive` is used (the empty entity behind the block collisions) |
| Minecraft Java Edition | **26.3** |
| [Fabric Loader](https://fabricmc.net) + [Fabric API](https://modrinth.com/mod/fabric-api) | 0.19.5+ / 0.161.0+26.3 |

Building also needs:
- **Visual Studio 2022 or newer Build Tools** with the C++ x64 tools;
- **JDK 25** (e.g. Temurin 25);
- **Git**.

## Build

```powershell
git clone https://github.com/Duocor3/minepunk
cd minepunk

# Cyberpunk plugin: fetch the RED4ext SDK + ReShade headers, then build MCPassthrough.dll
cd cyberpunk
powershell -ExecutionPolicy Bypass -File fetch_deps.ps1
.\build.bat                       # -> cyberpunk\build\MCPassthrough.dll

# Minecraft mod (JDK 25 on JAVA_HOME)
cd ..\minecraft
.\gradlew.bat build               # -> minecraft\build\libs\passthrough-0.1.0.jar
```

## Install

1. **Install the requirements** into Cyberpunk: CET, RED4ext, redscript, Codeware, World Builder, and ReShade
   with add-on support. Start the game once so ReShade writes its settings.
2. **Cyberpunk half:** from `cyberpunk\`, run
   `powershell -ExecutionPolicy Bypass -File install.ps1`.
   - It finds a Steam install by itself. For other installs, pass `-Game "<folder>"`.
   - It copies the plugin, the script, the shader and the redscript hook, and turns the effect on in ReShade.
   - `install.ps1 -Remove` takes all of it out again.
3. **Minecraft half:** make a **separate** Fabric 26.3 installation **with its own game folder**.
   - **Why separate:** the mod changes options and opens its own empty world, so keep it away from your real
     worlds.
   - **Mods folder:** put Fabric API and `passthrough-0.1.0.jar` in that installation's `mods` folder.
   - **With [Prism Launcher](https://prismlauncher.org)** (recommended): create an instance named e.g.
     `Cyberpunk Passthrough` (Minecraft 26.3 + Fabric) and add the two jars.
   - **With the official launcher:** use the Fabric installer, then give the new installation its own game
     directory.

## Run

1. Start Minecraft with that installation. It opens an empty world called `passthrough` by itself. Leave its
   window open, not minimized.
2. Start Cyberpunk and load a save. Steve appears once you're in the world.

**Optional: Cyberpunk starts Minecraft for you** (Prism only). Install with
`install.ps1 -AutoStart '"C:\Path\To\prismlauncher.exe" --launch "Cyberpunk Passthrough"'`.
Minecraft then starts 20 s after Cyberpunk and closes with it. Delete
`red4ext\plugins\MCPassthrough\autostart.txt` to turn that off.

## Controls

| | |
|---|---|
| Mouse buttons, wheel, 1-9 | Minecraft's attack / use / hotbar (Cyberpunk doesn't see them while you play) |
| Cyberpunk's crouch / jump | Steve crouches / jumps (higher than V's normal jump, so you can pillar) |
| Jump off something tall | the elytra opens. The mouse steers, and fireworks in the hand boost |
| A key bound in CET → Bindings | "Cycle view": first person → behind → in front |

**Live settings** are in `bin\x64\plugins\cyber_engine_tweaks\mods\mcpassthrough\tune.txt`, re-read every second:
- camera distance;
- jump boost;
- elytra turn speed;
- teleports to showcase spots (`go = 1..5`);
- police heat (`wanted = 0..5`).

## Known limits

- **Graphics:** no DLSS, FSR or XeSS frame generation or upscaling, and no motion blur or depth of field. They
  break the depth matching or smear only Cyberpunk's half of the picture. Borderless windowed works best.
- **Versions:** Cyberpunk 2.31 and Minecraft 26.3 only. Other versions need matching CET, Codeware and Fabric
  builds.
- **Block collision** is capped at 400 blocks, and every block is a full cube for V.
- **The link:** the two games talk over `127.0.0.1:25599` with no password. Any program on your PC could send it
  commands, so close Minecraft when you're done.

## Troubleshooting

- **Logs:**
  - `bin\x64\plugins\cyber_engine_tweaks\mods\mcpassthrough\mcpt.log` (the script);
  - `bin\x64\ReShade.log` (the compositor);
  - `red4ext\logs\` (the plugin);
  - Minecraft's `logs\latest.log`.
- **"REDscript compilation has failed" in Codeware:** wrong Codeware version for your game patch.
- **No Minecraft in the picture:** check the ReShade log for "MCPassthrough: registered" and "connected to
  Minecraft's frame export". Minecraft must be in its world, not on a menu.

## Credits

- **[universal-modder](https://github.com/rehan-remade/universal-modder)**, from its Minecraft × GTA V
  example: the Minecraft mod, the ReShade compositor and the WebSocket client this builds on (MIT).
- **[Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks),
  [RED4ext](https://github.com/wopss/RED4ext) / RED4ext.SDK,
  [redscript](https://github.com/jac3km4/redscript) and
  [Codeware](https://github.com/psiberx/cp2077-codeware):** the Cyberpunk modding stack.
- **[ReShade](https://reshade.me)** and its add-on API, by crosire.
- **[World Builder](https://github.com/justarandomguyintheinternet/CP77_entSpawner):** the runtime collision-box
  technique and its empty entity.
- **[Appearance Menu Mod](https://github.com/MaximiliumM/appearancemenumod):** the teleport coordinates of the
  showcase spots.
- **[Fabric](https://fabricmc.net)** and **[Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket)**.
- **Inspiration:** chasm's Minecraft-in-Skyrim and TobynJacobs' Minecraft-in-Elden-Ring passthroughs.

Minecraft belongs to Mojang Studios and Microsoft. Cyberpunk 2077 belongs to CD Projekt Red. No game files are
included or needed beyond your own installs.
