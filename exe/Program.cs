using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;

namespace TrustedInstallerShellBootstrap
{
    internal static class Program
    {
        private const string PayloadVersion = "__PAYLOAD_VERSION__";
        private const string PayloadSha256 = "__PAYLOAD_SHA256__";

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                Console.OutputEncoding = Encoding.UTF8;
            }
            catch
            {
            }

            try
            {
                return Run(args);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("[ERROR] " + ex.Message);
                if (!HasArgument(args, "-NoPause") && Environment.UserInteractive)
                {
                    Console.Error.WriteLine();
                    Console.Error.WriteLine("Press Enter to close...");
                    Console.ReadLine();
                }
                return 1;
            }
        }

        private static int Run(string[] args)
        {
            string dataRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "EcoTools",
                "TrustedInstallerShell",
                PayloadVersion);

            EnsurePayload(dataRoot);

            string scriptPath = Path.Combine(dataRoot, "scripts", "Start-TrustedInstallerShell.ps1");
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("Embedded payload is incomplete.", scriptPath);
            }

            string powershellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!File.Exists(powershellPath))
            {
                throw new FileNotFoundException("Windows PowerShell 5.1 was not found.", powershellPath);
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = BuildPowerShellArguments(scriptPath, args),
                WorkingDirectory = dataRoot,
                UseShellExecute = false
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("Unable to start Windows PowerShell.");
                }
                process.WaitForExit();
                return process.ExitCode;
            }
        }

        private static void EnsurePayload(string dataRoot)
        {
            string markerPath = Path.Combine(dataRoot, ".payload.sha256");
            if (File.Exists(markerPath))
            {
                try
                {
                    if (String.Equals(File.ReadAllText(markerPath).Trim(), PayloadSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        return;
                    }
                }
                catch
                {
                }
            }

            Assembly assembly = Assembly.GetExecutingAssembly();
            string resourceName = assembly.GetManifestResourceNames()
                .Single(name => name.EndsWith("payload.zip", StringComparison.OrdinalIgnoreCase));
            string tempRoot = Path.Combine(
                Path.GetTempPath(),
                "EcoTrustedInstallerShell-" + Guid.NewGuid().ToString("N"));

            try
            {
                Directory.CreateDirectory(tempRoot);
                string tempZip = Path.Combine(tempRoot, "payload.zip");
                string extractedRoot = Path.Combine(tempRoot, "extracted");

                using (Stream resource = assembly.GetManifestResourceStream(resourceName))
                using (FileStream output = File.Create(tempZip))
                {
                    if (resource == null)
                    {
                        throw new InvalidDataException("Embedded payload resource is missing.");
                    }
                    resource.CopyTo(output);
                }

                ZipFile.ExtractToDirectory(tempZip, extractedRoot);
                string payloadRoot = Directory.GetDirectories(extractedRoot).Single();
                string parent = Directory.GetParent(dataRoot).FullName;
                Directory.CreateDirectory(parent);

                if (Directory.Exists(dataRoot))
                {
                    Directory.Delete(dataRoot, true);
                }
                Directory.Move(payloadRoot, dataRoot);
                File.WriteAllText(markerPath, PayloadSha256);
            }
            finally
            {
                try
                {
                    if (Directory.Exists(tempRoot))
                    {
                        Directory.Delete(tempRoot, true);
                    }
                }
                catch
                {
                }
            }
        }

        private static string BuildPowerShellArguments(string scriptPath, string[] args)
        {
            StringBuilder builder = new StringBuilder();
            builder.Append("-NoLogo -NoProfile -ExecutionPolicy Bypass -File ");
            builder.Append(QuoteArgument(scriptPath));
            foreach (string argument in args)
            {
                builder.Append(' ');
                builder.Append(QuoteArgument(argument));
            }
            return builder.ToString();
        }

        private static bool HasArgument(string[] args, string value)
        {
            return args.Any(argument => String.Equals(argument, value, StringComparison.OrdinalIgnoreCase));
        }

        private static string QuoteArgument(string value)
        {
            if (String.IsNullOrEmpty(value))
            {
                return "\"\"";
            }

            StringBuilder builder = new StringBuilder();
            builder.Append('"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    builder.Append('\\', backslashes * 2 + 1);
                    builder.Append('"');
                    backslashes = 0;
                    continue;
                }
                if (backslashes > 0)
                {
                    builder.Append('\\', backslashes);
                    backslashes = 0;
                }
                builder.Append(character);
            }
            if (backslashes > 0)
            {
                builder.Append('\\', backslashes * 2);
            }
            builder.Append('"');
            return builder.ToString();
        }
    }
}
