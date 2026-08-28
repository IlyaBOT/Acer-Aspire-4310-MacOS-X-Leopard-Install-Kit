#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>

enum {
    SMC_HANDLE_EVENT = 2,
    SMC_READ_KEY = 5,
};

struct AppleSMCParam {
    uint32_t key;
    uint8_t pad0[22];
    IOByteCount data_size;
    uint8_t pad1[10];
    uint8_t command;
    uint32_t pad2;
    uint8_t bytes[32];
};

static int read_key(io_connect_t connection, uint32_t key, uint8_t output[32])
{
    struct AppleSMCParam parameter = {
        .key = key,
        .data_size = 32,
        .command = SMC_READ_KEY,
    };
    size_t parameter_size = sizeof(parameter);
    IOReturn status;

    status = IOConnectCallStructMethod(
        connection,
        SMC_HANDLE_EVENT,
        &parameter,
        sizeof(parameter),
        &parameter,
        &parameter_size
    );
    if (status != kIOReturnSuccess) {
        return 1;
    }
    for (size_t index = 0; index < 32; ++index) {
        output[index] = parameter.bytes[index];
    }
    return 0;
}

int main(void)
{
    io_service_t service;
    io_connect_t connection = IO_OBJECT_NULL;
    uint8_t osk[64];
    int status = 1;

    service = IOServiceGetMatchingService(
        kIOMasterPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        fputs("AppleSMC service was not found\n", stderr);
        return 1;
    }

    if (IOServiceOpen(service, mach_task_self(), 0, &connection)
        != kIOReturnSuccess || connection == IO_OBJECT_NULL) {
        fputs("AppleSMC service could not be opened\n", stderr);
        goto cleanup;
    }

    if (read_key(connection, 'OSK0', osk) != 0
        || read_key(connection, 'OSK1', osk + 32) != 0) {
        fputs("AppleSMC OSK0/OSK1 could not be read\n", stderr);
        goto cleanup;
    }

    if (fwrite(osk, 1, sizeof(osk), stdout) != sizeof(osk)) {
        fputs("AppleSMC OSK could not be written\n", stderr);
        goto cleanup;
    }
    status = 0;

cleanup:
    if (connection != IO_OBJECT_NULL) {
        IOServiceClose(connection);
    }
    IOObjectRelease(service);
    return status;
}
