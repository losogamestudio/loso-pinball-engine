# Convert videos (e.g. DaVinci Resolve exports) to Ogg Theora (.ogv), the only
# video format Godot plays, with settings that suit the Raspberry Pi.
#
# Usage, from PowerShell in the project folder:
#     .\tools\convert_videos.ps1 -Source D:\Videos\resolve_exports
#     .\tools\convert_videos.ps1 -Source D:\Videos\intro.mp4 -Height 480
#
# -Source   a video file, or a folder: every .mp4/.mov/.mkv/.mxf in it is converted
# -Output   where the .ogv files go (default: assets\video in this project)
# -Height   720 (default) or 480 if a clip stutters on the Pi; width follows the shape
# -Fps      30 (default); less work for the Pi than 60
# -Quality  Theora video quality 0..10 (default 7; 6 = smaller, easier to decode)
# -Force    convert again even if the .ogv is newer than the source
#
# Needs ffmpeg:  winget install Gyan.FFmpeg   (then open a new PowerShell)
# The file name becomes the video's name in the game: intro.ogv -> Media.play_video(&"intro").
# Keep the source files outside assets\, so they don't get synced to the Pi.

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Output = (Join-Path $PSScriptRoot "..\assets\video"),
    [ValidateSet(480, 540, 720, 1080)][int]$Height = 720,
    [int]$Fps = 30,
    [ValidateRange(0, 10)][int]$Quality = 7,
    [switch]$Force
)

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "ffmpeg isn't installed (or this PowerShell was opened before it was)." -ForegroundColor Red
    Write-Host "Install it with:  winget install Gyan.FFmpeg   then open a new PowerShell."
    exit 1
}

if (Test-Path $Source -PathType Container) {
    $files = Get-ChildItem $Source -File | Where-Object { $_.Extension -in ".mp4", ".mov", ".mkv", ".mxf" }
} elseif (Test-Path $Source -PathType Leaf) {
    $files = @(Get-Item $Source)
} else {
    Write-Host "Can't find $Source" -ForegroundColor Red
    exit 1
}
if (-not $files) {
    Write-Host "No .mp4/.mov/.mkv/.mxf files in $Source"
    exit 0
}

New-Item -ItemType Directory -Force $Output | Out-Null
$Output = (Resolve-Path $Output).Path

foreach ($file in $files) {
    $target = Join-Path $Output ($file.BaseName + ".ogv")
    if ((Test-Path $target) -and -not $Force -and (Get-Item $target).LastWriteTime -gt $file.LastWriteTime) {
        Write-Host "Up to date: $($file.Name)"
        continue
    }
    Write-Host "Converting $($file.Name) -> $target  (${Height}p, $Fps fps, quality $Quality)" -ForegroundColor Cyan
    # scale=-2:H keeps the shape (width rounded to an even number); -g = one
    # keyframe per second, so playback and skipping stay smooth; yuv420p is what
    # Theora decoders expect; Vorbis audio at quality 5.
    & ffmpeg -hide_banner -loglevel error -stats -y -i $file.FullName `
        -vf "scale=-2:${Height},fps=$Fps" `
        -c:v libtheora -q:v $Quality -g $Fps -pix_fmt yuv420p `
        -c:a libvorbis -q:a 5 -ar 48000 `
        $target
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ffmpeg failed on $($file.Name)" -ForegroundColor Red
    } else {
        $mb = [math]::Round((Get-Item $target).Length / 1MB, 1)
        Write-Host "  done, $mb MB" -ForegroundColor Green
    }
}
Write-Host "Finished. Sync assets\video to the Pi, then test with Service -> Audio & Video -> Video -> Play."
