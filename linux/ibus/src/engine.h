// IBus adapter for Misstype (docs/cross-platform.md, docs/ibus-port.md).
// All editing rules live in the Zig core's Session behind the C ABI in
// misstype.h; this adapter only translates key events, applies key results
// and draws the session view.
#ifndef MISSTYPE_IBUS_ENGINE_H
#define MISSTYPE_IBUS_ENGINE_H

#include <ibus.h>
#include <misstype.h>

G_BEGIN_DECLS

#define MISSTYPE_TYPE_IBUS_ENGINE (misstype_ibus_engine_get_type())
// Spelled out instead of G_DECLARE_FINAL_TYPE: libibus defines no autoptr
// cleanup for IBusEngine, which that macro needs for its parent.
typedef struct _MisstypeIBusEngine MisstypeIBusEngine;
typedef struct {
    IBusEngineClass parent_class;
} MisstypeIBusEngineClass;
GType misstype_ibus_engine_get_type(void);
#define MISSTYPE_IBUS_ENGINE(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), MISSTYPE_TYPE_IBUS_ENGINE, MisstypeIBusEngine))

/// The process-wide decoder shared by every input context (may be NULL when
/// the lexicon cannot be loaded: every key then passes through). Set before
/// the factory creates engines.
void misstype_ibus_set_core(misstype_engine *core);

/// Loads the shared settings file into the core (config.c).
void misstype_ibus_apply_config(misstype_engine *core);

G_END_DECLS

#endif
