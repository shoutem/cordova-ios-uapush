#import "PushNotificationPlugin.h"
#import "UAPush.h"
#import "UAirship.h"
#import "UAAnalytics.h"
#import "UALocationService.h"
#import "UAConfig.h"
#import "NSJSONSerialization+UAAdditions.h"

typedef id (^UACordovaCallbackBlock)(NSArray *args);
typedef void (^UACordovaVoidCallbackBlock)(NSArray *args);

@interface PushNotificationPlugin()
- (void)takeOff;
@property (nonatomic, copy) NSDictionary *incomingNotification;
@property (nonatomic, assign) BOOL disablePush;
@end

@implementation PushNotificationPlugin

- (void)pluginInitialize {
    UA_LINFO("Initializing PushNotificationPlugin");
    
    NSDictionary *settingsDictionary = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"settings" ofType:@"plist"]];
    self.disablePush = [[settingsDictionary objectForKey:@"disable_push"] boolValue];
    
    [self takeOff];
}

- (void)takeOff {
    //Init Airship launch options
    UAConfig *config = [UAConfig defaultConfig];
    
    NSDictionary *settings = self.commandDelegate.settings;
    
    config.productionAppKey = [settings valueForKey:@"com.urbanairship.production_app_key"] ?: config.productionAppKey;
    config.productionAppSecret = [settings valueForKey:@"com.urbanairship.production_app_secret"] ?: config.productionAppSecret;
    config.developmentAppKey = [settings valueForKey:@"com.urbanairship.development_app_key"] ?: config.developmentAppKey;
    config.developmentAppSecret = [settings valueForKey:@"com.urbanairship.development_app_secret"] ?: config.developmentAppSecret;
    if ([settings valueForKey:@"com.urbanairship.in_production"]) {
        config.inProduction = [[settings valueForKey:@"com.urbanairship.in_production"] boolValue];
    }
    
    BOOL enablePushOnLaunch = !self.disablePush && [[settings valueForKey:@"com.urbanairship.enable_push_onlaunch"] boolValue];
    [[UAPush shared] setUserPushNotificationsEnabledByDefault:enablePushOnLaunch];
    
    // Disable setting tags from the device on registration so we don't clear any tags set via REST API
    // For more info check getTagsFromServer: comment
    [UAPush shared].deviceTagsEnabled = NO;
    // Create Airship singleton that's used to talk to Urban Airship servers.
    // Please populate AirshipConfig.plist with your info from http://go.urbanairship.com
    [UAirship takeOff:config];
    
    [[UAPush shared] resetBadge];//zero badge on startup
    [UAPush shared].pushNotificationDelegate = self;
    [UAPush shared].registrationDelegate = self;
    
    [[UAirship shared].locationService startReportingSignificantLocationChanges];
}

- (void)failWithCallbackID:(NSString *)callbackID {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR];
    [self.commandDelegate sendPluginResult:result callbackId:callbackID];
}

- (void)succeedWithPluginResult:(CDVPluginResult *)result withCallbackID:(NSString *)callbackID {
    [self.commandDelegate sendPluginResult:result callbackId:callbackID];
}

- (BOOL)validateArguments:(NSArray *)args forExpectedTypes:(NSArray *)types {
    if (args.count == types.count) {
        for (int i = 0; i < args.count; i++) {
            if (![[args objectAtIndex:i] isKindOfClass:[types objectAtIndex:i]]) {
                //fail when when there is a type mismatch an expected and passed parameter
                UA_LERR(@"Type mismatch in cordova callback: expected %@ and received %@",
                        [types description], [args description]);
                return NO;
            }
        }
    } else {
        //fail when there is a number mismatch
        UA_LERR(@"Parameter number mismatch in cordova callback: expected %lu and received %lu", (unsigned long)types.count, (unsigned long)args.count);
        return NO;
    }
    
    return YES;
}

