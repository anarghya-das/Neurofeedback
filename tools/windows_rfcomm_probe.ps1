# Probe: does the MW75's raw EEG arrive over a direct Windows Bluetooth (RFCOMM) socket?
#
# Run it with the headset paired and worn (close any other program using the headset):
#   right-click this file > "Run with PowerShell"
# It does what the macOS app does, with Winsock instead of IOBluetooth:
#   1. connect the command channel (found through the Serial Port service, SDP)
#   2. connect the data channel (RFCOMM channel 25)
#   3. send enable_raw_mode on the command channel and count what arrives on channel 25
#      for 4 seconds
#   4. send disable_raw_mode and close
#
# Read the result:
#   "data channel: ... bytes in ... packets"  with hundreds or thousands of bytes
#       -> EEG arrives over the socket, so the Windows driver can be written in Dart
#   "connect failed, Winsock error N"  -> send the number and the line before it

$code = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class MwProbe
{
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct SockAddrBth
    {
        public ushort AddressFamily;
        public ulong BtAddr;
        public Guid ServiceClassId;
        public uint Port;
    }

    [DllImport("ws2_32.dll")] static extern int WSAStartup(ushort version, IntPtr data);
    [DllImport("ws2_32.dll")] static extern int WSAGetLastError();
    [DllImport("ws2_32.dll")] static extern IntPtr socket(int af, int type, int protocol);
    [DllImport("ws2_32.dll")] static extern int connect(IntPtr s, ref SockAddrBth name, int namelen);
    [DllImport("ws2_32.dll")] static extern int send(IntPtr s, byte[] buf, int len, int flags);
    [DllImport("ws2_32.dll")] static extern int recv(IntPtr s, byte[] buf, int len, int flags);
    [DllImport("ws2_32.dll")] static extern int setsockopt(IntPtr s, int level, int optname, ref int optval, int optlen);
    [DllImport("ws2_32.dll")] static extern int closesocket(IntPtr s);

    static readonly IntPtr Bad = new IntPtr(-1);

    static IntPtr Open(ulong addr, Guid service, uint port, string label)
    {
        Console.WriteLine("Connecting " + label + " ...");
        IntPtr s = socket(32, 1, 3);               // AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM
        if (s == Bad)
        {
            Console.WriteLine(label + ": socket() failed, Winsock error " + WSAGetLastError());
            return Bad;
        }
        SockAddrBth a = new SockAddrBth();
        a.AddressFamily = 32;
        a.BtAddr = addr;
        a.ServiceClassId = service;
        a.Port = port;
        int rc = connect(s, ref a, Marshal.SizeOf(typeof(SockAddrBth)));
        if (rc != 0)
        {
            Console.WriteLine(label + ": connect failed, Winsock error " + WSAGetLastError());
            closesocket(s);
            return Bad;
        }
        int ms = 500;                               // receive timeout
        setsockopt(s, 0xffff, 0x1006, ref ms, 4);   // SOL_SOCKET, SO_RCVTIMEO
        Console.WriteLine(label + ": connected");
        return s;
    }

    static string Hex(byte[] b, int n)
    {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++)
        {
            if (i > 0) sb.Append(' ');
            sb.Append(b[i].ToString("X2"));
        }
        return sb.ToString();
    }

    public static void Run(ulong addr)
    {
        IntPtr wsa = Marshal.AllocHGlobal(1024);
        int r = WSAStartup(0x0202, wsa);
        if (r != 0) { Console.WriteLine("WSAStartup failed, error " + r); return; }

        Guid spp = new Guid("00001101-0000-1000-8000-00805F9B34FB");
        IntPtr cmd = Open(addr, spp, 0, "command channel (Serial Port service via SDP)");
        if (cmd == Bad) return;
        IntPtr data = Open(addr, Guid.Empty, 25, "data channel (RFCOMM channel 25)");
        if (data == Bad) { closesocket(cmd); return; }

        byte[] on  = new byte[] { 0xFF, 0x04, 0x00, 0x01, 0x09, 0x9A, 0x03, 0x41, 0x01 };
        byte[] off = new byte[] { 0xFF, 0x04, 0x00, 0x01, 0x09, 0x9A, 0x03, 0x41, 0x00 };
        byte[] buf = new byte[4096];

        Console.WriteLine("Sending enable_raw_mode ...");
        send(cmd, on, on.Length, 0);
        int n = recv(cmd, buf, buf.Length, 0);
        if (n > 0) Console.WriteLine("command reply: " + Hex(buf, n));
        else Console.WriteLine("no command reply (recv " + n + ", Winsock error " + WSAGetLastError() + ")");

        Stopwatch sw = Stopwatch.StartNew();
        long total = 0;
        int packets = 0;
        string first = null;
        while (sw.ElapsedMilliseconds < 4000)
        {
            n = recv(data, buf, buf.Length, 0);
            if (n > 0)
            {
                total += n;
                packets++;
                if (first == null) first = Hex(buf, Math.Min(n, 40));
            }
            else if (n == 0)
            {
                Console.WriteLine("data channel closed by the headset");
                break;
            }
        }
        Console.WriteLine("data channel: " + total + " bytes in " + packets + " packets over " +
                          (sw.ElapsedMilliseconds / 1000.0).ToString("0.0") + " s");
        if (first != null) Console.WriteLine("first bytes: " + first);

        send(cmd, off, off.Length, 0);
        System.Threading.Thread.Sleep(500);
        closesocket(data);
        closesocket(cmd);
        Console.WriteLine("Closed.");
    }
}
"@

Add-Type -TypeDefinition $code
try {
    # 50:0B:91:A9:39:84, the lab MW75
    [MwProbe]::Run([uint64]0x500B91A93984)
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
}

Write-Host "`nDone. Take a photo of this window, then press Enter to close."
[void](Read-Host)
