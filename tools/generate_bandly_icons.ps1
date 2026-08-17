param(
    [Parameter(Mandatory = $true)]
    [string]$ConceptSheet
)

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$background = [System.Drawing.Color]::FromArgb(255, 24, 24, 24)
$sourceRect = [System.Drawing.Rectangle]::new(207, 443, 344, 344)

function New-Canvas([int]$width, [int]$height) {
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear($background)
    $graphics.Dispose()
    return $bitmap
}

function Resize-Icon(
    [System.Drawing.Image]$source,
    [int]$size,
    [string]$destination,
    [double]$scale = 1.0
) {
    $bitmap = New-Canvas $size $size
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    $drawSize = [Math]::Round($size * $scale)
    $offset = [Math]::Round(($size - $drawSize) / 2)
    $destinationRect = [System.Drawing.Rectangle]::new($offset, $offset, $drawSize, $drawSize)
    $graphics.DrawImage($source, $destinationRect)
    $graphics.Dispose()

    $directory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

function Write-PngIco([string]$pngPath, [string]$icoPath) {
    $pngBytes = [System.IO.File]::ReadAllBytes($pngPath)
    $stream = [System.IO.File]::Create($icoPath)
    $writer = [System.IO.BinaryWriter]::new($stream)

    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]1)
    $writer.Write([Byte]0)
    $writer.Write([Byte]0)
    $writer.Write([Byte]0)
    $writer.Write([Byte]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]32)
    $writer.Write([UInt32]$pngBytes.Length)
    $writer.Write([UInt32]22)
    $writer.Write($pngBytes)
    $writer.Dispose()
    $stream.Dispose()
}

$sheet = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $ConceptSheet))
$concept = New-Canvas $sourceRect.Width $sourceRect.Height
$conceptGraphics = [System.Drawing.Graphics]::FromImage($concept)
$conceptGraphics.DrawImage(
    $sheet,
    [System.Drawing.Rectangle]::new(0, 0, $sourceRect.Width, $sourceRect.Height),
    $sourceRect,
    [System.Drawing.GraphicsUnit]::Pixel
)
$conceptGraphics.Dispose()
$sheet.Dispose()

# The concept sheet displays icons with rounded corners and a faint outer shadow.
# Keep green-dominant artwork only so those presentation artifacts cannot leak
# into the production launcher icon.
for ($y = 0; $y -lt $concept.Height; $y++) {
    for ($x = 0; $x -lt $concept.Width; $x++) {
        $pixel = $concept.GetPixel($x, $y)
        $isGreenArtwork = (
            $pixel.G -gt 70 -and
            ($pixel.G - $pixel.R) -gt 15 -and
            ($pixel.G - $pixel.B) -gt 15
        )
        if (-not $isGreenArtwork) {
            $concept.SetPixel($x, $y, $background)
        }
    }
}

$sourcePath = Join-Path $root "assets\branding\bandly_icon.png"
Resize-Icon $concept 1024 $sourcePath
$source = [System.Drawing.Bitmap]::FromFile($sourcePath)
$concept.Dispose()

$android = @{
    "mipmap-mdpi\ic_launcher.png" = 48
    "mipmap-hdpi\ic_launcher.png" = 72
    "mipmap-xhdpi\ic_launcher.png" = 96
    "mipmap-xxhdpi\ic_launcher.png" = 144
    "mipmap-xxxhdpi\ic_launcher.png" = 192
}
foreach ($entry in $android.GetEnumerator()) {
    Resize-Icon $source $entry.Value (Join-Path $root "android\app\src\main\res\$($entry.Key)")
}

$ios = @{
    "Icon-App-20x20@1x.png" = 20
    "Icon-App-20x20@2x.png" = 40
    "Icon-App-20x20@3x.png" = 60
    "Icon-App-29x29@1x.png" = 29
    "Icon-App-29x29@2x.png" = 58
    "Icon-App-29x29@3x.png" = 87
    "Icon-App-40x40@1x.png" = 40
    "Icon-App-40x40@2x.png" = 80
    "Icon-App-40x40@3x.png" = 120
    "Icon-App-60x60@2x.png" = 120
    "Icon-App-60x60@3x.png" = 180
    "Icon-App-76x76@1x.png" = 76
    "Icon-App-76x76@2x.png" = 152
    "Icon-App-83.5x83.5@2x.png" = 167
    "Icon-App-1024x1024@1x.png" = 1024
}
foreach ($entry in $ios.GetEnumerator()) {
    Resize-Icon $source $entry.Value (Join-Path $root "ios\Runner\Assets.xcassets\AppIcon.appiconset\$($entry.Key)")
}

$macos = @(16, 32, 64, 128, 256, 512, 1024)
foreach ($size in $macos) {
    Resize-Icon $source $size (Join-Path $root "macos\Runner\Assets.xcassets\AppIcon.appiconset\app_icon_$size.png")
}

Resize-Icon $source 32 (Join-Path $root "web\favicon.png")
Resize-Icon $source 192 (Join-Path $root "web\icons\Icon-192.png")
Resize-Icon $source 512 (Join-Path $root "web\icons\Icon-512.png")
Resize-Icon $source 192 (Join-Path $root "web\icons\Icon-maskable-192.png") 0.78
Resize-Icon $source 512 (Join-Path $root "web\icons\Icon-maskable-512.png") 0.78

$windowsPng = Join-Path $env:TEMP "bandly_app_icon_256.png"
Resize-Icon $source 256 $windowsPng
Write-PngIco $windowsPng (Join-Path $root "windows\runner\resources\app_icon.ico")
Remove-Item -LiteralPath $windowsPng

$source.Dispose()
Write-Host "Bandly launcher icons generated from candidate 3."
