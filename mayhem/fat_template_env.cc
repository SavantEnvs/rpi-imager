// The FAT harnesses (fuzz_fatdir, fuzz_parttable) read their FAT32 template from $FUZZ_FAT_TEMPLATE, or
// from ./template.img when unset. Point them at the template build.sh generates, before
// LLVMFuzzerInitialize runs, so the binary works from any working directory without Mayhemfile env.
#include <cstdlib>

__attribute__((constructor)) static void setFatTemplateDefault()
{
    ::setenv("FUZZ_FAT_TEMPLATE", "/mayhem/build/seeds/template.img", 0);
}
