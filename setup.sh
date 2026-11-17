#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
TC="$ROOT/.tc"
mkdir -p "$TC"

echo "===== 1/5 INSTALL ====="
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  clang lld llvm git dpkg curl xz-utils unzip binutils
sudo ldconfig

LDP=""
for v in 14 15 16 13 12 11; do
  if [ -x "/usr/lib/llvm-$v/bin/ld64.lld" ]; then LDP="/usr/lib/llvm-$v/bin/ld64.lld"; break; fi
done
[ -z "$LDP" ] && [ -x /usr/bin/ld64.lld ] && LDP=/usr/bin/ld64.lld
if [ -z "$LDP" ]; then echo "NO LD64"; exit 1; fi
echo "$LDP" > "$TC/ld64_path.txt"
sudo ln -sf "$LDP" /usr/local/bin/ld64.lld

if [ ! -d "$TC/theos/sdks/iPhoneOS16.5.sdk" ]; then
  mkdir -p "$TC/theos/sdks"
  rm -rf /tmp/sdks
  git clone --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks
  cd /tmp/sdks && git sparse-checkout set iPhoneOS16.5.sdk
  mv iPhoneOS16.5.sdk "$TC/theos/sdks/"
  cd "$ROOT"
fi

export THEOS="$TC/theos"
export PATH="/usr/local/bin:$PATH"
export AR=ar

echo "===== 2/5 TREES ====="
rm -rf src dist
mkdir -p src/kcore src/game src/tweak src/package/DEBIAN dist

cat > src/kcore/krw.h <<'KRWH'
#pragma once
#include <stdint.h>
#include <stddef.h>

extern uint64_t g_kbase;
extern uint64_t g_gnames;
extern int g_kfd_ready;
extern int g_off_teamid;
extern int g_ps_n;

typedef struct { float x, y, z; } RVec3;

int row_up(void);
int kcd_jb_ready(void);
int kcd_jb_nsym(void);
int kcd_jb_xpc(void);

uint64_t r64(uint64_t a);
uint32_t r32(uint64_t a);
float    rf32(uint64_t a);
int      kread_buf(uint64_t a, void *b, size_t n);
uint64_t kread_ptr(uint64_t a);

uint64_t row_task_of_pid(int pid);
int      row_pid_by_name(const char *key);
uint64_t row_base_of_task(uint64_t task);
int      row_read_task(uint64_t task, uint64_t va, void *buf, size_t n);
int      kcd_block_read(uint64_t proc, uint64_t va, void *buf, size_t n);

int kcd_gnames_scan(void);
int kcd_fname(uint64_t pool, int32_t idx, char *out, int max);
int kcd_fname_str(uint64_t objaddr, char *out, int max);
int kcd_class_name(uint64_t obj, char *out, int max);

int   kcd_is_bot(uint64_t pawn);
int   kcd_team_of(uint64_t pawn);
int   kcd_yaw_of(uint64_t pawn);
float kcd_health_of(uint64_t pawn);
int   kcd_calib_teamid(void);
int   kcd_reflect_teamid(void);
KRWH

echo "===== 3/5 KRW.C ====="
cat > src/kcore/krw.c <<'KRW'
#include "krw.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <dlfcn.h>
#include <dirent.h>
#include <unistd.h>

#define OFF_PAWN_PS     0x2B0
#define OFF_PAWN_CTRL   0x2A8
#define OFF_CTRL_ROT    0x2E4
#define OFF_OBJ_CLASS   0x10
#define OFF_OBJ_NAME    0x18
#define OFF_USTRUCT_CHL 0x48
#define OFF_UPROP_OFF   0x4C
#define OFF_UFIELD_NEXT 0x28

uint64_t g_kbase = 0;
uint64_t g_gnames = 0;
int g_kfd_ready = 0;
int g_off_teamid = 0x2C0;
uint64_t g_ps_sample[32];
int g_ps_n = 0;

static int g_jb_nsym = 0;
static int g_jb_xpc  = 0;

static void *g_jb = NULL;
static uint64_t (*p_proc_find)(int) = NULL;
static uint64_t (*p_proc_find_by_pid)(int) = NULL;
static int      (*p_proc_vreadbuf)(uint64_t, const void *, void *, size_t) = NULL;
static uint64_t (*p_kread64)(uint64_t) = NULL;
static int      (*p_kreadbuf)(uint64_t, void *, size_t) = NULL;
static int      (*p_jbclient_xpc_setup)(void) = NULL;

static void *g_krw = NULL;
static int      (*p_krw_init)(void *) = NULL;
static int      (*p_krw_kread)(uint64_t, void *, size_t) = NULL;
static uint64_t (*p_krw_kbase)(void) = NULL;

static uint64_t g_proc = 0;
static int g_loaded = 0;
static char g_rootfs[256] = "/var/jb";

extern int proc_listpids(unsigned int, unsigned int, void *, int);
extern int proc_pidpath(int, void *, unsigned int);

static int kptr(uint64_t p) { return p > 0x100000000ULL && p < 0x3000000000ULL; }

static void detect_rootfs(void) {
    if (access("/var/jb/usr/lib/libjailbreak.dylib", F_OK) == 0) {
        strcpy(g_rootfs, "/var/jb");
        fprintf(stderr, "[kcd] rootfs=/var/jb\n");
        return;
    }
    void *lr = dlopen("/var/jb/usr/lib/libroot.dylib", RTLD_LAZY);
    if (!lr) lr = dlopen("/usr/lib/libroot.dylib", RTLD_LAZY);
    if (!lr) lr = dlopen("libroot.dylib", RTLD_LAZY);
    if (lr) {
        const char *(*rp)(void) = (const char *(*)(void))dlsym(lr, "rootfs_prefix");
        if (!rp) rp = (const char *(*)(void))dlsym(lr, "jbroot");
        if (rp) {
            const char *p = rp();
            if (p && p[0] == '/') {
                strncpy(g_rootfs, p, sizeof(g_rootfs) - 1);
                fprintf(stderr, "[kcd] rootfs=%s (libroot)\n", g_rootfs);
                return;
            }
        }
    }
    DIR *d = opendir("/var/containers/Bundle/Application");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (strncmp(e->d_name, ".jbroot-", 8) != 0) continue;
            char t[600];
            snprintf(t, sizeof(t),
                     "/var/containers/Bundle/Application/%s/usr/lib/libjailbreak.dylib",
                     e->d_name);
            if (access(t, F_OK) == 0) {
                snprintf(g_rootfs, sizeof(g_rootfs),
                         "/var/containers/Bundle/Application/%s", e->d_name);
                fprintf(stderr, "[kcd] rootfs=%s (jbroot)\n", g_rootfs);
                break;
            }
        }
        closedir(d);
    }
    fprintf(stderr, "[kcd] rootfs=%s\n", g_rootfs);
}

static int jb_load(void) {
    if (g_loaded) return (g_jb && p_proc_vreadbuf) ? 0 : -1;
    g_loaded = 1;

    detect_rootfs();

    char p1[512], p2[512], p3[512], p4[512];
    snprintf(p1, sizeof(p1), "%s/usr/lib/libjailbreak.dylib", g_rootfs);
    snprintf(p2, sizeof(p2), "%s/basebin/libjailbreak.dylib", g_rootfs);
    snprintf(p3, sizeof(p3), "%s/usr/local/lib/libjailbreak.dylib", g_rootfs);
    snprintf(p4, sizeof(p4), "%s/usr/lib/libjailbreak/libjailbreak.dylib", g_rootfs);

    const char *paths[] = {
        p1, p2, p3, p4,
        "/var/jb/usr/lib/libjailbreak.dylib",
        "/usr/lib/libjailbreak.dylib",
        "/var/jb/basebin/libjailbreak.dylib",
        NULL
    };
    for (int i = 0; paths[i] && !g_jb; i++) {
        g_jb = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (g_jb) fprintf(stderr, "[kcd] JB lib = %s\n", paths[i]);
    }
    if (!g_jb) {
        fprintf(stderr, "[kcd] JB lib NOT FOUND\n");
        return -1;
    }

    p_jbclient_xpc_setup = dlsym(g_jb, "jbclient_xpc_setup");
    if (!p_jbclient_xpc_setup) p_jbclient_xpc_setup = dlsym(g_jb, "jbclient_xpc_init");
    if (!p_jbclient_xpc_setup) p_jbclient_xpc_setup = dlsym(g_jb, "jbclient_init");
    if (p_jbclient_xpc_setup) {
        int r = p_jbclient_xpc_setup();
        g_jb_xpc = (r == 0) ? 1 : 0;
        fprintf(stderr, "[kcd] JB xpc_setup = %d\n", r);
    } else {
        g_jb_xpc = -1;
        fprintf(stderr, "[kcd] JB xpc_setup NOT FOUND\n");
    }

    static const char *pf_names[] = {
        "proc_find", "proc_find_by_pid", "jbd_proc_find",
        "proc_for_pid", "proc_find_by_pid_fast", NULL
    };
    for (int i = 0; pf_names[i]; i++) {
        if (p_proc_find) break;
        p_proc_find = dlsym(g_jb, pf_names[i]);
        if (p_proc_find) fprintf(stderr, "[kcd] proc_find <- %s\n", pf_names[i]);
    }
    p_proc_find_by_pid = dlsym(g_jb, "proc_find_by_pid");
    p_proc_vreadbuf    = dlsym(g_jb, "proc_vreadbuf");
    p_kread64          = dlsym(g_jb, "kread64");
    p_kreadbuf         = dlsym(g_jb, "kreadbuf");

    g_jb_nsym = 0;
    if (p_proc_find) g_jb_nsym++;
    if (p_proc_find_by_pid) g_jb_nsym++;
    if (p_proc_vreadbuf) g_jb_nsym++;
    if (p_kread64) g_jb_nsym++;
    if (p_kreadbuf) g_jb_nsym++;

    fprintf(stderr, "[kcd] JB syms=%d pv=%p k64=%p kb=%p pf=%p pfpid=%p\n",
            g_jb_nsym, p_proc_vreadbuf, p_kread64, p_kreadbuf,
            p_proc_find, p_proc_find_by_pid);

    return (p_proc_vreadbuf && (p_proc_find || p_proc_find_by_pid)) ? 0 : -1;
}

static int krw_load(void) {
    if (g_krw) return 0;
    char p1[512];
    snprintf(p1, sizeof(p1), "%s/usr/lib/libkrw.dylib", g_rootfs);
    const char *paths[] = {
        p1,
        "/var/jb/usr/lib/libkrw.dylib",
        "/usr/lib/libkrw.dylib",
        NULL
    };
    for (int i = 0; paths[i] && !g_krw; i++) {
        g_krw = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (g_krw) fprintf(stderr, "[kcd] KRW lib = %s\n", paths[i]);
    }
    if (!g_krw) {
        fprintf(stderr, "[kcd] KRW lib NOT FOUND\n");
        return -1;
    }
    p_krw_init  = dlsym(g_krw, "krw_init");
    p_krw_kread = dlsym(g_krw, "krw_kread");
    p_krw_kbase = dlsym(g_krw, "krw_kbase");

    void *t = NULL;
    if (p_krw_init) fprintf(stderr, "[kcd] krw_init = %d\n", p_krw_init(&t));
    if (p_krw_kbase) {
        g_kbase = p_krw_kbase();
        fprintf(stderr, "[kcd] KRW kbase = %llx\n", (unsigned long long)g_kbase);
    }
    return p_krw_kread ? 0 : -1;
}