- (CDVPluginResult *)pluginResultForValue:(id)value {
    CDVPluginResult *result;
    
    /*
     NSSString -> String
     NSNumber --> (Integer | Double)
     NSArray --> Array
     NSDictionary --> Object
     nil --> no return value
     */
    
    if ([value isKindOfClass:[NSString class]]) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                   messageAsString:[value stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    } else if ([value isKindOfClass:[NSNumber class]]) {
        CFNumberType numberType = CFNumberGetType((CFNumberRef)value);
        //note: underlyingly, BOOL values are typedefed as char
        if (numberType == kCFNumberIntType || numberType == kCFNumberCharType) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:[value intValue]];
        } else  {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:[value doubleValue]];
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:value];
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:value];
    } else if ([value isKindOfClass:[NSNull class]]) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        UA_LERR(@"Cordova callback block returned unrecognized type: %@", NSStringFromClass([value class]));
        return nil;
    }
    
    return result;
}

- (void)performCallbackWithCommand:(CDVInvokedUrlCommand*)command expecting:(NSArray *)expected withBlock:(UACordovaCallbackBlock)block {
    
    dispatch_async(dispatch_get_main_queue(), ^{
        //if we're expecting any arguments
        if (expected) {
            if (![self validateArguments:command.arguments forExpectedTypes:expected]) {
                [self failWithCallbackID:command.callbackId];
                return;
            }
        } else if(command.arguments.count) {
            UA_LERR(@"Parameter number mismatch: expected 0 and received %lu", (unsigned long)command.arguments.count);
            [self failWithCallbackID:command.callbackId];
            return;
        }
        
        //execute the block. the return value should be an obj-c object holding what we want to pass back to cordova.
        id returnValue = block(command.arguments);
        
        CDVPluginResult *result = [self pluginResultForValue:returnValue];
        if (result) {
            [self succeedWithPluginResult:result withCallbackID:command.callbackId];
        } else {
            [self failWithCallbackID:command.callbackId];
        }
    });
}

- (void)performCallbackWithCommand:(CDVInvokedUrlCommand*)command expecting:(NSArray *)expected withVoidBlock:(UACordovaVoidCallbackBlock)block {
    [self performCallbackWithCommand:command expecting:expected withBlock:^(NSArray *args) {
        block(args);
        return [NSNull null];
    }];
}

- (NSString *)alertForUserInfo:(NSDictionary *)userInfo {
    NSString *alert = @"";
    
    if ([[userInfo allKeys] containsObject:@"aps"]) {
        NSDictionary *apsDict = [userInfo objectForKey:@"aps"];
        //TODO: what do we want to do in the case of a localized alert dictionary?
        if ([[apsDict valueForKey:@"alert"] isKindOfClass:[NSString class]]) {
            alert = [apsDict valueForKey:@"alert"];
        }
    }
    
    return alert;
}

- (NSMutableDictionary *)extrasForUserInfo:(NSDictionary *)userInfo {
    
    // remove extraneous key/value pairs
    NSMutableDictionary *extras = [NSMutableDictionary dictionaryWithDictionary:userInfo];
    
    if([[extras allKeys] containsObject:@"aps"]) {
        [extras removeObjectForKey:@"aps"];
    }
    if([[extras allKeys] containsObject:@"_uamid"]) {
        [extras removeObjectForKey:@"_uamid"];
    }
    if([[extras allKeys] containsObject:@"_"]) {
        [extras removeObjectForKey:@"_"];
    }
    
    return extras;
}

#pragma mark - Phonegap bridge
- (NSDictionary *)notificationWithApplicationStateFromNotification:(NSDictionary *)notification active:(BOOL)active opened:(BOOL)opened
{
    NSDictionary *applicationStateDictionary = @{@"active": [NSNumber numberWithBool:active],
                                                 @"openedFromNotification": [NSNumber numberWithBool:opened]};
    
    return @{@"notification": notification,
             @"applicationState": applicationStateDictionary};
}

//events
- (void)raisePush:(NSString *)message withExtras:(NSDictionary *)extras
{
    [self raisePush:message withExtras:extras active:NO opened:NO];
}

