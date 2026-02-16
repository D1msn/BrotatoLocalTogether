[CmdletBinding()]
param(
    [string]$WorkshopItemId = "",
    [string]$SteamAppId = "1942280",
    [string]$GameDir = "D:\steam\steamapps\common\Brotato",
    [string]$ModId = "flash-BrotatoLocalTogether",
    [bool]$CompatSafeBootstrapEnabled = $true,
    [int]$CompatRolloutCount = 8,
    [switch]$FullMod,
    [bool]$WriteCompatConfig = $true,
    [bool]$ClearModLoaderCache = $true,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[BrotatoLocalTogether] $Message"
}

function New-ZipWithForwardSlashes {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$DestinationZip
    )

    if (-not (Test-Path $SourceDir)) {
        throw "Папка для упаковки не найдена: $SourceDir"
    }

    if (Test-Path $DestinationZip) {
        Remove-Item -Path $DestinationZip -Force
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $sourceRoot = (Resolve-Path $SourceDir).Path
    $zipFileStream = [System.IO.File]::Open($DestinationZip, [System.IO.FileMode]::CreateNew)
    $zipArchive = New-Object System.IO.Compression.ZipArchive(
        $zipFileStream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false
    )

    try {
        $dirs = Get-ChildItem -Path $sourceRoot -Recurse -Directory | Sort-Object FullName
        foreach ($dir in $dirs) {
            $relativeDirPath = $dir.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
            if ([string]::IsNullOrWhiteSpace($relativeDirPath)) {
                continue
            }
            $dirEntryName = ($relativeDirPath -replace "\\", "/").TrimEnd('/') + "/"
            $null = $zipArchive.CreateEntry($dirEntryName)
        }

        $files = Get-ChildItem -Path $sourceRoot -Recurse -File
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
            $entryName = $relativePath -replace "\\", "/"

            $entry = $zipArchive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            $sourceStream = [System.IO.File]::OpenRead($file.FullName)
            try {
                $sourceStream.CopyTo($entryStream)
            }
            finally {
                $sourceStream.Dispose()
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $zipArchive.Dispose()
        $zipFileStream.Dispose()
    }
}

function Get-WorkshopRoot {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentGameDir,
        [Parameter(Mandatory = $true)][string]$CurrentSteamAppId
    )

    $commonDir = Split-Path -Parent $CurrentGameDir
    $steamAppsDir = Split-Path -Parent $commonDir
    return Join-Path $steamAppsDir ("workshop\content\{0}" -f $CurrentSteamAppId)
}

function Resolve-WorkshopItemId {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentWorkshopRoot,
        [Parameter(Mandatory = $true)][string]$CurrentModId,
        [Parameter(Mandatory = $true)][string]$RequestedItemId
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedItemId)) {
        $requestedDir = Join-Path $CurrentWorkshopRoot $RequestedItemId
        if (-not (Test-Path $requestedDir)) {
            throw "Workshop item '$RequestedItemId' не найден в '$CurrentWorkshopRoot'."
        }
        return $RequestedItemId
    }

    $allItems = @(Get-ChildItem -Path $CurrentWorkshopRoot -Directory)
    if ($allItems.Count -eq 0) {
        throw "В '$CurrentWorkshopRoot' нет подписанных workshop item. Подпишись хотя бы на один мод в Steam."
    }

    $existingZipItems = @(
        $allItems | Where-Object { Test-Path (Join-Path $_.FullName ("{0}.zip" -f $CurrentModId)) } | Select-Object -ExpandProperty Name
    )
    if ($existingZipItems.Count -eq 1) {
        return $existingZipItems[0]
    }
    if ($existingZipItems.Count -gt 1) {
        $items = $existingZipItems -join ", "
        throw "Найдено несколько item с '$CurrentModId.zip': $items. Передай -WorkshopItemId явно."
    }

    if ($allItems.Count -eq 1) {
        return $allItems[0].Name
    }

    $available = ($allItems | Select-Object -ExpandProperty Name) -join ", "
    throw "Не удалось определить workshop item автоматически. Доступные item: $available. Передай -WorkshopItemId."
}