int row_up(void) {
    if (jb_load() != 0) {
        fprintf(stderr, "[kcd] JB load FAIL\n");
        return -1;
    }
    krw_load();
    g_kfd_ready = 1;
    fprintf(stderr, "[kcd] READY branch=libjailbreak\n");
    return 0;
}

int kcd_jb_ready(void) { return g_jb ? 1 : 0; }
int kcd_jb_nsym(void)  { return g_jb_nsym; }
int kcd_jb_xpc(void)   { return g_jb_xpc; }

int row_read_task(uint64_t proc, uint64_t va, void *buf, size_t n) {
    if (!p_proc_vreadbuf || !proc) return -1;
    return p_proc_vreadbuf(proc, (const void *)va, buf, n);
}

uint64_t r64(uint64_t a) {
    uint64_t v = 0;
    if (g_proc) { row_read_task(g_proc, a, &v, 8); return v; }
    if (p_kread64) return p_kread64(a);
    if (p_kreadbuf) { p_kreadbuf(a, &v, 8); return v; }
    return 0;
}

uint32_t r32(uint64_t a) {
    uint32_t v = 0;
    if (g_proc) { row_read_task(g_proc, a, &v, 4); return v; }
    if (p_kreadbuf) { p_kreadbuf(a, &v, 4); return v; }
    return 0;
}

float rf32(uint64_t a) {
    float v = 0;
    if (g_proc) { row_read_task(g_proc, a, &v, 4); return v; }
    if (p_kreadbuf) { p_kreadbuf(a, &v, 4); return v; }
    return 0;
}

uint64_t kread_ptr(uint64_t a) {
    uint64_t v = r64(a);
    return v & 0x0000FFFFFFFFFFFFULL;
}

int kread_buf(uint64_t a, void *b, size_t n) {
    if (p_kreadbuf) return p_kreadbuf(a, b, n);
    if (p_krw_kread) return p_krw_kread(a, b, n);
    return -1;
}

int kcd_block_read(uint64_t proc, uint64_t va, void *buf, size_t n) {
    if (row_read_task(proc, va, buf, n) == 0) return 0;
    uint8_t *p = (uint8_t *)buf;
    for (size_t off = 0; off < n; off += 0x1000) {
        size_t sz = n - off;
        if (sz > 0x1000) sz = 0x1000;
        if (row_read_task(proc, va + off, p + off, sz) != 0) {
            for (size_t k = 0; k < sz; k += 8) {
                size_t s2 = sz - k;
                if (s2 > 8) s2 = 8;
                if (row_read_task(proc, va + off + k, p + off + k, s2) != 0)
                    memset(p + off + k, 0, s2);
            }
        }
    }
    return 0;
}

uint64_t row_task_of_pid(int pid) {
    if (jb_load() != 0) return 0;
    uint64_t p = 0;
    if (p_proc_find_by_pid) p = p_proc_find_by_pid(pid);
    if (!p && p_proc_find)  p = p_proc_find(pid);
    if (p) g_proc = p;
    return p;
}

int row_pid_by_name(const char *key) {
    static const char *keys[] = {
        "DeltaForce", "deltaforce", "DeltaForceM",
        "Delta", "delta", "DFM", "dfm", "tmgp", "Tmgp", NULL
    };
    int cap = 8192;
    pid_t *l = (pid_t *)malloc(sizeof(pid_t) * (size_t)cap);
    if (!l) return -1;
    int n = proc_listpids(1, 0, l, sizeof(pid_t) * cap) / (int)sizeof(pid_t);
    int by_name = -1;
    int cand[128];
    int nc = 0;
    char path[1024];
    for (int i = 0; i < n; i++) {
        if (l[i] <= 0) continue;
        memset(path, 0, sizeof(path));
        if (proc_pidpath(l[i], path, sizeof(path) - 1) <= 0) continue;
        if (strstr(path, "/System/")) continue;
        if (strstr(path, "SpringBoard")) continue;
        if (strstr(path, "backboardd")) continue;
        if (!strstr(path, "/Bundle/Application/")) continue;
        if (strstr(path, key)) { by_name = l[i]; break; }
        for (int k = 0; keys[k]; k++)
            if (strstr(path, keys[k])) { by_name = l[i]; break; }
        if (by_name > 0) break;
        if (nc < 128) cand[nc++] = l[i];
    }
    free(l);
    if (by_name > 0) return by_name;
    if (nc == 0) return -1;
    if (nc == 1) return cand[0];
    static int rr = 0;
    int pick = cand[rr % nc];
    rr++;
    return pick;
}

uint64_t row_base_of_task(uint64_t proc) {
    if (!proc) return 0;
    uint64_t ranges[3][2] = {
        { 0x0000000100000000ULL, 0x0000000200000000ULL },
        { 0x0000000200000000ULL, 0x0000000300000000ULL },
        { 0x0000000F00000000ULL, 0x0000000F80000000ULL }
    };
    for (int r = 0; r < 3; r++) {
        for (uint64_t va = ranges[r][0]; va < ranges[r][1]; va += 0x1000000ULL) {
            uint32_t m = 0;
            if (row_read_task(proc, va, &m, 4) != 0) continue;
            if (m == 0xFEEDFACF || m == 0xFEEDFACE) return va;
        }
    }
    return 0;
}

int kcd_fname(uint64_t pool, int32_t idx, char *out, int max) {
    if (!pool || max < 4) return 0;
    int blk = idx >> 16, off = idx & 0xFFFF;
    if (blk < 0 || off < 0) return 0;
    uint64_t bs = r64(pool + 0x10);
    if (!kptr(bs)) return 0;
    uint64_t b = r64(bs + (uint64_t)blk * 8);
    if (!kptr(b)) return 0;
    uint64_t e = b + (uint64_t)off * 2;
    uint16_t h = (uint16_t)(r32(e) & 0xFFFF);
    int len = (h >> 6) & 0x3FF;
    if (len <= 0 || len >= max || len > 200) return 0;
    if (h & 1) {
        for (int i = 0; i < len; i++) out[i] = (char)(r32(e + 2 + (uint64_t)i * 2) & 0xFF);
    } else {
        for (int i = 0; i < len; i++) out[i] = (char)(r32(e + 2 + (uint64_t)i) & 0xFF);
    }
    out[len] = 0;
    return len;
}

int kcd_fname_str(uint64_t obj, char *out, int max) {
    if (!obj || !g_gnames) return 0;
    return kcd_fname(g_gnames, (int32_t)r32(obj + OFF_OBJ_NAME), out, max);
}

int kcd_class_name(uint64_t obj, char *out, int max) {
    if (!obj || !g_gnames) return 0;
    uint64_t cls = kread_ptr(obj + OFF_OBJ_CLASS);
    if (!kptr(cls)) return 0;
    return kcd_fname(g_gnames, (int32_t)r32(cls + OFF_OBJ_NAME), out, max);
}

int kcd_gnames_scan(void) {
    if (g_gnames) return 0;
    uint64_t proc = g_proc;
    if (!proc) return -1;
    uint64_t kb = row_base_of_task(proc);
    if (!kb) return -1;

    const size_t BLK = 0x20000;
    uint8_t *buf = (uint8_t *)malloc(BLK);
    if (!buf) return -1;

    char tmp[64];
    uint64_t ranges[3][2] = {
        { kb + 0x04000000ULL, kb + 0x20000000ULL },
        { kb + 0x20000000ULL, kb + 0x60000000ULL },
        { kb + 0x60000000ULL, kb + 0xA0000000ULL }
    };

    for (int r = 0; r < 3 && !g_gnames; r++) {
        for (uint64_t a = ranges[r][0]; a < ranges[r][1]; a += BLK) {
            if (kcd_block_read(proc, a, buf, BLK) != 0) continue;
            for (size_t i = 0; i + 0x18 <= BLK; i += 8) {
                uint64_t bs;
                memcpy(&bs, buf + i + 0x10, 8);
                if (!kptr(bs)) continue;
                uint64_t b0 = 0;
                if (row_read_task(proc, bs, &b0, 8) != 0) continue;
                if (!kptr(b0)) continue;
                uint16_t h = (uint16_t)(r32(b0) & 0xFFFF);
                int len = (h >> 6) & 0x3FF;
                if (len < 2 || len > 16) continue;
                uint64_t cand = a + i;
                if (kcd_fname(cand, 0, tmp, 60) > 0 && strcmp(tmp, "None") == 0) {
                    g_gnames = cand;
                    fprintf(stderr, "[kcd] GNames = %llx\n", (unsigned long long)cand);
                    break;
                }
            }
            if (g_gnames) break;
        }
    }
    free(buf);
    if (!g_gnames) fprintf(stderr, "[kcd] GNames NOT FOUND\n");
    return g_gnames ? 0 : -1;
}

int kcd_is_bot(uint64_t pawn) {
    if (!pawn) return 1;
    char buf[80] = {0};
    uint64_t c = kread_ptr(pawn + OFF_PAWN_CTRL);
    if (kptr(c) && kcd_class_name(c, buf, 72) > 0) {
        if (strstr(buf, "AIController")) return 1;
        if (strstr(buf, "AI_")) return 1;
    }
    memset(buf, 0, sizeof(buf));
    if (kcd_class_name(pawn, buf, 72) > 0) {
        if (strstr(buf, "_AI_")) return 1;
        if (strstr(buf, "Bot")) return 1;
    }
    return 0;
}

int kcd_team_of(uint64_t pawn) {
    if (!pawn) return -1;
    uint64_t ps = kread_ptr(pawn + OFF_PAWN_PS);
    if (!kptr(ps)) return -1;
    if (g_ps_n < 32) {
        int d = 0;
        for (int i = 0; i < g_ps_n; i++) if (g_ps_sample[i] == ps) { d = 1; break; }
        if (!d) g_ps_sample[g_ps_n++] = ps;
    }
    int t = (int)r32(ps + g_off_teamid);
    if (t < 0 || t > 64) return -1;
    return t;
}

int kcd_yaw_of(uint64_t pawn) {
    if (!pawn) return -1;
    uint64_t c = kread_ptr(pawn + OFF_PAWN_CTRL);
    if (!kptr(c)) return -1;
    float y = rf32(c + OFF_CTRL_ROT);
    if (!(y > -360.0f && y < 360.0f)) return -1;
    int d = (int)y;
    if (d < 0) d += 360;
    return d;
}

float kcd_health_of(uint64_t pawn) {
    if (!pawn) return -1.0f;
    uint64_t ps = kread_ptr(pawn + OFF_PAWN_PS);
    uint64_t cd[8] = {
        pawn + 0x3A0, pawn + 0x2F0, ps + 0x2F0, ps + 0x3A0,
        pawn + 0x4A0, ps + 0x4A0, pawn + 0x5A0, ps + 0x5A0
    };
    for (int i = 0; i < 8; i++) {
        if (!kptr(cd[i])) continue;
        float v = rf32(cd[i]);
        if (v > 0.0f && v <= 1000.0f) return v;
    }
    return -1.0f;
}

