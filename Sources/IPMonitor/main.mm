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

NSArray<NSString *> *ResolverURLs() {
    static NSArray<NSString *> *urls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        urls = @[
            @"https://api64.ipify.org",
            @"https://ifconfig.me/ip"
        ];
    });
    return urls;
}

NSString *TruncatedSingleLine(NSString *value, NSUInteger limit) {
    NSString *flattened = [[value stringByReplacingOccurrencesOfString:@"\r" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];

    if (flattened.length <= limit) {
        return flattened;
    }

    return [[flattened substringToIndex:limit] stringByAppendingString:@"..."];
}

}  // namespace ipmonitor

@interface AppDelegate : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate> {
    ipmonitor::MonitorState _monitorState;
}

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) NSMenuItem *currentIPMenuItem;
@property (nonatomic, strong) NSMenuItem *lastCheckedMenuItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *notificationsMenuItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSDate *lastCheckedAt;
@property (nonatomic, assign) BOOL notificationsAuthorized;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [self configureMenu];

    NSString *storedIP = [[NSUserDefaults standardUserDefaults] stringForKey:ipmonitor::kLastKnownIPKey];
    if (storedIP != nil) {
        _monitorState.currentIP = ipmonitor::ToStdString(storedIP);
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
                _monitorState.lastError = ipmonitor::ToStdString(
                    [NSString stringWithFormat:@"Notification permission failed: %@",
                     error.localizedDescription]
                );
                NSLog(@"Notification permission failed: %@", error);
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

- (void)performCheckWithResolverIndex:(NSUInteger)resolverIndex
                       notifyOnChange:(BOOL)notifyOnChange
                      failureMessages:(NSMutableArray<NSString *> *)failureMessages {
    NSArray<NSString *> *resolverURLs = ipmonitor::ResolverURLs();
    if (resolverIndex >= resolverURLs.count) {
        NSString *combinedFailure = failureMessages.count > 0
            ? [failureMessages componentsJoinedByString:@" | "]
            : @"No IP resolvers configured";
        [self recordFailure:combinedFailure];
        return;
    }

    NSString *resolverURLString = resolverURLs[resolverIndex];
    NSURL *url = [NSURL URLWithString:resolverURLString];
    if (url == nil) {
        [failureMessages addObject:[NSString stringWithFormat:@"Invalid resolver URL: %@",
                                    resolverURLString]];
        [self performCheckWithResolverIndex:(resolverIndex + 1)
                             notifyOnChange:notifyOnChange
                            failureMessages:failureMessages];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:20.0];
    [request setValue:@"text/plain" forHTTPHeaderField:@"Accept"];
    [request setValue:@"IPMonitor/1.0" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData * _Nullable data,
                                                         NSURLResponse * _Nullable response,
                                                         NSError * _Nullable error) {
        NSString *resolverName = url.host ?: resolverURLString;

        if (error != nil) {
            NSLog(@"%@ request failed: %@", resolverName, error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [failureMessages addObject:[NSString stringWithFormat:@"%@ request failed: %@",
                                            resolverName,
                                            error.localizedDescription]];
                [self performCheckWithResolverIndex:(resolverIndex + 1)
                                     notifyOnChange:notifyOnChange
                                    failureMessages:failureMessages];
            });
            return;
        }

        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode < 200 || httpResponse.statusCode > 299) {
                NSLog(@"%@ returned HTTP status %ld", resolverName, (long)httpResponse.statusCode);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [failureMessages addObject:[NSString stringWithFormat:@"%@ returned HTTP %ld",
                                                resolverName,
                                                (long)httpResponse.statusCode]];
                    [self performCheckWithResolverIndex:(resolverIndex + 1)
                                         notifyOnChange:notifyOnChange
                                        failureMessages:failureMessages];
                });
                return;
            }
        }

        if (data == nil) {
            NSLog(@"%@ returned an empty response body", resolverName);
            dispatch_async(dispatch_get_main_queue(), ^{
                [failureMessages addObject:[NSString stringWithFormat:@"%@ returned no response body",
                                            resolverName]];
                [self performCheckWithResolverIndex:(resolverIndex + 1)
                                     notifyOnChange:notifyOnChange
                                    failureMessages:failureMessages];
            });
            return;
        }

        NSString *rawValue = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (rawValue == nil) {
            NSLog(@"%@ returned non-UTF8 data (%lu bytes)", resolverName, (unsigned long)data.length);
            dispatch_async(dispatch_get_main_queue(), ^{
                [failureMessages addObject:[NSString stringWithFormat:@"%@ returned unreadable data",
                                            resolverName]];
                [self performCheckWithResolverIndex:(resolverIndex + 1)
                                     notifyOnChange:notifyOnChange
                                    failureMessages:failureMessages];
            });
            return;
        }

        NSString *trimmedValue = [rawValue stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        std::string ipValue = ipmonitor::ToStdString(trimmedValue);

        if (!ipmonitor::LooksLikeIPAddress(ipValue)) {
            NSString *shortPayload = ipmonitor::TruncatedSingleLine(trimmedValue, 100);
            NSLog(@"%@ returned unexpected payload: %@", resolverName, shortPayload);
            dispatch_async(dispatch_get_main_queue(), ^{
                [failureMessages addObject:[NSString stringWithFormat:@"%@ returned non-IP data: %@",
                                            resolverName,
                                            shortPayload]];
                [self performCheckWithResolverIndex:(resolverIndex + 1)
                                     notifyOnChange:notifyOnChange
                                    failureMessages:failureMessages];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordSuccess:ipValue
                 notifyOnChange:notifyOnChange
                       resolver:resolverName];
        });
    }] resume];
}

