/* Copyright Urban Airship and Contributors */

#import "UACordovaPluginManager.h"

#if __has_include(<AirshipKit/AirshipLib.h>)
#import <AirshipKit/AirshipLib.h>
#elif __has_include("AirshipLib.h")
#import "AirshipLib.h"
#else
@import AirshipKit;
#endif

#import "UACordovaEvent.h"
#import "UACordovaDeepLinkEvent.h"
#import "UACordovaInboxUpdatedEvent.h"
#import "UACordovaNotificationOpenedEvent.h"
#import "UACordovaNotificationOptInEvent.h"
#import "UACordovaPushEvent.h"
#import "UACordovaRegistrationEvent.h"
#import "UACordovaShowInboxEvent.h"

// Config keys
NSString *const ProductionAppKeyConfigKey = @"com.urbanairship.production_app_key";
NSString *const ProductionAppSecretConfigKey = @"com.urbanairship.production_app_secret";
NSString *const DevelopmentAppKeyConfigKey = @"com.urbanairship.development_app_key";
NSString *const DevelopmentAppSecretConfigKey = @"com.urbanairship.development_app_secret";
NSString *const ProductionLogLevelKey = @"com.urbanairship.production_log_level";
NSString *const DevelopmentLogLevelKey = @"com.urbanairship.development_log_level";
NSString *const ProductionConfigKey = @"com.urbanairship.in_production";
NSString *const EnablePushOnLaunchConfigKey = @"com.urbanairship.enable_push_onlaunch";
NSString *const ClearBadgeOnLaunchConfigKey = @"com.urbanairship.clear_badge_onlaunch";
NSString *const EnableAnalyticsConfigKey = @"com.urbanairship.enable_analytics";
NSString *const AutoLaunchMessageCenterKey = @"com.urbanairship.auto_launch_message_center";
NSString *const NotificationPresentationAlertKey = @"com.urbanairship.ios_foreground_notification_presentation_alert";
NSString *const NotificationPresentationBadgeKey = @"com.urbanairship.ios_foreground_notification_presentation_badge";
NSString *const NotificationPresentationSoundKey = @"com.urbanairship.ios_foreground_notification_presentation_sound";
NSString *const CloudSiteConfigKey = @"com.urbanairship.site";

NSString *const CloudSiteEUString = @"EU";

// Events
NSString *const CategoriesPlistPath = @"UACustomNotificationCategories";


@interface UACordovaPluginManager() <UARegistrationDelegate, UAPushNotificationDelegate, UAInboxDelegate, UADeepLinkDelegate>
@property (nonatomic, strong) NSDictionary *defaultConfig;
@property (nonatomic, strong) NSMutableArray<NSObject<UACordovaEvent> *> *pendingEvents;
@property (nonatomic, assign) BOOL isAirshipReady;

@end
@implementation UACordovaPluginManager

- (void)dealloc {
    [UAirship push].pushNotificationDelegate = nil;
    [UAirship push].registrationDelegate = nil;
    [UAirship inbox].delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithDefaultConfig:(NSDictionary *)defaultConfig {
    self = [super init];

    if (self) {
        self.defaultConfig = defaultConfig;
        self.pendingEvents = [NSMutableArray array];
    }

    return self;
}

+ (instancetype)pluginManagerWithDefaultConfig:(NSDictionary *)defaultConfig {
    return [[UACordovaPluginManager alloc] initWithDefaultConfig:defaultConfig];
}

- (void)attemptTakeOff {
    if (self.isAirshipReady) {
        return;
    }

    UAConfig *config = [self createAirshipConfig];
    if (![config validate]) {
        return;
    }

    [UAirship takeOff:config];

    [UAirship push].userPushNotificationsEnabledByDefault = [[self configValueForKey:EnablePushOnLaunchConfigKey] boolValue];

    if ([[self configValueForKey:ClearBadgeOnLaunchConfigKey] boolValue]) {
        [[UAirship push] resetBadge];
    }

    [self loadCustomNotificationCategories];

    [UAirship push].pushNotificationDelegate = self;
    [UAirship push].registrationDelegate = self;
    [UAirship inbox].delegate = self;
    [UAirship shared].deepLinkDelegate = self;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(inboxUpdated)
                                                 name:UAInboxMessageListUpdatedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(channelRegistrationSucceeded:)
                                                 name:UAChannelUpdatedEvent
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(channelRegistrationFailed)
                                                 name:UAChannelRegistrationFailedEvent
                                               object:nil];



    self.isAirshipReady = YES;
}

- (void)loadCustomNotificationCategories {
    NSString *categoriesPath = [[NSBundle mainBundle] pathForResource:CategoriesPlistPath ofType:@"plist"];
    NSSet *customNotificationCategories = [UANotificationCategories createCategoriesFromFile:categoriesPath];

    if (customNotificationCategories.count) {
        UA_LDEBUG(@"Registering custom notification categories: %@", customNotificationCategories);
        [UAirship push].customCategories = customNotificationCategories;
        [[UAirship push] updateRegistration];
    }
}

