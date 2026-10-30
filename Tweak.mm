#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>

static void TLOG(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[Tweak] %@", s);
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *p = [dir stringByAppendingPathComponent:@"tweak.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p])
        [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    [fh seekToEndOfFile];
    [fh writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void Recon(void) {
    uint32_t n = _dyld_image_count();
    TLOG(@"=== %u imagenes cargadas ===", n);
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "/System/") || strstr(name, "/usr/lib/")) continue;
        TLOG(@"[%u] base=0x%lx slide=0x%lx %s", i,
             (unsigned long)_dyld_get_image_header(i),
             (unsigned long)_dyld_get_image_vmaddr_slide(i), name);
        unsigned c = 0;
        const char **cls = objc_copyClassNamesForImage(name, &c);
        if (c) TLOG(@"    %u clases ObjC", c);
        for (unsigned k = 0; k < c && k < 80; k++) TLOG(@"    class: %s", cls[k]);
        free(cls);
    }
}

__attribute__((constructor))
static void init(void) {
    TLOG(@"##### Tweak cargado, pid=%d #####", getpid());
    Recon();
}
