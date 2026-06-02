# Tomato English Happy Talking - Codex 手绘风格预览
# 生成一张静态番茄伙伴 PNG 和 4 帧挥手/呼吸 spritesheet。

param(
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $workspaceRoot "docs\design-previews"
}

Add-Type -AssemblyName System.Drawing

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

function New-Color {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hex,
        [int]$Alpha = 255
    )

    $hexValue = $Hex.TrimStart("#")
    return [System.Drawing.Color]::FromArgb(
        $Alpha,
        [Convert]::ToInt32($hexValue.Substring(0, 2), 16),
        [Convert]::ToInt32($hexValue.Substring(2, 2), 16),
        [Convert]::ToInt32($hexValue.Substring(4, 2), 16)
    )
}

function New-Pen {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$Color,
        [float]$Width
    )

    $pen = [System.Drawing.Pen]::new($Color, $Width)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    return $pen
}

function Add-RoundRect {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Drawing2D.GraphicsPath]$Path,
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        [float]$Radius
    )

    $diameter = $Radius * 2
    $Path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
    $Path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
    $Path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
    $Path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
    $Path.CloseFigure()
}

function New-LeafPath {
    param(
        [float]$Cx,
        [float]$Cy,
        [float]$Width,
        [float]$Height,
        [float]$RotateDegrees
    )

    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddBezier(
        $Cx, $Cy - $Height / 2,
        $Cx - $Width / 2, $Cy - $Height / 3,
        $Cx - $Width / 2, $Cy + $Height / 3,
        $Cx, $Cy + $Height / 2
    )
    $path.AddBezier(
        $Cx, $Cy + $Height / 2,
        $Cx + $Width / 2, $Cy + $Height / 3,
        $Cx + $Width / 2, $Cy - $Height / 3,
        $Cx, $Cy - $Height / 2
    )
    $path.CloseFigure()

    $matrix = [System.Drawing.Drawing2D.Matrix]::new()
    $matrix.RotateAt($RotateDegrees, [System.Drawing.PointF]::new($Cx, $Cy))
    $path.Transform($matrix)
    $matrix.Dispose()
    return $path
}

function Draw-Confetti {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Graphics]$Graphics
    )

    $pieces = @(
        @{ X = 78; Y = 78; C = "#FFD54F"; R = -18 },
        @{ X = 118; Y = 44; C = "#2F86FF"; R = 14 },
        @{ X = 378; Y = 76; C = "#12B76A"; R = 24 },
        @{ X = 420; Y = 142; C = "#7C5CFF"; R = -22 },
        @{ X = 68; Y = 184; C = "#FF6B35"; R = 12 },
        @{ X = 402; Y = 226; C = "#FFD54F"; R = 18 }
    )

    foreach ($piece in $pieces) {
        $brush = [System.Drawing.SolidBrush]::new((New-Color $piece.C 235))
        $state = $Graphics.Save()
        $Graphics.TranslateTransform([float]$piece.X, [float]$piece.Y)
        $Graphics.RotateTransform([float]$piece.R)
        $Graphics.FillRectangle($brush, -7, -7, 14, 14)
        $Graphics.Restore($state)
        $brush.Dispose()
    }
}

