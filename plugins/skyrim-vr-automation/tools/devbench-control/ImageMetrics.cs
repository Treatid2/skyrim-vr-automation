// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public sealed class ImageRegion
{
    public string Eye, Zone;
    public int X, Y, Width, Height;
    public int[][] MaskRuns;

    public bool Includes(int x, int y)
    {
        var row = MaskRuns[y];
        for (int i = 0; i < row.Length; i += 2)
            if (x >= row[i] && x < row[i + 1]) return true;
        return false;
    }
}

public sealed class ImageMetric
{
    public string Eye, Zone;
    public int Samples;
    public double MeanLuma, EdgeContrast;
    public double? PreviousMeanAbsDiff;
}

/// <summary>Native-pixel measurements for receipt-described stereo ROI atlases.</summary>
public sealed class ImageMetrics
{
    private byte[] previous;
    private readonly int width, height;
    private readonly ImageRegion[] regions;

    public ImageMetrics(int width, int height, ImageRegion[] regions)
    {
        if (width <= 0 || height <= 0 || (long)width * height > int.MaxValue / 4 ||
            regions == null || regions.Length == 0)
            throw new ArgumentException("Invalid image dimensions or regions");
        this.width = width; this.height = height; this.regions = regions;
        foreach (var r in regions) {
            if (r == null || r.X < 0 || r.Y < 0 || r.Width < 3 || r.Height < 3 ||
                (long)r.X + r.Width > width || (long)r.Y + r.Height > height)
                throw new ArgumentException("Region outside image");
            if (r.MaskRuns == null || r.MaskRuns.Length != r.Height) throw new ArgumentException("Mask height mismatch");
            foreach (var row in r.MaskRuns) {
                if (row == null || row.Length % 2 != 0) throw new ArgumentException("Invalid mask intervals");
                int end = 0;
                for (int i = 0; i < row.Length; i += 2) {
                    if (row[i] < end || row[i + 1] <= row[i] || row[i + 1] > r.Width)
                        throw new ArgumentException("Invalid mask extent");
                    end = row[i + 1];
                }
            }
        }
    }

    private static byte[] ReadPixels(string path, int width, int height)
    {
        using (var source = new Bitmap(path))
        {
            if (source.Width != width || source.Height != height)
                throw new InvalidDataException("Image dimensions differ from receipt: " + path);
            using (var bitmap = source.Clone(new Rectangle(0, 0, width, height), PixelFormat.Format32bppArgb))
            {
                var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    if (data.Stride != width * 4) throw new InvalidDataException("Unexpected stride");
                    var bytes = new byte[data.Stride * height];
                    Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                    return bytes;
                }
                finally { bitmap.UnlockBits(data); }
            }
        }
    }

    private int Luma(byte[] pixels, int x, int y)
    {
        int i = (y * width + x) * 4;
        return (29 * pixels[i] + 150 * pixels[i + 1] + 77 * pixels[i + 2]) >> 8;
    }

    public ImageMetric[] Measure(string path)
    {
        var pixels = ReadPixels(path, width, height);
        var result = new ImageMetric[regions.Length];
        for (int index = 0; index < regions.Length; index++)
        {
            var r = regions[index];
            long light = 0, edge = 0, delta = 0;
            int count = 0, edgeCount = 0;
            for (int y = 0; y < r.Height - 1; y += 2)
            for (int x = 0; x < r.Width - 1; x += 2)
            {
                if (!r.Includes(x, y)) continue;
                int value = Luma(pixels, r.X + x, r.Y + y);
                light += value;
                if (r.Includes(x + 1, y))
                { edge += Math.Abs(value - Luma(pixels, r.X + x + 1, r.Y + y)); edgeCount++; }
                if (r.Includes(x, y + 1))
                { edge += Math.Abs(value - Luma(pixels, r.X + x, r.Y + y + 1)); edgeCount++; }
                if (previous != null) delta += Math.Abs(value - Luma(previous, r.X + x, r.Y + y));
                count++;
            }
            if (count == 0 || edgeCount == 0) throw new InvalidDataException("No pixels in " + r.Eye + "/" + r.Zone);
            result[index] = new ImageMetric { Eye = r.Eye, Zone = r.Zone, Samples = count,
                MeanLuma = light / (double)count, EdgeContrast = edge / (double)edgeCount,
                PreviousMeanAbsDiff = previous == null ? (double?)null : delta / (double)count };
        }
        previous = pixels;
        return result;
    }
}
