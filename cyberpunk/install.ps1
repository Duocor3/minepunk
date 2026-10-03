# Installs (or with -Remove, removes) the Cyberpunk half of the passthrough into the game folder.
#   powershell -ExecutionPolicy Bypass -File install.ps1                 # finds a Steam install of Cyberpunk 2077
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Game "D:\Games\Cyberpunk 2077"
#   powershell -ExecutionPolicy Bypass -File install.ps1 -AutoStart 'C:\Prism\prismlauncher.exe --launch "Cyberpunk Passthrough"'
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Remove
# It only adds its own files (listed below). Build first (build.bat), and fetch_deps.ps1 for the shader includes.
param([switch]$Remove, [string]$Game, [string]$AutoStart)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Cyberpunk {
	$steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
	if (-not $steam) { return $null }
	$libs = @($steam)
	$vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
	if (Test-Path $vdf) { $libs += [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } }
	foreach ($l in $libs) {
		$p = Join-Path $l "steamapps\common\Cyberpunk 2077"
		if (Test-Path (Join-Path $p "bin\x64\Cyberpunk2077.exe")) { return $p }
	}
	return $null
}

if (-not $Game) { $Game = Find-Cyberpunk }
if (-not $Game -or -not (Test-Path (Join-Path $Game "bin\x64\Cyberpunk2077.exe"))) {
	throw "Cyberpunk 2077 not found: pass -Game `"<install folder>`" (the folder with bin\x64\Cyberpunk2077.exe)"
}

$map = [ordered]@{
	"red4ext\plugins\MCPassthrough\MCPassthrough.dll"                = "$here\build\MCPassthrough.dll"
	"bin\x64\plugins\cyber_engine_tweaks\mods\mcpassthrough\init.lua" = "$here\cet\mcpassthrough\init.lua"
	"bin\x64\plugins\cyber_engine_tweaks\mods\mcpassthrough\tune.txt" = "$here\cet\mcpassthrough\tune.txt"
	"bin\x64\reshade-shaders\Shaders\MCPassthrough.fx"               = "$here\shaders\MCPassthrough.fx"
	"bin\x64\reshade-shaders\Shaders\ReShade.fxh"                    = "$here\third_party\ReShade.fxh"
	"bin\x64\reshade-shaders\Shaders\ReShadeUI.fxh"                  = "$here\third_party\ReShadeUI.fxh"
	"r6\scripts\MCPTColliderHook.reds"                               = "$here\r6\scripts\MCPTColliderHook.reds"
}
$autostartFile = "red4ext\plugins\MCPassthrough\autostart.txt"

if ($Remove) {
	foreach ($rel in @($map.Keys) + $autostartFile) { $p = Join-Path $Game $rel; if (Test-Path $p) { Remove-Item $p; "removed $rel" } }
	foreach ($d in "red4ext\plugins\MCPassthrough", "bin\x64\plugins\cyber_engine_tweaks\mods\mcpassthrough") {
		$p = Join-Path $Game $d
		if (Test-Path $p) { Remove-Item $p -Recurse -Force; "removed $d\ (incl. logs)" }
	}
	"Note: ReShadePreset.ini and ReShade.ini were left as they are."
	return
}

foreach ($rel in $map.Keys) {
	if (-not (Test-Path $map[$rel])) { throw "missing $($map[$rel]): run fetch_deps.ps1 and build.bat first" }
}
foreach ($rel in $map.Keys) {
	$dst = Join-Path $Game $rel
	New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
	if ($rel -like "*tune.txt" -and (Test-Path $dst)) { "kept your $rel"; continue } # don't overwrite the player's settings
	Copy-Item $map[$rel] $dst -Force
	"installed $rel"
}
if ($AutoStart) {
	Set-Content -Path (Join-Path $Game $autostartFile) -Value "# started 20 s after Cyberpunk; closes with it`r`ndelay=20`r`n$AutoStart" -Encoding ascii
	"installed $autostartFile"
}

# ReShade: the effect on (preset), and reversed depth for ReShade's depth-buffer heuristics
$preset = Join-Path $Game "bin\x64\ReShadePreset.ini"
if (-not (Test-Path $preset) -or -not ((Get-Content $preset -Raw) -match "MCPassthrough")) {
	Set-Content -Path $preset -Value "Techniques=MCPassthrough@MCPassthrough.fx`r`nTechniqueSorting=MCPassthrough@MCPassthrough.fx`r`n" -Encoding ascii
	"wrote bin\x64\ReShadePreset.ini"
}
$ini = Join-Path $Game "bin\x64\ReShade.ini"
if (Test-Path $ini) {
	$text = Get-Content $ini -Raw
	if ($text -notmatch "RESHADE_DEPTH_INPUT_IS_REVERSED") {
		$defs = "PreprocessorDefinitions=RESHADE_DEPTH_INPUT_IS_REVERSED=1,RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN=0,RESHADE_DEPTH_INPUT_IS_LOGARITHMIC=0`r`n"
		if ($text -match "PreprocessorDefinitions=\r?\n") { $text = $text -replace "PreprocessorDefinitions=\r?\n", $defs }
		else { $text = $text -replace "\[GENERAL\]\r?\n", "[GENERAL]`r`n$defs" }
		Set-Content -Path $ini -Value $text -Encoding ascii -NoNewline
		"updated bin\x64\ReShade.ini (reversed depth)"
	}
} else {
	"ReShade.ini not found yet: install ReShade (with add-on support) into bin\x64, start the game once, then run this again."
}
"done: $Game"