function Draw-Mascot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [float]$Bounce = 0,
        [float]$RightHandX = 438,
        [float]$RightHandY = 202,
        [switch]$Confetti
    )

    $width = 512
    $height = 512
    $bitmap = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)

    if ($Confetti) {
        Draw-Confetti -Graphics $graphics
    }

    $shadowBrush = [System.Drawing.SolidBrush]::new((New-Color "#24304F" 34))
    $graphics.FillEllipse($shadowBrush, 110, 430, 292, 42)
    $shadowBrush.Dispose()

    $graphics.TranslateTransform(0, $Bounce)

    $lineDark = New-Color "#11131A"
    $tomatoStroke = New-Color "#A9231A"
    $bodyPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $bodyPath.AddBezier(174, 118, 104, 142, 75, 218, 98, 306)
    $bodyPath.AddBezier(98, 306, 122, 394, 208, 430, 281, 398)
    $bodyPath.AddBezier(281, 398, 371, 358, 401, 253, 350, 174)
    $bodyPath.AddBezier(350, 174, 314, 118, 238, 94, 174, 118)
    $bodyPath.CloseFigure()

    $bodyBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.Rectangle]::new(88, 105, 306, 320),
        (New-Color "#FF8A52"),
        (New-Color "#C9261F"),
        55
    )
    $bodyPen = New-Pen -Color $tomatoStroke -Width 7
    $graphics.FillPath($bodyBrush, $bodyPath)
    $graphics.DrawPath($bodyPen, $bodyPath)
    $bodyBrush.Dispose()
    $bodyPen.Dispose()

    $glossPen = New-Pen -Color (New-Color "#FFB18D" 118) -Width 20
    $graphics.DrawBezier($glossPen, 292, 140, 348, 166, 368, 220, 356, 268)
    $glossPen.Dispose()

    $groovePen = New-Pen -Color (New-Color "#9E1E18" 100) -Width 5
    $graphics.DrawBezier($groovePen, 160, 123, 132, 194, 130, 302, 168, 390)
    $graphics.DrawBezier($groovePen, 237, 104, 214, 200, 214, 302, 244, 408)
    $graphics.DrawBezier($groovePen, 306, 133, 296, 210, 296, 316, 274, 390)
    $graphics.DrawBezier($groovePen, 101, 213, 172, 198, 284, 198, 369, 217)
    $graphics.DrawBezier($groovePen, 106, 298, 174, 282, 285, 283, 363, 302)
    $groovePen.Dispose()

    $leafBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.Rectangle]::new(126, 36, 230, 106),
        (New-Color "#2AD779"),
        (New-Color "#08733F"),
        45
    )
    $leafPen = New-Pen -Color (New-Color "#075F35") -Width 6
    $leaves = @(
        (New-LeafPath -Cx 170 -Cy 86 -Width 112 -Height 45 -RotateDegrees -28),
        (New-LeafPath -Cx 232 -Cy 70 -Width 122 -Height 52 -RotateDegrees 0),
        (New-LeafPath -Cx 296 -Cy 88 -Width 116 -Height 44 -RotateDegrees 24),
        (New-LeafPath -Cx 250 -Cy 48 -Width 45 -Height 88 -RotateDegrees 7)
    )
    foreach ($leaf in $leaves) {
        $graphics.FillPath($leafBrush, $leaf)
        $graphics.DrawPath($leafPen, $leaf)
        $leaf.Dispose()
    }
    $leafBrush.Dispose()
    $leafPen.Dispose()

    $armPen = New-Pen -Color $lineDark -Width 12
    $graphics.DrawBezier($armPen, 108, 264, 64, 232, 56, 186, 94, 156)
    $graphics.DrawBezier($armPen, 371, 260, 405, 244, 410, 218, $RightHandX - 10, $RightHandY + 18)
    $armPen.Dispose()

    $handBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.Rectangle]::new(52, 134, 56, 45),
        (New-Color "#FF6B35"),
        (New-Color "#D93424"),
        45
    )
    $handPen = New-Pen -Color $tomatoStroke -Width 5
    $graphics.FillEllipse($handBrush, 64, 132, 54, 44)
    $graphics.DrawEllipse($handPen, 64, 132, 54, 44)
    $graphics.FillEllipse($handBrush, $RightHandX - 28, $RightHandY - 20, 56, 46)
    $graphics.DrawEllipse($handPen, $RightHandX - 28, $RightHandY - 20, 56, 46)
    $handBrush.Dispose()
    $handPen.Dispose()

    $creamBrush = [System.Drawing.SolidBrush]::new((New-Color "#FFF8E8"))
    $eyePen = New-Pen -Color (New-Color "#E8DDC8") -Width 6
    $graphics.FillEllipse($creamBrush, 154, 178, 88, 88)
    $graphics.DrawEllipse($eyePen, 154, 178, 88, 88)
    $graphics.FillEllipse($creamBrush, 264, 176, 88, 88)
    $graphics.DrawEllipse($eyePen, 264, 176, 88, 88)
    $creamBrush.Dispose()
    $eyePen.Dispose()

    $pupilBrush = [System.Drawing.SolidBrush]::new($lineDark)
    $graphics.FillEllipse($pupilBrush, 183, 203, 45, 45)
    $graphics.FillEllipse($pupilBrush, 293, 201, 45, 45)
    $pupilBrush.Dispose()

    $highlightBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $graphics.FillEllipse($highlightBrush, 180, 194, 16, 16)
    $graphics.FillEllipse($highlightBrush, 290, 192, 16, 16)
    $highlightBrush.Dispose()

    $mouthPen = New-Pen -Color $lineDark -Width 9
    $graphics.DrawBezier($mouthPen, 202, 284, 226, 312, 278, 312, 304, 282)
    $mouthPen.Dispose()

    $legPen = New-Pen -Color $lineDark -Width 12
    $graphics.DrawLine($legPen, 196, 390, 188, 430)
    $graphics.DrawLine($legPen, 282, 390, 292, 430)
    $legPen.Dispose()

    $shoeBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.Rectangle]::new(154, 421, 200, 44),
        (New-Color "#FF6B35"),
        (New-Color "#C9261F"),
        45
    )
    $shoePen = New-Pen -Color $tomatoStroke -Width 5
    $leftShoe = [System.Drawing.Drawing2D.GraphicsPath]::new()
    Add-RoundRect -Path $leftShoe -X 151 -Y 421 -Width 72 -Height 34 -Radius 12
    $rightShoe = [System.Drawing.Drawing2D.GraphicsPath]::new()
    Add-RoundRect -Path $rightShoe -X 270 -Y 421 -Width 78 -Height 34 -Radius 12
    $graphics.FillPath($shoeBrush, $leftShoe)
    $graphics.DrawPath($shoePen, $leftShoe)
    $graphics.FillPath($shoeBrush, $rightShoe)
    $graphics.DrawPath($shoePen, $rightShoe)
    $leftShoe.Dispose()
    $rightShoe.Dispose()
    $shoeBrush.Dispose()
    $shoePen.Dispose()

    $graphics.ResetTransform()
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
}