- (void)performCheck:(BOOL)notifyOnChange {
    _monitorState.lastError = ipmonitor::ToStdString(@"Checking public IP resolver...");
    [self updateMenu];
    [self performCheckWithResolverIndex:0
                         notifyOnChange:notifyOnChange
                        failureMessages:[NSMutableArray array]];
}

- (void)recordSuccess:(const std::string &)ip
       notifyOnChange:(BOOL)notifyOnChange
             resolver:(NSString *)resolverName {
    std::optional<std::string> previousIP = _monitorState.currentIP;

    _monitorState.currentIP = ip;
    _monitorState.lastError.reset();
    self.lastCheckedAt = [NSDate date];

    [[NSUserDefaults standardUserDefaults] setObject:ipmonitor::ToNSString(ip)
                                              forKey:ipmonitor::kLastKnownIPKey];

    NSLog(@"Public IP updated to %@ via %@", ipmonitor::ToNSString(ip), resolverName);

    if (previousIP.has_value() && previousIP.value() != ip && notifyOnChange) {
        [self sendNotificationFromIP:previousIP.value() toIP:ip];
    }

    [self updateMenu];
}

- (void)recordFailure:(NSString *)message {
    _monitorState.lastError = ipmonitor::ToStdString(message);
    self.lastCheckedAt = [NSDate date];
    [self updateMenu];
}

- (void)updateMenu {
    if (_monitorState.currentIP.has_value()) {
        self.currentIPMenuItem.title = [NSString stringWithFormat:@"Current IP: %@",
                                        ipmonitor::ToNSString(_monitorState.currentIP.value())];
    } else {
        self.currentIPMenuItem.title = _monitorState.lastError.has_value()
            ? @"Current IP: Unavailable"
            : @"Current IP: Unknown";
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

    if (_monitorState.lastError.has_value()) {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: %@",
                                     ipmonitor::ToNSString(_monitorState.lastError.value())];
    } else {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: Monitoring every %d seconds",
                                     (int)ipmonitor::kPollInterval];
    }

    self.notificationsMenuItem.title = self.notificationsAuthorized
        ? @"Notifications: Enabled"
        : @"Notifications: Not enabled";

    if (self.statusItem.button != nil) {
        NSString *tooltipIP = _monitorState.currentIP.has_value()
            ? ipmonitor::ToNSString(_monitorState.currentIP.value())
            : @"Unavailable";
        NSString *tooltipStatus = _monitorState.lastError.has_value()
            ? ipmonitor::ToNSString(_monitorState.lastError.value())
            : @"Monitoring";
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"Public IP: %@\n%@", tooltipIP, tooltipStatus];
    }
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