- (void)raisePush:(NSString *)message withExtras:(NSDictionary *)extras active:(BOOL)active opened:(BOOL)opened {
    
    if (!message || !extras) {
        UA_LDEBUG(@"PushNotificationPlugin: attempted to raise push with nil message or extras");
        message = @"";
        extras = [NSMutableDictionary dictionary];
    }
    
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    
    [data setObject:message forKey:@"message"];
    [data setObject:extras forKey:@"extras"];
    
    NSString *json = [NSJSONSerialization stringWithObject:[self notificationWithApplicationStateFromNotification:data active:active opened:opened]];
    NSString *js = [NSString stringWithFormat:@"window.pushNotification.pushCallback(%@);", json];
    
    [self.commandDelegate evalJs:js scheduledOnRunLoop:NO];
    
    UA_LTRACE(@"js callback: %@", js);
}

- (void)raiseRegistration:(BOOL)valid withpushID:(NSString *)pushID {
    
    if (!pushID) {
        UA_LDEBUG(@"PushNotificationPlugin: attempted to raise registration with nil pushID");
        pushID = @"";
        valid = NO;
    }
    
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    if (valid) {
        [data setObject:pushID forKey:@"pushID"];
    } else {
        [data setObject:@"Registration failed." forKey:@"error"];
    }
    
    NSString *json = [NSJSONSerialization stringWithObject:data];
    NSString *js = [NSString stringWithFormat:@"window.pushNotification.registrationCallback(%@);", json];
    
    [self.commandDelegate evalJs:js scheduledOnRunLoop:NO];
    
    UA_LTRACE(@"js callback: %@", js);
}

//registration

- (void)registerForNotificationTypes:(CDVInvokedUrlCommand*)command {
    UA_LDEBUG(@"PushNotificationPlugin: register for notification types");
    
    if (command.arguments.count >= 1) {
        id obj = [command.arguments objectAtIndex:0];
        
        if ([obj isKindOfClass:[NSNumber class]]) {
            UIUserNotificationType bitmask = [obj intValue];
            UALOG(@"bitmask value: %d", [obj intValue]);
            [[UAPush shared] setUserNotificationTypes:bitmask];
            [[UAPush shared] updateRegistration];
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            [self writeJavascript: [result toSuccessCallbackString:command.callbackId]];
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR];
            [self writeJavascript: [result toErrorCallbackString:command.callbackId]];
        }
        
    } else {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR];
        [self writeJavascript: [result toErrorCallbackString:command.callbackId]];
    }
}

//general enablement

- (void)enablePush:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args){
        if (self.disablePush) {
            // Push is explicitly disabled in settings, do nothing
            return;
        }
        
        [UAPush shared].userPushNotificationsEnabled = YES;
        //forces a reregistration
        [[UAPush shared] updateRegistration];
    }];
}

- (void)disablePush:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args){
        [UAPush shared].userPushNotificationsEnabled = NO;
        //forces a reregistration
        [[UAPush shared] updateRegistration];
    }];
}

- (void)enableLocation:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args){
        [UALocationService setAirshipLocationServiceEnabled:YES];
        [[UAirship shared].locationService startReportingSignificantLocationChanges];
    }];
}

- (void)disableLocation:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args){
        [UALocationService setAirshipLocationServiceEnabled:NO];
        [[UAirship shared].locationService stopReportingSignificantLocationChanges];
    }];
}

- (void)enableBackgroundLocation:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args){
        [UAirship shared].locationService.backgroundLocationServiceEnabled = YES;
    }];
}

- (void)disableBackgroundLocation:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args){
        [UAirship shared].locationService.backgroundLocationServiceEnabled = NO;
    }];
}

//getters

- (void)isPushEnabled:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        BOOL enabled = [UAPush shared].userPushNotificationsEnabled;
        return [NSNumber numberWithBool:enabled];
    }];
}

