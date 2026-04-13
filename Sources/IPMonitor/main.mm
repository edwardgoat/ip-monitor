#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

#include <optional>
#include <regex>
#include <string>

namespace ipmonitor {

static NSString * const kLastKnownIPKey = @"LastKnownPublicIP";
constexpr NSTimeInterval kPollInterval = 300.0;

struct MonitorState {
    std::optional<std::string> currentIP;
    std::optional<std::string> lastError;
};

std::string ToStdString(NSString *value) {
    return value == nil ? std::string() : std::string(value.UTF8String);
}

NSString *ToNSString(const std::string &value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

bool LooksLikeIPAddress(const std::string &value) {
    static const std::regex kIPPattern(
        R"(^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+)$)"
    );

    return std::regex_match(value, kIPPattern);
}

}  // namespace ipmonitor

@interface AppDelegate : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate>

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) NSMenuItem *currentIPMenuItem;
@property (nonatomic, strong) NSMenuItem *lastCheckedMenuItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *notificationsMenuItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSDate *lastCheckedAt;
@property (nonatomic, assign) BOOL notificationsAuthorized;
@property (nonatomic, assign) ipmonitor::MonitorState monitorState;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [self configureMenu];

    NSString *storedIP = [[NSUserDefaults standardUserDefaults] stringForKey:ipmonitor::kLastKnownIPKey];
    if (storedIP != nil) {
        self.monitorState.currentIP = ipmonitor::ToStdString(storedIP);
    }

    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;

    [self requestNotificationPermission];
    [self updateMenu];
    [self performCheck:NO];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:ipmonitor::kPollInterval
                                                  target:self
                                                selector:@selector(timerFired:)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
}

- (void)configureMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    if (self.statusItem.button != nil) {
        self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"network"
                                             accessibilityDescription:@"Public IP Monitor"];
        self.statusItem.button.toolTip = @"Public IP Monitor";
    }

    self.menu = [[NSMenu alloc] init];
    self.menu.autoenablesItems = NO;

    self.currentIPMenuItem = [[NSMenuItem alloc] initWithTitle:@"Current IP: Checking..."
                                                        action:nil
                                                 keyEquivalent:@""];
    self.lastCheckedMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last checked: Never"
                                                          action:nil
                                                   keyEquivalent:@""];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Status: Starting up"
                                                     action:nil
                                              keyEquivalent:@""];
    self.notificationsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Notifications: Pending permission"
                                                            action:nil
                                                     keyEquivalent:@""];

    self.currentIPMenuItem.enabled = NO;
    self.lastCheckedMenuItem.enabled = NO;
    self.statusMenuItem.enabled = NO;
    self.notificationsMenuItem.enabled = NO;

    NSMenuItem *checkNowItem = [[NSMenuItem alloc] initWithTitle:@"Check Now"
                                                          action:@selector(checkNow:)
                                                   keyEquivalent:@"r"];
    checkNowItem.target = self;

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                      action:@selector(quit:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;

    [self.menu addItem:self.currentIPMenuItem];
    [self.menu addItem:self.lastCheckedMenuItem];
    [self.menu addItem:self.statusMenuItem];
    [self.menu addItem:self.notificationsMenuItem];
    [self.menu addItem:[NSMenuItem separatorItem]];
    [self.menu addItem:checkNowItem];
    [self.menu addItem:[NSMenuItem separatorItem]];
    [self.menu addItem:quitItem];

    self.statusItem.menu = self.menu;
}

- (void)requestNotificationPermission {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];

    [notificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                                         UNAuthorizationOptionSound |
                                                         UNAuthorizationOptionBadge)
                                      completionHandler:^(BOOL granted, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.notificationsAuthorized = granted;

            if (error != nil) {
                self.monitorState.lastError = ipmonitor::ToStdString(
                    [NSString stringWithFormat:@"Notification permission failed: %@",
                     error.localizedDescription]
                );
            }

            [self updateMenu];
        });
    }];
}

- (void)timerFired:(NSTimer *)timer {
    [self performCheck:YES];
}