- (UAConfig *)createAirshipConfig {
    UAConfig *airshipConfig = [UAConfig config];
    airshipConfig.productionAppKey = [self configValueForKey:ProductionAppKeyConfigKey];
    airshipConfig.productionAppSecret = [self configValueForKey:ProductionAppSecretConfigKey];
    airshipConfig.developmentAppKey = [self configValueForKey:DevelopmentAppKeyConfigKey];
    airshipConfig.developmentAppSecret = [self configValueForKey:DevelopmentAppSecretConfigKey];

    NSString *cloudSite = [self configValueForKey:CloudSiteConfigKey];
    airshipConfig.site = [UACordovaPluginManager parseCloudSiteString:cloudSite];

    if ([self configValueForKey:ProductionConfigKey] != nil) {
        airshipConfig.inProduction = [[self configValueForKey:ProductionConfigKey] boolValue];
    }

    airshipConfig.developmentLogLevel = [self parseLogLevel:[self configValueForKey:DevelopmentLogLevelKey]
                                            defaultLogLevel:UALogLevelDebug];

    airshipConfig.productionLogLevel = [self parseLogLevel:[self configValueForKey:ProductionLogLevelKey]
                                           defaultLogLevel:UALogLevelError];

    if ([self configValueForKey:EnableAnalyticsConfigKey] != nil) {
        airshipConfig.analyticsEnabled = [[self configValueForKey:EnableAnalyticsConfigKey] boolValue];
    }

    return airshipConfig;
}

- (id)configValueForKey:(NSString *)key {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (value != nil) {
        return value;
    }

    return self.defaultConfig[key];
}

- (BOOL)autoLaunchMessageCenter {
    if ([self configValueForKey:AutoLaunchMessageCenterKey] == nil) {
        return YES;
    }

    return [[self configValueForKey:AutoLaunchMessageCenterKey] boolValue];
}

- (void)setAutoLaunchMessageCenter:(BOOL)autoLaunchMessageCenter {
    [[NSUserDefaults standardUserDefaults] setValue:@(autoLaunchMessageCenter) forKey:AutoLaunchMessageCenterKey];
}

- (void)setProductionAppKey:(NSString *)appKey appSecret:(NSString *)appSecret {
    [[NSUserDefaults standardUserDefaults] setValue:appKey forKey:ProductionAppKeyConfigKey];
    [[NSUserDefaults standardUserDefaults] setValue:appSecret forKey:ProductionAppSecretConfigKey];
}

- (void)setDevelopmentAppKey:(NSString *)appKey appSecret:(NSString *)appSecret {
    [[NSUserDefaults standardUserDefaults] setValue:appKey forKey:DevelopmentAppKeyConfigKey];
    [[NSUserDefaults standardUserDefaults] setValue:appSecret forKey:DevelopmentAppSecretConfigKey];
}

- (void)setCloudSite:(NSString *)site {
    [[NSUserDefaults standardUserDefaults] setValue:site forKey:CloudSiteConfigKey];
}

- (void)setPresentationOptions:(NSUInteger)options {
    [[NSUserDefaults standardUserDefaults] setValue:@(options & UNNotificationPresentationOptionAlert) forKey:NotificationPresentationAlertKey];
    [[NSUserDefaults standardUserDefaults] setValue:@(options & UNNotificationPresentationOptionBadge) forKey:NotificationPresentationBadgeKey];
    [[NSUserDefaults standardUserDefaults] setValue:@(options & UNNotificationPresentationOptionSound) forKey:NotificationPresentationSoundKey];
}

