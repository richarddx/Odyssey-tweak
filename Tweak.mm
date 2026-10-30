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
            else {
                if (q < bs) ScanRange(q, bs - q, ref);
                if (qe > be) ScanRange(be, qe - be, ref);
            }
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
        uintptr_t a = gC[i].a;
        uint32_t cur = 0;
        RD(a, &cur, 4);
        TLOG(@"0x%lx  base%c0x%lx  int=%d float=%f", (unsigned long)a,
             a >= gBase ? '+' : '-',
             (unsigned long)(a >= gBase ? a - gBase : gBase - a),
             (int)cur, FloatOf(cur));
    }
}

static void WriteAll(uint32_t ref) {
    if (gC.size() > 32) {
        TLOG(@"Escribir: hay %zu candidatos, filtra a 32 o menos", gC.size());
        return;
    }
    for (auto &c : gC) {
        uint32_t w = ref;
        vm_write(mach_task_self(), (vm_address_t)c.a, (vm_offset_t)&w, 4);
        c.v = w ^ KEY;
    }
    TLOG(@"Escrito 0x%x en %zu direcciones", ref, gC.size());
}

static UIView *gPanel;
static UILabel *gLbl;
static UITextField *gTf;
static UISegmentedControl *gSeg;

static void Act(int t) {
    if (gBusy) return;
    gFloat = (gSeg.selectedSegmentIndex == 1);
    const char *s = gTf.text.UTF8String;
    if (!s) s = "0";
    uint32_t ref = gFloat ? BitsOf(strtof(s, NULL)) : (uint32_t)(int32_t)strtol(s, NULL, 10);
    [gTf resignFirstResponder];
    gBusy = true;
    gLbl.text = @"Trabajando...";
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        switch (t) {
            case 0: ScanNew(ref); break;
            case 1: FilterBy(OpChanged, ref); break;
            case 2: FilterBy(OpSame, ref); break;
            case 3: FilterBy(OpUp, ref); break;
            case 4: FilterBy(OpDown, ref); break;
            case 5: FilterBy(OpEq, ref); break;
            case 6: WriteAll(ref); break;
            default: break;
        }
        ShowResults();
        dispatch_async(dispatch_get_main_queue(), ^{
            gLbl.text = [NSString stringWithFormat:@"%zu candidatos", gC.size()];
            gBusy = false;
        });
    });
}

static UIButton *MakeBtn(NSString *title, int tag, CGFloat x, CGFloat y) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, 96, 34);
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    b.layer.cornerRadius = 8;
    UIAction *act = [UIAction actionWithHandler:^(UIAction *a) { Act(tag); }];
    [b addAction:act forControlEvents:UIControlEventTouchUpInside];
    return b;
}

@interface TwkDrag : NSObject
@end
@implementation TwkDrag
+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static void BuildUI(UIWindow *w) {
    gPanel = [[UIView alloc] initWithFrame:CGRectMake(8, 90, 324, 214)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    gPanel.layer.cornerRadius = 12;
    [gPanel addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:[TwkDrag class] action:@selector(pan:)]];

    gTf = [[UITextField alloc] initWithFrame:CGRectMake(8, 8, 130, 34)];
    gTf.borderStyle = UITextBorderStyleRoundedRect;
    gTf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    gTf.placeholder = @"valor";

    gSeg = [[UISegmentedControl alloc] initWithItems:@[@"Int32", @"Float"]];
    gSeg.frame = CGRectMake(146, 8, 170, 34);
    gSeg.selectedSegmentIndex = 0;

    gLbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 48, 308, 24)];
    gLbl.textColor = [UIColor whiteColor];
    gLbl.font = [UIFont systemFontOfSize:14];
    gLbl.text = @"listo";

    [gPanel addSubview:gTf];
    [gPanel addSubview:gSeg];
    [gPanel addSubview:gLbl];
    [gPanel addSubview:MakeBtn(@"Nuevo", 0, 8, 80)];
    [gPanel addSubview:MakeBtn(@"= Valor", 5, 114, 80)];
    [gPanel addSubview:MakeBtn(@"Log", 7, 220, 80)];
    [gPanel addSubview:MakeBtn(@"Cambio", 1, 8, 122)];
    [gPanel addSubview:MakeBtn(@"Igual", 2, 114, 122)];
    [gPanel addSubview:MakeBtn(@"Escribir", 6, 220, 122)];
    [gPanel addSubview:MakeBtn(@"Subio", 3, 8, 164)];
    [gPanel addSubview:MakeBtn(@"Bajo", 4, 114, 164)];
    [w addSubview:gPanel];

    UIButton *tog = [UIButton buttonWithType:UIButtonTypeSystem];
    tog.frame = CGRectMake(8, 52, 40, 30);
    [tog setTitle:@"=" forState:UIControlStateNormal];
    tog.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    tog.layer.cornerRadius = 8;
    [tog addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:[TwkDrag class] action:@selector(pan:)]];
    UIAction *ta = [UIAction actionWithHandler:^(UIAction *a) { gPanel.hidden = !gPanel.hidden; }];
    [tog addAction:ta forControlEvents:UIControlEventTouchUpInside];
    [w addSubview:tog];
}

static void Install(void) {
    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win) win = ws.windows.firstObject;
        if (win) break;
    }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ Install(); });
        return;
    }
    BuildUI(win);
    TLOG(@"UI instalada");
}

__attribute__((constructor))
static void init(void) {
    TLOG(@"##### Tweak v3 scanner, pid=%d #####", getpid());
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strstr(_dyld_get_image_name(i), "/DmIOS"))
            gBase = (uintptr_t)_dyld_get_image_header(i);
    }
    TLOG(@"base juego=0x%lx", (unsigned long)gBase);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ Install(); });
}
