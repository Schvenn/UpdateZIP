function updatezip ([string]$sourcepath, [string]$zip, [switch]$remove, [switch]$help) {# Update files in a ZIP archive, does not add any, but optionally removes files.

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Get SHA-256 hash of file or ZIP entry.
function getsha256hash ($source) {if ($source -is [string]) {if (-not (Test-Path $source)) {Write-Host -f red "`nFile not found: " -n; Write-Host -f white "$source"; return $null}
$source = Get-Item -LiteralPath $source}
$stream = $null
if ($source -is [System.IO.FileInfo]) {$stream = [System.IO.File]::OpenRead($source.FullName)}
elseif ($source -is [System.IO.Compression.ZipArchiveEntry]) {$stream = $source.Open()}
else {Write-Host -f red "`nUnsupported input type: " -n; Write-Host -f white "$($source.GetType().FullName)"}

try {$sha256 = [System.Security.Cryptography.SHA256]::Create(); $hash = $sha256.ComputeHash($stream); return [BitConverter]::ToString($hash).Replace("-", "")}
finally {if ($stream) {$stream.Dispose()}
if ($sha256) {$sha256.Dispose()}}}

# Modify fields sent to it with proper word wrapping.
function wordwrap ($field, $maximumlinelength) {if ($null -eq $field) {return $null}
$breakchars = ',.;?!\/ '; $wrapped = @()
if (-not $maximumlinelength) {[int]$maximumlinelength = (100, $Host.UI.RawUI.WindowSize.Width | Measure-Object -Maximum).Maximum}
if ($maximumlinelength -lt 60) {[int]$maximumlinelength = 60}
if ($maximumlinelength -gt $Host.UI.RawUI.BufferSize.Width) {[int]$maximumlinelength = $Host.UI.RawUI.BufferSize.Width}
foreach ($line in $field -split "`n", [System.StringSplitOptions]::None) {if ($line -eq "") {$wrapped += ""; continue}
$remaining = $line
while ($remaining.Length -gt $maximumlinelength) {$segment = $remaining.Substring(0, $maximumlinelength); $breakIndex = -1
foreach ($char in $breakchars.ToCharArray()) {$index = $segment.LastIndexOf($char)
if ($index -gt $breakIndex) {$breakIndex = $index}}
if ($breakIndex -lt 0) {$breakIndex = $maximumlinelength - 1}
$chunk = $segment.Substring(0, $breakIndex + 1); $wrapped += $chunk; $remaining = $remaining.Substring($breakIndex + 1)}
if ($remaining.Length -gt 0 -or $line -eq "") {$wrapped += $remaining}}
return ($wrapped -join "`n")}

# Draw a horizontal line.
function line ($colour, $length, [switch]$pre, [switch]$post, [switch]$double) {if (-not $length) {[int]$length = (100, $Host.UI.RawUI.WindowSize.Width | Measure-Object -Maximum).Maximum}
if ($length) {if ($length -lt 60) {[int]$length = 60}
if ($length -gt $Host.UI.RawUI.BufferSize.Width) {[int]$length = $Host.UI.RawUI.BufferSize.Width}}
if ($pre) {Write-Host ""}
$character = if ($double) {"="} else {"-"}
Write-Host -f $colour ($character * $length)
if ($post) {Write-Host ""}}

# Inline help.
if ($help) {function scripthelp ($section) {line yellow 100 -pre; $pattern = "(?ims)^## ($section.*?)(##|\z)"; $match = [regex]::Match($scripthelp, $pattern); $lines = $match.Groups[1].Value.TrimEnd() -split "`r?`n", 2; Write-Host $lines[0] -f yellow; line yellow 100
if ($lines.Count -gt 1) {wordwrap $lines[1] 100 | Out-String | Out-Host -Paging}; line yellow 100}

$scripthelp = Get-Content -Raw -Path $PSCommandPath; $sections = [regex]::Matches($scripthelp, "(?im)^## (.+?)(?=\r?\n)")
if ($sections.Count -eq 1) {cls; Write-Host "$([System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)) Help:" -f cyan; scripthelp $sections[0].Groups[1].Value; ""; return}
$selection = $null
do {cls; Write-Host "$([System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)) Help Sections:`n" -f cyan; for ($i = 0; $i -lt $sections.Count; $i++) {"{0}: {1}" -f ($i + 1), $sections[$i].Groups[1].Value}
if ($selection) {scripthelp $sections[$selection - 1].Groups[1].Value}
$input = Read-Host "`nEnter a section number to view"
if ($input -match '^\d+$') {$index = [int]$input
if ($index -ge 1 -and $index -le $sections.Count) {$selection = $index}
else {$selection = $null}} else {""; return}}
while ($true); return}

# Error-checking.
if ($sourcepath -and -not $zip) {$zip = $sourcepath; $sourcepath = "."}
if (-not $zip.ToLower().EndsWith('.zip')) {$zip += '.zip'}
if (-not $sourcepath -or -not (Test-Path $sourcepath)) {$sourcepath = $PWD.Path; Write-Host -f Yellow "`n⚠️ Defaulting to current directory.`n"}
if (-not ([System.IO.Path]::IsPathRooted($zip))) {$zip = Join-Path -Path (Get-Location) -ChildPath $zip}
if (-not (Test-Path $zip)) {Write-Host -f red "`n❌ ZIP file not found: $zip`n"; return}

$basePath = [IO.Path]::GetFullPath($sourcepath.TrimEnd('\','/')) + [IO.Path]::DirectorySeparatorChar; $fileStream = [System.IO.File]::Open($zip, 'Open', 'ReadWrite'); $zipArchive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Update); $zipFullPath = [IO.Path]::GetFullPath($zip); $updated = 0; $skipped = 0; $removed = 0

# Update ZIP.
""; Get-ChildItem -Path $sourcepath -Recurse -File | Where-Object { [IO.Path]::GetFullPath($_.FullName) -ne $zipFullPath } | ForEach-Object {if ($_.FullName.Length -le $basePath.Length) {continue}
$relativePath = $_.FullName.Substring($basePath.Length) -replace '\\','/'; $entry = $zipArchive.GetEntry($relativePath)
if ($entry) {$srcHash = getsha256hash ([System.IO.FileInfo]$_); $zipHash = getsha256hash $entry
if ($srcHash -ne $zipHash) {Write-Host -f Cyan "🔄 Updated $relativePath"; $entry.Delete(); [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $_.FullName, $relativePath) | Out-Null; $updated ++}
else {$skipped ++}}}

# Remove files with safety confirmation.
if ($remove) {$entries = @($zipArchive.Entries); $missing = $entries | Where-Object {$entryPath = $_.FullName; $sourceFilePath = Join-Path -Path $basePath -ChildPath ($entryPath -replace '/', '\') 
!(Test-Path $sourceFilePath -ea SilentlyContinue)}
$total = $entries.Count; $count = $missing.Count; $allmissing = $missing -join "`n`t"
if ($count -gt 10 -or $count -gt ($total / 2)) {Write-Host -f yellow "⚠️ Missing files:`n"; Write-Host "`t$allmissing"; Write-Host -f yellow "`n⚠️ $count of the $total files in the archive are missing from the source location. Are you sure you want to remove these? (Y/N) " -n; $confirm = Read-Host
if ($confirm -notmatch "^[Yy]") {Write-Host -f cyan "`n⏭️  Skipping file removals."; $missing = @()}; ""}
foreach ($entry in $missing) {$entryPath = $entry.FullName; Write-Host -f Red "🚫 Removing $entryPath."; $entry.Delete(); $removed++}}

# Summary.
$zipArchive.Dispose(); $fileStream.Dispose()
if ($updated -gt 0 -or $removed -gt 0) {Write-Host -f Green "`n✅ ZIP update complete:`n"
Write-Host -f white "Updated files: " -n; Write-Host -f green "$updated"
Write-Host -f white "Skipped files: " -n; Write-Host "$skipped"
if ($remove) {Write-Host -f white "Removed files: " -n; Write-Host -f red "$removed"}}
else {Write-Host -f Green "🚫 Nothing to update. All $skipped files matched their archived versions and no files were removed."}; ""}
sal -name update -value updatezip

Export-ModuleMember -Function updatezip

<#
## UpdateZIP

	Usage: updatezip <sourcepath> <zipfilename> <-remove> <-help>

This function simply updates a ZIP file with any files that have changed since it was last updated.
No new files from the source location are added.

The optional -remove switch will remove files that no longer exist in the source location, but with a confirmation dialogue if the volume seems disproportionate.
## License
MIT License

Copyright © 2025 Craig Plath

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
copies of the Software, and to permit persons to whom the Software is 
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in 
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
THE SOFTWARE.
##>
