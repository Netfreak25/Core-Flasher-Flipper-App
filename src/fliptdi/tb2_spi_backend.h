#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct Tb2SpiBackend Tb2SpiBackend;

/** Allocate a lazy native-SPI backend. Hardware is not touched until first use. */
Tb2SpiBackend* tb2_spi_backend_alloc(void);

/** Release any active transaction, deinitialize the external SPI handle and free the backend. */
void tb2_spi_backend_free(Tb2SpiBackend* backend);

/** Ensure the external Flipper SPI handle is initialized. */
bool tb2_spi_backend_init(Tb2SpiBackend* backend);

/** Begin one CS-low transaction using furi_hal_spi_bus_handle_external. */
bool tb2_spi_backend_acquire(Tb2SpiBackend* backend);

/** End the current transaction. Safe to call when no transaction is active. */
void tb2_spi_backend_release(Tb2SpiBackend* backend);

/** Forward bytes while an acquired transaction is active.
 * Flash command policy and transaction planning belong to the browser client. */
bool tb2_spi_backend_tx(Tb2SpiBackend* backend, const uint8_t* data, size_t size);
bool tb2_spi_backend_rx(Tb2SpiBackend* backend, uint8_t* data, size_t size);

/** True while the hardware SPI bus is acquired/CS is asserted. */
bool tb2_spi_backend_is_acquired(const Tb2SpiBackend* backend);

/** Diagnostic result of the most recent direct JEDEC probe. It does not gate raw transfers. */
bool tb2_spi_backend_is_verified(const Tb2SpiBackend* backend);

/** Clear the verification gate after a transport failure or session reset. */
void tb2_spi_backend_invalidate(Tb2SpiBackend* backend);

/**
 * Direct diagnostic transaction over the hardware-SPI path:
 * acquire -> TX 0x9F -> RX 3 -> release.
 *
 * Returns transport success independently of whether the ID matches EF 40 18.
 * A matching ID is recorded for diagnostics. Raw bridge transactions do not depend on it.
 */
bool tb2_spi_backend_probe_jedec(Tb2SpiBackend* backend, uint8_t jedec[3]);
