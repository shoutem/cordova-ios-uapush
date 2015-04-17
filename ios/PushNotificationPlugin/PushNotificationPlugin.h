//
//  UrbanAirshipPlugin.h
//  urbanairship.richpush
//
//  Created by urbanairship on 6/18/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Cordova/CDVPlugin.h>
#import "UAPush.h"

@interface PushNotificationPlugin : CDVPlugin <UARegistrationDelegate, UAPushNotificationDelegate>{
    
}

- (void)getTags:(CDVInvokedUrlCommand*)command;

@end