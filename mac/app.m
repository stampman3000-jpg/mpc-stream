/* Small Mac window for Stream. The sound still comes from play.m.
 * This only shows whether the MPC is arriving and whether BlackHole is there.
 * Quit the terminal ./play before opening this. Both want UDP port 47703.
 */
#import <Cocoa/Cocoa.h>
#import <pthread.h>

#include "stream.h"

static void *run_play(void *arg) {
    (void)arg;
    stream_play();
    return NULL;
}

@interface StreamApp : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *head;
@property(nonatomic, strong) NSTextField *body;
- (void)showWindow:(id)sender;
- (void)tick:(NSTimer *)timer;
@end

@implementation StreamApp

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    pthread_t thread;
    NSMenu *menu;
    NSMenuItem *show;
    NSMenuItem *quit;
    (void)note;

    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title = @"Stream";
    menu = [[NSMenu alloc] init];
    show = [[NSMenuItem alloc] initWithTitle:@"Show Stream" action:@selector(showWindow:) keyEquivalent:@""];
    show.target = self;
    quit = [[NSMenuItem alloc] initWithTitle:@"Quit Stream" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:show];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:quit];
    self.item.menu = menu;

    self.window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 440, 240)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"Stream";

    self.head = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 168, 392, 48)];
    self.head.editable = NO;
    self.head.bezeled = NO;
    self.head.drawsBackground = NO;
    self.head.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    self.head.stringValue = @"Starting";
    self.head.usesSingleLineMode = NO;
    self.head.cell.wraps = YES;

    self.body = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 20, 392, 140)];
    self.body.editable = NO;
    self.body.bezeled = NO;
    self.body.drawsBackground = NO;
    self.body.font = [NSFont systemFontOfSize:13];
    self.body.usesSingleLineMode = NO;
    self.body.cell.wraps = YES;
    self.body.cell.scrollable = NO;
    self.body.stringValue = @"Opening BlackHole 64ch.";

    [self.window.contentView addSubview:self.head];
    [self.window.contentView addSubview:self.body];
    [self.window center];
    [self showWindow:nil];

    pthread_create(&thread, NULL, run_play, NULL);
    pthread_detach(thread);
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (!flag) [self showWindow:nil];
    return YES;
}

- (void)showWindow:(id)sender {
    (void)sender;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)tick:(NSTimer *)timer {
    char menu[64], head[160], body[640];
    int level;
    (void)timer;
    level = stream_copy_status(menu, sizeof menu, head, sizeof head, body, sizeof body);
    self.item.button.title = [NSString stringWithUTF8String:menu];
    self.head.stringValue = [NSString stringWithUTF8String:head];
    self.body.stringValue = [NSString stringWithUTF8String:body];
    if (level >= 2)
        self.head.textColor = [NSColor systemOrangeColor];
    else if (level == 1)
        self.head.textColor = [NSColor secondaryLabelColor];
    else
        self.head.textColor = [NSColor labelColor];
}

@end

int main(void) {
    @autoreleasepool {
        StreamApp *delegate = [StreamApp new];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