- (void)checkNow:(id)sender {
    [self performCheck:YES];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

- (void)performCheck:(BOOL)notifyOnChange {
    NSURL *url = [NSURL URLWithString:@"https://ip.me"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:20.0];
    [request setValue:@"text/plain" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData * _Nullable data,
                                                         NSURLResponse * _Nullable response,
                                                         NSError * _Nullable error) {
        if (error != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self recordFailure:[NSString stringWithFormat:@"Request failed: %@",
                                     error.localizedDescription]];
            });
            return;
        }

        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode < 200 || httpResponse.statusCode > 299) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self recordFailure:[NSString stringWithFormat:@"Unexpected HTTP status: %ld",
                                         (long)httpResponse.statusCode]];
                });
                return;
            }
        }

        if (data == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self recordFailure:@"ip.me returned no response body"];
            });
            return;
        }

        NSString *rawValue = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *trimmedValue = [rawValue stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        std::string ipValue = ipmonitor::ToStdString(trimmedValue);

        if (!ipmonitor::LooksLikeIPAddress(ipValue)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self recordFailure:[NSString stringWithFormat:@"Unexpected response from ip.me: %@",
                                     trimmedValue]];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordSuccess:ipValue notifyOnChange:notifyOnChange];
        });
    }] resume];
}

- (void)recordSuccess:(const std::string &)ip notifyOnChange:(BOOL)notifyOnChange {
    std::optional<std::string> previousIP = self.monitorState.currentIP;

    self.monitorState.currentIP = ip;
    self.monitorState.lastError.reset();
    self.lastCheckedAt = [NSDate date];

    [[NSUserDefaults standardUserDefaults] setObject:ipmonitor::ToNSString(ip)
                                              forKey:ipmonitor::kLastKnownIPKey];

    if (previousIP.has_value() && previousIP.value() != ip && notifyOnChange) {
        [self sendNotificationFromIP:previousIP.value() toIP:ip];
    }

    [self updateMenu];
}

- (void)recordFailure:(NSString *)message {
    self.monitorState.lastError = ipmonitor::ToStdString(message);
    self.lastCheckedAt = [NSDate date];
    [self updateMenu];
}

- (void)updateMenu {
    if (self.monitorState.currentIP.has_value()) {
        self.currentIPMenuItem.title = [NSString stringWithFormat:@"Current IP: %@",
                                        ipmonitor::ToNSString(self.monitorState.currentIP.value())];
    } else {
        self.currentIPMenuItem.title = @"Current IP: Unknown";
    }

    if (self.lastCheckedAt != nil) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterMediumStyle;

        self.lastCheckedMenuItem.title = [NSString stringWithFormat:@"Last checked: %@",
                                          [formatter stringFromDate:self.lastCheckedAt]];
    } else {
        self.lastCheckedMenuItem.title = @"Last checked: Never";
    }

    if (self.monitorState.lastError.has_value()) {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: %@",
                                     ipmonitor::ToNSString(self.monitorState.lastError.value())];
    } else {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: Monitoring every %d seconds",
                                     (int)ipmonitor::kPollInterval];
    }

    self.notificationsMenuItem.title = self.notificationsAuthorized
        ? @"Notifications: Enabled"
        : @"Notifications: Not enabled";
}

- (void)sendNotificationFromIP:(const std::string &)oldIP toIP:(const std::string &)newIP {
    if (!self.notificationsAuthorized) {
        return;
    }

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Public IP Changed";
    content.body = [NSString stringWithFormat:@"Old: %@\nNew: %@",
                    ipmonitor::ToNSString(oldIP),
                    ipmonitor::ToNSString(newIP)];
    content.sound = [UNNotificationSound defaultSound];

    NSString *identifier = [[NSUUID UUID] UUIDString];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];

    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionSound);
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        AppDelegate *delegate = [[AppDelegate alloc] init];
        NSApplication *application = [NSApplication sharedApplication];
        application.delegate = delegate;
        [application run];
        return EXIT_SUCCESS;
    }
}
