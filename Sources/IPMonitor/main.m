#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

static NSString * const kLastKnownIPKey = @"LastKnownPublicIP";
static NSTimeInterval const kPollInterval = 300.0;

@interface AppDelegate : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate>

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) NSMenuItem *currentIPMenuItem;
@property (nonatomic, strong) NSMenuItem *lastCheckedMenuItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *notificationsMenuItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *currentIP;
@property (nonatomic, strong) NSDate *lastCheckedAt;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, assign) BOOL notificationsAuthorized;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [self configureMenu];

    self.currentIP = [[NSUserDefaults standardUserDefaults] stringForKey:kLastKnownIPKey];

    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;

    [self requestNotificationPermission];
    [self updateMenu];
    [self performCheck:NO];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:kPollInterval
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
                self.lastError = [NSString stringWithFormat:@"Notification permission failed: %@",
                                  error.localizedDescription];
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

        if (![self looksLikeIPAddress:trimmedValue]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self recordFailure:[NSString stringWithFormat:@"Unexpected response from ip.me: %@",
                                     trimmedValue]];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordSuccess:trimmedValue notifyOnChange:notifyOnChange];
        });
    }] resume];
}

- (BOOL)looksLikeIPAddress:(NSString *)value {
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"^([0-9]{1,3}(\\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+)$"
                             options:0
                               error:&error];

    if (regex == nil || error != nil) {
        return NO;
    }

    NSRange fullRange = NSMakeRange(0, value.length);
    return [regex firstMatchInString:value options:0 range:fullRange] != nil;
}

- (void)recordSuccess:(NSString *)ip notifyOnChange:(BOOL)notifyOnChange {
    NSString *previousIP = self.currentIP;

    self.currentIP = ip;
    self.lastCheckedAt = [NSDate date];
    self.lastError = nil;

    [[NSUserDefaults standardUserDefaults] setObject:ip forKey:kLastKnownIPKey];

    if (previousIP != nil && ![previousIP isEqualToString:ip] && notifyOnChange) {
        [self sendNotificationFromIP:previousIP toIP:ip];
    }

    [self updateMenu];
}

- (void)recordFailure:(NSString *)message {
    self.lastCheckedAt = [NSDate date];
    self.lastError = message;
    [self updateMenu];
}

- (void)updateMenu {
    if (self.currentIP != nil) {
        self.currentIPMenuItem.title = [NSString stringWithFormat:@"Current IP: %@", self.currentIP];
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

    if (self.lastError != nil) {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: %@", self.lastError];
    } else {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: Monitoring every %d seconds",
                                     (int)kPollInterval];
    }

    self.notificationsMenuItem.title = self.notificationsAuthorized
        ? @"Notifications: Enabled"
        : @"Notifications: Not enabled";
}

- (void)sendNotificationFromIP:(NSString *)oldIP toIP:(NSString *)newIP {
    if (!self.notificationsAuthorized) {
        return;
    }

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Public IP Changed";
    content.body = [NSString stringWithFormat:@"Old: %@\nNew: %@", oldIP, newIP];
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
