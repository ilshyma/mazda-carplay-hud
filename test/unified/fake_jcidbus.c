// Host stand-in for libjcidbus.so (connection lifecycle only).
static int g_conn;
void *JCIDBUS_conn_create(void *cb, int r) { (void)cb; (void)r; return &g_conn; }
int   JCIDBUS_conn_connect(void *c, const char *n, int b, void *r) { (void)c; (void)n; (void)b; (void)r; return 1; }
int   JCIDBUS_worker_start(void *c) { (void)c; return 0; }
void  JCIDBUS_worker_stop(void *c) { (void)c; }
void  JCIDBUS_conn_disconnect(void *c) { (void)c; }
void  JCIDBUS_conn_free(void *c) { (void)c; }
