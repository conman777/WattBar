#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdint.h>
#ifdef WATTBAR_CPU_TEMPERATURE_TEST
#include <stdio.h>
#endif
#include <string.h>

// Apple's SMC interface is private, just like the IOReport interface used by
// WattBar's GPU reader. Failures are reported as unavailable to the Swift UI.

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpu_limit;
    uint32_t gpu_limit;
    uint32_t memory_limit;
} SMCPowerLimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t data_attributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimit power_limit;
    SMCKeyInfo key_info;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t connection;
static uint32_t cpu_keys[256];
static size_t cpu_key_count;
static int keys_discovered;

static uint32_t fourcc(const char name[4]) {
    return ((uint32_t)(uint8_t)name[0] << 24)
        | ((uint32_t)(uint8_t)name[1] << 16)
        | ((uint32_t)(uint8_t)name[2] << 8)
        | (uint32_t)(uint8_t)name[3];
}

static int smc_call(const SMCKeyData *input, SMCKeyData *output) {
    size_t output_size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t status = IOConnectCallStructMethod(
        connection,
        2,
        input,
        sizeof(*input),
        output,
        &output_size
    );
    return status == KERN_SUCCESS && output->result == 0;
}

static int setup_smc(void) {
    if (connection != IO_OBJECT_NULL) return 1;

    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMCKeysEndpoint");
    if (!matching) return 0;

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }

    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_connect_t candidate = IO_OBJECT_NULL;
        if (IOServiceOpen(service, mach_task_self(), 0, &candidate) == KERN_SUCCESS) {
            connection = candidate;
        }
        IOObjectRelease(service);
        if (connection != IO_OBJECT_NULL) break;
    }
    IOObjectRelease(iterator);
    return connection != IO_OBJECT_NULL;
}

static int read_key_info(uint32_t key, SMCKeyInfo *info) {
    SMCKeyData input = {0};
    SMCKeyData output;
    input.key = key;
    input.command = 9;
    if (!smc_call(&input, &output)) return 0;
    *info = output.key_info;
    return 1;
}

static int read_key(uint32_t key, SMCKeyInfo *info, uint8_t bytes[32]) {
    if (!read_key_info(key, info) || info->data_size == 0 || info->data_size > 32) return 0;

    SMCKeyData input = {0};
    SMCKeyData output;
    input.key = key;
    input.key_info = *info;
    input.command = 5;
    if (!smc_call(&input, &output)) return 0;
    memcpy(bytes, output.bytes, info->data_size);
    return 1;
}

static int decode_temperature(uint32_t key, double *temperature) {
    SMCKeyInfo info;
    uint8_t bytes[32];
    if (!read_key(key, &info, bytes)) return 0;

    double value;
    if (info.data_type == fourcc("flt ") && info.data_size == 4) {
        float raw;
        memcpy(&raw, bytes, sizeof(raw));
        value = raw;
    } else if (info.data_type == fourcc("sp78") && info.data_size >= 2) {
        int16_t raw = (int16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
        value = (double)raw / 256.0;
    } else {
        return 0;
    }

    if (!isfinite(value) || value <= 0 || value > 150) return 0;
    *temperature = value;
    return 1;
}

static int is_cpu_sensor(uint32_t key) {
    char first = (char)(key >> 24);
    char second = (char)(key >> 16);
    return first == 'T' && (second == 'p' || second == 'e' || second == 's');
}

static void discover_cpu_keys(void) {
    if (keys_discovered) return;
    keys_discovered = 1;

    SMCKeyInfo count_info;
    uint8_t count_bytes[32];
    if (!read_key(fourcc("#KEY"), &count_info, count_bytes) || count_info.data_size < 4) return;

    uint32_t count = ((uint32_t)count_bytes[0] << 24)
        | ((uint32_t)count_bytes[1] << 16)
        | ((uint32_t)count_bytes[2] << 8)
        | count_bytes[3];

    for (uint32_t index = 0; index < count && cpu_key_count < 256; index++) {
        SMCKeyData input = {0};
        SMCKeyData output;
        input.command = 8;
        input.data32 = index;
        if (smc_call(&input, &output) && is_cpu_sensor(output.key)) {
            cpu_keys[cpu_key_count++] = output.key;
        }
    }
}

double wattbar_cpu_temperature_celsius(void) {
    if (!setup_smc()) return -1.0;

    // Prefer dedicated CPU die/package readings when the current Mac exposes one.
    const char *preferred[] = {"TCMz", "TC0P", "TC0D", "TC0E"};
    for (size_t index = 0; index < sizeof(preferred) / sizeof(preferred[0]); index++) {
        double value;
        if (decode_temperature(fourcc(preferred[index]), &value)) return value;
    }

    // Apple changes individual sensor keys between SoC generations. Average the
    // CPU performance/efficiency/system-cluster families as a portable fallback.
    discover_cpu_keys();
    double total = 0;
    size_t valid_count = 0;
    for (size_t index = 0; index < cpu_key_count; index++) {
        double value;
        if (decode_temperature(cpu_keys[index], &value)) {
            total += value;
            valid_count++;
        }
    }

    return valid_count > 0 ? total / (double)valid_count : -1.0;
}

#ifdef WATTBAR_CPU_TEMPERATURE_TEST
int main(void) {
    double temperature = wattbar_cpu_temperature_celsius();
    if (temperature < 0) {
        fprintf(stderr, "CPU temperature unavailable\n");
        return 1;
    }
    printf("%.1f °C\n", temperature);
    return 0;
}
#endif
