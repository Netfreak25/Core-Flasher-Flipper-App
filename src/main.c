/* Standalone Core Flasher application. Adapted FlipTDI transport by SkorP.
 * See LICENSE, NOTICE and third_party/flip_tdi/provenance.json. */
#include <flipper_format/flipper_format.h>
#include <storage/storage.h>
#include "fliptdi/ftdi_usb.h"
#include "fliptdi/tb2_spi_backend.h"

#include <furi.h>
#include <gui/gui.h>
#include <gui/modules/submenu.h>
#include <gui/modules/text_box.h>
#include <gui/view_dispatcher.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CORE_FLASHER_TEST_STACK 1024U
#define CORE_FLASHER_RETRY_MS   100U
#define CORE_FLASHER_UI_TICK_MS 100U

typedef enum {
    CoreFlasherViewMenu,
    CoreFlasherViewText,
} CoreFlasherView;

typedef enum {
    CoreFlasherActionUsb = 1,
    CoreFlasherActionTest,
    CoreFlasherActionSettings,
    CoreFlasherActionToggleClock,
    CoreFlasherActionSaveClock,
    CoreFlasherActionWiring,
    CoreFlasherActionAbout,
} CoreFlasherAction;

typedef enum {
    CoreFlasherScreenMenu,
    CoreFlasherScreenSettings,
    CoreFlasherScreenUsb,
    CoreFlasherScreenTest,
    CoreFlasherScreenText,
} CoreFlasherScreen;

typedef struct {
    Storage* storage;
    ViewDispatcher* dispatcher;
    Submenu* menu;
    TextBox* text;
    FuriMutex* mutex;
    FuriThread* worker;
    FtdiUsb* usb;
    Tb2SpiBackend* probe;
    atomic_bool stop;
    CoreFlasherScreen screen;
    bool probe_transport;
    bool probe_match;
    uint8_t jedec[3];
    uint32_t default_hz;
    uint32_t draft_hz;
    bool clock_failed;
    char clock_label[32];
    char buffer[512];
} CoreFlasherApp;

#define CORE_FLASHER_CONFIG_DIR     EXT_PATH("apps_data/core_flasher")
#define CORE_FLASHER_CONFIG_PATH    CORE_FLASHER_CONFIG_DIR "/settings.conf"
#define CORE_FLASHER_CONFIG_TYPE    "Core Flasher"
#define CORE_FLASHER_CONFIG_VERSION 1U

/* Invalid or absent configuration always has the conservative default. */
static bool core_flasher_load_clock(Storage* storage, uint32_t* hz) {
    *hz = TB2_SPI_DEFAULT_HZ;
    FlipperFormat* file = flipper_format_file_alloc(storage);
    FuriString* type = furi_string_alloc();
    uint32_t version = 0, mhz = 0;
    bool ok = flipper_format_file_open_existing(file, CORE_FLASHER_CONFIG_PATH) &&
              flipper_format_read_header(file, type, &version) &&
              !strcmp(furi_string_get_cstr(type), CORE_FLASHER_CONFIG_TYPE) &&
              version == CORE_FLASHER_CONFIG_VERSION &&
              flipper_format_read_uint32(file, "Default SPI MHz", &mhz, 1) &&
              (mhz == 2U || mhz == 4U);
    flipper_format_file_close(file);
    flipper_format_free(file);
    furi_string_free(type);
    if(ok) *hz = mhz * 1000000U;
    return ok;
}

static bool core_flasher_save_clock(Storage* storage, uint32_t hz) {
    if(hz != TB2_SPI_DEFAULT_HZ && hz != TB2_SPI_FAST_HZ) return false;
    if(!storage_simply_mkdir(storage, CORE_FLASHER_CONFIG_DIR)) return false;
    uint32_t mhz = hz / 1000000U;
    FlipperFormat* file = flipper_format_file_alloc(storage);
    bool ok = flipper_format_file_open_always(file, CORE_FLASHER_CONFIG_PATH) &&
              flipper_format_write_header_cstr(
                  file, CORE_FLASHER_CONFIG_TYPE, CORE_FLASHER_CONFIG_VERSION) &&
              flipper_format_write_uint32(file, "Default SPI MHz", &mhz, 1);
    if(!flipper_format_file_close(file)) ok = false;
    flipper_format_free(file);
    uint32_t saved;
    return ok && core_flasher_load_clock(storage, &saved) && saved == hz;
}

static void core_flasher_show_settings(CoreFlasherApp* app);

