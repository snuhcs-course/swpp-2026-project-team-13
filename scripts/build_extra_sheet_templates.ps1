# Generate additional meter labels on the established staff/clef template.
# Windows System.Drawing is used only at authoring time; the PNGs are bundled.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sheetRoot = Join-Path $PSScriptRoot '../backend/content/sheets'
$font = New-Object System.Drawing.Font('Times New Roman', 56, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$format = New-Object System.Drawing.StringFormat
$format.Alignment = [System.Drawing.StringAlignment]::Center
$format.LineAlignment = [System.Drawing.StringAlignment]::Center
foreach ($meter in @(@(2,4), @(7,8), @(9,8), @(12,8))) {
    $bitmap = New-Object System.Drawing.Bitmap((Join-Path $sheetRoot 'staff-8bars-6-8-v2.png'))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.FillRectangle([System.Drawing.Brushes]::White, 220, 329, 84, 94)
    foreach ($staffY in @(352,376,400)) {
        $graphics.DrawLine([System.Drawing.Pens]::Black, 220, $staffY, 304, $staffY)
        $graphics.DrawLine([System.Drawing.Pens]::Black, 220, ($staffY+1), 304, ($staffY+1))
    }
    $graphics.DrawString([string]$meter[0], $font, [System.Drawing.Brushes]::Black, [System.Drawing.RectangleF]::new(210,326,84,48), $format)
    $graphics.DrawString([string]$meter[1], $font, [System.Drawing.Brushes]::Black, [System.Drawing.RectangleF]::new(210,374,84,48), $format)
    $graphics.Dispose()
    $bitmap.Save((Join-Path $sheetRoot "staff-8bars-$($meter[0])-$($meter[1])-v2.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}
$format.Dispose()
$font.Dispose()
