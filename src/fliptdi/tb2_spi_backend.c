#include "tb2_spi_backend.h"

#include <furi.h>
#include <furi_hal.h>
#include <stdlib.h>
#include <string.h>

#define TAG                         "TB2_SPI"
#define TB2_SPI_TRANSFER_TIMEOUT_MS (1000U)

struct Tb2SpiBackend {
    bool initialized;
    bool acquired;
    bool insomnia;
    bool verified;
    uint8_t last_jedec[3];
};

Tb2SpiBackend* tb2_spi_backend_alloc(void) {
    Tb2SpiBackend* backend = malloc(sizeof(Tb2SpiBackend));
    if(!backend) return NULL;
    memset(backend, 0, sizeof(Tb2SpiBackend));
    return backend;
}

bool tb2_spi_backend_init(Tb2SpiBackend* backend) {
    if(!backend) return false;
    if(backend->initialized) return true;

    furi_hal_power_insomnia_enter();
    backend->insomnia = true;
    furi_hal_spi_bus_handle_init(&furi_hal_spi_bus_handle_external);
    backend->initialized = true;
    FURI_LOG_I(TAG, "native SPI initialized");
    return true;
}

bool tb2_spi_backend_acquire(Tb2SpiBackend* backend) {
    if(!backend) return false;
    if(backend->acquired) return true;
    if(!tb2_spi_backend_init(backend)) return false;

    furi_hal_spi_acquire(&furi_hal_spi_bus_handle_external);
    backend->acquired = true;
    return true;
}

void tb2_spi_backend_release(Tb2SpiBackend* backend) {
    if(!backend || !backend->acquired) return;
    furi_hal_spi_release(&furi_hal_spi_bus_handle_external);
    backend->acquired = false;
}

bool tb2_spi_backend_tx(Tb2SpiBackend* backend, const uint8_t* data, size_t size) {
    if(!backend || !backend->acquired || (!data && size)) return false;
    if(!size) return true;
    return furi_hal_spi_bus_tx(
        &furi_hal_spi_bus_handle_external, data, size, TB2_SPI_TRANSFER_TIMEOUT_MS);
}

bool tb2_spi_backend_rx(Tb2SpiBackend* backend, uint8_t* data, size_t size) {
    if(!backend || !backend->acquired || !data || !size) return false;
    return furi_hal_spi_bus_rx(
        &furi_hal_spi_bus_handle_external, data, size, TB2_SPI_TRANSFER_TIMEOUT_MS);
}

bool tb2_spi_backend_is_acquired(const Tb2SpiBackend* backend) {
    return backend && backend->acquired;
}

bool tb2_spi_backend_is_verified(const Tb2SpiBackend* backend) {
    return backend && backend->verified;
}

void tb2_spi_backend_invalidate(Tb2SpiBackend* backend) {
    if(!backend) return;
    backend->verified = false;
}

bool tb2_spi_backend_probe_jedec(Tb2SpiBackend* backend, uint8_t jedec[3]) {
    if(!backend || !jedec || backend->acquired) return false;

    static const uint8_t expected[3] = {0xEF, 0x40, 0x18};
    const uint8_t command = 0x9F;
    bool ok = tb2_spi_backend_acquire(backend);
    if(ok) ok = tb2_spi_backend_tx(backend, &command, 1);
    if(ok) ok = tb2_spi_backend_rx(backend, jedec, 3);
    tb2_spi_backend_release(backend);

    if(!ok) {
        memset(jedec, 0, 3);
        backend->verified = false;
        FURI_LOG_E(TAG, "direct JEDEC transport failed");
        return false;
    }

    memcpy(backend->last_jedec, jedec, sizeof(backend->last_jedec));
    backend->verified = memcmp(jedec, expected, sizeof(expected)) == 0;
    if(backend->verified) {
        FURI_LOG_I(TAG, "direct JEDEC verified: EF 40 18");
    }
    return true;
}

void tb2_spi_backend_free(Tb2SpiBackend* backend) {
    if(!backend) return;

    tb2_spi_backend_release(backend);
    if(backend->initialized) {
        furi_hal_spi_bus_handle_deinit(&furi_hal_spi_bus_handle_external);
        backend->initialized = false;
    }
    if(backend->insomnia) {
        furi_hal_power_insomnia_exit();
        backend->insomnia = false;
    }
    free(backend);
}