static void core_flasher_show_menu(CoreFlasherApp* app);

static void
    core_flasher_set_text(CoreFlasherApp* app, CoreFlasherScreen screen, const char* text) {
    app->screen = screen;
    strlcpy(app->buffer, text, sizeof(app->buffer));
    text_box_set_text(app->text, app->buffer);
    text_box_set_focus(app->text, TextBoxFocusStart);
    view_dispatcher_switch_to_view(app->dispatcher, CoreFlasherViewText);
}

static void core_flasher_probe_text(CoreFlasherApp* app) {
    furi_mutex_acquire(app->mutex, FuriWaitForever);
    if(app->probe_match) {
        snprintf(
            app->buffer,
            sizeof(app->buffer),
            "Hardware SPI test\n\nChip detected\nJEDEC: %02X %02X %02X\nWinbond W25Q128FV\nSPI: Mode 0 / %lu MHz\n\nBack: return",
            app->jedec[0],
            app->jedec[1],
            app->jedec[2],
            (unsigned long)(app->default_hz / 1000000U));
    } else if(app->probe_transport) {
        snprintf(
            app->buffer,
            sizeof(app->buffer),
            "Hardware SPI test\n\nWaiting for W25Q128FV\nLast ID: %02X %02X %02X\n\nPins: 2 MOSI, 3 MISO\n      4 CS,   5 SCK\n\nBack: cancel",
            app->jedec[0],
            app->jedec[1],
            app->jedec[2]);
    } else {
        strlcpy(
            app->buffer,
            "Hardware SPI test\n\nWaiting for chip...\n\nPins: 2 MOSI, 3 MISO\n      4 CS,   5 SCK\nPower: 3.3 V only\n\nBack: cancel",
            sizeof(app->buffer));
    }
    text_box_set_text(app->text, app->buffer);
    furi_mutex_release(app->mutex);
}

static int32_t core_flasher_probe_worker(void* context) {
    CoreFlasherApp* app = context;
    static const uint8_t expected[3] = {0xEF, 0x40, 0x18};
    while(!atomic_load(&app->stop)) {
        uint8_t id[3] = {0};
        bool transport = tb2_spi_backend_probe_jedec(app->probe, id);
        furi_mutex_acquire(app->mutex, FuriWaitForever);
        app->probe_transport = transport;
        memcpy(app->jedec, id, sizeof(app->jedec));
        app->probe_match = transport && !memcmp(id, expected, sizeof(expected));
        bool matched = app->probe_match;
        furi_mutex_release(app->mutex);
        if(matched) break;
        furi_delay_ms(CORE_FLASHER_RETRY_MS);
    }
    return 0;
}

static void core_flasher_stop_probe(CoreFlasherApp* app) {
    atomic_store(&app->stop, true);
    if(app->worker) {
        furi_thread_join(app->worker);
        furi_thread_free(app->worker);
        app->worker = NULL;
    }
    tb2_spi_backend_free(app->probe);
    app->probe = NULL;
}

static bool core_flasher_start_probe(CoreFlasherApp* app) {
    app->probe = tb2_spi_backend_alloc(app->default_hz);
    if(!app->probe) return false;
    atomic_store(&app->stop, false);
    app->probe_transport = app->probe_match = false;
    memset(app->jedec, 0, sizeof(app->jedec));
    app->worker = furi_thread_alloc_ex(
        "FlipTDIProbe", CORE_FLASHER_TEST_STACK, core_flasher_probe_worker, app);
    if(!app->worker) {
        tb2_spi_backend_free(app->probe);
        app->probe = NULL;
        return false;
    }
    app->screen = CoreFlasherScreenTest;
    core_flasher_probe_text(app);
    view_dispatcher_switch_to_view(app->dispatcher, CoreFlasherViewText);
    furi_thread_start(app->worker);
    return true;
}

static void core_flasher_menu_event(void* context, uint32_t index) {
    CoreFlasherApp* app = context;
    view_dispatcher_send_custom_event(app->dispatcher, index);
}

