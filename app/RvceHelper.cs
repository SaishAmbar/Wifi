// Helper types for RVCE-Connect.ps1. Compiled at runtime with Add-Type.
// Written for C# 5 so it compiles under Windows PowerShell 5.1.
//
//  - CredMan : read/write/delete a generic credential in Windows Credential Manager
//              (stored per-user and protected by Windows; never written to disk by this tool).
//  - Portal  : minimal HTTP client with certificate pinning for the captive portal and a
//              login POST that builds the request body from a SecureString and wipes it afterwards.

using System;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace RvceWifi
{
    public class StoredCredential
    {
        public string UserName;
        public SecureString Password;
    }

    public static class CredMan
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll")]
        private static extern void CredFree(IntPtr buffer);

        private const int CRED_TYPE_GENERIC = 1;
        private const int CRED_PERSIST_LOCAL_MACHINE = 2; // per-user, survives reboot, not roamed
        private const int ERROR_NOT_FOUND = 1168;

        public static StoredCredential Read(string target)
        {
            IntPtr p;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out p))
            {
                int err = Marshal.GetLastWin32Error();
                if (err == ERROR_NOT_FOUND) return null;
                throw new Win32Exception(err);
            }
            try
            {
                CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
                SecureString ss = new SecureString();
                int chars = c.CredentialBlobSize / 2;
                for (int i = 0; i < chars; i++)
                {
                    ss.AppendChar((char)Marshal.ReadInt16(c.CredentialBlob, i * 2));
                }
                ss.MakeReadOnly();
                StoredCredential r = new StoredCredential();
                r.UserName = c.UserName;
                r.Password = ss;
                return r;
            }
            finally
            {
                CredFree(p);
            }
        }

        public static void Write(string target, string userName, SecureString password)
        {
            if (password == null || password.Length == 0) throw new ArgumentException("Empty password");
            IntPtr blob = Marshal.SecureStringToGlobalAllocUnicode(password);
            try
            {
                CREDENTIAL c = new CREDENTIAL();
                c.Type = CRED_TYPE_GENERIC;
                c.TargetName = target;
                c.UserName = userName;
                c.Comment = "RV Institutions captive portal sign-in (RVCE-Connect)";
                c.CredentialBlob = blob;
                c.CredentialBlobSize = password.Length * 2;
                c.Persist = CRED_PERSIST_LOCAL_MACHINE;
                if (!CredWrite(ref c, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                Marshal.ZeroFreeGlobalAllocUnicode(blob);
            }
        }

        public static bool Delete(string target)
        {
            if (CredDelete(target, CRED_TYPE_GENERIC, 0)) return true;
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND) return false;
            throw new Win32Exception(err);
        }
    }

    // Standard Windows credential dialog, owned by a window we choose (so it opens on top, not hidden
    // behind other windows). The password is copied straight from an unmanaged buffer into a
    // SecureString and the buffer is wiped.
    public static class CredPrompt
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDUI_INFO
        {
            public int cbSize;
            public IntPtr hwndParent;
            public string pszMessageText;
            public string pszCaptionText;
            public IntPtr hbmBanner;
        }

        [DllImport("credui.dll", EntryPoint = "CredUIPromptForCredentialsW", CharSet = CharSet.Unicode)]
        private static extern int CredUIPromptForCredentials(ref CREDUI_INFO info, string targetName, IntPtr reserved,
            int authError, StringBuilder userName, int maxUserName, IntPtr password, int maxPassword,
            ref bool save, int flags);

        private const int CREDUI_FLAGS_DO_NOT_PERSIST = 0x2;
        private const int CREDUI_FLAGS_EXCLUDE_CERTIFICATES = 0x8;
        private const int CREDUI_FLAGS_ALWAYS_SHOW_UI = 0x80;
        private const int CREDUI_FLAGS_GENERIC_CREDENTIALS = 0x40000;
        private const int MaxUser = 514;
        private const int MaxPassword = 257;

        // Returns null if the user cancels.
        public static SecureString Prompt(IntPtr parent, string caption, string message, string target, out string userName)
        {
            userName = null;
            CREDUI_INFO info = new CREDUI_INFO();
            info.cbSize = Marshal.SizeOf(typeof(CREDUI_INFO));
            info.hwndParent = parent;
            info.pszCaptionText = caption;
            info.pszMessageText = message;

            StringBuilder user = new StringBuilder(MaxUser);
            IntPtr pw = Marshal.AllocHGlobal(MaxPassword * 2);
            try
            {
                for (int i = 0; i < MaxPassword; i++) Marshal.WriteInt16(pw, i * 2, 0);
                bool save = false;
                int flags = CREDUI_FLAGS_GENERIC_CREDENTIALS | CREDUI_FLAGS_ALWAYS_SHOW_UI
                            | CREDUI_FLAGS_DO_NOT_PERSIST | CREDUI_FLAGS_EXCLUDE_CERTIFICATES;
                int rc = CredUIPromptForCredentials(ref info, target, IntPtr.Zero, 0, user, MaxUser, pw, MaxPassword, ref save, flags);
                if (rc != 0) return null; // 1223 = cancelled

                userName = user.ToString();
                SecureString ss = new SecureString();
                for (int i = 0; i < MaxPassword; i++)
                {
                    char c = (char)Marshal.ReadInt16(pw, i * 2);
                    if (c == '\0') break;
                    ss.AppendChar(c);
                }
                ss.MakeReadOnly();
                return ss;
            }
            finally
            {
                for (int i = 0; i < MaxPassword; i++) Marshal.WriteInt16(pw, i * 2, 0);
                Marshal.FreeHGlobal(pw);
            }
        }
    }

    public class HttpResult
    {
        public int Status;          // 0 = no HTTP response (timeout, DNS, TLS failure, ...)
        public string Error;        // set when Status == 0
        public string Location;     // Location header, if any
        public string Body;
    }

    public static class Portal
    {
        // Only HTTPS connections to exactly this host:port, presenting exactly this certificate, are accepted.
        public static string AllowedHost = "";
        public static int AllowedPort = 0;
        public static string PinnedSha256 = "";

        // Details of the last certificate seen, so the script can show it to the user for pinning.
        public static string LastCertSha256;
        public static string LastCertSubject;
        public static string LastCertIssuer;
        public static string LastCertExpiry;
        public static string LastPolicyErrors;

        public static CookieContainer Cookies = new CookieContainer();
        private const int MaxBodyChars = 1024 * 1024;

        public static void ResetLastCert()
        {
            LastCertSha256 = null; LastCertSubject = null; LastCertIssuer = null;
            LastCertExpiry = null; LastPolicyErrors = null;
        }

        public static string Sha256Hex(X509Certificate cert)
        {
            using (SHA256 sha = SHA256.Create())
            {
                return BitConverter.ToString(sha.ComputeHash(cert.GetRawCertData())).Replace("-", "");
            }
        }

        public static bool IsAllowed(Uri u)
        {
            return u != null
                && u.Scheme == Uri.UriSchemeHttps
                && string.Equals(u.Host, AllowedHost, StringComparison.OrdinalIgnoreCase)
                && u.Port == AllowedPort;
        }

        private static bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
        {
            if (cert == null) return false;
            LastCertSha256 = Sha256Hex(cert);
            LastCertSubject = cert.Subject;
            LastCertIssuer = cert.Issuer;
            LastCertExpiry = cert.GetExpirationDateString();
            LastPolicyErrors = errors.ToString();

            HttpWebRequest req = sender as HttpWebRequest;
            if (req == null || !IsAllowed(req.RequestUri)) return false;
            if (string.IsNullOrEmpty(PinnedSha256)) return false; // not yet trusted by the user
            return string.Equals(LastCertSha256, PinnedSha256, StringComparison.OrdinalIgnoreCase);
        }

        private static HttpWebRequest Create(Uri uri, string method, int timeoutMs)
        {
            if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
                throw new ArgumentException("Only http/https URLs are supported");
            HttpWebRequest r = (HttpWebRequest)WebRequest.Create(uri);
            r.Method = method;
            r.AllowAutoRedirect = false;   // every hop is inspected by the script
            r.Timeout = timeoutMs;
            r.ReadWriteTimeout = timeoutMs;
            r.KeepAlive = false;
            r.Proxy = null;                // talk to the local gateway directly
            r.CookieContainer = Cookies;
            r.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) RVCE-Connect/1.0";
            if (uri.Scheme == Uri.UriSchemeHttps) r.ServerCertificateValidationCallback = Validate;
            return r;
        }

        public static HttpResult Get(string url, int timeoutMs)
        {
            HttpWebRequest r = Create(new Uri(url), "GET", timeoutMs);
            return Send(r, null);
        }

        // Builds an application/x-www-form-urlencoded body. The caller must wipe the returned array.
        public static byte[] BuildBody(string[] names, string[] values, string userField, string userName,
                                       string passField, SecureString password)
        {
            MemoryStream ms = new MemoryStream();
            IntPtr bstr = IntPtr.Zero;
            char[] pwChars = null;
            byte[] pwBytes = null;
            try
            {
                for (int i = 0; i < names.Length; i++)
                {
                    AppendField(ms, names[i], Encoding.UTF8.GetBytes(values[i] ?? ""));
                }
                AppendField(ms, userField, Encoding.UTF8.GetBytes(userName ?? ""));

                bstr = Marshal.SecureStringToGlobalAllocUnicode(password);
                pwChars = new char[password.Length];
                Marshal.Copy(bstr, pwChars, 0, pwChars.Length);
                pwBytes = Encoding.UTF8.GetBytes(pwChars);
                AppendField(ms, passField, pwBytes);
                return ms.ToArray();
            }
            finally
            {
                if (pwChars != null) Array.Clear(pwChars, 0, pwChars.Length);
                if (pwBytes != null) Array.Clear(pwBytes, 0, pwBytes.Length);
                if (bstr != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(bstr);
                byte[] buf = ms.GetBuffer();
                Array.Clear(buf, 0, buf.Length);
            }
        }

        // Sends the login form exactly once. Refuses anything except the pinned, allow-listed HTTPS portal.
        public static HttpResult PostLogin(string url, string referer, string[] names, string[] values,
                                           string userField, string userName, string passField,
                                           SecureString password, int timeoutMs)
        {
            Uri u = new Uri(url);
            if (!IsAllowed(u))
                throw new InvalidOperationException("Refusing to send credentials to " + u.GetLeftPart(UriPartial.Authority));
            if (string.IsNullOrEmpty(PinnedSha256))
                throw new InvalidOperationException("Portal certificate has not been confirmed; refusing to send credentials");

            byte[] body = BuildBody(names, values, userField, userName, passField, password);
            try
            {
                HttpWebRequest r = Create(u, "POST", timeoutMs);
                if (!string.IsNullOrEmpty(referer)) r.Referer = referer;
                return Send(r, body);
            }
            finally
            {
                Array.Clear(body, 0, body.Length);
            }
        }

        private static HttpResult Send(HttpWebRequest r, byte[] body)
        {
            HttpResult res = new HttpResult();
            try
            {
                if (body != null)
                {
                    r.ContentType = "application/x-www-form-urlencoded";
                    r.ContentLength = body.Length;
                    using (Stream s = r.GetRequestStream()) { s.Write(body, 0, body.Length); }
                }
                using (HttpWebResponse resp = (HttpWebResponse)r.GetResponse()) { Fill(res, resp); }
            }
            catch (WebException ex)
            {
                HttpWebResponse resp = ex.Response as HttpWebResponse;
                if (resp != null)
                {
                    using (resp) { Fill(res, resp); }
                }
                else
                {
                    res.Status = 0;
                    res.Error = ex.Status.ToString() + ": " + ex.Message;
                }
            }
            catch (Exception ex)
            {
                res.Status = 0;
                res.Error = ex.GetType().Name + ": " + ex.Message;
            }
            return res;
        }

        private static void Fill(HttpResult res, HttpWebResponse resp)
        {
            res.Status = (int)resp.StatusCode;
            res.Location = resp.Headers["Location"];
            using (Stream s = resp.GetResponseStream())
            using (StreamReader sr = new StreamReader(s, Encoding.UTF8, true))
            {
                StringBuilder sb = new StringBuilder();
                char[] buf = new char[8192];
                int n;
                while (sb.Length < MaxBodyChars && (n = sr.Read(buf, 0, buf.Length)) > 0) sb.Append(buf, 0, n);
                res.Body = sb.ToString();
            }
        }

        private static void AppendField(MemoryStream ms, string name, byte[] valueUtf8)
        {
            if (ms.Length > 0) ms.WriteByte((byte)'&');
            Encode(ms, Encoding.UTF8.GetBytes(name));
            ms.WriteByte((byte)'=');
            Encode(ms, valueUtf8);
        }

        private static void Encode(MemoryStream ms, byte[] bytes)
        {
            const string hex = "0123456789ABCDEF";
            foreach (byte b in bytes)
            {
                bool unreserved = (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
                                  || b == '-' || b == '_' || b == '.' || b == '~';
                if (unreserved)
                {
                    ms.WriteByte(b);
                }
                else
                {
                    ms.WriteByte((byte)'%');
                    ms.WriteByte((byte)hex[b >> 4]);
                    ms.WriteByte((byte)hex[b & 15]);
                }
            }
        }
    }
}
