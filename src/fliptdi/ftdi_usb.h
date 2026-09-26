#pragma once
#include <stdbool.h>

typedef struct FtdiUsb FtdiUsb;

FtdiUsb* ftdi_usb_start(void);
/** Restore the previous USB interface. Returns only after deinit completed. */
bool ftdi_usb_stop(FtdiUsb* ftdi);