int kcd_calib_teamid(void) {
    if (g_ps_n < 3) return -1;
    int best = -1, bs = -99999;
    for (int off = 0x280; off <= 0x340; off += 4) {
        int vals[32], n = 0, ok = 1, mx = 0, z = 0;
        for (int i = 0; i < g_ps_n; i++) {
            int v = (int)r32(g_ps_sample[i] + off);
            if (v < 0 || v > 64) { ok = 0; break; }
            vals[n++] = v;
            if (v > mx) mx = v;
            if (v == 0) z++;
        }
        if (!ok) continue;
        int dis = 0;
        for (int i = 0; i < n; i++) {
            int d = 0;
            for (int j = 0; j < i; j++) if (vals[j] == vals[i]) { d = 1; break; }
            if (!d) dis++;
        }
        int sc = 0;
        if (dis >= 2 && dis <= 12) sc += 120;
        if (dis <= 1) sc -= 250;
        if (z == n) sc -= 400;
        if (z > n / 2) sc -= 60;
        if (mx <= 20) sc += 25;
        if (sc > bs) { bs = sc; best = off; }
    }
    return best;
}

int kcd_reflect_teamid(void) {
    if (!g_gnames || g_ps_n < 1) return -1;
    uint64_t cls = kread_ptr(g_ps_sample[0] + OFF_OBJ_CLASS);
    if (!kptr(cls)) return -1;
    uint64_t p = kread_ptr(cls + OFF_USTRUCT_CHL);
    int g = 0;
    while (kptr(p) && g++ < 300) {
        char nm[80] = {0};
        kcd_fname_str(p, nm, 72);
        if (strstr(nm, "Team")) {
            int o = (int)r32(p + OFF_UPROP_OFF);
            if (o > 0 && o < 0x800) return o;
        }
        p = kread_ptr(p + OFF_UFIELD_NEXT);
    }
    return -1;
}
KRW
echo "===== 4/5 UE4 ====="
cat > src/game/ue4.h <<'UE4H'
#pragma once
#include <stdint.h>
#include "krw.h"

typedef struct { float x, y; } Vec2;

#define BONE_N   15
#define MAX_ENT  64
#define MAX_LOOT 128

typedef struct {
    uint64_t pawn;
    RVec3 world;
    float dist;
    int team, is_bot, yaw;
    float hp;
    char op[48];
    RVec3 bones[BONE_N];
} EntOut;

#define LT_BOX 0
#define LT_GUN 1
#define LT_BAG 2
#define LT_AMMO 3
#define LT_MED 4
#define LT_ARMOR 5
#define LT_ITEM 6

typedef struct {
    uint64_t actor;
    RVec3 world;
    float dist;
    int rarity, type;
    char name[48];
} LootOut;

typedef struct {
    int uw_level, uw_gi;
    int lvl_actors, lvl_cnt;
    int actor_root, root_loc;
    int pawn_ps, pawn_ctrl, ctrl_rot;
    int gi_local, lp_pc, pc_cam, cam_cache;
    int pov_loc, pov_rot, pov_fov;
} Ue4Off;

typedef struct {
    uint64_t task, base, gworld, self_pawn;
    RVec3 pov_loc;
    float pov_pitch, pov_yaw, fov;
    int sw, sh, ready;
    Ue4Off off;
    int ver, reflect_ok, best_score;
} Ue4Ctx;

int ue4_setup(Ue4Ctx *c);
int ue4_scan(Ue4Ctx *c, EntOut *out, int max);
int ue4_w2s(Ue4Ctx *c, RVec3 w, Vec2 *s);
int ue4_scan_loot(Ue4Ctx *c, LootOut *out, int max);
UE4H

cat > src/game/ue4.c <<'UE4C'
#include "ue4.h"
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define D2R 0.0174532925199433f

#define OBJ_CLASS    0x10
#define OBJ_NAME     0x18
#define STRUCT_SUPER 0x40
#define STRUCT_CHILD 0x48
#define PROP_OFFSET  0x4C
#define FIELD_NEXT   0x28

static const Ue4Off DEF427 = {
    0x30, 0x1B8, 0xA0, 0xA8, 0x1B0, 0x1A0,
    0x2B0, 0x2A8, 0x2E4,
    0x38, 0x30, 0x2E0, 0x1A0,
    0x10, 0x1C, 0x28
};
static const Ue4Off DEF50 = {
    0x38, 0x1C0, 0xA8, 0xB0, 0x1B8, 0x1A0,
    0x2C0, 0x2B8, 0x2F0,
    0x40, 0x38, 0x2F0, 0x1B0,
    0x10, 0x1C, 0x28
};
static const Ue4Off DEF426 = {
    0x30, 0x1B8, 0xA0, 0xA8, 0x198, 0x1A0,
    0x2B0, 0x2A8, 0x2E4,
    0x38, 0x30, 0x2E0, 0x1A0,
    0x10, 0x1C, 0x28
};

static int okp(uint64_t p) { return p > 0x100000000ULL && p < 0x3000000000ULL; }

static int prop_in_class(uint64_t cls, const char *name) {
    uint64_t first = kread_ptr(cls + STRUCT_CHILD);
    uint64_t p = first;
    int g = 0;
    while (okp(p) && g++ < 800) {
        char nm[96] = {0};
        kcd_fname_str(p, nm, 88);
        if (nm[0] && strcmp(nm, name) == 0) {
            int o = (int)r32(p + PROP_OFFSET);
            if (o > 0 && o < 0x4000) return o;
        }
        uint64_t nx = kread_ptr(p + FIELD_NEXT);
        if (nx == first) break;
        p = nx;
    }
    return -1;
}

static int rf_find(uint64_t obj, const char *name) {
    if (!okp(obj) || !g_gnames) return -1;
    uint64_t cls = kread_ptr(obj + OBJ_CLASS);
    int d = 0;
    while (okp(cls) && d++ < 14) {
        int o = prop_in_class(cls, name);
        if (o > 0) return o;
        uint64_t sup = kread_ptr(cls + STRUCT_SUPER);
        if (!okp(sup) || sup == cls) break;
        cls = sup;
    }
    return -1;
}

static int rf_any(uint64_t obj, const char *a, const char *b) {
    int o = rf_find(obj, a);
    if (o > 0) return o;
    if (b) { o = rf_find(obj, b); if (o > 0) return o; }
    return -1;
}

static int u16_to_utf8(const uint16_t *in, int n, char *out, int max) {
    int j = 0;
    for (int i = 0; i < n && j < max - 4; i++) {
        uint32_t ch = in[i];
        if (ch == 0) break;
        if (ch < 0x80) out[j++] = (char)ch;
        else if (ch < 0x800) {
            out[j++] = (char)(0xC0 | (ch >> 6));
            out[j++] = (char)(0x80 | (ch & 0x3F));
        } else {
            out[j++] = (char)(0xE0 | (ch >> 12));
            out[j++] = (char)(0x80 | ((ch >> 6) & 0x3F));
            out[j++] = (char)(0x80 | (ch & 0x3F));
        }
    }
    out[j] = 0;
    return j;
}

static int read_ftext_utf8(uint64_t addr, char *out, int max) {
    uint64_t data = kread_ptr(addr);
    if (!okp(data)) return 0;
    uint64_t src = kread_ptr(data + 0x28);
    int32_t len = (int32_t)r32(data + 0x30);
    if (!okp(src) || len <= 0 || len > 32) return 0;
    uint16_t buf[40];
    for (int i = 0; i < len; i++) buf[i] = (uint16_t)r32(src + (uint64_t)i * 2);
    return u16_to_utf8(buf, len, out, max);
}

static int read_fstring_utf8(uint64_t addr, char *out, int max) {
    uint64_t src = kread_ptr(addr);
    int32_t len = (int32_t)r32(addr + 8);
    if (!okp(src) || len <= 0 || len > 32) return 0;
    uint16_t buf[40];
    for (int i = 0; i < len; i++) buf[i] = (uint16_t)r32(src + (uint64_t)i * 2);
    return u16_to_utf8(buf, len, out, max);
}

static void try_read_name(uint64_t actor, char *out, int max) {
    static const char *props[] = {
        "DisplayName", "OperatorName", "CharacterName", "HeroName",
        "NameText", "PlayerNamePrivate", "PlayerName", NULL
    };
    out[0] = 0;
    for (int k = 0; props[k] && !out[0]; k++) {
        int o = rf_find(actor, props[k]);
        if (o <= 0) continue;
        if (read_ftext_utf8(actor + o, out, max) > 0) break;
        if (read_fstring_utf8(actor + o, out, max) > 0) break;
    }
}

static int look_uworld(Ue4Ctx *c, uint64_t u) {
    if (!okp(u)) return 0;
    uint64_t l = kread_ptr(u + c->off.uw_level);
    if (!okp(l)) return 0;
    uint64_t a = kread_ptr(l + c->off.lvl_actors);
    if (!okp(a)) return 0;
    int n = (int)r32(l + c->off.lvl_cnt);
    if (n < 1 || n > 200000) return 0;
    return 1;
}

static uint64_t scan_gworld(Ue4Ctx *c) {
    const size_t BLK = 0x4000;
    uint8_t *buf = (uint8_t *)malloc(BLK);
    if (!buf) return 0;

    uint64_t ranges[3][2] = {
        { c->base + 0x01000000ULL, c->base + 0x0A000000ULL },
        { c->base + 0x0A000000ULL, c->base + 0x20000000ULL },
        { c->base + 0x80000000ULL, c->base + 0x120000000ULL }
    };
    uint64_t found = 0;
    for (int r = 0; r < 3 && !found; r++) {
        fprintf(stderr, "[kcd] GW seg%d %llx..%llx\n", r,
                (unsigned long long)ranges[r][0],
                (unsigned long long)ranges[r][1]);
        for (uint64_t a = ranges[r][0]; a < ranges[r][1]; a += BLK) {
            if (kcd_block_read(c->task, a, buf, BLK) != 0) continue;
            for (size_t i = 0; i + 8 <= BLK; i += 8) {
                uint64_t v;
                memcpy(&v, buf + i, 8);
                if (!okp(v)) continue;
                if (look_uworld(c, v)) { found = v; break; }
            }
            if (found) break;
        }
    }
    free(buf);
    return found;
}

static uint64_t scan_gworld_slow(Ue4Ctx *c) {
    if (!g_gnames) return 0;
    const size_t BLK = 0x4000;
    uint8_t *buf = (uint8_t *)malloc(BLK);
    if (!buf) return 0;
    uint64_t ret = 0;
    for (uint64_t a = c->base + 0x01000000ULL;
         a < c->base + 0x40000000ULL && !ret; a += BLK) {
        if (kcd_block_read(c->task, a, buf, BLK) != 0) continue;
        for (size_t i = 0; i + 8 <= BLK; i += 8) {
            uint64_t v;
            memcpy(&v, buf + i, 8);
            if (!okp(v)) continue;
            uint64_t cls = kread_ptr(v + OBJ_CLASS);
            if (!okp(cls)) continue;
            int lvl = rf_find(v, "PersistentLevel");
            if (lvl <= 0) continue;
            uint64_t l = kread_ptr(v + lvl);
            if (!okp(l)) continue;
            int act = rf_find(l, "Actors");
            if (act <= 0) continue;
            uint64_t arr = kread_ptr(l + act);
            if (!okp(arr)) continue;
            int cnt = (int)r32(l + act + 8);
            if (cnt < 1 || cnt > 200000) continue;
            c->off.uw_level  = lvl;
            c->off.lvl_actors = act;
            c->off.lvl_cnt   = act + 8;
            ret = v;
            break;
        }
    }
    free(buf);
    return ret;
}

