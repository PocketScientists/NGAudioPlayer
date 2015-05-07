

#define kNGAudioPlayerKeypathRate           NSStringFromSelector(@selector(rate))
#define kNGAudioPlayerKeypathStatus         NSStringFromSelector(@selector(status))
#define kNGAudioPlayerKeypathCurrentItem    NSStringFromSelector(@selector(currentItem))
#define kNGAudioPlayerKeypathPlayback       NSStringFromSelector(@selector(playbackLikelyToKeepUp))

//
//  NGAudioPlayer.m
//  NGAudioPlayer
//
//  Created by Matthias Tretter on 21.06.12.
//
//  Contributors:
//  -------------
//  Matthias Tretter (@myell0w)
//  Manfred Scheiner (@scheinem)
//  Alexander Wolf
//
//  Copyright (c) 2012 NOUS Wissensmanagement GmbH. All rights reserved.
//

#import "NGAudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import "NGAudioPlayerControlResponder.h"



static char rateContext;
static char statusContext;

@interface NGAudioPlayer () {
    // flags for methods implemented in the delegate
    struct {
        unsigned int didStartPlaybackOfURL:1;
        unsigned int didFinishPlaybackOfURL:1;
        unsigned int didChangePlaybackState:1;
        unsigned int didFail:1;
        unsigned int didPlayToTime:1;
    } _delegateFlags;
}

@property (nonatomic, readonly) CMTime CMDurationOfCurrentItem;
@property (nonatomic, strong) NGAudioPlayerControlResponder *controlResponder;
@property (nonatomic, assign, readwrite) NGAudioPlayerPlaybackState playbackState;

@property (nonatomic, assign) CGFloat oldTime;
@property (nonatomic, assign) id periodicObserver;

@property (nonatomic, strong) AVQueuePlayer *queuePlayer;


- (NSURL *)URLOfItem:(AVPlayerItem *)item;
- (CMTime)CMDurationOfItem:(AVPlayerItem *)item;
- (NSTimeInterval)durationOfItem:(AVPlayerItem *)item;

- (void)handleRateChange:(NSDictionary *)change;
- (void)handleStatusChange:(NSDictionary *)change;

@end

@implementation NGAudioPlayer

////////////////////////////////////////////////////////////////////////
#pragma mark - Lifecycle
////////////////////////////////////////////////////////////////////////

+ (void)initialize {
    if (self == [NGAudioPlayer class]) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            (void)[self initBackgroundAudio];
        });
    }
}

- (id)initWithURLs:(NSArray *)urls {
    if ((self = [super init])) {
        if (urls.count > 0) {
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:urls.count];
            
            for (NSURL *url in urls) {
                if ([url isKindOfClass:[NSURL class]]) {
                    AVURLAsset *asset = [AVURLAsset assetWithURL: url];
                    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset: asset];
                    [items addObject:item];
                }
            }
            
            _queuePlayer = [AVQueuePlayer queuePlayerWithItems:items];
        } else {
            _queuePlayer = [AVQueuePlayer queuePlayerWithItems:nil];
            
        }
        
        [_queuePlayer addObserver:self forKeyPath:kNGAudioPlayerKeypathRate options:NSKeyValueObservingOptionNew context:&rateContext ];
        [_queuePlayer addObserver:self forKeyPath:kNGAudioPlayerKeypathStatus options:NSKeyValueObservingOptionNew context:&statusContext];
        

        
        _automaticallyUpdateNowPlayingInfoCenter = YES;
        self.usesMediaControls = YES;
        _removeAllURLsOnPlaybackStop = NO;
        
        _delegate_queue = dispatch_get_main_queue();
        
        self.playbackState = NGAudioPlayerPlaybackStateInitialized;
    }
    
    return self;
}

- (id)initWithURL:(NSURL *)url {
    return [self initWithURLs:[NSArray arrayWithObject:url]];
}

- (id)init {
    return [self initWithURLs:nil];
}

- (void)dealloc {
    
    [self removeObserverFromItems];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_queuePlayer removeObserver:self forKeyPath:kNGAudioPlayerKeypathRate];
    [_queuePlayer removeObserver:self forKeyPath:kNGAudioPlayerKeypathStatus];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject KVO
