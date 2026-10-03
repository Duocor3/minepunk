@echo off
rem Builds MCPassthrough.dll (RED4ext plugin + ReShade add-on) with MSVC into build\.
setlocal
set HERE=%~dp0
if not defined VCVARS for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
call "%VCVARS%" >nul || exit /b 1
if not exist "%HERE%build" mkdir "%HERE%build"
cl /nologo /LD /O2 /EHsc /std:c++20 /MT /W3 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS ^
  /I "%HERE%third_party\RED4ext.SDK\include" /I "%HERE%third_party\RED4ext.SDK\vendor\D3D12MemAlloc" /I "%HERE%third_party\reshade" ^
  "%HERE%src\plugin.cpp" "%HERE%src\compositor.cpp" "%HERE%src\ws.cpp" ^
  /Fo"%HERE%build\\" /Fe"%HERE%build\MCPassthrough.dll" ^
  /link ws2_32.lib user32.lib
