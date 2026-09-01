//
//  SAPUnicornShim.h
//  ipaverse
//
//  Swift cannot call variadic C functions (Xcode marks them
//  `unavailable` when imported) — `uc_hook_add` is declared with a
//  trailing `...` in unicorn.h because its variadic argument depends on
//  the hook `type`. This wraps the one case ipaverse actually uses
//  (UC_HOOK_CODE, which takes no variadic arguments at all) behind a
//  plain, non-variadic C function that Swift can call directly.
//

#ifndef SAPUnicornShim_h
#define SAPUnicornShim_h

#include <unicorn/unicorn.h>

static inline uc_err sap_uc_hook_add_code(uc_engine *uc, uc_hook *hh, void *callback, void *user_data, uint64_t begin, uint64_t end) {
    return uc_hook_add(uc, hh, UC_HOOK_CODE, callback, user_data, begin, end);
}

#endif /* SAPUnicornShim_h */