////////////////////////////////////////////////////////////////////////

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSLog(@"observeValueForKeyPath: %@",keyPath);
    if (context == &rateContext && [keyPath isEqualToString:kNGAudioPlayerKeypathRate]) {
        [self handleRateChange:change];
    } else if (context == &statusContext && [keyPath isEqualToString:kNGAudioPlayerKeypathStatus]) {
        [self handleStatusChange:change];
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

////////////////////////////////////////////////////////////////////////
#pragma mark - NGAudioPlayer Properties
////////////////////////////////////////////////////////////////////////

- (BOOL)isPlaying {
    return self.playbackState == NGAudioPlayerPlaybackStatePlaying;
}

- (void)setPlaybackState:(NGAudioPlayerPlaybackState)playbackState {
    if (_playbackState != playbackState) {
        _playbackState = playbackState;
        if (_delegateFlags.didChangePlaybackState) {
            dispatch_async(self.delegate_queue, ^{
                [self.delegate audioPlayerDidChangePlaybackState:_playbackState];
            });
        }
    }
}

- (NSURL *)currentPlayingURL {
    return [self URLOfItem:self.queuePlayer.currentItem];
}

- (NSTimeInterval)durationOfCurrentPlayingURL {
    return [self durationOfItem:self.queuePlayer.currentItem];
}

- (NSArray *)enqueuedURLs {
    NSArray *items = self.queuePlayer.items;
    NSArray *itemsWithURLAssets = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return [self URLOfItem:evaluatedObject] != nil;
    }]];
    
    NSAssert(items.count == itemsWithURLAssets.count, @"All Assets should be AVURLAssets");
    
    return [itemsWithURLAssets valueForKey:@"URL"];
}

- (void)setDelegate:(id<NGAudioPlayerDelegate>)delegate {
    if (delegate != _delegate) {
        _delegate = delegate;
        
        _delegateFlags.didStartPlaybackOfURL = [delegate respondsToSelector:@selector(audioPlayer:didStartPlaybackOfURL:)];
        _delegateFlags.didFinishPlaybackOfURL = [delegate respondsToSelector:@selector(audioPlayer:didFinishPlaybackOfURL:)];
        _delegateFlags.didChangePlaybackState = [delegate respondsToSelector:@selector(audioPlayerDidChangePlaybackState:)];
        _delegateFlags.didFail = [delegate respondsToSelector:@selector(audioPlayer:didFailForURL:)];
        _delegateFlags.didPlayToTime = [delegate respondsToSelector:@selector(audioPlayerDidPlayToTime:fromTime:)];
    }
}

- (BOOL)usesMediaControls {
    if (self.controlResponder == nil) {
        return NO;
    }
    return self.controlResponder.respondingToControls;
}

- (void)setUsesMediaControls:(BOOL)usesMediaControls {
    if (usesMediaControls) {
        if (self.controlResponder == nil) {
            self.controlResponder = [[NGAudioPlayerControlResponder alloc] initWithAudioPlayer:self];
        }
        self.controlResponder.respondingToControls = YES;
    }
    else {
        self.controlResponder.respondingToControls = NO;
    }
}



////////////////////////////////////////////////////////////////////////
#pragma mark - NGAudioPlayer Class Methods
////////////////////////////////////////////////////////////////////////

+ (BOOL)setAudioSessionCategory:(NSString *)audioSessionCategory {
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory:audioSessionCategory
                                           error:&error];
    
    if (error != nil) {
        NSLog(@"There was an error setting the AudioCategory to %@", audioSessionCategory);
        return NO;
    }
    
    return YES;
}

+ (BOOL)initBackgroundAudio {
    if (![self setAudioSessionCategory:AVAudioSessionCategoryPlayback]) {
        return NO;
    }
    
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setActive:YES error:&error]) {
        NSLog(@"Unable to set AudioSession active: %@", error);
        
        return NO;
    }
    
    return YES;
}

////////////////////////////////////////////////////////////////////////
#pragma mark - NGAudioPlayer Playback
////////////////////////////////////////////////////////////////////////

- (void)playURL:(NSURL *)url {
    if (url != nil) {
        [self removeAllURLs];
        [self enqueueURL:url];
        [self play];
    }
}

- (void)play {
    NSLog(@"NGAudioPlayer: PLAY");

    [self addObserverForCurrentItem];
    [self addPeriodicObserver];
    [self.queuePlayer play];
    NSURL *url = [self URLOfItem:self.queuePlayer.currentItem];
    if (url != nil && _delegateFlags.didStartPlaybackOfURL) {
        dispatch_async(self.delegate_queue, ^{
            [self.delegate audioPlayer:self didStartPlaybackOfURL:url];
        });
        
    }
    
    if(!url){
        NSLog(@"NO URL!!!!");
    }
    
    NSDictionary *nowPlayingInfo = url.ng_nowPlayingInfo;
    if (nowPlayingInfo && self.automaticallyUpdateNowPlayingInfoCenter && NSClassFromString(@"MPNowPlayingInfoCenter") != nil) {
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nowPlayingInfo;
        
    }
    
}



