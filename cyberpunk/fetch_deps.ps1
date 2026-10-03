# Downloads what building the Cyberpunk plugin needs into third_party\ (not committed: other people's code):
#   RED4ext.SDK          header-only, pinned to the commit this was built against
#   reshade\             ReShade 6.8.0's add-on API headers
#   ReShade.fxh / ReShadeUI.fxh   the shader includes MCPassthrough.fx uses (crosire/reshade-shaders, slim)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tp = Join-Path $here "third_party"
New-Item -ItemType Directory -Force $tp, "$tp\reshade" | Out-Null

$sdk = Join-Path $tp "RED4ext.SDK"
if (-not (Test-Path $sdk)) {
	git clone --quiet https://github.com/wopss/RED4ext.SDK.git $sdk
	git -C $sdk checkout --quiet ad7277714ad30d6885d7050c5ba24fa0102f6920
}

$reshade = "v6.8.0"
foreach ($f in "reshade.hpp", "reshade_api.hpp", "reshade_api_device.hpp", "reshade_api_pipeline.hpp", "reshade_api_resource.hpp",
	"reshade_api_format.hpp", "reshade_events.hpp", "reshade_overlay.hpp") {
	Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/crosire/reshade/$reshade/include/$f" -OutFile "$tp\reshade\$f"
}
foreach ($f in "ReShade.fxh", "ReShadeUI.fxh") {
	Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/crosire/reshade-shaders/slim/Shaders/$f" -OutFile "$tp\$f"
}
"third_party ready: $tp"
