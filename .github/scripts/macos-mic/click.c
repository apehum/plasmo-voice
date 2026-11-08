#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <unistd.h>

// Posts a real left click at screen point (x, y). TCC prompts expose no accessibility elements,
// so they can only be answered with HID-level events like these
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    CGPoint point = {atof(argv[1]), atof(argv[2])};

    CGEventType types[] = {kCGEventMouseMoved, kCGEventLeftMouseDown, kCGEventLeftMouseUp};
    for (int i = 0; i < 3; i++) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, types[i], point, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        usleep(150000);
    }
    return 0;
}
