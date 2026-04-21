$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$ZIG_EXE = ".\zig-out\bin\pxder.exe"
$NODE_EXE = "pxder"
$UID = "1159245"
$ITERATIONS = 3

function Format-MB($bytes) {
    return "{0:N1} MB" -f ($bytes / 1MB)
}

function Run-Test($label, $cmd_zig, $cmd_node) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  $label" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Zig
    Write-Host "`n[Zig pxder-zig]" -ForegroundColor Yellow
    $sw_zig = @()
    for ($i = 0; $i -lt $ITERATIONS; $i++) {
        $sw = Measure-Command { Invoke-Expression $cmd_zig 2>&1 | Out-Null }
        $sw_zig += $sw
        Write-Host "  Run $($i+1): $($sw.TotalMilliseconds) ms"
    }
    $avg_zig = ($sw_zig | Measure-Object -Property TotalMilliseconds -Average).Average
    Write-Host "  Avg : $([math]::Round($avg_zig, 1)) ms" -ForegroundColor Green

    # Node
    Write-Host "`n[Node.js pxder]" -ForegroundColor Yellow
    $sw_node = @()
    for ($i = 0; $i -lt $ITERATIONS; $i++) {
        $sw = Measure-Command { Invoke-Expression $cmd_node 2>&1 | Out-Null }
        $sw_node += $sw
        Write-Host "  Run $($i+1): $($sw.TotalMilliseconds) ms"
    }
    $avg_node = ($sw_node | Measure-Object -Property TotalMilliseconds -Average).Average
    Write-Host "  Avg : $([math]::Round($avg_node, 1)) ms" -ForegroundColor Green

    # Compare
    $ratio = [math]::Round($avg_node / $avg_zig, 2)
    $diff = [math]::Round($avg_node - $avg_zig, 1)
    Write-Host "`n  Result: Zig is $($ratio)x faster (saved $($diff) ms)" -ForegroundColor Magenta
}

# Test 1: Startup speed (--version)
Run-Test "Startup Speed (--version)" "$ZIG_EXE --version" "$NODE_EXE --version"

# Test 2: Startup speed (--help)
Run-Test "Startup Speed (--help)" "$ZIG_EXE --help" "$NODE_EXE --help"

# Test 3: Binary / install size
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Binary Size" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$zig_size = (Get-Item $ZIG_EXE).Length
Write-Host "`n[Zig pxder-zig]"
Write-Host "  Binary: $(Format-MB $zig_size)"

$node_path = (Get-Command $NODE_EXE -ErrorAction SilentlyContinue).Source
if ($node_path) {
    $node_dir = Split-Path $node_path
    $pxder_dir = Get-ChildItem (Split-Path $node_dir) -Directory -Filter "pxder" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pxder_dir) {
        $node_total = (Get-ChildItem $pxder_dir.FullName -Recurse | Measure-Object -Property Length -Sum).Sum
        Write-Host "`n[Node.js pxder]"
        Write-Host "  Package dir: $($pxder_dir.FullName)"
        Write-Host "  Total size : $(Format-MB $node_total)"
        Write-Host "`n  Zig binary is $([math]::Round($node_total / $zig_size, 1))x smaller" -ForegroundColor Magenta
    } else {
        Write-Host "`n[Node.js pxder] Could not locate package directory"
    }
} else {
    Write-Host "`n[Node.js pxder] Not found in PATH"
}

# Test 4: Download performance
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Download Performance (UID: $UID)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nNOTE: Download tests run once each (network-dependent)" -ForegroundColor DarkGray
Write-Host "NOTE: Files from previous run should be skipped (incremental)`n"

Write-Host "[Zig pxder-zig]" -ForegroundColor Yellow
$mem_before_zig = [System.GC]::GetTotalMemory($true) # not relevant for Zig but placeholder
$sw_dl_zig = Measure-Command { Invoke-Expression "$ZIG_EXE -u $UID" 2>&1 | ForEach-Object { Write-Host "  $_" } }
Write-Host "  Time: $($sw_dl_zig.ToString('mm\:ss\.fff'))"

Write-Host "`n[Node.js pxder]" -ForegroundColor Yellow
$sw_dl_node = Measure-Command { Invoke-Expression "$NODE_EXE -u $UID" 2>&1 | ForEach-Object { Write-Host "  $_" } }
Write-Host "  Time: $($sw_dl_node.ToString('mm\:ss\.fff'))"

$dl_ratio = if ($sw_dl_zig.TotalMilliseconds -gt 0) { [math]::Round($sw_dl_node.TotalMilliseconds / $sw_dl_zig.TotalMilliseconds, 2) } else { "N/A" }
Write-Host "`n  Result: Zig download speed ratio: ${dl_ratio}x" -ForegroundColor Magenta

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Benchmark Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
