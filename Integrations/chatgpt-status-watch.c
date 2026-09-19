#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <signal.h>
#include <stdio.h>
#include <dirent.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <limits.h>

#define SIDEBAR_SCAN_MAX 600
#define MAIN_SCAN_MAX 450
#define LOCATE_MAX 180
#define POLL_USEC 1000000

static volatile sig_atomic_t g_stop = 0;
static char g_active[PATH_MAX], g_codex_exec[PATH_MAX], g_active_dir[PATH_MAX], g_done[PATH_MAX], g_pulse[PATH_MAX], g_log[PATH_MAX];

typedef struct {
    int busy;
    int waiting;
    int nodes;
    int truncated;
    int valid;
    char label[256];
} Scan;

static void on_sig(int sig) { (void)sig; g_stop = 1; }

static void touch_file(const char *p) {
    FILE *f = fopen(p, "a");
    if (f) {
        fclose(f);
        struct timeval tv[2];
        gettimeofday(&tv[0], NULL);
        tv[1] = tv[0];
        utimes(p, tv);
    }
}
static void remove_file(const char *p) { unlink(p); }

static int active_dir_empty(void) {
    DIR *d = opendir(g_active_dir);
    if (!d) return 1;
    int empty = 1;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") != 0 && strcmp(ent->d_name, "..") != 0) {
            empty = 0;
            break;
        }
    }
    closedir(d);
    return empty;
}

static void log_line(const char *s) {
    FILE *f = fopen(g_log, "a");
    if (!f) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char ts[32];
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);
    fprintf(f, "%s %s\n", ts, s);
    fclose(f);
}

static pid_t find_chatgpt(void) {
    CFArrayRef wins = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!wins) return 0;
    pid_t pid = 0;
    CFIndex n = CFArrayGetCount(wins);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(wins, i);
        CFStringRef name = CFDictionaryGetValue(d, kCGWindowOwnerName);
        CFNumberRef pn = CFDictionaryGetValue(d, kCGWindowOwnerPID);
        if (name && pn &&
            CFStringCompare(name, CFSTR("ChatGPT"), 0) == kCFCompareEqualTo) {
            int p = 0;
            CFNumberGetValue(pn, kCFNumberIntType, &p);
            pid = (pid_t)p;
            break;
        }
    }
    CFRelease(wins);
    return pid;
}

static int pid_is_codex_exec(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int path_len = proc_pidpath(pid, path, sizeof(path));
    if (path_len <= 0) return 0;

    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (strcmp(base, "codex") != 0 && strncmp(base, "codex-", 6) != 0) return 0;

    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 ||
        size <= sizeof(int) || size > 1024 * 1024) return 0;

    char *buf = calloc(1, size);
    if (!buf) return 0;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) {
        free(buf);
        return 0;
    }

    int argc = 0;
    memcpy(&argc, buf, sizeof(argc));
    if (argc <= 0 || argc > 256) {
        free(buf);
        return 0;
    }

    char *p = buf + sizeof(argc);
    char *end = buf + size;

    /* KERN_PROCARGS2: exec path, padding NULs, then argv[]. */
    while (p < end && *p) p++;
    while (p < end && !*p) p++;

    int found = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t remain = (size_t)(end - p);
        size_t len = strnlen(p, remain);
        if (len == remain) break;
        if (strcmp(p, "exec") == 0) {
            found = 1;
            break;
        }
        p += len + 1;
        while (p < end && !*p) p++;
    }

    free(buf);
    return found;
}

static int any_codex_exec(void) {
    pid_t pids[4096] = {0};
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)sizeof(pids));
    if (bytes <= 0) return 0;
    int count = bytes / (int)sizeof(pid_t);
    for (int i = 0; i < count; i++) {
        if (pids[i] > 1 && pid_is_codex_exec(pids[i])) return 1;
    }
    return 0;
}