static bool core_flasher_custom_event(void* context, uint32_t event) {
    CoreFlasherApp* app = context;
    switch((CoreFlasherAction)event) {
    case CoreFlasherActionUsb:
        app->clock_failed = false;
        app->usb = ftdi_usb_start(app->default_hz);
        if(app->usb) {
            core_flasher_set_text(
                app,
                CoreFlasherScreenUsb,
                "Core Flasher USB\n\nUSB: ready (0403:6014)\nSPI: starting\nAccess: raw SPI\n\nOpen a WebUSB client in Chrome\nvia localhost/HTTPS.\n\nBack: stop bridge");
        } else {
            core_flasher_set_text(
                app,
                CoreFlasherScreenText,
                "Core Flasher cannot start\n\nUSB is busy or memory is low.\nClose other USB apps and retry.\n\nBack: return");
        }
        return true;
    case CoreFlasherActionTest:
        if(!core_flasher_start_probe(app))
            core_flasher_set_text(
                app,
                CoreFlasherScreenText,
                "Hardware SPI test\n\nNot enough memory to start.\n\nBack: return");
        return true;
    case CoreFlasherActionSettings:
        app->draft_hz = app->default_hz;
        core_flasher_show_settings(app);
        return true;
    case CoreFlasherActionToggleClock:
        app->draft_hz = app->draft_hz == TB2_SPI_DEFAULT_HZ ? TB2_SPI_FAST_HZ : TB2_SPI_DEFAULT_HZ;
        core_flasher_show_settings(app);
        return true;
    case CoreFlasherActionSaveClock:
        if(core_flasher_save_clock(app->storage, app->draft_hz)) {
            app->default_hz = app->draft_hz;
            core_flasher_show_menu(app);
        } else {
            submenu_set_header(app->menu, "Save failed: retry");
        }
        return true;
    case CoreFlasherActionWiring:
        core_flasher_set_text(
            app,
            CoreFlasherScreenText,
            "SPI wiring\n\nPin 2  MOSI / DI\nPin 3  MISO / DO\nPin 4  CS\nPin 5  SCK / CLK\nPin 8  GND\nPin 9  3.3 V\n\nNever use 5 V.");
        return true;
    case CoreFlasherActionAbout:
        core_flasher_set_text(
            app,
            CoreFlasherScreenText,
            "Core Flasher 1.0.1\n\nFT232H-compatible WebUSB\nraw SPI bridge.\nClient owns flash operations.\n\nGPL-3.0\nBack: return");
        return true;
    default:
        return false;
    }
}

static void core_flasher_show_settings(CoreFlasherApp* app) {
    app->screen = CoreFlasherScreenSettings;
    submenu_reset(app->menu);
    submenu_set_header(app->menu, "Settings");
    snprintf(
        app->clock_label,
        sizeof(app->clock_label),
        "Default SPI: %lu MHz",
        (unsigned long)(app->draft_hz / 1000000U));
    submenu_add_item(
        app->menu, app->clock_label, CoreFlasherActionToggleClock, core_flasher_menu_event, app);
    submenu_add_item(app->menu, "Save", CoreFlasherActionSaveClock, core_flasher_menu_event, app);
    view_dispatcher_switch_to_view(app->dispatcher, CoreFlasherViewMenu);
}

static void core_flasher_tick_event(void* context) {
    CoreFlasherApp* app = context;
    if(app->screen == CoreFlasherScreenTest) core_flasher_probe_text(app);
    if(app->screen == CoreFlasherScreenUsb && app->usb) {
        Tb2SpiClockStatus status;
        if(!ftdi_usb_clock_status(app->usb, &status)) return;
        app->clock_failed |= status.clock_error;
        if(app->clock_failed) {
            if(ftdi_usb_stop(app->usb)) {
                app->usb = NULL;
                core_flasher_set_text(
                    app,
                    CoreFlasherScreenText,
                    "Bridge stopped\n\nRequested SPI clock is below\nhardware minimum. Select a\nhigher clock in the browser.\n\nBack: return");
            }
            return;
        }
        snprintf(
            app->buffer,
            sizeof(app->buffer),
            "Core Flasher USB\nDefault: %lu MHz\nBrowser: %lu Hz\nApplied: %lu Hz\n\nBrowser 0: app default\nApplied 0: awaiting transfer\n\nOpen a WebUSB client in Chrome\nBack: stop bridge",
            (unsigned long)(status.default_hz / 1000000U),
            (unsigned long)status.requested_hz,
            (unsigned long)status.applied_hz);
        text_box_set_text(app->text, app->buffer);
    }
}

