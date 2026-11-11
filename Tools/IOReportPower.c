#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include "WattBarSensors.h"

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t channel_id, uint64_t options, uint64_t flags);
extern CFMutableDictionaryRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef desiredChannels, CFMutableDictionaryRef *subscribedChannels, uint64_t channel_id, CFTypeRef options);
extern CFDictionaryRef IOReportCreateSamples(CFMutableDictionaryRef subscription, CFMutableDictionaryRef channels, CFTypeRef options);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef oldSamples, CFDictionaryRef newSamples, CFTypeRef options);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef sample, int64_t *unit);

static CFMutableDictionaryRef subscription;
static CFMutableDictionaryRef subscribed_channels;
static CFDictionaryRef previous_sample;
static double previous_time;

static double monotonic_seconds(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return 0;
    return (double)time.tv_sec + ((double)time.tv_nsec / 1e9);
}

static int setup_report(void) {
    if (subscription && subscribed_channels) return 1;

    CFMutableDictionaryRef desired = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!desired) return 0;

    subscription = IOReportCreateSubscription(NULL, desired, &subscribed_channels, 0, NULL);
    CFRelease(desired);
    return subscription && subscribed_channels;
}

static int64_t gpu_energy_delta(CFDictionaryRef delta) {
    CFArrayRef channels = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (!channels || CFGetTypeID(channels) != CFArrayGetTypeID()) return -1;

    CFIndex count = CFArrayGetCount(channels);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef channel = CFArrayGetValueAtIndex(channels, i);
        if (!channel || CFGetTypeID(channel) != CFDictionaryGetTypeID()) continue;

        CFArrayRef legend = CFDictionaryGetValue(channel, CFSTR("LegendChannel"));
        if (!legend || CFGetTypeID(legend) != CFArrayGetTypeID() || CFArrayGetCount(legend) < 3) continue;

        CFStringRef name = CFArrayGetValueAtIndex(legend, 2);
        if (!name || CFGetTypeID(name) != CFStringGetTypeID()) continue;
        if (!CFEqual(name, CFSTR("GPU Energy"))) continue;

        int64_t unit = 0;
        int64_t value = IOReportSimpleGetIntegerValue(channel, &unit);
        if (value < 0) return -1;
        return value;
    }

    return -1;
}

double wattbar_gpu_watts(void) {
    if (!setup_report()) return -1.0;

    CFDictionaryRef sample = IOReportCreateSamples(subscription, subscribed_channels, NULL);
    if (!sample) return -1.0;

    double now = monotonic_seconds();
    if (!previous_sample || previous_time <= 0 || now <= previous_time) {
        if (previous_sample) CFRelease(previous_sample);
        previous_sample = sample;
        previous_time = now;
        return -1.0;
    }

    CFDictionaryRef delta = IOReportCreateSamplesDelta(previous_sample, sample, NULL);
    CFRelease(previous_sample);
    previous_sample = sample;

    int64_t energy_nj = delta ? gpu_energy_delta(delta) : -1;
    if (delta) CFRelease(delta);

    double elapsed = now - previous_time;
    previous_time = now;
    if (energy_nj < 0 || elapsed <= 0) return -1.0;

    double watts = ((double)energy_nj / 1e9) / elapsed;
    return watts >= 0 && watts <= 200 ? watts : -1.0;
}