- (void)isQuietTimeEnabled:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        BOOL enabled = [UAPush shared].quietTimeEnabled;
        return [NSNumber numberWithBool:enabled];
    }];
}

- (void)isInQuietTime:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        BOOL inQuietTime;
        NSDictionary *quietTimeDictionary = [UAPush shared].quietTime;
        if (quietTimeDictionary) {
            NSString *start = [quietTimeDictionary valueForKey:@"start"];
            NSString *end = [quietTimeDictionary valueForKey:@"end"];
            
            NSDateFormatter *df = [NSDateFormatter new];
            df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            df.dateFormat = @"HH:mm";
            
            NSDate *startDate = [df dateFromString:start];
            NSDate *endDate = [df dateFromString:end];
            
            NSDate *now = [NSDate date];
            
            inQuietTime = ([now earlierDate:startDate] == startDate && [now earlierDate:endDate] == now);
        } else {
            inQuietTime = NO;
        }
        
        return [NSNumber numberWithBool:inQuietTime];
    }];
}

- (void)isLocationEnabled:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        BOOL enabled = [UALocationService airshipLocationServiceEnabled];
        return [NSNumber numberWithBool:enabled];
    }];
}

- (void)isBackgroundLocationEnabled:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        BOOL enabled = [UAirship shared].locationService.backgroundLocationServiceEnabled;
        return [NSNumber numberWithBool:enabled];
    }];
}

// active: false
// openedFromNotification: true
- (void)getIncoming:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        NSString *incomingAlert = @"";
        NSMutableDictionary *incomingExtras = [NSMutableDictionary dictionary];
        
        if (self.incomingNotification) {
            incomingAlert = [self alertForUserInfo:self.incomingNotification];
            [incomingExtras setDictionary:[self extrasForUserInfo:self.incomingNotification]];
        }
        
        NSMutableDictionary *returnDictionary = [NSMutableDictionary dictionary];
        
        [returnDictionary setObject:incomingAlert forKey:@"message"];
        [returnDictionary setObject:incomingExtras forKey:@"extras"];
        
        //reset incoming push data until the next background push comes in
        self.incomingNotification = nil;
        
        return [self notificationWithApplicationStateFromNotification:returnDictionary active:NO opened:YES];
    }];
}

- (void)getPushID:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        NSString *pushID = [UAirship shared].deviceToken ?: @"";
        return pushID;
    }];
}

- (void)getQuietTime:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        NSDictionary *quietTimeDictionary = [UAPush shared].quietTime;
        //initialize the returned dictionary with zero values
        NSNumber *zero = [NSNumber numberWithInt:0];
        NSDictionary *returnDictionary = [NSDictionary dictionaryWithObjectsAndKeys:zero,@"startHour",
                                          zero,@"startMinute",
                                          zero,@"endHour",
                                          zero,@"endMinute",nil];
        
        //this can be nil if quiet time is not set
        if (quietTimeDictionary) {
            
            NSString *start = [quietTimeDictionary objectForKey:@"start"];
            NSString *end = [quietTimeDictionary objectForKey:@"end"];
            
            NSDateFormatter *df = [NSDateFormatter new];
            df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            df.dateFormat = @"HH:mm";
            
            NSDate *startDate = [df dateFromString:start];
            NSDate *endDate = [df dateFromString:end];
            
            //these will be nil if the dateformatter can't make sense of either string
            if (startDate && endDate) {
                
                NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
                
                NSDateComponents *startComponents = [gregorian components:NSHourCalendarUnit|NSMinuteCalendarUnit fromDate:startDate];
                NSDateComponents *endComponents = [gregorian components:NSHourCalendarUnit|NSMinuteCalendarUnit fromDate:endDate];
                
                NSNumber *startHr = [NSNumber numberWithInteger:startComponents.hour];
                NSNumber *startMin = [NSNumber numberWithInteger:startComponents.minute];
                NSNumber *endHr = [NSNumber numberWithInteger:endComponents.hour];
                NSNumber *endMin = [NSNumber numberWithInteger:endComponents.minute];
                
                returnDictionary = [NSDictionary dictionaryWithObjectsAndKeys:startHr,@"startHour",startMin,@"startMinute",
                                    endHr,@"endHour",endMin,@"endMinute",nil];
            }
        }
        return returnDictionary;
    }];
}

