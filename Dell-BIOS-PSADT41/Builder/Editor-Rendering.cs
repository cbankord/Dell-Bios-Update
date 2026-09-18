// Small native boundary for Rich Edit presentation. No file/deployment operations.
using System;
using System.Runtime.InteropServices;

namespace Medela.EditorV44
{
    [ComImport, Guid("8CC497C0-A1DF-11CE-8098-00AA0047BE5D"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    internal interface ITextDocument
    {
        // ITextDocument vtable order from the Windows SDK tom.h.
        void GetName([MarshalAs(UnmanagedType.BStr)] out string name);
        void GetSelection([MarshalAs(UnmanagedType.Interface)] out object selection);
        void GetStoryCount(out int count);
        void GetStoryRanges([MarshalAs(UnmanagedType.Interface)] out object ranges);
        void GetSaved(out int saved);
        void SetSaved(int saved);
        void GetDefaultTabStop(out float value);
        void SetDefaultTabStop(float value);
        void New();
        void Open(ref object value, int flags, int codePage);
        void Save(ref object value, int flags, int codePage);
        void Freeze(out int count);
        void Unfreeze(out int count);
        void BeginEditCollection();
        void EndEditCollection();
        void Undo(int count, out int actual);
    }

    public sealed class RenderScope : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
        [DllImport("user32.dll", EntryPoint="SendMessageW")] private static extern IntPtr Send(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", EntryPoint="SendMessageW")] private static extern IntPtr SendPoint(IntPtr hwnd, int msg, IntPtr w, ref Point point);
        [DllImport("user32.dll", EntryPoint="SendMessageW")] private static extern IntPtr SendInterface(IntPtr hwnd, int msg, IntPtr w, out IntPtr pointer);
        [DllImport("user32.dll")] private static extern bool InvalidateRect(IntPtr hwnd, IntPtr rect, bool erase);
        private IntPtr handle;
        private ITextDocument document;
        private Point scroll;
        private bool suspended, frozen;

        public static RenderScope Begin(IntPtr handle)
        {
            var scope = new RenderScope();
            scope.handle = handle;
            IntPtr ole = IntPtr.Zero, text = IntPtr.Zero;
            try
            {
                if (SendInterface(handle, 0x043C, IntPtr.Zero, out ole) == IntPtr.Zero || ole == IntPtr.Zero)
                    throw new InvalidOperationException("Rich Edit interface unavailable.");
                Guid id = typeof(ITextDocument).GUID;
                Marshal.ThrowExceptionForHR(Marshal.QueryInterface(ole, ref id, out text));
                scope.document = (ITextDocument)Marshal.GetTypedObjectForIUnknown(text, typeof(ITextDocument));
                int actual;
                scope.document.Undo(-9999995, out actual); // tomSuspend: keep color changes out of text undo history.
                scope.suspended = true;
                SendPoint(handle, 0x04DD, IntPtr.Zero, ref scope.scroll); // EM_GETSCROLLPOS
                Send(handle, 0x000B, IntPtr.Zero, IntPtr.Zero); // WM_SETREDRAW(false)
                scope.frozen = true;
                return scope;
            }
            catch { scope.Dispose(); throw; }
            finally
            {
                if (text != IntPtr.Zero) Marshal.Release(text);
                if (ole != IntPtr.Zero) Marshal.Release(ole);
            }
        }

        public void Dispose()
        {
            try { if (suspended) { suspended = false; int actual; document.Undo(-9999994, out actual); } }
            finally
            {
                if (frozen)
                {
                    frozen = false;
                    SendPoint(handle, 0x04DE, IntPtr.Zero, ref scroll); // EM_SETSCROLLPOS
                    Send(handle, 0x000B, new IntPtr(1), IntPtr.Zero);
                    InvalidateRect(handle, IntPtr.Zero, false);
                }
                if (document != null) { Marshal.ReleaseComObject(document); document = null; }
            }
        }
    }
}
