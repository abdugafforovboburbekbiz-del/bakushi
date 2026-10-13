# Push Bakushi to GitHub and tag v1.0.0. ASCII only (PowerShell 5.1).
#
# Usage (run once after creating an EMPTY public repo named "bakushi"
# on github.com - no README/license/.gitignore, this repo has them):
#   powershell -ExecutionPolicy Bypass -File tools\push_to_github.ps1 `
#       -RepoUrl https://github.com/<your-user>/bakushi.git
param([Parameter(Mandatory = $true)][string]$RepoUrl)

$ErrorActionPreference = 'Stop'

# Safety checks: nothing personal, no huge files, no models.
$pat = 'C:' + '\Users'
$personal = git grep -c -e $pat 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Error "ABORT: personal path references still in the repo: $personal"
}
$big = git ls-files | ForEach-Object {
    $len = (Get-Item $_ -ErrorAction SilentlyContinue).Length
    if ($len -gt 100MB) { $_ }
}
if ($big) {
    Write-Error "ABORT: files over 100 MB are tracked: $big"
}

# 1. Remote + push main.
$existing = git remote get-url origin 2>$null
if ($LASTEXITCODE -eq 0) {
    git remote set-url origin $RepoUrl
    Write-Host "remote origin updated to $RepoUrl"
} else {
    git remote add origin $RepoUrl
    Write-Host "remote origin added: $RepoUrl"
}
git push -u origin main
if ($LASTEXITCODE -ne 0) {
    Write-Error "push failed - is the repo created and empty on GitHub?"
}

# 2. Tag the release.
git tag -f v1.0.0
git push origin v1.0.0
if ($LASTEXITCODE -ne 0) {
    Write-Error "tag push failed"
}

Write-Host ""
Write-Host "Code and tag v1.0.0 are pushed. Finish the release on the web UI:"
Write-Host ""
Write-Host "  1. Open $RepoUrl/releases"
Write-Host "  2. Draft a new release -> tag: v1.0.0 (paste dist\RELEASE_NOTES.md)"
Write-Host "  3. Attach the two files:"
Write-Host "       dist\BakushiSetup.exe"
Write-Host "       dist\bakushi-release.zip"
Write-Host "  4. Publish."