- (void)getTags:(CDVInvokedUrlCommand*)command {
    [self getTagsFromServer:^(NSArray *tags) {
        NSArray *result = [NSArray array];
        if (tags) {
            result = tags;
            [UAPush shared].tags = tags;
        }
        
        [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
            NSDictionary *returnDictionary = [NSDictionary dictionaryWithObjectsAndKeys:result, @"tags", nil];
            return returnDictionary;
        }];
    }];
}

- (void)getAlias:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withBlock:^(NSArray *args){
        NSString *alias = [UAPush shared].alias ?: @"";
        return alias;
    }];
}

//setters

- (void)setTags:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:[NSArray arrayWithObjects:[NSArray class],nil] withVoidBlock:^(NSArray *args) {
        // Since we disabled device tags before registration, we need to enable them again here
        // otherwise nothing will be sent. It is important to always use the flow of getTags:,
        // modify the returned array and then call setTags: with that array to avoid clearing
        // tags set via REST API.
        [UAPush shared].deviceTagsEnabled = YES;
        NSMutableArray *tags = [NSMutableArray arrayWithArray:[args objectAtIndex:0]];
        [UAPush shared].tags = tags;
        [[UAPush shared] updateRegistration];
    }];
}

- (void)setAlias:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:[NSArray arrayWithObjects:[NSString class],nil] withVoidBlock:^(NSArray *args) {
        NSString *alias = [args objectAtIndex:0];
        // If the value passed in is nil or an empty string, set the alias to nil. Empty string will cause registration failures
        // from the Urban Airship API
        alias = [alias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([alias length] == 0) {
            [UAPush shared].alias = nil;
        }
        else{
            [UAPush shared].alias = alias;
        }
        [[UAPush shared] updateRegistration];
    }];
}

- (void)setQuietTimeEnabled:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:[NSArray arrayWithObjects:[NSNumber class],nil] withVoidBlock:^(NSArray *args) {
        NSNumber *value = [args objectAtIndex:0];
        BOOL enabled = [value boolValue];
        [UAPush shared].quietTimeEnabled = enabled;
        [[UAPush shared] updateRegistration];
    }];
}

- (void)setQuietTime:(CDVInvokedUrlCommand*)command {
    Class c = [NSNumber class];
    [self performCallbackWithCommand:command expecting:[NSArray arrayWithObjects:c,c,c,c,nil] withVoidBlock:^(NSArray *args) {
        int startHr = [[args objectAtIndex:0] intValue];
        int startMin = [[args objectAtIndex:1] intValue];
        int endHr = [[args objectAtIndex:2] intValue];
        int endMin = [[args objectAtIndex:3] intValue];
        
        [[UAPush shared] setQuietTimeStartHour:startHr startMinute:startMin endHour:endHr endMinute:endMin];
        [[UAPush shared] updateRegistration];
    }];
}

- (void)setAutobadgeEnabled:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:[NSArray arrayWithObjects:[NSNumber class],nil] withVoidBlock:^(NSArray *args) {
        NSNumber *number = [args objectAtIndex:0];
        BOOL enabled = [number boolValue];
        [UAPush shared].autobadgeEnabled = enabled;
    }];
}

- (void)setBadgeNumber:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:[NSArray arrayWithObjects:[NSNumber class],nil] withVoidBlock:^(NSArray *args) {
        id number = [args objectAtIndex:0];
        NSInteger badgeNumber = [number intValue];
        [[UAPush shared] setBadgeNumber:badgeNumber];
    }];
}

//reset badge

- (void)resetBadge:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args) {
        [[UAPush shared] resetBadge];
        [[UAPush shared] updateRegistration];
    }];
}

//location recording