static bool core_flasher_back_event(void* context) {
    CoreFlasherApp* app = context;
    if(app->screen == CoreFlasherScreenMenu) {
        view_dispatcher_stop(app->dispatcher);
        return true;
    }
    if(app->screen == CoreFlasherScreenTest) core_flasher_stop_probe(app);
    if(app->screen == CoreFlasherScreenUsb) {
        if(!ftdi_usb_stop(app->usb)) {
            core_flasher_set_text(
                app,
                CoreFlasherScreenUsb,
                "Core Flasher is active\n\nUSB could not be restored yet.\nDisconnect the browser and\npress Back to retry.");
            return true;
        }
        app->usb = NULL;
    }
    core_flasher_show_menu(app);
    return true;
}

static void core_flasher_show_menu(CoreFlasherApp* app) {
    app->screen = CoreFlasherScreenMenu;
    submenu_reset(app->menu);
    submenu_set_header(app->menu, "Core Flasher");
    submenu_add_item(
        app->menu, "Start USB bridge", CoreFlasherActionUsb, core_flasher_menu_event, app);
    submenu_add_item(
        app->menu, "Test hardware SPI", CoreFlasherActionTest, core_flasher_menu_event, app);
    submenu_add_item(
        app->menu, "Settings", CoreFlasherActionSettings, core_flasher_menu_event, app);
    submenu_add_item(app->menu, "Wiring", CoreFlasherActionWiring, core_flasher_menu_event, app);
    submenu_add_item(app->menu, "About", CoreFlasherActionAbout, core_flasher_menu_event, app);
    view_dispatcher_switch_to_view(app->dispatcher, CoreFlasherViewMenu);
}

static CoreFlasherApp* core_flasher_alloc(Gui* gui, Storage* storage) {
    CoreFlasherApp* app = calloc(1, sizeof(*app));
    if(!app) return NULL;

    app->storage = storage;
    core_flasher_load_clock(storage, &app->default_hz);
    app->mutex = furi_mutex_alloc(FuriMutexTypeNormal);
    app->dispatcher = view_dispatcher_alloc();
    app->menu = submenu_alloc();
    app->text = text_box_alloc();
    if(!app->mutex || !app->dispatcher || !app->menu || !app->text) {
        if(app->text) text_box_free(app->text);
        if(app->menu) submenu_free(app->menu);
        if(app->dispatcher) view_dispatcher_free(app->dispatcher);
        if(app->mutex) furi_mutex_free(app->mutex);
        free(app);
        return NULL;
    }

    view_dispatcher_enable_queue(app->dispatcher);
    view_dispatcher_set_event_callback_context(app->dispatcher, app);
    view_dispatcher_set_custom_event_callback(app->dispatcher, core_flasher_custom_event);
    view_dispatcher_set_navigation_event_callback(app->dispatcher, core_flasher_back_event);
    view_dispatcher_set_tick_event_callback(
        app->dispatcher, core_flasher_tick_event, CORE_FLASHER_UI_TICK_MS);
    view_dispatcher_add_view(app->dispatcher, CoreFlasherViewMenu, submenu_get_view(app->menu));
    view_dispatcher_add_view(app->dispatcher, CoreFlasherViewText, text_box_get_view(app->text));
    view_dispatcher_attach_to_gui(app->dispatcher, gui, ViewDispatcherTypeFullscreen);
    return app;
}

static void core_flasher_free(CoreFlasherApp* app) {
    if(!app) return;
    if(app->worker || app->probe) core_flasher_stop_probe(app);
    if(app->usb) {
        while(!ftdi_usb_stop(app->usb))
            furi_delay_ms(CORE_FLASHER_RETRY_MS);
        app->usb = NULL;
    }
    view_dispatcher_remove_view(app->dispatcher, CoreFlasherViewText);
    view_dispatcher_remove_view(app->dispatcher, CoreFlasherViewMenu);
    text_box_free(app->text);
    submenu_free(app->menu);
    view_dispatcher_free(app->dispatcher);
    furi_mutex_free(app->mutex);
    free(app);
}

int32_t core_flasher_app(void* context) {
    UNUSED(context);
    Gui* gui = furi_record_open(RECORD_GUI);
    Storage* storage = furi_record_open(RECORD_STORAGE);
    CoreFlasherApp* app = core_flasher_alloc(gui, storage);
    if(!app) {
        furi_record_close(RECORD_STORAGE);
        furi_record_close(RECORD_GUI);
        return 1;
    }

    core_flasher_show_menu(app);
    view_dispatcher_run(app->dispatcher);
    core_flasher_free(app);
    furi_record_close(RECORD_STORAGE);
    furi_record_close(RECORD_GUI);
    return 0;
}
