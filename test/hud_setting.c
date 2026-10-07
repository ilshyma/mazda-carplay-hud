// SPDX-License-Identifier: AGPL-3.0-or-later
//
// hud_setting — read (and optionally change) HUD settings in the OEM settings
// registry, through the same public client library the Vehicle Settings menu
// uses. Generalised from gsi_test.c (same plumbing, any setting name).
//
// Usage (on the CMU, as root):
//   hud_setting                      # read every known HUD setting
//   hud_setting StreetInformation    # read one
//   hud_setting StreetInformation 2  # set it to 2, then read it back
//
// Reading changes nothing. A set PERSISTS in the registry; note the old value
// printed first so it can be restored. Settings with no
// SETTINGS_Client_Get_<name> export are reported as unsupported.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char *kClientLib = "/jci/lib/libjcisettings_client.so";

typedef int  (*connect_fn)(const char *name,
                           void (*on_connect)(int status),
                           void (*on_disconnect)(int status));
typedef int  (*disconnect_fn)(void);
typedef int  (*set_short_fn)(short value, void (*cb)(short value, int status));
typedef int  (*get_fn)(void (*cb)(short value, int status));

// The OEM convention: callback status 100 (0x64) == success/OK.
#define JCI_OK 100

// ---- async plumbing ------------------------------------------------
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cv  = PTHREAD_COND_INITIALIZER;

static int   g_conn_done = 0, g_conn_status = 0;
static int   g_get_done  = 0, g_get_status  = 0;
static short g_get_value  = 0;
static int   g_set_done  = 0, g_set_status  = 0;
static short g_set_value  = 0;

static void on_connect(int status)
{
    printf("[cb] connect    status=%d\n", status);
    pthread_mutex_lock(&g_mtx);
    g_conn_status = status; g_conn_done = 1;
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mtx);
}

static void on_disconnect(int status)
{
    printf("[cb] disconnect status=%d\n", status);
}

static void on_get(short value, int status)
{
    pthread_mutex_lock(&g_mtx);
    g_get_value = value; g_get_status = status; g_get_done = 1;
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mtx);
}

static void on_set(short value, int status)
{
    printf("[cb] set        value=%d status=%d\n", (int)value, status);
    pthread_mutex_lock(&g_mtx);
    g_set_value = value; g_set_status = status; g_set_done = 1;
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mtx);
}

// Wait until *done becomes non-zero, or timeout_ms elapses.
// Returns 0 if the callback fired, -1 on timeout.
static int wait_done(volatile int *done, int timeout_ms)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec  += timeout_ms / 1000;
    ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }

    int rc = 0;
    pthread_mutex_lock(&g_mtx);
    while (!*done && rc == 0) {
        rc = pthread_cond_timedwait(&g_cv, &g_mtx, &ts);
    }
    int fired = *done;
    pthread_mutex_unlock(&g_mtx);
    return fired ? 0 : -1;
}

static const char *const kDefaultNames[] = {
    "StreetInformation", "CHudNavigation", "NavigationSignal", "GearShiftIndicator",
    "SpeedSignHUD", "SpeedLimitDisplayCHUD", "SpeedLimitCautionCHUD", "Hud_Type",
    "TSR_Feature_Mode", "TSR_Feature_Status",
};

static void *g_lib;

static int read_one(const char *name)
{
    char sym[128];
    snprintf(sym, sizeof(sym), "SETTINGS_Client_Get_%s", name);
    get_fn Get = (get_fn)dlsym(g_lib, sym);
    if (!Get) {
        printf("%-24s (no %s)\n", name, sym);
        return -1;
    }
    g_get_done = 0;
    Get(on_get);
    if (wait_done(&g_get_done, 5000) != 0) {
        printf("%-24s get timed out\n", name);
        return -1;
    }
    printf("%-24s = %d   (status %d%s)\n", name, (int)g_get_value, g_get_status,
           g_get_status == JCI_OK ? " OK" : "");
    return 0;
}

int main(int argc, char **argv)
{
    if (!getenv("JCI_HMI_BUS"))     setenv("JCI_HMI_BUS", "unix:path=/tmp/dbus_hmi_socket", 0);
    if (!getenv("JCI_SERVICE_BUS")) setenv("JCI_SERVICE_BUS", "unix:path=/tmp/dbus_service_socket", 0);

    // libjcisettings_client.so needs libjcidbus.so already in the global scope
    // (it imports JCIDBUS_* without a NEEDED entry) — see gsi_test.c.
    if (!dlopen("/jci/lib/libjcidbus.so", RTLD_NOW | RTLD_GLOBAL))
        fprintf(stderr, "warning: dlopen(libjcidbus.so) failed: %s\n", dlerror());
    g_lib = dlopen(kClientLib, RTLD_NOW | RTLD_GLOBAL);
    if (!g_lib) { fprintf(stderr, "dlopen(%s) failed: %s\n", kClientLib, dlerror()); return 1; }

    connect_fn    Connect    = (connect_fn)   dlsym(g_lib, "BLM_SETTINGS_Client_Connect");
    disconnect_fn Disconnect = (disconnect_fn)dlsym(g_lib, "BLM_SETTINGS_Client_Disconnect");
    if (!Connect) { fprintf(stderr, "dlsym(BLM_SETTINGS_Client_Connect) failed\n"); return 1; }

    // Must be a valid dotted D-Bus name (see gsi_test.c).
    int rc = Connect("com.jci.hudsettingtool", on_connect, on_disconnect);
    if (wait_done(&g_conn_done, 5000) != 0) {
        fprintf(stderr, "TIMEOUT connecting to com.jci.settings (rc=%d)\n", rc);
        return 2;
    }

    int ret = 0;
    if (argc < 2) {
        for (size_t i = 0; i < sizeof(kDefaultNames) / sizeof(kDefaultNames[0]); ++i)
            read_one(kDefaultNames[i]);
    } else {
        const char *name = argv[1];
        if (read_one(name) != 0) ret = 1;
        if (ret == 0 && argc >= 3) {
            char sym[128];
            snprintf(sym, sizeof(sym), "SETTINGS_Client_Set_%s", name);
            set_short_fn Set = (set_short_fn)dlsym(g_lib, sym);
            if (!Set) {
                printf("no %s — cannot set\n", sym);
                ret = 1;
            } else {
                short v = (short)atoi(argv[2]);
                g_set_done = 0;
                printf("setting %s = %d ...\n", name, (int)v);
                Set(v, on_set);
                if (wait_done(&g_set_done, 5000) == 0)
                    printf("set status=%d (%s)\n", g_set_status, g_set_status == JCI_OK ? "OK" : "NOT OK");
                else
                    printf("set timed out\n");
                read_one(name);
            }
        }
    }
    if (Disconnect) Disconnect();
    return ret;
}