function New-ContactSheet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$FramePaths,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $thumbW = 180
    $thumbH = 180
    $labelH = 28
    $sheet = [System.Drawing.Bitmap]::new($thumbW * $FramePaths.Count, $thumbH + $labelH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($sheet)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::White)
    $font = [System.Drawing.Font]::new("Arial", 9)
    for ($index = 0; $index -lt $FramePaths.Count; $index++) {
        $image = [System.Drawing.Image]::FromFile($FramePaths[$index])
        $x = $index * $thumbW
        $graphics.DrawImage($image, $x + 10, 0, 160, 160)
        $graphics.DrawString("frame-$index", $font, [System.Drawing.Brushes]::Black, $x + 64, 166)
        $image.Dispose()
    }
    $sheet.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $font.Dispose()
    $graphics.Dispose()
    $sheet.Dispose()
}

$staticPath = Join-Path $OutputRoot "codex-tomato-mascot.png"
Draw-Mascot -Path $staticPath -Bounce 0 -RightHandX 438 -RightHandY 202 -Confetti

$frameDir = Join-Path $OutputRoot "codex-tomato-wave-frames"
New-Item -ItemType Directory -Path $frameDir -Force | Out-Null
$frames = @(
    @{ Bounce = 0; RightHandX = 432; RightHandY = 214 },
    @{ Bounce = -7; RightHandX = 444; RightHandY = 180 },
    @{ Bounce = -12; RightHandX = 424; RightHandY = 154 },
    @{ Bounce = -5; RightHandX = 446; RightHandY = 184 }
)
$framePaths = @()
for ($i = 0; $i -lt $frames.Count; $i++) {
    $framePath = Join-Path $frameDir ("frame-{0:D2}.png" -f $i)
    Draw-Mascot -Path $framePath -Bounce $frames[$i].Bounce -RightHandX $frames[$i].RightHandX -RightHandY $frames[$i].RightHandY
    $framePaths += $framePath
}

$sheetPath = Join-Path $OutputRoot "codex-tomato-wave-spritesheet.png"
New-ContactSheet -FramePaths $framePaths -Path $sheetPath

[PSCustomObject]@{
    Static = $staticPath
    Frames = $frameDir
    SpriteSheet = $sheetPath
} | Format-List
