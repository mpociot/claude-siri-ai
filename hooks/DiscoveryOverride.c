// macOS 27 development-only discovery override. Loaded explicitly per process.
#include <stdbool.h>
#include <string.h>

extern bool os_variant_has_internal_ui(const char *subsystem);

static bool provider_internal_ui(const char *subsystem) {
    if (subsystem && (subsystem[0] == 0 || strcmp(subsystem, "com.apple.GenerativePartnerService") == 0)) return true;
    return os_variant_has_internal_ui(subsystem);
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_function; const void *old_function; } \
    interpose_##replacement = { (const void *)replacement, (const void *)original };

INTERPOSE(provider_internal_ui, os_variant_has_internal_ui)