- (void)recordCurrentLocation:(CDVInvokedUrlCommand*)command {
    [self performCallbackWithCommand:command expecting:nil withVoidBlock:^(NSArray *args) {
        [[UAirship shared].locationService reportCurrentLocation];
    }];
}

#pragma mark - UARegistrationDelegate
- (void)registrationSucceededForChannelID:(NSString *)channelID deviceToken:(NSString *)deviceToken
{
    UA_LINFO(@"PushNotificationPlugin: registered for remote notifications");
    
    [self raiseRegistration:YES withpushID:deviceToken];
}

-(void)registrationFailed
{
    UA_LINFO(@"PushNotificationPlugin: Failed to register for remote notifications");
    
    [self raiseRegistration:NO withpushID:@""];
}

#pragma mark - UAPushNotificationDelegate
- (void)launchedFromNotification:(NSDictionary *)notification {
    UA_LDEBUG(@"The application was launched or resumed from a notification %@", [notification description]);
    
    self.incomingNotification = notification;
    [[UAPush shared] setBadgeNumber:0]; // zero badge after push received
    
    NSString *alert = [self alertForUserInfo:notification];
    NSMutableDictionary *extras = [self extrasForUserInfo:notification];
    
    [self raisePush:alert withExtras:extras active:NO opened:YES];
}

- (void)receivedForegroundNotification:(NSDictionary *)notification
{
    UA_LDEBUG(@"Received a notification while the app was already in the foreground %@", [notification description]);
    
    [[UAPush shared] setBadgeNumber:0]; // zero badge after push received
    
    NSString *alert = [self alertForUserInfo:notification];
    NSMutableDictionary *extras = [self extrasForUserInfo:notification];
    
    [self raisePush:alert withExtras:extras active:YES opened:NO];
}

- (void)receivedForegroundNotification:(NSDictionary *)notification fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    [self receivedForegroundNotification:notification];
    completionHandler(UIBackgroundFetchResultNoData);
}

#pragma mark - Other stuff

- (void)dealloc {
    [UAPush shared].pushNotificationDelegate = nil;
}

- (void)failIfSimulator {
    if ([[[UIDevice currentDevice] model] compare:@"iPhone Simulator"] == NSOrderedSame) {
        UIAlertView *someError = [[UIAlertView alloc] initWithTitle:@"Notice"
                                                            message:@"You will not be able to recieve push notifications in the simulator."
                                                           delegate:self
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
        
        [someError show];
    }
}

// Urban Airship supports setting tags from the device via SDK or from the server via their
// REST API. However, tags set from these two locations don't play nicely with eachother -
// the device does not fetch tags set via the API and setting the tags from the device will
// clear any tags set via API. This method is a workaround for that limitation, it fetches
// the UA channel from their private device API, and channel contains an array of tags
- (void)getTagsFromServer:(void (^)(NSArray *tags))handler {
    UAConfig *config = [UAirship shared].config;
    
    // Construct url to UA device API to get data for current channel (installation)
    NSString *url = [NSString stringWithFormat:@"%@/api/channels/%@", config.deviceAPIURL, [UAPush shared].channelID];
    
    // Construct the Basic Authorization header value using the appKey and appSecret
    NSString *authStr = [NSString stringWithFormat:@"%@:%@", config.appKey, config.appSecret];
    NSData *authData = [authStr dataUsingEncoding:NSUTF8StringEncoding];
    NSString *authValue = [NSString stringWithFormat:@"Basic %@", [authData base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed]];
    
    // Construct and send request
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setHTTPMethod:@"GET"];
    [request setValue:authValue forHTTPHeaderField:@"Authorization"];
    
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        if (connectionError) {
            return handler(nil);
        }
        if (data) {
            NSError *error;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (error) {
                return handler(nil);
            }
            
            NSDictionary *channel = [json objectForKey:@"channel"];
            if (channel) {
                NSArray *tags = [channel objectForKey:@"tags"];
                return handler(tags);
            }
        }
        return handler(nil);
    }];
}

@end
