// Edge cases of the CarPlay <-> svcjcinavi side channel (common/hud_share.h).
// Runs in a throwaway container (see run.sh): it writes the real /tmp paths.
//
//   ./hud_share_test            as root
//   ./hud_share_test nonroot    as an unprivileged user, /tmp files owned by root
//   ./hud_share_test full       /tmp is a full tmpfs

#include "common/hud_share.h"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>

static int g_fail = 0;
#define CHECK(cond, ...) do { if (cond) { printf("  ok   "); } else { printf("  FAIL "); g_fail++; } \
                              printf(__VA_ARGS__); printf("\n"); } while (0)

static void put(const char *path, const char *text)
{
    unlink(path);
    FILE *f = fopen(path, "w");
    if (f) { fputs(text, f); fclose(f); }
}

static bool read_speed(uint16_t *l, uint8_t *u) { return hud_share::read_oem_speed(l, u); }

static int leftover_temp_files()
{
    int n = 0;
    DIR *d = opendir("/tmp");
    struct dirent *e;
    while (d && (e = readdir(d)))
        if (strncmp(e->d_name, "hud_oem_speed.", 14) == 0 ||
            strncmp(e->d_name, "hud_carplay_active.", 19) == 0) n++;
    if (d) closedir(d);
    return n;
}

static void speed_file()
{
    uint16_t l = 0; uint8_t u = 0;
    printf("[H1] OEM speed file round-trip and bad contents\n");
    CHECK(hud_share::publish_oem_speed(50, 3) && read_speed(&l, &u) && l == 50 && u == 3, "50/3 round-trip");
    CHECK(hud_share::publish_oem_speed(0, 0) && read_speed(&l, &u) && l == 0 && u == 0, "0/0 (no limit) still means merge shim present");
    CHECK(hud_share::publish_oem_speed(65535, 255) && read_speed(&l, &u) && l == 65535 && u == 255, "max values");

    struct { const char *text; const char *what; } bad[] = {
        { "",               "empty file" },
        { "abc def\n",      "garbage" },
        { "50\n",           "missing unit" },
        { "70000 3\n",      "limit > uint16" },
        { "50 300\n",       "unit > uint8" },
        { "-1 3\n",         "negative limit" },
        { "50 -3\n",        "negative unit" },
        { "99999999999999999999 3\n", "overflowing digits" },
        { "50 3 junk\n",    "trailing junk" },
    };
    for (auto &b : bad) {
        put(hud_share::kOemSpeedFile, b.text);
        l = 7; u = 7;
        bool ok = read_speed(&l, &u);
        CHECK(!ok && l == 7 && u == 7, "rejected: %s", b.what);
    }

    // A 1 MB file of digits: only a small prefix is read, never trusted.
    {
        FILE *f = fopen(hud_share::kOemSpeedFile, "w");
        for (int i = 0; i < (1 << 20); ++i) fputc('1', f);
        fclose(f);
        CHECK(!read_speed(&l, &u), "rejected: 1 MB of digits");
    }

    printf("[H2] symlinks\n");
    put("/tmp/victim", "untouched\n");
    unlink(hud_share::kOemSpeedFile);
    symlink("/tmp/victim", hud_share::kOemSpeedFile);
    CHECK(!read_speed(&l, &u), "reader does not follow a symlink");
    CHECK(hud_share::publish_oem_speed(60, 3), "writer replaces the symlink");
    struct stat st;
    lstat(hud_share::kOemSpeedFile, &st);
    char buf[32] = {0};
    FILE *v = fopen("/tmp/victim", "r"); fgets(buf, sizeof buf, v); fclose(v);
    CHECK(S_ISREG(st.st_mode) && strcmp(buf, "untouched\n") == 0, "symlink target untouched, path is a regular file");

    // A planted symlink at our private temp name is removed, not followed.
    char tmpname[96];
    snprintf(tmpname, sizeof tmpname, "%s.%d", hud_share::kOemSpeedFile, (int)getpid());
    symlink("/tmp/victim", tmpname);
    CHECK(hud_share::publish_oem_speed(70, 3) && read_speed(&l, &u) && l == 70, "planted temp-name symlink ignored");
    v = fopen("/tmp/victim", "r"); fgets(buf, sizeof buf, v); fclose(v);
    CHECK(strcmp(buf, "untouched\n") == 0, "victim still untouched");
    CHECK(leftover_temp_files() == 0, "no temp files left behind");
}

static void marker()
{
    const time_t now = 1790000000;   // ~2026
    printf("[H3] CarPlay-active marker freshness\n");
    hud_share::carplay_mark_active(now);
    CHECK(hud_share::carplay_is_active(now), "fresh");
    CHECK(hud_share::carplay_is_active(now + 3), "3 s old: still active (TTL)");
    CHECK(!hud_share::carplay_is_active(now + 4), "4 s old: stale");
    CHECK(hud_share::carplay_is_active(now - 2), "2 s in the future: tolerated");
    CHECK(!hud_share::carplay_is_active(now - 3), "3 s in the future: stale");

    printf("[H4] clock jumps (CMU boots at 1970, GPS sets 2026 later)\n");
    hud_share::carplay_mark_active(100);                 // written before the GPS fix
    CHECK(!hud_share::carplay_is_active(now), "forward jump: old marker stops muting OEM");
    hud_share::carplay_mark_active(now);                 // written after the fix
    CHECK(!hud_share::carplay_is_active(100), "backward jump: future marker stops muting OEM");

    printf("[H5] bad marker contents\n");
    const char *bad[] = { "", "garbage\n", "-5\n", "99999999999999999999999\n" };
    for (const char *b : bad) {
        put(hud_share::kCarplayActiveFile, b);
        CHECK(!hud_share::carplay_is_active(now), "inactive for \"%.12s\"", b);
    }
    hud_share::carplay_mark_inactive();
    CHECK(!hud_share::carplay_is_active(now), "removed -> inactive");
    hud_share::carplay_mark_inactive();
    CHECK(true, "double remove is harmless");
}

// /tmp files exist and belong to root; we are not root (sticky /tmp).
static void nonroot()
{
    uint16_t l = 0; uint8_t u = 0;
    printf("[H6] unprivileged writer, root-owned files in sticky /tmp\n");
    CHECK(!hud_share::publish_oem_speed(80, 3), "publish fails cleanly");
    CHECK(read_speed(&l, &u) && l == 50, "previous value still readable (%u)", l);
    hud_share::carplay_mark_active(1790000000);          // must fail quietly, not crash
    CHECK(leftover_temp_files() == 0, "no temp files left behind");
}

static void full()
{
    uint16_t l = 0; uint8_t u = 0;
    printf("[H7] /tmp full (ENOSPC)\n");
    bool ok = hud_share::publish_oem_speed(90, 3);
    CHECK(!ok, "publish reports failure");
    CHECK(!read_speed(&l, &u) || l != 90, "no torn or half-written value");
    CHECK(leftover_temp_files() == 0, "no temp files left behind");
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "";
    if (strcmp(mode, "nonroot") == 0) nonroot();
    else if (strcmp(mode, "full") == 0) full();
    else { speed_file(); marker(); }
    printf(g_fail ? "%d FAILED\n" : "all passed\n", g_fail);
    return g_fail ? 1 : 0;
}