-(void)resume:(NSURL *)url{
    NSLog(@"NGAudioPlayer: RESUME");
    
    if(self.queuePlayer.items.count>0){
        [self play];
    }else{
        [self playURL:url];
    }
    
}

- (void)pause {
    NSLog(@"NGAudioPlayer: PAUSE");
    [self removeObserverFromCurrentItem];
    [self.queuePlayer pause];
}

-(void)buffering{
    self.playbackState = NGAudioPlayerPlaybackStateBuffering;
}

- (void)stop {
    NSLog(@"NGAudioPlayer: STOP");
    [self removeObserverFromCurrentItem];
    [self removePeriodicObserver];
    [self.queuePlayer pause];

    NSArray *urls = [self enqueuedURLs];
    [self removeAllURLs];
    if (!self.removeAllURLsOnPlaybackStop) {
        [self enqueueURLs:urls];
    }
}

- (void)togglePlayback {
    if (self.playing) {
        [self pause];
    } else {
        [self play];
    }
}

- (CMTime)currentItemsDuration {
    return [self CMDurationOfCurrentItem];;
}

- (CMTime)currentTime {
    return self.queuePlayer.currentTime;
}

- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL finished))completionHandler {
    [self.queuePlayer seekToTime:time completionHandler:completionHandler];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - NGAudioPlayer Queuing
////////////////////////////////////////////////////////////////////////

- (BOOL)enqueueURL:(NSURL *)url {
    if ([url isKindOfClass:[NSURL class]]) {
        AVURLAsset *asset = [AVURLAsset assetWithURL: url];
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset: asset];
        
        if ([self.queuePlayer canInsertItem:item afterItem:nil]) {
            [self.queuePlayer insertItem:item afterItem:nil];
            
            return YES;
        }
    }
    
    return NO;
}

- (BOOL)enqueueURLs:(NSArray *)urls {
    BOOL successfullyAdded = YES;
    
    for (NSURL *url in urls) {
        if ([url isKindOfClass:[NSURL class]]) {
            successfullyAdded = successfullyAdded && [self enqueueURL:url];
        }
    }
    
    return successfullyAdded;
}

- (BOOL)enqueuePlayerItem:(AVPlayerItem *)item {
    if ([item isKindOfClass:[AVPlayerItem class]]) {
        if ([self.queuePlayer canInsertItem:item afterItem:nil] && [item.asset isKindOfClass:[AVURLAsset class]]) {
            [self.queuePlayer insertItem:item afterItem:nil];
            return YES;
        }
    }
    
    return NO;
}

- (BOOL)enqueueItems:(NSArray *)items {
    BOOL successfullyAdded = YES;
    
    for (AVPlayerItem *item in items) {
        if ([item isKindOfClass:[AVPlayerItem class]]) {
            successfullyAdded = successfullyAdded && [self enqueuePlayerItem:item];
        }
    }
    
    return successfullyAdded;
}

////////////////////////////////////////////////////////////////////////
#pragma mark - NGAudioPlayer Removing
////////////////////////////////////////////////////////////////////////

- (BOOL)removeURL:(NSURL *)url {
    NSArray *items = self.queuePlayer.items;
    NSArray *itemsWithURL = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return [[self URLOfItem:evaluatedObject] isEqual:url];
    }]];
    
    if (itemsWithURL.count > 0) {
        for(AVPlayerItem *item in itemsWithURL){
            [self removeObserverFromItem:item];
            [self.queuePlayer removeItem:item];
        }
        return YES;
    }
    
    return NO;
}