static int auto_offsets(Ue4Ctx *c) {
    uint64_t gw = c->gworld;
    int hit = 0;

    int o = rf_find(gw, "PersistentLevel");
    if (o > 0) { c->off.uw_level = o; hit++; }
    o = rf_find(gw, "OwningGameInstance");
    if (o > 0) { c->off.uw_gi = o; hit++; }

    uint64_t lvl = kread_ptr(gw + c->off.uw_level);
    if (!okp(lvl)) return hit;
    o = rf_find(lvl, "Actors");
    if (o > 0) { c->off.lvl_actors = o; c->off.lvl_cnt = o + 8; hit++; }

    uint64_t arr = kread_ptr(lvl + c->off.lvl_actors);
    int cnt = (int)r32(lvl + c->off.lvl_cnt);
    if (!okp(arr) || cnt < 1) return hit;
    if (cnt > 3000) cnt = 3000;

    uint64_t any = 0, pawn = 0;
    for (int i = 0; i < cnt; i++) {
        uint64_t a = kread_ptr(arr + (uint64_t)i * 8);
        if (!okp(a)) continue;
        if (!any) any = a;
        char cn[80] = {0};
        if (kcd_class_name(a, cn, 72) > 0) {
            if (strstr(cn, "Character") || strstr(cn, "Pawn")) { pawn = a; break; }
        }
    }

    if (any) {
        o = rf_find(any, "RootComponent");
        if (o > 0) { c->off.actor_root = o; hit++; }
        uint64_t rc = kread_ptr(any + c->off.actor_root);
        if (okp(rc)) {
            o = rf_find(rc, "RelativeLocation");
            if (o > 0) { c->off.root_loc = o; hit++; }
        }
    }
    if (pawn) {
        o = rf_find(pawn, "PlayerState");
        if (o > 0) { c->off.pawn_ps = o; hit++; }
        o = rf_find(pawn, "Controller");
        if (o > 0) { c->off.pawn_ctrl = o; hit++; }
        uint64_t ctrl = kread_ptr(pawn + c->off.pawn_ctrl);
        if (okp(ctrl)) {
            o = rf_find(ctrl, "ControlRotation");
            if (o > 0) { c->off.ctrl_rot = o + 4; hit++; }
        }
    }

    uint64_t gi = kread_ptr(gw + c->off.uw_gi);
    if (okp(gi)) {
        o = rf_find(gi, "LocalPlayers");
        if (o > 0) { c->off.gi_local = o; hit++; }
        uint64_t lp = kread_ptr(gi + c->off.gi_local);
        if (okp(lp)) {
            o = rf_find(lp, "PlayerController");
            if (o > 0) { c->off.lp_pc = o; hit++; }
            uint64_t pc = kread_ptr(lp + c->off.lp_pc);
            if (okp(pc)) {
                o = rf_find(pc, "PlayerCameraManager");
                if (o > 0) { c->off.pc_cam = o; hit++; }
                uint64_t cam = kread_ptr(pc + c->off.pc_cam);
                if (okp(cam)) {
                    o = rf_any(cam, "CameraCachePrivate", "CameraCache");
                    if (o > 0) { c->off.cam_cache = o; hit++; }
                }
            }
        }
    }
    return hit;
}

static int read_pov(Ue4Ctx *c) {
    uint64_t gw = c->gworld;
    uint64_t pc = 0;
    uint64_t gi = kread_ptr(gw + c->off.uw_gi);
    if (okp(gi)) {
        uint64_t lp = kread_ptr(gi + c->off.gi_local);
        if (okp(lp)) pc = kread_ptr(lp + c->off.lp_pc);
    }
    c->fov = 0;
    if (okp(pc)) {
        uint64_t cam = kread_ptr(pc + c->off.pc_cam);
        if (okp(cam)) {
            RVec3 loc, rot;
            if (row_read_task(c->task, cam + c->off.cam_cache + c->off.pov_loc,
                              &loc, 12) == 0) c->pov_loc = loc;
            if (row_read_task(c->task, cam + c->off.cam_cache + c->off.pov_rot,
                              &rot, 12) == 0) {
                c->pov_pitch = rot.x;
                c->pov_yaw   = rot.y;
            }
            float f = 0;
            if (row_read_task(c->task, cam + c->off.cam_cache + c->off.pov_fov,
                              &f, 4) == 0) {
                if (f > 30.0f && f < 140.0f) c->fov = f;
            }
        }
    }
    if (c->fov < 30.0f || c->fov > 140.0f) c->fov = 90.0f;
    if (fabsf(c->pov_loc.x) > 1000000.0f) return 0;
    if (fabsf(c->pov_loc.z) > 100000.0f) return 0;
    return 1;
}

int ue4_w2s(Ue4Ctx *c, RVec3 w, Vec2 *s) {
    float dx = w.x - c->pov_loc.x;
    float dy = w.y - c->pov_loc.y;
    float dz = w.z - c->pov_loc.z;
    float cy = cosf(-c->pov_yaw * D2R), sy = sinf(-c->pov_yaw * D2R);
    float x1 = dx * cy - dy * sy;
    float y1 = dx * sy + dy * cy;
    float z1 = dz;
    float cp = cosf(c->pov_pitch * D2R), sp = sinf(c->pov_pitch * D2R);
    float x2 = x1 * cp - z1 * sp;
    float z2 = x1 * sp + z1 * cp;
    float y2 = y1;
    if (x2 < 1.0f) return 0;
    float sc = (c->sh * 0.5f) / tanf(c->fov * D2R * 0.5f);
    s->x = c->sw * 0.5f + (y2 * sc / x2);
    s->y = c->sh * 0.5f - (z2 * sc / x2);
    return 1;
}

static void build_bones(EntOut *e) {
    const float h = 176.0f;
    RVec3 b = e->world;
    float yr = (float)e->yaw * D2R;
    float rx = cosf(yr) * 20.0f, ry = sinf(yr) * 20.0f;
    e->bones[0]  = (RVec3){ b.x, b.y, b.z + h };
    e->bones[1]  = (RVec3){ b.x, b.y, b.z + h * 0.90f };
    e->bones[2]  = (RVec3){ b.x, b.y, b.z + h * 0.80f };
    e->bones[3]  = (RVec3){ b.x - rx, b.y - ry, b.z + h * 0.80f };
    e->bones[4]  = (RVec3){ b.x - rx * 1.7f, b.y - ry * 1.7f, b.z + h * 0.60f };
    e->bones[5]  = (RVec3){ b.x - rx * 2.2f, b.y - ry * 2.2f, b.z + h * 0.45f };
    e->bones[6]  = (RVec3){ b.x + rx, b.y + ry, b.z + h * 0.80f };
    e->bones[7]  = (RVec3){ b.x + rx * 1.7f, b.y + ry * 1.7f, b.z + h * 0.60f };
    e->bones[8]  = (RVec3){ b.x + rx * 2.2f, b.y + ry * 2.2f, b.z + h * 0.45f };
    e->bones[9]  = (RVec3){ b.x, b.y, b.z + h * 0.50f };
    e->bones[10] = (RVec3){ b.x - rx * 0.6f, b.y - ry * 0.6f, b.z + h * 0.50f };
    e->bones[11] = (RVec3){ b.x + rx * 0.6f, b.y + ry * 0.6f, b.z + h * 0.50f };
    e->bones[12] = (RVec3){ b.x - rx * 0.6f, b.y - ry * 0.6f, b.z + h * 0.26f };
    e->bones[13] = (RVec3){ b.x + rx * 0.6f, b.y + ry * 0.6f, b.z + h * 0.26f };
    e->bones[14] = (RVec3){ b.x, b.y, b.z };
}

static void op_from_class(uint64_t pawn, char *out, int max) {
    out[0] = 0;
    char buf[80] = {0};
    if (kcd_class_name(pawn, buf, 72) <= 0) return;
    char *p = buf;
    if (strncmp(p, "BP_", 3) == 0) p += 3;
    if (strncmp(p, "Operator_", 9) == 0) p += 9;
    if (strncmp(p, "Op_", 3) == 0) p += 3;
    int n = (int)strlen(p);
    if (n > 2 && strcmp(p + n - 2, "_C") == 0) p[n - 2] = 0;
    strncpy(out, p, (size_t)(max - 1));
    out[max - 1] = 0;
}

int ue4_scan(Ue4Ctx *c, EntOut *out, int max) {
    if (!c->ready || !c->gworld) return 0;
    uint64_t l = kread_ptr(c->gworld + c->off.uw_level);
    if (!okp(l)) return 0;
    uint64_t arr = kread_ptr(l + c->off.lvl_actors);
    if (!okp(arr)) return 0;
    int cnt = (int)r32(l + c->off.lvl_cnt);
    if (cnt < 1) return 0;
    if (cnt > 3000) cnt = 3000;

    size_t bytes = sizeof(uint64_t) * (size_t)cnt;
    uint64_t *abuf = (uint64_t *)malloc(bytes);
    if (!abuf) return 0;
    kcd_block_read(c->task, arr, abuf, bytes);

    uint64_t self = c->self_pawn;
    int n = 0;
    for (int i = 0; i < cnt && n < max; i++) {
        uint64_t a = abuf[i];
        if (!okp(a) || a == self) continue;

        uint64_t ps = kread_ptr(a + c->off.pawn_ps);
        if (!okp(ps)) continue;
        uint64_t root = kread_ptr(a + c->off.actor_root);
        if (!okp(root)) continue;

        RVec3 loc;
        if (row_read_task(c->task, root + c->off.root_loc, &loc, 12) != 0) continue;
        if (loc.x < -1000000.0f || loc.x > 1000000.0f) continue;
        if (loc.z < -100000.0f || loc.z > 100000.0f) continue;

        float dx = loc.x - c->pov_loc.x;
        float dy = loc.y - c->pov_loc.y;
        float dz = loc.z - c->pov_loc.z;

        EntOut *e = &out[n];
        memset(e, 0, sizeof(*e));
        e->pawn   = a;
        e->world  = loc;
        e->dist   = sqrtf(dx * dx + dy * dy + dz * dz) / 100.0f;
        e->is_bot = kcd_is_bot(a);
        e->team   = kcd_team_of(a);
        e->yaw    = kcd_yaw_of(a);
        if (e->yaw < 0) e->yaw = 0;
        e->hp = kcd_health_of(a);
        op_from_class(a, e->op, 48);
        char dn[48] = {0};
        try_read_name(a, dn, 48);
        if (dn[0]) { strncpy(e->op, dn, 47); e->op[47] = 0; }
        build_bones(e);
        n++;
    }
    free(abuf);
    return n;
}

static int score_seed(Ue4Ctx *c) {
    int s = 0;
    if (c->self_pawn) s += 50;
    if (c->fov > 30.0f && c->fov < 140.0f) s += 20;
    if (fabsf(c->pov_loc.x) > 1.0f) s += 15;
    EntOut tmp[8];
    if (ue4_scan(c, tmp, 8) > 0) s += 30;
    return s;
}