static int string_eq(CFStringRef s, CFStringRef target) {
    return s && CFStringCompare(s, target, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
}
static int string_contains(CFStringRef s, CFStringRef needle) {
    if (!s) return 0;
    CFRange r = CFStringFind(s, needle, kCFCompareCaseInsensitive);
    return r.location != kCFNotFound;
}
static int classify(CFStringRef s, int *waiting) {
    if (!s) return 0;

    static CFStringRef waiters[] = {
        CFSTR("等待批准"), CFSTR("正在等待核准"), CFSTR("需要输入"), CFSTR("需要輸入"),
        CFSTR("需要操作"), CFSTR("等待操作"), CFSTR("Needs input"), CFSTR("Awaiting approval"),
        CFSTR("Waiting for approval"), CFSTR("Requires input")
    };
    static CFStringRef running[] = {
        CFSTR("处理中"), CFSTR("正在处理"), CFSTR("正在运行"), CFSTR("运行中"),
        CFSTR("執行中"), CFSTR("工作中"), CFSTR("正在工作"),
        CFSTR("Running"), CFSTR("Working"), CFSTR("Processing")
    };

    for (size_t i = 0; i < sizeof(waiters) / sizeof(waiters[0]); i++) {
        if (string_eq(s, waiters[i])) {
            *waiting = 1;
            return 1;
        }
    }
    for (size_t i = 0; i < sizeof(running) / sizeof(running[0]); i++) {
        if (string_eq(s, running[i])) return 1;
    }

    if (string_contains(s, CFSTR("Stop generating")) ||
        string_contains(s, CFSTR("Stop running task")) ||
        string_contains(s, CFSTR("停止生成")) ||
        string_contains(s, CFSTR("停止正在运行的任务")) ||
        string_contains(s, CFSTR("停止執行中的工作"))) {
        return 1;
    }
    return 0;
}

static void save_label(CFStringRef s, Scan *scan) {
    if (scan->label[0] || !s) return;
    CFStringGetCString(s, scan->label, sizeof(scan->label), kCFStringEncodingUTF8);
}

static int element_visible(AXUIElementRef e) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXSizeAttribute, &v) != kAXErrorSuccess || !v)
        return 1;
    int visible = 1;
    if (CFGetTypeID(v) == AXValueGetTypeID()) {
        CGSize s;
        if (AXValueGetValue((AXValueRef)v, kAXValueCGSizeType, &s))
            visible = (s.width > 40 && s.height > 40);
    }
    CFRelease(v);
    return visible;
}

static void locate_roots(AXUIElementRef e, int depth, int *nodes,
                         AXUIElementRef *web, AXUIElementRef *sidebar) {
    if (!e || depth > 24 || *nodes >= LOCATE_MAX || (*web && *sidebar)) return;
    (*nodes)++;

    CFTypeRef role = NULL;
    if (!*web &&
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute, &role) == kAXErrorSuccess &&
        role && CFGetTypeID(role) == CFStringGetTypeID() &&
        CFStringCompare((CFStringRef)role, CFSTR("AXWebArea"), 0) == kCFCompareEqualTo) {
        *web = (AXUIElementRef)CFRetain(e);
    }
    if (role) CFRelease(role);

    CFTypeRef sub = NULL;
    if (!*sidebar &&
        AXUIElementCopyAttributeValue(e, kAXSubroleAttribute, &sub) == kAXErrorSuccess &&
        sub && CFGetTypeID(sub) == CFStringGetTypeID() &&
        CFStringCompare((CFStringRef)sub, CFSTR("AXLandmarkComplementary"), 0) == kCFCompareEqualTo &&
        element_visible(e)) {
        *sidebar = (AXUIElementRef)CFRetain(e);
    }
    if (sub) CFRelease(sub);

    CFTypeRef cv = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXChildrenAttribute, &cv) == kAXErrorSuccess && cv) {
        if (CFGetTypeID(cv) == CFArrayGetTypeID()) {
            CFArrayRef a = (CFArrayRef)cv;
            CFIndex n = CFArrayGetCount(a);
            for (CFIndex i = 0; i < n && *nodes < LOCATE_MAX && !(*web && *sidebar); i++) {
                CFTypeRef child = CFArrayGetValueAtIndex(a, i);
                if (child && CFGetTypeID(child) == AXUIElementGetTypeID())
                    locate_roots((AXUIElementRef)child, depth + 1, nodes, web, sidebar);
            }
        }
        CFRelease(cv);
    }
}

