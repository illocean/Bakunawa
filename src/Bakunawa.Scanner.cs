using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Bakunawa {
    public sealed class ScanEntry {
        public string Path, Kind, Message;
        public long Bytes, Files;
        public DateTime LatestWriteUtc;
        public bool Complete = true;
    }

    // One iterative, streaming walk. Memory follows tree depth, not file count.
    public static class Scanner {
        [DllImport("shell32.dll")]
        static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);

        public static string KnownFolder(string id) {
            Guid folder = new Guid(id);
            IntPtr path = IntPtr.Zero;
            try {
                // DONT_VERIFY returns redirected paths without creating or opening folders.
                Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(ref folder, 0x4000, IntPtr.Zero, out path));
                return Marshal.PtrToStringUni(path);
            } finally { if (path != IntPtr.Zero) Marshal.FreeCoTaskMem(path); }
        }

        // Check ancestors before touching descendants: C:\link\cache may live on D:.
        public static bool IsAllowedPath(string path) {
            return PathIssue(path) == null;
        }
        public static string PathIssue(string path) {
            if (String.IsNullOrWhiteSpace(path)) return "Empty path";
            path = path.Replace('/', '\\');
            if (!path.StartsWith("C:\\", StringComparison.OrdinalIgnoreCase) || path.IndexOf(':', 2) >= 0) return "C: only; absolute local paths required";
            try {
                string full = Path.GetFullPath(path);
                string current = "C:\\";
                foreach (string part in full.Substring(3).Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries)) {
                    current = Path.Combine(current, part);
                    try {
                        if ((File.GetAttributes(current) & (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0) return "Reparse point or offline content: " + current;
                    } catch (FileNotFoundException) { }
                      catch (DirectoryNotFoundException) { }
                }
                return null;
            } catch (Exception e) { return e.Message; }
        }

        sealed class Frame : IDisposable {
            public DirectoryInfo Directory;
            public IEnumerator<FileSystemInfo> Iterator;
            public long Bytes, Files, Children;
            public DateTime Latest;
            public bool Complete = true;
            public Frame(string path) {
                Directory = new DirectoryInfo(path);
                Latest = Directory.LastWriteTimeUtc;
                Iterator = Directory.EnumerateFileSystemInfos().GetEnumerator();
            }
            public void Dispose() { if (Iterator != null) Iterator.Dispose(); }
        }
        public static bool Within(string path, string root) {
            root = root.TrimEnd(Path.DirectorySeparatorChar);
            return path.Equals(root, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }
        public static bool Blocked(string path, string[] exclusions) {
            foreach (string root in exclusions) if (Within(path, root)) return true;
            return false;
        }
        static bool IsLink(FileSystemInfo item) {
            return (item.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0;
        }
        public static IEnumerable<ScanEntry> Walk(string root, string[] exclusions) {
            return Walk(root, exclusions, false);
        }
        public static IEnumerable<ScanEntry> Walk(string root, string[] exclusions, bool discovery) {
            if (!IsAllowedPath(root)) {
                yield return new ScanEntry { Path = root, Kind = "Skipped", Message = PathIssue(root), Complete = false };
                yield break;
            }
            var stack = new Stack<Frame>();
            string failure = null;
            try {
                var info = new DirectoryInfo(root);
                if (Blocked(info.FullName, exclusions) || IsLink(info)) {
                    failure = "Protected path, reparse point or offline content";
                } else { stack.Push(new Frame(root)); }
            } catch (Exception e) { failure = e.Message; }
            if (failure != null) {
                yield return new ScanEntry { Path = root, Kind = "Skipped", Message = failure, Complete = false };
                yield break;
            }
            long visited = 0;
            try {
                while (stack.Count > 0) {
                    Frame frame = stack.Peek();
                    FileSystemInfo item = null;
                    failure = null;
                    try { if (frame.Iterator.MoveNext()) item = frame.Iterator.Current; }
                    catch (Exception e) { failure = e.Message; frame.Complete = false; }
                    if (failure != null)
                        yield return new ScanEntry { Path = frame.Directory.FullName, Kind = "Error", Message = failure, Complete = false };
                    if (item == null) {
                        stack.Pop();
                        frame.Dispose();
                        if (stack.Count > 0) {
                            Frame parent = stack.Peek();
                            parent.Bytes += frame.Bytes;
                            parent.Files += frame.Files;
                            if (frame.Latest > parent.Latest) parent.Latest = frame.Latest;
                            parent.Complete &= frame.Complete;
                        }
                        yield return new ScanEntry {
                            Path = frame.Directory.FullName, Kind = frame.Children == 0 ? "EmptyDirectory" : "Directory",
                            Bytes = frame.Bytes, Files = frame.Files, LatestWriteUtc = frame.Latest, Complete = frame.Complete
                        };
                        continue;
                    }
                    frame.Children++;
                    bool skip = false, directory = false;
                    try {
                        skip = Blocked(item.FullName, exclusions) || IsLink(item);
                        directory = (item.Attributes & FileAttributes.Directory) != 0;
                        if (discovery && directory && (item.Name.Equals(".git", StringComparison.OrdinalIgnoreCase) ||
                            item.Name.Equals(".svn", StringComparison.OrdinalIgnoreCase) || item.Name.Equals(".hg", StringComparison.OrdinalIgnoreCase))) skip = true;
                    } catch (Exception e) { failure = e.Message; }
                    if (skip || failure != null) {
                        frame.Complete = false;
                        yield return new ScanEntry { Path = item.FullName, Kind = failure == null ? "Skipped" : "Error",
                            Message = failure ?? "Protected path, reparse point or offline content", Complete = false };
                        continue;
                    }
                    if (directory) {
                        try { stack.Push(new Frame(item.FullName)); }
                        catch (Exception e) { failure = e.Message; frame.Complete = false; }
                        if (failure != null)
                            yield return new ScanEntry { Path = item.FullName, Kind = "Error", Message = failure, Complete = false };
                    } else {
                        ScanEntry file = null;
                        try {
                            var fi = (FileInfo)item;
                            frame.Bytes += fi.Length;
                            frame.Files++;
                            if (fi.LastWriteTimeUtc > frame.Latest) frame.Latest = fi.LastWriteTimeUtc;
                            file = new ScanEntry { Path = fi.FullName, Kind = "File", Bytes = fi.Length,
                                Files = 1, LatestWriteUtc = fi.LastWriteTimeUtc };
                        } catch (Exception e) { failure = e.Message; frame.Complete = false; }
                        if (failure != null)
                            yield return new ScanEntry { Path = item.FullName, Kind = "Error", Message = failure, Complete = false };
                        // Emit only useful file candidates; all files still contribute to subtree totals.
                        if (file != null) {
                            string ext = Path.GetExtension(file.Path).ToLowerInvariant();
                            if (ext == ".tmp" || ext == ".temp" || ext == ".dmp" || ext == ".lnk" || ext == ".log")
                                yield return file;
                        }
                    }
                    if (++visited % 2048 == 0)
                        yield return new ScanEntry { Path = item.FullName, Kind = "Progress", Files = visited };
                }
            } finally { while (stack.Count > 0) stack.Pop().Dispose(); }
        }

        // Validate the entire target before a recursive mutation, including excluded descendants.
        public static ScanEntry Inspect(string path, string[] exclusions) {
            if (!IsAllowedPath(path)) throw new IOException("C: only; Reparse points, offline and inaccessible paths are blocked: " + path);
            path = Path.GetFullPath(path);
            if (Blocked(path, exclusions)) throw new IOException("Protected cleanup target: " + path);
            for (var parent = new DirectoryInfo(Path.GetDirectoryName(path)); parent != null; parent = parent.Parent)
                if (IsLink(parent)) throw new IOException("Reparse point in target ancestry: " + parent.FullName);
            if (File.Exists(path)) {
                var file = new FileInfo(path);
                if (IsLink(file)) throw new IOException("Reparse point or offline file: " + path);
                return new ScanEntry { Path = path, Kind = "File", Bytes = file.Length, Files = 1, LatestWriteUtc = file.LastWriteTimeUtc };
            }
            ScanEntry result = null;
            foreach (ScanEntry entry in Walk(path, exclusions)) {
                if (!entry.Complete) throw new IOException("Target could not be fully validated: " + entry.Path + " " + entry.Message);
                if (entry.Path.Equals(path, StringComparison.OrdinalIgnoreCase)) result = entry;
            }
            if (result == null) throw new IOException("Target could not be inspected: " + path);
            return result;
        }
    }
}