- (void)removeAllURLs {
    [self removeObserverFromItems];
    [self.queuePlayer removeAllItems];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - NGAudioPlayer Advancing
////////////////////////////////////////////////////////////////////////

- (void)advanceToNextURL {
    [self.queuePlayer advanceToNextItem];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - Private
////////////////////////////////////////////////////////////////////////

- (NSURL *)URLOfItem:(AVPlayerItem *)item {
    if ([item isKindOfClass:[AVPlayerItem class]]) {
        AVAsset *asset = item.asset;
        
        if ([asset isKindOfClass:[AVURLAsset class]]) {
            AVURLAsset *urlAsset = (AVURLAsset *)asset;
            
            return urlAsset.URL;
        }
    }
    
    return nil;
}

- (CMTime)CMDurationOfCurrentItem {
    return [self CMDurationOfItem:self.queuePlayer.currentItem];
}

- (CMTime)CMDurationOfItem:(AVPlayerItem *)item {
    // Peferred in HTTP Live Streaming
    if ([item respondsToSelector:@selector(duration)] && // 4.3
        item.status == AVPlayerItemStatusReadyToPlay) {
        
        if (CMTIME_IS_VALID(item.duration)) {
            return item.duration;
        }
    }
    
    else if (CMTIME_IS_VALID(item.asset.duration)) {
        return item.asset.duration;
    }
    
    return kCMTimeInvalid;
}

- (NSTimeInterval)durationOfItem:(AVPlayerItem *)item {
    return CMTimeGetSeconds([self CMDurationOfItem:item]);
}

- (void)handleRateChange:(NSDictionary *)change {
    float rate = [[change valueForKey:NSKeyValueChangeNewKey] floatValue];
    NSLog(@"Rate: %f",rate);
    NSLog(@"Playback Likely To Keep Up: %@" ,self.queuePlayer.currentItem.isPlaybackLikelyToKeepUp ? @"YES" : @"NO");
    if (rate > 0.f) {
        if (self.queuePlayer.currentItem.isPlaybackLikelyToKeepUp ) {
            self.playbackState = NGAudioPlayerPlaybackStatePlaying;
        }
        else {
            self.playbackState = NGAudioPlayerPlaybackStateBuffering;
        }
    }
    else {
        self.playbackState = NGAudioPlayerPlaybackStatePaused;
    }
}

- (void)handleStatusChange:(NSDictionary *)change {
    AVPlayerStatus newStatus = (AVPlayerStatus)[[change valueForKey:NSKeyValueChangeNewKey] intValue];
    NSLog(@"Status: %li", (long)newStatus);
    
    if (newStatus == AVPlayerStatusFailed) {
        if (_delegateFlags.didFail) {
            dispatch_async(self.delegate_queue, ^{
                [self.delegate audioPlayer:self didFailForURL:self.currentPlayingURL];
            });
        }
    }
}

- (void)handlePlaybackStatusChange:(NSDictionary *)change {
    BOOL bufferingFinished = [[change valueForKey:NSKeyValueChangeNewKey] boolValue];

    if (bufferingFinished) {
        if (self.queuePlayer.rate > 0.f) {
            NSLog(@"handlePlaybackStatusChange Rate: %f",self.queuePlayer.rate);
            self.playbackState = NGAudioPlayerPlaybackStatePlaying;
        }
    }
    else {
        self.playbackState = NGAudioPlayerPlaybackStateBuffering;
    }
}




- (void)fadePlayerFromVolume:(CGFloat)fromVolume toVolume:(CGFloat)toVolume duration:(NSTimeInterval)duration {
    CMTime startFadeOutTime = CMTimeMakeWithSeconds(0.0, 1);
    CMTime endFadeOutTime = CMTimeMakeWithSeconds(duration, 1);
    CMTimeRange fadeInTimeRange = CMTimeRangeFromTimeToTime(startFadeOutTime, endFadeOutTime);
    
    AVPlayerItem *playerItem = self.queuePlayer.currentItem;
    
    AVAsset *asset = playerItem.asset;
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    
    NSMutableArray *allAudioParams = [NSMutableArray array];
    for (AVAssetTrack *track in audioTracks) {
        AVMutableAudioMixInputParameters *audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParameters];
        [audioInputParams setVolumeRampFromStartVolume:fromVolume toEndVolume:toVolume timeRange:fadeInTimeRange];
        [audioInputParams setTrackID:[track trackID]];
        [allAudioParams addObject:audioInputParams];
    }
    
    AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
    [audioMix setInputParameters:allAudioParams];
    
    [playerItem setAudioMix:audioMix];
}


#pragma mark - AVPlayerItem Notifications

-(void)addObserversToPlayerItems{
    
    for(AVPlayerItem *item in self.queuePlayer.items){
        [self addObserverToPlayerItem:item];
    }
    
}

-(void)addObserverForCurrentItem{
    AVPlayerItem *item = self.queuePlayer.currentItem;
    if(!item){
        return;
    }
    [self addObserverToPlayerItem:item];
}

-(void)addObserverToPlayerItem:(AVPlayerItem *)item{

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidFailPlayToEnd:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemTimeJumped:) name:AVPlayerItemTimeJumpedNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemPlaybackStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemNewAccessLog:) name:AVPlayerItemNewAccessLogEntryNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemNewErrorLog:) name:AVPlayerItemNewErrorLogEntryNotification object:item];
    
}


