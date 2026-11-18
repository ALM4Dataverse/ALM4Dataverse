@echo off
rem Git for Windows cannot expose a worktree's Git common directory at the
rem Windows path recorded in its .git file inside a Linux container. Keep a
rem real directory so the mount in devcontainer.json has a valid source.
setlocal
set "link=%~dp0git-common"
if exist "%link%\" exit /b 0
if exist "%link%" del /f /q "%link%" >nul 2>&1
mkdir "%link%" >nul 2>&1
if not exist "%link%\" (
    echo Could not create "%link%" for the Dev Container mount. 1>&2
    exit /b 1
)
exit /b 0
