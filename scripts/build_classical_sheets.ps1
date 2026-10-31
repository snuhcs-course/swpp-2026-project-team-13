# Same logical sheet and four-plus-four geometry as the existing handwriting canvas.
# Draw the clef, fixed key signature on both systems, and numeric meter on the first.
param([string]$Repository = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sheetRoot = Join-Path $Repository 'backend/content/sheets'
$source = Get-Content -Raw -LiteralPath (Join-Path $Repository 'backend/content/source/classical/provenance.json') | ConvertFrom-Json
$combinations = @{}
foreach ($item in $source.accepted) {
    [xml]$score = Get-Content -Raw -LiteralPath (Join-Path $Repository "backend/content/source/classical/$($item.file)")
    $n = [int]$score.'score-partwise'.part.measure[0].attributes.time.beats
    $d = [int]$score.'score-partwise'.part.measure[0].attributes.time.'beat-type'
    $combinations["$n-$d-$($item.key.fifths)"] = @($n,$d,[int]$item.key.fifths)
}
# Exercise the new meter templates even when a candidate in that meter is excluded.
$combinations['2-2-0'] = @(2,2,0)
$combinations['3-8-0'] = @(3,8,0)
$symbolFamily = New-Object System.Drawing.FontFamily('Segoe UI Symbol')
$numberFamily = New-Object System.Drawing.FontFamily('Times New Roman')
$keyPaths = Get-Content -Raw -LiteralPath (Join-Path $Repository 'scripts/engraving/key-signature-paths.json') | ConvertFrom-Json
function New-MusicPath([string]$data) {
    $tokens = [regex]::Matches($data,'[MLCZ]|-?\d+(?:\.\d+)?') | ForEach-Object Value
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new([System.Drawing.Drawing2D.FillMode]::Winding)
    $index=0; [single]$x=0; [single]$y=0
    while ($index -lt $tokens.Count) {
        $command=$tokens[$index]; $index++
        switch ($command) {
            'M' { $path.CloseFigure(); $path.StartFigure(); $x=[single]::Parse($tokens[$index],[cultureinfo]::InvariantCulture); $y=[single]::Parse($tokens[$index+1],[cultureinfo]::InvariantCulture); $index+=2 }
            'L' { $nextX=[single]::Parse($tokens[$index],[cultureinfo]::InvariantCulture); $nextY=[single]::Parse($tokens[$index+1],[cultureinfo]::InvariantCulture); $path.AddLine($x,$y,$nextX,$nextY); $x=$nextX; $y=$nextY; $index+=2 }
            'C' { $values=@(); foreach ($offset in 0..5) { $values += [single]::Parse($tokens[$index+$offset],[cultureinfo]::InvariantCulture) }; $path.AddBezier($x,$y,$values[0],$values[1],$values[2],$values[3],$values[4],$values[5]); $x=$values[4]; $y=$values[5]; $index+=6 }
            'Z' { $path.CloseFigure() }
            default { throw "Unsupported engraving path command $command" }
        }
    }
    $path.CloseFigure()
    return ,$path
}
function Draw-Glyph($graphics, [string]$text, $family, [int]$style, [single]$size, [single]$centerX, [single]$baseline) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $ascent = $family.GetCellAscent($style) * $size / $family.GetEmHeight($style)
    $path.AddString($text,$family,$style,$size,[System.Drawing.PointF]::new(0,0),[System.Drawing.StringFormat]::GenericTypographic)
    $bounds = $path.GetBounds()
    $matrix = New-Object System.Drawing.Drawing2D.Matrix
    $matrix.Translate(($centerX - $bounds.X - $bounds.Width/2),($baseline - $ascent))
    $path.Transform($matrix)
    $graphics.FillPath([System.Drawing.Brushes]::Black,$path)
    $matrix.Dispose(); $path.Dispose()
}
foreach ($entry in $combinations.Values) {
    $n,$d,$fifths = $entry
    $id = "staff-8bars-$n-$d-key$fifths-v3"
    $bitmap = New-Object System.Drawing.Bitmap(2660,1692,[System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::White)
    $graphics.ScaleTransform(2,2)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black,1.5)
    $svg = [System.Collections.Generic.List[string]]::new()
    $svg.Add('<svg xmlns="http://www.w3.org/2000/svg" width="2660" height="1692" viewBox="0 0 1330 846"><rect width="1330" height="846" fill="white"/>')
    foreach ($system in @(0,1)) {
        $top = @(164,499)[$system]
        foreach ($j in 0..4) { $y=$top+$j*12; $graphics.DrawLine($pen,54,$y,1276,$y); $svg.Add("<path d='M54 ${y}H1276' stroke='black' stroke-width='1.5'/>") }
        $bars = if ($system -eq 0) { @(54,450,725,1000,1276) } else { @(54,397,690,983,1276) }
        foreach ($x in $bars) { $graphics.DrawLine($pen,$x,$top,$x,($top+48)); $svg.Add("<path d='M$x ${top}v48' stroke='black' stroke-width='1.5'/>") }
        Draw-Glyph $graphics ([char]::ConvertFromUtf32(0x1D11E)) $symbolFamily 0 75 84 ($top+44)
        $svg.Add("<text x='84' y='$($top+44)' text-anchor='middle' font-family='Segoe UI Symbol' font-size='75'>&#x1D11E;</text>")
        $keyY = if ($fifths -gt 0) { @(0,18,-6,12,30,6,24) } else { @(24,6,30,12,36,18,42) }
        $keyData = if ($fifths -gt 0) { $keyPaths.sharp } else { $keyPaths.flat }
        for ($k=0; $k -lt [Math]::Abs($fifths); $k++) {
            # Leland's origin is the exact pitch position, including the flat's bowl.
            # Reuse the MuseScore outline rather than estimating a text baseline.
            $path=New-MusicPath $keyData; $bounds=$path.GetBounds()
            [single]$scale=12/$keyPaths.staff_space_units
            [single]$x=116+$k*15-($bounds.X+$bounds.Width/2)*$scale; [single]$y=$top+$keyY[$k]
            $matrix=[System.Drawing.Drawing2D.Matrix]::new($scale,0,0,$scale,$x,$y)
            $path.Transform($matrix); $graphics.FillPath([System.Drawing.Brushes]::Black,$path)
            $matrix.Dispose(); $path.Dispose()
            $svg.Add("<path class='KeySignature' data-fifths='$fifths' data-system='$system' data-pitch-y='$y' transform='matrix($scale,0,0,$scale,$x,$y)' d='$keyData'/>")
        }
        if ($system -eq 0) {
            $x=126+[Math]::Abs($fifths)*15
            Draw-Glyph $graphics ([string]$n) $numberFamily 1 29 $x ($top+22)
            Draw-Glyph $graphics ([string]$d) $numberFamily 1 29 $x ($top+46)
            $svg.Add("<text x='$x' y='$($top+22)' text-anchor='middle' font-family='Times New Roman' font-weight='bold' font-size='29'>$n</text><text x='$x' y='$($top+46)' text-anchor='middle' font-family='Times New Roman' font-weight='bold' font-size='29'>$d</text>")
        }
    }
    $svg.Add('</svg>')
    [IO.File]::WriteAllText((Join-Path $sheetRoot "$id.svg"),($svg -join ''),[Text.UTF8Encoding]::new($false))
    $graphics.Dispose(); $pen.Dispose()
    $bitmap.Save((Join-Path $sheetRoot "$id.png"),[System.Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
}
$symbolFamily.Dispose(); $numberFamily.Dispose()
Write-Output "Generated $($combinations.Count) key/meter templates without changing legacy sheets."