static void scan_walk(AXUIElementRef e, int depth, Scan *scan, int max_nodes,
                      int reverse, AXUIElementRef skip_subtree) {
    if (!e || scan->busy || depth > 50) return;
    if (skip_subtree && CFEqual(e, skip_subtree)) return;
    if (scan->nodes++ >= max_nodes) {
        scan->truncated = 1;
        return;
    }

    CFTypeRef tv = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXTitleAttribute, &tv) == kAXErrorSuccess && tv) {
        if (CFGetTypeID(tv) == CFStringGetTypeID()) {
            int waiting = 0;
            if (classify((CFStringRef)tv, &waiting)) {
                scan->busy = 1;
                scan->waiting = waiting;
                save_label((CFStringRef)tv, scan);
                CFRelease(tv);
                return;
            }
        }
        CFRelease(tv);
    }

    CFTypeRef cv = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXChildrenAttribute, &cv) == kAXErrorSuccess && cv) {
        if (CFGetTypeID(cv) == CFArrayGetTypeID()) {
            CFArrayRef a = (CFArrayRef)cv;
            CFIndex n = CFArrayGetCount(a);
            if (reverse) {
                for (CFIndex i = n; i > 0 && !scan->busy && !scan->truncated; i--) {
                    CFTypeRef child = CFArrayGetValueAtIndex(a, i - 1);
                    if (child && CFGetTypeID(child) == AXUIElementGetTypeID())
                        scan_walk((AXUIElementRef)child, depth + 1, scan, max_nodes, reverse, skip_subtree);
                }
            } else {
                for (CFIndex i = 0; i < n && !scan->busy && !scan->truncated; i++) {
                    CFTypeRef child = CFArrayGetValueAtIndex(a, i);
                    if (child && CFGetTypeID(child) == AXUIElementGetTypeID())
                        scan_walk((AXUIElementRef)child, depth + 1, scan, max_nodes, reverse, skip_subtree);
                }
            }
        }
        CFRelease(cv);
    }
}

static Scan scan_once(pid_t pid) {
    Scan s = {0};
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return s;

    AXUIElementRef web = NULL, sidebar = NULL;
    int locate_nodes = 0;
    locate_roots(app, 0, &locate_nodes, &web, &sidebar);

    if (sidebar) {
        s.valid = 1;
        scan_walk(sidebar, 0, &s, SIDEBAR_SCAN_MAX, 0, NULL);
    } else if (web) {
        s.valid = 1;
        scan_walk(web, 0, &s, MAIN_SCAN_MAX, 1, NULL);
    }

    if (sidebar) CFRelease(sidebar);
    if (web) CFRelease(web);
    CFRelease(app);
    return s;
}

static double now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