int ue4_setup(Ue4Ctx *c) {
    c->ready = 0;
    c->reflect_ok = 0;
    c->best_score = -9999;

    const Ue4Off *seeds[3] = { &DEF427, &DEF50, &DEF426 };
    Ue4Ctx best_ctx;
    memset(&best_ctx, 0, sizeof(best_ctx));
    int best_i = -1, best_s = -9999;

    for (int i = 0; i < 3; i++) {
        c->off = *seeds[i];
        c->ver = i;
        c->fov = 90.0f;
        c->self_pawn = 0;
        uint64_t gw = scan_gworld(c);
        if (!gw) {
            fprintf(stderr, "[kcd] seed%d: no GWorld\n", i);
            continue;
        }
        c->gworld = gw;
        c->reflect_ok = auto_offsets(c);
        if (!read_pov(c)) {
            fprintf(stderr, "[kcd] seed%d: pov fail\n", i);
            continue;
        }
        c->ready = 1;
        int s = score_seed(c);
        fprintf(stderr, "[kcd] seed%d score=%d self=%llx fov=%.0f refl=%d\n",
                i, s, (unsigned long long)c->self_pawn, c->fov, c->reflect_ok);
        if (s > best_s) { best_s = s; best_i = i; best_ctx = *c; }
    }

    if (best_i >= 0) {
        *c = best_ctx;
        c->ready = 1;
        c->best_score = best_s;
        fprintf(stderr, "[kcd] PICK seed%d score=%d\n", best_i, best_s);
        return best_i;
    }

    fprintf(stderr, "[kcd] all seeds failed, slow scan\n");
    c->off = DEF427;
    c->ver = 9;
    c->fov = 90.0f;
    c->self_pawn = 0;
    uint64_t gw = scan_gworld_slow(c);
    if (!gw) { fprintf(stderr, "[kcd] slow scan fail\n"); return -1; }
    c->gworld = gw;
    c->reflect_ok = auto_offsets(c);
    if (!read_pov(c)) { fprintf(stderr, "[kcd] slow pov fail\n"); return -1; }
    c->ready = 1;
    c->best_score = score_seed(c);
    fprintf(stderr, "[kcd] SLOW score=%d\n", c->best_score);
    return 9;
}

static int kw_hit(const char *s, const char *k) {
    size_t n = strlen(k);
    for (const char *p = s; *p; p++) {
        size_t i = 0;
        while (i < n && p[i]) {
            char a = p[i], b = k[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) break;
            i++;
        }
        if (i == n) return 1;
    }
    return 0;
}

static int loot_type(const char *c) {
    if (kw_hit(c, "Weapon") || kw_hit(c, "Rifle") || kw_hit(c, "Gun") ||
        kw_hit(c, "Pistol") || kw_hit(c, "Sniper") || kw_hit(c, "Shotgun") ||
        kw_hit(c, "SMG") || kw_hit(c, "LMG") || kw_hit(c, "Carbine")) return LT_GUN;
    if (kw_hit(c, "Backpack") || kw_hit(c, "Bag") || kw_hit(c, "Pack") ||
        kw_hit(c, "Rucksack")) return LT_BAG;
    if (kw_hit(c, "Ammo") || kw_hit(c, "Bullet") || kw_hit(c, "Mag") ||
        kw_hit(c, "Grenade") || kw_hit(c, "Bomb")) return LT_AMMO;
    if (kw_hit(c, "Med") || kw_hit(c, "Aid") || kw_hit(c, "Bandage") ||
        kw_hit(c, "Injector") || kw_hit(c, "Stim") || kw_hit(c, "Syringe")) return LT_MED;
    if (kw_hit(c, "Armor") || kw_hit(c, "Vest") || kw_hit(c, "Helmet") ||
        kw_hit(c, "Plate") || kw_hit(c, "Rig")) return LT_ARMOR;
    if (kw_hit(c, "Box") || kw_hit(c, "Case") || kw_hit(c, "Safe") ||
        kw_hit(c, "Chest") || kw_hit(c, "Container") || kw_hit(c, "Loot") ||
        kw_hit(c, "Supply") || kw_hit(c, "Stash") || kw_hit(c, "Crate")) return LT_BOX;
    if (kw_hit(c, "Item") || kw_hit(c, "Pickup") || kw_hit(c, "Pickable") ||
        kw_hit(c, "Drop")) return LT_ITEM;
    return -1;
}

static int loot_rarity(uint64_t actor) {
    static const uint32_t offs[] = {
        0x2C0, 0x2D0, 0x2E0, 0x2F0, 0x300, 0x310, 0x3A0, 0x3B0, 0x4A0, 0x5A0
    };
    for (int i = 0; i < 10; i++) {
        int v = (int)r32(actor + offs[i]);
        if (v >= 1 && v <= 6) return v;
    }
    return 0;
}

int ue4_scan_loot(Ue4Ctx *c, LootOut *out, int max) {
    if (!c->ready || !c->gworld) return 0;
    uint64_t l = kread_ptr(c->gworld + c->off.uw_level);
    if (!okp(l)) return 0;
    uint64_t arr = kread_ptr(l + c->off.lvl_actors);
    if (!okp(arr)) return 0;
    int cnt = (int)r32(l + c->off.lvl_cnt);
    if (cnt < 1) return 0;
    if (cnt > 4000) cnt = 4000;

    size_t bytes = sizeof(uint64_t) * (size_t)cnt;
    uint64_t *abuf = (uint64_t *)malloc(bytes);
    if (!abuf) return 0;
    kcd_block_read(c->task, arr, abuf, bytes);

    int n = 0;
    for (int i = 0; i < cnt && n < max; i++) {
        uint64_t a = abuf[i];
        if (!okp(a) || a == c->self_pawn) continue;

        char cls[96] = {0};
        if (kcd_class_name(a, cls, 88) <= 0) continue;
        int tp = loot_type(cls);
        if (tp < 0) continue;

        uint64_t ps = kread_ptr(a + c->off.pawn_ps);
        if (okp(ps)) continue;

        int rar = loot_rarity(a);
        if (rar <= 0) rar = 3;

        uint64_t root = kread_ptr(a + c->off.actor_root);
        if (!okp(root)) continue;
        RVec3 loc;
        if (row_read_task(c->task, root + c->off.root_loc, &loc, 12) != 0) continue;
        if (loc.x < -1000000.0f || loc.x > 1000000.0f) continue;
        if (loc.z < -100000.0f || loc.z > 100000.0f) continue;

        float dx = loc.x - c->pov_loc.x;
        float dy = loc.y - c->pov_loc.y;
        float dz = loc.z - c->pov_loc.z;

        LootOut *o = &out[n];
        memset(o, 0, sizeof(*o));
        o->actor  = a;
        o->world  = loc;
        o->dist   = sqrtf(dx * dx + dy * dy + dz * dz) / 100.0f;
        o->rarity = rar;
        o->type   = tp;

        char *p = cls;
        if (strncmp(p, "BP_", 3) == 0) p += 3;
        int L = (int)strlen(p);
        if (L > 2 && strcmp(p + L - 2, "_C") == 0) p[L - 2] = 0;
        strncpy(o->name, p, 47);
        o->name[47] = 0;
        n++;
    }
    free(abuf);
    return n;
}
UE4C
echo "===== 5/5 TWEAK + PACK ====="
cat > src/tweak/Overlay.xm <<'OX1'
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include <unistd.h>
#include "krw.h"
#include "ue4.h"

@interface UIWindow (KCDSec)
- (void)_setSecure:(BOOL)b;
@end

static Ue4Ctx  g_ctx;
static EntOut  g_ents[MAX_ENT];
static int     g_n = 0;
static int     g_run = 1;
static int     g_game_pid = 0;
static int     g_my_team = 1;
static float   g_near = 1e9f;
static int     g_near_team = -1;
static int     g_near_yaw = -1;
static char    g_near_op[48] = {0};
static int     g_back = 0;
static int     g_humans = 0;
static uint32_t g_tmask = 0;
static int     g_locked = 0;
static uint64_t g_locked_task = 0;
static volatile int g_restart = 0;
static UIWindow *g_esp = nil;
static UIWindow *g_hud = nil;
static UIWindow *g_panel = nil;
static UILabel *g_l1 = nil, *g_l2 = nil, *g_l3 = nil;
static UIScrollView *g_psv = nil;
static BOOL g_panel_on = NO;

static id cfg_get(NSString *k) {
    CFPreferencesAppSynchronize(CFSTR("com.kcd.config"));
    return (__bridge id)CFPreferencesCopyAppValue((__bridge CFStringRef)k,
                                                  CFSTR("com.kcd.config"));
}
static void cfg_set(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k,
                             (__bridge CFPropertyListRef)v,
                             CFSTR("com.kcd.config"));
    CFPreferencesAppSynchronize(CFSTR("com.kcd.config"));
}
static BOOL cfg_b(NSString *k, BOOL d) { id v = cfg_get(k); return v ? [v boolValue] : d; }
static int  cfg_i(NSString *k, int d)  { id v = cfg_get(k); return v ? [v intValue] : d; }

static UIFont *PFS(CGFloat s) {
    UIFont *f = [UIFont fontWithName:@"PingFangSC-Regular" size:s];
    return f ? f : [UIFont systemFontOfSize:s];
}
static UIFont *PFSB(CGFloat s) {
    UIFont *f = [UIFont fontWithName:@"PingFangSC-Semibold" size:s];
    return f ? f : [UIFont boldSystemFontOfSize:s];
}

static CGFloat ui_scale(void) {
    CGRect b = [UIScreen mainScreen].bounds;
    return (MIN(b.size.width, b.size.height) >= 1000) ? 1.7 : 1.0;
}

static CGRect landscape_bounds(void) {
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat w = MAX(b.size.width, b.size.height);
    CGFloat h = MIN(b.size.width, b.size.height);
    return CGRectMake(0, 0, w, h);
}

static UIColor *team_color(int t, BOOL me) {
    if (me) return [UIColor colorWithRed:0.0 green:1.0 blue:0.93 alpha:1.0];
    if (t < 0) return [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1.0];
    static const int rgb[12][3] = {
        {255,38,38},{255,140,0},{255,224,0},{160,255,0},
        {0,224,80},{0,224,160},{0,200,255},{42,107,255},
        {138,43,226},{224,32,192},{255,80,144},{176,112,48}
    };
    int i = t % 12;
    if (i < 0) i += 12;
    return [UIColor colorWithRed:rgb[i][0]/255.0
                           green:rgb[i][1]/255.0
                            blue:rgb[i][2]/255.0
                           alpha:1.0];
}

static const char *op_cn(const char *en) {
    if (!en || !en[0]) return "";
    static const struct { const char *k; const char *v; } T[] = {
        {"HongLang","红狼"},{"Honglang","红狼"},{"Wolf","红狼"},
        {"WeiLong","威龙"},{"Weilong","威龙"},{"Wyvern","威龙"},{"Dragon","威龙"},
        {"WuMing","无名"},{"Wuming","无名"},{"Nameless","无名"},
        {"JiFeng","疾风"},{"Jifeng","疾风"},{"Gale","疾风"},
        {"YeHuo","野火"},{"Yehuo","野火"},{"Wildfire","野火"},
        {"FengYi","蜂医"},{"Fengyi","蜂医"},{"Stinger","蜂医"},
        {"Butterfly","蝶"},{"Die","蝶"},
        {"LvRen","旅人"},{"Lvren","旅人"},{"Wanderer","旅人"},
        {"MuYangRen","牧羊人"},{"Muyangren","牧羊人"},{"Shepherd","牧羊人"},
        {"WuLuLu","乌鲁鲁"},{"Wululu","乌鲁鲁"},{"Uluru","乌鲁鲁"},
        {"ShenLan","深蓝"},{"Shenlan","深蓝"},{"DeepBlue","深蓝"},
        {"BiTe","比特"},{"Bite","比特"},
        {"YeDan","液氮"},{"Yedan","液氮"},{"Nitrogen","液氮"},
        {"HaiZhua","骇爪"},{"Haizhua","骇爪"},{"HaiZhao","骇爪"},{"Hackclaw","骇爪"},
        {"YinYi","银翼"},{"Yinyi","银翼"},{"Silverwing","银翼"},
        {"HuiXiang","回响"},{"Huixiang","回响"},{"Echo","回响"},
        {"Luna","露娜"},
        {NULL, NULL}
    };
    for (int i = 0; T[i].k; i++) if (strstr(en, T[i].k)) return T[i].v;
    if (strstr(en, "_Gu") || strstr(en, "Gu_") || strcmp(en, "Gu") == 0) return "蛊";
    return en;
}