-(NSInteger)parseLogLevel:(id)logLevel defaultLogLevel:(UALogLevel)defaultValue  {
    if (![logLevel isKindOfClass:[NSString class]] || ![logLevel length]) {
        return defaultValue;
    }

    NSString *normalizedLogLevel = [[logLevel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];

    if ([normalizedLogLevel isEqualToString:@"verbose"]) {
        return UALogLevelTrace;
    } else if ([normalizedLogLevel isEqualToString:@"debug"]) {
        return UALogLevelDebug;
    } else if ([normalizedLogLevel isEqualToString:@"info"]) {
        return UALogLevelInfo;
    } else if ([normalizedLogLevel isEqualToString:@"warning"]) {
        return UALogLevelWarn;
    } else if ([normalizedLogLevel isEqualToString:@"error"]) {
        return UALogLevelError;
    } else if ([normalizedLogLevel isEqualToString:@"none"]) {
        return UALogLevelNone;
    }

    return defaultValue;
}

+ (UACloudSite)parseCloudSiteString:(NSString *)site {
    if ([CloudSiteEUString caseInsensitiveCompare:site] == NSOrderedSame) {
        return UACloudSiteEU;
    } else {
        return UACloudSiteUS;
    }
}

#pragma mark UAInboxDelegate

- (void)showMessageForID:(NSString *)messageID {
    if (self.autoLaunchMessageCenter) {
        [[UAirship messageCenter] displayMessageForID:messageID];
    } else {
        [self fireEvent:[UACordovaShowInboxEvent eventWithMessageID:messageID]];
    }
}

- (void)showInbox {
    if (self.autoLaunchMessageCenter) {
        [[UAirship messageCenter] display];
    } else {
        [self fireEvent:[UACordovaShowInboxEvent event]];
    }
}

- (void)inboxUpdated {
    UA_LDEBUG(@"Inbox updated");
    [self fireEvent:[UACordovaInboxUpdatedEvent event]];
}

#pragma mark UAPushNotificationDelegate

-(void)receivedForegroundNotification:(UANotificationContent *)notificationContent completionHandler:(void (^)(void))completionHandler {
    UA_LDEBUG(@"Received a notification while the app was already in the foreground %@", notificationContent);

    [self fireEvent:[UACordovaPushEvent eventWithNotificationContent:notificationContent]];

    completionHandler();
}

- (void)receivedBackgroundNotification:(UANotificationContent *)notificationContent
                     completionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {

    UA_LDEBUG(@"Received a background notification %@", notificationContent);

    [self fireEvent:[UACordovaPushEvent eventWithNotificationContent:notificationContent]];

    completionHandler(UIBackgroundFetchResultNoData);
}

-(void)receivedNotificationResponse:(UANotificationResponse *)notificationResponse completionHandler:(void (^)(void))completionHandler {
    UA_LDEBUG(@"The application was launched or resumed from a notification %@", notificationResponse);

    UACordovaNotificationOpenedEvent *event = [UACordovaNotificationOpenedEvent eventWithNotificationResponse:notificationResponse];
    self.lastReceivedNotificationResponse = event.data;
    [self fireEvent:event];

    completionHandler();
}

- (UNNotificationPresentationOptions)extendPresentationOptions:(UNNotificationPresentationOptions)options notification:(UNNotification *)notification {
    if ([[self configValueForKey:NotificationPresentationAlertKey] boolValue]) {
        options = options | UNNotificationPresentationOptionAlert;
    }

    if ([[self configValueForKey:NotificationPresentationBadgeKey] boolValue]) {
        options = options | UNNotificationPresentationOptionBadge;
    }

    if ([[self configValueForKey:NotificationPresentationSoundKey] boolValue]) {
        options = options | UNNotificationPresentationOptionSound;
    }

    return options;
}

#pragma mark UADeepLinkDelegate

-(void)receivedDeepLink:(NSURL *_Nonnull)url completionHandler:(void (^_Nonnull)(void))completionHandler {
    self.lastReceivedDeepLink = [url absoluteString];
    [self fireEvent:[UACordovaDeepLinkEvent eventWithDeepLink:url]];
    completionHandler();
}


#pragma mark Channel Registration Events

- (void)channelRegistrationSucceeded:(NSNotification *)notification {
    NSString *channelID = notification.userInfo[UAChannelUpdatedEventChannelKey];
    NSString *deviceToken = [UAirship push].deviceToken;

    UA_LINFO(@"Channel registration successful %@.", channelID);

    [self fireEvent:[UACordovaRegistrationEvent registrationSucceededEventWithChannelID:channelID deviceToken:deviceToken]];
}

- (void)channelRegistrationFailed {
    UA_LINFO(@"Channel registration failed.");
    [self fireEvent:[UACordovaRegistrationEvent registrationFailedEvent]];
}

#pragma mark UARegistrationDelegate

- (void)notificationAuthorizedSettingsDidChange:(UAAuthorizedNotificationSettings)authorizedSettings {
    UACordovaNotificationOptInEvent *event = [UACordovaNotificationOptInEvent eventWithAuthorizedSettings:authorizedSettings];
    [self fireEvent:event];
}

- (void)fireEvent:(NSObject<UACordovaEvent> *)event {
    id strongDelegate = self.delegate;

    if (strongDelegate && [strongDelegate notifyListener:event.type data:event.data]) {
        UA_LTRACE(@"Cordova plugin manager delegate notified with event of type:%@ with data:%@", event.type, event.data);

        return;
    }

    UA_LTRACE(@"No cordova plugin manager delegate available, storing pending event of type:%@ with data:%@", event.type, event.data);

    // Add pending event
    [self.pendingEvents addObject:event];
}

- (void)setDelegate:(id<UACordovaPluginManagerDelegate>)delegate {
    _delegate = delegate;

    if (delegate) {
        @synchronized(self.pendingEvents) {
            UA_LTRACE(@"Cordova plugin manager delegate set:%@", delegate);

            NSDictionary *events = [self.pendingEvents copy];
            [self.pendingEvents removeAllObjects];

            for (NSObject<UACordovaEvent> *event in events) {
                [self fireEvent:event];
            }
        }
    }
}

@end
