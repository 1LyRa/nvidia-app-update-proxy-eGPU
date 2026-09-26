using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace NvidiaAppOculinkLauncher
{
    internal sealed class ManifestEntry
    {
        internal ManifestEntry(string relativePath, string sha256, long length)
        {
            RelativePath = relativePath;
            Sha256 = sha256;
            Length = length;
        }

        internal string RelativePath { get; }
        internal string Sha256 { get; }
        internal long Length { get; }
    }

    internal sealed class MaintenanceManifest
    {
        internal const string FileName = "MaintenanceManifest.ps1";

        internal static readonly string[] RequiredRelativePaths =
        {
            "AutoRepair-NvidiaAppOculinkShim.ps1",
            "Install-NvidiaAppOculinkShim.ps1",
            "Migrate-V3ToV4.ps1",
            "NvidiaAppOculinkShim.Common.psm1",
            "Repair-NvidiaAppOculinkShim.ps1",
            "Setup.ps1",
            "Status.ps1",
            "Test-NvidiaAppOculinkShim.ps1",
            "Uninstall-NvidiaAppOculinkShim.ps1",
            "payload\\NvidiaAppOculinkShim.exe",
        };

        private static readonly Regex FileLine = new Regex(
            "^# File-SHA256: ([A-Fa-f0-9]{64})  ([0-9]+)  (.+)$",
            RegexOptions.CultureInvariant);
        private static readonly Regex PackageVersionLine = new Regex(
            "^# Package-Version: " +
            "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" +
            "(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?" +
            "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$",
            RegexOptions.CultureInvariant);

        private MaintenanceManifest(
            string packageVersion,
            IReadOnlyDictionary<string, ManifestEntry> entries)
        {
            PackageVersion = packageVersion;
            Entries = entries;
        }

        internal string PackageVersion { get; }
        internal IReadOnlyDictionary<string, ManifestEntry> Entries { get; }

        internal static MaintenanceManifest Load(string path)
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                throw new InvalidDataException("Maintenance manifest is missing: " + path);
            }
            if (info.Length > 1024 * 1024)
            {
                throw new InvalidDataException("Maintenance manifest is unexpectedly large.");
            }

            return Parse(File.ReadAllLines(path));
        }

        internal static MaintenanceManifest Parse(IEnumerable<string> lines)
        {
            bool manifestVersionSeen = false;
            bool packageVersionSeen = false;
            bool runtimeSeen = false;
            string? packageVersion = null;
            var entries = new Dictionary<string, ManifestEntry>(StringComparer.Ordinal);

            foreach (string sourceLine in lines)
            {
                string line = sourceLine.TrimEnd('\r');
                if (line == "# SIG # Begin signature block")
                {
                    break;
                }
                if (line.Length == 0)
                {
                    continue;
                }
                if (line == "# Manifest-Version: 1")
                {
                    if (manifestVersionSeen)
                    {
                        throw new InvalidDataException("Duplicate Manifest-Version header.");
                    }
                    manifestVersionSeen = true;
                    continue;
                }
                if (line == "# Runtime-Identifier: win-x64")
                {
                    if (runtimeSeen)
                    {
                        throw new InvalidDataException("Duplicate Runtime-Identifier header.");
                    }
                    runtimeSeen = true;
                    continue;
                }
                if (PackageVersionLine.IsMatch(line))
                {
                    if (packageVersionSeen)
                    {
                        throw new InvalidDataException("Duplicate Package-Version header.");
                    }
                    packageVersionSeen = true;
                    packageVersion = line.Substring("# Package-Version: ".Length);
                    continue;
                }

                Match match = FileLine.Match(line);
                if (!match.Success)
                {
                    throw new InvalidDataException("Unexpected maintenance manifest line: " + line);
                }

                long length;
                if (!long.TryParse(
                    match.Groups[2].Value,
                    NumberStyles.None,
                    CultureInfo.InvariantCulture,
                    out length))
                {
                    throw new InvalidDataException("Invalid manifest file length.");
                }

                string relativePath = NormalizeRelativePath(match.Groups[3].Value);
                if (!RequiredRelativePaths.Contains(relativePath, StringComparer.Ordinal))
                {
                    throw new InvalidDataException(
                        "Unexpected maintenance manifest path: " + relativePath);
                }
                if (entries.ContainsKey(relativePath))
                {
                    throw new InvalidDataException(
                        "Duplicate maintenance manifest path: " + relativePath);
                }

                entries.Add(
                    relativePath,
                    new ManifestEntry(
                        relativePath,
                        match.Groups[1].Value.ToUpperInvariant(),
                        length));
            }

            if (!manifestVersionSeen || !packageVersionSeen || !runtimeSeen)
            {
                throw new InvalidDataException("Maintenance manifest headers are incomplete.");
            }
            if (entries.Count != RequiredRelativePaths.Length ||
                RequiredRelativePaths.Any(path => !entries.ContainsKey(path)))
            {
                throw new InvalidDataException(
                    "Maintenance manifest does not contain the exact required file set.");
            }

            return new MaintenanceManifest(packageVersion!, entries);
        }

        internal static string NormalizeRelativePath(string value)
        {
            if (string.IsNullOrWhiteSpace(value) ||
                Path.IsPathRooted(value) ||
                value.IndexOf('/') >= 0 ||
                value.IndexOf(':') >= 0 ||
                value.IndexOf('\0') >= 0)
            {
                throw new InvalidDataException("Unsafe maintenance manifest path: " + value);
            }

            string[] segments = value.Split(new[] { '\\' }, StringSplitOptions.None);
            if (segments.Length == 0)
            {
                throw new InvalidDataException("Unsafe maintenance manifest path: " + value);
            }
            foreach (string segment in segments)
            {
                if (segment.Length == 0 || segment == "." || segment == ".." ||
                    segment.EndsWith(".", StringComparison.Ordinal) ||
                    segment.EndsWith(" ", StringComparison.Ordinal) ||
                    segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                {
                    throw new InvalidDataException("Unsafe maintenance manifest path: " + value);
                }
            }

            string normalized = string.Join("\\", segments);
            string full = Path.GetFullPath(Path.Combine("C:\\manifest-root", normalized));
            string prefix = "C:\\manifest-root\\";
            if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Manifest path escapes its package root: " + value);
            }
            return normalized;
        }
    }
}
