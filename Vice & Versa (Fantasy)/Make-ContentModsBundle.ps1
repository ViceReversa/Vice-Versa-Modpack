# Make-ContentModsBundle.ps1  (PowerShell 5.1 compatible)
# Create a trimmed bundle of "gameplay/content" mods by scanning each JAR's internal content.
# Output:
#  - mods_content\   (copied JARs that look like gameplay/content)
#  - reports\content_scan.csv   (per-jar metrics: recipes, loot, worldgen, tags, assets/lang, etc.)
#  - reports\excluded.csv       (what was skipped and why)
#  - reports\summary.txt        (counts + total sizes)
# Run from your instance root (folder containing mods\).

[CmdletBinding()]
param(
  [string]$ModsDir = (Join-Path (Get-Location).Path "mods"),
  [string]$OutDir  = "mods_content",
  [string]$ReportDir = "reports",
  [int]$MinSignal = 2,   # minimal total "signal" to consider as content (recipes+loot+tags+worldgen+models+lang)
  [switch]$DryRun   # if set, don't copy files—just report
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-CleanDir($path) {
  if (Test-Path $path) { Remove-Item $path -Recurse -Force }
  New-Item -ItemType Directory -Path $path | Out-Null
}

function ReadZipSafe([string]$jarPath) {
  try { return [System.IO.Compression.ZipFile]::OpenRead($jarPath) } catch { return $null }
}

# Heuristic keyword lists for "infra"/"library" mods (filename or mod_id/name contains these)
$InfraKeywords = @(
  'api','core','library','lib','compat','common','forge','fabric','quilt',
  'architectury','resourceful-lib','cloth-config','placebo','balm','supermartijn642',
  'oops','moonlight','terrablender','embeddium','rubidium','oculus','iris','krypton','ferritecore',
  'starlight','sodium','magnesium','lazydfu','modmenu','mixin','puzzleslib','bookshelf','geckolib',
  'yacl','configured','catalogue','placebo','forgeconfigapi','curios-api','patchouli','badpackets',
  'citadel','playeranimator','selene','caelus','collective','framework','pollen','smartbrainlib',
  'kotlin','mutil','resourceful','moonlight','rhino','kubejs-core','performance','c2me','canary'
) | Sort-Object -Unique

function LooksLikeInfra([string]$name) {
  $n = $name.ToLower()
  foreach($k in $InfraKeywords){ if ($n -match "\b$([regex]::Escape($k))\b") { return $true } }
  return $false
}

function ScanJar([string]$jarPath) {
  $rec = [ordered]@{
    file = [IO.Path]::GetFileName($jarPath)
    size_bytes = (Get-Item $jarPath).Length
    recipes = 0; loot = 0; adv = 0; tags = 0
    tags_entity = 0; tags_biome = 0; tags_structure = 0
    wg_biome = 0; wg_feature = 0; wg_placed = 0; wg_structure = 0; wg_set = 0; wg_dimtype = 0; wg_dimension = 0
    models = 0; lang = 0; sounds = 0
    has_data = $false; has_assets = $false
    mod_id = ""; mod_name = ""; loader = ""
    reason = ""
    keep = $false
  }
  $zip = ReadZipSafe $jarPath
  if (-not $zip) { $rec.reason = "zip open failed"; return [pscustomobject]$rec }

  try {
    foreach($e in $zip.Entries) {
      $p = $e.FullName
      if ($p.StartsWith("data/")) {
        $rec.has_data = $true
        if ($p -like "*/recipes/*") { $rec.recipes++ }
        elseif ($p -like "*/loot_tables/*") { $rec.loot++ }
        elseif ($p -like "*/advancements/*") { $rec.adv++ }
        elseif ($p -like "*/tags/*") {
          $rec.tags++
          if ($p -like "*/tags/entity_types/*") { $rec.tags_entity++ }
          if ($p -like "*/tags/worldgen/biome/*" -or $p -like "*/tags/biome/*") { $rec.tags_biome++ }
          if ($p -like "*/tags/worldgen/structure/*") { $rec.tags_structure++ }
        }
        elseif ($p -like "*/worldgen/biome/*") { $rec.wg_biome++ }
        elseif ($p -like "*/worldgen/configured_feature/*") { $rec.wg_feature++ }
        elseif ($p -like "*/worldgen/placed_feature/*") { $rec.wg_placed++ }
        elseif ($p -like "*/worldgen/structure/*") { $rec.wg_structure++ }
        elseif ($p -like "*/worldgen/structure_set/*") { $rec.wg_set++ }
        elseif ($p -like "*/dimension_type/*") { $rec.wg_dimtype++ }
        elseif ($p -like "*/dimension/*") { $rec.wg_dimension++ }
      } elseif ($p.StartsWith("assets/")) {
        $rec.has_assets = $true
        if ($p -like "*/models/*") { $rec.models++ }
        elseif ($p -like "*/lang/*.json") { $rec.lang++ }
        elseif ($p -like "*/sounds*.json" -or $p -like "*/sounds/*.json") { $rec.sounds++ }
      } elseif ($p -ieq "META-INF/mods.toml") {
        # quick metadata skim
        try {
          $sr = New-Object IO.StreamReader($e.Open())
          $toml = $sr.ReadToEnd()
          $sr.Close()
          $id = ([regex]::Match($toml,'^\s*modId\s*=\s*"(.*?)"\s*$', 'IgnoreCase,Multiline').Groups[1].Value)
          $name = ([regex]::Match($toml,'^\s*displayName\s*=\s*"(.*?)"\s*$', 'IgnoreCase,Multiline').Groups[1].Value)
          if ($id) { $rec.mod_id = $id; $rec.loader = "forge" }
          if ($name) { $rec.mod_name = $name }
        } catch {}
      } elseif ($p -ieq "fabric.mod.json" -or $p -ieq "quilt.mod.json") {
        try {
          $sr = New-Object IO.StreamReader($e.Open())
          $txt = $sr.ReadToEnd()
          $sr.Close()
          $j = $null; try { $j = $txt | ConvertFrom-Json -ErrorAction Stop } catch {}
          if ($j) {
            if ($p -ieq "fabric.mod.json") { $rec.loader = "fabric" } else { $rec.loader = "quilt" }
            if ($j.PSObject.Properties.Name -contains "id") { $rec.mod_id = $j.id }
            if ($j.PSObject.Properties.Name -contains "name") { $rec.mod_name = $j.name }
            if (-not $rec.mod_name -and $j.PSObject.Properties.Name -contains "quilt_loader") {
              $ql = $j.quilt_loader
              if ($ql -and $ql.PSObject.Properties.Name -contains "metadata") { $rec.mod_name = $ql.metadata.name }
            }
          }
        } catch {}
      }
    }
  } finally { $zip.Dispose() }

  $signal = $rec.recipes + $rec.loot + $rec.tags + $rec.wg_biome + $rec.wg_feature + $rec.wg_placed + $rec.wg_structure + $rec.wg_set + $rec.wg_dimtype + $rec.wg_dimension + $rec.models + $rec.lang + $rec.sounds

  $fname = [IO.Path]::GetFileNameWithoutExtension($rec.file)
  $isInfraName = LooksLikeInfra $fname
  $isInfraId   = (if ($rec.mod_id) { LooksLikeInfra $rec.mod_id } else { $false })
  $infra = ($isInfraName -or $isInfraId)

  # Keep if strong signals OR has data/assets with non-infra name
  if ($signal -ge $MinSignal) { $rec.keep = $true }
  elseif ($rec.has_data -or $rec.has_assets) { $rec.keep = -not $infra }
  else { $rec.keep = $false }

  if (-not $rec.keep) {
    if ($infra) { $rec.reason = "infra/library keyword match" }
    elseif (-not $rec.has_data -and -not $rec.has_assets) { $rec.reason = "no assets/data present" }
    elseif ($signal -lt $MinSignal) { $rec.reason = "low signal ($signal<$MinSignal)" }
    else { $rec.reason = "heuristic skip" }
  }

  return [pscustomobject]$rec
}

# --- Main ---
if (-not (Test-Path $ModsDir)) { throw "Mods directory not found: $ModsDir" }
New-CleanDir $ReportDir
if (-not $DryRun) {
  if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
  New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$rows = @()
$excluded = @()
$files = Get-ChildItem $ModsDir -Filter *.jar -File
foreach($f in $files) {
  $r = ScanJar $f.FullName
  $rows += $r
  if (-not $r.keep) { $excluded += $r }
  elseif (-not $DryRun) { Copy-Item $f.FullName (Join-Path $OutDir $r.file) -Force }
}

# Reports
$rows | Sort-Object -Property @{Expression="keep";Descending=$true}, file | Export-Csv (Join-Path $ReportDir "content_scan.csv") -NoTypeInformation -Encoding UTF8
$excluded | Sort-Object file | Export-Csv (Join-Path $ReportDir "excluded.csv") -NoTypeInformation -Encoding UTF8

# Summary
$kept = $rows | Where-Object { $_.keep }
$sumAllBytes = ($rows | Measure-Object -Property size_bytes -Sum).Sum
$sumKeptBytes = ($kept | Measure-Object -Property size_bytes -Sum).Sum

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("Content Mods Bundle Summary")
[void]$sb.AppendLine("===========================")
[void]$sb.AppendLine(("Total jars: {0}" -f $rows.Count))
[void]$sb.AppendLine(("Kept jars:  {0}" -f $kept.Count))
[void]$sb.AppendLine(("Total size (MB): {0:N1}" -f ($sumAllBytes/1MB)))
[void]$sb.AppendLine(("Kept size  (MB): {0:N1}" -f ($sumKeptBytes/1MB)))
[void]$sb.AppendLine(("Output dir: {0}" -f (Resolve-Path $OutDir)))
$sb.ToString() | Out-File (Join-Path $ReportDir "summary.txt") -Encoding UTF8 -Force

Write-Host "`nDone." -ForegroundColor Green
if (-not $DryRun) { Write-Host ("Copied {0} content jars to {1}" -f $kept.Count, (Resolve-Path $OutDir)) -ForegroundColor Green }
Write-Host ("See reports in {0}" -f (Resolve-Path $ReportDir)) -ForegroundColor Yellow
