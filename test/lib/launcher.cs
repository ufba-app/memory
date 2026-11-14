using System;
using System.Diagnostics;
using System.IO;
using System.Text;

// Lancador de teste: vira ai-memory.exe / claude.exe e repassa tudo ao stub em Node (stdin e stdout herdados).
static class L {
  static string Q(string a) {
    if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
    var sb = new StringBuilder("\""); int bs = 0;
    foreach (char c in a) {
      if (c == '\\') { bs++; }
      else if (c == '"') { sb.Append('\\', bs * 2 + 1); sb.Append('"'); bs = 0; }
      else { sb.Append('\\', bs); bs = 0; sb.Append(c); }
    }
    sb.Append('\\', bs * 2); sb.Append('"'); return sb.ToString();
  }
  static int Main(string[] a) {
    string self = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName);
    string js = Environment.GetEnvironmentVariable("STUB_JS");
    var sb = new StringBuilder(); sb.Append(Q(js)).Append(' ').Append(Q(self));
    foreach (var x in a) sb.Append(' ').Append(Q(x));
    var psi = new ProcessStartInfo("node", sb.ToString()); psi.UseShellExecute = false;
    var p = Process.Start(psi); p.WaitForExit(); return p.ExitCode;
  }
}
