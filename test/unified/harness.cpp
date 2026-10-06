// Host integration test for the CarPlay <-> svcjcinavi hand-off.
//
// One process plays both sides of the real system:
//   * the main thread is svcjcinavi: it calls the (merge-shim-interposed)
//     VBS_NAVI_SetHUDDisplayMsgReq / Msg2 exactly like thUpdateGuidanceChangeToHUD;
//   * the real CarPlay sender (hud_send.cpp) runs its own thread and writes the
//     fake libjcivbsnaviclient directly, like jciCARPLAY does.
// The fake library records every frame that would reach the HUD, tagged with
// its source, and the scenarios below assert on that timeline.
//
//   ./harness coop     merge shim present (OEM speed shared, OEM frames muted)
//   ./harness legacy   no merge shim; legacy /data_persist/splim reader
//   ./harness street   force_street_name(+_native) = true in libpatch.conf
//   ./harness street_off   same frames, both keys false (stock blanking kept)

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "blmjcicarplay/hud/hud_send.h"
#include "common/oem/vbs_navi_hud.h"

// --- CarPlay shim glue (normally main.cpp / nav.cpp) ----------------------
bool g_enabled = true;
FILE *g_logf = nullptr;
extern "C" void nav_request_reset(void) {}
void hud_send_start(void);
void hud_send_stop(void);
void hud_request_clear(void);
void hud_request_fullclear(void);
void hud_request_yield(void);

// --- fake VBS recorder ------------------------------------------------------
struct Rec { int src; int kind; uint32_t man; uint16_t speed; uint8_t sunit; char street[48]; };
enum { SRC_OEM = 0, SRC_CP = 1 };
enum { K_DISP = 0, K_MSG2 = 1 };
extern "C" void fake_set_main_thread(void);
extern "C" int  fake_count(void);
extern "C" int  fake_get(int i, Rec *out);

// svcjcinavi's view: the merge shim's exported definitions (interposed first).
extern "C" int VBS_NAVI_SetHUDDisplayMsgReq(void *, VbsNaviHudDisplay *, void *, void *, void *);
extern "C" int VBS_NAVI_TMC_SetHUD_Display_Msg2(void *, VbsNaviHudMsg2 *, void *, void *, void *);

static int g_fail = 0;
#define CHECK(cond, ...) do { if (cond) { printf("  ok   "); } else { printf("  FAIL "); g_fail++; } \
                              printf(__VA_ARGS__); printf("\n"); } while (0)

static void oem_frame(uint32_t man, uint16_t speed, uint8_t unit, const char *street)
{
    VbsNaviHudDisplay d = {};
    d.nextManeuverInfo = man; d.displaySpeedLimit = speed; d.displaySpeedUnit = unit;
    VbsNaviHudMsg2 m = { street, 1 };
    VBS_NAVI_SetHUDDisplayMsgReq(nullptr, &d, nullptr, nullptr, nullptr);
    VBS_NAVI_TMC_SetHUD_Display_Msg2(nullptr, &m, nullptr, nullptr, nullptr);
}

static void aa_frame(uint32_t man, const char *street)   // svcnavi transport: sentinel speed
{
    VbsNaviHudDisplay d = {};
    d.nextManeuverInfo = man; d.displaySpeedLimit = kAapSpeedSentinel;
    VbsNaviHudMsg2 m = { street, 2 };
    VBS_NAVI_SetHUDDisplayMsgReq(nullptr, &d, nullptr, nullptr, nullptr);
    VBS_NAVI_TMC_SetHUD_Display_Msg2(nullptr, &m, nullptr, nullptr, nullptr);
}

static void cp_route(const char *street)
{
    hud_on_status(1);
    hud_on_next_turn(street, /*side RIGHT*/2, /*TURN_TURN*/4, 90, 0);
    hud_on_distance(300, 20, 300 * 1000, /*METERS*/1);
}

struct Stats { int oem_disp, cp_disp, cp_live, cp_blank; uint16_t last_cp_speed; uint8_t last_cp_unit;
               uint32_t last_oem_man; uint16_t last_oem_speed; };