int main(int argc, char **argv) {
    const char *home = getenv("HOME");
    if (!home || !*home) {
        struct passwd *pw = getpwuid(getuid());
        home = (pw && pw->pw_dir) ? pw->pw_dir : NULL;
    }
    if (!home || !*home) {
        fprintf(stderr, "Unable to resolve HOME\n");
        return 2;
    }

    char dir[PATH_MAX], adir[PATH_MAX];
    const char *override = getenv("PHOSIGNAL_STATE_DIR");
    if (override && *override) {
        snprintf(dir, sizeof(dir), "%s", override);
    } else {
        snprintf(dir, sizeof(dir), "%s/Library/Application Support/PhoSignal", home);
    }
    snprintf(adir, sizeof(adir), "%s/active", dir);
    mkdir(dir, 0755);
    mkdir(adir, 0755);
    snprintf(g_active_dir, sizeof(g_active_dir), "%s", adir);
    snprintf(g_active, sizeof(g_active), "%s/chatgpt-ui", adir);
    snprintf(g_codex_exec, sizeof(g_codex_exec), "%s/codex-exec-process", adir);
    snprintf(g_done, sizeof(g_done), "%s/done", dir);
    snprintf(g_pulse, sizeof(g_pulse), "%s/pulse", dir);
    snprintf(g_log, sizeof(g_log), "%s/chatgpt-watch.log", dir);

    int once = (argc > 1 && strcmp(argv[1], "--once") == 0);
    pid_t pid = find_chatgpt();
    int trusted = AXIsProcessTrusted() ? 1 : 0;
    double t0 = now_ms();
    Scan s = {0};
    if (trusted && pid) s = scan_once(pid);
    int codex_exec = any_codex_exec();

    if (once) {
        printf("{\"trusted\":%d,\"pid\":%d,\"valid\":%d,\"busy\":%d,\"waiting\":%d,"
               "\"codex_exec\":%d,\"nodes\":%d,\"truncated\":%d,\"label\":\"%s\",\"ms\":%.1f}\n",
               trusted, pid, s.valid, s.busy, s.waiting, codex_exec, s.nodes, s.truncated,
               s.label, now_ms() - t0);
        return trusted ? 0 : 3;
    }

    signal(SIGTERM, on_sig);
    signal(SIGINT, on_sig);
    signal(SIGHUP, on_sig);

    int prev_busy = 0, prev_waiting = 0, failures = 0, prev_codex_exec = 0, prev_trusted = -1;
    pid_t last_pid = 0;
    log_line("ChatGPT/Codex watcher started");

    while (!g_stop) {
        trusted = AXIsProcessTrusted() ? 1 : 0;
        if (trusted != prev_trusted) {
            log_line(trusted ? "Accessibility permission available" : "Accessibility permission missing");
            prev_trusted = trusted;
        }
        pid = find_chatgpt();
        Scan cur = {0};

        if (trusted && pid) {
            cur = scan_once(pid);
            if (cur.valid) failures = 0;
            else failures++;
        } else {
            failures++;
        }

        if (pid != last_pid) {
            last_pid = pid;
            if (pid) log_line("ChatGPT process detected");
            else log_line("ChatGPT process absent");
        }

        codex_exec = any_codex_exec();
        if (codex_exec) {
            touch_file(g_codex_exec);
            if (!prev_codex_exec) log_line("Codex exec process active (hook fallback)");
        } else {
            if (prev_codex_exec) {
                remove_file(g_codex_exec);
                if (active_dir_empty()) touch_file(g_done);
                log_line("Codex exec process ended");
            } else {
                remove_file(g_codex_exec);
            }
        }
        prev_codex_exec = codex_exec;

        if (cur.valid && cur.busy) {
            touch_file(g_active);
            if (cur.waiting && !prev_waiting) {
                touch_file(g_pulse);
                log_line("ChatGPT needs input/approval");
            }
            if (!prev_busy) {
                char msg[384];
                snprintf(msg, sizeof(msg), "ChatGPT working (%s)",
                         cur.label[0] ? cur.label : "status");
                log_line(msg);
            }
            prev_busy = 1;
            prev_waiting = cur.waiting;
        } else if (cur.valid && !cur.busy) {
            if (prev_busy) {
                remove_file(g_active);
                if (active_dir_empty()) touch_file(g_done);
                log_line("ChatGPT idle");
            } else {
                remove_file(g_active);
            }
            prev_busy = 0;
            prev_waiting = 0;
        } else if (failures >= 4) {
            if (prev_busy) log_line("ChatGPT status unavailable; clearing stale UI activity");
            remove_file(g_active);
            prev_busy = 0;
            prev_waiting = 0;
        }

        usleep(POLL_USEC);
    }

    remove_file(g_active);
    remove_file(g_codex_exec);
    log_line("ChatGPT/Codex watcher stopped");
    return 0;
}
