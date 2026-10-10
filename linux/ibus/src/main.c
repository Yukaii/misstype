// ibus-engine-misstype: the IBus engine process. ibus-daemon starts it with
// --ibus (component XML); run bare, it registers its own component, which is
// how the headless tests and local development start it.
#include "engine.h"

#include <stdlib.h>

#ifndef MISSTYPE_DATADIR
#define MISSTYPE_DATADIR "/usr/share/misstype"
#endif

static IBusBus *bus;

static void on_disconnected(IBusBus *b, gpointer data) {
    (void)b;
    (void)data;
    ibus_quit();
}

int main(int argc, char **argv) {
    gboolean launched_by_daemon = FALSE;
    for (int i = 1; i < argc; ++i)
        if (g_str_equal(argv[i], "--ibus")) launched_by_daemon = TRUE;

    ibus_init();
    bus = ibus_bus_new();
    if (!ibus_bus_is_connected(bus)) {
        g_printerr("misstype: cannot connect to the IBus daemon\n");
        return 1;
    }
    g_signal_connect(bus, "disconnected", G_CALLBACK(on_disconnected), NULL);

    const char *env = g_getenv("MISSTYPE_RESOURCES");
    const char *resources = env && *env ? env : MISSTYPE_DATADIR;
    // NULL paths: learned phrases, my words and learned slips live in $XDG_DATA_HOME/misstype.
    misstype_engine *core = misstype_engine_new(resources, NULL);
    if (core) {
        misstype_engine_set_user_dictionary_path(core, NULL);
        misstype_engine_set_channel_path(core, NULL);
        misstype_ibus_apply_config(core);
        misstype_ibus_watch_config(core);
    } else {
        // Never crash and never filter: every key passes through.
        g_printerr("misstype: cannot load lexicon.tsv from %s\n", resources);
    }
    misstype_ibus_set_core(core);

    IBusFactory *factory = ibus_factory_new(ibus_bus_get_connection(bus));
    g_object_ref_sink(factory);
    ibus_factory_add_engine(factory, "misstype", MISSTYPE_TYPE_IBUS_ENGINE);

    if (launched_by_daemon) {
        ibus_bus_request_name(bus, "org.freedesktop.IBus.Misstype", 0);
    } else {
        IBusComponent *component = ibus_component_new("org.freedesktop.IBus.Misstype", "Misstype", "0.1", "MIT",
                                                      "Misstype", "https://github.com/Yukaii/misstype", "", "misstype");
        ibus_component_add_engine(component, ibus_engine_desc_new("misstype", "Misstype (隨打注音)",
                                                                  "Zhuyin with optional tones and typo repair",
                                                                  "zh_TW", "MIT", "Misstype", "misstype-symbolic", "us"));
        if (!ibus_bus_register_component(bus, component)) g_printerr("misstype: cannot register the component\n");
        g_object_unref(component);
    }

    ibus_main();

    g_object_unref(factory);
    g_object_unref(bus);
    if (core) misstype_engine_free(core);
    return EXIT_SUCCESS;
}
