//
//  NGAudioPlayerControlResponder.m
//  NGAudioPlayer
//
//  Created by Manfred Scheiner on 08.11.12.
//  Copyright (c) 2012 PocketScience GmbH. All rights reserved.
//

#import "NGAudioPlayerControlResponder.h"

@implementation NGAudioPlayerControlResponder

- (id)initWithAudioPlayer:(NGAudioPlayer *)player {
    self = [super init];
    if (self != nil) {
        self.player = player;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:NSSelectorFromString(@"remoteControlReceivedWithEvent:") name:@"remoteControlReceived" object:nil];
    }
    return self;
}

- (void)dealloc {
    self.respondingToControls = NO;
    self.player = nil;
}

- (BOOL)respondingToControls {
    return [self isFirstResponder];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)setRespondingToControls:(BOOL)respondingToControls {
    if (respondingToControls) {
        [self becomeFirstResponder];
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
    else {
        [self resignFirstResponder];
        [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    }
}

- (void)remoteControlReceivedWithEvent:(NSNotification *)notification {
    
    UIEvent *receivedEvent = (UIEvent *)[notification object];
    if (receivedEvent.type == UIEventTypeRemoteControl) {
        switch (receivedEvent.subtype) {
            case UIEventSubtypeRemoteControlTogglePlayPause: {
                [self.player togglePlayback];
                break;
            }
            case UIEventSubtypeRemoteControlPreviousTrack: {
                break;
            }
            case UIEventSubtypeRemoteControlNextTrack: {
                break;
            }
            default: {
                break;
            }
        }
    }
}

@end
