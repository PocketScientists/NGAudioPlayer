NGAudioPlayer
=============

An audio player for iOS that can handle queueing of URLs, supports background audio and supports iOS standard media and controls.

Supporting iOS standard media and remote controls
-------------------------------------------------

To get the controls connected with NGAudioPlayer unfortunately you need to put this three lines of code into your AppDelegate:

```objectivec
- (void)remoteControlReceivedWithEvent:(UIEvent *)receivedEvent {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"remoteControlReceived" object:receivedEvent];
}
```