static const char *loot_cn(const char *en) {
    if (!en || !en[0]) return "";
    if (strstr(en, "SafeBox") || strstr(en, "Case_Safe")) return "保险箱";
    if (strstr(en, "WeaponBox") || strstr(en, "GunCase")) return "武器箱";
    if (strstr(en, "AmmoBox") || strstr(en, "Ammo_Case")) return "弹药箱";
    if (strstr(en, "MedBox") || strstr(en, "MedicalBox")) return "医疗箱";
    if (strstr(en, "SupplyBox") || strstr(en, "Supply")) return "补给箱";
    if (strstr(en, "LootBox") || strstr(en, "Loot")) return "战利品";
    if (strstr(en, "Crate")) return "木箱";
    if (strstr(en, "Backpack")) return "背包";
    if (strstr(en, "Rucksack")) return "行囊";
    if (strstr(en, "Vest")) return "护甲";
    if (strstr(en, "Helmet")) return "头盔";
    if (strstr(en, "Grenade")) return "手雷";
    if (strstr(en, "Medkit") || strstr(en, "FirstAid")) return "急救包";
    if (strstr(en, "Bandage")) return "绷带";
    if (strstr(en, "Injector") || strstr(en, "Stim")) return "注射器";
    return en;
}

static void *scan_loop(void *arg) {
    (void)arg;
    if (row_up() != 0) {
        fprintf(stderr, "[kcd] row_up FAIL\n");
        return NULL;
    }

    while (g_run) {
        if (g_restart) {
            g_restart = 0;
            fprintf(stderr, "[kcd] restart...\n");
            g_kfd_ready = 0;
            g_gnames = 0;
            g_locked = 0;
            g_locked_task = 0;
            g_game_pid = 0;
            memset(&g_ctx, 0, sizeof(g_ctx));
            if (row_up() == 0) fprintf(stderr, "[kcd] restart OK\n");
            else fprintf(stderr, "[kcd] restart FAIL\n");
            continue;
        }

        int pid = row_pid_by_name("DeltaForce");
        if (pid <= 0) {
            if (g_locked) {
                g_locked = 0;
                g_locked_task = 0;
                g_game_pid = 0;
                memset(&g_ctx, 0, sizeof(g_ctx));
            }
            usleep(500000);
            continue;
        }

        uint64_t proc = row_task_of_pid(pid);
        if (!proc) { usleep(300000); continue; }

        if (!g_locked || proc != g_locked_task) {
            uint64_t base = row_base_of_task(proc);
            if (!base) { usleep(300000); continue; }

            memset(&g_ctx, 0, sizeof(g_ctx));
            g_ctx.task = proc;
            g_ctx.base = base;
            CGRect sb = landscape_bounds();
            g_ctx.sw = (int)sb.size.width;
            g_ctx.sh = (int)sb.size.height;

            if (kcd_gnames_scan() != 0) fprintf(stderr, "[kcd] GNames miss\n");

            int v = ue4_setup(&g_ctx);
            if (v < 0 || !g_ctx.ready) {
                fprintf(stderr, "[kcd] ue4_setup FAIL v=%d\n", v);
                usleep(1000000);
                continue;
            }

            g_game_pid = pid;
            g_locked_task = proc;
            g_locked = 1;

            int sel = cfg_i(@"teamid_off", 0);
            if (sel > 0) g_off_teamid = 0x2B8 + (sel - 1) * 8;
            else if (g_ps_n >= 3) {
                int o = kcd_calib_teamid();
                if (o > 0) g_off_teamid = o;
                else {
                    int r2 = kcd_reflect_teamid();
                    if (r2 > 0) g_off_teamid = r2;
                }
            }
            fprintf(stderr,
                "[kcd] LOCKED pid=%d proc=%llx base=%llx ver=%d team=0x%X score=%d\n",
                pid, (unsigned long long)proc, (unsigned long long)base,
                g_ctx.ver, g_off_teamid, g_ctx.best_score);
        }

        if (!g_locked || !g_ctx.ready) { usleep(200000); continue; }

        g_my_team = cfg_i(@"my_team", 1);
        g_n = ue4_scan(&g_ctx, g_ents, MAX_ENT);

        float nr = 1e9f;
        int nt = -1, ny = -1, bk = 0, hm = 0;
        char nop[48] = {0};
        uint32_t tm = 0;
        int botf = cfg_b(@"bot_filter", YES) ? 1 : 0;
        int maxd = cfg_i(@"max_dist", 300);

        for (int i = 0; i < g_n; i++) {
            EntOut *e = &g_ents[i];
            if (botf && e->is_bot) continue;
            if (e->dist > maxd) continue;
            hm++;
            if (e->team >= 0 && e->team < 32) tm |= (1u << e->team);
            Vec2 sp;
            BOOL on = ue4_w2s(&g_ctx, e->world, &sp) &&
                      sp.x > 0 && sp.x < g_ctx.sw &&
                      sp.y > 0 && sp.y < g_ctx.sh;
            if (!on && e->dist < 40.0f) bk++;
            if (e->dist < nr) {
                nr = e->dist;
                nt = e->team;
                ny = e->yaw;
                strncpy(nop, e->op, 47);
            }
        }

        g_near = nr;
        g_near_team = nt;
        g_near_yaw = ny;
        strncpy(g_near_op, nop, 47);
        g_near_op[47] = 0;
        g_back = bk;
        g_humans = hm;
        g_tmask = tm;

        usleep((useconds_t)cfg_i(@"scan_ms", 16) * 1000);
    }
    return NULL;
}

@interface KCDView : UIView @end
@implementation KCDView
- (void)drawRect:(CGRect)r {
    (void)r;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    int botf    = cfg_b(@"bot_filter", YES) ? 1 : 0;
    int teamf   = cfg_b(@"team_filter", NO) ? 1 : 0;
    int maxd    = cfg_i(@"max_dist", 300);
    int box_on  = cfg_b(@"box_enemy", YES) ? 1 : 0;
    int bone_on = cfg_b(@"skeleton", YES) ? 1 : 0;
    int hp_on   = cfg_b(@"health", YES) ? 1 : 0;
    int d_on    = cfg_b(@"distance", YES) ? 1 : 0;
    int nm_on   = cfg_b(@"op_name", YES) ? 1 : 0;
    int nsrc    = cfg_i(@"name_src", 0);
    CGFloat fs  = (CGFloat)cfg_i(@"text_size", 13) * ui_scale();
    CGFloat th  = (CGFloat)cfg_i(@"thick", 1);

    UIFont *f = [UIFont boldSystemFontOfSize:fs];
    NSDictionary *wa = @{ NSFontAttributeName: f,
                          NSForegroundColorAttributeName: [UIColor whiteColor] };

    for (int i = 0; i < g_n; i++) {
        EntOut *e = &g_ents[i];
        if (botf && e->is_bot) continue;
        if (teamf && e->team == g_my_team) continue;
        if (e->dist > maxd) continue;

        RVec3 head = e->world;
        head.z += 176.0f;
        Vec2 ph, pf;
        if (!ue4_w2s(&g_ctx, head, &ph)) continue;
        if (!ue4_w2s(&g_ctx, e->world, &pf)) continue;
        CGFloat h = fabsf(pf.y - ph.y);
        if (h < 6.0f) continue;
        CGFloat w = h * 0.42f;
        CGRect box = CGRectMake(ph.x - w * 0.5f, ph.y, w, h);

        BOOL me = (e->team == g_my_team);
        UIColor *c = team_color(e->team, me);

        if (box_on) {
            CGContextSetStrokeColorWithColor(ctx, c.CGColor);
            CGContextSetLineWidth(ctx, th);
            CGContextStrokeRect(ctx, box);
        }
        if (bone_on) {
            Vec2 bp[BONE_N];
            int ok[BONE_N];
            for (int k = 0; k < BONE_N; k++) ok[k] = ue4_w2s(&g_ctx, e->bones[k], &bp[k]);
            CGContextSetStrokeColorWithColor(ctx, c.CGColor);
            CGContextSetLineWidth(ctx, th);
            static const int ln[14][2] = {
                {1,2},{2,9},{2,3},{3,4},{4,5},{2,6},{6,7},
                {7,8},{9,10},{9,11},{10,12},{11,13},{12,14},{13,14}
            };
            for (int k = 0; k < 14; k++) {
                int a = ln[k][0], b = ln[k][1];
                if (!ok[a] || !ok[b]) continue;
                CGContextMoveToPoint(ctx, bp[a].x, bp[a].y);
                CGContextAddLineToPoint(ctx, bp[b].x, bp[b].y);
            }
            CGContextStrokePath(ctx);
            if (ok[0]) {
                CGFloat rr = MAX(2.0f, h * 0.06f);
                CGContextSetFillColorWithColor(ctx, c.CGColor);
                CGContextFillEllipseInRect(ctx,
                    CGRectMake(bp[0].x - rr, bp[0].y - rr, rr * 2, rr * 2));
            }
        }
        if (hp_on && e->hp > 0.0f) {
            CGFloat pct = e->hp / 100.0f;
            if (pct > 1.0f) pct = 1.0f;
            CGRect hb = CGRectMake(box.origin.x - 5, box.origin.y, 3, box.size.height);
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
            CGContextFillRect(ctx, hb);
            CGRect hf = CGRectMake(hb.origin.x,
                                   hb.origin.y + hb.size.height * (1.0f - pct),
                                   hb.size.width,
                                   hb.size.height * pct);
            CGContextSetFillColorWithColor(ctx,
                [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:1.0].CGColor);
            CGContextFillRect(ctx, hf);
        }

        NSString *txt = @"";
        if (nm_on && e->op[0]) {
            const char *nm = (nsrc == 2) ? e->op : op_cn(e->op);
            txt = [NSString stringWithFormat:@"%s", nm];
        }
        if (d_on) {
            NSString *d = [NSString stringWithFormat:@"%.0fm", e->dist];
            txt = txt.length ? [NSString stringWithFormat:@"%@ %@", txt, d] : d;
        }
        if (txt.length) {
            [txt drawAtPoint:CGPointMake(box.origin.x, box.origin.y + box.size.height + 2)
              withAttributes:wa];
        }
    }
}
@end
OX1
cat >> src/tweak/Overlay.xm <<'OX2'

static void make_esp(void) {
    if (g_esp) return;
    CGRect sc = landscape_bounds();
    g_esp = [[UIWindow alloc] initWithFrame:sc];
    g_esp.windowLevel = UIWindowLevelAlert + 400;
    g_esp.backgroundColor = [UIColor clearColor];
    g_esp.userInteractionEnabled = NO;
    if ([g_esp respondsToSelector:@selector(_setSecure:)]) [g_esp _setSecure:YES];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;
    KCDView *v = [[KCDView alloc] initWithFrame:sc];
    v.backgroundColor = [UIColor clearColor];
    v.userInteractionEnabled = NO;
    [vc.view addSubview:v];
    g_esp.rootViewController = vc;
    g_esp.hidden = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *tt) {
        (void)tt;
        [v setNeedsDisplay];
    }];
}