function Write-CompatCfg {
    param(
        [Parameter(Mandatory = $true)][string]$CompatPath,
        [Parameter(Mandatory = $true)][bool]$SafeBootstrapEnabled,
        [Parameter(Mandatory = $true)][int]$RolloutCount
    )

    $compatDir = Split-Path -Parent $CompatPath
    if (-not (Test-Path $compatDir)) {
        New-Item -Path $compatDir -ItemType Directory -Force | Out-Null
    }

    # Минимальный compat.cfg:
    # группы берутся из default в моде,
    # rollout определяет сколько extension реально ставится.
    $content = @"
[bootstrap]
safe_bootstrap_enabled=$($SafeBootstrapEnabled.ToString().ToLower())
extension_rollout_count=$RolloutCount
"@
    # Godot ConfigFile в некоторых сборках плохо читает UTF-8 BOM.
    # Пишем UTF-8 без BOM.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($CompatPath, $content, $utf8NoBom)
}

if ($FullMod) {
    $CompatRolloutCount = -1
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot
$modSourceDir = Join-Path $repoRoot $ModId
$buildDir = Join-Path $repoRoot "build"
$stageDir = Join-Path $buildDir "_stage_mods-unpacked"
$stageModDir = Join-Path $stageDir ("mods-unpacked\{0}" -f $ModId)
$zipName = "{0}.zip" -f $ModId
$zipPath = Join-Path $buildDir $zipName

if (-not (Test-Path $modSourceDir)) {
    throw "Исходник мода не найден: $modSourceDir"
}

$workshopRoot = Get-WorkshopRoot -CurrentGameDir $GameDir -CurrentSteamAppId $SteamAppId
if (-not (Test-Path $workshopRoot)) {
    throw "Путь workshop не найден: $workshopRoot"
}

$targetWorkshopItemId = Resolve-WorkshopItemId -CurrentWorkshopRoot $workshopRoot -CurrentModId $ModId -RequestedItemId $WorkshopItemId
$targetDir = Join-Path $workshopRoot $targetWorkshopItemId
$targetZip = Join-Path $targetDir $zipName

Write-Step "Сборка архива с корректной структурой mods-unpacked/$ModId ..."
if (Test-Path $stageDir) {
    Remove-Item -Path $stageDir -Recurse -Force
}
New-Item -Path $stageModDir -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $modSourceDir "*") -Destination $stageModDir -Recurse -Force
if (Test-Path $zipPath) {
    Remove-Item -Path $zipPath -Force
}
New-ZipWithForwardSlashes -SourceDir $stageDir -DestinationZip $zipPath

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipHandle = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$entries = @($zipHandle.Entries | ForEach-Object { $_.FullName -replace "\\", "/" })
$zipHandle.Dispose()
$requiredEntry = "mods-unpacked/$ModId/manifest.json"
if (-not ($entries -contains $requiredEntry)) {
    throw "Неверная структура ZIP: не найден '$requiredEntry'."
}

Write-Step "Копирование ZIP в workshop item $targetWorkshopItemId ..."
if ($DryRun) {
    Write-Step "[DryRun] Пропуск копирования: $zipPath -> $targetZip"
}
else {
    Copy-Item -Path $zipPath -Destination $targetZip -Force
}

if ($WriteCompatConfig) {
    $compatPath = Join-Path $env:APPDATA "Brotato\brotato_local_together\compat.cfg"
    Write-Step "Запись compat.cfg (safe_bootstrap_enabled=$CompatSafeBootstrapEnabled, extension_rollout_count=$CompatRolloutCount) ..."
    if ($DryRun) {
        Write-Step "[DryRun] Пропуск записи compat.cfg: $compatPath"
    }
    else {
        Write-CompatCfg -CompatPath $compatPath -SafeBootstrapEnabled $CompatSafeBootstrapEnabled -RolloutCount $CompatRolloutCount
    }
}

if ($ClearModLoaderCache) {
    $cachePath = Join-Path $env:APPDATA "Brotato\mod_loader_cache.json"
    if (Test-Path $cachePath) {
        if ($DryRun) {
            Write-Step "[DryRun] Пропуск очистки cache: $cachePath"
        }
        else {
            Remove-Item -Path $cachePath -Force
            Write-Step "Очищен cache: $cachePath"
        }
    }
}

Write-Step "Готово."
Write-Host "ZIP: $zipPath"
Write-Host "Workshop target: $targetZip"
Write-Host "Теперь запусти Brotato и проверь logs/modloader.log."