static Stats stats_since(int from)
{
    Stats s = {};
    Rec r;
    for (int i = from; fake_get(i, &r); ++i) {
        if (r.kind != K_DISP) continue;
        if (r.src == SRC_OEM) { s.oem_disp++; s.last_oem_man = r.man; s.last_oem_speed = r.speed; }
        else {
            s.cp_disp++;
            if (r.man) s.cp_live++; else s.cp_blank++;
            s.last_cp_speed = r.speed; s.last_cp_unit = r.sunit;
        }
    }
    return s;
}

static void (*g_set_oem_street)(const char *) = nullptr;

// Street of the last OEM-sourced Msg2 (i.e. what svcjcinavi let reach the HUD).
static bool last_oem_street(int from, char *out, size_t n)
{
    Rec r; bool found = false;
    for (int i = from; fake_get(i, &r); ++i)
        if (r.kind == K_MSG2 && r.src == SRC_OEM) { snprintf(out, n, "%s", r.street); found = true; }
    return found;
}

// svcjcinavi has stored `received` in current_StreetName but, EU-style,
// blanked the outbound strip to " ".
static void oem_frame_eu(uint32_t man, uint16_t speed, const char *received)
{
    g_set_oem_street(received);
    oem_frame(man, speed, 3, " ");
}

static int street(bool on)
{
    char got[64];
    printf("[S1] stock-nav route frame, EU-blanked strip\n");
    int mark = fake_count();
    oem_frame_eu(3, 50, "Oboronna vulytsia");
    last_oem_street(mark, got, sizeof(got));
    if (on) CHECK(strcmp(got, "Oboronna vulytsia") == 0, "native street un-blanked (\"%s\")", got);
    else    CHECK(strcmp(got, " ") == 0, "stock blanking kept with the keys off (\"%s\")", got);

    printf("[S2] stock-nav speed-only frame (no route)\n");
    mark = fake_count();
    oem_frame_eu(0, 50, "Oboronna vulytsia");
    last_oem_street(mark, got, sizeof(got));
    CHECK(strcmp(got, " ") == 0, "no stale street without a maneuver (\"%s\")", got);

    printf("[S3] Android Auto frame + OEM-cadence frame\n");
    mark = fake_count();
    g_set_oem_street("Hrushevskoho");
    aa_frame(5, " ");                       // EU-blanked AA strip
    last_oem_street(mark, got, sizeof(got));
    if (on) CHECK(strcmp(got, "Hrushevskoho") == 0, "AA street un-blanked (\"%s\")", got);
    else    CHECK(strcmp(got, " ") == 0, "AA street stays blank with the keys off (\"%s\")", got);
    mark = fake_count();
    oem_frame_eu(0, 60, "");
    last_oem_street(mark, got, sizeof(got));
    if (on) CHECK(strcmp(got, "Hrushevskoho") == 0, "OEM-cadence frame repeats AA street (\"%s\")", got);
    aa_frame(0, "");
    return g_fail;
}

static bool file_exists(const char *p) { return access(p, F_OK) == 0; }

static void read_file(const char *p, char *buf, size_t n)
{
    buf[0] = 0;
    FILE *f = fopen(p, "r");
    if (!f) return;
    size_t k = fread(buf, 1, n - 1, f);
    buf[k] = 0;
    fclose(f);
    char *nl = strchr(buf, '\n'); if (nl) *nl = 0;
}

