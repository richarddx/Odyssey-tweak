#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <unistd.h>
#import <string.h>
#import <math.h>
#import <vector>

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

#define KEY 0xA5C3E1F7u
#define BUFSZ (4u << 20)
#define MAXC 6000000u
struct Cand { uintptr_t a; uint32_t v; };
static std::vector<Cand> gC;
static uint8_t *gBuf = NULL;
static bool gFloat = false, gBusy = false;
enum Op { OpEq, OpChanged, OpSame, OpUp, OpDown };

static float FloatOf(uint32_t x) { float f; memcpy(&f, &x, 4); return f; }
static uint32_t BitsOf(float f) { uint32_t x; memcpy(&x, &f, 4); return x; }

static bool RD(uintptr_t a, void *o, size_t n) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)o, &got) == KERN_SUCCESS && got == n;
}

static bool Match(uint32_t cur, uint32_t ref) {
    return gFloat ? fabsf(FloatOf(cur) - FloatOf(ref)) < 0.01f : cur == ref;
}

static void ScanRange(uintptr_t p, size_t n, uint32_t ref) {
    if (!RD(p, gBuf, n)) return;
    const uint32_t *w = (const uint32_t *)gBuf;
    for (size_t i = 0; i < n / 4 && gC.size() < MAXC; i++)
        if (Match(w[i], ref)) gC.push_back({p + i * 4, w[i] ^ KEY});
}

static void ScanNew(uint32_t ref) {
    gC.clear(); gC.shrink_to_fit();
    if (!gBuf) gBuf = (uint8_t *)malloc(BUFSZ);
    uintptr_t bs = (uintptr_t)gBuf, be = bs + BUFSZ;
    vm_address_t addr = 0;
    while (gC.size() < MAXC) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        uintptr_t start = addr, end = addr + size;
        addr += size;
        if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) continue;
        for (uintptr_t p = start; p < end; p += BUFSZ) {
            size_t n = (end - p < BUFSZ) ? (end - p) : BUFSZ;
            uintptr_t q = p, qe = p + n;
            if (qe <= bs || q >= be) ScanRange(q, qe - q, ref);
            else { if (q < bs) ScanRange(q, bs - q, ref); if (qe > be) ScanRange(be, qe - be, ref); }
        }
    }
}

static void FilterBy(Op op, uint32_t ref) {
    std::vector<Cand> out;
    for (auto &c : gC) {
        uint32_t cur, old = c.v ^ KEY;
        if (!RD(c.a, &cur, 4)) continue;
        bool ok = false;
        if (gFloat) {
            float x = FloatOf(cur), o = FloatOf(old);
            switch (op) {
                case OpEq: ok = fabsf(x - FloatOf(ref)) < 0.01f; break;
                case OpChanged: ok = fabsf(x - o) > 0.0001f; break;
                case OpSame: ok = fabsf(x - o) <= 0.0001f; break;
                case OpUp: ok = x > o + 0.0001f; break;
                case OpDown: ok = x < o - 0.0001f; break;
            }
        } else {
            int32_t x = (int32_t)cur, o = (int32_t)old;
            switch (op) {
                case OpEq: ok = (cur == ref); break;
                case OpChanged: ok = x != o; break;
                case OpSame: ok = x == o; break;
                case OpUp: ok = x > o; break;
                case OpDown: ok = x < o; break;
            }
        }
        if (ok) { c.v = cur ^ KEY; out.push_back(c); }
    }
    gC.swap(out);
}

static void ShowResults(void) {
    TLOG(@"--- %zu candidatos ---", gC.size());
    for (size_t i = 0; i < gC.size() && i < 40; i++) {
        uintptr_t a = gC[i].a; uint32_t cur = 0; RD(a, &cur, 4);
        TLOG(@"0x%lx  base%c0x%lx  int=%d float=%f", (unsigned long)a,
             a >= gBase ? '+' : '-', (unsigned long)(a >= gBase ? a - gBase : gBase - a),
             (int)cur, FloatOf(cur));
    }
}

static void WriteAll(uint32_t ref) {
    if (gC.size() > 32) { TLOG(@"Escribir: hay %zu candidatos, filtra a 32 o menos", gC.size()); return; }
    for (auto &c : gC) {
        uint32_t w = ref;
        vm_write(mach_task_self(), (vm_address_t)c.a, (vm_offset_t)&w, 4);
        c.v = w ^ KEY;
    }
    TLOG(@"Escrito 0x%x en %zu direcciones", ref, gC.size());
}

@interface TwkUI : NSObject
@property (strong) UIView *panel;
