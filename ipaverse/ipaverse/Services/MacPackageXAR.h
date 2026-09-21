#ifndef MacPackageXAR_h
#define MacPackageXAR_h

#include <xar/xar.h>

// Apple's downloaded installer packages use XAR. Keep libxar's checksum
// verification for reading those packages; we do not create new XAR archives.
// Isolate the deprecated API here rather than disabling warnings project-wide.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline xar_t ipaverse_xar_open_read(const char *path) {
    return xar_open(path, READ);
}
#pragma clang diagnostic pop

#endif
