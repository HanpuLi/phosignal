// PhoSignal — minimal MagSafe LED helper.
// Copyright (c) 2026 Caitlyn Lye
// SPDX-License-Identifier: MIT
//
// Controls only the AppleSMC ACLC key. Write operations require root.
// Supported modes intentionally exclude arbitrary raw SMC writes.

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCKeyData_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

_Static_assert(sizeof(SMCKeyData_t) == 80, "Unexpected AppleSMC ABI layout");

static const uint32_t KEY_ACLC = ('A' << 24) | ('C' << 16) | ('L' << 8) | 'C';

static kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *input, SMCKeyData_t *output) {
    size_t output_size = sizeof(*output);
    return IOConnectCallStructMethod(
        conn, KERNEL_INDEX_SMC,
        input, sizeof(*input),
        output, &output_size
    );
}

static int key_info(io_connect_t conn, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t input = {0}, output = {0};
    input.key = KEY_ACLC;
    input.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(conn, &input, &output);
    if (kr != KERN_SUCCESS || output.result != 0) return -1;
    *info = output.keyInfo;
    return 0;
}

static int read_value(io_connect_t conn, uint8_t *value) {
    SMCKeyData_keyInfo_t info = {0};
    if (key_info(conn, &info) != 0 || info.dataSize != 1) return -1;

    SMCKeyData_t input = {0}, output = {0};
    input.key = KEY_ACLC;
    input.data8 = SMC_CMD_READ_BYTES;
    input.keyInfo.dataSize = info.dataSize;
    kern_return_t kr = smc_call(conn, &input, &output);
    if (kr != KERN_SUCCESS || output.result != 0) return -2;
    *value = output.bytes[0];
    return 0;
}

static int write_value(io_connect_t conn, uint8_t value) {
    if (geteuid() != 0) {
        fprintf(stderr, "write requires root\n");
        return 4;
    }

    SMCKeyData_keyInfo_t info = {0};
    if (key_info(conn, &info) != 0 || info.dataSize != 1) {
        fprintf(stderr, "ACLC key unavailable or has unexpected size\n");
        return 5;
    }

    SMCKeyData_t input = {0}, output = {0};
    input.key = KEY_ACLC;
    input.data8 = SMC_CMD_WRITE_BYTES;
    input.keyInfo.dataSize = info.dataSize;
    input.bytes[0] = value;
    kern_return_t kr = smc_call(conn, &input, &output);
    if (kr != KERN_SUCCESS || output.result != 0) {
        fprintf(stderr, "SMC write failed (kr=0x%x, result=%u)\n", kr, output.result);
        return 6;
    }
    return 0;
}

static int parse_mode(const char *mode, uint8_t *value) {
    if (strcmp(mode, "auto") == 0)       *value = 0x00;
    else if (strcmp(mode, "off") == 0)   *value = 0x01;
    else if (strcmp(mode, "green") == 0) *value = 0x03;
    else if (strcmp(mode, "amber") == 0) *value = 0x04;
    else if (strcmp(mode, "amber-slow") == 0) *value = 0x06;
    else if (strcmp(mode, "amber-fast") == 0) *value = 0x07;
    else return -1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: magsafe-led read|auto|off|green|amber|amber-slow|amber-fast\n");
        return 2;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) {
        fprintf(stderr, "AppleSMC service not found\n");
        return 3;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || connection == IO_OBJECT_NULL) {
        fprintf(stderr, "cannot open AppleSMC (kr=0x%x)\n", kr);
        return 3;
    }

    int rc = 0;
    if (strcmp(argv[1], "read") == 0) {
        uint8_t value = 0;
        rc = read_value(connection, &value);
        if (rc == 0) printf("ACLC=%02x\n", value);
        else fprintf(stderr, "ACLC read failed\n");
    } else {
        uint8_t value = 0;
        if (parse_mode(argv[1], &value) != 0) {
            fprintf(stderr, "unsupported mode\n");
            rc = 2;
        } else {
            rc = write_value(connection, value);
        }
    }

    IOServiceClose(connection);
    return rc;
}