static int coop()
{
    char buf[64];
    unlink("/tmp/hud_oem_speed");
    unlink("/tmp/hud_carplay_active");

    printf("[1] OEM nav alone (no projection)\n");
    int mark = fake_count();
    oem_frame(0, 50, 3, " ");
    Stats s = stats_since(mark);
    read_file("/tmp/hud_oem_speed", buf, sizeof(buf));
    CHECK(s.oem_disp == 1 && s.last_oem_speed == 50, "OEM speed frame passes through (speed=%u)", s.last_oem_speed);
    CHECK(strcmp(buf, "50 3") == 0, "merge shim published OEM speed \"%s\"", buf);

    printf("[2] CarPlay connects, no route yet\n");
    mark = fake_count();
    hud_send_start();
    usleep(1500 * 1000);
    s = stats_since(mark);
    CHECK(s.cp_live == 0 && s.cp_blank == 1, "one startup frame only, blank maneuver (blank=%d live=%d)", s.cp_blank, s.cp_live);
    CHECK(s.last_cp_speed == 50 && s.last_cp_unit == 3, "startup frame keeps OEM limit 50/unit 3 (got %u/%u)", s.last_cp_speed, s.last_cp_unit);
    CHECK(!file_exists("/tmp/hud_carplay_active"), "CarPlay does not claim the HUD without a route");

    printf("[3] CarPlay route active\n");
    mark = fake_count();
    cp_route("Khreshchatyk");
    usleep(1300 * 1000);
    s = stats_since(mark);
    CHECK(s.cp_live >= 2, "CarPlay maneuver frames + ~2 Hz keepalive (%d)", s.cp_live);
    CHECK(s.last_cp_speed == 50 && s.last_cp_unit == 3, "CarPlay frames carry OEM limit 50/unit 3 (got %u/%u)", s.last_cp_speed, s.last_cp_unit);
    CHECK(file_exists("/tmp/hud_carplay_active"), "CarPlay-active marker present");

    printf("[4] OEM sends a new limit while CarPlay guides\n");
    mark = fake_count();
    oem_frame(0, 60, 3, " ");
    usleep(1200 * 1000);
    s = stats_since(mark);
    CHECK(s.oem_disp == 0, "blank-maneuver OEM frame was dropped (oem frames=%d)", s.oem_disp);
    CHECK(s.last_cp_speed == 60, "CarPlay picked up the new OEM limit (%u)", s.last_cp_speed);
    {
        Rec r; bool street_leak = false;
        for (int i = mark; fake_get(i, &r); ++i) if (r.kind == K_MSG2 && r.src == SRC_OEM) street_leak = true;
        CHECK(!street_leak, "OEM street strip was dropped with its frame");
    }

    printf("[5] CarPlay route ends (phone still connected)\n");
    hud_on_status(2);
    usleep(700 * 1000);
    mark = fake_count();
    usleep(1500 * 1000);
    s = stats_since(mark);
    CHECK(!file_exists("/tmp/hud_carplay_active"), "marker removed on hand-back");
    CHECK(s.cp_disp == 0, "CarPlay silent after hand-back (%d frames)", s.cp_disp);
    mark = fake_count();
    oem_frame(0, 70, 3, " ");
    s = stats_since(mark);
    CHECK(s.oem_disp == 1 && s.last_oem_speed == 70, "OEM frames flow again (speed=%u)", s.last_oem_speed);

    printf("[6] Android Auto (svcnavi) after CarPlay: OEM speed spliced, CarPlay quiet\n");
    mark = fake_count();
    aa_frame(5, "Hrushevskoho");
    oem_frame(0, 80, 3, " ");
    usleep(1200 * 1000);
    s = stats_since(mark);
    CHECK(s.cp_disp == 0, "no CarPlay frames under Android Auto (%d)", s.cp_disp);
    CHECK(s.oem_disp == 2 && s.last_oem_man == 5 && s.last_oem_speed == 80,
          "AA maneuver kept on the OEM-cadence frame with OEM speed (man=%u speed=%u)", s.last_oem_man, s.last_oem_speed);
    aa_frame(0, "");   // AA guidance stops -> releases ownership

    printf("[7] CarPlay route again, then phone unplugged\n");
    cp_route("Velyka Vasylkivska");
    usleep(1200 * 1000);
    CHECK(file_exists("/tmp/hud_carplay_active"), "CarPlay re-claims the HUD");
    hud_request_fullclear();
    usleep(700 * 1000);
    mark = fake_count();
    oem_frame(0, 90, 3, " ");
    usleep(1500 * 1000);
    s = stats_since(mark);
    CHECK(!file_exists("/tmp/hud_carplay_active"), "marker removed on session end");
    CHECK(s.cp_disp == 0 && s.oem_disp == 1 && s.last_oem_speed == 90, "OEM owns HUD again, CarPlay silent (cp=%d oem=%d)", s.cp_disp, s.oem_disp);

    printf("[8] CarPlay process dies while guiding (marker goes stale)\n");
    cp_route("Antonovycha");
    usleep(1200 * 1000);
    hud_send_stop();   // stands in for the process going away
    // A crash would skip teardown; emulate the leftover marker it would leave.
    {
        char ts[32]; snprintf(ts, sizeof(ts), "%ld\n", (long)time(nullptr));
        FILE *f = fopen("/tmp/hud_carplay_active", "w"); fputs(ts, f); fclose(f);
    }
    mark = fake_count();
    oem_frame(0, 100, 3, " ");
    s = stats_since(mark);
    CHECK(s.oem_disp == 0, "fresh marker still mutes OEM");
    sleep(4);
    mark = fake_count();
    oem_frame(0, 110, 3, " ");
    s = stats_since(mark);
    CHECK(s.oem_disp == 1, "after TTL the OEM frames flow again");
    return g_fail;
}

