// Host stand-in for /jci/navi/svcjcinavi.so. The merge shim self-gates on it
// being mapped, and (force_street_name / force_street_name_native) reads
// current_StreetName at a fixed offset from the exported GetServiceInterfaces.
// run.sh links this with --section-start so both land at the FW 74.00.324A
// file offsets (0x19008 / 0xaab98), exercising the real anchor arithmetic.
#include <string.h>

__attribute__((section(".anchor"), used))
int GetServiceInterfaces(void) { return 0; }

__attribute__((section(".streetbuf"), used))
char current_StreetName[255] __attribute__((aligned(8)));

void fake_set_street(const char *s)
{
    strncpy(current_StreetName, s, sizeof(current_StreetName) - 1);
    current_StreetName[sizeof(current_StreetName) - 1] = 0;
}