@interface KCDPan : NSObject @end
@implementation KCDPan
+ (instancetype)sh {
    static KCDPan *s;
    if (!s) s = [KCDPan new];
    return s;
}
- (void)pan:(UIPanGestureRecognizer *)p {
    UIView *v = p.view;
    CGPoint d = [p translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [p setTranslation:CGPointZero inView:v.superview];
    if (p.state == UIGestureRecognizerStateEnded) {
        CGRect sc = landscape_bounds();
        int px = (int)(v.center.x / sc.size.width * 100.0);
        int py = (int)(v.center.y / sc.size.height * 100.0);
        NSString *kx = @"nearest_x", *ky = @"nearest_y";
        if (v.tag == 2) { kx = @"back_x";  ky = @"back_y";  }
        if (v.tag == 3) { kx = @"count_x"; ky = @"count_y"; }
        cfg_set(kx, @(px));
        cfg_set(ky, @(py));
    }
}
@end

@interface KCDHudWin : UIWindow @end
@implementation KCDHudWin
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self) return nil;
    if (v == self.rootViewController.view) return nil;
    return v;
}
@end

static UILabel *mklab(CGFloat x, CGFloat y, int tag) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x, y, 640, 30)];
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont boldSystemFontOfSize:13.0 * ui_scale()];
    l.userInteractionEnabled = YES;
    l.tag = tag;
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc]
        initWithTarget:[KCDPan sh] action:@selector(pan:)];
    [l addGestureRecognizer:p];
    return l;
}

static void make_hud(void) {
    if (g_hud) return;
    CGRect sc = landscape_bounds();
    CGFloat W = sc.size.width, H = sc.size.height;
    g_hud = [[KCDHudWin alloc] initWithFrame:sc];
    g_hud.windowLevel = UIWindowLevelAlert + 500;
    g_hud.backgroundColor = [UIColor clearColor];
    g_hud.rootViewController = [[UIViewController alloc] init];
    g_hud.rootViewController.view.backgroundColor = [UIColor clearColor];
    g_hud.hidden = NO;

    g_l1 = mklab(W * cfg_i(@"nearest_x", 5) / 100.0, H * cfg_i(@"nearest_y", 25) / 100.0, 1);
    g_l1.text = @"最近: --";
    [g_hud.rootViewController.view addSubview:g_l1];

    g_l2 = mklab(W * cfg_i(@"back_x", 5) / 100.0, H * cfg_i(@"back_y", 32) / 100.0, 2);
    [g_hud.rootViewController.view addSubview:g_l2];

    g_l3 = mklab(W * cfg_i(@"count_x", 5) / 100.0, H * cfg_i(@"count_y", 39) / 100.0, 3);
    [g_hud.rootViewController.view addSubview:g_l3];

    [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *tt) {
        (void)tt;
        if (!g_l1) return;
        int teams = __builtin_popcount(g_tmask);
        int nsrc = cfg_i(@"name_src", 0);
        const char *nm = (nsrc == 2) ? g_near_op : op_cn(g_near_op);

        if (g_near > 1e8f) {
            g_l1.text = @"最近: --";
        } else if (nm[0]) {
            g_l1.text = [NSString stringWithFormat:@"最近: %.0fm  队%d  朝向 %d  %s",
                         g_near, g_near_team, g_near_yaw, nm];
        } else {
            g_l1.text = [NSString stringWithFormat:@"最近: %.0fm  队%d  朝向 %d",
                         g_near, g_near_team, g_near_yaw];
        }

        if (cfg_b(@"blink_on", YES) && g_near < 15.0f) {
            float a = 0.35f + 0.65f * fabsf(sinf((float)CACurrentMediaTime() * 8.0f));
            g_l1.textColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:a];
        } else {
            g_l1.textColor = [UIColor whiteColor];
        }

        if (!cfg_b(@"back_on", YES)) {
            g_l2.hidden = YES;
        } else if (g_back > 0) {
            g_l2.hidden = NO;
            g_l2.text = [NSString stringWithFormat:@"背敌: %d (%dm内)",
                         g_back, cfg_i(@"back_dist", 40)];
        } else {
            g_l2.hidden = YES;
        }

        if (!cfg_b(@"count_on", YES)) {
            g_l3.hidden = YES;
        } else {
            g_l3.hidden = NO;
            g_l3.text = [NSString stringWithFormat:@"真人: %d / 总: %d  队伍: %d",
                         g_humans, g_n, teams];
        }
    }];
}

static void panel_refresh(void);
static void panel_hide(void);

static NSArray *rows(void) {
    return @[
        @[@"h", @"绘制"],
        @[@"b", @"box_enemy", @"敌人方框"],
        @[@"b", @"skeleton",  @"骨骼线"],
        @[@"b", @"health",    @"血条"],
        @[@"b", @"distance",  @"距离数字"],
        @[@"b", @"op_name",   @"干员名"],
        @[@"h", @"过滤"],
        @[@"b", @"bot_filter",  @"只显示真人"],
        @[@"b", @"team_filter", @"过滤队友"],
        @[@"b", @"back_on",     @"背敌预警"],
        @[@"h", @"物资"],
        @[@"b", @"loot_on",     @"物资透视"],
        @[@"b", @"loot_box",    @"  箱子"],
        @[@"b", @"loot_gun",    @"  枪械"],
        @[@"b", @"loot_bag",    @"  背包"],
        @[@"b", @"loot_ammo",   @"  弹药"],
        @[@"b", @"loot_med",    @"  药品"],
        @[@"b", @"loot_armor",  @"  护甲"],
        @[@"i", @"loot_min",    @"最低品质", @[@3, @4, @5]],
        @[@"i", @"loot_dist",   @"物资距离", @[@50, @100, @150, @200, @300]],
        @[@"h", @"外观"],
        @[@"i", @"text_size",   @"字号",     @[@11, @13, @15, @18, @22]],
        @[@"i", @"thick",       @"框线粗细", @[@1, @2, @3]],
        @[@"i", @"max_dist",    @"最远距离", @[@50, @100, @150, @200, @300, @400, @500]],
        @[@"i", @"name_src",    @"名字来源", @[@"映射", @"游戏", @"英文"]],
        @[@"h", @"其他"],
        @[@"i", @"my_team",     @"我的队伍", @[@0,@1,@2,@3,@4,@5,@6,@7,@8]],
        @[@"i", @"teamid_off",  @"偏移校准", @[@0,@1,@2,@3,@4,@5,@6]],
        @[@"b", @"blink_on",    @"近敌闪烁"],
        @[@"b", @"count_on",    @"人数统计"]
    ];
}

static void panel_build(void) {
    if (g_panel) return;
    CGRect sc = landscape_bounds();
    CGFloat W = MIN(MAX(sc.size.width * 0.42, 340), 620);
    CGFloat H = MIN(sc.size.height - 90, 900);
    g_panel = [[UIWindow alloc] initWithFrame:CGRectMake((sc.size.width - W) / 2,
                                                        (sc.size.height - H) / 2, W, H)];
    g_panel.windowLevel = UIWindowLevelAlert + 1000;
    g_panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.93];
    g_panel.layer.cornerRadius = 14;
    g_panel.layer.masksToBounds = YES;
    g_panel.hidden = YES;
    g_panel.rootViewController = [[UIViewController alloc] init];
    g_panel.rootViewController.view.backgroundColor = [UIColor clearColor];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, W - 100, 28)];
    t.text = @"三角洲透视";
    t.textColor = [UIColor whiteColor];
    t.font = PFSB(16);
    [g_panel.rootViewController.view addSubview:t];

    UIButton *cl = [UIButton buttonWithType:UIButtonTypeSystem];
    cl.frame = CGRectMake(W - 76, 8, 64, 30);
    [cl setTitle:@"关闭" forState:UIControlStateNormal];
    [cl setTitleColor:[UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1]
             forState:UIControlStateNormal];
    [cl addAction:[UIAction actionWithHandler:^(UIAction *a) {
        (void)a;
        panel_hide();
    }] forControlEvents:UIControlEventTouchUpInside];
    [g_panel.rootViewController.view addSubview:cl];

    g_psv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, W, H - 44)];
    [g_panel.rootViewController.view addSubview:g_psv];
}

static void panel_refresh(void) {
    if (!g_panel) return;
    for (UIView *v in g_psv.subviews) [v removeFromSuperview];

    CGFloat PW = g_panel.frame.size.width;
    CGFloat BW = PW - 16;
    CGFloat y = 8;

    for (NSArray *r in rows()) {
        if ([r[0] isEqualToString:@"h"]) {
            UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, y, BW, 22)];
            h.text = r[1];
            h.textColor = [UIColor colorWithWhite:0.6 alpha:1];
            h.font = PFS(13);
            [g_psv addSubview:h];
            y += 26;
            continue;
        }
        NSString *key = r[1];
        NSString *nm  = r[2];
        NSArray *opts = (r.count > 3) ? r[3] : nil;
        id cur = cfg_get(key);
        NSString *val;
        if (opts) {
            val = cur ? [NSString stringWithFormat:@"%@", cur]
                      : [NSString stringWithFormat:@"%@", opts[0]];
        } else {
            val = (cur && [cur boolValue]) ? @"开" : @"关";
        }

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8, y, BW, 36);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        NSMutableString *tt = [NSMutableString stringWithFormat:@"  %@", nm];
        while ([tt length] < 20) [tt appendString:@" "];
        [tt appendString:val];
        [b setTitle:tt forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = PFS(15);
        [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
            (void)a;
            if ([r[0] isEqualToString:@"b"]) {
                cfg_set(key, @(!cfg_b(key, NO)));
            } else if (opts) {
                int cv = cfg_i(key, [opts[0] intValue]);
                NSUInteger i = [opts indexOfObject:@(cv)];
                i = (i == NSNotFound || i + 1 >= opts.count) ? 0 : i + 1;
                cfg_set(key, opts[i]);
            }
            panel_refresh();
        }] forControlEvents:UIControlEventTouchUpInside];
        [g_psv addSubview:b];
        y += 40;
    }

    NSString *kstr;
    UIColor *kcol;
    if (g_kfd_ready) {
        kstr = [NSString stringWithFormat:@"内联:正常 符号:%d XPC:%d",
                kcd_jb_nsym(), kcd_jb_xpc()];
        kcol = [UIColor greenColor];
    } else {
        kstr = @"内联:失败";
        kcol = [UIColor redColor];
    }
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 8, BW, 20)];
    st.text = [NSString stringWithFormat:@"%@ 池:%@ 队:0x%X",
               kstr, g_gnames ? @"正常" : @"无", g_off_teamid];
    st.textColor = kcol;
    st.font = PFS(11);
    [g_psv addSubview:st];
    y += 24;

    NSString *vstr = (g_ctx.ver == 9) ? @"慢扫"
                   : [NSString stringWithFormat:@"预%d", g_ctx.ver];
    UILabel *sr = [[UILabel alloc] initWithFrame:CGRectMake(16, y, BW, 20)];
    sr.text = [NSString stringWithFormat:@"引擎:%@ 反射:%d 分数:%d",
               vstr, g_ctx.reflect_ok, g_ctx.best_score];
    sr.textColor = g_ctx.ready ? [UIColor colorWithRed:0.55 green:0.9 blue:1 alpha:1]
                               : [UIColor orangeColor];
    sr.font = PFS(11);
    [g_psv addSubview:sr];
    y += 24;

    UILabel *lk = [[UILabel alloc] initWithFrame:CGRectMake(16, y, BW, 20)];
    if (g_locked) {
        lk.text = [NSString stringWithFormat:@"锁定:进程 %d", g_game_pid];
        lk.textColor = [UIColor greenColor];
    } else {
        lk.text = @"锁定:未连接";
        lk.textColor = [UIColor orangeColor];
    }
    lk.font = PFS(11);
    [g_psv addSubview:lk];
    y += 32;

    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    rb.frame = CGRectMake(8, y, BW, 40);
    rb.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [rb setTitle:@"  重新连接内核" forState:UIControlStateNormal];
    [rb setTitleColor:[UIColor colorWithRed:1.0 green:0.82 blue:0.3 alpha:1]
             forState:UIControlStateNormal];
    rb.titleLabel.font = PFS(15);
    [rb addAction:[UIAction actionWithHandler:^(UIAction *a) {
        (void)a;
        g_restart = 1;
        panel_hide();
    }] forControlEvents:UIControlEventTouchUpInside];
    [g_psv addSubview:rb];
    y += 44;

    g_psv.contentSize = CGSizeMake(PW, y);
}

