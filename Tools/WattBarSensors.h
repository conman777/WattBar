#ifndef WATTBAR_SENSORS_H
#define WATTBAR_SENSORS_H

// Imported into Swift with -import-objc-header. Each returns a negative value
// when the reading is unavailable.
double wattbar_gpu_watts(void);
double wattbar_cpu_temperature_celsius(void);
double wattbar_fan_rpm(void);

#endif
