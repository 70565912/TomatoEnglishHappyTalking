@echo off
setlocal

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo Visual Studio Installer vswhere.exe was not found. 1>&2
  exit /b 1
)

for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%I"
if not defined VSROOT (
  echo Visual Studio C++ build tools were not found. 1>&2
  exit /b 1
)

call "%VSROOT%\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
where cl
if errorlevel 1 (
  echo Visual Studio initialized without cl.exe. 1>&2
  exit /b 1
)

set "NINJA=%VSROOT%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
if not exist "%NINJA%" (
  echo Visual Studio bundled Ninja was not found. 1>&2
  exit /b 1
)

cmake -S "%~dp0." -B "%~dp0..\..\build\udpipe-v3-trainer" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM="%NINJA%" -DCMAKE_CXX_COMPILER=cl
if errorlevel 1 exit /b %errorlevel%

cmake --build "%~dp0..\..\build\udpipe-v3-trainer" --target udpipe_v3_train udpipe_v3_probe --parallel 4
exit /b %errorlevel%