-(void)itemDidPlayToEnd:(NSNotification *)notification{
    

    if (_delegateFlags.didFinishPlaybackOfURL) {
        NSURL *url = [self URLOfItem:notification.object];
        
        if (url != nil) {
            dispatch_async(self.delegate_queue, ^{
                [self.delegate audioPlayer:self didFinishPlaybackOfURL:url];
            });
        }
    }else{
    }
    
    [self stop];

}

-(void)itemDidFailPlayToEnd:(NSNotification *)notification{
    self.playbackState = NGAudioPlayerPlaybackStateBuffering;
    
    if (_delegateFlags.didFail) {
        NSURL *url = [self URLOfItem:notification.object];
        
        if (url != nil) {
            dispatch_async(self.delegate_queue, ^{
                [self.delegate audioPlayer:self didFailForURL:url];
            });
        }
    }
}

-(void)itemPlaybackStalled:(NSNotification *)notification{
    NSLog(@"Time Stalled Back");
    
    AVPlayerItem *item = (AVPlayerItem *)notification.object;
    BOOL bufferingFinished = item.playbackLikelyToKeepUp;
    if (bufferingFinished) {
        if (self.queuePlayer.rate > 0.f) {
            
            self.playbackState = NGAudioPlayerPlaybackStatePlaying;
        }
    }
    else {
        self.playbackState = NGAudioPlayerPlaybackStateBuffering;
    }
    
}

-(void)itemTimeJumped:(NSNotification *)notification{
    
    AVPlayerItem *item = (AVPlayerItem *)notification.object;
    if(item){
        NSLog(@"Time Jumped");
        [self play];
    }
}

-(void)itemNewAccessLog:(NSNotification *)notification{
    AVPlayerItem *item = (AVPlayerItem *)notification.object;
    if(item){
        NSLog(@"New Access Log");
    }
    
}

-(void)itemNewErrorLog:(NSNotification *)notification{
    AVPlayerItem *item = (AVPlayerItem *)notification.object;
    if(item){
        NSLog(@"New Error Log");
    }
}

-(void)removeObserverFromItem:(AVPlayerItem *)item{

    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemTimeJumpedNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewAccessLogEntryNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewErrorLogEntryNotification object:item];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemTimeJumpedNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewAccessLogEntryNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewErrorLogEntryNotification object:item];
}

-(void)removeObserverFromCurrentItem{
    AVPlayerItem *item = self.queuePlayer.currentItem;
    if(!item){
        return;
    }else{
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemTimeJumpedNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewAccessLogEntryNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewErrorLogEntryNotification object:nil];

    }
    [self removeObserverFromItem:item];
}

-(void)removeObserverFromItems{
    for(AVPlayerItem *item in self.queuePlayer.items){
        [self removeObserverFromItem:item];
    }
}


#pragma mark - Periodic observer
-(void)addPeriodicObserver{
    __block id strongSelf = self;
    
    if(!self.periodicObserver){
        self.periodicObserver = [_queuePlayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1.f, 1.f) queue:NULL usingBlock:^(CMTime time) {
            NGAudioPlayer *currentPlayer = (NGAudioPlayer *)strongSelf;
            
            CGFloat oldTime = currentPlayer.oldTime;
            CGFloat currentTime =  CMTimeGetSeconds(time);
            CGFloat diff = currentTime-oldTime;
            
            NSLog(@"Old time: %f Current Time: %f Diff:%f",oldTime,currentTime,diff);
            if (diff > 0.0010f && currentPlayer.playbackState == NGAudioPlayerPlaybackStateBuffering) {
                currentPlayer.playbackState = NGAudioPlayerPlaybackStatePlaying;
            } else if (diff <= 0.0010f && currentPlayer.playbackState == NGAudioPlayerPlaybackStatePlaying) {
                currentPlayer.playbackState = NGAudioPlayerPlaybackStateBuffering;
            }
            
            if (currentPlayer->_delegateFlags.didPlayToTime) {
                dispatch_async(currentPlayer.delegate_queue, ^{
                    [currentPlayer.delegate audioPlayerDidPlayToTime:time fromTime:[currentPlayer currentItemsDuration]];
                });
            }
            
            currentPlayer.oldTime = CMTimeGetSeconds(time);
        }];
    }
}

-(void)removePeriodicObserver{
    if(self.periodicObserver){
        [_queuePlayer removeTimeObserver:self.periodicObserver];
        self.periodicObserver=nil;
    }
}


@end
