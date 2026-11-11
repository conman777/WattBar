#include <IOKit/IOKitLib.h>
#include <assert.h>
#include <stdio.h>

static kern_return_t mock_smc_call(io_connect_t connection, uint32_t selector,
    const void *input, size_t input_size, void *output, size_t *output_size);
#define IOConnectCallStructMethod mock_smc_call
#include "../Tools/CPUTemperature.c"
#undef IOConnectCallStructMethod

static int metadata_calls;
static int value_calls;
static int fail_value;
static int fail_metadata;
static float sensor_value = 45;
static uint8_t fan_count;
static float fan_rpm = 2500;
static kern_return_t mock_smc_call(io_connect_t connection, uint32_t selector,
    const void *raw_input, size_t input_size, void *raw_output, size_t *output_size) {
    const SMCKeyData *input = raw_input;
    SMCKeyData *output = raw_output;
    if (input->command == 9) {
        metadata_calls++;
        if (fail_metadata) return kIOReturnError;
        if (input->key == fourcc("TC0P")) {
            output->result = SMC_KEY_NOT_FOUND;
            return KERN_SUCCESS;
        }
        int is_fan_count = input->key == fourcc("FNum");
        output->key_info.data_size = is_fan_count ? 1 : 4;
        output->key_info.data_type = is_fan_count ? fourcc("ui8 ") : fourcc("flt ");
    } else if (input->command == 5) {
        value_calls++;
        if (fail_value) return kIOReturnError;
        if (input->key == fourcc("FNum")) {
            output->bytes[0] = fan_count;
        } else {
            const float *value = (char)(input->key >> 24) == 'F' ? &fan_rpm : &sensor_value;
            memcpy(output->bytes, value, sizeof(*value));
        }
    }
    return KERN_SUCCESS;
}
int main(void) {
    double temperature;
    uint32_t key = fourcc("Tp01");
    assert(decode_temperature(key, &temperature) && temperature == 45);
    sensor_value = 55;
    assert(decode_temperature(key, &temperature) && temperature == 55);
    assert(metadata_calls == 1 && value_calls == 2);
    fail_value = 1;
    assert(!decode_temperature(key, &temperature));
    fail_value = 0;
    assert(decode_temperature(key, &temperature) && temperature == 55);
    assert(metadata_calls == 2 && value_calls == 4);

    uint32_t missing = fourcc("TC0P");
    assert(!decode_temperature(missing, &temperature));
    assert(!decode_temperature(missing, &temperature));
    assert(metadata_calls == 3 && value_calls == 4);

    uint32_t flaky = fourcc("Tp02");
    fail_metadata = 1;
    assert(!decode_temperature(flaky, &temperature));
    fail_metadata = 0;
    assert(decode_temperature(flaky, &temperature) && temperature == 55);
    assert(metadata_calls == 5);
    puts("Passed CPU metadata cache freshness, recovery and missing-key checks");

    connection = 1;
    assert(wattbar_fan_rpm() < 0);
    fan_count = 1;
    assert(wattbar_fan_rpm() == 2500);
    fan_rpm = 0;
    assert(wattbar_fan_rpm() == 0);
    fan_rpm = -5;
    assert(wattbar_fan_rpm() < 0);
    puts("Passed fan count, speed, stopped-fan and invalid-reading checks");
}
