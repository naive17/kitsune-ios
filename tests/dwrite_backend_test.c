/* Host check of the actual Wine DirectWrite Unix backend. Not an iPhone test. */
#include "../third_party/wine/dlls/dwrite/freetype.c"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

int __cdecl __wine_dbg_output(const char *text) { return fputs(text, stderr); }
int __cdecl __wine_dbg_header(enum __wine_debug_class cls, struct __wine_debug_channel *channel,
                             const char *function) {
    (void)cls; (void)channel; (void)function; return -1;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(process_attach(NULL) == STATUS_SUCCESS);
    FILE *file = fopen(argv[1], "rb");
    assert(file && !fseek(file, 0, SEEK_END));
    long size = ftell(file);
    assert(size > 0 && !fseek(file, 0, SEEK_SET));
    void *data = malloc(size);
    assert(data && fread(data, 1, size, file) == (size_t)size);
    fclose(file);

    UINT64 object = 0;
    struct create_font_object_params create = {data, size, 0, &object};
    assert(create_font_object(&create) == STATUS_SUCCESS && object);
    unsigned count = 0;
    struct get_glyph_count_params count_params = {object, &count};
    assert(get_glyph_count(&count_params) == STATUS_SUCCESS && count > 100);

    unsigned visible = 0;
    for (unsigned glyph = 1; glyph < 100; ++glyph) {
        RECT box = {0};
        struct get_glyph_bbox_params bbox = {object, 0, glyph, 24, {1, 0, 0, 1}, &box};
        assert(get_glyph_bbox(&bbox) == STATUS_SUCCESS);
        if (box.right > box.left && box.bottom > box.top) ++visible;
    }
    assert(visible > 50);
    struct release_font_object_params release = {object};
    assert(release_font_object(&release) == STATUS_SUCCESS);
    unsigned char invalid[] = {0, 1, 2, 3};
    object = 0;
    create.data = invalid; create.size = sizeof(invalid);
    assert(create_font_object(&create) != STATUS_SUCCESS && !object);
    assert(process_detach(NULL) == STATUS_SUCCESS);
    free(data);
    printf("PASS: DirectWrite backend attach, %u glyphs, %u nonempty bounds, invalid-font rejection\n", count, visible);
    return 0;
}