static void panel_show(void) {
    panel_build();
    panel_refresh();
    g_panel.hidden = NO;
    g_panel_on = YES;
}
static void panel_hide(void) {
    g_panel.hidden = YES;
    g_panel_on = NO;
}
static void panel_toggle(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_panel_on) panel_hide();
        else panel_show();
    });
}

static LootOut g_loot[MAX_LOOT];
static int     g_loot_n = 0;
static UIWindow *g_lwin = nil;

static UIColor *rar_color(int r) {
    if (r >= 6) return [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1];
    if (r >= 5) return [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1];
    if (r >= 4) return [UIColor colorWithRed:1.0 green:0.55 blue:0.0 alpha:1];
    return [UIColor colorWithRed:0.63 green:0.13 blue:0.94 alpha:1];
}

static const char *type_tag(int t) {
    switch (t) {
        case LT_BOX:   return "箱";
        case LT_GUN:   return "枪";
        case LT_BAG:   return "包";
        case LT_AMMO:  return "弹";
        case LT_MED:   return "药";
        case LT_ARMOR: return "甲";
        default:       return "物";
    }
}

static void *loot_loop(void *arg) {
    (void)arg;
    while (1) {
        if (g_ctx.ready && cfg_b(@"loot_on", YES))
            g_loot_n = ue4_scan_loot(&g_ctx, g_loot, MAX_LOOT);
        else
            g_loot_n = 0;
        usleep(400000);
    }
    return NULL;
}

@interface KCDLootView : UIView @end
@implementation KCDLootView
- (void)drawRect:(CGRect)r {
    (void)r;
    if (!cfg_b(@"loot_on", YES)) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    int minr = cfg_i(@"loot_min", 3);
    int maxd = cfg_i(@"loot_dist", 200);
    int sh_box   = cfg_b(@"loot_box",   YES) ? 1 : 0;
    int sh_gun   = cfg_b(@"loot_gun",   YES) ? 1 : 0;
    int sh_bag   = cfg_b(@"loot_bag",   YES) ? 1 : 0;
    int sh_ammo  = cfg_b(@"loot_ammo",  NO ) ? 1 : 0;
    int sh_med   = cfg_b(@"loot_med",   YES) ? 1 : 0;
    int sh_armor = cfg_b(@"loot_armor", YES) ? 1 : 0;
    CGFloat fs = (CGFloat)cfg_i(@"text_size", 13) * ui_scale() - 3;
    if (fs < 8) fs = 8;
    UIFont *f = [UIFont boldSystemFontOfSize:fs];

    for (int i = 0; i < g_loot_n; i++) {
        LootOut *o = &g_loot[i];
        if (o->rarity < minr) continue;
        if (o->dist > maxd) continue;
        switch (o->type) {
            case LT_BOX:   if (!sh_box)   continue; break;
            case LT_GUN:   if (!sh_gun)   continue; break;
            case LT_BAG:   if (!sh_bag)   continue; break;
            case LT_AMMO:  if (!sh_ammo)  continue; break;
            case LT_MED:   if (!sh_med)   continue; break;
            case LT_ARMOR: if (!sh_armor) continue; break;
            default: break;
        }

        RVec3 top = o->world;
        top.z += 35.0f;
        Vec2 sp, st;
        if (!ue4_w2s(&g_ctx, o->world, &sp)) continue;
        if (!ue4_w2s(&g_ctx, top, &st)) continue;
        CGFloat h = fabsf(st.y - sp.y);
        if (h < 3.5f) h = 10.0f;
        if (h > 90.0f) h = 90.0f;
        CGFloat w = h;
        CGRect box = CGRectMake(sp.x - w * 0.5f, sp.y - h, w, h);

        UIColor *c = rar_color(o->rarity);
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 1.4f);
        CGContextStrokeRect(ctx, box);
        CGContextSetFillColorWithColor(ctx, [c colorWithAlphaComponent:0.15f].CGColor);
        CGContextFillRect(ctx, box);

        if (o->type == LT_MED) {
            CGContextSetLineWidth(ctx, 1.6f);
            CGContextMoveToPoint(ctx, box.origin.x + w * 0.5f, box.origin.y + h * 0.2f);
            CGContextAddLineToPoint(ctx, box.origin.x + w * 0.5f, box.origin.y + h * 0.8f);
            CGContextMoveToPoint(ctx, box.origin.x + w * 0.2f, box.origin.y + h * 0.5f);
            CGContextAddLineToPoint(ctx, box.origin.x + w * 0.8f, box.origin.y + h * 0.5f);
            CGContextStrokePath(ctx);
        }

        NSString *t = [NSString stringWithFormat:@"%s %s %.0fm",
                       type_tag(o->type), loot_cn(o->name), o->dist];
        NSDictionary *wa = @{ NSFontAttributeName: f,
                              NSForegroundColorAttributeName: c };
        [t drawAtPoint:CGPointMake(box.origin.x, box.origin.y - fs - 1)
        withAttributes:wa];
    }
}
@end

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef a);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef c, CFDictionaryRef m);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef c,
                                                        void (*cb)(void *, void *, IOHIDEventRef),
                                                        void *t, void *r);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef c,
                                                      CFRunLoopRef rl, CFStringRef mode);
extern int IOHIDEventGetType(IOHIDEventRef e);
extern int64_t IOHIDEventGetIntegerValue(IOHIDEventRef e, int32_t f);

static BOOL g_vu = NO, g_vd = NO;
static int  g_vtok = 0;

static void hid_cb(void *t, void *r, IOHIDEventRef e) {
    (void)t; (void)r;
    if (IOHIDEventGetType(e) != 3) return;
    int64_t usage = IOHIDEventGetIntegerValue(e, 0x00030000);
    int64_t press = IOHIDEventGetIntegerValue(e, 0x00030002);
    if (usage != 0xE9 && usage != 0xEA) return;

    if (press != 0) {
        if (usage == 0xE9) g_vu = YES; else g_vd = YES;
        if (g_vu && g_vd) {
            g_vtok++;
            int my = g_vtok;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (my == g_vtok && g_vu && g_vd) {
                    g_vu = NO;
                    g_vd = NO;
                    panel_toggle();
                }
            });
        }
    } else {
        if (usage == 0xE9) g_vu = NO; else g_vd = NO;
        g_vtok++;
    }
}

__attribute__((constructor)) static void kcd_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        make_esp();
        make_hud();

        CGRect sc = landscape_bounds();
        g_lwin = [[UIWindow alloc] initWithFrame:sc];
        g_lwin.windowLevel = UIWindowLevelAlert + 450;
        g_lwin.backgroundColor = [UIColor clearColor];
        g_lwin.userInteractionEnabled = NO;
        if ([g_lwin respondsToSelector:@selector(_setSecure:)]) [g_lwin _setSecure:YES];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.userInteractionEnabled = NO;
        KCDLootView *lv = [[KCDLootView alloc] initWithFrame:sc];
        lv.backgroundColor = [UIColor clearColor];
        lv.userInteractionEnabled = NO;
        [vc.view addSubview:lv];
        g_lwin.rootViewController = vc;
        g_lwin.hidden = NO;
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *tt) {
            (void)tt;
            [lv setNeedsDisplay];
        }];

        dispatch_async(dispatch_get_global_queue(0, 0), ^{ scan_loop(NULL); });
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ loot_loop(NULL); });

        IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (c) {
            IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{});
            IOHIDEventSystemClientRegisterEventCallback(c, hid_cb, NULL, NULL);
            IOHIDEventSystemClientScheduleWithRunLoop(c,
                                                      CFRunLoopGetMain(),
                                                      kCFRunLoopDefaultMode);
        }
    });
}
OX2

cat > src/ent.plist <<'E1'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key><true/>
    <key>com.apple.private.security.no-container</key><true/>
    <key>com.apple.private.skip-library-validation</key><true/>
    <key>com.apple.private.hid.client.event-monitor</key><true/>
    <key>get-task-allow</key><true/>
</dict>
</plist>
E1

cat > src/package/DEBIAN/control <<'E2'
Package: com.kcd.deltaforce
Name: KCD
Version: 3.1
Architecture: iphoneos-arm64
Description: readonly esp (libjailbreak / dopamine / ios 15-16)
Maintainer: kcd
Author: kcd
Section: Tweaks
Depends: mobilesubstrate | ellekit
E2

printf '#!/bin/bash\nkillall -9 SpringBoard 2>/dev/null || true\nexit 0\n' \
  > src/package/DEBIAN/postinst
printf '#!/bin/bash\nkillall -9 SpringBoard 2>/dev/null || true\nexit 0\n' \
  > src/package/DEBIAN/prerm
chmod 755 src/package/DEBIAN/postinst src/package/DEBIAN/prerm

cd src

echo "===== COMPILE ====="
SDK="$THEOS/sdks/iPhoneOS16.5.sdk"
TG=arm64e-apple-ios15.0
LDP=$(cat "$TC/ld64_path.txt")

CF="-target $TG -isysroot $SDK -fobjc-arc -w -O1 \
    -include stdint.h -include stddef.h -include stdbool.h -include sys/types.h \
    -Ikcore -Igame"

rm -rf obj release
mkdir -p obj release

echo "  kcore/krw.c"
clang $CF -x objective-c -c kcore/krw.c -o obj/krw.o

echo "  game/ue4.c"
clang $CF -x objective-c -c game/ue4.c -o obj/ue4.o

echo "  tweak/Overlay.xm"
clang $CF -x objective-c -c tweak/Overlay.xm -o obj/Overlay.o

echo "===== LINK ====="
clang -target $TG -isysroot $SDK -dynamiclib \
  -fuse-ld="$LDP" -Wl,-platform_version,ios,15.0,15.0 \
  -o release/libsystem_coreservices.dylib obj/*.o \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -framework CoreGraphics -framework CoreText -framework QuartzCore

echo "===== PACKAGE ====="
rm -rf pkg
mkdir -p pkg/var/jb/Library/MobileSubstrate/DynamicLibraries
cp release/libsystem_coreservices.dylib \
   pkg/var/jb/Library/MobileSubstrate/DynamicLibraries/
printf '{ Filter = { Executables = ( SpringBoard ); }; }\n' \
  > pkg/var/jb/Library/MobileSubstrate/DynamicLibraries/libsystem_coreservices.plist
cp -r package/DEBIAN pkg/DEBIAN
dpkg-deb -b pkg "$ROOT/dist/com.kcd.deltaforce_3.1_iphoneos-arm64.deb"

ls -lh "$ROOT/dist/"
echo "===== DONE ====="
