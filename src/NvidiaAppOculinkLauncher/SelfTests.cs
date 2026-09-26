using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace NvidiaAppOculinkLauncher
{
    internal static class SelfTests
    {
        internal static int Run()
        {
            try
            {
                TestArgumentParser();
                TestWindowsQuoting();
                TestManifestParser();
                TestManifestPaths();
                TestSignatureClassification();
                TestPowerShellEnvironment();
                TestStagingDirectoryClassification();
                TestExecutableLease();
                string powerShell = PowerShellRunner.GetPowerShellPath();
                Require(
                    powerShell.EndsWith(
                        "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                        StringComparison.OrdinalIgnoreCase),
                    "PowerShell path is not fixed below System32.");
                Require(
                    Program.GetNvidiaAppPath().EndsWith(
                        "\\NVIDIA Corporation\\NVIDIA App\\CEF\\NVIDIA App.exe",
                        StringComparison.OrdinalIgnoreCase),
                    "NVIDIA App path is not fixed below Program Files.");
                Console.WriteLine(
                    "Launcher self-test passed: arguments, quoting, manifest, and paths are scoped.");
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine("Launcher self-test failed: " + exception);
                return 1;
            }
        }

        private static void TestArgumentParser()
        {
            Require(ArgumentParser.Parse(new string[0]).Kind == CommandKind.Menu,
                "Empty arguments did not select the menu.");
            foreach (MaintenanceAction action in Enum.GetValues<MaintenanceAction>())
            {
                string value = ArgumentParser.ToArgumentValue(action);
                ParsedCommand parsed = ArgumentParser.Parse(
                    new[] { "--action", value });
                Require(parsed.Kind == CommandKind.PublicAction && parsed.Action == action,
                    "Public action parsing failed for " + value);
            }
            Require(
                ArgumentParser.Parse(new[] { "--elevated-child", "setup" }).Kind ==
                    CommandKind.ElevatedChild,
                "Elevated setup parsing failed.");
            Require(
                ArgumentParser.Parse(new[] { "--elevated-child", "status" }).Kind ==
                    CommandKind.Invalid,
                "Elevated status was not rejected.");
            Require(
                ArgumentParser.Parse(new[] { "--action", "unknown" }).Kind ==
                    CommandKind.Invalid,
                "Unknown action was not rejected.");
            Require(
                ArgumentParser.Parse(new[] { "--self-test", "extra" }).Kind ==
                    CommandKind.Invalid,
                "Extra self-test arguments were not rejected.");
            Require(
                ArgumentParser.Parse(new[] { "--verify-package" }).Kind ==
                    CommandKind.VerifyPackage,
                "Package verification argument was not accepted.");
            Require(
                ArgumentParser.Parse(new[] { "--verify-package", "extra" }).Kind ==
                    CommandKind.Invalid,
                "Extra package verification arguments were not rejected.");
        }

        private static void TestWindowsQuoting()
        {
            string[] values =
            {
                string.Empty,
                "simple",
                "with spaces",
                "C:\\包 目录\\",
                "embedded\"quote",
                "slashes-before-quote\\\\\"value",
                "tab\tvalue",
                "ampersand&parentheses()",
            };
            foreach (string value in values)
            {
                string commandLine = "launcher.exe " +
                    WindowsCommandLine.QuoteArgument(value);
                string[] parsed = NativeMethods.ParseWindowsCommandLine(commandLine);
                Require(parsed.Length == 2 && parsed[1] == value,
                    "Windows quoting round-trip failed for: " + value);
            }
        }

        private static void TestManifestParser()
        {
            var lines = new List<string>
            {
                "# Manifest-Version: 1",
                "# Package-Version: 4.0.0-test.1",
                "# Runtime-Identifier: win-x64",
            };
            int index = 1;
            foreach (string path in MaintenanceManifest.RequiredRelativePaths)
            {
                lines.Add(
                    "# File-SHA256: " + new string(
                        "0123456789ABCDEF"[(index++) % 16], 64) +
                    "  0  " + path);
            }
            lines.Add("# SIG # Begin signature block");
            lines.Add("# ignored-signature-data");
            MaintenanceManifest manifest = MaintenanceManifest.Parse(lines);
            Require(manifest.Entries.Count == 10,
                "Manifest did not contain ten exact payload entries.");

            var missing = new List<string>(lines);
            missing.RemoveAt(3);
            ExpectInvalidManifest(missing, "Missing manifest file was accepted.");

            var duplicate = new List<string>(lines);
            duplicate.Insert(4, duplicate[3]);
            ExpectInvalidManifest(duplicate, "Duplicate manifest file was accepted.");

            var unexpected = new List<string>(lines);
            unexpected.Insert(
                unexpected.Count - 2,
                "# File-SHA256: " + new string('A', 64) + "  0  extra.exe");
            ExpectInvalidManifest(unexpected, "Unexpected manifest file was accepted.");
        }

        private static void TestManifestPaths()
        {
            Require(
                MaintenanceManifest.NormalizeRelativePath(
                    "payload\\NvidiaAppOculinkShim.exe") ==
                    "payload\\NvidiaAppOculinkShim.exe",
                "Safe manifest path changed during normalization.");
            foreach (string unsafePath in new[]
            {
                "C:\\absolute.exe",
                "..\\escape.exe",
                "payload\\..\\escape.exe",
                "payload/NvidiaAppOculinkShim.exe",
                "payload\\",
                "payload\\trailing.\\file.exe",
                "payload\\trailing \\file.exe",
                "payload\\double\\\\file.exe",
            })
            {
                bool rejected = false;
                try
                {
                    MaintenanceManifest.NormalizeRelativePath(unsafePath);
                }
                catch (InvalidDataException)
                {
                    rejected = true;
                }
                Require(rejected, "Unsafe manifest path was accepted: " + unsafePath);
            }
        }

        private static void TestSignatureClassification()
        {
            string? signer;
            bool production = PackageTrust.ClassifyLauncherSignature(
                new SignatureResult(
                    false,
                    null,
                    PackageTrust.TrustENoSignature),
                out signer);
            Require(!production && signer == null,
                "A truly unsigned launcher did not select development mode.");

            production = PackageTrust.ClassifyLauncherSignature(
                new SignatureResult(true, new string('A', 40), 0),
                out signer);
            Require(production && signer == new string('A', 40),
                "A trusted launcher signer was not preserved.");

            foreach (SignatureResult invalid in new[]
            {
                new SignatureResult(false, new string('B', 40),
                    unchecked((int)0x80096010)),
                new SignatureResult(false, null, unchecked((int)0x80004005)),
                new SignatureResult(true, null, 0),
            })
            {
                bool rejected = false;
                try
                {
                    PackageTrust.ClassifyLauncherSignature(invalid, out signer);
                }
                catch (InvalidDataException)
                {
                    rejected = true;
                }
                Require(rejected,
                    "An invalid or untrusted signature downgraded to development mode.");
            }
        }

        private static void TestPowerShellEnvironment()
        {
            var startInfo = new ProcessStartInfo();
            startInfo.EnvironmentVariables["COR_ENABLE_PROFILING"] = "1";
            startInfo.EnvironmentVariables["CORECLR_ENABLE_PROFILING"] = "1";
            startInfo.EnvironmentVariables["DOTNET_STARTUP_HOOKS"] =
                "C:\\untrusted\\hook.dll";
            startInfo.EnvironmentVariables["PATH"] = "C:\\untrusted";
            PowerShellRunner.SanitizeEnvironment(startInfo);

            Require(!startInfo.EnvironmentVariables.ContainsKey(
                "COR_ENABLE_PROFILING"),
                "The PowerShell environment retained COR profiling.");
            Require(!startInfo.EnvironmentVariables.ContainsKey(
                "CORECLR_ENABLE_PROFILING"),
                "The PowerShell environment retained CoreCLR profiling.");
            Require(!startInfo.EnvironmentVariables.ContainsKey(
                "DOTNET_STARTUP_HOOKS"),
                "The PowerShell environment retained a startup hook.");
            Require(
                string.Equals(
                    startInfo.EnvironmentVariables["ProgramData"],
                    Environment.GetFolderPath(
                        Environment.SpecialFolder.CommonApplicationData),
                    StringComparison.OrdinalIgnoreCase),
                "ProgramData was not rebuilt from the Windows known folder.");
            Require(
                !startInfo.EnvironmentVariables["PATH"]!.Contains(
                    "untrusted",
                    StringComparison.OrdinalIgnoreCase),
                "The PowerShell PATH retained an untrusted directory.");
        }

        private static void TestStagingDirectoryClassification()
        {
            Require(
                StagingArea.IsStagingLeafName(
                    "NVIDIAAppOCuLink-Staging-" +
                    "0123456789abcdef0123456789abcdef"),
                "A valid staging directory name was rejected.");
            foreach (string invalid in new[]
            {
                "NVIDIAAppOCuLink-Staging-0123456789abcdef0123456789abcde",
                "NVIDIAAppOCuLink-Staging-0123456789abcdef0123456789abcdef-extra",
                "nvidiaappoculink-staging-0123456789abcdef0123456789abcdef",
                "NVIDIAAppOCuLink-Staging-not-a-guid",
            })
            {
                Require(
                    !StagingArea.IsStagingLeafName(invalid),
                    "An invalid staging directory name was accepted: " + invalid);
            }

            var current = new DateTime(2026, 8, 3, 12, 0, 0, DateTimeKind.Utc);
            Require(
                StagingArea.IsStaleDirectory(current.AddHours(-24), current),
                "A staging directory at the cleanup age was not stale.");
            Require(
                !StagingArea.IsStaleDirectory(
                    current.AddHours(-24).AddTicks(1),
                    current),
                "A recent staging directory was considered stale.");
        }

        private static void TestExecutableLease()
        {
            string path = Path.Combine(
                Path.GetTempPath(),
                "nvidia-oculink-launcher-lease-" +
                Guid.NewGuid().ToString("N") + ".tmp");
            string moved = path + ".moved";
            ExecutableLease? lease = null;
            try
            {
                File.WriteAllText(path, "lease-test");
                lease = ExecutableLease.Open(path);
                lease.AssertPathIdentity();

                bool replacementBlocked = false;
                try
                {
                    File.Move(path, moved);
                }
                catch (IOException)
                {
                    replacementBlocked = true;
                }
                catch (UnauthorizedAccessException)
                {
                    replacementBlocked = true;
                }
                Require(
                    replacementBlocked,
                    "The executable lease did not block path replacement.");
                lease.AssertPathIdentity();
            }
            finally
            {
                lease?.Dispose();
                File.Delete(path);
                File.Delete(moved);
            }
        }

        private static void ExpectInvalidManifest(
            IEnumerable<string> lines,
            string failureMessage)
        {
            bool rejected = false;
            try
            {
                MaintenanceManifest.Parse(lines);
            }
            catch (InvalidDataException)
            {
                rejected = true;
            }
            Require(rejected, failureMessage);
        }

        private static void Require(bool condition, string message)
        {
            if (!condition)
            {
                throw new InvalidOperationException(message);
            }
        }
    }
}
