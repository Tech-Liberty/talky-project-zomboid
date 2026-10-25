<#
.SYNOPSIS
  Draws the PROVISIONAL Talky images (to be replaced by real artwork before release):
    mod/Talky/42/poster.png           512x512, shown in the in-game mod list
    packaging/workshop/preview.png    256x256, Steam Workshop preview (exactly 256x256, < 1000 KB)
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot

function New-Color([string]$hex, [int]$alpha = 255) {
    $c = [System.Drawing.ColorTranslator]::FromHtml($hex)
    return [System.Drawing.Color]::FromArgb($alpha, $c.R, $c.G, $c.B)
}

function Get-FontFamily([string[]]$names) {
    $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
    foreach ($n in $names) { if ($installed -contains $n) { return $n } }
    return [System.Drawing.FontFamily]::GenericSansSerif.Name
}

function New-TalkyImage([int]$size, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $s = $size / 512.0

    $bg = New-Color '#0E1116'
    $accent = New-Color '#20E6C3'
    $text = New-Color '#F2F5F7'
    $muted = New-Color '#9AA4AE'
    $g.Clear($bg)

    # Thin frame and corner ticks in the accent color
    $frame = New-Object System.Drawing.Pen((New-Color '#20E6C3' 70), [float](2 * $s))
    $inset = [float](22 * $s)
    $g.DrawRectangle($frame, $inset, $inset, [float]($size - 2 * $inset), [float]($size - 2 * $inset))
    $tick = New-Object System.Drawing.Pen($accent, [float](5 * $s))
    $len = [float](46 * $s)
    $a = $inset; $b = [float]($size - $inset)
    $g.DrawLine($tick, $a, $a, [float]($a + $len), $a); $g.DrawLine($tick, $a, $a, $a, [float]($a + $len))
    $g.DrawLine($tick, $b, $b, [float]($b - $len), $b); $g.DrawLine($tick, $b, $b, $b, [float]($b - $len))

    $center = New-Object System.Drawing.StringFormat
    $center.Alignment = [System.Drawing.StringAlignment]::Center
    $center.LineAlignment = [System.Drawing.StringAlignment]::Center

    $titleFamily = Get-FontFamily @('Segoe UI Black', 'Arial Black', 'Segoe UI', 'Arial')
    $bodyFamily = Get-FontFamily @('Segoe UI Semibold', 'Segoe UI', 'Arial')

    $titleFont = New-Object System.Drawing.Font($titleFamily, [float](118 * $s), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawString('TALKY', $titleFont, (New-Object System.Drawing.SolidBrush($text)),
        (New-Object System.Drawing.RectangleF(0, [float](150 * $s), $size, [float](150 * $s))), $center)

    # Accent bar under the title
    $barW = [float](150 * $s); $barH = [float](8 * $s)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($accent)), [float](($size - $barW) / 2), [float](300 * $s), $barW, $barH)

    $subFont = New-Object System.Drawing.Font($bodyFamily, [float](30 * $s), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawString([string]::Format('Project Zomboid {0} LibertyTalk', [char]0x00D7), $subFont, (New-Object System.Drawing.SolidBrush($muted)),
        (New-Object System.Drawing.RectangleF(0, [float](330 * $s), $size, [float](60 * $s))), $center)

    $smallFont = New-Object System.Drawing.Font($bodyFamily, [float](22 * $s), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawString('Build 42', $smallFont, (New-Object System.Drawing.SolidBrush($accent)),
        (New-Object System.Drawing.RectangleF(0, [float](400 * $s), $size, [float](40 * $s))), $center)

    $g.Dispose()
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $info = Get-Item $path
    Write-Host ("{0}  {1}x{1}  {2:N0} bytes" -f $path, $size, $info.Length)
}

New-TalkyImage 512 (Join-Path $root 'mod\Talky\42\poster.png')
New-TalkyImage 256 (Join-Path $root 'packaging\workshop\preview.png')
