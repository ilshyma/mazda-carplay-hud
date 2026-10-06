// Host stand-in for /jci/navi/svcjcinavi.so: only its presence matters
// (the merge shim's self-gate dlopen(RTLD_NOLOAD)s it).
int GetServiceInterfaces(void) { return 0; }
