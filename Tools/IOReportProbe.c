#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t channel_id, uint64_t options, uint64_t flags);
extern CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t channel_id, uint64_t options);
extern CFMutableDictionaryRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef desiredChannels, CFMutableDictionaryRef *subscribedChannels, uint64_t channel_id, CFTypeRef options);
extern CFDictionaryRef IOReportCreateSamples(CFMutableDictionaryRef subscription, CFMutableDictionaryRef channels, CFTypeRef options);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef oldSamples, CFDictionaryRef newSamples, CFTypeRef options);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef sample, int64_t *unit);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef sample);

static void print_string(CFStringRef string) {
    if (!string) {
        printf("(null)");
        return;
    }

    char buffer[512];
    if (CFStringGetCString(string, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s", buffer);
    } else {
        printf("(unprintable)");
    }
}

static void print_decoded_samples(CFDictionaryRef samples) {
    if (!samples) return;

    CFArrayRef channels = CFDictionaryGetValue(samples, CFSTR("IOReportChannels"));
    if (!channels || CFGetTypeID(channels) != CFArrayGetTypeID()) return;

    CFIndex count = CFArrayGetCount(channels);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef channel = CFArrayGetValueAtIndex(channels, i);
        if (!channel || CFGetTypeID(channel) != CFDictionaryGetTypeID()) continue;

        CFArrayRef legend = CFDictionaryGetValue(channel, CFSTR("LegendChannel"));
        CFStringRef name = NULL;
        if (legend && CFGetTypeID(legend) == CFArrayGetTypeID() && CFArrayGetCount(legend) >= 3) {
            name = CFArrayGetValueAtIndex(legend, 2);
        }

        int64_t unit = 0;
        int64_t value = IOReportSimpleGetIntegerValue(channel, &unit);
        printf("decoded name=");
        print_string(name);
        printf(" value=%lld unit=%lld unit_label=", value, unit);
        print_string(IOReportChannelGetUnitLabel(channel));
        printf("\n");
    }
}

static void print_plist(CFTypeRef value) {
    if (!value) {
        puts("(null)");
        return;
    }

    CFErrorRef error = NULL;
    CFDataRef data = CFPropertyListCreateData(kCFAllocatorDefault, value, kCFPropertyListXMLFormat_v1_0, 0, &error);
    if (!data) {
        CFShow(error);
        if (error) CFRelease(error);
        return;
    }

    fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), stdout);
    CFRelease(data);
}

static void list_channels(CFDictionaryRef channels) {
    if (!channels) return;

    CFArrayRef entries = CFDictionaryGetValue(channels, CFSTR("IOReportChannels"));
    if (!entries || CFGetTypeID(entries) != CFArrayGetTypeID()) return;

    CFIndex count = CFArrayGetCount(entries);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(entries, i);
        if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) continue;

        CFStringRef group = CFDictionaryGetValue(entry, CFSTR("IOReportGroupName"));
        CFStringRef subgroup = CFDictionaryGetValue(entry, CFSTR("IOReportSubGroupName"));
        CFArrayRef legend = CFDictionaryGetValue(entry, CFSTR("LegendChannel"));
        if (!legend || CFGetTypeID(legend) != CFArrayGetTypeID()) continue;

        printf("group=");
        print_string(group);
        printf(" subgroup=");
        print_string(subgroup);
        printf(" channel=");
        if (CFArrayGetCount(legend) >= 3) {
            print_string(CFArrayGetValueAtIndex(legend, 2));
        } else {
            printf("(unnamed)");
        }
        printf(" unit=");
        CFDictionaryRef info = CFDictionaryGetValue(entry, CFSTR("IOReportChannelInfo"));
        if (info && CFGetTypeID(info) == CFDictionaryGetTypeID()) {
            CFNumberRef unit = CFDictionaryGetValue(info, CFSTR("IOReportChannelUnit"));
            int64_t value = 0;
            if (unit && CFGetTypeID(unit) == CFNumberGetTypeID()) {
                CFNumberGetValue(unit, kCFNumberSInt64Type, &value);
                printf("%lld", value);
            } else {
                printf("(unknown)");
            }
        } else {
            printf("(unknown)");
        }
        printf("\n");
    }
}

int main(int argc, const char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--list") == 0) {
        CFMutableDictionaryRef channels = IOReportCopyAllChannels(0, 0);
        print_plist(channels);
        list_channels(channels);
        if (channels) CFRelease(channels);
        return 0;
    }

    if (argc < 3) {
        fprintf(stderr, "usage: %s group subgroup [delay_ms]\\n", argv[0]);
        return 2;
    }

    int delay_ms = argc >= 4 ? atoi(argv[3]) : 500;

    CFStringRef group = CFStringCreateWithCString(kCFAllocatorDefault, argv[1], kCFStringEncodingUTF8);
    CFStringRef subgroup = strcmp(argv[2], "--none") == 0
        ? NULL
        : CFStringCreateWithCString(kCFAllocatorDefault, argv[2], kCFStringEncodingUTF8);
    CFMutableDictionaryRef desired = IOReportCopyChannelsInGroup(group, subgroup, 0, 0, 0);
    if (!desired) {
        fprintf(stderr, "no channels\\n");
        return 1;
    }

    CFMutableDictionaryRef subscribed = NULL;
    CFMutableDictionaryRef subscription = IOReportCreateSubscription(NULL, desired, &subscribed, 0, NULL);
    fprintf(stderr, "desired=%p subscribed=%p subscription=%p\\n", desired, subscribed, subscription);
    if (!subscription || !subscribed) {
        print_plist(desired);
        return 1;
    }

    CFDictionaryRef sample1 = IOReportCreateSamples(subscription, subscribed, NULL);
    usleep((useconds_t)delay_ms * 1000);
    CFDictionaryRef sample2 = IOReportCreateSamples(subscription, subscribed, NULL);
    CFDictionaryRef delta = NULL;
    if (sample1 && sample2) {
        delta = IOReportCreateSamplesDelta(sample1, sample2, NULL);
    }

    fprintf(stderr, "sample1=%p sample2=%p delta=%p\\n", sample1, sample2, delta);
    puts("decoded_scope=sample");
    print_decoded_samples(sample2);
    puts("decoded_scope=delta");
    print_decoded_samples(delta);
    print_plist(delta ? delta : sample2);

    if (delta) CFRelease(delta);
    if (sample2) CFRelease(sample2);
    if (sample1) CFRelease(sample1);
    if (subscription) CFRelease(subscription);
    if (subscribed) CFRelease(subscribed);
    CFRelease(desired);
    CFRelease(group);
    if (subgroup) CFRelease(subgroup);
    return 0;
}
