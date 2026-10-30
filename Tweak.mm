#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <unistd.h>
#import <string.h>

static uintptr_t gBase = 0;

static void TLOG(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *p = [dir stringByAppendingPathComponent:@"tweak.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p])
        [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    [fh seekToEndOfFile];
    [fh writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void DumpMethods(Class c, const char *tag) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        uintptr_t imp = (uintptr_t)method_getImplementation(ms[i]);
        TLOG(@"  %s %s off=0x%lx", tag, sel_getName(method_getName(ms[i])),
             (unsigned long)(imp - gBase));
    }
    free(ms);
}

static void DumpClass(const char *cn) {
    Class c = objc_getClass(cn);
    if (!c) return;
    TLOG(@"--- %s ---", cn);
    unsigned n = 0;
    Ivar *iv = class_copyIvarList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        const char *nm = ivar_getName(iv[i]);
        const char *tp = ivar_getTypeEncoding(iv[i]);
        TLOG(@"  ivar %s %s +%td", nm ? nm : "?", tp ? tp : "?", ivar_getOffset(iv[i]));
    }
    free(iv);
    DumpMethods(c, "-");
    DumpMethods(object_getClass(c), "+");
}

static void DumpRegions(const char *why) {
    TLOG(@"=== regiones grandes (%s) ===", why);
    vm_address_t addr = 0;
    while (1) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        if (size >= (64ull << 20))
            TLOG(@"region 0x%lx-0x%lx %lluMB prot=%c%c%c",
                 (unsigned long)addr, (unsigned long)(addr + size),
                 (unsigned long long)(size >> 20),
                 (info.protection & VM_PROT_READ) ? 'r' : '-',
                 (info.protection & VM_PROT_WRITE) ? 'w' : '-',
                 (info.protection & VM_PROT_EXECUTE) ? 'x' : '-');
        addr += size;
    }
}

__attribute__((constructor))
static void init(void) {
    TLOG(@"##### Tweak v2, pid=%d #####", getpid());
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *nm = _dyld_get_image_name(i);
        if (strstr(nm, "/DmIOS")) {
            gBase = (uintptr_t)_dyld_get_image_header(i);
            TLOG(@"juego: base=0x%lx %s", (unsigned long)gBase, nm);
        }
    }
    const char *cls[] = {"DmGameView","DmRootVC","DmGamepad","DmRecTable","DmRecEnc",
                         "DmRecCB","NvArena","NvProg","NvPkg","App","SceneDelegate"};
    for (int i = 0; i < 11; i++) DumpClass(cls[i]);
    DumpRegions("inicio");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
        dispatch_get_global_queue(0, 0), ^{ DumpRegions("60s despues"); });
}