static int legacy()
{
    unlink("/tmp/hud_oem_speed");
    unlink("/tmp/hud_carplay_active");
    if (system("mkdir -p /data_persist") != 0) return 1;

    // Fresh legacy splim file kept alive by a background "bridge".
    auto write_splim = [](int v) {
        FILE *f = fopen("/data_persist/splim", "w");
        fprintf(f, "%d %ld\n", v, (long)time(nullptr)); fclose(f);
    };

    printf("[L1] legacy: CarPlay route with bridge speed\n");
    write_splim(50);
    int mark = fake_count();
    hud_send_start();
    cp_route("Main");
    usleep(1300 * 1000);
    Stats s = stats_since(mark);
    CHECK(s.cp_live >= 2 && s.last_cp_speed == 50 && s.last_cp_unit == 2,
          "maneuver + legacy limit 50, unit 2 (km/h) (live=%d %u/%u)", s.cp_live, s.last_cp_speed, s.last_cp_unit);
    CHECK(!file_exists("/tmp/hud_carplay_active"), "no CarPlay-active marker without the merge shim");

    printf("[L2] legacy: route ends -> sign keepalive while CarPlay connected (unchanged behaviour)\n");
    hud_on_status(2);
    usleep(600 * 1000);
    write_splim(50);
    mark = fake_count();
    usleep(1200 * 1000);
    s = stats_since(mark);
    CHECK(s.cp_disp >= 2 && s.cp_live == 0 && s.last_cp_speed == 50, "blank maneuver + sign keepalive (%d)", s.cp_disp);

    printf("[L3] legacy: phone unplugged -> no more repaint even though splim stays fresh\n");
    hud_request_fullclear();
    usleep(600 * 1000);
    write_splim(60);
    mark = fake_count();
    usleep(600 * 1000);
    write_splim(60);
    usleep(900 * 1000);
    s = stats_since(mark);
    CHECK(s.cp_disp == 0, "CarPlay silent after session end (%d frames; was the AA/stock-nav flicker bug)", s.cp_disp);

    printf("[L4] legacy: native nav takes TBT -> CarPlay yields\n");
    cp_route("Main");
    write_splim(60);
    usleep(800 * 1000);
    hud_request_clear();
    hud_request_yield();
    usleep(600 * 1000);
    write_splim(60);
    mark = fake_count();
    usleep(1200 * 1000);
    s = stats_since(mark);
    CHECK(s.cp_disp == 0, "no keepalive under the stock nav (%d frames)", s.cp_disp);
    hud_send_stop();
    return g_fail;
}

int main(int argc, char **argv)
{
    fake_set_main_thread();
    // The merge shim self-gates on svcjcinavi.so being mapped in-process.
    void *nav = dlopen("/jci/navi/svcjcinavi.so", RTLD_NOW | RTLD_GLOBAL);
    if (!nav) {
        fprintf(stderr, "dlopen fake svcjcinavi failed: %s\n", dlerror());
        return 2;
    }
    g_set_oem_street = reinterpret_cast<void (*)(const char *)>(dlsym(nav, "fake_set_street"));
    const char *mode = argc > 1 ? argv[1] : "coop";
    int fails = strcmp(mode, "legacy") == 0     ? legacy()
              : strcmp(mode, "street") == 0     ? street(true)
              : strcmp(mode, "street_off") == 0 ? street(false)
              : coop();
    printf(fails ? "\n%s: %d FAILED\n" : "\n%s: all passed\n", mode, fails);
    return fails ? 1 : 0;
}
