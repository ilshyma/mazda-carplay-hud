// Host stand-in for /jci/lib/libjcivbsnaviclient.so: records every HUD frame.
// The thread that sends tells the source apart: the harness main thread plays
// svcjcinavi (frames go through the merge shim first), any other thread is the
// CarPlay sender (direct VBS, like the real jciCARPLAY process).
#include <pthread.h>
#include <stdint.h>
#include <string.h>

struct Disp { uint32_t man; uint16_t dist; uint8_t dunit; uint16_t speed; uint8_t sunit; uint8_t sync; };
struct Msg2 { const char *street; uint8_t sync; };

typedef struct { int src; int kind; uint32_t man; uint16_t speed; uint8_t sunit; char street[48]; } Rec;
enum { SRC_OEM = 0, SRC_CP = 1 };
enum { K_DISP = 0, K_MSG2 = 1 };

static Rec g_rec[4096];
static int g_n;
static pthread_t g_main;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

void fake_set_main_thread(void) { g_main = pthread_self(); }
int  fake_count(void) { pthread_mutex_lock(&g_mu); int n = g_n; pthread_mutex_unlock(&g_mu); return n; }
int  fake_get(int i, Rec *out) { pthread_mutex_lock(&g_mu); int ok = i < g_n; if (ok) *out = g_rec[i]; pthread_mutex_unlock(&g_mu); return ok; }

static void push(int kind, uint32_t man, uint16_t sp, uint8_t su, const char *st)
{
    pthread_mutex_lock(&g_mu);
    if (g_n < 4096) {
        Rec *r = &g_rec[g_n++];
        r->src = pthread_equal(pthread_self(), g_main) ? SRC_OEM : SRC_CP;
        r->kind = kind; r->man = man; r->speed = sp; r->sunit = su;
        strncpy(r->street, st ? st : "", sizeof(r->street) - 1);
        r->street[sizeof(r->street) - 1] = 0;
    }
    pthread_mutex_unlock(&g_mu);
}

int VBS_NAVI_SetHUDDisplayMsgReq(void *c, struct Disp *d, void *u, void *cb, void *ud)
{ (void)c; (void)u; (void)cb; (void)ud; push(K_DISP, d->man, d->speed, d->sunit, 0); return 0; }
int VBS_NAVI_TMC_SetHUD_Display_Msg2(void *c, struct Msg2 *m, void *u, void *cb, void *ud)
{ (void)c; (void)u; (void)cb; (void)ud; push(K_MSG2, 0, 0, 0, m->street); return 0; }
int VBS_NAVI_GetHUDStatus(void *c, void *cb, void *ud)
{ ((void (*)(void *, unsigned char, void *))cb)(c, 1, ud); return 0; }
