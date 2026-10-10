// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
namespace SkyrimVRAutomation.Native {
    public sealed class InteractiveContext {
        public int Pid, SessionId, IntegrityRid;
        public string Path, UserSid, CreatedUtc;
        public bool Elevated, AppContainer;
    }
    public sealed class InteractiveLaunch {
        public int ProcessId, ThreadId;
        public IntPtr ProcessHandle, ThreadHandle;
        public InteractiveContext Caller, Desktop, Child;
        public bool NormalUserAccessVerified;
        public string Method;
    }
    // No credentials, existing token/ACL edits, privilege adjustment, shell
    // command or elevated fallback. Only NEW object creation security is set;
    // the shell token is read/duplicated, never modified.
    public static class NormalInteractiveProcess {
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI {
            public int cb; public string reserved, desktop, title;
            public uint x,y,xSize,ySize,xChars,yChars,fill,flags;
            public short show,reserved2; public IntPtr lpReserved2,hIn,hOut,hErr;
        }
        [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process,thread; public int pid,tid; }
        [StructLayout(LayoutKind.Sequential)] struct SX { public SI si; public IntPtr attributes; }
        [StructLayout(LayoutKind.Sequential)] struct SA { public int size; public IntPtr descriptor; public int inherit; }
        [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint low,high; public long Value { get { return ((long)high << 32) | low; } } }
        [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out int pid);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint rights,bool inherit,int pid);
        [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out FILETIME created,out FILETIME exit,out FILETIME kernel,out FILETIME user);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder name,ref uint size);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint rights,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int kind,IntPtr data,int size,out int used);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr token,uint rights,IntPtr attributes,int level,int type,out IntPtr duplicate);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool ImpersonateLoggedOnUser(IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool RevertToSelf();
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr source,IntPtr handle,IntPtr target,out IntPtr copy,uint rights,bool inherit,uint flags);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool InitializeSecurityDescriptor(IntPtr descriptor,uint revision);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetSecurityDescriptorDacl(IntPtr descriptor,bool present,IntPtr acl,bool defaulted);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetSecurityDescriptorOwner(IntPtr descriptor,IntPtr sid,bool defaulted);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl,uint revision,out IntPtr descriptor,out uint length);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetSecurityDescriptorSacl(IntPtr descriptor,out bool present,out IntPtr acl,out bool defaulted);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetSecurityDescriptorSacl(IntPtr descriptor,bool present,IntPtr acl,bool defaulted);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("kernel32.dll",EntryPoint="CreateProcessW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessExtended(string application,StringBuilder command,ref SA pa,ref SA ta,bool inherit,uint flags,IntPtr environment,string cwd,ref SX startup,out PI process);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string application,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr environment,string cwd,ref SI startup,out PI process);
        [DllImport("kernel32.dll",SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr process,uint ms);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
        static bool CancelSuspended(PI pi) {
            if(pi.process==IntPtr.Zero)return true;
            uint code;bool requested=TerminateProcess(pi.process,0xe0000023);
            bool exited=WaitForSingleObject(pi.process,100)==0 && GetExitCodeProcess(pi.process,out code) && code!=259;
            bool threadClosed=pi.thread==IntPtr.Zero || CloseHandle(pi.thread);
            bool processClosed=CloseHandle(pi.process);
            return requested && exited && threadClosed && processClosed;
        }
        public static bool Abort(InteractiveLaunch launch) { return CancelSuspended(new PI {process=launch.ProcessHandle,thread=launch.ThreadHandle,pid=launch.ProcessId,tid=launch.ThreadId}); }
        static void Check(bool ok,string operation) { if(!ok) { int error=Marshal.GetLastWin32Error();throw new Win32Exception(error,operation+"; Win32="+error); } }
        static IntPtr Info(IntPtr token,int kind) {
            int size; GetTokenInformation(token,kind,IntPtr.Zero,0,out size);
            if(size<=0 || size>65536) throw new InvalidOperationException("Token metadata size unavailable/out of bound");
            var value=Marshal.AllocHGlobal(size);
            try { Check(GetTokenInformation(token,kind,value,size,out size),"GetTokenInformation"); return value; }
            catch { Marshal.FreeHGlobal(value); throw; }
        }
        static int Number(IntPtr token,int kind) { var p=Info(token,kind); try { return Marshal.ReadInt32(p); } finally { Marshal.FreeHGlobal(p); } }
        static string Sid(IntPtr token,int kind) { var p=Info(token,kind); try { return new SecurityIdentifier(Marshal.ReadIntPtr(p)).Value; } finally { Marshal.FreeHGlobal(p); } }
        static InteractiveContext Read(IntPtr process,int pid) {
            IntPtr token; Check(OpenProcessToken(process,8,out token),"OpenProcessToken(query)");
            try {
                FILETIME created,exit,kernel,user; Check(GetProcessTimes(process,out created,out exit,out kernel,out user),"GetProcessTimes");
                uint size=32768; var path=new StringBuilder((int)size); Check(QueryFullProcessImageName(process,0,path,ref size),"QueryFullProcessImageName");
                string integrity=Sid(token,25);
                return new InteractiveContext { Pid=pid,Path=path.ToString(),CreatedUtc=DateTime.FromFileTimeUtc(created.Value).ToString("o"),
                    SessionId=Number(token,12),UserSid=Sid(token,1),IntegrityRid=int.Parse(integrity.Substring(integrity.LastIndexOf('-')+1)),
                    Elevated=Number(token,20)!=0,AppContainer=Number(token,29)!=0 };
            } finally { CloseHandle(token); }
        }
        public static void ValidateContext(InteractiveContext caller,InteractiveContext desktop) {
            if(caller==null || desktop==null || String.IsNullOrEmpty(caller.UserSid) || caller.Pid<=0 || desktop.Pid<=0 ||
               String.IsNullOrEmpty(caller.CreatedUtc) || String.IsNullOrEmpty(desktop.CreatedUtc) ||
               caller.UserSid!=desktop.UserSid || caller.SessionId!=desktop.SessionId || caller.SessionId<=0 ||
               desktop.Elevated || desktop.AppContainer || desktop.IntegrityRid!=8192 || caller.AppContainer ||
               (caller.IntegrityRid!=8192 && caller.IntegrityRid!=12288) ||
               (caller.IntegrityRid==8192 && caller.Elevated) ||
               (caller.IntegrityRid==12288 && !caller.Elevated))
                throw new InvalidOperationException("Normal interactive same-user/session/context gate refused");
            string expected=System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"explorer.exe");
            if(!String.Equals(desktop.Path,expected,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Desktop shell executable identity refused");
        }
        public static void ValidateChild(InteractiveContext desktop,InteractiveContext child,string expectedPath) {
            if(child==null || child.Pid<=0 || String.IsNullOrEmpty(child.CreatedUtc) || child.Elevated || child.AppContainer || child.IntegrityRid!=8192 || child.UserSid!=desktop.UserSid ||
               child.SessionId!=desktop.SessionId || !String.Equals(child.Path,System.IO.Path.GetFullPath(expectedPath),StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Suspended child effective context/path gate refused");
        }
        static void Deadline(DateTime deadline) { if(DateTime.UtcNow>=deadline) throw new TimeoutException("Normal interactive launch admission deadline expired"); }
        static PI CreateDesktopParent(IntPtr shell,IntPtr token,string path,string command,string cwd,SI startup) {
            IntPtr size=IntPtr.Zero,list=IntPtr.Zero,parentValue=IntPtr.Zero,handles=IntPtr.Zero,descriptor=IntPtr.Zero,dacl=IntPtr.Zero,owner=IntPtr.Zero,label=IntPtr.Zero;
            bool initialized=false; var remote=new System.Collections.Generic.List<IntPtr>(); PI result=new PI();
            try {
                int count=(startup.flags&0x100)!=0?2:1;
                InitializeProcThreadAttributeList(IntPtr.Zero,count,0,ref size);list=Marshal.AllocHGlobal(size);
                Check(InitializeProcThreadAttributeList(list,count,0,ref size),"Initialize desktop attributes");initialized=true;
                parentValue=Marshal.AllocHGlobal(IntPtr.Size);Marshal.WriteIntPtr(parentValue,shell);
                Check(UpdateProcThreadAttribute(list,0,(IntPtr)0x20000,parentValue,(IntPtr)IntPtr.Size,IntPtr.Zero,IntPtr.Zero),"Bind desktop parent");
                if(count==2) {
                    foreach(var handle in new[]{startup.hIn,startup.hOut,startup.hErr}) {
                        IntPtr copy;Check(DuplicateHandle(GetCurrentProcess(),handle,shell,out copy,0,true,2),"Duplicate owned stream handle into desktop parent");remote.Add(copy);
                    }
                    startup.hIn=remote[0];startup.hOut=remote[1];startup.hErr=remote[2];
                    handles=Marshal.AllocHGlobal(IntPtr.Size*3);for(int i=0;i<3;i++)Marshal.WriteIntPtr(handles,i*IntPtr.Size,remote[i]);
                    Check(UpdateProcThreadAttribute(list,0,(IntPtr)0x20002,handles,(IntPtr)(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero),"Bind only owned standard handles");
                }
                // Select initial object security from the normal desktop token.
                // No existing object ACL or token is changed. A parent attribute
                // alone otherwise uses the elevated creator's default DACL.
                dacl=Info(token,6);owner=Info(token,1);descriptor=Marshal.AllocHGlobal(64);
                Check(InitializeSecurityDescriptor(descriptor,1),"Initialize creation security");
                if(Marshal.ReadIntPtr(dacl)==IntPtr.Zero) throw new InvalidOperationException("Desktop token default DACL unavailable");
                Check(SetSecurityDescriptorDacl(descriptor,true,Marshal.ReadIntPtr(dacl),false),"Select desktop-token creation DACL");
                Check(SetSecurityDescriptorOwner(descriptor,Marshal.ReadIntPtr(owner),false),"Select same-user creation owner");
                uint labelSize;bool present,defaulted;IntPtr labelAcl;
                Check(ConvertStringSecurityDescriptorToSecurityDescriptor("S:(ML;;NW;;;ME)",1,out label,out labelSize),"Select normal-context creation integrity");
                Check(GetSecurityDescriptorSacl(label,out present,out labelAcl,out defaulted),"Read creation integrity");
                Check(SetSecurityDescriptorSacl(descriptor,present,labelAcl,defaulted),"Bind creation integrity");
                var security=new SA {size=Marshal.SizeOf(typeof(SA)),descriptor=descriptor};
                var sx=new SX {si=startup,attributes=list};sx.si.cb=Marshal.SizeOf(typeof(SX));
                Check(CreateProcessExtended(path,new StringBuilder(command),ref security,ref security,count==2,4|0x08000000|0x80000,IntPtr.Zero,cwd,ref sx,out result),"Create suspended desktop-token process");
                return result;
            } finally {
                // Close only these temporary owned duplicates, never shell or
                // unrelated application handles. Child keeps its own inherited copies.
                string cleanupError=null;
                foreach(var handle in remote) {
                    IntPtr copy;
                    if(!DuplicateHandle(shell,handle,GetCurrentProcess(),out copy,0,false,1|2)) cleanupError="Owned parent stream cleanup failed; Win32="+Marshal.GetLastWin32Error();
                    else if(!CloseHandle(copy)) cleanupError="Returned stream cleanup failed; Win32="+Marshal.GetLastWin32Error();
                }
                if(initialized)DeleteProcThreadAttributeList(list);
                foreach(var p in new[]{list,parentValue,handles,descriptor,dacl,owner})if(p!=IntPtr.Zero)Marshal.FreeHGlobal(p);
                if(label!=IntPtr.Zero)LocalFree(label);
                if(cleanupError!=null) {
                    bool cleaned=CancelSuspended(result);
                    var failure=new InvalidOperationException(cleanupError);
                    failure.Data["normalLaunchPid"]=result.pid;failure.Data["normalLaunchCleanupVerified"]=cleaned;
                    throw failure;
                }
            }
        }
        public static InteractiveLaunch Create(string path,string command,string cwd,IntPtr stdin,IntPtr stdout,IntPtr stderr,DateTime deadline) {
            Deadline(deadline);
            int shellPid; if(GetShellWindow()==IntPtr.Zero || GetWindowThreadProcessId(GetShellWindow(),out shellPid)==0) throw new InvalidOperationException("No attributable interactive desktop shell");
            IntPtr shell=OpenProcess(0x1000|0x80|0x40,false,shellPid),token=IntPtr.Zero,duplicate=IntPtr.Zero;
            PI pi=new PI();
            if(shell==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"OpenProcess(desktop query)");
            try {
                var caller=Read(GetCurrentProcess(),Process.GetCurrentProcess().Id); var desktop=Read(shell,shellPid);
                ValidateContext(caller,desktop);
                Check(OpenProcessToken(shell,8|2,out token),"OpenProcessToken(desktop query/duplicate)");
                Check(DuplicateTokenEx(token,8|2|4,IntPtr.Zero,2,1,out duplicate),"DuplicateTokenEx(desktop query/impersonation)");
                var si=new SI {cb=Marshal.SizeOf(typeof(SI)),desktop="winsta0\\default",flags=1,show=0};
                if(stdout!=IntPtr.Zero || stderr!=IntPtr.Zero) { si.flags|=0x100;si.hIn=stdin;si.hOut=stdout;si.hErr=stderr; }
                Deadline(deadline);
                bool same=caller.IntegrityRid==8192 && !caller.Elevated;
                if(same) Check(CreateProcessW(path,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,stdout!=IntPtr.Zero,4|0x08000000,IntPtr.Zero,cwd,ref si,out pi),"Create suspended same-normal-context process");
                else pi=CreateDesktopParent(shell,token,path,command,cwd,si);
                var child=Read(pi.process,pi.pid); ValidateChild(desktop,child,path);
                var rechecked=Read(shell,shellPid); ValidateContext(caller,rechecked);
                if(rechecked.CreatedUtc!=desktop.CreatedUtc || GetWindowThreadProcessId(GetShellWindow(),out shellPid)==0 || shellPid!=desktop.Pid)
                    throw new InvalidOperationException("Desktop shell identity drift before resume");
                // Validate access under the exact normal token, not under the
                // elevated creator. No alteration of the new process DACL.
                Check(ImpersonateLoggedOnUser(duplicate),"Impersonate normal token for read-only access check");
                try {
                    IntPtr observed=OpenProcess(0x40|0x400|0x20000,false,pi.pid);
                    if(observed==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Normal user process access denied before resume");
                    try { if(Read(observed,pi.pid).CreatedUtc!=child.CreatedUtc) throw new InvalidOperationException("Child identity drift during normal-token access check"); }
                    finally { CloseHandle(observed); }
                } finally { Check(RevertToSelf(),"RevertToSelf after normal-token read"); }
                Deadline(deadline);
                return new InteractiveLaunch {ProcessId=pi.pid,ThreadId=pi.tid,ProcessHandle=pi.process,ThreadHandle=pi.thread,
                    Caller=caller,Desktop=desktop,Child=child,NormalUserAccessVerified=true,Method=same?"same-normal-context-CreateProcessW":"desktop-parent-and-normal-token-creation-security"};
            } catch(Exception failure) {
                if(pi.process!=IntPtr.Zero) {
                    failure.Data["normalLaunchPid"]=pi.pid;
                    failure.Data["normalLaunchCleanupVerified"]=CancelSuspended(pi);
                }
                throw;
            } finally { if(duplicate!=IntPtr.Zero) CloseHandle(duplicate);if(token!=IntPtr.Zero) CloseHandle(token);CloseHandle(shell); }
        }
    }
}
